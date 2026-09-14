#!/usr/bin/env python3
"""Runner script to record example/simulator.dart to a high-quality animated GIF."""

import os
import pty
import re
import select
import subprocess
import sys
import time

import cairo
import gi

gi.require_version('Pango', '1.0')
gi.require_version('PangoCairo', '1.0')
from gi.repository import Pango, PangoCairo


def render_frame_to_cairo(ansi_frame, ctx, surface, layout, width, height):
    # Outer dark background
    ctx.set_source_rgb(0.043, 0.059, 0.09)  # #0b0f17
    ctx.paint()

    # Window card
    margin_x = 12
    margin_y = 12
    card_w = width - 2 * margin_x
    card_h = height - 2 * margin_y
    radius = 8

    # Rounded card path
    ctx.new_sub_path()
    ctx.arc(margin_x + card_w - radius, margin_y + radius, radius, -1.57, 0)
    ctx.arc(
        margin_x + card_w - radius, margin_y + card_h - radius, radius, 0, 1.57
    )
    ctx.arc(margin_x + radius, margin_y + card_h - radius, radius, 1.57, 3.14)
    ctx.arc(margin_x + radius, margin_y + radius, radius, 3.14, 4.71)
    ctx.close_path()

    ctx.set_source_rgb(0.075, 0.098, 0.149)  # #131926
    ctx.fill_preserve()
    ctx.set_source_rgba(0.2, 0.25, 0.35, 0.6)
    ctx.set_line_width(1.0)
    ctx.stroke()

    # Window title bar dots
    dots = [
        (margin_x + 18, margin_y + 15, 0.937, 0.267, 0.267),  # Red #ef4444
        (margin_x + 34, margin_y + 15, 0.961, 0.620, 0.043),  # Yellow #f59e0b
        (margin_x + 50, margin_y + 15, 0.133, 0.773, 0.369),  # Green #22c55e
    ]
    for x, y, r, g, b in dots:
        ctx.arc(x, y, 4.5, 0, 6.28)
        ctx.set_source_rgb(r, g, b)
        ctx.fill()

    # Title bar text
    title_layout = PangoCairo.create_layout(ctx)
    title_desc = Pango.FontDescription('DejaVu Sans 9.5')
    title_desc.set_weight(Pango.Weight.BOLD)
    title_layout.set_font_description(title_desc)
    title_layout.set_markup(
        '<span foreground="#64748b">circuit_breaker — simulator.dart</span>', -1
    )
    ctx.move_to(margin_x + card_w / 2 - 115, margin_y + 9)
    PangoCairo.show_layout(ctx, title_layout)

    # Terminal text
    desc = Pango.FontDescription('DejaVu Sans Mono 9.5')
    layout.set_font_description(desc)

    lines = [
        l.replace('\r', '').replace('\x1b[K', '')
        for l in ansi_frame.strip().split('\n')
    ]

    parsed_lines = []
    for line in lines:
        line_esc = (
            line.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
        )

        # Map ANSI colors
        line_esc = line_esc.replace(
            '\x1b[32m', '<span foreground="#4ade80" weight="bold">'
        )
        line_esc = line_esc.replace(
            '\x1b[31m', '<span foreground="#f87171" weight="bold">'
        )
        line_esc = line_esc.replace(
            '\x1b[33m', '<span foreground="#facc15" weight="bold">'
        )
        line_esc = line_esc.replace('\x1b[0m', '</span>')

        # Semantic highlights
        if '=====================================' in line_esc:
            line_esc = f'<span foreground="#334155">{line_esc}</span>'
        elif '--- ' in line_esc and ' ---' in line_esc:
            line_esc = f'<span foreground="#38bdf8" weight="bold">{line_esc}</span>'
        elif 'Resilience Simulator Dashboard' in line_esc:
            line_esc = f'<span foreground="#60a5fa" weight="bold">{line_esc}</span>'
        elif line_esc.startswith('Criticality:'):
            line_esc = f'<span foreground="#94a3b8" weight="bold">{line_esc}</span>'
        elif line_esc.startswith('Status:'):
            line_esc = f'<span foreground="#f1f5f9" weight="bold">{line_esc}</span>'
        else:
            # Highlight specific tags in log lines
            line_esc = line_esc.replace(
                '[CB Tripped]',
                '<span foreground="#facc15" weight="bold">[CB Tripped]</span>',
            )
            line_esc = line_esc.replace(
                '[Throttled]',
                '<span foreground="#fb923c" weight="bold">[Throttled]</span>',
            )
            line_esc = line_esc.replace(
                '[Hedge]',
                '<span foreground="#38bdf8" weight="bold">[Hedge]</span>',
            )
            line_esc = line_esc.replace(
                '[Retry]',
                '<span foreground="#c084fc" weight="bold">[Retry]</span>',
            )
            line_esc = line_esc.replace(
                '[Timeout]',
                '<span foreground="#f87171" weight="bold">[Timeout]</span>',
            )
            line_esc = f'<span foreground="#cbd5e1">{line_esc}</span>'

        parsed_lines.append(line_esc)

    full_markup = '\n'.join(parsed_lines)
    layout.set_markup(full_markup, -1)

    ctx.move_to(margin_x + 16, margin_y + 36)
    PangoCairo.show_layout(ctx, layout)


