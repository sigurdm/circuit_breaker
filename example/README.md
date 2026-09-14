# Examples & Interactive Simulator

This folder contains practical code examples showing how to use `package:circuit_breaker` in client (Flutter) applications and server-side distributed RPC architectures, as well as the interactive terminal resilience simulator.

---

## 1. Flutter & Client Application Examples

Client applications have low QPS and need fast, deterministic feedback to conserve device battery and avoid UI hangs.

### Repository Pattern with Circuit Breaker & Exponential Backoff
This pattern protects the client from repeated network calls when an API is down, failing fast to display offline UI.

```dart
import 'package:circuit_breaker/circuit_breaker.dart';

class UserProfileRepository {
  final _policy = ResiliencePolicy(
    circuitBreaker: CircuitBreakerConfig(
      consecutiveFailuresThreshold: 3,
      resetTimeout: const Duration(seconds: 15),
    ),
    retry: RetryConfig(
      maxAttempts: 3,
      baseDelay: const Duration(milliseconds: 200),
      maxDelay: const Duration(seconds: 2),
      enableJitter: true, // Prevents synchronized client retry bursts
    ),
    timeout: const Duration(seconds: 5),
  );

  Future<UserProfile> fetchProfile(String userId) async {
    try {
      return await _policy.execute(() => apiClient.getUserProfile(userId));
    } on CircuitBreakerOpenException {
      // Circuit is open: fail fast and show cached offline data immediately
      return cache.getUserProfile(userId);
    }
  }
}
```

### Search Autocomplete with Static Hedging & Cancellation
For search-as-you-type, speculative hedging dispatches a duplicate request if the primary takes longer than a fixed threshold (e.g. 150ms). When the user types another letter, the previous request is cancelled via `CancellationToken`.

```dart
import 'package:circuit_breaker/circuit_breaker.dart';

class SearchService {
  final _policy = ResiliencePolicy(
    hedging: HedgingConfig(
      enabled: true,
      delay: const Duration(milliseconds: 150), // Static delay for client
    ),
    timeout: const Duration(seconds: 2),
  );

  CancellationToken? _activeSearchToken;

  Future<List<String>> onQueryChanged(String query) async {
    // Cancel any previous in-flight search request
    _activeSearchToken?.cancel();
    _activeSearchToken = CancellationToken();

    final token = _activeSearchToken!;
    return await ResilienceContext.runWithCancellationToken(
      token,
      () => _policy.executeCancelable((cancelCompleter) async {
        return await apiClient.queryAutocomplete(query, cancelToken: token);
      }),
    );
  }
}
```

---

## 2. Server-to-Server Distributed RPC Examples

Backend services and API gateways handle continuous traffic (high QPS) and coordinate multiple downstream microservices.

### Microservice Topology with Hierarchical Resources & Throttling
See `example/main.dart` for a complete runnable end-to-end example.

```dart
import 'package:circuit_breaker/circuit_breaker.dart';

void main() async {
  final context = ResilienceContext();

  // 1. Shared Database Cluster (Parent Resource)
  final dbCluster = Resource(
    'db-cluster',
    circuitBreaker: CircuitBreakerConfig(
      consecutiveFailuresThreshold: 10,
      resetTimeout: const Duration(seconds: 10),
    ),
  );

  // 2. Child Service Resource (Inherits parent health, adds adaptive throttling)
  final orderService = context.resource(
    'order-service',
    parent: dbCluster,
    throttling: ThrottlingConfig(
      k: 2.0, // Google SRE adaptive throttling
      windowDuration: const Duration(minutes: 2),
    ),
    retry: RetryConfig(
      maxAttempts: 3,
      retryBudgetRatio: 0.1, // Max 10% retries to avoid retry storms
    ),
  );

  // 3. Define operations with criticality tiers
  final checkoutOp = orderService.operation(
    'checkout',
    criticality: Criticality.criticalPlus, // Protected from shedding
  );

  final syncOp = orderService.operation(
    'exportMetrics',
    criticality: Criticality.sheddable, // Shed first under backend load
  );

  // Execute operations
  final orderId = await context.execute(checkoutOp, () => db.insertOrder());
}
```

### End-to-End Deadline Propagation in HTTP Middleware
Propagate incoming server deadlines across downstream RPCs to prevent zombie requests:

```dart
import 'package:circuit_breaker/circuit_breaker.dart';

Future<void> handleHttpRequest(Request request) async {
  final header = request.headers['X-Server-Deadline'];
  final deadline = header != null ? DateTime.parse(header) : DateTime.now().add(const Duration(seconds: 3));
  final clientToken = CancellationToken();

  await ResilienceContext.runWithDeadline(deadline, () {
    return ResilienceContext.runWithCancellationToken(clientToken, () async {
      // Downstream operations automatically inherit deadline & cancellation
      final user = await userService.execute(() => fetchUser());
      final orders = await orderService.execute(() => fetchOrders(user.id));
    });
  });
}
```

