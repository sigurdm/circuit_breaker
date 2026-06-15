import 'package:test/test.dart';
import 'package:circuit_breaker/src/retry.dart';
import 'package:circuit_breaker/src/context.dart';

void main() {
  group('Retry', () {
    late ResourceConfig config;
    late ResourceState state;

    setUp(() {
      config = ResourceConfig(
        retry: RetryConfig(
          maxAttempts: 3,
          baseDelay: Duration(milliseconds: 10),
          enableJitter: false, // Disable jitter for predictable tests
        ),
      );
      state = ResourceState(config);
    });

    test('succeeds on first attempt', () async {
      int attempts = 0;
      final result = await executeWithRetry(
        () async {
          attempts++;
          return 'success';
        },
        config: config,
        state: state,
      );

      expect(result, 'success');
      expect(attempts, 1);
      expect(state.retryHistory.length, 1);
      expect(state.retryHistory.where((r) => r.isRetry).length, 0);
    });

    test('retries on failure and succeeds', () async {
      int attempts = 0;
      final result = await executeWithRetry(
        () async {
          attempts++;
          if (attempts < 3) {
            throw Exception('fail');
          }
          return 'success';
        },
        config: config,
        state: state,
      );

      expect(result, 'success');
      expect(attempts, 3);
      expect(state.retryHistory.length, 3);
      expect(state.retryHistory.where((r) => r.isRetry).length, 2);
    });

    test('fails after max attempts', () async {
      int attempts = 0;

      await expectLater(
        executeWithRetry(
          () async {
            attempts++;
            throw Exception('fail');
          },
          config: config,
          state: state,
        ),
        throwsException,
      );

      expect(attempts, 3);
      expect(state.retryHistory.length, 3);
      expect(state.retryHistory.where((r) => r.isRetry).length, 2);
    });

    test('enforces retry budget', () async {
      // Setup state to trigger budget (totalRequests > 10 and retries >= 10%)
      // We add 9 initial requests (not retries) and 2 retries.
      for (int i = 0; i < 9; i++) {
        state.retryHistory.add(
          RetryAttemptRecord(DateTime.now(), isRetry: false),
        );
      }
      state.retryHistory.add(RetryAttemptRecord(DateTime.now(), isRetry: true));
      state.retryHistory.add(RetryAttemptRecord(DateTime.now(), isRetry: true));

      int attempts = 0;

      await expectLater(
        executeWithRetry(
          () async {
            attempts++;
            throw Exception('fail');
          },
          config: config,
          state: state,
        ),
        throwsException,
      );

      // Should fail immediately on first attempt because budget is exceeded
      expect(attempts, 1);
      expect(state.retryHistory.length, 12); // 11 preset + 1 new attempt
      expect(
        state.retryHistory.where((r) => r.isRetry).length,
        2,
      ); // No new retries allowed
    });

    test('retryOn filtering - retries when true', () async {
      int attempts = 0;
      final result = await executeWithRetry(
        () async {
          attempts++;
          if (attempts == 1) throw ArgumentError('invalid');
          return 'success';
        },
        config: config,
        state: state,
        retryOn: (e) => e is ArgumentError,
      );

      expect(result, 'success');
      expect(attempts, 2);
    });

    test('retryOn filtering - rethrows immediately when false', () async {
      int attempts = 0;
      await expectLater(
        executeWithRetry(
          () async {
            attempts++;
            throw Exception('not an argument error');
          },
          config: config,
          state: state,
          retryOn: (e) => e is ArgumentError,
        ),
        throwsException,
      );

      expect(attempts, 1); // No retries
    });

    test('allows retry when it results in exactly the budget ratio', () async {
      // Config has default budget ratio of 0.1 (10%)
      // We want to achieve: totalRequests = 19, totalRetries = 1 at check point.
      // If we allow retry, totalRequests becomes 20, totalRetries becomes 2.
      // Ratio = 2/20 = 10% (exactly budget ratio).
      //
      // Preset history:
      // 17 successes (isRetry: false)
      // 1 retry (isRetry: true)
      for (int i = 0; i < 17; i++) {
        state.retryHistory.add(
          RetryAttemptRecord(DateTime.now(), isRetry: false),
        );
      }
      state.retryHistory.add(RetryAttemptRecord(DateTime.now(), isRetry: true));

      int attempts = 0;
      await executeWithRetry(
        () async {
          attempts++;
          if (attempts == 1) {
            throw Exception('fail');
          }
          return 'success';
        },
        config: config,
        state: state,
      );

      expect(attempts, 2); // Should be allowed to retry
    });
  });
}
