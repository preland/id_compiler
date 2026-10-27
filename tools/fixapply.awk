# fixapply.awk -- apply one file's `idparse --fixes` edits to that file.
#
#   LC_ALL=C awk -v efile=EDITS -f tools/fixapply.awk SOURCE > NEW
#
# EDITS holds the @R and @D lines for SOURCE only (bin/idc --fix selects them);
# compiler/parse/mid/form/fix/run/entry.id documents both. Every coordinate in
# them is a line and a byte column of SOURCE as it is now, so all of them are
# resolved against the original text first and applied from the end of the file
# backwards, which keeps each position valid while the text before it has not
# changed yet. LC_ALL=C makes awk count bytes, as the lexer does.
#
# Two edits that overlap would mean a broken rewrite, never a smaller one, so
# that is not skipped: nothing is written and the exit status is 2.
BEGIN {
    ne = 0
    while ((getline line < efile) > 0) edits[++ne] = line
    close(efile)
    RS = "^$"
}
{ src = $0 }
END {
    nl = 1
    start[1] = 1
    for (i = 1; i <= length(src); i++)
        if (substr(src, i, 1) == "\n") start[++nl] = i + 1
    nop = 0
    for (k = 1; k <= ne; k++) {
        split(edits[k], f, "|")
        if (f[1] == "@R") add_r(f, edits[k])
        else if (f[1] == "@D") add_d(f)
        else if (f[1] == "@X") add_x(f)
    }
    for (i = 1; i <= nop; i++)
        key[sprintf("%012d %d %012d", opa[i], oprank[i], opseq[i])] = i
    n = asorti(key, order, "@ind_str_desc")
    lowest = length(src) + 2
    for (j = 1; j <= n; j++) {
        i = key[order[j]]
        if (opb[i] > lowest || (opb[i] == lowest && opa[i] < opb[i] && zero_at_lowest)) {
            print "fixapply: overlapping edits at byte " opa[i] > "/dev/stderr"
            exit_code = 2
            exit 2
        }
        src = substr(src, 1, opa[i] - 1) optext[i] substr(src, opb[i])
        zero_at_lowest = (opa[i] == opb[i])
        lowest = opa[i]
    }
    for (i = 1; i <= nnew; i++) {
        printf "%s", newtext[i] > newpath[i]
        close(newpath[i])
    }
    printf "%s", src
}

function at(l, c) { return start[l] + c }

function push_op(a, b, text, rank, seq) {
    nop++
    opa[nop] = a; opb[nop] = b; optext[nop] = text; oprank[nop] = rank; opseq[nop] = seq
}

# @R|FILE|L0|C0|L1|C1|SEQ|TEXT -- TEXT is everything after the seventh bar.
# A record is one line, so TEXT spells a newline as the two characters \n and a
# backslash as \\ (see unescape).
function add_r(f, whole,    text, p, i) {
    p = 0
    for (i = 1; i <= 7; i++) p = index(substr(whole, p + 1), "|") + p
    text = unescape(substr(whole, p + 1))
    push_op(at(f[3], f[4]), at(f[5], f[6]), text, (f[4] == f[6] && f[3] == f[5]) ? 1 : 2, f[7] + 0)
}

