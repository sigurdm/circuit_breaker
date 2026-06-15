# Interactive Resilience Simulator

An interactive terminal dashboard to visualize and experiment with client-side resilience patterns under backend overload, slowness, and failures.

The simulator demonstrates the following patterns:
*   **Retry**: Retrying failed requests with backoff.
*   **Circuit Breaker**: Failing fast when the service is down to prevent resource exhaustion.
*   **Hedging**: Sending duplicate requests to reduce tail latency.
*   **Adaptive Throttling**: Client-side load shedding based on backend rejection probability, with traffic isolation by criticality.

## How to Run

To run the simulator, execute the following command in your terminal:

```bash
dart run example/simulator.dart
```

Ensure your terminal window is large enough to display the full dashboard (at least 80x40 is recommended).

## Dashboard Layout

The dashboard is divided into several sections, updated in real-time:

### 1. TRAFFIC METRICS (cumulative & rolling rates)
Displays the request counts and rates (per second) categorized by Criticality (`critPlus`, `critical`, `shedPlus`, `sheddable`).
*   **Requests**: Total requests initiated by the client.
*   **Success**: Successfully completed requests.
*   **Failure**: Requests that failed with a backend error (excluding timeouts and throttled/blocked requests).
*   **Timeout**: Requests that exceeded the overall timeout.
*   **Throttled**: Requests shed by the client-side adaptive throttling.
*   **Blocked (CB)**: Requests blocked by the Circuit Breaker because it is in the `OPEN` state.
*   **Hedges**: Number of hedged (duplicate) requests sent.
*   **Retries**: Number of retry attempts.

Values are formatted as `rolling_rate/s (cumulative_count)`. Rolling rates are calculated over a 5-second window.

### 2. THROTTLING STATES (last 10s)
Shows the state of the adaptive throttling mechanism for each criticality level:
*   **Window Requests**: Number of requests in the 10-second throttling window.
*   **Window Accepts**: Number of accepted requests by the backend in the window.
*   **Rejection Prob**: The probability that a request of this criticality will be throttled (shed) client-side. Higher criticality requests have a higher threshold and are protected longer.

### 3. SHARED MECHANISM STATES
*   **Circuit Breaker**: Displays the current state (`CLOSED` in green, `OPEN` in red, `HALF-OPEN` in yellow), consecutive failure count, threshold, and recovery countdown when `OPEN`.
*   **Retry Budget**: Displays client-side retry budget statistics: total requests, retries, current retry ratio, and the configured budget limit (e.g., 10%).

### 4. VISUAL TRENDS (last 20s)
Sparklines showing the trends over the last 20 seconds:
*   **Success Rate**: Percentage of successful requests over total outcomes.
*   **Shedding Prob**: The rejection probability for the lowest criticality (`sheddable`) traffic.

### 5. CONFIGURATIONS & HOTKEYS
Shows the current backend status and resilience configuration, along with the hotkeys to adjust them:
*   **Backend**:
    *   `Base Lat`: Base latency of the backend.
    *   `Base Fail`: Base failure rate of the backend.
    *   `Cap`: Backend capacity limit in RPS.
    *   `RPS`: Current actual RPS sent to the backend.
    *   `Load`: Load factor (`RPS / Capacity`). If > 100%, backend enters overload, causing latency and failure rate to rise.
    *   `Lat / Fail`: Effective latency and failure rate (including overload penalty).
*   **Resilience**:
    *   `CB Thresh / Reset`: Circuit breaker consecutive failures threshold and reset timeout.
    *   `Budget`: Retry budget status (`ON` with limit, or `OFF`).
    *   `Base K`: Adaptive throttling multiplier. Shows derived K values for each criticality.
    *   `Hedge`: Hedging delay or dynamic status.
    *   `Timeout`: Overall request timeout.

### 6. LIVE EVENT LOG (last 5)
A scrolling log of the 5 most recent significant events (e.g., Throttled, Circuit Breaker tripped, Hedged, Retry, Timeout).

---

## Interactive Controls (Hotkeys Reference)

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

---

## Scenarios Playbook

Use these playbooks to observe how the resilience mechanisms protect the system.

### 1. Traffic Spike (Protecting the Backend)
Simulates a sudden surge in traffic to test client-side load shedding (adaptive throttling).

