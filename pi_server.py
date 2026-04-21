#!/usr/bin/env python3
"""
Pi OCR HTTP Server
Receives capture+OCR requests from the Windows test tool over the network,
captures a frame via the HDMI capture pipeline, and returns OCR results as JSON.

Usage:
    python3 pi_server.py [--port 8080]

Endpoints:
    GET  /status   — stream/device status
    POST /ocr      — capture frame + OCR regions, return results
"""

import http.server
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

# ─── Configuration ────────────────────────────────────────────────────────────
HOST             = "0.0.0.0"
PORT             = 8080
CAPTURE_DEVICE   = "/dev/video0"
LOOPBACK_DEVICE  = "/dev/video10"
STREAM_PID_FILE  = "/tmp/capture_stream.pid"
CAPTURE_FILE     = "/tmp/pi_server_capture.png"


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

def capture_frame(method='auto'):
    """
    Capture a single frame from the video pipeline.

    method: 'loopback' | 'ondemand' | 'auto'
        auto — uses loopback if the stream is running, else on-demand.

    Returns (capture_file_path, elapsed_ms, method_used).
    Raises RuntimeError on failure.
    """
    if method == 'auto':
        method = 'loopback' if is_streaming() else 'ondemand'

    start = time.time()

    if method == 'loopback':
        cmd = [
            'ffmpeg', '-f', 'v4l2', '-i', LOOPBACK_DEVICE,
            '-vframes', '1', '-update', '1', '-y', CAPTURE_FILE,
            '-loglevel', 'quiet',
        ]
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

    return CAPTURE_FILE, elapsed_ms, method


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
            self.send_json(200, {
                'ok':            True,
                'streaming':     is_streaming(),
                'device_present': os.path.exists(CAPTURE_DEVICE),
                'capture_device': CAPTURE_DEVICE,
                'loopback_device': LOOPBACK_DEVICE,
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

        capture_method = data.get('capture_method', 'auto')

        # ── Capture frame ────────────────────────────────────────────────────
        try:
            image_path, capture_ms, method_used = capture_frame(capture_method)
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
            'capture_ms':     capture_ms,
            'capture_method': method_used,
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
    print()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.shutdown()


if __name__ == '__main__':
    main()
