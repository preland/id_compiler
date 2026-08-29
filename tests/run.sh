#!/usr/bin/env bash
# Regression tests for idc. Run from anywhere: tests/run.sh
#
#   tests/run.sh                 everything (85s -- over the 60s budget)
#   tests/run.sh --list          the sections, with their indices
#   tests/run.sh core conform    just those, by name or index
#   tests/run.sh --from 4        section 4 onward
#   tests/run.sh --resume        continue after the last section that passed
#
# Why sections: no test or script should take longer than 60 seconds, because
# a slow suite does not merely cost time -- it changes behaviour, batching work
# and skipping verification. The whole suite is 85s and each SECTION is 6-36s,
# so the budget is met by running it in pieces. --resume records progress after
# each section, so an interrupted run continues rather than starting over.
set -u
cd "$(dirname "$0")"

SECTIONS=(core invalid runtime_invalid self_host_build backends stdlib conform tests_feature idstd_real kernel editor)
STATE=../.idc-cache/run-state
WANTED=()
resume=0

index_of() { local i=0 s; for s in "${SECTIONS[@]}"; do [ "$s" = "$1" ] && { echo "$i"; return 0; }; i=$((i+1)); done; return 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --list)
            i=0; for s in "${SECTIONS[@]}"; do echo "$i  $s"; i=$((i+1)); done; exit 0 ;;
        --from)
            start=$(index_of "${2:?--from needs a section}" 2>/dev/null || echo "$2")
            for j in $(seq "$start" $(( ${#SECTIONS[@]} - 1 )) ); do WANTED+=("${SECTIONS[$j]}"); done
            shift 2 ;;
        --resume)
            resume=1; shift ;;
        -h|--help)
            sed -n '2,12p' "$0"; exit 0 ;;
        *)
            case "$1" in
                [0-9]*) WANTED+=("${SECTIONS[$1]}") ;;
                *)      index_of "$1" >/dev/null || { echo "run.sh: no such section: $1 (see --list)" >&2; exit 2; }
                        WANTED+=("$1") ;;
            esac
            shift ;;
    esac
done

if [ "$resume" -eq 1 ]; then
    done_list=$( [ -f "$STATE" ] && cat "$STATE" || true )
    for s in "${SECTIONS[@]}"; do
        case " $done_list " in *" $s "*) continue ;; esac
        WANTED+=("$s")
    done
    [ "${#WANTED[@]}" -eq 0 ] && { echo "run.sh: every section already passed; rm $STATE to start over"; exit 0; }
    echo "run.sh: resuming with ${WANTED[*]}"
fi

[ "${#WANTED[@]}" -eq 0 ] && WANTED=("${SECTIONS[@]}")
want() { case " ${WANTED[*]} " in *" $1 "*) return 0 ;; esac; return 1; }

# Record a section as passed, so --resume skips it next time. A section that
# fails is deliberately NOT recorded: resuming must retry it.
mark_done() { mkdir -p "$(dirname "$STATE")"; printf '%s ' "$1" >> "$STATE"; }
[ "${#WANTED[@]}" -eq "${#SECTIONS[@]}" ] && rm -f "$STATE"

# Every check below this line predates the standard library, and all of them
# assert on exact diagnostics, exact emitted C, or the demos' own sources. A
# library implicitly merged into each of those programs would change what they
# are, so this file is hermetic: it builds with no stdlib, and the stdlib's own
# behaviour is tested in stdlib.sh against a fixture library instead.
#
# This is not a way of avoiding the question. Porting the demos onto idstd is
# real work that has to happen -- it is C9 in docs/IDSTD.md -- and it cannot
# happen until idstd has the functions to port them onto.
export IDC_NO_STD=1

IDC=../idc.py
BIN_IDC=../bin/idc
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0

# concatenate a project's .id files in the same order idc compiles them
# (every .id in the tree, sorted by full path), for the differential parity
# checks against the id-written compiler.
project_cat() { find "$1" -name '*.id' | LC_ALL=C sort | xargs cat; }

ok()   { pass=$((pass+1)); echo "PASS: $1"; }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; }

