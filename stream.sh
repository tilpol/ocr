#!/bin/bash

# ─── Configuration ────────────────────────────────────────
DEVICE=/dev/video0
VIRT=/dev/video10
PIDFILE=/tmp/capture_stream.pid
DEFAULT_OUTPUT=capture.png
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Capture settings (capture.conf; environment variables override) ───
# Defaults here match capture.conf so the script still works without it.
_conf_defaults() {
  CAPTURE_MODE=managed
  I2C_BUS=6
  PS176_BASE=0x48
  LINK_TIMEOUT=15
  LINK_DOWN_TIMEOUT=15
  SETTLE_MS=1000
  CAPTURE_RETRIES=3
  POLL_MS=50
  LOCK_FILE=/tmp/capture.lock
}
_load_conf() {
  local keys="CAPTURE_MODE I2C_BUS PS176_BASE LINK_TIMEOUT SETTLE_MS CAPTURE_RETRIES POLL_MS LOCK_FILE LINK_DOWN_TIMEOUT"
  local k saved=()
  # 1. remember env overrides (before defaults/file overwrite them)
  for k in $keys; do [ -n "${!k+x}" ] && saved+=("$k=${!k}"); done
  # 2. defaults, then capture.conf
  _conf_defaults
  [ -f "$SCRIPT_DIR/capture.conf" ] && source "$SCRIPT_DIR/capture.conf"
  # 3. re-apply env overrides
  for k in "${saved[@]}"; do declare -g "${k%%=*}=${k#*=}"; done
}
_load_conf
PS176_LINK="python3 $SCRIPT_DIR/ps176_link.py"
export CAPTURE_MODE I2C_BUS PS176_BASE LINK_TIMEOUT LINK_DOWN_TIMEOUT SETTLE_MS CAPTURE_RETRIES POLL_MS LOCK_FILE

# ─── Colours for output ───────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Colour

# ─── Helper functions ─────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

check_device() {
  if [ ! -e "$DEVICE" ]; then
    error "Capture device $DEVICE not found"
    exit 1
  fi
}

is_streaming() {
  [ -f "$PIDFILE" ] && kill -0 $(cat "$PIDFILE") 2>/dev/null
}

show_cpu() {
  local pid=$1
  local label=$2
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    local cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
    local mem=$(ps -p "$pid" -o %mem= 2>/dev/null | tr -d ' ')
    local rss=$(ps -p "$pid" -o rss=  2>/dev/null | tr -d ' ')
    local vsz=$(ps -p "$pid" -o vsz=  2>/dev/null | tr -d ' ')
    local rss_mb=$(( rss / 1024 ))
    local vsz_mb=$(( vsz / 1024 ))

    # Get total system RAM in MB
    local total_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)

    echo -e "  ${CYAN}$label${NC}"
    echo -e "    CPU:           ${cpu}%"
    echo -e "    RAM (RSS):     ${rss_mb}MB of ${total_mb}MB total (${mem}%)"
    echo -e "    Virtual (VSZ): ${vsz_mb}MB"
  fi
}

show_system_mem() {
  local total=$(awk '/MemTotal/  {printf "%d", $2/1024}' /proc/meminfo)
  local free=$(awk '/MemFree/   {printf "%d", $2/1024}' /proc/meminfo)
  local avail=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
  local used=$(( total - avail ))
  local cached=$(awk '/^Cached/  {printf "%d", $2/1024}' /proc/meminfo)
  local buffers=$(awk '/^Buffers/ {printf "%d", $2/1024}' /proc/meminfo)
  local pct=$(( used * 100 / total ))

  echo -e "  ${CYAN}System Memory${NC}"
  echo -e "    Total:     ${total}MB"
  echo -e "    Used:      ${used}MB (${pct}%)"
  echo -e "    Available: ${avail}MB"
  echo -e "    Cached:    ${cached}MB"
  echo -e "    Buffers:   ${buffers}MB"
}

# ─── Stop any running stream ──────────────────────────────
stop_stream() {
  if is_streaming; then
    local pid=$(cat "$PIDFILE")
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -f "$PIDFILE"
    success "Stream stopped (was PID $pid)"
  else
    warn "No stream currently running"
  fi
}

# ─── Method 1: loopback at 60fps (original) ───────────────
start_loopback_60fps() {
  check_device
  if is_streaming; then
    warn "Stream already running — stop it first"
    return 1
  fi
  info "Starting loopback stream at 60fps (high quality, high CPU)..."
  sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="capture" 2>/dev/null
  ffmpeg -f v4l2 -input_format yuyv422 -video_size 1920x1080 \
    -framerate 60 \
    -i "$DEVICE" \
    -vf "scale=1920:1080,format=yuv420p" \
    -f v4l2 "$VIRT" \
    -loglevel quiet &
  echo $! > "$PIDFILE"
  sleep 2
  success "Loopback 60fps started (PID $(cat $PIDFILE))"
  info "Capture with: $0 capture-loopback"
}

# ─── Method 2: loopback at 5fps (reduced CPU) ─────────────
# Shared ffmpeg launch (no settle delay) — used by start-5fps and managed capture.
# Only calls modprobe (sudo) if the loopback device is missing.
spawn_5fps_ffmpeg() {
  [ -e "$VIRT" ] || sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="capture" 2>/dev/null
  ffmpeg -f v4l2 -input_format yuyv422 -video_size 1920x1080 \
    -framerate 60 \
    -i "$DEVICE" \
    -vf "scale=1920:1080,format=yuv420p" \
    -r 5 \
    -f v4l2 "$VIRT" \
    -loglevel quiet 9>&- &      # 9>&-: don't leak the capture lock fd into ffmpeg
  echo $! > "$PIDFILE"
}

start_loopback_5fps() {
  check_device
  if is_streaming; then
    warn "Stream already running — stop it first"
    return 1
  fi
  info "Starting loopback stream at 5fps (reduced CPU)..."
  spawn_5fps_ffmpeg
  sleep 2
  success "Loopback 5fps started (PID $(cat $PIDFILE))"
  info "Capture with: $0 capture-loopback"
}

