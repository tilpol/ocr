#!/bin/bash

# ─── Configuration ────────────────────────────────────────
DEVICE=/dev/video0
VIRT=/dev/video10
PIDFILE=/tmp/capture_stream.pid
DEFAULT_OUTPUT=capture.png

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
start_loopback_5fps() {
  check_device
  if is_streaming; then
    warn "Stream already running — stop it first"
    return 1
  fi
  info "Starting loopback stream at 5fps (reduced CPU)..."
  sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="capture" 2>/dev/null
  ffmpeg -f v4l2 -input_format yuyv422 -video_size 1920x1080 \
    -framerate 60 \
    -i "$DEVICE" \
    -vf "scale=1920:1080,format=yuv420p" \
    -r 5 \
    -f v4l2 "$VIRT" \
    -loglevel quiet &
  echo $! > "$PIDFILE"
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


loop_test() {
  local method=${1:-ondemand}
  local config=${2:-test_regions.conf}
  local interval=${3:-5}
  local max_iterations=${4:-0}
  local output=/tmp/loop_capture.png
  local log_file="loop_test_$(date +%Y%m%d_%H%M%S).log"

  # Validate method
  case "$method" in
    60fps|5fps|mjpeg|nice|ondemand) ;;
    *)
      error "Unknown method: $method — valid: 60fps 5fps mjpeg nice ondemand"
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

  # Start loopback stream if needed
  if [ "$method" != "ondemand" ]; then
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
    echo -e "  Log:            $log_file"
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
    echo ""
  }

  trap 'print_summary; [ "$started_stream" -eq 1 ] && stop_stream; rm -f $output /tmp/loop_ocr.png; exit 0' INT TERM

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
    echo "# Format:   iter|timestamp|capture_ms|pass|fail|label=result[STATUS]..."
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

    if [ "$method" = "ondemand" ]; then
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

    if [ "$cap_ok" -eq 0 ] || [ ! -s "$output" ]; then
      cap_errors=$(( cap_errors + 1 ))
      echo -e "  [$(printf '%4d' $iter)] $ts ${RED}CAPTURE FAILED${NC} (${cap_ms}ms)"
      echo "${iter}|${ts}|${cap_ms}|0|0|CAPTURE_FAILED" >> "$log_file"
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
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

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

    # CPU/mem of stream process
    local stream_info=""
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
    echo "${iter}|${ts}|${cap_ms}|${iter_pass}|${iter_fail}|${log_regions}" >> "$log_file"

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
  echo "On-demand commands (no background process):"
  echo "  capture-ondemand  Open device, wait 2s, capture, close (zero idle CPU)"
  echo ""
  echo "Utility:"
  echo "  benchmark [config]                 Test all methods + OCR validation"
  echo "  validate [img] [cfg]               OCR validate an existing image"
  echo "  loop-test [method] [cfg] [secs] [n] Run capture+OCR in a loop"
  echo "    method: 60fps | 5fps | mjpeg | nice | ondemand (default: ondemand)"
  echo "    secs:   interval between captures in seconds   (default: 5)"
  echo "    n:      number of iterations, 0=unlimited      (default: 0)"
  echo "  status                             Show stream status, CPU and memory"
  echo ""
  echo "Examples:"
  echo "  $0 start-5fps"
  echo "  $0 capture-loopback myfile.png"
  echo "  $0 capture-ondemand myfile.png"
  echo "  $0 benchmark test_regions.conf"
  echo "  $0 validate capture.png test_regions.conf"
  echo "  $0 loop-test ondemand test_regions.conf 5 0"
  echo "  $0 loop-test 5fps test_regions.conf 10 100"
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
  stop)              stop_stream ;;
  benchmark)         benchmark "${2:-/tmp/bench_capture.png}" "${3:-test_regions.conf}" ;;
  validate)          validate "${2:-$DEFAULT_OUTPUT}" "${3:-test_regions.conf}" ;;
  loop-test)         loop_test "${2:-ondemand}" "${3:-test_regions.conf}" "${4:-5}" "${5:-0}" ;;
  status)            status ;;
  *)                 usage ;;
esac