expect_output() { # name, expected, actual
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
expect_error() { # name, file, pattern
    if $IDC "$2" -o "$TMP/x" 2>&1 | grep -q "$3"; then ok "$1"; else bad "$1"; fi
}

# The body below is NOT re-indented: wrapping 700 lines in an if would make
# the diff unreadable for a change that only gates them. bash does not care.
if want core; then
# --- hello_world end to end (the demos/hello project bundles otherfn.id, which
#     testfn calls, so the whole program resolves within one project)
$IDC ../demos/hello -o "$TMP/hello" 2>/dev/null \
    || bad "hello_world compiles"
expect_output "usage message"  "usage: $TMP/hello <message>" "$("$TMP/hello")"
expect_output "hello with arg" "hello world: hi"             "$("$TMP/hello" hi)"

# --- demos/ projects compile and run as documented
$IDC ../demos/calc -o "$TMP/calc" 2>/dev/null \
    || bad "calc demo compiles"
expect_output "calc demo output" "total = 42 (positive)" "$("$TMP/calc")"
"$TMP/calc" >/dev/null; expect_output "calc demo exit code" "42" "$?"

$IDC ../demos/control/flow.id -o "$TMP/flow" 2>/dev/null \
    || bad "control demo compiles"
expect_output "control demo output" "7 is a big odd / medium" "$("$TMP/flow")"

# --- adventure demo: input() builtin + cross-file branching to 8 endings.
#     Feed a choice sequence on stdin and check which ending it reaches.
$IDC ../demos/adventure -o "$TMP/adv" 2>/dev/null \
    || bad "adventure demo compiles"
expect_output "adventure path 1,1,1" "ENDING 1" \
    "$(printf '1\n1\n1\n' | "$TMP/adv" | grep -o 'ENDING [0-9]')"
expect_output "adventure path 2,2,2" "ENDING 8" \
    "$(printf '2\n2\n2\n' | "$TMP/adv" | grep -o 'ENDING [0-9]')"
expect_output "adventure path 2,1,2" "ENDING 6" \
    "$(printf '2\n1\n2\n' | "$TMP/adv" | grep -o 'ENDING [0-9]')"
expect_output "adventure invalid choice" ">> You freeze with indecision and your torch gutters out. THE END." \
    "$(printf 'x\n' | "$TMP/adv" | grep '>>')"

# --- while loop + string builtins (len/charat/chr)
cat > "$TMP/scan.id" <<'EOF'
main() {
  string s = "aZ9";
  int i = 0;
  while(i < len(s)) {
    int c = charat(s, i);
    show_char(i, c);
    i = i + 1;
  }
} return int 0;

show_char(int i, int c) {
  string ch = chr(c);
  print(i + ":" + c + ":" + ch);
} return void;
EOF
$IDC "$TMP/scan.id" -o "$TMP/scan" 2>/dev/null || bad "while/len/charat/chr compiles"
expect_output "string builtins walk" "0:97:a 1:90:Z 2:57:9" "$("$TMP/scan" | tr '\n' ' ' | sed 's/ $//')"

# --- growable lists: empty literal, push across a call (reference semantics),
#     len, index get/set, and to_int. seed() fills [0,1,4,9] through a list
#     passed by reference; done() overwrites xs[0] via index-assign + to_int.
cat > "$TMP/listrun.id" <<'EOF'
seed(int[] xs) {
  int i = 0;
  while(i < 4) {
    push(xs, i * i);
    i = i + 1;
  }
} return void;

done(int[] xs) {
  xs[0] = to_int("99");
  int n = len(xs);
  print("len=" + n + " xs[0]=" + xs[0] + " xs[3]=" + xs[3]);
} return void;

main() {
  int[] xs = [];
  seed(xs);
  done(xs);
} return int 0;
EOF
$IDC "$TMP/listrun.id" -o "$TMP/listrun" 2>/dev/null || bad "list runtime compiles"
expect_output "lists push/get/set/to_int" "len=4 xs[0]=99 xs[3]=9" "$("$TMP/listrun")"

# --- idc-in-id: the lexer (written in id) tokenizes id source from stdin
# The compiler is built WITH the standard library -- both stages call idstd's
# lset. IDC_NO_STD is exported at the top of this file for every program it
# builds; the compiler is not one of those programs.
env -u IDC_NO_STD $IDC ../compiler/lex -o "$TMP/idlex" 2>/dev/null || bad "idc-in-id lexer compiles"
expect_output "id-lexer keyword"    "kw while"   "$(printf 'while' | "$TMP/idlex" | head -1)"
expect_output "id-lexer two-char op" "op =="     "$(printf 'x == 2' | "$TMP/idlex" | sed -n 2p)"
expect_output "id-lexer string lit" 'str "hi"'   "$(printf '"hi"'   | "$TMP/idlex" | head -1)"
# `line N` markers carry source positions for diagnostics; they are not
# tokens, and the parser drops them. Filtered here so these assertions stay
# about tokenisation.
expect_output "id-lexer comment skip + eof" "eof" "$(printf '// just a comment\n' | "$TMP/idlex" | grep -v '^line ' | head -1)"
expect_output "id-lexer tracks lines" "line 3" "$(printf 'a\n\nb' | "$TMP/idlex" | sed -n 3p)"

# --- idc-in-id stage 2: the calculator (parser + evaluator + printer written
#     in id), fed by the stage-1 lexer through a pipe
$IDC ../demos/idc_in_id_calc -o "$TMP/idcalc" 2>/dev/null || bad "idc-in-id calc compiles"
expect_output "calc parse+print" "(+ 2 (* 3 4))" \
    "$(echo '2 + 3 * 4' | "$TMP/idlex" | "$TMP/idcalc" | head -1)"
expect_output "calc evaluate" "= 14" \
    "$(echo '2 + 3 * 4' | "$TMP/idlex" | "$TMP/idcalc" | tail -1)"
expect_output "calc precedence/parens/unary/%" "= 13" \
    "$(echo '2 * (3 + 4) - 10 % 3' | "$TMP/idlex" | "$TMP/idcalc" | tail -1)"

# --- idc-in-id stage 2b/3: the function/statement parser + C emitter (written
#     in id), fed by the lexer. `idparse ast` prints the AST as an S-expression;
#     `idparse` (no arg) emits C.
env -u IDC_NO_STD $IDC ../compiler/parse -o "$TMP/idparse" 2>/dev/null || bad "idc-in-id parser compiles"
cat > "$TMP/p_fn.id" <<'EOF'
add(int x, int y) {
  int sum = x + y;
} return int sum;
EOF
expect_output "parser: function/params/decl" \
    "(func add (params (param int x) (param int y)) int (body (decl int sum (+ x y))) (return sum))" \
    "$("$TMP/idlex" < "$TMP/p_fn.id" | "$TMP/idparse" ast)"
cat > "$TMP/p_ctrl.id" <<'EOF'
countdown(int n) {
  while (n > 0) {
    print(n);
    n = n - 1;
  }
} return void;
EOF
expect_output "parser: while/call/void" \
    "(func countdown (params (param int n)) void (body (while (> n 0) (body (expr (call print n)) (assign n (- n 1))))) (return void))" \
    "$("$TMP/idlex" < "$TMP/p_ctrl.id" | "$TMP/idparse" ast)"
cat > "$TMP/p_if.id" <<'EOF'
chk(int x) {
  int r = 0;
  if (x = 0) {
    r = 1;
  }
} return int r;
EOF
expect_output "parser: if/else + bare-= equality" \
    "(func chk (params (param int x)) int (body (decl int r 0) (if (= x 0) (then (assign r 1)) (else))) (return r))" \
    "$("$TMP/idlex" < "$TMP/p_if.id" | "$TMP/idparse" ast)"

# --- stage 3 end to end: id source -> (id lexer) -> (id parser+codegen) -> C,
#     then compiled by cc and run. The whole front+middle is written in id.
cat > "$TMP/g_sq.id" <<'EOF'
square(int n) {
  int r = n * n;
} return int r;

main() {
  int a = square(6);
} return int a;
EOF
"$TMP/idlex" < "$TMP/g_sq.id" | "$TMP/idparse" > "$TMP/g_sq.c"
cc -std=c11 "$TMP/g_sq.c" -o "$TMP/g_sq" 2>/dev/null || bad "emitted C (square) compiles"
"$TMP/g_sq"; expect_output "codegen: square(6) exit code" "36" "$?"
cat > "$TMP/g_sum.id" <<'EOF'
sumto(int n) {
  int s = 0;
  while (n > 0) {
    s = s + n;
    n = n - 1;
  }
} return int s;

main() {
  int t = sumto(5);
} return int t;
EOF
"$TMP/idlex" < "$TMP/g_sum.id" | "$TMP/idparse" > "$TMP/g_sum.c"
cc -std=c11 "$TMP/g_sum.c" -o "$TMP/g_sum" 2>/dev/null || bad "emitted C (sumto) compiles"
"$TMP/g_sum"; expect_output "codegen: sumto(5) exit code" "15" "$?"

# parity: for the supported (scalar) subset, the id-written compiler emits
# byte-identical C to idc.py itself
"$IDC" "$TMP/g_sum.id" --emit-c "$TMP/parity_py.c" >/dev/null 2>&1
"$TMP/idlex" < "$TMP/g_sum.id" | "$TMP/idparse" > "$TMP/parity_id.c"
if diff "$TMP/parity_py.c" "$TMP/parity_id.c" >/dev/null; then
    ok "codegen parity with idc.py (scalar)"
else
    bad "codegen parity with idc.py (scalar)"
fi
# parity with the type pass: print(int) wraps id_str_of_int, string `+` becomes
# id_concat -- exactly as idc.py
cat > "$TMP/g_str.id" <<'EOF'
show(int n) {
  print("n = " + n);
} return void;

main() {
  show(7);
} return int 0;
EOF
"$IDC" "$TMP/g_str.id" --emit-c "$TMP/pstr_py.c" >/dev/null 2>&1
"$TMP/idlex" < "$TMP/g_str.id" | "$TMP/idparse" > "$TMP/pstr_id.c"
if diff "$TMP/pstr_py.c" "$TMP/pstr_id.c" >/dev/null; then
    ok "codegen parity with idc.py (print + string concat)"
else
    bad "codegen parity with idc.py (print + string concat)"
fi
# parity on a real multi-file demo: export/import, string[] params, concat,
# nested if/else, cross-file calls
"$IDC" ../demos/calc --emit-c "$TMP/calc_py.c" >/dev/null 2>&1
project_cat ../demos/calc | "$TMP/idlex" | "$TMP/idparse" > "$TMP/calc_id.c"
if diff "$TMP/calc_py.c" "$TMP/calc_id.c" >/dev/null; then
    ok "codegen parity with idc.py (demos/calc)"
else
    bad "codegen parity with idc.py (demos/calc)"
fi
# parity on the adventure demo: string equality (strcmp), nested if/else,
# input(), concat, void functions across several files
"$IDC" ../demos/adventure --emit-c "$TMP/adv_py.c" >/dev/null 2>&1
project_cat ../demos/adventure | "$TMP/idlex" | "$TMP/idparse" > "$TMP/adv_id.c"
if diff "$TMP/adv_py.c" "$TMP/adv_id.c" >/dev/null; then
    ok "codegen parity with idc.py (demos/adventure)"
else
    bad "codegen parity with idc.py (demos/adventure)"
fi

# parity on `else if`, and on the `else { if }` that looks identical in the
# AST but must emit differently: idc.py splices an else-if chain flat, and
# nests a braced block. The self-hosted parser carries the distinction as a
# flag on the if node, because by the time the else arm is parsed the tokens
# that told them apart are gone.
mkdir -p "$TMP/g_elif"
cat > "$TMP/g_elif/m.id" <<'EOF'
main(int argc, string[] argv) {
  string msg = build_msg();
  print(msg);
} return int 0;

chain(int n) {
  string s = "z";
  if(n == 0) { s = "a"; } else if(n == 1) { s = "b"; }
} return string s;

nested(int n) {
  string s = "-";
  if(n > 5) { s = "big"; } else { s = chain(n); }
} return string s;
EOF
cat > "$TMP/g_elif/more.id" <<'EOF'
build_msg() {
  string a = chain(0) + chain(1) + chain(2);
  string b = nested(0);
  string msg = a + b;
} return string msg;
EOF
"$IDC" "$TMP/g_elif" --emit-c "$TMP/elif_py.c" >/dev/null 2>&1
project_cat "$TMP/g_elif" | "$TMP/idlex" | "$TMP/idparse" > "$TMP/elif_id.c"
if diff "$TMP/elif_py.c" "$TMP/elif_id.c" >/dev/null; then
    ok "codegen parity with idc.py (else if vs else-block)"
else
    bad "codegen parity with idc.py (else if vs else-block)"
fi
# The self-hosted compiler must actually REJECT rule violations, not merely be
# capable of noticing them. Each check family gets a guard here: the hook in
# check_program() is a single shared block with room for three actions, so a
# family can be unhooked by an unrelated edit and go silent with nothing else
# failing. These catch that.
guard_reject() { # name, source, expected-substring
    mkdir -p "$TMP/g_rej"
    printf '%s' "$2" > "$TMP/g_rej/m.id"
    out=$({ printf '#file m.id\n'; cat "$TMP/g_rej/m.id"; } | "$TMP/idlex" | "$TMP/idparse" 2>&1)
    rc=$?
    if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "$3"; then
        ok "self-hosted rejects: $1"
    else
        bad "self-hosted rejects: $1 (rc=$rc, got: $(printf '%s' "$out" | head -1))"
    fi
}
# The other direction: a program the self-hosted compiler must ACCEPT. Only
# worth a helper for rules that used to reject something, where the evidence
# is that the rejection is gone rather than that a message changed.
guard_accept() { # name, source
    mkdir -p "$TMP/g_acc"
    printf '%s' "$2" > "$TMP/g_acc/m.id"
    out=$({ printf '#file m.id\n'; cat "$TMP/g_acc/m.id"; } | "$TMP/idlex" | "$TMP/idparse" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        ok "self-hosted accepts: $1"
    else
        bad "self-hosted accepts: $1 (rc=$rc, got: $(printf '%s' "$out" | head -1))"
    fi
}

# docs/FRICTION.md 8: an array literal's type comes from the slot it is going
# into, never from its first element, so these three are the same literal at
# three types and none of them is an int[] being refused.
guard_accept "a word[] literal" 'main(int argc, string[] argv) {
  word[] xs = [0, 0, 0];
  print(xs[0]);
} return int 0;'
guard_accept "a float[] literal" 'main(int argc, string[] argv) {
  float[] xs = [1.0, 2.0];
  print(xs[0]);
} return int 0;'
guard_accept "a literal of literals" 'main(int argc, string[] argv) {
  int[][] rows = [[1, 2], [3]];
  print(rows[1][0]);
} return int 0;'
guard_reject "a wrong first element" 'main(int argc, string[] argv) {
  int[] xs = ["a", "b"];
  int n = len(xs);
  print(n);
} return int 0;' "element 0 of a int\[\] literal is a string"
guard_reject "a wrong later element" 'main(int argc, string[] argv) {
  word[] xs = [0, "a"];
  int n = len(xs);
  print(n);
} return int 0;' "element 1 of a word\[\] literal is a string"
guard_reject "a literal in a scalar slot" 'main(int argc, string[] argv) {
  int x = [1, 2];
  print(x);
} return int 0;' "cannot initialize int"

