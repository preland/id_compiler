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
if IDSTD_HOME="$FIXTURE" $BIN_IDC --no-std "$TMP/proj" -o "$TMP/ns" >"$TMP/ns.err" 2>&1; then
    bad "--no-std removes the stdlib"   # it built, so the stdlib was still there
elif grep -q "no such function 'tfx_max'" "$TMP/ns.err"; then
    ok "--no-std removes the stdlib"
else
    bad "--no-std removes the stdlib (wrong reason: $(head -1 "$TMP/ns.err"))"
fi

# -- 5. IDC_NO_STD does the same, for scripts that cannot pass a flag ------
if IDSTD_HOME="$FIXTURE" IDC_NO_STD=1 $BIN_IDC "$TMP/proj" -o "$TMP/ns" >"$TMP/ns.err" 2>&1; then
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
  string shown = path + "";
  int found = bk_exists(shown);
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

# -- 11. a stdlib directory has no entry limit -------------------------------
# It is imported source like any other, and a directory holds any number of
# files, so ten of them in one stdlib directory build.
rm -rf "$TMP/fat"; mkdir -p "$TMP/fat"
n=0
for f in alpha bravo charlie delta echo foxtrot golf hotel india juliet; do n=$((n + 1)); printf 'fat%d(int a) {\n  int v = a + %d;\n} return int v;\n' "$n" "$n" > "$TMP/fat/$f.id"; done
rm -rf "$TMP/proj11"; mkdir -p "$TMP/proj11"
printf 'main(int argc, string[] argv) {\n  print(fat3(4));\n} return int 0;\n' > "$TMP/proj11/main.id"
if $BIN_IDC --allow-untested --std "$TMP/fat" "$TMP/proj11" -o "$TMP/x" >"$TMP/fat.err" 2>&1 \
   && [ "$("$TMP/x")" = "7" ]; then
    ok "a stdlib directory of ten files is accepted"
else
    bad "a stdlib directory of ten files is accepted"
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

# -- 15. a file named like its own directory, directly in the root, is
#        accepted (root/loop.id) --------------------------------------------
# check_file_named_like_dir does not apply to a file directly in the
# collected root: the root directory's name is just where it was checked
# out, not a level of the tree it wrote. A nested instance of the same
# pattern (root/a/a.id) is rejected -- see 26.
rm -rf "$TMP/self"; mkdir -p "$TMP/self"
printf 'self_fn(int a) {\n  int v = a + 1;\n} return int v;\n(1):(2)\n' > "$TMP/self/self.id"
rm -rf "$TMP/proj15"; mkdir -p "$TMP/proj15"
printf 'main(int argc, string[] argv) {\n  print(1);\n} return int 0;\n' > "$TMP/proj15/main.id"
if $BIN_IDC --allow-untested --std "$TMP/self" "$TMP/proj15" -o "$TMP/x" >/dev/null 2>&1; then
    ok "a file named like its own directory, directly in the root, is accepted (root/loop.id)"
else
    bad "a file named like its own directory, directly in the root, is accepted (root/loop.id)"
fi

# -- 16. a numbered sibling file (chunk.id, chunk2.id) is rejected ----------
# chunk2.id's name is chunk.id's followed by digits, in the same directory.
rm -rf "$TMP/num"; mkdir -p "$TMP/num"
printf 'num_fn(int a) {\n  int v = a + 1;\n} return int v;\n(1):(2)\n' > "$TMP/num/chunk.id"
printf 'num_fn2(int a) {\n  int v = a + 2;\n} return int v;\n(1):(3)\n' > "$TMP/num/chunk2.id"
rm -rf "$TMP/proj16"; mkdir -p "$TMP/proj16"
printf 'main(int argc, string[] argv) {\n  print(1);\n} return int 0;\n' > "$TMP/proj16/main.id"
if ! $BIN_IDC --allow-untested --std "$TMP/num" "$TMP/proj16" -o "$TMP/x" >"$TMP/num.err" 2>&1 \
   && grep -q "is a numbered copy of" "$TMP/num.err" \
   && grep -q "chunk2.id" "$TMP/num.err"; then
    ok "a numbered sibling file (chunk.id, chunk2.id) is rejected"
