import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Records `pkgs/circuit_breaker/example/simulator.dart` to an animated GIF at
/// `doc/assets/simulator.gif`.
void main() async {
  final repoRoot = Directory.current.path;
  final outputGif = '$repoRoot/doc/assets/simulator.gif';
  Directory('$repoRoot/doc/assets').createSync(recursive: true);

  print('Starting simulator run to record to: $outputGif');

  final proc = await Process.start(Platform.resolvedExecutable, [
    'run',
    'pkgs/circuit_breaker/example/simulator.dart',
  ], workingDirectory: repoRoot);

  final frames = <(double, String)>[];
  var buffer = '';
  final stopwatch = Stopwatch()..start();

  final sub = proc.stdout.transform(utf8.decoder).listen((chunk) {
    buffer += chunk;
    while (buffer.contains('\x1B[u')) {
      final idx = buffer.indexOf('\x1B[u');
      final frameRaw = buffer.substring(0, idx);
      buffer = buffer.substring(idx + 2);
      if (frameRaw.contains('\x1B[0;0H')) {
        final frame = frameRaw.split('\x1B[0;0H').last;
        final elapsed = stopwatch.elapsedMilliseconds / 1000.0;
        frames.add((elapsed, frame));
      }
    }
  });

  // Timeline of simulator actions:
  // 1. Steady state initial baseline (0s - 2.5s)
  // 2. Failure breakdown: CB trips CLOSED -> OPEN (2.5s - 7.5s)
  // 3. Recovery: CB transitions HALF-OPEN -> CLOSED (7.5s - 9.5s)
  // 4. Overload & Adaptive Throttling: sheddable shed, critical admitted (9.5s - 15.5s)
  // 5. Dynamic Hedging: tail latency mitigation (16.0s - 21.0s)
  // 6. Steady state loop-back (21.0s - 23.5s)
  // 7. Quit (23.5s)
  final events = [
    (2.5, 'b', 'Trigger breakdown (CLOSED -> OPEN)'),
    (
      9.5,
      'ccccccccccccccccffKKKK',
      'Prep for Throttling (high CB thresh, lower K, 20% fail)',
    ),
    (10.0, 's', 'Start traffic spike (Adaptive Throttling)'),
    (15.0, 'CCCCCCCCCCCCCCCCFFkkkk', 'Reset Throttling & CB thresh'),
    (16.0, 'Hllll', 'Enable Dynamic Hedging & latency bump'),
    (21.0, 'LLLLH', 'Reset latency & Hedging'),
    (23.5, 'q', 'Quit simulator'),
  ];

  for (final (t, cmd, desc) in events) {
    final now = stopwatch.elapsedMilliseconds / 1000.0;
    if (t > now) {
      await Future<void>.delayed(
        Duration(milliseconds: ((t - now) * 1000).round()),
      );
    }
    final currentSec = stopwatch.elapsedMilliseconds / 1000.0;
    print('[${currentSec.toStringAsFixed(1)}s] Action: $desc');
    proc.stdin.write(cmd);
  }

  await proc.exitCode;
  await sub.cancel();

  print(
    'Captured ${frames.length} raw frames over ${(stopwatch.elapsedMilliseconds / 1000.0).toStringAsFixed(1)}s.',
  );

  if (frames.isEmpty) {
    stderr.writeln('Error: No frames were captured from the simulator.');
    exit(1);
  }

  final tempDir = Directory.systemTemp.createTempSync('sim_frames_');
  try {
    print('Generating SVG frames in ${tempDir.path}...');
    for (var i = 0; i < frames.length; i++) {
      final svgContent = renderFrameToSvg(frames[i].$2);
      final framePath =
          '${tempDir.path}/frame_${(i + 1).toString().padLeft(4, '0')}.svg';
      File(framePath).writeAsStringSync(svgContent);
    }

    const fps = 6;
    print('Encoding animated GIF with ffmpeg...');
    final ffmpegResult = await Process.run('ffmpeg', [
      '-y',
      '-r',
      '$fps',
      '-i',
      '${tempDir.path}/frame_%04d.svg',
      '-filter_complex',
      'split[s0][s1];[s0]palettegen=max_colors=128:stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle',
      outputGif,
    ]);

    if (ffmpegResult.exitCode != 0) {
      stderr.writeln('ffmpeg error: ${ffmpegResult.stderr}');
      exit(1);
    }

    final fileSizeMb = File(outputGif).lengthSync() / (1024 * 1024);
    print(
      'Successfully generated $outputGif (${fileSizeMb.toStringAsFixed(2)} MB)!',
    );
  } finally {
    tempDir.deleteSync(recursive: true);
  }
}