# docs/FRICTION.md 12: a declaration may narrow, because it names the type it
# is narrowing to on the line that does it. An argument may not -- the
# parameter's type is in another file.
guard_accept "a declaration that narrows" 'main(int argc, string[] argv) {
  word a = 7;
  int n = a;
  print(n);
} return int 0;'
guard_reject "an argument that narrows" 'main(int argc, string[] argv) {
  word a = 7;
  take(a);
} return int 0;

take(int n) {
  print(n);
} return void;' "narrows word to int"
guard_accept "an argument that widens" 'main(int argc, string[] argv) {
  int n = 7;
  take(n);
} return int 0;

take(word a) {
  print(a);
} return void;'

guard_reject "action limit" 'main(int argc, string[] argv) {
  int a = 1;
  int b = 2;
  int c = 3;
  int d = 4;
} return int 0;' "performs 4 actions"
guard_reject "nesting depth" 'main(int argc, string[] argv) {
  int i = 0;
  while(i < 2) {
    if(i > 0) {
      while(i < 1) {
        i = i + 1;
      }
    }
  }
} return int 0;' "nested too deeply"
guard_reject "one name one type" 'main(int argc, string[] argv) {
  int v = 1;
} return int 0;

other() {
  string v = "x";
} return void;' "must keep one type"
guard_reject "type mismatch" 'main(int argc, string[] argv) {
  int x = "hi";
} return int 0;' "cannot initialize"
guard_reject "asm return type is checked" 'asm "x86_64-unknown-linux-gnu" tk() {
  "mov %%rax, %[ret]"
} return word ret;

