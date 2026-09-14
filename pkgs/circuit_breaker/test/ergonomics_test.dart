import 'package:test/test.dart';
import 'package:circuit_breaker/circuit_breaker.dart';

void main() {
  group('ResilienceTarget & Flattened Resource Constructor', () {
    test('Resource implements ResilienceTarget', () {
      final res = Resource('test-resource');
      expect(res, isA<ResilienceTarget>());
      expect(res.resource, equals(res));
      expect(res.criticality, equals(Criticality.critical));
      expect(res.hedgingOverride, isNull);
      expect(res.retryOverride, isNull);
    });

    test('Flattened Resource constructor configures policies directly', () {
      final res = Resource(
        'users-service',
        circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 3),
        retry: RetryConfig(maxAttempts: 5),
        throttling: ThrottlingConfig(k: 1.5),
        hedging: HedgingConfig(
          enabled: true,
          delay: const Duration(milliseconds: 150),
        ),
        timeout: const Duration(seconds: 4),
        failureClassifier: (e) => e is FormatException,
      );

      expect(res.config.circuitBreaker.consecutiveFailuresThreshold, equals(3));
      expect(res.config.retry.maxAttempts, equals(5));
      expect(res.config.throttling.k.critical, equals(1.5));
      expect(res.config.hedging.enabled, isTrue);
      expect(
        res.config.hedging.delay,
        equals(const Duration(milliseconds: 150)),
      );
      expect(res.config.timeout, equals(const Duration(seconds: 4)));
      expect(res.config.failureClassifier(FormatException()), isTrue);
      expect(res.config.failureClassifier(Exception()), isFalse);
    });

    test(
      'Resource constructor throws when both config and individual options are passed',
      () {
        expect(
          () => Resource(
            'bad-res',
            config: ResourceConfig(),
            retry: RetryConfig(maxAttempts: 2),
          ),
          throwsArgumentError,
        );
      },
    );

    test('Direct Resource execution via ResilienceContext.execute', () async {
      final context = ResilienceContext();
      int attempts = 0;
      final res = Resource(
        'direct-exec',
        retry: RetryConfig(maxAttempts: 3, baseDelay: Duration.zero),
      );

      final result = await context.execute(res, () async {
        attempts++;
        if (attempts < 3) throw Exception('temporary');
        return 'success';
      });

      expect(result, equals('success'));
      expect(attempts, equals(3));
    });

    test('Direct Resource execution trips circuit breaker', () async {
      final context = ResilienceContext();
      final res = Resource(
        'cb-exec',
        circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 2),
        retry: RetryConfig(maxAttempts: 1),
        throttling: ThrottlingConfig(minRequests: 100),
      );

      await expectLater(
        context.execute(res, () async => throw Exception('fail 1')),
        throwsException,
      );
      await expectLater(
        context.execute(res, () async => throw Exception('fail 2')),
        throwsException,
      );

      // 3rd attempt: circuit is open
      await expectLater(
        context.execute(res, () async => 'should not run'),
        throwsA(isA<CircuitBreakerOpenException>()),
      );
    });
  });

  group('Context Decorators (wrap and wrapUnary)', () {
    test('context.wrap decorates nullary functions', () async {
      final context = ResilienceContext();
      int attempts = 0;
      final res = Resource(
        'wrap-res',
        retry: RetryConfig(maxAttempts: 3, baseDelay: Duration.zero),
      );

      final fn = context.wrap(res, () async {
        attempts++;
        if (attempts < 2) throw Exception('transient');
        return 42;
      });

      final result = await fn();
      expect(result, equals(42));
      expect(attempts, equals(2));
    });

    test('context.wrapUnary decorates unary functions', () async {
      final context = ResilienceContext();
      int calls = 0;
      final res = Resource(
        'wrap-unary-res',
        retry: RetryConfig(maxAttempts: 2, baseDelay: Duration.zero),
      );

      final getUser = context.wrapUnary<String, int>(res, (id) async {
        calls++;
        return 'user_$id';
      });

      final u1 = await getUser(101);
      final u2 = await getUser(202);
      expect(u1, equals('user_101'));
      expect(u2, equals('user_202'));
      expect(calls, equals(2));
    });

    test('context.wrap propagates custom retryOn', () async {
      final context = ResilienceContext();
      int attempts = 0;
      final res = Resource(
        'retryon-res',
        retry: RetryConfig(maxAttempts: 3, baseDelay: Duration.zero),
      );

      final fn = context.wrap(res, () async {
        attempts++;
        throw ArgumentError('not retried');
      }, retryOn: (e) => e is FormatException);

      await expectLater(fn(), throwsArgumentError);
      expect(attempts, equals(1));
    });
  });

  group('BoundResource (context.resource and context.bind)', () {
    test(
      'context.resource creates BoundResource with direct methods',
      () async {
        final context = ResilienceContext();
        final users = context.resource(
          'users-bound',
          retry: RetryConfig(maxAttempts: 3, baseDelay: Duration.zero),
        );

        expect(users, isA<ResilienceTarget>());
        expect(users.name, equals('users-bound'));
        expect(users.context, equals(context));
        expect(users.config.retry.maxAttempts, equals(3));
        expect(users.resource, isA<Resource>());
        expect(users.state, isA<ResourceState>());

        int attempts = 0;
        final res = await users.execute(() async {
          attempts++;
          if (attempts < 3) throw Exception('retry me');
          return 'bound-success';
        });
        expect(res, equals('bound-success'));
        expect(attempts, equals(3));
      },
    );

    test('context.bind binds existing Resource', () async {
      final context = ResilienceContext();
      final original = Resource('legacy-service');
      final bound = context.bind(original);

      expect(bound.resource, equals(original));
      expect(bound.name, equals('legacy-service'));

      final result = await bound.execute(() async => 'bound-legacy');
      expect(result, equals('bound-legacy'));

      final parentRes = Resource('parent');
      final childRes = Resource('child', parent: parentRes);
      final boundChild = context.bind(childRes);
      expect(boundChild.parent, equals(parentRes));
      expect(boundChild.criticality, equals(Criticality.critical));
      expect(boundChild.hedgingOverride, isNull);
      expect(boundChild.retryOverride, isNull);
    });

    test('BoundResource.wrap and wrapUnary', () async {
      final context = ResilienceContext();
      final api = context.resource(
        'api-wrap',
        retry: RetryConfig(maxAttempts: 2, baseDelay: Duration.zero),
      );

      final getGreeting = api.wrap(() async => 'Hello');
      expect(await getGreeting(), equals('Hello'));

      final getEcho = api.wrapUnary<String, String>(
        (msg) async => 'Echo: $msg',
      );
      expect(await getEcho('Dart'), equals('Echo: Dart'));
    });

    test('BoundResource.operation creates sub-operation', () async {
      final context = ResilienceContext();
      final api = context.resource('parent-api');
      final op = api.operation(
        'special-op',
        retryOverride: RetryConfig(maxAttempts: 1),
        criticality: Criticality.sheddable,
      );

      expect(op.name, equals('special-op'));
      expect(op.resource, equals(api.resource));
      expect(op.retryOverride?.maxAttempts, equals(1));
      expect(op.criticality, equals(Criticality.sheddable));
    });

    test(
      'BoundResource.executeCancelable executes with cancel token',
      () async {
        final context = ResilienceContext();
        final api = context.resource('cancel-api');

        final result = await api.executeCancelable((cancelCompleter) async {
          expect(cancelCompleter.isCompleted, isFalse);
          return 'not-cancelled';
        });
        expect(result, equals('not-cancelled'));
      },
    );
  });

  group('Ambient / Default Context', () {
    test('ResilienceContext.defaultContext is accessible singleton', () {
      expect(ResilienceContext.defaultContext, isNotNull);
      expect(ResilienceContext.defaultContext, isA<ResilienceContext>());
      expect(
        ResilienceContext.defaultContext,
        same(ResilienceContext.defaultContext),
      );
    });

    test('ResilienceContext.run executes using defaultContext', () async {
      final target = Resource(
        'ambient-target',
        retry: RetryConfig(maxAttempts: 2, baseDelay: Duration.zero),
      );
      int attempts = 0;

      final res = await ResilienceContext.run(target, () async {
        attempts++;
        if (attempts < 2) throw Exception('retry ambient');
        return 'ambient-ok';
      });

      expect(res, equals('ambient-ok'));
      expect(attempts, equals(2));
    });

    test(
      'ResilienceContext.runCancelable executes using defaultContext',
      () async {
        final target = Resource('ambient-cancelable');

        final res = await ResilienceContext.runCancelable(target, (
          completer,
        ) async {
          return 'ambient-cancelable-ok';
        });

        expect(res, equals('ambient-cancelable-ok'));
      },
    );

    test(
      'ResilienceContext.run honors target.context when BoundResource',
      () async {
        final customContext = ResilienceContext();
        final bound = customContext.resource('custom-bound-res');

        final res = await ResilienceContext.run(
          bound,
          () async => 'custom-ctx-ok',
        );
        expect(res, equals('custom-ctx-ok'));
        expect(customContext.states.containsKey('custom-bound-res'), isTrue);
      },
    );
  });

  group('Resource.operation factory method', () {
    test('creates operation targeting resource with overrides', () {
      final res = Resource('res-op');
      final retryOverride = RetryConfig(maxAttempts: 5);
      final op = res.operation('my-op', retryOverride: retryOverride);

      expect(op.name, equals('my-op'));
      expect(op.resource, same(res));
      expect(op.retryOverride, same(retryOverride));
      expect(op.criticality, equals(Criticality.critical));
    });
  });
}
