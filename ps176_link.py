#!/usr/bin/env python3
"""
PS176 link status for link-managed capture.

Reads the PS176 (DP -> HDMI) over I2C to tell whether the DisplayPort link is up
and whether a valid video timing is present. Standalone: only needs smbus2.
Never touches the PS8652 splitter or /dev/video0.

CLI:
    python3 ps176_link.py status            one-line state, exit 0 = link up
    python3 ps176_link.py video             JSON video info, exit 0 = valid
    python3 ps176_link.py wait [--timeout N]  wait for link+video, JSON timings, exit 0 on success
    python3 ps176_link.py wait-down [--timeout N]  wait for the link to drop, JSON {down_ms}, exit 0 on success
    python3 ps176_link.py toggle            DP_HPD low/high pulse (recovery only)
"""

import argparse
import contextlib
import fcntl
import json
import os
import sys
import time

# ─── Settings (capture.conf, overridden by environment) ──────────────────────
_CONF_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'capture.conf')
_DEFAULTS = {
    'CAPTURE_MODE':    'managed',
    'I2C_BUS':         '6',
    'PS176_BASE':      '0x48',
    'LINK_TIMEOUT':    '15',
    'LINK_DOWN_TIMEOUT': '15',
    'SETTLE_MS':       '1000',
    'CAPTURE_RETRIES': '3',
    'POLL_MS':         '50',
    'LOCK_FILE':       '/tmp/capture.lock',
}


def _load_conf():
    conf = dict(_DEFAULTS)
    try:
        with open(_CONF_FILE) as f:
            for line in f:
                line = line.split('#', 1)[0].strip()
                if '=' in line:
                    k, v = line.split('=', 1)
                    conf[k.strip()] = v.strip()
    except OSError:
        pass
    for k in conf:
        if k in os.environ:
            conf[k] = os.environ[k]
    return conf


_CONF = _load_conf()
CAPTURE_MODE    = _CONF['CAPTURE_MODE']
I2C_BUS         = int(_CONF['I2C_BUS'], 0)
PS176_BASE      = int(_CONF['PS176_BASE'], 0)
LINK_TIMEOUT    = float(_CONF['LINK_TIMEOUT'])
LINK_DOWN_TIMEOUT = float(_CONF['LINK_DOWN_TIMEOUT'])
SETTLE_MS       = int(_CONF['SETTLE_MS'])
CAPTURE_RETRIES = int(_CONF['CAPTURE_RETRIES'])
POLL_MS         = int(_CONF['POLL_MS'])
LOCK_FILE       = _CONF['LOCK_FILE']

PAGE_MSA  = PS176_BASE          # 0x48 main stream attributes
PAGE_DPCD = PS176_BASE + 1      # 0x49 DPCD mirror
PAGE_HPD  = PS176_BASE + 2      # 0x4A DP_HPD control
HPD_REG   = 0xA1                # bit 7 = DP_HPD output

LINK_RATES = {0x06: 1.62, 0x0A: 2.7, 0x14: 5.4, 0x1E: 8.1}
DPCD_OFFS  = (0x02, 0x20, 0x21, 0x32, 0x33, 0x34, 0x35)


class LinkTimeout(Exception):
    pass


# ─── I2C access ──────────────────────────────────────────────────────────────
_bus = None


def _smbus():
    """Lazily open the I2C bus. Returns None if unavailable (treated as 'down')."""
    global _bus
    if _bus is None:
        try:
            import smbus2
            _bus = smbus2.SMBus(I2C_BUS)
        except Exception:
            return None
    return _bus


def _read(addr, reg):
    bus = _smbus()
    if bus is None:
        raise OSError('I2C bus unavailable')
    return bus.read_byte_data(addr, reg)


def _write(addr, reg, val):
    bus = _smbus()
    if bus is None:
        raise OSError('I2C bus unavailable')
    bus.write_byte_data(addr, reg, val)


