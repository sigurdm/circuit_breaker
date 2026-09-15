// A self-contained tour of circuit_breaker_http, running against an in-memory
// server so it needs no network. Swap `_flakyServer()` for `http.Client()` to
// point it at a real host.
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:circuit_breaker_http/circuit_breaker_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<void> main() async {
  final client = _flakyServer();

  // httpPolicy pre-wires HttpClassifier.isFailure, so a 404 never opens the
  // circuit, and honours Retry-After out of the box.
  final policy = httpPolicy(
    circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 3),
    retry: RetryConfig(
      maxAttempts: 4,
      baseDelay: const Duration(milliseconds: 50),
      maxDelay: const Duration(seconds: 5),
    ),
    timeout: const Duration(seconds: 2),
  );

  // The factory runs once per attempt, so retries get a fresh request.
  final response = await policy.executeHttp(
    client,
    () => http.Request('GET', Uri.parse('https://example.com/flaky')),
  );
  print('recovered after retries: ${response.statusCode} ${response.body}');

  // A 404 is surfaced to the caller but does not count against the backend.
  try {
    await policy.executeHttp(
      client,
      () => http.Request('GET', Uri.parse('https://example.com/missing')),
    );
  } on HttpResponseException catch (e) {
    print(
      'client error surfaced: ${e.statusCode}, '
      'circuit still ${policy.circuitState.name}',
    );
  }

  // A named resource shared across a process, with criticality attached so
  // bulk traffic is shed before interactive traffic.
  final context = ResilienceContext();
  final api = Resource(
    'example-api',
    config: httpResourceConfig(
      circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 5),
    ),
  );
  final sync = Operation(
    'nightly-sync',
    api,
    criticality: Criticality.sheddable,
  );

  final bulk = await context.executeHttp(
    sync,
    client,
    () => http.Request('GET', Uri.parse('https://example.com/bulk')),
    timeout: const Duration(seconds: 10),
  );
  print('bulk sync: ${bulk.statusCode}');

  client.close();
}

/// Fails `/flaky` twice with a 503 before succeeding.
http.Client _flakyServer() {
  var flakyHits = 0;
  return MockClient((request) async {
    switch (request.url.path) {
      case '/flaky':
        if (++flakyHits <= 2) {
          return http.Response(
            'warming up',
            503,
            headers: {'retry-after': '0'},
          );
        }
        return http.Response('ok', 200);
      case '/missing':
        return http.Response('no such thing', 404);
      default:
        return http.Response('ok', 200);
    }
  });
}