main(int argc, string[] argv) {
  string s = tk();
} return int 0;' "cannot initialize string"
guard_reject "duplicate logic" 'main(int argc, string[] argv) {
  int one_v = one(2);
  int two_v = two(3);
  print("" + one_v + two_v);
} return int 0;

one(int a) {
  int r = a + 1;
} return int r;

two(int b) {
  int v = b + 1;
} return int v;' "same signature and logic"
guard_reject "return inside a body" 'main(int argc, string[] argv) {
  return 0;
} return int 0;' "belongs after the function"
guard_reject "missing brace" 'main(int argc, string[] argv)
  int x = 1;
} return int 0;' "expected .{."
guard_reject "missing equals" 'main(int argc, string[] argv) {
  int x 5;
} return int 0;' "expected .=."
guard_reject "unexported access" 'main(int argc, string[] argv) {
  int q = 1;
} return int 0;

other() {
  print("" + q);
} return void;' "belongs to function"

# idview: a random source viewer written in id. It has no filesystem access,
# so it splits a marker-delimited stream back into files -- the same protocol
# the compiler uses for file boundaries.
$IDC ../demos/idview -o "$TMP/idview" >/dev/null 2>&1
view_out=$({ printf '#file a.id\n'; printf 'one\n'; printf '#file b.id\n'; printf 'two\n'; } | "$TMP/idview")
case "$view_out" in
    "==== a.id"*one*) ok "idview picks a file and prints its body" ;;
    "==== b.id"*two*) ok "idview picks a file and prints its body" ;;
    *) bad "idview picks a file and prints its body (got: $(printf '%s' "$view_out" | tr '\n' '|'))" ;;
esac
expect_output "idview on empty input" "idview: no id files on stdin" "$(printf '' | "$TMP/idview")"

# parity on the systems features: word, hex literals, all six bitwise
# operators, the flat store, and the unsigned builtins. These are what the
# kernel port is written in, so the self-hosted stages have to cover them --
# a gap here used to be invisible, because bin/idc would silently fall back to
# idc.py rather than report it.
mkdir -p "$TMP/g_sys"
cat > "$TMP/g_sys/m.id" <<'EOF'
main(int argc, string[] argv) {
  word p = alloc(64);
  poke32(p, 0xdeadbeef);
  show(p);
} return int 0;

show(word p) {
  word v = peek32(p);
  print("" + (v & 0xffff) + (v | 1) + (v ^ 255) + (~v) + (v << 3) + (v >> 2));
  show2(v);
} return void;
EOF
cat > "$TMP/g_sys/more.id" <<'EOF'
show2(word v) {
  string t = "" + udiv(v, 7) + umod(v, 7) + ult(v, 1) + ushr(0 - 16, 60);
  string s = mem_str();
  print(t + s);
} return void;

mem_str() {
  word m = mem_of_str("k");
  string s = str_of_mem(m, 1);
} return string s;
EOF
"$IDC" "$TMP/g_sys" --emit-c "$TMP/sys_py.c" >/dev/null 2>&1
project_cat "$TMP/g_sys" | "$TMP/idlex" | "$TMP/idparse" > "$TMP/sys_id.c"
if diff "$TMP/sys_py.c" "$TMP/sys_id.c" >/dev/null; then
    ok "codegen parity with idc.py (word/bitwise/store)"
else
    bad "codegen parity with idc.py (word/bitwise/store)"
