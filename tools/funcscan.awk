# funcscan.awk -- print NAME|LINE for each top-level function definition in
# a .id file, one per line, in source order. A `chain` continuation
# (docs/PROJECT.md section 3: "A function and its chains count as one
# function against the file's three") is not printed separately -- its
# header is `chain (...) {`, and the word `chain` is excluded on purpose.
#
#   awk -f funcscan.awk FILE
#
# Heuristic, not a parser: a definition is recognised as an identifier at
# brace depth 0, immediately followed by a balanced `(...)`, immediately
# followed (after whitespace) by `{`. That last check is what excludes a
# `native NAME(...) return TYPE;` declaration -- no `{` follows its `)` --
# without needing to special-case the `native` keyword. String contents and
# `//` comments are skipped so a brace or paren inside either is never
# mistaken for one in code. Assumes a function's own header -- name, `(`,
# every parameter, `)`, `{` -- appears with no unbalanced or quoted parens
# in between; ordinary `id` signatures satisfy this.
#
# If the file's braces are not balanced by end of file (e.g. a botched merge
# that spliced two sides' overlapping edits to the same closing brace),
# depth never returns to 0 for the rest of the file, so any definition past
# that point is invisible to the depth-0 check above and would be silently
# undercounted. Rather than let a count that could be silently wrong pass
# for a real one, this exits 1 in that case -- the caller is expected to
# discard whatever NAME|LINE rows were already printed and treat the whole
# file as unscannable, not to trust a partial count.
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
    instr = 0
    i = 1
    while (i <= n) {
        c = substr(text, i, 1)
        if (c == "\n") { lineno++; i++; continue }
        if (instr) {
            if (c == "\\") { i += 2; continue }
            if (c == "\"") instr = 0
            i++
            continue
        }
        if (c == "\"") { instr = 1; i++; continue }
        if (c == "/" && substr(text, i + 1, 1) == "/") {
            while (i <= n && substr(text, i, 1) != "\n") i++
            continue
        }
        if (depth == 0 && c ~ /[A-Za-z_]/) {
            wline = lineno
            word = ""
            while (i <= n) {
                cc = substr(text, i, 1)
                if (cc ~ /[A-Za-z0-9_]/) { word = word cc; i++ } else break
            }
            j = i
            while (j <= n) {
                cj = substr(text, j, 1)
                if (cj == " " || cj == "\t") { j++ }
                else if (cj == "\n") { j++ }
                else break
            }
            if (substr(text, j, 1) == "(") {
                close_at = find_close(text, j, n)
                if (close_at > 0) {
                    k = close_at + 1
                    while (k <= n) {
                        ck = substr(text, k, 1)
                        if (ck == " " || ck == "\t" || ck == "\n") { k++ } else break
                    }
                    if (substr(text, k, 1) == "{" && word != "chain") {
                        print word "|" wline
                    }
                }
            }
            i = j
            continue
        }
        if (c == "{") { depth++; i++; continue }
        if (c == "}") { depth--; i++; continue }
        i++
    }
    if (depth != 0) {
        print "funcscan: " file ": unbalanced braces (depth " depth " at end of file) -- function count unreliable" > "/dev/stderr"
        exit 1
    }
}
# find_close TEXT POS N -- POS is a "(" ; returns the index of its matching
# ")", skipping strings, or 0 if the parens never balance before N.
function find_close(text, pos, n,    d, k, c, s) {
    d = 0
    s = 0
    for (k = pos; k <= n; k++) {
        c = substr(text, k, 1)
        if (s) {
            if (c == "\\") { k++; continue }
            if (c == "\"") s = 0
            continue
        }
        if (c == "\"") { s = 1; continue }
        if (c == "(") d++
        else if (c == ")") {
            d--
            if (d == 0) return k
        }
    }
    return 0
}
