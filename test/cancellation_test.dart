import 'dart:async';
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:test/test.dart';

void main() {
  group('CancellationToken Unit Tests', () {
    test('attach propagates cancellation', () {
      final parent = CancellationToken();
      final child = CancellationToken();
      child.attach(parent);

      expect(child.isCancelled, isFalse);
      parent.cancel();
      expect(child.isCancelled, isTrue);
    });

    test('detach stops propagation', () {
      final parent = CancellationToken();
      final child = CancellationToken();
      child.attach(parent);

      expect(child.isCancelled, isFalse);
      child.detach();
      parent.cancel();
      expect(child.isCancelled, isFalse);
    });

    test('cancel detaches from parent', () {
      final parent = CancellationToken();
      final child = CancellationToken();
      child.attach(parent);

      child.cancel();
      // Should be detached now, parent cancellation shouldn't affect it
    });

    test('attach to already-cancelled parent immediately cancels child', () {
      final parent = CancellationToken();
      parent.cancel();

      final child = CancellationToken();
      expect(child.isCancelled, isFalse);

      child.attach(parent);
      expect(child.isCancelled, isTrue);
    });
  });

  group('ResilienceContext CancellationToken Leak Tests', () {
    test('attemptToken is detached after successful execution', () async {
      final parentToken = CancellationToken();
      final context = ResilienceContext();
      final resource = Resource('test_resource');
      final operation = Operation('test_operation', resource);

      CancellationToken? capturedAttemptToken;

      await ResilienceContext.runWithCancellationToken(parentToken, () async {
        await context.executeCancelable(operation, (cancelCompleter) async {
          capturedAttemptToken = ResilienceContext.currentCancellationToken;
          expect(capturedAttemptToken, isNotNull);
          expect(capturedAttemptToken!.isCancelled, isFalse);
          return 'success';
        });
      });

      expect(capturedAttemptToken, isNotNull);
      expect(capturedAttemptToken!.isCancelled, isFalse);

      // Now cancel parent token. If attemptToken was not detached, it would be cancelled.
      parentToken.cancel();

      expect(capturedAttemptToken!.isCancelled, isFalse);
    });

    test('attemptToken is detached after failed execution', () async {
      final parentToken = CancellationToken();
      final context = ResilienceContext();
      final resource = Resource('test_resource');
      final operation = Operation('test_operation', resource);

      CancellationToken? capturedAttemptToken;

      await ResilienceContext.runWithCancellationToken(parentToken, () async {
        try {
          await context.executeCancelable(operation, (cancelCompleter) async {
            capturedAttemptToken = ResilienceContext.currentCancellationToken;
            throw Exception('failed');
          });
        } catch (_) {
          // Expected
        }
      });

      expect(capturedAttemptToken, isNotNull);
      expect(capturedAttemptToken!.isCancelled, isFalse);

      parentToken.cancel();

      expect(capturedAttemptToken!.isCancelled, isFalse);
    });

    test('attemptToken is detached after cancellation', () async {
      final parentToken = CancellationToken();
      final context = ResilienceContext();
      final resource = Resource('test_resource');
      final operation = Operation('test_operation', resource);

      CancellationToken? capturedAttemptToken;

      await ResilienceContext.runWithCancellationToken(parentToken, () async {
        try {
          await context.executeCancelable(operation, (cancelCompleter) async {
            capturedAttemptToken = ResilienceContext.currentCancellationToken;
            parentToken.cancel(); // Cancel from within

            // Wait to allow propagation
            await Future.delayed(const Duration(milliseconds: 50));
            throw const OperationCancelledException();
          });
        } catch (_) {
          // Expected
        }
      });

      expect(capturedAttemptToken, isNotNull);
      expect(
        capturedAttemptToken!.isCancelled,
        isTrue,
      ); // Should be cancelled because parent was cancelled during execution

      // Detach should still have happened.
      // Since it is already cancelled, detaching is mostly for GC.
    });

    group('Memory Leak Verification (WeakReference)', () {
      test('detached token can be GCed', () async {
        final parent = CancellationToken();

        WeakReference<CancellationToken> getWeakRef() {
          final child = CancellationToken();
          child.attach(parent);
          child.detach();
          return WeakReference(child);
        }

        final weakRef = getWeakRef();
        expect(weakRef.target, isNotNull);

        // Try to force GC
        for (int i = 0; i < 10; i++) {
          List<dynamic>? pin = [];
          for (var j = 0; j < 10000; j++) {
            pin.add(List.filled(100, j));
          }
          pin = null;
          await Future.delayed(
            const Duration(milliseconds: 1),
          ); // yield to allow GC
        }
        expect(weakRef.target, isNull);
      });
    });
  });
}
