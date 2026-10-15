#!/bin/bash
# Minimal capture tool: managed single capture, or a continuous 5fps stream.
#
#   ./capture.sh capture [out.png]   link-managed single capture (default: capture.png)
#   ./capture.sh start               continuous 5fps stream to /dev/video10
#   ./capture.sh stop                stop the continuous stream
#   ./capture.sh status              stream and DisplayPort link state
#
# Needs: ffmpeg, imagemagick, python3-smbus2, v4l2loopback, ps176_link.py and capture.conf
# alongside this script, and membership of the i2c group.

DEVICE=/dev/video0
VIRT=/dev/video10
PIDFILE=/tmp/capture_stream.pid
DEFAULT_OUTPUT=capture.png
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Settings (capture.conf; environment variables override) ───
_conf_defaults() {
  I2C_BUS=6
  PS176_BASE=0x48
  LINK_TIMEOUT=15
  LINK_DOWN_TIMEOUT=15
  SETTLE_MS=1500
  CAPTURE_RETRIES=3
  POLL_MS=50
  LOCK_FILE=/tmp/capture.lock
}
_load_conf() {
  local keys="I2C_BUS PS176_BASE LINK_TIMEOUT LINK_DOWN_TIMEOUT SETTLE_MS CAPTURE_RETRIES POLL_MS LOCK_FILE"
  local k saved=()
  for k in $keys; do [ -n "${!k+x}" ] && saved+=("$k=${!k}"); done
  _conf_defaults
  [ -f "$SCRIPT_DIR/capture.conf" ] && source "$SCRIPT_DIR/capture.conf"
  for k in "${saved[@]}"; do declare -g "${k%%=*}=${k#*=}"; done
}
_load_conf
PS176_LINK="python3 $SCRIPT_DIR/ps176_link.py"
export I2C_BUS PS176_BASE LINK_TIMEOUT LINK_DOWN_TIMEOUT SETTLE_MS CAPTURE_RETRIES POLL_MS LOCK_FILE

info()  { echo "[INFO]  $1"; }
warn()  { echo "[WARN]  $1" >&2; }
error() { echo "[ERROR] $1" >&2; }
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