def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    dart_bin = os.path.expanduser('~/.dvm/darts/3.11.0/bin/dart')
    output_gif = os.path.join(repo_root, 'doc', 'assets', 'simulator.gif')
    os.makedirs(os.path.dirname(output_gif), exist_ok=True)

    print(f'Starting simulator run to record to: {output_gif}')

    master, slave = pty.openpty()
    pid = os.fork()
    if pid == 0:
        os.close(master)
        os.dup2(slave, 0)
        os.dup2(slave, 1)
        os.dup2(slave, 2)
        os.close(slave)
        os.execv(dart_bin, ['dart', 'run', 'example/simulator.dart'])

    os.close(slave)

    buffer = ''
    frames = []
    t0 = time.time()

    # Timeline of actions to trigger all 4 requirements:
    # 1. Steady state initial baseline (0s - 2.5s)
    # 2. Failure breakdown: CB trips CLOSED -> OPEN, fast-rejecting (2.5s - 7.5s)
    # 3. Recovery: CB transitions HALF-OPEN -> CLOSED (7.5s - 9.5s)
    # 4. Overload & Adaptive Throttling: lower criticality shed, critical admitted (9.5s - 15.5s)
    # 5. Dynamic Hedging: tail latency mitigation (16.0s - 21.0s)
    # 6. Steady state loop-back (21.0s - 23.5s)
    # 7. Quit (24.0s)
    events = [
        (2.5, b'b', 'Trigger breakdown (CLOSED -> OPEN)'),
        (9.5, b'ccccccccccccccccffKKKK', 'Prep for Throttling (high CB thresh, lower K, 20% fail)'),
        (10.0, b's', 'Start traffic spike (Adaptive Throttling)'),
        (15.0, b'CCCCCCCCCCCCCCCCFFkkkk', 'Reset Throttling & CB thresh'),
        (16.0, b'Hllll', 'Enable Dynamic Hedging & latency bump'),
        (21.0, b'LLLLH', 'Reset latency & Hedging'),
        (23.5, b'q', 'Quit simulator'),
    ]

    event_idx = 0

    while True:
        now = time.time() - t0
        if event_idx < len(events) and now >= events[event_idx][0]:
            t, cmd, desc = events[event_idx]
            print(f'[{now:.1f}s] Action: {desc}')
            os.write(master, cmd)
            event_idx += 1
            if cmd == b'q':
                break

        r, _, _ = select.select([master], [], [], 0.05)
        if master in r:
            try:
                chunk = os.read(master, 8192).decode('utf-8', errors='ignore')
                buffer += chunk
                while '\x1b[u' in buffer:
                    idx = buffer.index('\x1b[u')
                    frame_raw = buffer[:idx]
                    buffer = buffer[idx + 2 :]
                    if '\x1b[0;0H' in frame_raw:
                        frame = frame_raw.split('\x1b[0;0H')[-1]
                        frames.append((now, frame))
            except OSError:
                break

    time.sleep(0.2)
    try:
        os.close(master)
    except OSError:
        pass

    print(f'Captured {len(frames)} raw frames over {time.time() - t0:.1f}s.')

    # Setup Cairo surface
    width = 780
    height = 780
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
    ctx = cairo.Context(surface)
    layout = PangoCairo.create_layout(ctx)

    # Encode with ffmpeg using palettegen for compact, clean GIF
    fps = 6
    ffmpeg_cmd = [
        'ffmpeg',
        '-y',
        '-f',
        'rawvideo',
        '-pix_fmt',
        'bgra',
        '-s',
        f'{width}x{height}',
        '-r',
        str(fps),
        '-i',
        '-',
        '-filter_complex',
        (
            'split[s0][s1];'
            '[s0]palettegen=max_colors=128:stats_mode=diff[p];'
            '[s1][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle'
        ),
        output_gif,
    ]

    print(f'Rendering and encoding {len(frames)} frames to {output_gif}...')
    proc = subprocess.Popen(
        ffmpeg_cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE
    )

    t_render = time.time()
    for _, frame_text in frames:
        render_frame_to_cairo(frame_text, ctx, surface, layout, width, height)
        proc.stdin.write(surface.get_data())

    proc.stdin.close()
    stderr = proc.stderr.read().decode('utf-8')
    proc.wait()

    if proc.returncode != 0:
        print('ffmpeg error:', stderr)
        sys.exit(1)

    file_size_mb = os.path.getsize(output_gif) / (1024 * 1024)
    print(
        f'Successfully generated {output_gif} ({file_size_mb:.2f} MB) in'
        f' {time.time() - t_render:.2f}s!'
    )


if __name__ == '__main__':
    main()
