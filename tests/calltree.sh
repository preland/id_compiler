#!/usr/bin/env bash
# `idc PROJECT --calls` and tools/calltree.sh, against a small fixture
# project: a direct call, self-recursion, a function used as a value, a call
# into the real standard library, and a call to a builtin. README.md's "The
# function dependency tree" section documents the row and tree formats this
# checks.
#
# The fixture is merged with the real standard library (unlike most of this
# suite, which sets IDC_NO_STD=1) specifically to exercise the [idstd] mark,
# so it locates one the way tests/idstd_real.sh does and skips if there is
# none -- this file is not the place to assert anything about the library
# itself, only that calltree.sh recognises where one of its functions lives.
#
# Run from anywhere: tests/calltree.sh
set -u
cd "$(dirname "$0")"
HERE=$(pwd)
IDC="$HERE/../bin/idc"
CALLTREE="$HERE/../tools/calltree.sh"

STD="${IDSTD_HOME:-}"
if [ -z "$STD" ]; then
    R=$(cd .. && pwd)
    for up in "$R/../idstd" "$R/../../idstd"; do
        [ -d "$up" ] && { STD="$up"; break; }
    done
    STD="${STD:-$R/../idstd}"
fi
if [ ! -d "$STD" ]; then
    echo "SKIP: no standard library at '$STD' (set IDSTD_HOME to point at one)"
    exit 0
fi
STD=$(cd "$STD" && pwd -P)
export IDSTD_HOME="$STD"
LSET_LOC="$STD/core/data/lst/lst.id:21"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; echo "$2" | sed 's/^/  /'; }

# countdown: a direct call and self-recursion. holder: countdown named as a
# value, with no accompanying call (docs/TESTS.md's kind=value). fill_xs:
# a direct call (countdown) and a call into the real standard library
# (lset). main: a direct call (fill_xs, holder) and a call to a builtin
# (len). Every function stays within the 3-action-per-block and
# no-call-in-a-call's-argument rules bin/idc itself enforces.
PROJ="$TMP/proj"
mkdir -p "$PROJ"
cat > "$PROJ/calc.id" <<'EOF'
countdown(int n) {
  int r = n;
  if(n > 0) {
    r = countdown(n - 1);
  }
} return int r;

holder() {
  func(int) return int g = countdown;
} return void;
EOF
cat > "$PROJ/main.id" <<'EOF'
main(int argc, string[] argv) {
  int[] xs = fill_xs(argc);
  int n = len(xs);
  holder();
} return int n;

fill_xs(int argc) {
  int[] xs = [1, 2, 3];
  int c = countdown(argc);
  lset(xs, 0, c);
} return int[] xs;
EOF

# -- idc PROJECT --calls -----------------------------------------------------
"$IDC" "$PROJ" --calls > "$TMP/calls.out" 2> "$TMP/calls.err"
calls_rc=$?
if [ "$calls_rc" -ne 0 ]; then
    bad "idc --calls exits 0 on a fixture with no rule violations" "exit $calls_rc: $(cat "$TMP/calls.err")"
else
    ok "idc --calls exits 0 on a fixture with no rule violations"
fi

# Only the fixture's own four functions' edges -- the rest of the merged
# standard library's edges are real but not this test's concern.
awk -F'|' 'NF==5 && ($1=="countdown"||$1=="holder"||$1=="main"||$1=="fill_xs")' "$TMP/calls.out" \
    | LC_ALL=C sort > "$TMP/edges.got"
cat > "$TMP/edges.want" <<EOF
countdown|$PROJ/calc.id:1|countdown|$PROJ/calc.id:1|call
countdown|$PROJ/calc.id:1|countdown|$PROJ/calc.id:1|value
holder|$PROJ/calc.id:8|countdown|$PROJ/calc.id:1|value
main|$PROJ/main.id:1|fill_xs|$PROJ/main.id:7|call
main|$PROJ/main.id:1|fill_xs|$PROJ/main.id:7|value
main|$PROJ/main.id:1|holder|$PROJ/calc.id:8|call
main|$PROJ/main.id:1|holder|$PROJ/calc.id:8|value
main|$PROJ/main.id:1|len||call
fill_xs|$PROJ/main.id:7|countdown|$PROJ/calc.id:1|call
fill_xs|$PROJ/main.id:7|countdown|$PROJ/calc.id:1|value
fill_xs|$PROJ/main.id:7|lset|$LSET_LOC|call
fill_xs|$PROJ/main.id:7|lset|$LSET_LOC|value
EOF
LC_ALL=C sort -o "$TMP/edges.want" "$TMP/edges.want"
if diff -u "$TMP/edges.want" "$TMP/edges.got" > "$TMP/edges.diff"; then
    ok "--calls edges match the fixture's source exactly (direct call, recursion, value, idstd, builtin)"
