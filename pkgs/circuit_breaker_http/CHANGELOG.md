## 0.1.0

- Initial release of `circuit_breaker_http`.
- Added `executeHttp` extension for `ResiliencePolicy` and `ResilienceContext`.
- Added `HttpClassifier` for failure and transient error detection.
- Added `RetryAfterParser` supporting RFC 9110 delta-seconds and HTTP-date.
- Added `HttpResponseException` carrying underlying response and metadata.
- Added `HttpDelayCalculators.respectRetryAfter`.
