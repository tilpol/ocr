#!/usr/bin/env python3
"""
Pi OCR HTTP Server
Receives capture+OCR requests from the Windows test tool over the network,
captures a frame via the HDMI capture pipeline, and returns OCR results as JSON.

Usage:
    python3 pi_server.py [--port 8080]

Endpoints:
    GET  /status   — stream/device status and PS176 link state
    POST /ocr      — capture frame + OCR regions, return results

capture_method: "managed" (default) | "loopback" | "ondemand" | "auto"
    managed — start the loopback stream, wait for the PS176 link, capture, stop the stream
              (settings in capture.conf; same sequence and lock as `stream.sh capture`)
"""

import http.server
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

import ps176_link

# ─── Configuration ────────────────────────────────────────────────────────────
HOST             = "0.0.0.0"
PORT             = 8080
CAPTURE_DEVICE   = "/dev/video0"
LOOPBACK_DEVICE  = "/dev/video10"
STREAM_PID_FILE  = "/tmp/capture_stream.pid"
CAPTURE_FILE     = "/tmp/pi_server_capture.png"
DEFAULT_METHOD   = "managed"
BLANK_STDDEV_MIN = 0.01     # frame check: normalised std-dev at 5% scale, below = uniform/black


# ─── Stream detection ─────────────────────────────────────────────────────────

def is_streaming():
    """Return True if the v4l2loopback stream started by stream.sh is running."""
    if not os.path.exists(STREAM_PID_FILE):
        return False
    try:
        with open(STREAM_PID_FILE) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)   # signal 0: check existence without sending a signal
        return True
    except (ValueError, OSError):
        return False


# ─── Frame capture ────────────────────────────────────────────────────────────

LOOPBACK_GRAB_CMD = [
    'ffmpeg', '-f', 'v4l2', '-i', LOOPBACK_DEVICE,
    '-vframes', '1', '-update', '1', '-y', CAPTURE_FILE,
    '-loglevel', 'quiet',
]

# Same ffmpeg command as `stream.sh start-5fps`
STREAM_CMD = [
    'ffmpeg', '-f', 'v4l2', '-input_format', 'yuyv422', '-video_size', '1920x1080',
    '-framerate', '60', '-i', CAPTURE_DEVICE,
    '-vf', 'scale=1920:1080,format=yuv420p', '-r', '5',
    '-f', 'v4l2', LOOPBACK_DEVICE, '-loglevel', 'quiet',
]


def frame_ok(path):
    """True if the file exists, is non-empty and is not a uniform/black image."""
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return False
    # -scale first: fx:standard_deviation takes ~8s on a full 1080p frame, ~0.2s at 5%
    r = subprocess.run(['convert', path, '-scale', '5%',
                        '-format', '%[fx:standard_deviation]', 'info:'],
                       capture_output=True, text=True)
    try:
        return r.returncode == 0 and float(r.stdout) > BLANK_STDDEV_MIN
    except ValueError:
        return False


