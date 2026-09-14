import 'dart:async';
import 'package:test/test.dart' hide Retry;
import 'package:circuit_breaker/circuit_breaker.dart';

class PrimaryException implements Exception {
  final String message;
  PrimaryException(this.message);
  @override
  String toString() => 'PrimaryException: $message';
}

class HedgeException implements Exception {
  final String message;
  HedgeException(this.message);
  @override
  String toString() => 'HedgeException: $message';
}

void main() {
  group('M1: Programmer errors are not retried by default', () {
    late ResilienceContext context;
    late Resource resource;

    setUp(() {
      context = ResilienceContext();
      resource = Resource(
        'm1-resource',
        retry: RetryConfig(maxAttempts: 3, baseDelay: Duration.zero),
      );
    });

    test(
      'ArgumentError fails immediately without retry in executeCancelable',
      () async {
        int attempts = 0;
        await expectLater(
          context.executeCancelable<String>(resource, (c) async {
            attempts++;
            throw ArgumentError('invalid argument');
          }),
          throwsArgumentError,
        );
        expect(attempts, equals(1));
      },
    );

    test(
      'RangeError fails immediately without retry in executeCancelable',
      () async {
        int attempts = 0;
        await expectLater(
          context.executeCancelable<String>(resource, (c) async {
            attempts++;
            throw RangeError.index(5, [1, 2], 'list');
          }),
          throwsRangeError,
        );
        expect(attempts, equals(1));
      },
    );

    test(
      'FormatException fails immediately without retry in executeCancelable',
      () async {
        int attempts = 0;
        await expectLater(
          context.executeCancelable<String>(resource, (c) async {
            attempts++;
            throw const FormatException('bad format');
          }),
          throwsFormatException,
        );
        expect(attempts, equals(1));
      },
    );

    test(
      'TypeError fails immediately without retry in executeCancelable',
      () async {
        int attempts = 0;
        await expectLater(
          context.executeCancelable<String>(resource, (c) async {
            attempts++;
            dynamic notAString = 123;
            return notAString as String;
          }),
          throwsA(isA<TypeError>()),
        );
        expect(attempts, equals(1));
      },
    );

    test(
      'AssertionError fails immediately without retry in executeCancelable',
      () async {
        int attempts = 0;
        await expectLater(
          context.executeCancelable<String>(resource, (c) async {
            attempts++;
            assert(false, 'assertion failed');
            return 'ok';
          }),
          throwsA(isA<AssertionError>()),
        );
        expect(attempts, equals(1));
      },
    );

    test(
      'transient exceptions ARE retried by default up to maxAttempts',
      () async {
        int attempts = 0;
        await expectLater(
          context.execute<String>(resource, () async {
            attempts++;
            throw Exception('transient network error');
          }),
          throwsException,
        );
        expect(attempts, equals(3));
      },
    );

    test(
      'programmer error IS retried if retryOn explicitly allows it',
      () async {
        int attempts = 0;
        await expectLater(
          context.execute<String>(resource, () async {
            attempts++;
            throw ArgumentError('explicit retry');
          }, retryOn: (e) => e is ArgumentError),
          throwsArgumentError,
        );
        expect(attempts, equals(3));
      },
    );

    test(
      'Retry.standalone does not retry programmer errors by default',
      () async {
        final r = Retry.standalone(maxAttempts: 3, baseDelay: Duration.zero);
        int attempts = 0;
        await expectLater(
          r.execute(() async {
            attempts++;
            throw ArgumentError('arg error');
          }),
          throwsArgumentError,
        );
        expect(attempts, equals(1));
      },
    );

    test(
      'Retry.standalone retries programmer error if retryOn explicitly overrides',
      () async {
        final r = Retry.standalone(
          maxAttempts: 3,
          baseDelay: Duration.zero,
          retryOn: (e) => true,
        );
        int attempts = 0;
        await expectLater(
          r.execute(() async {
            attempts++;
            throw ArgumentError('arg error');
          }),
          throwsArgumentError,
        );
        expect(attempts, equals(3));
      },
    );

    test(
      'top-level retry() function does not retry programmer errors by default',
      () async {
        int attempts = 0;
        await expectLater(
          retry(
            () async {
              attempts++;
              throw const FormatException('syntax error');
            },
            maxAttempts: 3,
            baseDelay: Duration.zero,
          ),
          throwsFormatException,
        );
        expect(attempts, equals(1));
      },
    );
  });

  group(
    'M2: Uncaught async background errors in runZonedGuarded do not hijack execution',
    () {
      test(
        'ResilienceContext.execute is not failed by background error in timer',
        () async {
          final context = ResilienceContext();
          final resource = Resource(
            'm2-resource',
            retry: RetryConfig(maxAttempts: 1),
          );

          final result = await context.execute(resource, () async {
            Timer(const Duration(milliseconds: 10), () {
              throw StateError('unhandled background timer error');
            });
            await Future.delayed(const Duration(milliseconds: 30));
            return 'primary-success';
          });

          expect(result, equals('primary-success'));
          // Wait past timer to ensure isolate does not crash
          await Future.delayed(const Duration(milliseconds: 40));
        },
      );

      test(
        'ResilienceContext.executeCancelable is not failed by unawaited async error',
        () async {
          final context = ResilienceContext();
          final resource = Resource(
            'm2-cancelable-resource',
            retry: RetryConfig(maxAttempts: 1),
          );

          final result = await context.executeCancelable(resource, (c) async {
            unawaited(Future(() => throw StateError('unhandled async error')));
            await Future.delayed(const Duration(milliseconds: 20));
            return 'cancelable-success';
          });

          expect(result, equals('cancelable-success'));
          await Future.delayed(const Duration(milliseconds: 30));
        },
      );

      test(
        'RequestHedger.execute is not failed by background error in timer',
        () async {
          final hedger = RequestHedger.standalone(
            delay: const Duration(milliseconds: 50),
          );

          final result = await hedger.execute(() async {
            Timer(const Duration(milliseconds: 10), () {
              throw StateError('unhandled background hedge timer error');
            });
            await Future.delayed(const Duration(milliseconds: 30));
            return 'hedger-success';
          });

          expect(result, equals('hedger-success'));
          await Future.delayed(const Duration(milliseconds: 40));
        },
      );
    },
  );

  group(
    'M3: Deterministically surface primary exception when both primary and hedge fail',
    () {
      test(
        'primary fails first, hedge fails second -> surfaces primary error',
        () async {
          final hedger = RequestHedger.standalone(
            delay: const Duration(milliseconds: 10),
          );

          int attempt = 0;
          await expectLater(
            hedger.executeCancelable((c) async {
              final isPrimary = (attempt++ == 0);
              if (isPrimary) {
                // Primary takes 20ms and fails first
                await Future.delayed(const Duration(milliseconds: 20));
                throw PrimaryException('primary failed at 20ms');
              } else {
                // Hedge starts at 10ms, takes 30ms (completes at 40ms) and fails second
                await Future.delayed(const Duration(milliseconds: 30));
                throw HedgeException('hedge failed at 40ms');
              }
            }),
            throwsA(
              isA<PrimaryException>().having(
                (e) => e.message,
                'message',
                equals('primary failed at 20ms'),
              ),
            ),
          );
        },
      );

      test(
        'hedge fails first, primary fails second -> surfaces primary error',
        () async {
          final hedger = RequestHedger.standalone(
            delay: const Duration(milliseconds: 10),
          );

          int attempt = 0;
          await expectLater(
            hedger.executeCancelable((c) async {
              final isPrimary = (attempt++ == 0);
              if (isPrimary) {
                // Primary takes 50ms and fails second
                await Future.delayed(const Duration(milliseconds: 50));
                throw PrimaryException('primary failed at 50ms');
              } else {
                // Hedge starts at 10ms, takes 15ms (completes at 25ms) and fails first
                await Future.delayed(const Duration(milliseconds: 15));
                throw HedgeException('hedge failed at 25ms');
              }
            }),
            throwsA(
              isA<PrimaryException>().having(
                (e) => e.message,
                'message',
                equals('primary failed at 50ms'),
              ),
            ),
          );
        },
      );

      test(
        'ResilienceContext with hedging surfaces primary error when both fail',
        () async {
          final context = ResilienceContext();
          final resource = Resource(
            'm3-context-resource',
            retry: RetryConfig(maxAttempts: 1),
            hedging: HedgingConfig(
              enabled: true,
              delay: const Duration(milliseconds: 10),
            ),
          );

          int attempt = 0;
          await expectLater(
            context.executeCancelable(resource, (c) async {
              final isPrimary = (attempt++ == 0);
              if (isPrimary) {
                await Future.delayed(const Duration(milliseconds: 50));
                throw PrimaryException('context primary error');
              } else {
                await Future.delayed(const Duration(milliseconds: 15));
                throw HedgeException('context hedge error');
              }
            }),
            throwsA(
              isA<PrimaryException>().having(
                (e) => e.message,
                'message',
                equals('context primary error'),
              ),
            ),
          );
        },
      );
    },
  );
}
