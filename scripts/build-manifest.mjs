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

// r29：包内精简前端（官方 lite asset）身份。--web-dist 指向解开后的 dist 目录。
// 只认下面 pin 里的版本：任何一项现算值与 pin 不符就 exit 1（fail-closed，不出包）。
// 说明：file_count 是本文件上面的「源码指纹条数」，web_dist.file_count 是包内静态文件数，两回事。
const WEB_PATH = "usr/share/openlist-txiki/dist"
const WEB_SOURCE = "OpenListTeam/OpenList-Frontend"
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
  const pin = WEB_PINS[version]
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
const out = {
  package: "openlist-txiki",
  package_version: opt.version,
  upstream_commit: commit,
  bundle_sha256: sha256(opt.bundle),
  bundle_bytes: bundleBytes,
  tjs_sha256: sha256(opt.tjs),
  tjs_bytes: tjsBytes,
  patches: patchLines,
  patch_count: patchLines.length,
  file_count: fileLines.length,
  inputs_count: Number(opt.inputs),
  source_manifest_sha256: sha256(opt["source-manifest"]),
  source_archive_path: opt["source-archive-path"] || (archive ? path.basename(path.dirname(archive)) + "/" + path.basename(archive) : ""),
  source_archive_url: opt["source-archive-url"] || "",
  source_archive_sha256: archive ? sha256(archive) : "",
  source_archive_bytes: archive ? fs.statSync(archive).size : 0,
  contact_email: opt["contact-email"] || "",
  offer_valid_until: opt["offer-valid-until"] || "",
  build_date: new Date().toISOString().slice(0, 10),
}
if (webDist) out.web_dist = webDist
fs.mkdirSync(path.dirname(opt.out), { recursive: true })
fs.writeFileSync(opt.out, JSON.stringify(out, null, 2) + "\n")
console.log(JSON.stringify({ out: opt.out, bundle_sha256: out.bundle_sha256, bundle_bytes: bundleBytes, tjs_sha256: out.tjs_sha256, tjs_bytes: tjsBytes, patches: patchLines.length }, null, 2))
