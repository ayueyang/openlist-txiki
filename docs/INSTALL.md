# 安装与运行

## 一、OpenWrt apk（aarch64）

```sh
apk add --allow-untrusted ./openlist-txiki-<版本>.apk
```

安装后：

| 路径 | 内容 |
|---|---|
| `/usr/libexec/openlist-txiki/tjs` | 私有 tjs 运行时（不经系统包，不与其他服务共用） |
| `/usr/libexec/openlist-txiki/openlist-txiki.js` | 应用 bundle |
| `/etc/openlist-txiki/openlist-txiki.env` | 运行参数模板（首次安装时复制） |
| `/etc/openlist-txiki/admin.pass` | 初始管理员口令，`0600 root:root` |
| `/etc/openlist-txiki/data.db` | SQLite 数据库 |
| `/etc/openlist-txiki/rollback/` | 升级前留下的旧二进制与 `build-manifest.json`（数据库备份不在这里） |

首次启动：

```sh
cat /etc/openlist-txiki/admin.pass
/etc/init.d/openlist-txiki start
curl -s http://127.0.0.1:5345/api/public/settings
```

服务默认监听 `127.0.0.1:5345`，不对局域网开放。要对外提供访问，编辑 `/etc/openlist-txiki/openlist-txiki.env`：

```sh
LISTEN_ADDR=0.0.0.0
```

改完必须 `/etc/init.d/openlist-txiki restart`（env 只在进程启动时读取）。开 LAN 前务必换掉初始口令，并确认只在你自己的内网使用。

## 二、独立运行（Windows / Linux）

下载对应平台的 `tjs` 与 `openlist-txiki.js`，放在同一目录：

```sh
# Linux (aarch64 / x86_64)
./tjs run openlist-txiki.js

# Windows (x86_64)
tjs.exe run openlist-txiki.js
```

环境变量：

| 变量 | 说明 | 默认 |
|---|---|---|
| `TJS_PORT` | 监听端口 | `5345` |
| `TJS_LISTEN_ADDR` | 监听地址 | `127.0.0.1` |
| `TJS_DATA_DIR` | 数据目录（放 data.db） | 当前目录 |
| `TJS_JWT_SECRET` | JWT 密钥，生产必须自己设 | 空 |
| `TJS_ADMIN_PASS` | 首次建号口令；设了就用它，不设则从 `admin.pass` 读 | 空 |
| `OPENLIST_TXIKI_READONLY` | 只读模式开关，1 为只读 | `1` |

Windows 下建议写成 `.ps1` 或 `.cmd` 包装脚本，把上述变量设好再启动。

## 三、注意事项

- 数据目录必须可写，`data.db` 旁边会生成 `-wal` / `-shm`。
- 升级 apk 不会覆盖你改过的 `openlist-txiki.env`，但会替换 bundle 与 tjs。升级前的备份分两处：数据库备份在 `/etc/openlist-txiki/data.db.bak-<旧版本>`（`-wal`、`-shm` 成套备份，主文件超过 32 MiB 时跳过不备份）；旧 `tjs`、旧 bundle 与 `build-manifest.json` 在 `/etc/openlist-txiki/rollback/<旧版本>/`。两处默认都只留最近一份。
- 卸载（`apk del`）不会删除 `/etc/openlist-txiki`，数据还在；要清干净得手动删目录。
- 断电可能丢失最近数秒的配置写入（SQLite `synchronous=NORMAL`），数据库本身不会损坏；如需更强保证，可自行改 `DB_SYNC=FULL`（写放大明显）。
