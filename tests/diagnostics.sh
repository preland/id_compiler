#!/usr/bin/env bash
# The diagnostic record and what reads it (docs/DIAGNOSTICS.md, docs/ERRORS.md).
#
#   tests/diagnostics.sh basic       --explain, the code registry against docs/ERRORS.md,
#                                    the three output formats, colour, applying an edit
#   tests/diagnostics.sh docs I N    the docs/ERRORS.md examples of every Nth code from
#                                    the Ith (0-based): each `Incorrect:` block must fail
#                                    with its code, each `Correct:` block must build
#
# The examples are split into slices because one build costs a second or two and no
# test may run over a minute; tests/run.sh runs the slices as diagnostics_docs_0..2.
set -u
export IDC_NO_STD=1
cd "$(dirname "$0")"
BIN_IDC=../bin/idc
DOC=../../docs/ERRORS.md
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

# codes_in_docs -- every `## E0123` heading of docs/ERRORS.md, one per line.
codes_in_docs() { sed -n 's/^## \(E[0-9][0-9][0-9][0-9]\) .*/\1/p' "$DOC"; }

# extract_examples DIR -- writes DIR/CODE.bad.id and DIR/CODE.good.id (and .flags files
# holding `tests` for a block written ```id tests) for every section's first
# `Incorrect:` and `Correct:` block that is an `id` block.
extract_examples() {
    awk -v dir="$1" '
        /^## E[0-9][0-9][0-9][0-9] / { code = $2; label = ""; next }
        /^Incorrect:$/ { label = "bad"; next }
        /^Correct:$/ { label = "good"; next }
        /^```id/ && label != "" && !inblock {
            inblock = 1; out = dir "/" code "." label ".id"
            flags = dir "/" code "." label ".flags"
            printf "%s\n", (($0 ~ /tests/) ? "tests" : "") > flags
            printf "" > out; next
        }
        /^```text/ && label != "" { label = ""; next }
        /^```$/ && inblock { inblock = 0; close(out); label = ""; next }
        inblock { print > out }
    ' "$DOC"
}

# build_example FILE FLAGS_FILE OUT -- the build of one example; the exit status is idc's.
build_example() {
    local extra="--allow-untested"
    [ "$(cat "$2")" = tests ] && extra=""
    $BIN_IDC "$1" $extra -o "$3" > "$3.log" 2>&1
}

# layout_check CODE FILES MORE_FILES UNUSED -- a project tree made of FILES and MORE_FILES
# (paths under it, each holding one small function, and `main` in the first), built:
# the diagnostic of the tree-shape rule CODE names must come out, with a why and a
# help line (the rules are tools/idlayout's; their examples in docs/ERRORS.md are trees).
layout_check() {
    local code="$1" proj="$TMP/lay_$1" f n=0 first=1
    mkdir -p "$proj"
    for f in $2 $3; do
        mkdir -p "$proj/$(dirname "$f")"
        n=$((n+1))
        if [ "$first" -eq 1 ]; then
            printf 'main(int argc, string[] argv) {\n  int r = argc;\n} return int r;\n' > "$proj/$f"; first=0
        else
            printf 'f%s(int x) {\n  int y = x + %s;\n} return int y;\n' "$n" "$n" > "$proj/$f"
        fi
    done
    $BIN_IDC "$proj" --allow-untested --diagnostics=human -o "$proj.bin" > "$proj.log" 2>&1
    if grep -qE "^error\[$code\]: " "$proj.log" && grep -q "= why: " "$proj.log" && grep -q "= help: " "$proj.log"; then
        ok "layout $code: reported with its code, a why and a help"
    else
        bad "layout $code: $(grep -m2 'error' "$proj.log" | cut -c1-160 | tr '\n' '|')"
    fi
}

basic() {
    local out rc

    out=$($BIN_IDC --explain E0501 2>&1); rc=$?
    if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | head -1 | grep -q '^E0501 ' \
       && printf '%s\n' "$out" | grep -q '^Incorrect:$' && printf '%s\n' "$out" | grep -q '^Correct:$'; then
        ok "--explain E0501 prints its section: heading, an incorrect and a correct example"
    else
        bad "--explain E0501 prints its section (rc=$rc, first line: $(printf '%s' "$out" | head -1))"
    fi
    out=$($BIN_IDC --explain e0501 2>&1 | head -1); out2=$($BIN_IDC --explain 501 2>&1 | head -1)
    if [ "$out" = "$out2" ] && printf '%s' "$out" | grep -q '^E0501 '; then
        ok "--explain takes the code in lower case or as a bare number"
    else
        bad "--explain takes the code in lower case or as a bare number ('$out' / '$out2')"
    fi
    out=$($BIN_IDC --explain E9999 2>&1); rc=$?
    if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "no error code 'E9999'" && printf '%s' "$out" | grep -q 'E0501'; then
        ok "--explain of an unknown code fails and lists the codes that exist"
    else
        bad "--explain of an unknown code fails and lists the codes that exist (rc=$rc)"
    fi
    out=$($BIN_IDC x.id --diagnostics=bogus 2>&1); rc=$?
    if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "human.*json.*plain"; then
        ok "--diagnostics with an unknown format is a usage error naming the three"
    else
        bad "--diagnostics with an unknown format is a usage error naming the three (rc=$rc)"
    fi

    local emitted documented missing extra
    emitted=$(grep -rhoE '"E0[1-9][0-9][0-9]"' ../compiler ../tools --include=*.id | tr -d '"' | sort -u)
    documented=$(codes_in_docs | sort -u)
    missing=$(comm -23 <(printf '%s\n' "$emitted") <(printf '%s\n' "$documented") | tr '\n' ' ')
    extra=$(comm -13 <(printf '%s\n' "$emitted") <(printf '%s\n' "$documented") | tr '\n' ' ')
    if [ -z "$missing" ] && [ -z "$extra" ] && [ -n "$emitted" ]; then
        ok "every code the compiler and tools emit has a section in docs/ERRORS.md, and every section a code"
    else
        bad "code registry: emitted but not documented: [$missing] documented but never emitted: [$extra]"
    fi

    cat > "$TMP/t.id" <<'EOF'
add(int a, int b) {
  int s = a + b;
} return int s;

main(int argc, string[] argv) {
  int c = add(1, 2);
  print(c);
} return int 0;
(1, ["x"]):(0)
EOF
    TERM=xterm $BIN_IDC "$TMP/t.id" --diagnostics=human -o "$TMP/t.bin" > "$TMP/human.out" 2>&1; rc=$?
    if [ "$rc" -eq 1 ] \
       && grep -qE "^error\[E0501\]: function 'add' has 0 test case\(s\)" "$TMP/human.out" \
       && grep -qE '^  --> .*t\.id:1:1$' "$TMP/human.out" && grep -qxF '  in add' "$TMP/human.out" \
       && ! grep -qE ': error: ' "$TMP/human.out" \
       && grep -qxF '1 | add(int a, int b) {' "$TMP/human.out" \
       && grep -qE '^  \| \^\^\^$' "$TMP/human.out" \
       && grep -q '= why: ' "$TMP/human.out" && grep -q '= help: ' "$TMP/human.out" \
       && grep -qxF 'error: aborting due to 2 previous errors' "$TMP/human.out"; then
        ok "human format: a rustc-style head with the place and the function, the source line, a caret under the function name, why, help, a summary"
    else
        bad "human format (rc=$rc): $(head -4 "$TMP/human.out" | tr '\n' '|')"
    fi
    if ! grep -q $'\033' "$TMP/human.out"; then
        ok "no colour when output is not a terminal"
    else
        bad "no colour when output is not a terminal"
    fi
    $BIN_IDC "$TMP/t.id" --diagnostics=human --color=always -o "$TMP/t.bin" > "$TMP/color.out" 2>&1
    if grep -q $'\033\\[1;31merror' "$TMP/color.out"; then
        ok "--color=always colours the severity"
    else
        bad "--color=always colours the severity"
    fi
    NO_COLOR=1 $BIN_IDC "$TMP/t.id" --diagnostics=human --color=auto -o "$TMP/t.bin" > "$TMP/nocolor.out" 2>&1
    if ! grep -q $'\033' "$TMP/nocolor.out"; then
        ok "NO_COLOR keeps --color=auto plain"
    else
        bad "NO_COLOR keeps --color=auto plain"
    fi
    $BIN_IDC "$TMP/t.id" -o "$TMP/t.bin" > "$TMP/piped.out" 2>&1; rc=$?
    if [ "$rc" -eq 1 ] && grep -qE "t\.id:1: error: function 'add' has 0 test case\(s\).* \[E0501\]$" "$TMP/piped.out" \
       && ! grep -qE '^error\[|^ *--> |^ *\| ' "$TMP/piped.out"; then
        ok "default format with stderr piped is plain: FILE:LINE: error: MESSAGE [CODE], no snippet"
    else
        bad "default format with stderr piped (rc=$rc): $(head -3 "$TMP/piped.out" | tr '\n' '|')"
    fi
    IDC_DIAGNOSTICS=human $BIN_IDC "$TMP/t.id" -o "$TMP/t.bin" > "$TMP/envh.out" 2>&1
    if grep -q '^error\[E0501\]: ' "$TMP/envh.out"; then
        ok "IDC_DIAGNOSTICS=human overrides the piped default"
    else
        bad "IDC_DIAGNOSTICS=human overrides the piped default"
    fi
    $BIN_IDC "$TMP/t.id" --diagnostics=plain -o "$TMP/t.bin" > "$TMP/plain.out" 2>&1; rc=$?
    if [ "$rc" -eq 1 ] && grep -qE "t\.id:1: error: function 'add' has 0 test case\(s\).* \[E0501\]$" "$TMP/plain.out" \
       && grep -qxF '  at: add' "$TMP/plain.out" && ! grep -q '^ *| ' "$TMP/plain.out" \
       && ! grep -qE '^error\[|^ *--> |^ *in |follows' "$TMP/plain.out"; then
        ok "plain format: the compiler's own lines, no snippet, the at/why/help/edit lines indented under the head"
    else
        bad "plain format (rc=$rc): $(head -3 "$TMP/plain.out" | tr '\n' '|')"
    fi

    $BIN_IDC "$TMP/t.id" --diagnostics=json -o "$TMP/t.bin" > "$TMP/json.out" 2>&1; rc=$?
    cat > "$TMP/check.js" <<'EOF'
const fs = require('fs');
const lines = fs.readFileSync(process.argv[2], 'utf8').split('\n').filter(Boolean);
const objs = lines.map((l) => JSON.parse(l));
const fail = (m) => { console.log('FAIL ' + m); process.exit(1); };
const kinds = new Set(objs.map((o) => o.kind));
for (const k of kinds) if (!['diagnostic', 'text', 'summary'].includes(k)) fail('kind ' + k);
const d = objs.find((o) => o.kind === 'diagnostic');
if (!d) fail('no diagnostic');
if (d.code !== 'E0501' || d.severity !== 'error') fail('code/severity ' + d.code + ' ' + d.severity);
if (d.line !== 1 || d.column !== 1 || d.end_column !== 4) fail('span ' + d.line + ':' + d.column + '-' + d.end_column);
if (!d.file.endsWith('t.id') || !d.message.startsWith("function 'add' has 0 test case(s)")) fail('file/message');
if (!d.why || !d.rendered.includes('^^^')) fail('why/rendered');
if (d.function !== 'add' || d.follows !== null) fail('function/follows ' + d.function + ' ' + JSON.stringify(d.follows));
if (!d.rendered.startsWith('error[E0501]: function')) fail('rendered head ' + d.rendered.split('\n')[0]);
const fx = d.fixes[0];
if (!fx || fx.applicability !== 'has-placeholders' || fx.edits.length !== 1) fail('fix ' + JSON.stringify(fx));
const e = fx.edits[0];
if (e.line !== 4 || e.column !== 1 || e.end_line !== 4 || e.end_column !== 1) fail('edit span');
if (!e.text.startsWith('(ARG1_1, ARG1_2):(EXPECTED1)\n(ARG2_1, ARG2_2):(EXPECTED2)\n')) fail('edit text ' + JSON.stringify(e.text));
const s = objs[objs.length - 1];
if (s.kind !== 'summary' || s.errors !== 2 || !s.codes.includes('E0501')) fail('summary ' + JSON.stringify(s));
console.log('ok');
EOF
    if ! command -v node >/dev/null 2>&1; then
        echo "SKIP: json format (needs node on PATH)"
    elif [ "$rc" -eq 1 ] && [ "$(node "$TMP/check.js" "$TMP/json.out" 2>&1)" = ok ]; then
        ok "json format: one object per line; code, severity, span, message, why, a fix with an edit at the right line, a summary"
    else
        bad "json format (rc=$rc): $(node "$TMP/check.js" "$TMP/json.out" 2>&1 | head -2)"
    fi

    printf 'main(int argc, string[] argv) {\n  int x 5;\n  int y = z;\n} return int 0;\n' > "$TMP/c.id"
    $BIN_IDC "$TMP/c.id" --allow-untested --diagnostics=human -o "$TMP/c.bin" > "$TMP/c.human" 2>&1
    $BIN_IDC "$TMP/c.id" --allow-untested --diagnostics=plain -o "$TMP/c.bin" > "$TMP/c.plain" 2>&1
    $BIN_IDC "$TMP/c.id" --allow-untested --diagnostics=json -o "$TMP/c.bin" > "$TMP/c.json" 2>&1
    cat > "$TMP/follow.js" <<'EOF'
const fs = require('fs');
const ds = fs.readFileSync(process.argv[2], 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)).filter((o) => o.kind === 'diagnostic');
const fail = (m) => { console.log('FAIL ' + m); process.exit(1); };
const by = (code, msg) => ds.find((o) => o.code === code && o.message.includes(msg));
const root = by('E0101', "expected '='");
const brace = by('E0102', "unexpected token ';'");
const semi = by('E0301', "undefined variable ';'");
const real = by('E0301', "undefined variable 'z'");
if (!root || !brace || !semi || !real) fail('missing diagnostic ' + ds.map((o) => o.code + ':' + o.message).join(' | '));
if (root.follows !== null) fail('the syntax error follows nothing');
for (const o of [brace, semi]) if (!o.follows || o.follows.code !== 'E0101' || o.follows.line !== root.line || o.follows.file !== root.file) fail('follow-on ' + JSON.stringify(o.follows));
if (real.follows !== null) fail('a mistake of its own on another line is not tagged: ' + JSON.stringify(real.follows));
if (root.function !== 'main' || real.function !== 'main') fail('function ' + root.function);
if (!semi.rendered.includes('= note: follows from the error at ') || !semi.rendered.includes(' above')) fail('rendered note');
console.log('ok');
EOF
    if [ "$(grep -c '^  = note: follows from the error at .*c\.id:2 above$' "$TMP/c.human")" = 2 ] \
       && [ "$(grep -c '^error\[' "$TMP/c.human")" = 4 ] && ! grep -q 'follows' "$TMP/c.plain" \
       && [ "$(grep -c ': error: ' "$TMP/c.plain")" = 4 ]; then
        ok "after a syntax error, the diagnostics it caused are tagged 'follows from' (human) and left as they were (plain), not suppressed"
    else
        bad "follow-on tagging, human/plain: $(grep -c 'follows' "$TMP/c.human") notes, $(grep -c '^error\[' "$TMP/c.human") errors"
    fi
    if ! command -v node >/dev/null 2>&1; then
        echo "SKIP: follow-on tagging in json (needs node on PATH)"
    elif [ "$(node "$TMP/follow.js" "$TMP/c.json" 2>&1)" = ok ]; then
        ok "json: a diagnostic caused by a syntax error carries follows {file, line, code}; the real error on the next line and the syntax error carry null"
    else
        bad "follow-on tagging, json: $(node "$TMP/follow.js" "$TMP/c.json" 2>&1 | head -2)"
    fi

    mkdir -p "$TMP/wh/sub" "$TMP/wh/.hid"
    printf 'f() {\n} return void;\n' > "$TMP/wh/a.id"
    printf '// c\ng(int x) {\n} return int x;\n' > "$TMP/wh/sub/b.id"
    printf 'g(string s) {\n} return string s;\n' > "$TMP/wh/.hid/c.id"
    out=$($BIN_IDC --where g "$TMP/wh" 2>&1); rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = "$TMP/wh/sub/b.id:2: g(int x) -> int" ]; then
        ok "--where NAME PATH prints FILE:LINE, the signature and the return type, and does not enter a hidden directory"
    else
        bad "--where NAME PATH (rc=$rc): $out"
    fi
    out=$($BIN_IDC --where sub/b.id::g "$TMP/wh" 2>&1); out2=$($BIN_IDC --where other.id::g "$TMP/wh" 2>&1); rc=$?
    if [ "$out" = "$TMP/wh/sub/b.id:2: g(int x) -> int" ] && [ "$rc" -eq 1 ] && printf '%s' "$out2" | grep -q "no function 'other.id::g'"; then
        ok "--where FILE::NAME keeps only the functions of that file, and a miss names what to check"
    else
        bad "--where FILE::NAME (rc=$rc): $out / $out2"
    fi
    start=$(date +%s%N); $BIN_IDC --where no_such_function_zz ../compiler > /dev/null 2>&1; end=$(date +%s%N)
    start2=$(date +%s%N); $BIN_IDC --where no_such_function_zz ../compiler > /dev/null 2>&1; end2=$(date +%s%N)
    ms=$(( (end2 - start2) / 1000000 ))
    if [ "$ms" -lt 1000 ]; then
        ok "--where scans the whole compiler tree in ${ms} ms warm (limit 1000)"
    else
        bad "--where on the compiler took ${ms} ms warm; the limit is 1000"
    fi

    wide="$TMP/lay_wide"
    mkdir -p "$wide"
    printf 'main(int argc, string[] argv) {\n  int r = argc;\n} return int r;\n' > "$wide/main.id"
    n=0
    sum=1
    for f in alpha bravo charlie delta echo foxtrot golf hotel india; do n=$((n + 1)); sum="$sum + x"; printf 'wide%s(int x) {\n  int y = %s;\n} return int y;\n' "$n" "$sum" > "$wide/$f.id"; done
    if $BIN_IDC "$wide" --allow-untested -o "$wide.bin" > "$wide.log" 2>&1 && [ ! -s "$wide.log" ]; then
        ok "layout: a directory of ten files builds, with nothing reported"
    else
        bad "layout: a directory of ten files builds: $(head -c 300 "$wide.log" | tr '\n' '|')"
    fi
    layout_check E0702 'util.id' '' ''
    layout_check E0703 'loop/loop.id' '' ''
    layout_check E0704 'loop/loop/main.id' '' ''
    layout_check E0705 'chunk.id chunk2.id' '' ''
    layout_check E0706 'main.id import.id' '' ''
    layout_check E0707 'main.id sub/conf.id' '' ''

    cat > "$TMP/m.id" <<'EOF'
main(int argc, string[] argv) {
  int flags = argc;
  int on = 0;
  if(flags & 4 == 4) {
    on = 1;
  }
} return int on;
EOF
    cat > "$TMP/apply.js" <<'EOF'
const fs = require('fs');
const [stream, want] = process.argv.slice(2);
const objs = fs.readFileSync(stream, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
const d = objs.find((o) => o.kind === 'diagnostic' && o.code === want);
if (!d) { console.log('no diagnostic ' + want); process.exit(1); }
const fx = d.fixes.find((f) => f.applicability === 'machine-applicable' && f.edits.length > 0);
if (!fx) { console.log('no machine-applicable fix'); process.exit(1); }
let text = fs.readFileSync(d.file, 'utf8');
const at = (line, col) => {
  let off = 0;
  for (let i = 1; i < line; i++) off = text.indexOf('\n', off) + 1;
  return off + col - 1;
};
const edits = fx.edits.map((e) => ({ a: at(e.line, e.column), b: at(e.end_line, e.end_column), t: e.text }));
edits.sort((x, y) => y.a - x.a);
for (const e of edits) text = text.slice(0, e.a) + e.t + text.slice(e.b);
fs.writeFileSync(d.file, text);
console.log('applied');
EOF
    if ! command -v node >/dev/null 2>&1; then
        echo "SKIP: applying a machine-applicable edit (needs node on PATH)"
    else
        $BIN_IDC "$TMP/m.id" --allow-untested --diagnostics=json -o "$TMP/m.bin" > "$TMP/m.json" 2>&1
        if [ "$(node "$TMP/apply.js" "$TMP/m.json" E0601 2>&1)" = applied ] \
           && sed -n 4p "$TMP/m.id" | grep -qxF '  if((flags & 4) == 4) {' \
           && $BIN_IDC "$TMP/m.id" --allow-untested -o "$TMP/m.bin" > "$TMP/m2.log" 2>&1 \
           && "$TMP/m.bin" > /dev/null; then
            ok "the machine-applicable edit of E0601, applied from the JSON, fixes the program: it builds and runs"
        else
            bad "applying E0601's machine-applicable edit ($(head -c 300 "$TMP/m2.log" 2>/dev/null); line 4: $(sed -n 4p "$TMP/m.id"))"
        fi
    fi
}

docs() {
    local slice="$1" of="$2" i=0 code
    mkdir -p "$TMP/ex"
    extract_examples "$TMP/ex"
    for code in $(codes_in_docs); do
        i=$((i+1))
        [ $(( (i - 1) % of )) -eq "$slice" ] || continue
        if [ -f "$TMP/ex/$code.bad.id" ]; then
            if build_example "$TMP/ex/$code.bad.id" "$TMP/ex/$code.bad.flags" "$TMP/ex/$code.bad.bin"; then
                bad "$code: its Incorrect example builds"
            elif grep -qF "[$code]" "$TMP/ex/$code.bad.bin.log"; then
                ok "$code: the Incorrect example fails with [$code]"
            else
                bad "$code: the Incorrect example fails, but not with [$code]: $(grep -m1 'error' "$TMP/ex/$code.bad.bin.log" | cut -c1-200)"
            fi
        fi
        if [ -f "$TMP/ex/$code.good.id" ]; then
            if build_example "$TMP/ex/$code.good.id" "$TMP/ex/$code.good.flags" "$TMP/ex/$code.good.bin"; then
                ok "$code: the Correct example builds"
            else
                bad "$code: the Correct example does not build: $(grep -m1 'error' "$TMP/ex/$code.good.bin.log" | cut -c1-200)"
            fi
        fi
    done
}

case "${1:-}" in
    basic) basic ;;
    docs) docs "${2:?docs needs a slice index}" "${3:?docs needs a slice count}" ;;
    *) echo "usage: diagnostics.sh basic | docs I N" >&2; exit 2 ;;
esac

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
