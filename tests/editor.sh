#!/usr/bin/env bash
# The document editor: every module, then the whole chain.
#
# Four suites test the pieces against references of their own -- Python's zlib
# and zipfile for the archive, a struct-only font reader for the outlines, a
# second rasteriser for the coverage, and the fixture's own XML for the model.
# The fifth checks what none of them can: that the chain ends with the right
# ink in the right places.
#
# Run from anywhere: tests/editor.sh
# The editor uses `idstd` -- lset, str_join, str_repeat -- so it is built with
# the library, unlike everything above it in tests/run.sh. That file exports
# IDC_NO_STD=1 to keep the compiler's own checks hermetic; a program is not the
# compiler.
set -u
unset IDC_NO_STD
cd "$(dirname "$0")"
fail=0
for t in editor_zip editor_doc editor_ttf editor_ras editor_render; do
    echo "--- $t ---"
    ./$t.sh || fail=1
done
exit "$fail"
