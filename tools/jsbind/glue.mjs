// The JavaScript half of an id program built with `idc --target wasm`.
//
// idc/tools/jsbind/gen.mjs copies this file into <name>.mjs, replacing the
// three lines that end in `//@gen` with what this build knows (its name, the
// signatures of its public functions, and which backend supplies each native),
// and appends the backends' own modules after it. Nothing here is specific to
// one program, so it is also what `node --test` runs against in
// idc/tests/wasm_js.sh. docs/INTEROP.md, "id and JavaScript", is the contract.

const IDW_NAME = "idw"; //@gen NAME
const IDW_SIGS = {}; //@gen SIGS
const IDW_NATIVES = {}; //@gen NATIVES
const IDW_BACKENDS_BY_NAME = {}; //@gen BACKENDS

const IS_NODE = typeof process !== "undefined" && !!(process.versions && process.versions.node);
const enc = new TextEncoder();
const dec = new TextDecoder();

export class IdTrap extends Error {
  constructor(message, kind, code, stderr) {
    super(message);
    this.name = "IdTrap";
    this.kind = kind;
    this.code = code;
    this.stderr = stderr;
  }
}

async function nodeMod(name) {
  return await import(/* webpackIgnore: true */ /* @vite-ignore */ name);
}

async function wasmBytes(source) {
  if (source === undefined) source = new URL(IDW_NAME + ".wasm", import.meta.url);
  if (source instanceof WebAssembly.Module || ArrayBuffer.isView(source) || source instanceof ArrayBuffer) return source;
  if (typeof Response !== "undefined" && source instanceof Response) return await source.arrayBuffer();
  const href = source instanceof URL ? source.href : String(source);
  if (IS_NODE && !/^https?:/.test(href)) {
    const url = await nodeMod("node:url");
    const path = /^file:/.test(href) ? url.fileURLToPath(href) : href;
    return (await nodeMod("node:fs/promises")).readFile(path);
  }
  const res = await fetch(href);
  if (!res.ok) throw new Error("id: cannot fetch " + href + " (" + res.status + ")");
  return await res.arrayBuffer();
}

function nodeWrite(nodeFs, fd) {
  return (bytes) => {
    let off = 0;
    while (off < bytes.length) {
      try {
        off += nodeFs.writeSync(fd, bytes, off, bytes.length - off);
      } catch (e) {
        if (e.code !== "EAGAIN") throw e;
      }
    }
  };
}

function lineSink(log) {
  let pending = "";
  const d = new TextDecoder();
  return (bytes) => {
    pending += d.decode(bytes, { stream: true });
    let nl;
    while ((nl = pending.indexOf("\n")) >= 0) {
      log(pending.slice(0, nl));
      pending = pending.slice(nl + 1);
    }
  };
}

function stdinSource(spec, nodeFs) {
  if (typeof spec === "function") return spec;
  if (typeof spec === "string" || spec instanceof Uint8Array) {
    const all = typeof spec === "string" ? enc.encode(spec) : spec;
    let at = 0;
    return (n) => {
      const out = all.subarray(at, at + n);
      at += out.length;
      return out;
    };
  }
  if (nodeFs) {
    return (n) => {
      const buf = new Uint8Array(n);
      for (;;) {
        try {
          return buf.subarray(0, nodeFs.readSync(0, buf, 0, n, null));
        } catch (e) {
          if (e.code === "EOF") return new Uint8Array(0);
          if (e.code !== "EAGAIN") throw e;
        }
      }
    };
  }
  return () => new Uint8Array(0);
}

const ERRNO = { EPERM: 1, ENOENT: 2, EIO: 5, EBADF: 9, EACCES: 13, EEXIST: 17, ENOTDIR: 20, EISDIR: 21, EINVAL: 22, EMFILE: 24, EFBIG: 27, ENOSPC: 28, ENAMETOOLONG: 36, ENOSYS: 38, ENOTEMPTY: 39 };

export function errnoOf(e) {
  if (typeof e.errno === "number") return Math.abs(e.errno);
  return ERRNO[e.code] || ERRNO.EIO;
}

function memNode(isDir, mode) {
  return { dir: isDir, mode, mtimeMs: Date.now(), data: new Uint8Array(0), size: 0, kids: isDir ? new Map() : null };
}

