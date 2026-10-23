#!/usr/bin/env bash
# Test clauses: the cases written under a function, run by the compiler.
# See docs/TESTS.md for what they mean; this file checks that bin/idc does it
# on every build. idc.py is frozen (docs/HACKING.md) and no longer built
# against here -- see git history for the checks this file used to run
# against its own --tests/--require-tests flags.
#
# Every program here is written to $TMP and built with IDC_NO_STD=1, so what a
# case measures is the function under test and nothing else -- a standard
# library merged into the program would put its own functions (and its own
# allocations) into the same harness.
#
# Run from anywhere: tests/tests_feature.sh [0-4]
#
# The checks are five chunks, tf_chunk_0..4, so that none runs over the minute;
# tests/run.sh runs them as tests_feature_0..4. No argument runs all five.
set -u
cd "$(dirname "$0")"

# The environment must not leak in: a developer with IDSTD_HOME set would
# otherwise get different results from this file than CI does.
unset IDSTD_HOME
export IDC_NO_STD=1

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

# bin/idc runs every written case on every build, with no flag and no opt-out.
# The program under test is always $TMP/p.id, written by the heredoc above
# each check.
self_build() {
    ../bin/idc "$TMP/p.id" "$@" >"$TMP/log" 2>&1
}
self_accept() {   # desc, flags...
    local desc="$1"; shift
    if self_build "$@"; then ok "$desc"; else bad "$desc ($(head -1 "$TMP/log"))"; fi
}
self_refuse() {   # desc, expected message (fixed string), flags...
    local desc="$1" want="$2"; shift 2
    if self_build "$@"; then
        bad "$desc (built; it should not have)"
    elif grep -qF "$want" "$TMP/log"; then
        ok "$desc"
    else
        bad "$desc (wrong message: $(head -1 "$TMP/log"))"
    fi
}

tf_chunk_0() {
printf '%s' 'add(int a, int b) {
  int s = a * 2 + b;
} return int s;
(1, 2):(4)
(0, 0):(0)
' > "$TMP/p.id"
if ../bin/idc "$TMP/p.id" --require-tests --emit-c /dev/null >/dev/null 2>&1; then
    ok "bin/idc accepts a function with two cases"
else
    bad "bin/idc accepts a function with two cases"
fi

# --- two cases must be two cases ---------------------------------------------
# The cheapest way to satisfy a two-case minimum without producing any evidence
# is to write the same case twice, so a duplicate is an error. Checked ALWAYS,
# not only under --require-tests: it is wrong in a program that writes cases
# voluntarily too. This rule lives only in the self-hosted compiler.
dup_case() { # desc, source, flags...
    local desc="$1" src="$2"; shift 2
    printf '%s' "$src" > "$TMP/p.id"
    if ../bin/idc "$TMP/p.id" "$@" --emit-c /dev/null >"$TMP/log" 2>&1; then
        bad "$desc (built; it should not have)"
    elif grep -qF "identical to an earlier one" "$TMP/log"; then
        ok "$desc"
    else
        bad "$desc (wrong message: $(head -1 "$TMP/log"))"
    fi
}
dup_case "an identical case is rejected" 'add(int a, int b) {
  int s = a + b;
} return int s;
(1, 2):(3)
(1, 2):(3)
'
# Compared by tokens, so spacing cannot smuggle a duplicate past the rule.
dup_case "whitespace does not hide a duplicate" 'add(int a, int b) {
  int s = a + b;
} return int s;
(1,2):(3)
(1, 2) : (3)
'
# Same case text under two DIFFERENT functions is not a duplicate.
printf '%s' 'add(int a, int b) {
  int s = a * 2 + b;
} return int s;
(1, 2):(4)
(0, 0):(0)

mul(int a, int b) {
  int p = a * b * 2;
} return int p;
(1, 2):(4)
(0, 0):(0)
' > "$TMP/p.id"
if ../bin/idc "$TMP/p.id" --require-tests --emit-c /dev/null >/dev/null 2>&1; then
    ok "the same case under two functions is not a duplicate"
else
    bad "the same case under two functions is not a duplicate"
fi

# --- lists returned ----------------------------------------------------------
cat > "$TMP/p.id" <<'EOF'
grow(int[] xs) {
  push(xs, 9);
} return int[] xs;
([1]):([1, 9])
([]):([9])
EOF
self_accept "bin/idc: a list case builds" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
grow(int[] xs) {
  push(xs, 9);
} return int[] xs;
([1]):([1, 8])
([]):([9])
EOF
self_refuse "bin/idc: a list case compares elementwise" \
    "test failed: grow([1]) = [1, 9], expected [1, 8]" --emit-c /dev/null

# --- floats ------------------------------------------------------------------
cat > "$TMP/p.id" <<'EOF'
half(float x) {
  float h = x / 2.0;
} return float h;
(3.0):(1.5)
(1.0):(0.5)
EOF
self_accept "bin/idc: a float case builds" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
half(float x) {
  float h = x / 2.0;
} return float h;
(3.0):(1.4)
(1.0):(0.5)
EOF
self_refuse "bin/idc: a float case compares by value" \
    "test failed: half(3.0) = 1.5, expected 1.4" --emit-c /dev/null

# --- a constraint needs two cases to compare ---------------------------------
cat > "$TMP/p.id" <<'EOF'
total(int[] xs) {
  int t = 0;
  int i = 0;
  while(i < len(xs)) {
    t = t + xs[i];
    i = i + 1;
  }
} return int t;
([1, 2, 3]):(6)[time:O(n)]
([4, 5, 6]):(15)[time:O(n)]
EOF
self_refuse "bin/idc: two cases of the same size cannot compare either" \
    "p.id:9: error: [time:O(n)] has 2 cases but they all give n = 3, so there is no second input size to compare" \
    --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
total(int[] xs, int cap) {
  int t = 0;
  int i = 0;
  while(i < len(xs)) {
    t = t + xs[i];
    i = i + 1;
  }
} return int t;
([1, 2, 3], 1000):(6)[time:O(n)]
([1, 2, 3, 4, 5, 6, 7, 8, 9], 1000):(45)[time:O(n)]
EOF
self_refuse "bin/idc: cases whose size comes from one large integer argument say what n is" \
    "p.id:9: error: [time:O(n)] has 2 cases but they all give n = 1000, so there is no second input size to compare; n is the largest of every list length, string length and integer value among a case's arguments" \
    --emit-c /dev/null

# --- malformed cases ---------------------------------------------------------
cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;
(1, 2)(3)
(0, 0):(0)
EOF
self_refuse "bin/idc: a case needs the ':' between its two sides" "expected ':'" --emit-c /dev/null

# --- two cases per function, by default ---------------------------------------
# Every build of bin/idc applies the two-case minimum, with the diagnostic
# --require-tests gives. --allow-untested is the way out while the tree is
# catching up: it turns the minimum off and changes nothing else -- not the
# exit status, and not stdout, which can be the program's C, and it is
# silent (id has no warnings: something is allowed or it is not).
printf '%s' 'add(int a, int b) {
  int s = a * 2 + b;
} return int s;
' > "$TMP/p.id"
self_refuse "bin/idc: a function with no cases fails a default build" \
    "function 'add' has 0 test case(s); --require-tests needs at least 2 (see docs/TESTS.md)" --emit-c /dev/null
../bin/idc "$TMP/p.id" --allow-untested -o "$TMP/out" >"$TMP/stdout" 2>"$TMP/stderr"
[ $? -eq 0 ] \
    && ok "bin/idc: --allow-untested builds a function with no cases" \
    || bad "bin/idc: --allow-untested builds a function with no cases ($(head -1 "$TMP/stderr"))"
[ ! -s "$TMP/stderr" ] \
    && ok "bin/idc: --allow-untested prints nothing on stderr" \
    || bad "bin/idc: --allow-untested prints nothing on stderr (stderr: $(tr '\n' '|' < "$TMP/stderr"))"
[ -e "$TMP/out" ] && [ ! -s "$TMP/stdout" ] \
    && ok "bin/idc: --allow-untested prints nothing on stdout" \
    || bad "bin/idc: --allow-untested prints nothing on stdout"

printf '%s' 'add(int a, int b) {
  int s = a * 2 + b;
} return int s;
(1, 2):(4)
' > "$TMP/p.id"
self_refuse "bin/idc: a function with one case fails a default build" \
    "function 'add' has 1 test case(s); --require-tests needs at least 2 (see docs/TESTS.md)" --emit-c /dev/null
self_accept "bin/idc: --allow-untested builds a function with one case" --allow-untested --emit-c /dev/null
[ ! -s "$TMP/log" ] || ! grep -qF -- "--allow-untested" "$TMP/log" \
    && ok "bin/idc: --allow-untested is silent on a one-case build" \
    || bad "bin/idc: --allow-untested is silent on a one-case build (log: $(tr '\n' '|' < "$TMP/log"))"

printf '%s' 'add(int a, int b) {
  int s = a * 2 + b;
} return int s;
(1, 2):(5)
(0, 0):(0)
' > "$TMP/p.id"
self_refuse "bin/idc: --allow-untested does not turn a failing case into a build" \
    "p.id:4: test failed: add(1, 2) = 4, expected 5" --allow-untested --emit-c /dev/null

printf '%s' 'add(int a, int b) {
  int s = a * 2 + b;
} return int s;
(1, 2):(4)
(0, 0):(0)
' > "$TMP/p.id"
../bin/idc "$TMP/p.id" --emit-c /dev/null >"$TMP/stdout" 2>"$TMP/stderr"
[ $? -eq 0 ] && [ ! -s "$TMP/stderr" ] \
    && ok "bin/idc: a fully cased program builds by default, with no warning" \
    || bad "bin/idc: a fully cased program builds by default, with no warning ($(head -1 "$TMP/stderr"))"

cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a * 2 + b;
} return int s;
(1, 2):(4)
(0, 0):(0)

main(int argc, string[] argv) {
  int r = add(2, 3);
  print("sum " + r);
} return int 0;
EOF
rm -f "$TMP/out"
self_accept "bin/idc: passing cases build" --allow-untested -o "$TMP/out"
[ "$("$TMP/out" 2>&1)" = "sum 7" ] \
    && ok "bin/idc: a program whose cases pass runs" \
    || bad "bin/idc: a program whose cases pass runs"

cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a * 2 + b;
} return int s;
(1, 2):(5)
(0, 0):(0)
(2, 2):(7)

main(int argc, string[] argv) {
  int r = add(2, 3);
  print("sum " + r);
} return int 0;
EOF
rm -f "$TMP/out"
self_refuse "bin/idc: a false case fails the build" \
    "p.id:4: test failed: add(1, 2) = 4, expected 5" --allow-untested -o "$TMP/out"
grep -qF "p.id:6: test failed: add(2, 2) = 6, expected 7" "$TMP/log" \
    && ok "bin/idc: every failing case is reported, not only the first" \
    || bad "bin/idc: every failing case is reported, not only the first"
[ ! -e "$TMP/out" ] \
    && ok "bin/idc: a failing case produces no program" \
    || bad "bin/idc: a failing case produces no program"
rm -f "$TMP/emitted.c"
../bin/idc "$TMP/p.id" --allow-untested --emit-c "$TMP/emitted.c" >/dev/null 2>&1
[ ! -f "$TMP/emitted.c" ] \
    && ok "bin/idc: a failing case blocks --emit-c too" \
    || bad "bin/idc: a failing case blocks --emit-c too (the C was written anyway)"

mkdir -p "$TMP/locp/lib"
cat > "$TMP/locp/main.id" <<'EOF'
main(int argc, string[] argv) {
  int d = dbl(argc);
  print(d);
} return int 0;
EOF
cat > "$TMP/locp/lib/dbl.id" <<'EOF'
dbl(int a) {
  int r = a * 2;
} return int r;
(1):(2)
(4):(9)
EOF
env -u IDC_NO_STD ../bin/idc "$TMP/locp" --allow-untested -o "$TMP/locp.out" > "$TMP/locp.log" 2>&1
grep -qF "locp/lib/dbl.id:5: test failed: dbl(4) = 8, expected 9" "$TMP/locp.log" \
    && ok "bin/idc: a failing case names its own file with the standard library merged in" \
    || bad "bin/idc: a failing case names its own file with the standard library merged in (got: $(head -1 "$TMP/locp.log"))"

# The cases reach the harness and nothing else: the program's C is the same
# with them and without them, and carries no counter.
printf '%s' 'add(int a, int b) {
  int s = a * 2 + b;
} return int s;
(1, 2):(4)
(0, 0):(0)
' > "$TMP/p.id"
printf '%s' 'add(int a, int b) {
  int s = a * 2 + b;
} return int s;
' > "$TMP/q.id"
../bin/idc "$TMP/p.id" --emit-c "$TMP/with.c" >/dev/null 2>&1
../bin/idc "$TMP/q.id" --allow-untested --emit-c "$TMP/without.c" >/dev/null 2>&1
if [ -s "$TMP/with.c" ] && cmp -s "$TMP/with.c" "$TMP/without.c" && ! grep -q "id_ctr_\|idtc_" "$TMP/with.c"; then
    ok "bin/idc: cases do not change the program's C"
else
    bad "bin/idc: cases do not change the program's C"
fi

cat > "$TMP/p.id" <<'EOF'
fill(int[] xs, int n) {
  int i = 0;
  while(i < n) {
    push(xs, i);
    i = i + 1;
  }
} return void;
([], 3):([0, 1, 2])
([], 0):([])
EOF
self_accept "bin/idc: a void function is tested through its list argument" --emit-c /dev/null
cat > "$TMP/p.id" <<'EOF'
fill(int[] xs, int n) {
  int i = 0;
  while(i < n) {
    push(xs, i);
    i = i + 1;
  }
} return void;
([], 3):([0, 1, 3], 3)
([], 0):([])
EOF
self_refuse "bin/idc: a void function's arguments are compared after the call" \
    "p.id:8: test failed: fill([], 3) = ([0, 1, 2], 3), expected ([0, 1, 3], 3)" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
greet(string who) {
  string s = "hi " + who;
} return string s;
("bob"):("hi bob")
("a\"b"):("hi a\"b")
EOF
self_accept "bin/idc: a string case builds" --emit-c /dev/null
cat > "$TMP/p.id" <<'EOF'
greet(string who) {
  string s = "hi " + who;
} return string s;
("bob"):("hello bob")
(""):("hi ")
EOF
self_refuse "bin/idc: a string case compares by content" \
    'test failed: greet("bob") = "hi bob", expected "hello bob"' --emit-c /dev/null
}

