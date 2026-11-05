#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""openlist-txiki apk 变体打包：前端（standard|lite）× 运行时（bundled|shared）。

用法（在仓库根执行）：
  FRONTEND=lite   TJS=bundled OUT_DIR=artifacts/release-matrix-1010 python scripts/apk/build-variant.py
  FRONTEND=standard TJS=shared  OUT_DIR=... python scripts/apk/build-variant.py

参数全部走环境变量：
  FRONTEND   standard|lite（必填）
  TJS        bundled|shared（必填）
  BYTECODE   0|1（默认 0）。1=把包内 bundle 编译成独立二进制 openlist-txiki-bin 放进包，
             生成 A2 的 manifest 字段与 /usr/share/openlist-txiki/bytecode-identity.txt。
             编译器与模板都钉 r29 release（见下方 HOSTTJS/TEMPLATE 常量）。
  VERSION    默认 0.1.0-r40（bundle/补丁不变，只换前端与 init/依赖）
  BASE_STAGE 默认 work/porter-r40/stage（提供 bundle、tjs、固定件、manifest 基线）
  OUT_DIR    必填；apk 与 raw/ 落这里
  WORK_ROOT  默认 <PROJ>/work/porter-matrix-1010/build
  SRC_ARCHIVE 默认 work/porter-r40/out/openlist-txiki-source-<VERSION>.tar.gz
  DOCKER_IMAGE 默认钉死的 alpine（apk-tools 3.0.7-r0）

做的事（不改业务代码、不改 bundle/tjs 字节）：
  1. 复制 BASE_STAGE，替换 dist 为所选前端（tree sha 与钉死值比对）；
  2. 用 scripts/apk/openlist-txiki.init 覆盖包内 init（带 TJS_BIN/BUNDLED_TJS 的版本），
     shared 只改两行默认值（TJS_BIN=/usr/bin/tjs、BUNDLED_TJS=0）；
  3. 用 scripts/apk/build-manifest.mjs 重生成 build-manifest.json（web_dist / runtime / tjs_min_version）；
  4. shared 删掉包内 tjs；
  5. 钉死镜像里连打两次并 cmp，再解包逐文件与 stage 比对；
  6. 输出 apk 与测量 JSON（字节数、sha256、installed-size、文件数、dist tree、init tjs 路径、Depends）。
