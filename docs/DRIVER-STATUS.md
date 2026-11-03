# 驱动状态（DRIVER-STATUS）

调研日期：2026-11-04（Asia/Shanghai）
适用仓库：OpenList / OpenList-Worker / AList（AlistGo/alist）
用途：给适配排期一个"哪些驱动已经不能碰、哪些还能用"的底账。

本文只写查得到证据的结论。没有直接证据的，状态写「未验证」，不猜。

## 0. 先看结论

1. **115 Open 官方平台已暂停。** 2026-08-08 23:56 公告，2026-08-09 00:00 起停止对外服务；官方随后措辞改为"服务调整优化/系统维护"，恢复时间未公布。AList 文档 2026-08-21 直接判定"已关闭 Open 接口"。存量 token 在 2026-10-25 还有一次真账号全链路成功的记录，所以不是硬切断，但不能当稳定路径。
2. **115 现在唯一可持续的是 cookie/扫码版。** TV 扫码只是取 cookie 的推荐方式（避免把常用设备踢下线），不是另一套协议。OpenList 文档把这条标成"逆向接口、项目组不主动维护"。
3. **百度网盘青春版没有"已下线"的证据。** AList 2026-03-25 才新增 BaiduYouth 驱动，2026-04-19 维护者实测可正常挂载；网传"2023 年停止服务"只有媒体说法，与实测矛盾。OpenList 和 Worker 都没有这个驱动。
4. **天翼云盘现行推荐的是 189pc（PC 客户端协议），不是 189（网页协议）。** 189 的网页登录已改滑动验证码，不再支持 OCR/手动输入。我们移植的是 189 网页版。
5. **阿里云盘 Open 的中转是 OpenList 官方项目，但不是 SLA。** api.oplist.org 由 OpenListTeam/OpenList-APIPages 维护，可自建；阿里云盘 2025-12 起不再接受个人开发者，没有企业资质的话自建中转也拿不到 client id，只能共用公益服务器。
6. **明确不值得再投时间的：** 115 Open（平台暂停）、百度 Crack API（文档已标无法使用）、迅雷离线下载（上游标 hack-wont-fix）、腾讯视频（已下线）、Aliyundrive 旧版（已无法使用）。

## 1. 判定口径

| 状态 | 含义 |
|---|---|
| 可用 | 有 2026 年内的实测或官方文档正常说明，且没有未解决的致命 issue |
| 受限 | 能用，但有关键限制：登录方式受限、限速、必须代理、平台暂停、依赖第三方中转 |
| 已失效 | 官方公告、官方文档或实测明确不能用 |
| 已弃用 | 上游明确不再维护、已删除驱动或已停止对接（驱动代码可能还在，也可能还能跑） |
| 未验证 | 本次没有查到直接证据，不写结论 |

证据优先级：官方公告 > 官方文档 > 已合并 PR 里的实测记录 > 用户 issue/讨论。用户单方面报错只当线索，不当结论。

## 2. 判定表

