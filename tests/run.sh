#!/usr/bin/env bash
# Regression tests for idc. Run from anywhere: tests/run.sh
#
#   tests/run.sh                 everything (over the 60s budget: run it by section)
#   tests/run.sh --list          the sections, with their indices
#   tests/run.sh core conform_fn just those, by name or index
#   tests/run.sh --from 4        section 4 onward
#   tests/run.sh --resume        continue after the last section that passed
#
# Why sections: no test or script should take longer than 60 seconds, because
# a slow suite does not merely cost time -- it changes behaviour, batching work
# and skipping verification. The whole suite is over it and each SECTION is under,
# so the budget is met by running it in pieces. --resume records progress after
# each section, so an interrupted run continues rather than starting over.
set -u
cd "$(dirname "$0")"

SECTIONS=(core core_parse core_guard core_self core_rest invalid_1of4 invalid_2of4 invalid_3of4 invalid_4of4 diagnostics diagnostics_docs_0 diagnostics_docs_1 diagnostics_docs_2 runtime_invalid self_host_build_demos self_host_build_link self_host_build_project_1 self_host_build_project_2 self_host_build_project_3 self_host_build_stage0 self_host_build_boot_cold self_host_build_expr backends_fs backends_fs_list backends_ipc backends_link backends_link_lib backends_link_att backends_link_pkg backends_link_gfx backends_demos backends_display backends_galaxy backends_galaxy_run stdlib_import stdlib_dce stdlib_precheck wasm wasm_js wasm_js_std lib lib_csv opt conform_eprint conform_float conform_flow conform_fn conform_free conform_int conform_list_1of2 conform_list_2of2 conform_order conform_store conform_str conform_struct conform_trap conform_closure conform_const tests_feature_0 tests_feature_1 tests_feature_2 tests_feature_3 tests_feature_4 fix idstd_real_0 idstd_real_1 idstd_real_2 kernel_build kernel_boot kernel_kfree editor mutscore statusgen)
TMPGUARD_TREES=(../idstd/.tests/hello idc/tools/buildrun idc/tools/ccrun idc/tools/iddiag idc/tools/idlayout idc/tools/idrun idc/tools/kbuild idc/tools/qmon idc/tools/mkodt editor word wordcheck uicheck iconcheck trials/csvq trials/httpd trials/jsontool trials/kv demos/fsdemo idc/tools/idwhere trials/sqlq idc/tools/statusgen)
for i in "${!TMPGUARD_TREES[@]}"; do SECTIONS+=("tmpguard_$i"); done
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

# The suite is one serial run, and a check that times a compile (timeout, ulimit)
# must not count a wait for a build slot as the compile being slow. bin/idc
# takes no slot while this is set; a suite run is the unit that gets throttled.
export IDC_NO_SLOTS=1

# The thousands of throwaway programs the suite builds stay out of the build
# record the launcher lists.
export IDC_RECORD=0

# Nothing this file builds with bin/idc has two cases per function -- not the
# compiler, not the demos -- so every such build passes --allow-untested.
# docs/TESTS.md, "Enforcement, and the migration"; the check near the end of
# `core` fails once adoption is complete and the flag is still here.
BIN_IDC="../bin/idc --allow-untested"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0

ok()   { pass=$((pass+1)); echo "PASS: $1"; }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; }

