# Circuit Breaker & Resilience Patterns for Dart

A robust, zero-dependency resilience library for Dart applications, implementing advanced patterns for distributed systems as described in the Google SRE book and other literature.

## Features

-   **Circuit Breaking**: Protects your application from failing dependencies by failing fast when error thresholds are exceeded.
-   **Advanced Retries**: Exponential backoff, full jitter, and **Retry Budgets** to prevent retry storms.
-   **Request Hedging**: Reduces tail latency by speculatively issuing parallel requests.
-   **Adaptive Throttling**: Client-side throttling using the technique described in the [Google SRE book](https://sre.google/sre-book/handling-overload) to protect backends from overload.
-   **Hierarchical Configuration**: Share state across resources while overriding settings for specific operations.
-   **Criticality Awareness**: Prioritize traffic and throttle less critical requests first.

## Circuit Breaking and Throttling

In a distributed system, failures are inevitable. Without protection, these failures can cascade and bring down your entire system.

### The Danger of Retries (Retry Storms)

Suppose a backend service has a capacity of $C$ requests per second. If it becomes overloaded and starts failing requests, clients will typically retry. If every client retries $3$ times, the load on the backend suddenly becomes $4C$. This "retry storm" ensures the backend can never recover.

**Adaptive Throttling** solves this by capping the probability of sending a request based on the recent success rate:

$$P_{throttle} = \max\left(0, \frac{\text{requests} - K \times \text{accepts}}{\text{requests} + 1}\right)$$

Where $K$ is the acceptance multiplier (e.g., $2.0$). This ensures that the client will never send more than roughly $K$ times the amount of requests the backend can actually handle.

#### 2. Circuit Breaking: Failing Fast

If a service is down, waiting for a timeout on every request wastes client resources (threads, memory) and provides a terrible user experience.

A **Circuit Breaker** acts as a state machine:
-   **Closed**: Requests pass through.
-   **Open**: Requests fail immediately.
-   **Half-Open**: Allows a single trial request to see if the service has recovered.

### Improving Tail Latency with Hedging

Tail latency (e.g., P99 or P99.9) is often dominated by a small fraction of requests that take an unusually long time due to garbage collection, network blips, or resource contention.

**Request Hedging** mitigates this by sending a second, identical request if the first one takes too long.

#### Obtaining better tail latencies with hedging

Suppose a service has a latency distribution where $5\%$ of requests take longer than $1$ second (P95 = 1s).
If we wait $1$ second and then send a *hedged* request, the probability that *both* requests take longer than $1$ second (assuming independence) is:

$$P(\text{Both Slow}) = P(\text{Request 1 Slow}) \times P(\text{Request 2 Slow}) = 0.05 \times 0.05 = 0.0025$$

By duplicating at most $5\%$ of requests, we turn the P95 latency into the P99.75 latency!

> [!IMPORTANT]
> Only use hedging for **idempotent** operations (like reads) as it causes operations to be executed multiple times.

## Usage

### Basic Setup

```dart
import 'package:circuit_breaker/circuit_breaker.dart';

void main() async {
  final context = RetryContext();

  // Define a resource with shared state
  final myService = Resource('my-service', config: ResourceConfig(
    circuitBreaker: CircuitBreakerConfig(failureThreshold: 5),
    throttling: ThrottlingConfig(k: 2.0),
  ));

  // Define operations
  final readOp = Operation('read', myService, hedgingOverride: HedgingConfig(enabled: true, delay: Duration(milliseconds: 200)));
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

  // Execute an operation that supports cancellation (e.g., for hedging)
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
```

### Using Criticality

You can tag operations with criticality to ensure that less important traffic is throttled first during an overload.

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

## Further Resources

-   **Google SRE Book - Handling Overload**: [https://sre.google/sre-book/handling-overload](https://sre.google/sre-book/handling-overload)
-   **Google SRE Book - Addressing Cascading Failures**: [https://sre.google/sre-book/addressing-cascading-failures](https://sre.google/sre-book/addressing-cascading-failures)
-   **The Tail at Scale** (Jeff Dean and Luiz André Barroso): [https://cacm.acm.org/magazines/2013/2/160173-the-tail-at-scale/fulltext](https://cacm.acm.org/magazines/2013/2/160173-the-tail-at-scale/fulltext)
-   **Circuit Breaker Pattern** (Martin Fowler): [https://martinfowler.com/bliki/CircuitBreaker.html](https://martinfowler.com/bliki/CircuitBreaker.html)
-   **Circuit Breaker Pattern** (Microsoft Azure Architecture Center): [https://learn.microsoft.com/en-us/azure/architecture/patterns/circuit-breaker](https://learn.microsoft.com/en-us/azure/architecture/patterns/circuit-breaker)
