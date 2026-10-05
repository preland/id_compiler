// gen.mjs -- write <name>.mjs and <name>.d.ts beside an id-built <name>.wasm.
//
//   node gen.mjs --wasm FILE --glue glue.mjs --natives MAP [--out PREFIX] --src FILE...
//
// bin/idc runs it at the end of `--target wasm`. The module is glue.mjs with
// this build's facts written into its three `//@gen` lines and the JS module of
// every backend whose native the wasm actually imports appended; the .d.ts is
// the TypeScript view of the same signatures. The signatures are read from the
// --src files (the functions bin/idc exported) with a scanner, not a parser:
// a definition is `name(params) {`, its body is the balanced braces after it,
// and its type is the first word of the `} return TYPE ...;` that closes it
// (docs/PROJECT.md section 3 for `chain`). MAP lines are NATIVE TAB BACKEND TAB JSFILE.

import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);
const opt = { src: [] };
for (let i = 0; i < args.length; i += 2) {
  const k = args[i].replace(/^--/, "");
  if (k === "src") opt.src.push(args[i + 1]);
  else opt[k] = args[i + 1];
}
const die = (msg) => {
  console.error("idc: jsbind: " + msg);
  process.exit(1);
};
if (!opt.wasm || !opt.glue) die("usage: gen.mjs --wasm FILE --glue glue.mjs [--natives MAP] [--out PREFIX] --src FILE...");
const prefix = opt.out || opt.wasm.replace(/\.wasm$/, "");
const name = path.basename(prefix);

const isId = (c) => /[A-Za-z0-9_]/.test(c);

function matchClose(text, i, open, close) {
  let depth = 0;
  for (; i < text.length; i++) {
    const c = text[i];
    if (c === "/" && text[i + 1] === "/") while (i < text.length && text[i] !== "\n") i++;
    else if (c === '"') {
      i++;
      while (i < text.length && text[i] !== '"') i += text[i] === "\\" ? 2 : 1;
    } else if (c === open) depth++;
    else if (c === close && --depth === 0) return i + 1;
  }
  return -1;
}

function splitParams(inner) {
  const out = [];
  let depth = 0;
  let cur = "";
  for (const c of inner) {
    if (c === "(" || c === "[") depth++;
    if (c === ")" || c === "]") depth--;
    if (c === "," && depth === 0) {
      out.push(cur);
      cur = "";
    } else cur += c;
  }
  if (cur.trim()) out.push(cur);
  return out.map((p) => p.trim());
}

function scan(text, file) {
  const defs = [];
  let i = 0;
  let depth = 0;
  while (i < text.length) {
    const c = text[i];
    if (c === "/" && text[i + 1] === "/") {
      while (i < text.length && text[i] !== "\n") i++;
    } else if (c === '"') {
      i++;
      while (i < text.length && text[i] !== '"') i += text[i] === "\\" ? 2 : 1;
      i++;
    } else if (c === "{") {
      depth++;
      i++;
    } else if (c === "}") {
      depth--;
      i++;
    } else if (depth === 0 && /[A-Za-z_]/.test(c) && (i === 0 || !isId(text[i - 1]))) {
      let j = i;
      while (j < text.length && isId(text[j])) j++;
      const ident = text.slice(i, j);
      let k = j;
      while (text[k] === " " || text[k] === "\t") k++;
      i = j;
      if (text[k] !== "(" || ["chain", "given", "then", "native", "stdin", "timeout", "asm"].includes(ident)) continue;
      const close = matchClose(text, k, "(", ")");
      if (close < 0) continue;
      let q = close;
      while (/\s/.test(text[q] || "")) q++;
      if (text[q] !== "{") continue;
      const params = splitParams(text.slice(k + 1, close - 1));
      let end = matchClose(text, q, "{", "}");
      let ret = null;
      while (end > 0) {
        let r = end;
        while (/\s/.test(text[r] || "")) r++;
        if (text.startsWith("chain", r)) {
          const po = text.indexOf("(", r);
          const pc = matchClose(text, po, "(", ")");
          let b = pc;
          while (/\s/.test(text[b] || "")) b++;
          end = text[b] === "{" ? matchClose(text, b, "{", "}") : -1;
        } else {
          const m = /^return\s+([A-Za-z_][A-Za-z0-9_]*(?:\[\])*)/.exec(text.slice(r, r + 200));
          if (m) ret = m[1];
          end = -1;
          i = r;
        }
      }
      defs.push({ name: ident, params, ret, file, line: text.slice(0, k).split("\n").length });
    } else i++;
  }
  return defs;
}

