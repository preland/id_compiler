#!/usr/bin/env bash
# Build-cache tests: bin/idc's "Build cache" section (the idlex|idparse
# front-end cache, and the compiled harness/program object cache) must reuse
# a previous build's result exactly when nothing that could change it has
# changed, and must recompute -- never guess -- the moment something has: a
# source file's content, a flag, a stdlib file, or IDC_NO_CACHE. A build whose
# cases fail must never come back cached as a pass, because the cases
# themselves are never skipped -- only the parse and the compile are.
#
# Run from anywhere: tests/cache.sh
set -u
cd "$(dirname "$0")"
BIN_IDC="../bin/idc --allow-untested"

# The environment must not leak in: a developer's own IDSTD_HOME or
# IDC_NO_CACHE would otherwise give this file different results than CI does.
unset IDSTD_HOME IDC_NO_CACHE

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

# An isolated cache, seeded with the already-built stage binaries so this file
# pays to bootstrap the compiler itself only on a checkout that has not built
# it yet -- what is under test here is bin/idc's own fe/ and obj/ entries, and
# they must never be read from or written to a developer's real cache.
CACHE="$TMP/cache"
mkdir -p "$CACHE"
# Copied in this order, and without -p: stale() below compares mtimes, and a
# developer's tree may have files touched more recently than the real cache
# was last built (this file's own fixtures do). Giving every copy "now" as
# its mtime, stage0 first, keeps stage1 no older than stage0 and both no
# older than anything under compiler/{lex,parse} -- so this cache is read as
# current no matter what the source tree's own mtimes say. ccrun and
# idlayout are seeded the same way and for the same reason: without them, the
# very first build below that reaches capped()'s delegating branch, or that
# names a directory, pays to build them (its own fe cache entries, on top of
# the fixture's), which is bin/idc's own behaviour but not what these counts
# are measuring, and a checkout with no idstd/ sibling and IDSTD_HOME unset
# -- exactly what "must not leak in" above gives every build here -- could
# not build either of them at all.
for f in idlex0 idparse0 idlex idparse ccrun idlayout; do
    [ -x "../.idc-cache/$f" ] && cp "../.idc-cache/$f" "$CACHE/"
done
export IDC_CACHE_DIR="$CACHE"

fe_entries()  { find "$CACHE/fe"  -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }
obj_entries() { find "$CACHE/obj" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }

# ms_now -- milliseconds since the epoch (GNU date's %3N), for the "is fast"
# check below; whole seconds ($SECONDS) cannot tell a cache hit apart from a
# miss on a fixture this small.
ms_now() { date +%s%3N; }

PROJ="$TMP/proj"
mkdir -p "$PROJ"
cat > "$PROJ/main.id" <<'EOF'
cache_add(int a, int b) {
  int c = a + b;
} return int c;
(2, 3):(5)
(10, 5):(15)

main(int argc, string[] argv) {
  print("ok");
} return int 0;
EOF

# build NAME [ARGS...] -- bin/idc $PROJ -o $TMP/NAME ARGS..., recording
# combined output, exit status and wall time under $TMP/NAME.{out,rc,ms}.
build() {
    local name="$1"; shift
    local t0 t1
    t0=$(ms_now)
    $BIN_IDC "$PROJ" -o "$TMP/$name" --no-std "$@" >"$TMP/$name.out" 2>&1
    echo $? > "$TMP/$name.rc"
    t1=$(ms_now)
    echo $((t1 - t0)) > "$TMP/$name.ms"
}
rc_of() { cat "$TMP/$1.rc"; }
ms_of()  { cat "$TMP/$1.ms"; }

# -- a build creates one cache entry -----------------------------------------
e0=$(fe_entries)
build cold1
if [ "$(rc_of cold1)" -eq 0 ] && [ "$("$TMP/cold1")" = "ok" ]; then
    ok "setup: the fixture builds and runs"
else
    bad "setup: the fixture builds and runs: $(head -1 "$TMP/cold1.out")"
fi
e1=$(fe_entries); o1=$(obj_entries)
[ "$e1" -eq $((e0 + 1)) ] && ok "a build creates one front-end cache entry" \
    || bad "a build creates one front-end cache entry (had $e0, now $e1)"
[ "$o1" -ge 1 ] && ok "a build creates at least one compiled-object cache entry (harness+program)" \
    || bad "a build creates at least one compiled-object cache entry (had $o1)"

