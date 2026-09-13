#!/usr/bin/env bash
# mkodt.sh -- write the editor's test document, an OpenDocument text.
#
#   tools/mkodt.sh [OUT.odt]      (default: tests/fixtures/sample.odt)
#
# tools/mkodt (in `id`) writes the archive. This builds it and runs it with the
# caller's arguments in the caller's directory; the build's own output goes to
# stderr.
#
# The program is built with idstd whatever the caller's IDC_NO_STD says, as
# tools/fbtext.sh is: tests/run.sh exports IDC_NO_STD=1 for everything it runs.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

env -u IDC_NO_STD "$ROOT/bin/idc" "$ROOT/tools/mkodt" --allow-untested -o "$TMP/mkodt" >&2 \
    || { echo "mkodt.sh: failed to build tools/mkodt" >&2; exit 1; }

"$TMP/mkodt" "$@"
