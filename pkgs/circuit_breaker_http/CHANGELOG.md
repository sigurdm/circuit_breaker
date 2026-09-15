## 0.1.0

- Initial release of `circuit_breaker_http`.
- Added `httpPolicy` and `httpResourceConfig`, which pre-wire
  `HttpClassifier.isFailure` so client errors such as `404` and `401` never
  open a circuit.
- Added `executeHttp` extensions on `ResiliencePolicy` and `ResilienceContext`.
  The context extension accepts any `ResilienceTarget`, so an `Operation` can
  attach criticality and per-call overrides.
- `executeHttp` aborts the response body when the operation is cancelled — a
  lost hedge, an expired deadline, or an explicit `CancellationToken` — instead
  of leaving the socket draining.
- The request factory returns `http.BaseRequest`, so `MultipartRequest` and
  `StreamedRequest` work.
- Added `HttpClassifier`, separating `isFailure` (counts against the backend)
  from `isTransient` (worth another attempt).
- Added `HttpClassifier.retryAfterDelay`, a `RetryDelaySuggestion` that makes
  retry backoff honour the server's `Retry-After` header.
- Added `RetryAfterParser` supporting RFC 9110 delta-seconds and HTTP-date.
- Added `HttpResponseException` carrying the underlying response and metadata.