# -- a second identical build is a hit, is fast, and matches exactly --------
build hit1
e2=$(fe_entries); o2=$(obj_entries)
[ "$e2" -eq "$e1" ] && [ "$o2" -eq "$o1" ] \
    && ok "a second identical build creates no new cache entries (a hit)" \
    || bad "a second identical build creates no new cache entries (fe $e1->$e2, obj $o1->$o2)"
if diff -q "$TMP/cold1.out" "$TMP/hit1.out" >/dev/null && [ "$(rc_of hit1)" -eq "$(rc_of cold1)" ]; then
    ok "a cached build's diagnostics and exit status match the uncached build exactly"
else
    bad "a cached build's diagnostics and exit status match the uncached build exactly"
fi
cold_ms=$(ms_of cold1); hit_ms=$(ms_of hit1)
if [ "$hit_ms" -le $((cold_ms / 2 + 1)) ]; then
    ok "a second identical build is fast (${hit_ms}ms vs ${cold_ms}ms cold)"
else
    bad "a second identical build is fast (${hit_ms}ms vs ${cold_ms}ms cold)"
fi

# -- changing a source file's content is a miss ------------------------------
cp "$PROJ/main.id" "$TMP/main.id.orig"
{ printf '// v2\n'; cat "$TMP/main.id.orig"; } > "$PROJ/main.id"
build changed1
e3=$(fe_entries)
[ "$(rc_of changed1)" -eq 0 ] && [ "$e3" -eq $((e2 + 1)) ] \
    && ok "changing a source file's content is a miss" \
    || bad "changing a source file's content is a miss (fe $e2->$e3, rc $(rc_of changed1))"

# -- touching a file without changing its content is a hit -------------------
# This cache is content-addressed, not mtime-addressed, on purpose: bin/idc
# already has one mtime-based staleness check (whether to rebuild the
# compiler itself, see stale() and its docstring note above), and a touch
# with no real edit defeating THAT is exactly the cost this cache exists to
# remove. A hit here is the content-addressing working as intended, not an
# oversight.
touch "$PROJ/main.id"
build touched1
e4=$(fe_entries)
[ "$(rc_of touched1)" -eq 0 ] && [ "$e4" -eq "$e3" ] \
    && ok "touching a file without changing its content is a hit (by design -- content-addressed, not mtime-addressed)" \
    || bad "touching a file without changing its content stayed a hit (fe $e3->$e4)"

# Restore the original content: this should hit the ORIGINAL entry again.
cp "$TMP/main.id.orig" "$PROJ/main.id"
build restored1
e5=$(fe_entries)
[ "$(rc_of restored1)" -eq 0 ] && [ "$e5" -eq "$e4" ] \
    && ok "restoring the original content hits the original entry again" \
    || bad "restoring the original content hits the original entry again (fe $e4->$e5)"

# -- changing a flag is a miss ------------------------------------------------
build checked1 --check
e6=$(fe_entries)
[ "$(rc_of checked1)" -eq 0 ] && [ "$e6" -eq $((e5 + 1)) ] \
    && ok "changing a flag (--check) is a miss" \
    || bad "changing a flag (--check) is a miss (fe $e5->$e6, rc $(rc_of checked1))"
build checked2 --check
e7=$(fe_entries)
[ "$e7" -eq "$e6" ] && diff -q "$TMP/checked1.out" "$TMP/checked2.out" >/dev/null \
    && ok "the same flag on the next build is a hit again" \
    || bad "the same flag on the next build is a hit again (fe $e6->$e7)"

# -- changing a standard-library file is a miss ------------------------------
STD="$TMP/std"; mkdir -p "$STD"
cat > "$STD/lib.id" <<'EOF'
std_helper(int x) {
  int y = x * 2;
} return int y;
(3):(6)
(4):(8)
EOF
APP="$TMP/app"; mkdir -p "$APP"
cat > "$APP/main.id" <<'EOF'
main(int argc, string[] argv) {
  print("ok");
} return int 0;
EOF
e8=$(fe_entries)
$BIN_IDC --std "$STD" "$APP" -o "$TMP/std1" >"$TMP/std1.out" 2>&1; std1_rc=$?
e9=$(fe_entries)
[ "$std1_rc" -eq 0 ] && [ "$e9" -eq $((e8 + 1)) ] \
    && ok "setup: a build against a --std library creates its own cache entry" \
    || bad "setup: a build against a --std library creates its own cache entry (fe $e8->$e9, rc $std1_rc)"
