#!/usr/bin/env bash
# Build the kernel: the runtime and the kernel through the LLVM target, the
# boot stub with clang's assembler, and ld.lld over the linker script.
#
# Nothing here compiles C. clang appears twice -- once as an assembler for the
# boot stub, once as an LLVM IR compiler -- and never as a C compiler.
set -eu
cd "$(dirname "$0")/.."
OUT="${1:-build/kernel.elf}"
TRIPLE=x86_64-unknown-none
mkdir -p build

./bin/idc runtime --no-std --runtime --triple "$TRIPLE" -o build/runtime.o
./bin/idc ../kernel/prog --no-std --freestanding --triple "$TRIPLE" -o build/kernel.o
clang -target "$TRIPLE" -ffreestanding -c ../kernel/boot/boot.S -o build/boot.o
clang -target "$TRIPLE" -ffreestanding -c ../kernel/boot/isr.S -o build/isr.o
ld.lld -n -T ../kernel/boot/kernel.ld build/boot.o build/isr.o build/runtime.o build/kernel.o -o "$OUT"
echo "built $OUT ($(wc -c < "$OUT") bytes)"
