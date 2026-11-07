#!/usr/bin/env node
/**
 * 生成包内 /usr/share/openlist-txiki/build-manifest.json。
 *
 * 用法：
 *   node scripts/apk/build-manifest.mjs \
 *     --bundle artifacts/p2-freeze-20261022T1540/openlist-txiki.js \
 *     --tjs artifacts/p2-freeze-20261022T1540/tjs-pss \
 *     --source-manifest work/p2-source-manifest.txt \
 *     --version <版本> --inputs 435 --out <输出路径>
 *
 * r29 起可选（成对给，缺一即 exit 1）：
 *   --web-dist <解开后的 dist 目录> --web-dist-archive <官方 asset tar.gz>
 *   现算 archive sha/bytes、dist 文件数/总字节/tree_sha256/index_sha256，与脚本内 WEB_PINS 逐项比对，
 *   任何一项不符 exit 1。产物写入 manifest 的 web_dist 字段；不给这两个参数时 manifest 不含该字段。
 *
 * 字段与规格 §1 一致；patches 直接取源码指纹清单的 patch 记录（含应用顺序）。
 * fail-closed：bundle/tjs 缺失、清单缺 patch 记录、--version 为空都 exit 1。
 */
import fs from "fs"
import path from "path"
import crypto from "crypto"

const args = process.argv.slice(2)
const opt = {}
for (let i = 0; i < args.length; i += 2) {
  const k = args[i]
  if (!k || !k.startsWith("--")) {
    console.error("FAIL: 参数必须是 --key value 形式，遇到 " + k)
    process.exit(1)
  }
  opt[k.slice(2)] = args[i + 1]
}

const need = ["bundle", "tjs", "source-manifest", "version", "inputs", "out"]
const missing = need.filter((k) => !opt[k])
if (missing.length) {
  console.error("FAIL: 缺少参数 " + missing.map((m) => "--" + m).join(" "))
  process.exit(1)
}

// 源码要约字段（B2）：内部分发也要记录源码归档位置与 sha，对外分发再填 url 与有效期。
// --source-archive 给了就必须存在且非空；没给则五个字段写空串，不臆造。
const archive = opt["source-archive"] ? path.resolve(opt["source-archive"]) : ""
if (archive && !fs.existsSync(archive)) {
  console.error("FAIL: 源码归档不存在 " + archive)
  process.exit(1)
}

for (const f of [opt.bundle, opt.tjs, opt["source-manifest"]]) {
  if (!fs.existsSync(f)) {
    console.error("FAIL: 文件不存在 " + f)
    process.exit(1)
  }
}

const sha256 = (f) => crypto.createHash("sha256").update(fs.readFileSync(f)).digest("hex")
const sha256buf = (b) => crypto.createHash("sha256").update(b).digest("hex")

// A2：字节码独立二进制。给了 --exe 就必须同时给四个 tjs-* 身份字段（构建侧已核实），
// 这里复算尾标构成并写进 manifest；任一项不符 exit 1。不给 --exe 时 manifest 不含这些字段，
// 与 A2 之前的包逐字节同形。
let bytecodeInfo = null
if (opt.exe) {
  const needBc = ["tjs-version", "tjs-compile-sha256", "tjs-template-sha256", "tjs-template-arch"].filter((k) => !opt[k])
  if (needBc.length) {
    console.error("FAIL: 给 --exe 时必须同时给 " + needBc.map((k) => "--" + k).join(" "))
    process.exit(1)
  }
  if (!fs.existsSync(opt.exe)) {
    console.error("FAIL: 文件不存在 " + opt.exe)
    process.exit(1)
  }
  const exeBuf = fs.readFileSync(opt.exe)
  const exeBytes = exeBuf.length
  if (exeBytes <= 12) {
    console.error("FAIL: exe 字节数过小 " + exeBytes)
    process.exit(1)
  }
  const trailerBuf = exeBuf.subarray(exeBytes - 12)
  const trailerMagic = trailerBuf.subarray(0, 8).toString("latin1")
  const bcOffset = trailerBuf.readUInt32LE(8)
  if (trailerMagic !== "tx1k1.js") {
    console.error("FAIL: 尾 12 B 的 magic=" + JSON.stringify(trailerMagic) + " 期望 tx1k1.js")
    process.exit(1)
  }
  if (bcOffset <= 0 || bcOffset > exeBytes - 12) {
    console.error("FAIL: 尾标偏移 " + bcOffset + " 越界（exe_bytes=" + exeBytes + "）")
    process.exit(1)
  }
  const bcBuf = exeBuf.subarray(bcOffset, exeBytes - 12)
  if (bcOffset + bcBuf.length + 12 !== exeBytes) {
    console.error("FAIL: 构成为 offset+bytes+12 != exe_bytes")
    process.exit(1)
  }
  let engineVersions = {}
  if (opt["tjs-engine-versions"]) {
    try {
      engineVersions = JSON.parse(opt["tjs-engine-versions"])
    } catch (e) {
      console.error("FAIL: --tjs-engine-versions 不是合法 JSON: " + e.message)
      process.exit(1)
    }
  }
  bytecodeInfo = {
    exe_sha256: sha256buf(exeBuf),
    exe_bytes: exeBytes,
    bytecode_sha256: sha256buf(bcBuf),
    bytecode_bytes: bcBuf.length,
    bytecode_offset: bcOffset,
    bytecode_trailer: trailerMagic,
    tjs_bc_version: bcBuf[0],
    tjs_version: opt["tjs-version"],
    tjs_engine_versions: engineVersions,
    tjs_compile_sha256: opt["tjs-compile-sha256"],
    tjs_template_sha256: opt["tjs-template-sha256"],
    tjs_template_arch: opt["tjs-template-arch"],
  }
}