sed -i 's/x \* 2/x * 2 + 0/' "$STD/lib.id"
$BIN_IDC --std "$STD" "$APP" -o "$TMP/std2" >"$TMP/std2.out" 2>&1; std2_rc=$?
e10=$(fe_entries)
[ "$std2_rc" -eq 0 ] && [ "$e10" -eq $((e9 + 1)) ] \
    && ok "changing a standard-library file is a miss" \
    || bad "changing a standard-library file is a miss (fe $e9->$e10, rc $std2_rc)"

# -- IDC_NO_CACHE=1 bypasses the cache entirely ------------------------------
e11=$(fe_entries); o11=$(obj_entries)
IDC_NO_CACHE=1 $BIN_IDC "$PROJ" -o "$TMP/nc1" --no-std >"$TMP/nc1.out" 2>&1; nc1_rc=$?
IDC_NO_CACHE=1 $BIN_IDC "$PROJ" -o "$TMP/nc2" --no-std >"$TMP/nc2.out" 2>&1; nc2_rc=$?
e12=$(fe_entries); o12=$(obj_entries)
[ "$nc1_rc" -eq 0 ] && [ "$nc2_rc" -eq 0 ] && [ "$e12" -eq "$e11" ] && [ "$o12" -eq "$o11" ] \
    && ok "IDC_NO_CACHE=1 reads and writes neither cache" \
    || bad "IDC_NO_CACHE=1 reads and writes neither cache (fe $e11->$e12, obj $o11->$o12)"

# -- a build whose cases fail is never cached as a pass ----------------------
FAILPROJ="$TMP/failproj"; mkdir -p "$FAILPROJ"
cat > "$FAILPROJ/main.id" <<'EOF'
cache_fail(int a) {
  int b = a + 1;
} return int b;
(1):(2)
(1):(999)

main(int argc, string[] argv) {
  print("unused");
} return int 0;
EOF
$BIN_IDC "$FAILPROJ" -o "$TMP/fail1" --no-std >"$TMP/fail1.out" 2>&1; fail1_rc=$?
$BIN_IDC "$FAILPROJ" -o "$TMP/fail2" --no-std >"$TMP/fail2.out" 2>&1; fail2_rc=$?
if [ "$fail1_rc" -ne 0 ] && [ "$fail2_rc" -ne 0 ]; then
    ok "a build whose cases fail exits nonzero, before and after its harness binary is cached"
else
    bad "a build whose cases fail exits nonzero, before and after its harness binary is cached (rc1=$fail1_rc rc2=$fail2_rc)"
fi
diff -q "$TMP/fail1.out" "$TMP/fail2.out" >/dev/null \
    && ok "a failing build's diagnostics are identical whether or not its harness was cached" \
    || bad "a failing build's diagnostics are identical whether or not its harness was cached"
if [ ! -e "$TMP/fail1" ] && [ ! -e "$TMP/fail2" ]; then
    ok "a failing build produces no output binary, cached harness or not"
else
    bad "a failing build produces no output binary, cached harness or not"
fi

# -- the case-result cache ----------------------------------------------------
# A case whose key has passed before is not run again. The observable is time:
# slow_caller's two cases sleep 1.5 s each, so a build that runs them takes
# at least 3 s and one that does not is well under it. slow_caller calls
# slow_leaf, and other_fn is unrelated to both.
SLOW="$TMP/slow"; mkdir -p "$SLOW"
cat > "$SLOW/leaf.id" <<'EOF'
slow_leaf(int a) {
  int b = a + 1;
} return int b;
(1):(2)
(2):(3)

slow_caller(int a) {
  sleep_ms(1500);
  int b = slow_leaf(a);
} return int b;
(1):(2)
(5):(6)
EOF
cat > "$SLOW/main.id" <<'EOF'
other_fn(int a) {
  int b = a * 2;
} return int b;
(1):(2)
(3):(6)

main(int argc, string[] argv) {
  print("ok");
} return int 0;
(1, ["p"]):(0)
(2, ["p", "q"]):(0)
EOF
cp "$SLOW/leaf.id" "$TMP/leaf.id.orig"
slow_build() {
    local name="$1" t0 t1; shift
    t0=$(ms_now)
    $BIN_IDC "$SLOW" -o "$TMP/$name" --no-std "$@" >"$TMP/$name.out" 2>&1
    echo $? > "$TMP/$name.rc"
    t1=$(ms_now)
    echo $((t1 - t0)) > "$TMP/$name.ms"
}
case_entries() { find "$CACHE/cases" -mindepth 1 -maxdepth 1 -type f ! -name '*.tmp' 2>/dev/null | wc -l | tr -d ' '; }

