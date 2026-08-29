#!/usr/bin/env bash
# Standard-library tests: implicit import, and the transitive dependency
# resolution it is built on.
#
# `idstd` is imported by DEFAULT -- a program calls a library function with no
# conf.id line and no flag. That is a change to how every program is built,
# so it needs its own file of checks, and every one of them runs against BOTH
# compilers: bin/idc and idc.py must agree about what a program's sources are,
# or they stop emitting byte-identical C for every program at once.
#
# Everything here uses tests/fixtures/idstd rather than the real ../idstd, so
# the suite says the same thing on a checkout that has no standard library
# beside it and on one that does, and does not change meaning as the real
# library grows.
#
# Run from anywhere: tests/stdlib.sh
set -u
cd "$(dirname "$0")"
ROOT=".."
BIN_IDC=../bin/idc
IDC_PY=../idc.py
FIXTURE=$(cd fixtures/idstd && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

# The environment must not leak in: a developer with IDSTD_HOME set, or with
# IDC_NO_STD exported, would otherwise get different results from this file
# than CI does.
unset IDSTD_HOME IDC_NO_STD

# run_both DESC EXPECTED_STDOUT -- build $TMP/proj with each compiler, run it,
# compare output, and check the two emitted C files are byte-identical.
run_both() {
    local desc="$1" want="$2" got

    for cc_name in idc idc.py; do
        case "$cc_name" in
            idc)    build=("$BIN_IDC" --std "$FIXTURE" "$TMP/proj" -o "$TMP/out.$cc_name") ;;
            idc.py) build=("$IDC_PY"  --std "$FIXTURE" "$TMP/proj" -o "$TMP/out.$cc_name") ;;
        esac
        if ! "${build[@]}" >"$TMP/build.err" 2>&1; then
            bad "$desc ($cc_name: build failed: $(head -1 "$TMP/build.err"))"
            return
        fi
        got=$("$TMP/out.$cc_name" 2>&1)
        if [ "$got" != "$want" ]; then
            bad "$desc ($cc_name: got '$got', want '$want')"
            return
        fi
    done

    "$BIN_IDC" --std "$FIXTURE" "$TMP/proj" --emit-c "$TMP/a.c" >/dev/null 2>&1
    "$IDC_PY"  --std "$FIXTURE" "$TMP/proj" --emit-c "$TMP/b.c" >/dev/null 2>&1
    if cmp -s "$TMP/a.c" "$TMP/b.c"; then
        ok "$desc"
    else
        bad "$desc (emitted C differs between compilers)"
    fi
}

# -- 1. a program calls the stdlib with no conf.id at all -----------------
rm -rf "$TMP/proj"; mkdir -p "$TMP/proj"
cat > "$TMP/proj/main.id" <<'EOF'
main(int argc, string[] argv) {
    int a = tfx_max(3, 9);
    int b = tfx_abs(0 - 4);
    print("" + a + "\n" + b);
} return int 0;
EOF
run_both "a project reaches the stdlib with no conf.id" "9
4"

# -- 2. a nested stdlib directory is reached, not just its top level --------
rm -rf "$TMP/proj"; mkdir -p "$TMP/proj"
cat > "$TMP/proj/main.id" <<'EOF'
main(int argc, string[] argv) {
    string r = tstr_twice("ab");
    print(r);
} return int 0;
EOF
run_both "the whole stdlib tree is merged, not just its root" "abab"

# -- 3. a single FILE gets the stdlib too ----------------------------------
# The tutorial path (`idc prog.id`) is the one that most needs fx_max to
# already exist, so it must not be the one path that misses out.
cat > "$TMP/single.id" <<'EOF'
main(int argc, string[] argv) {
    int r = tfx_max(2, 7);
    print(r);
} return int 0;
EOF
sf_ok=1
for cc in "$BIN_IDC" "$IDC_PY"; do
    "$cc" --std "$FIXTURE" "$TMP/single.id" -o "$TMP/single.bin" >/dev/null 2>&1 \
        || { sf_ok=0; break; }
    [ "$("$TMP/single.bin")" = "7" ] || { sf_ok=0; break; }