expect_output() { # name, expected, actual
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

# core is five sections, because one was over a minute once the compiler cache
# had been evicted: core builds and runs the demos, the lexer and the calculator;
# core_parse builds the parser and tests it end to end; core_guard holds the
# self-hosted rejection guards and the systems builds; core_self runs the
# compiler over its own source; core_rest is the rest. A part run alone builds
# the lexer and parser it needs.
core_tools() {
    [ -x "$TMP/idlex" ] || env -u IDC_NO_STD $BIN_IDC ../compiler/lex -o "$TMP/idlex" 2>/dev/null || bad "idc-in-id lexer compiles"
    [ -x "$TMP/idparse" ] || env -u IDC_NO_STD $BIN_IDC ../compiler/parse -o "$TMP/idparse" 2>/dev/null || bad "idc-in-id parser compiles"
}

# The body below is NOT re-indented: wrapping 700 lines in an if would make
# the diff unreadable for a change that only gates them. bash does not care.
if want core; then
# --- hello_world end to end (the demos/hello project bundles otherfn.id, which
#     testfn calls, so the whole program resolves within one project)
$BIN_IDC ../../demos/hello -o "$TMP/hello" 2>/dev/null \
    || bad "hello_world compiles"
expect_output "usage message"  "usage: $TMP/hello <message>" "$("$TMP/hello")"
expect_output "hello with arg" "hello world: hi"             "$("$TMP/hello" hi)"

# --- demos/ projects compile and run as documented
$BIN_IDC ../../demos/calc -o "$TMP/calc" 2>/dev/null \
    || bad "calc demo compiles"
expect_output "calc demo output" "total = 42 (positive)" "$("$TMP/calc")"
"$TMP/calc" >/dev/null; expect_output "calc demo exit code" "42" "$?"

$BIN_IDC ../../demos/control/flow.id -o "$TMP/flow" 2>/dev/null \
    || bad "control demo compiles"
expect_output "control demo output" "7 is a big odd / medium" "$("$TMP/flow")"

# --- adventure demo: input() builtin + cross-file branching to 8 endings.
#     Feed a choice sequence on stdin and check which ending it reaches.
$BIN_IDC ../../demos/adventure -o "$TMP/adv" 2>/dev/null \
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
main(int argc, string[] argv) {
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
$BIN_IDC "$TMP/scan.id" -o "$TMP/scan" 2>/dev/null || bad "while/len/charat/chr compiles"
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

main(int argc, string[] argv) {
  int[] xs = [];
  seed(xs);
  done(xs);
} return int 0;
EOF
$BIN_IDC "$TMP/listrun.id" -o "$TMP/listrun" 2>/dev/null || bad "list runtime compiles"
expect_output "lists push/get/set/to_int" "len=4 xs[0]=99 xs[3]=9" "$("$TMP/listrun")"

# --- idc-in-id: the lexer (written in id) tokenizes id source from stdin
# The compiler is built WITH the standard library -- both stages call idstd's
# lset. IDC_NO_STD is exported at the top of this file for every program it
# builds; the compiler is not one of those programs. It is built by bin/idc,
# like every build in this file that merges idstd: idc.py cannot parse an
# idstd that holds a `given` case.
env -u IDC_NO_STD $BIN_IDC ../compiler/lex -o "$TMP/idlex" 2>/dev/null || bad "idc-in-id lexer compiles"
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
env -u IDC_NO_STD $BIN_IDC ../../demos/idc_in_id_calc -o "$TMP/idcalc" 2>/dev/null || bad "idc-in-id calc compiles"
expect_output "calc parse+print" "(+ 2 (* 3 4))" \
    "$(echo '2 + 3 * 4' | "$TMP/idlex" | "$TMP/idcalc" | head -1)"
expect_output "calc evaluate" "= 14" \
    "$(echo '2 + 3 * 4' | "$TMP/idlex" | "$TMP/idcalc" | tail -1)"
expect_output "calc precedence/parens/unary/%" "= 13" \
    "$(echo '2 * (3 + 4) - 10 % 3' | "$TMP/idlex" | "$TMP/idcalc" | tail -1)"

# --- idc-in-id stage 2b/3: the function/statement parser + C emitter (written
#     in id), fed by the lexer. `idparse ast` prints the AST as an S-expression;
#     `idparse` (no arg) emits C.
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] && mark_done core
fi

if want core_parse; then
core_tools
cat > "$TMP/p_fn.id" <<'EOF'
add(int x, int y) {
  int sum = x * 2 + y;
} return int sum;
EOF
expect_output "parser: function/params/decl" \
    "(func add (params (param int x) (param int y)) int (body (decl int sum (+ (* x 2) y))) (return sum))" \
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
cat > "$TMP/p_chain.id" <<'EOF'
f(int x) {
  int a = 1;
  int b = 2;
  int c = 3;
} chain (int x) {
  print(a + b + c);
} return int c;
EOF
expect_output "parser: ast of a chain function shows the seam" \
    "(func f (params (param int x)) int (body (decl int a 1) (decl int b 2) (decl int c 3) (chain) (expr (call print (+ (+ a b) c)))) (return c))" \
    "$("$TMP/idlex" < "$TMP/p_chain.id" | "$TMP/idparse" ast)"

# --- stage 3 end to end: id source -> (id lexer) -> (id parser+codegen) -> C,
#     then compiled by cc and run. The whole front+middle is written in id.
cat > "$TMP/g_sq.id" <<'EOF'
twice_square(int n) {
  int r = n * n * 2;
} return int r;

main(int argc, string[] argv) {
  int a = twice_square(6);
} return int a;
EOF
"$TMP/idlex" < "$TMP/g_sq.id" | "$TMP/idparse" > "$TMP/g_sq.c"
cc -std=c11 "$TMP/g_sq.c" -o "$TMP/g_sq" 2>/dev/null || bad "emitted C (twice_square) compiles"
"$TMP/g_sq"; expect_output "codegen: twice_square(6) exit code" "72" "$?"
cat > "$TMP/g_sum.id" <<'EOF'
sumto(int n) {
  int s = 0;
  while (n > 0) {
    s = s + n;
    n = n - 1;
  }
} return int s;

main(int argc, string[] argv) {
  int t = sumto(5);
} return int t;
EOF
"$TMP/idlex" < "$TMP/g_sum.id" | "$TMP/idparse" > "$TMP/g_sum.c"
cc -std=c11 "$TMP/g_sum.c" -o "$TMP/g_sum" 2>/dev/null || bad "emitted C (sumto) compiles"
"$TMP/g_sum"; expect_output "codegen: sumto(5) exit code" "15" "$?"

# the self-hosted compiler must distinguish `else if`, spliced flat, from
# `else { if }`, which nests a braced block -- they look identical in the AST,
# and the parser carries the distinction as a flag on the if node, because by
# the time the else arm is parsed the tokens that told them apart are gone.
mkdir -p "$TMP/g_elif"
cat > "$TMP/g_elif/m.id" <<'EOF'
main(int argc, string[] argv) {
  string msg = build_msg();
  print(msg);
} return int 0;

choose(int n) {
  string s = "z";
  if(n == 0) { s = "a"; } else if(n == 1) { s = "b"; }
} return string s;

nested(int n) {
  string s = "-";
  if(n > 5) { s = "big"; } else { s = choose(n); }
} return string s;
EOF
cat > "$TMP/g_elif/more.id" <<'EOF'
build_msg() {
  string a = choose(0) + choose(1) + choose(2);
  string b = nested(0);
  string msg = a + b;
} return string msg;
EOF
$BIN_IDC "$TMP/g_elif" --emit-c "$TMP/elif_id.c" >/dev/null 2>&1
if grep -qF '} else if ((n == 1)) {' "$TMP/elif_id.c" \
   && grep -A1 -F '} else {' "$TMP/elif_id.c" | grep -q 'id_choose(n)'; then
    ok "else if is spliced flat, and else { if } nests a block"
else
    bad "else if is spliced flat, and else { if } nests a block"
fi
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] && mark_done core_parse
fi