| 驱动（上游名） | 认证方式 | 当前状态 | 证据（日期） | 对我们的影响 |
|---|---|---|---|---|
| 115 Open（Go `115_open` / Worker `115open`） | OAuth2 access/refresh token（115 开放平台） | 受限：新授权已停，存量时好时坏 | 115 公告 2026-08-08/09（IT之家 https://www.ithome.com/0/987/464.htm 、后续维护说明 https://www.ithome.com/0/987/610.htm ）；AList 文档 2026-08-21 判"已关闭"（https://alistgo.com/zh/guide/drivers/115_open.html ）；Worker PR #152 2026-10-25 真 token 全链路成功（https://github.com/OpenListTeam/OpenList-Worker/pull/152 ） | 我们树里的 `drivers/115` 和 `drivers/115open` **都是这条路线**，且 `drivers/115` 还带着双重 `/open` 的路径 bug（PR #152 已在上游删除该目录）。不能作为 115 的主路径。 |
| 115 Cloud（Go `115`，cookie/扫码） | Cookie；扫码可取 cookie（推荐 TV） | 可用；文档标注逆向接口、不主动维护 | OpenList 文档 https://doc.oplist.org/guide/drivers/115 （页脚最后更新 2025-12-06）；本项目真账号实测 2026-11-04（开发仓有完整记录） | 115 唯一可持续路径。新增 115cookie 驱动，保留 Open API 版仅作兼容，不投入新功能。 |
| 115 分享（`115_share`） | 分享链接 + 提取码 + cookie | 未验证 | 本次未查 | 我们已有目录，未适配；优先级低于个人盘。 |
| 百度网盘（`baidu_netdisk`） | OAuth refresh_token（官方开放平台） | 可用；有 errno 20016 间歇故障，删除重加可解；内置 client id 曾失效 | Issue #2839 2026-10-22（https://github.com/OpenListTeam/OpenList/issues/2839 ）；Discussion #2243 2026-03-21（https://github.com/orgs/OpenListTeam/discussions/2243 ） | 我们已适配，路线正确。`download_api` 里的 Crack 选项是死路，应隐藏或移除。 |
| 百度网盘青春版（`BaiduYouth`） | Cookie | 可用（截至 2026-04 实测）；2026-11 未复测 | AList 2026-03-25 新增驱动（https://github.com/AlistGo/alist/commit/c07cd1bf ）；Issue #9479 2026-04-26 维护者实测可挂载（https://github.com/AlistGo/alist/issues/9479 ）；"2023 停服"仅媒体说法（https://news.qq.com/rain/a/20260105A05C2300 ） | 我们树里没有这个驱动，OpenList 和 Worker 也都没有。**不需要适配**。 |
| 天翼云盘 189（网页协议） | 账号密码 + 滑动验证码 / Cookie | 受限：网页登录改滑动验证码，不再支持 OCR 与手动输入 | OpenList 文档 https://doc.oplist.org/guide/drivers/189 | 我们已适配的是这条；登录首跳还要设备 curl 兜底。建议排期换 189pc。 |
| 天翼云盘 189pc（PC 客户端协议） | 账号密码（PC 客户端登录，accessToken/sessionKey） | 可用；文档推荐首选，2026-09/10 仍在修登录 | 文档 189 页"建议首选使用天翼云盘客户端"；PR #3105 2026-10-03 对齐官方 PC 客户端（https://github.com/OpenListTeam/OpenList/pull/3105 ）；Issue #3320 2026-10-28（https://github.com/OpenListTeam/OpenList/issues/3320 ） | 我们树里有 `189pc` 代码，但 `storage.ts` 把 `189cloudpc` 路由到网页版 `Cloud189Driver`（storage.ts:763-774），等于没启用。要换得改路由并补测。 |
| 天翼云盘 189TV（`189_tv`） | 扫码/短信登录换 access_token | 可用；有用户反馈限速 | 文档 189 页 189CloudTV 段；Issue #2668 2026-09-03 保存出错（open，https://github.com/OpenListTeam/OpenList/issues/2668 ） | 我们已移植。网页版登录受阻时可作备选。 |
| 阿里云盘 Open（`aliyundrive_open`） | OAuth refresh_token + 中转换 token | 可用；依赖中转，个人开发者资质已关闭 | Discussion #1744 2025-12-06（https://github.com/orgs/OpenListTeam/discussions/1744 ）；官方中转仓 https://github.com/OpenListTeam/OpenList-APIPages （2026-10-18 仍活跃）；AList 中转证书过期事件 2026-08-18（https://github.com/AlistGo/alist/discussions/9623 ） | 我们已适配（patch 40）。保留中转，但文档要写清：公益服务、有限流、会故障；自建需企业开发者资质。 |
| 阿里云盘旧版 / 分享（`aliyundrive`） | 旧 OAuth | 已失效 | AList 文档：已经无法使用，后续不再开发和维护（https://alistgo.com/zh/guide/drivers/aliyundrive.html ） | 我们没有这条，不用管。 |
| 夸克（`quark`） | Cookie | 可用；限速，只能本地代理传输 | 文档 https://doc.oplist.org/guide/drivers/quark （"现在只能使用本地代理进行传输"）；我们已实测列目录与取链 | 已适配。必须走代理，不能 302。 |
| 迅雷（`thunder`） | 账号密码 + 滑块/creditkey | 受限：能挂载，但登录要设备验证，2026-09 仍有人卡在 need verify；离线下载上游标 hack-wont-fix | Discussion #3026 2026-09-02（https://github.com/orgs/OpenListTeam/discussions/3026 ）；Issue #2661 2026-07-23（label `hack-wont-fix`，https://github.com/OpenListTeam/OpenList/issues/2661 ） | 未适配。只做挂载/列目录可考虑；离线下载不要投。 |
| 移动云盘 139（`139`） | authorization / cookie（网页约 30 天，邮箱约 14 天） | 可用；旧上传路径有覆盖上传先删原文件的 bug（open） | Issue #3329 2026-10-30（https://github.com/OpenListTeam/OpenList/issues/3329 ）；Issue #3069 2026-09-10 cookie 有效期（https://github.com/OpenListTeam/OpenList/issues/3069 ） | 未适配。如做，只用新上传路径。 |
| 联通云盘（`wopan`） | refresh_token（工具获取；7 天或 2 个月两种） | 受限：逆向接口；2026-10-20 大面积挂载失败，已合并部分修复；刷新逻辑 PR 仍未合并 | Discussion #3127 2026-10-20 "本驱动为逆向接口，请等待有缘人修复"（https://github.com/orgs/OpenListTeam/discussions/3127 ）；PR #3222 2026-10-20 已合并；PR #3241 仍 open | 未适配。优先级低，等上游稳定。 |
| 蓝奏云（`lanzou`） | 账号密码 / Cookie / 链接 | 受限：账号密码登录失败；带密码文件不能下载（open）；Worker 正在适配新下载页 | Discussion #3038 2026-09-05（https://github.com/orgs/OpenListTeam/discussions/3038 ）；Issue #3238 2026-10-22（https://github.com/OpenListTeam/OpenList/issues/3238 ）；Worker PR #147 2026-11-03（https://github.com/OpenListTeam/OpenList-Worker/pull/147 ） | 未适配。等上游修完再说。 |
| PikPak（`pikpak`） | 账号密码 或 refresh_token | 可用；要求请求方 IP 与账号一致，或开代理 | 文档 https://doc.oplist.org/guide/drivers/pikpak （"谁发出请求谁能用"）；Worker PR #154 2026-10-26 修 CACHE 无链接回退（https://github.com/OpenListTeam/OpenList-Worker/pull/154 ） | 未适配。可作第二梯队。 |
| 腾讯视频（`vtencent`） | Cookie | 已失效 | AList 文档："已下线关闭服务，无法使用"（`aldocs/docs/zh/guide/drivers/vtencent.md`） | 我们没有这条。 |
| Febbox | Cookie | 受限：上传不可用 | OpenList 文档 https://doc.oplist.org/guide/drivers/febbox （"目前上传功能不可用"） | 未适配，需求低。 |
| 微云（`weiyun`） | Cookie | 受限：复制不可用 | OpenList 文档 https://doc.oplist.org/guide/drivers/weiyun （"复制功能无法使用"） | 未适配。 |