done
[ "$sf_ok" -eq 1 ] && ok "a single .id file gets the stdlib too" \
                   || bad "a single .id file gets the stdlib too"

# -- 4. --no-std really means no stdlib ------------------------------------
# This is not a nicety. idstd cannot import itself, the bootstrap stages
# define their own helpers, and tests/invalid's diagnostics must not shift
# because a library appeared in the program.
rm -rf "$TMP/proj"; mkdir -p "$TMP/proj"
cat > "$TMP/proj/main.id" <<'EOF'
main(int argc, string[] argv) {
    int r = tfx_max(3, 9);
    print(r);
} return int 0;
EOF
ns_ok=1
for cc in "$BIN_IDC" "$IDC_PY"; do
    if "$cc" --no-std --std "$FIXTURE" "$TMP/proj" -o "$TMP/ns" >"$TMP/ns.err" 2>&1; then
        ns_ok=0   # it built, so the stdlib was still there
    elif ! grep -q "no such function 'tfx_max'" "$TMP/ns.err"; then
        ns_ok=0   # it failed for the wrong reason
    fi
done
[ "$ns_ok" -eq 1 ] && ok "--no-std removes the stdlib (both compilers)" \
                   || bad "--no-std removes the stdlib (both compilers)"

# -- 5. IDC_NO_STD does the same, for scripts that cannot pass a flag ------
env_ok=1
for cc in "$BIN_IDC" "$IDC_PY"; do
    if IDC_NO_STD=1 "$cc" --std "$FIXTURE" "$TMP/proj" -o "$TMP/ns" >"$TMP/ns.err" 2>&1; then
        env_ok=0
    elif ! grep -q "no such function 'tfx_max'" "$TMP/ns.err"; then
        env_ok=0
    fi
done
[ "$env_ok" -eq 1 ] && ok "IDC_NO_STD=1 removes the stdlib (both compilers)" \
                    || bad "IDC_NO_STD=1 removes the stdlib (both compilers)"

# -- 6. $IDSTD_HOME locates it ---------------------------------------------
rm -rf "$TMP/proj"; mkdir -p "$TMP/proj"
cat > "$TMP/proj/main.id" <<'EOF'
main(int argc, string[] argv) {
    int r = tfx_max(1, 5);
    print(r);
} return int 0;
EOF
home_ok=1
for cc in "$BIN_IDC" "$IDC_PY"; do
    IDSTD_HOME="$FIXTURE" "$cc" "$TMP/proj" -o "$TMP/h" >/dev/null 2>&1 || { home_ok=0; break; }
    [ "$("$TMP/h")" = "5" ] || { home_ok=0; break; }
done
[ "$home_ok" -eq 1 ] && ok "\$IDSTD_HOME locates the stdlib" \
                     || bad "\$IDSTD_HOME locates the stdlib"

# -- 7. a bad --std is reported, not ignored -------------------------------
bad_ok=1
for cc in "$BIN_IDC" "$IDC_PY"; do
    "$cc" --std "$TMP/nope" "$TMP/proj" -o "$TMP/x" >"$TMP/x.err" 2>&1 && bad_ok=0
    grep -qi "not a directory\|does not name a directory" "$TMP/x.err" || bad_ok=0
done
[ "$bad_ok" -eq 1 ] && ok "a --std that is not a directory is reported" \
                    || bad "a --std that is not a directory is reported"

# -- 8. transitive source imports (C3) -------------------------------------
# a -> b -> c, where only a's manifest is the project's own. Before this
# landed, a library could not declare its own dependencies at all.
rm -rf "$TMP/tr"; mkdir -p "$TMP/tr/app" "$TMP/tr/mid" "$TMP/tr/base"
printf 'trbase_v() {\n} return int 41;\n'                        > "$TMP/tr/base/b.id"
printf 'import "../base"\n'                                      > "$TMP/tr/mid/conf.id"
printf 'trmid_v() {\n  int v = trbase_v() + 1;\n} return int v;\n' > "$TMP/tr/mid/m.id"
printf 'import "../mid"\n'                                       > "$TMP/tr/app/conf.id"
printf 'main(int argc, string[] argv) {\n    int v = trmid_v();\n    print(v);\n} return int 0;\n' \
                                                                 > "$TMP/tr/app/main.id"