def image_size(path):
    """Saved image size as 'WxH', or None."""
    r = subprocess.run(['identify', '-format', '%wx%h', path], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else None


def _grab_loopback():
    """Grab one frame from the loopback device. Returns True if ffmpeg succeeded."""
    return subprocess.run(LOOPBACK_GRAB_CMD, capture_output=True).returncode == 0


def _stop_stream(proc):
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


def capture_managed():
    """
    Link-managed capture (sequence from CAPTURE_ON_DEMAND.md; mirrors `stream.sh capture`):
    start stream -> wait for PS176 link + valid video -> settle -> grab -> re-check link -> stop.
    Caller must hold ps176_link.capture_lock().

    Returns a timings dict. Raises RuntimeError on failure.
    """
    t = {'link_ms': 0, 'settle_ms': 0, 'capture_ms': 0, 'total_ms': 0,
         'link_down_ms': 0, 'cycle_ms': 0, 'retries': 0,
         'hpd_toggle_used': False, 'source_resolution': None,
         'link_rate_gbps': None, 'lanes': None}
    t0 = time.monotonic()
    was_running = is_streaming()      # always-on stream: don't start/stop it, no settle needed
    proc = None
    err = 'capture failed'

    try:
        if not was_running:
            if not os.path.exists(LOOPBACK_DEVICE):
                subprocess.run(['sudo', 'modprobe', 'v4l2loopback', 'devices=1',
                                'video_nr=10', 'card_label=capture'], capture_output=True)
            proc = subprocess.Popen(STREAM_CMD, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL)

        for attempt in range(ps176_link.CAPTURE_RETRIES + 1):
            t['retries'] = attempt

            # wait for link (one HPD toggle on timeout)
            try:
                try:
                    info = ps176_link.wait_for_link()
                except ps176_link.LinkTimeout:
                    if t['hpd_toggle_used']:
                        raise
                    t['hpd_toggle_used'] = True
                    ps176_link.hpd_toggle()
                    info = ps176_link.wait_for_link()
            except ps176_link.LinkTimeout as e:
                err = f'link did not come up: {e}'
                break
            t['link_ms'] += info['link_ms']
            t['source_resolution'] = f"{info['width']}x{info['height']}"
            t['link_rate_gbps'] = info['rate_gbps']
            t['lanes'] = info['lanes']

            # settle so the MS2130 has fresh frames
            if not was_running:
                time.sleep(ps176_link.SETTLE_MS / 1000.0)
                t['settle_ms'] += ps176_link.SETTLE_MS

            # grab
            g0 = time.monotonic()
            grabbed = _grab_loopback()
            t['capture_ms'] = int((time.monotonic() - g0) * 1000)

            # link must still be up, else the frame may be stale/partial
            if ps176_link.link_dropped():
                err = 'link dropped during capture'
                continue
            if not grabbed or not frame_ok(CAPTURE_FILE):
                err = 'blank or missing frame'
                continue
            err = None
            break
    finally:
        if proc is not None:
            _stop_stream(proc)
        t['total_ms'] = int((time.monotonic() - t0) * 1000)
        # Wait for the link to drop so the next capture starts clean (lock still held).
        # Skipped when an always-on stream was left running.
        if proc is not None:
            try:
                t['link_down_ms'] = ps176_link.wait_for_link_down()
            except ps176_link.LinkTimeout:
                t['link_down_ms'] = int(ps176_link.LINK_DOWN_TIMEOUT * 1000)
        t['cycle_ms'] = t['total_ms'] + t['link_down_ms']

    if err:
        raise RuntimeError(f"Managed capture failed: {err} "
                           f"(retries={t['retries']}, {t['total_ms']}ms)")
    return t


def capture_frame(method=DEFAULT_METHOD):
    """
    Capture a single frame from the video pipeline.

    method: 'managed' | 'loopback' | 'ondemand' | 'auto'
        managed  — start stream, wait for PS176 link, capture, stop stream
        loopback — grab from an always-on stream (stream.sh start-5fps)
        ondemand — open /dev/video0 directly (fails silently without HDMI signal)
        auto     — loopback if an always-on stream is running, else managed

    Holds the shared capture lock (same file as stream.sh) for the whole capture.

    Returns (capture_file_path, timings_dict, method_used).
    timings_dict keys: link_ms, settle_ms, capture_ms, total_ms, retries, hpd_toggle_used,
    source_resolution, link_rate_gbps, lanes.  Raises RuntimeError on failure.
    """
    if method not in ('managed', 'loopback', 'ondemand', 'auto'):
        raise RuntimeError(f'Unknown capture_method: {method}')

    with ps176_link.capture_lock():
        # Checked after taking the lock so a shell capture in progress isn't mistaken
        # for an always-on stream.
        if method == 'auto':
            method = 'loopback' if is_streaming() else 'managed'

        if method == 'managed':
            return CAPTURE_FILE, capture_managed(), method

        start = time.time()
        if method == 'loopback':
            cmd = LOOPBACK_GRAB_CMD
        else:
            # On-demand: open capture device directly, skip 60 frames for warmup
            cmd = [
                'ffmpeg',
                '-f', 'v4l2', '-input_format', 'yuyv422',
                '-video_size', '1920x1080', '-framerate', '60',
                '-i', CAPTURE_DEVICE,
                '-vf', "select='gte(n,60)',scale=1920:1080,format=rgb24",
                '-vframes', '1', '-update', '1', '-y', CAPTURE_FILE,
                '-loglevel', 'quiet',
            ]

        result = subprocess.run(cmd, capture_output=True)
        elapsed_ms = int((time.time() - start) * 1000)

    if result.returncode != 0 or not os.path.exists(CAPTURE_FILE) or os.path.getsize(CAPTURE_FILE) == 0:
        raise RuntimeError(
            f"Capture failed (exit {result.returncode}): "
            + result.stderr.decode(errors='replace').strip()
        )

    timings = {'link_ms': 0, 'settle_ms': 0, 'capture_ms': elapsed_ms, 'total_ms': elapsed_ms,
               'link_down_ms': 0, 'cycle_ms': elapsed_ms, 'retries': 0, 'hpd_toggle_used': False, 'source_resolution': None,
               'link_rate_gbps': None, 'lanes': None}
    return CAPTURE_FILE, timings, method


# ─── OCR pipeline ─────────────────────────────────────────────────────────────

def ocr_region(image_path, region):
    """
    Preprocess a region of the capture image with ImageMagick then OCR with Tesseract.
    Mirrors the pipeline in ocr.sh exactly.

    region dict fields:
        label     — descriptive name (used for temp file naming only)
        crop      — ImageMagick geometry: WxH+X+Y
        shave     — edges to trim: NxN (or '0x0' / '' to skip)
        whitelist — allowed chars for Tesseract ('' = all)
        options   — list of strings: 'invert', 'scale2x', 'scale3x'

    Returns the OCR result string (stripped), or '' on any failure.
    """
    label     = region.get('label', 'region')
    crop      = region['crop']
    shave     = region.get('shave', '0x0')
    whitelist = region.get('whitelist', '')
    options   = region.get('options', [])

    safe_label = re.sub(r'[^a-zA-Z0-9_-]', '_', label)
    tmp_file   = f'/tmp/pi_server_ocr_{safe_label}.png'

    try:
        # ── ImageMagick preprocessing ────────────────────────────────────────
        cmd = ['convert', image_path, '-crop', crop, '+repage']

        if shave and shave != '0x0':
            cmd += ['-shave', shave]

        if 'scale3x' in options:
            cmd += ['-resize', '300%']
        elif 'scale2x' in options:
            cmd += ['-resize', '200%']

        cmd += ['-colorspace', 'Gray', '-normalize']

        if 'invert' in options:
            cmd += ['-negate']

        cmd += ['-threshold', '40%', tmp_file]

        proc = subprocess.run(cmd, capture_output=True)
        if proc.returncode != 0 or not os.path.exists(tmp_file) or os.path.getsize(tmp_file) == 0:
            return ''

        # ── Tesseract OCR ────────────────────────────────────────────────────
        tess_cmd = ['tesseract', tmp_file, 'stdout', '--psm', '7']
        if whitelist:
            tess_cmd += ['-c', f'tessedit_char_whitelist={whitelist}']

        tess = subprocess.run(tess_cmd, capture_output=True, text=True)
        value = tess.stdout.replace('\f', '').strip()
        return value

    finally:
        try:
            os.remove(tmp_file)
        except FileNotFoundError:
            pass


# ─── HTTP handler ─────────────────────────────────────────────────────────────

class OCRHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        ts = datetime.now().strftime('%H:%M:%S')
        print(f"[{ts}] {self.address_string()} — {fmt % args}")

    def send_json(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        """Handle CORS preflight."""
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def do_GET(self):
        if self.path == '/status':
            link = ps176_link.read_link()       # read-only I2C; never touches /dev/video0
            video = ps176_link.read_video(link)
            self.send_json(200, {
                'ok':            True,
                'streaming':     is_streaming(),
                'device_present': os.path.exists(CAPTURE_DEVICE),
                'capture_device': CAPTURE_DEVICE,
                'loopback_device': LOOPBACK_DEVICE,
                'ps176_present':  link['present'],
                'link_up':        link['up'],
                'source_resolution': (f"{video['h_active']}x{video['v_active']}"
                                      if video['valid'] else None),
                'link_rate_gbps': link['rate_gbps'] if link['up'] else None,
                'lanes':          link['lanes'] if link['up'] else None,
            })
        else:
            self.send_json(404, {'error': 'Not found'})

    def do_POST(self):
        if self.path != '/ocr':
            self.send_json(404, {'error': 'Not found'})
            return

        # ── Parse request body ───────────────────────────────────────────────
        try:
            length = int(self.headers.get('Content-Length', 0))
            body   = self.rfile.read(length)
            data   = json.loads(body)
        except (ValueError, json.JSONDecodeError) as e:
            self.send_json(400, {'error': f'Bad request: {e}'})
            return

        regions = data.get('regions', [])
        if not regions:
            self.send_json(400, {'error': 'No regions specified'})
            return

        capture_method = data.get('capture_method', DEFAULT_METHOD)

        # ── Capture frame ────────────────────────────────────────────────────
        try:
            image_path, timings, method_used = capture_frame(capture_method)
        except RuntimeError as e:
            self.send_json(500, {'success': False, 'error': str(e)})
            return

        # ── OCR each region ──────────────────────────────────────────────────
        results = []
        for region in regions:
            value = ocr_region(image_path, region)
            results.append({
                'label': region.get('label', ''),
                'value': value,
            })

        self.send_json(200, {
            'success':        True,
            'capture_ms':     timings['capture_ms'],
            'capture_method': method_used,
            'link_ms':        timings['link_ms'],
            'settle_ms':      timings['settle_ms'],
            'total_ms':       timings['total_ms'],
            'link_down_ms':   timings['link_down_ms'],
            'cycle_ms':       timings['cycle_ms'],
            'retries':        timings['retries'],
            'hpd_toggle_used': timings['hpd_toggle_used'],
            'source_resolution': timings['source_resolution'],
            'image_resolution': image_size(image_path),
            'timestamp':      datetime.now(timezone.utc).isoformat(),
            'results':        results,
        })


# ─── Entry point ──────────────────────────────────────────────────────────────

def main():
    port = PORT
    args = sys.argv[1:]
    for i, arg in enumerate(args):
        if arg == '--port' and i + 1 < len(args):
            try:
                port = int(args[i + 1])
            except ValueError:
                print(f"ERROR: Invalid port: {args[i + 1]}", file=sys.stderr)
                sys.exit(1)

    server = http.server.HTTPServer((HOST, port), OCRHandler)

    print(f"Pi OCR Server — listening on {HOST}:{port}")
    print(f"  Capture device:  {CAPTURE_DEVICE}")
    print(f"  Loopback device: {LOOPBACK_DEVICE}")
    print(f"  Stream PID file: {STREAM_PID_FILE}")
    print(f"  Default capture: {DEFAULT_METHOD} (lock {ps176_link.LOCK_FILE}, I2C bus {ps176_link.I2C_BUS})")
    print()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.shutdown()


if __name__ == '__main__':
    main()
