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
