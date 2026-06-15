# Circuit Breaker & Resilience Patterns for Dart

A resilience library for Dart applications implementing patterns for distributed systems, inspired by the Google SRE book and release engineering practices.

## Features

*   **Circuit Breaking**: Fast-fail requests when error thresholds are exceeded to protect failing dependencies.
*   **Adaptive Throttling**: Client-side throttling to protect backends from overload (Google SRE book, Chapter 21).
*   **Request Hedging**: Speculative parallel requests to mitigate tail latency (The Tail at Scale).
*   **Retry Budgets**: Rolling window budget to prevent client-induced retry storms.
*   **Execution Timeouts**: Integrated timeouts that propagate cancellation to active hedges.
*   **Failure Classification**: Distinguish application-level errors from system failures.
*   **Hierarchical Configuration**: Share state across resources while overriding settings for specific operations.
*   **Criticality Awareness**: Prioritize traffic and throttle less critical requests first.

## Core Concepts

### Adaptive Throttling (Retry Storm Prevention)

When a backend is overloaded, client retries can exacerbate the issue (retry storms). Adaptive throttling client-side calculates a rejection probability based on the ratio of accepted requests to total requests:

```
P_throttle = max(0, (requests - K × accepts) / (requests + 1))
```

Where `K` is the acceptance multiplier (e.g., `2.0`). If `K = 2`, the client will allow at most twice as many requests as the backend is successfully accepting. Excess requests are rejected locally with a `ThrottledException`.

### Circuit Breaking (Failing Fast)

Avoids wasting resources on a dependency that is down. Using the electrical analogy, a **closed** circuit allows traffic to flow, while an **open** circuit breaks the path, blocking all requests.

The circuit breaker transitions through three states:
*   **Closed**: Normal operation. Requests are allowed to pass through to the backend.
*   **Open**: The backend is failing. Requests are blocked and fail immediately with `CircuitBreakerOpenException`.
*   **Half-Open**: The reset timeout has expired. The client allows a single trial request to test if the backend has recovered.


### Request Hedging (Tail Latency Mitigation)

Speculatively sends a second, parallel request if the first request does not complete within a configured delay. 
If a service has a 5% chance of taking >1s, hedging after 1s reduces the probability of both requests taking >1s to `0.05 × 0.05 = 0.25%`, significantly reducing tail latency at the cost of at most 5% extra traffic.

The library supports two modes of hedging:
*   **Static Hedging**: Uses a fixed pre-configured delay.
*   **Dynamic (Adaptive) Hedging**: Automatically estimates the target percentile latency (e.g., P95) at runtime using a memory-efficient stochastic tracker (Robbins-Monro algorithm) and adjusts the hedging delay dynamically. It includes overload protection (token bucket) to limit the percentage of traffic hedged, and concurrency limits to avoid thundering herds.

> [!IMPORTANT]
> Only use hedging for **idempotent** operations (like reads) as it causes operations to be executed multiple times.

### Dynamic vs. Static Hedging

Choosing between static and dynamic hedging depends on your backend's characteristics and your operational requirements.

| Scenario / Feature | Static Hedging (Fixed Delay) | Dynamic Hedging (Adaptive) |
| :--- | :--- | :--- |
| **Stable Load** | Works well if tuned correctly, but requires manual retuning if the backend latency profile changes. | Self-tunes to track the target percentile, maintaining a constant, predictable hedge rate. |
| **Latency Spikes** (e.g., GC pause) | Mitigates the spike for requests exceeding the static threshold. | Adapts slowly (due to tracker inertia), allowing it to hedge spiked requests. |
| **Global Backend Slowdown** | Static threshold is permanently exceeded, causing the client to hedge almost 100% of requests, adding load when the backend is struggling. | Adapts by increasing the hedging delay to continue hedging only the new tail (worst 5%), keeping load stable. |

#### Trade-offs of Dynamic Hedging

*   **Complexity**: Requires configuring and tuning multiple parameters (percentile, adaptation rate, min/max delays, token bucket limits).
*   **Cold Start**: Starts with a default estimate and takes time (a stream of requests) to converge to the true percentile.
*   **State Interference**: Since the latency estimate is shared at the `Resource` level, running operations with vastly different latency profiles (e.g., a 10ms read vs. a 5s write) on the same resource will corrupt the shared estimate.

