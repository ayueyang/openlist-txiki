#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""r47：桌面两件（linux x86_64 tar.gz / win x64 zip）通用组装器。

以 work/porter-r46-01-tpn-1135/build-archives-r46.py 为基线改造，配方一字未改：
  - tar：USTAR_FORMAT、mtime=1793119200、uid=gid=0、uname=gname=""、
    gzip 头 mtime=0 且 filename=产物名；成员顺序按路径 UTF-8 字节序，目录项在排序位置；
  - zip：date_time=(2026,10,28,0,0,0)、create_system=0、
    external_attr=(0o100000|mode)<<16、ZIP_DEFLATED；不含目录条目；
  - mode：目录 0755；run.sh / tjs 0755；其余 0644；
  - 五份许可证各两份（根目录 + usr/share/openlist-txiki/）；
  - 包内 SHA256SUMS：相对路径，覆盖除自身外全部文件，行格式 "sha  path"。

与 r46 一次性脚本的差异只在输入来源与判据位置：
  - 版本、补丁数、五件输入身份、dist 指纹、模板目录与三模板身份全部从 --inputs
    的 json 读，不再写死 VERSION / ANCHORS / DIST_TREE；
  - 七道门 G1-G7 全部在内存里判完，才允许在 --out 落盘；失败 exit 1 且
    --out 不产生任何新文件、同名旧产物不动；
  - 参数缺失或 inputs.json 字段缺失/类型不对：exit 2（usage 错，不落盘）；
  - 渲染仍调公开仓 build/make-archives.py --render-only，参数与 r46 逐参一致；
  - 基线里写死 r46/r45 的 notices 计数检查已移除（版本锁死，通用脚本无法保留），
    由 G1/G2/G4 的通用判据替代。

CA-87 补件（FIX-1..4 + S1..S4）：
  - FIX-1：G4 拆成两条独立判据——SOURCE-OFFER 内 PATCH_RE 命中数 >=2、
    THIRD-PARTY-NOTICES 内命中数 >=1，且两份文件里每个命中值都等于 patch_count；
    报错带 file= 与实际值，不再按「合并命中总数」放行。
  - FIX-2：inputs.json 的 templates.files 增加 run.sh.in / run.cmd.in /
    README-Windows.md.in 三件的 sha256 与 bytes；G5 在调渲染器前逐项核存在、
    字节数、sha256 与 json 全等，另保留「模板目录与渲染器同级 assets 逐字节相同」。
  - FIX-3：G7 在内存 entries 组装完成后、任何落盘之前，对每个成员按
    utf-8 decode replace 后扫版本串模式 0.1.0-rNN，命中值不等于 version 即
    fail("STALE_VERSION_IN_ARCHIVE", member=..., values=...)；
    verify() 里的同扫描保留作二道。
  - FIX-4：T3 的 bundle/tjs/dist 来源与「真正冷重建未验证」写进交付 README。
  - S1：r46 输入样例的受控落点是 scripts/apk/build-archives.inputs.r46.json，
    发版时随版本更新；不用同一次运行的 --record 写回自己的 json 再自证。
  - S2/S3/S4：G1/G2 行匹配先 lstrip（已做）；渲染目录每次整目录新建（mkdtemp）；
    渲染器用 sys.executable（已做）。

用法：
  python scripts/apk/build-archives.py --inputs <inputs.json> --out <dir> \
      --renderer <make-archives.py> [--record]

inputs.json 必填字段：
  version, patch_count,
  bundle{path,sha256,bytes}, tjs_linux{...}, tjs_win{...},
  dist{path,tree_sha256,bytes,files},
  offer{path,sha256,bytes}, notices{path,sha256,bytes},
  templates{dir, files{run.sh.in{sha256,bytes}, run.cmd.in{sha256,bytes},
                       README-Windows.md.in{sha256,bytes}}}