说明：OpenList 的 `115_open.md` 文档页最后更新停在 2025-12-06，**没有**写 2026-08-09 的暂停公告；AList 的同一页 2026-08-21 才补了"已关闭"警告。看文档时要以日期为准，别把没更新当成没问题。

## 3. 逐条核实

### 3.1 115 Open API 是否已被官方关闭

结论：**官方平台已暂停，新接入不可用；存量 token 还能跑，但不能当稳定服务。**

时间线：
- 2026-08-08 23:56，115 客服在社区发《115网盘API开放平台暂停服务公告》，2026-08-09 00:00 起暂停。报道：IT之家 https://www.ithome.com/0/987/464.htm 。
- 2026-08-09 晚间官方改口为"服务调整优化/系统维护"，说"小部分开发者或会受到服务波动影响"，基础功能和官方端不受影响，完成时间未公布：https://www.ithome.com/0/987/610.htm 。
- 2026-08-21，AList 文档把 115 Open 页改成"由于 115 网盘已关闭 Open 接口，后续无法继续使用 115 Open 进行对接"（commit `b88e704c`）。
- 2026-10-25，Worker PR #152 用真实 115 token 跑通 init/list/get/mkdir/rename/delete/refreshToken，说明存量授权还在工作（https://github.com/OpenListTeam/OpenList-Worker/pull/152 ）。

所以"官方已经关闭"这个说法要分两层：对**新授权**成立；对**存量 token** 不成立，但随时可能停，且官方没给恢复时间表。

### 3.2 115 cookie/TV 扫码版是否是当前唯一可行路径

结论：**是当前唯一可持续路径，但"TV 扫码"不是独立驱动，只是取 cookie 的推荐方式。**