1.  Observe the dashboard under normal conditions. Success rate should be near 100%, and Shedding Prob sparkline should be flat at 0%.
2.  Press `s` to trigger a **Traffic Spike**.
3.  **Observe**:
    *   The Requests rate spikes.
    *   The backend RPS rises, exceeding the `Cap` (Capacity).
    *   The Load factor goes well above 100%.
    *   **Client-side load shedding kicks in**: The Rejection Prob for `sheddable` and `sheddablePlus` traffic rises quickly.
    *   Look at the TRAFFIC METRICS: `sheddable` traffic shows high Throttled rates.
    *   **Traffic Isolation**: `critical` and `criticalPlus` traffic remains largely unthrottled (lower rejection probability) and successful, protecting critical user flows.
4.  After 5 seconds, the scenario ends. Observe the rejection probabilities decay back to 0% and the success rate recover.

### 2. Latency Brownout & Hedging
Simulates a slow backend to observe how hedging hides latency spikes.

1.  Ensure hedging is `ON` (Toggle shows a delay or `DYNAMIC`, not `OFF`). The default timeout is 500ms.
2.  Press `o` to trigger a **Latency Brownout**.
3.  **Observe**:
    *   The backend latency gradually rises up to 1000ms.
    *   As latency exceeds the hedging delay (default 100ms), `Hedges` count/rate begins to rise.
    *   Even though backend latency is high, the overall Success Rate remains high because the hedged attempts (sent early) complete before the 500ms timeout.
4.  Press `h` to **disable hedging**.
5.  **Observe**:
    *   `Hedges` drop to 0.
    *   Timeout rate spikes because requests now wait for the slow backend and exceed the 500ms timeout.
    *   Overall Success Rate drops significantly.
6.  Press `h` again to enable hedging, or press `H` to enable **Dynamic Hedging**.
    *   With Dynamic Hedging, the simulator estimates the P95 latency and adjusts the hedging delay automatically (shows `DYNAMIC (P95: ... -> Target: ...)`).
7.  Observe the recovery as the scenario ends and latency returns to normal.

### 3. Service Breakdown & Circuit Breaker
Simulates a complete backend outage to observe fail-fast behavior.

1.  Press `b` to trigger a **Service Breakdown**. This forces a 100% failure rate for 5 seconds.
2.  **Observe**:
    *   Requests begin to fail. Failure rate rises.
    *   The Circuit Breaker consecutive failure count increases rapidly.
    *   Once it hits the threshold (default 5), the Circuit Breaker transitions to `OPEN` (red).
    *   **Fail-Fast**: Immediately, TRAFFIC METRICS shows requests being `Blocked (CB)`. The backend RPS drops to 0 because the client stops sending requests to the broken backend.
    *   This protects the client from wasting resources and prevents overloading the backend.
3.  After 5 seconds, the breakdown ends (backend recovers), but the CB remains `OPEN`.
4.  Wait for the reset timeout (default 5s). The CB transitions to `HALF-OPEN` (yellow).
5.  **Observe**:
    *   A trial request is sent. It bypasses adaptive throttling.
    *   Since the backend has recovered, the trial request succeeds.
    *   The CB transitions back to `CLOSED` (green), and normal traffic resumes.

### 4. Retry Storm (Budget Protection)
Demonstrates how a retry budget prevents clients from overloading a failing backend.

1.  First, turn the **Retry Budget OFF** by pressing `r` (shows `Budget: OFF`).
2.  Trigger failures by pressing `b` (Breakdown) or `v` (Oscillating Failures).
3.  **Observe**:
    *   As requests fail, the client retries them.
    *   Since budget is `OFF`, the client retries every failed request up to 3 times (max attempts).
    *   Look at the TRAFFIC METRICS: The Backend Attempts rate is up to 3x the Requests rate. This is a Retry Storm, which can keep a struggling backend down.
4.  Now, press `r` to turn the **Retry Budget ON** (shows `Budget: ON (10%)`).
5.  With failures still occurring (or trigger another breakdown with `b`):
6.  **Observe**:
    *   The Backend Attempts rate is now controlled. It is capped at roughly Requests + 10% (the budget ratio).
    *   Look at SHARED MECHANISM STATES: The Retry Budget Ratio will be pinned at the 10.0% limit.
    *   Many failed requests are not retried because the budget is exhausted, protecting the backend from overload.