# ─── Method 3: loopback with MJPEG (lower bandwidth) ──────
start_loopback_mjpeg() {
  check_device
  if is_streaming; then
    warn "Stream already running — stop it first"
    return 1
  fi
  info "Starting loopback stream with MJPEG at 10fps..."
  sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="capture" 2>/dev/null
  ffmpeg -f v4l2 -input_format mjpeg -video_size 1920x1080 \
    -framerate 10 \
    -i "$DEVICE" \
    -vf "format=yuv420p" \
    -r 5 \
    -f v4l2 "$VIRT" \
    -loglevel quiet &
  echo $! > "$PIDFILE"
  sleep 2
  success "Loopback MJPEG started (PID $(cat $PIDFILE))"
  info "Capture with: $0 capture-loopback"
}

# ─── Method 4: loopback with nice (lower priority) ────────
start_loopback_nice() {
  check_device
  if is_streaming; then
    warn "Stream already running — stop it first"
    return 1
  fi
  info "Starting loopback stream at 60fps with low priority (nice 19)..."
  sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="capture" 2>/dev/null
  nice -n 19 ffmpeg -f v4l2 -input_format yuyv422 -video_size 1920x1080 \
    -framerate 60 \
    -i "$DEVICE" \
    -vf "scale=1920:1080,format=yuv420p" \
    -r 5 \
    -f v4l2 "$VIRT" \
    -loglevel quiet &
  echo $! > "$PIDFILE"
  sleep 2
  success "Loopback nice started (PID $(cat $PIDFILE))"
  info "Capture with: $0 capture-loopback"
}

# ─── Capture from loopback device ─────────────────────────
capture_loopback() {
  local output=${1:-$DEFAULT_OUTPUT}
  if ! is_streaming; then
    error "No stream running — start one first"
    exit 1
  fi
  local start=$(date +%s%N)
  ffmpeg -f v4l2 -i "$VIRT" \
    -vframes 1 -update 1 -y "$output" 2>/dev/null
  local end=$(date +%s%N)
  local ms=$(( (end - start) / 1000000 ))
  success "Captured to $output in ${ms}ms"
  show_cpu "$(cat $PIDFILE 2>/dev/null)" "ffmpeg stream"
}

# ─── Method 6: link-managed capture ───────────────────────
# start stream → wait for PS176 link + valid video → settle → grab → re-check link → stop stream.
# Results are left in M_* globals (so loop-test can use them); see capture.conf for settings.
MANAGED_STARTED=0
M_LINK_MS=0 M_SETTLE_MS=0 M_CAPTURE_MS=0 M_TOTAL_MS=0 M_DOWN_MS=0 M_CYCLE_MS=0
M_RES="" M_OUT_RES="" M_RATE="" M_LANES="" M_RETRIES=0 M_HPD=0 M_ERR=""

now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

# Stop the stream if (and only if) managed_capture started it. Returns 0 if it stopped one.
stop_managed_stream() {
  [ "$MANAGED_STARTED" = 1 ] || return 1
  if is_streaming; then
    local pid
    pid=$(cat "$PIDFILE")
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  fi
  rm -f "$PIDFILE"
  MANAGED_STARTED=0
  return 0
}

# Stop our stream (if any) and release the lock. Safe to call twice.
managed_cleanup() {
  stop_managed_stream
  exec 9>&-
}

# Returns 0 if image looks like real content (not uniform/black)
frame_ok() {
  local img=$1 sd
  [ -s "$img" ] || return 1
  # -scale first: fx:standard_deviation takes ~8s on a full 1080p frame, ~0.2s at 5%
  sd=$(convert "$img" -scale 5% -format "%[fx:standard_deviation]" info: 2>/dev/null) || return 1
  awk -v sd="$sd" 'BEGIN { exit !(sd > 0.01) }'
}