- OpenList 的 115 驱动支持三种取 cookie 方式：二维码扫码（推荐 TV）、手动抓包、Python 脚本。推荐 TV 是因为用 Web/Android/iOS 扫码会把常用设备踢下线（文档 115 页）。
- OpenList 文档同时写明：这条是"基于历史产物的逆向接口，项目组不会主动维护，请勿针对此驱动提出修复 issue"。
- 本地真账号验证：2026-11-04，cookie 校验、根目录 16 项、`downurl` 取直链、44 B 文件下载 sha1 一致，四步全过。

结论落地：115 只保留 cookie 路线；Open API 版留作兼容，不再投入。

### 3.3 百度网盘青春版是否已被官方下线

结论：**没有可靠证据表明已下线；相反，2026-04 还有维护者实测可挂载。**

- AList 2026-03-25 新增 `drivers/baidu_youth`（commit `c07cd1bf`）。
- Issue #9479（2026-04-26）：用户报 cookie 登录失败，AList 维护者 `okatu-loli` 复测"至少在我这里是可以正常挂载的"，并给出 `https://pan.baidu.com/youth/pan/main` 的取 cookie 步骤；最后用户自己说"问题已经解决，鉴定为玄学问题"（https://github.com/AlistGo/alist/issues/9479 ）。
- 网传"2023 年百度网盘青春版停止服务"只有腾讯新闻一篇回顾文章（https://news.qq.com/rain/a/20260105A05C2300 ），没有官方公告原文，且与 2026-04 的实测矛盾，判为**未证实**。
- OpenList 和 OpenList-Worker 都没有 BaiduYouth 驱动；我们也没有。

结论落地：不用为青春版排期。真要做，只能从 AlistGo/alist 移植，且需求存疑。

### 3.4 天翼 189 与 189pc 的关系，哪个是现行

- `189`：网页协议。账号密码登录，现在网页端换成滑动验证码，OpenList 文档明确"不再支持 OCR 与手动输入"，要验证码只能用 Cookie 或改用客户端驱动。
- `189pc`：PC 客户端协议。用客户端那套登录换 accessToken/sessionKey，OpenList 文档在 189 页里单列"天翼云盘客户端 / 189 CloudPC"，并写"建议首选使用天翼云盘客户端"。
- 两者都在维护：189pc 2026-10-03 还有 PR #3105 对齐官方 PC 客户端登录；189 网页版 2026-09 还有时间格式修复。
- 我们的情况：`src/backend/internal/op/storage.ts` 的 189 分派（约 763-774 行）把 `189cloudpc` 也路由到 `Cloud189Driver`（网页版），`drivers/189pc/` 目录里的 PC 协议代码是死代码（目录里还有一份自相矛盾的 README 说"已删除"）。

结论：**现行推荐 189pc；我们跑的是受限的 189 网页版。** 要换得改路由 + 补测，属于中等工作量。

### 3.5 阿里云盘 Open 的中转是否官方支持、会不会随时关

- 官方支持：`api.oplist.org` 是 OpenList 官方项目 `OpenListTeam/OpenList-APIPages` 的部署（MIT，README 明确写着"用于 OpenList 获取部分网盘 API 的接口和页面"，支持 Cloudflare/EdgeOne/Docker 自建，2026-10-18 仍有提交）。
- 官方文档把它写进流程：OpenList 的 115 Open 和 Aliyundrive Open 文档都让人去 api.oplist.org 换 token，并注明"如果使用公益服务器/自建服务器，访问对应地址"。
- 但它不是 SLA：文档自己写了同一 IP 请求过多会 Too Many Requests；AList 侧的中转 `api.alistgo.com` 在 2026-08-18 出过证书过期，用户侧表现为 `x509: certificate has expired`，后来自行恢复（https://github.com/AlistGo/alist/discussions/9623 ）。
- 更硬的门槛：2025-12 的讨论指出阿里云盘不再接受个人开发者，没有企业资质就申请不到 client id/secret，自建中转也只能"看不能吃"，最终还得用公益服务器（https://github.com/orgs/OpenListTeam/discussions/1744 ）。

结论：**官方支持，但没有可用性承诺；会限流、会故障、可能停。** 我们能做的是：默认填官方地址、允许改 `api_url_address`、在文档里写清风险，不要把中转当自有基础设施。

### 3.6 迅雷、移动云盘 139、联通沃盘、蓝奏、PikPak