slow_build sc1
[ "$(rc_of sc1)" -eq 0 ] && [ "$(ms_of sc1)" -ge 3000 ] \
    && ok "setup: the slow fixture builds, running its slow cases ($(ms_of sc1)ms)" \
    || bad "setup: the slow fixture builds, running its slow cases (rc $(rc_of sc1), $(ms_of sc1)ms): $(head -1 "$TMP/sc1.out")"
[ "$(case_entries)" -ge 1 ] && ok "a build with cases writes a pass list" \
    || bad "a build with cases writes a pass list (found $(case_entries))"

slow_build sc2
[ "$(rc_of sc2)" -eq 0 ] && [ "$(ms_of sc2)" -lt 3000 ] \
    && ok "an identical rebuild runs none of its already-passed cases ($(ms_of sc2)ms)" \
    || bad "an identical rebuild runs none of its already-passed cases (rc $(rc_of sc2), $(ms_of sc2)ms)"

sed -i 's/a \* 2/a + a/' "$SLOW/main.id"
slow_build sc3
[ "$(rc_of sc3)" -eq 0 ] && [ "$(ms_of sc3)" -lt 3000 ] \
    && ok "editing an unrelated function does not rerun a cached case ($(ms_of sc3)ms)" \
    || bad "editing an unrelated function does not rerun a cached case (rc $(rc_of sc3), $(ms_of sc3)ms)"

sed -i 's/a + 1/1 + a/' "$SLOW/leaf.id"
slow_build sc4
[ "$(rc_of sc4)" -eq 0 ] && [ "$(ms_of sc4)" -ge 3000 ] \
    && ok "editing a callee reruns its caller's cached cases ($(ms_of sc4)ms)" \
    || bad "editing a callee reruns its caller's cached cases (rc $(rc_of sc4), $(ms_of sc4)ms)"

sed -i 's/1 + a/a + 2/' "$SLOW/leaf.id"
slow_build sc5
if [ "$(rc_of sc5)" -ne 0 ] && [ "$(ms_of sc5)" -lt 3000 ] \
   && grep -q 'leaf.id:4: test failed: slow_leaf(1) = 3, expected 2' "$TMP/sc5.out" \
   && grep -q 'leaf.id:11: not run: slow_caller(1) depends on slow_leaf, whose case at .*leaf.id:4 failed' "$TMP/sc5.out" \
   && ! grep -q 'test failed: slow_caller' "$TMP/sc5.out"; then
    ok "a callee's broken edit fails its own cases, and its caller's are not run ($(ms_of sc5)ms)"
else
    bad "a callee's broken edit fails its own cases, and its caller's are not run (rc $(rc_of sc5), $(ms_of sc5)ms): $(head -4 "$TMP/sc5.out")"
fi
slow_build sc6
if [ "$(rc_of sc6)" -ne 0 ] && diff -q "$TMP/sc5.out" "$TMP/sc6.out" >/dev/null; then
    ok "a failed case is never recorded as a pass: the same build fails the same way"
else
    bad "a failed case is never recorded as a pass: the same build fails the same way (rc $(rc_of sc6))"
fi

cp "$TMP/leaf.id.orig" "$SLOW/leaf.id"
slow_build sc7
[ "$(rc_of sc7)" -eq 0 ] && [ "$(ms_of sc7)" -lt 3000 ] \
    && ok "restoring the callee finds the caller's earlier passes again ($(ms_of sc7)ms)" \
    || bad "restoring the callee finds the caller's earlier passes again (rc $(rc_of sc7), $(ms_of sc7)ms)"

IDC_NO_CACHE=1 slow_build sc8
[ "$(rc_of sc8)" -eq 0 ] && [ "$(ms_of sc8)" -ge 3000 ] \
    && ok "IDC_NO_CACHE=1 runs every case ($(ms_of sc8)ms)" \
    || bad "IDC_NO_CACHE=1 runs every case (rc $(rc_of sc8), $(ms_of sc8)ms)"

