# circuit_breaker_http

HTTP client resilience extensions, failure classification, and retry policies for [`package:circuit_breaker`](https://pub.dev/packages/circuit_breaker).

## Why not wrap `http.BaseClient`?

Wrapping `http.BaseClient` directly introduces fundamental semantic flaws in HTTP resilience:
1. **Streaming Lifecycle Mismatch**: `client.send()` completes as soon as HTTP headers arrive (TTFB). If the connection drops mid-body during streaming, a `send()` wrapper records a false success, distorting circuit breaker metrics and preventing transparent retries.
2. **Single-Use Requests**: Calling `request.finalize()` on an `http.BaseRequest` locks the request body. A wrapper cannot re-send or hedge the request without cloning it in memory, breaking streaming requests.

Instead, `circuit_breaker_http` operates at the **operation boundary** using a request factory (`() => http.Request(...)`) and awaits the full response body before declaring success.

## Features

- **`executeHttp`**: Extension on `ResiliencePolicy` and `ResilienceContext` that executes requests via a factory function, awaiting the full response before recording success.
- **`HttpClassifier`**: Failure and retry predicates that distinguish 5xx server errors and network dropouts from 4xx client errors (so client bugs or typos never trip your circuit breaker).
- **`RetryAfterParser`**: RFC 9110 compliant parser for `Retry-After` headers supporting both delta-seconds (`120`) and HTTP dates (`Wed, 21 Oct 2026 07:28:00 GMT`).
- **`HttpResponseException`**: Typed exception carrying the full `http.Response`, status code, headers, and parsed `retryAfter`.

## Usage

```dart
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:circuit_breaker_http/circuit_breaker_http.dart';
import 'package:http/http.dart' as http;

final policy = ResiliencePolicy(
  circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 5),
  retry: RetryConfig(
    maxAttempts: 3,
    baseDelay: Duration(milliseconds: 200),
  ),
  failureClassifier: HttpClassifier.defaultFailureClassifier,
);

final client = http.Client();

// Fresh request created for each attempt:
final response = await policy.executeHttp(
  client,
  () => http.Request('GET', Uri.parse('https://api.example.com/data')),
);

print(response.body);
```