# @D|FILE|L|C|SEQ|IL|HEAD|L0|C0|L1|C1[|SL0|SC0|SL1|SC1|NAME]...
# At the start of its line (after indentation) the declaration gets a line of
# its own, indented as line IL is -- or, for IL 0, one step past line L. Mid-line
# it goes in place, followed by a space.
function add_d(f,    a, b, piece, ns, i, sa, sb, sname, k2, sk, sorder, m, j, text, p, ls, prefix, indent) {
    a = at(f[8], f[9]); b = at(f[10], f[11])
    ns = 0
    delete sk
    for (i = 12; i + 4 <= length(f); i += 5) {
        ns++
        sa[ns] = at(f[i], f[i + 1]); sb[ns] = at(f[i + 2], f[i + 3]); sname[ns] = f[i + 4]
        sk[sprintf("%012d", sa[ns])] = ns
    }
    piece = substr(src, a, b - a)
    m = asorti(sk, sorder, "@ind_str_desc")
    for (j = 1; j <= m; j++) {
        k2 = sk[sorder[j]]
        piece = substr(piece, 1, sa[k2] - a) sname[k2] substr(piece, sb[k2] - a + 1)
    }
    gsub(/\n[ \t]*/, " ", piece)
    text = f[7] piece ";"
    p = at(f[3], f[4]); ls = start[f[3]]
    prefix = substr(src, ls, p - ls)
    if (prefix ~ /^[ \t]*$/) {
        indent = lead(f[6] + 0 > 0 ? f[6] : f[3])
        if (f[6] + 0 == 0) indent = indent "  "
        push_op(ls, ls, indent text "\n", 0, f[5] + 0)
    } else {
        push_op(p, p, text " ", 1, f[5] + 0)
    }
}

function unescape(t,    out, i, c, d) {
    out = ""
    for (i = 1; i <= length(t); i++) {
        c = substr(t, i, 1)
        d = substr(t, i + 1, 1)
        if (c == "\\" && d == "n") { out = out "\n"; i++ }
        else if (c == "\\" && d == "\\") { out = out "\\"; i++ }
        else out = out c
    }
    return out
}

function lead(l,    s, e) {
    e = (l < nl) ? start[l + 1] - 1 : length(src) + 1
    s = substr(src, start[l], e - start[l])
    match(s, /^[ \t]*/)
    return substr(s, 1, RLENGTH)
}

# @X|FILE|L0|C0|L1|C1|SEQ|NAME|CALL|HEAD|CHAIN|TAIL|ORIGIN[|L|C]...
# The span L0:C0 .. L1:C1 becomes the body of a new function NAME in a new
# file NAME.id beside FILE, and CALL takes its place. The body is cut at each
# L|C and the pieces joined by CHAIN, re-indented to two spaces. A path that
# exists already is a broken rewrite, never a smaller one: exit status 2.
function add_x(f,    a, b, cuts, pos, k, piece, body, text, path, dir) {
    a = at(f[3], f[4]); b = at(f[5], f[6])
    cuts = 0
    for (k = 14; k + 1 <= length(f); k += 2) pos[++cuts] = at(f[k], f[k + 1])
    pos[cuts + 1] = b
    body = ""
    for (k = 1; k <= cuts + 1; k++) {
        piece = substr(src, (k == 1) ? a : pos[k - 1], pos[k] - ((k == 1) ? a : pos[k - 1]))
        body = body (k == 1 ? "" : "\n" f[11] "\n") reindent(piece, f[4] + 0)
    }
    text = "// Pulled out of " f[13] " by idc --fix: that block performed more than 3 actions.\n\n" f[10] "\n" body "\n" f[12] "\n"
    dir = f[2]
    if (!sub(/[^\/]*$/, "", dir)) dir = ""
    path = dir f[8] ".id"
    if ((getline probe < path) >= 0) {
        print "fixapply: " path " exists already" > "/dev/stderr"
        exit_code = 2
        exit 2
    }
    nnew++; newpath[nnew] = path; newtext[nnew] = text
    push_op(a, b, f[9], 2, f[7] + 0)
}

function reindent(piece, base,    n, lines, i, out, indent, s) {
    gsub(/^[ \t\n]+/, "", piece)
    gsub(/[ \t\n]+$/, "", piece)
    n = split(piece, lines, "\n")
    out = "  " lines[1]
    for (i = 2; i <= n; i++) {
        s = lines[i]
        match(s, /^[ \t]*/)
        indent = RLENGTH - base + 2
        if (indent < 2) indent = 2
        out = out "\n" sprintf("%" indent "s", "") substr(s, RLENGTH + 1)
    }
    return out
}
