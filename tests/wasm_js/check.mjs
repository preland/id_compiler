// What idc/tests/wasm_js.sh runs under node after it has built the fixtures
// into the directory given as argv[2]. Each check prints "PASS: ..." or
// "FAIL: ..." and the script exits 1 if any failed.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const dir = path.resolve(process.argv[2]);
let failed = 0;
const check = async (name, fn) => {
  try {
    await fn();
    console.log("PASS: " + name);
  } catch (e) {
    failed++;
    console.log("FAIL: " + name + " -- " + String(e.message).split("\n")[0]);
  }
};
const mod = (name) => import(pathToFileURL(path.join(dir, name + ".mjs")).href);

const lib = await mod("lib");
const text = (bytes) => new TextDecoder().decode(bytes);

await check("a string, an int and an int[] cross the boundary, through a JS native each", async () => {
  const m = await lib.load();
  assert.equal(m.shout("hi"), "HI!?");
  assert.equal(m.twice(21), 43);
  assert.deepEqual(m.squares(4), [0, 1, 4, 9, 0]);
});

await check("a JS native that returns a string hands id a real id string (length header set)", async () => {
  const m = await lib.load();
  assert.equal(m.shout("a longer string than the others"), "A LONGER STRING THAN THE OTHERS!?");
});

await check("exactly the functions conf.id's lib_exports names are bound, a subdirectory's measure among them", async () => {
  const d = fs.readFileSync(path.join(dir, "lib.d.ts"), "utf8");
  for (const f of ["shout", "twice", "squares", "measure"]) assert.match(d, new RegExp("\\b" + f + "\\("));
  for (const f of ["hidden", "peekat", "halve"]) assert.doesNotMatch(d, new RegExp("\\b" + f + "\\("));
  const m = await lib.load();
  assert.equal(m.measure("abc"), 4);
});

await check("--exports all binds the subdirectory's functions too", async () => {
  const all = await mod("liball");
  const m = await all.load();
  assert.equal(m.hidden(3), 21);
  assert.equal(m.halve(9, 3), 103);
  assert.equal(typeof m.shout, "function");
});