tf_chunk_1() {
# --- a trigraph in a string literal is its three characters ------------------
cat > "$TMP/p.id" <<'EOF2'
tag(string s) {
  string r = s + "??>";
} return string r;
("??("):("??(??>")
("x"):("x??)")
EOF2
self_refuse "bin/idc: a case literal and its message keep a trigraph as written" \
    'test failed: tag("x") = "x??>", expected "x??)"' --emit-c /dev/null
sed -i 's/"x??)"/"x??>"/' "$TMP/p.id"
self_accept "bin/idc: a string case holding trigraph sequences passes" --allow-untested --emit-c /dev/null
cat > "$TMP/p.id" <<'EOF2'
measure(string s) {
  int n = len(s) * 2;
} return int n;
("abcd"):(8)[time:O(n), mem:O(1)]
("abcdefgh??/"):(22)[time:O(n), mem:O(1)]
EOF2
self_accept "bin/idc: a scaling claim sizes a literal ending in a trigraph by its bytes" --emit-c /dev/null

# --- a case that stops on its own is that case failing -----------------------
cat > "$TMP/p.id" <<'EOF'
quot(int a, int b) {
  int q = a / b + a % b;
} return int q;
(6, 0):(0)
(7, 3):(3)
(7, 0):(1)
EOF
self_refuse "bin/idc: a trapping case is reported at its line" \
    "p.id:4: test failed: quot(6, 0) trapped: id: division by zero" --emit-c /dev/null
grep -qF "p.id:6: test failed: quot(7, 0) trapped: id: division by zero" "$TMP/log" \
    && ok "bin/idc: a trap in one case does not stop the next" \
    || bad "bin/idc: a trap in one case does not stop the next"

cat > "$TMP/p.id" <<'EOF'
down(int n) {
  int r = down(n + 1);
} return int r;
(0):(0)
(1):(1)
EOF
self_refuse "bin/idc: a crashing case is reported with its signal" \
    "p.id:4: test failed: down(0) was killed by signal" --emit-c /dev/null

# --- callees first, and a caller of a failed case is not run ------------------
# top calls mid calls leaf, written in that order, so index order would run
# the callers first. leaf's `traps` case passes and its second case fails.
cat > "$TMP/p.id" <<'EOF'
top(int a) {
  int t = mid(a) * 3;
} return int t;
(1):(36)
(2):(18)

mid(int a) {
  int m = leaf(a) * 2;
} return int m;
(1):(12)
(3):(4)

leaf(int a) {
  int q = 6 / a;
} return int q;
(0):() then traps:("division by zero")
(3):(3)
EOF
export IDC_SHOW_NOT_RUN=1
self_refuse "bin/idc: a caller of a function whose case failed is reported not run (IDC_SHOW_NOT_RUN lists each)" \
    "p.id:10: not run: mid(1) depends on leaf, whose case at $TMP/p.id:17 failed" --emit-c /dev/null
grep -qF "p.id:4: not run: top(1) depends on leaf, whose case at $TMP/p.id:17 failed" "$TMP/log" \
    && grep -qF "p.id:5: not run: top(2) depends on leaf" "$TMP/log" \
    && ! grep -q 'test failed: \(top\|mid\)' "$TMP/log" \
    && ! grep -q 'p.id:16' "$TMP/log" \
    && ok "bin/idc: a failure skips every transitive caller's cases, and none of them runs" \
    || bad "bin/idc: a failure skips every transitive caller's cases, and none of them runs ($(cat "$TMP/log"))"
leaf_at=$(grep -n 'p.id:17: test failed' "$TMP/log" | cut -d: -f1)
top_at=$(grep -n 'p.id:4: not run' "$TMP/log" | cut -d: -f1)
[ -n "$leaf_at" ] && [ -n "$top_at" ] && [ "$leaf_at" -lt "$top_at" ] \
    && ok "bin/idc: a callee's cases run before its callers', whatever the file order" \
    || bad "bin/idc: a callee's cases run before its callers', whatever the file order ($(cat "$TMP/log"))"
unset IDC_SHOW_NOT_RUN
self_refuse "bin/idc: without IDC_SHOW_NOT_RUN the cases not run are one summary line, not one line each" \
    "idc: 1 case(s) failed; 4 more not run, because a function they call failed a case (the first failure was a case of 'leaf' at $TMP/p.id:17; set IDC_SHOW_NOT_RUN=1 to list each case not run)" --emit-c /dev/null
! grep -q 'not run:' "$TMP/log" \
    && ok "bin/idc: a failing case is followed by one summary line, not a line for each case that depended on it" \
    || bad "bin/idc: a failing case is followed by one summary line, not a line for each case that depended on it ($(cat "$TMP/log"))"

# other is independent of caller and leaf, and fails on its own.
cat > "$TMP/p.id" <<'EOF'
caller(int a) {
  int c = leaf(a) * 2;
} return int c;
(1):(12)
(3):(4)

other(int a) {
  int o = a * 2;
} return int o;
(1):(3)
(2):(4)

leaf(int a) {
  int q = 6 / a;
} return int q;
(1):(6)
(3):(3)
EOF
self_refuse "bin/idc: an independent function's cases still run beside a skipped caller" \
    "p.id:10: test failed: other(1) = 2, expected 3" --emit-c /dev/null
! grep -q 'not run:' "$TMP/log" \
    && grep -qF "idc: 2 case(s) failed; 2 more not run, because a function they call failed a case (the first failure was a case of 'leaf' at $TMP/p.id:17" "$TMP/log" \
    && ok "bin/idc: the summary counts the failed cases and the ones not run" \
    || bad "bin/idc: the summary counts the failed cases and the ones not run ($(cat "$TMP/log"))"

# --- then traps:("TEXT") (docs/TESTS.md) --------------------------------------
# bin/idc only: idc.py lexes `traps` as an ordinary identifier the same way it
# does `given`/`then`/`prints`/`eprints`/`calls`.
cat > "$TMP/p.id" <<'EOF'
quot(int a, int b) {
  int q = a / b + a % b;
} return int q;
(6, 0):() then traps:("division by zero")
(7, 3):(3)
EOF
self_accept "bin/idc: a matching 'traps' check builds" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
quot(int a, int b) {
  int q = a / b + a % b;
} return int q;
(6, 0):() then traps:("out of bounds")
(7, 3):(3)
EOF
self_refuse "bin/idc: a mismatching 'traps' check fails, showing both sides" \
    "p.id:4: test failed: quot(6, 0) trapped: id: division by zero, expected a trap containing out of bounds" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
quot(int a, int b) {
  int q = a / b + a % b;
} return int q;
(7, 3):() then traps:("division by zero")
(7, 2):(4)
EOF
self_refuse "bin/idc: a function that returns instead of trapping fails 'traps'" \
    "p.id:4: test failed: quot(7, 3) expected a trap containing division by zero, but it returned" --emit-c /dev/null

# A signal death (docs/TESTS.md's "was killed by signal") counts as a trap
# too, matched against the same text idtc_report would otherwise print.
cat > "$TMP/p.id" <<'EOF'
down(int n) {
  int r = down(n + 1);
} return int r;
(0):() then traps:("signal 11")
(1):() then traps:("Segmentation fault")
EOF
self_accept "bin/idc: 'traps' matches a death by signal, not only a runtime trap" --emit-c /dev/null

# A case whose `given` omits the setup reads an export nothing has set. The
# harness traps on it for every type (docs/SPEC.md 8) -- a string used to
# segfault and an int to read 0 -- while the program's own C carries no check.
cat > "$TMP/p.id" <<'EOF'
setup_s() {
  export string gs = "x";
} return void;
():() then read_s:("x")
given setup_s ():() then read_s:("x")

read_s() {
  string v = (import gs);
} return string v;
given setup_s ():("x")
():() then traps:("uninitialised export")

main(int argc, string[] argv) {
  setup_s();
  print(read_s());
} return int 0;
(1, ["p"]):(0)
(2, ["p", "q"]):(0)
EOF
self_accept "bin/idc: a string export read before its setup traps in a case" --emit-c "$TMP/out.c"
if grep -q idtc_set "$TMP/out.c"; then
    bad "bin/idc: the program's C carries no uninitialised-export check"
else
    ok "bin/idc: the program's C carries no uninitialised-export check"
fi

cat > "$TMP/p.id" <<'EOF'
setup_i() {
  export int gi = 7;
} return void;
():() then read_i:(7)
given setup_i ():() then read_i:(7)

read_i() {
  int v = (import gi);
} return int v;
given setup_i ():(7)
():() then traps:("uninitialised export")

main(int argc, string[] argv) {
  setup_i();
  print("" + read_i());
} return int 0;
(1, ["p"]):(0)
(2, ["p", "q"]):(0)
EOF
self_accept "bin/idc: an int export read before its setup traps in a case" --emit-c /dev/null

sed -i 's/^():() then traps:("uninitialised export")$/():(7)/' "$TMP/p.id"
self_refuse "bin/idc: an int export read before its setup fails the case, not reads 0" \
    "p.id:11: test failed: read_i() trapped: id: read of an uninitialised export (its declaring function has not run)" --emit-c /dev/null

# Flat-store addresses are the case's own: the second case would be handed a
# later address if the first case's allocation were still live.
cat > "$TMP/p.id" <<'EOF'
first_addr(word n) {
  word a = alloc(n) + n;
} return word a;
(8):(16)
(64):(72)
EOF
self_accept "bin/idc: each case sees the flat store as if it ran alone" --emit-c /dev/null

# --- constraints -------------------------------------------------------------
cat > "$TMP/p.id" <<'EOF'
total(int[] xs) {
  int t = 0;
  int i = 0;
  while(i < len(xs)) {
    t = t + xs[i];
    i = i + 1;
  }
} return int t;
([1, 2, 3]):(6)[time:O(n), mem:O(1)]
([1, 2, 3, 4, 5, 6]):(21)[time:O(n), mem:O(1)]
EOF
self_accept "bin/idc: a scaling claim that holds builds" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
quad(int n) {
  int t = 0;
  int i = 0;
  while(i < n) {
    t = t + inner(n);
    i = i + 1;
  }
} return int t;
(2):(4)[time:O(n)]
(30):(900)[time:O(n)]

inner(int n) {
  int j = 0;
  int t = 0;
  while(j < n) {
    t = t + 1;
    j = j + 1;
  }
} return int t;
(1):(1)
(2):(2)
EOF
self_refuse "bin/idc: a quadratic function cannot claim O(n)" \
    "p.id:10: error: [time:O(n)] does not hold for 'quad'" --emit-c /dev/null

# A single loop that is quadratic only because each `+` copies the string so
# far: this fails only if the runtime's own work is counted.
cat > "$TMP/p.id" <<'EOF'
build(int n) {
  string out = "";
  int i = 0;
  while(i < n) {
    out = out + "x";
    i = i + 1;
  }
} return string out;
(4):("xxxx")[time:O(n)]
(64):("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")[time:O(n)]
EOF
self_refuse "bin/idc: string building in a loop is caught as quadratic, with docs/TESTS.md's counts" \
    "p.id:10: error: [time:O(n)] does not hold for 'build': time is 15 at n=4 and 2145 at n=64, where O(n) allows at most 960" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
total(int[] xs) {
  int t = 0;
  int i = 0;
  while(i < len(xs)) {
    t = t + xs[i];
    i = i + 1;
  }
} return int t;
([1, 2, 3]):(6)
([1, 2, 3, 4, 5, 6]):(21)[mem:O(1)]
EOF
self_refuse "bin/idc: a claim carried by one case is rejected" \
    "p.id:10: error: [mem:O(1)] needs a second case with a different input size to compare against" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;
(1, 2):(3)[time:O(n^3)]
(0, 0):(0)
EOF
self_refuse "bin/idc: an unknown bound is named" "unknown bound 'O(n^3)'" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;
(1, 2):(3)[cpu:O(n)]
(0, 0):(0)
EOF
self_refuse "bin/idc: an unknown constraint is named" "unknown constraint 'cpu'" --emit-c /dev/null

# --- cases that fit their function -------------------------------------------
cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;
(a, 2):(3)
(0, 0):(0)
EOF
self_refuse "bin/idc: a case argument must be a literal" "a test case takes literals only" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;
(1):(3)
(0, 0):(0)
EOF
self_refuse "bin/idc: a case with the wrong number of arguments is rejected" \
    "p.id:4: error: this case passes 1 argument(s) to 'add', which takes 2" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;
("x", 2):(3)
(0, 0):(0)
EOF
self_refuse "bin/idc: a case argument of the wrong type is rejected" \
    "this case gives a string where a int is required" --emit-c /dev/null

# --- given, then, and (import NAME) ------------------------------------------
# A case may name a setup to run first and checks to run after, and read an
# export the setup made. These are rules of the self-hosted compiler only:
# idc.py does not parse them, so none of this is in tests/invalid/.
cat > "$TMP/p.id" <<'EOF'
buf_setup() {
  export word gb = alloc(8);
} return void;

fill3(word p) {
  poke8(p, 3);
} return void;
given buf_setup ((import gb)):((import gb)) then first_byte:(3)
given buf_setup ((import gb)):() then first_byte:(3)

first_byte() {
  word b = peek8((import gb));
} return word b;
EOF
self_accept "bin/idc: a setup's address is passed in, and a check reads it back" --allow-untested --emit-c /dev/null

sed -i 's/((import gb)) then first_byte:(3)$/((import gb)) then first_byte:(4)/' "$TMP/p.id"
self_refuse "bin/idc: a check that does not hold fails the case, naming the check" \
    "p.id:8: test failed: fill3((import gb)) then first_byte() = 3, expected 4" --allow-untested --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
err_setup() {
  export int[] err_n = [0];
} return void;

err_report(string msg) {
  int[] c = (import err_n);
  c[0] = c[0] + 1;
} return void;
given err_setup ("x"):("x") then count:(1)
given err_setup ("y"):() then count:(1)

count() {
  int n = (import err_n)[0];
} return int n;
EOF
self_accept "bin/idc: a void function that only writes module state is tested by a check" --allow-untested --emit-c /dev/null

sed -i 's/("x"):("x") then count:(1)/("x"):("x") then count:(2)/' "$TMP/p.id"
self_refuse "bin/idc: ... and a check that does not hold fails it" \
    'p.id:9: test failed: err_report("x") then count() = 1, expected 2' --allow-untested --emit-c /dev/null

# --- then (import NAME) and then (import NAME)[i] ----------------------------------
# A check may read an export, or one element of it, instead of naming a
# function that does. The function under test may not read that export itself.
cat > "$TMP/p.id" <<'EOF'
mk() {
  export int[] cnt = [0, 5];
  export string tag = "a";
} return void;

bump(int k) {
  int[] c = (import cnt);
  c[k] = c[k] + 1;
} return void;

wrap(int k) {
  bump(k);
  bump(k);
} return void;
given mk (0):() then (import cnt)[0]:(2) then (import cnt)[1]:(5) then (import tag):("a") then (import cnt):([2, 5])
given mk (1):() then (import cnt)[1]:(7)
EOF
self_accept "bin/idc: a check reads an export, an element of it, or the whole list" --allow-untested --emit-c /dev/null

sed -i 's/then (import cnt)\[1\]:(7)$/then (import cnt)[1]:(8)/' "$TMP/p.id"
self_refuse "bin/idc: an element check that does not hold fails the case, naming the element" \
    "p.id:16: test failed: wrap(1) then (import cnt)[1] = 7, expected 8" --allow-untested --emit-c /dev/null

sed -i 's/then (import cnt)\[1\]:(8)$/then (import cnt)[1]:(7) then (import cnt):([0, 8])/' "$TMP/p.id"
self_refuse "bin/idc: a whole-export check that does not hold fails the case, showing the list" \
    "p.id:16: test failed: wrap(1) then (import cnt) = [0, 7], expected [0, 8]" --allow-untested --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
mk() {
  export int[] cnt = [0, 5];
} return void;

wrap(int k) {
  int a = (import cnt)[k];
} return void;
given mk (0):() then (import cnt)[0]:(0)
given mk (1):() then (import cnt)[1]:(5)
EOF
self_refuse "bin/idc: then (import NAME) under a function that only reads NAME is rejected, naming the fix" \
    "p.id:8: error: then (import cnt): the function under test, 'wrap', reads (import cnt) but never writes it, so this check would only repeat its own read; check an export the function changes, or write one check function that states the whole expected state and name it in 'then CHECK:(value)'" --allow-untested --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
mk() {
  export int[] cnt = [0, 5];
} return void;

wrap(int k) {
  int[] c = (import cnt);
  c[k] = c[k] + 1;
} return void;
given mk (0):() then (import cnt)[0]:(1)
given mk (1):() then (import cnt)[1]:(6)
EOF
self_accept "bin/idc: then (import NAME) under a function that reads NAME and writes it is accepted" --allow-untested --emit-c /dev/null

sed -i 's/then (import cnt)\[1\]:(6)$/then (import cnt)[1]:(5)/' "$TMP/p.id"
self_refuse "bin/idc: ... and the check holds the write to its effect" \
    "p.id:10: test failed: wrap(1) then (import cnt)[1] = 6, expected 5" --allow-untested --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
mk() {
  export int[] cnt = [0, 5];
  export string tag = "ab";
} return void;

grow(int k) {
  push((import cnt), k);
  push((import cnt), k * 2);
} return void;
given mk (0):() then len((import cnt)):(4) then len((import tag)):(2)
given mk (1):() then len((import cnt)):(4)
EOF
self_accept "bin/idc: then len((import NAME)) measures a list or a string export" --allow-untested --emit-c /dev/null

sed -i 's/then len((import cnt)):(4)$/then len((import cnt)):(2)/' "$TMP/p.id"
self_refuse "bin/idc: a len check that does not hold fails the case, naming the length" \
    "p.id:11: test failed: grow(1) then len((import cnt)) = 4, expected 2" --allow-untested --emit-c /dev/null

# A check may read a field of a struct export, nested fields, an element of a
# list field and the length of one, and the value is held to the field's type.
# A struct is declared in a file of its own.
FLDIR="$TMP/fldir"; mkdir -p "$FLDIR/types"
printf 'struct Page {\n  int[] starts;\n  int count;\n}\n' > "$FLDIR/types/page.id"
printf 'struct Book {\n  Page pages;\n  string title;\n}\n' > "$FLDIR/types/book.id"
cat > "$FLDIR/main.id" <<'EOF2'
book_open() {
  Page pg = Page([0, 0], 2);
  export Book bk = Book(pg, "t");
} return void;

book_grow(Book b, int n) {
  b.pages.count = b.pages.count + n;
  push(b.pages.starts, n);
} return void;

book_add(int n) {
  book_grow((import bk), n);
  book_grow((import bk), n);
} return void;
given book_open (1):() then (import bk).pages.count:(4) then len((import bk).pages.starts):(4)
given book_open (2):() then (import bk).pages.starts[2]:(2) then (import bk).title:("t") then (import bk).pages.starts:([0, 0, 2, 2])
EOF2
cat > "$FLDIR/run.id" <<'EOF2'
book_push(int n) {
  push((import bk).pages.starts, n);
  push((import bk).pages.starts, n * 2);
} return void;
given book_open (7):() then (import bk).pages.starts[2]:(7) then len((import bk).pages.starts):(4)
given book_open (8):() then (import bk).pages.starts:([0, 0, 8, 16])

main(int argc, string[] argv) {
} return int 0;
EOF2
if ../bin/idc "$FLDIR" --allow-untested --emit-c /dev/null >"$TMP/log" 2>&1; then
    ok "bin/idc: a check reads a field, a nested field, an element and the length of a list field"
else
    bad "bin/idc: a check reads a field, a nested field, an element and the length of a list field ($(grep -v warning "$TMP/log" | head -1))"
fi
sed -i 's/then (import bk).pages.count:(4)/then (import bk).pages.count:(5)/' "$FLDIR/main.id"
if ../bin/idc "$FLDIR" --allow-untested --emit-c /dev/null >"$TMP/log" 2>&1; then
    bad "bin/idc: a field check that does not hold fails the case (built; it should not have)"
elif grep -qF "main.id:15: test failed: book_add(1) then (import bk).pages.count = 4, expected 5" "$TMP/log"; then
    ok "bin/idc: a field check that does not hold fails the case, naming the path"
else
    bad "bin/idc: a field check that does not hold fails the case, naming the path ($(grep -v warning "$TMP/log" | head -1))"
fi
sed -i 's/then (import bk).pages.count:(5)/then (import bk).pages.count:(4)/; s/then (import bk).title:("t")/then (import bk).title:(5)/' "$FLDIR/main.id"
if ../bin/idc "$FLDIR" --allow-untested --emit-c /dev/null >"$TMP/log" 2>&1; then
    bad "bin/idc: a field check holds its value to the field's type (built; it should not have)"
elif grep -qF "main.id:16: error: this case gives a int where a string is required" "$TMP/log"; then
    ok "bin/idc: a field check holds its value to the field's type"
else
    bad "bin/idc: a field check holds its value to the field's type ($(grep -v warning "$TMP/log" | head -1))"
fi

# A field is a position in the struct, so the struct's own file is part of what
# a field check reads: changing the order of the fields must run the case again,
# not reuse its earlier pass.
CKDIR="$TMP/ckdir"; mkdir -p "$CKDIR/types"
printf 'struct Pt {\n  int x;\n  int y;\n}\n' > "$CKDIR/types/pt.id"
cat > "$CKDIR/main.id" <<'EOF2'
pt_open() {
  Pt p = Pt(1, 2);
  export Pt pt = p;
} return void;

pt_set(Pt q, int d) {
  q.x = q.x + d;
} return void;

pt_move(int d) {
  pt_set((import pt), d);
  pt_set((import pt), d);
} return void;
given pt_open (1):() then (import pt).y:(2)
given pt_open (2):() then (import pt).x:(5)
EOF2
cat > "$CKDIR/run.id" <<'EOF2'
main(int argc, string[] argv) {
} return int 0;
EOF2
if ../bin/idc "$CKDIR" --allow-untested --emit-c /dev/null >"$TMP/log" 2>&1; then
    ok "bin/idc: a field check of a struct builds"
else
    bad "bin/idc: a field check of a struct builds ($(grep -v warning "$TMP/log" | head -1))"
fi
printf 'struct Pt {\n  int y;\n  int x;\n}\n' > "$CKDIR/types/pt.id"
if ../bin/idc "$CKDIR" --allow-untested --emit-c /dev/null >"$TMP/log" 2>&1; then
    bad "bin/idc: reordering a struct's fields re-runs a field check (built; it should not have)"
elif grep -qF "main.id:14: test failed: pt_move(1) then (import pt).y = 1, expected 2" "$TMP/log"; then
    ok "bin/idc: reordering a struct's fields re-runs a field check"
else
    bad "bin/idc: reordering a struct's fields re-runs a field check ($(grep -v warning "$TMP/log" | head -1))"
fi

# A setup's own arguments are read before the call, so they may name an export
# the function under test declares: that is how a case shows that a second run
# starts from scratch. An expected value is read after the call and may not.
cat > "$TMP/p.id" <<'EOF'
bump(int[] t) {
  t[1] = 9;
} return void;

mk(int n) {
  export int[] st = [n, 0];
} return void;
given mk(1) given bump((import st)) (2):()
given mk(1) given bump((import st)) (3):()
EOF
self_accept "bin/idc: a setup's argument may name an export the function under test declares" --allow-untested --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
mk(int k) {
  int[] b = [k];
  export int[] box = b;
} return int[] b;
(5):([5])
given prep (1):((import box))

prep() {
  mk(1);
} return void;
EOF
self_accept "bin/idc: an expected value may be an export the function under test declares when the arguments hold no import" --allow-untested --emit-c /dev/null
# A variable the function under test declares may be checked against a literal,
# or against another value the call computed. Two imports in one case are held
# apart only in a function's first two cases (the core cases), and then only
# when the function under test declares the export and nothing in the call
# writes it afterwards; a return clause `} return void export NAME;` exempts it.
# function exists to initialize it, which its return clause says.
cat > "$TMP/p.id" <<'EOF'
mk() {
  export int[] box = [0, 0];
  box[1] = 5;
} return void;
given mk ():() then (import box)[1]:(5)
given mk ():() then (import box):([0, 5])
EOF
self_accept "bin/idc: a variable the call writes after declaring it may be read back" --allow-untested --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
init_tab() {
  export int[] tab = [0, 0, 7];
} return void;
given init_tab ():() then (import tab)[2]:(7)
given init_tab ():() then len((import tab)):(3)
EOF
self_accept "bin/idc: a variable the call only declares may be checked against a literal" --allow-untested --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
mk(int k) {
  export int ba = 1;
  export int bb = 2;
  int r = k + 1;
} return int r;
(1):(2)
(5):(6)
given prep ((import ba)):((import bb))

prep() {
  mk(1);
} return void;
EOF
self_accept "bin/idc: an export the function declares may be compared with another export in a case after the first two" --allow-untested --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
mk(int k) {
  export int ba = 1;
  export int bb = 2;
  int r = k + 1;
} return int r;
(1):(2)
given prep ((import ba)):((import bb))
(5):(6)

prep() {
  mk(1);
} return void;
EOF
self_refuse "bin/idc: ... but not in one of the first two cases, its core cases" \
    "the first two cases of a function are its core cases and may not compare one import against another" --allow-untested --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
mk(int k) {
  export int ba = 1;
  export int bb = 2;
  int r = k + 1;
} return int r;
given prep ((import ba)):(2)
given prep (0):((import ba))

prep() {
  mk(1);
} return void;
EOF
self_accept "bin/idc: an import on one side of a core case is allowed" --allow-untested --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
init_tab() {
  export int[] tab = [0, 0, 7];
} return void export tab;
given init_tab ():() then (import tab)[2]:(7) then len((import tab)):(3)
given init_tab ():() then (import tab):([0, 0, 7])
EOF
self_accept "bin/idc: a function that returns void export NAME may check NAME in every form" --allow-untested --emit-c /dev/null

sed -i 's/then (import tab):(\[0, 0, 7\])/then (import tab):([0, 0, 8])/' "$TMP/p.id"
self_refuse "bin/idc: ... and the check holds the export to its value" \
    "p.id:5: test failed: init_tab() then (import tab) = [0, 0, 7], expected [0, 0, 8]" --allow-untested --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
init_tab() {
  export int[] tab = [0, 0, 7];
} return void export tab;

use(int k) {
  init_tab();
  int u = k + 1;
} return int u;
(1):(2) then (import tab)[2]:(7)
(2):(3) then len((import tab)):(3)
EOF
self_accept "bin/idc: the cases of a caller may check NAME against a literal" --allow-untested --emit-c /dev/null


# A conf.id constant may stand in a check's index: it says where to look, and
# the value compared with stays a literal. Nothing but the case line names it,
# so a changed constant must change the case's cache key or the old pass is
# reused.
IXDIR="$TMP/ixdir"; mkdir -p "$IXDIR"
printf 'int slot = 1;\n' > "$IXDIR/conf.id"
cat > "$IXDIR/main.id" <<'EOF2'
mk() {
  export int[] cnt = [0, 5];
} return void;

bump(int k) {
  int[] c = (import cnt);
  c[k] = c[k] + 1;
} return void;

wrap(int k) {
  bump(k);
  bump(k);
} return void;
given mk (0):() then (import cnt)[(import slot)]:(5)
given mk (1):() then (import cnt)[(import slot)]:(7)
EOF2
cat > "$IXDIR/run.id" <<'EOF2'
main(int argc, string[] argv) {
} return int 0;
EOF2
if ../bin/idc "$IXDIR" --allow-untested --emit-c /dev/null >"$TMP/log" 2>&1; then
    ok "bin/idc: a conf.id constant names a check's index"
else
    bad "bin/idc: a conf.id constant names a check's index ($(grep -v warning "$TMP/log" | head -1))"
fi
printf 'int slot = 0;\n' > "$IXDIR/conf.id"
if ../bin/idc "$IXDIR" --allow-untested --emit-c /dev/null >"$TMP/log" 2>&1; then
    bad "bin/idc: a changed index constant re-runs the case (built; it should not have)"
elif grep -qF "main.id:14: test failed: wrap(0) then (import cnt)[(import slot)] = 2, expected 5" "$TMP/log"; then
    ok "bin/idc: a changed index constant re-runs the case"
else
    bad "bin/idc: a changed index constant re-runs the case ($(grep -v warning "$TMP/log" | head -1))"
fi

# A conf.id constant may be an argument of a given setup and of a check, and a
# check may be called with one element of an exported list: all three are read
# after the call, so a changed constant must change the case's cache key.
ARGDIR="$TMP/argdir"; mkdir -p "$ARGDIR"
printf 'int slot = 1;\n' > "$ARGDIR/conf.id"
cat > "$ARGDIR/main.id" <<'EOF2'
mk(int s) {
  export int[] cnt = [0, 0];
  int[] c = (import cnt);
  c[s] = 5;
} return void;

pick(int v) {
  int w = v + 1;
} return int w;
(1):(2)
(2):(3)

wrap(int k) {
  int[] c = (import cnt);
  c[k] = c[k] + 1;
} return void;
given mk((import slot)) (0):() then pick((import cnt)[1]):(6)
given mk((import slot)) (1):() then pick((import cnt)[(import slot)]):(7)
given mk(0) (1):() then pick((import slot)):(2)
EOF2
cat > "$ARGDIR/run.id" <<'EOF2'
main(int argc, string[] argv) {
} return int 0;
EOF2
if ../bin/idc "$ARGDIR" --allow-untested --emit-c /dev/null >"$TMP/log" 2>&1; then
    ok "bin/idc: a constant in a setup or check, and an indexed export in a check, are accepted"
else
    bad "bin/idc: a constant in a setup or check, and an indexed export in a check, are accepted ($(grep -v warning "$TMP/log" | head -1))"
fi
printf 'int slot = 0;\n' > "$ARGDIR/conf.id"
if ../bin/idc "$ARGDIR" --allow-untested --emit-c /dev/null >"$TMP/log" 2>&1; then
    bad "bin/idc: a changed setup or check constant re-runs the case (built; it should not have)"
elif grep -qF "main.id:17: test failed: wrap(0) then pick((import cnt)[1]) = 1, expected 6" "$TMP/log" \
    && grep -qF "main.id:19: test failed: wrap(1) then pick((import slot)) = 1, expected 2" "$TMP/log"; then
    ok "bin/idc: a changed setup or check constant re-runs the case"
else
    bad "bin/idc: a changed setup or check constant re-runs the case ($(grep -v warning "$TMP/log" | head -1))"
fi
cat > "$TMP/p.id" <<'EOF'
mk() {
  export int[] cnt = [0, 5];
} return void;

wrap(int k) {
  int a = k + 1;
} return void;
(0):() then (import cnt)[0]:(0)
(1):() then (import cnt)[1]:(5)
EOF
self_refuse "bin/idc: then (import NAME) without a given is rejected" \
    "p.id:8: error: (import cnt) needs a 'given'" --allow-untested --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
mk() {
  export int[] cnt = [0, 5];
} return void;

other() {
  export int[] away = [1];
} return void;

wrap(int k) {
  int a = k + 1;
} return void;
given mk (0):() then (import away):([1])
given mk (1):() then (import away)[0]:(1)
EOF
self_refuse "bin/idc: then (import NAME) of an export the setup does not reach is rejected" \
    "p.id:13: error: (import away): 'away' is exported by 'other', which the setup 'mk' does not reach" --allow-untested --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
mk() {
  export int total = 4;
} return void;

wrap(int k) {
  int a = k + 1;
} return void;
given mk (0):() then (import total)[0]:(4)
given mk (1):() then (import total):("4")
EOF
self_refuse "bin/idc: an index on an export that is not a list is rejected, naming the fix" \
    "p.id:8: error: (import total)[...] reads one element, but 'total' is a int, not a list; drop the index, or name a list export" --allow-untested --emit-c /dev/null

self_refuse "bin/idc: then (import NAME) holds its value to the export's type" \
    "p.id:9: error: this case gives a string where a int is required" --allow-untested --emit-c /dev/null

# The larger case's setup does 20000 iterations and the smaller's none, so
# this claim holds only if a setup's work is not counted as the call's.
cat > "$TMP/p.id" <<'EOF'
small() {
  export int[] ss = [0];
} return void;

big() {
  int[] bs = [];
  int i = 0;
  while(i < 20000) {
    push(bs, i);
    i = i + 1;
  }
} return void;

inc(int a) {
  int b = a + 1;
} return int b;
given small (1):(2)[time:O(1)]
given big (100):(101)[time:O(1)]
EOF
self_accept "bin/idc: a setup's work is not counted against a constraint" --allow-untested --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
f(int a) {
  int b = a + 1;
} return void;
given f (1):(2)
(0):(1)
EOF
self_refuse "bin/idc: a bare given of a setup that takes parameters is rejected" \
    "p.id:4: error: 'given' names 'f', which takes 1 parameter(s), but this 'given' passes 0" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
f(int a) {
  int b = a + 1;
} return int b;
given nope (1):(2)
(0):(1)
EOF
self_refuse "bin/idc: a setup that does not exist is rejected" \
    "p.id:4: error: 'given' names 'nope', which is not a function in this build" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
st() {
  export int g = 1;
} return void;

f(int a) {
  int b = a + 1;
} return int b;
given st (1):(2) then st:(1)
(0):(1)
EOF
self_refuse "bin/idc: a check that returns void is rejected" \
    "p.id:8: error: 'then' names 'st', which returns void; a check returns the value it compares" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
st() {
  export int g = 1;
} return void;

f(int a) {
  int b = a + 1;
} return int b;
((import g)):(2)
(0):(1)
EOF
self_refuse "bin/idc: (import NAME) without a setup is rejected" \
    "p.id:8: error: (import g) needs a 'given': an export has no value in a case until a setup has run" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
st() {
  export int g = 1;
} return void;

other() {
  export int h = 2;
} return void;

f(int a) {
  int b = a + 1;
} return int b;
given st ((import h)):(3)
(0):(1)
EOF
self_refuse "bin/idc: (import NAME) of an export the setup does not reach is rejected" \
    "p.id:12: error: (import h): 'h' is exported by 'other', which the setup 'st' does not reach, so nothing sets it before the call" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
st() {
  export int g = 1;
  helper();
} return void;

helper() {
  export int hg = 3;
} return void;

f(int a) {
  int b = a + 1;
} return int b;
given st ((import hg)):(4)
given st ((import g)):(2)
EOF
self_accept "bin/idc: (import NAME) of an export made by a function the setup calls" --allow-untested --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
st() {
  export int[] xs = [1];
} return void;

f(int a) {
  int b = a + 1;
} return int b;
given st ((import xs)):(2)
(0):(1)
EOF
self_refuse "bin/idc: (import NAME) of the wrong type is rejected" \
    "p.id:8: error: this case gives (import xs), a int[], where a int is required" --emit-c /dev/null

# The duplicate rule compares the whole case, then clauses included.
cat > "$TMP/p.id" <<'EOF'
st() {
  export int[] n = [0];
} return void;

same(int a) {
  int b = a;
} return int b;
given st (1):(1) then cnt:(0)
given st (1):(1)

cnt() {
  int v = (import n)[0];
} return int v;
EOF
self_accept "bin/idc: two cases differing only in a then clause are not duplicates" --allow-untested --emit-c /dev/null

cat > "$TMP/q.id" <<'EOF'
st() {
  export int[] n = [0];
} return void;

same(int a) {
  int b = a;
} return int b;
given st (1):(1)
(1):(1)
EOF
if ../bin/idc "$TMP/q.id" --allow-untested --emit-c /dev/null >"$TMP/log" 2>&1; then
    ok "bin/idc: two cases differing only in a given are not duplicates"
else
    bad "bin/idc: two cases differing only in a given are not duplicates ($(head -1 "$TMP/log"))"
fi

sed -i 's/^given st (1):(1)$/given st (1):(1) then cnt:(0)/' "$TMP/p.id"
self_refuse "bin/idc: two cases identical then clauses included are duplicates" \
    "p.id:9: error: this test case is identical to an earlier one" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
f(int a) {
  int given = a;
} return int a;
(1):(1)
(2):(2)
EOF
self_refuse "bin/idc: given is not a variable name" \
    "p.id:2: error: 'given' is a test case keyword (see docs/TESTS.md) and cannot be used as a name" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
f(int then) {
  int b = len("a");
} return int b;
(1):(1)
(2):(1)
EOF
self_refuse "bin/idc: then is not a parameter name" \
    "p.id:1: error: 'then' is a test case keyword (see docs/TESTS.md) and cannot be used as a name" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
f(int stdin) {
  int b = len("a");
} return int b;
(1):(1)
(2):(1)
EOF
self_refuse "bin/idc: stdin is not a parameter name" \
    "p.id:1: error: 'stdin' is a test case keyword (see docs/TESTS.md) and cannot be used as a name" --emit-c /dev/null

# --- a case's stdin clause, and the default when it has none -----------------
# read_all() reads the real stdin of the case's own process (docs/TESTS.md):
# a `stdin "TEXT"` clause makes that TEXT, and a case with none sees an empty
# stdin rather than the harness's own -- never the terminal, never a leftover
# from an earlier case.
cat > "$TMP/p.id" <<'EOF'
grab() {
  string s = read_all();
  print(s);
} return void;
stdin "hi\n" ():() then prints:("hi\n\n")
():() then prints:("\n")
EOF
self_accept "bin/idc: a case's stdin clause is what read_all() sees, and a case without one sees empty stdin" --emit-c /dev/null
}