# managed_capture <out.png> [quiet]
managed_capture() {
  local output=${1:-$DEFAULT_OUTPUT} quiet=${2:-}
  local t0 t1 attempt out rc
  local was_running=0 settle_s

  M_LINK_MS=0 M_SETTLE_MS=0 M_CAPTURE_MS=0 M_TOTAL_MS=0 M_DOWN_MS=0 M_CYCLE_MS=0
  M_RES="" M_OUT_RES="" M_RATE="" M_LANES="" M_RETRIES=0 M_HPD=0 M_ERR=""

  if [ ! -e "$DEVICE" ]; then
    M_ERR="capture device $DEVICE not found"
    [ -z "$quiet" ] && error "$M_ERR"
    return 1
  fi

  t0=$(now_ms)

  # 0. only one capture at a time (shared with pi_server.py)
  exec 9>"$LOCK_FILE"
  flock 9

  # 1. start stream (unless an always-on stream is already running)
  if is_streaming; then
    was_running=1
  else
    spawn_5fps_ffmpeg
    MANAGED_STARTED=1
  fi

  settle_s=$(awk -v ms="$SETTLE_MS" 'BEGIN { printf "%.3f", ms / 1000 }')

  for (( attempt = 0; attempt <= CAPTURE_RETRIES; attempt++ )); do
    M_RETRIES=$attempt

    # 2. wait for link + valid video (one HPD toggle on timeout)
    out=$($PS176_LINK wait --timeout "$LINK_TIMEOUT" --poll-ms "$POLL_MS"); rc=$?
    if [ $rc -ne 0 ] && [ "$M_HPD" -eq 0 ]; then
      [ -z "$quiet" ] && warn "Link not up after ${LINK_TIMEOUT}s — toggling DP_HPD"
      M_HPD=1
      $PS176_LINK toggle >/dev/null
      out=$($PS176_LINK wait --timeout "$LINK_TIMEOUT" --poll-ms "$POLL_MS"); rc=$?
    fi
    if [ $rc -ne 0 ]; then
      M_ERR="link did not come up"
      break
    fi
    local lm
    read -r lm M_RATE M_LANES M_RES < <(echo "$out" | python3 -c \
      'import sys,json; d=json.load(sys.stdin); print(d["link_ms"], d["rate_gbps"], d["lanes"], "%dx%d" % (d["width"], d["height"]))')
    M_LINK_MS=$(( M_LINK_MS + lm ))

    # 3. settle so the MS2130 has fresh frames (an already-running stream doesn't need it)
    if [ $was_running -eq 0 ]; then
      sleep "$settle_s"
      M_SETTLE_MS=$(( M_SETTLE_MS + SETTLE_MS ))
    fi

    # 4. grab one frame from the loopback
    local c0 c1 cap_ok=1
    c0=$(now_ms)
    ffmpeg -f v4l2 -i "$VIRT" -vframes 1 -update 1 -y "$output" \
      -loglevel quiet 2>/dev/null 9>&- || cap_ok=0
    c1=$(now_ms)
    M_CAPTURE_MS=$(( c1 - c0 ))

    # 5. link must still be up, otherwise the frame may be stale/partial → retry
    if ! $PS176_LINK status >/dev/null; then
      M_ERR="link dropped during capture"
      [ -z "$quiet" ] && warn "$M_ERR — retrying ($((attempt + 1))/$CAPTURE_RETRIES)"
      continue
    fi

    # 6. basic frame check
    if [ $cap_ok -eq 0 ] || ! frame_ok "$output"; then
      M_ERR="blank or missing frame"
      [ -z "$quiet" ] && warn "$M_ERR — retrying ($((attempt + 1))/$CAPTURE_RETRIES)"
      continue
    fi

    M_ERR=""
    M_OUT_RES=$(identify -format "%wx%h" "$output" 2>/dev/null)
    break
  done

  # 7. stop stream (only if we started it)
  local stopped=0
  stop_managed_stream && stopped=1
  t1=$(now_ms)
  M_TOTAL_MS=$(( t1 - t0 ))

  # 8. wait for the link to drop so the next capture starts from a clean state.
  #    The lock is held until then. Not needed if we left an always-on stream running.
  if [ $stopped -eq 1 ]; then
    out=$($PS176_LINK wait-down --timeout "$LINK_DOWN_TIMEOUT" --poll-ms "$POLL_MS"); rc=$?
    M_DOWN_MS=$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["down_ms"])' 2>/dev/null || echo 0)
    [ $rc -ne 0 ] && [ -z "$quiet" ] && warn "Link still up ${LINK_DOWN_TIMEOUT}s after stream stop"
  fi
  M_CYCLE_MS=$(( M_TOTAL_MS + M_DOWN_MS ))
  managed_cleanup        # releases the lock

  if [ -n "$M_ERR" ]; then
    [ -z "$quiet" ] && error "Managed capture failed: $M_ERR (${M_TOTAL_MS}ms, link down ${M_DOWN_MS}ms, retries=$M_RETRIES)"
    return 1
  fi

  if [ -z "$quiet" ]; then
    success "Captured to $output in ${M_TOTAL_MS}ms (ready for next capture after ${M_CYCLE_MS}ms)"
    echo "  link ${M_LINK_MS}ms | settle ${M_SETTLE_MS}ms | capture ${M_CAPTURE_MS}ms | stop ${M_TOTAL_MS}ms total | link down ${M_DOWN_MS}ms | cycle ${M_CYCLE_MS}ms"
    echo "  image ${M_OUT_RES} | source ${M_RES} | ${M_RATE}Gbps x${M_LANES} | retries ${M_RETRIES} | hpd_toggle ${M_HPD}"
  fi
  return 0
}

# `capture` command: honours CAPTURE_MODE
capture_cmd() {
  local output=${1:-$DEFAULT_OUTPUT}
  case "$CAPTURE_MODE" in
    managed)
      trap 'managed_cleanup; exit 130' INT TERM
      trap 'managed_cleanup' EXIT
      managed_capture "$output" ;;
    always-on)
      capture_loopback "$output" ;;
    *)
      error "Unknown CAPTURE_MODE: $CAPTURE_MODE (valid: managed always-on)"
      exit 1 ;;
  esac
}

# ─── Method 5: on-demand with warmup delay ────────────────
capture_ondemand() {
  local output=${1:-$DEFAULT_OUTPUT}
  check_device
  if is_streaming; then
    warn "A loopback stream is running — this will compete for the device"
  fi
  info "Capturing on-demand (skipping 60 frames for warmup)..."
  local start=$(date +%s%N)
  ffmpeg -f v4l2 -input_format yuyv422 -video_size 1920x1080 \
    -framerate 60 \
    -i "$DEVICE" \
    -vf "select='gte(n,60)',scale=1920:1080,format=rgb24" \
    -vframes 1 -update 1 -y "$output" \
    -loglevel quiet
  local end=$(date +%s%N)
  local ms=$(( (end - start) / 1000000 ))
  success "Captured to $output in ${ms}ms"
}

