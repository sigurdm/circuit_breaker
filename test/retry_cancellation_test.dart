import "dart:async";
import "package:test/test.dart";
import "package:circuit_breaker/circuit_breaker.dart";

void main() {
  test("Retry loop is aborted immediately on top-level timeout", () async {
    final context = ResilienceContext();
    final resource = Resource(
      "test-service",
      config: ResourceConfig(
        timeout: Duration(milliseconds: 50),
        retry: RetryConfig(
          maxAttempts: 5,
          baseDelay: Duration(milliseconds: 10),
          enableJitter: false,
        ),
      ),
    );

    final op = Operation("op", resource);

    int attempts = 0;

    try {
      await context.executeCancelable<void>(op, (cancel) async {
        attempts++;
        final completer = Completer<void>();
        unawaited(
          cancel.future.then((_) {
            if (!completer.isCompleted) completer.complete();
          }),
        );
        await completer.future;
        throw Exception("should be cancelled");
      });
      fail("Should have timed out");
    } catch (e) {
      expect(e, isA<ResilienceTimeoutException>());
    }

    expect(attempts, equals(1));
  });
}