tr_ok=1
for cc in "$BIN_IDC" "$IDC_PY"; do
    "$cc" --no-std "$TMP/tr/app" -o "$TMP/tr/out" >/dev/null 2>&1 || { tr_ok=0; break; }
    [ "$("$TMP/tr/out")" = "42" ] || { tr_ok=0; break; }
done
[ "$tr_ok" -eq 1 ] && ok "an imported directory's own conf.id is followed" \
                   || bad "an imported directory's own conf.id is followed"

# -- 9. a cycle in the import graph terminates -----------------------------
rm -rf "$TMP/cy"; mkdir -p "$TMP/cy/a" "$TMP/cy/b"
printf 'import "../b"\n'                            > "$TMP/cy/a/conf.id"
printf 'cya_v() {\n  int v = cyb_v();\n} return int v;\n' > "$TMP/cy/a/a.id"
printf 'import "../a"\n'                            > "$TMP/cy/b/conf.id"
printf 'cyb_v() {\n} return int 7;\nmain(int argc, string[] argv) {\n    int v = cya_v();\n    print(v);\n} return int 0;\n' \
                                                    > "$TMP/cy/b/b.id"
cy_ok=1
for cc in "$BIN_IDC" "$IDC_PY"; do
    timeout 30 "$cc" --no-std "$TMP/cy/b" -o "$TMP/cy/out" >/dev/null 2>&1 || { cy_ok=0; break; }
    [ "$("$TMP/cy/out")" = "7" ] || { cy_ok=0; break; }
done
[ "$cy_ok" -eq 1 ] && ok "a cycle in the import graph terminates" \
                   || bad "a cycle in the import graph terminates"

# -- 10. a transitively-imported BACKEND is linked -------------------------
# The reason transitivity had to land with the stdlib: a graphics module in a
# library declares backends/gfx once, instead of every program naming it.
rm -rf "$TMP/bk"; mkdir -p "$TMP/bk/lib" "$TMP/bk/app"
printf 'import "%s"\n' "$(cd "$ROOT/backends/fs" && pwd)" > "$TMP/bk/lib/conf.id"
cat > "$TMP/bk/lib/l.id" <<'EOF'
bklib_has(string path) {
  int found = fs_exists(path);
} return int found;
EOF
printf 'import "../lib"\n' > "$TMP/bk/app/conf.id"
cat > "$TMP/bk/app/main.id" <<'EOF'
main(int argc, string[] argv) {
    int has = bklib_has("/nonexistent-for-sure");
    print(has);
} return int 0;
EOF
bk_ok=1
for cc in "$BIN_IDC" "$IDC_PY"; do
    "$cc" --no-std "$TMP/bk/app" -o "$TMP/bk/out" >/dev/null 2>&1 || { bk_ok=0; break; }
    [ "$("$TMP/bk/out")" = "0" ] || { bk_ok=0; break; }
done
[ "$bk_ok" -eq 1 ] && ok "a backend named by an imported library is linked" \
                   || bad "a backend named by an imported library is linked"

# -- 11. the stdlib obeys the 3-entries-per-directory rule -----------------
# It is imported source like any other, so the rule applies to it -- and a
# violation must name the stdlib's directory, not the user's project.
rm -rf "$TMP/fat"; mkdir -p "$TMP/fat"
for n in 1 2 3 4; do printf 'fat%d() {\n} return int %d;\n' "$n" "$n" > "$TMP/fat/f$n.id"; done
fat_ok=1
for cc in "$BIN_IDC" "$IDC_PY"; do
    "$cc" --std "$TMP/fat" "$TMP/proj" -o "$TMP/x" >"$TMP/fat.err" 2>&1 && fat_ok=0
    grep -q "at most 3 files and directories" "$TMP/fat.err" || fat_ok=0
    grep -q "$TMP/fat" "$TMP/fat.err" || fat_ok=0
done
[ "$fat_ok" -eq 1 ] && ok "the entry-count rule applies to the stdlib, and names it" \
                    || bad "the entry-count rule applies to the stdlib, and names it"