---

## 3. Zero-Boilerplate Ad-Hoc Usage

For lightweight scripts, CLI tools, or one-off operations:

```dart
import 'package:circuit_breaker/circuit_breaker.dart';

// One-liner retry with exponential backoff and jitter
final data = await retry(
  () => httpGet('https://api.example.com/data'),
  maxAttempts: 3,
  timeout: const Duration(seconds: 5),
);

// One-liner speculative hedge for idempotent reads
final result = await hedge(
  () => readReplica(),
  delay: const Duration(milliseconds: 100),
);
```

---

## 4. Interactive Terminal Resilience Simulator

The repository includes an interactive terminal dashboard to visualize and experiment with these resilience patterns under backend overload, slowness, and failures in real-time.

```bash
dart run example/simulator.dart
```

Ensure your terminal window is at least 80x40 to display the full dashboard.

### Simulator Dashboard Sections
- **TRAFFIC METRICS**: Live request rates and cumulative counts segmented by Criticality (`critPlus`, `critical`, `shedPlus`, `sheddable`).
- **THROTTLING STATES**: Rolling 10s window counts, accepted requests, and dynamic rejection probability $P_{\text{reject}}$.
- **SHARED MECHANISM STATES**: Circuit Breaker state (`CLOSED`, `OPEN`, `HALF-OPEN`) and Retry Budget ratio vs limit.
- **VISUAL TRENDS**: 20-second sparklines of overall success rate and sheddable rejection probability.
- **CONFIGURATIONS & HOTKEYS**: Live parameters for backend latency, failure rate, and resilience limits.
- **LIVE EVENT LOG**: Scrolling log of significant events (circuit breaker state transitions, throttling rejections, hedges, retries).

### Interactive Hotkeys Reference

| Hotkey | Action |
| :--- | :--- |
| `f` / `F` | Increase / Decrease backend base failure rate by 10% |
| `l` / `L` | Increase / Decrease backend base latency by 50ms |
| `b` | Trigger a 5-second backend Service Breakdown (100% failure rate) |
| `p` / `P` | Increase / Decrease backend capacity by 10 RPS |
| `c` / `C` | Increase / Decrease Circuit Breaker consecutive failures threshold |
| `k` / `K` | Increase / Decrease Adaptive Throttling base multiplier K |
| `r` | Toggle Retry Budget `ON` (10% limit) / `OFF` (unlimited retries) |
| `g` / `G` | Increase / Decrease static hedging delay by 50ms |
| `h` | Toggle Hedging `ON` / `OFF` |
| `H` | Toggle Dynamic Hedging `ON` (uses P95 latency estimate) / `OFF` |
| `t` / `T` | Increase / Decrease overall request timeout by 50ms |
| **Scenarios** | |
| `s` | Trigger **Traffic Spike** scenario (5s) |
| `o` | Trigger **Latency Brownout** scenario (15s) |
| `v` | Trigger **Oscillating Failures** scenario (15s) |
| **Global** | |
| `q` | Quit the simulator |

### Scenarios Playbook

#### 1. Traffic Spike (Adaptive Throttling & Criticality)
Press `s` to trigger a sudden 5-second traffic surge:
- Observe RPS exceed backend capacity and load factor rise above 100%.
- Client-side adaptive throttling kicks in: rejection probability for `sheddable` traffic rises first.
- High-priority traffic (`criticalPlus` and `critical`) remains largely unthrottled and succeeds, demonstrating traffic isolation.

#### 2. Latency Brownout & Hedging
Press `o` to simulate backend latency degradation up to 1000ms:
- When static hedging is `ON` (`h`), speculative duplicate requests complete before the timeout, preserving high success rates.
- Toggle hedging `OFF` (`h`) and observe request timeouts spike and success rates collapse.
- Toggle dynamic hedging `ON` (`H`) to observe Robbins-Monro tracking the P95 latency shift automatically.

#### 3. Service Breakdown & Circuit Breaker
Press `b` to force a 100% backend failure rate for 5 seconds:
- Consecutive failures trip the Circuit Breaker to `OPEN`.
- Requests fail fast locally (`Blocked (CB)`), immediately cutting network traffic to 0 to give the backend breathing room.
- After the reset timeout, the breaker transitions to `HALF-OPEN`, sending a trial request to verify recovery before closing.

#### 4. Retry Storm (Retry Budget)
Press `r` to toggle the Retry Budget `OFF`, then trigger failures with `b`:
- The client retries every failed request, generating up to $3\times$ QPS backend attempts (retry storm).
- Turn the Retry Budget `ON` (`r`): retries are capped at 10% of total requests, protecting the failing service.
