import 'dart:convert';
import 'dart:io';

import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:circuit_breaker_http/circuit_breaker_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

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

    test('identifies transient errors for retries', () {
      final resp503 = HttpResponseException(http.Response('Unavailable', 503));
      final resp429 = HttpResponseException(http.Response('Rate limited', 429));
      final resp404 = HttpResponseException(http.Response('Not found', 404));
      final socketError = const SocketException('Connection reset');

      expect(HttpClassifier.isTransient(resp503), isTrue);
      expect(HttpClassifier.isTransient(resp429), isTrue);
      expect(HttpClassifier.isTransient(resp404), isFalse);
      expect(HttpClassifier.isTransient(socketError), isTrue);
      expect(HttpClassifier.isTransient(ArgumentError('bad arg')), isFalse);
    });

    test('defaultFailureClassifier excludes client errors', () {
      final resp404 = HttpResponseException(http.Response('Not found', 404));
      final resp400 = HttpResponseException(http.Response('Bad request', 400));
      final resp500 = HttpResponseException(http.Response('Crash', 500));
      final resp503 = HttpResponseException(http.Response('Down', 503));

      expect(HttpClassifier.defaultFailureClassifier(resp404), isFalse);
      expect(HttpClassifier.defaultFailureClassifier(resp400), isFalse);
      expect(HttpClassifier.defaultFailureClassifier(resp500), isTrue);
      expect(HttpClassifier.defaultFailureClassifier(resp503), isTrue);
      expect(
        HttpClassifier.defaultFailureClassifier(
          const SocketException('dropped'),
        ),
        isTrue,
      );
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
  });
}
