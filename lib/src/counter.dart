import 'dart:collection';
import 'dart:math';

import 'context.dart';

/// A single time slice in a bucketed ring counter for adaptive throttling.
final class _ThrottlingBucket {
  int epochBucket = -1;
  final List<int> requests = List.filled(Criticality.values.length, 0);
  final List<int> accepts = List.filled(Criticality.values.length, 0);
  int totalRequests = 0;
  int totalAccepts = 0;

  void reset(int newEpoch) {
    epochBucket = newEpoch;
    requests.fillRange(0, requests.length, 0);
    accepts.fillRange(0, accepts.length, 0);
    totalRequests = 0;
    totalAccepts = 0;
  }
}

/// A constant-time O(1) rolling window counter for adaptive throttling metrics.
///
/// Implements a ring buffer of fixed-duration time buckets covering a sliding
/// [windowDuration]. Maintains running totals across all criticalities to provide
/// O(1) recordings and O(1) metric queries without scanning or pruning unbounded lists.
///
/// Performance:
/// - [record]: O(1) amortized
/// - [clean]: O(1) bounded by [bucketCount]
/// - [getRequests], [getAccepts], [getTotalRequests], [getTotalAccepts]: O(1)
/// - Memory: O(B) fixed allocation where B is [bucketCount]
final class BucketedThrottlingCounter {
  Duration _windowDuration;
  final int bucketCount;
  late int _bucketDurationUs;
  late List<_ThrottlingBucket> _ring;
  int _lastEpoch = -1;

  final List<int> _requestsByCriticality = List.filled(
    Criticality.values.length,
    0,
  );
  final List<int> _acceptsByCriticality = List.filled(
    Criticality.values.length,
    0,
  );
  int _totalRequests = 0;
  int _totalAccepts = 0;

  /// The duration of the rolling time window.
  Duration get windowDuration => _windowDuration;

  /// Creates a new [BucketedThrottlingCounter].
  ///
  /// The [windowDuration] specifies the total duration of the rolling window.
  /// It is an error if [windowDuration] is not positive.
  /// The [bucketCount] specifies the number of discrete slices in the ring buffer (default 60).
  /// It is an error if [bucketCount] is less than 1.
  BucketedThrottlingCounter({
    required Duration windowDuration,
    this.bucketCount = 60,
  }) : _windowDuration = windowDuration {
    if (windowDuration <= Duration.zero) {
      throw ArgumentError.value(
        windowDuration,
        'windowDuration',
        'must be positive',
      );
    }
    if (bucketCount < 1) {
      throw ArgumentError.value(
        bucketCount,
        'bucketCount',
        'must be at least 1',
      );
    }
    _init();
  }

  void _init() {
    final us = _windowDuration.inMicroseconds;
    _bucketDurationUs = max(1, us ~/ bucketCount);
    _ring = List.generate(bucketCount, (_) => _ThrottlingBucket());
    _resetTotals();
    _lastEpoch = -1;
  }

  void _resetTotals() {
    _requestsByCriticality.fillRange(0, _requestsByCriticality.length, 0);
    _acceptsByCriticality.fillRange(0, _acceptsByCriticality.length, 0);
    _totalRequests = 0;
    _totalAccepts = 0;
  }

  /// Updates the sliding window duration, re-indexing existing buckets if necessary.
  void updateWindowDuration(Duration newDuration) {
    if (newDuration == _windowDuration) return;
    if (newDuration <= Duration.zero) {
      throw ArgumentError.value(newDuration, 'newDuration', 'must be positive');
    }
    _windowDuration = newDuration;
    _init();
  }

  /// Evicts buckets older than [now] minus [windowDuration].
  void clean(DateTime now) {
    final nowUs = now.microsecondsSinceEpoch;
    final currentEpoch = nowUs ~/ _bucketDurationUs;

    if (_lastEpoch == -1) {
      _lastEpoch = currentEpoch;
      return;
    }

    if (currentEpoch < _lastEpoch) {
      // Clock jumped backward: reset future or out-of-range buckets
      for (final b in _ring) {
        if (b.epochBucket > currentEpoch ||
            b.epochBucket <= currentEpoch - bucketCount) {
          _subtractBucket(b);
          b.reset(-1);
        }
      }
      _lastEpoch = currentEpoch;
      return;
    }

    final diff = currentEpoch - _lastEpoch;
    if (diff >= bucketCount) {
      // Complete window elapsed: wipe all buckets
      for (final b in _ring) {
        b.reset(-1);
      }
      _resetTotals();
      _lastEpoch = currentEpoch;
      return;
    }

    // Advance and evict expired slices
    for (var e = _lastEpoch + 1; e <= currentEpoch; e++) {
      final idx = e % bucketCount;
      final b = _ring[idx];
      if (b.epochBucket != -1 && b.epochBucket <= currentEpoch - bucketCount) {
        _subtractBucket(b);
        b.reset(-1);
      }
    }
    _lastEpoch = currentEpoch;
  }

