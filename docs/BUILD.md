# 从源码构建

三步：取上游 → 打补丁出 bundle → 编 tjs → 打包。

所有脚本都在 `build/` 与 `scripts/`，这里写步骤和约束；脚本里的命令是权威版本。

## 0. 依赖

- Node.js 20+ 与 pnpm（只用于构建 bundle 与跑上游测试）
- Zig 0.16.0（编 tjs）
- Linux 或 WSL（tjs 的构建脚本用 Linux 工具链；Windows 侧只用来跑成品）
- `apk` 工具链：用 OpenWrt SDK 或设备自带的 `apk mkpkg`（不要手工 tar，apk v3 是二进制格式）

## 1. 取上游（固定 commit）

```sh
git clone https://github.com/OpenListTeam/OpenList-Worker.git upstream
cd upstream
git checkout 5f53f58dd0f5e5d03eb6079da7f637fa151d8dca
```

**必须是 CRLF 检出**（补丁上下文按 CRLF 写）。若你的 git 配置会自动转换，用：

```sh
git -c core.autocrlf=true checkout 5f53f58dd0f5e5d03eb6079da7f637fa151d8dca
```

## 2. 打补丁

按 `patches/openlist/` 文件名编号顺序累进应用：

```sh
for p in ../patches/openlist/*.patch; do
  git apply --exclude='src/backend/txiki/*' "$p" || { echo "FAIL $p"; break; }
done
```

`--exclude` 是必须的：`src/backend/txiki/` 这一层由本移植自己提供，补丁里不涉及。

校验：`build/p2-source-manifest.txt` 记录了每个补丁的 sha256 与改动后的文件指纹，`build/build-txiki.mjs` 在构建前会逐条校验，不符即中止（fail-closed）。

## 3. 出 bundle

```sh
node build/build-txiki.mjs
```

产物是单文件 `openlist-txiki.js`（约 2MB），同时生成 `build-manifest.json`，记录上游 commit、补丁 sha、指纹条目数与 bundle sha256。

## 4. 编 tjs

tjs 来自 `qwtel/txiki-js` fork（26.9.0），需要打 `patches/txiki/` 下的 6 个补丁（TLS 1.2 PSS、LWS 客户端 ALPN、mbedtls QUIC、WAMR、流式请求体、异常中断补全）。

```sh
bash build/build-merged.sh
```

**关键约束：构建路径会进二进制。** tjs 源码里有约 170 条以自身绝对路径开头的字符串，同一棵树换个路径编出来的 sha 必变。要复现同一个 sha，必须把树放在记录的原路径（或用 `unshare -m` + `mount --bind` 挂到那个路径再编）。

## 5. 打包 apk

```sh
bash scripts/build-apk.sh <版本号>
```

脚本会校验 `package_version` 与版本号一致、`fault-inject` 计数为 0，然后调 `apk mkpkg` 出包。

## 6. 验证

出包后至少确认：

```sh
apk add ./openlist-txiki-<版本>-aarch64.apk
cat /etc/openlist-txiki/admin.pass
/etc/init.d/openlist-txiki start
curl -s http://127.0.0.1:5345/api/public/settings      # 期望 200，version v4.2.3
```

更完整的回归矩阵（82 条接口用例 + 文件名边界 + WebDAV 方法）不在本仓库内，属内部验收资产。