def _le(addr, off, n):
    return int.from_bytes(bytes(_read(addr, off + i) for i in range(n)), 'little')


# ─── Link / video state ──────────────────────────────────────────────────────

def read_link():
    """
    Link state from the PS176 DPCD mirror (page 0x49).
    Returns dict: present, up, rate_gbps, lanes, lane_status, aligned, sync, caps.
    A PS176 that does not answer (asleep / resetting) gives present=False, up=False.
    """
    down = {'present': False, 'up': False, 'rate_gbps': None, 'lanes': 0,
            'lane_status': [], 'aligned': False, 'sync': False, 'caps': 0}
    try:
        r = {o: _read(PAGE_DPCD, o) for o in DPCD_OFFS}
    except OSError:
        return down

    n = r[0x21] & 0x1F
    status = [r[0x32] & 0xF, r[0x32] >> 4, r[0x33] & 0xF, r[0x33] >> 4][:max(n, 1)]
    aligned = bool(r[0x34] & 1)
    sync = bool(r[0x35] & 1)
    up = (r[0x20] != 0 and n in (1, 2, 4)
          and all((x & 7) == 7 for x in status) and aligned and sync)
    return {'present': True, 'up': up, 'rate_gbps': LINK_RATES.get(r[0x20]),
            'lanes': n, 'lane_status': status, 'aligned': aligned, 'sync': sync,
            'caps': r[0x02] & 0x1F}


def read_video(link=None):
    """
    Source video timing from page 0x48. Registers hold stale values when no stream is
    present, so 'valid' is only True while the link is up.
    Returns dict: h_active, v_active, refresh, valid.
    """
    link = link or read_link()
    out = {'h_active': 0, 'v_active': 0, 'refresh': None, 'valid': False}
    if not link['up']:
        return out
    try:
        h_total  = _le(PAGE_MSA, 0x09, 2)
        h_active = _le(PAGE_MSA, 0x0D, 2)
        v_total  = _le(PAGE_MSA, 0x0F, 2)
        v_active = _le(PAGE_MSA, 0x13, 2)
        mvid     = _le(PAGE_MSA, 0x2D, 3)
        nvid     = _le(PAGE_MSA, 0x30, 3)
    except OSError:
        return out

    out['h_active'], out['v_active'] = h_active, v_active
    if mvid and nvid and link['rate_gbps'] and h_total and v_total:
        pclk_mhz = mvid / nvid * (link['rate_gbps'] * 100)    # 8b/10b symbol clock
        out['refresh'] = round(pclk_mhz * 1e6 / (h_total * v_total), 2)
    out['valid'] = bool(mvid and 0 < h_active < h_total and 0 < v_active < v_total)
    return out


def link_ready():
    """(link, video) with video valid only if the link is up. 'ready' = both good."""
    link = read_link()
    video = read_video(link)
    return link, video


def link_dropped():
    """True if the link is not up right now (used to check a frame grab was clean)."""
    return not read_link()['up']


def wait_for_link(timeout=None, poll_ms=None):
    """
    Poll until link_up AND video_valid. Returns a timings dict:
        link_ms, rate_gbps, lanes, width, height, refresh
    Raises LinkTimeout after `timeout` seconds.
    """
    timeout = LINK_TIMEOUT if timeout is None else timeout
    poll = (POLL_MS if poll_ms is None else poll_ms) / 1000.0
    start = time.monotonic()
    while True:
        link, video = link_ready()
        if link['up'] and video['valid']:
            return {
                'link_ms':   int((time.monotonic() - start) * 1000),
                'rate_gbps': link['rate_gbps'],
                'lanes':     link['lanes'],
                'width':     video['h_active'],
                'height':    video['v_active'],
                'refresh':   video['refresh'],
            }
        if time.monotonic() - start >= timeout:
            raise LinkTimeout(f'link not up after {timeout:g}s '
                              f'(present={link["present"]} up={link["up"]} '
                              f'video_valid={video["valid"]})')
        time.sleep(poll)


