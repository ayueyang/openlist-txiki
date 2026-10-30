/**
 * txiki 构建脚本：把 src/backend/txiki/entry.ts 打成单文件 ESM，给 tjs run。
 *
 * 关键点（与上游 scripts/build-edge.mjs 对齐）：
 * - platform=neutral：不打 Node 内置模块的包；
 * - node:* 与裸内置模块全部解析到「访问即抛错」的 CJS 空壳，
 *   这样产物里不会残留 node: 说明符（G1 的 grep 门槛）；
 * - ftp / sftp 驱动替换为空壳，消除间接拼出来的 node:net / node:stream；
 * - Buffer / process 通过 inject 注入，上游源码不改。
 */
import esbuild from "esbuild"
import fs from "fs"
import path from "path"
import { createHash } from "crypto"
import { execFileSync } from "child_process"
import { fileURLToPath } from "url"

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const root = path.resolve(__dirname, "..")
const outdir = path.join(root, "dist-txiki")
// 测试专用故障注入构建：TXIKI_FAULT_ENTRY 指向一个只用于测试的入口文件
// （如 src/backend/txiki/rename-fail-entry.ts），产物名固定 openlist-txiki.fault.js。
// 不设该变量时入口与产物名与原来完全一致，生产 bundle 逐字节不变。
const faultEntry = process.env.TXIKI_FAULT_ENTRY || ""
const outfile = path.join(
  outdir,
  faultEntry
    ? "openlist-txiki.fault.js"
    : process.env.TXIKI_DEBUG
      ? "openlist-txiki.debug.js"
      : "openlist-txiki.js",
)

const NODE_BUILTINS = [
  "assert", "buffer", "child_process", "cluster", "console", "constants",
  "crypto", "dgram", "dns", "domain", "events", "fs", "http", "http2",
  "https", "module", "net", "os", "path", "perf_hooks", "process",
  "punycode", "querystring", "readline", "repl", "stream", "string_decoder",
  "timers", "tls", "tty", "url", "util", "v8", "vm", "worker_threads", "zlib",
]

/** 访问任何属性都抛错的 CJS 空壳；esbuild 会把命名导入转成属性访问。 */
const emptyModulePlugin = {
  name: "empty-node-module",
  setup(build) {
    // tjs: 模块由运行时提供，保持原样
    build.onResolve({ filter: /^tjs:/ }, (args) => ({ path: args.path, external: true }))
    // util 是模块加载期就会被调的少数内置之一（inherits / promisify / format），
    // 给一份真实现，避免第三方包在 import 阶段就炸。
    build.onResolve({ filter: /^(node:)?util$/ }, () => ({ path: "util", namespace: "util-shim" }))
    build.onResolve({ filter: /^node:/ }, (args) => ({ path: args.path, namespace: "empty-node" }))
    build.onResolve({ filter: new RegExp(`^(${NODE_BUILTINS.join("|")})(\\/.*)?$`) }, (args) => ({
      path: args.path,
      namespace: "empty-node",
    }))
    build.onLoad({ filter: /.*/, namespace: "util-shim" }, () => ({
      contents: `
function inherits(ctor, superCtor) {
  ctor.super_ = superCtor
  Object.setPrototypeOf(ctor.prototype, superCtor.prototype)
}
function promisify(fn) {
  return (...args) => new Promise((resolve, reject) => fn(...args, (err, value) => err ? reject(err) : resolve(value)))
}
function format(...args) { return args.map((a) => typeof a === "string" ? a : JSON.stringify(a)).join(" ") }
function inspect(o) { try { return JSON.stringify(o) } catch { return String(o) } }
const types = {
  isDate: (v) => v instanceof Date,
  isRegExp: (v) => v instanceof RegExp,
  isPromise: (v) => !!v && typeof v.then === "function",
  isNativeError: (v) => v instanceof Error,
}
module.exports = {
  inherits, promisify, format, inspect, types,
  deprecate: (fn) => fn,
  debuglog: () => () => {},
  isDeepStrictEqual: (a, b) => JSON.stringify(a) === JSON.stringify(b),
  callbackify: (fn) => fn,
  TextEncoder, TextDecoder,
  default: {},
}
`,
      loader: "js",
    }))
    build.onLoad({ filter: /.*/, namespace: "empty-node" }, (args) => ({
      contents: `
// 说明符字符串不能出现在产物里（G1 用 grep node: 自检），错误信息只给属性名。
// 只在「调用/构造」时抛错：模块加载期常有 util.inherits(X, EventEmitter) 这类
// 只摸 prototype 的代码，属性访问就抛会让 bundle 根本加载不起来。
function stub(label) {
  const f = function () { throw new Error("Node builtin is not available on txiki.js: " + label) }
  return new Proxy(f, {
    get(_t, prop) {
      if (prop === "prototype") return f.prototype
      if (prop === "default") return f
      if (prop === Symbol.toPrimitive) return () => ""
      if (prop === "then") return undefined
      return stub(label + "." + String(prop))
    },
    apply() { throw new Error("Node builtin is not available on txiki.js: " + label) },
    construct() { throw new Error("Node builtin is not available on txiki.js: " + label) },
  })
}
module.exports = stub("builtin")
`,
      loader: "js",
    }))
  },
}