else
    bad "a numbered sibling file (chunk.id, chunk2.id) is rejected"
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
# (compiler/parse/back/tgt/c/runtime/prelude.id) are both hand-maintained now
# (docs/HACKING.md). If someone adds a helper to the prelude and forgets to add
# its name to resv_names_src, an id function could be given that name and
# collide with the runtime in the generated C -- this is what makes forgetting
# it a test failure, extracting each side with grep/sed rather than a second
# implementation of either.
runtime_names=$(grep -ohE 'id_[a-zA-Z_0-9]+\(' "$ROOT/compiler/parse/back/tgt/c/runtime/prelude.id" \
    "$ROOT/compiler/parse/back/tgt/c/runtime/closure/c/text.id" \
    "$ROOT/compiler/parse/back/tgt/c/runtime/closure/c/more/cmp.id" \
    | sed -E 's/^id_//; s/\($//' | sort -u)
conf_names=$(grep -oE 'string resv_names_src = "[^"]*"' "$ROOT/compiler/parse/conf.id" \
    | sed -E 's/^string resv_names_src = "//; s/"$//' | tr ' ' '\n' | sort -u)
if [ "$runtime_names" = "$conf_names" ]; then
    ok "the id-side reserved-name list matches the runtime prelude"
else
    bad "the id-side reserved-name list matches the runtime prelude (drift: $(diff <(echo "$runtime_names") <(echo "$conf_names") | head -1))"
fi

# -- 21. the library's variable names have the library's types -------------
# One type per name is program-wide, the library included. `s` is a string in
# the fixture library (tstr_twice's parameter), so an `int s` in a user's own
# function is refused, at the user's declaration with the library's as the
# related place; the same name with the same type is fine. Whether the build
# held tstr_twice or only its index is tests 41-43's concern.
rm -rf "$TMP/proj"; mkdir -p "$TMP/proj"
cat > "$TMP/proj/main.id" <<'EOF2'
total(int a, int b) {
  int s = a + b;
} return int s;
main(int argc, string[] argv) {
  int n = total(2, 3);
  print(n);
} return int 0;
EOF2
if ! $BIN_IDC --std "$FIXTURE" "$TMP/proj" -o "$TMP/out21" >"$TMP/o21.err" 2>&1 \
   && grep -qF "variable 's' is declared int here but string in the standard library [E0303]" "$TMP/o21.err" \
   && grep -qF "the standard library's declaration, which is string" "$TMP/o21.err"; then
    ok "a variable named like a library variable with another type is refused, naming both declarations"
else
    bad "a variable named like a library variable with another type is refused, naming both declarations ($(head -1 "$TMP/o21.err"))"
fi
cat > "$TMP/proj/main.id" <<'EOF2'
twice_of(string s) {
  string t = s + "-" + s;
} return string t;
main(int argc, string[] argv) {
  print(twice_of("ab"));
} return int 0;
EOF2
run_one "a variable named like a library variable with the same type is accepted" "ab-ab"

# -- 22. ...and it still holds inside the user's own tree ------------------
# Every file of one project is one scope, so a name
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

# -- 23. --print-std prints the stdlib root this build would merge ---------
# tools/idxpack.sh's ===STD=== line is exactly this, run with the same
# flags/env as its --calls run, so idxpack's "which unit is this file in"
# decision uses the stdlib idc actually resolved instead of guessing at a
# "/idstd/" path substring. An explicit --std wins over everything else, so
# this holds wherever the checkout sits.
rm -rf "$TMP/proj"; mkdir -p "$TMP/proj"
printf 'main(int argc, string[] argv) {\n  print(1);\n} return int 0;\n' > "$TMP/proj/main.id"
want=$(cd "$FIXTURE" && pwd -P)
got=$($BIN_IDC "$TMP/proj" --std "$FIXTURE" --print-std)
if [ "$got" = "$want" ]; then
    ok "--print-std honours --std DIR"
else
    bad "--print-std honours --std DIR (got '$got', want '$want')"
fi

# -- 24. --print-std honours $IDSTD_HOME ------------------------------------
want=$(cd "$FIXTURE" && pwd -P)
got=$(IDSTD_HOME="$FIXTURE" $BIN_IDC "$TMP/proj" --print-std)
if [ "$got" = "$want" ]; then
    ok "--print-std honours \$IDSTD_HOME"
else
    bad "--print-std honours \$IDSTD_HOME (got '$got', want '$want')"
fi

# -- 25. --print-std prints nothing under --no-std --------------------------
# An $IDSTD_HOME alongside --no-std must not leak through: --no-std wins, same
# as it does for the real build (test 4, above).
got=$(IDSTD_HOME="$FIXTURE" $BIN_IDC --no-std "$TMP/proj" --print-std)
if [ "$got" = "" ]; then
    ok "--print-std prints nothing under --no-std"
