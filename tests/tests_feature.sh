#!/usr/bin/env bash
# Test clauses: the cases written under a function, run by the compiler.
# See docs/TESTS.md for what they mean; this file checks that idc.py does it.
#
# Every program here is written to $TMP and built with IDC_NO_STD=1, so what a
# case measures is the function under test and nothing else -- a standard
# library merged into the program would put its own functions (and its own
# allocations) into the same harness.
#
# Run from anywhere: tests/tests_feature.sh
set -u
cd "$(dirname "$0")"

# The environment must not leak in: a developer with IDSTD_HOME set would
# otherwise get different results from this file than CI does.
unset IDSTD_HOME
export IDC_NO_STD=1

IDC=../idc.py
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

# The program under test is always $TMP/p.id, written by the heredoc above each
# check; run_idc builds it with whatever flags the check passes.
run_idc() {
    $IDC "$TMP/p.id" "$@" -o "$TMP/out" >"$TMP/log" 2>&1
}
expect_build() {   # desc, flags...
    local desc="$1"; shift
    if run_idc "$@"; then ok "$desc"; else bad "$desc ($(head -1 "$TMP/log"))"; fi
}
expect_reject() {  # desc, expected message (fixed string), flags...
    local desc="$1" want="$2"; shift 2
    if run_idc "$@"; then
        bad "$desc (built; it should not have)"
    elif grep -qF "$want" "$TMP/log"; then
        ok "$desc"
    else
        bad "$desc (wrong message: $(head -1 "$TMP/log"))"
    fi
}

# --- a case that passes -------------------------------------------------------
cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;
(1, 2):(3)
(0, 0):(0)
EOF
expect_build "a passing case builds" --tests

# --- a case that fails is a build failure, naming the case --------------------
cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;
(1, 2):(4)
(0, 0):(0)
EOF
expect_reject "a failing case fails the build" \
    "p.id:4: test failed: add(1, 2) = 3, expected 4" --tests

# --- ... and produces no output at all, --emit-c included ---------------------
rm -f "$TMP/emitted.c"
$IDC "$TMP/p.id" --tests --emit-c "$TMP/emitted.c" >/dev/null 2>&1
[ ! -f "$TMP/emitted.c" ] \
    && ok "a failing case blocks --emit-c too" \
    || bad "a failing case blocks --emit-c too (the C was written anyway)"

# --- cases are inert without --tests -----------------------------------------
expect_build "cases are inert without --tests"
$IDC "$TMP/p.id" --emit-c "$TMP/emitted.c" >/dev/null 2>&1
grep -q "id_ctr_" "$TMP/emitted.c" \
    && bad "no counters in a normal build" \
    || ok "no counters in a normal build"

# --- and they do not change the emitted C ------------------------------------
# The self-hosted compiler is compared against this text byte for byte
# (tools/parity.sh), so a case must be invisible to codegen.
cat > "$TMP/q.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;
EOF
$IDC "$TMP/q.id" --emit-c "$TMP/plain.c" >/dev/null 2>&1
cmp -s "$TMP/emitted.c" "$TMP/plain.c" \
    && ok "cases do not change the emitted C" \
    || bad "cases do not change the emitted C"

# --- --require-tests: 0, 1, and 2 cases --------------------------------------
cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;
EOF
expect_reject "--require-tests rejects a function with no cases" \
    "function 'add' has 0 test case(s)" --require-tests

cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;
(1, 2):(3)
EOF
expect_reject "--require-tests rejects a function with one case" \
    "function 'add' has 1 test case(s)" --require-tests

cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;
(1, 2):(3)
(0, 0):(0)
EOF
expect_build "--require-tests accepts a function with two cases" --require-tests

# --- and the PRIMARY compiler enforces it too --------------------------------
# The rule is only real if bin/idc applies it: idc.py is stage 0 and is being
# retired, so a check that lives only there is a check the language does not
# have. Both compilers must also give the SAME text, as tests/invalid.sh
# requires of every other diagnostic.
self_reject() { # desc, source, expected-substring
    local desc="$1" src="$2" want="$3" out_self out_py rc_self rc_py
    printf '%s' "$src" > "$TMP/p.id"
    out_self=$(../bin/idc "$TMP/p.id" --require-tests --emit-c /dev/null 2>&1); rc_self=$?
    out_py=$($IDC     "$TMP/p.id" --require-tests --emit-c /dev/null 2>&1); rc_py=$?
    if [ "$rc_self" -eq 0 ]; then
        bad "$desc (bin/idc built it; it should not have)"
    elif ! printf '%s' "$out_self" | grep -qF "$want"; then
        bad "$desc (bin/idc wrong message: $(printf '%s' "$out_self" | head -1))"
    elif [ "$out_self" != "$out_py" ]; then
        bad "$desc (compilers disagree: bin/idc='$out_self' idc.py='$out_py')"
    else
        ok "$desc"
    fi
}
self_reject "bin/idc rejects a function with no cases" \
    'add(int a, int b) {
  int s = a + b;
} return int s;
' "function 'add' has 0 test case(s)"
self_reject "bin/idc rejects a function with one case" \
    'add(int a, int b) {
  int s = a + b;
} return int s;
(1, 2):(3)
' "function 'add' has 1 test case(s)"
if ../bin/idc "$TMP/p.id" --emit-c /dev/null >/dev/null 2>&1; then
    ok "bin/idc ignores cases without the flag"
