import 'dart:async';
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:circuit_breaker/src/hedging.dart';
import 'package:circuit_breaker/src/retry.dart' as cb;
import 'package:test/test.dart' hide Retry;

void main() {
  group('Low-Severity and Polish Items', () {
    group(
      'Item 1: ResourceConfig doc comment and _defaultFailureClassifier',
      () {
        test('defaultFailureClassifier returns true for general errors', () {
          expect(defaultFailureClassifier(Exception('network error')), isTrue);
          expect(defaultFailureClassifier(Error()), isTrue);
          expect(defaultFailureClassifier(StateError('state')), isTrue);
        });

        test(
          'ResourceConfig constructs cleanly and holds expected defaults',
          () {
            final config = ResourceConfig();
            expect(config.circuitBreaker, isA<CircuitBreakerConfig>());
            expect(config.retry, isA<RetryConfig>());
            expect(config.hedging, isA<HedgingConfig>());
            expect(config.throttling, isA<ThrottlingConfig>());
            expect(config.timeout, isNull);
          },
        );
      },
    );

    group('Item 2: RequestHedger.standalone respects enabled: false', () {
      test(
        'RequestHedger.standalone preserves enabled: false from config',
        () async {
          final hedger = RequestHedger.standalone(
            config: HedgingConfig(
              enabled: false,
              delay: const Duration(milliseconds: 10),
            ),
          );

          int attempts = 0;
          final resultCompleter = Completer<String>();

          final future = hedger.executeCancelable((cancel) async {
            attempts++;
            return await resultCompleter.future;
          });

          // Wait longer than the 10ms delay
          await Future.delayed(const Duration(milliseconds: 50));

          // Since enabled: false is preserved, no hedge should have been spawned.
          expect(attempts, equals(1));

          resultCompleter.complete('done');
          expect(await future, equals('done'));
        },
      );
    });

    group(
      'Item 3: hedge(...) function respects delay override with config',
      () {
        test(
          'hedge overrides config.delay when explicit delay is provided',
          () async {
            final config = HedgingConfig(
              delay: const Duration(milliseconds: 500),
              enabled: false,
            );

            int attempts = 0;
            final primaryCompleter = Completer<String>();

            final future = hedge<String>(
              () async {
                attempts++;
                if (attempts == 1) {
                  return await primaryCompleter.future;
                }
                return 'hedged';
              },
              delay: const Duration(milliseconds: 20),
              config: config,
              resourceName: 'delay-override-test-1',
            );

            // Wait past 20ms but well before 500ms
            await Future.delayed(const Duration(milliseconds: 60));

            // The hedge should have spawned at ~20ms, not 500ms
            expect(attempts, equals(2));
            expect(await future, equals('hedged'));
          },
        );

        test(
          'hedge uses config.delay when delay parameter is default (500ms)',
          () async {
            final config = HedgingConfig(
              delay: const Duration(milliseconds: 20),
              enabled: true,
            );

            int attempts = 0;
            final primaryCompleter = Completer<String>();

            final future = hedge<String>(
              () async {
                attempts++;
                if (attempts == 1) {
                  return await primaryCompleter.future;
                }
                return 'hedged';
              },
              config: config,
              resourceName: 'delay-override-test-2',
            );

            await Future.delayed(const Duration(milliseconds: 60));
            expect(attempts, equals(2));
            expect(await future, equals('hedged'));
          },
        );
      },
    );

    group('Item 5: ResourceState refundHedgingToken consolidation', () {
      test(
        'refundHedgingToken increments hedgingTokens up to maxOverloadTokens',
        () {
          final config = ResourceConfig(
            hedging: HedgingConfig(enabled: true, maxOverloadTokens: 5.0),
          );
          final state = ResourceState(config);
          state.hedgingTokens = 2.0;

          state.refundHedgingToken();
          expect(state.hedgingTokens, equals(3.0));

          state.hedgingTokens = 4.5;
          state.refundHedgingToken();
          expect(
            state.hedgingTokens,
            equals(5.0),
          ); // clamped to maxOverloadTokens
        },
      );
    });

    group('Item 6: Token already cancelled before first attempt', () {
      test(
        'executeWithRetry throws OperationCancelledException if token already cancelled',
        () async {
          final token = CancellationToken()..cancel();
          final config = ResourceConfig();
          final state = ResourceState(config);

          int attempts = 0;
          await expectLater(
            ResilienceContext.runWithCancellationToken(
              token,
              () => cb.executeWithRetry(
                () async {
                  attempts++;
                  return 'result';
                },
                config: config,
                state: state,
              ),
            ),
            throwsA(isA<OperationCancelledException>()),
          );

          expect(attempts, equals(0));
        },
      );

      test(
        'Retry.standalone.execute throws OperationCancelledException if token already cancelled',
        () async {
          final token = CancellationToken()..cancel();
          final retry = cb.Retry.standalone();

          int attempts = 0;
          await expectLater(
            ResilienceContext.runWithCancellationToken(
              token,
              () => retry.execute(() async {
                attempts++;
                return 'result';
              }),
            ),
            throwsA(isA<OperationCancelledException>()),
          );

          expect(attempts, equals(0));
        },
      );

      test(
        'executeWithHedging throws OperationCancelledException if token already cancelled before call',
        () async {
          final token = CancellationToken()..cancel();
          final config = ResourceConfig(hedging: HedgingConfig(enabled: true));
          final state = ResourceState(config);

          int attempts = 0;
          await expectLater(
            ResilienceContext.runWithCancellationToken(
              token,
              () => executeWithHedging(
                (c) async {
                  attempts++;
                  return 'result';
                },
                config: config,
                state: state,
              ),
            ),
            throwsA(isA<OperationCancelledException>()),
          );

          expect(attempts, equals(0));
        },
      );

      test(
        'RequestHedger.standalone throws OperationCancelledException if token already cancelled',
        () async {
          final token = CancellationToken()..cancel();
          final hedger = RequestHedger.standalone();

          int attempts = 0;
          await expectLater(
            ResilienceContext.runWithCancellationToken(
              token,
              () => hedger.execute(() async {
                attempts++;
                return 'result';
              }),
            ),
            throwsA(isA<OperationCancelledException>()),
          );

          expect(attempts, equals(0));
        },
      );

      test(
        'ResilienceContext.executeCancelable throws OperationCancelledException if parent token already cancelled',
        () async {
          final token = CancellationToken()..cancel();
          final context = ResilienceContext();
          final resource = Resource('cancelled-resource');

          int attempts = 0;
          await expectLater(
            ResilienceContext.runWithCancellationToken(
              token,
              () => context.executeCancelable(Operation('op', resource), (
                cancel,
              ) async {
                attempts++;
                return 'result';
              }),
            ),
            throwsA(isA<OperationCancelledException>()),
          );

          expect(attempts, equals(0));
        },
      );

      test(
        'ResilienceContext.execute throws OperationCancelledException if parent token already cancelled',
        () async {
          final token = CancellationToken()..cancel();
          final context = ResilienceContext();
          final resource = Resource('cancelled-resource-exec');

          int attempts = 0;
          await expectLater(
            ResilienceContext.runWithCancellationToken(
              token,
              () => context.execute(Operation('op', resource), () async {
                attempts++;
                return 'result';
              }),
            ),
            throwsA(isA<OperationCancelledException>()),
          );

          expect(attempts, equals(0));
        },
      );
    });
  });
}
