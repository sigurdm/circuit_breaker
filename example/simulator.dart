import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:circuit_breaker/circuit_breaker.dart';

// --- State ---

enum Scenario { none, trafficSpike, latencyBrownout, oscillatingFailures }

final class SimulatorState {
  double failureRate = 0.0;
  Duration latency = const Duration(milliseconds: 50);

  // Backend Capacity Config
  double backendCapacity = 100.0;
  double currentBackendRps = 0.0;

  double get loadFactor =>
      backendCapacity > 0 ? currentBackendRps / backendCapacity : 0.0;

  Duration get effectiveLatency {
    if (loadFactor <= 1.0) return latency;
    final multiplier = 1.0 + (loadFactor - 1.0) * 2.0;
    return Duration(
      milliseconds: (latency.inMilliseconds * multiplier).round(),
    );
  }

  double get effectiveFailureRate {
    if (loadFactor <= 1.0) return failureRate;
    return (failureRate + (loadFactor - 1.0) * 0.5).clamp(0.0, 1.0);
  }

  // Resilience Config
  int cbConsecutiveFailuresThreshold = 5;
  Duration cbResetTimeout = const Duration(seconds: 5);
  double throttlingK = 2.0;
  int retryMaxAttempts = 3;
  Duration retryBaseDelay = const Duration(milliseconds: 100);
  bool hedgingEnabled = true;
  Duration hedgingDelay = const Duration(milliseconds: 100);
  double? hedgingDynamicPercentile;
  Duration overallTimeout = const Duration(milliseconds: 500);
  bool retryBudgetEnabled = true;

  String lastStatusMessage = 'Simulator started.';
  bool configChanged = false;

  Timer? breakdownTimer;
  double? savedFailureRate;
  bool isBreakdownActive = false;

  // Scenario State
  String activeScenarioName = 'None';
  int scenarioTicksRemaining = 0;
  Scenario activeScenario = Scenario.none;
  Duration? scenarioSavedLatency;
  double? scenarioSavedFailureRate;
  int scenarioTicksElapsed = 0;

  // History for sparklines
  final List<double> successRateHistory = <double>[];
  final List<double> sheddingProbHistory = <double>[];

  final List<LogEvent> eventLog = [];
  CircuitState? lastObservedCBState;
}

final state = SimulatorState();

// --- Stats Tracking ---

enum EventType {
  requestStarted,
  requestSuccess,
  requestFailure,
  requestTimeout,
  requestThrottled,
  requestBlockedCB,
  hedgeTriggered,
  retryTriggered,
  backendAttempt,
}

final class MetricEvent {
  final DateTime timestamp;
  final Criticality criticality;
  final EventType type;
  MetricEvent(this.timestamp, this.criticality, this.type);
}

final class LogEvent {
  final DateTime timestamp;
  final String message;
  LogEvent(this.timestamp, this.message);
}

String _formatTimestamp(DateTime dt) {
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  final ss = dt.second.toString().padLeft(2, '0');
  final ms = (dt.millisecond / 100).floor().toString();
  return '$hh:$mm:$ss.$ms';
}

final class StatsTracker {
  final List<MetricEvent> _events = [];
  final Duration windowDuration;

  // Cumulative stats since startup
  final Map<Criticality, Stats> _cumulativeStats = {
    Criticality.criticalPlus: Stats(),
    Criticality.critical: Stats(),
    Criticality.sheddablePlus: Stats(),
    Criticality.sheddable: Stats(),
  };

  StatsTracker({this.windowDuration = const Duration(seconds: 5)});

  void record(Criticality criticality, EventType type) {
    _events.add(MetricEvent(DateTime.now(), criticality, type));

    final cStats = _cumulativeStats[criticality]!;
    switch (type) {
      case EventType.requestStarted:
        cStats.total++;
      case EventType.requestSuccess:
        cStats.success++;
      case EventType.requestFailure:
        cStats.failure++;
      case EventType.requestTimeout:
        cStats.timeout++;
      case EventType.requestThrottled:
        cStats.throttled++;
      case EventType.requestBlockedCB:
        cStats.blockedCB++;
      case EventType.hedgeTriggered:
        cStats.hedges++;
      case EventType.retryTriggered:
        cStats.retries++;
      case EventType.backendAttempt:
        cStats.backendAttempts++;
    }
  }

  void _purgeOldEvents() {
    final cutoff = DateTime.now().subtract(windowDuration);
    _events.removeWhere((e) => e.timestamp.isBefore(cutoff));
  }

  Stats getRollingStats(Criticality criticality) {
    _purgeOldEvents();
    final stats = Stats();
    for (final e in _events.where((e) => e.criticality == criticality)) {
      switch (e.type) {
        case EventType.requestStarted:
          stats.total++;
        case EventType.requestSuccess:
          stats.success++;
        case EventType.requestFailure:
          stats.failure++;
        case EventType.requestTimeout:
          stats.timeout++;
        case EventType.requestThrottled:
          stats.throttled++;
        case EventType.requestBlockedCB:
          stats.blockedCB++;
        case EventType.hedgeTriggered:
          stats.hedges++;
        case EventType.retryTriggered:
          stats.retries++;
        case EventType.backendAttempt:
          stats.backendAttempts++;
      }
    }
    return stats;
  }

