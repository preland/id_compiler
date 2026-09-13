#!/usr/bin/env bash
# Test clauses: the cases written under a function, run by the compiler.
# See docs/TESTS.md for what they mean; this file checks that idc.py does it
# under --tests, and that bin/idc does it on every build.
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
    ok "bin/idc does not require two cases without the flag"
else
    bad "bin/idc does not require two cases without the flag"
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

# =============================================================================
# bin/idc runs every written case on every build, with no flag and no opt-out.
# A case that does not pass is a compile error, and the build produces nothing.
# Each case runs in a process of its own, so one case stopping -- a trap, a
# crash, a limit -- is reported as that case, and the others still run.
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

cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;
(1, 2):(3)
(0, 0):(0)

main(int argc, string[] argv) {
  int r = add(2, 3);
  print("sum " + r);
} return int 0;
EOF
rm -f "$TMP/out"
self_accept "bin/idc: passing cases build" -o "$TMP/out"
[ "$("$TMP/out" 2>&1)" = "sum 5" ] \
    && ok "bin/idc: a program whose cases pass runs" \
    || bad "bin/idc: a program whose cases pass runs"

cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;
(1, 2):(4)
(0, 0):(0)
(2, 2):(5)

main(int argc, string[] argv) {
  int r = add(2, 3);
  print("sum " + r);
} return int 0;
EOF
rm -f "$TMP/out"
self_refuse "bin/idc: a false case fails the build" \
    "p.id:4: test failed: add(1, 2) = 3, expected 4" -o "$TMP/out"
grep -qF "p.id:6: test failed: add(2, 2) = 4, expected 5" "$TMP/log" \
    && ok "bin/idc: every failing case is reported, not only the first" \
    || bad "bin/idc: every failing case is reported, not only the first"
[ ! -e "$TMP/out" ] \
    && ok "bin/idc: a failing case produces no program" \
    || bad "bin/idc: a failing case produces no program"
rm -f "$TMP/emitted.c"
../bin/idc "$TMP/p.id" --emit-c "$TMP/emitted.c" >/dev/null 2>&1
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
env -u IDC_NO_STD ../bin/idc "$TMP/locp" -o "$TMP/locp.out" > "$TMP/locp.log" 2>&1
grep -qF "locp/lib/dbl.id:5: test failed: dbl(4) = 8, expected 9" "$TMP/locp.log" \
    && ok "bin/idc: a failing case names its own file with the standard library merged in" \
    || bad "bin/idc: a failing case names its own file with the standard library merged in (got: $(head -1 "$TMP/locp.log"))"

# The cases reach the harness and nothing else: the program's C is the same
# with them and without them, and carries no counter.
printf '%s' 'add(int a, int b) {
  int s = a + b;
} return int s;
(1, 2):(3)
(0, 0):(0)
' > "$TMP/p.id"
printf '%s' 'add(int a, int b) {
  int s = a + b;
} return int s;
' > "$TMP/q.id"
../bin/idc "$TMP/p.id" --emit-c "$TMP/with.c" >/dev/null 2>&1
../bin/idc "$TMP/q.id" --emit-c "$TMP/without.c" >/dev/null 2>&1
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

# --- a case that stops on its own is that case failing -----------------------
cat > "$TMP/p.id" <<'EOF'
quot(int a, int b) {
  int q = a / b;
} return int q;
(6, 0):(0)
(6, 3):(2)
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

# Flat-store addresses are the case's own: the second case would be handed a
# later address if the first case's allocation were still live.
cat > "$TMP/p.id" <<'EOF'
first_addr(word n) {
  word a = alloc(n);
} return word a;
(8):(8)
(64):(8)
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
self_accept "bin/idc: a setup's address is passed in, and a check reads it back" --emit-c /dev/null

sed -i 's/((import gb)) then first_byte:(3)$/((import gb)) then first_byte:(4)/' "$TMP/p.id"
self_refuse "bin/idc: a check that does not hold fails the case, naming the check" \
    "p.id:8: test failed: fill3((import gb)) then first_byte() = 3, expected 4" --emit-c /dev/null

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
self_accept "bin/idc: a void function that only writes module state is tested by a check" --emit-c /dev/null

sed -i 's/("x"):("x") then count:(1)/("x"):("x") then count:(2)/' "$TMP/p.id"
self_refuse "bin/idc: ... and a check that does not hold fails it" \
    'p.id:9: test failed: err_report("x") then count() = 1, expected 2' --emit-c /dev/null

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
self_accept "bin/idc: a setup's work is not counted against a constraint" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
f(int a) {
  int b = a + 1;
} return int b;
given f (1):(2)
(0):(1)
EOF
self_refuse "bin/idc: a setup that takes parameters is rejected" \
    "p.id:4: error: 'given' names 'f', which takes 1 parameter(s); a setup takes none and returns void" --emit-c /dev/null

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
    "p.id:8: error: 'then' names 'st', which returns void; a check takes none and returns the value it compares" --emit-c /dev/null

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
self_accept "bin/idc: (import NAME) of an export made by a function the setup calls" --emit-c /dev/null

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
self_accept "bin/idc: two cases differing only in a then clause are not duplicates" --emit-c /dev/null

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
if ../bin/idc "$TMP/q.id" --emit-c /dev/null >"$TMP/log" 2>&1; then
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

# --- a build whose cases cannot run here says why ----------------------------
cat > "$TMP/p.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;
(1, 2):(3)
(0, 0):(0)
EOF
self_refuse "bin/idc: a --freestanding build with cases is refused" \
    "a --freestanding build has no host to run them on" --freestanding --emit-llvm /dev/null
self_refuse "bin/idc: a build for another platform with cases is refused" \
    "but it is for 'aarch64-unknown-linux-gnu'" --triple aarch64-unknown-linux-gnu --emit-c /dev/null

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
# being retired and does not have the rule (tests/invalid/const_wrapper_*.id
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

# A list is not a constant: each call builds a fresh list, so one caller's
# write is invisible to the next call -- a shared conf.id global could not
# behave that way. Run, to show the two lists really are distinct.
cat > "$TMP/p.id" <<'EOF'
primes() {
  int[] ps = [2, 3, 5];
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
self_accept "bin/idc: a function returning a list literal is not a constant wrapper" -o "$TMP/out"
[ "$("$TMP/out" 2>&1)" = "9 2" ] \
    && ok "bin/idc: each call of a list-returning function gets its own list" \
    || bad "bin/idc: each call of a list-returning function gets its own list"

cat > "$TMP/p.id" <<'EOF'
twice(int a) {
  int n = a + a;
} return int n;

main(int argc, string[] argv) {
  int c = twice(argc);
  print(c);
} return int 0;
EOF
self_accept "bin/idc: a result that depends on a parameter is not a constant" --emit-c /dev/null

cat > "$TMP/p.id" <<'EOF'
width() {
  int n = len("abcd");
} return int n;

main(int argc, string[] argv) {
  int c = width();
  print(c);
} return int 0;
EOF
self_accept "bin/idc: a result computed by a call is not a constant" --emit-c /dev/null

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
self_accept "bin/idc: a result chosen by a branch is not a constant" --emit-c /dev/null

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
self_accept "bin/idc: a function that assigns its parameter is not a constant wrapper" --emit-c /dev/null

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