tf_chunk_2() {
# --- a case's timeout clause: its own limit in place of the default 30 -------
# Short limits stand in for the real thing (no case may run near 30s here):
# `timeout 1` on a case that spins for about 3s must be stopped at ITS limit,
# and the report names that limit; `timeout 5` on the same case passes. The
# default is IDTC_SECONDS 30 in the harness text (back/tgt/c/emit/prog/test/
# unit/more/text/proc.id), which a case in that file's own cases checks.
cat > "$TMP/p.id" <<'EOF'
spin(int ms) {
  int t0 = ticks();
  int t = t0;
  while(t - t0 < ms) {
    t = ticks();
  }
} return int ms;
timeout 1 (3000):(3000)
(0):(0)
EOF
self_refuse "bin/idc: a case's timeout stops it at its own limit and the report names it" \
    "spin(3000) did not finish within 1 seconds" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
spin(int ms) {
  int t0 = ticks();
  int t = t0;
  while(t - t0 < ms) {
    t = ticks();
  }
} return int ms;
timeout 5 (3000):(3000)
(0):(0)
EOF
self_accept "bin/idc: a case that needs more than a second passes under a larger timeout" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
f(int timeout) {
  int b = len("a");
} return int b;
(1):(1)
(2):(1)
EOF
self_refuse "bin/idc: timeout is not a parameter name" \
    "p.id:1: error: 'timeout' is a test case keyword (see docs/TESTS.md) and cannot be used as a name" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
grab() {
  string s = read_all();
  print(s);
} return void;
stdin "hi\n" timeout 20 ():() then prints:("hi\n\n")
():() then prints:("\n")
EOF
self_accept "bin/idc: timeout follows stdin and precedes the arguments" --emit-c /dev/null
# A native's func(...) parameter is a C function pointer (docs/INTEROP.md): a plain
# function crosses as one, and a closure (docs/SPEC.md 1.1.1) has none to give, so
# passing one is the trap that names the fix, on both targets that link C.
NF="$TMP/natfn"
mkdir -p "$NF/nf"
cat > "$NF/nf/backend.id" <<'EOF'
string name = "nf";
string c_header = "nf.h";

string[] c_linux_sources = ["nf.c"];
string[] c_linux_cflags = [];
string[] c_linux_link = [];
string[] c_darwin_sources = ["nf.c"];
string[] c_darwin_cflags = [];
string[] c_darwin_link = [];
EOF
cat > "$NF/nf/nf.h" <<'EOF'
#ifndef ID_NF_H
#define ID_NF_H
extern int id_nf_call(int (*f)(int), int x);
#endif
EOF
cat > "$NF/nf/nf.c" <<'EOF'
#include "nf.h"
int id_nf_call(int (*f)(int), int x) { return f(x) + 1; }
EOF
cat > "$NF/nf/decl.id" <<'EOF'
native nf_call(func(int) return int f, int x) return int;
EOF
cat > "$NF/entry.id" <<'EOF'
inc(int n) {
  int r = n + 1;
} return int r;

add_to(int n, int x) {
  int r = n + x;
} return int r;

main(int argc, string[] argv) {
  func(int) return int p = inc;
  int a = nf_call(p, 10);
  print(a);
} chain (int argc, string[] argv) {
  if (argc > 1) {
    func(int) return int c = bind(add_to, 5);
    print(nf_call(c, 1));
  }
} return int 0;
EOF
for tgt in c llvm; do
    if ../bin/idc "$NF" --target "$tgt" --allow-untested -o "$TMP/natfn.$tgt" >"$TMP/log" 2>&1; then
        got=$("$TMP/natfn.$tgt" 2>&1 | tr '\n' ' ')
        if [ "$got" = "12 " ]; then ok "natives: a plain function crosses to C as a function pointer ($tgt)"; else bad "natives: a plain function crosses to C as a function pointer ($tgt: got '$got')"; fi
        err=$("$TMP/natfn.$tgt" x 2>&1 >/dev/null)
        if printf '%s' "$err" | grep -qF "a closure cannot be passed to a native"; then ok "natives: a closure passed to a native traps with the fix named ($tgt)"; else bad "natives: a closure passed to a native traps with the fix named ($tgt: got '$err')"; fi
    else
        bad "natives: the function-pointer fixture builds ($tgt: $(head -1 "$TMP/log"))"
    fi
done
}

