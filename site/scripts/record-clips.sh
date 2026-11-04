#!/usr/bin/env bash
# Records the website's gameplay clips and stills from the real game.
#
#   Xvfb :77 -screen 0 1920x1080x24 +extension GLX &
#   DISPLAY=:77 site/scripts/record-clips.sh            # every clip and still
#   DISPLAY=:77 site/scripts/record-clips.sh race       # only these
#
# HERO_TRACK and HERO_CAR pick the hero clip's track and car (oasis and wedge).
# OUT writes somewhere other than site/public/media, to try things out.
#
# It works on a copy of the game, so the repository is never changed. The copy's
# tests/visual.lua is patched to step the game 1/60 s per frame and save every frame
# of a range, so the clips are smooth at 60 fps however slowly the display renders.
# Nothing is played aloud (ALSOFT_DRIVERS=null). Needs love 11.5 and ffmpeg.
set -euo pipefail
cd "$(dirname "$0")/../.."
repo="$PWD"
out="${OUT:-$repo/site/public/media}"
mkdir -p "$out"
only=" $* "
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
save="${XDG_DATA_HOME:-$HOME/.local/share}/love/spppd-test"

cp -r main.lua conf.lua assets src tests "$work/"
python3 - "$work/tests/visual.lua" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("update(1 / 30)", "update(tonumber(os.getenv('REC_DT') or '') or 1 / 30)")
s = s.replace("""    draw()
    if frame == waitFrames then""", """    draw()
    local from, n = tonumber(os.getenv('REC_FROM') or ''), tonumber(os.getenv('REC_N') or '')
    if from then
      if frame >= from and frame < from + n then
        local name = string.format('rec/%05d.png', frame - from)
        love.graphics.captureScreenshot(function(data) data:encode('png', name) end)
      elseif frame == from + n + 2 then
        love.event.quit()
      end
      return
    end
    if frame == waitFrames then""")
s = s.replace("  SCENES[scene]()\n", "  love.filesystem.createDirectory('rec')\n  SCENES[scene]()\n")
# The hero: any track by day, with any car, against the usual five.
s = s.replace("local waitFrames = 180", """SCENES.hero = function()
  race({ track = os.getenv('HERO_TRACK'), time = 'day', spec = garage.byId(os.getenv('HERO_CAR')) })
  autopilot()
end

local waitFrames = 180""")
assert s.count("REC_") == 3 and "SCENES.hero" in s, "tests/visual.lua changed; update the patch"
open(p, "w").write(s)
EOF

run() {
  (cd "$work" && WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 ALSOFT_DRIVERS=null "$@") > "$work/log.txt" 2>&1 \
    || { cat "$work/log.txt"; exit 1; }
}

# Skips anything not named on the command line, if anything is.
wanted() {
  [ "$only" = "  " ] || [[ "$only" == *" $1 "* ]]
}

# clip <name> <scene> <first frame> <frames> [ENV=value...]
clip() {
  local name=$1 scene=$2 from=$3 n=$4
  shift 4
  wanted "$name" || return 0
  rm -rf "$save/rec"
  run env SPPPD_SIZE=1280x720 REC_DT=0.0166666667 REC_FROM="$from" REC_N="$n" "$@" \
    timeout 600 love . --visual "$scene" unused.png 99999
  ffmpeg -loglevel error -y -framerate 60 -i "$save/rec/%05d.png" \
    -c:v libx264 -preset slow -crf "${CRF:-27}" -pix_fmt yuv420p -movflags +faststart -an \
    "$out/$name.mp4"
  ffmpeg -loglevel error -y -i "$save/rec/00000.png" -q:v 7 "$out/$name.jpg"
  echo "$name.mp4 $(du -h "$out/$name.mp4" | cut -f1)"
}

# still <name> <scene> <size> [ENV=value...]
still() {
  local name=$1 scene=$2 size=$3
  shift 3
  wanted "$name" || return 0
  run env SPPPD_SIZE="$size" "$@" timeout 600 love . --visual "$scene" "$name.png" 120
  ffmpeg -loglevel error -y -i "$save/$name.png" -q:v 3 "$out/$name.jpg"
  echo "$name.jpg"
}

clip race hero 240 600 HERO_TRACK="${HERO_TRACK:-oasis}" HERO_CAR="${HERO_CAR:-wedge}"
clip boost boost 380 540
clip midnight midnight 300 600
clip pack night 200 600
still editor editor 1280x720
still touch touch 853x384