else
    bad "bin/idc ignores cases without the flag"
fi
printf '%s' 'add(int a, int b) {
  int s = a + b;
} return int s;
(1, 2):(3)
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
# voluntarily too. This rule lives only in the self-hosted compiler -- idc.py is
# stage 0 and is being retired, so new rules do not go there.
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
  int s = a + b;
} return int s;
(1, 2):(3)
(0, 0):(0)

mul(int a, int b) {
  int p = a * b;
} return int p;
(1, 2):(2)
(0, 0):(0)
' > "$TMP/p.id"
if ../bin/idc "$TMP/p.id" --require-tests --emit-c /dev/null >/dev/null 2>&1; then
    ok "the same case under two functions is not a duplicate"
else
    bad "the same case under two functions is not a duplicate"
fi

# --- a void function, judged by what it left in its list argument ------------
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
expect_build "a void function is tested through its list argument" --tests

cat > "$TMP/p.id" <<'EOF'
fill(int[] xs, int n) {
  int i = 0;
  while(i < n) {
    push(xs, i);
    i = i + 1;
  }
} return void;
([], 3):([0, 1, 3])
([], 0):([])
EOF
expect_reject "a void function's arguments are compared after the call" \
    "test failed: fill([], 3) = [0, 1, 2], expected [0, 1, 3]" --tests

# --- strings -----------------------------------------------------------------
cat > "$TMP/p.id" <<'EOF'
greet(string who) {
  string s = "hi " + who;
} return string s;
("bob"):("hi bob")
(""):("hi ")
EOF
expect_build "a string case builds" --tests

cat > "$TMP/p.id" <<'EOF'
greet(string who) {
  string s = "hi " + who;
} return string s;
("bob"):("hello bob")
(""):("hi ")
EOF
expect_reject "a string case compares by content" \
    'test failed: greet("bob") = "hi bob", expected "hello bob"' --tests

# --- lists returned ----------------------------------------------------------
cat > "$TMP/p.id" <<'EOF'
grow(int[] xs) {
  push(xs, 9);
} return int[] xs;
([1]):([1, 9])
([]):([9])
EOF
expect_build "a list case builds" --tests

cat > "$TMP/p.id" <<'EOF'
grow(int[] xs) {
  push(xs, 9);
} return int[] xs;
([1]):([1, 8])
([]):([9])
EOF
expect_reject "a list case compares elementwise" \
    "test failed: grow([1]) = [1, 9], expected [1, 8]" --tests

# --- floats ------------------------------------------------------------------
cat > "$TMP/p.id" <<'EOF'
half(float x) {
  float h = x / 2.0;
} return float h;
(3.0):(1.5)
(1.0):(0.5)
EOF
expect_build "a float case builds" --tests

cat > "$TMP/p.id" <<'EOF'
half(float x) {
  float h = x / 2.0;
} return float h;
(3.0):(1.4)
(1.0):(0.5)
EOF
expect_reject "a float case compares by value" \
    "test failed: half(3.0) = 1.5, expected 1.4" --tests

# --- a constraint that holds -------------------------------------------------
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
expect_build "a scaling claim that holds builds" --tests

# --- a constraint that is violated -------------------------------------------
# quad() runs inner() n times and inner() loops n times, so its count grows
# with n^2 while the case claims O(n).
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
expect_reject "a quadratic function cannot claim O(n)" \
    "[time:O(n)] does not hold for 'quad'" --tests

# --- work done inside the runtime is counted too ------------------------------
# The case above has nested loops, so counting only generated code already
# catches it -- which means it does NOT cover the runtime counters, and would
# still pass if they were removed. This one does cover them: build() is a
# SINGLE loop, so by the generated code's own arithmetic it is linear. It is
# quadratic only because each `+` on a string copies everything built so far,
# and that copying happens inside id_concat. If instrumented_runtime() stops
# charging the helpers for the bytes they touch, this is the test that fails.
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
expect_reject "string building in a loop is caught as quadratic" \
    "[time:O(n)] does not hold for 'build'" --tests

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
([1, 2, 3]):(6)
([1, 2, 3, 4, 5, 6]):(21)[time:O(n)]
EOF
expect_reject "a claim carried by one case is rejected" \
    "[time:O(n)] needs a second case with a different input size to compare against" \
    --tests

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
expect_reject "two cases of the same size cannot compare either" \
    "[time:O(n)] needs a second case with a different input size to compare against" \
    --tests

# --- malformed cases ---------------------------------------------------------
cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;
(a, 2):(3)
EOF
expect_reject "a case argument must be a literal" \
    "a test case takes literals only"

cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;
(1, 2)(3)
EOF
expect_reject "a case needs the ':' between its two sides" "expected ':'"

cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;
(1, 2):(3)[time:O(n^3)]
EOF
expect_reject "an unknown bound is named" "unknown bound 'O(n^3)'"

cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;
(1, 2):(3)[cpu:O(n)]
EOF
expect_reject "an unknown constraint is named" "unknown constraint 'cpu'"

cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;
(1):(3)
(0, 0):(0)
EOF
expect_reject "a case with the wrong number of arguments is rejected" \
    "this case passes 1 argument(s) to 'add', which takes 2" --tests

cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;
("x", 2):(3)
(0, 0):(0)
EOF
expect_reject "a case argument of the wrong type is rejected" \
    "this case gives a string where a int is required" --tests

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
