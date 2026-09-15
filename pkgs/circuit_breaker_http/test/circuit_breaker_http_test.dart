import 'dart:async';
import 'dart:convert';

import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:circuit_breaker_http/circuit_breaker_http.dart';
import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// A client whose response body never completes, so the only way out is for
/// the caller to cancel the subscription.
final class _StallingClient extends http.BaseClient {
  /// Set when the response body subscription is cancelled.
  bool aborted = false;

  /// Completes once the body has actually started streaming.
  final started = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final controller = StreamController<List<int>>();
    controller.onListen = () {
      controller.add(utf8.encode('partial'));
      if (!started.isCompleted) started.complete();
    };
    controller.onCancel = () {
      aborted = true;
    };
    return http.StreamedResponse(controller.stream, 200);
  }
}

void main() {
  group('RetryAfterParser', () {
    test('parses delta-seconds correctly', () {
      expect(
        RetryAfterParser.parse('120'),
        equals(const Duration(seconds: 120)),
      );
      expect(RetryAfterParser.parse('0'), equals(Duration.zero));
      expect(RetryAfterParser.parse('-10'), equals(Duration.zero));
      expect(
        RetryAfterParser.parse('  45  '),
        equals(const Duration(seconds: 45)),
      );
    });

    test('parses HTTP-date correctly', () {
      final baseTime = DateTime.utc(2026, 10, 21, 7, 28, 0);
      final targetDate = 'Wed, 21 Oct 2026 07:30:00 GMT'; // +120s
      final parsed = RetryAfterParser.parse(targetDate, now: baseTime);
      expect(parsed, equals(const Duration(seconds: 120)));

      // Past date returns Duration.zero
      final pastDate = 'Wed, 21 Oct 2026 07:20:00 GMT';
      expect(
        RetryAfterParser.parse(pastDate, now: baseTime),
        equals(Duration.zero),
      );
    });

    test('an HTTP-date is measured against the ambient clock', () {
      withClock(Clock.fixed(DateTime.utc(2026, 10, 21, 7, 28, 0)), () {
        expect(
          RetryAfterParser.parse('Wed, 21 Oct 2026 07:29:00 GMT'),
          equals(const Duration(seconds: 60)),
        );
      });
    });

    test('returns null on invalid inputs', () {
      expect(RetryAfterParser.parse(null), isNull);
      expect(RetryAfterParser.parse(''), isNull);
      expect(RetryAfterParser.parse('   '), isNull);
      expect(RetryAfterParser.parse('invalid-date-or-number'), isNull);
    });
  });

  group('HttpClassifier', () {
    test('identifies server and client errors', () {
      expect(HttpClassifier.isServerError(500), isTrue);
      expect(HttpClassifier.isServerError(503), isTrue);
      expect(HttpClassifier.isServerError(404), isFalse);

      expect(HttpClassifier.isClientError(400), isTrue);
      expect(HttpClassifier.isClientError(404), isTrue);
      expect(HttpClassifier.isClientError(429), isTrue);
      expect(HttpClassifier.isClientError(500), isFalse);
    });

    test('isTransientStatus covers the self-clearing statuses', () {
      for (final status in [408, 425, 429, 502, 503, 504]) {
        expect(
          HttpClassifier.isTransientStatus(status),
          isTrue,
          reason: '$status should be transient',
        );
      }
      for (final status in [200, 400, 404, 409, 500, 501]) {
        expect(
          HttpClassifier.isTransientStatus(status),
          isFalse,
          reason: '$status should not be transient',
        );
      }
    });

    test('identifies transient errors for retries', () {
      final resp503 = HttpResponseException(http.Response('Unavailable', 503));
      final resp429 = HttpResponseException(http.Response('Rate limited', 429));
      final resp404 = HttpResponseException(http.Response('Not found', 404));

      expect(HttpClassifier.isTransient(resp503), isTrue);
      expect(HttpClassifier.isTransient(resp429), isTrue);
      expect(HttpClassifier.isTransient(resp404), isFalse);
      expect(
        HttpClassifier.isTransient(http.ClientException('connection reset')),
        isTrue,
      );
      expect(HttpClassifier.isTransient(TimeoutException('too slow')), isTrue);
      expect(HttpClassifier.isTransient(ArgumentError('bad arg')), isFalse);
      expect(HttpClassifier.isTransient(StateError('unrelated')), isFalse);
    });

    test('isFailure excludes client errors but keeps 429', () {
      final resp404 = HttpResponseException(http.Response('Not found', 404));
      final resp400 = HttpResponseException(http.Response('Bad request', 400));
      final resp401 = HttpResponseException(http.Response('Expired', 401));
      final resp429 = HttpResponseException(http.Response('Slow down', 429));
      final resp500 = HttpResponseException(http.Response('Crash', 500));
      final resp503 = HttpResponseException(http.Response('Down', 503));

      expect(HttpClassifier.isFailure(resp404), isFalse);
      expect(HttpClassifier.isFailure(resp400), isFalse);
      expect(HttpClassifier.isFailure(resp401), isFalse);
      expect(HttpClassifier.isFailure(resp429), isTrue);
      expect(HttpClassifier.isFailure(resp500), isTrue);
      expect(HttpClassifier.isFailure(resp503), isTrue);
      expect(HttpClassifier.isFailure(http.ClientException('dropped')), isTrue);
      expect(HttpClassifier.isFailure(ArgumentError('bad arg')), isFalse);
    });
  });

  group('httpPolicy / httpResourceConfig', () {
    test('repeated 404s never open the circuit', () async {
      final client = MockClient((request) async {
        return http.Response('Not Found', 404);
      });

      final policy = httpPolicy(
        circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 2),
      );

      for (var i = 0; i < 6; i++) {
        await expectLater(
          policy.executeHttp(
            client,
            () => http.Request('GET', Uri.parse('https://example.com/missing')),
          ),
          throwsA(isA<HttpResponseException>()),
          reason: 'attempt $i must surface the 404, not an open circuit',
        );
      }
      expect(policy.circuitState, equals(CircuitState.closed));
    });

    test('a hand-rolled policy without the classifier self-destructs', () async {
      // The counter-example that motivates httpPolicy: with the core's generic
      // classifier a 404 counts as a backend failure, so a client mistake
      // poisons the resource health shared by every caller.
      var serverHits = 0;
      final client = MockClient((request) async {
        serverHits++;
        return http.Response('Not Found', 404);
      });

      final policy = ResiliencePolicy(
        circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 2),
      );

      Object? rejection;
      for (var i = 0; i < 6 && rejection == null; i++) {
        try {
          await policy.executeHttp(
            client,
            () => http.Request('GET', Uri.parse('https://example.com/missing')),
          );
        } on HttpResponseException {
          // The 404 reached the caller; keep going.
        } on ResilienceException catch (e) {
          rejection = e;
        }
      }

      expect(
        rejection,
        isNotNull,
        reason: 'repeated 404s should have tripped the resilience layer',
      );
      expect(serverHits, lessThan(6));
    });

    test('repeated 503s still open the circuit', () async {
      final client = MockClient((request) async {
        return http.Response('Unavailable', 503);
      });

      final policy = httpPolicy(
        circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 2),
        retry: RetryConfig(maxAttempts: 1),
      );

      for (var i = 0; i < 2; i++) {
        await expectLater(
          policy.executeHttp(
            client,
            () => http.Request('GET', Uri.parse('https://example.com/down')),
          ),
          throwsA(isA<HttpResponseException>()),
        );
      }
      expect(policy.circuitState, equals(CircuitState.open));

      await expectLater(
        policy.executeHttp(
          client,
          () => http.Request('GET', Uri.parse('https://example.com/down')),
        ),
        throwsA(isA<CircuitBreakerOpenException>()),
      );
    });

    test('httpResourceConfig wires the classifier onto a named Resource', () {
      final config = httpResourceConfig();
      expect(config.failureClassifier, same(HttpClassifier.isFailure));
      expect(config.retry.suggestedDelay, same(HttpClassifier.retryAfterDelay));

      final resource = Resource('users-api', config: config);
      expect(resource.config.failureClassifier, same(HttpClassifier.isFailure));
    });

    test('an explicit failureClassifier wins over the HTTP default', () {
      bool everythingFails(Object error) => true;
      final config = httpResourceConfig(failureClassifier: everythingFails);
      expect(config.failureClassifier, same(everythingFails));
    });
  });

  group('executeHttp', () {
    test('completes successfully on 200 OK', () async {
      final client = MockClient((request) async {
        return http.Response(
          '{"status": "ok"}',
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final policy = ResiliencePolicy();
      final response = await policy.executeHttp(
        client,
        () => http.Request('GET', Uri.parse('https://example.com/api')),
      );

      expect(response.statusCode, equals(200));
      expect(response.body, contains('"ok"'));
    });

    test(
      'calls requestFactory on each attempt and retries transient failures',
      () async {
        int factoryInvocations = 0;
        int clientInvocations = 0;

        final client = MockClient((request) async {
          clientInvocations++;
          if (clientInvocations == 1) {
            return http.Response('Service Unavailable', 503);
          }
          return http.Response('Success', 200);
        });

        final policy = ResiliencePolicy(
          retry: RetryConfig(
            maxAttempts: 3,
            baseDelay: const Duration(milliseconds: 10),
          ),
        );

        final response = await policy.executeHttp(client, () {
          factoryInvocations++;
          return http.Request('POST', Uri.parse('https://example.com/items'))
            ..body = jsonEncode({'attempt': factoryInvocations});
        });

        expect(response.statusCode, equals(200));
        expect(factoryInvocations, equals(2));
        expect(clientInvocations, equals(2));
      },
    );

    test('client error 404 fails immediately without retrying', () async {
      int clientInvocations = 0;

      final client = MockClient((request) async {
        clientInvocations++;
        return http.Response('Not Found', 404);
      });

      final policy = ResiliencePolicy(retry: RetryConfig(maxAttempts: 3));

      await expectLater(
        policy.executeHttp(
          client,
          () => http.Request('GET', Uri.parse('https://example.com/missing')),
        ),
        throwsA(
          isA<HttpResponseException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );

      expect(clientInvocations, equals(1));
    });

    test('validateStatus overrides the default <400 rule', () async {
      final client = MockClient((request) async {
        return http.Response('', 302, headers: {'location': '/elsewhere'});
      });

      final policy = httpPolicy();

      // The default accepts a surfaced 3xx.
      final permissive = await policy.executeHttp(
        client,
        () => http.Request('GET', Uri.parse('https://example.com/moved')),
      );
      expect(permissive.statusCode, equals(302));

      await expectLater(
        policy.executeHttp(
          client,
          () => http.Request('GET', Uri.parse('https://example.com/moved')),
          validateStatus: (response) => response.statusCode < 300,
        ),
        throwsA(isA<HttpResponseException>()),
      );
    });

    test('accepts any BaseRequest, including MultipartRequest', () async {
      String? seenBody;
      final client = MockClient((request) async {
        seenBody = request.body;
        return http.Response('uploaded', 200);
      });

      final policy = httpPolicy();
      final response = await policy.executeHttp(client, () {
        return http.MultipartRequest(
            'POST',
            Uri.parse('https://example.com/upload'),
          )
          ..files.add(
            http.MultipartFile.fromString(
              'report',
              'hello,world',
              filename: 'r.csv',
            ),
          );
      });

      expect(response.body, equals('uploaded'));
      expect(seenBody, contains('hello,world'));
    });

    test('aborts the response body when the deadline expires', () async {
      final client = _StallingClient();
      final policy = httpPolicy(retry: RetryConfig(maxAttempts: 1));

      await expectLater(
        policy.executeHttp(
          client,
          () => http.Request('GET', Uri.parse('https://example.com/slow')),
          timeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<ResilienceTimeoutException>()),
      );

      // Give the cancellation a turn of the event loop to propagate.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        client.aborted,
        isTrue,
        reason: 'the socket must be released, not left draining',
      );
    });

    test('aborts the response body when the caller cancels', () async {
      final client = _StallingClient();
      final policy = httpPolicy(retry: RetryConfig(maxAttempts: 1));
      final token = CancellationToken();

      final pending = policy.executeHttp(
        client,
        () => http.Request('GET', Uri.parse('https://example.com/slow')),
        cancelToken: token,
      );

      await client.started.future;
      token.cancel();

      await expectLater(pending, throwsA(isA<OperationCancelledException>()));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(client.aborted, isTrue);
    });

    test('surfaces a mid-stream disconnect as a failure', () async {
      final client = MockClient.streaming((request, bodyStream) async {
        final controller = StreamController<List<int>>();
        controller.add(utf8.encode('half a '));
        controller.addError(http.ClientException('connection closed'));
        unawaited(controller.close());
        return http.StreamedResponse(controller.stream, 200);
      });

      final policy = httpPolicy(retry: RetryConfig(maxAttempts: 1));

      await expectLater(
        policy.executeHttp(
          client,
          () => http.Request('GET', Uri.parse('https://example.com/truncated')),
        ),
        throwsA(isA<http.ClientException>()),
      );
    });
  });

  group('ResilienceContext.executeHttp', () {
    test('accepts an Operation and honours its retry override', () async {
      var attempts = 0;
      final client = MockClient((request) async {
        attempts++;
        return http.Response('Unavailable', 503);
      });

      final context = ResilienceContext();
      final resource = Resource(
        'flaky-api',
        config: httpResourceConfig(
          retry: RetryConfig(
            maxAttempts: 5,
            baseDelay: const Duration(milliseconds: 1),
          ),
        ),
      );
      final operation = Operation(
        'ping',
        resource,
        retryOverride: RetryConfig(maxAttempts: 2),
        criticality: Criticality.sheddable,
      );

      await expectLater(
        context.executeHttp(
          operation,
          client,
          () => http.Request('GET', Uri.parse('https://example.com/ping')),
        ),
        throwsA(isA<HttpResponseException>()),
      );

      expect(
        attempts,
        equals(2),
        reason: "the Operation's retryOverride must win over the resource",
      );
    });

    test('a plain Resource still works', () async {
      final client = MockClient((request) async {
        return http.Response('ok', 200);
      });

      final context = ResilienceContext();
      final resource = Resource('users-api', config: httpResourceConfig());

      final response = await context.executeHttp(
        resource,
        client,
        () => http.Request('GET', Uri.parse('https://example.com/users')),
      );
      expect(response.statusCode, equals(200));
    });

    test('404s do not open the circuit for a named resource', () async {
      final client = MockClient((request) async {
        return http.Response('Not Found', 404);
      });

      final context = ResilienceContext();
      final resource = Resource(
        'users-api',
        config: httpResourceConfig(
          circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 2),
        ),
      );

      for (var i = 0; i < 5; i++) {
        await expectLater(
          context.executeHttp(
            resource,
            client,
            () => http.Request('GET', Uri.parse('https://example.com/nope')),
          ),
          throwsA(isA<HttpResponseException>()),
        );
      }
      expect(
        context.getMetricsSnapshot(resource).circuitState,
        equals(CircuitState.closed),
      );
    });
  });

  group('HttpClassifier.retryAfterDelay', () {
    test('extracts the Retry-After header from an HTTP error', () {
      final rateLimited = HttpResponseException(
        http.Response('slow down', 429, headers: {'retry-after': '7'}),
      );
      expect(
        HttpClassifier.retryAfterDelay(1, rateLimited),
        equals(const Duration(seconds: 7)),
      );
    });

    test('defers to standard backoff when there is no usable header', () {
      final noHeader = HttpResponseException(http.Response('down', 503));
      final garbage = HttpResponseException(
        http.Response('down', 503, headers: {'retry-after': 'soonish'}),
      );

      expect(HttpClassifier.retryAfterDelay(1, noHeader), isNull);
      expect(HttpClassifier.retryAfterDelay(1, garbage), isNull);
      expect(
        HttpClassifier.retryAfterDelay(1, StateError('unrelated')),
        isNull,
      );
    });

    test('actually paces retries when wired into RetryConfig', () async {
      var attempts = 0;
      final client = MockClient((request) async {
        attempts++;
        if (attempts == 1) {
          return http.Response('slow down', 429, headers: {'retry-after': '1'});
        }
        return http.Response('ok', 200);
      });

      final policy = ResiliencePolicy(
        retry: RetryConfig(
          maxAttempts: 2,
          // Backoff alone would retry almost immediately; the header must win.
          baseDelay: const Duration(milliseconds: 1),
          maxDelay: const Duration(seconds: 30),
          enableJitter: false,
          suggestedDelay: HttpClassifier.retryAfterDelay,
        ),
      );

      final stopwatch = Stopwatch()..start();
      final response = await policy.executeHttp(
        client,
        () => http.Request('GET', Uri.parse('https://example.com/limited')),
      );
      stopwatch.stop();

      expect(response.statusCode, 200);
      expect(attempts, 2);
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 900)),
        reason: 'must have waited out the Retry-After, not the 1ms backoff',
      );
    });

    test('maxDelay caps a hostile Retry-After', () async {
      var attempts = 0;
      final client = MockClient((request) async {
        attempts++;
        if (attempts == 1) {
          return http.Response(
            'go away',
            503,
            headers: {'retry-after': '86400'}, // one day
          );
        }
        return http.Response('ok', 200);
      });

      final policy = ResiliencePolicy(
        retry: RetryConfig(
          maxAttempts: 2,
          baseDelay: const Duration(milliseconds: 1),
          maxDelay: const Duration(milliseconds: 50),
          enableJitter: false,
          suggestedDelay: HttpClassifier.retryAfterDelay,
        ),
      );

      final response = await policy
          .executeHttp(
            client,
            () => http.Request('GET', Uri.parse('https://example.com/limited')),
          )
          .timeout(const Duration(seconds: 5));

      expect(response.statusCode, 200);
      expect(attempts, 2);
    });

    test('httpPolicy honours Retry-After out of the box', () async {
      var attempts = 0;
      final client = MockClient((request) async {
        attempts++;
        if (attempts == 1) {
          return http.Response('slow down', 429, headers: {'retry-after': '0'});
        }
        return http.Response('ok', 200);
      });

      final response = await httpPolicy().executeHttp(
        client,
        () => http.Request('GET', Uri.parse('https://example.com/limited')),
      );

      expect(response.statusCode, 200);
      expect(attempts, 2);
    });
  });
}