await check("the generated .d.ts types every signature", () => {
  const d = fs.readFileSync(path.join(dir, "lib.d.ts"), "utf8");
  assert.match(d, /shout\(ws: string\): string;/);
  assert.match(d, /twice\(tn: number\): number;/);
  assert.match(d, /squares\(sn: number\): number\[\];/);
  assert.match(d, /export function load\(/);
  assert.match(d, /class IdTrap extends Error/);
});

await check("an argument of the wrong type is a TypeError or RangeError before id runs, and the instance lives on", async () => {
  const m = await lib.load();
  assert.throws(() => m.twice("3"), RangeError);
  assert.throws(() => m.twice(2 ** 31), RangeError);
  assert.throws(() => m.twice(1.5), RangeError);
  assert.throws(() => m.shout(7), TypeError);
  assert.throws(() => m.shout("a\0b"), /NUL/);
  assert.throws(() => m.twice(), /takes 1 argument/);
  assert.equal(m.twice(2), 5);
  assert.equal(m.alive, true);
});

const all = await mod("liball");
await check("a runtime trap (index out of bounds) surfaces as IdTrap with id's message, and kills the instance", async () => {
  const quiet = { stderr: () => {} };
  const m = await all.load(undefined, quiet);
  assert.equal(m.peekat([1, 2], 1), 11);
  let err;
  try {
    m.peekat([1, 2], 9);
  } catch (e) {
    err = e;
  }
  assert.ok(err instanceof all.IdTrap, "IdTrap");
  assert.equal(err.kind, "exit");
  assert.equal(err.code, 1);
  assert.match(err.message, /index 9 out of bounds \(len 2\)/);
  assert.equal(err.stderr, err.message);
  assert.equal(m.alive, false);
  assert.throws(() => m.hidden(1), /instance is dead/);
});

await check("division by zero is an IdTrap, not a wasm RuntimeError", async () => {
  const m = await all.load(undefined, { stderr: () => {} });
  assert.throws(() => m.halve(1, 0), (e) => e instanceof all.IdTrap && /division by zero/.test(e.message));
});

await check("fail(msg) is an IdTrap carrying id's own line, and kills the instance", async () => {
  const m = await all.load(undefined, { stderr: () => {} });
  assert.equal(m.mustpos(3), 3);
  let err;
  try {
    m.mustpos(0);
  } catch (e) {
    err = e;
  }
  assert.ok(err instanceof all.IdTrap, "IdTrap");
  assert.equal(err.code, 1);
  assert.match(err.message, /id: mustpos: need a positive number, got 0/);
  assert.equal(m.alive, false);
});

await check("stderr the program wrote reaches the stderr sink exactly once", async () => {
  const seen = [];
  const m = await all.load(undefined, { stderr: (b) => seen.push(text(b)) });
  assert.throws(() => m.peekat([], 0));
  assert.equal(seen.join(""), "id: index 0 out of bounds (len 0)\n");
});

await check("two instances do not share state", async () => {
  const a = await lib.load();
  const b = await lib.load();
  assert.deepEqual(a.squares(2), b.squares(2));
  assert.notEqual(a.memory, b.memory);
});

const growth = (m, call, n) => {
  const at = () => m.memory.buffer.byteLength;
  for (let i = 0; i < n; i++) call();
  const a = at();
  for (let i = 0; i < 3 * n; i++) call();
  return at() - a;
};

await check("by default an argument the escape summary shows unkept is freed: memory growth from N to 4N calls is bounded", async () => {
  const everything = await mod("liball");
  const s = "x".repeat(4096);
  const m = await everything.load();
  assert.equal(m.measure(s), 4097);
  assert.ok(growth(m, () => m.measure(s), 1000) < 1048576, "the default kept growing");
});

await check("freeArgs: false keeps the old behaviour: the same calls grow memory", async () => {
  const everything = await mod("liball");
  const s = "x".repeat(4096);
  const m = await everything.load(undefined, { freeArgs: false });
  assert.equal(m.measure(s), 4097);
  assert.ok(growth(m, () => m.measure(s), 1000) > 4 * 1048576, "freeArgs: false did not grow");
});

await check("an argument the summary says is kept (it reaches a native) is not freed, and the answers stay right", async () => {
  const src = fs.readFileSync(path.join(dir, "liball.mjs"), "utf8");
  assert.match(src, /"shout":\["1",/);
  assert.match(src, /"measure":\["0",/);
  const everything = await mod("liball");
  const m = await everything.load();
  const s = "y".repeat(4096);
  for (let i = 0; i < 2000; i++) assert.equal(m.shout(s + i), s.toUpperCase() + i + "!?");
  assert.ok(growth(m, () => m.shout(s), 500) > 4 * 1048576, "the kept argument was freed");
});


await check("a backend nothing reaches is not bundled and costs no import", async () => {
  const src = fs.readFileSync(path.join(dir, "nobe.mjs"), "utf8");
  assert.doesNotMatch(src, /jsx_twice/);
  assert.doesNotMatch(src, /idw_be_jsx/);
  const m = await (await mod("nobe")).load();
  assert.equal(m.plain(1), 6);
  assert.deepEqual(WebAssembly.Module.imports(new WebAssembly.Module(fs.readFileSync(path.join(dir, "nobe.wasm")))).filter((i) => i.module === "env"), []);
});

const cmd = await mod("cmd");
await check("a program with main runs under run(): stdin, argv, stdout and exit status", async () => {
  const out = [];
  const m = await cmd.load(undefined, { stdin: "line one\nline two\n", stdout: (b) => out.push(text(b)), clock: () => 777 });
  const code = m.run(["prog", "arg1"]);
  assert.equal(code, 2);
  assert.equal(out.join(""), "line one|arg1|777\n");
});

await check("the clock option is what ticks() reads, and a real clock moves", async () => {
  let now = 1000;
  const out = [];
  const m = await cmd.load(undefined, { stdin: "x\n", stdout: (b) => out.push(text(b)), clock: () => (now += 5) });
  m.run(["p", "q"]);
  assert.match(out.join(""), /^x\|q\|10\d\d\n$/);
  const real = [];
  const m2 = await cmd.load(undefined, { stdin: "x\n", stdout: (b) => real.push(text(b)) });
  m2.run(["p", "q"]);
  assert.match(real.join(""), /^x\|q\|\d+\n$/);
});

await check("a library module refuses run(), and a command module has no bound functions", async () => {
  const m = await lib.load();
  assert.throws(() => m.run(), /library/);
});

const bytesLib = await mod("bytes");

await check("a bytes argument and result cross as a copied Uint8Array, a 0 and a 255 included", async () => {
  const m = await bytesLib.load();
  const sent = new Uint8Array([0, 7, 255]);
  const got = m.frame(sent);
  assert.ok(got instanceof Uint8Array);
  assert.deepEqual(Array.from(got), [0, 7, 255, 255, 0]);
  assert.deepEqual(Array.from(sent), [0, 7, 255]);
  assert.notEqual(got.buffer, m.raw.memory.buffer);
  assert.equal(m.weight(new Uint8Array([0, 255, 0, 255])), 510);
  assert.deepEqual(Array.from(m.frame(new Uint8Array(0))), [255, 0]);
  assert.throws(() => m.frame([1, 2]), /Uint8Array/);
});

process.exit(failed ? 1 : 0);