# -- per-unit compilation -----------------------------------------------------
# The C is compiled as translation units cached one by one (bin/idc's
# unit_build). With IDC_UNIT_FILES=1 each source file is its own unit, so an
# edit to one function must add objects for that file's unit alone (its
# program unit, its harness unit, and the harness's case table) and reuse the
# rest; and the program must behave exactly as the one-file build does.
UNITS="$TMP/units"; mkdir -p "$UNITS/parts"
for n in 1 2 3; do
cat > "$UNITS/parts/part$n.id" <<EOF
unit_fn$n(int a) {
  int b = a + $n;
} return int b;
(1):($((1 + n)))
(2):($((2 + n)))
EOF
done
cat > "$UNITS/main.id" <<'EOF'
main(int argc, string[] argv) {
  int s = unit_fn1(argc) + unit_fn2(argc) + unit_fn3(argc);
  print("sum " + s);
} return int 0;
(1, ["p"]):(0) then prints:("sum 9\n")
(2, ["p", "q"]):(0) then prints:("sum 12\n")
EOF
unit_entries() { find "$CACHE/units" -mindepth 1 -maxdepth 1 -name '*.o' 2>/dev/null | wc -l | tr -d ' '; }
ub() { local name="$1"; shift
       IDC_UNIT_FILES=1 "$@" $BIN_IDC "$UNITS" -o "$TMP/$name" --no-std >"$TMP/$name.out" 2>&1; echo $? > "$TMP/$name.rc"; }

u0=$(unit_entries)
ub un1
u1=$(unit_entries)
[ "$(rc_of un1)" -eq 0 ] && [ "$("$TMP/un1")" = "sum 9" ] && [ "$u1" -ge $((u0 + 8)) ] \
    && ok "setup: a four-file program builds from its units ($((u1 - u0)) unit objects)" \
    || bad "setup: a four-file program builds from its units (rc $(rc_of un1), $((u1 - u0)) objects): $(head -1 "$TMP/un1.out")"

ub un2 env IDC_UNITS=0
if [ "$(rc_of un2)" -eq 0 ] && [ "$("$TMP/un2")" = "$("$TMP/un1")" ] && [ "$(unit_entries)" -eq "$u1" ]; then
    ok "IDC_UNITS=0 builds the same program as one file, and touches no unit"
else
    bad "IDC_UNITS=0 builds the same program as one file, and touches no unit (rc $(rc_of un2))"
fi

sed -i 's/a + 2;/2 + a;/' "$UNITS/parts/part2.id"
ub un3
u3=$(unit_entries)
if [ "$(rc_of un3)" -eq 0 ] && [ "$("$TMP/un3")" = "sum 9" ] && [ "$u3" -gt "$u1" ] && [ "$u3" -le $((u1 + 3)) ]; then
    ok "editing one function compiles only its own file's units ($((u3 - u1)) new objects)"
else
    bad "editing one function compiles only its own file's units (rc $(rc_of un3), $((u3 - u1)) new objects)"
fi

sed -i 's/2 + a;/a + 20;/' "$UNITS/parts/part2.id"
sed -i 's/(1):(3)/(1):(21)/; s/(2):(4)/(2):(22)/' "$UNITS/parts/part2.id"
sed -i 's/sum 9/sum 27/; s/sum 12/sum 30/' "$UNITS/main.id"
ub un4
[ "$(rc_of un4)" -eq 0 ] && [ "$("$TMP/un4")" = "sum 27" ] \
    && ok "a changed unit is linked in, not a stale object: the program sees the edit" \
    || bad "a changed unit is linked in, not a stale object: the program sees the edit (rc $(rc_of un4), prints '$("$TMP/un4" 2>/dev/null)')"

# -- the type check's cache ---------------------------------------------------
# A function whose check came out clean before, and whose key says nothing it
# reads has changed, is not type-checked again (compiler/parse/mid/types/
# check/walk/check/tk/). The bar is that a warm build says exactly what a
# cold one does: after each kind of edit below, the diagnostics, the exit
# status and the C of a build with the cache must equal those of a build with
# IDC_NO_CACHE=1. The edits that break the program break it in a function
# that was NOT edited -- a caller, a reader -- which is exactly the function a
# stale key would skip. A function's key also covers the cases of the
# function before it (they are parsed into its run), so the caller is filed
# BEFORE its callee: the callee's edited cases then change the callee's own
# key and never the caller's, and only the meaning of the callee's name can.
TCP="$TMP/tcp"; mkdir -p "$TCP/parts"
cat > "$TCP/parts/a_use.id" <<'EOF'
lib_use(int a) {
  int d = lib_add(a, 1);
} return int d;
(1):(2)
(5):(6)
EOF
cat > "$TCP/parts/lib.id" <<'EOF'
lib_add(int a, int b) {
  int c = a + b;
} return int c;
(1, 2):(3)
(2, 2):(4)
EOF
cat > "$TCP/parts/exp.id" <<'EOF'
exp_setup() {
  export int ex_val = 3;
} return void;
():()
():() then exp_read:(4)