function memErr(code, op, path) {
  const e = new Error(code + ": " + op + " '" + path + "'");
  e.code = code;
  e.errno = -ERRNO[code];
  return e;
}

// A Node-fs-shaped, in-memory file system: the same synchronous subset the fs
// backend module (idstd/host/io/fs/fs.mjs) calls, for a browser or for a test
// that must not touch the disk. Paths are absolute and POSIX.
export function createMemFs(files) {
  const root = memNode(true, 0o777);
  const fds = new Map();
  let nextFd = 3;
  const split = (p) => p.split("/").filter((s) => s !== "" && s !== ".");
  const find = (p, op) => {
    let n = root;
    for (const part of split(p)) {
      if (!n.dir) throw memErr("ENOTDIR", op, p);
      n = n.kids.get(part);
      if (!n) throw memErr("ENOENT", op, p);
    }
    return n;
  };
  const parentOf = (p, op) => {
    const parts = split(p);
    const last = parts.pop();
    let n = root;
    for (const part of parts) {
      n = n.kids.get(part);
      if (!n) throw memErr("ENOENT", op, p);
      if (!n.dir) throw memErr("ENOTDIR", op, p);
    }
    return [n, last];
  };
  const stat = (n) => ({ size: n.dir ? 4096 : n.size,mtimeMs: n.mtimeMs, mode: n.mode, isDirectory: () => n.dir, isFile: () => !n.dir });
  const api = {
    statSync: (p) => stat(find(p, "stat")),
    existsSync: (p) => {
      try {
        find(p, "stat");
        return true;
      } catch {
        return false;
      }
    },
    mkdirSync: (p) => {
      const [dir, name] = parentOf(p, "mkdir");
      if (!name || dir.kids.has(name)) throw memErr("EEXIST", "mkdir", p);
      dir.kids.set(name, memNode(true, 0o777));
    },
    readdirSync: (p) => {
      const n = find(p, "scandir");
      if (!n.dir) throw memErr("ENOTDIR", "scandir", p);
      return [...n.kids.keys()];
    },
    openSync: (p, flags) => {
      const [dir, name] = parentOf(p, "open");
      let n = name ? dir.kids.get(name) : dir;
      const create = /[wa]/.test(flags);
      if (!n && !create) throw memErr("ENOENT", "open", p);
      if (n && n.dir) throw memErr("EISDIR", "open", p);
      if (n && flags.includes("x")) throw memErr("EEXIST", "open", p);
      if (!n) dir.kids.set(name, (n = memNode(false, 0o666)));
      if (flags[0] === "w") n.size = 0;
      const fd = nextFd++;
      fds.set(fd, { n, pos: flags[0] === "a" ? n.size : 0, append: flags[0] === "a", write: /[wa+]/.test(flags), read: flags[0] === "r" || flags.includes("+") });
      return fd;
    },
    closeSync: (fd) => {
      if (!fds.delete(fd)) throw memErr("EBADF", "close", String(fd));
    },
    readSync: (fd, buf, off, len, pos) => {
      const f = fds.get(fd);
      if (!f || !f.read) throw memErr("EBADF", "read", String(fd));
      const at = pos == null ? f.pos : pos;
      const got = Math.max(0, Math.min(len, f.n.size - at));
      buf.set(f.n.data.subarray(at, at + got), off);
      if (pos == null) f.pos += got;
      return got;
    },
    writeSync: (fd, buf, off, len, pos) => {
      const f = fds.get(fd);
      if (!f || !f.write) throw memErr("EBADF", "write", String(fd));
      const at = f.append ? f.n.size : pos == null ? f.pos : pos;
      if (at + len > f.n.data.length) {
        const bigger = new Uint8Array(Math.max(at + len, f.n.data.length * 2));
        bigger.set(f.n.data.subarray(0, f.n.size));
        f.n.data = bigger;
      }
      f.n.data.set(buf.subarray(off, off + len), at);
      f.n.size = Math.max(f.n.size, at + len);
      if (pos == null) f.pos = at + len;
      f.n.mtimeMs = Date.now();
      return len;
    },
    unlinkSync: (p) => {
      const [dir, name] = parentOf(p, "unlink");
      const n = dir.kids.get(name);
      if (!n) throw memErr("ENOENT", "unlink", p);
      if (n.dir) throw memErr("EISDIR", "unlink", p);
      dir.kids.delete(name);
    },
    rmdirSync: (p) => {
      const [dir, name] = parentOf(p, "rmdir");
      const n = dir.kids.get(name);
      if (!n) throw memErr("ENOENT", "rmdir", p);
      if (!n.dir) throw memErr("ENOTDIR", "rmdir", p);
      if (n.kids.size) throw memErr("ENOTEMPTY", "rmdir", p);
      dir.kids.delete(name);
    },
    rmSync: (p) => {
      const [dir, name] = parentOf(p, "rm");
      dir.kids.delete(name);
    },
    renameSync: (a, b) => {
      const [da, na] = parentOf(a, "rename");
      const n = da.kids.get(na);
      if (!n) throw memErr("ENOENT", "rename", a);
      const [db, nb] = parentOf(b, "rename");
      const old = db.kids.get(nb);
      if (old && old.dir !== n.dir) throw memErr(old.dir ? "EISDIR" : "ENOTDIR", "rename", b);
      da.kids.delete(na);
      db.kids.set(nb, n);
    },
    chmodSync: (p, mode) => {
      find(p, "chmod").mode = mode;
    },
  };
  api.mkdirSync("/tmp");
  for (const [p, v] of Object.entries(files || {})) {
    const parts = split(p);
    for (let i = 1; i < parts.length; i++) {
      const d = "/" + parts.slice(0, i).join("/");
      if (!api.existsSync(d)) api.mkdirSync(d);
    }
    const fd = api.openSync(p, "w");
    const bytes = typeof v === "string" ? enc.encode(v) : v;
    api.writeSync(fd, bytes, 0, bytes.length, null);
    api.closeSync(fd);
  }
  return api;
}