const SUPPORTED = new Set(["int", "float", "word", "string", "int[]", "float[]", "string[]"]);
const TS = { int: "number", float: "number", word: "bigint", string: "string", void: "void", "int[]": "number[]", "float[]": "number[]", "string[]": "string[]" };
const TS_RESERVED = new Set(["break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "new", "null", "return", "super", "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while", "with", "yield", "let", "static", "implements", "interface", "package", "private", "protected", "public", "await", "async"]);

const wasmBytes = fs.readFileSync(opt.wasm);
const mod = new WebAssembly.Module(wasmBytes);
const exportNames = new Set(WebAssembly.Module.exports(mod).map((e) => e.name));
const imports = WebAssembly.Module.imports(mod);

const natMap = new Map();
if (opt.natives && fs.existsSync(opt.natives)) {
  for (const line of fs.readFileSync(opt.natives, "utf8").split("\n")) {
    if (!line) continue;
    const [native, backend, js] = line.split("\t");
    natMap.set(native, { backend, js });
  }
}

const defs = new Map();
for (const f of opt.src) for (const d of scan(fs.readFileSync(f, "utf8"), f)) if (!defs.has(d.name)) defs.set(d.name, d);

const sigs = {};
const skipped = [];
for (const e of exportNames) {
  if (!e.startsWith("id_") || ["id_alloc", "id_str_of_cstr", "id_store_span"].includes(e)) continue;
  const fn = e.slice(3);
  const d = defs.get(fn);
  if (!d) {
    skipped.push([fn, "no definition of it was found in the exported source files"]);
    continue;
  }
  const params = d.params.map((p) => {
    const m = /^([\s\S]+?)\s+([A-Za-z_][A-Za-z0-9_]*)$/.exec(p);
    return m ? [m[2], m[1].replace(/\s+/g, "")] : [p, "?"];
  });
  const bad = params.find(([, t]) => !SUPPORTED.has(t));
  if (bad) skipped.push([fn, "parameter '" + bad[0] + "' has type " + bad[1] + ", which does not cross the boundary (int, float, word, string and lists of int, float or string do)"]);
  else if (!d.ret || (d.ret !== "void" && !SUPPORTED.has(d.ret))) skipped.push([fn, "it returns " + d.ret + ", which does not cross the boundary"]);
  else sigs[fn] = { params, ret: d.ret, file: d.file, line: d.line };
}

const used = {};
const backends = new Map();
for (const imp of imports) {
  if (imp.module === "wasi_snapshot_preview1") continue;
  if (imp.module !== "env" || !imp.name.startsWith("id_")) die("the module imports " + imp.module + "." + imp.name + ", which nothing here can answer");
  const native = imp.name.slice(3);
  const m = natMap.get(native);
  if (!m || !m.js) die("the module imports env." + imp.name + " (native '" + native + "') but no backend with a wasm_js module declares it; add `string wasm_js = \"FILE.mjs\";` to that backend's backend.id (docs/INTEROP.md, \"id and JavaScript\")");
  used[native] = m.backend;
  backends.set(m.backend, m.js);
}

const ident = (s) => s.replace(/[^A-Za-z0-9_]/g, "_");
let glue = fs.readFileSync(opt.glue, "utf8");
const replaceLine = (tag, text) => {
  const re = new RegExp("^.*//@gen " + tag + "$", "m");
  if (!re.test(glue)) die(opt.glue + " has no //@gen " + tag + " line");
  glue = glue.replace(re, () => text);
};
replaceLine("NAME", "const IDW_NAME = " + JSON.stringify(name) + ";");
replaceLine("SIGS", "const IDW_SIGS = " + JSON.stringify(Object.fromEntries(Object.entries(sigs).map(([k, v]) => [k, { params: v.params, ret: v.ret }]))) + ";");
replaceLine("NATIVES", "const IDW_NATIVES = " + JSON.stringify(used) + ";");
replaceLine("BACKENDS", "const IDW_BACKENDS_BY_NAME = { " + [...backends.keys()].map((b) => JSON.stringify(b) + ": idw_be_" + ident(b)).join(", ") + " };");
glue = "// Generated by idc --target wasm from " + path.basename(opt.wasm) + ". Do not edit; rebuild instead.\n// The JS runtime is idc/tools/jsbind/glue.mjs; the backend modules at the end are the\n// wasm_js files of the backends this program reaches (docs/INTEROP.md).\n" + glue;
for (const [b, js] of backends) {
  const src = fs.readFileSync(js, "utf8");
  if (!/export default function\s*\(/.test(src)) die(js + " must contain `export default function (host) { ... }` returning an object of natives");
  glue += "\n// ---- backend " + b + " (" + path.basename(js) + ") ----\n" + src.replace(/export default function\s*\(/, "function idw_be_" + ident(b) + "(");
}
fs.writeFileSync(prefix + ".mjs", glue);

const reserved = new Set(["raw", "memory", "alive", "dispose", "run"]);
const dts = [];
dts.push("// Generated by idc --target wasm from " + path.basename(opt.wasm) + ". Do not edit; rebuild instead.");
dts.push("");
dts.push("export class IdTrap extends Error {");
dts.push("  /** \"exit\": the program called exit (a runtime check failed, or main returned); \"trap\": the wasm trapped; \"stack\": recursion too deep. */");
dts.push("  kind: \"exit\" | \"trap\" | \"stack\";");
dts.push("  /** The exit status; 1 for a trap. */");
dts.push("  code: number;");
dts.push("  /** The last stderr line the program wrote before it died, e.g. \"id: index 5 out of bounds (len 3)\". */");
dts.push("  stderr: string;");
dts.push("}");
dts.push("");
dts.push("export interface MemFs { [method: string]: (...args: any[]) => any }");
dts.push("export function createMemFs(files?: Record<string, string | Uint8Array>): MemFs;");
dts.push("");
dts.push("export interface IdOptions {");
dts.push("  /** Bytes the program writes to stdout / stderr. Default: the process's own, or console.log / console.error by line in a browser. */");
dts.push("  stdout?: (bytes: Uint8Array) => void;");
dts.push("  stderr?: (bytes: Uint8Array) => void;");
dts.push("  /** What the program reads from stdin: text, bytes, or a function that returns up to n bytes (empty at end). Default: the process's stdin in Node, empty in a browser. */");
dts.push("  stdin?: string | Uint8Array | ((n: number) => Uint8Array);");
dts.push("  /** argv for the program (default [\"" + name + "\"]). */");
dts.push("  args?: string[];");
dts.push("  /** The environment the program sees (default: a copy of process.env in Node, empty in a browser). */");
dts.push("  env?: Record<string, string>;");
dts.push("  /** The file system fs_* natives use: Node's `fs` (the default in Node), \"memory\" or createMemFs() (the default in a browser), or any object with the same synchronous methods. */");
dts.push("  fs?: \"node\" | \"memory\" | MemFs | object;");
dts.push("  /** A clock in milliseconds, replacing the real one (for deterministic runs). */");
dts.push("  clock?: () => number;");
dts.push("  /** How sleep_ms waits. */");
dts.push("  sleep?: (ms: number) => void;");
dts.push("  /** How fs_run runs a shell command; returns its wait status. Default: /bin/sh in Node, none in a browser. */");
dts.push("  run?: (cmd: string) => number;");
dts.push("  /** Release each string and list argument after its call: true for every function, or the names of the functions to do it for. Only safe for a function that does not keep its arguments (store them in an export or in another list); the compiler cannot tell you which. Default: none, so every argument stays allocated until dispose(). */");
dts.push("  freeArgs?: boolean | string[];");
dts.push("}");
dts.push("");
dts.push("export interface IdApi {");
for (const [fn, s] of Object.entries(sigs)) {
  const pn = (n) => (TS_RESERVED.has(n) ? n + "_" : n);
  dts.push("  /** " + fn + " (" + path.basename(s.file) + ":" + s.line + ") */");
  dts.push("  " + (reserved.has(fn) ? fn + "_" : fn) + "(" + s.params.map(([n, t]) => pn(n) + ": " + TS[t]).join(", ") + "): " + TS[s.ret] + ";");
}
dts.push("}");
dts.push("");
dts.push("export interface IdInstance extends IdApi {");
dts.push("  /** Every export of the wasm module, untyped. */");
dts.push("  raw: WebAssembly.Exports;");
dts.push("  memory: WebAssembly.Memory;");
dts.push("  /** False once a call has trapped or exited, or dispose() has run. */");
dts.push("  readonly alive: boolean;");
dts.push("  /** Close open files and remove fs_drop_exit paths. The instance is dead afterwards. */");
dts.push("  dispose(): void;");
dts.push("  /** Run a program with a main (its _start) and return its exit status. */");
dts.push("  run(argv?: string[]): number;");
dts.push("}");
dts.push("");
dts.push("export function load(source?: string | URL | Response | ArrayBuffer | ArrayBufferView | WebAssembly.Module, options?: IdOptions): Promise<IdInstance>;");
for (const [fn, why] of skipped) dts.push("// not bound: " + fn + " -- " + why + " (still callable as raw.id_" + fn + ")");
fs.writeFileSync(prefix + ".d.mts", dts.join("\n") + "\n");
fs.writeFileSync(prefix + ".d.ts", dts.join("\n") + "\n");
console.log("idc: jsbind: wrote " + path.basename(prefix) + ".mjs, .d.mts and .d.ts (" + Object.keys(sigs).length + " functions" + (backends.size ? ", backends " + [...backends.keys()].join("+") : "") + (skipped.length ? ", " + skipped.length + " not bound" : "") + ")");
