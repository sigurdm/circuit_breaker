import 'package:circuit_breaker/circuit_breaker.dart';

void main() async {
  final context = ResilienceContext();

  // 1. Configure a resource with inline parameters and bind directly to context
  final usersApi = context.resource(
    'users-api',
    circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 3),
    retry: RetryConfig(maxAttempts: 3),
  );

  // 2. Execute directly on the resource — no Operation needed!
  try {
    final user = await usersApi.execute(() => fetchUser(123));
    print('User from direct resource execution: $user');
  } catch (e) {
    print('Operation failed: $e');
  }

  // 3. For fine-grained endpoints, create an Operation with overrides:
  final getUserOp = usersApi.operation(
    'getUser',
    hedgingOverride: HedgingConfig(
      enabled: true,
      delay: const Duration(milliseconds: 100),
    ),
  );

  try {
    final user = await context.execute(getUserOp, () => fetchUser(456));
    print('User from operation execution: $user');
  } catch (e) {
    print('Operation failed or was throttled: $e');
  }
}

Future<String> fetchUser(int id) async => 'user_$id';