function wasiImports(h, imports) {
  const dv = () => h.dv;
  const envList = () => Object.entries(h.env).map(([k, v]) => enc.encode(k + "=" + v + "\0"));
  const argList = () => (h.opts.args || [IDW_NAME]).map((a) => enc.encode(a + "\0"));
  const sizes = (list, cntp, sizep) => {
    dv().setUint32(cntp, list.length, true);
    dv().setUint32(sizep, list.reduce((a, b) => a + b.length, 0), true);
    return 0;
  };
  const fill = (list, ptrs, buf) => {
    for (const item of list) {
      dv().setUint32(ptrs, buf, true);
      h.u8.set(item, buf);
      ptrs += 4;
      buf += item.length;
    }
    return 0;
  };
  const clock = (id) => {
    if (h.opts.clock) return BigInt(Math.round(h.opts.clock() * 1e6));
    if (id === 0) return BigInt(Math.round((performance.timeOrigin + performance.now()) * 1e6));
    if (id >= 2 && IS_NODE) return BigInt(Math.round((process.cpuUsage().user + process.cpuUsage().system) * 1e3));
    return BigInt(Math.round(performance.now() * 1e6));
  };
  const sleeper = typeof SharedArrayBuffer !== "undefined" ? new Int32Array(new SharedArrayBuffer(4)) : null;
  const sleep = (ms) => {
    if (h.opts.sleep) return h.opts.sleep(ms);
    if (ms <= 0) return;
    if (sleeper) {
      try {
        Atomics.wait(sleeper, 0, 0, ms);
        return;
      } catch {}
    }
    const end = performance.now() + ms;
    while (performance.now() < end);
  };
  const wasi = {
    args_sizes_get: (c, s) => sizes(argList(), c, s),
    args_get: (p, b) => fill(argList(), p, b),
    environ_sizes_get: (c, s) => sizes(envList(), c, s),
    environ_get: (p, b) => fill(envList(), p, b),
    clock_res_get: (id, p) => (dv().setBigUint64(p, 1000n, true), 0),
    clock_time_get: (id, prec, p) => (dv().setBigUint64(p, clock(id), true), 0),
    fd_write: (fd, iovs, n, outp) => {
      if (fd !== 1 && fd !== 2) return 8;
      const parts = [];
      let total = 0;
      for (let i = 0; i < n; i++) {
        const p = dv().getUint32(iovs + 8 * i, true);
        const l = dv().getUint32(iovs + 8 * i + 4, true);
        parts.push(h.u8.slice(p, p + l));
        total += l;
      }
      const bytes = parts.length === 1 ? parts[0] : concat(parts, total);
      h.write(fd, bytes);
      dv().setUint32(outp, total, true);
      return 0;
    },
    fd_read: (fd, iovs, n, outp) => {
      if (fd !== 0) return 8;
      let total = 0;
      for (let i = 0; i < n; i++) {
        const p = dv().getUint32(iovs + 8 * i, true);
        const l = dv().getUint32(iovs + 8 * i + 4, true);
        const got = h.stdin(l);
        h.u8.set(got, p);
        total += got.length;
        if (got.length < l) break;
      }
      dv().setUint32(outp, total, true);
      return 0;
    },
    fd_fdstat_get: (fd, p) => {
      if (fd > 2) return 8;
      dv().setUint8(p, 2);
      dv().setUint16(p + 2, 0, true);
      dv().setBigUint64(p + 8, 0xffffffffffffffffn, true);
      dv().setBigUint64(p + 16, 0xffffffffffffffffn, true);
      return 0;
    },
    fd_seek: (fd) => (fd <= 2 ? 70 : 8),
    fd_close: (fd) => (fd <= 2 ? 0 : 8),
    fd_prestat_get: () => 8,
    fd_prestat_dir_name: () => 8,
    sched_yield: () => 0,
    random_get: (p, n) => {
      for (let off = 0; off < n; off += 65536) crypto.getRandomValues(h.u8.subarray(p + off, p + Math.min(n, off + 65536)));
      return 0;
    },
    poll_oneoff: (inp, outp, nsubs, evp) => {
      let wait = Infinity;
      for (let i = 0; i < nsubs; i++) {
        const s = inp + 48 * i;
        if (dv().getUint8(s + 8) !== 0) wait = 0;
        else {
          const t = Number(dv().getBigUint64(s + 24, true)) / 1e6;
          const abs = dv().getUint16(s + 40, true) & 1;
          wait = Math.min(wait, abs ? t - Number(clock(dv().getUint32(s + 16, true))) / 1e6 : t);
        }
      }
      sleep(wait);
      dv().setBigUint64(outp, dv().getBigUint64(inp, true), true);
      dv().setUint16(outp + 8, 0, true);
      dv().setUint8(outp + 10, dv().getUint8(inp + 8));
      dv().setUint32(evp, 1, true);
      return 0;
    },
    proc_exit: (code) => {
      throw new IdTrap(h.tail() || "id: exit " + code, "exit", code, h.tail());
    },
  };
  const out = {};
  for (const imp of imports) if (imp.module === "wasi_snapshot_preview1") out[imp.name] = wasi[imp.name] || (() => 52);
  return out;
}

