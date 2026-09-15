## 0.1.0

Initial release of `circuit_breaker`, a production-grade resilience engineering library for Dart and Flutter.

### Features & Resilience Patterns

- **Circuit Breaker**:
  - Fail-fast protection across `closed`, `open`, and `halfOpen` states.
  - Configurable consecutive failure threshold and reset timeout.
  - Isolated trial executions in half-open state with graceful recovery or re-opening.
  - Available as standalone primitive (`CircuitBreaker.standalone`) or managed via context.

- **Exponential Retry & Retry Budgets**:
  - Exponential backoff with configurable base delay, max delay, and full jitter to prevent thundering herds.
  - Client-side retry budget to bound retries to a percentage of total requests (Google SRE pattern).
  - Custom failure classification via `failureClassifier` predicates.
  - `RetryConfig.suggestedDelay` hook letting an error state its own retry timing (e.g. an HTTP `Retry-After` header) in place of the computed backoff.
  - Zero-boilerplate `retry(...)` function and stateful `Retry.standalone`.

- **Adaptive Throttling & Criticality**:
  - Client-side adaptive throttling implementation based on Google SRE statistical formula ($P_{\text{throttle}}$).
  - Rolling-window request and accept accounting.
  - Tiered request criticality levels (`criticalPlus`, `critical`, `sheddablePlus`, `sheddable`) for graceful load shedding.
  - Available as `AdaptiveThrottler.standalone` or within context/policy.

- **Request Hedging**:
  - Speculative request duplication for idempotent operations to tame tail latency (*The Tail at Scale*).
  - Static delay or dynamic percentile latency estimation (e.g. P95 tracking).
  - Concurrency caps and hedge token bucket to prevent downstream overload.
  - Zero-boilerplate `hedge(...)` function and `RequestHedger.standalone`.

- **Composite Policy & Progressive Adoption**:
  - `ResiliencePolicy`: Bundles circuit breaking, retries, throttling, hedging, and timeouts into a unified policy.
  - High-order function decorators (`wrap` and `wrapUnary`) for seamless zero-boilerplate integration into existing codebases.

- **Resilience Context & Hierarchical Resources**:
  - `ResilienceContext`: Enterprise multi-tier resource management with named and hierarchical resources.
  - Cascading health evaluation and deadlock-free trial dispatching across parent-child resource topologies.
  - Fallback handlers for graceful degradation.

- **Deadline Propagation & Cooperative Cancellation**:
  - Zone-scoped deadline propagation across nested calls to prevent zombie requests.
  - Integrated `CancellationToken` support for cooperative task cancellation.

- **Observability & Telemetry**:
  - Structured event streams (`ResilienceEvent`) capturing state changes, throttle events, retries, hedges, and completion metrics.
  - Real-time metrics snapshots and rate trackers.
