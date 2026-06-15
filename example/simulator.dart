import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:circuit_breaker/circuit_breaker.dart';

// --- State ---

final class SimulatorState {
  double failureRate = 0.0;
  Duration latency = const Duration(milliseconds: 50);

  // Resilience Config
  int cbConsecutiveFailuresThreshold = 5;
  Duration cbResetTimeout = const Duration(seconds: 5);
  double throttlingK = 2.0;
  int retryMaxAttempts = 3;
  Duration retryBaseDelay = const Duration(milliseconds: 100);
  bool hedgingEnabled = true;
  Duration hedgingDelay = const Duration(milliseconds: 100);
  Duration overallTimeout = const Duration(milliseconds: 500);

  bool showHelp = false;
  String lastStatusMessage = 'Simulator started. Press "?" for help.';
  bool configChanged = false;

  Timer? breakdownTimer;
  double? savedFailureRate;
  bool isBreakdownActive = false;
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
}

final class MetricEvent {
  final DateTime timestamp;
  final Criticality criticality;
  final EventType type;
  MetricEvent(this.timestamp, this.criticality, this.type);
}

final class StatsTracker {
  final List<MetricEvent> _events = [];
  final Duration windowDuration;

  // Cumulative stats since startup
  final Map<Criticality, Stats> _cumulativeStats = {
    Criticality.criticalPlus: Stats(),
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
    } else if (totalAttempts > 0) {
      statsTracker.record(criticality, EventType.retryTriggered);
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

Future<String> mockBackend(Completer<void> cancelSignal) async {
  await waitWithCancellation(state.latency, cancelSignal);

  if (cancelSignal.isCompleted) {
    throw Exception('Cancelled');
  }

  if (Random().nextDouble() < state.failureRate) {
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
      retryBudgetRatio: 1.0,
    ),
    hedging: HedgingConfig(
      enabled: state.hedgingEnabled,
      delay: state.hedgingDelay,
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
  } on CircuitBreakerOpenException {
    statsTracker.record(criticality, EventType.requestBlockedCB);
  } on ResilienceTimeoutException {
    statsTracker.record(criticality, EventType.requestTimeout);
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
  if (state.showHelp && key != '?') {
    state.showHelp = false;
    return;
  }

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
      case '?':
        state.showHelp = !state.showHelp;
      case 'q':
        cleanup();
        exit(0);
    }
  } catch (e) {
    setStatus('Error: ${e.toString().replaceAll('Exception: ', '')}');
  }
}

void drawUI() {
  final critRolling = statsTracker.getRollingStats(Criticality.criticalPlus);
  final shedRolling = statsTracker.getRollingStats(Criticality.sheddable);
  final critCumulative = statsTracker.getCumulativeStats(
    Criticality.criticalPlus,
  );
  final shedCumulative = statsTracker.getCumulativeStats(Criticality.sheddable);

  final resState = context.states['api-service'];
  String cbStateStr = 'UNKNOWN';
  String cbColor = '\x1B[0m'; // Reset

  if (resState != null) {
    switch (resState.circuitState) {
      case CircuitState.closed:
        cbStateStr = 'CLOSED';
        cbColor = '\x1B[32m'; // Green
      case CircuitState.open:
        cbStateStr = 'OPEN';
        cbColor = '\x1B[31m'; // Red
      case CircuitState.halfOpen:
        cbStateStr = 'HALF-OPEN';
        cbColor = '\x1B[33m'; // Yellow
    }
  }

  // Save cursor
  stdout.write('\x1B[s');
  // Move to top
  stdout.write('\x1B[0;0H');

  final buf = StringBuffer();
  buf.writeln(
    '================================================================================\x1B[K',
  );
  buf.writeln(
    'Resilience Simulator Dashboard                                                  \x1B[K',
  );
  buf.writeln(
    '================================================================================\x1B[K',
  );
  buf.writeln(
    'Resource: api-service | CB State: $cbColor$cbStateStr\x1B[0m (Fail Count: ${resState?.failureCount ?? 0})\x1B[K',
  );
  buf.writeln(
    '--------------------------------------------------------------------------------\x1B[K',
  );
  buf.writeln(
    'Stats:                 Critical (criticalPlus)    Sheddable (sheddable)         \x1B[K',
  );
  buf.writeln(
    '--------------------------------------------------------------------------------\x1B[K',
  );

  final critTotalStr = '${critCumulative.total} (since start)';
  final shedTotalStr = '${shedCumulative.total} (since start)';
  buf.writeln(
    'Total Requests:        ${critTotalStr.padRight(26)}${shedTotalStr}\x1B[K',
  );

  final critSuccessStr =
      '${(critRolling.success / 5.0).toStringAsFixed(1)}/s (${critCumulative.success})';
  final shedSuccessStr =
      '${(shedRolling.success / 5.0).toStringAsFixed(1)}/s (${shedCumulative.success})';
  buf.writeln(
    'Success Rate:          ${critSuccessStr.padRight(26)}${shedSuccessStr}\x1B[K',
  );

  final critFailStr =
      '${(critRolling.failure / 5.0).toStringAsFixed(1)}/s (${critCumulative.failure})';
  final shedFailStr =
      '${(shedRolling.failure / 5.0).toStringAsFixed(1)}/s (${shedCumulative.failure})';
  buf.writeln(
    'Failure Rate:          ${critFailStr.padRight(26)}${shedFailStr}\x1B[K',
  );

  final critTimeoutStr =
      '${(critRolling.timeout / 5.0).toStringAsFixed(1)}/s (${critCumulative.timeout})';
  final shedTimeoutStr =
      '${(shedRolling.timeout / 5.0).toStringAsFixed(1)}/s (${shedCumulative.timeout})';
  buf.writeln(
    'Timeout Rate:          ${critTimeoutStr.padRight(26)}${shedTimeoutStr}\x1B[K',
  );

  final critThrottledStr =
      '${(critRolling.throttled / 5.0).toStringAsFixed(1)}/s (${critCumulative.throttled})';
  final shedThrottledStr =
      '${(shedRolling.throttled / 5.0).toStringAsFixed(1)}/s (${shedCumulative.throttled})';
  buf.writeln(
    'Throttled Rate:        ${critThrottledStr.padRight(26)}${shedThrottledStr}\x1B[K',
  );

  final critBlockedStr =
      '${(critRolling.blockedCB / 5.0).toStringAsFixed(1)}/s (${critCumulative.blockedCB})';
  final shedBlockedStr =
      '${(shedRolling.blockedCB / 5.0).toStringAsFixed(1)}/s (${shedCumulative.blockedCB})';
  buf.writeln(
    'CB-Blocked Rate:       ${critBlockedStr.padRight(26)}${shedBlockedStr}\x1B[K',
  );

  final critHedgesStr =
      '${(critRolling.hedges / 5.0).toStringAsFixed(1)}/s (${critCumulative.hedges})';
  final shedHedgesStr =
      '${(shedRolling.hedges / 5.0).toStringAsFixed(1)}/s (${shedCumulative.hedges})';
  buf.writeln(
    'Hedges Triggered:      ${critHedgesStr.padRight(26)}${shedHedgesStr}\x1B[K',
  );

  final critRetriesStr =
      '${(critRolling.retries / 5.0).toStringAsFixed(1)}/s (${critCumulative.retries})';
  final shedRetriesStr =
      '${(shedRolling.retries / 5.0).toStringAsFixed(1)}/s (${shedCumulative.retries})';
  buf.writeln(
    'Retries Triggered:     ${critRetriesStr.padRight(26)}${shedRetriesStr}\x1B[K',
  );

  buf.writeln(
    '--------------------------------------------------------------------------------\x1B[K',
  );
  final breakdownStatus = state.isBreakdownActive
      ? ' \x1B[31m[BREAKDOWN ACTIVE]\x1B[0m'
      : '';
  buf.writeln(
    'Backend Config:        [l/L] Latency: ${state.latency.inMilliseconds}ms | [f/F] Failure Rate: ${(state.failureRate * 100).toStringAsFixed(0)}% [b] Breakdown$breakdownStatus\x1B[K',
  );
  buf.writeln(
    'Resilience Config:     [c/C] CB Threshold: ${state.cbConsecutiveFailuresThreshold} | CB Reset: ${state.cbResetTimeout.inSeconds}s\x1B[K',
  );
  buf.writeln(
    '                       [k/K] Throttling K: ${state.throttlingK.toStringAsFixed(1)}\x1B[K',
  );
  buf.writeln(
    '                       [g/G] Hedge Delay: ${state.hedgingEnabled ? "${state.hedgingDelay.inMilliseconds}ms" : "OFF"} ([h] Toggle) | [t/T] Timeout: ${state.overallTimeout.inMilliseconds}ms\x1B[K',
  );
  buf.writeln(
    '================================================================================\x1B[K',
  );
  buf.writeln('Status: ${state.lastStatusMessage}\x1B[K');

  if (state.showHelp) {
    buf.writeln(
      '--------------------------------------------------------------------------------\x1B[K',
    );
    buf.writeln('Hotkeys:\x1B[K');
    buf.writeln(
      '  f / F  : Increase / Decrease backend failure rate by 10%\x1B[K',
    );
    buf.writeln('  l / L  : Increase / Decrease backend latency by 50ms\x1B[K');
    buf.writeln(
      '  b      : Trigger 5-second service breakdown (100% failure rate)\x1B[K',
    );
    buf.writeln('  c / C  : Increase / Decrease CB threshold\x1B[K');
    buf.writeln('  k / K  : Increase / Decrease Throttling K parameter\x1B[K');
    buf.writeln('  t / T  : Increase / Decrease overall timeout\x1B[K');
    buf.writeln('  g / G  : Increase / Decrease hedging delay\x1B[K');
    buf.writeln('  h      : Toggle hedging enabled\x1B[K');
    buf.writeln('  ?      : Toggle this help overlay\x1B[K');
    buf.writeln('  q      : Quit the simulator\x1B[K');
  } else {
    for (int i = 0; i < 12; i++) {
      buf.writeln('\x1B[K');
    }
  }
  buf.writeln(
    '================================================================================\x1B[K',
  );
  buf.writeln('Controls: [?] Help | [q] Quit\x1B[K');

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
    executeRequest(resource, Criticality.criticalPlus);
    executeRequest(resource, Criticality.sheddable);
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
