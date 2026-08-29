#!/usr/bin/env bash
# Run a command inside the `id` development toolchain.
#
# This repo is developed on NixOS, where dev headers/libraries are NOT on the
# default compiler search path -- they are provided by the Nix dev shell, which
# sets NIX_CFLAGS_COMPILE / NIX_LDFLAGS so the wrapped `cc`/`clang` find them
# without any pkg-config plumbing. Every build that links a graphics backend or
# targets LLVM/WASM must run inside this shell.
#
#   tools/devshell.sh './idc.py demos/gfxdemo --backend backends/gfx -o /tmp/gfxdemo'
#   tools/devshell.sh 'bash tests/run.sh'
#
# The toolchain is defined once in flake.nix (also used by `nix develop` and
# direnv's .envrc). This wrapper prefers that flake dev shell so there is a
# single source of truth; if flakes are unavailable it falls back to an
# equivalent `nix-shell -p` invocation.
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

if command -v nix >/dev/null 2>&1 \
   && nix develop "path:$REPO" --command true >/dev/null 2>&1; then
  exec nix develop "path:$REPO" --command bash -c "$*"
fi

exec nix-shell -p \
  libx11 libGL libglvnd mesa pkg-config \
  llvm clang lld wabt wasmtime \
  --run "$*"