#### When to Use Static Hedging

*   **Short-Lived Clients**: CLI tools or serverless functions (e.g., Cloud Functions) that exit quickly do not live long enough to build a latency history.
*   **Strict SLAs**: If you have a hard constraint (e.g., "responses must arrive within 100ms"), a static hedge at 60ms is preferred to force attempts to meet the SLA, rather than adapting to a slower backend.
*   **Highly Predictable Latency**: If the backend has a fixed, guaranteed latency profile, static hedging avoids the overhead of dynamic tracking.
*   **Simplicity**: In low-traffic or non-critical systems, static hedging is easier to configure and reason about.

## Resource and Context Model

The library models your system's dependencies using three core concepts:

*   **`ResilienceContext`**: The **runtime state container**. It maintains the active state of your resilience patterns (e.g., circuit breaker status, rolling request history for throttling) for all resources. You should typically create a single, application-wide `ResilienceContext` to ensure metrics are accumulated globally.
*   **`Resource`**: A logical **target service** or dependency (e.g., `'database'` or `'auth-service'`). It defines the identity (name) and default policies (`ResourceConfig`) for that target. Runtime state is keyed by the resource name, meaning all operations targeting the same resource share its circuit breaker and throttling metrics.
*   **`Operation`**: A specific **action** performed on a resource (e.g., `'getUser'` or `'updateAvatar'`). Operations inherit their resource's configuration but can override settings (like enabling hedging for reads but disabling it for writes). Operations also define the `Criticality` of the call.

This separation ensures that health metrics are aggregated at the service level (Resource) while allowing fine-grained policy tuning at the call level (Operation).

## Usage



### Basic Setup

```dart
import 'package:circuit_breaker/circuit_breaker.dart';

void main() async {
  final context = ResilienceContext();

  // Define a resource with shared state
  final myService = Resource(
    'my-service',
    config: const ResourceConfig(
      circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 5),
      throttling: ThrottlingConfig(k: 2.0),
      timeout: Duration(seconds: 5),
    ),
  );

  // Define operations
  final readOp = Operation(
    'read',
    myService,
    hedgingOverride: const HedgingConfig(
      enabled: true,
      delay: Duration(milliseconds: 200),
    ),
  );
  
  final writeOp = Operation('write', myService);

  // Execute a simple operation
  try {
    final result = await context.execute(writeOp, () async {
      return await makeNetworkCall();
    });
    print(result);
  } catch (e) {
    print('Operation failed: $e');
  }

  // Execute a cancelable operation (required for hedging/timeouts)
  try {
    final result = await context.executeCancelable(readOp, (cancelSignal) async {
      final work = makeNetworkCall();
      return await Future.any([
        work,
        cancelSignal.future.then((_) => throw Exception('Cancelled')),
      ]);
    });
    print(result);
  } catch (e) {
    print('Operation failed: $e');
  }
}

Future<String> makeNetworkCall() async => 'data';
```

### Criticality-Aware Throttling

Operations can be configured with a `Criticality` level. Under overload, adaptive throttling will discard sheddable traffic first to protect critical path operations.

```dart
final backgroundSync = Operation(
  'sync', 
  myService, 
  criticality: Criticality.sheddable,
);

final userAction = Operation(
  'checkout', 
  myService, 
  criticality: Criticality.criticalPlus,
);
```

To enable this, `ThrottlingConfig` automatically spreads the sensitivity multiplier (`K`) across different criticality levels.

By default, `ThrottlingConfig(k: base, spread: 1.0)` calculates the effective `K` for each level as:
*   **`criticalPlus`**: `k * 4.0` (tolerant to failures, default `8.0`).
*   **`critical`** (default level): `k` (default `2.0`).
*   **`sheddablePlus`**: `max(k * 0.8, 1.1)` (default `1.6`).
*   **`sheddable`**: `max(k * 0.6, 1.1)` (default `1.2`).

A lower `K` makes throttling more aggressive. Under default settings, `sheddable` traffic starts throttling earlier (when failures exceed 16%), while `critical` traffic tolerates up to 50% failures, and `criticalPlus` is shielded from throttling.

You can adjust the width of this spread using the `spread` parameter (setting `spread: 0.0` collapses all levels to use the same base `k`).