function concat(parts, total) {
  const out = new Uint8Array(total);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

function lowerer(type, fname, pname, h) {
  switch (type) {
    case "int":
      return (v) => {
        if (typeof v !== "number" || !Number.isInteger(v) || v < -2147483648 || v > 2147483647) {
          throw new RangeError(fname + ": argument '" + pname + "' must be an integer in the int range (-2^31 .. 2^31-1), got " + String(v));
        }
        return v;
      };
    case "float":
      return (v) => {
        if (typeof v !== "number") throw new TypeError(fname + ": argument '" + pname + "' must be a number, got " + typeof v);
        return v;
      };
    case "word":
      return (v) => {
        if (typeof v === "number" && Number.isInteger(v)) return BigInt(v);
        if (typeof v !== "bigint") throw new TypeError(fname + ": argument '" + pname + "' must be a bigint, got " + typeof v);
        return BigInt.asIntN(64, v);
      };
    case "string":
      return (v) => h.lowerString(v, fname, pname);
    case "bytes":
      return (v) => h.lowerBytes(v, fname, pname);
    case "int[]":
    case "float[]":
    case "string[]":
      return (v) => h.lowerList(type.slice(0, -2), v, fname, pname);
    default:
      throw new Error("no marshalling for type " + type);
  }
}

function lifter(type, h) {
  switch (type) {
    case "int":
    case "float":
      return (v) => v;
    case "word":
      return (v) => v;
    case "void":
      return () => undefined;
    case "string":
      return (p) => h.liftString(p);
    case "bytes":
      return (p) => h.liftBytes(p);
    case "int[]":
    case "float[]":
    case "string[]":
      return (p) => h.liftList(type.slice(0, -2), p);
    default:
      throw new Error("no marshalling for type " + type);
  }
}

// load(source?, options?) -> the instance.
//   source   a URL, path, Response, bytes or WebAssembly.Module; by default the
//            <name>.wasm beside this file.
//   options  stdout, stderr: (Uint8Array) => void;  stdin: string | bytes | (n) => bytes;
//            args: string[];  env: object;  fs: node fs, createMemFs(), or "memory";
//            clock: () => ms;  sleep: (ms) => void;  run: (cmd) => status
export async function load(source, options) {
  const opts = options || {};
  const nodeFs = IS_NODE ? await nodeMod("node:fs") : null;
  const childProcess = IS_NODE ? await nodeMod("node:child_process") : null;
  const module = source instanceof WebAssembly.Module ? source : await WebAssembly.compile(await wasmBytes(source));
  const imports = WebAssembly.Module.imports(module);
  const st = { dead: false, closers: [], tail: [] };
  let exps = null;
  let mem = null;
  let bufNow = null;
  let u8 = null;
  let dvNow = null;
  const view = () => {
    if (mem.buffer !== bufNow) {
      bufNow = mem.buffer;
      u8 = new Uint8Array(bufNow);
      dvNow = new DataView(bufNow);
    }
  };
  const sinkOf = (fd) => {
    const user = fd === 1 ? opts.stdout : opts.stderr;
    if (user) return user;
    if (nodeFs) return nodeWrite(nodeFs, fd);
    return lineSink(fd === 1 ? console.log : console.error);
  };
  const outSink = sinkOf(1);
  const errSink = sinkOf(2);
  const h = {
    opts,
    nodeFs,
    env: opts.env || (IS_NODE ? { ...process.env } : {}),
    stdin: stdinSource(opts.stdin, nodeFs),
    run: opts.run || (IS_NODE ? (cmd) => {
      const r = childProcess.spawnSync("/bin/sh", ["-c", cmd], { stdio: "inherit" });
      return r.status === null ? -1 : r.status << 8;
    } : null),
    get u8() {
      view();
      return u8;
    },
    get dv() {
      view();
      return dvNow;
    },
    tail: () => st.tail.join("").trim().split("\n").filter(Boolean).slice(-1)[0] || "",
    write: (fd, bytes) => {
      if (fd === 2) {
        st.tail.push(dec.decode(bytes));
        if (st.tail.length > 8) st.tail.shift();
        errSink(bytes);
      } else outSink(bytes);
    },
    onClose: (fn) => st.closers.push(fn),
    flushStdout: () => exps.idw_flush(),
    str: (p) => {
      view();
      const n = dvNow.getUint32(p - 4, true);
      return dec.decode(u8.subarray(p, p + n));
    },
    span: (addr, n) => exps.idw_span(BigInt(addr), BigInt(n)),
    release: (type, p) => {
      if (type === "string") exps.idw_release_str(p);
      else if (type === "bytes") exps.idw_release_bytes(p);
      else {
        if (type === "string[]") {
          const l = h.listSpan(p);
          for (let i = 0; i < l.len; i++) exps.idw_release_str(h.dv.getUint32(l.data + 8 * i, true));
        }
        exps.idw_release_list(p);
      }
    },
    listSpan: (p) => {
      view();
      return { len: dvNow.getInt32(p, true), data: dvNow.getUint32(p + 8, true) };
    },
    lowerString: (s, fname, pname) => {
      if (typeof s !== "string") throw new TypeError(fname + ": argument '" + pname + "' must be a string, got " + typeof s);
      if (s.indexOf("\0") >= 0) throw new TypeError(fname + ": argument '" + pname + "' contains a NUL character; an id string cannot hold one (use the flat store for binary data)");
      const n = s.length;
      const p = exps.idw_str(n);
      view();
      const r = enc.encodeInto(s, u8.subarray(p, p + n));
      if (r.read === n && r.written === n) return p;
      exps.idw_release_str(p);
      const b = enc.encode(s);
      const q = exps.idw_str(b.length);
      view();
      u8.set(b, q);
      return q;
    },
    lowerBytes: (v, fname, pname) => {
      if (!(v instanceof Uint8Array)) throw new TypeError(fname + ": argument '" + pname + "' must be a Uint8Array, got " + typeof v);
      const p = exps.idw_bytes(v.length);
      view();
      u8.set(v, dvNow.getUint32(p + 8, true));
      return p;
    },
    liftBytes: (p) => {
      view();
      const at = dvNow.getUint32(p + 8, true);
      return u8.slice(at, at + dvNow.getInt32(p, true));
    },
    liftString: (p) => {
      if (p === 0) return "";
      view();
      return dec.decode(u8.subarray(p, p + dvNow.getUint32(p - 4, true)));
    },
    lowerList: (elem, arr, fname, pname) => {
      if (!Array.isArray(arr) && !ArrayBuffer.isView(arr)) throw new TypeError(fname + ": argument '" + pname + "' must be an array, got " + typeof arr);
      const n = arr.length;
      const l = exps.idw_list(n);
      if (elem === "string") {
        for (let i = 0; i < n; i++) {
          const cell = h.lowerString(arr[i], fname, pname + "[" + i + "]");
          view();
          const at = dvNow.getUint32(l + 8, true) + 8 * i;
          dvNow.setUint32(at, cell, true);
          dvNow.setUint32(at + 4, 0, true);
        }
        return l;
      }
      view();
      const data = dvNow.getUint32(l + 8, true);
      if (elem === "float") {
        const cells = new Float64Array(bufNow, data, n);
        for (let i = 0; i < n; i++) {
          const v = arr[i];
          if (typeof v !== "number") throw new TypeError(fname + ": " + pname + "[" + i + "] must be a number, got " + typeof v);
          cells[i] = v;
        }
      } else {
        const cells = new Int32Array(bufNow, data, 2 * n);
        for (let i = 0; i < n; i++) {
          const v = arr[i];
          if (typeof v !== "number" || (v | 0) !== v) throw new RangeError(fname + ": " + pname + "[" + i + "] must be an integer in the int range (-2^31 .. 2^31-1), got " + String(v));
          cells[2 * i] = v;
          cells[2 * i + 1] = v >> 31;
        }
      }
      return l;
    },
    liftList: (elem, p) => {
      view();
      const n = dvNow.getInt32(p, true);
      const data = dvNow.getUint32(p + 8, true);
      if (elem === "float") return Array.from(new Float64Array(bufNow, data, n));
      if (elem === "int") {
        const cells = new Int32Array(bufNow, data, 2 * n);
        const out = new Array(n);
        for (let i = 0; i < n; i++) out[i] = cells[2 * i];
        return out;
      }
      const out = new Array(n);
      for (let i = 0; i < n; i++) out[i] = h.liftString(dvNow.getUint32(data + 8 * i, true));
      return out;
    },
  };
  const be = {};
  const instImports = { wasi_snapshot_preview1: wasiImports(h, imports), env: {} };
  const handlers = {};
  for (const imp of imports) {
    if (imp.module === "env") {
      const native = imp.name.replace(/^id_/, "");
      if (!IDW_NATIVES[native]) throw new Error("id: the module imports env." + imp.name + " but no backend module for '" + native + "' was bundled; rebuild with a backend.id that declares wasm_js");
      instImports.env[imp.name] = (...a) => handlers[native](...a);
    }
  }
  const instance = await WebAssembly.instantiate(module, instImports);
  exps = instance.exports;
  mem = exps.memory;
  if (typeof exps.idw_abi !== "function") throw new Error("id: this wasm module has no idw_abi export; rebuild it with an idc that emits the JS binding shim");
  const abi = exps.idw_abi();
  if (abi !== (12 | (8 << 8) | (8 << 16) | (4 << 24))) throw new Error("id: runtime layout (0x" + abi.toString(16) + ") differs from what this glue reads (IdList 12 bytes, data at 8, 8-byte cells, 4-byte size_t); regenerate the bindings with the idc that built the wasm");
  const probe = exps.idw_list(1);
  if (h.dv.getUint32(probe + 8, true) % 8 !== 0) throw new Error("id: list cells are not 8-byte aligned in this module; regenerate the bindings with the idc that built the wasm");
  const fsOpt = opts.fs;
  h.fs = fsOpt === "memory" || (!fsOpt && !nodeFs) ? createMemFs() : fsOpt && fsOpt !== "node" ? fsOpt : nodeFs;
  h.raw = exps;
  for (const [native, name] of Object.entries(IDW_NATIVES)) {
    if (!be[name]) be[name] = IDW_BACKENDS_BY_NAME[name](h);
    handlers[native] = be[name][native];
    if (typeof handlers[native] !== "function") throw new Error("id: backend '" + name + "' declares no JS implementation of native '" + native + "'");
  }
  if (typeof exps._initialize === "function") exps._initialize();

  const api = {
    raw: exps,
    memory: mem,
    get alive() {
      return !st.dead;
    },
    dispose() {
      st.dead = true;
      const fns = st.closers.splice(0);
      for (const f of fns) f();
    },
    run(argv) {
      if (typeof exps._start !== "function") throw new Error("id: this module is a library (it has no main); call its functions instead");
      if (argv) h.opts.args = argv;
      try {
        exps._start();
        return 0;
      } catch (e) {
        st.dead = true;
        if (e instanceof IdTrap && e.kind === "exit") return e.code;
        throw wrap(e);
      }
    },
  };
  const wrap = (e) => {
    if (e instanceof IdTrap) return e;
    if (e instanceof WebAssembly.RuntimeError) return new IdTrap("id: " + e.message, "trap", 1, h.tail());
    if (e instanceof RangeError && /call stack/i.test(e.message)) return new IdTrap("id: stack overflow (recursion too deep)", "stack", 1, h.tail());
    return e;
  };
  const reserved = new Set(Object.keys(api));
  for (const [name, sig] of Object.entries(IDW_SIGS)) {
    const f = exps["id_" + name];
    if (typeof f !== "function") continue;
    const lows = sig.params.map(([pn, pt]) => lowerer(pt, name, pn, h));
    const lift = lifter(sig.ret, h);
    const n = lows.length;
    const freeArgs = opts.freeArgs === true || (Array.isArray(opts.freeArgs) && opts.freeArgs.includes(name));
    const owned = sig.params.map((p, i) => i).filter((i) => /^(string|bytes|int\[\]|float\[\]|string\[\])$/.test(sig.params[i][1]));
    const dead = () => new Error("id: the instance is dead (an earlier call trapped or exited, or dispose() ran); load a new one");
    const arity = () => new TypeError(name + " takes " + n + " argument(s)");
    const finish = (a, r) => {
      if (freeArgs) for (const i of owned) h.release(sig.params[i][1], a[i]);
      return r;
    };
    const fail = (e) => {
      st.dead = true;
      return wrap(e);
    };
    let bound;
    if (n === 0) {
      bound = function () {
        if (arguments.length !== 0) throw arity();
        if (st.dead) throw dead();
        if (st.tail.length) st.tail.length = 0;
        try {
          return lift(f());
        } catch (e) {
          throw fail(e);
        }
      };
    } else if (n === 1 && !freeArgs) {
      const l0 = lows[0];
      bound = function (a0) {
        if (arguments.length !== 1) throw arity();
        if (st.dead) throw dead();
        if (st.tail.length) st.tail.length = 0;
        const w0 = l0(a0);
        try {
          return lift(f(w0));
        } catch (e) {
          throw fail(e);
        }
      };
    } else if (n === 2 && !freeArgs) {
      const [l0, l1] = lows;
      bound = function (a0, a1) {
        if (arguments.length !== 2) throw arity();
        if (st.dead) throw dead();
        if (st.tail.length) st.tail.length = 0;
        const w0 = l0(a0);
        const w1 = l1(a1);
        try {
          return lift(f(w0, w1));
        } catch (e) {
          throw fail(e);
        }
      };
    } else {
      bound = function (...args) {
        if (args.length !== n) throw arity();
        if (st.dead) throw dead();
        if (st.tail.length) st.tail.length = 0;
        const a = new Array(n);
        for (let i = 0; i < n; i++) a[i] = lows[i](args[i]);
        try {
          return finish(a, lift(f(...a)));
        } catch (e) {
          throw fail(e);
        }
      };
    }
    api[reserved.has(name) ? name + "_" : name] = bound;
  }
  return api;
}