tf_chunk_3() {
# --- (import NAME) inside a list literal of a case -----------------------------
# An element of a list in ARGS or EXPECTED may be (import NAME), nested lists
# included: read after the setup on the argument side and after the call on the
# expected side, exactly as a whole argument is.
cat > "$TMP/p.id" <<'EOS'
fx() {
  export int n = 7;
} return void;
():()
():() then prints:("")

pair(int[] xs) {
  int a = len(xs);
} return int[] xs;
given fx ([1, (import n)]):([1, (import n)])
given fx ([(import n), 2]):([7, 2])

nest(int[][] ys) {
  int a = len(ys);
} return int[][] ys;
given fx ([[1], [(import n)]]):([[1], [7]])
given fx ([[1], [(import n)]]):([[1], [(import n)]])
EOS
self_accept "bin/idc: (import NAME) is an element of a list, nested or not, in arguments and expected values" --emit-c /dev/null

sed -i 's/:(\[7, 2\])/:([8, 2])/' "$TMP/p.id"
self_refuse "bin/idc: an (import NAME) inside an argument list holds the export's value" \
    "p.id:11: test failed: pair([(import n), 2]) = [7, 2], expected [8, 2]" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOS'
fx() {
  export int n = 7;
} return void;
():()
():() then prints:("")

pair(int[] xs) {
  int a = len(xs);
} return int[] xs;
([1, (import n)]):([1, 7])
([2]):([2])
EOS
self_refuse "bin/idc: (import NAME) inside a list still needs a given" \
    "p.id:10: error: (import n) needs a 'given': an export has no value in a case until a setup has run" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOS'
fx() {
  export string path = "x.db";
} return void;
():()
():() then prints:("")

main(int argc, string[] argv) {
  print(argv[1]);
} return int 0;
given fx (2, ["prog", (import path)]):(0) then prints:("x.db\n")
given fx (3, ["prog", (import path), "z"]):(0) then prints:("x.db\n")
EOS
self_accept "bin/idc: main's argv may carry an exported value" --emit-c /dev/null

# --- parameterised setups: given NAME(LIT, ...) --------------------------------
cat > "$TMP/p.id" <<'EOS'
mk() {
  export int[] buf = [0, 0];
} return void;
():()
():() then prints:("")

bump(int[] b, int k, int v) {
  b[k] = v + 1;
} return void;
([0, 0], 1, 7):([0, 8], 1, 7)
([0, 0], 0, 1):([2, 0], 0, 1)

use(int[] xs) {
  int a = len(xs);
} return int[] xs;
given mk given bump((import buf), 1, 7) ((import buf)):([0, 8])
given mk given bump((import buf), 0, 4) given bump((import buf), 1, 6) ((import buf)):([5, 7])
EOS
self_accept "bin/idc: a setup is called with literals and with an export an earlier setup set" --emit-c /dev/null

sed -i 's/:(\[0, 8\])$/:([0, 9])/' "$TMP/p.id"
self_refuse "bin/idc: a setup's arguments reach it (its effect is what the case sees)" \
    "p.id:16: test failed: use((import buf)) = [0, 8], expected [0, 9]" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOS'
mk() {
  export int[] buf = [0, 0];
} return void;
():()
():() then prints:("")

bump(int[] b, int k, int v) {
  b[k] = v + 1;
} return void;
([0, 0], 1, 7):([0, 8], 1, 7)
([0, 0], 0, 1):([2, 0], 0, 1)

use(int[] xs) {
  int a = len(xs);
} return int[] xs;
given bump((import buf), 1, 7) given mk ((import buf)):([0, 8])
([1]):([1])
EOS
self_refuse "bin/idc: a setup's own arguments cannot read an export only a later setup sets" \
    "p.id:16: error: (import buf) needs a 'given': an export has no value in a case until a setup has run; a setup's own arguments are read before it runs" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOS'
fill(int n) {
  int[] bs = [];
  int i = 0;
  while(i < n) {
    push(bs, i);
    i = i + 1;
  }
} return void;
(3):(3)
(4):(4)

inc(int a) {
  int b = a + 1;
} return int b;
given fill(20000) (100):(101)[time:O(1)]
given fill(20000)(200):(201)[time:O(1)]
EOS
self_accept "bin/idc: a parameterised setup's work is not counted against a constraint, and its spacing decides nothing" --allow-untested --emit-c /dev/null

# --- parameterised checks: then NAME(LIT, ...):(VALUE) -------------------------
cat > "$TMP/p.id" <<'EOS'
mk() {
  export int[] buf = [0, 0];
} return void;
():()
():() then prints:("")

bump(int[] b, int k, int v) {
  b[k] = v + 1;
} return void;
([0, 0], 1, 7):([0, 8], 1, 7)
([0, 0], 0, 1):([2, 0], 0, 1)

elem(int[] b, int k) {
  int v = b[k];
} return int v;
([4, 5], 1):(5)
([4, 5], 0):(4)
given mk given bump((import buf), 0, 4) ((import buf), 1):(0) then elem((import buf), 0):(5) then elem((import buf), 1):(0)
given mk given bump((import buf), 1, 6) ((import buf), 1):(7) then elem((import buf), 1):(7) then elem([9, 8], 1):(8)
EOS
self_accept "bin/idc: a check is called with literals and with an export the call left, in the order written" --emit-c /dev/null
self_accept "bin/idc: a parameterised check is run on the llvm target too" --emit-llvm /dev/null

sed -i 's/then elem((import buf), 0):(5)/then elem((import buf), 0):(6)/' "$TMP/p.id"
self_refuse "bin/idc: a failing parameterised check shows the call with its arguments" \
    "p.id:18: test failed: elem((import buf), 1) then elem((import buf), 0) = 5, expected 6" --emit-c /dev/null

sed -i 's/then elem((import buf), 0):(6)/then elem((import buf), 0, 1):(5)/' "$TMP/p.id"
self_refuse "bin/idc: a check passed more literals than it has parameters is refused" \
    "'then' names 'elem', which takes 2 parameter(s), but this 'then' passes 3" --emit-c /dev/null

sed -i 's/then elem((import buf), 0, 1):(5)/then elem((import buf)):(5)/' "$TMP/p.id"
self_refuse "bin/idc: a check passed fewer literals than it has parameters is refused" \
    "'then' names 'elem', which takes 2 parameter(s), but this 'then' passes 1" --emit-c /dev/null

sed -i 's/then elem((import buf)):(5)/then elem((import buf), "x"):(5)/' "$TMP/p.id"
self_refuse "bin/idc: a check's literal is held to the parameter's type" \
    "p.id:18: error: this case gives a string where a int is required" --emit-c /dev/null

sed -i 's/then elem((import buf), "x"):(5)/then elem((import buf), bump):(5)/' "$TMP/p.id"
self_refuse "bin/idc: a check's literal may not be a function's name" \
    "a check's arguments are literals or (import NAME); 'bump' is a function name" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOS'
mk() {
  export int[] buf = [0, 0];
} return void;
():()
():() then prints:("")

bump(int[] b, int k, int v) {
  b[k] = v + 1;
} return void;
([0, 0], 1, 7):([0, 8], 1, 7)
([0, 0], 0, 1):([2, 0], 0, 1)

elem(int[] b, int k) {
  int v = b[k];
} return int v;
([4, 5], 1):(5)
([4, 5], 0):(4)
given bump((import buf), 0, 4) ((import buf), 1):(0) then elem((import buf), 0):(5)
EOS
self_refuse "bin/idc: a check's (import NAME) needs a 'given' that sets it, as an expected value does" \
    "needs a 'given': an export has no value in a case until a setup has run" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOS'
mk() {
  export int[] buf = [5, 6];
} return void;
():()
():() then prints:("")

first() {
  int n = (import buf)[0];
} return int n;
given mk ():(5)
given mk ():(5) then prints:("")

inc(int a) {
  int b = a + 1;
} return int b;
given mk (1):(2) then first():(5)
given mk (2):(3) then first:(5)
EOS
self_accept "bin/idc: then NAME():(VALUE) is a check with no parameters, as then NAME:(VALUE) is" --emit-c /dev/null
sed -i 's/then first():(5)/then first():(6)/' "$TMP/p.id"
self_refuse "bin/idc: a check written with empty parentheses fails like one written without" \
    "p.id:16: test failed: inc(1) then first() = 5, expected 6" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOS'
cell(int[] xs, int i) {
  int v = xs[i];
} return int v;
([4, 5], 1):(5)
([4, 5], 0):(4)
EOS
self_refuse "bin/idc: E0408 refuses a one-operation function nothing names as a fixture" \
    "[E0408]" --emit-c /dev/null
cat >> "$TMP/p.id" <<'EOS'

use(int n) {
  int m = n + 1;
} return int m;
(1):(2) then cell([4, 5], 0):(4)
(2):(3) then cell([4, 5], 1):(5)
EOS
self_accept "bin/idc: a function named in then NAME(LIT, ...) is a fixture, exempt from E0408" --emit-c /dev/null

# --- a build whose cases cannot run here says why ----------------------------
cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a * 2 + b;
} return int s;
(1, 2):(4)
(0, 0):(0)
EOF
self_refuse "bin/idc: a build for another platform with cases is refused" \
    "but it is for 'aarch64-unknown-linux-gnu'" --triple aarch64-unknown-linux-gnu --emit-c /dev/null

