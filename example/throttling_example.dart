import 'package:circuit_breaker/circuit_breaker.dart';

void main() async {
  final context = ResilienceContext();
  final resource = Resource('my-resource');
  final operation = Operation('my-operation', resource);

  try {
    await context.execute(operation, () async {
      // Perform mock call
      return 'data';
    });
  } on ThrottledException catch (e) {
    print('Request was throttled: ${e.message}');
    // Fallback or wait and retry
  }
}