String _escapeXml(String text) {
  return text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

String renderFrameToSvg(String ansiFrame) {
  const width = 780;
  const height = 780;
  const marginX = 12;
  const marginY = 12;
  const cardW = width - 2 * marginX;
  const cardH = height - 2 * marginY;
  const textX = marginX + 16;
  const textY = marginY + 48;
  const lineHeight = 17.0;

  final lines = ansiFrame
      .replaceAll('\r', '')
      .replaceAll('\x1B[K', '')
      .trim()
      .split('\n');

  final tspans = StringBuffer();

  for (var i = 0; i < lines.length; i++) {
    final rawLine = lines[i];
    final dy = i == 0 ? 0.0 : lineHeight;
    final parsedContent = _parseAnsiLine(rawLine);
    tspans.writeln(
      '    <tspan x="$textX" dy="${dy.toStringAsFixed(1)}">$parsedContent</tspan>',
    );
  }

  return '''
<svg width="$width" height="$height" xmlns="http://www.w3.org/2000/svg">
  <rect width="$width" height="$height" fill="#0b0f17"/>
  <rect x="$marginX" y="$marginY" width="$cardW" height="$cardH" rx="8" ry="8" fill="#131926" stroke="#334059" stroke-width="1"/>
  <circle cx="${marginX + 18}" cy="${marginY + 15}" r="4.5" fill="#ef4444"/>
  <circle cx="${marginX + 34}" cy="${marginY + 15}" r="4.5" fill="#f59e0b"/>
  <circle cx="${marginX + 50}" cy="${marginY + 15}" r="4.5" fill="#22c55e"/>
  <text x="${width / 2}" y="${marginY + 19}" text-anchor="middle" font-family="DejaVu Sans, sans-serif" font-size="13" font-weight="bold" fill="#64748b">circuit_breaker — simulator.dart</text>
  <text x="$textX" y="$textY" font-family="'DejaVu Sans Mono', monospace" font-size="12.5" xml:space="preserve" fill="#cbd5e1">
$tspans  </text>
</svg>
''';
}

String _parseAnsiLine(String line) {
  if (line.contains('=====================================')) {
    return '<tspan fill="#334155">${_escapeXml(line)}</tspan>';
  }
  if (line.contains('--- ') && line.contains(' ---')) {
    return '<tspan fill="#38bdf8" font-weight="bold">${_escapeXml(line)}</tspan>';
  }
  if (line.contains('Resilience Simulator Dashboard')) {
    return '<tspan fill="#60a5fa" font-weight="bold">${_escapeXml(line)}</tspan>';
  }
  if (line.startsWith('Criticality:')) {
    return '<tspan fill="#94a3b8" font-weight="bold">${_escapeXml(line)}</tspan>';
  }
  if (line.startsWith('Status:')) {
    return '<tspan fill="#f1f5f9" font-weight="bold">${_escapeXml(line)}</tspan>';
  }

  // Parse ANSI color escape codes into tspans
  final pattern = RegExp(r'(\x1B\[[0-9;]*m)');
  final parts = line.split(pattern);
  final matches = pattern.allMatches(line).toList();

  final buf = StringBuffer();
  String? currentFill;
  bool isBold = false;

  void openStyle(String fill, bool bold) {
    currentFill = fill;
    isBold = bold;
    final weight = isBold ? ' font-weight="bold"' : '';
    buf.write('<tspan fill="$currentFill"$weight>');
  }

  void closeStyle() {
    if (currentFill != null) {
      buf.write('</tspan>');
      currentFill = null;
      isBold = false;
    }
  }

  for (var i = 0; i < parts.length; i++) {
    var text = _escapeXml(parts[i]);

    // Apply semantic tag highlights when in default color
    if (currentFill == null) {
      text = text
          .replaceAll(
            '[CB Tripped]',
            '<tspan fill="#facc15" font-weight="bold">[CB Tripped]</tspan>',
          )
          .replaceAll(
            '[Throttled]',
            '<tspan fill="#fb923c" font-weight="bold">[Throttled]</tspan>',
          )
          .replaceAll(
            '[Hedge]',
            '<tspan fill="#38bdf8" font-weight="bold">[Hedge]</tspan>',
          )
          .replaceAll(
            '[Retry]',
            '<tspan fill="#c084fc" font-weight="bold">[Retry]</tspan>',
          )
          .replaceAll(
            '[Timeout]',
            '<tspan fill="#f87171" font-weight="bold">[Timeout]</tspan>',
          );
    }

    buf.write(text);

    if (i < matches.length) {
      final code = matches[i].group(1);
      closeStyle();
      switch (code) {
        case '\x1B[32m':
          openStyle('#4ade80', true);
        case '\x1B[31m':
          openStyle('#f87171', true);
        case '\x1B[33m':
          openStyle('#facc15', true);
        case '\x1B[0m':
          // Reset: already closed
          break;
        default:
          break;
      }
    }
  }

  closeStyle();
  return buf.toString();
}