路径可为绝对路径，或相对当前工作目录。
"""
import argparse
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

MTIME = 1793119200
ZIP_DT = (2026, 10, 28, 0, 0, 0)
LIC_SUB = "usr/share/openlist-txiki"
VER_RE = re.compile(r"0\.1\.0-r\d+")
PATCH_RE = re.compile(r"(\d+) 个补丁")
TEMPLATE_NAMES = ("README-Windows.md", "run.cmd", "run.sh", "BUILD.md")
# FIX-2：进 inputs.json 并逐项核身份的三件模板（带 .in 后缀）
TEMPLATE_IDS = ("run.sh.in", "run.cmd.in", "README-Windows.md.in")

# 五份许可证全文与固定身份（与 r46 一次性脚本同一组锚点）
LICENSES = {
    "LICENSE.AGPL-3.0": "6f1e622c82a380075843bb084a7ec3b1f1d12a4a02526d75e78b0924a860aa75",
    "LICENSE.Apache-2.0": "29fd5f7287b1834c40d3d350d10f9c66ac52bd6c3f8fbb4dbc8306fde79034d5",
    "LICENSE.LGPL-3.0": "e3a994d82e644b03a792a930f574002658412f62407f5fee083f2555c5f23118",
    "LICENSE.MIT": "e7fb66b7a4722f5a531a418762d649c574e96edbb741312d2afce0e638e31462",
    "LICENSE.MIT-OpenList-Frontend": "584ee10e15ea2aea53397728b21378d094204a2880db4558ba8238705fc0d527",
}
# 许可证可能所在的相对目录（仓库根、源码树根、归档根各按此顺序找）
LICENSE_RELDIRS = ("licenses", "packaging/openlist-txiki/licenses", "scripts/apk/licenses")

# 固定成员名单（不含 dist 与 SHA256SUMS），基础件数由它算出来，不写死 468/469
BASE_LINUX = ("SOURCE-OFFER", "THIRD-PARTY-NOTICES", "openlist-txiki.js", "tjs", "run.sh")
BASE_WIN = ("SOURCE-OFFER", "THIRD-PARTY-NOTICES", "openlist-txiki.js", "tjs.exe",
            "run.cmd", "README-Windows.md")


class UsageError(Exception):
    """参数或 inputs.json 不合规：exit 2。"""


class GateError(Exception):
    """判据失败：exit 1，不落盘。"""


def sha(b):
    return hashlib.sha256(b).hexdigest()


def read(p):
    with open(p, "rb") as f:
        return f.read()


def fail(reason, **kw):
    detail = " ".join("%s=%s" % (k, v) for k, v in kw.items())
    raise GateError("%s%s" % (reason, (" " + detail) if detail else ""))


def need(obj, key, typ, where):
    if not isinstance(obj, dict):
        raise UsageError("INPUTS_NOT_OBJECT %s" % where)
    if key not in obj:
        raise UsageError("INPUTS_FIELD_MISSING %s.%s" % (where, key))
    val = obj[key]
    if typ is int and isinstance(val, bool):
        raise UsageError("INPUTS_FIELD_TYPE %s.%s want=int got=bool" % (where, key))
    if not isinstance(val, typ):
        raise UsageError("INPUTS_FIELD_TYPE %s.%s want=%s got=%s"
                         % (where, key, typ.__name__, type(val).__name__))
    return val


def load_inputs(path):
    if not os.path.isfile(path):
        raise UsageError("INPUTS_MISSING %s" % path)
    try:
        with open(path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception as e:  # noqa: BLE001 - 语法错一律 usage 错
        raise UsageError("INPUTS_JSON %s" % e)
    if not isinstance(cfg, dict):
        raise UsageError("INPUTS_NOT_OBJECT root")
    version = need(cfg, "version", str, "root")
    patch_count = need(cfg, "patch_count", int, "root")
    out = {"version": version, "patch_count": patch_count}
    for name in ("bundle", "tjs_linux", "tjs_win", "offer", "notices"):
        sub = need(cfg, name, dict, "root")
        out[name] = {
            "path": need(sub, "path", str, name),
            "sha256": need(sub, "sha256", str, name),
            "bytes": need(sub, "bytes", int, name),
        }
    dist = need(cfg, "dist", dict, "root")
    out["dist"] = {
        "path": need(dist, "path", str, "dist"),
        "tree_sha256": need(dist, "tree_sha256", str, "dist"),
        "bytes": need(dist, "bytes", int, "dist"),
        "files": need(dist, "files", int, "dist"),
    }
    tpl = need(cfg, "templates", dict, "root")
    tf = need(tpl, "files", dict, "templates")
    tpl_out = {"dir": need(tpl, "dir", str, "templates"), "files": {}}
    for n in TEMPLATE_IDS:
        spec = need(tf, n, dict, "templates.files")
        tpl_out["files"][n] = {
            "sha256": need(spec, "sha256", str, "templates.files." + n),
            "bytes": need(spec, "bytes", int, "templates.files." + n),
        }
    out["templates"] = tpl_out
    return out, cfg


def identity(p, label):
    if not os.path.isfile(p):
        fail("INPUT_MISSING", which=label, path=p)
    b = read(p)
    return b, sha(b), len(b)


def compute_dist(d):
    """递归收集 dist 普通文件；tree = sha256(按名排序的 'name\\tsha' 行 + 换行)。"""
    if not os.path.isdir(d):
        fail("DIST_MISSING", path=d)
    files = {}
    for root, _dirs, names in os.walk(d):
        for f in names:
            p = os.path.join(root, f)
            rel = os.path.relpath(p, d).replace("\\", "/")
            files[rel] = read(p)
    if not files:
        fail("DIST_EMPTY", path=d)
    total = sum(len(v) for v in files.values())
    lines = "\n".join("%s\t%s" % (n, sha(files[n])) for n in sorted(files))
    tree = sha((lines + "\n").encode())
    return files, total, tree


def gate_offer(offer_text, version, patch_count, notices_text):
    # G1 版本行：恰好 1 行，取 openlist-txiki 之后、（ 之前的串，整串等于 version
    prefix = "包名与版本："
    lines = [ln for ln in offer_text.splitlines() if ln.lstrip().startswith(prefix)]
    if len(lines) != 1:
        fail("OFFER_VERSION_LINES", count=len(lines))
    rest = lines[0].lstrip()[len(prefix):]
    if "openlist-txiki " not in rest:
        fail("OFFER_VERSION_SEPARATOR", line=lines[0])
    tail = rest.split("openlist-txiki ", 1)[1]
    if "（" not in tail:
        fail("OFFER_VERSION_SEPARATOR", line=lines[0])
    actual = tail.split("（", 1)[0]
    if actual != version:
        fail("OFFER_VERSION", expected=version, actual=actual)

    # G2 下载 tag：/releases/download/ 后到下一个 / 的段，整串等于 v+version
    dprefix = "下载地址："
    dlines = [ln for ln in offer_text.splitlines() if ln.lstrip().startswith(dprefix)]
    if len(dlines) != 1:
        fail("OFFER_TAG_LINES", count=len(dlines))
    url = dlines[0].lstrip()[len(dprefix):].strip()
    if "/releases/download/" not in url:
        fail("OFFER_TAG_SEPARATOR", url=url)
    seg = url.split("/releases/download/", 1)[1].split("/", 1)[0]
    if seg != "v" + version:
        fail("OFFER_TAG", expected="v" + version, actual=seg)

    # G3 占位符：offer 与 notices 里 @@ 零命中
    if "@@" in offer_text:
        fail("PLACEHOLDER_LEFT", file="SOURCE-OFFER")
    if "@@" in notices_text:
        fail("PLACEHOLDER_LEFT", file="THIRD-PARTY-NOTICES")

    # G4 补丁数（FIX-1）：两份文件各自独立判据——
    #   SOURCE-OFFER 命中数 >=2、THIRD-PARTY-NOTICES 命中数 >=1，
    #   且每份文件里每个命中值都等于 patch_count；报错必须带 file= 与实际值。
    for fname, text, minimum in (
            ("SOURCE-OFFER", offer_text, 2),
            ("THIRD-PARTY-NOTICES", notices_text, 1)):
        hits = PATCH_RE.findall(text)
        if len(hits) < minimum:
            fail("PATCH_COUNT_HITS", file=fname, hits=len(hits), need=minimum)
        bad = [h for h in hits if int(h) != patch_count]
        if bad:
            fail("PATCH_COUNT", file=fname, expected=patch_count,
                 actual=",".join(sorted(set(bad))), hits=",".join(hits))


def check_identity(cfg):
    data = {}
    for name in ("bundle", "tjs_linux", "tjs_win", "offer", "notices"):
        spec = cfg[name]
        b, got_sha, got_bytes = identity(spec["path"], name)
        if got_sha != spec["sha256"] or got_bytes != spec["bytes"]:
            fail("INPUT_IDENTITY", which=name,
                 expected="%s/%d" % (spec["sha256"], spec["bytes"]),
                 actual="%s/%d" % (got_sha, got_bytes))
        data[name] = b
    dist_files, dist_bytes, dist_tree = compute_dist(cfg["dist"]["path"])
    if (dist_tree != cfg["dist"]["tree_sha256"]
            or dist_bytes != cfg["dist"]["bytes"]
            or len(dist_files) != cfg["dist"]["files"]):
        fail("DIST_IDENTITY",
             expected="%s/%d/%d" % (cfg["dist"]["tree_sha256"], cfg["dist"]["bytes"],
                                    cfg["dist"]["files"]),
             actual="%s/%d/%d" % (dist_tree, dist_bytes, len(dist_files)))
    return data, dist_files


def find_license(name, roots):
    for root in roots:
        for rel in LICENSE_RELDIRS:
            p = os.path.join(root, rel, name)
            if os.path.isfile(p):
                return p
    fail("LICENSE_MISSING", name=name)


def load_licenses(cfg):
    offer_dir = os.path.dirname(os.path.abspath(cfg["offer"]["path"]))
    script_dir = os.path.dirname(os.path.abspath(__file__))
    roots = [
        os.path.dirname(offer_dir),      # 源码树根 / 归档根（offer 在 scripts/ 下）
        offer_dir,
        os.path.dirname(script_dir),     # 仓库根（scripts/apk/ 的上一级）
        script_dir,
        os.path.abspath(os.getcwd()),
    ]
    out = {}
    for name, want in LICENSES.items():
        p = find_license(name, roots)
        b = read(p)
        if sha(b) != want:
            fail("LICENSE_SHA", name=name, expected=want, actual=sha(b))
        out[name] = b
    return out


def render_assets(renderer, cfg, dist_count, tmpdir):
    """调公开仓渲染器 --render-only；模板目录先与渲染器自带 assets 逐字节对齐。"""
    if not os.path.isfile(renderer):
        raise UsageError("RENDERER_MISSING %s" % renderer)
    tpl_dir = os.path.abspath(cfg["templates"]["dir"])
    # G5（FIX-2）：调渲染器前逐项核三模板的存在、字节数、sha256 与 json 全等
    for n in TEMPLATE_IDS:
        p = os.path.join(tpl_dir, n)
        spec = cfg["templates"]["files"][n]
        if not os.path.isfile(p):
            fail("TEMPLATE_IDENTITY_MISSING", file=n, path=p)
        b = read(p)
        got = "%s/%d" % (sha(b), len(b))
        want = "%s/%d" % (spec["sha256"], spec["bytes"])
        if got != want:
            fail("TEMPLATE_IDENTITY", file=n, expected=want, actual=got)
    r_assets = os.path.join(os.path.dirname(os.path.abspath(renderer)), "assets")
    for n in TEMPLATE_NAMES:
        a = os.path.join(tpl_dir, n + ".in")
        b = os.path.join(r_assets, n + ".in")
        if not os.path.isfile(a):
            fail("TEMPLATE_MISSING", path=a)
        if not os.path.isfile(b) or read(a) != read(b):
            fail("TEMPLATE_SET_MISMATCH", name=n, templates=a, renderer_assets=b)

    render_dir = os.path.join(tmpdir, "render")
    cmd = [
        sys.executable,
        os.path.abspath(renderer),
        "--version", cfg["version"],
        "--release-dir", render_dir,
        "--bundle", os.path.abspath(cfg["bundle"]["path"]),
        "--tjs-win", os.path.abspath(cfg["tjs_win"]["path"]),
        "--dist-count", str(dist_count),
        "--render-only",
    ]
    print("render_cmd %s" % " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.stdout:
        sys.stdout.write(r.stdout)
    if r.stderr:
        sys.stderr.write(r.stderr)
    if r.returncode != 0:
        fail("RENDER_ASSETS", rc=r.returncode)
    out = {}
    for n in ("README-Windows.md", "run.sh", "run.cmd"):
        p = os.path.join(render_dir, "assets", n)
        if not os.path.isfile(p):
            fail("RENDER_MISSING", path=p)
        out[n] = read(p)
    text = out["README-Windows.md"].decode("utf-8")
    if ("（%d 个" % dist_count) not in text:
        fail("RENDER_DIST_COUNT_NOT_IN_README", dist_count=dist_count)
    for n, b in out.items():
        t = b.decode("utf-8", "replace")
        if "@@" in t:
            fail("TEMPLATE_PLACEHOLDER_LEFT", name=n)
        bad = [h for h in set(VER_RE.findall(t)) if h != cfg["version"]]
        if bad:
            fail("TEMPLATE_STALE_VERSION", name=n, versions=",".join(sorted(bad)))
    return out


def build_entries(platform, version, dist, lic, data, assets):
    entries = {}
    for n, b in lic.items():
        entries[n] = (b, 0o644)
        entries[LIC_SUB + "/" + n] = (b, 0o644)
    entries["SOURCE-OFFER"] = (data["offer"], 0o644)
    entries["THIRD-PARTY-NOTICES"] = (data["notices"], 0o644)
    entries["openlist-txiki.js"] = (data["bundle"], 0o644)
    if platform == "linux":
        entries["tjs"] = (data["tjs_linux"], 0o755)
        entries["run.sh"] = (assets["run.sh"], 0o755)
    else:
        entries["tjs.exe"] = (data["tjs_win"], 0o644)
        entries["run.cmd"] = (assets["run.cmd"], 0o644)
        entries["README-Windows.md"] = (assets["README-Windows.md"], 0o644)
    base = set(entries)
    fixed = set(LICENSES) | {LIC_SUB + "/" + n for n in LICENSES} | set(
        BASE_LINUX if platform == "linux" else BASE_WIN)
    if base != fixed:
        fail("STRUCTURE_BASE", platform=platform,
             missing=",".join(sorted(fixed - base)) or "-",
             extra=",".join(sorted(base - fixed)) or "-")
    for n, b in dist.items():
        entries["dist/" + n] = (b, 0o644)
    sums = "".join("%s  %s\n" % (sha(entries[n][0]), n) for n in sorted(entries))
    entries["SHA256SUMS"] = (sums.encode(), 0o644)

    # G6 结构：成员名唯一、无空名、无绝对路径、无 ..；文件数 = 基础件数 + dist.files + 1
    if len(entries) != len(fixed) + len(dist) + 1:
        fail("STRUCTURE_COUNT", platform=platform,
             expected=len(fixed) + len(dist) + 1, actual=len(entries))
    for n in entries:
        if not n:
            fail("STRUCTURE_EMPTY_NAME", platform=platform)
        if n.startswith("/") or re.match(r"^[A-Za-z]:", n):
            fail("STRUCTURE_ABS_PATH", platform=platform, name=n)
        if ".." in n.split("/"):
            fail("STRUCTURE_DOTDOT", platform=platform, name=n)
    return entries


def stale_values(text, version):
    """返回文本里所有不等于 version 的 0.1.0-rNN 命中值（去重排序）。"""
    return sorted({h for h in VER_RE.findall(text) if h != version})


def gate_stale_versions(entries, version):
    """G7（FIX-3）：落盘前对全部内存成员做 stale-version 扫描。

    成员按 utf-8 decode replace 后扫 0\\.1\\.0-r\\d+；任一命中值不等于 version
    即 fail，exit 1，--out 不产生任何新文件。verify() 里的同扫描保留作二道。
    """
    for name in sorted(entries):
        txt = entries[name][0].decode("utf-8", "replace")
        bad = stale_values(txt, version)
        if bad:
            fail("STALE_VERSION_IN_ARCHIVE", member=name,
                 values=",".join(bad))


def member_order(entries, root):
    dirs = {""}
    for n in entries:
        parts = n.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            dirs.add("/".join(parts[:i]))
    order = sorted(set(entries) | dirs, key=lambda s: s.encode())
    members = []
    for n in order:
        full = root + ("/" + n if n else "/")
        if n in entries:
            members.append((full, entries[n][0], entries[n][1]))
        else:
            members.append((full, None, 0o755))
    return members


def write_tar(members, path, gzname):
    import gzip
    with open(path, "wb") as f:
        with gzip.GzipFile(filename=gzname, mode="wb", fileobj=f, mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w", format=tarfile.USTAR_FORMAT) as t:
                for name, data, mode in members:
                    ti = tarfile.TarInfo(name)
                    ti.mtime = MTIME
                    ti.mode = mode
                    ti.uid = ti.gid = 0
                    ti.uname = ti.gname = ""
                    if data is None:
                        ti.type = tarfile.DIRTYPE
                        ti.size = 0
                        t.addfile(ti)
                    else:
                        ti.size = len(data)
                        t.addfile(ti, io.BytesIO(data))


def write_zip(members, path):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data, mode in members:
            if data is None:
                continue
            zi = zipfile.ZipInfo(name, date_time=ZIP_DT)
            zi.external_attr = (0o100000 | mode) << 16
            zi.create_system = 0
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, data)


def verify(path, members, kind, version):
    exp = {}
    for n, d, m in members:
        if kind == "zip" and d is None:
            continue
        exp[n.rstrip("/")] = (sha(d) if d is not None else None, m)
    got = {}
    if kind == "tar":
        with tarfile.open(path) as t:
            for m in t.getmembers():
                got[m.name.rstrip("/")] = (
                    sha(t.extractfile(m).read()) if m.isfile() else None, m.mode)
                if m.isfile():
                    txt = t.extractfile(m).read().decode("utf-8", "replace")
                    bad = stale_values(txt, version)
                    if bad:
                        fail("STALE_VERSION_IN_ARCHIVE", member=m.name,
                             values=",".join(bad))
    else:
        with zipfile.ZipFile(path) as z:
            badzip = z.testzip()
            if badzip is not None:
                fail("ZIP_TESTZIP", name=badzip)
            for i in z.infolist():
                data = z.read(i.filename)
                got[i.filename] = (sha(data), i.external_attr >> 16 & 0o777)
                txt = data.decode("utf-8", "replace")
                bad = stale_values(txt, version)
                if bad:
                    fail("STALE_VERSION_IN_ARCHIVE", member=i.filename,
                         values=",".join(bad))
    if set(got) != set(exp):
        fail("MEMBER_SET_DIFF", kind=kind,
             missing=",".join(sorted(set(exp) - set(got))[:5]) or "-",
             extra=",".join(sorted(set(got) - set(exp))[:5]) or "-")
    for n in sorted(exp):
        if exp[n][0] != got[n][0]:
            fail("MEMBER_BYTES", kind=kind, name=n)
        if (exp[n][1] & 0o777) != (got[n][1] & 0o777):
            fail("MEMBER_MODE", kind=kind, name=n,
                 expected="%o" % exp[n][1], actual="%o" % got[n][1])
    if kind == "tar":
        with tarfile.open(path) as t:
            mt = {m.mtime for m in t.getmembers()}
        if mt != {MTIME}:
            fail("TAR_MTIME", values=",".join(str(x) for x in sorted(mt)))
    else:
        with zipfile.ZipFile(path) as z:
            dts = {i.date_time for i in z.infolist()}
        if dts != {ZIP_DT}:
            fail("ZIP_DATE_TIME", values=str(sorted(dts)))
    print("verify_%s members=%d files=%d dirs=%d OK"
          % (kind, len(got), sum(1 for v in got.values() if v[0] is not None),
             sum(1 for v in got.values() if v[0] is None)))


def record_inputs(path, cfg_raw, cfg, dist_files, dist_bytes, dist_tree):
    """--record：把当前输入的 sha256/字节数写回 json（只证明盘面现状，见规格 R1）。"""
    for name in ("bundle", "tjs_linux", "tjs_win", "offer", "notices"):
        p = cfg[name]["path"]
        b = read(p)
        cfg_raw[name]["sha256"] = sha(b)
        cfg_raw[name]["bytes"] = len(b)
    cfg_raw["dist"]["tree_sha256"] = dist_tree
    cfg_raw["dist"]["bytes"] = dist_bytes
    cfg_raw["dist"]["files"] = len(dist_files)
    tpl_dir = os.path.abspath(cfg["templates"]["dir"])
    for n in TEMPLATE_IDS:
        b = read(os.path.join(tpl_dir, n))
        cfg_raw["templates"]["files"][n]["sha256"] = sha(b)
        cfg_raw["templates"]["files"][n]["bytes"] = len(b)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(cfg_raw, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("RECORD path=%s sha256=%s" % (path, sha(read(path))))


def run(args):
    cfg, cfg_raw = load_inputs(args.inputs)
    if not os.path.isfile(args.renderer):
        raise UsageError("RENDERER_MISSING %s" % args.renderer)
    version = cfg["version"]

    data, dist_files = check_identity(cfg)
    offer_text = data["offer"].decode("utf-8")
    notices_text = data["notices"].decode("utf-8")
    gate_offer(offer_text, version, cfg["patch_count"], notices_text)
    print("gate G1-G5 OK version=%s patch_count=%d dist_files=%d"
          % (version, cfg["patch_count"], len(dist_files)))

    # r48 B5：VERSION 缺失时给明确错误码，不抛 Python 栈（此前 read() 直接 FileNotFoundError）。
    vpath = os.path.join(cfg["dist"]["path"], "VERSION")
    if not os.path.isfile(vpath):
        fail("DIST_VERSION_MISSING", path=vpath)
    if "0.1.0-r" in read(vpath).decode("utf-8", "replace"):
        fail("DIST_VERSION_IS_PACKAGE_VERSION", path=vpath)

    lic = load_licenses(cfg)
    tmpdir = tempfile.mkdtemp(prefix="build-archives-")
    try:
        assets = render_assets(args.renderer, cfg, len(dist_files), tmpdir)
        root_l = "openlist-txiki-%s-linux-x86_64" % version
        root_w = "openlist-txiki-%s-win-x64" % version
        el = build_entries("linux", version, dist_files, lic, data, assets)
        ew = build_entries("win", version, dist_files, lic, data, assets)
        ml = member_order(el, root_l)
        mw = member_order(ew, root_w)
        print("linux members=%d (dirs=%d files=%d) ; win members=%d"
              % (len(ml), sum(1 for x in ml if x[1] is None), len(el), len(mw)))

        # G7（FIX-3）：内存 entries 组装完成、任何落盘之前，全成员 stale-version 扫描
        gate_stale_versions(el, version)
        gate_stale_versions(ew, version)
        print("gate G7 OK members=%d/%d version=%s" % (len(el), len(ew), version))

        tarball = os.path.join(args.out, "openlist-txiki-%s-linux-x86_64.tar.gz" % version)
        zippath = os.path.join(args.out, "openlist-txiki-%s-win-x64.zip" % version)
        tmp_t = os.path.join(tmpdir, "l.tar.gz")
        tmp_z = os.path.join(tmpdir, "w.zip")
        write_tar(ml, tmp_t, os.path.basename(tarball))
        write_zip(mw, tmp_z)
        verify(tmp_t, ml, "tar", version)
        verify(tmp_z, mw, "zip", version)

        os.makedirs(args.out, exist_ok=True)
        os.replace(tmp_t, tarball)
        os.replace(tmp_z, zippath)
        for p in (tarball, zippath):
            b = read(p)
            print("%s  bytes=%d  sha256=%s" % (os.path.basename(p), len(b), sha(b)))
        if args.record:
            record_inputs(args.inputs, cfg_raw, cfg, dist_files,
                          sum(len(v) for v in dist_files.values()),
                          cfg["dist"]["tree_sha256"])
        print("BUILD=PASS")
        return 0
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="r47 桌面两件组装器：七道门通过后才落盘")
    ap.add_argument("--inputs", required=True, help="inputs.json")
    ap.add_argument("--out", required=True, help="产物输出目录")
    ap.add_argument("--renderer", required=True, help="公开仓 build/make-archives.py")
    ap.add_argument("--record", action="store_true", help="把当前输入身份写回 json（默认关）")
    args = ap.parse_args(argv)
    try:
        return run(args)
    except UsageError as e:
        print("BUILD=FAIL reason=USAGE %s" % e)
        return 2
    except GateError as e:
        print("BUILD=FAIL reason=%s" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
