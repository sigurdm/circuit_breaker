import 'dart:async';
import 'package:test/test.dart';
import 'package:circuit_breaker/circuit_breaker.dart';

void main() {
  group('Sealed ResilienceException hierarchy', () {
    test('exhaustively matches in switch statement without default clause', () {
      String describe(ResilienceException e) {
        return switch (e) {
          CircuitBreakerOpenException(:final resourceName) =>
            'cb:${resourceName ?? "none"}',
          ThrottledException(:final criticality) =>
            'throttled:${criticality?.name ?? "none"}',
          ResilienceTimeoutException(:final timeout) =>
            'timeout:${timeout?.inMilliseconds ?? 0}',
          OperationCancelledException(:final token) =>
            'cancelled:${token != null}',
        };
      }

      final cb = CircuitBreakerOpenException('open', resourceName: 'api');
      final throttled = ThrottledException(
        'throttled',
        criticality: Criticality.sheddable,
      );
      final timeout = ResilienceTimeoutException(
        'timeout',
        timeout: const Duration(seconds: 1),
      );
      final cancelled = OperationCancelledException(
        'cancelled',
        CancellationToken(),
      );

      expect(describe(cb), equals('cb:api'));
      expect(describe(throttled), equals('throttled:sheddable'));
      expect(describe(timeout), equals('timeout:1000'));
      expect(describe(cancelled), equals('cancelled:true'));
    });

    test(
      'all exceptions implement ResilienceException and provide message',
      () {
        final exceptions = <ResilienceException>[
          const CircuitBreakerOpenException('cb error'),
          const ThrottledException('throttled error'),
          const ResilienceTimeoutException('timeout error'),
          const OperationCancelledException('cancelled error'),
        ];

        expect(
          exceptions.map((e) => e.message),
          containsAllInOrder([
            'cb error',
            'throttled error',
            'timeout error',
            'cancelled error',
          ]),
        );
      },
    );
  });

  group('Structured Exception Fields', () {
    test('CircuitBreakerOpenException stores structured fields', () {
      const e = CircuitBreakerOpenException(
        'Circuit breaker is open',
        resourceName: 'payment-svc',
        resetTimeout: Duration(seconds: 30),
        state: CircuitState.open,
      );

      expect(e.message, equals('Circuit breaker is open'));
      expect(e.resourceName, equals('payment-svc'));
      expect(e.resetTimeout, equals(const Duration(seconds: 30)));
      expect(e.state, equals(CircuitState.open));
      expect(
        e.toString(),
        equals('CircuitBreakerOpenException: Circuit breaker is open'),
      );
    });

    test('CircuitBreakerOpenException defaults optional fields to null', () {
      const e = CircuitBreakerOpenException('cb open');
      expect(e.resourceName, isNull);
      expect(e.resetTimeout, isNull);
      expect(e.state, isNull);
    });

    test('ThrottledException stores structured fields', () {
      const e = ThrottledException(
        'Request throttled',
        resourceName: 'user-db',
        criticality: Criticality.sheddablePlus,
        rejectionProbability: 0.42,
      );

      expect(e.message, equals('Request throttled'));
      expect(e.resourceName, equals('user-db'));
      expect(e.criticality, equals(Criticality.sheddablePlus));
      expect(e.rejectionProbability, equals(0.42));
      expect(e.toString(), equals('ThrottledException: Request throttled'));
    });

    test('ThrottledException defaults optional fields to null', () {
      const e = ThrottledException('throttled');
      expect(e.resourceName, isNull);
      expect(e.criticality, isNull);
      expect(e.rejectionProbability, isNull);
    });

    test('ResilienceTimeoutException stores structured fields', () {
      const e = ResilienceTimeoutException(
        'Timed out',
        timeout: Duration(milliseconds: 500),
        elapsed: Duration(milliseconds: 505),
      );

      expect(e.message, equals('Timed out'));
      expect(e.timeout, equals(const Duration(milliseconds: 500)));
      expect(e.elapsed, equals(const Duration(milliseconds: 505)));
      expect(e.toString(), equals('ResilienceTimeoutException: Timed out'));
    });

    test('ResilienceTimeoutException defaults optional fields to null', () {
      const e = ResilienceTimeoutException('timed out');
      expect(e.timeout, isNull);
      expect(e.elapsed, isNull);
    });

    test('OperationCancelledException stores structured fields', () {
      final token = CancellationToken();
      final e = OperationCancelledException('Aborted by user', token);

      expect(e.message, equals('Aborted by user'));
      expect(e.token, same(token));
      expect(
        e.toString(),
        equals('OperationCancelledException: Aborted by user'),
      );
    });

    test(
      'OperationCancelledException defaults to null token and standard message',
      () {
        const e = OperationCancelledException();
        expect(e.message, equals('Operation was cancelled'));
        expect(e.token, isNull);
        expect(
          e.toString(),
          equals('OperationCancelledException: Operation was cancelled'),
        );
      },
    );

    test(
      'Context execution populates CircuitBreakerOpenException fields',
      () async {
        final context = ResilienceContext();
        final resource = context.resource(
          'billing',
          circuitBreaker: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 1,
            resetTimeout: const Duration(seconds: 10),
          ),
        );

        // Trigger circuit to open
        try {
          await resource.execute(() async => throw Exception('failure'));
        } catch (_) {}

        try {
          await resource.execute(() async => 'ok');
          fail('Should have thrown CircuitBreakerOpenException');
        } on CircuitBreakerOpenException catch (e) {
          expect(e.resourceName, equals('billing'));
          expect(e.resetTimeout, equals(const Duration(seconds: 10)));
          expect(e.state, equals(CircuitState.open));
        }
      },
    );

    test(
      'Context execution populates ResilienceTimeoutException fields',
      () async {
        final context = ResilienceContext();
        final resource = context.resource(
          'slow-svc',
          timeout: const Duration(milliseconds: 20),
        );

        try {
          await resource.execute(() async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            return 'ok';
          });
          fail('Should have timed out');
        } on ResilienceTimeoutException catch (e) {
          expect(e.timeout, equals(const Duration(milliseconds: 20)));
          expect(e.elapsed, isNotNull);
          expect(
            e.elapsed!,
            greaterThanOrEqualTo(const Duration(milliseconds: 15)),
          );
        }
      },
    );

    test(
      'Context execution populates OperationCancelledException fields',
      () async {
        final context = ResilienceContext();
        final resource = context.resource('cancelable-svc');
        final token = CancellationToken();
        token.cancel();

        try {
          await resource.executeCancelable(
            (_) async => 'ok',
            cancellationToken: token,
          );
          fail('Should have thrown OperationCancelledException');
        } on OperationCancelledException catch (e) {
          expect(e.token, same(token));
        }
      },
    );
  });

  group('Config ergonomics - copyWith, ==, hashCode', () {
    test('CircuitBreakerConfig copyWith, equality, hashCode', () {
      final c1 = CircuitBreakerConfig(
        consecutiveFailuresThreshold: 3,
        resetTimeout: const Duration(seconds: 15),
        halfOpenSuccessThreshold: 2,
      );

      final c2 = c1.copyWith();
      expect(c2, equals(c1));
      expect(c2.hashCode, equals(c1.hashCode));

      final c3 = c1.copyWith(consecutiveFailuresThreshold: 10);
      expect(c3.consecutiveFailuresThreshold, equals(10));
      expect(c3.resetTimeout, equals(const Duration(seconds: 15)));
      expect(c3.halfOpenSuccessThreshold, equals(2));
      expect(c3, isNot(equals(c1)));

      final c4 = c1.copyWith(
        resetTimeout: const Duration(seconds: 60),
        halfOpenSuccessThreshold: 5,
      );
      expect(c4.consecutiveFailuresThreshold, equals(3));
      expect(c4.resetTimeout, equals(const Duration(seconds: 60)));
      expect(c4.halfOpenSuccessThreshold, equals(5));
      expect(c4, isNot(equals(c1)));
    });

    test('RetryConfig copyWith, equality, hashCode', () {
      final r1 = RetryConfig(
        maxAttempts: 4,
        baseDelay: const Duration(milliseconds: 200),
        maxDelay: const Duration(seconds: 2),
        backoffFactor: 3.0,
        enableJitter: false,
        minRequestsForBudget: 15,
        retryBudgetRatio: 0.2,
        budgetWindow: const Duration(minutes: 2),
      );

      final r2 = r1.copyWith();
      expect(r2, equals(r1));
      expect(r2.hashCode, equals(r1.hashCode));

      final r3 = r1.copyWith(maxAttempts: 1, enableJitter: true);
      expect(r3.maxAttempts, equals(1));
      expect(r3.enableJitter, isTrue);
      expect(r3.baseDelay, equals(const Duration(milliseconds: 200)));
      expect(r3, isNot(equals(r1)));

      final r4 = r1.copyWith(
        baseDelay: const Duration(milliseconds: 100),
        maxDelay: const Duration(seconds: 5),
        backoffFactor: 1.5,
        minRequestsForBudget: 20,
        retryBudgetRatio: 0.25,
        budgetWindow: const Duration(minutes: 5),
      );
      expect(r4.baseDelay, equals(const Duration(milliseconds: 100)));
      expect(r4.maxDelay, equals(const Duration(seconds: 5)));
      expect(r4.backoffFactor, equals(1.5));
      expect(r4.minRequestsForBudget, equals(20));
      expect(r4.retryBudgetRatio, equals(0.25));
      expect(r4.budgetWindow, equals(const Duration(minutes: 5)));
      expect(r4, isNot(equals(r1)));
    });

    test('ThrottlingConfig copyWith, equality, hashCode', () {
      final t1 = ThrottlingConfig(
        k: 1.8,
        minRequests: 40,
        windowDuration: const Duration(seconds: 60),
      );

      final t2 = t1.copyWith();
      expect(t2, equals(t1));
      expect(t2.hashCode, equals(t1.hashCode));

      final t3 = t1.copyWith(minRequests: 100);
      expect(t3.minRequests, equals(100));
      expect(t3.windowDuration, equals(const Duration(seconds: 60)));
      expect(t3, isNot(equals(t1)));

      final t4 = t1.copyWith(
        windowDuration: const Duration(seconds: 120),
        k: (
          criticalPlus: 3.0,
          critical: 2.0,
          sheddablePlus: 1.5,
          sheddable: 1.2,
        ),
      );
      expect(t4.windowDuration, equals(const Duration(seconds: 120)));
      expect(t4.k.critical, equals(2.0));
      expect(t4, isNot(equals(t1)));
    });

    test('HedgingConfig copyWith, equality, hashCode', () {
      final h1 = HedgingConfig(
        delay: const Duration(milliseconds: 150),
        delayMultiplier: 1.5,
        maxConcurrentHedges: 3,
        enabled: true,
      );

      final h2 = h1.copyWith();
      expect(h2, equals(h1));
      expect(h2.hashCode, equals(h1.hashCode));

      final h3 = h1.copyWith(maxConcurrentHedges: 5, enabled: false);
      expect(h3.maxConcurrentHedges, equals(5));
      expect(h3.enabled, isFalse);
      expect(h3.delay, equals(const Duration(milliseconds: 150)));
      expect(h3, isNot(equals(h1)));

      final h4 = h1.copyWith(
        delay: const Duration(milliseconds: 200),
        delayMultiplier: 2.0,
      );
      expect(h4.delay, equals(const Duration(milliseconds: 200)));
      expect(h4.delayMultiplier, equals(2.0));
      expect(h4, isNot(equals(h1)));
    });

    test('ResourceConfig copyWith, equality, hashCode', () {
      final rc1 = ResourceConfig(
        circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 2),
        retry: RetryConfig(maxAttempts: 2),
        throttling: ThrottlingConfig(k: 1.5),
        hedging: HedgingConfig(maxConcurrentHedges: 1),
        timeout: const Duration(seconds: 3),
      );

      final rc2 = rc1.copyWith();
      expect(rc2, equals(rc1));
      expect(rc2.hashCode, equals(rc1.hashCode));

      final rc3 = rc1.copyWith(
        timeout: const Duration(seconds: 10),
        circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 5),
      );
      expect(rc3.timeout, equals(const Duration(seconds: 10)));
      expect(rc3.circuitBreaker.consecutiveFailuresThreshold, equals(5));
      expect(rc3.retry.maxAttempts, equals(2));
      expect(rc3, isNot(equals(rc1)));

      final rc4 = rc1.copyWith(
        retry: RetryConfig(maxAttempts: 5),
        throttling: ThrottlingConfig(k: 3.0),
        hedging: HedgingConfig(maxConcurrentHedges: 4),
      );
      expect(rc4.retry.maxAttempts, equals(5));
      expect(rc4.throttling.k.critical, equals(3.0));
      expect(rc4.hedging.maxConcurrentHedges, equals(4));
      expect(rc4, isNot(equals(rc1)));
    });
  });

  group('Per-operation timeout override', () {
    test('Operation timeout override overrides resource timeout', () async {
      final context = ResilienceContext();
      final resource = context.resource(
        'fast-or-slow',
        timeout: const Duration(seconds: 10), // resource default is 10s
      );
      final fastOp = resource.operation(
        'fast',
        timeout: const Duration(milliseconds: 30), // override to 30ms
      );

      expect(fastOp.timeoutOverride, equals(const Duration(milliseconds: 30)));

      try {
        await context.execute(fastOp, () async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return 'done';
        });
        fail('Should have timed out with 30ms override');
      } on ResilienceTimeoutException catch (e) {
        expect(e.timeout, equals(const Duration(milliseconds: 30)));
      }
    });

    test('Operation constructor validates positive timeout', () {
      final res = Resource('test-res');
      expect(
        () => Operation('bad', res, timeout: Duration.zero),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => Operation('bad', res, timeout: const Duration(milliseconds: -1)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'execute(timeout: ...) parameter overrides resource timeout',
      () async {
        final context = ResilienceContext();
        final resource = context.resource(
          'call-timeout-res',
          timeout: const Duration(seconds: 10),
        );

        try {
          await resource.execute(() async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            return 'ok';
          }, timeout: const Duration(milliseconds: 25));
          fail('Should have timed out via call timeout override');
        } on ResilienceTimeoutException catch (e) {
          expect(e.timeout, equals(const Duration(milliseconds: 25)));
        }
      },
    );

    test(
      'executeCancelable(timeout: ...) parameter overrides target timeout',
      () async {
        final context = ResilienceContext();
        final resource = context.resource(
          'call-timeout-res-cancelable',
          timeout: const Duration(seconds: 10),
        );
        final op = resource.operation(
          'op',
          timeout: const Duration(seconds: 5),
        );

        // Call override (30ms) should take precedence over operation override (5s)
        try {
          await context.executeCancelable(op, (_) async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            return 'ok';
          }, timeout: const Duration(milliseconds: 30));
          fail('Should have timed out via executeCancelable call override');
        } on ResilienceTimeoutException catch (e) {
          expect(e.timeout, equals(const Duration(milliseconds: 30)));
        }
      },
    );

    test('ResiliencePolicy supports per-call timeout override', () async {
      final policy = ResiliencePolicy(timeout: const Duration(seconds: 10));

      try {
        await policy.execute(() async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return 'ok';
        }, timeout: const Duration(milliseconds: 25));
        fail('Should have timed out via policy execute timeout override');
      } on ResilienceTimeoutException catch (e) {
        expect(e.timeout, equals(const Duration(milliseconds: 25)));
      }
    });
  });

  group('Cancellation ergonomics', () {
    test(
      'executeCancelable with pre-cancelled cancellationToken aborts immediately',
      () async {
        final context = ResilienceContext();
        final resource = context.resource('cancel-res');
        final token = CancellationToken();
        token.cancel();

        bool actionCalled = false;
        try {
          await resource.executeCancelable((_) async {
            actionCalled = true;
            return 'ok';
          }, cancellationToken: token);
          fail('Should have thrown OperationCancelledException');
        } on OperationCancelledException catch (e) {
          expect(actionCalled, isFalse);
          expect(e.token, same(token));
        }
      },
    );

    test(
      'executeCancelable with cancellationToken cancelled mid-flight aborts',
      () async {
        final context = ResilienceContext();
        final resource = context.resource('cancel-midflight');
        final token = CancellationToken();

        final future = resource.executeCancelable((cancelCompleter) async {
          await cancelCompleter.future;
          throw const OperationCancelledException();
        }, cancellationToken: token);

        await Future<void>.delayed(const Duration(milliseconds: 10));
        token.cancel();

        await expectLater(future, throwsA(isA<OperationCancelledException>()));
      },
    );

    test(
      'ResiliencePolicy executeCancelable supports cancellationToken',
      () async {
        final policy = ResiliencePolicy();
        final token = CancellationToken();
        token.cancel();

        bool actionCalled = false;
        try {
          await policy.executeCancelable((_) async {
            actionCalled = true;
            return 'ok';
          }, cancellationToken: token);
          fail('Should have thrown OperationCancelledException');
        } on OperationCancelledException catch (e) {
          expect(actionCalled, isFalse);
          expect(e.token, same(token));
        }
      },
    );

    test(
      'ResilienceContext.runCancelable supports cancellationToken and timeout',
      () async {
        final resource = Resource('static-run-res');
        final token = CancellationToken();
        token.cancel();

        expect(
          () => ResilienceContext.runCancelable(
            resource,
            (_) async => 'ok',
            cancellationToken: token,
          ),
          throwsA(isA<OperationCancelledException>()),
        );
      },
    );
  });
}
