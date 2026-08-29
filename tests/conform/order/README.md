# Evaluation order

`docs/SPEC.md` §7. The operands of an operator, and the arguments of a call,
are evaluated **left to right**.

These cases are the ones where that is observable: two operands that both have
an effect, and an effect that the other operand can see. Every other expression
in the language gives the same answer whichever order it is evaluated in, which
is why this went unnoticed until a bit reader and a `pop` next to a `len` found
it.

## What §7.1 took away

There used to be a third case here, `03-argument-order`:

```
print(pair(step(c), step(c)));
```

It is no longer a program `id` accepts. §7.1 says a call may not be an argument
to a call, so **two calls can never be arguments of the same call** — and the
order in which a call's arguments are evaluated therefore cannot be observed at
all. The case was deleted rather than rewritten, because every rewrite of it
turns into two statements, and the order of two statements was never in
question.

What is left observable is operands: `bump(c) + bump(c)` is still legal, because
neither call is inside the other's argument list. So §7 now says something about
operators and something vacuous about arguments, and these three cases are the
whole of the part that can be checked.

That also narrows S11. The C target's non-conformance was found through a call's
arguments; what remains to be proved is whether it holds for `+`, which C also
leaves unsequenced.

## A warning, paid for once

`01-operand-order` was briefly broken by the tool that swept this repository to
§7.1: it collapsed the two `bump(c)` calls into one binding, on the theory that
a repeated call is a repeated value. `id` has no way to say that a function is
free of effects, so nothing may assume it. The case went from `a=1 b=2` to
`a=1 b=1` and would have passed on every target, agreeing about the wrong
answer — which is exactly the failure this directory exists to catch, arriving
from the direction nobody was watching.