if want core_guard; then
core_tools
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
  word b = a * 2;
  print(b);
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
guard_reject "break outside a loop" 'main(int argc, string[] argv) {
  break;
} return int 0;' "is not inside a 'while'"
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
env -u IDC_NO_STD $BIN_IDC ../../demos/idview -o "$TMP/idview" >/dev/null 2>&1
view_out=$({ printf '#file a.id\n'; printf 'one\n'; printf '#file b.id\n'; printf 'two\n'; } | "$TMP/idview")
case "$view_out" in
    "==== a.id"*one*) ok "idview picks a file and prints its body" ;;
    "==== b.id"*two*) ok "idview picks a file and prints its body" ;;
    *) bad "idview picks a file and prints its body (got: $(printf '%s' "$view_out" | tr '\n' '|'))" ;;
esac
expect_output "idview on empty input" "idview: no id files on stdin" "$(printf '' | "$TMP/idview")"

# the systems features: word, hex literals, all six bitwise operators, the
# flat store, and the unsigned builtins. These are what the kernel port is
# written in, so the self-hosted stages have to cover them -- a gap here used
# to be invisible, because bin/idc would silently fall back to idc.py rather
# than report it.
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
  string t = "" + udiv(v, 7) + umod(v, 7) + ult(v, 1) + ushr(v, 28);
  string s = mem_str();
  print(t + s);
} return void;

mem_str() {
  word m = mem_of_str("k");
  string s = str_of_mem(m, 1);
} return string s;
EOF
$BIN_IDC "$TMP/g_sys" -o "$TMP/g_sys.bin" 2>/dev/null || bad "systems features (word/bitwise/store) compiles"
expect_output "word/bitwise/store" "4887937359285593735928336-373592856029887428472933982139
5337040796013k" "$("$TMP/g_sys.bin")"
# pop, whose result type is the list's element type and so cannot be derived
# from the callee name alone. The self-hosted emitter used to produce a call
# to a runtime function that does not exist.
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
$BIN_IDC "$TMP/g_pop" -o "$TMP/g_pop.bin" 2>/dev/null || bad "pop element type compiles"
expect_output "pop element type" "2b" "$("$TMP/g_pop.bin")"
# the unsigned end of the hex range: 0xffffffffffffffff must lex to the full
# 64-bit all-ones pattern -- printed as -1, since word prints as signed
# decimal -- not truncated or misread as some other value.
mkdir -p "$TMP/g_hex"
cat > "$TMP/g_hex/m.id" <<'EOF'
main(int argc, string[] argv) {
  word a = 0xffffffffffffffff;
  print("" + a + " " + 0x7fffffffffffffff + " " + 0xff);
} return int 0;
EOF
$BIN_IDC "$TMP/g_hex" -o "$TMP/g_hex.bin" 2>/dev/null || bad "wide hex literals compiles"
expect_output "wide hex literals" "-1 9223372036854775807 255" "$("$TMP/g_hex.bin")"
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] && mark_done core_guard
fi

if want core_self; then
core_tools
# --- self-hosting: the id-written compiler emits byte-identical C for its OWN
#     source (lexer + parser/codegen) whether it is the stage bin/idc runs or
#     the lexer and parser this file built from that stage's C, and the
#     self-compiled compiler is a fixpoint (compiling itself twice reproduces
#     the same C exactly).
#
# The compiler is one of the programs in this file built WITH the standard
# library, because it uses it: both stages call idstd's `lset`. So these three
# checks unset IDC_NO_STD, and they get their input from `bin/idc --emit-sources`
# rather than from project_cat -- assembling that stream now means resolving
# idstd, ordering its roots and numbering its compilation units, and a test
# that re-implements all that is testing its own copy of it. Skips itself when
# there is no standard library to resolve, because then there is no compiler
# to check.
#
# The first two used to compare idc.py's C for the compiler with the
# self-hosted compiler's. That cannot survive an idstd holding a `given` case:
# idc.py does not parse the form, and the compiler cannot be built without
# idstd. What replaces it is bin/idc's own --emit-c against the lexer and
# parser built above. With tools/regen_bootstrap.sh --check in
# self_host_build.sh, that says stage 0, stage 1 and the compiler built from
# stage 1 all emit the same C for the compiler. What is lost is a second,
# independent implementation agreeing with them on it.
if env -u IDC_NO_STD $BIN_IDC ../compiler/lex --emit-c /dev/null >/dev/null 2>&1; then
    for src in lex parse; do
        env -u IDC_NO_STD $BIN_IDC ../compiler/$src --emit-c "$TMP/${src}_bin.c" >/dev/null 2>&1
        env -u IDC_NO_STD ../bin/idc ../compiler/$src --emit-sources 2>/dev/null \
            | "$TMP/idlex" | "$TMP/idparse" > "$TMP/${src}_id.c"
        if [ -s "$TMP/${src}_bin.c" ] && diff "$TMP/${src}_bin.c" "$TMP/${src}_id.c" >/dev/null; then
            ok "self-hosting parity with bin/idc (compiler/$src)"
        else
            bad "self-hosting parity with bin/idc (compiler/$src)"
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
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] && mark_done core_self
fi

