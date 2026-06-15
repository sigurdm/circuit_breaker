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
  String lastStatusMessage = 'Simulator started. Type "help" for commands.';
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

  StatsTracker({this.windowDuration = const Duration(seconds: 5)});

  void record(Criticality criticality, EventType type) {
    _events.add(MetricEvent(DateTime.now(), criticality, type));
  }

  void _purgeOldEvents() {
    final cutoff = DateTime.now().subtract(windowDuration);
    _events.removeWhere((e) => e.timestamp.isBefore(cutoff));
  }

  Stats getStats(Criticality criticality) {
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

void processCommand(String line) {
  final parts = line.trim().split(' ');
  if (parts.isEmpty || parts[0].isEmpty) return;

  final cmd = parts[0];
  final args = parts.sublist(1);

  try {
    switch (cmd) {
      case 'fail':
        if (args.isEmpty) throw Exception('Missing value');
        final val = double.parse(args[0]);
        if (val < 0.0 || val > 1.0) {
          throw Exception('Must be between 0.0 and 1.0');
        }
        if (state.isBreakdownActive) {
          state.breakdownTimer?.cancel();
          state.isBreakdownActive = false;
          state.savedFailureRate = null;
          state.breakdownTimer = null;
        }
        state.failureRate = val;
        setStatus(
          'Backend failure rate set to ${(val * 100).toStringAsFixed(0)}%',
        );
      case 'breakdown':
        final duration = args.isEmpty ? 5 : int.tryParse(args[0]) ?? 5;
        if (duration <= 0) throw Exception('Duration must be positive');

        state.breakdownTimer?.cancel();

        if (!state.isBreakdownActive) {
          state.savedFailureRate = state.failureRate;
          state.isBreakdownActive = true;
        }

        state.failureRate = 1.0;
        setStatus('Service breakdown active for ${duration}s...');

        state.breakdownTimer = Timer(Duration(seconds: duration), () {
          state.failureRate = state.savedFailureRate ?? 0.0;
          state.isBreakdownActive = false;
          state.savedFailureRate = null;
          state.breakdownTimer = null;
          setStatus(
            'Service recovered (failure rate restored to ${(state.failureRate * 100).toStringAsFixed(0)}%)',
          );
        });
      case 'latency':
        if (args.isEmpty) throw Exception('Missing value');
        final val = int.parse(args[0]);
        if (val < 0) throw Exception('Latency must be non-negative');
        state.latency = Duration(milliseconds: val);
        setStatus('Backend latency set to ${val}ms');
      case 'k':
        if (args.isEmpty) throw Exception('Missing value');
        final val = double.parse(args[0]);
        if (val <= 0) throw Exception('K must be positive');
        state.throttlingK = val;
        state.configChanged = true;
        setStatus('Throttling K set to $val');
      case 'threshold':
        if (args.isEmpty) throw Exception('Missing value');
        final val = int.parse(args[0]);
        if (val <= 0) throw Exception('CB threshold must be positive');
        state.cbConsecutiveFailuresThreshold = val;
        state.configChanged = true;
        setStatus('CB consecutive failures threshold set to $val');
      case 'timeout':
        if (args.isEmpty) throw Exception('Missing value');
        final val = int.parse(args[0]);
        if (val <= 0) throw Exception('Timeout must be positive');
        state.overallTimeout = Duration(milliseconds: val);
        state.configChanged = true;
        setStatus('Overall timeout set to ${val}ms');
      case 'hedge':
        if (args.isEmpty) throw Exception('Missing value');
        if (args[0] == 'off') {
          state.hedgingEnabled = false;
          setStatus('Hedging disabled');
        } else {
          final val = int.parse(args[0]);
          if (val <= 0) throw Exception('Hedging delay must be positive');
          state.hedgingEnabled = true;
          state.hedgingDelay = Duration(milliseconds: val);
          setStatus('Hedging delay set to ${val}ms');
        }
        state.configChanged = true;
      case 'help':
        state.showHelp = true;
      case 'quit':
        // Exit alternative screen buffer
        stdout.write('\x1B[?1049l');
        exit(0);
      default:
        setStatus('Unknown command: $cmd. Type "help" for info.');
    }
  } catch (e) {
    setStatus('Error: ${e.toString().replaceAll('Exception: ', '')}');
  }
}

void drawUI() {
  final critStats = statsTracker.getStats(Criticality.criticalPlus);
  final shedStats = statsTracker.getStats(Criticality.sheddable);

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
    'Resilience Simulator Dashboard (5s window)                                      \x1B[K',
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
  buf.writeln(
    'Total Requests:        ${critStats.total.toString().padRight(26)}${shedStats.total}\x1B[K',
  );

  final critSuccRate = critStats.success / 5.0;
  final shedSuccRate = shedStats.success / 5.0;
  buf.writeln(
    'Success Rate:          ${(critSuccRate).toStringAsFixed(1).padRight(5)}/s (${critStats.success})'
            .padRight(47) +
        '${(shedSuccRate).toStringAsFixed(1)}/s (${shedStats.success})\x1B[K',
  );

  final critFailRate = critStats.failure / 5.0;
  final shedFailRate = shedStats.failure / 5.0;
  buf.writeln(
    'Failure Rate:          ${(critFailRate).toStringAsFixed(1).padRight(5)}/s (${critStats.failure})'
            .padRight(47) +
        '${(shedFailRate).toStringAsFixed(1)}/s (${shedStats.failure})\x1B[K',
  );

  final critTimeoutRate = critStats.timeout / 5.0;
  final shedTimeoutRate = shedStats.timeout / 5.0;
  buf.writeln(
    'Timeout Rate:          ${(critTimeoutRate).toStringAsFixed(1).padRight(5)}/s (${critStats.timeout})'
            .padRight(47) +
        '${(shedTimeoutRate).toStringAsFixed(1)}/s (${shedStats.timeout})\x1B[K',
  );

  final critThroRate = critStats.throttled / 5.0;
  final shedThroRate = shedStats.throttled / 5.0;
  buf.writeln(
    'Throttled Rate:        ${(critThroRate).toStringAsFixed(1).padRight(5)}/s (${critStats.throttled})'
            .padRight(47) +
        '${(shedThroRate).toStringAsFixed(1)}/s (${shedStats.throttled})\x1B[K',
  );

  final critCBRate = critStats.blockedCB / 5.0;
  final shedCBRate = shedStats.blockedCB / 5.0;
  buf.writeln(
    'CB-Blocked Rate:       ${(critCBRate).toStringAsFixed(1).padRight(5)}/s (${critStats.blockedCB})'
            .padRight(47) +
        '${(shedCBRate).toStringAsFixed(1)}/s (${shedStats.blockedCB})\x1B[K',
  );

  buf.writeln(
    'Hedges Triggered:      ${critStats.hedges.toString().padRight(26)}${shedStats.hedges}\x1B[K',
  );
  buf.writeln(
    'Retries Triggered:     ${critStats.retries.toString().padRight(26)}${shedStats.retries}\x1B[K',
  );
  buf.writeln(
    '--------------------------------------------------------------------------------\x1B[K',
  );
  final breakdownStatus = state.isBreakdownActive
      ? ' \x1B[31m[BREAKDOWN ACTIVE]\x1B[0m'
      : '';
  buf.writeln(
    'Backend Config:        Latency: ${state.latency.inMilliseconds}ms | Failure Rate: ${(state.failureRate * 100).toStringAsFixed(0)}%$breakdownStatus\x1B[K',
  );
  buf.writeln(
    'Resilience Config:     CB Threshold: ${state.cbConsecutiveFailuresThreshold} | CB Reset: ${state.cbResetTimeout.inSeconds}s\x1B[K',
  );
  buf.writeln(
    '                       Throttling K: ${state.throttlingK}\x1B[K',
  );
  buf.writeln(
    '                       Retry Max: ${state.retryMaxAttempts} | Retry Base: ${state.retryBaseDelay.inMilliseconds}ms\x1B[K',
  );
  buf.writeln(
    '                       Hedge Delay: ${state.hedgingEnabled ? "${state.hedgingDelay.inMilliseconds}ms" : "OFF"} | Timeout: ${state.overallTimeout.inMilliseconds}ms\x1B[K',
  );
  buf.writeln(
    '================================================================================\x1B[K',
  );
  buf.writeln('Status: ${state.lastStatusMessage}\x1B[K');

  if (state.showHelp) {
    buf.writeln(
      '--------------------------------------------------------------------------------\x1B[K',
    );
    buf.writeln('Commands:\x1B[K');
    buf.writeln(
      '  fail <0.0-1.0>      Set backend failure rate (e.g., fail 0.4)\x1B[K',
    );
    buf.writeln(
      '  breakdown <sec>     Simulate temporary breakdown (default 5s)\x1B[K',
    );
    buf.writeln(
      '  latency <ms>        Set backend latency (e.g., latency 150)\x1B[K',
    );
    buf.writeln(
      '  k <double>          Set Throttling k parameter (e.g., k 1.5)\x1B[K',
    );
    buf.writeln(
      '  threshold <int>     Set CB consecutiveFailuresThreshold (e.g., threshold 3)\x1B[K',
    );
    buf.writeln(
      '  timeout <ms>        Set overall timeout in ms (e.g., timeout 300)\x1B[K',
    );
    buf.writeln(
      '  hedge <ms|off>      Set hedging delay in ms, or disable it (e.g., hedge 100)\x1B[K',
    );
    buf.writeln('  help                Show this help overlay\x1B[K');
    buf.writeln('  quit                Exit the simulator\x1B[K');
    buf.writeln('  (Any key to close help)\x1B[K');
  } else {
    for (int i = 0; i < 12; i++) {
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
  // Clear screen once at start
  stdout.write('\x1B[2J\x1B[0;0H');

  // Handle Ctrl+C to restore terminal screen buffer before exiting
  ProcessSignal.sigint.watch().listen((signal) {
    stdout.write('\x1B[?1049l');
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

  // Position prompt initially
  // Dashboard height is 23 (basic) + 12 (help/blank) + 2 (borders/status) = 37 lines.
  // Prompt at line 38.
  stdout.write('\x1B[38;0H');
  stdout.write('Simulator command > ');

  // Listen to stdin
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    if (state.showHelp) {
      state.showHelp = false;
    }
    processCommand(line);

    // Reposition prompt and clear the line
    stdout.write('\x1B[38;0H\x1B[K');
    stdout.write('Simulator command > ');
  });
}
