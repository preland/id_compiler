#!/usr/bin/env bash
# Run a windowed `id` program without a window reaching the real compositor.
#
#   tools/headless.sh ./gl3d
#   tools/headless.sh bash -c 'bin/idc demos/gl3d --backend backends/gl -o /tmp/g && /tmp/g'
#
# Why: on a tiling compositor, opening a window steals focus, moves the
# pointer, and drops whatever was fullscreen. That is correct behaviour for an
# application and hostile behaviour for a test, and the graphics demos are run
# far more often as tests than as demos.
#
# Both backends are X11, so the fix is one virtual X server: the program gets
# a real display with a real GLX context, draws real frames, and the compositor
# never learns it exists. This also means the graphics tests run on a machine
# with no session at all.
#
# GFX_MAX_FRAMES is honoured by the demos, so a run here terminates rather than
# looping until killed -- see tests/backends.sh.
#
# To *see* the window instead, run the program directly and add the window
# rules in docs/HYPRLAND.md, which put it on a workspace without following it.
set -u

if [ $# -eq 0 ]; then
    echo "usage: tools/headless.sh COMMAND [ARGS...]" >&2
    exit 2
fi

command -v Xvfb >/dev/null 2>&1 || {
    echo "headless: Xvfb not found -- run inside 'nix develop' (or tools/devshell.sh)," >&2
    echo "          which provides it." >&2
    exit 1
}

# Pick a display number nothing is using. :0 is almost always the real one.
DISP=""
for n in $(seq 90 99); do
    [ -e "/tmp/.X11-unix/X$n" ] && continue
    DISP=":$n"; break
done
[ -n "$DISP" ] || { echo "headless: no free display number in :90-:99" >&2; exit 1; }

Xvfb "$DISP" -screen 0 1280x800x24 >/dev/null 2>&1 &
XVFB_PID=$!
trap 'kill "$XVFB_PID" 2>/dev/null; wait "$XVFB_PID" 2>/dev/null' EXIT

# Wait for it to accept connections rather than sleeping a fixed amount: a
# fixed sleep is either too slow or occasionally too short, and "occasionally"
# is the worst kind of test failure.
for _ in $(seq 1 100); do
    [ -e "/tmp/.X11-unix/X${DISP#:}" ] && break
    sleep 0.05
done
[ -e "/tmp/.X11-unix/X${DISP#:}" ] || {
    echo "headless: Xvfb did not start on $DISP" >&2
    exit 1
}

DISPLAY="$DISP" "$@"