# -- 12. dead-code elimination: an unused stdlib function is not emitted -----
# This is what makes an always-imported library affordable. Before it existed,
# a 729-function library cost hello-world 0.75 s and a 75 KB binary against
# 0.18 s and 16 KB; with it, +0.007 s and +40 bytes.
rm -rf "$TMP/proj"; mkdir -p "$TMP/proj"
cat > "$TMP/proj/main.id" <<'EOF'
main(int argc, string[] argv) {
    int r = tfx_max(3, 9);
    print(r);
} return int 0;
EOF
dce_ok=1
for cc in "$BIN_IDC" "$IDC_PY"; do
    "$cc" --std "$FIXTURE" "$TMP/proj" --emit-c "$TMP/dce.c" >/dev/null 2>&1 || dce_ok=0
    # tstr_twice is in the stdlib and nothing calls it
    grep -q "id_tstr_twice" "$TMP/dce.c" && dce_ok=0
    # tfx_max is called, and tfx_abs is not -- but tfx_max is reached, so it stays
    grep -q "id_tfx_max" "$TMP/dce.c" || dce_ok=0
    grep -q "id_tfx_abs" "$TMP/dce.c" && dce_ok=0
done
[ "$dce_ok" -eq 1 ] && ok "an unreachable stdlib function is not emitted" \
                    || bad "an unreachable stdlib function is not emitted"

# -- 13. and the two compilers agree about exactly what survives ------------
"$BIN_IDC" --std "$FIXTURE" "$TMP/proj" --emit-c "$TMP/p1.c" >/dev/null 2>&1
"$IDC_PY"  --std "$FIXTURE" "$TMP/proj" --emit-c "$TMP/p2.c" >/dev/null 2>&1
cmp -s "$TMP/p1.c" "$TMP/p2.c" \
    && ok "both compilers eliminate exactly the same code" \
    || bad "both compilers eliminate exactly the same code"

# -- 14. a library (no main) keeps everything ------------------------------
# Every function of a project with no main is an entry point -- it compiles to
# a .o for something else to link, and pruning it would empty the object file.
rm -rf "$TMP/lib"; mkdir -p "$TMP/lib"
cat > "$TMP/lib/l.id" <<'EOF'
libx_a(int a) {
  int r = a + 1;
} return int r;

libx_b(int a) {
  int r = a + 2;
} return int r;
EOF
lib_ok=1
for cc in "$BIN_IDC" "$IDC_PY"; do
    "$cc" --no-std "$TMP/lib" --emit-c "$TMP/lib.c" >/dev/null 2>&1 || lib_ok=0
    grep -q "id_libx_a" "$TMP/lib.c" || lib_ok=0
    grep -q "id_libx_b" "$TMP/lib.c" || lib_ok=0
done
[ "$lib_ok" -eq 1 ] && ok "a project with no main keeps every function" \
                    || bad "a project with no main keeps every function"

# -- 15. DEAD CODE IS STILL CHECKED ----------------------------------------
# The rule that makes dead-code elimination safe, and the one that was got
# wrong first: a function nothing calls must still obey every rule of the
# language. Code that stops being checked because nothing calls it is how a
# library rots -- and it would stop checking a user's own dead code too.
#
# Both a structural rule (the action limit) and an access rule (which in
# idc.py is enforced inside code generation, and so was the one that actually
# broke) are checked here.
rm -rf "$TMP/dead"; mkdir -p "$TMP/dead"
cat > "$TMP/dead/main.id" <<'EOF'
main(int argc, string[] argv) {
    print(1);
} return int 0;
EOF
cat > "$TMP/dead/never.id" <<'EOF'
never_called(int a) {
    int m = a;
    m = m + 1;
    m = m + 2;
    m = m + 3;
} return int m;
EOF
act_ok=1
for cc in "$BIN_IDC" "$IDC_PY"; do
    "$cc" --no-std "$TMP/dead" -o "$TMP/d" >"$TMP/d.err" 2>&1 && act_ok=0
    grep -q "the limit is 3" "$TMP/d.err" || act_ok=0