is_streaming() {
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

# 5fps ffmpeg stream /dev/video0 -> /dev/video10. 9>&- keeps the capture lock fd out of ffmpeg.
spawn_5fps_ffmpeg() {
  [ -e "$VIRT" ] || sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="capture" 2>/dev/null
  ffmpeg -f v4l2 -input_format yuyv422 -video_size 1920x1080 \
    -framerate 60 \
    -i "$DEVICE" \
    -vf "scale=1920:1080,format=yuv420p" \
    -r 5 \
    -f v4l2 "$VIRT" \
    -loglevel quiet 9>&- &
  echo $! > "$PIDFILE"
}

kill_stream() {
  if is_streaming; then
    local pid
    pid=$(cat "$PIDFILE")
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  fi
  rm -f "$PIDFILE"
}

# ─── start / stop / status ───
cmd_start() {
  if [ ! -e "$DEVICE" ]; then error "Capture device $DEVICE not found"; exit 1; fi
  if is_streaming; then warn "Stream already running (PID $(cat "$PIDFILE"))"; exit 1; fi
  info "Starting 5fps stream to $VIRT ..."
  spawn_5fps_ffmpeg
  sleep 2
  if ! is_streaming; then rm -f "$PIDFILE"; error "Stream failed to start"; exit 1; fi
  info "Stream running (PID $(cat "$PIDFILE")); read frames from $VIRT"
}

cmd_stop() {
  if ! is_streaming; then warn "No stream running"; rm -f "$PIDFILE"; return 0; fi
  local pid
  pid=$(cat "$PIDFILE")
  kill_stream
  info "Stream stopped (was PID $pid)"
}

cmd_status() {
  if is_streaming; then echo "stream: running (PID $(cat "$PIDFILE")) -> $VIRT"; else echo "stream: stopped"; fi
  echo "link:   $($PS176_LINK status)"
}

# ─── managed capture ───
MANAGED_STARTED=0

# Stop the stream only if this script started it; release the lock. Safe to call twice.
cleanup() {
  [ "$MANAGED_STARTED" = 1 ] && kill_stream
  MANAGED_STARTED=0
  exec 9>&-
}

# 0 if the image has real content (not uniform/black)
frame_ok() {
  local sd
  [ -s "$1" ] || return 1
  sd=$(convert "$1" -scale 5% -format "%[fx:standard_deviation]" info: 2>/dev/null) || return 1
  awk -v sd="$sd" 'BEGIN { exit !(sd > 0.01) }'
}

# start stream -> wait for PS176 link + valid video -> settle -> grab -> re-check link -> stop stream
cmd_capture() {
  local output=${1:-$DEFAULT_OUTPUT}
  local t0 attempt out rc res="" err="" hpd=0 stopped=0 was_running=0 retries=0

  if [ ! -e "$DEVICE" ]; then error "Capture device $DEVICE not found"; exit 1; fi
  trap 'cleanup; exit 130' INT TERM
  trap cleanup EXIT

  t0=$(now_ms)
  exec 9>"$LOCK_FILE"        # one capture at a time
  flock 9

  if is_streaming; then
    was_running=1
  else
    spawn_5fps_ffmpeg
    MANAGED_STARTED=1
  fi

  for (( attempt = 0; attempt <= CAPTURE_RETRIES; attempt++ )); do
    retries=$attempt
    out=$($PS176_LINK wait --timeout "$LINK_TIMEOUT" --poll-ms "$POLL_MS"); rc=$?
    if [ $rc -ne 0 ] && [ $hpd -eq 0 ]; then
      warn "Link not up after ${LINK_TIMEOUT}s - toggling DP_HPD"
      hpd=1
      $PS176_LINK toggle >/dev/null
      out=$($PS176_LINK wait --timeout "$LINK_TIMEOUT" --poll-ms "$POLL_MS"); rc=$?
    fi
    if [ $rc -ne 0 ]; then err="link did not come up"; break; fi
    res=$(echo "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("%dx%d" % (d["width"], d["height"]))')

    # let the MS2130 deliver fresh frames (an already-running stream doesn't need it)
    [ $was_running -eq 0 ] && sleep "$(awk -v ms="$SETTLE_MS" 'BEGIN { printf "%.3f", ms / 1000 }')"

    local cap_ok=1
    ffmpeg -f v4l2 -i "$VIRT" -vframes 1 -update 1 -y "$output" \
      -loglevel quiet 2>/dev/null 9>&- || cap_ok=0

    # a dropped link means the frame may be stale or partial
    if ! $PS176_LINK status >/dev/null; then
      err="link dropped during capture"
      warn "$err - retrying ($((attempt + 1))/$CAPTURE_RETRIES)"
      continue
    fi
    if [ $cap_ok -eq 0 ] || ! frame_ok "$output"; then
      err="blank or missing frame"
      warn "$err - retrying ($((attempt + 1))/$CAPTURE_RETRIES)"
      continue
    fi
    err=""
    break
  done

  if [ "$MANAGED_STARTED" = 1 ]; then
    stopped=1
    kill_stream
    MANAGED_STARTED=0
  fi
  local total=$(( $(now_ms) - t0 ))

  # wait for the link to drop so the next capture starts clean (lock still held)
  [ $stopped -eq 1 ] && $PS176_LINK wait-down --timeout "$LINK_DOWN_TIMEOUT" --poll-ms "$POLL_MS" >/dev/null
  cleanup

  if [ -n "$err" ]; then
    error "Capture failed: $err (${total}ms, retries=$retries)"
    exit 1
  fi
  info "Captured $output in ${total}ms (source ${res}, retries ${retries})"
}

usage() {
  cat <<EOF
Usage: $0 <command>
  capture [out.png]   link-managed single capture (default: $DEFAULT_OUTPUT)
  start               continuous 5fps stream to $VIRT
  stop                stop the continuous stream
  status              stream and DisplayPort link state
EOF
}

case "$1" in
  capture) cmd_capture "$2" ;;
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  status)  cmd_status ;;
  *)       usage; exit 1 ;;
esac
