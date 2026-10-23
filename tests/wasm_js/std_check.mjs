// The fs and env backends (idstd host/io/fs/fs.mjs, host/os/env/env.mjs) answering
// real idstd programs from JS. argv[2] is the directory holding std.mjs.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const dir = path.resolve(process.argv[2]);
const std = await import(pathToFileURL(path.join(dir, "std.mjs")).href);
let failed = 0;
const check = async (name, fn) => {
  try {
    await fn();
    console.log("PASS: " + name);
  } catch (e) {
    failed++;
    console.log("FAIL: " + name + " -- " + String(e.stack || e.message).split("\n").slice(0, 3).join(" | "));
  }
};

await check("slurp reads a real file through Node's fs", async () => {
  const f = path.join(dir, "data.txt");
  fs.writeFileSync(f, "from disk\nsecond line\n");
  const m = await std.load();
  assert.equal(m.slurp(f), "from disk\nsecond line\n");
  assert.equal(m.slurp(path.join(dir, "missing.txt")), "");
  m.dispose();
});

await check("env natives read the environment the host gives, not the real one", async () => {
  const m = await std.load(undefined, { env: { IDW_X: "value12" } });
  assert.equal(m.envlen("IDW_X"), 7);
  assert.equal(m.envlen("IDW_NOT_SET"), -1);
  const real = await std.load();
  assert.equal(real.envlen("HOME"), (process.env.HOME || "").length);
});

await check("a file written and read back by id, on the real disk, in /tmp", async () => {
  const m = await std.load();
  assert.equal(m.roundtrip("hello world"), "hello world11");
  assert.equal(m.roundtrip("multi\nline"), "multi\nline10");
  m.dispose();
});

await check("fs_load_bytes and fs_save_bytes carry 0 and 255 through the fs backend", async () => {
  const m = await std.load();
  assert.deepEqual(Array.from(m.bytesrt(Uint8Array.from([0, 255, 0, 7, 128]))), [0, 255, 0, 7, 128]);
  assert.equal(m.bytesrt(new Uint8Array(0)).length, 0);
  m.dispose();
});

await check("fs_drop_exit paths are gone after dispose()", async () => {
  const own = fs.mkdtempSync("/tmp/idwo");
  try {
    const mine = () => fs.readdirSync(own).length;
    const m = await std.load(undefined, { env: { ...process.env, TMPDIR: own } });
    m.roundtrip("x");
    m.scratch("y");
    assert.equal(mine(), 2, "created " + mine());
    m.dispose();
    assert.equal(mine(), 0);
  } finally {
    fs.rmSync(own, { recursive: true, force: true });
  }
});

await check("the same program on an in-memory file system never touches the disk", async () => {
  const files = std.createMemFs({ "/data/in.txt": "memory text" });
  const m = await std.load(undefined, { fs: files, env: { ...process.env, TMPDIR: "/tmp" } });
  assert.equal(m.slurp("/data/in.txt"), "memory text");
  assert.equal(m.roundtrip("virtual"), "virtual7");
  assert.deepEqual(m.scratch("zz"), ["f.txt", ""]);
  assert.equal(m.lsn("/data"), 2);
  assert.equal(fs.existsSync("/data/in.txt"), false);
});

await check("fs_list gives a directory's entries sorted, with / on directories", async () => {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), "idwl"));
  try {
    fs.mkdirSync(path.join(d, "b"));
    fs.writeFileSync(path.join(d, "a.txt"), "1");
    fs.writeFileSync(path.join(d, "c.txt"), "2");
    const m = await std.load();
    assert.equal(m.lsn(d), 4);
    assert.deepEqual(m.lsof(d), ["a.txt", "b/", "c.txt", ""]);
    m.dispose();
  } finally {
    fs.rmSync(d, { recursive: true, force: true });
  }
});

process.exit(failed ? 1 : 0);
