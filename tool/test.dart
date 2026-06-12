import 'dart:io';

void main() async {
  print('Running tests via tool/test.dart...');
  final result = await Process.run('dart', ['test']);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  exit(result.exitCode);
}