- 迅雷：挂载本身有人成功，但登录要过设备验证/滑块，2026-09 仍有人卡在 `need verify`（Discussion #3026）。离线下载被上游打了 `hack-wont-fix`（Issue #2661），不要再投。
- 139：可用，cookie 有效期网页约 30 天、邮箱约 14 天；旧上传路径覆盖上传会先删原文件，失败就丢数据（Issue #3329，open）。要做只用新上传路径。
- 联通沃盘：逆向接口，2026-10-20 大面积"不能挂载"，维护者在讨论里说"请等待有缘人修复"；当天合了 PR #3222（UA + 初始化前刷新 token），但更完整的 #3241 还开着。状态：受限。
- 蓝奏：账号密码登录报"密码不对"（Discussion #3038），带密码的文件下载失败（Issue #3238，open）；Worker 2026-11-03 有 PR #147 在适配新 `/fn` 下载页。状态：受限，等上游。
- PikPak：可用，但"谁发出请求谁能用"——服务器 IP 和你的 IP 不一致就播不了/下不了，除非开代理中转；Worker PR #154 修了 `usage=CACHE` 无链接时的回退。

## 4. 对我们（openlist-txiki）的直接影响

1. **115 两个驱动都是 Open API 路线。** `drivers/115`（Client115）和 `drivers/115open`（Pan115Driver）都走 `proapi.115.com/open`。前者还有 `API_BASE` 已含 `/open`、请求又拼 `/open/ufile/files` 的双重路径 bug；上游 PR #152 已把这个目录整个删掉（2026-10-25 合并）。我们的固定 commit 在删除之前，所以还带着它。
2. **189pc 没启用。** 代码在，路由没接；要换协议得改 `storage.ts` 的分派并补设备实测。
3. **百度 Crack API 是死选项。** OpenList 文档已标"非官方接口（已无法使用）"，我们的 `baidu_netdisk` 还保留 `download_api` 的 crack 值，应在表单里隐藏或标注。
4. **夸克必须代理。** 官方文档写明限速后只能本地代理传输；我们已按代理方式适配。
5. **青春版不用管。** 我们和 OpenList 都没有这个驱动。

## 5. 适配优先级建议

排序原则：先用"有没有证据证明可用"，再看"用户实际需求"，最后看"上游还在不在修"。

| 优先级 | 驱动 | 理由 | 建议 |
|---|---|---|---|
| P0 | 115 cookie/扫码 | 115 Open 已停，cookie 是唯一可持续路径；规格与真号读路径已验证 | 按 `arch-115-cookie-spec-0722` 实现；Open API 版留兼容不再加功能 |
| P1 | 189pc | 我们现有 189 网页版受限（滑块验证码 + TLS 指纹 + curl 兜底） | 改路由启用 189pc，设备实测后替换 189 作为推荐 |
| P1 | 阿里云盘 Open | 已适配，但中转是外部依赖 | 保持；文档写清中转风险；监控换 token 失败率 |
| P2 | 百度网盘 | 已适配，路线正确；有 20016 间歇故障 | 保持；隐藏 Crack 选项；内置 client id 失效时提示用户填自己的 |
| P2 | 夸克 | 已适配；限速必须代理 | 保持；确认代理路径不会被 302 绕过 |
| P2 | 139 | 用户有需求时可做；只用新上传路径 | 排期靠后 |
| P2 | PikPak | 可用，但同 IP 限制会带来大量"能挂不能播"的售后 | 做的话默认开代理 |
| P3 | 189TV | 备选，有限速反馈 | 保留现状 |
| 不做 | 115 Open 深适配 | 平台暂停，存量随时可能停 | 只修明显 bug，不投新功能 |
| 不做 | 百度 Crack API | 文档已判死 | 移除入口 |
| 不做 | 迅雷离线下载 | 上游 `hack-wont-fix` | 不排期 |
| 不做 | 腾讯视频 | 已下线 | 不排期 |
| 不做 | Aliyundrive 旧版/分享 | 已无法使用 | 不排期 |
| 不做 | 联通沃盘 | 逆向且 2026-10 大面积故障，修复未完成 | 除非用户点名，不排期 |
| 暂缓 | 蓝奏 | 上游正在修新下载页 | 等上游 PR 合并后再评估 |
| 不做 | 百度青春版 | 我们无驱动，需求存疑，且"已下线"未证实 | 不排期 |

## 6. 未验证