// r29：包内精简前端（官方 lite asset）身份。--web-dist 指向解开后的 dist 目录。
// 只认下面 pin 里的版本：任何一项现算值与 pin 不符就 exit 1（fail-closed，不出包）。
// 说明：file_count 是本文件上面的「源码指纹条数」，web_dist.file_count 是包内静态文件数，两回事。
const WEB_PATH = "usr/share/openlist-txiki/dist"
const WEB_SOURCE = "OpenListTeam/OpenList-Frontend"
// 同一版本有两个官方 asset：lite 与 standard（完整）。lite 按版本号登记（旧口径不变），
// standard 按 asset 文件名登记（同名版本，靠文件名区分）。
const WEB_PINS = {
  "v4.2.7": {
    commit: "d82d950c",
    archive: "openlist-frontend-dist-lite-v4.2.7.tar.gz",
    archive_sha256: "6679861e3726305434f5de665a06880bd9a74aeab5ffc4c4150accef00e1c42d",
    archive_bytes: 2966517,
    file_count: 222,
    bytes: 9384554,
    tree_sha256: "507b55de4aac050c340b00ff3c8335755c0f11ef7700fc22ebe3554f6d26db8a",
    index_sha256: "d2151c0c5e0aadc315e68b869c34f1e47030cbc20a266b5a0da3c79492348f47",
  },
}
const WEB_PINS_BY_ARCHIVE = {
  "openlist-frontend-dist-v4.2.7.tar.gz": {
    commit: "d82d950c",
    archive_sha256: "88aba5260646ed784847a11e473880d749b17b80af53caf895fe1f31f36aa3e3",
    archive_bytes: 20631035,
    file_count: 452,
    bytes: 58517793,
    tree_sha256: "c107306c3f3d760d65bf9f615d92d9a9a67485d72e024b0e0d061178f63c5137",
    index_sha256: "d39323e13b44e2e909a12d46bfe26141bed55012ee08ea1f6c8f71575e38193a",
  },
}

function webTree(dir) {
  const files = []
  const walk = (abs, rel) => {
    for (const e of fs.readdirSync(abs, { withFileTypes: true })) {
      const childAbs = path.join(abs, e.name)
      const childRel = rel ? rel + "/" + e.name : e.name
      if (e.isDirectory()) walk(childAbs, childRel)
      else files.push({ rel: childRel, abs: childAbs })
    }
  }
  walk(dir, "")
  // LC_ALL=C 等价：按 UTF-8 字节序排（JS 默认是 UTF-16 码元序，非 ASCII 会不同）。
  files.sort((a, b) => Buffer.compare(Buffer.from(a.rel, "utf8"), Buffer.from(b.rel, "utf8")))
  let total = 0
  const lines = []
  for (const f of files) {
    total += fs.statSync(f.abs).size
    lines.push(f.rel + "\t" + sha256(f.abs) + "\n")
  }
  return { files, total, tree: crypto.createHash("sha256").update(Buffer.from(lines.join(""), "utf8")).digest("hex") }
}

