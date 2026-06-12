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

$$P_{\text{throttle}} = \max\left(0, \frac{\text{requests} - K \times \text{accepts}}{\text{requests} + 1}\right)$$

Where $K$ is the acceptance multiplier (e.g., `2.0`). If $K = 2$, the client will allow at most twice as many requests as the backend is successfully accepting. Excess requests are rejected locally with a `ThrottledException`.

### Circuit Breaking (Failing Fast)

Avoids wasting resources on a dependency that is down. The circuit breaker transitions through three states:
*   **Closed**: Requests are allowed.
*   **Open**: Requests fail immediately with `CircuitBreakerOpenException`.
*   **Half-Open**: Allows a single trial request after `resetTimeout` to check if the service has recovered.

### Request Hedging (Tail Latency Mitigation)

Speculatively sends a second, parallel request if the first request does not complete within a configured delay. 
If a service has a 5% chance of taking >1s, hedging after 1s reduces the probability of both requests taking >1s to $0.05 \times 0.05 = 0.25\%$, significantly reducing tail latency at the cost of at most 5% extra traffic.

> [!IMPORTANT]
> Only use hedging for **idempotent** operations (like reads) as it causes operations to be executed multiple times.

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
      circuitBreaker: CircuitBreakerConfig(failureThreshold: 5),
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

## References

*   **Google SRE Book - Handling Overload**: [Chapter 21](https://sre.google/sre-book/handling-overload)
*   **Google SRE Book - Addressing Cascading Failures**: [Chapter 22](https://sre.google/sre-book/addressing-cascading-failures)
*   **The Tail at Scale**: [Dean & Barroso](https://cacm.acm.org/magazines/2013/2/160173-the-tail-at-scale/fulltext)
*   **Circuit Breaker Pattern**: [Martin Fowler](https://martinfowler.com/bliki/CircuitBreaker.html)