/**
 * P2 A2：把 Local 驱动与本地回传分支的 node 内置解析到 txiki shim。
 *
 * 只按 importer 限定（drivers/local.ts 与 server/raw.ts），别处仍然走
 * emptyModulePlugin 的「访问即抛错」空壳。必须注册在 emptyModulePlugin 之前：
 * esbuild 的 onResolve 是「先注册先命中」，后注册的同 filter 不会再被调用。
 */
const txikiLocalShimPlugin = {
  name: "txiki-local-shim",
  setup(build) {
    const shimDir = path.join(root, "src/backend/txiki/shims")
    const targeted = /(?:^|[\\/])(?:drivers[\\/]local|server[\\/]raw)\.ts$/
    build.onResolve({ filter: /^(node:)?(fs\/promises|fs|path)$/ }, (args) => {
      if (!args.importer || !targeted.test(args.importer)) return null
      const spec = args.path.replace(/^node:/, "")
      if (spec === "fs/promises") return { path: path.join(shimDir, "fs-promises.ts") }
      if (spec === "fs") return { path: path.join(shimDir, "fs.ts") }
      // tjs:path 只有 default 导出，而 local.ts 用的是 `await import("path")`
      // 再取 path.join/path.dirname 的命名空间用法，所以过一层 path shim。
      return { path: path.join(shimDir, "path.ts") }
    })
  },
}

const emptyNodeDriverPlugin = {
  name: "empty-node-driver",
  setup(build) {
    build.onResolve({ filter: /drivers[\\/](sftp|ftp)([\\/].*)?$/ }, (args) => ({
      path: args.path,
      namespace: "empty-node-driver",
    }))
    build.onResolve({ filter: /^(ssh2|cpu-features|iconv-lite)(\/.*)?$/ }, (args) => ({
      path: args.path,
      namespace: "empty-node-driver",
    }))
    build.onResolve({ filter: /^mysql2(\/.*)?$/ }, (args) => ({ path: args.path, namespace: "empty-node-driver" }))
    build.onLoad({ filter: /.*/, namespace: "empty-node-driver" }, () => ({
      contents: `
export const SFTPDriver = class { constructor() { throw new Error("SFTP driver is not available on txiki.js") } }
export const normalizeSFTPAddition = (v) => v
export const FTPDriver = class { constructor() { throw new Error("FTP driver is not available on txiki.js") } }
export const SFTPClient = class { constructor() { throw new Error("SFTP driver is not available on txiki.js") } }
export const parseAddress = () => ({ host: "127.0.0.1", port: 22 })
export const Client = class { constructor() { throw new Error("ssh2 is not available on txiki.js") } }
export const createPool = () => { throw new Error("mysql2 is not available on txiki.js") }
export default {}
`,
      loader: "js",
    }))
  },
}

/**
 * P2 源码指纹预检（fail-closed，2026-10-21 conductor 裁决一）。
 *
 * 输入 work/p2-source-manifest.txt：pinned 上游 commit、补丁 sha256、改动与新增
 * 源码文件的 sha256。任何一项对不上就打印不符清单并以非零码退出，禁止出包。
 * 清单查找顺序：$TXIKI_SOURCE_MANIFEST，其次 <root>/work/，再次 <root>/../../work/
 * （构建树是 reference/OpenList-Worker 时，清单在项目根的 work/ 下）。
 */