else
    bad "--print-std prints nothing under --no-std (got '$got')"
fi

# -- 25b. an explicit --std beats IDC_NO_STD; IDC_NO_STD alone still means none
want=$(cd "$FIXTURE" && pwd -P)
got=$(IDC_NO_STD=1 $BIN_IDC "$TMP/proj" --std "$FIXTURE" --print-std)
if [ "$got" = "$want" ]; then
    ok "--std DIR beats IDC_NO_STD=1"
else
    bad "--std DIR beats IDC_NO_STD=1 (got '$got', want '$want')"
fi
got=$(IDSTD_HOME="$FIXTURE" IDC_NO_STD=1 $BIN_IDC "$TMP/proj" --print-std)
if [ "$got" = "" ]; then
    ok "IDC_NO_STD=1 alone still means no stdlib"
else
    bad "IDC_NO_STD=1 alone still means no stdlib (got '$got')"
fi

# -- 25c. --no-std with --std is a contradiction, and the message names the fix
if $BIN_IDC --no-std --std "$FIXTURE" "$TMP/proj" --print-std >"$TMP/both.out" 2>"$TMP/both.err"; then
    bad "--no-std with --std is refused"
elif grep -q "drop --no-std" "$TMP/both.err" && grep -q "drop --std" "$TMP/both.err"; then
    ok "--no-std with --std is refused"
else
    bad "--no-std with --std is refused (wrong reason: $(head -1 "$TMP/both.err"))"
fi

# -- 26. a broken idstd case fails a program build with the library's own
# message, never the program's -- bin/idc's pre-check (run_std_precheck),
# against a scratch COPY of the fixture stdlib, never fixtures/idstd itself.
# The pre-check is of the functions the program reaches and their cases, so the
# program calls the one whose case is broken.
rm -rf "$TMP/idstd_broken"; cp -r "$FIXTURE" "$TMP/idstd_broken"
sed -i 's/(3, 9):(9)/(3, 9):(999)/' "$TMP/idstd_broken/math/fx.id"
broken=$(cd "$TMP/idstd_broken" && pwd -P)
rm -rf "$TMP/proj"; mkdir -p "$TMP/proj"
printf 'main(int argc, string[] argv) {\n  int r = tfx_max(1, 2);\n  print(r);\n} return int 0;\n' > "$TMP/proj/main.id"
out=$($BIN_IDC "$TMP/proj" --std "$broken" -o "$TMP/out26" 2>&1)
if printf '%s\n' "$out" | grep -qF "idc: the standard library at $broken failed its own test cases (this is not an error in your program):" \
   && printf '%s\n' "$out" | grep -qF "test failed: tfx_max(3, 9) = 9, expected 999" \
   && [ ! -e "$TMP/out26" ]; then
    ok "a broken idstd case fails a program build with the library's own message"
else
    bad "a broken idstd case fails a program build with the library's own message: $(printf '%s\n' "$out" | head -2 | tr '\n' ' ')"
fi

# -- 27. a failing case in the program itself is reported as the program's,
# with idstd (unmodified) fine -----------------------------------------------
rm -rf "$TMP/proj"; mkdir -p "$TMP/proj"
cat > "$TMP/proj/main.id" <<'EOF'
proj_add_one(int a) {
  int b = a + 1;
} return int b;
(1):(2)
(2):(999)

main(int argc, string[] argv) {
  int r = proj_add_one(1);
  print(r);
} return int 0;
EOF
out=$($BIN_IDC "$TMP/proj" --std "$FIXTURE" -o "$TMP/out27" 2>&1)
if printf '%s\n' "$out" | grep -qF "test failed: proj_add_one(2) = 3, expected 999" \
   && ! printf '%s\n' "$out" | grep -q "failed its own test cases"; then
    ok "a failing case in the program is reported as the program's, with idstd fine"
else
    bad "a failing case in the program is reported as the program's, with idstd fine: $(printf '%s\n' "$out" | head -2 | tr '\n' ' ')"
fi

