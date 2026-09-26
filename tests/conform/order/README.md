# Evaluation order

`docs/SPEC.md` §7. The operands of an operator, and the arguments of a call,
are evaluated **left to right**.

These cases are the ones where that is observable: two operands that both have
an effect, and an effect that the other operand can see. Every other expression
in the language gives the same answer whichever order it is evaluated in, which
is why this went unnoticed until a bit reader and a `pop` next to a `len` found
it.

## What §7.1 took away, and gave part of back

There used to be a third case here, `03-argument-order`:

```
print(pair(step(c), step(c)));
```

For a while `id` did not accept it. §7.1 used to say a call may not be an
argument to a call *at any depth*, so two calls could never be arguments of
the same call, and the order in which a call's arguments are evaluated could
not be observed at all. The case was deleted rather than rewritten, because
every rewrite of it turned into two statements, and the order of two
statements was never in question.

§7.1 now allows one level of call nesting (a call's argument may itself be a
call, so long as that inner call's own arguments hold no call of their own),
so `pair(step(c), step(c))` is legal again -- each argument to `pair` is a
bare call, one level. What is still illegal is nesting `pair(...)` itself
inside `print(...)`: from `print`'s side that argument would carry two levels
(`print` -> `pair` -> `step`), which is exactly what §7.1 forbids. So the
restored `03-argument-order` binds the call to a name first, then prints the
name -- the same shape every multi-statement rewrite here already uses, and
the one that keeps `print`'s own argument flat.

What is left observable is operands and one-level call arguments: `bump(c) +
bump(c)` is legal because neither call is inside the other's argument list,
and `pair(bump(c), bump(c))` is legal because each of `pair`'s two arguments
is a call one level deep, not two. So §7 says something about operators and
something real, once more, about arguments: `03-argument-order` is where the
C target's non-conformance (`known_apart c:order`, tests/conform.sh) actually
reappears -- built and run directly, gcc evaluates `pair`'s arguments right to
left (`a=2 b=1`), the opposite of §7's left-to-right. That is not a new bug
from the relaxation: it is the same pre-existing C-target gap, reachable again
through a shape the old rule had made impossible to write.

That also narrows S11. The C target's non-conformance was found through a call's
arguments; what remains to be proved is whether it holds for `+`, which C also
leaves unsequenced.

## How the C target conforms

It held for `+` too: before the fix, `01` printed `a=2 b=1` and `04` printed
`321` on C. The C target now binds each call, index, import, trapping
division and `&&`/`||` to a temporary, left to right, whenever two operands of
one expression both hold one, inside a GNU statement expression that stays
where the expression was written
(compiler/parse/back/tgt/c/emit/prog/code/expr/atom/order/). `c:order` is no
longer known apart.

Cases 05-10 pin the places where the obvious alternative, binding the
temporaries in statements emitted before the one that uses them, is wrong:

- `05` a `while` condition, which must run again every iteration
- `06` an `else if` condition, which must run only when it is reached
- `07` the right operand of `&&` and `||`, which must not run when the left
  one decides the result
- `08` the elements of a list literal
- `09` an index assignment: list, then index, then value
- `10` arguments that wrap a call in an operator, and one that is itself a
  short-circuit

## A warning, paid for once

`01-operand-order` was briefly broken by the tool that swept this repository to
§7.1: it collapsed the two `bump(c)` calls into one binding, on the theory that
a repeated call is a repeated value. `id` has no way to say that a function is
free of effects, so nothing may assume it. The case went from `a=1 b=2` to
`a=1 b=1` and would have passed on every target, agreeing about the wrong
answer — which is exactly the failure this directory exists to catch, arriving
from the direction nobody was watching.