For complete control, you can configure the values explicitly using a Dart Record:
```dart
final myService = Resource(
  'my-service',
  config: ResourceConfig(
    throttling: ThrottlingConfig.withCriticality(
      k: (
        criticalPlus: 10.0,
        critical: 2.0,
        sheddablePlus: 1.5,
        sheddable: 1.1,
      ),
    ),
  ),
);
```


### Dynamic Hedging Configuration

To enable dynamic hedging, configure `dynamicPercentile` (e.g., `0.95` for P95) in the `HedgingConfig`. The library will dynamically adjust the hedging delay based on runtime latency samples.

```dart
final myService = Resource(
  'my-service',
  config: ResourceConfig(
    hedging: HedgingConfig(
      enabled: true,
      dynamicPercentile: 0.95, // Track P95 latency
      delayMultiplier: 2.0,    // Hedge delay is 2 * P95
      minDelay: Duration(milliseconds: 10),
      maxDelay: Duration(seconds: 2),
      adaptationRate: 10.0,    // Speed of adaptation
      overloadPercentile: 0.95, // Refill rate for token bucket (max 5% hedged requests)
      maxOverloadTokens: 10.0,
      maxConcurrentHedges: 5,   // Concurrency limit per resource
    ),
  ),
);
```

### How Dynamic Hedging Works

Adaptive hedging dynamically adjusts the delay before starting a speculative hedge request, responding to changes in backend latency. It implements several advanced mechanisms to ensure stability, fast reaction times, and overload protection.

#### 1. Retrospective Hedging (Avoiding the Feedback Loop)
A naive adaptive hedging implementation might only measure the latency of *unhedged* requests (requests that complete before the hedging threshold). However, during a global backend slowdown, this suffers from **survival bias**: the client only measures the few requests that happened to complete quickly. The tracker would falsely conclude the backend is fast, lower the hedging delay, and trigger a runaway loop where 100% of traffic is hedged, DDOSing the backend.

To prevent this, the library implements **Retrospective Hedging**:
*   It tracks the **best of multiple attempts** (the minimum latency between the primary and the hedged request) for each logical call: `min(latency_primary, latency_hedge)`.
*   If the backend slows down globally, both attempts will be slow. The tracked latency increases, pushing the hedging delay up and reducing the rate of hedges.
*   Combined with the **Token Bucket** (see below), this mathematically guarantees that the feedback loop is broken and the system remains stable.

#### 2. Stochastic Percentile Tracking (Robbins-Monro Algorithm)
To avoid the CPU and memory overhead of storing a rolling window of hundreds of latency samples, the library uses a **stochastic approximation algorithm** (Robbins-Monro) to track the target percentile (e.g., P95) in `O(1)` space and time:
*   On every request, the current raw estimate `V` is updated based on whether the request's best latency was "slow" (exceeded `V`) or "fast" (was below `V`).
*   If slow, the estimate is increased: `V_new = V_old × (1 + P / R)`
*   If fast, the estimate is decreased: `V_new = V_old × (1 - (1 - P) / R)`
*   Where `P` is the target `dynamicPercentile` (e.g., `0.95`) and `R` is the `adaptationRate` (e.g., `10.0`). At the target percentile, the expected change is zero, causing the estimate to track the true percentile.

#### 3. Early Registration
During a sudden backend outage, waiting for requests to timeout or finish before updating the tracker would cause a slow reaction time.
*   To solve this, the library starts an **Early Registration Timer** set to the raw percentile estimate `V` when a request begins.
*   If the primary request exceeds `V`, it is immediately registered as a "slow" sample, adjusting the tracker upward *before* the request even completes or is hedged.
*   Only one sample is registered per logical request (subsequent completions of the primary or hedge are ignored by the tracker).

#### 4. Overload Protection
To protect the backend from being overwhelmed by speculative requests:
*   **Hedging Token Bucket**: A rate limiter that refills tokens at a rate of `1.0 - overloadPercentile` on every logical request. Starting a hedge consumes 1 token. If the bucket is empty, hedging is blocked. This limits the long-term overhead of hedging to at most `1 - overloadPercentile` (e.g., 5% of traffic).
*   **Concurrency Limit**: Caps the absolute number of concurrent active hedges (`maxConcurrentHedges`) per resource.
*   **Bypass in Half-Open**: Hedging is automatically disabled when the Circuit Breaker is in the `halfOpen` state, ensuring trial requests do not spawn speculative duplicates.