# -- 28. the pre-check is cached: a second, identical build against the same
# library creates no new pre-check cache entry -------------------------------
rm -rf "$TMP/proj" "$TMP/idstd_cachetest"; mkdir -p "$TMP/proj"
cp -r "$FIXTURE" "$TMP/idstd_cachetest"
printf 'main(int argc, string[] argv) {\n  int r = tfx_max(1, 2);\n  print(r);\n} return int 0;\n' > "$TMP/proj/main.id"
precheck_entries() {
    find "$ROOT/.idc-cache/std_precheck" -mindepth 1 -maxdepth 1 -type d ! -name '.bincache' 2>/dev/null \
        | wc -l | tr -d ' '
}
$BIN_IDC "$TMP/proj" --std "$TMP/idstd_cachetest" -o "$TMP/out28a" >/dev/null 2>&1
e1=$(precheck_entries)
$BIN_IDC "$TMP/proj" --std "$TMP/idstd_cachetest" -o "$TMP/out28b" >/dev/null 2>&1
e2=$(precheck_entries)
if [ "$e1" -ge 1 ] && [ "$e2" -eq "$e1" ]; then
    ok "the library pre-check is cached: a second build creates no new pre-check cache entry"
else
    bad "the library pre-check is cached: a second build creates no new pre-check cache entry (had $e1, now $e2)"
fi

# -- 29. a numbered directory sibling (pane/, pane2/) is rejected -----------
rm -rf "$TMP/panes"; mkdir -p "$TMP/panes/pane" "$TMP/panes/pane2"
printf 'pane_fn(int a) {\n  int v = a + 1;\n} return int v;\n(1):(2)\n' > "$TMP/panes/pane/f.id"
printf 'pane_fn2(int a) {\n  int v = a + 2;\n} return int v;\n(1):(3)\n' > "$TMP/panes/pane2/f.id"
rm -rf "$TMP/proj23"; mkdir -p "$TMP/proj23"
printf 'main(int argc, string[] argv) {\n  print(1);\n} return int 0;\n' > "$TMP/proj23/main.id"
if ! $BIN_IDC --allow-untested --std "$TMP/panes" "$TMP/proj23" -o "$TMP/x" >"$TMP/panes.err" 2>&1 \
   && grep -q "is a numbered copy of" "$TMP/panes.err" \
   && grep -q "pane2" "$TMP/panes.err"; then
    ok "a numbered directory sibling (pane/, pane2/) is rejected"
else
    bad "a numbered directory sibling (pane/, pane2/) is rejected"
fi

# -- 30. two numbered siblings with no un-numbered form (x2.id, x3.id) are
#        rejected as numbered siblings of each other ------------------------
# Neither is more "the real one" than the other, so both are numbered copies
# of something, and the pair is still rejected even though neither is x.id.
rm -rf "$TMP/xx"; mkdir -p "$TMP/xx"
printf 'x2_fn(int a) {\n  int v = a + 1;\n} return int v;\n(1):(2)\n' > "$TMP/xx/x2.id"
printf 'x3_fn(int a) {\n  int v = a + 2;\n} return int v;\n(1):(3)\n' > "$TMP/xx/x3.id"
rm -rf "$TMP/proj24"; mkdir -p "$TMP/proj24"
printf 'main(int argc, string[] argv) {\n  print(1);\n} return int 0;\n' > "$TMP/proj24/main.id"
if ! $BIN_IDC --allow-untested --std "$TMP/xx" "$TMP/proj24" -o "$TMP/x" >"$TMP/xx.err" 2>&1 \
   && grep -q "is a numbered copy of\|numbered sibling of" "$TMP/xx.err"; then
    ok "x2.id beside x3.id, with no x.id, is rejected (numbered siblings of each other)"
else
    bad "x2.id beside x3.id, with no x.id, is rejected (numbered siblings of each other)"
fi

# -- 31. a file with digits but no un-numbered sibling (md5.id) is accepted --
rm -rf "$TMP/md5"; mkdir -p "$TMP/md5"
printf 'md5_fn(int a) {\n  int v = a + 1;\n} return int v;\n(1):(2)\n' > "$TMP/md5/md5.id"
rm -rf "$TMP/proj25"; mkdir -p "$TMP/proj25"
printf 'main(int argc, string[] argv) {\n  print(1);\n} return int 0;\n' > "$TMP/proj25/main.id"
if $BIN_IDC --allow-untested --std "$TMP/md5" "$TMP/proj25" -o "$TMP/x" >/dev/null 2>&1; then
    ok "a file with digits but no un-numbered sibling (md5.id) is accepted"
else
    bad "a file with digits but no un-numbered sibling (md5.id) is accepted"
fi