exp_read() {
  int r = (import ex_val) + 1;
} return int r;
given exp_setup ():(4)
given exp_setup ():(4) then exp_read:(4)
EOF
cat > "$TCP/main.id" <<'EOF'
main(int argc, string[] argv) {
  int u = lib_use(argc);
  print("u " + u);
} return int 0;
(1, ["p"]):(0) then prints:("u 2\n")
(2, ["p", "q"]):(0) then prints:("u 3\n")
EOF
cp "$TCP/parts/lib.id" "$TMP/tc_lib.orig"; cp "$TCP/parts/exp.id" "$TMP/tc_exp.orig"
tc_lists() { cat "$CACHE"/tc/* 2>/dev/null | wc -l | tr -d ' '; }
tcb() { local name="$1"; shift
        rm -f "$TMP/tc_emit.c"
        "$@" $BIN_IDC "$TCP" --no-std --emit-c "$TMP/tc_emit.c" >"$TMP/$name.out" 2>&1; echo $? > "$TMP/$name.rc"
        [ -e "$TMP/tc_emit.c" ] && mv "$TMP/tc_emit.c" "$TMP/$name.c"; }
tc_same() { # tc_same WARM COLD -- same exit, same words, same C (or both no C)
    [ "$(rc_of "$1")" = "$(rc_of "$2")" ] && diff -q "$TMP/$1.out" "$TMP/$2.out" >/dev/null \
        && { [ ! -e "$TMP/$1.c" ] && [ ! -e "$TMP/$2.c" ] || cmp -s "$TMP/$1.c" "$TMP/$2.c"; }
}
tc_case() { # tc_case LABEL SED_EXPR FILE -- warm the cache on the original, edit, compare
    local label="$1" expr="$2" file="$3"
    cp "$TMP/tc_lib.orig" "$TCP/parts/lib.id"; cp "$TMP/tc_exp.orig" "$TCP/parts/exp.id"
    tcb tcw0
    local k0; k0=$(tc_lists)
    sed -i "$expr" "$TCP/parts/$file"
    rm -f "$TMP/tcw.c" "$TMP/tcc.c"
    tcb tcw
    TC_K0="$k0"; TC_K1=$(tc_lists)
    tcb tcc env IDC_NO_CACHE=1
    if [ "$(rc_of tcw0)" -eq 0 ] && [ "$k0" -ge 5 ] && tc_same tcw tcc; then
        ok "type check cache: after $label, a warm build equals a cold one (rc $(rc_of tcw))"
    else
        bad "type check cache: after $label, a warm build equals a cold one (warm rc $(rc_of tcw), cold rc $(rc_of tcc), $k0 keys): $(diff "$TMP/tcw.out" "$TMP/tcc.out" | head -3)"
    fi
}
tc_case "a body edit" 's/a + b;/b + a;/' lib.id
[ "$TC_K1" -eq $((TC_K0 + 1)) ] \
    && ok "a body edit gives exactly one function a new key: the edited one" \
    || bad "a body edit gives exactly one function a new key: the edited one ($TC_K0 -> $TC_K1 keys)"
tc_case "a signature change" 's/^lib_add(int a, int b) {/lib_add(int a, string b) {/; s/  int c = a + b;/  int c = a + to_int(b);/; s/^(1, 2):(3)/(1, "2"):(3)/; s/^(2, 2):(4)/(2, "2"):(4)/' lib.id
tc_case "an export-type change" 's/export int ex_val = 3;/export string ex_val = "3";/' exp.id
tc_case "a rename" 's/^lib_add(/lib_sum(/' lib.id
tc_case "a deleted callee" '1,5d' lib.id
if [ "$(rc_of tcc)" -ne 0 ] && grep -q 'lib_add' "$TMP/tcc.out"; then
    ok "setup: deleting the callee leaves its caller broken, and the caller is where it is reported"
else
    bad "setup: deleting the callee leaves its caller broken: $(head -2 "$TMP/tcc.out")"
fi
cp "$TMP/tc_lib.orig" "$TCP/parts/lib.id"; cp "$TMP/tc_exp.orig" "$TCP/parts/exp.id"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
