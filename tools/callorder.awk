# callorder.awk -- bottom-up order (callees before callers, cycles grouped)
# for tools/calltree.sh --order.
#
#   awk -v namesfile=NAMES -v locfile=LOCS -f tools/callorder.awk EDGES
#
# NAMES: one function name per line, in the caller's --order FILE order (the
# node set, and a stable tie-break within a cycle). LOCS: NAME<TAB>LOC, LOC a
# "path:line", for every name in NAMES. EDGES (this script's main input):
# CALLER<TAB>CALLEE pairs; a pair naming something outside NAMES is ignored,
# and a self pair (CALLER == CALLEE, direct recursion) is kept as a
# one-member cycle.
#
# Kosaraju's algorithm: a first DFS over the (filtered) call edges records a
# finish order, then a second DFS over the reverse edges, taken in that
# finish order, groups each strongly connected component (a cycle, or a
# single acyclic function) as it is discovered -- and discovers them in a
# topological order of the *caller* graph, so reading that discovery order
# backwards is calls-before-callers, which is bottom-up.
BEGIN {
    FS = "\t"
    nn = 0
    while ((getline line < namesfile) > 0) {
        if (line == "") continue
        nn++
        names[nn] = line
        idx[line] = nn
        innames[line] = 1
    }
    close(namesfile)
    while ((getline line < locfile) > 0) {
        split(line, f, "\t")
        loc[f[1]] = f[2]
    }
    close(locfile)
}
{
    if (!(($1 in innames) && ($2 in innames))) next
    outn[$1]++
    outedge[$1, outn[$1]] = $2
    inn[$2]++
    inedge[$2, inn[$2]] = $1
}
END {
    sp = 0
    for (i = 1; i <= nn; i++) {
        u = names[i]
        if (!(u in visited)) dfs1(u)
    }
    ncomp = 0
    for (i = sp; i >= 1; i--) {
        u = fin[i]
        if (!(u in comp)) {
            ncomp++
            dfs2(u, ncomp)
        }
    }
    for (c = ncomp; c >= 1; c--) {
        emit(c)
    }
}
function dfs1(u,   k, v) {
    visited[u] = 1
    for (k = 1; k <= outn[u]; k++) {
        v = outedge[u, k]
        if (!(v in visited)) dfs1(v)
    }
    fin[++sp] = u
}
function dfs2(u, c,   k, v) {
    comp[u] = c
    csize[c]++
    member[c, csize[c]] = u
    for (k = 1; k <= inn[u]; k++) {
        v = inedge[u, k]
        if (!(v in comp)) dfs2(v, c)
    }
}
# emit COMP -- one component, its members in NAMES order. A cycle (more than
# one member, or one member that calls itself) gets a "# cycle:" header.
function emit(c,   j, k, tmp, t2, small, si) {
    for (j = 1; j <= csize[c]; j++) tmp[j] = member[c, j]
    for (j = 1; j < csize[c]; j++) {
        small = j
        for (k = j + 1; k <= csize[c]; k++) {
            if (idx[tmp[k]] < idx[tmp[small]]) small = k
        }
        if (small != j) { t2 = tmp[j]; tmp[j] = tmp[small]; tmp[small] = t2 }
    }
    si = 0
    for (k = 1; k <= outn[tmp[1]]; k++) if (outedge[tmp[1], k] == tmp[1]) si = 1
    if (csize[c] > 1 || si == 1) {
        printf "# cycle:"
        for (j = 1; j <= csize[c]; j++) printf " %s%s", tmp[j], (j < csize[c] ? "," : "")
        printf "\n"
    }
    for (j = 1; j <= csize[c]; j++) print loc[tmp[j]] "|" tmp[j]
}