let webDist = null
if (opt["web-dist"]) {
  const distDir = path.resolve(opt["web-dist"])
  if (!fs.existsSync(distDir)) {
    console.error("FAIL: --web-dist 目录不存在 " + distDir)
    process.exit(1)
  }
  const archivePath = opt["web-dist-archive"] ? path.resolve(opt["web-dist-archive"]) : ""
  if (!archivePath || !fs.existsSync(archivePath)) {
    console.error("FAIL: 给了 --web-dist 就必须给存在的 --web-dist-archive")
    process.exit(1)
  }
  const archiveSha = sha256(archivePath)
  const archiveBytes = fs.statSync(archivePath).size
  const indexAbs = path.join(distDir, "index.html")
  if (!fs.existsSync(indexAbs)) {
    console.error("FAIL: dist 里没有 index.html：" + indexAbs)
    process.exit(1)
  }
  const indexSha = sha256(indexAbs)
  const t = webTree(distDir)
  if (!t.files.length) {
    console.error("FAIL: dist 文件数为 0")
    process.exit(1)
  }
  // 版本从 asset 文件名取，只认 pin 里的版本。
  const m = path.basename(archivePath).match(/-v(\d+\.\d+\.\d+)\.tar\.gz$/)
  const version = opt["web-version"] || (m ? "v" + m[1] : "")
  const pin = WEB_PINS_BY_ARCHIVE[path.basename(archivePath)] || WEB_PINS[version]
  if (!pin) {
    console.error("FAIL: 未登记的前端版本 " + (version || "(无法从文件名解析，需 --web-version)") + "；已登记：" + Object.keys(WEB_PINS).join(", "))
    process.exit(1)
  }
  const mismatch = []
  if (archiveSha !== pin.archive_sha256) mismatch.push("archive_sha256 现算=" + archiveSha + " pin=" + pin.archive_sha256)
  if (archiveBytes !== pin.archive_bytes) mismatch.push("archive_bytes 现算=" + archiveBytes + " pin=" + pin.archive_bytes)
  if (t.files.length !== pin.file_count) mismatch.push("file_count 现算=" + t.files.length + " pin=" + pin.file_count)
  if (t.total !== pin.bytes) mismatch.push("bytes 现算=" + t.total + " pin=" + pin.bytes)
  if (t.tree !== pin.tree_sha256) mismatch.push("tree_sha256 现算=" + t.tree + " pin=" + pin.tree_sha256)
  if (indexSha !== pin.index_sha256) mismatch.push("index_sha256 现算=" + indexSha + " pin=" + pin.index_sha256)
  if (mismatch.length) {
    console.error("FAIL: 前端产物与 pin 不符（" + version + "）")
    for (const x of mismatch) console.error("  - " + x)
    process.exit(1)
  }
  webDist = {
    source: WEB_SOURCE,
    version,
    commit: pin.commit,
    archive: path.basename(archivePath),
    archive_sha256: archiveSha,
    archive_bytes: archiveBytes,
    path: WEB_PATH,
    file_count: t.files.length,
    bytes: t.total,
    tree_sha256: t.tree,
    index_sha256: indexSha,
  }
}
const manifestText = fs.readFileSync(opt["source-manifest"], "utf8")
const patchLines = manifestText
  .split(/\r?\n/)
  .map((l) => l.trim())
  .filter((l) => l.startsWith("patch "))
  .map((l) => {
    const p = l.split(/\s+/)
    return { seq: p[1], path: p[3], sha256: p[2] }
  })
const fileLines = manifestText
  .split(/\r?\n/)
  .map((l) => l.trim())
  .filter((l) => l.startsWith("file "))
const commit = (manifestText.match(/^upstream_commit ([0-9a-f]{40})$/m) || [])[1] || ""

if (!patchLines.length) {
  console.error("FAIL: 源码指纹清单里没有 patch 记录")
  process.exit(1)
}
if (!fileLines.length) {
  console.error("FAIL: 源码指纹清单里没有 file 记录")
  process.exit(1)
}
if (!commit) {
  console.error("FAIL: 源码指纹清单里没有 upstream_commit")
  process.exit(1)
}

const bundleBytes = fs.statSync(opt.bundle).size
const tjsBytes = fs.statSync(opt.tjs).size
const runtime = opt.runtime || "bundled"
if (runtime !== "bundled" && runtime !== "shared") {
  console.error("FAIL: --runtime 只接受 bundled 或 shared（现为 " + runtime + "）")
  process.exit(1)
}