  Stats getCumulativeStats(Criticality criticality) {
    return _cumulativeStats[criticality]!;
  }
}

final class Stats {
  int total = 0;
  int success = 0;
  int failure = 0;
  int timeout = 0;
  int throttled = 0;
  int blockedCB = 0;
  int hedges = 0;
  int retries = 0;
  int backendAttempts = 0;
}

// Globals removed. Used SimulatorState instead.

String renderSparkline(List<double> values) {
  const chars = [' ', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
  final renderValues = List<double>.filled(40, 0.0);
  if (values.length >= 40) {
    renderValues.setRange(0, 40, values.sublist(values.length - 40));
  } else {
    renderValues.setRange(40 - values.length, 40, values);
  }

  final buf = StringBuffer();
  for (final val in renderValues) {
    final idx = (val * (chars.length - 1)).round().clamp(0, chars.length - 1);
    buf.write(chars[idx]);
  }
  return buf.toString();
}

void logEvent(String message) {
  state.eventLog.add(LogEvent(DateTime.now(), message));
  if (state.eventLog.length > 5) {
    state.eventLog.removeAt(0);
  }
}

void progressScenario() {
  if (state.activeScenario == Scenario.none) return;

  state.scenarioTicksElapsed++;
  state.scenarioTicksRemaining--;

  if (state.scenarioTicksRemaining < 0) {
    stopScenario();
    return;
  }

  switch (state.activeScenario) {
    case Scenario.trafficSpike:
      break;
    case Scenario.latencyBrownout:
      final base = state.scenarioSavedLatency!.inMilliseconds.toDouble();
      final target = 1000.0;
      double current = base;
      if (state.scenarioTicksElapsed <= 100) {
        final t = state.scenarioTicksElapsed / 100.0;
        current = base + (target - base) * t;
      } else if (state.scenarioTicksElapsed <= 200) {
        current = target;
      } else {
        final t = (state.scenarioTicksElapsed - 200) / 100.0;
        current = target - (target - base) * t;
      }
      state.latency = Duration(milliseconds: current.round());
      break;
    case Scenario.oscillatingFailures:
      final elapsed = state.scenarioTicksElapsed;
      final period = 100.0;
      state.failureRate = 0.5 - 0.5 * cos(2 * pi * elapsed / period);
      break;
    default:
      break;
  }
}

void startScenario(Scenario scenario) {
  if (state.activeScenario != Scenario.none) {
    stopScenario();
  }

  if (state.isBreakdownActive) {
    state.breakdownTimer?.cancel();
    state.failureRate = state.savedFailureRate ?? 0.0;
    state.isBreakdownActive = false;
    state.savedFailureRate = null;
    state.breakdownTimer = null;
  }

  state.activeScenario = scenario;
  state.scenarioTicksElapsed = 0;

  switch (scenario) {
    case Scenario.trafficSpike:
      state.activeScenarioName = 'Traffic Spike';
      state.scenarioTicksRemaining = 100;
      break;
    case Scenario.latencyBrownout:
      state.activeScenarioName = 'Latency Brownout';
      state.scenarioTicksRemaining = 300;
      state.scenarioSavedLatency = state.latency;
      break;
    case Scenario.oscillatingFailures:
      state.activeScenarioName = 'Oscillating Failures';
      state.scenarioTicksRemaining = 300;
      state.scenarioSavedFailureRate = state.failureRate;
      break;
    default:
      break;
  }
  setStatus('Started scenario: ${state.activeScenarioName}');
}

void stopScenario() {
  final oldScenario = state.activeScenario;
  state.activeScenario = Scenario.none;
  state.activeScenarioName = 'None';
  state.scenarioTicksRemaining = 0;

  switch (oldScenario) {
    case Scenario.latencyBrownout:
      if (state.scenarioSavedLatency != null) {
        state.latency = state.scenarioSavedLatency!;
      }
      break;
    case Scenario.oscillatingFailures:
      if (state.scenarioSavedFailureRate != null) {
        state.failureRate = state.scenarioSavedFailureRate!;
      }
      break;
    default:
      break;
  }
  state.scenarioSavedLatency = null;
  state.scenarioSavedFailureRate = null;
  setStatus('Scenario finished');
}

final class RequestTracker {
  final Criticality criticality;
  final StatsTracker statsTracker;
  int totalAttempts = 0;
  int activeAttempts = 0;

  RequestTracker(this.criticality, this.statsTracker);

  void startAttempt() {
    if (activeAttempts > 0) {
      statsTracker.record(criticality, EventType.hedgeTriggered);
      logEvent('[Hedge] Triggered');
    } else if (totalAttempts > 0) {
      statsTracker.record(criticality, EventType.retryTriggered);
      logEvent('[Retry] Attempt ${totalAttempts + 1}');
    }
    totalAttempts++;
    activeAttempts++;
  }

  void endAttempt() {
    activeAttempts--;
  }
}

// --- Mock Backend ---

Future<void> waitWithCancellation(
  Duration duration,
  Completer<void> cancelSignal,
) async {
  if (cancelSignal.isCompleted) return;

  final completer = Completer<void>();
  final timer = Timer(duration, () {
    if (!completer.isCompleted) completer.complete();
  });

  unawaited(
    cancelSignal.future.then((_) {
      timer.cancel();
      if (!completer.isCompleted) completer.complete();
    }),
  );

  await completer.future;
}

double _nextGaussian() {
  final random = Random();
  double u1 = 0;
  double u2 = 0;
  while (u1 == 0) {
    u1 = random.nextDouble();
  }
  u2 = random.nextDouble();
  return sqrt(-2.0 * log(u1)) * cos(2.0 * pi * u2);
}

double _nextGaussianLatency(double mean) {
  final stdDev = mean * 0.2;
  final z0 = _nextGaussian();
  return max(0.0, mean + z0 * stdDev);
}

Future<String> mockBackend(Completer<void> cancelSignal) async {
  final mean = state.effectiveLatency.inMilliseconds.toDouble();
  final latencyMs = _nextGaussianLatency(mean);
  final actualLatency = Duration(milliseconds: latencyMs.round());
  await waitWithCancellation(actualLatency, cancelSignal);

  if (cancelSignal.isCompleted) {
    throw Exception('Cancelled');
  }

  if (Random().nextDouble() < state.effectiveFailureRate) {
    throw Exception('Backend helper error');
  }

  return 'Success';
}

// --- Main Simulation ---

final statsTracker = StatsTracker();
final context = ResilienceContext();

ResourceConfig buildConfig() {
  return ResourceConfig(
    circuitBreaker: CircuitBreakerConfig(
      consecutiveFailuresThreshold: state.cbConsecutiveFailuresThreshold,
      resetTimeout: state.cbResetTimeout,
    ),
    throttling: ThrottlingConfig(
      k: state.throttlingK,
      windowDuration: const Duration(seconds: 10),
    ),
    retry: RetryConfig(
      maxAttempts: state.retryMaxAttempts,
      baseDelay: state.retryBaseDelay,
      minRequestsForBudget: 0,
      retryBudgetRatio: state.retryBudgetEnabled ? 0.1 : 1.0,
    ),
    hedging: HedgingConfig(
      enabled: state.hedgingEnabled,
      delay: state.hedgingDelay,
      dynamicPercentile: state.hedgingDynamicPercentile,
    ),
    timeout: state.overallTimeout,
  );
}

void executeRequest(Resource resource, Criticality criticality) async {
  final tracker = RequestTracker(criticality, statsTracker);
  statsTracker.record(criticality, EventType.requestStarted);

  try {
    await context.executeCancelable(
      Operation('op', resource, criticality: criticality),
      (cancelCompleter) async {
        tracker.startAttempt();
        statsTracker.record(criticality, EventType.backendAttempt);
        try {
          return await mockBackend(cancelCompleter);
        } finally {
          tracker.endAttempt();
        }
      },
    );
    statsTracker.record(criticality, EventType.requestSuccess);
  } on ThrottledException {
    statsTracker.record(criticality, EventType.requestThrottled);
    logEvent('[Throttled] ${criticality.name}');
  } on CircuitBreakerOpenException {
    statsTracker.record(criticality, EventType.requestBlockedCB);
  } on ResilienceTimeoutException {
    statsTracker.record(criticality, EventType.requestTimeout);
    logEvent('[Timeout] Request timed out');
  } catch (e) {
    statsTracker.record(criticality, EventType.requestFailure);
  }
}

void setStatus(String msg) {
  state.lastStatusMessage = msg;
}

void cleanup() {
  stdout.write('\x1B[?25h'); // Restore cursor
  stdout.write('\x1B[?1049l'); // Exit alternative screen buffer
  try {
    stdin.lineMode = true;
    stdin.echoMode = true;
  } catch (_) {}
}

void triggerBreakdown() {
  if (state.activeScenario != Scenario.none) {
    stopScenario();
  }
  const duration = 5;
  state.breakdownTimer?.cancel();

  if (!state.isBreakdownActive) {
    state.savedFailureRate = state.failureRate;
    state.isBreakdownActive = true;
  }

  state.failureRate = 1.0;
  setStatus('Service breakdown active for ${duration}s...');

  state.breakdownTimer = Timer(const Duration(seconds: duration), () {
    state.failureRate = state.savedFailureRate ?? 0.0;
    state.isBreakdownActive = false;
    state.savedFailureRate = null;
    state.breakdownTimer = null;
    setStatus(
      'Service recovered (failure rate restored to ${(state.failureRate * 100).toStringAsFixed(0)}%)',
    );
  });
}

void handleKey(String key) {
  try {
    switch (key) {
      case 'f':
        if (state.isBreakdownActive) {
          state.savedFailureRate = (state.savedFailureRate! + 0.1).clamp(
            0.0,
            1.0,
          );
          setStatus(
            'Backend failure rate (target) set to ${(state.savedFailureRate! * 100).toStringAsFixed(0)}%',
          );
        } else {
          state.failureRate = (state.failureRate + 0.1).clamp(0.0, 1.0);
          setStatus(
            'Backend failure rate set to ${(state.failureRate * 100).toStringAsFixed(0)}%',
          );
        }
      case 'F':
        if (state.isBreakdownActive) {
          state.savedFailureRate = (state.savedFailureRate! - 0.1).clamp(
            0.0,
            1.0,
          );
          setStatus(
            'Backend failure rate (target) set to ${(state.savedFailureRate! * 100).toStringAsFixed(0)}%',
          );
        } else {
          state.failureRate = (state.failureRate - 0.1).clamp(0.0, 1.0);
          setStatus(
            'Backend failure rate set to ${(state.failureRate * 100).toStringAsFixed(0)}%',
          );
        }
      case 'l':
        state.latency = Duration(
          milliseconds: (state.latency.inMilliseconds + 50).clamp(0, 2000),
        );
        setStatus('Latency set to ${state.latency.inMilliseconds}ms');
      case 'L':
        state.latency = Duration(
          milliseconds: (state.latency.inMilliseconds - 50).clamp(0, 2000),
        );
        setStatus('Latency set to ${state.latency.inMilliseconds}ms');
      case 'b':
        triggerBreakdown();
      case 'c':
        state.cbConsecutiveFailuresThreshold =
            (state.cbConsecutiveFailuresThreshold + 1).clamp(1, 20);
        state.configChanged = true;
        setStatus(
          'CB threshold set to ${state.cbConsecutiveFailuresThreshold}',
        );
      case 'C':
        state.cbConsecutiveFailuresThreshold =
            (state.cbConsecutiveFailuresThreshold - 1).clamp(1, 20);
        state.configChanged = true;
        setStatus(
          'CB threshold set to ${state.cbConsecutiveFailuresThreshold}',
        );
      case 'k':
        state.throttlingK = (state.throttlingK + 0.5).clamp(1.0, 10.0);
        state.configChanged = true;
        setStatus(
          'Throttling K set to ${state.throttlingK.toStringAsFixed(1)}',
        );
      case 'K':
        state.throttlingK = (state.throttlingK - 0.5).clamp(1.0, 10.0);
        state.configChanged = true;
        setStatus(
          'Throttling K set to ${state.throttlingK.toStringAsFixed(1)}',
        );
      case 't':
        state.overallTimeout = Duration(
          milliseconds: (state.overallTimeout.inMilliseconds + 50).clamp(
            10,
            2000,
          ),
        );
        state.configChanged = true;
        setStatus('Timeout set to ${state.overallTimeout.inMilliseconds}ms');
      case 'T':
        state.overallTimeout = Duration(
          milliseconds: (state.overallTimeout.inMilliseconds - 50).clamp(
            10,
            2000,
          ),
        );
        state.configChanged = true;
        setStatus('Timeout set to ${state.overallTimeout.inMilliseconds}ms');
      case 'g':
        state.hedgingDelay = Duration(
          milliseconds: (state.hedgingDelay.inMilliseconds + 50).clamp(
            10,
            2000,
          ),
        );
        state.configChanged = true;
        setStatus(
          'Hedging delay set to ${state.hedgingDelay.inMilliseconds}ms',
        );
      case 'G':
        state.hedgingDelay = Duration(
          milliseconds: (state.hedgingDelay.inMilliseconds - 50).clamp(
            10,
            2000,
          ),
        );
        state.configChanged = true;
        setStatus(
          'Hedging delay set to ${state.hedgingDelay.inMilliseconds}ms',
        );
      case 'h':
        state.hedgingEnabled = !state.hedgingEnabled;
        state.configChanged = true;
        setStatus('Hedging ${state.hedgingEnabled ? "enabled" : "disabled"}');
      case 'H':
        if (state.hedgingDynamicPercentile == null) {
          state.hedgingDynamicPercentile = 0.95;
          state.hedgingEnabled = true;
          setStatus('Dynamic hedging enabled (0.95)');
        } else {
          state.hedgingDynamicPercentile = null;
          setStatus('Dynamic hedging disabled');
        }
        state.configChanged = true;
      case 'r':
        state.retryBudgetEnabled = !state.retryBudgetEnabled;
        state.configChanged = true;
        setStatus(
          'Retry budget ${state.retryBudgetEnabled ? "enabled" : "disabled"}',
        );
      case 's':
        startScenario(Scenario.trafficSpike);
      case 'o':
        startScenario(Scenario.latencyBrownout);
      case 'v':
        startScenario(Scenario.oscillatingFailures);
      case 'p':
        state.backendCapacity = (state.backendCapacity + 10.0).clamp(
          10.0,
          500.0,
        );
        setStatus(
          'Backend capacity set to ${state.backendCapacity.toStringAsFixed(1)} RPS',
        );
      case 'P':
        state.backendCapacity = (state.backendCapacity - 10.0).clamp(
          10.0,
          500.0,
        );
        setStatus(
          'Backend capacity set to ${state.backendCapacity.toStringAsFixed(1)} RPS',
        );
      case 'q':
        cleanup();
        exit(0);
    }
  } catch (e) {
    setStatus('Error: ${e.toString().replaceAll('Exception: ', '')}');
  }
}

void drawUI() {
  final critPlusRolling = statsTracker.getRollingStats(
    Criticality.criticalPlus,
  );
  final critRolling = statsTracker.getRollingStats(Criticality.critical);
  final shedPlusRolling = statsTracker.getRollingStats(
    Criticality.sheddablePlus,
  );
  final shedRolling = statsTracker.getRollingStats(Criticality.sheddable);

  final critPlusCumulative = statsTracker.getCumulativeStats(
    Criticality.criticalPlus,
  );
  final critCumulative = statsTracker.getCumulativeStats(Criticality.critical);
  final shedPlusCumulative = statsTracker.getCumulativeStats(
    Criticality.sheddablePlus,
  );
  final shedCumulative = statsTracker.getCumulativeStats(Criticality.sheddable);

  final resState = context.states['api-service'];

  // Save cursor
  stdout.write('\x1B[s');
  // Move to top
  stdout.write('\x1B[0;0H');

  final buf = StringBuffer();

  String formatRow(String label, String c1, String c2, String c3, String c4) {
    final row =
        '${label.padRight(18)}${c1.padRight(15)}${c2.padRight(15)}${c3.padRight(15)}${c4.padRight(15)}';
    if (row.length > 80) {
      return row.substring(0, 80);
    }
    return row;
  }

  buf.writeln(
    '================================================================================\x1B[K',
  );
  buf.writeln(
    'Resilience Simulator Dashboard                                                  \x1B[K',
  );
  buf.writeln(
    '================================================================================\x1B[K',
  );

  // 1. TRAFFIC METRICS (cumulative)
  buf.writeln(
    '--- TRAFFIC METRICS (cumulative & rolling rates) --------------------------------\x1B[K',
  );
  buf.writeln(
    formatRow('Criticality:', 'critPlus', 'critical', 'shedPlus', 'sheddable') +
        '\x1B[K',
  );
  buf.writeln(
    '--------------------------------------------------------------------------------\x1B[K',
  );

  String formatMetricValue(int rollingVal, int cumulativeVal) {
    final rateStr = (rollingVal / 5.0).toStringAsFixed(1);
    return '$rateStr/s ($cumulativeVal)';
  }

  buf.writeln(
    formatRow(
          'Requests:',
          formatMetricValue(critPlusRolling.total, critPlusCumulative.total),
          formatMetricValue(critRolling.total, critCumulative.total),
          formatMetricValue(shedPlusRolling.total, shedPlusCumulative.total),
          formatMetricValue(shedRolling.total, shedCumulative.total),
        ) +
        '\x1B[K',
  );

  buf.writeln(
    formatRow(
          'Success:',
          formatMetricValue(
            critPlusRolling.success,
            critPlusCumulative.success,
          ),
          formatMetricValue(critRolling.success, critCumulative.success),
          formatMetricValue(
            shedPlusRolling.success,
            shedPlusCumulative.success,
          ),
          formatMetricValue(shedRolling.success, shedCumulative.success),
        ) +
        '\x1B[K',
  );

  buf.writeln(
    formatRow(
          'Failure:',
          formatMetricValue(
            critPlusRolling.failure,
            critPlusCumulative.failure,
          ),
          formatMetricValue(critRolling.failure, critCumulative.failure),
          formatMetricValue(
            shedPlusRolling.failure,
            shedPlusCumulative.failure,
          ),
          formatMetricValue(shedRolling.failure, shedCumulative.failure),
        ) +
        '\x1B[K',
  );

  buf.writeln(
    formatRow(
          'Timeout:',
          formatMetricValue(
            critPlusRolling.timeout,
            critPlusCumulative.timeout,
          ),
          formatMetricValue(critRolling.timeout, critCumulative.timeout),
          formatMetricValue(
            shedPlusRolling.timeout,
            shedPlusCumulative.timeout,
          ),
          formatMetricValue(shedRolling.timeout, shedCumulative.timeout),
        ) +
        '\x1B[K',
  );

  buf.writeln(
    formatRow(
          'Throttled:',
          formatMetricValue(
            critPlusRolling.throttled,
            critPlusCumulative.throttled,
          ),
          formatMetricValue(critRolling.throttled, critCumulative.throttled),
          formatMetricValue(
            shedPlusRolling.throttled,
            shedPlusCumulative.throttled,
          ),
          formatMetricValue(shedRolling.throttled, shedCumulative.throttled),
        ) +
        '\x1B[K',
  );

  buf.writeln(
    formatRow(
          'Blocked (CB):',
          formatMetricValue(
            critPlusRolling.blockedCB,
            critPlusCumulative.blockedCB,
          ),
          formatMetricValue(critRolling.blockedCB, critCumulative.blockedCB),
          formatMetricValue(
            shedPlusRolling.blockedCB,
            shedPlusCumulative.blockedCB,
          ),
          formatMetricValue(shedRolling.blockedCB, shedCumulative.blockedCB),
        ) +
        '\x1B[K',
  );

  buf.writeln(
    formatRow(
          'Hedges:',
          formatMetricValue(critPlusRolling.hedges, critPlusCumulative.hedges),
          formatMetricValue(critRolling.hedges, critCumulative.hedges),
          formatMetricValue(shedPlusRolling.hedges, shedPlusCumulative.hedges),
          formatMetricValue(shedRolling.hedges, shedCumulative.hedges),
        ) +
        '\x1B[K',
  );

  buf.writeln(
    formatRow(
          'Retries:',
          formatMetricValue(
            critPlusRolling.retries,
            critPlusCumulative.retries,
          ),
          formatMetricValue(critRolling.retries, critCumulative.retries),
          formatMetricValue(
            shedPlusRolling.retries,
            shedPlusCumulative.retries,
          ),
          formatMetricValue(shedRolling.retries, shedCumulative.retries),
        ) +
        '\x1B[K',
  );

  // 2. THROTTLING STATES (last 10s)
  buf.writeln(
    '--- THROTTLING STATES (last 10s) -----------------------------------------------\x1B[K',
  );

  String winReqStr(Criticality c) {
    if (resState == null) return '0';
    return '${resState.getThrottlingRequests(c)}';
  }

  String winAccStr(Criticality c) {
    if (resState == null) return '0';
    return '${resState.getThrottlingAccepts(c)}';
  }

  String rejProbStr(Criticality c) {
    if (resState == null) return '0.0%';
    final p = resState.getThrottlingRejectionProbability(c);
    return '${(p * 100).toStringAsFixed(1)}%';
  }

  buf.writeln(
    formatRow(
          'Window Requests:',
          winReqStr(Criticality.criticalPlus),
          winReqStr(Criticality.critical),
          winReqStr(Criticality.sheddablePlus),
          winReqStr(Criticality.sheddable),
        ) +
        '\x1B[K',
  );

  buf.writeln(
    formatRow(
          'Window Accepts:',
          winAccStr(Criticality.criticalPlus),
          winAccStr(Criticality.critical),
          winAccStr(Criticality.sheddablePlus),
          winAccStr(Criticality.sheddable),
        ) +
        '\x1B[K',
  );

  buf.writeln(
    formatRow(
          'Rejection Prob:',
          rejProbStr(Criticality.criticalPlus),
          rejProbStr(Criticality.critical),
          rejProbStr(Criticality.sheddablePlus),
          rejProbStr(Criticality.sheddable),
        ) +
        '\x1B[K',
  );

  // 3. SHARED MECHANISM STATES
  buf.writeln(
    '--- SHARED MECHANISM STATES ----------------------------------------------------\x1B[K',
  );

  String cbStateLine = 'Circuit Breaker:   ';
  if (resState != null) {
    String cbStateStr = 'UNKNOWN';
    String cbColor = '\x1B[0m';
    switch (resState.circuitState) {
      case CircuitState.closed:
        cbStateStr = 'CLOSED';
        cbColor = '\x1B[32m';
      case CircuitState.open:
        cbStateStr = 'OPEN';
        cbColor = '\x1B[31m';
      case CircuitState.halfOpen:
        cbStateStr = 'HALF-OPEN';
        cbColor = '\x1B[33m';
    }

    cbStateLine += '$cbColor$cbStateStr\x1B[0m';

    if (resState.circuitState == CircuitState.open) {
      final now = DateTime.now();
      final elapsed = now.difference(resState.lastStateChange);
      final remaining = resState.config.circuitBreaker.resetTimeout - elapsed;
      final remainingSecs = max(0.0, remaining.inMilliseconds / 1000.0);
      cbStateLine += ' (recovers in ${remainingSecs.toStringAsFixed(1)}s)';
    }

    cbStateLine +=
        ' | Failures: ${resState.failureCount} / ${resState.config.circuitBreaker.consecutiveFailuresThreshold}';
  } else {
    cbStateLine += 'N/A';
  }
  buf.writeln(cbStateLine + '\x1B[K');

  String retryBudgetLine = 'Retry Budget:      ';
  if (resState != null) {
    final budgetRequests = resState.getRetryBudgetRequests();
    final budgetRetries = resState.getRetryBudgetRetries();
    final ratio = resState.getRetryBudgetRatio();
    final limit = resState.config.retry.retryBudgetRatio;

    retryBudgetLine +=
        'Requests: $budgetRequests | Retries: $budgetRetries | Ratio: ${(ratio * 100).toStringAsFixed(1)}% / ${(limit * 100).toStringAsFixed(1)}%';
  } else {
    retryBudgetLine += 'N/A';
  }
  buf.writeln(retryBudgetLine + '\x1B[K');

  // 4. VISUAL TRENDS (last 20s)
  buf.writeln(
    '--- VISUAL TRENDS (last 20s) ---------------------------------------------------\x1B[K',
  );
  final currentSuccessRate = state.successRateHistory.isNotEmpty
      ? state.successRateHistory.last
      : 1.0;
  final currentSheddingProb = state.sheddingProbHistory.isNotEmpty
      ? state.sheddingProbHistory.last
      : 0.0;
  final successRateStr = '${(currentSuccessRate * 100).toStringAsFixed(1)}%';
  final sheddingProbStr = '${(currentSheddingProb * 100).toStringAsFixed(1)}%';

  buf.writeln(
    'Success Rate:  ${successRateStr.padLeft(6)} [${renderSparkline(state.successRateHistory)}]\x1B[K',
  );
  buf.writeln(
    'Shedding Prob: ${sheddingProbStr.padLeft(6)} [${renderSparkline(state.sheddingProbHistory)}]\x1B[K',
  );

  // 5. CONFIGURATIONS & HOTKEYS
  buf.writeln(
    '--- CONFIGURATIONS & HOTKEYS ---------------------------------------------------\x1B[K',
  );
  final breakdownOpt = state.isBreakdownActive
      ? '\x1B[31m[b] Breakdown (5s)\x1B[0m'
      : '[b] Breakdown (5s)';
  buf.writeln(
    'Backend:    [l/L] Base Lat: ${state.latency.inMilliseconds}ms | [f/F] Base Fail: ${(state.failureRate * 100).toStringAsFixed(0)}% | $breakdownOpt\x1B[K',
  );
  buf.writeln(
    '            [p/P] Cap: ${state.backendCapacity.toStringAsFixed(0)} | RPS: ${state.currentBackendRps.toStringAsFixed(1)} (${(state.loadFactor * 100).toStringAsFixed(0)}%) | Lat: ${state.effectiveLatency.inMilliseconds}ms | Fail: ${(state.effectiveFailureRate * 100).toStringAsFixed(0)}%\x1B[K',
  );
  final throttlingConfig =
      resState?.config.throttling ?? buildConfig().throttling;
  final kShed = throttlingConfig.getK(Criticality.sheddable).toStringAsFixed(1);
  final kShedPlus = throttlingConfig
      .getK(Criticality.sheddablePlus)
      .toStringAsFixed(1);
  final kCrit = throttlingConfig.getK(Criticality.critical).toStringAsFixed(1);
  final kCritPlus = throttlingConfig
      .getK(Criticality.criticalPlus)
      .toStringAsFixed(1);

  final cbThresh = state.cbConsecutiveFailuresThreshold;
  final cbReset = state.cbResetTimeout.inSeconds;
  final budgetStr = state.retryBudgetEnabled ? "ON (10%)" : "OFF";
  buf.writeln(
    'Resilience: [c/C] CB Thresh: $cbThresh | Reset: ${cbReset}s | [r] Budget: $budgetStr\x1B[K',
  );
  buf.writeln(
    '            [k/K] Base K: ${state.throttlingK.toStringAsFixed(1)} (Shed: $kShed, Shed+: $kShedPlus, Crit: $kCrit, Crit+: $kCritPlus)\x1B[K',
  );
  String hedgeStr;
  if (!state.hedgingEnabled) {
    hedgeStr = 'OFF';
  } else if (state.hedgingDynamicPercentile != null) {
    if (resState != null) {
      final estimate = resState.dynamicDelayEstimate;
      final multiplier = resState.config.hedging.delayMultiplier;
      final target = Duration(
        microseconds: (estimate.inMicroseconds * multiplier).round(),
      );
      final p = state.hedgingDynamicPercentile!;
      hedgeStr =
          'DYNAMIC (P${(p * 100).toInt()}: ${estimate.inMilliseconds}ms -> Target: ${target.inMilliseconds}ms)';
    } else {
      final p = state.hedgingDynamicPercentile!;
      hedgeStr = 'DYNAMIC (P${(p * 100).toInt()}: waiting...)';
    }
  } else {
    hedgeStr = '${state.hedgingDelay.inMilliseconds}ms';
  }
  buf.writeln(
    '            [g/G] Hedge: $hedgeStr ([h] Toggle, [H] Toggle Dynamic) | [t/T] Timeout: ${state.overallTimeout.inMilliseconds}ms\x1B[K',
  );
  buf.writeln(
    'Scenarios:  [s] Spike (5s) | [o] Brownout (15s) | [v] Oscillate (15s)\x1B[K',
  );
  buf.writeln('Controls:   [q] Quit\x1B[K');

  // 6. STATUS & SCENARIO
  buf.writeln(
    '================================================================================\x1B[K',
  );
  String scenarioLine = 'Scenario:          ${state.activeScenarioName}';
  if (state.activeScenario != Scenario.none) {
    final remainingSecs = state.scenarioTicksRemaining * 0.05;
    scenarioLine += ' (${remainingSecs.toStringAsFixed(1)}s remaining)';
  }
  buf.writeln(scenarioLine + '\x1B[K');
  buf.writeln('Status: ${state.lastStatusMessage}\x1B[K');

  // 7. LIVE EVENT LOG (last 5)
  buf.writeln(
    '--- LIVE EVENT LOG (last 5) ----------------------------------------------------\x1B[K',
  );
  for (int i = 0; i < 5; i++) {
    if (i < state.eventLog.length) {
      final event = state.eventLog[i];
      final ts = _formatTimestamp(event.timestamp);
      buf.writeln('[$ts] ${event.message}\x1B[K');
    } else {
      buf.writeln('\x1B[K');
    }
  }

  buf.writeln(
    '================================================================================\x1B[K',
  );

  stdout.write(buf.toString());

  // Restore cursor
  stdout.write('\x1B[u');
}

void main() async {
  // Enter alternative screen buffer
  stdout.write('\x1B[?1049h');
  // Hide cursor
  stdout.write('\x1B[?25l');
  // Clear screen once at start
  stdout.write('\x1B[2J\x1B[0;0H');

  try {
    stdin.lineMode = false;
    stdin.echoMode = false;
  } catch (_) {
    // Might fail if not a TTY
  }

  // Handle Ctrl+C to restore terminal screen buffer before exiting
  ProcessSignal.sigint.watch().listen((signal) {
    cleanup();
    exit(0);
  });

  var resource = Resource('api-service', config: buildConfig());

  // Simulation loop: every 50ms
  Timer.periodic(const Duration(milliseconds: 50), (timer) {
    if (state.configChanged) {
      resource = Resource('api-service', config: buildConfig());
      state.configChanged = false;
    }

    progressScenario();

    final resState = context.states['api-service'];
    if (resState != null) {
      final currentCBState = resState.circuitState;
      if (state.lastObservedCBState != currentCBState) {
        if (state.lastObservedCBState != null) {
          String stateStr;
          switch (currentCBState) {
            case CircuitState.closed:
              stateStr = 'CLOSED';
              break;
            case CircuitState.open:
              stateStr = 'OPEN';
              break;
            case CircuitState.halfOpen:
              stateStr = 'HALF-OPEN';
              break;
          }
          logEvent('[CB Tripped] -> $stateStr');
        }
        state.lastObservedCBState = currentCBState;
      }
    }

    final requestCount = state.activeScenario == Scenario.trafficSpike ? 5 : 1;
    for (var i = 0; i < requestCount; i++) {
      executeRequest(resource, Criticality.criticalPlus);
      executeRequest(resource, Criticality.critical);
      executeRequest(resource, Criticality.sheddablePlus);
      executeRequest(resource, Criticality.sheddable);
    }
  });

  // Metrics Sampler: every 500ms
  Timer.periodic(const Duration(milliseconds: 500), (timer) {
    int success = 0;
    int outcomes = 0;
    int totalBackendAttempts = 0;
    for (final c in Criticality.values) {
      final stats = statsTracker.getRollingStats(c);
      success += stats.success;
      outcomes +=
          stats.success +
          stats.failure +
          stats.timeout +
          stats.throttled +
          stats.blockedCB;
      totalBackendAttempts += stats.backendAttempts;
    }
    state.currentBackendRps = totalBackendAttempts / 5.0;
    final successRate = outcomes == 0 ? 1.0 : success / outcomes;
    state.successRateHistory.add(successRate);
    if (state.successRateHistory.length > 40) {
      state.successRateHistory.removeAt(0);
    }

    // Shedding Probability
    final resState = context.states['api-service'];
    final sheddingProb =
        resState?.getThrottlingRejectionProbability(Criticality.sheddable) ??
        0.0;
    state.sheddingProbHistory.add(sheddingProb);
    if (state.sheddingProbHistory.length > 40) {
      state.sheddingProbHistory.removeAt(0);
    }
  });

  // UI Redraw: every 200ms
  Timer.periodic(const Duration(milliseconds: 200), (timer) {
    drawUI();
  });

  // Listen to stdin raw
  stdin.transform(utf8.decoder).listen((char) {
    for (var i = 0; i < char.length; i++) {
      handleKey(char[i]);
    }
  });
}
