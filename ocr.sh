#!/bin/bash

# ─── Config ───────────────────────────────────────────────
IMAGE=${1:-capture.png}
CONFIG=${2:-ocr_regions.conf}
TMPFILE=/tmp/ocr_region.png

# ─── Checks ───────────────────────────────────────────────
if [ ! -f "$IMAGE" ]; then
  echo "ERROR: Image file '$IMAGE' not found"
  exit 1
fi

if [ ! -f "$CONFIG" ]; then
  echo "ERROR: Config file '$CONFIG' not found"
  exit 1
fi

if ! command -v tesseract &>/dev/null; then
  echo "ERROR: tesseract not installed"
  exit 1
fi

if ! command -v convert &>/dev/null; then
  echo "ERROR: imagemagick not installed"
  exit 1
fi

# ─── OCR function ─────────────────────────────────────────
ocr_region() {
  local label="$1"
  local crop="$2"
  local shave="$3"
  local whitelist="$4"
  local options="$5"

  # Build imagemagick command
  local cmd="convert \"$IMAGE\" -crop \"$crop\" +repage"

  # Shave edges
  if [ -n "$shave" ] && [ "$shave" != "0x0" ]; then
    cmd="$cmd -shave \"$shave\""
  fi

  # Scale up if requested
  if echo "$options" | grep -q "scale3x"; then
    cmd="$cmd -resize 300%"
  elif echo "$options" | grep -q "scale2x"; then
    cmd="$cmd -resize 200%"
  fi

  # Convert to greyscale and normalise
  cmd="$cmd -colorspace Gray -normalize"

  # Invert if requested
  if echo "$options" | grep -q "invert"; then
    cmd="$cmd -negate"
  fi

  # Threshold
  cmd="$cmd -threshold 40% \"$TMPFILE\""

  # Execute
  eval "$cmd" 2>/dev/null

  # Check crop produced a valid image
  if [ ! -s "$TMPFILE" ]; then
    printf "%-20s: ERROR (empty crop)\n" "$label"
    return
  fi

  # Run OCR
  local result
  if [ -n "$whitelist" ]; then
    result=$(tesseract "$TMPFILE" stdout --psm 7 \
      -c tessedit_char_whitelist="$whitelist" 2>/dev/null)
  else
    result=$(tesseract "$TMPFILE" stdout --psm 7 2>/dev/null)
  fi

  # Clean up result
  result=$(echo "$result" | tr -d '\f' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/,,*/,/g')

  printf "%-20s: %s\n" "$label" "$result"
}

# ─── Main ─────────────────────────────────────────────────
echo "OCR scan of: $IMAGE"
echo "Config:      $CONFIG"
echo "──────────────────────────────────────────"

while IFS='|' read -r label crop shave whitelist options; do
  # Skip blank lines and comments
  [[ "$label" =~ ^[[:space:]]*# ]] && continue
  [[ -z "$label" ]] && continue

  # Trim whitespace from all fields
  label=$(echo "$label"         | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  crop=$(echo "$crop"           | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  shave=$(echo "$shave"         | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  whitelist=$(echo "$whitelist" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  options=$(echo "$options"     | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  ocr_region "$label" "$crop" "$shave" "$whitelist" "$options"

done < "$CONFIG"

echo "──────────────────────────────────────────"

rm -f "$TMPFILE"