# --- a --freestanding build runs its cases on the build host -----------------
# The harness is the same source built for the machine doing the build, run
# exactly as a hosted build's is; the object is built only if every case passes.
rm -f "$TMP/fs.o"
self_accept "bin/idc: a --freestanding build with passing cases builds its object" --freestanding -o "$TMP/fs.o"
[ -s "$TMP/fs.o" ] \
    && ok "bin/idc: the --freestanding object exists after its cases passed" \
    || bad "bin/idc: the --freestanding object exists after its cases passed"
cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a * 2 + b;
} return int s;
(1, 2):(5)
(0, 0):(0)
EOF
rm -f "$TMP/fs2.o"
self_refuse "bin/idc: a failing case fails a --freestanding build, naming the case" \
    "p.id:4: test failed: add(1, 2) = 4, expected 5" --freestanding -o "$TMP/fs2.o"
[ ! -e "$TMP/fs2.o" ] \
    && ok "bin/idc: a --freestanding build whose case fails writes no object" \
    || bad "bin/idc: a --freestanding build whose case fails writes no object"

# A function that reaches an asm body the build host has no row for cannot be
# tested there: it is exempt from the two-case minimum, and says so.
mkdir -p "$TMP/fs"
cat > "$TMP/fs/io.id" <<'EOF'
asm "x86_64-unknown-none" in8(word p) {
  "movq %[p], %%rdx"
  "xorq %%rax, %%rax"
  "inb %%dx, %%al"
  "movq %%rax, %[ret]"
} return word ret;

port_byte(word p) {
  word v = in8(p) % 256;
} return word v;

kbd_scan() {
  word sc = port_byte(0x60);
} return word sc;
EOF
cat > "$TMP/fs/add.id" <<'EOF'
add(int a, int b) {
  int s = a * 2 + b;
} return int s;
(1, 2):(4)
(0, 0):(0)
EOF
../bin/idc "$TMP/fs" --freestanding -o "$TMP/fs3.o" >"$TMP/log" 2>&1
fs_rc=$?
[ "$fs_rc" -eq 0 ] && [ -s "$TMP/fs3.o" ] \
    && ok "bin/idc: a --freestanding function reaching a target-only asm builds without cases" \
    || bad "bin/idc: a --freestanding function reaching a target-only asm builds without cases ($(head -1 "$TMP/log"))"
grep -qF "fs/io.id:12: note: function 'kbd_scan' cannot be tested on the build host (" "$TMP/log" \
   && grep -qF "): it calls 'port_byte', which reaches asm 'in8', which has no body for that triple (defined for: x86_64-unknown-none); it is exempt from the two-case minimum" "$TMP/log" \
    && ok "bin/idc: the exemption is a note naming the function and what it reaches" \
    || bad "bin/idc: the exemption is a note naming the function and what it reaches ($(tr '\n' '|' < "$TMP/log"))"
grep -qF "fs/io.id:8: note: function 'port_byte' cannot be tested on the build host (" "$TMP/log" \
   && grep -qF "): it reaches asm 'in8', which has no body for that triple" "$TMP/log" \
    && ok "bin/idc: a direct caller of the asm is exempt too, and says so" \
    || bad "bin/idc: a direct caller of the asm is exempt too, and says so"

cat >> "$TMP/fs/add.id" <<'EOF'

mul(int a, int b) {
  int s = a * b;
} return int s;
EOF
../bin/idc "$TMP/fs" --freestanding -o "$TMP/fs4.o" >"$TMP/log" 2>&1
fs_rc=$?
[ "$fs_rc" -ne 0 ] && grep -qF "function 'mul' has 0 test case(s); --require-tests needs at least 2" "$TMP/log" \
    && ok "bin/idc: a pure function without cases fails the minimum in a --freestanding build" \
    || bad "bin/idc: a pure function without cases fails the minimum in a --freestanding build ($(head -1 "$TMP/log"))"
! grep -qF "function 'kbd_scan' has 0 test case(s)" "$TMP/log" \
   && grep -qF "note: function 'kbd_scan' cannot be tested on the build host" "$TMP/log" \
    && ok "bin/idc: beside it, the exempt function is a note and not a minimum error" \
    || bad "bin/idc: beside it, the exempt function is a note and not a minimum error ($(tr '\n' '|' < "$TMP/log"))"

# The adoption count asks the compiler which functions are exempt rather than
# guessing from the text, so they are not counted short.
../bin/idc "$TMP/fs" --freestanding --list-untested >"$TMP/list" 2>"$TMP/log"
grep -qxF "exempt|$TMP/fs/io.id:12|kbd_scan" "$TMP/list" \
   && grep -qxF "short|$TMP/fs/add.id:7|mul|0" "$TMP/list" \
   && [ "$(wc -l < "$TMP/list")" -eq 3 ] \
    && ok "bin/idc: --list-untested lists the exempt and the short functions" \
    || bad "bin/idc: --list-untested lists the exempt and the short functions ($(tr '\n' '|' < "$TMP/list") $(head -1 "$TMP/log"))"

cat > "$TMP/fs/io.id" <<'EOF'
asm "x86_64-unknown-none" in8(word p) {
  "movq %[p], %%rdx"
  "xorq %%rax, %%rax"
  "inb %%dx, %%al"
  "movq %%rax, %[ret]"
} return word ret;

kbd_scan() {
  word sc = in8(0x60);
} return word sc;
():(0)
():(1)
EOF
rm -f "$TMP/fs/add.id"
../bin/idc "$TMP/fs" --freestanding -o "$TMP/fs5.o" >"$TMP/log" 2>&1
fs_rc=$?
[ "$fs_rc" -ne 0 ] && grep -qF "fs/io.id:11: error: 'kbd_scan' cannot be tested on the build host (" "$TMP/log" \
   && grep -qF "this case would never run, and a function that cannot be tested needs none" "$TMP/log" \
    && ok "bin/idc: cases under a function that cannot be tested on the build host are an error" \
    || bad "bin/idc: cases under a function that cannot be tested on the build host are an error ($(head -1 "$TMP/log"))"

# An asm function with a row for the build host's own triple runs there: the
# harness selects that row, exactly as a hosted build would.
if [ "$(uname -m)-$(uname -s)" = "x86_64-Linux" ]; then
    cat > "$TMP/fs/io.id" <<'EOF'
asm "x86_64-unknown-none" dbl(word a) {
  "mov %[a], %[ret]"
  "add %[ret], %[ret]"
} return word ret;

asm "x86_64-unknown-linux-gnu" dbl(word a) {
  "mov %[a], %[ret]"
  "add %[ret], %[ret]"
} return word ret;

quad(word a) {
  word h = dbl(a);
  word r = dbl(h);
} return word r;
(3):(12)
(0):(1)
EOF
    ../bin/idc "$TMP/fs" --freestanding -o "$TMP/fs6.o" >"$TMP/log" 2>&1
    grep -qF "io.id:16: test failed: quad(0) = 0, expected 1" "$TMP/log" \
        && ok "bin/idc: an asm function with a row for the build host runs in a --freestanding build's harness" \
        || bad "bin/idc: an asm function with a row for the build host runs in a --freestanding build's harness ($(head -1 "$TMP/log"))"
fi

# A hosted build exempts nothing: its harness and its minimum are what they were.
cat > "$TMP/p.id" <<'EOF'
asm "x86_64-unknown-linux-gnu" dbl(word a) {
  "mov %[a], %[ret]"
  "add %[ret], %[ret]"
} return word ret;

twice(word a) {
  word r = dbl(a);
} return word r;
EOF
self_refuse "bin/idc: a hosted build does not exempt a function that reaches asm" \
    "function 'twice' has 0 test case(s)" --triple aarch64-unknown-linux-gnu --emit-c /dev/null

# --- duplicate function name should not cascade "declared twice" errors --------
cat > "$TMP/p.id" <<'EOF'
f(int a) {
  int r = a + 1;
} return int r;

f(int a) {
  int r = a * 3;
} return int r;

main(int argc, string[] argv) {
  int y = f(argc);
} return int y;
EOF
if ../bin/idc "$TMP/p.id" >"$TMP/log" 2>&1; then
    bad "bin/idc: duplicate function should be rejected"
else
    if grep -qF "function 'f' already defined" "$TMP/log"; then
        if grep -qF "variable 'a' is declared twice in function 'f'" "$TMP/log"; then
            bad "bin/idc: duplicate function should not cascade 'declared twice' error (got variable cascade)"
        elif grep -qF "variable 'r' is declared twice in function 'f'" "$TMP/log"; then
            bad "bin/idc: duplicate function should not cascade 'declared twice' error (got variable cascade)"
        else
            ok "bin/idc: duplicate function does not cascade 'declared twice' errors"
        fi
    else
        bad "bin/idc: duplicate function should report 'already defined' ($(head -1 "$TMP/log"))"
    fi
fi

# --- genuine redeclaration inside a single function should still report "declared twice" --
cat > "$TMP/p.id" <<'EOF'
f(int a) {
  int x = a;
  int x = 2;
} return int x;
EOF
self_refuse "bin/idc: genuine variable redeclaration reports 'declared twice'" \
    "p.id:3: error: variable 'x' is declared twice in function 'f'" --emit-c /dev/null

# =============================================================================
# A function that only wraps one scalar constant is an error: the constant is
# declared in conf.id and read with (import name). bin/idc only -- idc.py is
# frozen and does not have the rule (tests/invalid/const_wrapper_*.id
# records that it still accepts these). The shapes tests/invalid/ does not
# cover: a value only an operator fold produces, the other scalar types, a
# local reassigned, and the functions that are NOT constants.
cat > "$TMP/p.id" <<'EOF'
neg() {
  int n = 0 - 1;
} return int n;

main(int argc, string[] argv) {
  int c = neg();
  print(c);
} return int 0;
EOF
self_refuse "bin/idc: a wrapper of a negative fold is spelled as the subtraction" \
    "p.id:1: error: 'neg' only returns the constant 0 - 1; declare it in conf.id as 'int neg = 0 - 1;' and read it with (import neg)" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
half() {
} return float 0.5;

main(int argc, string[] argv) {
  float h = half();
  print(h);
} return int 0;
EOF
self_refuse "bin/idc: a float constant wrapper is rejected" \
    "p.id:1: error: 'half' only returns the constant 0.5; declare it in conf.id as 'float half = 0.5;'" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
big() {
} return word 5000000000;

main(int argc, string[] argv) {
  word b = big();
  print(b);
} return int 0;
EOF
self_refuse "bin/idc: a word constant wrapper is rejected" \
    "p.id:1: error: 'big' only returns the constant 5000000000; declare it in conf.id as 'word big = 5000000000;'" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
last() {
  int n = 1;
  n = 2;
} return int n;

main(int argc, string[] argv) {
  int c = last();
  print(c);
} return int 0;
EOF
self_refuse "bin/idc: a wrapper that reassigns its own local is rejected with the final value" \
    "p.id:1: error: 'last' only returns the constant 2;" --emit-c /dev/null

# A scalar constant may be initialised by another, and a list constant's element
# may read one: C needs a constant expression at file scope and LLVM needs a load
# inside @idc_const_init, so each target would otherwise reject a conf.id that
# builds on the other.
CDIR="$TMP/cdir"; mkdir -p "$CDIR"
cat > "$CDIR/conf.id" <<'EOF2'
int base = 7;
int again = (import base);
int[] tbl = [(import base), 2];
EOF2
cat > "$CDIR/main.id" <<'EOF2'
main(int argc, string[] argv) {
  print("" + (import again) + " " + (import tbl)[0] + " " + (import tbl)[1]);
} return int 0;
EOF2
for tgt in c llvm; do
    rm -f "$TMP/cout"
    if ../bin/idc "$CDIR" --allow-untested --target "$tgt" -o "$TMP/cout" >"$TMP/log" 2>&1 && [ "$("$TMP/cout" 2>&1)" = "7 7 2" ]; then
        ok "bin/idc: constants that read constants build and agree, target $tgt"
    else
        bad "bin/idc: constants that read constants build and agree, target $tgt ($(grep -v warning "$TMP/log" | head -1))"
    fi
done

# A list a function builds is not a constant: each call builds a fresh list,
# so one caller's write is invisible to the next call -- a shared conf.id
# global could not behave that way. Run, to show the two lists really are
# distinct. `push` keeps `primes` out of the constant-wrapper rule
# (docs/SPEC.md 7.2): a call anywhere in the body makes it a function, same as
# a scalar-returning wrapper -- unlike `int[] ps = [2, 3, 5]; return int[] ps;`
# on its own, which that rule now rejects (a list has a home in conf.id).
cat > "$TMP/p.id" <<'EOF'
primes() {
  int[] ps = [2, 3, 5];
  push(ps, 7);
} return int[] ps;

bump() {
  int[] a = primes();
  a[0] = 9;
} return int[] a;

main(int argc, string[] argv) {
  int[] a = bump();
  int[] b = primes();
  print("" + a[0] + " " + b[0]);
} return int 0;
EOF
rm -f "$TMP/out"
self_accept "bin/idc: a function returning a list literal is not a constant wrapper" --allow-untested -o "$TMP/out"
[ "$("$TMP/out" 2>&1)" = "9 2" ] \
    && ok "bin/idc: each call of a list-returning function gets its own list" \
    || bad "bin/idc: each call of a list-returning function gets its own list"

cat > "$TMP/p.id" <<'EOF'
twice(int a) {
  int n = a * 2;
} return int n;

main(int argc, string[] argv) {
  int c = twice(argc);
  print(c);
} return int 0;
EOF
self_accept "bin/idc: a result that depends on a parameter is not a constant" --allow-untested --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
width() {
  int n = len("abcd");
} return int n;

main(int argc, string[] argv) {
  int c = width();
  print(c);
} return int 0;
EOF
self_accept "bin/idc: a result computed by a call is not a constant" --allow-untested --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
pick() {
  int n = 1;
  if(ticks() > 0) {
    n = 2;
  }
} return int n;

main(int argc, string[] argv) {
  int c = pick();
  print(c);
} return int 0;
EOF
self_accept "bin/idc: a result chosen by a branch is not a constant" --allow-untested --emit-c /dev/null

# Assigning a parameter is a use of it, and a parameter is not one of the
# function's own locals, so this is outside the rule as written.
cat > "$TMP/p.id" <<'EOF'
reset(int a) {
  a = 5;
} return int a;

main(int argc, string[] argv) {
  int c = reset(argc);
  print(c);
} return int 0;
EOF
self_accept "bin/idc: a function that assigns its parameter is not a constant wrapper" --allow-untested --emit-c /dev/null
}