if want core_rest; then
core_tools
# --- the two terminal games build cleanly on idstd's term_ engine (real-time
#     I/O builtins put/flush/getkey/sleep_ms/ticks/pop exercised by the games)
if env -u IDC_NO_STD $BIN_IDC ../../demos/moonbuggy -o "$TMP/moonbuggy" 2>/dev/null; then
    ok "moonbuggy builds (on idstd's term_ engine)"
else
    bad "moonbuggy builds (on idstd's term_ engine)"
fi
if env -u IDC_NO_STD $BIN_IDC ../../demos/solitaire -o "$TMP/solitaire" 2>/dev/null; then
    ok "solitaire builds (on idstd's term_ engine)"
else
    bad "solitaire builds (on idstd's term_ engine)"
fi

# --- export/import roundtrip at runtime
cat > "$TMP/roundtrip.id" <<'EOF'
main(int argc, string[] argv) {
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
$BIN_IDC "$TMP/roundtrip.id" -o "$TMP/roundtrip" 2>/dev/null || bad "roundtrip compiles"
expect_output "export/import roundtrip" "lucky 7" "$("$TMP/roundtrip")"
"$TMP/roundtrip" >/dev/null; expect_output "exit code from exported var" "7" "$?"

# --- dead-export pruning: an export declared by a function nothing calls is
# dropped from emitted C and LLVM IR, exactly as the function itself is
# (compiler/parse/back/drive/run/check/dce/export/keep.id); a reachable export
# survives. Self-hosted only -- idc.py does not prune (docs/HACKING.md).
mkdir -p "$TMP/exprune"
cat > "$TMP/exprune/m.id" <<'EOF'
main(int argc, string[] argv) {
  keep_fn();
  int r = (import kept);
} return int r;

keep_fn() {
  export int kept = 1;
} return void;

drop_fn() {
  export int dropped = 1;
} return void;
EOF
$BIN_IDC "$TMP/exprune" --emit-c "$TMP/exprune_c.c" >/dev/null 2>&1
if grep -q 'int dropped;' "$TMP/exprune_c.c"; then
    bad "dead-export pruning: unreachable export dropped (C)"
else
    ok "dead-export pruning: unreachable export dropped (C)"
fi
if grep -q 'int kept;' "$TMP/exprune_c.c"; then
    ok "dead-export pruning: reachable export kept (C)"
else
    bad "dead-export pruning: reachable export kept (C)"
fi
$BIN_IDC "$TMP/exprune" --target llvm --emit-llvm "$TMP/exprune_ll.ll" >/dev/null 2>&1
if grep -q '^@dropped ' "$TMP/exprune_ll.ll"; then
    bad "dead-export pruning: unreachable export dropped (LLVM)"
else
    ok "dead-export pruning: unreachable export dropped (LLVM)"
fi
if grep -q '^@kept ' "$TMP/exprune_ll.ll"; then
    ok "dead-export pruning: reachable export kept (LLVM)"
else
    bad "dead-export pruning: reachable export kept (LLVM)"
fi

# The test harness narrows independently of the program (back/drive/target/
# tests/): an export only a case's `given` setup reaches is kept in the
# harness's own unit even though main() never calls it, and is still absent
# from the program emitted beside it.
mkdir -p "$TMP/exprune_harn"
cat > "$TMP/exprune_harn/m.id" <<'EOF'
main(int argc, string[] argv) {
} return int 0;

harn_setup() {
  export int harn_only = 1;
} return void;

get_harn_only() {
  int v = (import harn_only);
} return int v;
given harn_setup ():(1)
EOF
$BIN_IDC "$TMP/exprune_harn" --emit-sources 2>/dev/null \
    | "$TMP/idlex" | "$TMP/idparse" --harness --natives > "$TMP/exprune_harn.c" 2>/dev/null
harn_part=$(awk '/end of test harness/{exit} {print}' "$TMP/exprune_harn.c")
prog_part=$(awk 'f{print} /end of test harness/{f=1}' "$TMP/exprune_harn.c")
if printf '%s' "$harn_part" | grep -q 'int harn_only;'; then
    ok "dead-export pruning: harness-only export kept in the harness's unit"
else
    bad "dead-export pruning: harness-only export kept in the harness's unit"
fi
if printf '%s' "$prog_part" | grep -q 'int harn_only;'; then
    bad "dead-export pruning: harness-only export absent from the program"
else
    ok "dead-export pruning: harness-only export absent from the program"
fi

# ...and the harness keeps every export, not only the ones a case's setup
# reaches: a function the cases reach may read an export whose declaring
# function only main calls. Pruning it left the harness C with an undeclared
# global, and the build failed in cc (tools/qmon's qm_qmph, 2026-09-13).
mkdir -p "$TMP/exprune_reader"
cat > "$TMP/exprune_reader/m.id" <<'EOF'
main(int argc, string[] argv) {
  boot();
  int r = reader_twice(argc);
} return int r;

boot() {
  export int boot_val = 7;
} return void;
EOF
cat > "$TMP/exprune_reader/r.id" <<'EOF'
peek_boot() {
  int v = (import boot_val);
} return int v;

reader_twice(int n) {
  int r = n * 2;
  if(n < 0) {
    r = peek_boot();
  }
} return int r;
(1):(2)
(2):(4)
EOF
if $BIN_IDC "$TMP/exprune_reader" -o "$TMP/exprune_reader.bin" >"$TMP/exprune_reader.log" 2>&1; then
    ok "dead-export pruning: the harness declares an export a kept function reads"
else
    bad "dead-export pruning: the harness declares an export a kept function reads ($(grep -m1 'error' "$TMP/exprune_reader.log"))"
fi

# --- rule violations must be compile errors. action limit and one-name-one-
# type are guard_reject-checked above (bin/idc directly); 3-functions-per-file,
# unexported access and import-without-export are tests/invalid/*.id, run by
# invalid.sh -- so only the case with no bin/idc coverage yet stays here: a
# name may repeat across functions when its type is consistent.
cat > "$TMP/reuse.id" <<'EOF'
inc(int i) { int r = i + 1; } return int r;
dec(int i) { int r = i - 1; } return int r;
main(int argc, string[] argv) { int r = inc(10) + dec(10); print("r=" + r); } return int 0;
EOF
$BIN_IDC "$TMP/reuse.id" -o "$TMP/reuse" 2>/dev/null || bad "name reuse (same type) compiles"
expect_output "name reuse same type" "r=20" "$("$TMP/reuse")"

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
$BIN_IDC "$TMP/bits" -o "$TMP/bits.out" >/dev/null 2>&1
expect_output "bitwise operators + hex literals" "48 241 15 -241
960 30 -4" "$("$TMP/bits.out")"

# `flags & MASK != 0` would group as `(flags & MASK) != 0` -- unlike C, whose
# precedence here is a well-known source of parenthesis bugs -- and because
# the two disagree, bin/idc requires the grouping to be written.
mkdir -p "$TMP/prec"
cat > "$TMP/prec/m.id" <<'EOF'
main(int argc, string[] argv) {
  int flags = 6;
  print("" + ((flags & 4) != 0));
} return int 0;
EOF
$BIN_IDC "$TMP/prec" -o "$TMP/prec.out" >/dev/null 2>&1
expect_output "bitwise binds tighter than comparison" "1" "$("$TMP/prec.out")"

mkdir -p "$TMP/word"
cat > "$TMP/word/m.id" <<'EOF'
main(int argc, string[] argv) {
  word big = 0xffffffffffff;
  show1(big);
  show2(big);
} return int 0;

show1(word big) {
  string line1 = "" + (big >> 32) + " " + ushr(big, 44) + " " + ult(0 - 1, 1);
  print(line1);
} return void;

show2(word big) {
  string line2 = "" + udiv(big, 3) + " " + umod(100, 7) + " " + (big & 0xff);
  print(line2);
} return void;
EOF
$BIN_IDC "$TMP/word" -o "$TMP/word.out" >/dev/null 2>&1
expect_output "word: 64-bit + unsigned builtins" "65535 15 0
93824992236885 2 255" "$("$TMP/word.out")"

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
$BIN_IDC "$TMP/store" -o "$TMP/store.out" >/dev/null 2>&1
expect_output "flat store: poke/peek, widths, string bridge" "1234
48879 239 hi" "$("$TMP/store.out")"

# A narrower value stored into a word[] must be widened at the point of the
# store: list cells are filled through id_list_lit's varargs and read back as
# `long long`, so without the cast an int element comes back with garbage in
# its top 32 bits. This regressed once; it now has a test.
mkdir -p "$TMP/wbox"
cat > "$TMP/wbox/m.id" <<'EOF'
wof(int a) {
  word w = a;
} return word w;

main(int argc, string[] argv) {
  word[] xs = [wof(0), 0 - 1];
  print("" + xs[1] + " " + xs[0]);
} return int 0;
EOF
$BIN_IDC "$TMP/wbox" -o "$TMP/wbox.out" >/dev/null 2>&1
expect_output "int element widened into a word[]" "-1 0" "$("$TMP/wbox.out")"

# --- alt codegen targets (--target llvm / --target wasm): a handful of
# known-good demos must produce the SAME program output/exit code as the
# default C target. Needs clang (llvm), and the WASI toolchain plus wasmtime
# (wasm); skip with a clear message if they are missing (they are inside
# tools/devshell.sh, which is how this script is meant to be run for these
# checks: `tools/devshell.sh bash tests/run.sh`).
echo
echo "--- alt targets (--target llvm / --target wasm) ---"
have_alt=1
for tool in clang wasmtime; do
    command -v "$tool" >/dev/null 2>&1 || have_alt=0
done
[ -n "${IDC_WASI_CLANG:-}" ] || have_alt=0
if [ "$have_alt" -eq 0 ]; then
    echo "SKIP: alt-target tests (need clang, wasmtime and the WASI toolchain -- " \
         "run via 'tools/devshell.sh bash tests/run.sh')"
else
    # argv[0] differs by target/binary path/name (and wasmtime reports it
    # differently again), so exercise hello with an argument (its output
    # doesn't embed argv[0]) rather than the no-arg "usage" branch.
    alt_cc() { # alt_cc TARGET SRC OUT
        $BIN_IDC "$2" --target "$1" -o "$3" 2>/dev/null
    }
    for target in llvm wasm; do
        if [ "$target" = wasm ]; then
            bin="$TMP/hello_$target.wasm"
        else
            bin="$TMP/hello_$target"
        fi
        if ! alt_cc "$target" ../../demos/hello "$bin"; then
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
        if ! alt_cc "$target" ../../demos/calc "$bin"; then
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
        if ! alt_cc "$target" ../../demos/control/flow.id "$bin"; then
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

# --- every document says whether it describes reality. Three of the ten did;
#     the other seven read as specifications whether they were one or not, and
#     docs/DISPATCH.md -- 113 lines with nothing implemented anywhere -- read
#     exactly like docs/SPEC.md, which is executable. A reader cannot tell a
#     plan from a description without opening the code, so each doc opens with
#     a `> **Status:` line and this refuses a new one that does not.
undocumented=""
for d in ../../docs/*.md; do
    grep -q '^> \*\*Status' "$d" || undocumented="$undocumented $(basename "$d")"
done
if [ -z "$undocumented" ]; then
    ok "every doc states whether it describes reality"
else
    bad "no '> **Status:' line in:$undocumented -- say whether the doc is a description, a plan, or a proposal"
fi

# --- docs/README.md lists every doc and nothing that is not there. The old
#     index in README.md named five documents that did not exist and missed
#     most of those that did; a table nobody checks is a table that drifts.
unindexed=""
for d in ../../docs/*.md; do
    n=$(basename "$d")
    [ "$n" = "README.md" ] && continue
    grep -qF "[\`$n\`]($n)" ../../docs/README.md || unindexed="$unindexed $n"
done
phantom=""
for n in $(grep -o '\](\([A-Za-z_]*\.md\))' ../../docs/README.md | sed 's/^](//; s/)$//'); do
    [ -f "../../docs/$n" ] || phantom="$phantom $n"
done
if [ -z "$unindexed" ] && [ -z "$phantom" ]; then
    ok "docs/README.md lists every doc and only docs that exist"
else
    bad "docs/README.md is out of step with docs/: not listed:${unindexed:- none}; listed but missing:${phantom:- none} -- add a row, or remove it"
fi


echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] && mark_done core_rest
fi

# --- negative tests: every file in tests/invalid/ must be rejected with the
#     error named on its `// EXPECT:` line.
echo
echo "--- negative tests (tests/invalid/) ---"
neg=0
for ik in 1 2 3 4; do
    if want "invalid_${ik}of4"; then
        ./invalid.sh "$ik" 4
        irc=$?
        if [ "$irc" -eq 0 ]; then mark_done "invalid_${ik}of4"; else neg=$irc; fi
    fi
done

# --- the diagnostic record and what reads it: the renderers, --explain, the code
#     registry, and the examples of docs/ERRORS.md (tests/diagnostics.sh). The
#     examples are three slices so that each stays under the minute.
echo
echo "--- diagnostics (tests/diagnostics.sh, docs/ERRORS.md) ---"
dgs=0
if want diagnostics; then
    ./diagnostics.sh basic
    [ $? -eq 0 ] && mark_done diagnostics || dgs=1
fi
for i in 0 1 2; do
    if want "diagnostics_docs_$i"; then
        ./diagnostics.sh docs "$i" 3
        [ $? -eq 0 ] && mark_done "diagnostics_docs_$i" || dgs=1
    fi
done

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
#     resulting binaries' output. See tests/self_host_build.sh.
echo
echo "--- self-hosted driver build (bin/idc) ---"
shneg=0
for sg in demos link project_1 project_2 project_3 stage0 boot_cold expr; do
    if want "self_host_build_$sg"; then
        ./self_host_build.sh "$sg"
        shrc=$?
        if [ "$shrc" -eq 0 ]; then mark_done "self_host_build_$sg"; else shneg=$shrc; fi
    fi
done

# --- native backends: both backends compile and coexist in one binary, the
#     graphics demos build at byte parity, and no windowed demo hangs when
#     there is no display. Skips itself when the X11/GL headers are absent.
echo
echo "--- native backends (idstd's host/io/fs, host/dev/win/gfx, host/dev/win/gl) ---"
bend=0
for bs in fs fs_list ipc link link_lib link_att link_pkg link_gfx demos display galaxy galaxy_run; do
    if want "backends_$bs"; then
        ./backends.sh "$bs"
        brc=$?
        if [ "$brc" -eq 0 ]; then mark_done "backends_$bs"; else bend=$brc; fi
    fi
done

# --- the standard library: implicit import, --no-std, $IDSTD_HOME, and the
#     transitive dependency resolution it is built on. Runs against a fixture
#     stdlib (tests/fixtures/idstd), so it says the same thing whether or not
#     a real ../idstd exists. It unsets IDC_NO_STD itself.
echo
echo "--- standard library (implicit import) ---"
std=0
for sp in "import 1" "dce 2" "precheck 3"; do
    if want "stdlib_${sp%% *}"; then
        ./stdlib.sh "${sp#* }"
        stdrc=$?
        if [ "$stdrc" -eq 0 ]; then mark_done "stdlib_${sp%% *}"; else std=$stdrc; fi
    fi
done

# --- `--target wasm`: the C target's own C, recompiled for wasm32-wasi and
#     linked as a WASI reactor (docs/TODO.md 9b). Skips itself when the
#     wasm32-wasi toolchain (nix develop's IDC_WASI_*) or node is absent, so a
#     checkout run outside the umbrella's devshell still runs the rest.
echo
echo "--- --target wasm (docs/TODO.md 9b) ---"
wsm=0
if want wasm; then
    ./wasm.sh
    wsm=$?
    [ "$wsm" -eq 0 ] && mark_done wasm
fi

# --- the JS side of --target wasm: <name>.mjs and .d.ts, the JS backends that
#     answer natives, and traps as exceptions (docs/INTEROP.md, "id and
#     JavaScript"). Two sections because the second builds against the real
#     idstd, which takes longer than the fixtures of the first.
echo
echo "--- --target wasm: JavaScript bindings ---"
wjs=0
if want wasm_js; then
    ./wasm_js.sh
    wjs=$?
    [ "$wjs" -eq 0 ] && mark_done wasm_js
fi
wjss=0
if want wasm_js_std; then
    ./wasm_js.sh std
    wjss=$?
    [ "$wjss" -eq 0 ] && mark_done wasm_js_std
fi

# --- --lib: an id project as a shared library, a static archive and a C
#     header, called from C (docs/INTEROP.md). lib builds fixtures with no
#     standard library; lib_csv builds trials/csvlib, which needs the real one.
echo
echo "--- --lib (docs/INTEROP.md, id as a library) ---"
lbs=0
if want lib; then
    ./lib.sh
    lbs=$?
    [ "$lbs" -eq 0 ] && mark_done lib
fi
if want lib_csv; then
    ./lib.sh csv
    lbc=$?
    [ "$lbc" -eq 0 ] && mark_done lib_csv
    [ "$lbc" -eq 0 ] || lbs=1
fi

# --- -O LEVEL: what each optimisation level does to a program, and that none of
#     them changes what it means (docs/BACKENDS.md, "Optimisation levels").
echo
echo "--- -O levels (docs/BACKENDS.md) ---"
opts=0
if want opt; then
    ./opt.sh
    opts=$?
    [ "$opts" -eq 0 ] && mark_done opt
fi

# --- conformance: every code-generation target must agree about what a
#     program means. Comparing emitted text against idc.py, which the tree
#     used to do, is only a question while both compilers emit C; this
#     compares behaviour, which is the question that survives a second
#     target. See docs/SPEC.md.
echo
echo "--- conformance across targets (docs/SPEC.md) ---"
conf=0
for cp in "eprint eprint" "float float" "flow flow" "fn fn" "free free" "int int" \
          "list_1of2 list:1/2" "list_2of2 list:2/2" "order order" "store store" "str str" \
          "struct struct" "trap trap" "closure closure" "const const"; do
    if want "conform_${cp%% *}"; then
        ./conform.sh ${cp#* }
        crc=$?
        if [ "$crc" -eq 0 ]; then mark_done "conform_${cp%% *}"; else conf=$crc; fi
    fi
done

# --- test clauses: the cases written under a function, run by --tests, and the
#     scaling claims they may carry. It sets IDC_NO_STD itself, because what a
#     case measures must be the function under test and nothing else.
echo
echo "--- test clauses (docs/TESTS.md) ---"
tst=0
for i in 0 1 2 3 4; do
    if want "tests_feature_$i"; then
        ./tests_feature.sh "$i"
        rc=$?
        [ "$rc" -eq 0 ] && mark_done "tests_feature_$i" || tst=1
    fi
done

# --- bin/idc --check and --fix: each case's before/ tree, fixed, is its
#     expect/ tree, a second --fix changes nothing, --check says what a build
#     says, and a fixed program prints what its hand-fixed twin prints.
echo
echo "--- --check and --fix (tests/fix/) ---"
fixr=0
if want fix; then
    ./fix.sh
    fixr=$?
    [ "$fixr" -eq 0 ] && mark_done fix
fi

# --- the REAL standard library against the real projects. Everything above
#     this line runs with IDC_NO_STD=1 or against a fixture library, which is
#     what makes it hermetic and what made a whole class of breakage --
#     a project colliding with a name idstd defines -- invisible to the suite.
#     Skips itself when there is no ../idstd. See tests/idstd_expect.txt.
echo
echo "--- the real standard library (tests/idstd_expect.txt) ---"
real=0
for real_part in 0 1 2; do
    if want idstd_real_$real_part; then
        ./idstd_real.sh $real_part 3
        real=$?
        [ "$real" -eq 0 ] && mark_done idstd_real_$real_part
    fi
done

# --- the kernel. Last because it is the only section that runs a whole machine,
#     and because everything it exercises has already been checked hosted --
#     what it adds is that none of it needed a C runtime to be true.
echo
echo "--- the kernel (docs/KERNEL.md) ---"
kern=0
for kp in build boot kfree; do
    if want "kernel_$kp"; then
        ./kernel.sh "$kp"
        krc=$?
        if [ "$krc" -eq 0 ]; then mark_done "kernel_$kp"; else kern=$krc; fi
    fi
done

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

# --- the mutation score. tools/mutscore (an `id` program) breaks a scratch COPY
#     of fixtures/mutscore one function at a time. The fixture has seven
#     mutants and is built so that exactly one survives: six killed and one
#     survived is 85.7, and the survivor is the `>` that became `>=`. The
#     section also proves the source tree's bytes are the same afterwards.
#     Under a minute: the fixture builds without the standard library, and
#     each run stops itself before the minute is up and is resumable.
echo
echo "--- the mutation score (tools/mutscore, docs/TESTS.md) ---"
if want mutscore; then
    MS_FIX=$(cd fixtures/mutscore && pwd)
    cp -r "$MS_FIX" "$TMP/ms_before"
    if ! env -u IDC_NO_STD ../bin/idc ../tools/mutscore -o "$TMP/mutscore" >"$TMP/mutscore.log" 2>&1; then
        bad "tools/mutscore builds ($(grep -v 'warning:' "$TMP/mutscore.log" | head -1))"
    else
        for _ in 1 2 3; do
            "$TMP/mutscore" run "$MS_FIX" --out "$TMP/ms_out" --idc "$(cd .. && pwd)/bin/idc" --budget 30 >"$TMP/ms_run.out" 2>&1
            grep -q ', 0 left\|is complete' "$TMP/ms_run.out" && break
        done
        tsv=$("$TMP/mutscore" report "$TMP/ms_out" --tsv 2>&1)
        expect_output "mutscore scores the fixture 6 killed, 1 survived" $'tree\t\t\t6\t1\t0\t0\t85.7' "$(printf '%s\n' "$tsv" | grep '^tree')"
        expect_output "mutscore names the survivor" $'mutant\tcheck.id\tbig\tcmp\t9\tsurvived\tint r = n > 9;  =>  int r = n >= 9;' "$(printf '%s\n' "$tsv" | grep $'\tsurvived\t')"
        expect_output "mutscore counts six kills" "6" "$(printf '%s\n' "$tsv" | grep -c $'\tkilled\t')"
        if diff -r "$MS_FIX" "$TMP/ms_before" >/dev/null; then ok "mutscore left the source tree's bytes unchanged"; else bad "mutscore changed the source tree"; fi
        [ "$fail" -eq 0 ] && mark_done mutscore
    fi
fi

# --- the status page. tools/statusgen (an `id` program) measures the tree and
#     writes docs/STATUS.md, the one place the changing numbers live. This
#     fails when the committed page is not what statusgen prints now, so the
#     page cannot go stale unnoticed; regenerate it with `statusgen --write`.
#     It also holds two things the old statusgen.sh did: a freestanding function
#     that reaches `asm` is exempt from the two-case minimum (the kernel has
#     many and no function short of its cases), and --allow-untested is deleted
#     from bin/idc once no function in any tree is short of two cases: a way out
#     nobody needs is a way out somebody will use. It counts functions, not
#     cases, so functions with many cases cannot hide one with none.
echo
echo "--- the status page (tools/statusgen, docs/STATUS.md) ---"
if want statusgen; then
    SG_ROOT=$(cd ../.. && pwd)
    if ! env -u IDC_NO_STD ../bin/idc ../tools/statusgen -o "$TMP/statusgen" >"$TMP/statusgen.log" 2>&1; then
        bad "tools/statusgen builds ($(grep -v 'warning:' "$TMP/statusgen.log" | head -1))"
    else
        if "$TMP/statusgen" --check --root "$SG_ROOT" >"$TMP/sg_check.out" 2>&1; then
            ok "docs/STATUS.md is what statusgen prints now"
        else
            bad "docs/STATUS.md is stale: $(head -1 "$TMP/sg_check.out")"
        fi
        "$TMP/statusgen" --untested --root "$SG_ROOT" >"$TMP/sg_short.out" 2>&1
        expect_output "statusgen: no function of the freestanding kernel is short of its cases" "0" "$(grep -c '^kernel/' "$TMP/sg_short.out")"
        sg_short=$(wc -l < "$TMP/sg_short.out")
        if [ "$sg_short" -eq 0 ] && grep -q -- '--allow-untested' ../bin/idc; then
            bad "no function is short of two cases and bin/idc still has --allow-untested -- delete the flag from bin/idc and every build that passes it"
        else
            ok "--allow-untested has not outlived the migration ($sg_short functions still short of two cases)"
        fi
        [ "$fail" -eq 0 ] && mark_done statusgen
    fi
fi

# --- no test case leaves anything in /tmp. tools/tmpguard (an `id` program)
#     builds one tree with the compiler cache off, so every case of the tree
#     and of idstd runs, and fails when /tmp has an entry afterwards that it did
#     not have before. One section per tree, because one tree is a cold build
#     of up to a minute; a case that makes a scratch path registers it with
#     fs_drop_exit (idstd host/io/fs), which removes it when the process ends
#     whether the case passes or fails. Other programs writing to /tmp while
#     this runs show up as entries: run it on a quiet machine.
echo
echo "--- no case leaves anything in /tmp (tools/tmpguard) ---"
tmpg=0
for i in "${!TMPGUARD_TREES[@]}"; do
    if want "tmpguard_$i"; then
        if [ ! -x "$TMP/tmpguard" ] && ! env -u IDC_NO_STD ../bin/idc ../tools/tmpguard -o "$TMP/tmpguard" >"$TMP/tmpguard.log" 2>&1; then
            bad "tools/tmpguard builds ($(grep -v 'warning:' "$TMP/tmpguard.log" | head -1))"
            tmpg=1
        elif "$TMP/tmpguard" .. "../../${TMPGUARD_TREES[$i]}" >"$TMP/tmpguard.out" 2>&1; then
            ok "$(cat "$TMP/tmpguard.out")"
            mark_done "tmpguard_$i"
        else
            bad "$(cat "$TMP/tmpguard.out")"
            tmpg=1
        fi
    fi
done

[ "$fail" -eq 0 ] && [ "$tmpg" -eq 0 ] && [ "$neg" -eq 0 ] && [ "$dgs" -eq 0 ] && [ "$rneg" -eq 0 ] && [ "$shneg" -eq 0 ] \
    && [ "$bend" -eq 0 ] && [ "$std" -eq 0 ] && [ "$wsm" -eq 0 ] && [ "$wjs" -eq 0 ] && [ "$wjss" -eq 0 ] && [ "$lbs" -eq 0 ] && [ "$opts" -eq 0 ] && [ "$conf" -eq 0 ] \
    && [ "$tst" -eq 0 ] && [ "$fixr" -eq 0 ] && [ "$real" -eq 0 ] && [ "$kern" -eq 0 ] && [ "$edit" -eq 0 ]