## Combining Patterns (Best Practices)

When combining Retry, Circuit Breaker, Hedging, and Adaptive Throttling, the order of execution and how they share state is critical to prevent them from conflicting.

### Execution Order

The library automatically coordinates and enforces these patterns in the following order (from outer wrapper to inner execution):

1.  **Circuit Breaker (First Gate)**: Fails fast immediately if the circuit is `open` (broken path, requests blocked). This protects the backend and prevents CPU/resource waste on the client.

2.  **Adaptive Throttling (Second Gate)**: Proactively drops requests probabilistically if the client detects the backend is overloaded.
    *   *Note: Throttling is bypassed for trial requests when the Circuit Breaker is in the `halfOpen` state to ensure the trial request can reach the backend to test its health.*
3.  **Overall Timeout**: Binds the entire operation's duration, including all retries and hedges.
4.  **Retry Loop**: Wraps the hedging logic. This treats the speculative hedged attempts as a single "logical attempt". If both the primary and hedge requests fail, the retry loop starts a new attempt.
5.  **Hedging**: Speculatively starts parallel attempts if the primary attempt is slow.
6.  **Per-Attempt Timeout**: Handled by your HTTP client to bound individual network connections.

```
Client Request
└── [Overall Timeout]
    └── [Circuit Breaker Check]
        └── [Adaptive Throttling] (bypassed if CB is Half-Open)
            └── [Retry Loop]
                └── [Hedging Loop]
                    └── [Per-Attempt Timeout (Client HTTP)]
                        └── Actual Call
```

### Why Retry Wraps Hedging (Not Vice Versa)

Wrapping Hedging with Retry ensures that we only retry if *both* the primary request and its hedge fail.
If Hedging wrapped Retry, starting a hedge would initiate a second parallel retry loop. During a backend slowdown, this would trigger exponential request multiplication, worsening the overload.

### How Metrics Interact

To maintain accurate health metrics:
*   **Throttling & CB** record results for *every actual attempt* (including retries and individual hedges) that completes. Cancelled hedges are ignored.
*   **Retry Budget** only counts *logical retries* initiated by the Retry loop. Speculative hedge attempts do not consume the retry budget.
*   **CB-Blocked Requests** do not record failures in Throttling, ensuring that local fast-fails do not pollute throttling metrics.

### Configuration Rules of Thumb

*   **Circuit Breaker `consecutiveFailuresThreshold`** must be set to **at least `maxAttempts + 2`** (e.g., if max retry attempts is 3, set CB threshold to 5). Otherwise, a single request exhausting its retries will trip the circuit breaker for all other traffic.
*   **Hedging Delay**:
    *   For **Static Hedging**, set `delay` to the **P90 or P95 latency** of the target service under normal load. This ensures you only duplicate the slowest 10% or 5% of requests.
    *   For **Dynamic Hedging**, set `dynamicPercentile` to `0.90` or `0.95` and the library will track this latency automatically. Use `delayMultiplier` (default `2.0`) to apply a safety margin before sending the hedge.
    *   Use `overloadPercentile` (default `0.95`) to prevent hedging from exceeding a safe fraction of total traffic (e.g., 5% of requests) under sustained backend slowness.
*   **Adaptive Throttling `k` & `spread`**:
    *   **`k`** (base multiplier) should default to **`2.0`** (which sets the sensitivity for the default `critical` traffic, allowing up to 50% failures).
    *   **`spread`** (default **`1.0`**) controls how aggressively sheddable traffic is dropped relative to critical traffic. Adjusting `spread` to `0.0` disables priority-based throttling, treating all traffic equally.

## References

*   **Google SRE Book - Handling Overload**: [Chapter 21](https://sre.google/sre-book/handling-overload)
*   **Google SRE Book - Addressing Cascading Failures**: [Chapter 22](https://sre.google/sre-book/addressing-cascading-failures)
*   **The Tail at Scale**: [Dean & Barroso](https://cacm.acm.org/magazines/2013/2/160173-the-tail-at-scale/fulltext)
*   **Circuit Breaker Pattern**: [Martin Fowler](https://martinfowler.com/bliki/CircuitBreaker.html)