fi
# parity on pop, whose result type is the list's element type and so cannot be
# derived from the callee name alone. The self-hosted emitter used to produce
# a call to a runtime function that does not exist.
mkdir -p "$TMP/g_pop"
cat > "$TMP/g_pop/m.id" <<'EOF'
main(int argc, string[] argv) {
  int[] xs = [1, 2];
  string[] ss = ["a", "b"];
  show_pop(xs, ss);
} return int 0;

show_pop(int[] xs, string[] ss) {
  int px = pop(xs);
  string sy = pop(ss);
  print("" + px + sy);
} return void;
EOF
"$IDC" "$TMP/g_pop" --emit-c "$TMP/pop_py.c" >/dev/null 2>&1
project_cat "$TMP/g_pop" | "$TMP/idlex" | "$TMP/idparse" > "$TMP/pop_id.c"
if diff "$TMP/pop_py.c" "$TMP/pop_id.c" >/dev/null; then
    ok "codegen parity with idc.py (pop element type)"
else
    bad "codegen parity with idc.py (pop element type)"
fi
# the unsigned end of the hex range: 0xffffffffffffffff must lex to
# 18446744073709551615, not -1
mkdir -p "$TMP/g_hex"
cat > "$TMP/g_hex/m.id" <<'EOF'
main(int argc, string[] argv) {
  word a = 0xffffffffffffffff;
  print("" + a + " " + 0x7fffffffffffffff + " " + 0xff);
} return int 0;
EOF
"$IDC" "$TMP/g_hex" --emit-c "$TMP/hex_py.c" >/dev/null 2>&1
project_cat "$TMP/g_hex" | "$TMP/idlex" | "$TMP/idparse" > "$TMP/hex_id.c"
if diff "$TMP/hex_py.c" "$TMP/hex_id.c" >/dev/null; then
    ok "codegen parity with idc.py (wide hex literals)"
else
    bad "codegen parity with idc.py (wide hex literals)"
fi

# --- self-hosting: the id-written compiler emits byte-identical C for its OWN
#     source (lexer + parser/codegen), and the self-compiled compiler is a
#     fixpoint (compiling itself twice reproduces the same C exactly).
#
# The compiler is the one program in this file built WITH the standard library,
# because it uses it: both stages call idstd's `lset`. So these three checks
# unset IDC_NO_STD, and they get their input from `bin/idc --emit-sources`
# rather than from project_cat -- assembling that stream now means resolving
# idstd, ordering its roots and numbering its compilation units, and a test
# that re-implements all that is testing its own copy of it. Skips itself when
# there is no standard library to resolve, because then there is no compiler
# to check.
if env -u IDC_NO_STD "$IDC" ../compiler/lex --emit-c /dev/null >/dev/null 2>&1; then
    for src in lex parse; do
        env -u IDC_NO_STD "$IDC" ../compiler/$src --emit-c "$TMP/${src}_py.c" >/dev/null 2>&1
        env -u IDC_NO_STD ../bin/idc ../compiler/$src --emit-sources 2>/dev/null \
            | "$TMP/idlex" | "$TMP/idparse" > "$TMP/${src}_id.c"
        if diff "$TMP/${src}_py.c" "$TMP/${src}_id.c" >/dev/null; then
            ok "self-hosting parity with idc.py (compiler/$src)"
        else
            bad "self-hosting parity with idc.py (compiler/$src)"
        fi
    done
    # build the self-compiled compiler and check it reproduces its own C
    cc "$TMP/lex_id.c"   -o "$TMP/idlex2"   2>/dev/null || bad "self-compiled lexer builds"
    cc "$TMP/parse_id.c" -o "$TMP/idparse2" 2>/dev/null || bad "self-compiled parser builds"
    env -u IDC_NO_STD ../bin/idc ../compiler/parse --emit-sources 2>/dev/null \
        | "$TMP/idlex2" | "$TMP/idparse2" > "$TMP/idparse_fix.c"
    if diff "$TMP/parse_id.c" "$TMP/idparse_fix.c" >/dev/null; then
        ok "self-hosting fixpoint (self-compiled compiler reproduces itself)"
    else
        bad "self-hosting fixpoint (self-compiled compiler reproduces itself)"
    fi
else
    echo "SKIP: self-hosting checks (no idstd resolvable; the compiler needs it)"
fi

# --- the game engine + the two games it drives build cleanly (real-time I/O
#     builtins put/flush/getkey/sleep_ms/ticks/pop exercised by the games)
if "$IDC" ../demos/moonbuggy -o "$TMP/moonbuggy" 2>/dev/null; then
    ok "moonbuggy builds (with bundled engine)"
else
    bad "moonbuggy builds (with bundled engine)"
fi
if "$IDC" ../demos/solitaire -o "$TMP/solitaire" 2>/dev/null; then
    ok "solitaire builds (with bundled engine)"
else
    bad "solitaire builds (with bundled engine)"
fi

# --- export/import roundtrip at runtime
cat > "$TMP/roundtrip.id" <<'EOF'
main() {
  export int code = 7;
  string msg = describe();
  print(msg);
} return int code;

describe() {
  string s = "";
  if((import code) = 7) {
    s = "lucky " + (import code);
  } else {
    s = "boring";
  }
} return string s;
EOF
$IDC "$TMP/roundtrip.id" -o "$TMP/roundtrip" 2>/dev/null || bad "roundtrip compiles"
expect_output "export/import roundtrip" "lucky 7" "$("$TMP/roundtrip")"
"$TMP/roundtrip" >/dev/null; expect_output "exit code from exported var" "7" "$?"

# --- rule violations must be compile errors
cat > "$TMP/toomany.id" <<'EOF'
main() {
  int a = 1;
  int b = 2;
  int c = 3;
  int d = 4;
} return int 0;
EOF
expect_error "action limit enforced" "$TMP/toomany.id" "performs 4 actions"

cat > "$TMP/fourfns.id" <<'EOF'
f1() {} return void;
f2() {} return void;
f3() {} return void;
f4() {} return void;
EOF
expect_error "3 functions per file" "$TMP/fourfns.id" "too many functions"