"""
import difflib
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys

PROJ = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
IMG = os.environ.get("DOCKER_IMAGE", "alpine@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000")

VERSION = os.environ.get("VERSION", "0.1.0-r40")
FRONTEND = os.environ.get("FRONTEND", "")
TJS = os.environ.get("TJS", "")
BASE_STAGE = os.path.abspath(os.environ.get("BASE_STAGE", os.path.join(PROJ, "work/porter-r40/stage")))
OUT_DIR = os.path.abspath(os.environ.get("OUT_DIR", "")) if os.environ.get("OUT_DIR") else ""
WORK_ROOT = os.path.abspath(os.environ.get("WORK_ROOT", os.path.join(PROJ, "work/porter-matrix-1010/build")))
SRC_ARCHIVE = os.path.abspath(os.environ.get(
    "SRC_ARCHIVE", os.path.join(PROJ, "work/porter-r40/out/openlist-txiki-source-%s.tar.gz" % VERSION)))
# r40 驱动拆分：chunk 清单以构建脚本产出的 build-manifest.json 为准（含 rel/bytes/sha256）。
SPLIT_MANIFEST = os.path.abspath(os.environ.get(
    "SPLIT_MANIFEST",
    os.path.join(PROJ, "work/porter-r40-split/out/split-b1/build-manifest.json")))

# A2 字节码：编译器与模板都钉 r29 release。两者 sha 由 conductor 13:52 实取核实
# （artifacts/release-r29-0745/bin 与 candidate），编译器与模板同构建。
BYTECODE = os.environ.get("BYTECODE", "0")
# A2：包版本与源码归档版本解耦。bundle/patches 不变时，源码归档仍是旧版本那份，
# SOURCE-OFFER 与 manifest 的源码字段必须指向真实归档，不能跟着包版本编造。
OFFER_VERSION = os.environ.get("OFFER_VERSION", VERSION)
SRC_NAME = os.environ.get("SOURCE_ARCHIVE_NAME", "openlist-txiki-source-%s.tar.gz" % VERSION)
SRC_URL = os.environ.get(
    "SOURCE_ARCHIVE_URL",
    "https://github.com/ayueyang/openlist-txiki/releases/download/v%s/%s" % (VERSION, SRC_NAME))
HOSTTJS = os.path.abspath(os.environ.get(
    "HOSTTJS", os.path.join(PROJ, "artifacts/release-r29-0745/bin/tjs-x86_64-windows.exe")))
TEMPLATE = os.path.abspath(os.environ.get(
    "TEMPLATE", os.path.join(PROJ, "artifacts/release-r29-0745/candidate/tjs")))

# r40：字节码编译必须在 POSIX 路径下跑。Windows 版 tjs compile 会把 chunk 说明符写成
# ".\chunks\x.js"（反斜杠），独立二进制换到设备上按 cwd 解析直接 could not load（设备实测）。
# WSL_COMPILE=1 时用 WSL 里的 Linux x86_64 musl 同版本编译器（v26.9.0）编译，产物同字节数。
WSL_COMPILE = os.environ.get("WSL_COMPILE", "0") == "1"


def wsl_path(p):
    p = os.path.abspath(p).replace("\\", "/")
    if len(p) > 2 and p[1] == ":":
        return "/mnt/" + p[0].lower() + p[2:]
    return p

# 冻版锚点：bundle 与 tjs 一个字节都不许变。
# r40 起 bundle 是拆分形态的主文件（esbuild splitting，main only；chunk 在 chunks/ 下）。
BUNDLE_SHA = "c435e26be38859168339f883cb84e7019fc9f3661840e014efc99db32b7cbd43"
BUNDLE_BYTES = 257847
TJS_SHA = "4b931f662c3ff56e80997fb48c407e9bf671360bcd34e8c91592ef60d1f74693"
TJS_BYTES = 5282808
PATCH_COUNT = 41
FILE_COUNT = 40
INPUTS_COUNT = 444

# A2 字节码钉死值：编译器、模板、trailer 语义。
HOSTTJS_SHA = "a991f1053b0dc8352008276fe57291bd1a161740edab6f81bde2784d77db2217"
HOSTTJS_BYTES = 5359184
TEMPLATE_SHA = "4b931f662c3ff56e80997fb48c407e9bf671360bcd34e8c91592ef60d1f74693"
TEMPLATE_BYTES = 5282808
TEMPLATE_ARCH = "aarch64"
TEMPLATE_E_MACHINE = 0xB7
TRAILER_MAGIC = b"tx1k1.js"
BC_VERSION = 27

# 官方前端 asset 的钉死身份（与 build-manifest.mjs 的 pin 同口径）。
FRONTEND_PINS = {
    "lite": {
        "archive": os.path.join(PROJ, "work/frontend/lite/openlist-frontend-dist-lite-v4.2.7.tar.gz"),
        "dir": os.path.join(PROJ, "work/frontend/lite/dist"),
        "archive_sha256": "6679861e3726305434f5de665a06880bd9a74aeab5ffc4c4150accef00e1c42d",
        "archive_bytes": 2966517,
        "file_count": 222,
        "bytes": 9384554,
        "tree_sha256": "507b55de4aac050c340b00ff3c8335755c0f11ef7700fc22ebe3554f6d26db8a",
        "index_sha256": "d2151c0c5e0aadc315e68b869c34f1e47030cbc20a266b5a0da3c79492348f47",
    },
    "standard": {
        "archive": os.path.join(PROJ, "work/frontend/standard/openlist-frontend-dist-v4.2.7.tar.gz"),
        "dir": os.path.join(PROJ, "work/frontend/standard/dist"),
        "archive_sha256": "88aba5260646ed784847a11e473880d749b17b80af53caf895fe1f31f36aa3e3",
        "archive_bytes": 20631035,
        "file_count": 452,
        "bytes": 58517793,
        "tree_sha256": "c107306c3f3d760d65bf9f615d92d9a9a67485d72e024b0e0d061178f63c5137",
        "index_sha256": "d39323e13b44e2e909a12d46bfe26141bed55012ee08ea1f6c8f71575e38193a",
    },
}

SUFFIX = {
    ("standard", "bundled"): "",
    ("lite", "bundled"): "-lite",
    ("standard", "shared"): "-shared-tjs",
    ("lite", "shared"): "-lite-shared-tjs",
}


def die(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def tree_facts(d):
    files = []
    for root, dirs, fs in os.walk(d):
        for n in fs:
            a = os.path.join(root, n)
            files.append(os.path.relpath(a, d).replace(os.sep, "/"))
    files.sort(key=lambda s: s.encode("utf-8"))
    lines = []
    total = 0
    for rel in files:
        a = os.path.join(d, rel)
        total += os.path.getsize(a)
        lines.append(rel + "\t" + sha256_file(a) + "\n")
    return len(files), total, hashlib.sha256("".join(lines).encode("utf-8")).hexdigest()


def rel(p):
    return os.path.relpath(p, PROJ).replace("\\", "/")


def docker(cmd):
    return ["docker", "run", "--rm", "--network", "none", "-v", PROJ + ":/w", "-w", "/w", IMG, "sh", "-c", cmd]


def run(cmd, log=None, cwd=None):
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", cwd=cwd)
    out = (r.stdout or "") + (r.stderr or "")
    if log:
        with open(log, "w", encoding="utf-8", newline="\n") as f:
            f.write(out)
    return r, out


def build_bytecode(work, stage, log_path):
    """A2：用钉死的 r29 编译器 + r29 aarch64 模板把包内 bundle 编成独立二进制。

    校验与 init 的五步门同源：模板身份（sha/字节/ELF e_machine）→ 编译 →
    产物前 template_bytes 与模板逐字节相同 → 尾 12 B magic 与偏移 → 构成等式 →
    字节码首字节 == BC_VERSION。任何一步不符直接 die，不出包。
    """
    import struct
    for p in (HOSTTJS, TEMPLATE):
        if not os.path.exists(p):
            die("缺输入 %s" % p)
    if sha256_file(HOSTTJS) != HOSTTJS_SHA or os.path.getsize(HOSTTJS) != HOSTTJS_BYTES:
        die("编译器身份不符：%s %d" % (sha256_file(HOSTTJS), os.path.getsize(HOSTTJS)))
    if sha256_file(TEMPLATE) != TEMPLATE_SHA or os.path.getsize(TEMPLATE) != TEMPLATE_BYTES:
        die("模板身份不符：%s %d" % (sha256_file(TEMPLATE), os.path.getsize(TEMPLATE)))
    head = open(TEMPLATE, "rb").read(20)
    if head[:4] != b"\x7fELF" or head[4] != 2:
        die("模板不是 ELF64")
    e_machine = struct.unpack("<H", head[18:20])[0]
    if e_machine != TEMPLATE_E_MACHINE:
        die("模板 e_machine=0x%X 不是 0x%X（AArch64）" % (e_machine, TEMPLATE_E_MACHINE))
    print("OK   template ELF64 e_machine=0x%X（%s）%d B %s" % (e_machine, TEMPLATE_ARCH, TEMPLATE_BYTES, TEMPLATE_SHA))

    bundle = os.path.join(stage, "usr/libexec/openlist-txiki/openlist-txiki.js")
    out = os.path.join(work, "openlist-txiki-bin")
    if os.path.exists(out):
        os.remove(out)
    if WSL_COMPILE:
        inner = "cd %s && %s compile -x %s ./openlist-txiki.js %s" % (
            shlex.quote(wsl_path(os.path.dirname(bundle))),
            shlex.quote(wsl_path(HOSTTJS)),
            shlex.quote(wsl_path(TEMPLATE)),
            shlex.quote(wsl_path(out)))
        r, log = run(["wsl", "-e", "bash", "-lc", inner], log_path)
    else:
        r, log = run([HOSTTJS, "compile", "-x", TEMPLATE, bundle, out], log_path,
                     cwd=os.path.dirname(bundle))
    if r.returncode != 0:
        print(log[-4000:])
        die("tjs compile rc=%d" % r.returncode)
    # Windows 上 tjs compile 对不带 .exe 的 outfile 会追加 .exe；只改名，不改字节。
    if not os.path.exists(out) and os.path.exists(out + ".exe"):
        os.replace(out + ".exe", out)
    if not os.path.exists(out):
        die("编译产物不存在：%s" % out)

    tpl = open(TEMPLATE, "rb").read()
    exe = open(out, "rb").read()
    if exe[:len(tpl)] != tpl:
        die("产物前 %d B 与模板不逐字节相同" % len(tpl))
    trailer = exe[-12:]
    if trailer[:8] != TRAILER_MAGIC:
        die("尾 12 B magic=%r 期望 %r" % (trailer[:8], TRAILER_MAGIC))
    off = struct.unpack("<I", trailer[8:])[0]
    if off != len(tpl):
        die("尾标偏移 %d 期望模板字节数 %d" % (off, len(tpl)))
    bc = exe[len(tpl):len(exe) - 12]
    if len(tpl) + len(bc) + 12 != len(exe):
        die("构成等式不成立：%d+%d+12 != %d" % (len(tpl), len(bc), len(exe)))
    if not bc or bc[0] != BC_VERSION:
        die("字节码首字节 %r 期望 %d" % (bc[0] if bc else None, BC_VERSION))

    dst = os.path.join(stage, "usr/libexec/openlist-txiki/openlist-txiki-bin")
    shutil.copyfile(out, dst)
    os.chmod(dst, 0o755)
    runner_src = os.path.join(PROJ, "scripts/apk/launch-bytecode.sh")
    runner_dst = os.path.join(stage, "usr/libexec/openlist-txiki/launch-bytecode.sh")
    if not os.path.exists(runner_src):
        die("缺启动器 %s" % runner_src)
    shutil.copyfile(runner_src, runner_dst)
    os.chmod(runner_dst, 0o755)

    # 引擎身份：编译器与模板同 release，用编译器的 --version 与 engine.versions 取值。
    if WSL_COMPILE:
        tjs_ver = run(["wsl", "-e", "bash", "-lc", wsl_path(HOSTTJS) + " --version"])[1].strip().splitlines()[0].strip()
        ev = run(["wsl", "-e", "bash", "-lc",
                  wsl_path(HOSTTJS) + " eval 'console.log(JSON.stringify(tjs.engine.versions))'"])[1].strip().splitlines()[0].strip()
    else:
        tjs_ver = run([HOSTTJS, "--version"])[1].strip().splitlines()[0].strip()
        ev = run([HOSTTJS, "eval", "console.log(JSON.stringify(tjs.engine.versions))"])[1].strip().splitlines()[0].strip()
    json.loads(ev)

    facts = {
        "exe_path": dst,
        "exe_sha256": sha256_file(dst),
        "exe_bytes": len(exe),
        "bytecode_sha256": hashlib.sha256(bc).hexdigest(),
        "bytecode_bytes": len(bc),
        "bytecode_offset": off,
        "bytecode_trailer": trailer[:8].decode("latin1"),
        "tjs_bc_version": bc[0],
        "tjs_version": tjs_ver,
        "tjs_engine_versions": ev,
        "tjs_compile_sha256": HOSTTJS_SHA,
        "tjs_template_sha256": TEMPLATE_SHA,
        "tjs_template_arch": TEMPLATE_ARCH,
    }
    print("OK   bytecode exe=%d B %s bc=%d B off=%d bc_version=%d tjs=%s" % (
        len(exe), facts["exe_sha256"], len(bc), off, bc[0], tjs_ver))
    return facts


def main():
    if FRONTEND not in ("standard", "lite"):
        die("FRONTEND 只接受 standard|lite（现为 %r）" % FRONTEND)
    if TJS not in ("bundled", "shared"):
        die("TJS 只接受 bundled|shared（现为 %r）" % TJS)
    if BYTECODE not in ("0", "1"):
        die("BYTECODE 只接受 0|1（现为 %r）" % BYTECODE)
    if not OUT_DIR:
        die("必须给 OUT_DIR")
    pin = FRONTEND_PINS[FRONTEND]
    variant = "%s-%s" % (FRONTEND, TJS)
    apk_name = "openlist-txiki-%s%s.apk" % (VERSION, SUFFIX[(FRONTEND, TJS)])
    print("VARIANT %s VERSION=%s APK=%s" % (variant, VERSION, apk_name))

    need_inputs = [BASE_STAGE, pin["dir"], pin["archive"], SRC_ARCHIVE, SPLIT_MANIFEST]
    if BYTECODE == "1":
        need_inputs += [HOSTTJS, TEMPLATE]
    for p in need_inputs:
        if not os.path.exists(p):
            die("缺输入 %s" % p)
    # 前端来源先核：archive sha/bytes 与解开的 dist 三项必须同时对上钉死值。
    if sha256_file(pin["archive"]) != pin["archive_sha256"] or os.path.getsize(pin["archive"]) != pin["archive_bytes"]:
        die("前端归档 %s 身份不符" % pin["archive"])
    n, b, tr = tree_facts(pin["dir"])
    if (n, b, tr) != (pin["file_count"], pin["bytes"], pin["tree_sha256"]):
        die("前端目录身份不符 files=%d bytes=%d tree=%s" % (n, b, tr))
    print("OK   frontend %s files=%d bytes=%d tree=%s" % (FRONTEND, n, b, tr))

    # r40：chunk 数量以构建清单为准；stage 里的 chunks 由 prepare-stage 放好。
    sm = json.load(open(SPLIT_MANIFEST, encoding="utf-8"))
    chunk_list = sm.get("chunks") or []
    if not chunk_list:
        die("SPLIT_MANIFEST 里没有 chunks：%s" % SPLIT_MANIFEST)
    chunk_count = len(chunk_list)
    split_drivers = sm.get("split_drivers") or []
    stage_chunks = os.path.join(BASE_STAGE, "usr/libexec/openlist-txiki/chunks")
    got_chunks = len([x for x in os.listdir(stage_chunks) if x.endswith(".js")]) if os.path.isdir(stage_chunks) else 0
    if got_chunks != chunk_count:
        die("BASE_STAGE chunks 文件数 %d 与构建清单 %d 不符" % (got_chunks, chunk_count))
    print("OK   chunks=%d split_drivers=%s" % (chunk_count, ",".join(split_drivers)))

    work = os.path.join(WORK_ROOT, variant)
    if os.path.isdir(work):
        shutil.rmtree(work)
    os.makedirs(work)
    os.makedirs(os.path.join(OUT_DIR, "raw"), exist_ok=True)
    stage = os.path.join(work, "stage")
    shutil.copytree(BASE_STAGE, stage, symlinks=True)

    # 1. 前端 dist 替换
    dist = os.path.join(stage, "usr/share/openlist-txiki/dist")
    if os.path.isdir(dist):
        shutil.rmtree(dist)
    shutil.copytree(pin["dir"], dist)
    n2, b2, tr2 = tree_facts(dist)
    if (n2, b2, tr2) != (pin["file_count"], pin["bytes"], pin["tree_sha256"]):
        die("进 stage 后 dist 身份不符 files=%d bytes=%d tree=%s" % (n2, b2, tr2))
    idx = os.path.join(dist, "index.html")
    if sha256_file(idx) != pin["index_sha256"]:
        die("index.html sha 与钉死值不符")

    # 2. init：仓内版本（带 TJS_BIN/BUNDLED_TJS）覆盖包内的旧 init；shared 只改两行
    init_src_bytes = open(os.path.join(PROJ, "scripts/apk/openlist-txiki.init"), "rb").read()
    init_dst = os.path.join(stage, "etc/init.d/openlist-txiki")
    init_bytes = init_src_bytes
    if TJS == "shared":
        old1 = b"TJS_BIN=${TJS_BIN:-$PKG_DIR/tjs}"
        old2 = b"BUNDLED_TJS=${BUNDLED_TJS:-1}"
        new1 = b"TJS_BIN=${TJS_BIN:-/usr/bin/tjs}"
        new2 = b"BUNDLED_TJS=${BUNDLED_TJS:-0}"
        for o in (old1, old2):
            if init_bytes.count(o) != 1:
                die("init 锚点缺失：%r 命中 %d 次" % (o, init_bytes.count(o)))
        init_bytes = init_bytes.replace(old1, new1).replace(old2, new2)
        diff = list(difflib.unified_diff(
            init_src_bytes.decode("utf-8").splitlines(True),
            init_bytes.decode("utf-8").splitlines(True), "init", "init(shared)"))
        changed = [l for l in diff if l.startswith(("+", "-")) and not l.startswith(("+++", "---"))]
        if len(changed) != 4:
            die("shared init 必须只改两行，实际 %d 行" % len(changed))
        print("OK   init shared 只改两行（2 删 + 2 增）")
    # 非字节码变体（BYTECODE=0，含 r40 重打与 shared）：包内没有 openlist-txiki-bin，
    # init 的默认形态必须是 source，否则默认 bytecode 会因为缺 bin 拒绝启动。
    if BYTECODE == "0":
        old_bc = b"TJS_MODE=${TJS_MODE:-bytecode}"
        new_bc = b"TJS_MODE=${TJS_MODE:-source}"
        if init_bytes.count(old_bc) != 1:
            die("init 默认形态锚点缺失：%r 命中 %d 次" % (old_bc, init_bytes.count(old_bc)))
        init_bytes = init_bytes.replace(old_bc, new_bc)
        print("OK   init 默认 TJS_MODE=source（本包不含独立二进制）")
    with open(init_dst, "wb") as f:
        f.write(init_bytes)
    os.chmod(init_dst, 0o755)
    tjs_path = "/usr/bin/tjs" if TJS == "shared" else "$PKG_DIR/tjs"
    print("OK   init TJS_BIN 默认=%s" % tjs_path)

    # 2.5 A2：编译独立二进制、放启动器；facts 供 manifest 与结果 JSON 用。
    bc_facts = None
    if BYTECODE == "1":
        bc_facts = build_bytecode(work, stage, os.path.join(OUT_DIR, "raw", "compile-%s.log.txt" % variant))

    # 3. manifest（tjs 字段要在删包内 tjs 之前算）
    bundle = os.path.join(stage, "usr/libexec/openlist-txiki/openlist-txiki.js")
    tjs_bin = os.path.join(stage, "usr/libexec/openlist-txiki/tjs")
    if sha256_file(bundle) != BUNDLE_SHA or os.path.getsize(bundle) != BUNDLE_BYTES:
        die("bundle 字节变了：%s %d" % (sha256_file(bundle), os.path.getsize(bundle)))
    if sha256_file(tjs_bin) != TJS_SHA or os.path.getsize(tjs_bin) != TJS_BYTES:
        die("tjs 字节变了：%s %d" % (sha256_file(tjs_bin), os.path.getsize(tjs_bin)))
    print("OK   bundle %d B %s / tjs %d B %s（未重编）" % (BUNDLE_BYTES, BUNDLE_SHA, TJS_BYTES, TJS_SHA))

    man = os.path.join(stage, "usr/share/openlist-txiki/build-manifest.json")
    cmd = ["node", os.path.join(PROJ, "scripts/apk/build-manifest.mjs"),
           "--bundle", bundle, "--tjs", tjs_bin,
           "--source-manifest", os.path.join(PROJ, "work/p2-source-manifest.txt"),
           "--version", VERSION, "--inputs", str(INPUTS_COUNT),
           "--web-dist", dist, "--web-dist-archive", pin["archive"],
           "--source-archive", SRC_ARCHIVE,
           "--source-archive-path", SRC_NAME,
           "--source-archive-url", SRC_URL,
           "--split-manifest", SPLIT_MANIFEST,
           "--out", man]
    if TJS == "shared":
        cmd += ["--runtime", "shared", "--tjs-min-version", "26.9.0"]
    if bc_facts:
        cmd += ["--exe", bc_facts["exe_path"],
                "--tjs-version", bc_facts["tjs_version"],
                "--tjs-engine-versions", bc_facts["tjs_engine_versions"],
                "--tjs-compile-sha256", bc_facts["tjs_compile_sha256"],
                "--tjs-template-sha256", bc_facts["tjs_template_sha256"],
                "--tjs-template-arch", bc_facts["tjs_template_arch"]]
    r = subprocess.run(cmd, cwd=PROJ, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr)
        die("build-manifest.mjs rc=%d" % r.returncode)
    m = json.load(open(man, encoding="utf-8"))
    checks = [
        ("package_version", m["package_version"], VERSION),
        ("bundle_sha256", m["bundle_sha256"], BUNDLE_SHA),
        ("tjs_sha256", m["tjs_sha256"], TJS_SHA),
        ("patch_count", m["patch_count"], PATCH_COUNT),
        ("file_count", m["file_count"], FILE_COUNT),
        ("inputs_count", m["inputs_count"], INPUTS_COUNT),
        ("chunk_count", m.get("chunk_count"), chunk_count),
        ("web_dist.tree_sha256", m["web_dist"]["tree_sha256"], pin["tree_sha256"]),
        ("web_dist.file_count", m["web_dist"]["file_count"], pin["file_count"]),
    ]
    for name, got, want in checks:
        if got != want:
            die("manifest %s=%r 期望 %r" % (name, got, want))
    if TJS == "shared":
        if m.get("runtime") != "shared" or m.get("tjs_min_version") != "26.9.0":
            die("manifest 缺 runtime/tjs_min_version")
    else:
        if "runtime" in m:
            die("bundled manifest 不应有 runtime 字段")
    if bc_facts:
        for name, want in (("exe_sha256", bc_facts["exe_sha256"]),
                           ("exe_bytes", bc_facts["exe_bytes"]),
                           ("bytecode_sha256", bc_facts["bytecode_sha256"]),
                           ("bytecode_bytes", bc_facts["bytecode_bytes"]),
                           ("bytecode_offset", bc_facts["bytecode_offset"]),
                           ("bytecode_trailer", bc_facts["bytecode_trailer"]),
                           ("tjs_bc_version", bc_facts["tjs_bc_version"]),
                           ("tjs_version", bc_facts["tjs_version"]),
                           ("tjs_compile_sha256", bc_facts["tjs_compile_sha256"]),
                           ("tjs_template_sha256", bc_facts["tjs_template_sha256"]),
                           ("tjs_template_arch", bc_facts["tjs_template_arch"])):
            if m.get(name) != want:
                die("manifest %s=%r 期望 %r" % (name, m.get(name), want))
        ident = os.path.join(stage, "usr/share/openlist-txiki/bytecode-identity.txt")
        lines = [
            "# openlist-txiki 字节码身份（A2）。字段与 build-manifest.json 同名。",
            "package_version=%s" % VERSION,
            "build_date=%s" % m["build_date"],
        ]
        for k in ("exe_sha256", "exe_bytes", "bytecode_sha256", "bytecode_bytes", "bytecode_offset",
                  "bytecode_trailer", "tjs_bc_version", "tjs_version", "tjs_compile_sha256",
                  "tjs_template_sha256", "tjs_template_arch"):
            lines.append("%s=%s" % (k, m[k]))
        lines.append("tjs_engine_versions=%s" % json.dumps(m["tjs_engine_versions"], separators=(",", ":"), sort_keys=True))
        with open(ident, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines) + "\n")
        print("OK   bytecode-identity.txt %d 行" % len(lines))
    print("OK   manifest %s runtime=%s web_dist=%d 文件/%d B" % (
        VERSION, m.get("runtime", "bundled"), m["web_dist"]["file_count"], m["web_dist"]["bytes"]))

    # 4. shared：包内不放 tjs
    if TJS == "shared":
        os.remove(tjs_bin)
        if os.path.exists(tjs_bin):
            die("shared stage 里仍有 tjs")
        print("OK   shared stage 无 tjs")
    # 5. 构建两次 + cmp
    logs = []
    for tag in ("run1", "run2"):
        out_apk = os.path.join(work, tag + ".apk")
        if os.path.exists(out_apk):
            os.remove(out_apk)
        inner = ("STAGE=/w/%s SCRIPTS=/w/scripts/apk OUT=/w/%s VERSION=%s SHARED_TJS=%d OFFER_VERSION=%s "
                 "BYTECODE=%s CHUNK_COUNT=%d TJS_MIN_VERSION=26.9.0 sh /w/scripts/apk/build-apk.sh") % (
            rel(stage), rel(out_apk), VERSION, 1 if TJS == "shared" else 0, OFFER_VERSION, BYTECODE, chunk_count)
        log = os.path.join(OUT_DIR, "raw", "build-%s-%s.log.txt" % (variant, tag))
        r, out = run(docker(inner), log)
        logs.append(log)
        if r.returncode != 0:
            print(out[-4000:])
            die("构建 %s rc=%d" % (tag, r.returncode))
    if open(os.path.join(work, "run1.apk"), "rb").read() != open(os.path.join(work, "run2.apk"), "rb").read():
        die("两次构建字节不一致")
    print("OK   两次构建 cmp rc=0")
    logtxt = open(logs[0], encoding="utf-8").read()

    def pick(prefix):
        for line in logtxt.splitlines():
            if line.startswith(prefix):
                return line.split("=", 1)[1].strip()
        return ""

    apk = os.path.join(OUT_DIR, apk_name)
    shutil.copyfile(os.path.join(work, "run1.apk"), apk)
    apk_bytes = os.path.getsize(apk)
    apk_sha = sha256_file(apk)
    if pick("SHA256") != apk_sha or int(pick("BYTES")) != apk_bytes:
        die("构建日志与产物身份不符")

    # 6. 解包逐文件比对（包内文件数取解包树）
    ex = os.path.join(work, "extract")
    if os.path.isdir(ex):
        shutil.rmtree(ex)
    os.makedirs(ex)
    inner = "cd /w/%s && apk extract --allow-untrusted /w/%s >/dev/null" % (rel(ex), rel(apk))
    r, out = run(docker(inner), os.path.join(OUT_DIR, "raw", "extract-%s.log.txt" % variant))
    if r.returncode != 0:
        print(out[-2000:])
        die("解包 rc=%d" % r.returncode)
    stage_files = {}
    for root, dirs, fs in os.walk(stage):
        for f in fs:
            a = os.path.join(root, f)
            stage_files[os.path.relpath(a, stage).replace(os.sep, "/")] = sha256_file(a)
    ex_files = {}
    for root, dirs, fs in os.walk(ex):
        for f in fs:
            a = os.path.join(root, f)
            ex_files[os.path.relpath(a, ex).replace(os.sep, "/")] = sha256_file(a)
    if stage_files != ex_files:
        missing = sorted(set(stage_files) - set(ex_files))
        extra = sorted(set(ex_files) - set(stage_files))
        diff = sorted(k for k in set(stage_files) & set(ex_files) if stage_files[k] != ex_files[k])
        die("解包与 stage 不一致 missing=%s extra=%s diff=%s" % (missing[:5], extra[:5], diff[:5]))
    print("OK   解包 %d 文件与 stage 逐文件 sha 相同" % len(ex_files))

    # 7. adbdump：Depends / installed-size
    adb = os.path.join(work, "adbdump.txt")
    r, out = run(docker("apk adbdump /w/%s" % rel(apk)), adb)
    if r.returncode != 0:
        die("adbdump rc=%d" % r.returncode)
    shutil.copyfile(adb, os.path.join(OUT_DIR, "raw", "adbdump-%s.txt" % variant))
    adb_txt = open(adb, encoding="utf-8", errors="replace").read()
    depends = []
    isize = ""
    adb_lines = adb_txt.splitlines()
    for i, line in enumerate(adb_lines):
        s = line.strip()
        if s.startswith("depends:"):
            j = i + 1
            while j < len(adb_lines) and adb_lines[j].startswith("    - "):
                depends.append(adb_lines[j].strip()[2:].strip())
                j += 1
        elif s.startswith("installed-size:"):
            isize = s.split(":", 1)[1].strip()
    if not isize:
        die("adbdump 读不到 installed-size")
    if int(isize) != sum(os.path.getsize(os.path.join(stage, k)) for k in stage_files):
        print("WARN installed-size=%s 与 stage 字节和不一" % isize)
    print("OK   installed-size=%s depends=%s" % (isize, " ".join(depends)))

    # 8. dist 树与 Depends 再从包内复核一次
    dist_in_apk = os.path.join(ex, "usr/share/openlist-txiki/dist")
    n3, b3, tr3 = tree_facts(dist_in_apk)
    if tr3 != pin["tree_sha256"]:
        die("包内 dist tree=%s 与钉死值不符" % tr3)

    init_in_apk = open(os.path.join(ex, "etc/init.d/openlist-txiki"), encoding="utf-8").read()
    line = [l for l in init_in_apk.splitlines() if l.startswith("TJS_BIN=")][0]

    result = {
        "variant": variant,
        "version": VERSION,
        "frontend": FRONTEND,
        "tjs": TJS,
        "apk_name": apk_name,
        "apk_path": rel(apk),
        "apk_bytes": apk_bytes,
        "apk_sha256": apk_sha,
        "installed_size": int(isize),
        "package_file_count": len(ex_files),
        "depends": depends,
        "init_tjs_line": line,
        "init_tjs_path": tjs_path,
        "frontend_dist": {
            "archive": os.path.basename(pin["archive"]),
            "archive_sha256": pin["archive_sha256"],
            "archive_bytes": pin["archive_bytes"],
            "file_count": n3,
            "bytes": b3,
            "tree_sha256": tr3,
            "index_sha256": pin["index_sha256"],
        },
        "bundle_sha256": BUNDLE_SHA,
        "bundle_bytes": BUNDLE_BYTES,
        "chunk_count": chunk_count,
        "split_drivers": split_drivers,
        "tjs_sha256": TJS_SHA,
        "tjs_bytes": TJS_BYTES,
        "manifest_sha256": sha256_file(os.path.join(ex, "usr/share/openlist-txiki/build-manifest.json")),
        "build_logs": [rel(logs[0]), rel(logs[1])],
    }
    if bc_facts:
        result["bytecode"] = {k: bc_facts[k] for k in (
            "exe_sha256", "exe_bytes", "bytecode_sha256", "bytecode_bytes", "bytecode_offset",
            "bytecode_trailer", "tjs_bc_version", "tjs_version", "tjs_compile_sha256",
            "tjs_template_sha256", "tjs_template_arch")}
    mj = os.path.join(OUT_DIR, "raw", "measure-%s.json" % variant)
    with open(mj, "w", encoding="utf-8", newline="\n") as f:
        json.dump(result, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print("RESULT %s" % json.dumps({k: result[k] for k in (
        "variant", "apk_name", "apk_bytes", "apk_sha256", "installed_size",
        "package_file_count", "init_tjs_path")}, ensure_ascii=False))
    print("DONE %s -> %s" % (variant, rel(apk)))


if __name__ == "__main__":
    main()
