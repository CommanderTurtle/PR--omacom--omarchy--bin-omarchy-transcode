#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command magick
require_command ffmpeg

test_tmp=$(mktemp -d)
export OMARCHY_PATH="$ROOT"
trap 'rm -rf "$test_tmp"' EXIT

# The script finishes with a clipboard write and a notification, and with no
# arguments it is menu-driven: stub all three so the test runs headless.
mkdir -p "$test_tmp/bin"
printf '#!/bin/bash\ncat > /dev/null\n' >"$test_tmp/bin/wl-copy"
printf '#!/bin/bash\nexit 0\n' >"$test_tmp/bin/omarchy-notification-send"
chmod +x "$test_tmp/bin/wl-copy" "$test_tmp/bin/omarchy-notification-send"
export PATH="$test_tmp/bin:$ROOT/bin:$PATH"

export HOME="$test_tmp/home"
mkdir -p "$HOME"

run_transcode() {
  bash "$ROOT/bin/omarchy-transcode" "$@"
}

# A 640x360 two-frame animated gif, a static gif, and a 128x128 two-frame
# transparent gif (a transparent index, so the alpha check fires).
magick -size 640x360 xc:red -fill blue -draw "circle 320,180 320,80" "$test_tmp/a1.png"
magick -size 640x360 xc:blue -fill red -draw "circle 320,180 320,80" "$test_tmp/a2.png"
magick "$test_tmp/a1.png" "$test_tmp/a2.png" -set delay 100 "$test_tmp/anim.gif"
magick "$test_tmp/a1.png" "$test_tmp/static.gif"
magick -size 128x128 xc:none -fill red -draw "circle 64,64 64,40" "$test_tmp/t1.png"
magick -size 128x128 xc:none -fill blue -draw "circle 64,64 64,40" "$test_tmp/t2.png"
magick "$test_tmp/t1.png" "$test_tmp/t2.png" -set delay 100 "$test_tmp/alpha.gif"

# Menu answers in call order: the axis, a resolution rung, then the format.
menu_log="$test_tmp/menu.log"
: >"$menu_log"
cat >"$test_tmp/bin/omarchy-menu-select" <<STUB
#!/bin/bash
echo "\$*" >> "$menu_log"
n=\$(cat "$test_tmp/menu-count" 2>/dev/null || echo 0)
answers=(Resolution 360 webp webp)
echo "\${answers[\$(( n % \${#answers[@]} ))]}"
echo \$(( n + 1 )) > "$test_tmp/menu-count"
STUB
chmod +x "$test_tmp/bin/omarchy-menu-select"

# A no-argument animated gif takes the axis flow: Resolution first, then the
# format menu offers every animated-capable output, and the rung sizes the
# longest side of the webp encode.
run_transcode "$test_tmp/anim.gif" >"$test_tmp/t1.log" 2>&1 || fail "a no-argument animated gif takes the resolution axis" "$(cat "$test_tmp/t1.log")"
grep -q '^Select resolution 640' "$menu_log" || fail "the gif resolution ladder starts at the longest side" "$(head -2 "$menu_log")"
grep -q ' webp avif gif mp4 webm$' "$menu_log" || fail "the animated gif format menu offers every animated output" "$(head -3 "$menu_log")"
w=$(magick identify -format '%w' "$test_tmp/anim-360.webp[0]")
(( w == 360 )) || fail "a picked rung sizes a gif's longest side for webp" "$w"
pass "a no-argument animated gif is resized from the longest side and offered every animated output"

# A static gif with an explicit video output takes the video path instead of
# dying in the picture encoder.
run_transcode "$test_tmp/static.gif" gif >"$test_tmp/t2.log" 2>&1 || fail "a static gif with an explicit gif output takes the video path" "$(cat "$test_tmp/t2.log")"
[[ -e $test_tmp/static-re.gif ]] || fail "a static gif re-encoded to gif is written"
pass "a static gif with an explicit video output is transcoded"

# A picked rung reaches the gif video encoder as a longest-side size.
run_transcode "$test_tmp/anim.gif" gif 360 >"$test_tmp/t3.log" 2>&1 || fail "a gif rung reaches the gif encoder" "$(cat "$test_tmp/t3.log")"
w=$(magick identify -format '%w' "$test_tmp/anim-360.gif[0]")
(( w == 360 )) || fail "a picked rung sizes a gif's longest side for gif" "$w"
pass "a picked rung sizes a gif's longest side for gif"