# a name may repeat across functions when its type is consistent...
cat > "$TMP/reuse.id" <<'EOF'
inc(int i) { int r = i + 1; } return int r;
dec(int i) { int r = i - 1; } return int r;
main() { int r = inc(10) + dec(10); print("r=" + r); } return int 0;
EOF
$IDC "$TMP/reuse.id" -o "$TMP/reuse" 2>/dev/null || bad "name reuse (same type) compiles"
expect_output "name reuse same type" "r=20" "$("$TMP/reuse")"

# ...but the same name with two different types is an error
cat > "$TMP/typeconflict.id" <<'EOF'
main() { int count = 1; } return int 0;
other() { string count = "hi"; } return void;
EOF
expect_error "name keeps one type" "$TMP/typeconflict.id" "must keep one type"

cat > "$TMP/noconf.id" <<'EOF'
main() { int x = 1; } return int 0;
other() { int y = x; } return void;
EOF
expect_error "cross-function use needs import" "$TMP/noconf.id" "not exported"

cat > "$TMP/badconf.id" <<'EOF'
main() { int x = 1; } return int 0;
other() { int y = (import x); } return void;
EOF
expect_error "import requires export" "$TMP/badconf.id" "is not exported"

# --- systems programming: bitwise operators, hex literals, the `word` machine
# word, and the flat bounds-checked store. These are what let a C-level
# program (a kernel, say) be expressed in id at all; see
# ../linux_id/docs/ID_EXTENSIONS.md for the rationale.
mkdir -p "$TMP/bits"
cat > "$TMP/bits/m.id" <<'EOF'
main(int argc, string[] argv) {
  int x = 0xf0;
  print("" + (x & 0x3c) + " " + (x | 1) + " " + (x ^ 255) + " " + (~x));
  print("" + (x << 2) + " " + (x >> 3) + " " + (0 - 16 >> 2));
} return int 0;
EOF
$IDC "$TMP/bits" -o "$TMP/bits.out" >/dev/null 2>&1
expect_output "bitwise operators + hex literals" "48 241 15 -241
960 30 -4" "$("$TMP/bits.out")"

# `flags & MASK != 0` groups as `(flags & MASK) != 0` -- deliberately unlike C,
# whose precedence here is a well-known source of parenthesis bugs.
mkdir -p "$TMP/prec"
cat > "$TMP/prec/m.id" <<'EOF'
main(int argc, string[] argv) {
  int flags = 6;
  print("" + (flags & 4 != 0));
} return int 0;
EOF
$IDC "$TMP/prec" -o "$TMP/prec.out" >/dev/null 2>&1
expect_output "bitwise binds tighter than comparison" "1" "$("$TMP/prec.out")"

mkdir -p "$TMP/word"
cat > "$TMP/word/m.id" <<'EOF'
main(int argc, string[] argv) {
  word big = 0xffffffffffff;
  show1(big);
  show2(big);
} return int 0;

show1(word big) {
  string line1 = "" + (big >> 32) + " " + ushr(0 - 16, 60) + " " + ult(0 - 1, 1);
  print(line1);
} return void;

show2(word big) {
  string line2 = "" + udiv(0 - 2, 3) + " " + umod(100, 7) + " " + (big & 0xff);
  print(line2);
} return void;
EOF
$IDC "$TMP/word" -o "$TMP/word.out" >/dev/null 2>&1
expect_output "word: 64-bit + unsigned builtins" "65535 15 0
6148914691236517204 2 255" "$("$TMP/word.out")"

# The store is little-endian and untyped: a 32-bit poke is readable as four
# bytes, which is exactly what makes C structs and unions expressible.
mkdir -p "$TMP/store"
cat > "$TMP/store/m.id" <<'EOF'
main(int argc, string[] argv) {
  word p = alloc(64);
  poke32(p, 0x04030201);
  show(p);
} return int 0;

show(word p) {
  poke16(p + 8, 0xbeef);
  string out = full_line(p);
  print(out);
} return void;
EOF
cat > "$TMP/store/more.id" <<'EOF'
full_line(word p) {
  string line1 = "" + peek8(p) + peek8(p + 1) + peek8(p + 2) + peek8(p + 3);
  string line2 = words_line(p);
  string out = line1 + "\n" + line2;
} return string out;

words_line(word p) {
  word m = mem_of_str("hi");
  string s = str_of_mem(m, 2);
  string out = "" + peek16(p + 8) + " " + peek8(p + 8) + " " + s;
} return string out;
EOF
$IDC "$TMP/store" -o "$TMP/store.out" >/dev/null 2>&1
expect_output "flat store: poke/peek, widths, string bridge" "1234
48879 239 hi" "$("$TMP/store.out")"

# A narrower value stored into a word[] must be widened at the point of the
# store: list cells are filled through id_list_lit's varargs and read back as
# `long long`, so without the cast an int element comes back with garbage in
# its top 32 bits. This regressed once; it now has a test.
mkdir -p "$TMP/wbox"
cat > "$TMP/wbox/m.id" <<'EOF'
wzero() {
} return word 0;

main(int argc, string[] argv) {
  word[] xs = [wzero(), 0 - 1];
  print("" + xs[1] + " " + xs[0]);
} return int 0;
EOF
$IDC "$TMP/wbox" -o "$TMP/wbox.out" >/dev/null 2>&1
expect_output "int element widened into a word[]" "-1 0" "$("$TMP/wbox.out")"

# --- alt codegen targets (--target llvm / --target wasm): a handful of
# known-good demos must produce the SAME program output/exit code as the
# default C target. Needs clang (llvm) and wat2wasm + wasmtime (wasm); skip
# with a clear message if the toolchain isn't on PATH (it is inside
# tools/devshell.sh, which is how this script is meant to be run for these
# checks: `tools/devshell.sh bash tests/run.sh`).
echo
echo "--- alt targets (--target llvm / --target wasm) ---"
have_alt=1
for tool in clang wat2wasm wasmtime; do
    command -v "$tool" >/dev/null 2>&1 || have_alt=0
done
if [ "$have_alt" -eq 0 ]; then
    echo "SKIP: alt-target tests (need clang, wat2wasm, and wasmtime on PATH -- " \
         "run via 'tools/devshell.sh bash tests/run.sh')"
