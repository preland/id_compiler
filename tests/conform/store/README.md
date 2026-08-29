Each case pins down one semantic question about `id`'s WORD/FLAT-STORE system.

- `01-alloc-nonzero` — `alloc` never hands out address 0 (0 is reserved for null); the first real allocation is 8.
- `02-store-size-grows` — `store_size()` reflects the store's high-water mark before and after an `alloc`.
- `03-poke8-peek8` — a single byte written with `poke8` reads back unchanged through `peek8`.
- `04-poke-round-trip-widths` — `poke16`/`poke32`/`poke64` each round-trip through the matching `peek` width.
- `05-endianness` — `poke32` of a known multi-byte value, read back one byte at a time with `peek8`, pins the store down as little-endian.
- `06-narrow-wide-crossing` — a narrow write (`poke8`) read back wide (`peek64`) shows only the low byte set; a wide write (`poke64`) read back narrow (`peek8`) shows only the low byte.
- `07-alloc-alignment` — every allocation base is 8-byte aligned: a 1-byte `alloc` is still followed by the next allocation 8 bytes later, and a `poke64` at each address doesn't corrupt its neighbor.
- `08-unsigned-vs-signed` — on a word whose top bit is set, `udiv`/`ult`/`ushr` disagree with the plain signed `/`, `<`, `>>` operators on the identical bit pattern.
- `09-mem-str-roundtrip` — `mem_of_str` followed by `str_of_mem` recovers the original string's bytes.
- `10-word-wraparound` — `word` arithmetic wraps at 64 bits (two's complement) rather than trapping or promoting.