const sha256 = (buf) => createHash("sha256").update(buf).digest("hex")

/**
 * 注释头剥离：仓库 txiki 副本带 4 行冻版后注释头（见清单“行尾与注释头规则”）。
 * 只认固定形态，任何一行不符就返回 null 让调用方失败——不猜、不兜底。
 */
function stripProvenanceHeader(buf) {
  const lines = buf.toString("utf8").split(/(?<=\n)/)
  if (lines.length < 4) return null
  const l1 = lines[0].replace(/\r?\n$/, "").trim()
  const l4 = lines[3].replace(/\r?\n$/, "").trim()
  if (l1 !== "/**") return null
  if (!lines[1].includes("上游基线") || !lines[1].includes("OpenListTeam/OpenList-Worker")) return null
  if (!lines[2].includes("本地维护")) return null
  if (l4 !== "*/") return null
  return lines.slice(4).join("")
}

/** 行尾归一：keep 不动；lf 把 CRLF 压成 LF；crlf 先归一到 LF 再统一成 CRLF（幂等）。 */
function normalizeEol(text, eol) {
  if (eol === "keep") return text
  const lf = text.replace(/\r\n/g, "\n")
  if (eol === "lf") return lf
  return lf.replace(/\n/g, "\r\n")
}

/**
 * 源码指纹预检 v2（fail-closed，2026-10-22 P3-1b 补齐三个缺口）。
 *
 * 输入 work/p2-source-manifest.txt（manifest_version 3）：
 *   - 31 个补丁的 sha256 与应用顺序（patch <序号>）；
 *   - 28 条源码指纹，每条带 src=（upstream/repo/patch/显式路径）、strip_header=、eol=；
 *   - rename-fail-entry.ts 的来源固定为 work/fault/rename-fail-entry.ts。
 *
 * 两阶段：
 *   1) prepare：把 src=repo / 显式路径的条目按 strip_header 剥头、按 eol 归一后写进构建树；
 *      src=patch 的条目只在构建树里做行尾归一（补丁带 CRLF 上下文，见清单说明）。已一致不重写。
 *   2) verify：对 28 条 file 逐条 sha256 比对。任何不符打印期望/实际并 exit 1，不出包。
 *
 * 清单查找顺序：$TXIKI_SOURCE_MANIFEST，其次 <root>/work/，再次 <root>/../../work/。
 */
