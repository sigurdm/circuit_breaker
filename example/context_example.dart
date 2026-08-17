import 'package:circuit_breaker/circuit_breaker.dart';

void main() async {
  final context = ResilienceContext();

  final usersApi = Resource(
    'users-api',
    config: ResourceConfig(
      circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 3),
    ),
  );

  final getUserOp = Operation('getUser', usersApi);

  // Execute operation
  try {
    final user = await context.execute(getUserOp, () async {
      return await fetchUser(123);
    });
    print('User: $user');
  } catch (e) {
    print('Operation failed or was throttled: $e');
  }
}

Future<String> fetchUser(int id) async => 'user_$id';