else
    bad "--calls edges match the fixture's source exactly" "$(cat "$TMP/edges.diff")"
fi

# One row per fixture function in the case-count section, all short of cases
# (the fixture writes none -- --calls does not require them).
awk -F'|' 'NF==3 && ($1=="countdown"||$1=="holder"||$1=="main"||$1=="fill_xs")' "$TMP/calls.out" \
    | LC_ALL=C sort > "$TMP/cases.got"
printf '%s\n' \
    "countdown|$PROJ/calc.id:1|0" \
    "holder|$PROJ/calc.id:8|0" \
    "main|$PROJ/main.id:1|0" \
    "fill_xs|$PROJ/main.id:7|0" | LC_ALL=C sort > "$TMP/cases.want"
if diff -u "$TMP/cases.want" "$TMP/cases.got" > "$TMP/cases.diff"; then
    ok "--calls case-count rows match (0 cases each; --calls does not require them)"
else
    bad "--calls case-count rows match" "$(cat "$TMP/cases.diff")"
fi

# -- tools/calltree.sh: forward tree from main ------------------------------
"$CALLTREE" "$PROJ" main > "$TMP/tree.got" 2> "$TMP/tree.err"
tree_rc=$?
cat > "$TMP/tree.want" <<EOF
main  $PROJ/main.id:1  (0 cases)
├── fill_xs  $PROJ/main.id:7  (0 cases)
│   ├── countdown  $PROJ/calc.id:1  (0 cases)
│   │   └── countdown  $PROJ/calc.id:1  (0 cases) (recursive)
│   └── lset  $LSET_LOC  (2 cases)  [idstd]
├── holder  $PROJ/calc.id:8  (0 cases)
│   └── countdown  $PROJ/calc.id:1  (0 cases) (shown above)
└── len  [builtin]
EOF
if [ "$tree_rc" -ne 0 ]; then
    bad "calltree.sh PROJECT main renders the forward tree" "exit $tree_rc: $(cat "$TMP/tree.err")"
elif diff -u "$TMP/tree.want" "$TMP/tree.got" > "$TMP/tree.diff"; then
    ok "calltree.sh PROJECT main renders the forward tree (recursive, shown above, builtin, idstd)"
else
    bad "calltree.sh PROJECT main renders the forward tree" "$(cat "$TMP/tree.diff")"
fi

# -- tools/calltree.sh --callers, --depth ------------------------------------
"$CALLTREE" "$PROJ" countdown --callers --depth 1 > "$TMP/callers.got" 2> "$TMP/callers.err"
callers_rc=$?
cat > "$TMP/callers.want" <<EOF
countdown  $PROJ/calc.id:1  (0 cases)
├── countdown  $PROJ/calc.id:1  (0 cases) (recursive)
├── fill_xs  $PROJ/main.id:7  (0 cases)
└── holder  $PROJ/calc.id:8  (0 cases)
EOF
if [ "$callers_rc" -ne 0 ]; then
    bad "calltree.sh PROJECT countdown --callers --depth 1" "exit $callers_rc: $(cat "$TMP/callers.err")"
elif diff -u "$TMP/callers.want" "$TMP/callers.got" > "$TMP/callers.diff"; then
    ok "calltree.sh PROJECT countdown --callers --depth 1 inverts the tree and stops at depth 1"
else
    bad "calltree.sh PROJECT countdown --callers --depth 1" "$(cat "$TMP/callers.diff")"
fi

# -- tools/calltree.sh --order: callees before callers, cycle grouped -------
printf '%s\n' \
    "$PROJ/main.id:1|main" \
    "$PROJ/main.id:7|fill_xs" \
    "$PROJ/calc.id:8|holder" \
    "$PROJ/calc.id:1|countdown" > "$TMP/batch.txt"
"$CALLTREE" "$PROJ" --order "$TMP/batch.txt" > "$TMP/order.got" 2> "$TMP/order.err"
order_rc=$?
cat > "$TMP/order.want" <<EOF
# cycle: countdown
$PROJ/calc.id:1|countdown
$PROJ/main.id:7|fill_xs
$PROJ/calc.id:8|holder
$PROJ/main.id:1|main
EOF
if [ "$order_rc" -ne 0 ]; then
    bad "calltree.sh PROJECT --order orders callees before callers, self-recursion grouped" "exit $order_rc: $(cat "$TMP/order.err")"
elif diff -u "$TMP/order.want" "$TMP/order.got" > "$TMP/order.diff"; then
    ok "calltree.sh PROJECT --order orders callees before callers, self-recursion grouped"
else
    bad "calltree.sh PROJECT --order orders callees before callers, self-recursion grouped" "$(cat "$TMP/order.diff")"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