else
    # argv[0] differs by target/binary path/name (and wasmtime reports it
    # differently again), so exercise hello with an argument (its output
    # doesn't embed argv[0]) rather than the no-arg "usage" branch.
    # llvm is the self-hosted target (bin/idc); wasm is still idc.py's, and is
    # the last thing holding that file here.
    alt_cc() { # alt_cc TARGET SRC OUT
        if [ "$1" = llvm ]; then "$BIN_IDC" "$2" --target llvm -o "$3" 2>/dev/null
        else "$IDC" "$2" --target "$1" -o "$3" 2>/dev/null; fi
    }
    for target in llvm wasm; do
        if [ "$target" = wasm ]; then
            bin="$TMP/hello_$target.wasm"
        else
            bin="$TMP/hello_$target"
        fi
        if ! alt_cc "$target" ../demos/hello "$bin"; then
            bad "hello builds ($target)"
        else
            if [ "$target" = wasm ]; then out=$(wasmtime "$bin" hi); else out=$("$bin" hi); fi
            expect_output "hello world: hi ($target)" "hello world: hi" "$out"
        fi

        if [ "$target" = wasm ]; then
            bin="$TMP/calc_$target.wasm"
        else
            bin="$TMP/calc_$target"
        fi
        if ! alt_cc "$target" ../demos/calc "$bin"; then
            bad "calc builds ($target)"
        else
            if [ "$target" = wasm ]; then out=$(wasmtime "$bin"); else out=$("$bin"); fi
            rc=$?
            expect_output "calc output ($target)" "total = 42 (positive)" "$out"
            expect_output "calc exit code ($target)" "42" "$rc"
        fi

        if [ "$target" = wasm ]; then
            bin="$TMP/flow_$target.wasm"
        else
            bin="$TMP/flow_$target"
        fi
        if ! alt_cc "$target" ../demos/control/flow.id "$bin"; then
            bad "control builds ($target)"
        else
            if [ "$target" = wasm ]; then out=$(wasmtime "$bin"); else out=$("$bin"); fi
            expect_output "control output ($target)" "7 is a big odd / medium" "$out"
        fi

        # memory safety carries over to the alt targets too: an out-of-bounds
        # list index must abort with the same clear message and nonzero exit
        # as the C target (llvm reuses the C RUNTIME; wasm has its own traps).
        if [ "$target" = wasm ]; then
            bin="$TMP/oob_$target.wasm"
        else
            bin="$TMP/oob_$target"
        fi
        if ! alt_cc "$target" runtime_invalid/list_get_oob.id "$bin"; then
            bad "runtime_invalid/list_get_oob builds ($target)"
        else
            if [ "$target" = wasm ]; then
                err=$(wasmtime "$bin" 2>&1 1>/dev/null); rc=$?
            else
                err=$("$bin" 2>&1 1>/dev/null); rc=$?
            fi
            expect_output "OOB index exit code ($target)" "1" "$rc"
            if printf '%s' "$err" | grep -qF "id: index 5 out of bounds (len 3)"; then
                ok "OOB index abort message ($target)"
            else
                bad "OOB index abort message ($target) (got: $err)"
            fi
        fi
    done
fi

# --- the compiler's own map. 212 of its 258 filenames say nothing about what
#     is in them, so MAP.md is the only way to find code without already
#     knowing a symbol to grep for -- which is why new work kept landing in
#     idc.py instead. An index that goes stale is worse than none, so it is
#     generated and checked. See docs/HACKING.md.
if ../tools/mapgen.sh --check >/dev/null 2>&1; then
    ok "MAP.md is current"
else
    bad "MAP.md is out of date -- run tools/mapgen.sh"
fi

# --- idc.py may not grow. It is stage 0 of a bootstrap being retired
#     (docs/BACKENDS.md), and "language features are not built here" was a
#     sentence in the README for a while before this line existed -- during
#     which idc.py gained 1711 lines. A sentence is not a gate. This is.
#
#     Raised once, by 38, for the string-length memo in RUNTIME: `charat` and
#     `len` remembered one string's length, so a parser alternating between its
#     input and the strings it builds paid a strlen of the whole input per
#     character -- 46.8 seconds for a 3.5 MB document. That is the runtime, not
#     a language feature, and tools/gen_runtime_id.py regenerates the id side
#     from it, so both compilers still emit the same prelude. Six of those
#     lines are in instrumented_runtime, which has to declare the test
#     counters before the helper that now charges them. See docs/FRICTION.md.
#
#     The ceiling ratchets DOWN: port something out, lower the number in the
#     same commit. It never goes up. If a change genuinely has to land here
#     first, that is a decision worth having to write down, which is the point.
# Raised once, from 5285, and the reason is written down because that is the
# whole point of a ratchet: +51 for the conf.id project format, which both
# compilers must agree on and which is genuinely stage-0 work, and +96 for
# check_assigned_once, which is NOT -- it is a semantic check on the AST and
# belongs in mid/, like every other rule. It is here because it was written
# here; moving it is item 3 in docs/TODO.md and the ceiling drops by 96 when
# it lands. The gate did its job: it caught a rule going into the wrong
# compiler, which is exactly the drift it exists to stop.
IDCPY_CEILING=5470
idcpy_lines=$(wc -l < ../idc.py)
if [ "$idcpy_lines" -le "$IDCPY_CEILING" ]; then
    ok "idc.py is $idcpy_lines lines (ceiling $IDCPY_CEILING)"
else
    bad "idc.py grew to $idcpy_lines lines, over its $IDCPY_CEILING ceiling -- build it in the self-hosted compiler, or lower nothing and justify raising it"
fi