# -- 32. a nested file named like its own directory (root/a/a.id) is
#        rejected -- unlike 15, a is not the collected root ----------------
rm -rf "$TMP/nested"; mkdir -p "$TMP/nested/a"
printf 'a_fn(int a) {\n  int v = a + 1;\n} return int v;\n(1):(2)\n' > "$TMP/nested/a/a.id"
rm -rf "$TMP/proj26"; mkdir -p "$TMP/proj26"
printf 'main(int argc, string[] argv) {\n  print(1);\n} return int 0;\n' > "$TMP/proj26/main.id"
if ! $BIN_IDC --allow-untested --std "$TMP/nested" "$TMP/proj26" -o "$TMP/x" >"$TMP/nested.err" 2>&1 \
   && grep -q "has the same name as its directory" "$TMP/nested.err" \
   && grep -q "a/a.id" "$TMP/nested.err"; then
    ok "a nested file named like its own directory (root/a/a.id) is rejected"
else
    bad "a nested file named like its own directory (root/a/a.id) is rejected"
fi

# -- 33. an underscore-numbered sibling (x.id, x_2.id) is rejected too ------
rm -rf "$TMP/under"; mkdir -p "$TMP/under"
printf 'under_fn(int a) {\n  int v = a + 1;\n} return int v;\n(1):(2)\n' > "$TMP/under/x.id"
printf 'under_fn2(int a) {\n  int v = a + 2;\n} return int v;\n(1):(3)\n' > "$TMP/under/x_2.id"
rm -rf "$TMP/proj27"; mkdir -p "$TMP/proj27"
printf 'main(int argc, string[] argv) {\n  print(1);\n} return int 0;\n' > "$TMP/proj27/main.id"
if ! $BIN_IDC --allow-untested --std "$TMP/under" "$TMP/proj27" -o "$TMP/x" >"$TMP/under.err" 2>&1 \
   && grep -q "is a numbered copy of" "$TMP/under.err" \
   && grep -q "x_2.id" "$TMP/under.err"; then
    ok "an underscore-numbered sibling (x.id, x_2.id) is rejected"
else
    bad "an underscore-numbered sibling (x.id, x_2.id) is rejected"
fi

# -- 34. the library is loaded by use: the program is checked against all of
# it, and the part it does not reach is not checked itself ---------------------
# bin/idc loads only the library functions a program reaches ("The standard
# library is loaded by use") and holds the rest as an index. A program still
# may not take a library function's name, or repeat its body, by not calling it,
# and what a build says about that is what it said when it merged the whole
# library (IDC_STD_FULL=1). Each comparison below runs the build both ways.
unset IDC_STD_FULL
ABS_IDC="$(cd .. && pwd)/bin/idc"
LZ_FLAGS=""
lazy_same() { # lazy_same PROJECT STDDIR -- LAZY_OUT/FULL_OUT: --check's words, both ways
    LAZY_OUT=$(cd "$TMP" && "$ABS_IDC" --allow-untested --std "$2" "$1" --check $LZ_FLAGS 2>&1); LAZY_RC=$?
    FULL_OUT=$(cd "$TMP" && IDC_STD_FULL=1 "$ABS_IDC" --allow-untested --std "$2" "$1" --check $LZ_FLAGS 2>&1); FULL_RC=$?
    [ "$LAZY_RC" -eq "$FULL_RC" ] && [ "$LAZY_OUT" = "$FULL_OUT" ]
}
rm -rf "$TMP/p34"; mkdir -p "$TMP/p34"
cat > "$TMP/p34/main.id" <<'EOF'
tstr_twice(string a) {
  string b = a + "!";
} return string b;
("a"):("a!")
("b"):("b!")

main(int argc, string[] argv) {
  print(1);
} return int 0;
(1, ["p"]):(0)
(2, ["p", "q"]):(0)
EOF
if lazy_same p34 "$FIXTURE" && [ "$LAZY_RC" -ne 0 ] \
   && printf '%s\n' "$LAZY_OUT" | grep -q "function 'tstr_twice' already defined at"; then
    ok "a function named like a library function nothing calls is reported, as when the library is merged whole"
else
    bad "a function named like a library function nothing calls is reported, as when the library is merged whole: $(printf '%s\n' "$LAZY_OUT" | head -2 | tr '\n' ' ')"
fi

