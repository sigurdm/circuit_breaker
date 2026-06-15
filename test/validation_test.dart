import 'package:test/test.dart';
import 'package:circuit_breaker/src/context.dart';

void main() {
  group('API Validation', () {
    group('ThrottlingConfig', () {
      test('valid config does not throw', () {
        expect(() => ThrottlingConfig(k: 1.0, spread: 0.0), returnsNormally);
        expect(() => ThrottlingConfig.withCriticality(
          k: (criticalPlus: 1.0, critical: 1.0, sheddablePlus: 1.0, sheddable: 1.0),
        ), returnsNormally);
      });

      test('k < 1.0 throws ArgumentError', () {
        expect(() => ThrottlingConfig(k: 0.9), throwsArgumentError);
        expect(() => ThrottlingConfig.withCriticality(
          k: (criticalPlus: 0.9, critical: 1.0, sheddablePlus: 1.0, sheddable: 1.0),
        ), throwsArgumentError);
        expect(() => ThrottlingConfig.withCriticality(
          k: (criticalPlus: 1.0, critical: 0.9, sheddablePlus: 1.0, sheddable: 1.0),
        ), throwsArgumentError);
        expect(() => ThrottlingConfig.withCriticality(
          k: (criticalPlus: 1.0, critical: 1.0, sheddablePlus: 0.9, sheddable: 1.0),
        ), throwsArgumentError);
        expect(() => ThrottlingConfig.withCriticality(
          k: (criticalPlus: 1.0, critical: 1.0, sheddablePlus: 1.0, sheddable: 0.9),
        ), throwsArgumentError);
      });

      test('spread < 0 throws ArgumentError', () {
        expect(() => ThrottlingConfig(spread: -0.1), throwsArgumentError);
      });

      test('windowDuration <= 0 throws ArgumentError', () {
        expect(() => ThrottlingConfig(windowDuration: Duration.zero), throwsArgumentError);
        expect(() => ThrottlingConfig(windowDuration: Duration(seconds: -1)), throwsArgumentError);
        expect(() => ThrottlingConfig.withCriticality(
          k: (criticalPlus: 1.0, critical: 1.0, sheddablePlus: 1.0, sheddable: 1.0),
          windowDuration: Duration.zero,
        ), throwsArgumentError);
      });
    });

    group('CircuitBreakerConfig', () {
      test('valid config does not throw', () {
        expect(() => CircuitBreakerConfig(), returnsNormally);
      });

      test('consecutiveFailuresThreshold < 1 throws ArgumentError', () {
        expect(() => CircuitBreakerConfig(consecutiveFailuresThreshold: 0), throwsArgumentError);
        expect(() => CircuitBreakerConfig(consecutiveFailuresThreshold: -1), throwsArgumentError);
      });

      test('resetTimeout <= 0 throws ArgumentError', () {
        expect(() => CircuitBreakerConfig(resetTimeout: Duration.zero), throwsArgumentError);
        expect(() => CircuitBreakerConfig(resetTimeout: Duration(seconds: -1)), throwsArgumentError);
      });
    });

    group('RetryConfig', () {
      test('valid config does not throw', () {
        expect(() => RetryConfig(), returnsNormally);
      });

      test('maxAttempts < 1 throws ArgumentError', () {
        expect(() => RetryConfig(maxAttempts: 0), throwsArgumentError);
      });

      test('baseDelay < 0 throws ArgumentError', () {
        expect(() => RetryConfig(baseDelay: Duration(seconds: -1)), throwsArgumentError);
      });

      test('maxDelay < baseDelay throws ArgumentError', () {
        expect(
          () => RetryConfig(baseDelay: Duration(seconds: 2), maxDelay: Duration(seconds: 1)),
          throwsArgumentError,
        );
      });

      test('backoffFactor < 1.0 throws ArgumentError', () {
        expect(() => RetryConfig(backoffFactor: 0.9), throwsArgumentError);
      });

      test('retryBudgetRatio not in [0.0, 1.0] throws ArgumentError', () {
        expect(() => RetryConfig(retryBudgetRatio: -0.1), throwsArgumentError);
        expect(() => RetryConfig(retryBudgetRatio: 1.1), throwsArgumentError);
      });

      test('budgetWindow <= 0 throws ArgumentError', () {
        expect(() => RetryConfig(budgetWindow: Duration.zero), throwsArgumentError);
      });

      test('minRequestsForBudget < 0 throws ArgumentError', () {
        expect(() => RetryConfig(minRequestsForBudget: -1), throwsArgumentError);
      });
    });

    group('HedgingConfig', () {
      test('valid config does not throw', () {
        expect(() => HedgingConfig(), returnsNormally);
      });

      test('negative delays throw ArgumentError', () {
        expect(() => HedgingConfig(delay: Duration(seconds: -1)), throwsArgumentError);
        expect(() => HedgingConfig(minDelay: Duration(seconds: -1)), throwsArgumentError);
        expect(() => HedgingConfig(maxDelay: Duration(seconds: -1)), throwsArgumentError);
      });

      test('minDelay > maxDelay throws ArgumentError', () {
        expect(
          () => HedgingConfig(minDelay: Duration(seconds: 2), maxDelay: Duration(seconds: 1)),
          throwsArgumentError,
        );
      });

      test('dynamicPercentile not in [0.0, 1.0] throws ArgumentError', () {
        expect(() => HedgingConfig(dynamicPercentile: -0.1), throwsArgumentError);
        expect(() => HedgingConfig(dynamicPercentile: 1.1), throwsArgumentError);
      });

      test('delayMultiplier <= 0 throws ArgumentError', () {
        expect(() => HedgingConfig(delayMultiplier: 0.0), throwsArgumentError);
        expect(() => HedgingConfig(delayMultiplier: -0.1), throwsArgumentError);
      });

      test('adaptationRate <= 0 throws ArgumentError', () {
        expect(() => HedgingConfig(adaptationRate: 0.0), throwsArgumentError);
        expect(() => HedgingConfig(adaptationRate: -0.1), throwsArgumentError);
      });

      test('overloadPercentile not in [0.0, 1.0] throws ArgumentError', () {
        expect(() => HedgingConfig(overloadPercentile: -0.1), throwsArgumentError);
        expect(() => HedgingConfig(overloadPercentile: 1.1), throwsArgumentError);
      });

      test('maxOverloadTokens < 0 throws ArgumentError', () {
        expect(() => HedgingConfig(maxOverloadTokens: -0.1), throwsArgumentError);
      });

      test('maxConcurrentHedges < 0 throws ArgumentError', () {
        expect(() => HedgingConfig(maxConcurrentHedges: -1), throwsArgumentError);
      });
    });

    group('Resource', () {
      test('empty name throws ArgumentError', () {
        expect(() => Resource(''), throwsArgumentError);
      });
    });

    group('Operation', () {
      test('empty name throws ArgumentError', () {
        final resource = Resource('name');
        expect(() => Operation('', resource), throwsArgumentError);
      });
    });

    group('ResourceConfig', () {
      test('timeout <= 0 throws ArgumentError', () {
        expect(() => ResourceConfig(timeout: Duration.zero), throwsArgumentError);
        expect(() => ResourceConfig(timeout: Duration(seconds: -1)), throwsArgumentError);
      });
    });
  });
}
