#!/usr/bin/env bash
# Standard-library tests: implicit import, and the transitive dependency
# resolution it is built on.
#
# `idstd` is imported by DEFAULT -- a program calls a library function with no
# conf.id line and no flag. That is a change to how every program is built,
# so it needs its own file of checks, against bin/idc, the only compiler that
# is still built.
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
# bin/idc takes --allow-untested throughout: neither these programs nor the
# fixture library has two cases per function, and what is under test is how
# the library is found.
BIN_IDC="../bin/idc --allow-untested"
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

# run_one DESC EXPECTED_STDOUT -- build $TMP/proj, run it, compare output.
run_one() {
    local desc="$1" want="$2" got
    if ! $BIN_IDC --std "$FIXTURE" "$TMP/proj" -o "$TMP/out" >"$TMP/build.err" 2>&1; then
        bad "$desc (build failed: $(head -1 "$TMP/build.err"))"
        return
    fi
    got=$("$TMP/out" 2>&1)
    if [ "$got" = "$want" ]; then
        ok "$desc"
    else
        bad "$desc (got '$got', want '$want')"
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
run_one "a project reaches the stdlib with no conf.id" "9
4"

# -- 2. a nested stdlib directory is reached, not just its top level --------
rm -rf "$TMP/proj"; mkdir -p "$TMP/proj"
cat > "$TMP/proj/main.id" <<'EOF'
main(int argc, string[] argv) {
    string r = tstr_twice("ab");
    print(r);
} return int 0;
EOF
run_one "the whole stdlib tree is merged, not just its root" "abab"

# -- 3. a single FILE gets the stdlib too ----------------------------------
# The tutorial path (`idc prog.id`) is the one that most needs fx_max to
# already exist, so it must not be the one path that misses out.
cat > "$TMP/single.id" <<'EOF'
main(int argc, string[] argv) {
    int r = tfx_max(2, 7);
    print(r);
} return int 0;
EOF
if $BIN_IDC --std "$FIXTURE" "$TMP/single.id" -o "$TMP/single.bin" >/dev/null 2>&1 \
   && [ "$("$TMP/single.bin")" = "7" ]; then
    ok "a single .id file gets the stdlib too"
else
    bad "a single .id file gets the stdlib too"
fi

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
if $BIN_IDC --no-std --std "$FIXTURE" "$TMP/proj" -o "$TMP/ns" >"$TMP/ns.err" 2>&1; then
    bad "--no-std removes the stdlib"   # it built, so the stdlib was still there
elif grep -q "no such function 'tfx_max'" "$TMP/ns.err"; then
    ok "--no-std removes the stdlib"
else
    bad "--no-std removes the stdlib (wrong reason: $(head -1 "$TMP/ns.err"))"
fi

# -- 5. IDC_NO_STD does the same, for scripts that cannot pass a flag ------
if IDC_NO_STD=1 $BIN_IDC --std "$FIXTURE" "$TMP/proj" -o "$TMP/ns" >"$TMP/ns.err" 2>&1; then
    bad "IDC_NO_STD=1 removes the stdlib"
elif grep -q "no such function 'tfx_max'" "$TMP/ns.err"; then
    ok "IDC_NO_STD=1 removes the stdlib"
else
    bad "IDC_NO_STD=1 removes the stdlib (wrong reason: $(head -1 "$TMP/ns.err"))"
fi

# -- 6. $IDSTD_HOME locates it ---------------------------------------------
rm -rf "$TMP/proj"; mkdir -p "$TMP/proj"
cat > "$TMP/proj/main.id" <<'EOF'
main(int argc, string[] argv) {
    int r = tfx_max(1, 5);
    print(r);
} return int 0;
EOF
if IDSTD_HOME="$FIXTURE" $BIN_IDC "$TMP/proj" -o "$TMP/h" >/dev/null 2>&1 \
   && [ "$("$TMP/h")" = "5" ]; then
    ok "\$IDSTD_HOME locates the stdlib"
else
    bad "\$IDSTD_HOME locates the stdlib"
fi

# -- 7. a bad --std is reported, not ignored -------------------------------
if ! $BIN_IDC --std "$TMP/nope" "$TMP/proj" -o "$TMP/x" >"$TMP/x.err" 2>&1 \
   && grep -qi "not a directory\|does not name a directory" "$TMP/x.err"; then
    ok "a --std that is not a directory is reported"
else
    bad "a --std that is not a directory is reported"
fi

# -- 8. transitive source imports (C3) -------------------------------------
# a -> b -> c, where only a's manifest is the project's own. Before this
# landed, a library could not declare its own dependencies at all.
rm -rf "$TMP/tr"; mkdir -p "$TMP/tr/app" "$TMP/tr/mid" "$TMP/tr/base"
printf 'trbase_v(int a) {\n  int v = a;\n} return int v;\n'     > "$TMP/tr/base/b.id"
printf 'import "../base"\n'                                      > "$TMP/tr/mid/conf.id"
printf 'trmid_v() {\n  int v = trbase_v(41) + 1;\n} return int v;\n' > "$TMP/tr/mid/m.id"
printf 'import "../mid"\n'                                       > "$TMP/tr/app/conf.id"
printf 'main(int argc, string[] argv) {\n    int v = trmid_v();\n    print(v);\n} return int 0;\n' \
                                                                 > "$TMP/tr/app/main.id"
if $BIN_IDC --no-std "$TMP/tr/app" -o "$TMP/tr/out" >/dev/null 2>&1 \
   && [ "$("$TMP/tr/out")" = "42" ]; then
    ok "an imported directory's own conf.id is followed"
else
    bad "an imported directory's own conf.id is followed"
fi

# -- 9. a cycle in the import graph terminates -----------------------------
rm -rf "$TMP/cy"; mkdir -p "$TMP/cy/a" "$TMP/cy/b"
printf 'import "../b"\n'                            > "$TMP/cy/a/conf.id"
printf 'cya_v() {\n  int v = cyb_v(7);\n} return int v;\n' > "$TMP/cy/a/a.id"
printf 'import "../a"\n'                            > "$TMP/cy/b/conf.id"
printf 'cyb_v(int a) {\n  int v = a;\n} return int v;\nmain(int argc, string[] argv) {\n    int v = cya_v();\n    print(v);\n} return int 0;\n' \
                                                    > "$TMP/cy/b/b.id"
if timeout 30 $BIN_IDC --no-std "$TMP/cy/b" -o "$TMP/cy/out" >/dev/null 2>&1 \
   && [ "$("$TMP/cy/out")" = "7" ]; then
    ok "a cycle in the import graph terminates"
else
    bad "a cycle in the import graph terminates"
fi

# -- 10. a transitively-imported BACKEND is linked -------------------------
# The reason transitivity had to land with the stdlib: a graphics module in a
# library declares its backend once, instead of every program naming it.
rm -rf "$TMP/bk"; mkdir -p "$TMP/bk/lib" "$TMP/bk/app" "$TMP/bk/be"
printf 'string name = "bk";\nstring[] c_linux_sources = ["bk.c"];\nstring[] c_darwin_sources = ["bk.c"];\n' > "$TMP/bk/be/backend.id"
printf 'int id_bk_exists(char* path) { return path[0] == 0; }\n' > "$TMP/bk/be/bk.c"
printf 'native bk_exists(string path) return int;\n' > "$TMP/bk/be/bk.id"
printf 'import "../be"\n' > "$TMP/bk/lib/conf.id"
cat > "$TMP/bk/lib/l.id" <<'EOF'
bklib_has(string path) {
  int found = bk_exists(path);
} return int found;
EOF
printf 'import "../lib"\n' > "$TMP/bk/app/conf.id"
cat > "$TMP/bk/app/main.id" <<'EOF'
main(int argc, string[] argv) {
    int has = bklib_has("/nonexistent-for-sure");
    print(has);
} return int 0;
EOF
if $BIN_IDC --no-std "$TMP/bk/app" -o "$TMP/bk/out" >/dev/null 2>&1 \
   && [ "$("$TMP/bk/out")" = "0" ]; then
    ok "a backend named by an imported library is linked"
else
    bad "a backend named by an imported library is linked"
fi

# -- 11. the stdlib obeys the 3-entries-per-directory rule -----------------
# It is imported source like any other, so the rule applies to it -- and a
# violation must name the stdlib's directory, not the user's project.
rm -rf "$TMP/fat"; mkdir -p "$TMP/fat"
for n in 1 2 3 4; do printf 'fat%d(int a) {\n  int v = a + %d;\n} return int v;\n' "$n" "$n" > "$TMP/fat/f$n.id"; done
if ! $BIN_IDC --std "$TMP/fat" "$TMP/proj" -o "$TMP/x" >"$TMP/fat.err" 2>&1 \
   && grep -q "at most 3 files and directories" "$TMP/fat.err" \
   && grep -q "$TMP/fat" "$TMP/fat.err"; then
    ok "the entry-count rule applies to the stdlib, and names it"
else
    bad "the entry-count rule applies to the stdlib, and names it"
fi

# -- 12. the stdlib rejects a directory with the same name as its parent -----
rm -rf "$TMP/dup"; mkdir -p "$TMP/dup/dup"
printf 'dup_fn(int a) {\n  int v = a + 1;\n} return int v;\n' > "$TMP/dup/dup/f.id"
if ! $BIN_IDC --std "$TMP/dup" "$TMP/proj" -o "$TMP/x" >"$TMP/dup.err" 2>&1 \
   && grep -q "has the same name as its parent" "$TMP/dup.err" \
   && grep -q "$TMP/dup/dup" "$TMP/dup.err"; then
    ok "directory with same name as parent is rejected, and named in error"
else
    bad "directory with same name as parent is rejected, and named in error"
fi

# -- 13. the stdlib rejects a file with a generic name ----------------------
rm -rf "$TMP/gen"; mkdir -p "$TMP/gen"
printf 'gen_helper(int a) {\n  int v = a + 1;\n} return int v;\n' > "$TMP/gen/helper.id"
if ! $BIN_IDC --std "$TMP/gen" "$TMP/proj" -o "$TMP/x" >"$TMP/gen.err" 2>&1 \
   && grep -q "has a generic name" "$TMP/gen.err" \
   && grep -q "helper.id" "$TMP/gen.err"; then
    ok "generic filenames are rejected"
else
    bad "generic filenames are rejected"
fi

# -- 14. a grandparent-named directory is accepted if not the same as parent --
rm -rf "$TMP/gran"; mkdir -p "$TMP/gran/grandparent/parent"
printf 'gran_fn(int a) {\n  int v = a + 1;\n} return int v;\n(1):(2)\n' > "$TMP/gran/grandparent/parent/f.id"
rm -rf "$TMP/proj14"; mkdir -p "$TMP/proj14"
printf 'main(int argc, string[] argv) {\n  print(1);\n} return int 0;\n' > "$TMP/proj14/main.id"
if $BIN_IDC --allow-untested --std "$TMP/gran" "$TMP/proj14" -o "$TMP/x" >/dev/null 2>&1; then
    ok "a grandparent-named directory is accepted"
else
    bad "a grandparent-named directory is accepted"
fi

# -- 15. a file named like its own directory (x/x.id) is accepted -----------
# The same-name-as-parent rule (12) checks directories against their parent
# directory; a file sharing its containing directory's name is a different
# pattern, and not one either new rule reaches.
rm -rf "$TMP/self"; mkdir -p "$TMP/self"
printf 'self_fn(int a) {\n  int v = a + 1;\n} return int v;\n(1):(2)\n' > "$TMP/self/self.id"
rm -rf "$TMP/proj15"; mkdir -p "$TMP/proj15"
printf 'main(int argc, string[] argv) {\n  print(1);\n} return int 0;\n' > "$TMP/proj15/main.id"
if $BIN_IDC --allow-untested --std "$TMP/self" "$TMP/proj15" -o "$TMP/x" >/dev/null 2>&1; then
    ok "a file named like its own directory (x/x.id) is accepted"
else
    bad "a file named like its own directory (x/x.id) is accepted"
fi

# -- 16. numbered sibling files (chunk.id, chunk2.id) are accepted ----------
# The generic-name rule (13) checks a fixed list of names; a numbered series
# of otherwise-descriptive names is a different pattern, and not one it reaches.
rm -rf "$TMP/num"; mkdir -p "$TMP/num"
printf 'num_fn(int a) {\n  int v = a + 1;\n} return int v;\n(1):(2)\n' > "$TMP/num/chunk.id"
printf 'num_fn2(int a) {\n  int v = a + 2;\n} return int v;\n(1):(3)\n' > "$TMP/num/chunk2.id"
rm -rf "$TMP/proj16"; mkdir -p "$TMP/proj16"
printf 'main(int argc, string[] argv) {\n  print(1);\n} return int 0;\n' > "$TMP/proj16/main.id"
if $BIN_IDC --allow-untested --std "$TMP/num" "$TMP/proj16" -o "$TMP/x" >/dev/null 2>&1; then
    ok "numbered sibling files (chunk.id, chunk2.id) are accepted"
else
    bad "numbered sibling files (chunk.id, chunk2.id) are accepted"
fi

# -- 17. dead-code elimination: an unused stdlib function is not emitted -----
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
$BIN_IDC --std "$FIXTURE" "$TMP/proj" --emit-c "$TMP/dce.c" >/dev/null 2>&1 || dce_ok=0
# tstr_twice is in the stdlib and nothing calls it
grep -q "id_tstr_twice" "$TMP/dce.c" && dce_ok=0
# tfx_max is called, and tfx_abs is not -- but tfx_max is reached, so it stays
grep -q "id_tfx_max" "$TMP/dce.c" || dce_ok=0
grep -q "id_tfx_abs" "$TMP/dce.c" && dce_ok=0
[ "$dce_ok" -eq 1 ] && ok "an unreachable stdlib function is not emitted" \
                    || bad "an unreachable stdlib function is not emitted"

# -- 18. a library (no main) keeps everything ------------------------------
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
$BIN_IDC --no-std "$TMP/lib" --emit-c "$TMP/lib.c" >/dev/null 2>&1 || lib_ok=0
grep -q "id_libx_a" "$TMP/lib.c" || lib_ok=0
grep -q "id_libx_b" "$TMP/lib.c" || lib_ok=0
[ "$lib_ok" -eq 1 ] && ok "a project with no main keeps every function" \
                    || bad "a project with no main keeps every function"

# -- 19. DEAD CODE IS STILL CHECKED ----------------------------------------
# The rule that makes dead-code elimination safe, and the one that was got
# wrong first: a function nothing calls must still obey every rule of the
# language. Code that stops being checked because nothing calls it is how a
# library rots -- and it would stop checking a user's own dead code too.
#
# Both a structural rule (the action limit) and an access rule are checked
# here.
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
if ! $BIN_IDC --no-std "$TMP/dead" -o "$TMP/d" >"$TMP/d.err" 2>&1 \
   && grep -q "the limit is 3" "$TMP/d.err"; then
    ok "an unreachable function still obeys the action limit"
else
    bad "an unreachable function still obeys the action limit"
fi

cat > "$TMP/dead/never.id" <<'EOF'
never_owner(int a) {
    int hidden = a;
} return int hidden;

never_peeker() {
    int v = (import hidden);
} return int v;
EOF
if ! $BIN_IDC --no-std "$TMP/dead" -o "$TMP/d" >"$TMP/d.err" 2>&1 \
   && grep -qi "not exported" "$TMP/d.err"; then
    ok "an unreachable function still obeys the export rules"
else
    bad "an unreachable function still obeys the export rules"
fi

# -- 20. the reserved-name list has not drifted from the runtime -----------
# resv_names_src, in compiler/parse/conf.id, and the runtime prelude
# (compiler/parse/back/tgt/c/runtime/runtime.id) are both hand-maintained now
# (docs/HACKING.md). If someone adds a helper to the prelude and forgets to add
# its name to resv_names_src, an id function could be given that name and
# collide with the runtime in the generated C -- this is what makes forgetting
# it a test failure, extracting each side with grep/sed rather than a second
# implementation of either.
runtime_names=$(grep -oE 'id_[a-zA-Z_0-9]+\(' "$ROOT/compiler/parse/back/tgt/c/runtime/runtime.id" \
    | sed -E 's/^id_//; s/\($//' | sort -u)
conf_names=$(grep -oE 'string resv_names_src = "[^"]*"' "$ROOT/compiler/parse/conf.id" \
    | sed -E 's/^string resv_names_src = "//; s/"$//' | tr ' ' '\n' | sort -u)
if [ "$runtime_names" = "$conf_names" ]; then
    ok "the id-side reserved-name list matches the runtime prelude"
else
    bad "the id-side reserved-name list matches the runtime prelude (drift: $(diff <(echo "$runtime_names") <(echo "$conf_names") | head -1))"
fi

# -- 21. the library does not reserve the user's local names (C4) ----------
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
run_one "a library name does not reserve the user's local name" "5"

# -- 22. ...but the rule still holds inside the user's own tree ------------
# Per-unit is not per-file: every file of one project is one unit, so a name
# that changes type between two of them is still the error it has always been.
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
if ! $BIN_IDC --std "$FIXTURE" "$TMP/two" -o "$TMP/two.out" >"$TMP/two.out.err" 2>&1 \
   && grep -q "must keep one type" "$TMP/two.out.err"; then
    ok "one type per name still holds across the user's own tree"
else
    bad "one type per name still holds across the user's own tree"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