# -- 35. ...and a body written again is reported, on whichever of the two the
# build reads second: tstr_twice is never called, so the program's own copy is
# the only place its logic appears.
rm -rf "$TMP/p35"; mkdir -p "$TMP/p35"
cat > "$TMP/p35/main.id" <<'EOF'
mine_twice(string x) {
  string y = x + x;
} return string y;
("a"):("aa")
("b"):("bb")

main(int argc, string[] argv) {
  string s = mine_twice("c");
  print(s);
} return int 0;
(1, ["p"]):(0)
(2, ["p", "q"]):(0)
EOF
want35="function 'mine_twice' has the same signature and logic as 'tstr_twice' (defined at"
want35b="function 'tstr_twice' has the same signature and logic as 'mine_twice' (defined at"
rm -rf "$TMP/zz_std" "$TMP/aa_proj"; cp -r "$FIXTURE" "$TMP/zz_std"; mkdir -p "$TMP/aa_proj"; cp "$TMP/p35/main.id" "$TMP/aa_proj/main.id"
if lazy_same p35 "$FIXTURE" && [ "$LAZY_RC" -ne 0 ] && printf '%s\n' "$LAZY_OUT" | grep -qF "$want35"; then
    ok "a body that repeats a library function nothing calls is reported against the library's, when the library is read first"
else
    bad "a body that repeats a library function nothing calls is reported against the library's, when the library is read first: $(printf '%s\n' "$LAZY_OUT" | head -2 | tr '\n' ' ')"
fi
if lazy_same "$TMP/aa_proj" "$TMP/zz_std" && [ "$LAZY_RC" -ne 0 ] && printf '%s\n' "$LAZY_OUT" | grep -qF "$want35b"; then
    ok "a body that repeats a library function nothing calls is reported at the library's, when the program is read first"
else
    bad "a body that repeats a library function nothing calls is reported at the library's, when the program is read first: $(printf '%s\n' "$LAZY_OUT" | head -2 | tr '\n' ' ')"
fi

# -- 36. a type error in a library function the program does not reach does not
# fail the program's build, and does fail the library's own: the library built
# as the project is what idstd/run.sh's `whole` section runs --------------------
rm -rf "$TMP/idstd_te"; cp -r "$FIXTURE" "$TMP/idstd_te"
sed -i 's/int m = tfx_max(a, 0 - a);/int m = tfx_max(a, "x");/' "$TMP/idstd_te/math/fx.id"
te=$(cd "$TMP/idstd_te" && pwd -P)
rm -rf "$TMP/p36"; mkdir -p "$TMP/p36"
printf 'main(int argc, string[] argv) {\n  int r = tfx_max(4, 9);\n  print(r);\n} return int 0;\n' > "$TMP/p36/main.id"
if $BIN_IDC --std "$te" "$TMP/p36" -o "$TMP/out36" >"$TMP/o36.err" 2>&1 && [ "$("$TMP/out36")" = "9" ]; then
    ok "a type error in a library function the program does not reach does not fail the program"
else
    bad "a type error in a library function the program does not reach does not fail the program: $(head -2 "$TMP/o36.err" | tr '\n' ' ')"
fi
if ! IDC_STD_FULL=1 $BIN_IDC --std "$te" "$TMP/p36" -o "$TMP/out36f" >"$TMP/o36f.err" 2>&1 \
   && ! $BIN_IDC --std "$te" "$te" -o "$TMP/lib36.o" >"$TMP/l36.err" 2>&1 \
   && grep -q "fx.id" "$TMP/o36f.err" && grep -q "fx.id" "$TMP/l36.err"; then
    ok "that type error is found by building the library whole, as a project and merged"
else
    bad "that type error is found by building the library whole, as a project and merged: $(head -2 "$TMP/l36.err" | tr '\n' ' ')"
fi

# -- 37. the same for a case: a failing case of a function the program does not
# reach is the library's concern, one of a function it does reach is the
# program build's (26) -----------------------------------------------------------
rm -rf "$TMP/idstd_fc"; cp -r "$FIXTURE" "$TMP/idstd_fc"
sed -i 's/(-4):(4)/(-4):(5)/' "$TMP/idstd_fc/math/fx.id"
fc=$(cd "$TMP/idstd_fc" && pwd -P)
if $BIN_IDC --std "$fc" "$TMP/p36" -o "$TMP/out37" >"$TMP/o37.err" 2>&1 && [ "$("$TMP/out37")" = "9" ]; then
    ok "a failing case of a library function the program does not reach does not fail the program"