  void _subtractBucket(_ThrottlingBucket b) {
    if (b.epochBucket == -1) return;
    _totalRequests = max(0, _totalRequests - b.totalRequests);
    _totalAccepts = max(0, _totalAccepts - b.totalAccepts);
    for (var i = 0; i < Criticality.values.length; i++) {
      _requestsByCriticality[i] = max(
        0,
        _requestsByCriticality[i] - b.requests[i],
      );
      _acceptsByCriticality[i] = max(
        0,
        _acceptsByCriticality[i] - b.accepts[i],
      );
    }
  }

  /// Records a request outcome for [criticality] at [timestamp].
  void record({
    required bool accepted,
    required Criticality criticality,
    required DateTime timestamp,
  }) {
    clean(timestamp);
    final tsUs = timestamp.microsecondsSinceEpoch;
    final epoch = tsUs ~/ _bucketDurationUs;

    if (_lastEpoch != -1 && epoch <= _lastEpoch - bucketCount) {
      return;
    }

    final idx = epoch % bucketCount;
    final b = _ring[idx];
    if (b.epochBucket != epoch) {
      _subtractBucket(b);
      b.reset(epoch);
    }

    final critIdx = criticality.index;
    b.requests[critIdx]++;
    b.totalRequests++;
    _requestsByCriticality[critIdx]++;
    _totalRequests++;

    if (accepted) {
      b.accepts[critIdx]++;
      b.totalAccepts++;
      _acceptsByCriticality[critIdx]++;
      _totalAccepts++;
    }
  }

  /// Returns the total requests for [criticality] in the active sliding window.
  int getRequests(Criticality criticality, [DateTime? now]) {
    if (now != null) clean(now);
    return _requestsByCriticality[criticality.index];
  }

  /// Returns the total accepted requests for [criticality] in the active sliding window.
  int getAccepts(Criticality criticality, [DateTime? now]) {
    if (now != null) clean(now);
    return _acceptsByCriticality[criticality.index];
  }

  /// Returns the aggregate requests across all criticalities in the active sliding window.
  int getTotalRequests([DateTime? now]) {
    if (now != null) clean(now);
    return _totalRequests;
  }

  /// Returns the aggregate accepted requests across all criticalities in the active sliding window.
  int getTotalAccepts([DateTime? now]) {
    if (now != null) clean(now);
    return _totalAccepts;
  }

  /// Resets all counters and clears all buckets.
  void clear() {
    for (final b in _ring) {
      b.reset(-1);
    }
    _resetTotals();
    _lastEpoch = -1;
  }

  /// Clears counts for a specific [criticality] without clearing other traffic.
  void clearCriticality(Criticality criticality) {
    final critIdx = criticality.index;
    for (final b in _ring) {
      if (b.epochBucket != -1) {
        b.totalRequests -= b.requests[critIdx];
        b.totalAccepts -= b.accepts[critIdx];
        _totalRequests = max(0, _totalRequests - b.requests[critIdx]);
        _totalAccepts = max(0, _totalAccepts - b.accepts[critIdx]);
        _requestsByCriticality[critIdx] = max(
          0,
          _requestsByCriticality[critIdx] - b.requests[critIdx],
        );
        _acceptsByCriticality[critIdx] = max(
          0,
          _acceptsByCriticality[critIdx] - b.accepts[critIdx],
        );
        b.requests[critIdx] = 0;
        b.accepts[critIdx] = 0;
      }
    }
  }

  /// Rebuilds metrics for [criticality] from a list of records.
  void rebuildFromCriticality(
    Criticality criticality,
    Iterable<RequestRecord> records,
  ) {
    clearCriticality(criticality);
    for (final r in records) {
      record(
        accepted: r.accepted,
        criticality: criticality,
        timestamp: r.timestamp,
      );
    }
  }
}

/// A single time slice in a bucketed ring counter for retry budget tracking.
final class _RetryBucket {
  int epochBucket = -1;
  int requests = 0;
  int retries = 0;

  void reset(int newEpoch) {
    epochBucket = newEpoch;
    requests = 0;
    retries = 0;
  }
}

