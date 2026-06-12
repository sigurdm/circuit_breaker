import 'package:test/test.dart';
import 'package:circuit_breaker/src/retry.dart';
import 'package:circuit_breaker/src/context.dart';

void main() {
  group('Retry', () {
    late ResourceConfig config;
    late ResourceState state;

    setUp(() {
      config = const ResourceConfig(
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
      expect(state.totalRequests, 1);
      expect(state.totalRetries, 0);
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
      expect(state.totalRequests, 3);
      expect(state.totalRetries, 2);
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
      expect(state.totalRequests, 3);
      expect(state.totalRetries, 2);
    });

    test('enforces retry budget', () async {
      // Setup state to trigger budget (totalRequests > 10 and retries >= 10%)
      state.totalRequests = 11;
      state.totalRetries = 2; // ~18%

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
      expect(state.totalRequests, 12);
      expect(state.totalRetries, 2); // No new retries allowed
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
  });
}
