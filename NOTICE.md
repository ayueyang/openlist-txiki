# NOTICE

## 上游与版本

- 应用：**OpenListTeam/OpenList-Worker**，许可证 AGPL-3.0
  固定基线 commit：`5f53f58dd0f5e5d03eb6079da7f637fa151d8dca`
  应用补丁：31 个，见 `patches/openlist/`（按文件名编号顺序累进 `git apply`）
- 运行时：**qwtel/txiki-js** fork（txiki.js 26.9.0），许可证 MIT
  tjs 侧补丁：7 个，见 `patches/txiki/`，逐个如下（前 6 个用于本版发布的三目标
  aarch64-linux-musl / x86_64-linux-musl / x86_64-windows，第 7 个只用于 aarch64-windows）：
  `p6-stream-body.patch`、`p6b-abort-incomplete-body.patch`、`mbedtls-tls12-pss.patch`、
  `lws-mbedtls-client-alpn-uaf.patch`、`mbedtls-quic.patch`、`wamr-zig.patch`、
  `libffi-aarch64-windows.patch`（仅 aarch64-windows，本版三目标不发它）

## 许可证归属

- 本仓库的补丁、构建脚本、文档：AGPL-3.0（与上游一致，便于整体再分发）
- txiki.js 及其补丁：MIT（补丁按 MIT 提供）
- 第三方随包组件与许可证全文在发布包的 `THIRD-PARTY-NOTICES` 与 `LICENSE.*` 中，包括 AGPL-3.0、MIT、Apache-2.0、LGPL-3.0-or-later

## 源码获取（AGPL-3.0 §13）

每个 Release 附带：

1. `openlist-txiki-source-<版本>.tar.gz`：上游 `5f53f58` 的完整源码树 + 全部补丁 + 构建脚本，足以重建同一份 bundle 与 tjs；
2. `SOURCE-OFFER`：书面要约，写明获取方式与有效期。

重建步骤见 `docs/BUILD.md`。

## 声明

本项目为个人自用向移植，不隶属于 OpenListTeam 或 txiki.js 维护者，也不代表其立场。上游若有独立修复，以本仓库补丁链与回归证据为准，不自动跟随上游版本。