- 本次只覆盖点名的 10 个驱动，加上官方文档里明确写"失效/下线/不可用"的几个；其余 60 多个驱动没有逐个验证。
- 115 存量 token 的长期可用性：只有 2026-10-25 一次真账号实测，之后没再复测。
- 百度青春版 2026-11 的现状：最近证据停在 2026-04。
- 189pc 在 txiki 上的可行性：没移植、没实测；PC 协议里的加密与设备指纹是否依赖 Node 能力，未评估。
- 阿里云盘中转：2026-11-04 只做了首页 HTTP 200 探测（api.oplist.org 200、api.alistgo.com 302），没有跑真实换 token。
- 迅雷、沃盘、蓝奏、PikPak 的"可用"只依据文档和他人 issue/PR，没有我们自己的账号实测。

## 7. 证据索引

官方公告与文档：
- IT之家，115 API 开放平台暂停服务，2026-08-09：https://www.ithome.com/0/987/464.htm
- IT之家，115 维护说明（基础功能不受影响），2026-08-09：https://www.ithome.com/0/987/610.htm
- OpenList 115 文档（逆向接口说明）：https://doc.oplist.org/guide/drivers/115
- OpenList 115 Open 文档（未更新暂停公告）：https://doc.oplist.org/guide/drivers/115_open
- AList 115 Open 文档（2026-08-21 判关闭）：https://alistgo.com/zh/guide/drivers/115_open.html
- OpenList 189 文档：https://doc.oplist.org/guide/drivers/189
- OpenList 阿里云盘 Open 文档：https://doc.oplist.org/guide/drivers/aliyundrive_open
- OpenList 夸克文档：https://doc.oplist.org/guide/drivers/quark
- OpenList PikPak 文档：https://doc.oplist.org/guide/drivers/pikpak
- OpenList 沃盘文档：https://doc.oplist.org/guide/drivers/wopan
- AList Aliyundrive 旧版文档：https://alistgo.com/zh/guide/drivers/aliyundrive.html
- OpenList-APIPages（官方中转源码）：https://github.com/OpenListTeam/OpenList-APIPages

Issue / PR / Discussion：
- OpenList-Worker #128 115open 添加后无法使用：https://github.com/OpenListTeam/OpenList-Worker/issues/128
- OpenList-Worker #152 修复 115 驱动（旧驱动失效 + 子目录解析），2026-10-25 合并：https://github.com/OpenListTeam/OpenList-Worker/pull/152
- OpenList #2839 百度三种方式无法登录，2026-10-22：https://github.com/OpenListTeam/OpenList/issues/2839
- OpenList #3329 139 旧上传路径覆盖上传丢原文件，2026-10-30：https://github.com/OpenListTeam/OpenList/issues/3329
- OpenList #3238 蓝奏带密码文件无法下载，2026-10-22：https://github.com/OpenListTeam/OpenList/issues/3238
- OpenList #2661 迅雷离线下载失败（hack-wont-fix），2026-07-23：https://github.com/OpenListTeam/OpenList/issues/2661
- OpenList #3218 联通云盘无法使用，2026-10-20：https://github.com/OpenListTeam/OpenList/issues/3218
- OpenList #3105 189pc 对齐官方 PC 客户端登录，2026-10-03：https://github.com/OpenListTeam/OpenList/pull/3105
- Discussion #2916 115开放平台api会关闭吗（无回复）：https://github.com/orgs/OpenListTeam/discussions/2916
- Discussion #1744 阿里云盘不再接受个人开发者，2025-12-06：https://github.com/orgs/OpenListTeam/discussions/1744
- Discussion #2243 百度网盘无法正常挂载（empty token / client id），2026-03-21：https://github.com/orgs/OpenListTeam/discussions/2243
- Discussion #3026 迅雷 creditkey 后 need verify，2026-09-02：https://github.com/orgs/OpenListTeam/discussions/3026
- Discussion #3038 蓝奏账号密码登录失败，2026-09-05：https://github.com/orgs/OpenListTeam/discussions/3038
- Discussion #3127 联通网盘不能写入/不能挂载，2026-10-20：https://github.com/orgs/OpenListTeam/discussions/3127
- AlistGo/alist #9479 百度青春版 cookie 登录，2026-04-26：https://github.com/AlistGo/alist/issues/9479
- AlistGo/alist commit c07cd1bf 新增百度青春版驱动，2026-03-25：https://github.com/AlistGo/alist/commit/c07cd1bf
- AlistGo/alist Discussion #9623 阿里云盘中转证书过期，2026-08-18：https://github.com/AlistGo/alist/discussions/9623
