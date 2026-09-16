# lastaction.awk -- is CALLEE's call the last top-level action of the
# function starting at STARTLINE in FILE?
#
#   awk -v startline=N -v callee=NAME -f tools/lastaction.awk FILE
#
# Prints "yes" or "no" on stdout. Used by tools/chainfind.sh to decide rule
# 6 (a function called exactly once, whose one call site is its caller's
# last action, must become a `chain` of the caller): `bin/idc --calls`
# records a caller/callee pair, never a call site's position in the body, so
# the caller's own source is the only place that position can come from.
#
# The file is scanned once as a flat character stream, tracking brace depth,
# skipping string contents and `//` comments so a brace or `;` inside either
# is never mistaken for one in code. Depth 0->1 at STARTLINE enters the
# target function; while inside it, depth 1 is directly in the function's
# own body (a top-level statement) and depth 2+ is inside an `if`/`while`
# arm. A top-level statement ends at a `;` seen at depth 1, or at a `}` that
# closes a nested block back to depth 1 -- unless an `else` follows, which
# continues the same statement. The text of the last such statement, seen
# right before the function's own closing brace (depth 1->0), is checked
# against CALLEE(...) : the call itself, or a bare or typed assignment of
# it, with nothing before the name and nothing after the matching ")". A
# statement that is a whole `if`/`while` block -- even one whose only nested
# statement calls CALLEE -- never matches that shape, which is what keeps a
# nested call from being mistaken for a top-level one.
function is_pure_call(expr, name,    plen, i, d, c, rest, trailing) {
    plen = length(name)
    if (substr(expr, 1, plen) != name) return 0
    rest = substr(expr, plen + 1)
    gsub(/^[ \t]+/, "", rest)
    if (substr(rest, 1, 1) != "(") return 0
    d = 0
    for (i = 1; i <= length(rest); i++) {
        c = substr(rest, i, 1)
        if (c == "(") d++
        else if (c == ")") {
            d--
            if (d == 0) {
                trailing = substr(rest, i + 1)
                gsub(/[ \t]/, "", trailing)
                return (trailing == "") ? 1 : 0
            }
        }
    }
    return 0
}
BEGIN {
    file = ARGV[1]
    text = ""
    first = 1
    while ((getline line < file) > 0) {
        text = first ? line : text "\n" line
        first = 0
    }
    close(file)
    n = length(text)
    depth = 0
    lineno = 1
    active = 0
    started = 0
    finished = 0
    instr = 0
    stmt = ""
    laststmt = ""
    i = 1
    while (i <= n) {
        c = substr(text, i, 1)
        if (c == "\n") {
            lineno++
            if (active) stmt = stmt " "
            i++
            continue
        }
        if (instr) {
            if (active) stmt = stmt c
            if (c == "\\") {
                i++
                if (active && i <= n) stmt = stmt substr(text, i, 1)
                i++
                continue
            }
            if (c == "\"") instr = 0
            i++
            continue
        }
        if (c == "\"") {
            instr = 1
            if (active) stmt = stmt c
            i++
            continue
        }
        if (c == "/" && substr(text, i + 1, 1) == "/") {
            while (i <= n && substr(text, i, 1) != "\n") i++
            continue
        }
        if (c == "{") {
            if (depth == 0 && started == 0 && lineno == startline + 0) {
                active = 1
                started = 1
            }
            depth++
            if (active) {
                if (depth == 1) stmt = ""
                else stmt = stmt c
            }
            i++
            continue
        }
        if (c == "}") {
            depth--
            if (active) {
                if (depth == 1) {
                    stmt = stmt c
                    j = i + 1
                    while (j <= n) {
                        cc = substr(text, j, 1)
                        if (cc == " " || cc == "\t" || cc == "\n") { j++ } else break
                    }
                    nxt = substr(text, j + 4, 1)
                    if (substr(text, j, 4) != "else" || nxt ~ /[A-Za-z0-9_]/) {
                        laststmt = stmt
                        stmt = ""
                    }
                } else if (depth == 0) {
                    finished = 1
                    active = 0
                } else {
                    stmt = stmt c
                }
            }
            i++
            if (finished) break
            continue
        }
        if (c == ";" && active && depth == 1) {
            laststmt = stmt
            stmt = ""
            i++
            continue
        }
        if (active) stmt = stmt c
        i++
    }
    gsub(/^[ \t]+/, "", laststmt)
    gsub(/[ \t]+$/, "", laststmt)
    gsub(/[ \t]+/, " ", laststmt)
    if (!finished) {
        print "no" > "/dev/stderr"
        print "lastaction: " file ":" startline " -- function body never closed" > "/dev/stderr"
        print "no"
        exit 1
    }
    expr = laststmt
    eqpos = index(expr, "=")
    parpos = index(expr, "(")
    callexpr = expr
    if (eqpos > 0 && (parpos == 0 || eqpos < parpos)) {
        callexpr = substr(expr, eqpos + 1)
        gsub(/^[ \t]+/, "", callexpr)
    }
    print is_pure_call(callexpr, callee) ? "yes" : "no"
}