function verifySourceManifest() {
  const manifestName = "p2-source-manifest.txt"
  const candidates = [
    process.env.TXIKI_SOURCE_MANIFEST ? path.resolve(process.env.TXIKI_SOURCE_MANIFEST) : "",
    path.join(root, "work", manifestName),
    path.join(root, "..", "..", "work", manifestName),
  ].filter(Boolean)
  const manifestPath = candidates.find((p) => fs.existsSync(p))
  if (!manifestPath) {
    console.error("FAIL: 源码指纹预检不通过（1 项）— 构建中止")
    console.error("  - 找不到源码指纹清单 " + manifestName + "（fail-closed：无清单不出包）")
    console.error("  查找过：" + candidates.join(" | "))
    process.exit(1)
  }

  const entries = { version: 0, commit: "", checkoutEol: "", patchCount: 0, fileCount: 0, patches: [], files: [] }
  const problems = []
  fs.readFileSync(manifestPath, "utf8")
    .split(/\r?\n/)
    .forEach((raw, i) => {
      const line = raw.trim()
      if (!line || line.startsWith("#")) return
      const parts = line.split(/\s+/)
      const bad = (msg) => problems.push("清单第 " + (i + 1) + " 行：" + msg)
      if (parts[0] === "manifest_version") {
        if (parts.length !== 2 || !/^\d+$/.test(parts[1])) return bad("manifest_version 需要 1 个整数")
        entries.version = Number(parts[1])
      } else if (parts[0] === "upstream_commit") {
        if (parts.length !== 2 || !/^[0-9a-f]{40}$/.test(parts[1])) return bad("upstream_commit 需要 40 位小写 sha")
        entries.commit = parts[1]
      } else if (parts[0] === "checkout_eol") {
        if (parts.length !== 2 || !["crlf", "lf"].includes(parts[1])) return bad("checkout_eol 需为 crlf 或 lf")
        entries.checkoutEol = parts[1]
      } else if (parts[0] === "patch_count") {
        if (parts.length !== 2 || !/^\d+$/.test(parts[1])) return bad("patch_count 需要 1 个整数")
        entries.patchCount = Number(parts[1])
      } else if (parts[0] === "file_count") {
        if (parts.length !== 2 || !/^\d+$/.test(parts[1])) return bad("file_count 需要 1 个整数")
        entries.fileCount = Number(parts[1])
      } else if (parts[0] === "patch") {
        if (parts.length !== 4) return bad("patch 记录格式：patch <序号> <sha256> <路径>")
        if (!/^\d{2}$/.test(parts[1]) || !/^[0-9a-f]{64}$/.test(parts[2])) return bad("patch 序号需两位数字、sha256 需 64 位小写")
        entries.patches.push({ seq: parts[1], sha256: parts[2], rel: parts[3] })
      } else if (parts[0] === "file") {
        if (parts.length < 5) return bad("file 记录格式：file <sha256> <路径> src=... strip_header=... eol=...")
        if (!/^[0-9a-f]{64}$/.test(parts[1])) return bad("file sha256 需 64 位小写")
        const kv = {}
        for (const tok of parts.slice(3)) {
          const eq = tok.indexOf("=")
          if (eq <= 0) return bad("无法解析属性 " + tok)
          kv[tok.slice(0, eq)] = tok.slice(eq + 1)
        }
        const unknown = Object.keys(kv).filter((k) => !["src", "strip_header", "eol"].includes(k))
        if (unknown.length) return bad("未知属性 " + unknown.join(","))
        entries.files.push({ sha256: parts[1], rel: parts[2], src: kv.src, stripHeader: kv.strip_header, eol: kv.eol })
      } else {
        bad("无法识别的记录类型 " + parts[0])
      }
    })

  if (entries.version !== 3) problems.push("清单版本必须是 3（v1 只声明 3 个补丁、v2 停在 22 条补丁；拒绝按旧版本出包）")
  if (!entries.commit) problems.push("清单缺少 upstream_commit")
  if (!entries.checkoutEol) problems.push("清单缺少 checkout_eol")
  if (!entries.patches.length) problems.push("清单缺少 patch 条目")
  if (!entries.files.length) problems.push("清单缺少 file 条目")
  if (entries.patchCount !== entries.patches.length) problems.push("patch_count " + entries.patchCount + " 与实际 patch 条目 " + entries.patches.length + " 不符")
  if (entries.fileCount !== entries.files.length) problems.push("file_count " + entries.fileCount + " 与实际 file 条目 " + entries.files.length + " 不符")
  if (entries.patches.length !== 31) problems.push("补丁栈应为 31 个，实际 " + entries.patches.length + " 个")
  entries.patches.forEach((p, idx) => {
    const want = String(idx + 1).padStart(2, "0")
    if (p.seq !== want) problems.push("补丁顺序断档：第 " + (idx + 1) + " 条序号 " + p.seq + "，期望 " + want)
  })
  const seen = new Set()
  for (const p of entries.patches) {
    if (seen.has(p.rel)) problems.push("补丁重复登记：" + p.rel)
    seen.add(p.rel)
  }
  for (const f of entries.files) {
    if (!f.src) problems.push(f.rel + ": 缺少 src=")
    if (!["yes", "no"].includes(f.stripHeader)) problems.push(f.rel + ": strip_header 需为 yes 或 no")
    if (!["crlf", "lf", "keep"].includes(f.eol)) problems.push(f.rel + ": eol 需为 crlf/lf/keep")
    if (f.stripHeader === "yes" && ["upstream", "patch"].includes(f.src)) problems.push(f.rel + ": strip_header=yes 不能用于 src=" + f.src)
  }

  const projectRoot = path.dirname(path.dirname(manifestPath))

  if (entries.commit) {
    let head = ""
    try {
      head = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim()
    } catch {
      head = ""
    }
    if (!head) problems.push("上游 commit 无法校验：构建树不是 git 工作树或 git 不可用（" + root + "）")
    else if (head !== entries.commit) problems.push("上游 commit 不符：清单 " + entries.commit + "，工作树 " + head)
  }

  for (const e of entries.patches) {
    const abs = path.resolve(projectRoot, e.rel)
    if (!fs.existsSync(abs)) {
      problems.push(e.rel + ": 补丁缺失")
      continue
    }
    const got = sha256(fs.readFileSync(abs))
    if (got !== e.sha256) problems.push(e.rel + ": 补丁 sha256 不符（期望 " + e.sha256 + "，实际 " + got + "）")
  }

  if (problems.length) {
    console.error("FAIL: 源码指纹预检不通过（" + problems.length + " 项）— 构建中止")
    for (const p of problems) console.error("  - " + p)
    console.error("  清单：" + manifestPath)
    process.exit(1)
  }

  // ---- prepare：剥头 / 行尾归一 / 复制来源，幂等 ----
  const prepare = { rewritten: [], unchanged: [], copied: [], eol_rewritten: [] }
  for (const e of entries.files) {
    const abs = path.join(root, e.rel)
    if (e.src === "patch") {
      if (!fs.existsSync(abs)) {
        problems.push(e.rel + ": 补丁产物缺失（31 个补丁是否按清单顺序 apply 过？）")
        continue
      }
      const before = fs.readFileSync(abs)
      const after = Buffer.from(normalizeEol(before.toString("utf8"), e.eol), "utf8")
      if (after.equals(before)) {
        prepare.unchanged.push(e.rel)
      } else {
        fs.writeFileSync(abs, after)
        prepare.eol_rewritten.push(e.rel)
      }
      continue
    }
    if (e.src === "upstream") {
      if (!fs.existsSync(abs)) problems.push(e.rel + ": 上游 checkout 里缺少该文件")
      else prepare.unchanged.push(e.rel)
      continue
    }
    const srcAbs = e.src === "repo" ? path.join(projectRoot, e.rel) : path.join(projectRoot, e.src)
    if (!fs.existsSync(srcAbs)) {
      problems.push(e.rel + ": 来源缺失（src=" + e.src + "）")
      continue
    }
    let buf = fs.readFileSync(srcAbs)
    if (e.stripHeader === "yes") {
      const stripped = stripProvenanceHeader(buf)
      if (stripped === null) {
        problems.push(e.rel + ": 声明 strip_header=yes，但来源没有约定的 4 行注释头（" + e.src + "）")
        continue
      }
      buf = Buffer.from(stripped, "utf8")
    }
    buf = Buffer.from(normalizeEol(buf.toString("utf8"), e.eol), "utf8")
    if (fs.existsSync(abs) && fs.readFileSync(abs).equals(buf)) {
      prepare.unchanged.push(e.rel)
    } else {
      fs.mkdirSync(path.dirname(abs), { recursive: true })
      fs.writeFileSync(abs, buf)
      if (!fs.readFileSync(abs).equals(buf)) problems.push(e.rel + ": 写入构建树后回读不一致")
      else if (e.src !== "repo") prepare.copied.push(e.rel)
      else prepare.rewritten.push(e.rel)
    }
  }

  for (const e of entries.files) {
    const abs = path.join(root, e.rel)
    if (!fs.existsSync(abs)) {
      problems.push(e.rel + ": 文件缺失")
      continue
    }
    const got = sha256(fs.readFileSync(abs))
    if (got !== e.sha256) problems.push(e.rel + ": sha256 不符（期望 " + e.sha256 + "，实际 " + got + "）")
  }

  if (problems.length) {
    console.error("FAIL: 源码指纹预检不通过（" + problems.length + " 项）— 构建中止")
    for (const p of problems) console.error("  - " + p)
    console.error("  清单：" + manifestPath)
    process.exit(1)
  }

  const info = {
    upstream_commit: entries.commit,
    checkout_eol: entries.checkoutEol,
    patch_sha256: entries.patches.map((p) => p.sha256).join(","),
    patches: entries.patches.map((p) => ({ seq: p.seq, path: p.rel, sha256: p.sha256 })),
    fingerprint_files: entries.files.length,
    fingerprint_entries: entries.files.length + entries.patches.length + 1,
    prepare,
    source_manifest: manifestPath,
    source_manifest_sha256: sha256(fs.readFileSync(manifestPath)),
  }
  console.error(
    "源码指纹预检通过：commit " +
      entries.commit.slice(0, 8) +
      "，补丁 " +
      entries.patches.length +
      "/31（01..31 顺序与 sha 一致），指纹 " +
      info.fingerprint_entries +
      " 条（file " +
      info.fingerprint_files +
      " + patch " +
      entries.patches.length +
      " + commit 1），checkout_eol=" +
      entries.checkoutEol,
  )
  console.error(
    "prepare：构建树已一致 " +
      prepare.unchanged.length +
      " 条，重写 " +
      prepare.rewritten.length +
      " 条（剥头+归一），来源复制 " +
      prepare.copied.length +
      " 条，补丁产物行尾归一 " +
      prepare.eol_rewritten.length +
      " 条",
  )
  return info
}