tf_chunk_4() {
# --- function values (docs/SPEC.md 1.1) --------------------------------------
# bin/idc only: idc.py has no function values. The harness builds and runs a
# tested function that takes one, handed in through an export its setup stores.
cat > "$TMP/p.id" <<'EOF'
dbl(int n) {
  int r = n * 2;
} return int r;
(3):(6)
(0):(0)

st() {
  export func(int) return int g = dbl;
} return void;

apply(func(int) return int f, int x) {
  int r = f(x) * 2;
} return int r;
given st ((import g), 3):(12)
given st ((import g), 5):(20)
EOF
self_accept "bin/idc: a case passes a function value in through (import NAME)" --allow-untested --emit-c /dev/null

sed -i 's/:(20)$/:(21)/' "$TMP/p.id"
self_refuse "bin/idc: a false case that calls through a function value fails the build" \
    "p.id:15: test failed: apply((import g), 5) = 20, expected 21" --allow-untested --emit-c /dev/null

# Two functions that differ only in which function they pass are two
# functions: a function named as a value keeps its name in the fingerprint,
# while a call through a parameter is numbered like any use of it.
mkdir -p "$TMP/fp"
cat > "$TMP/fp/a.id" <<'EOF'
tick(int n) {
  print("tick " + n);
} return void;
(1):(1)
(2):(2)

tock(int n) {
  print("tock " + n * 2);
} return void;
(3):(3)
(4):(4)

run(func(int) return void step, int dt) {
  step(dt);
  step(dt * 2);
} return void;
(tick, 5):(tick, 5)
(tock, 6):(tock, 6)
EOF
cat > "$TMP/fp/b.id" <<'EOF'
pass_tick(int dt) {
  run(tick, dt);
  print("passed " + dt);
} return void;
(7):(7)
(8):(8)

pass_tock(int dt) {
  run(tock, dt);
  print("passed " + dt);
} return void;
(7):(7)
(8):(8)

main(int argc, string[] argv) {
  pass_tick(1);
  pass_tock(2);
} return int 0;
EOF
if ../bin/idc "$TMP/fp" --allow-untested -o "$TMP/fpbin" >"$TMP/log" 2>&1 && [ "$("$TMP/fpbin")" = "$(printf 'tick 1\ntick 2\npassed 1\ntock 4\ntock 8\npassed 2')" ]; then
    ok "bin/idc: functions differing only in the function they pass are distinct"
else
    bad "bin/idc: functions differing only in the function they pass are distinct ($(head -1 "$TMP/log"))"
fi
../bin/idc "$TMP/fp" --fingerprints >"$TMP/log" 2>&1
grep -qF "e:c(run:fv(tick),v0);" "$TMP/log" && grep -qF "{e:c(v0:v1);e:c(v0:b*(v1,I2))}" "$TMP/log" \
    && ok "bin/idc: a fingerprint keeps a function value's name and numbers a call through a parameter" \
    || bad "bin/idc: a fingerprint keeps a function value's name and numbers a call through a parameter"

# A case names a function where a function value goes, as the program would:
# the function's signature must be the parameter's type exactly.
cat > "$TMP/p.id" <<'EOF'
twice(int n) {
  int r = n * 2;
} return int r;
(3):(6)
(0):(0)

apply(func(int) return int f, int x) {
  int r = f(x) * 2;
} return int r;
(twice, 3):(12)
(twice, 5):(20)

apply_into(func(int) return int f, int[] xs) {
  int v = f(xs[0]);
  push(xs, v);
} return void;
(twice, [4]):(twice, [4, 8])
(twice, [0]):(twice, [0, 0])
EOF
self_accept "bin/idc: a case passes a function by name" --emit-c /dev/null

sed -i 's/^(twice, 5):(20)$/(twice, 5):(21)/' "$TMP/p.id"
self_refuse "bin/idc: a false case with a function argument fails the build" \
    "p.id:11: test failed: apply(twice, 5) = 20, expected 21" --emit-c /dev/null

sed -i 's/^(twice, 5):(21)$/(twice, 5):(20)/; s/^(twice, \[0\]):(twice, \[0, 0\])$/(twice, [0]):(twice, [0, 1])/' "$TMP/p.id"
self_refuse "bin/idc: a false case comparing a list after a function argument fails the build" \
    "p.id:18: test failed" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
shout(string s) {
  print(s);
} return void;
("a"):("a")
("b"):("b")

apply(func(int) return int f, int x) {
  int r = f(x) * 2;
} return int r;
(shout, 3):(6)
(nope, 5):(10)
EOF
self_refuse "bin/idc: a case naming a function of the wrong signature is rejected" \
    "p.id:10: error: this case gives 'shout', a func(string) return void, where a func(int) return int is required" --emit-c /dev/null
grep -qF "p.id:11: error: a test case takes literals only (a number, a string, a list of those, or a struct written as P(1, 2)); 'nope' is not a function in this build" "$TMP/log" \
    && ok "bin/idc: a case naming no function is rejected" \
    || bad "bin/idc: a case naming no function is rejected ($(head -1 "$TMP/log"))"

# A case builds a closure where a function value goes, with bind written as a
# function value's name is (docs/TESTS.md): the values are case literals, and the
# function it names is carried by the harness though nothing else calls it.
cat > "$TMP/p.id" <<'EOF'
by_key(int[] keys, int a, int b) {
  int r = keys[a] > keys[b];
} return int r;
([5, 3], 0, 1):(1)
([5, 5], 0, 1):(0)

first(func(int, int) return int gt, int a, int b) {
  int r = a;
  if(gt(a, b) == 1) {
    r = b;
  }
} return int r;
(bind(by_key, [5, 3]), 0, 1):(1)
(bind(by_key, [3, 5]), 0, 1):(0)
EOF
self_accept "bin/idc: a case passes a closure it builds with bind" --emit-c /dev/null

sed -i 's/^(bind(by_key, \[3, 5\]), 0, 1):(0)$/(bind(by_key, [3, 5]), 0, 1):(1)/' "$TMP/p.id"
self_refuse "bin/idc: a false case with a closure argument fails the build" \
    "p.id:14: test failed: first(bind(by_key, [3, 5]), 0, 1) = 0, expected 1" --emit-c /dev/null

sed -i 's/^(bind(by_key, \[3, 5\]), 0, 1):(1)$/(bind(by_key, "x"), 0, 1):(0)/' "$TMP/p.id"
self_refuse "bin/idc: a case's bind holds each value to the parameter it fixes" \
    "p.id:14: error: this case gives \"x\" where a int[] is required" --emit-c /dev/null

sed -i 's/^(bind(by_key, "x"), 0, 1):(0)$/(bind(by_key, [5, 3], 0), 0, 1):(0)/' "$TMP/p.id"
self_refuse "bin/idc: a case's bind must make the function type the position wants" \
    "p.id:14: error: this case builds a func(int) return int with bind(by_key, ...) where a func(int, int) return int is required" --emit-c /dev/null

# --freestanding has no host to run a harness on and builds through LLVM only.
cat > "$TMP/p.id" <<'EOF'
run(func(int) return int step, int dt) {
  int r = step(dt) * 2;
} return int r;

twice(int n) {
  int r = n * 2;
} return int r;

use(int n) {
  int m = n * 3;
  int r = run(twice, m);
} return int r;
EOF
self_accept "bin/idc: a --freestanding object passes and calls a function value" --allow-untested --freestanding -o "$TMP/lib.o"
self_build --allow-untested --freestanding --emit-llvm "$TMP/lib.ll"
grep -qF "call ptr @id_fn_plain(ptr @idfn_a_twice__0, ptr @id_twice)" "$TMP/lib.ll" && grep -qE "call i32 %v[0-9]+\(ptr %v[0-9]+, i32 " "$TMP/lib.ll" \
    && ok "bin/idc: --freestanding LLVM gets the function's object from the runtime and calls the adapter" \
    || bad "bin/idc: --freestanding LLVM gets the function's object from the runtime and calls the adapter"

# --- eprint inside a function under test ---------------------------------------
# A case's stderr is the harness's own channel: the runtime's trap line and the
# mismatch message come back through it, and the harness reports what it read,
# keeping the first 4096 bytes. So a case's eprint goes where its print goes --
# the harness's stdout, which bin/idc discards -- and never into that channel.
# The noise below is longer than 4096 bytes, which in that channel would push
# the trap's own line out of the report.
cat > "$TMP/p.id" <<'EOF'
noisy(int n) {
  int i = 0;
  while(i < 80) {
    eprint("noise from the function under test, which is not part of any report");
    i = i + 1;
  }
  int q = 10 / n;
} return int q;
(5):(2)
(0):(0)
EOF
self_refuse "bin/idc: a trapping case that eprints is reported by its trap" \
    "p.id:10: test failed: noisy(0) trapped: id: division by zero" --emit-c /dev/null
grep -q "noise" "$TMP/log" \
    && bad "bin/idc: a trapping case's eprint stays out of the report ($(grep -c noise "$TMP/log") lines of it)" \
    || ok "bin/idc: a trapping case's eprint stays out of the report"

cat > "$TMP/p.id" <<'EOF'
loud(int n) {
  eprint("loud " + n);
  int m = n + 1;
} return int m;
(1):(2)
(2):(4)
EOF
self_refuse "bin/idc: a mismatching case that eprints is reported by its mismatch" \
    "p.id:6: test failed: loud(2) = 3, expected 4" --emit-c /dev/null
grep -q "loud [12]" "$TMP/log" \
    && bad "bin/idc: a mismatching case's eprint stays out of the report ($(tr '\n' '|' < "$TMP/log"))" \
    || ok "bin/idc: a mismatching case's eprint stays out of the report"

cat > "$TMP/p.id" <<'EOF'
loud(int n) {
  eprint("loud " + n);
  int m = n + 1;
} return int m;
(1):(2)
(2):(3)
EOF
self_accept "bin/idc: cases that eprint and pass build" --emit-c /dev/null
grep -q "loud [12]" "$TMP/log" \
    && bad "bin/idc: passing cases that eprint keep it out of the build's output ($(tr '\n' '|' < "$TMP/log"))" \
    || ok "bin/idc: passing cases that eprint keep it out of the build's output"

# --- return clause narrowing (docs/SPEC.md 1) -----------------------------------
# The return clause narrows exactly as an argument does (tests/invalid/
# narrowing_return_*.id cover the three rejected kinds). Widening the other
# way is unaffected: an int returned as a wider word still builds with no
# local needed to say so.
cat > "$TMP/p.id" <<'EOF'
widen(int n) {
  word w = n;
} return word w;
(5):(5)
(0):(0)
EOF
self_accept "bin/idc: a return clause that widens still builds" --emit-c /dev/null

# --- then prints / then eprints (docs/TESTS.md) -------------------------------
# bin/idc only: idc.py lexes `given`/`then` as ordinary identifiers and neither
# it nor the self-hosted compiler's front end before this feature knew
# `prints`/`eprints`/`calls`.
cat > "$TMP/p.id" <<'EOF'
speak(int n) {
  print("hi " + n);
} return int n;
(1):(1) then prints:("hi 1\n")
(2):(2) then prints:("hi 2\n")
EOF
self_accept "bin/idc: a matching 'prints' clause builds" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
speak(int n) {
  print("hi " + n);
} return int n;
(1):(1) then prints:("bye\n")
(2):(2) then prints:("hi 2\n")
EOF
self_refuse "bin/idc: a mismatching 'prints' clause fails, showing both sides" \
    'p.id:4: test failed: speak(1) prints = "hi 1\n", expected "bye\n"' --emit-c /dev/null

# print()/puts() always ends a line, so a case can ask for that newline
# explicitly -- this is what proves the comparison sees it rather than a
# trimmed line.
cat > "$TMP/p.id" <<'EOF'
line(int n) {
  print("x");
} return int n;
(1):(1) then prints:("x\n")
(2):(2) then prints:("x\n")
EOF
self_accept "bin/idc: 'prints' compares the trailing newline print() always writes" --emit-c /dev/null

# A function that writes nothing is tested the same way: the empty string.
cat > "$TMP/p.id" <<'EOF'
silent(int n) {
  int m = n;
} return int m;
(1):(1) then prints:("")
(2):(2) then prints:("")
EOF
self_accept "bin/idc: 'prints' of an empty string matches a function that prints nothing" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
grumble(int n) {
  eprint("grumble " + n);
} return int n;
(1):(1) then eprints:("grumble 1\n")
(2):(2) then eprints:("grumble 2\n")
EOF
self_accept "bin/idc: a matching 'eprints' clause builds" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
grumble(int n) {
  eprint("grumble " + n);
} return int n;
(1):(1) then eprints:("nope\n")
(2):(2) then eprints:("grumble 2\n")
EOF
self_refuse "bin/idc: a mismatching 'eprints' clause fails, showing both sides" \
    'p.id:4: test failed: grumble(1) eprints = "grumble 1\n", expected "nope\n"' --emit-c /dev/null

# A setup's own output happens before the call under test's counters are read
# and before the channel is captured, so it is never compared -- only the call
# under test's own bytes are.
cat > "$TMP/p.id" <<'EOF'
noisy_setup() {
  print("setup noise");
} return void;

quiet(int n) {
  int m = n;
} return int m;
given noisy_setup (1):(1) then prints:("")
given noisy_setup (2):(2) then prints:("")
EOF
self_accept "bin/idc: a setup's own prints are not counted, only the call under test's" \
    --allow-untested --emit-c /dev/null

# --- then calls NAME:(ARGS) / then calls NAME:[N] (docs/TESTS.md) ------------
cat > "$TMP/p.id" <<'EOF'
helper(int x) {
  int y = x + 1;
} return int y;
(1):(2)
(5):(6)

runner(int n) {
  int h = helper(n * 2);
} return int h;
(1):(3) then calls helper:(2)
(2):(5) then calls helper:(4)
EOF
self_accept "bin/idc: a matching 'calls NAME:(ARGS)' clause builds" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
helper(int x) {
  int y = x + 1;
} return int y;
(1):(2)
(5):(6)

runner(int n) {
  int h = helper(n * 2);
} return int h;
(1):(3) then calls helper:(99)
(2):(5) then calls helper:(4)
EOF
self_refuse "bin/idc: 'calls NAME:(ARGS)' with the wrong arguments fails" \
    "p.id:10: test failed: runner(1) calls helper(99) did not match any of the 1 recorded call(s) to 'helper': helper(2)" \
    --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
helper(int x) {
  int y = x + 1;
} return int y;
(1):(2)
(5):(6)

runner(int n) {
} return int n;
(1):(1) then calls helper:(1)
(2):(2) then calls helper:(2)
EOF
self_refuse "bin/idc: 'calls NAME:(ARGS)' fails when the function is never called" \
    "p.id:9: test failed: runner(1) calls helper(1) did not match any of the 0 recorded call(s) to 'helper'" \
    --emit-c /dev/null

# Two clauses on one case, matched as a subsequence in the order written: the
# second helper(2) must be found AFTER the first helper(1), not before it.
cat > "$TMP/p.id" <<'EOF'
helper(int x) {
  int y = x + 1;
} return int y;
(1):(2)
(5):(6)

runner(int n) {
  int a = helper(n);
  int b = helper(n + 1);
} return int b;
(1):(3) then calls helper:(1) then calls helper:(2)
(2):(4) then calls helper:(2) then calls helper:(3)
EOF
self_accept "bin/idc: several 'calls' clauses are matched in the order written" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
helper(int x) {
  int y = x + 1;
} return int y;
(1):(2)
(5):(6)

runner(int n) {
  int a = helper(n);
  int b = helper(n + 1);
} return int b;
(1):(3) then calls helper:(2) then calls helper:(1)
(2):(4) then calls helper:(3) then calls helper:(2)
EOF
self_refuse "bin/idc: the same two 'calls' clauses out of order do not match" \
    "test failed:" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
helper(int x) {
  int y = x + 1;
} return int y;
(1):(2)
(5):(6)

runner(int n) {
  int a = helper(n);
  int b = helper(n + 1);
} return int b;
(1):(3) then calls helper:[2]
(2):(4) then calls helper:[2]
EOF
self_accept "bin/idc: 'calls NAME:[N]' matches the exact count" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
helper(int x) {
  int y = x + 1;
} return int y;
(1):(2)
(5):(6)

runner(int n) {
  int a = helper(n);
  int b = helper(n + 1);
} return int b;
(1):(3) then calls helper:[3]
(2):(4) then calls helper:[3]
EOF
self_refuse "bin/idc: 'calls NAME:[N]' fails one call short of the count" \
    "p.id:11: test failed: runner(1) calls helper[2], expected 3" --emit-c /dev/null

# A call made two levels down (runner -> mid -> helper) is recorded exactly as
# a direct one is: the harness instruments helper's own body, not runner's
# call site.
cat > "$TMP/p.id" <<'EOF'
helper(int x) {
  int y = x + 1;
} return int y;
(1):(2)
(5):(6)

mid(int x) {
  int y = helper(x * 2);
} return int y;
(1):(3)
(5):(11)

runner(int n) {
  int h = mid(n * 2);
} return int h;
(1):(5) then calls helper:(4)
(2):(9) then calls helper:(8)
EOF
self_accept "bin/idc: a transitive call (two levels down) is recorded" --emit-c /dev/null

# A `given` setup's own call to the target is never recorded either: it runs
# before idtc_rec_on is turned on.
cat > "$TMP/p.id" <<'EOF'
helper(int x) {
  int y = x + 1;
} return int y;
(1):(2)
(5):(6)

warmup() {
  int h = helper(9);
} return void;

runner(int n) {
} return int n;
given warmup (1):(1) then calls helper:[0]
given warmup (2):(2) then calls helper:[0]
EOF
self_accept "bin/idc: a 'given' setup's own calls are not recorded" \
    --allow-untested --emit-c /dev/null

# Recording is bounded (test/unit/more/rec/scan/prelude.id's IDTC_REC_MAX,
# 65536 rows a name). 200 million calls once grew the rows past the case's
# address space and the recorder wrote through realloc's NULL, a segfault;
# every call is still counted, so the count stays exact past the bound.
cat > "$TMP/p.id" <<'EOF'
helper(int x) {
  int y = x + 1;
} return int y;
(1):(2)
(5):(6)

runner(int n) {
  int i = 0;
  int s = 0;
  while(i < n) {
    s = helper(i);
    i = i + 1;
  }
} return int s;
(70000):(70000) then calls helper:[70000]
(200000000):(200000000) then calls helper:[200000000]
EOF
self_accept "bin/idc: 'calls NAME:[N]' stays exact past the recording bound" --emit-c /dev/null

# The last kept row (call 65536, argument 65535) still matches; the first call
# past the bound was counted but its arguments were not kept, so a miss says
# the recording overflowed rather than passing or claiming no such call.
cat > "$TMP/p.id" <<'EOF'
helper(int x) {
  int y = x + 1;
} return int y;
(1):(2)
(5):(6)

runner(int n) {
  int i = 0;
  int s = 0;
  while(i < n) {
    s = helper(i);
    i = i + 1;
  }
} return int s;
(70000):(70000) then calls helper:(65535)
(3):(3) then calls helper:(2)
EOF
self_accept "bin/idc: 'calls NAME:(ARGS)' matches the last row inside the recording bound" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
helper(int x) {
  int y = x + 1;
} return int y;
(1):(2)
(5):(6)

runner(int n) {
  int i = 0;
  int s = 0;
  while(i < n) {
    s = helper(i);
    i = i + 1;
  }
} return int s;
(70000):(70000) then calls helper:(65536)
(3):(3) then calls helper:(2)
EOF
self_refuse "bin/idc: 'calls NAME:(ARGS)' past the recording bound reports the overflow" \
    "p.id:15: test failed: runner(70000) calls helper(65536) did not match any of the 65536 recorded call(s) to 'helper': helper(0), helper(1), helper(2), helper(3), helper(4), ... (65531 more); recording overflowed: 4464 later call(s) were counted but their arguments were not kept (at most 65536 per function)" \
    --emit-c /dev/null

# A miss shows the recorded calls it was compared against, at most five, as
# the clause itself would write them.
cat > "$TMP/p.id" <<'EOF'
helper(int x) {
  int y = x + 1;
} return int y;
(1):(2)
(5):(6)

runner(int n) {
  int i = 0;
  int s = 0;
  while(i < n) {
    s = helper(i);
    i = i + 1;
  }
} return int s;
(8):(8) then calls helper:(99)
(3):(3) then calls helper:(2)
EOF
self_refuse "bin/idc: a 'calls' miss shows at most five recorded calls" \
    "p.id:15: test failed: runner(8) calls helper(99) did not match any of the 8 recorded call(s) to 'helper': helper(0), helper(1), helper(2), helper(3), helper(4), ... (3 more)" --emit-c /dev/null

# A later clause may only match after the previous one's match, so the calls
# before it are listed apart as skipped rather than as candidates.
cat > "$TMP/p.id" <<'EOF'
helper(int x) {
  int y = x + 1;
} return int y;
(1):(2)
(5):(6)

runner(int n) {
  int a = helper(n);
  int b = helper(n + 1);
  int c = helper(n + 2);
} return int c;
(1):(4) then calls helper:(2) then calls helper:(1)
(2):(5) then calls helper:(3) then calls helper:(4)
EOF
self_refuse "bin/idc: a 'calls' miss after an earlier match lists the skipped calls apart" \
    "p.id:12: test failed: runner(1) calls helper(1) did not match any of the 1 recorded call(s) to 'helper' after the previous clause's match: helper(3); 2 earlier call(s) were skipped: helper(1), helper(2)" \
    --emit-c /dev/null

# A list argument is recorded by reference, so it shows (and is compared at)
# the state the case left it in, and the message says so.
cat > "$TMP/p.id" <<'EOF'
helper(int[] xs, int k) {
  int y = k + 1;
} return int y;
([1], 1):(2)
([2], 5):(6)

runner(int n) {
  int[] zs = [0, 0];
  int h = helper(zs, n);
  zs[0] = 7;
} return int h;
(1):(2) then calls helper:([0, 0], 1)
(2):(3) then calls helper:([7, 0], 2)
EOF
self_refuse "bin/idc: a 'calls' miss shows a list argument's final state, and says so" \
    "p.id:12: test failed: runner(1) calls helper([0, 0], 1) did not match any of the 1 recorded call(s) to 'helper': helper([7, 0], 1) (list arguments show their final state)" \
    --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
helper(int[] xs, int k) {
  int y = k + 1;
} return int y;
([1], 1):(2)
([2], 5):(6)

runner(int n) {
  int[] zs = [];
  int i = 0;
  while(i < n) {
    push(zs, i);
    i = i + 1;
  }
} chain (int n) {
  int h = helper(zs, n);
} return int h;
(20):(21) then calls helper:([], 20)
(2):(3) then calls helper:([0, 1], 2)
EOF
self_refuse "bin/idc: a 'calls' miss shows at most 16 elements of a list" \
    "p.id:17: test failed: runner(20) calls helper([], 20) did not match any of the 1 recorded call(s) to 'helper': helper([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, ...], 20) (list arguments show their final state)" \
    --emit-c /dev/null

# --------------------------------------------------------------------------
# Decomposition errors (docs/PROJECT.md, "decomposition errors"): E0406 and
# E0310 fail the build like any other, so a violation is self_refuse. What each
# rule leaves alone is self_unflagged: the build must succeed and the log must
# not name the shape.
self_unflagged() {   # desc, message that must NOT appear, flags...
    local desc="$1" absent="$2"; shift 2
    if self_build "$@" && ! grep -qF "$absent" "$TMP/log"; then
        ok "$desc"
    else
        bad "$desc ($(tr '\n' '|' < "$TMP/log"))"
    fi
}

# E0406: a pure forwarder.
cat > "$TMP/p.id" <<'EOF'
callee(int x) {
  int r = x * 2;
} return int r;

forwarder(int x) {
  int r = callee(x);
} return int r;

main(int argc, string[] argv) {
  int r = forwarder(3);
  print("" + r);
} return int 0;
EOF
self_refuse "bin/idc: a pure forwarder is an error (E0406)" \
    "p.id:5: error: function 'forwarder' only forwards to 'callee' [E0406]" \
    --allow-untested --emit-c /dev/null

# Excluded: main, even when it would otherwise match.
cat > "$TMP/p.id" <<'EOF'
only_main_body(int argc, string[] argv) {
  int r = argc + 1;
} return int r;

main(int argc, string[] argv) {
  int r = only_main_body(argc, argv);
} return int r;
EOF
self_unflagged "bin/idc: 'main' is excluded from the forwarder error" \
    "'main' only forwards" --allow-untested --emit-c /dev/null

# Excluded: a forwarder whose signature differs from its callee's (here, it
# drops a parameter -- real_add's second argument is a literal, not a
# parameter add_one has).
cat > "$TMP/p.id" <<'EOF'
real_add(int x, int y) {
  int r = x * 2 + y;
} return int r;

add_one(int x) {
  int r = real_add(x, 1);
} return int r;

main(int argc, string[] argv) {
  int r = add_one(3);
  print("" + r);
} return int 0;
EOF
self_unflagged "bin/idc: a forwarder that drops a parameter (signature differs) is excluded" \
    "only forwards" --allow-untested --emit-c /dev/null

# Excluded: a forwarder-shaped function whose own name is also used as a
# function value elsewhere -- it may exist to adapt to a func(...) type.
mkdir -p "$TMP/fwdval"
cat > "$TMP/fwdval/callee.id" <<'EOF'
value_target(int x) {
  int r = x * 3;
} return int r;

fwd_used(int x) {
  int r = value_target(x);
} return int r;
EOF
cat > "$TMP/fwdval/apply.id" <<'EOF'
apply_fn(func(int) return int f, int x) {
  int r = f(x) * 2;
} return int r;

main(int argc, string[] argv) {
  int r = apply_fn(fwd_used, 2);
  print("" + r);
} return int 0;
EOF
../bin/idc "$TMP/fwdval" --allow-untested --emit-c /dev/null >"$TMP/log" 2>&1
if [ $? -eq 0 ] && ! grep -qF "'fwd_used' only forwards" "$TMP/log"; then
    ok "bin/idc: a forwarder whose name is used as a function value is excluded"
else
    bad "bin/idc: a forwarder whose name is used as a function value is excluded ($(tr '\n' '|' < "$TMP/log"))"
fi
rm -rf "$TMP/fwdval"

# Two functions that differ only in which imported value they read are one
# function written twice: a compile error that names both and the fix, however
# short they are -- a one-statement accessor per global is the same function
# written once per global. A difference only in a literal is its own error (E0407, below). Every other way of differing -- a second
# import, an operator, more logic -- is quiet: no diagnostic at all, which self_silent
# checks as an empty log.
self_silent() {   # desc, flags...
    local desc="$1"; shift
    if self_build "$@" && [ -z "$(grep -v '^wrote ' "$TMP/log")" ]; then
        ok "$desc"
    else
        bad "$desc ($(tr '\n' '|' < "$TMP/log"))"
    fi
}
cat > "$TMP/p.id" <<'EOF'
use_a(int x) {
  int y = x + (import ia);
  int z = y * 2;
} return int z;

use_b(int x) {
  int y = x + (import ib);
  int z = y * 2;
} return int z;

main(int argc, string[] argv) {
  export int ia = 3;
  export int ib = 4;
  int a = use_a(1);
} chain (int argc, string[] argv) {
  int b = use_b(1);
  print("" + a + " " + b);
} return int 0;
EOF
self_refuse "bin/idc: two functions differing only in an imported value are an error naming both" \
    "p.id:6: error: function 'use_b' and 'use_a' (defined at " --allow-untested --emit-c /dev/null
self_refuse "bin/idc: ...and the error names the two imports" \
    "p.id:1) differ only in the imported value they read ((import ib) in one, (import ia) in the other) [E0405]" \
    --allow-untested --emit-c /dev/null
self_refuse "bin/idc: ...and its help names the fix" \
    "replace the import with a parameter, call that one function from both places, and delete the other" \
    --allow-untested --emit-c /dev/null

# An import AND another difference: not this pair. 3 instead of 2.
cat > "$TMP/p.id" <<'EOF'
use_a(int x) {
  int y = x + (import ia);
  int z = y * 2;
} return int z;

use_b(int x) {
  int y = x + (import ib);
  int z = y * 3;
} return int z;

main(int argc, string[] argv) {
  export int ia = 3;
  export int ib = 4;
  int a = use_a(1);
} chain (int argc, string[] argv) {
  int b = use_b(1);
  print("" + a + " " + b);
} return int 0;
EOF
self_silent "bin/idc: an import plus a literal difference is not reported" --allow-untested --emit-c /dev/null

# Two imports differ: two values to parameterise, not "an imported value".
cat > "$TMP/p.id" <<'EOF'
use_a(int x) {
  int y = x + (import ia) + (import ic);
  int z = y * 2;
} return int z;

use_b(int x) {
  int y = x + (import ib) + (import id);
  int z = y * 2;
} return int z;

main(int argc, string[] argv) {
  export int ia = 3;
  export int ib = 4;
  export int ic = 5;
} chain (int argc, string[] argv) {
  export int id = 6;
  int a = use_a(1);
  int b = use_b(1);
} return int 0;
EOF
self_silent "bin/idc: two imports differing is not reported" --allow-untested --emit-c /dev/null

# A function of one statement is no exception: s1_of and s2_of were once two
# accessors of two globals, and the fix is the same parameter.
cat > "$TMP/p.id" <<'EOF'
get_a() {
  int r = len((import la));
} return int r;

get_b() {
  int r = len((import lb));
} return int r;

main(int argc, string[] argv) {
  export int[] la = [1, 2];
  export int[] lb = [3];
  int n = get_a() + get_b();
} return int n;
EOF
self_refuse "bin/idc: one-statement accessors of two globals are an error naming both" \
    "p.id:5: error: function 'get_b' and 'get_a' (defined at " --allow-untested --emit-c /dev/null

# A literal-only difference is an error (E0407): the logic is the same and the
# values are all that vary, so they are the parameters.
cat > "$TMP/p.id" <<'EOF'
add10(int x) {
  int y = x + 10;
  int z = y * 2;
} return int z;

add16(int x) {
  int y = x + 16;
  int z = y * 2;
} return int z;

main(int argc, string[] argv) {
  int a = add10(3);
  int b = add16(3);
  print("" + a + " " + b);
} return int 0;
EOF
self_refuse "bin/idc: two functions differing only in a literal are an error naming both (E0407)" \
    "function 'add16' differs from 'add10' (defined at " --allow-untested --emit-c /dev/null
self_refuse "bin/idc: ...and its help names the fix" \
    "make each literal that differs a parameter, call that one function from both places passing each place's value, and delete the other" \
    --allow-untested --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
slot_x() {
  int c = character_code_at("abc", 0);
  int r = c + 1;
} return int r;

slot_y() {
  int c = character_code_at("abc", 1);
  int r = c + 1;
} return int r;

main(int argc, string[] argv) {
  int a = slot_x();
  int b = slot_y();
  print("" + a + " " + b);
} return int 0;
EOF
self_refuse "bin/idc: accessors differing only in an index literal are an error (E0407)" \
    "function 'slot_y' differs from 'slot_x' (defined at " --allow-untested --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
greet_a(string name) {
  string s = "hello, " + name;
} return string s;

greet_b(string name) {
  string s = "goodbye, " + name;
} return string s;

main(int argc, string[] argv) {
  string a = greet_a("x");
  string b = greet_b("x");
  print(a + b);
} return int 0;
EOF
self_refuse "bin/idc: a string literal alone is an error too (E0407)" \
    "function 'greet_b' differs from 'greet_a' (defined at " --allow-untested --emit-c /dev/null
self_refuse "bin/idc: ...and when both are one operation on their inputs, its help says to write the expression at each call site (E0407)" \
    'are each one operation on their inputs: write `("goodbye, " + name)` at each call site of' --allow-untested --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
scale_a(float x) {
  float y = x * 1.5;
} return float y;

scale_b(float x) {
  float y = x * 2.5;
} return float y;

main(int argc, string[] argv) {
  float a = scale_a(1.0);
  float b = scale_b(1.0);
  print("" + a + " " + b);
} return int 0;
EOF
self_refuse "bin/idc: a float literal alone is an error too (E0407)" \
    "function 'scale_b' differs from 'scale_a' (defined at " --allow-untested --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
step_a(int x) {
  int y = x + 1;
} return int y;

step_b(int x) {
  int y = x - 1;
} return int y;

main(int argc, string[] argv) {
  int a = step_a(3);
  int b = step_b(3);
  print("" + a + " " + b);
} return int 0;
EOF
self_silent "bin/idc: functions that differ in an operator, not only in a literal, are not reported" --allow-untested --emit-c /dev/null

# Two functions identical in every way, imports included, are the duplicate-logic
# error, and only that one.
cat > "$TMP/p.id" <<'EOF'
same_a(int x) {
  int y = x + (import ia);
  int z = y * 2;
} return int z;

same_b(int x) {
  int y = x + (import ia);
  int z = y * 2;
} return int z;

main(int argc, string[] argv) {
  export int ia = 3;
  int a = same_a(1);
} chain (int argc, string[] argv) {
  int b = same_b(1);
  print("" + a + " " + b);
} return int 0;
EOF
self_refuse "bin/idc: two functions identical but for nothing are the existing duplicate-logic error" \
    "has the same signature and logic as" --allow-untested --emit-c /dev/null
if ! grep -qF "differ only in the imported value" "$TMP/log"; then
    ok "bin/idc: ...not also the import-only error"
else
    bad "bin/idc: ...not also the import-only error ($(tr '\n' '|' < "$TMP/log"))"
fi

# A chain function is one unit of logic, compared whole: two chain functions
# whose last segments happen to match are not duplicates, as two plain functions
# sharing a final statement are not.
cat > "$TMP/p.id" <<'EOF'
fa(int ia, int ib) {
  int x = ia * 3;
  int y = ib;
  int w = ia;
} chain (int ia, int ib) {
  int r = x + y + w;
} return int r;

fb(int ia, int ib) {
  int x = ia - 7;
  int y = ib;
  int w = ia;
} chain (int ia, int ib) {
  int r = x + y + w;
} return int r;

main(int argc, string[] argv) {
  int t = fa(1, 2) + fb(3, 4);
} return int 0;
EOF
self_accept "bin/idc: chain functions sharing only a last segment are not duplicates" --allow-untested --emit-c /dev/null

# E0310: a generated parameter name.
cat > "$TMP/p.id" <<'EOF'
helper(int asset_at_v) {
  int r = asset_at_v + 1;
} return int r;

main(int argc, string[] argv) {
  int r = helper(3);
  print("" + r);
} return int 0;
EOF
self_refuse "bin/idc: a '--fix'-style '_v' parameter name is an error (E0310)" \
    "p.id:1: error: parameter 'asset_at_v' of 'helper' has a generated name [E0310]" \
    --allow-untested --emit-c /dev/null

# Excluded: a generated name on a LOCAL, not a parameter.
cat > "$TMP/p.id" <<'EOF'
helper2(int width) {
  int ret_i = width + 1;
} return int ret_i;

main(int argc, string[] argv) {
  int r = helper2(3);
  print("" + r);
} return int 0;
EOF
self_unflagged "bin/idc: a generated-looking LOCAL name is excluded (parameters only)" \
    "has a generated name" --allow-untested --emit-c /dev/null

# An idstd_-prefixed parameter that looks generated after stripping is not reported.
cat > "$TMP/p.id" <<'EOF'
fill(int idstd_v) {
  int i = 0;
  while(i < idstd_v) {
    i = i + 1;
  }
} return void;
(3):(3)

main(int argc, string[] argv) {
  fill(5);
} return int 0;
EOF
self_unflagged "bin/idc: an idstd_-prefixed parameter is not a generated name (idstd_v)" \
    "has a generated name" --allow-untested --emit-c /dev/null

# A chain's seam marker used to be built with its "return expression" field
# left at 0 rather than -1 (front/parse/decl/func/sig/chain/tail.id), the
# value every other no-expression node in this pass uses (see acc_stmt4,
# mid/names/symbols/check/access/expr/assign.id). 0 is also a real node id --
# whichever node the whole build happens to parse first -- so the access
# check ran that node through acc_expr as if it were the marker's own
# expression. It stayed silent whenever node 0 was harmless, and only
# surfaced as a bogus "'NAME' is a builtin, not a function defined in id"
# once something built earlier in the same source stream put a bare builtin
# reference at node 0 -- which is what `alloc(1)` here does, parsed before
# any node of g's. bin/idc's own driver/idstd build hit this for real: the
# same project fails or builds depending only on whether its absolute path
# sorts before or after idstd's in the one global source-file sort.
cat > "$TMP/p.id" <<'EOF'
f() {
  alloc(1);
} return void;

g(int x) {
  int a1 = x;
  int a2 = a1;
  int a3 = a2;
} chain (int x) {
  int a4 = a3;
} return int a4;
EOF
self_accept "bin/idc: a chain segment after a builtin call elsewhere does not misname 'alloc'" \
    --allow-untested --emit-c /dev/null

# --- structs (docs/SPEC.md 1.2) ------------------------------------------------
# A struct has a file of its own, so these programs are directories.
SD="$TMP/sd"
sd_project() {   # writes the struct and a main into a fresh $SD
    rm -rf "$SD"; mkdir -p "$SD/geo" "$SD/app"
    printf 'struct Box {\n  int[] xs;\n  int n;\n}\n' > "$SD/geo/box.id"
    printf 'struct Point {\n  int x;\n  int y;\n}\n' > "$SD/geo/point.id"
}
sd_build() {   # flags...; the output binary is $SD/out
    ../bin/idc "$SD" -o "$SD/out" "$@" >"$TMP/log" 2>&1
}

# A list a function made, put into a struct by the constructor and by a field
# write, must outlive the function: the analysis does not follow a value into a
# field, so it keeps it (docs/MEMORY.md). Run under the free guard, a list that
# was freed and then read is a trap.
sd_project
cat > "$SD/app/a.id" <<'EOF'
make(int n) {
  int[] xs = [n, n];
  Box b = Box(xs, n);
} return Box b;

refill(Box b) {
  int[] ys = [7, 8];
  b.xs = ys;
} return void;
EOF
cat > "$SD/main.id" <<'EOF'
main(int argc, string[] argv) {
  Box q = make(3);
  print(q.xs[1]);
  refill(q);
} chain (int argc, string[] argv) {
  print(q.xs[1]);
} return int 0;
EOF
if sd_build --allow-untested; then
    got=$(ID_FREE_GUARD=1 "$SD/out" 2>&1 | tr '\n' ' ')
    if [ "$got" = "3 8 " ]; then ok "structs: a list put into a struct is not freed under the guard"; else bad "structs: a list put into a struct is not freed under the guard (got '$got')"; fi
else
    bad "structs: the list-in-struct program builds ($(head -1 "$TMP/log"))"
fi

# A test case writes a struct as its constructor, and a failure shows both sides
# the way they were written.
sd_project
cat > "$SD/app/a.id" <<'EOF'
shift(Point p, int dx) {
  p.x = p.x + dx;
} return void;
(Point(1, 2), 3):(Point(9, 2))
(Point(0, 0), 5):(Point(5, 0))
EOF
printf 'main(int argc, string[] argv) {\n} return int 0;\n' > "$SD/main.id"
if sd_build --allow-untested; then
    bad "structs: a wrong expected struct fails the case (built)"
elif grep -qF "shift(Point(1, 2), 3) = Point(4, 2), expected Point(9, 2)" "$TMP/log"; then
    ok "structs: a failing case shows the structs as written"
else
    bad "structs: a failing case shows the structs as written ($(head -1 "$TMP/log"))"
fi
sed -i 's/Point(9, 2)/Point(4, 2)/' "$SD/app/a.id"
if sd_build --allow-untested; then ok "structs: a case with struct arguments and a struct expected value passes"; else bad "structs: a case with struct arguments and a struct expected value passes ($(head -1 "$TMP/log"))"; fi

# A struct holds only itself in its file, and one in a single file is refused
# with the fix named.
printf 'struct Solo {\n  int a;\n}\n\nmain(int argc, string[] argv) {\n} return int 0;\n' > "$TMP/p.id"
self_refuse "structs: a struct beside a function is refused" \
    "a struct is declared in a file of its own" --allow-untested

# A list a native returns is built by C with malloc. push and the end-of-life
# free used to treat it as an arena block and segfault (exit 139); every call to
# a list-returning native now copies the result into a list the runtime owns, on
# the C target (a macro over the prototype) and the LLVM target (a call after the
# call). A malformed result traps with the fix named.
NL="$TMP/natlist"
mkdir -p "$NL/nb"
cat > "$NL/nb/backend.id" <<'EOF'
string name = "nb";
string c_header = "nb.h";

string[] c_linux_sources = ["nb.c"];
string[] c_linux_cflags = [];
string[] c_linux_link = [];
string[] c_darwin_sources = ["nb.c"];
string[] c_darwin_cflags = [];
string[] c_darwin_link = [];
EOF
cat > "$NL/nb/nb.h" <<'EOF'
#ifndef ID_NB_H
#define ID_NB_H
typedef struct { int len, cap; long long* data; } IdList;
extern IdList* id_nb_three(void);
extern IdList* id_nb_bad(void);
#endif
EOF
cat > "$NL/nb/nb.c" <<'EOF'
#include "nb.h"
#include <stdlib.h>
IdList* id_nb_three(void) {
    IdList* L = malloc(sizeof(IdList));
    L->len = 3; L->cap = 3;
    L->data = malloc(3 * sizeof(long long));
    L->data[0] = 5; L->data[1] = 6; L->data[2] = 7;
    return L;
}
IdList* id_nb_bad(void) {
    IdList* L = malloc(sizeof(IdList));
    L->len = -1; L->cap = 0; L->data = NULL;
    return L;
}
EOF
cat > "$NL/nb/decl.id" <<'EOF'
native nb_three() return int[];

native nb_bad() return int[];
EOF
cat > "$NL/entry.id" <<'EOF'
main(int argc, string[] argv) {
  int[] xs = nb_three();
  print(len(xs));
  print(xs[0]);
} chain (int argc, string[] argv) {
  push(xs, 9);
  push(xs, 10);
  print(len(xs));
} chain (int argc, string[] argv) {
  print(xs[3]);
  int s = xs[0] + xs[1] + xs[2] + xs[3] + xs[4];
  print(s);
} chain (int argc, string[] argv) {
  if (argc > 1) {
    int[] ys = nb_bad();
  }
} return int 0;
EOF
for tgt in c llvm; do
    if ../bin/idc "$NL" --target "$tgt" --allow-untested -o "$TMP/natlist.$tgt" >"$TMP/log" 2>&1; then
        got=$("$TMP/natlist.$tgt" 2>&1 | tr '\n' ' ')
        if [ "$got" = "3 5 5 9 37 " ]; then ok "natives: a list returned from C can be pushed to and read ($tgt)"; else bad "natives: a list returned from C can be pushed to and read ($tgt: got '$got')"; fi
        err=$("$TMP/natlist.$tgt" x 2>&1 >/dev/null)
        if printf '%s' "$err" | grep -qF "a native returned a malformed list"; then ok "natives: a malformed list from C traps with the fix named ($tgt)"; else bad "natives: a malformed list from C traps with the fix named ($tgt: got '$err')"; fi
    else
        bad "natives: the list-returning fixture builds ($tgt: $(head -1 "$TMP/log"))"
    fi
done

# idrun dispatches the runtime helpers the IR calls by a numbered list
# (tools/idrun/conf.id bi_names, fbi_names). A helper the compiler starts to emit
# and that list lacks makes idrun refuse every program that reaches it, so the
# set the LLVM declarations and the IR builder's lw_callf calls can name must be
# inside that list, less these, which the interpreter cannot see: the loop-versioning
# readers exist only at -O>0 (back/ir/build/stmt/flow/loop/ver.id) and idrun runs
# --opt 0; id_list_adopt and id_str_of_cstr wrap what a native returns, and idrun
# has no natives (docs/INTERPRETER.md, milestone 2).
IDR_DECL=../compiler/parse/back/tgt/ll/mod/sect/decl.id
IDR_CONF=../tools/idrun/conf.id
IDR_SKIP=" id_list_cell id_list_cell_set id_list_len_raw id_list_cap_raw id_list_adopt id_str_of_cstr "
{ grep -v '^given ' "$IDR_DECL" | grep -F 'declare ptr @id_list_new()' | grep -o '@id_[a-z0-9_]*' | tr -d '@'; grep -rhoE 'lw_callf\("id_[a-z0-9_]+"' ../compiler/parse/back/ir/build | grep -o 'id_[a-z0-9_]*'; } | sort -u > "$TMP/idr_emit"
grep -E '^string f?bi_names' "$IDR_CONF" | grep -o 'id_[a-z0-9_]*' | sort -u > "$TMP/idr_have"
idr_missing=""
while read -r idr_name; do
    case "$IDR_SKIP" in *" $idr_name "*) continue ;; esac
    grep -qxF "$idr_name" "$TMP/idr_have" || idr_missing="$idr_missing $idr_name"
