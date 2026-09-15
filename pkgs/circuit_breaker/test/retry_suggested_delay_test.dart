import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

/// Error carrying its own retry timing, standing in for an HTTP 429.
final class _BackoffRequested implements Exception {
  final Duration after;
  _BackoffRequested(this.after);
}

void main() {
  group('RetryConfig.suggestedDelay', () {
    test('a suggestion replaces the computed backoff verbatim', () {
      fakeAsync((async) {
        final gaps = <Duration>[];
        var last = DateTime.fromMillisecondsSinceEpoch(0);
        var attempts = 0;

        final policy = ResiliencePolicy(
          retry: RetryConfig(
            maxAttempts: 3,
            // Backoff that is obviously distinguishable from the suggestion.
            baseDelay: const Duration(seconds: 5),
            maxDelay: const Duration(minutes: 1),
            enableJitter: false,
            suggestedDelay: (attempt, error) =>
                error is _BackoffRequested ? error.after : null,
          ),
        );

        policy.execute(() async {
          final now = clock.now();
          if (attempts > 0) gaps.add(now.difference(last));
          last = now;
          attempts++;
          if (attempts < 3) {
            throw _BackoffRequested(const Duration(milliseconds: 250));
          }
          return 'ok';
        }).ignore();

        async.elapse(const Duration(minutes: 2));

        expect(attempts, 3);
        // 250ms as asked, not the 5s / 10s exponential schedule.
        expect(gaps, [
          const Duration(milliseconds: 250),
          const Duration(milliseconds: 250),
        ]);
      });
    });

    test('a null suggestion falls back to exponential backoff', () {
      fakeAsync((async) {
        final gaps = <Duration>[];
        var last = DateTime.fromMillisecondsSinceEpoch(0);
        var attempts = 0;

        final policy = ResiliencePolicy(
          retry: RetryConfig(
            maxAttempts: 3,
            baseDelay: const Duration(seconds: 1),
            maxDelay: const Duration(minutes: 1),
            backoffFactor: 2.0,
            enableJitter: false,
            // Only opinionated about _BackoffRequested, which never occurs here.
            suggestedDelay: (attempt, error) =>
                error is _BackoffRequested ? error.after : null,
          ),
        );

        policy.execute(() async {
          final now = clock.now();
          if (attempts > 0) gaps.add(now.difference(last));
          last = now;
          attempts++;
          if (attempts < 3) throw StateError('boom');
          return 'ok';
        }).ignore();

        async.elapse(const Duration(minutes: 2));

        expect(gaps, [const Duration(seconds: 1), const Duration(seconds: 2)]);
      });
    });

    test('a suggestion is clamped to maxDelay', () {
      fakeAsync((async) {
        var attempts = 0;
        var completed = false;

        final policy = ResiliencePolicy(
          retry: RetryConfig(
            maxAttempts: 2,
            baseDelay: const Duration(milliseconds: 1),
            maxDelay: const Duration(seconds: 2),
            enableJitter: false,
            suggestedDelay: (attempt, error) => const Duration(hours: 1),
          ),
        );

        policy
            .execute(() async {
              attempts++;
              if (attempts < 2) throw StateError('boom');
              return 'ok';
            })
            .then((_) => completed = true)
            .ignore();

        async.elapse(const Duration(milliseconds: 1999));
        expect(completed, isFalse, reason: 'must wait the full maxDelay');

        async.elapse(const Duration(milliseconds: 2));
        expect(completed, isTrue, reason: 'must not wait the full hour');
      });
    });

    test('a negative or zero suggestion retries immediately', () {
      fakeAsync((async) {
        var attempts = 0;
        var completed = false;

        final policy = ResiliencePolicy(
          retry: RetryConfig(
            maxAttempts: 2,
            baseDelay: const Duration(seconds: 30),
            maxDelay: const Duration(minutes: 5),
            enableJitter: false,
            suggestedDelay: (attempt, error) => const Duration(seconds: -1),
          ),
        );

        policy
            .execute(() async {
              attempts++;
              if (attempts < 2) throw StateError('boom');
              return 'ok';
            })
            .then((_) => completed = true)
            .ignore();

        async.elapse(Duration.zero);
        expect(completed, isTrue);
      });
    });

    test(
      'a throwing hook falls back to backoff instead of failing the call',
      () {
        fakeAsync((async) {
          var attempts = 0;
          Object? outcome;

          final policy = ResiliencePolicy(
            retry: RetryConfig(
              maxAttempts: 2,
              baseDelay: const Duration(seconds: 1),
              maxDelay: const Duration(seconds: 10),
              enableJitter: false,
              suggestedDelay: (attempt, error) =>
                  throw StateError('hook is broken'),
            ),
          );

          policy
              .execute(() async {
                attempts++;
                if (attempts < 2) throw StateError('boom');
                return 'ok';
              })
              .then((v) => outcome = v)
              .ignore();

          async.elapse(const Duration(seconds: 5));

          expect(attempts, 2);
          expect(outcome, 'ok');
        });
      },
    );

    test('the hook receives the failing attempt number and error', () {
      fakeAsync((async) {
        final seen = <(int, String)>[];
        var attempts = 0;

        final policy = ResiliencePolicy(
          retry: RetryConfig(
            maxAttempts: 3,
            baseDelay: const Duration(milliseconds: 1),
            maxDelay: const Duration(seconds: 1),
            enableJitter: false,
            suggestedDelay: (attempt, error) {
              seen.add((attempt, (error as StateError).message));
              return Duration.zero;
            },
          ),
        );

        policy.execute(() async {
          attempts++;
          throw StateError('failure-$attempts');
        }).ignore();

        async.elapse(const Duration(seconds: 5));

        // Called after attempts 1 and 2; attempt 3 exhausts and rethrows.
        expect(seen, [(1, 'failure-1'), (2, 'failure-2')]);
      });
    });

    test('is carried through copyWith and equality', () {
      Duration? hook(int attempt, Object error) => Duration.zero;

      final base = RetryConfig(maxAttempts: 2);
      final withHook = base.copyWith(suggestedDelay: hook);

      expect(base.suggestedDelay, isNull);
      expect(withHook.suggestedDelay, same(hook));
      expect(withHook.maxAttempts, 2);

      expect(
        withHook,
        equals(RetryConfig(maxAttempts: 2, suggestedDelay: hook)),
      );
      expect(withHook, isNot(equals(base)));
    });
  });
}
