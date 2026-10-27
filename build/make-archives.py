#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""渲染 assets 模板并打 Windows zip / x86_64-linux tar.gz，全程 fail-closed。

唯一模板源：本仓库 build/assets/*.in（占位符 @VERSION@）。
产物：
  <release-dir>/assets/README-Windows.md、run.cmd、run.sh、BUILD.md
  <release-dir>/openlist-txiki-<ver>-win-x64.zip
  <release-dir>/openlist-txiki-<ver>-linux-x86_64.tar.gz

fail-closed（任一成立即 rc=1，且不留下 zip/tar）：
  T1 模板缺失，或模板内含字面版本串（版本只许写 @VERSION@）
  T2 渲染后残留 '@@' 占位符
  T3 渲染后的 assets 里出现 '0.1.0-rN' 且不等于 --version
  T4 打出来的归档里任一条目出现 '0.1.0-rN' 且不等于 --version
  T5 归档条目字节与渲染源不一致，或缺条目

用法：
  python3 build/make-archives.py --version 0.1.0-r18 \\
      --release-dir artifacts/release-r18-HHMM \\
      --bin-dir artifacts/release-r18-HHMM/bin \\
      --legal-dir scripts/apk
  --template-dir 可覆盖模板目录（负向实测用）；--render-only 只渲染不打包。
"""
import argparse
import hashlib
import os
import re
import shutil
import sys
import tarfile
import tempfile
import zipfile

TEMPLATES = ("README-Windows.md", "run.cmd", "run.sh", "BUILD.md")
ASSETS_IN_ARCHIVE = ("README-Windows.md", "run.cmd", "run.sh")
VER_RE = re.compile(r"0\.1\.0-r\d+")
MTIME = 1793119200
FILE_MODES = {
    "README-Windows.md": 0o644,
    "run.cmd": 0o644,
    "run.sh": 0o755,
}


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def read_bytes(p):
    with open(p, "rb") as f:
        return f.read()


def render(template_dir, out_dir, version):
    """渲染模板到 out_dir；返回 {文件名: bytes}。任何不合规抛 SystemExit 式的 RuntimeError。"""
    os.makedirs(out_dir, exist_ok=True)
    rendered = {}
    for name in TEMPLATES:
        tpl_path = os.path.join(template_dir, name + ".in")
        if not os.path.isfile(tpl_path):
            raise RuntimeError("T1 TEMPLATE_MISSING %s" % tpl_path)
        tpl = read_bytes(tpl_path)
        text = tpl.decode("utf-8")
        if VER_RE.search(text):
            raise RuntimeError(
                "T1 TEMPLATE_HAS_LITERAL_VERSION %s: %s"
                % (tpl_path, VER_RE.search(text).group(0))
            )
        out = text.replace("@VERSION@", version).encode("utf-8")
        if "@@" in out.decode("utf-8", "replace"):
            raise RuntimeError("T2 PLACEHOLDER_LEFT %s" % name)
        hits = sorted(set(VER_RE.findall(out.decode("utf-8"))))
        bad = [h for h in hits if h != version]
        if bad:
            raise RuntimeError("T3 STALE_VERSION %s: %s" % (name, ",".join(bad)))
        rendered[name] = out
        with open(os.path.join(out_dir, name), "wb") as f:
            f.write(out)
    return rendered


def build_zip(entries, out_path):
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in entries:
            zi = zipfile.ZipInfo(name, date_time=(2026, 10, 28, 0, 0, 0))
            zi.external_attr = ((0o100000 | FILE_MODES.get(name, 0o644)) & 0xFFFF) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, data)


def build_tgz(entries, out_path):
    with tarfile.open(out_path, "w:gz", format=tarfile.USTAR_FORMAT) as t:
        for name, data in entries:
            ti = tarfile.TarInfo(name)
            ti.size = len(data)
            ti.mtime = MTIME
            ti.mode = FILE_MODES.get(name, 0o644)
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            import io

            t.addfile(ti, io.BytesIO(data))


def verify_archive(archive_path, expected, version):
    """T4/T5：读回归档逐条比对，并扫版本串。"""
    names = {}
    if archive_path.endswith(".zip"):
        with zipfile.ZipFile(archive_path) as z:
            for n in z.namelist():
                names[n] = z.read(n)
    else:
        with tarfile.open(archive_path) as t:
            for m in t.getmembers():
                if m.isfile():
                    names[m.name] = t.extractfile(m).read()
    for n, data in sorted(names.items()):
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        bad = sorted({h for h in VER_RE.findall(text) if h != version})
        if bad:
            raise RuntimeError("T4 STALE_VERSION_IN_ARCHIVE %s:%s: %s"
                               % (os.path.basename(archive_path), n, ",".join(bad)))
    for n, data in expected.items():
        if n not in names:
            raise RuntimeError("T5 ENTRY_MISSING %s:%s" % (os.path.basename(archive_path), n))
        if names[n] != data:
            raise RuntimeError("T5 ENTRY_BYTES_DIFF %s:%s" % (os.path.basename(archive_path), n))
    return sorted(names)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--release-dir", required=True)
    ap.add_argument("--bin-dir", default=None)
    ap.add_argument("--legal-dir", default=None)
    ap.add_argument("--template-dir", default=None)
    ap.add_argument("--render-only", action="store_true")
    a = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    pub = os.path.dirname(here)
    tpl_dir = a.template_dir or os.path.join(here, "assets")
    bin_dir = a.bin_dir or os.path.join(a.release_dir, "bin")
    legal_dir = a.legal_dir or os.path.join(pub, "scripts")
    rel = a.release_dir
    assets_dir = os.path.join(rel, "assets")

    try:
        rendered = render(tpl_dir, assets_dir, a.version)
        print("render_ok templates=%d version=%s" % (len(rendered), a.version))
        for n in TEMPLATES:
            print("  %-18s %6d B  %s" % (n, len(rendered[n]), sha256_bytes(rendered[n])))
        if a.render_only:
            print("RENDER_ONLY_DONE")
            return 0

        legal = {
            "SOURCE-OFFER": read_bytes(os.path.join(legal_dir, "SOURCE-OFFER")),
            "THIRD-PARTY-NOTICES": read_bytes(os.path.join(legal_dir, "THIRD-PARTY-NOTICES")),
        }
        for n, data in legal.items():
            bad = sorted({h for h in VER_RE.findall(data.decode("utf-8")) if h != a.version})
            if bad:
                raise RuntimeError("T3 STALE_VERSION legal %s: %s" % (n, ",".join(bad)))

        sub = lambda *p: os.path.join(*p)
        win_entries = [
            ("tjs.exe", read_bytes(sub(bin_dir, "tjs-x86_64-windows.exe"))),
            ("openlist-txiki.js", read_bytes(sub(bin_dir, "openlist-txiki.js"))),
            ("run.cmd", rendered["run.cmd"]),
            ("README-Windows.md", rendered["README-Windows.md"]),
            ("SOURCE-OFFER", legal["SOURCE-OFFER"]),
            ("THIRD-PARTY-NOTICES", legal["THIRD-PARTY-NOTICES"]),
        ]
        lnx_entries = [
            ("tjs", read_bytes(sub(bin_dir, "tjs-x86_64-linux-musl"))),
            ("openlist-txiki.js", read_bytes(sub(bin_dir, "openlist-txiki.js"))),
            ("run.sh", rendered["run.sh"]),
            ("SOURCE-OFFER", legal["SOURCE-OFFER"]),
            ("THIRD-PARTY-NOTICES", legal["THIRD-PARTY-NOTICES"]),
        ]
        sums = lambda entries: ("SHA256SUMS", "\n".join(
            "%s  %s" % (sha256_bytes(d), n) for n, d in entries).encode() + b"\n")
        win_entries.append(sums(win_entries))
        lnx_entries.append(sums(lnx_entries))

        zw = os.path.join(rel, "openlist-txiki-%s-win-x64.zip" % a.version)
        tl = os.path.join(rel, "openlist-txiki-%s-linux-x86_64.tar.gz" % a.version)
        tmpdir = tempfile.mkdtemp(prefix="mkarch-")
        tzw = os.path.join(tmpdir, "w.zip")
        ttl = os.path.join(tmpdir, "l.tar.gz")
        try:
            build_zip(win_entries, tzw)
            build_tgz(lnx_entries, ttl)
            for p, expected in ((tzw, dict(win_entries)), (ttl, dict(lnx_entries))):
                entries = verify_archive(p, {k: v for k, v in expected.items() if k != "SHA256SUMS"}, a.version)
                print("archive_ok %s entries=%s" % (os.path.basename(p), entries))
            os.replace(tzw, zw)
            os.replace(ttl, tl)
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

        for p in (zw, tl):
            print("%s  bytes=%d  sha256=%s" % (os.path.basename(p), os.path.getsize(p), sha256_bytes(read_bytes(p))))
        print("MAKE_ARCHIVES=PASS")
        return 0
    except Exception as e:  # noqa: BLE001 - fail-closed: 贴原因、清产物、rc=1
        print("MAKE_ARCHIVES=FAIL reason=%s" % e)
        for p in (os.path.join(rel, "openlist-txiki-%s-win-x64.zip" % a.version),
                  os.path.join(rel, "openlist-txiki-%s-linux-x86_64.tar.gz" % a.version)):
            if os.path.exists(p):
                os.remove(p)
                print("  removed %s" % p)
        return 1


if __name__ == "__main__":
    sys.exit(main())