else
    bad "a failing case of a library function the program does not reach does not fail the program: $(head -2 "$TMP/o37.err" | tr '\n' ' ')"
fi
rm -rf "$TMP/p37"; mkdir -p "$TMP/p37"
printf 'main(int argc, string[] argv) {\n  int r = tfx_abs(0 - 4);\n  print(r);\n} return int 0;\n' > "$TMP/p37/main.id"
out=$($BIN_IDC "$TMP/p37" --std "$fc" -o "$TMP/out37b" 2>&1)
if printf '%s\n' "$out" | grep -qF "failed its own test cases" && printf '%s\n' "$out" | grep -qF "tfx_abs(-4)"; then
    ok "a failing case of a library function the program does reach fails it, as the library's"
else
    bad "a failing case of a library function the program does reach fails it, as the library's: $(printf '%s\n' "$out" | head -2 | tr '\n' ' ')"
fi

# -- 38. the library's conf.id constants are loaded by use too: a library
# function that reads one brings it, and one the program does not reach is not
# emitted; a program that declares a constant of the same name is told so -------
rm -rf "$TMP/libc"; mkdir -p "$TMP/libc/num"
printf 'int lc_k = 5;\nint lc_unused = 9;\n' > "$TMP/libc/conf.id"
cat > "$TMP/libc/num/get.id" <<'EOF'
lc_get(int a) {
  int b = a + (import lc_k);
} return int b;
(1):(6)
(2):(7)
EOF
rm -rf "$TMP/p38"; mkdir -p "$TMP/p38"
printf 'main(int argc, string[] argv) {\n  int r = lc_get(3);\n  print(r);\n} return int 0;\n' > "$TMP/p38/main.id"
if $BIN_IDC --std "$TMP/libc" "$TMP/p38" -o "$TMP/out38" --emit-c "$TMP/c38.c" >"$TMP/o38.err" 2>&1 \
   && grep -q "lc_k" "$TMP/c38.c" && ! grep -q "lc_unused" "$TMP/c38.c" \
   && $BIN_IDC --std "$TMP/libc" "$TMP/p38" -o "$TMP/out38" >/dev/null 2>&1 && [ "$("$TMP/out38")" = "8" ]; then
    ok "a library constant a reached function reads is loaded, and one nothing reads is not"
else
    bad "a library constant a reached function reads is loaded, and one nothing reads is not: $(head -2 "$TMP/o38.err" | tr '\n' ' ')"
fi
mkdir -p "$TMP/p38c"
printf 'int lc_k = 7;\n' > "$TMP/p38c/conf.id"
cp "$TMP/p38/main.id" "$TMP/p38c/main.id"
lazy_same p38c "$TMP/libc"
if [ "$LAZY_RC" -ne 0 ] && printf '%s\n' "$LAZY_OUT" | grep -q "constant 'lc_k' is already declared at"; then
    ok "a program constant named like a library constant is reported, as when the library is merged whole"
else
    bad "a program constant named like a library constant is reported, as when the library is merged whole: $(printf '%s\n' "$LAZY_OUT" | head -2 | tr '\n' ' ')"
fi

# -- 39. a program that lives inside the library's own tree is built with the
# whole library, which is also what reads the constants once through its
# enclosing root (idstd/.tests/tool/names is built this way) ------------------
rm -rf "$TMP/libc/app"; mkdir -p "$TMP/libc/app"
cp "$TMP/p38/main.id" "$TMP/libc/app/main.id"
if $BIN_IDC --std "$TMP/libc" "$TMP/libc/app" -o "$TMP/out39" >"$TMP/o39.err" 2>&1 && [ "$("$TMP/out39")" = "8" ]; then
    ok "a program inside the library's tree builds, and reads the library's constants once"
else
    bad "a program inside the library's tree builds, and reads the library's constants once: $(head -2 "$TMP/o39.err" | tr '\n' ' ')"
fi

# -- 40. a collision with a library function the program does not reach is a
# diagnostic of the same record as one inside the program: the code, the why, the
# help and a related place pointing at the library's definition, in each format ---
for fmt in plain json human; do
    LZ_FLAGS="--diagnostics=$fmt"
    case "$fmt" in
        json)  pat='"code":"E0402"'; rel='"related":[{"file":' ;;
        plain) pat='[E0402]'; rel='  related: ' ;;
        human) pat='[E0402]'; rel='the function this one repeats (' ;;
    esac
    if lazy_same p35 "$FIXTURE" && [ "$LAZY_RC" -ne 0 ] && printf '%s\n' "$LAZY_OUT" | grep -qF -- "$pat" && printf '%s\n' "$LAZY_OUT" | grep -qF -- "$rel"; then
        ok "a collision with an unreached library function carries E0402 and a related place in $fmt, as when the library is merged whole"
    else
        bad "a collision with an unreached library function carries E0402 and a related place in $fmt, as when the library is merged whole: $(printf '%s\n' "$LAZY_OUT" | head -2 | cut -c1-200 | tr '\n' ' ')"
    fi
