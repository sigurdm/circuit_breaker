# circuit_breaker_http

HTTP resilience for [`package:circuit_breaker`](https://pub.dev/packages/circuit_breaker): circuit breaking, retry, hedging, adaptive throttling and deadlines around `package:http`.

Pure Dart — works on native, web and wasm.

## Why not wrap `http.BaseClient`?

A `BaseClient` wrapper is the obvious design, and it is wrong for two reasons:

1. **The streaming lifecycle doesn't line up.** `client.send()` completes when the response *headers* arrive. If the connection dies at byte 10 of 100, the wrapper has already recorded a success — the circuit breaker never learns about it, and retry can't act on it.
2. **Requests are single-use.** `request.finalize()` locks the body. A wrapper holding a finalized `http.BaseRequest` cannot replay it for a retry or a hedge without cloning it in memory, which is impossible for a streamed request.

So this package attaches resilience at the **operation boundary** instead. You hand it a *factory* — `() => http.Request(...)` — and it reads the body to completion inside the protected operation. Every attempt gets a fresh request, and a truncated body is the failure it actually is.

## Usage

Start from `httpPolicy`. It is `ResiliencePolicy` with HTTP-aware defaults pre-wired:

```dart
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:circuit_breaker_http/circuit_breaker_http.dart';
import 'package:http/http.dart' as http;

final policy = httpPolicy(
  circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 5),
  retry: RetryConfig(
    maxAttempts: 3,
    baseDelay: Duration(milliseconds: 200),
    maxDelay: Duration(seconds: 30),
    suggestedDelay: HttpClassifier.retryAfterDelay,
  ),
);

final client = http.Client();

// The factory runs once per attempt.
final response = await policy.executeHttp(
  client,
  () => http.Request('GET', Uri.parse('https://api.example.com/data')),
);
```

For a named resource shared across a process, use `httpResourceConfig` with a `ResilienceContext`:

```dart
final context = ResilienceContext();
final api = Resource('users-api', config: httpResourceConfig(
  circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 5),
));

// An Operation attaches criticality, so a bulk sync is shed before checkout
// traffic against the same host.
final sync = Operation('nightly-sync', api, criticality: Criticality.sheddable);

final response = await context.executeHttp(
  sync,
  client,
  () => http.Request('GET', Uri.parse('https://api.example.com/bulk')),
);
```

> [!IMPORTANT]
> Use `httpPolicy` / `httpResourceConfig` rather than constructing `ResiliencePolicy` or `ResourceConfig` by hand. The core's generic failure classifier treats *any* exception as a backend failure, so a handful of `401`s from an expired token will open the circuit for every caller. These factories default `failureClassifier` to `HttpClassifier.isFailure`, which knows a `404` says nothing about backend health.

## Two predicates, two questions

| | Question | Drives | Default |
| :-- | :--- | :--- | :--- |
| `HttpClassifier.isFailure` | Does this count against the backend? | Circuit breaker, adaptive throttling | 5xx, `429`, transport errors |
| `HttpClassifier.isTransient` | Is another attempt likely to fare better? | Retry (`retryOn`) | `408`, `425`, `429`, `502`, `503`, `504`, transport errors |

They deliberately disagree. A bare `500` counts against the backend but is *not* retried by default: the server has already processed something and gone wrong, so replaying a non-idempotent request risks duplicating it. Pass `retryOn: HttpClassifier.isFailure` — or anything you like — per call when the request is idempotent.

## Status validation

By default any status below 400 is accepted. That includes a surfaced 3xx, which only shows up when redirects are disabled. Pass `validateStatus` for anything stricter:

```dart
await policy.executeHttp(
  client,
  () => http.Request('GET', uri),
  validateStatus: (response) => response.statusCode == 200,
);
```

A rejected status throws `HttpResponseException`, carrying the full `http.Response`, the status code, the headers, and a parsed `retryAfter`.

## Cancellation

`executeHttp` runs the request under `executeCancelable`, so when the deadline expires, the caller cancels, or a hedge loses the race, the response body subscription is cancelled and the socket is released. Without that, a timed-out request keeps draining bytes nobody will read.

```dart
final token = CancellationToken();
final pending = policy.executeHttp(
  client,
  () => http.Request('GET', uri),
  cancelToken: token,
);
token.cancel(); // Aborts the in-flight body.
```

## `Retry-After`

`HttpClassifier.retryAfterDelay` plugs into `RetryConfig.suggestedDelay` so backoff waits exactly as long as the server asked instead of guessing. It is on by default in `httpPolicy` and `httpResourceConfig`.

The value is clamped to `RetryConfig.maxDelay`, so a hostile `Retry-After: 86400` cannot stall a call for a day. `RetryAfterParser` accepts both RFC 9110 forms: delta-seconds (`120`) and an HTTP-date (`Wed, 21 Oct 2026 07:28:00 GMT`).

> [!NOTE]
> `HttpResponseException` sits outside the sealed `ResilienceException` hierarchy — Dart does not permit a sealed type to be implemented from another library. An exhaustive `switch` over `ResilienceException` will not cover HTTP status failures; match `HttpResponseException` separately.