# A transparent gif encodes to avif at a picked rung: the alpha branch must
# build its magick resize from the rung, not from a ffmpeg scale string.
run_transcode "$test_tmp/alpha.gif" avif 128 >"$test_tmp/t4.log" 2>&1 || fail "a transparent gif encodes to avif at a picked rung" "$(cat "$test_tmp/t4.log")"
[[ -e $test_tmp/alpha-128.avif ]] || fail "the transparent gif's avif is written"
pass "a transparent gif encodes to avif at a picked rung"

# --- avif timing regression ------------------------------------------------
# The ffprobe avif demuxer only exposes the first frame, so the timing
# probe reads the container duration from ffprobe and the frame count plus
# per-frame delays (centiseconds) from magick. Use it on any animated avif.
avif_timing() {
  local f="$1" dur frames tsum
  dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -- "$f" 2>/dev/null)
  frames=$(magick identify -format '%n\n' -- "$f" 2>/dev/null | grep -c . || true)
  tsum=$(magick identify -format '%T\n' -- "$f" 2>/dev/null | awk '{ s += $1 } END { print s + 0 }')
  printf '%s %s %s\n' "$dur" "$frames" "$tsum"
}

# A 2s 60fps avif written by the ffmpeg avif muxer. Its libheif per-frame
# delays are a placeholder whose sum (~307s) diverges from the container
# duration (2s), so the re-encode must fall back to the uniform container
# duration and keep the input's playback time.
ffmpeg -v error -y -framerate 60 -stream_loop 59 -start_number 1 -i "$test_tmp/a%d.png" \
  -c:v libaom-av1 -crf 20 -b:v 0 -cpu-used 6 -pix_fmt yuv420p -f avif "$test_tmp/anim.avif"

read -r in_dur in_frames in_tsum < <(avif_timing "$test_tmp/anim.avif")
(( in_frames == 120 )) || fail "the 60fps avif fixture has 120 frames" "$in_frames"
awk -v d="$in_dur" 'BEGIN { exit (d >= 1.8 && d <= 2.2) ? 0 : 1 }' || fail "the 60fps avif fixture is ~2s" "$in_dur"
awk -v d="$in_dur" -v t="$in_tsum" 'BEGIN { exit (d > 0 && t / 100 > 5 * d) ? 0 : 1 }' \
  || fail "the ffmpeg-written avif's per-frame delays are a placeholder" "dur=$in_dur tsum=$in_tsum"

run_transcode "$test_tmp/anim.avif" avif "" 360 cpu >"$test_tmp/t5.log" 2>&1 \
  || fail "the 60fps avif is transcoded" "$(cat "$test_tmp/t5.log")"
read -r out_dur out_frames _ < <(avif_timing "$test_tmp/anim-360.avif")
(( out_frames == 120 )) || fail "the avif re-encode keeps every frame" "$out_frames"
awk -v d="$out_dur" 'BEGIN { exit (d >= 1.7 && d <= 2.4) ? 0 : 1 }' \
  || fail "the avif re-encode keeps the input's playback duration" "$out_dur"
pass "an ffmpeg-written 60fps avif keeps its playback duration through an avif re-encode"

# An avif with real, unequal per-frame delays that reconcile with the
# container total takes the per-frame delay path; the re-encode keeps
# every frame.
magick -size 640x360 xc:green "$test_tmp/a3.png"
magick -delay 50 "$test_tmp/a1.png" -delay 150 "$test_tmp/a2.png" -delay 100 "$test_tmp/a3.png" "$test_tmp/uneven.avif"
read -r in_dur in_frames in_tsum < <(avif_timing "$test_tmp/uneven.avif")
(( in_frames == 3 )) || fail "the uneven-delay avif fixture has 3 frames" "$in_frames"
awk -v t="$in_tsum" 'BEGIN { exit (t >= 280 && t <= 320) ? 0 : 1 }' \
  || fail "the uneven-delay avif fixture carries its 50/150/100 delays" "$in_tsum"

run_transcode "$test_tmp/uneven.avif" avif "" 360 cpu >"$test_tmp/t6.log" 2>&1 \
  || fail "the uneven-delay avif is transcoded" "$(cat "$test_tmp/t6.log")"
out_frames=$(magick identify -format '%n\n' "$test_tmp/uneven-360.avif" 2>/dev/null | grep -c . || true)
(( out_frames == 3 )) || fail "the uneven-delay re-encode keeps every frame" "$out_frames"
pass "an uneven-delay avif re-encode keeps every frame"
