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
fs.mkdirSync(path.dirname(opt.out), { recursive: true })
fs.writeFileSync(opt.out, JSON.stringify(out, null, 2) + "\n")
console.log(JSON.stringify({ out: opt.out, bundle_sha256: out.bundle_sha256, bundle_bytes: bundleBytes, tjs_sha256: out.tjs_sha256, tjs_bytes: tjsBytes, patches: patchLines.length }, null, 2))
