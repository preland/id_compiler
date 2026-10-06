# Closures

`bind(NAME, v1, ..., vk)` (docs/SPEC.md 1.1.1): a function value that carries
copies of the values it fixes. Runs on all three targets, with the answer the
C target gives: scalars and strings by value, a list as a locked copy, a
closure and a plain function the same type.