const sourceFingerprint = verifySourceManifest()

if (process.env.TXIKI_PRECHECK_ONLY) {
  console.error("TXIKI_PRECHECK_ONLY=1：预检通过，跳过 esbuild")
  process.exit(0)
}

fs.mkdirSync(outdir, { recursive: true })

const result = await esbuild.build({
  entryPoints: [faultEntry ? path.resolve(root, faultEntry) : path.join(root, "src/backend/txiki/entry.ts")],
  outfile,
  bundle: true,
  format: "esm",
  platform: "neutral",
  target: "es2022",
  minify: process.env.TXIKI_DEBUG ? false : true,
  sourcemap: false,
  legalComments: "none",
  mainFields: ["module", "main"],
  conditions: ["browser", "import", "default"],
  inject: [path.join(root, "src/backend/txiki/globals.ts")],
  plugins: [txikiLocalShimPlugin, emptyModulePlugin, emptyNodeDriverPlugin],
  logLevel: "warning",
  metafile: true,
})

if (process.env.TXIKI_META) {
  fs.writeFileSync(path.join(outdir, "meta.json"), JSON.stringify(result.metafile))
}

const code = fs.readFileSync(outfile, "utf8")
const size = Buffer.byteLength(code)

// G1 自检 1：产物里不能有 node: 说明符
const nodeSpecs = [...new Set((code.match(/["'`]node:[a-z_/]+/g) || []).map((s) => s.slice(1)))]
// G1 自检 2：不能有 require("net") 这类裸内置残留
const bare = [...new Set((code.match(/require\(["'`](net|stream|fs|crypto|http|https|os|path)["'`]\)/g) || []))]

const inputs = Object.keys(result.metafile.inputs).length
const bundleSha256 = sha256(Buffer.from(code))
console.log(
  JSON.stringify(
    {
      outfile,
      size,
      inputs,
      sha256: bundleSha256,
      upstream_commit: sourceFingerprint.upstream_commit,
      patch_sha256: sourceFingerprint.patch_sha256,
      fingerprint_entries: sourceFingerprint.fingerprint_entries,
      nodeSpecs,
      bareRequires: bare,
    },
    null,
    2,
  ),
)

if (nodeSpecs.length || bare.length) {
  console.error("FAIL: bundle still references node builtins")
  process.exit(1)
}
if (size > 6 * 1024 * 1024) {
  console.error("FAIL: bundle exceeds 6MB")
  process.exit(1)
}

// 构建 manifest：只在校验全过之后写，构建失败不留 manifest。
const buildManifest = {
  built_at: new Date().toISOString(),
  outfile,
  upstream_commit: sourceFingerprint.upstream_commit,
  checkout_eol: sourceFingerprint.checkout_eol,
  patch_sha256: sourceFingerprint.patch_sha256,
  patches: sourceFingerprint.patches,
  fingerprint_files: sourceFingerprint.fingerprint_files,
  fingerprint_entries: sourceFingerprint.fingerprint_entries,
  prepare: sourceFingerprint.prepare,
  source_manifest: sourceFingerprint.source_manifest,
  source_manifest_sha256: sourceFingerprint.source_manifest_sha256,
  bundle: { file: path.basename(outfile), sha256: bundleSha256, size, inputs },
  checks: { nodeSpecs, bareRequires: bare },
}
const buildManifestPath = path.join(outdir, faultEntry ? "build-manifest.fault.json" : "build-manifest.json")
fs.writeFileSync(buildManifestPath, JSON.stringify(buildManifest, null, 2) + "\n")
console.error("build manifest: " + buildManifestPath)