done < "$TMP/idr_emit"
if [ -s "$TMP/idr_emit" ] && [ -z "$idr_missing" ]; then
    ok "idrun dispatches every runtime helper the IR can call ($(wc -l < "$TMP/idr_emit") emitted, $(wc -l < "$TMP/idr_have") dispatched)"
else
    bad "idrun lacks runtime helpers the IR can call:${idr_missing:- (none found: the emitted set came out empty)}; add each to bi_names and a b_ id in tools/idrun/conf.id and dispatch it in exec/run/bi, or list it in IDR_SKIP with the reason"
fi

# --- the harness declares no libc name a program may use ----------------------
# The harness is one C translation unit with the program's own global
# variables, emitted under their own names, so every libc header it includes
# is a set of names a program cannot use as a global. The teardown's headers
# (<sys/stat.h>, <dirent.h>, <fcntl.h>, <poll.h>) therefore live in
# interop/idtc_teardown.c, an object linked in; c2id's `export int[] fstat`
# stopped building the day they came in. The globals here are the names those
# headers declare; the functions, which are id_-prefixed in C, carry all seven
# names the teardown touches. (kill, mkdtemp and setpgid as globals clash with
# <signal.h>, <stdlib.h> and <unistd.h>, which the harness always included.)
mkdir -p "$TMP/hg" "$TMP/hf"
hn_bodies=("a * 2 + b" "a - b * 2" "a * b + a" "a * a + b" "b * 2 - a" "a + b + b" "(a + b) * b")
hn_wants=(4 -3 3 3 3 5 6)
hn_i=0
for hn_f in fstat poll opendir kill mkdtemp open setpgid; do
    printf '%s\n' "$hn_f(int a, int b) {" "  int s = ${hn_bodies[$hn_i]};" "} return int s;" "(1, 2):(${hn_wants[$hn_i]})" "(0, 0):(0)" > "$TMP/hf/$hn_f.id"
    hn_i=$((hn_i + 1))