/// A constant-time O(1) rolling window counter for retry budget calculations.
///
/// Implements a ring buffer of fixed-duration time buckets covering a sliding
/// [budgetWindow]. Tracks total requests and retried attempts to compute retry budget
/// ratios in O(1) time and constant memory.
///
/// Performance:
/// - [record]: O(1) amortized
/// - [clean]: O(1) bounded by [bucketCount]
/// - [getRequests], [getRetries], [getRatio]: O(1)
/// - Memory: O(B) fixed allocation where B is [bucketCount]
final class BucketedRetryCounter {
  Duration _budgetWindow;
  final int bucketCount;
  late int _bucketDurationUs;
  late List<_RetryBucket> _ring;
  int _lastEpoch = -1;

  int _totalRequests = 0;
  int _totalRetries = 0;

  /// The duration of the rolling retry budget window.
  Duration get budgetWindow => _budgetWindow;

  /// Creates a new [BucketedRetryCounter].
  ///
  /// The [budgetWindow] specifies the duration of the rolling window.
  /// It is an error if [budgetWindow] is not positive.
  /// The [bucketCount] specifies the number of discrete slices in the ring buffer (default 60).
  /// It is an error if [bucketCount] is less than 1.
  BucketedRetryCounter({required Duration budgetWindow, this.bucketCount = 60})
    : _budgetWindow = budgetWindow {
    if (budgetWindow <= Duration.zero) {
      throw ArgumentError.value(
        budgetWindow,
        'budgetWindow',
        'must be positive',
      );
    }
    if (bucketCount < 1) {
      throw ArgumentError.value(
        bucketCount,
        'bucketCount',
        'must be at least 1',
      );
    }
    _init();
  }

  void _init() {
    final us = _budgetWindow.inMicroseconds;
    _bucketDurationUs = max(1, us ~/ bucketCount);
    _ring = List.generate(bucketCount, (_) => _RetryBucket());
    _totalRequests = 0;
    _totalRetries = 0;
    _lastEpoch = -1;
  }

  /// Updates the budget window duration.
  void updateBudgetWindow(Duration newDuration) {
    if (newDuration == _budgetWindow) return;
    if (newDuration <= Duration.zero) {
      throw ArgumentError.value(newDuration, 'newDuration', 'must be positive');
    }
    _budgetWindow = newDuration;
    _init();
  }

  /// Evicts buckets older than [now] minus [budgetWindow].
  void clean(DateTime now) {
    final nowUs = now.microsecondsSinceEpoch;
    final currentEpoch = nowUs ~/ _bucketDurationUs;

    if (_lastEpoch == -1) {
      _lastEpoch = currentEpoch;
      return;
    }

    if (currentEpoch < _lastEpoch) {
      for (final b in _ring) {
        if (b.epochBucket > currentEpoch ||
            b.epochBucket <= currentEpoch - bucketCount) {
          _totalRequests = max(0, _totalRequests - b.requests);
          _totalRetries = max(0, _totalRetries - b.retries);
          b.reset(-1);
        }
      }
      _lastEpoch = currentEpoch;
      return;
    }

    final diff = currentEpoch - _lastEpoch;
    if (diff >= bucketCount) {
      for (final b in _ring) {
        b.reset(-1);
      }
      _totalRequests = 0;
      _totalRetries = 0;
      _lastEpoch = currentEpoch;
      return;
    }

    for (var e = _lastEpoch + 1; e <= currentEpoch; e++) {
      final idx = e % bucketCount;
      final b = _ring[idx];
      if (b.epochBucket != -1 && b.epochBucket <= currentEpoch - bucketCount) {
        _totalRequests = max(0, _totalRequests - b.requests);
        _totalRetries = max(0, _totalRetries - b.retries);
        b.reset(-1);
      }
    }
    _lastEpoch = currentEpoch;
  }

  /// Records an attempt at [timestamp], noting whether it was an [isRetry].
  void record({required bool isRetry, required DateTime timestamp}) {
    clean(timestamp);
    final tsUs = timestamp.microsecondsSinceEpoch;
    final epoch = tsUs ~/ _bucketDurationUs;

    if (_lastEpoch != -1 && epoch <= _lastEpoch - bucketCount) {
      return;
    }

    final idx = epoch % bucketCount;
    final b = _ring[idx];
    if (b.epochBucket != epoch) {
      if (b.epochBucket != -1) {
        _totalRequests = max(0, _totalRequests - b.requests);
        _totalRetries = max(0, _totalRetries - b.retries);
      }
      b.reset(epoch);
    }

    b.requests++;
    _totalRequests++;
    if (isRetry) {
      b.retries++;
      _totalRetries++;
    }
  }