# --- every document says whether it describes reality. Three of the ten did;
#     the other seven read as specifications whether they were one or not, and
#     docs/DISPATCH.md -- 113 lines with nothing implemented anywhere -- read
#     exactly like docs/SPEC.md, which is executable. A reader cannot tell a
#     plan from a description without opening the code, so each doc opens with
#     a `> **Status:` line and this refuses a new one that does not.
undocumented=""
for d in ../docs/*.md; do
    grep -q '^> \*\*Status' "$d" || undocumented="$undocumented $(basename "$d")"
done
if [ -z "$undocumented" ]; then
    ok "every doc states whether it describes reality"
else
    bad "no '> **Status:' line in:$undocumented -- say whether the doc is a description, a plan, or a proposal"
fi

# --- and the numbers in a status block are measured, not remembered.
#     docs/TESTS.md said "Cases written so far: 0, of 6816" -- true when
#     written, false four commits later in the same session, and lying about
#     the adoption of the rule it describes. The counts are generated now.
#     Same discipline as MAP.md above, and as ../linux_id/docs/STATUS.md,
#     which is where the idea comes from.
if ../tools/statusgen.sh --check >/dev/null 2>&1; then
    ok "docs/TESTS.md adoption numbers are current"
else
    bad "docs/TESTS.md adoption numbers are stale -- run tools/statusgen.sh"
fi

# --- idc.py obeys a lightweight form of the rules it enforces. A compiler
#     that rejects long blocks, deep nesting and duplicated logic, in a file
#     with a 128-statement function in it, is not a good argument for any of
#     those rules. Relaxed limits (32 statements, depth 4) with a ratcheting
#     budget for what already exceeded them. See tools/lint_idcpy.py.
lint_out=$(cd .. && tools/lint_idcpy.py --check 2>&1)
if [ $? -eq 0 ]; then
    ok "idc.py passes its own lightweight lint"
else
    bad "idc.py lint: $(printf '%s' "$lint_out" | head -1)"
fi

echo
echo "$pass passed, $fail failed"
mark_done core
fi

# --- negative tests: every file in tests/invalid/ must be rejected with the
#     error named on its `// EXPECT:` line.
echo
echo "--- negative tests (tests/invalid/) ---"
neg=0
if want invalid; then
    ./invalid.sh
    neg=$?
    [ "$neg" -eq 0 ] && mark_done invalid
fi

# --- runtime-safety negative tests: every file in tests/runtime_invalid/
#     compiles fine but must ABORT when run (bounds/empty-pop violations),
#     printing the message named on its `// EXPECT:` line to stderr and
#     exiting nonzero. Distinct from tests/invalid/ (compile-time errors).
echo
echo "--- runtime-safety negative tests (tests/runtime_invalid/) ---"
rneg=0
if want runtime_invalid; then
    ./runtime_invalid.sh
    rneg=$?
    [ "$rneg" -eq 0 ] && mark_done runtime_invalid
fi

# --- self-hosted driver (bin/idc): builds several demos through the
#     id-written lexer+parser (via the bin/idc bash driver) and checks the
#     resulting binaries run identically to idc.py's. See tests/self_host_build.sh.
echo
echo "--- self-hosted driver build (bin/idc) ---"
shneg=0
if want self_host_build; then
    ./self_host_build.sh
    shneg=$?
    [ "$shneg" -eq 0 ] && mark_done self_host_build
fi

# --- native backends: both backends compile and coexist in one binary, the
#     graphics demos build at byte parity, and no windowed demo hangs when
#     there is no display. Skips itself when the X11/GL headers are absent.
echo
echo "--- native backends (backends/gfx, backends/gl) ---"
bend=0
if want backends; then
    ./backends.sh
    bend=$?
    [ "$bend" -eq 0 ] && mark_done backends
fi

# --- the standard library: implicit import, --no-std, $IDSTD_HOME, and the
#     transitive dependency resolution it is built on. Runs against a fixture
#     stdlib (tests/fixtures/idstd), so it says the same thing whether or not
#     a real ../idstd exists. It unsets IDC_NO_STD itself.
echo
echo "--- standard library (implicit import) ---"
std=0
if want stdlib; then
    ./stdlib.sh
    std=$?
    [ "$std" -eq 0 ] && mark_done stdlib
fi

# --- conformance: every code-generation target must agree about what a
#     program means. tools/parity.sh compares emitted text, which is only a
#     question while both compilers emit C; this compares behaviour, which is
#     the question that survives a second target. See docs/SPEC.md.
echo
echo "--- conformance across targets (docs/SPEC.md) ---"
conf=0
if want conform; then
    ./conform.sh
    conf=$?
    [ "$conf" -eq 0 ] && mark_done conform
fi

# --- test clauses: the cases written under a function, run by --tests, and the
#     scaling claims they may carry. It sets IDC_NO_STD itself, because what a
#     case measures must be the function under test and nothing else.
echo
echo "--- test clauses (docs/TESTS.md) ---"
tst=0
if want tests_feature; then
    ./tests_feature.sh
    tst=$?
    [ "$tst" -eq 0 ] && mark_done tests_feature
fi

# --- the REAL standard library against the real projects. Everything above
#     this line runs with IDC_NO_STD=1 or against a fixture library, which is
#     what makes it hermetic and what made a whole class of breakage --
#     a project colliding with a name idstd defines -- invisible to the suite.
#     Skips itself when there is no ../idstd. See tests/idstd_expect.txt.
echo
echo "--- the real standard library (tests/idstd_expect.txt) ---"
real=0
if want idstd_real; then
    ./idstd_real.sh
    real=$?
    [ "$real" -eq 0 ] && mark_done idstd_real
fi

# --- the kernel. Last because it is the only section that runs a whole machine,
#     and because everything it exercises has already been checked hosted --
#     what it adds is that none of it needed a C runtime to be true.
echo
echo "--- the kernel (docs/KERNEL.md) ---"
kern=0
if want kernel; then
    ./kernel.sh
    kern=$?
    [ "$kern" -eq 0 ] && mark_done kernel
fi

# --- the document editor. Last with the kernel, because the two of them are
#     what the language was stretched against: everything above this line is
#     the compiler checking itself, and these two are it being used.
echo
echo "--- the document editor (docs/EDITOR.md) ---"
edit=0
if want editor; then
    ./editor.sh
    edit=$?
    [ "$edit" -eq 0 ] && mark_done editor
fi

[ "$fail" -eq 0 ] && [ "$neg" -eq 0 ] && [ "$rneg" -eq 0 ] && [ "$shneg" -eq 0 ] \
    && [ "$bend" -eq 0 ] && [ "$std" -eq 0 ] && [ "$conf" -eq 0 ] \
    && [ "$tst" -eq 0 ] && [ "$real" -eq 0 ] && [ "$kern" -eq 0 ] && [ "$edit" -eq 0 ]