done
printf '%s\n' 'main(int argc, string[] argv) {' '  print(fstat(argc, 1));' '} return int 0;' '(1, ["a"]):(0) then prints:("3\n")' '(2, ["a", "b"]):(0) then prints:("5\n")' > "$TMP/hf/main.id"
hn_i=0
for hn_f in fstat poll opendir open; do
    hn_i=$((hn_i + 1))
    printf '%s\n' "sys_$hn_f() {" "  export int[] $hn_f = [];" "} return void export $hn_f;" "():() then len((import $hn_f)):(0)" "given sys_$hn_f ():() then len((import $hn_f)):(0)" > "$TMP/hg/sys_$hn_f.id"
done
printf '%s\n' 'main(int argc, string[] argv) {' '  print(argc);' '} return int 0;' '(1, ["a"]):(0) then prints:("1\n")' '(2, ["a", "b"]):(0) then prints:("2\n")' > "$TMP/hg/main.id"
if ../bin/idc "$TMP/hf" -o "$TMP/hf.bin" >"$TMP/log" 2>&1 && [ "$("$TMP/hf.bin" x)" = "5" ]; then
    ok "functions named fstat, poll, opendir, kill, mkdtemp, open and setpgid build and pass their cases"
else
    bad "functions named like the teardown's libc calls build ($(head -1 "$TMP/log"))"
fi
if ../bin/idc "$TMP/hg" -o "$TMP/hg.bin" >"$TMP/log" 2>&1 && [ "$("$TMP/hg.bin" x)" = "2" ]; then
    ok "globals named fstat, poll, opendir and open build and pass their cases in the harness"
else
    bad "globals named like <sys/stat.h>, <poll.h>, <dirent.h> and <fcntl.h> names build ($(head -1 "$TMP/log"))"
fi
}

case "${1:-all}" in
    all) for k in 0 1 2 3 4; do "tf_chunk_$k"; done ;;
    [0-4]) "tf_chunk_$1" ;;
    *) echo "usage: tests_feature.sh [0-4]   (no argument runs every chunk)" >&2; exit 2 ;;
esac

# --- a first line `#!` is a shebang, read by the lexer and by nothing else ----
# The line is skipped and its newline is not, so a diagnostic below it keeps the
# line number the file shows. Anywhere else a `#!` is an error (tests/invalid/).
SB="$TMP/sb.id"
printf '%s\n' '#!/usr/bin/env idrun' 'add(int a, int b) {' '  int s = a * 2 + b;' '} return int s;' '(1, 2):(4)' '(0, 0):(0)' > "$SB"
printf '%s\n' 'main(int argc, string[] argv) {' '  print(add(argc, 1));' '} return int 0;' '(1, ["a"]):(0) then prints:("3\n")' '(2, ["a", "b"]):(0) then prints:("5\n")' >> "$SB"
if ../bin/idc "$SB" -o "$TMP/sb.bin" >"$TMP/log" 2>&1 && [ "$("$TMP/sb.bin" x)" = "5" ]; then
    ok "a script with a #! first line builds with every rule and runs"
else
    bad "a script with a #! first line builds and runs ($(head -1 "$TMP/log"))"
fi
printf '%s\n' '#!/usr/bin/env idrun' 'main(int argc, string[] argv) {' '  y = 2;' '} return int 0;' > "$SB"
if ../bin/idc "$SB" --allow-untested -o "$TMP/sb.bin" >"$TMP/log" 2>&1; then
    bad "a diagnostic below a #! line (built; it should not have)"
elif grep -qF "sb.id:3: error: undefined variable 'y'" "$TMP/log"; then
    ok "a diagnostic below a #! line keeps its own line number"
else
    bad "a diagnostic below a #! line keeps its own line number ($(head -1 "$TMP/log"))"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