  /// Returns the total attempts in the active retry budget window.
  int getRequests([DateTime? now]) {
    if (now != null) clean(now);
    return _totalRequests;
  }

  /// Returns the retried attempts in the active retry budget window.
  int getRetries([DateTime? now]) {
    if (now != null) clean(now);
    return _totalRetries;
  }

  /// Returns the ratio of retries to total requests in the active window (0.0 to 1.0).
  double getRatio([DateTime? now]) {
    if (now != null) clean(now);
    if (_totalRequests == 0) return 0.0;
    return _totalRetries / _totalRequests;
  }

  /// Resets all counters and clears all buckets.
  void clear() {
    for (final b in _ring) {
      b.reset(-1);
    }
    _totalRequests = 0;
    _totalRetries = 0;
    _lastEpoch = -1;
  }

  /// Rebuilds metrics from a list of records.
  void rebuildFrom(Iterable<RetryAttemptRecord> records) {
    clear();
    for (final r in records) {
      record(isRetry: r.isRetry, timestamp: r.timestamp);
    }
  }
}

/// A specialized [List] of [RequestRecord] that automatically keeps an underlying
/// [BucketedThrottlingCounter] synchronized for O(1) metric evaluation.
final class RequestHistoryList extends ListBase<RequestRecord> {
  /// The criticality associated with this history list.
  final Criticality criticality;

  /// The underlying bucketed counter.
  final BucketedThrottlingCounter counter;

  final List<RequestRecord> _records = [];

  /// Creates a new [RequestHistoryList].
  RequestHistoryList({required this.criticality, required this.counter});

  @override
  int get length => _records.length;

  @override
  set length(int newLength) {
    _records.length = newLength;
    counter.rebuildFromCriticality(criticality, _records);
  }

  @override
  RequestRecord operator [](int index) => _records[index];

  @override
  void operator []=(int index, RequestRecord value) {
    _records[index] = value;
    counter.rebuildFromCriticality(criticality, _records);
  }

  @override
  void add(RequestRecord element) {
    _records.add(element);
    counter.record(
      accepted: element.accepted,
      criticality: criticality,
      timestamp: element.timestamp,
    );
  }

  @override
  void addAll(Iterable<RequestRecord> iterable) {
    for (final element in iterable) {
      add(element);
    }
  }

  @override
  void clear() {
    _records.clear();
    counter.clearCriticality(criticality);
  }

  /// Prunes records that are strictly older than [cutoff] or strictly in the future of [maxTime].
  void pruneExpired({required DateTime cutoff, required DateTime maxTime}) {
    if (_records.isEmpty) return;
    if (_records.first.timestamp.isAfter(cutoff) &&
        !_records.last.timestamp.isAfter(maxTime)) {
      return;
    }
    _records.removeWhere(
      (r) => r.timestamp.isBefore(cutoff) || r.timestamp.isAfter(maxTime),
    );
  }
}

/// A specialized [List] of [RetryAttemptRecord] that automatically keeps an underlying
/// [BucketedRetryCounter] synchronized for O(1) retry budget evaluation.
final class RetryHistoryList extends ListBase<RetryAttemptRecord> {
  /// The underlying bucketed counter.
  final BucketedRetryCounter counter;

  final List<RetryAttemptRecord> _records = [];

  /// Creates a new [RetryHistoryList].
  RetryHistoryList({required this.counter});

  @override
  int get length => _records.length;

  @override
  set length(int newLength) {
    _records.length = newLength;
    counter.rebuildFrom(_records);
  }

  @override
  RetryAttemptRecord operator [](int index) => _records[index];

  @override
  void operator []=(int index, RetryAttemptRecord value) {
    _records[index] = value;
    counter.rebuildFrom(_records);
  }

  @override
  void add(RetryAttemptRecord element) {
    _records.add(element);
    counter.record(isRetry: element.isRetry, timestamp: element.timestamp);
  }

  @override
  void addAll(Iterable<RetryAttemptRecord> iterable) {
    for (final element in iterable) {
      add(element);
    }
  }

  @override
  void clear() {
    _records.clear();
    counter.clear();
  }

  /// Prunes records that are strictly older than [cutoff] or strictly in the future of [maxTime].
  void pruneExpired({required DateTime cutoff, required DateTime maxTime}) {
    if (_records.isEmpty) return;
    if (_records.first.timestamp.isAfter(cutoff) &&
        !_records.last.timestamp.isAfter(maxTime)) {
      return;
    }
    _records.removeWhere(
      (r) => r.timestamp.isBefore(cutoff) || r.timestamp.isAfter(maxTime),
    );
  }
}