done
LZ_FLAGS="--diagnostics=json"
if lazy_same p34 "$FIXTURE" && printf '%s\n' "$LAZY_OUT" | grep -qF '"code":"E0'; then
    ok "a name collision with an unreached library function is a coded diagnostic in json, as when the library is merged whole"
else
    bad "a name collision with an unreached library function is a coded diagnostic in json, as when the library is merged whole: $(printf '%s\n' "$LAZY_OUT" | head -2 | cut -c1-200 | tr '\n' ' ')"
fi
LZ_FLAGS=""

# -- 41. a variable named like a library variable with another type is one
# diagnostic, whether the build held the library function that declares it or
# only its index -----------------------------------------------------------
# `s` is a string in tstr_twice. p41 never calls it, so a lazy build knows it
# only as a V line of the library's index; p42 calls it, so the build loaded it
# and the registry holds the row. Both must say what the whole library says.
rm -rf "$TMP/p41" "$TMP/p42" "$TMP/p43"; mkdir -p "$TMP/p41" "$TMP/p42" "$TMP/p43"
cat > "$TMP/p41/main.id" <<'EOF2'
total(int a, int b) {
  int s = a + b;
} return int s;
main(int argc, string[] argv) {
  int n = total(2, 3);
  print(n);
} return int 0;
EOF2
cat > "$TMP/p42/main.id" <<'EOF2'
total(int a, int b) {
  int s = a + b;
} return int s;
main(int argc, string[] argv) {
  int n = total(2, 3);
  print(tstr_twice("x") + n);
} return int 0;
EOF2
cat > "$TMP/p43/main.id" <<'EOF2'
total(string s) {
  string u = s + "?";
} return string u;
main(int argc, string[] argv) {
  print(total("x"));
} return int 0;
EOF2
want41="variable 's' is declared int here but string in the standard library [E0303]"
for p in p41 p42; do
    if lazy_same $p "$FIXTURE" && [ "$LAZY_RC" -ne 0 ] && printf '%s\n' "$LAZY_OUT" | grep -qF "$want41"; then
        ok "$p: a variable named like a library variable with another type is reported the same way when the library is merged whole"
    else
        bad "$p: a variable named like a library variable with another type is reported the same way when the library is merged whole: $(printf '%s\n' "$LAZY_OUT" | head -2 | cut -c1-200 | tr '\n' ' ') | $(printf '%s\n' "$FULL_OUT" | head -2 | cut -c1-200 | tr '\n' ' ')"
    fi
done
if lazy_same p43 "$FIXTURE" && [ "$LAZY_RC" -eq 0 ]; then
    ok "a variable named like a library variable with the same type is accepted, loaded or only indexed"
else
    bad "a variable named like a library variable with the same type is accepted, loaded or only indexed: $(printf '%s\n' "$LAZY_OUT" | head -2 | cut -c1-200 | tr '\n' ' ')"
fi
for fmt in plain json human; do
    LZ_FLAGS="--diagnostics=$fmt"
    case "$fmt" in
        json)  pat='"code":"E0303"'; rel='"related":[{"file":' ;;
        plain) pat='[E0303]'; rel='  related: ' ;;
        human) pat='[E0303]'; rel="the standard library's declaration, which is string (" ;;
    esac
    if lazy_same p41 "$FIXTURE" && [ "$LAZY_RC" -ne 0 ] && printf '%s\n' "$LAZY_OUT" | grep -qF -- "$pat" && printf '%s\n' "$LAZY_OUT" | grep -qF -- "$rel"; then
        ok "a collision of a variable with the library's carries E0303 and a related place in $fmt, as when the library is merged whole"
    else
        bad "a collision of a variable with the library's carries E0303 and a related place in $fmt, as when the library is merged whole: $(printf '%s\n' "$LAZY_OUT" | head -2 | cut -c1-200 | tr '\n' ' ')"
    fi
done
LZ_FLAGS=""

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