done
[ "$act_ok" -eq 1 ] && ok "an unreachable function still obeys the action limit" \
                    || bad "an unreachable function still obeys the action limit"

cat > "$TMP/dead/never.id" <<'EOF'
never_owner() {
    int hidden = 5;
} return int hidden;

never_peeker() {
    int v = (import hidden);
} return int v;
EOF
acc_ok=1
for cc in "$BIN_IDC" "$IDC_PY"; do
    "$cc" --no-std "$TMP/dead" -o "$TMP/d" >"$TMP/d.err" 2>&1 && acc_ok=0
    grep -qi "not exported" "$TMP/d.err" || acc_ok=0
done
[ "$acc_ok" -eq 1 ] && ok "an unreachable function still obeys the export rules" \
                    || bad "an unreachable function still obeys the export rules"

# -- 16. the reserved-name list has not drifted from the runtime -----------
# resv_names() in the self-hosted compiler is generated from idc.py's RUNTIME
# by tools/gen_runtime_id.py. If someone adds a helper to the prelude and does
# not regenerate, the two compilers stop agreeing about which names are taken
# -- one accepts a program the other rejects. Regenerating is a command; this
# is what makes forgetting it a test failure.
python3 - "$ROOT" <<'PY' >"$TMP/drift" 2>&1
import os, re, sys
root = sys.argv[1]
sys.path.insert(0, root)
import idc
gen = os.path.join(root, "compiler", "parse",
                   "back", "tgt", "c", "runtime", "reserved.gen.id")
listed = set(re.findall(r'"([a-z_0-9]+)"', open(gen).read()))
if listed == set(idc.RUNTIME_HELPERS):
    print("OK")
else:
    print("DRIFT", sorted(set(idc.RUNTIME_HELPERS) ^ listed))
PY
grep -q '^OK$' "$TMP/drift" \
    && ok "the id-side reserved-name list matches idc.py's RUNTIME" \
    || bad "the id-side reserved-name list matches idc.py's RUNTIME ($(head -1 "$TMP/drift"))"

# -- 17. the library does not reserve the user's local names (C4) ----------
# The one-type-per-name rule applies within a compilation unit -- the user's
# own tree, or one imported dependency -- and not across them. `s` is a string
# in the fixture library (tstr_twice's parameter); while the rule spanned the
# import boundary, an `int s` in a user's own function was rejected by two
# diagnostics that both named library files the user had never opened, and
# renaming the local was the only cure.
rm -rf "$TMP/proj"; mkdir -p "$TMP/proj"
cat > "$TMP/proj/main.id" <<'EOF'
total(int a, int b) {
  int s = a + b;
} return int s;
main(int argc, string[] argv) {
  int n = total(2, 3);
  print(n);
} return int 0;
EOF
run_both "a library name does not reserve the user's local name" "5"

# -- 18. ...but the rule still holds inside the user's own tree ------------
# Per-unit is not per-file: every file of one project is one unit, so a name
# that changes type between two of them is the error it has always been -- from
# both compilers, in the same words.
rm -rf "$TMP/two"; mkdir -p "$TMP/two"
cat > "$TMP/two/main.id" <<'EOF'
main(int argc, string[] argv) {
    int s = 1;
    print(s);
} return int 0;
EOF
cat > "$TMP/two/other.id" <<'EOF'
twoname_other() {
    string s = "hi";
    print(s);
} return void;
EOF
one_ok=1
for cc_name in idc idc.py; do
    case "$cc_name" in
        idc)    cc="$BIN_IDC" ;;
        idc.py) cc="$IDC_PY" ;;
    esac
    "$cc" --std "$FIXTURE" "$TMP/two" -o "$TMP/two.out" >"$TMP/two.$cc_name" 2>&1 && one_ok=0
    grep -m1 "must keep one type" "$TMP/two.$cc_name" > "$TMP/msg.$cc_name" || one_ok=0
done
cmp -s "$TMP/msg.idc" "$TMP/msg.idc.py" || one_ok=0
[ "$one_ok" -eq 1 ] && ok "one type per name still holds across the user's own tree" \
                    || bad "one type per name still holds across the user's own tree"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