// r40：驱动拆分形态的 chunk 清单。--split-manifest 指向构建脚本产出的 build-manifest.json，
// 取其中的 chunks（rel/bytes/sha256），逐条与盘面（相对 bundle 所在目录）核对；
// 目录里多一个、少一个、字节不符都 exit 1，不出包。
let splitInfo = null
if (opt["split-manifest"]) {
  const smPath = path.resolve(opt["split-manifest"])
  if (!fs.existsSync(smPath)) {
    console.error("FAIL: --split-manifest 不存在 " + smPath)
    process.exit(1)
  }
  const sm = JSON.parse(fs.readFileSync(smPath, "utf8"))
  const list = Array.isArray(sm.chunks) ? sm.chunks : []
  if (!list.length) {
    console.error("FAIL: --split-manifest 里没有 chunks（拆分构建没产出 chunk）")
    process.exit(1)
  }
  const baseDir = path.dirname(path.resolve(opt.bundle))
  for (const c of list) {
    if (!/^chunks\/[A-Za-z0-9._-]+\.js$/.test(c.rel)) {
      console.error("FAIL: chunk 路径不合规 " + c.rel)
      process.exit(1)
    }
    const abs = path.join(baseDir, c.rel)
    if (!fs.existsSync(abs)) {
      console.error("FAIL: chunk 缺失 " + abs)
      process.exit(1)
    }
    if (fs.statSync(abs).size !== c.bytes || sha256(abs) !== c.sha256) {
      console.error("FAIL: chunk 字节不符 " + c.rel)
      process.exit(1)
    }
  }
  const chunkDir = path.join(baseDir, "chunks")
  const got = fs.readdirSync(chunkDir).filter((n) => n.endsWith(".js")).sort()
  const want = list.map((c) => c.rel.slice("chunks/".length)).sort()
  if (JSON.stringify(got) !== JSON.stringify(want)) {
    console.error("FAIL: chunks 目录与构建清单不一致（多/少文件）")
    process.exit(1)
  }
  splitInfo = { chunk_count: list.length, chunks: list, split_drivers: sm.split_drivers || [] }
}

const out = {
  package: "openlist-txiki",
  package_version: opt.version,
  upstream_commit: commit,
  bundle_sha256: sha256(opt.bundle),
  bundle_bytes: bundleBytes,
  // S6：shared 变体不随包提供 tjs，包内 tjs_sha256 若记构建参考件，会被误读成设备系统 tjs
  // （35385499…/5,282,872 实为 x86_64 构建参考件）。这里写 null，shared 另补 tjs_reference。
  // openlist-txiki.init 只在 BUNDLED_TJS=1 时读 tjs_sha256，shared 模式不读，语义不变。
  tjs_sha256: runtime === "shared" ? null : sha256(opt.tjs),
  tjs_bytes: runtime === "shared" ? null : tjsBytes,
  patches: patchLines,
  patch_count: patchLines.length,
  file_count: fileLines.length,
  inputs_count: Number(opt.inputs),
  source_manifest_sha256: sha256(opt["source-manifest"]),
  source_archive_path: opt["source-archive-path"] || (archive ? path.basename(path.dirname(archive)) + "/" + path.basename(archive) : ""),
  source_archive_url: opt["source-archive-url"] || "",
  source_archive_sha256: archive ? sha256(archive) : "",
  source_archive_bytes: archive ? fs.statSync(archive).size : 0,
  contact_email: opt["contact-email"] || "https://github.com/ayueyang/openlist-txiki/issues",
  // S2/S3：要约有效期按「自分发之日起 3 年」。r47 分发日 2026-11-06，覆盖至 2029-11-06；
  // 后续分发另给 --offer-valid-until 覆盖，不沿用旧日期。
  offer_valid_until: opt["offer-valid-until"] || "2029-11-06",
  build_date: new Date().toISOString().slice(0, 10),
}
if (webDist) out.web_dist = webDist
if (bytecodeInfo) Object.assign(out, bytecodeInfo)
if (splitInfo) Object.assign(out, splitInfo)
if (runtime === "shared") {
  out.runtime = "shared"
  out.tjs_min_version = opt["tjs-min-version"] || "26.9.0"
  // S6：shared 的运行时由系统 txiki-js 提供，包内 tjs_sha256/tjs_bytes 为 null；
  // 构建参考件身份放 tjs_reference，明确它不是设备上的 /usr/bin/tjs。
  out.tjs_reference = {
    sha256: sha256(opt.tjs),
    bytes: tjsBytes,
    note: "构建参考 tjs，不是设备系统 tjs；shared 模式由 init 按 tjs_min_version 闸版本",
  }
}
fs.mkdirSync(path.dirname(opt.out), { recursive: true })
fs.writeFileSync(opt.out, JSON.stringify(out, null, 2) + "\n")
console.log(JSON.stringify({ out: opt.out, runtime, bundle_sha256: out.bundle_sha256, bundle_bytes: bundleBytes, tjs_sha256: out.tjs_sha256, tjs_bytes: tjsBytes, patches: patchLines.length }, null, 2))