# ─── OCR and validate against expected values ────────────
# Config format: label|crop|shave|whitelist|options|expected
ocr_validate() {
  local image="$1"
  local config="$2"
  local pass=0
  local fail=0
  local total=0

  echo -e "  ${CYAN}OCR Validation — $config${NC}"
  echo -e "  $(printf '%-20s %-20s %-20s %s' 'Label' 'Expected' 'Got' 'Result')"
  echo -e "  -----------------------------------------------------------------------"

  while IFS='|' read -r label crop shave whitelist options expected; do
    [[ "$label" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$label" ]] && continue

    label=$(echo "$label"         | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    crop=$(echo "$crop"           | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    shave=$(echo "$shave"         | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    whitelist=$(echo "$whitelist" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    options=$(echo "$options"     | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    expected=$(echo "$expected"   | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    local cmd="convert \"$image\" -crop \"$crop\" +repage"
    if [ -n "$shave" ] && [ "$shave" != "0x0" ]; then
      cmd="$cmd -shave \"$shave\""
    fi
    if echo "$options" | grep -q "scale3x"; then
      cmd="$cmd -resize 300%"
    elif echo "$options" | grep -q "scale2x"; then
      cmd="$cmd -resize 200%"
    fi
    cmd="$cmd -colorspace Gray -normalize"
    if echo "$options" | grep -q "invert"; then
      cmd="$cmd -negate"
    fi
    cmd="$cmd -threshold 40% /tmp/ocr_val.png"
    eval "$cmd" 2>/dev/null

    local result
    if [ -n "$whitelist" ]; then
      result=$(tesseract /tmp/ocr_val.png stdout --psm 7 \
        -c tessedit_char_whitelist="$whitelist" 2>/dev/null)
    else
      result=$(tesseract /tmp/ocr_val.png stdout --psm 7 2>/dev/null)
    fi
    result=$(echo "$result" | tr -d '\f' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    total=$(( total + 1 ))
    if [ -z "$expected" ]; then
      printf "  %-20s %-20s %-20s " "$label" "(not set)" "$result"
      echo -e "${CYAN}SKIP${NC}"
    elif [ "$result" = "$expected" ]; then
      pass=$(( pass + 1 ))
      printf "  %-20s %-20s %-20s " "$label" "$expected" "$result"
      echo -e "${GREEN}PASS${NC}"
    else
      fail=$(( fail + 1 ))
      printf "  %-20s %-20s %-20s " "$label" "$expected" "$result"
      echo -e "${RED}FAIL${NC}"
    fi

  done < "$config"

  echo -e "  -----------------------------------------------------------------------"
  echo -e "  Total: $total  ${GREEN}Pass: $pass${NC}  ${RED}Fail: $fail${NC}"
  echo ""
  rm -f /tmp/ocr_val.png
  [ "$fail" -eq 0 ]
}

# ─── Run OCR validation on current capture ────────────────
validate() {
  local image=${1:-$DEFAULT_OUTPUT}
  local config=${2:-test_regions.conf}

  if [ ! -f "$image" ]; then
    error "Image '$image' not found — capture one first"
    exit 1
  fi
  if [ ! -f "$config" ]; then
    error "Config '$config' not found"
    exit 1
  fi

  echo ""
  echo -e "${CYAN}════════════════════════════════════════${NC}"
  echo -e "${CYAN}   OCR Validation                       ${NC}"
  echo -e "${CYAN}════════════════════════════════════════${NC}"
  echo ""
  ocr_validate "$image" "$config"
  echo -e "${CYAN}════════════════════════════════════════${NC}"
}

# ─── Benchmark: run all methods and compare ───────────────
benchmark() {
  local output=/tmp/bench_capture.png
  echo ""
  echo -e "${CYAN}════════════════════════════════════════${NC}"
  echo -e "${CYAN}   Capture Method Benchmark             ${NC}"
  echo -e "${CYAN}════════════════════════════════════════${NC}"
  echo ""

  # On-demand
  echo -e "${YELLOW}Method: On-demand (no stream)${NC}"
  local start=$(date +%s%N)
  ffmpeg -f v4l2 -input_format yuyv422 -video_size 1920x1080 \
    -framerate 60 -i "$DEVICE" \
    -vf "select='gte(n,60)',scale=1920:1080,format=rgb24" \
    -vframes 1 -update 1 -y "$output" -loglevel quiet
  local end=$(date +%s%N)
  echo "  Capture time: $(( (end - start) / 1000000 ))ms"
  echo "  File size:    $(ls -lh $output | awk '{print $5}')"
  show_system_mem
  echo ""

  # Loopback 60fps
  echo -e "${YELLOW}Method: Loopback 60fps${NC}"
  sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="capture" 2>/dev/null
  ffmpeg -f v4l2 -input_format yuyv422 -video_size 1920x1080 \
    -framerate 60 -i "$DEVICE" \
    -vf "scale=1920:1080,format=yuv420p" \
    -f v4l2 "$VIRT" -loglevel quiet &
  local spid=$!
  sleep 3
  show_cpu "$spid" "ffmpeg"
  show_system_mem
  start=$(date +%s%N)
  ffmpeg -f v4l2 -i "$VIRT" -vframes 1 -update 1 -y "$output" -loglevel quiet
  end=$(date +%s%N)
  echo "  Capture time: $(( (end - start) / 1000000 ))ms"
  kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
  sleep 1
  echo ""

  # Loopback 5fps
  echo -e "${YELLOW}Method: Loopback 5fps${NC}"
  ffmpeg -f v4l2 -input_format yuyv422 -video_size 1920x1080 \
    -framerate 60 -i "$DEVICE" \
    -vf "scale=1920:1080,format=yuv420p" \
    -r 5 -f v4l2 "$VIRT" -loglevel quiet &
  spid=$!
  sleep 3
  show_cpu "$spid" "ffmpeg"
  show_system_mem
  start=$(date +%s%N)
  ffmpeg -f v4l2 -i "$VIRT" -vframes 1 -update 1 -y "$output" -loglevel quiet
  end=$(date +%s%N)
  echo "  Capture time: $(( (end - start) / 1000000 ))ms"
  kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
  sleep 1
  echo ""

  # Loopback nice
  echo -e "${YELLOW}Method: Loopback 5fps nice-19${NC}"
  nice -n 19 ffmpeg -f v4l2 -input_format yuyv422 -video_size 1920x1080 \
    -framerate 60 -i "$DEVICE" \
    -vf "scale=1920:1080,format=yuv420p" \
    -r 5 -f v4l2 "$VIRT" -loglevel quiet &
  spid=$!
  sleep 3
  show_cpu "$spid" "ffmpeg"
  show_system_mem
  start=$(date +%s%N)
  ffmpeg -f v4l2 -i "$VIRT" -vframes 1 -update 1 -y "$output" -loglevel quiet
  end=$(date +%s%N)
  echo "  Capture time: $(( (end - start) / 1000000 ))ms"
  kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
  sleep 1
  echo ""

  # Managed (start stream, wait for link, capture, stop stream)
  echo -e "${YELLOW}Method: Managed (link-aware, stream started per capture)${NC}"
  if managed_capture "$output" quiet; then
    echo "  Capture time: ${M_TOTAL_MS}ms total (link ${M_LINK_MS}ms, settle ${M_SETTLE_MS}ms, grab ${M_CAPTURE_MS}ms)"
    echo "  Ready for next: ${M_CYCLE_MS}ms (link down ${M_DOWN_MS}ms after stream stop)"
    echo "  Image:        ${M_OUT_RES} (source ${M_RES} ${M_RATE}Gbps x${M_LANES}), retries ${M_RETRIES}, hpd_toggle ${M_HPD}"
  else
    echo -e "  ${RED}Managed capture failed: ${M_ERR}${NC}"
  fi
  echo ""

  echo -e "${CYAN}════════════════════════════════════════${NC}"
  echo -e "${CYAN}   OCR Validation Results               ${NC}"
  echo -e "${CYAN}════════════════════════════════════════${NC}"
  echo ""

  local test_config=${2:-test_regions.conf}
  if [ -f "$test_config" ]; then
    ocr_validate "$output" "$test_config"
  else
    warn "No test config found ($test_config) — skipping OCR validation"
    warn "Create $test_config with expected values to enable OCR testing"
  fi

  echo -e "${CYAN}════════════════════════════════════════${NC}"
  echo -e "${GREEN}Benchmark complete${NC}"
  rm -f "$output"
}


# ─── Managed-capture stats helpers (use the caller's locals via bash dynamic scope) ──
record_managed_stats() {
  [ -n "$M_ERR" ] && return
  link_n=$(( link_n + 1 ))
  link_sum=$(( link_sum + M_LINK_MS ))
  [ "$M_LINK_MS" -lt "$link_min" ] && link_min=$M_LINK_MS
  [ "$M_LINK_MS" -gt "$link_max" ] && link_max=$M_LINK_MS
  retries_sum=$(( retries_sum + M_RETRIES ))
  hpd_sum=$(( hpd_sum + M_HPD ))
  down_sum=$(( down_sum + M_DOWN_MS ))
  [ "$M_DOWN_MS" -gt "$down_max" ] && down_max=$M_DOWN_MS
  cycle_sum=$(( cycle_sum + M_CYCLE_MS ))
}

print_managed_summary() {
  local mean=0 down_mean=0 cycle_mean=0
  [ "$link_n" -gt 0 ] && mean=$(( link_sum / link_n )) && down_mean=$(( down_sum / link_n )) && cycle_mean=$(( cycle_sum / link_n ))
  [ "$link_n" -eq 0 ] && link_min=0
  echo -e "  Time to link:   min ${link_min}ms / mean ${mean}ms / max ${link_max}ms"
  echo -e "  Link down:      mean ${down_mean}ms / max ${down_max}ms (after stream stop)"
  echo -e "  Full cycle:     mean ${cycle_mean}ms (start of capture until ready for the next)"
  echo -e "  Retries:        $retries_sum   HPD toggles: $hpd_sum"
}

# "timing=..." log field for the last managed_capture (empty for other methods).
# Pass "lead" when the preceding text doesn't already end in "|".
managed_log_field() {
  [ "$method" = "managed" ] || return 0
  [ "$1" = "lead" ] && echo -n "|"
  echo -n "timing=${M_LINK_MS},${M_SETTLE_MS},${M_CAPTURE_MS},${M_TOTAL_MS},${M_DOWN_MS},${M_CYCLE_MS},${M_RES},${M_RETRIES},${M_HPD}"
}

loop_test() {
  local method=${1:-ondemand}
  local config=${2:-test_regions.conf}
  local interval=${3:-5}
  local max_iterations=${4:-0}
  local output=/tmp/loop_capture.png
  local log_file="loop_test_$(date +%Y%m%d_%H%M%S).log"

  # Validate method
  case "$method" in
    60fps|5fps|mjpeg|nice|ondemand|managed) ;;
    *)
      error "Unknown method: $method — valid: 60fps 5fps mjpeg nice ondemand managed"
      exit 1 ;;
  esac

  if [ ! -f "$config" ]; then
    error "Config file not found: $config"
    exit 1
  fi

  local iter=0
  local total_pass=0
  local total_fail=0
  local total_ms=0
  local cap_errors=0
  local started_stream=0
  local link_n=0 link_sum=0 link_min=999999 link_max=0 retries_sum=0 hpd_sum=0 down_sum=0 down_max=0 cycle_sum=0

  # Start loopback stream if needed
  if [ "$method" != "ondemand" ] && [ "$method" != "managed" ]; then
    if is_streaming; then
      warn "Using existing stream"
    else
      info "Starting $method stream..."
      case "$method" in
        60fps) start_loopback_60fps ;;
        5fps)  start_loopback_5fps ;;
        mjpeg) start_loopback_mjpeg ;;
        nice)  start_loopback_nice ;;
      esac
      started_stream=1
    fi
  fi

  print_summary() {
    local avg=0
    [ "$iter" -gt 0 ] && avg=$(( total_ms / iter ))
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}   Loop Test Summary${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
    echo -e "  Finished:       $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "  Iterations:     $iter"
    echo -e "  Capture errors: $cap_errors"
    echo -e "  Total pass:     ${GREEN}$total_pass${NC}"
    echo -e "  Total fail:     ${RED}$total_fail${NC}"
    echo -e "  Avg capture:    ${avg}ms"
    [ "$method" = "managed" ] && print_managed_summary
    echo -e "  Log:            $log_file"
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
    echo ""
  }

  trap 'managed_cleanup; print_summary; [ "$started_stream" -eq 1 ] && stop_stream; rm -f $output /tmp/loop_ocr.png; exit 0' INT TERM

  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}   Loop Test${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
  echo -e "  Method:    $method"
  echo -e "  Config:    $config"
  echo -e "  Interval:  ${interval}s"
  if [ "$max_iterations" -eq 0 ]; then
    echo -e "  Max iters: unlimited"
  else
    echo -e "  Max iters: $max_iterations"
  fi
  echo -e "  Log:       $log_file"
  echo -e "  Started:   $(date '+%Y-%m-%d %H:%M:%S')"
  echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
  echo -e "  Press ${YELLOW}Ctrl+C${NC} to stop"
  echo ""

  {
    echo "# Loop Test Log"
    echo "# Started:  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Method:   $method"
    echo "# Config:   $config"
    echo "# Format:   iter|timestamp|capture_ms|pass|fail|label=result[STATUS]...[|timing=...]"
    [ "$method" = "managed" ] && echo "# timing:   link_ms,settle_ms,capture_ms,total_ms,down_ms,cycle_ms,res,retries,hpd_toggle (managed only)"
  } > "$log_file"

  while true; do
    iter=$(( iter + 1 ))
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local iter_pass=0
    local iter_fail=0
    local log_regions=""

    # Capture
    local t_start t_end cap_ms cap_ok
    t_start=$(date +%s%N)
    cap_ok=1

    if [ "$method" = "managed" ]; then
      managed_capture "$output" quiet || cap_ok=0
    elif [ "$method" = "ondemand" ]; then
      ffmpeg -f v4l2 -input_format yuyv422 -video_size 1920x1080 \
        -framerate 60 -i "$DEVICE" \
        -vf "select='gte(n,60)',scale=1920:1080,format=rgb24" \
        -vframes 1 -update 1 -y "$output" \
        -loglevel quiet 2>/dev/null || cap_ok=0
    else
      ffmpeg -f v4l2 -i "$VIRT" \
        -vframes 1 -update 1 -y "$output" \
        -loglevel quiet 2>/dev/null || cap_ok=0
    fi

    t_end=$(date +%s%N)
    cap_ms=$(( (t_end - t_start) / 1000000 ))
    total_ms=$(( total_ms + cap_ms ))
    [ "$method" = "managed" ] && record_managed_stats

    if [ "$cap_ok" -eq 0 ] || [ ! -s "$output" ]; then
      cap_errors=$(( cap_errors + 1 ))
      echo -e "  [$(printf '%4d' $iter)] $ts ${RED}CAPTURE FAILED${NC} (${cap_ms}ms)"
      echo "${iter}|${ts}|${cap_ms}|0|0|CAPTURE_FAILED$(managed_log_field lead)" >> "$log_file"
      sleep "$interval"
      [ "$max_iterations" -gt 0 ] && [ "$iter" -ge "$max_iterations" ] && break
      continue
    fi

    # OCR each region
    local fail_detail=""
    while IFS='|' read -r lbl crop shave wl opts exp; do
      [[ "$lbl" =~ ^[[:space:]]*# ]] && continue
      [[ -z "$lbl" ]] && continue

      lbl=$(echo "$lbl"   | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      crop=$(echo "$crop" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      shave=$(echo "$shave" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      wl=$(echo "$wl"     | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      opts=$(echo "$opts" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      exp=$(echo "$exp"   | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

      # Preprocess image
      local icmd
      icmd="convert \"$output\" -crop \"$crop\" +repage"
      [ -n "$shave" ] && [ "$shave" != "0x0" ] && icmd="$icmd -shave \"$shave\""
      echo "$opts" | grep -q "scale3x" && icmd="$icmd -resize 300%"
      echo "$opts" | grep -q "scale2x" && icmd="$icmd -resize 200%"
      icmd="$icmd -colorspace Gray -normalize"
      echo "$opts" | grep -q "invert" && icmd="$icmd -negate"
      icmd="$icmd -threshold 40% /tmp/loop_ocr.png"
      eval "$icmd" 2>/dev/null

      # OCR
      local ocr_result
      if [ -n "$wl" ]; then
        ocr_result=$(tesseract /tmp/loop_ocr.png stdout --psm 7 \
          -c tessedit_char_whitelist="$wl" 2>/dev/null)
      else
        ocr_result=$(tesseract /tmp/loop_ocr.png stdout --psm 7 2>/dev/null)
      fi
      ocr_result=$(printf '%s' "$ocr_result" | tr -d '\014\015' | \
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/,,*/,/g')

      # Compare
      local st
      if [ -z "$exp" ]; then
        st="SKIP"
      elif [ "$ocr_result" = "$exp" ]; then
        iter_pass=$(( iter_pass + 1 ))
        st="PASS"
      else
        iter_fail=$(( iter_fail + 1 ))
        st="FAIL"
        fail_detail="${fail_detail}  ${RED}✗ ${lbl}: expected '${exp}' got '${ocr_result}'${NC}\n"
      fi

      log_regions="${log_regions}${lbl}=${ocr_result}[${st}]|"

    done < "$config"

    total_pass=$(( total_pass + iter_pass ))
    total_fail=$(( total_fail + iter_fail ))

    # CPU/mem of stream process (managed: link timings instead)
    local stream_info=""
    if [ "$method" = "managed" ]; then
      stream_info=" link:${M_LINK_MS}ms down:${M_DOWN_MS}ms cycle:${M_CYCLE_MS}ms retries:${M_RETRIES} hpd:${M_HPD} ${M_RES}"
    fi
    if is_streaming; then
      local spid
      spid=$(cat "$PIDFILE" 2>/dev/null)
      if [ -n "$spid" ] && kill -0 "$spid" 2>/dev/null; then
        local scpu srss srss_mb
        scpu=$(ps -p "$spid" -o %cpu= 2>/dev/null | tr -d ' ')
        srss=$(ps -p "$spid" -o rss= 2>/dev/null | tr -d ' ')
        srss_mb=$(( srss / 1024 ))
        stream_info=" CPU:${scpu}% MEM:${srss_mb}MB"
      fi
    fi

    # Print result line
    local sc sl
    if [ "$iter_fail" -gt 0 ]; then
      sc=$RED; sl="FAIL"
    else
      sc=$GREEN; sl="PASS"
    fi

    printf "  [%4d] %s %b%-4s%b %4dms pass:%-2d fail:%-2d%s\n" \
      "$iter" "$ts" "$sc" "$sl" "$NC" \
      "$cap_ms" "$iter_pass" "$iter_fail" "$stream_info"

    # Print failure detail
    if [ -n "$fail_detail" ]; then
      printf "%b" "         ${RED}Failed regions:${NC}\n${fail_detail}"
    fi

    # Log
    echo "${iter}|${ts}|${cap_ms}|${iter_pass}|${iter_fail}|${log_regions}$(managed_log_field)" >> "$log_file"

    [ "$max_iterations" -gt 0 ] && [ "$iter" -ge "$max_iterations" ] && break

    sleep "$interval"
  done

  print_summary
  [ "$started_stream" -eq 1 ] && stop_stream
  rm -f "$output" /tmp/loop_ocr.png
}

# ─── Loop: capture + OCR, print values only (no pass/fail) ──
read_loop() {
  local method=${1:-ondemand}
  local config=${2:-test_regions.conf}
  local interval=${3:-5}
  local max_iterations=${4:-0}
  local output=/tmp/loop_capture.png
  local log_file="loop_test_$(date +%Y%m%d_%H%M%S).log"

  case "$method" in
    60fps|5fps|mjpeg|nice|ondemand|managed) ;;
    *)
      error "Unknown method: $method — valid: 60fps 5fps mjpeg nice ondemand managed"
      exit 1 ;;
  esac

  if [ ! -f "$config" ]; then
    error "Config file not found: $config"
    exit 1
  fi

  local iter=0
  local total_ms=0
  local cap_errors=0
  local started_stream=0
  local link_n=0 link_sum=0 link_min=999999 link_max=0 retries_sum=0 hpd_sum=0 down_sum=0 down_max=0 cycle_sum=0

  if [ "$method" != "ondemand" ] && [ "$method" != "managed" ]; then
    if is_streaming; then
      warn "Using existing stream"
    else
      info "Starting $method stream..."
      case "$method" in
        60fps) start_loopback_60fps ;;
        5fps)  start_loopback_5fps ;;
        mjpeg) start_loopback_mjpeg ;;
        nice)  start_loopback_nice ;;
      esac
      started_stream=1
    fi
  fi

  print_summary() {
    local avg=0
    [ "$iter" -gt 0 ] && avg=$(( total_ms / iter ))
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}   Read Loop Summary${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
    echo -e "  Finished:       $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "  Iterations:     $iter"
    echo -e "  Capture errors: $cap_errors"
    echo -e "  Avg capture:    ${avg}ms"
    [ "$method" = "managed" ] && print_managed_summary
    echo -e "  Log:            $log_file"
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
    echo ""
  }

  trap 'managed_cleanup; print_summary; [ "$started_stream" -eq 1 ] && stop_stream; rm -f $output /tmp/loop_ocr.png; exit 0' INT TERM

  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}   Read Loop${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
  echo -e "  Method:    $method"
  echo -e "  Config:    $config"
  echo -e "  Interval:  ${interval}s"
  if [ "$max_iterations" -eq 0 ]; then
    echo -e "  Max iters: unlimited"
  else
    echo -e "  Max iters: $max_iterations"
  fi
  echo -e "  Log:       $log_file"
  echo -e "  Started:   $(date '+%Y-%m-%d %H:%M:%S')"
  echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
  echo -e "  Press ${YELLOW}Ctrl+C${NC} to stop"
  echo ""

  {
    echo "# Read Loop Log"
    echo "# Started:  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Method:   $method"
    echo "# Config:   $config"
    echo "# Format:   iter|timestamp|capture_ms|label=value...[|timing=...]"
    [ "$method" = "managed" ] && echo "# timing:   link_ms,settle_ms,capture_ms,total_ms,down_ms,cycle_ms,res,retries,hpd_toggle (managed only)"
  } > "$log_file"

  while true; do
    iter=$(( iter + 1 ))
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local log_regions=""

    # Capture
    local t_start t_end cap_ms cap_ok
    t_start=$(date +%s%N)
    cap_ok=1

    if [ "$method" = "managed" ]; then
      managed_capture "$output" quiet || cap_ok=0
    elif [ "$method" = "ondemand" ]; then
      ffmpeg -f v4l2 -input_format yuyv422 -video_size 1920x1080 \
        -framerate 60 -i "$DEVICE" \
        -vf "select='gte(n,60)',scale=1920:1080,format=rgb24" \
        -vframes 1 -update 1 -y "$output" \
        -loglevel quiet 2>/dev/null || cap_ok=0
    else
      ffmpeg -f v4l2 -i "$VIRT" \
        -vframes 1 -update 1 -y "$output" \
        -loglevel quiet 2>/dev/null || cap_ok=0
    fi

    t_end=$(date +%s%N)
    cap_ms=$(( (t_end - t_start) / 1000000 ))
    total_ms=$(( total_ms + cap_ms ))
    [ "$method" = "managed" ] && record_managed_stats

    if [ "$cap_ok" -eq 0 ] || [ ! -s "$output" ]; then
      cap_errors=$(( cap_errors + 1 ))
      echo -e "  [$(printf '%4d' $iter)] $ts ${RED}CAPTURE FAILED${NC} (${cap_ms}ms)"
      echo "${iter}|${ts}|${cap_ms}|CAPTURE_FAILED$(managed_log_field lead)" >> "$log_file"
      sleep "$interval"
      [ "$max_iterations" -gt 0 ] && [ "$iter" -ge "$max_iterations" ] && break
      continue
    fi

    # OCR each region and collect results
    local results=()
    while IFS='|' read -r lbl crop shave wl opts exp; do
      [[ "$lbl" =~ ^[[:space:]]*# ]] && continue
      [[ -z "$lbl" ]] && continue

      lbl=$(echo "$lbl"     | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      crop=$(echo "$crop"   | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      shave=$(echo "$shave" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      wl=$(echo "$wl"       | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      opts=$(echo "$opts"   | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

      local icmd
      icmd="convert \"$output\" -crop \"$crop\" +repage"
      [ -n "$shave" ] && [ "$shave" != "0x0" ] && icmd="$icmd -shave \"$shave\""
      echo "$opts" | grep -q "scale3x" && icmd="$icmd -resize 300%"
      echo "$opts" | grep -q "scale2x" && icmd="$icmd -resize 200%"
      icmd="$icmd -colorspace Gray -normalize"
      echo "$opts" | grep -q "invert" && icmd="$icmd -negate"
      icmd="$icmd -threshold 40% /tmp/loop_ocr.png"
      eval "$icmd" 2>/dev/null

      local ocr_result
      if [ -n "$wl" ]; then
        ocr_result=$(tesseract /tmp/loop_ocr.png stdout --psm 7 \
          -c tessedit_char_whitelist="$wl" 2>/dev/null)
      else
        ocr_result=$(tesseract /tmp/loop_ocr.png stdout --psm 7 2>/dev/null)
      fi
      ocr_result=$(printf '%s' "$ocr_result" | tr -d '\014\015' | \
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/,,*/,/g')

      results+=("${lbl}|${ocr_result}")
      log_regions="${log_regions}${lbl}=${ocr_result}|"

    done < "$config"

    # CPU/mem of stream process (managed: link timings instead)
    local stream_info=""
    if [ "$method" = "managed" ]; then
      stream_info=" link:${M_LINK_MS}ms down:${M_DOWN_MS}ms cycle:${M_CYCLE_MS}ms retries:${M_RETRIES} hpd:${M_HPD} ${M_RES}"
    fi
    if is_streaming; then
      local spid
      spid=$(cat "$PIDFILE" 2>/dev/null)
      if [ -n "$spid" ] && kill -0 "$spid" 2>/dev/null; then
        local scpu srss srss_mb
        scpu=$(ps -p "$spid" -o %cpu= 2>/dev/null | tr -d ' ')
        srss=$(ps -p "$spid" -o rss= 2>/dev/null | tr -d ' ')
        srss_mb=$(( srss / 1024 ))
        stream_info=" CPU:${scpu}% MEM:${srss_mb}MB"
      fi
    fi

    # Print iteration header then one line per region
    printf "  [%4d] %s  %4dms%s\n" "$iter" "$ts" "$cap_ms" "$stream_info"
    for entry in "${results[@]}"; do
      local r_lbl r_val
      r_lbl="${entry%%|*}"
      r_val="${entry#*|}"
      printf "         ${CYAN}%-22s${NC} %s\n" "${r_lbl}:" "$r_val"
    done

    echo "${iter}|${ts}|${cap_ms}|${log_regions}$(managed_log_field)" >> "$log_file"

    [ "$max_iterations" -gt 0 ] && [ "$iter" -ge "$max_iterations" ] && break

    sleep "$interval"
  done

  print_summary
  [ "$started_stream" -eq 1 ] && stop_stream
  rm -f "$output" /tmp/loop_ocr.png
}

# ─── Status ───────────────────────────────────────────────
status() {
  echo ""
  if is_streaming; then
    local pid=$(cat "$PIDFILE")
    success "Stream is RUNNING (PID $pid)"
    show_cpu "$pid" "ffmpeg stream"
    echo ""
    info "Virtual device: $VIRT"
    info "Source device:  $DEVICE"
  else
    warn "No stream running"
  fi
  echo ""
  local link_line
  link_line=$($PS176_LINK status 2>&1)
  info "PS176 link:     $link_line"
  if $PS176_LINK status >/dev/null 2>&1; then
    local res
    res=$($PS176_LINK video 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print("%dx%d @ %sHz" % (d["h_active"], d["v_active"], d["refresh"]))' 2>/dev/null)
    [ -n "$res" ] && info "Source video:   $res"
  fi
  info "Capture mode:   $CAPTURE_MODE"
  echo ""
  show_system_mem
  echo ""
}

# ─── Usage ────────────────────────────────────────────────
usage() {
  echo ""
  echo -e "${CYAN}Usage: $0 <command> [output.png]${NC}"
  echo ""
  echo "Stream commands (continuous, low capture latency):"
  echo "  start-60fps       Loopback at 60fps          (highest quality, ~50% CPU)"
  echo "  start-5fps        Loopback at 5fps            (good quality, lower CPU)"
  echo "  start-mjpeg       Loopback MJPEG at 10fps     (test if MJPEG works at 1080p)"
  echo "  start-nice        Loopback 5fps, nice 19      (low priority, yields to other processes)"
  echo "  capture-loopback  Capture frame from stream   (fast, requires stream running)"
  echo "  stop              Stop the running stream"
  echo ""
  echo "Link-managed capture (stream only runs during the capture; see capture.conf):"
  echo "  capture [out.png]  Start stream, wait for PS176 link, capture, stop stream"
  echo "                     (CAPTURE_MODE=always-on uses the running loopback stream instead)"
  echo "  link-status        Show PS176 link state (exit 0 = up)"
  echo ""
  echo "On-demand commands (no background process):"
  echo "  capture-ondemand  Open device, wait 2s, capture, close (zero idle CPU)"
  echo ""
  echo "Utility:"
  echo "  benchmark [config]                 Test all methods + OCR validation"
  echo "  validate [img] [cfg]               OCR validate an existing image"
  echo "  loop-test [method] [cfg] [secs] [n] Run capture+OCR in a loop, showing pass/fail"
  echo "  read-loop [method] [cfg] [secs] [n] Run capture+OCR in a loop, printing values only"
  echo "    method: 60fps | 5fps | mjpeg | nice | ondemand | managed (default: ondemand)"
  echo "    secs:   interval between captures in seconds   (default: 5)"
  echo "    n:      number of iterations, 0=unlimited      (default: 0)"
  echo "  status                             Show stream status, CPU and memory"
  echo ""
  echo "Examples:"
  echo "  $0 start-5fps"
  echo "  $0 capture-loopback myfile.png"
  echo "  $0 capture-ondemand myfile.png"
  echo "  $0 capture myfile.png"
  echo "  $0 loop-test managed test_regions.conf 15 100"
  echo "  $0 benchmark test_regions.conf"
  echo "  $0 validate capture.png test_regions.conf"
  echo "  $0 loop-test ondemand test_regions.conf 5 0"
  echo "  $0 loop-test 5fps test_regions.conf 10 100"
  echo "  $0 read-loop 5fps configs/mymachine.conf 5 0"
  echo ""
}

# ─── Entry point ──────────────────────────────────────────
case "$1" in
  start-60fps)       start_loopback_60fps ;;
  start-5fps)        start_loopback_5fps ;;
  start-mjpeg)       start_loopback_mjpeg ;;
  start-nice)        start_loopback_nice ;;
  capture-loopback)  capture_loopback "${2:-$DEFAULT_OUTPUT}" ;;
  capture-ondemand)  capture_ondemand "${2:-$DEFAULT_OUTPUT}" ;;
  capture)           capture_cmd "${2:-$DEFAULT_OUTPUT}" ;;
  link-status)       $PS176_LINK status ;;
  stop)              stop_stream ;;
  benchmark)         benchmark "${2:-/tmp/bench_capture.png}" "${3:-test_regions.conf}" ;;
  validate)          validate "${2:-$DEFAULT_OUTPUT}" "${3:-test_regions.conf}" ;;
  loop-test)         loop_test "${2:-ondemand}" "${3:-test_regions.conf}" "${4:-5}" "${5:-0}" ;;
  read-loop)         read_loop "${2:-ondemand}" "${3:-test_regions.conf}" "${4:-5}" "${5:-0}" ;;
  status)            status ;;
  *)                 usage ;;
esac