def wait_for_link_down(timeout=None, poll_ms=None):
    """
    Poll until the link is no longer up (PS176 asleep/not answering also counts).
    Call right after the stream is stopped. Returns elapsed ms; raises LinkTimeout.
    """
    timeout = LINK_DOWN_TIMEOUT if timeout is None else timeout
    poll = (POLL_MS if poll_ms is None else poll_ms) / 1000.0
    start = time.monotonic()
    while read_link()['up']:
        if time.monotonic() - start >= timeout:
            raise LinkTimeout(f'link still up {timeout:g}s after stream stop')
        time.sleep(poll)
    return int((time.monotonic() - start) * 1000)


def hpd_toggle(low_ms=100):
    """
    Pulse the PS176 DP_HPD output low then high so the PS8652 retrains TX1.
    Only bit 7 of page 0x4A reg 0xA1 is changed. Bit 7 is always restored, even on error.
    Returns True on success.
    """
    try:
        orig = _read(PAGE_HPD, HPD_REG)
    except OSError:
        return False
    ok = False
    try:
        _write(PAGE_HPD, HPD_REG, orig & 0x7F)
        time.sleep(low_ms / 1000.0)
        ok = True
    except OSError:
        pass
    finally:
        for _ in range(3):
            try:
                _write(PAGE_HPD, HPD_REG, orig | 0x80)
                after = _read(PAGE_HPD, HPD_REG)
                if after & 0x80:
                    break
            except OSError:
                time.sleep(0.05)
        else:
            ok = False
    return ok


# ─── Cross-process capture lock (shared with stream.sh: flock on LOCK_FILE) ──

@contextlib.contextmanager
def capture_lock():
    fd = os.open(LOCK_FILE, os.O_CREAT | os.O_RDWR, 0o666)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)        # closing releases the flock


# ─── CLI ─────────────────────────────────────────────────────────────────────

def describe(link):
    if not link['present']:
        return 'PS176 not answering'
    rate = f"{link['rate_gbps']}G" if link['rate_gbps'] else 'rate=?'
    st = '/'.join(f'{x:x}' for x in link['lane_status'])
    return (f"{'UP' if link['up'] else 'DOWN'} {rate} x{link['lanes']} st={st} "
            f"aligned={int(link['aligned'])} sync={int(link['sync'])} caps=x{link['caps']}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[1])
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('status')
    sub.add_parser('video')
    w = sub.add_parser('wait')
    w.add_argument('--timeout', type=float, default=LINK_TIMEOUT)
    w.add_argument('--poll-ms', type=int, default=POLL_MS)
    wd = sub.add_parser('wait-down')
    wd.add_argument('--timeout', type=float, default=LINK_DOWN_TIMEOUT)
    wd.add_argument('--poll-ms', type=int, default=POLL_MS)
    sub.add_parser('toggle')
    a = ap.parse_args()

    if a.cmd == 'status':
        link = read_link()
        print(describe(link))
        return 0 if link['up'] else 1

    if a.cmd == 'video':
        video = read_video()
        print(json.dumps(video))
        return 0 if video['valid'] else 1

    if a.cmd == 'wait':
        try:
            print(json.dumps(wait_for_link(a.timeout, a.poll_ms)))
            return 0
        except LinkTimeout as e:
            print(json.dumps({'error': str(e)}))
            return 1

    if a.cmd == 'wait-down':
        try:
            print(json.dumps({'down_ms': wait_for_link_down(a.timeout, a.poll_ms)}))
            return 0
        except LinkTimeout as e:
            print(json.dumps({'down_ms': int(a.timeout * 1000), 'error': str(e)}))
            return 1

    if a.cmd == 'toggle':
        ok = hpd_toggle()
        print(json.dumps({'ok': ok}))
        return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
