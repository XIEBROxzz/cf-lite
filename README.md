<div style="display: flex; align-items: center; gap: 24px; margin: 30px 0 20px 0;">
  <img src="https://github.com/eishare/X-Shield/blob/main/logo.png" alt="Xray-go Logo" width="100" style="display: block; border-radius: 14px; flex-shrink: 0; border: none;">
  <div style="font-size: 34px; font-weight: 900; line-height: 1.25; color: #24292e;">
  </div>
</div>
<br>

## Xray-go · Argo 隧道版 **CF-C** （VPS服务器版）
**XHTTP-Argo 双模隧道** / **Cloudflare 自动搭建** / **零端口暴露**
<br>

<p align="left" style="margin: 20px 0 16px 0;">
  <img src="https://img.shields.io/badge/Ubuntu-20.04%2B-E95420?style=flat-square&logo=ubuntu&logoColor=white" alt="Ubuntu">
  <img src="https://img.shields.io/badge/Debian-11%2B-A81D33?style=flat-square&logo=debian&logoColor=white" alt="Debian">
  <img src="https://img.shields.io/badge/CentOS-7%2F8%2F9-26252D?style=flat-square&logo=centos&logoColor=white" alt="CentOS">
  <img src="https://img.shields.io/badge/Alpine-Linux-0D5BE1?style=flat-square&logo=alpine&logoColor=white" alt="Alpine">
  <img src="https://img.shields.io/badge/Xray--go-V2.0-2ea44f?style=flat-square" alt="Version">
  <img src="https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square" alt="License">
</p>

---

## 🗂️ 三套方案：CF-A / CF-B / CF-C

同一个仓库里放着三套**互相独立**的方案，按需装其中一套即可（也可以并存，互不干扰）：

| 代号 | 脚本 | 一键命令 | 装出来的命令 | 定位 |
| :--- | :--- | :--- | :--- | :--- |
| **CF-A** | `xray_cf_lite.sh` | `bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/xray_cf_lite.sh)` | `x` | Xray + VLESS-WS + **CF Origin 证书**，域名 443 直连橙云回源，**不需要 cloudflared** |
| **CF-B** | `singbox-lite_tunnel.sh` | `bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/singbox-lite_tunnel.sh)` | `sb` | **sing-box** + cloudflared Argo 隧道（临时 / 固定），VLESS-WS、Trojan-WS 多节点并存 |
| **CF-C** | `xray-go.sh` | `bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/install.sh)` | `xg` | **Xray** + cloudflared Argo，CF 邮箱 + API Key 全自动，出 H2/H3 两条链接，零公网端口 |

一句话区分：

- **CF-A**：有域名、有 CF Origin 证书，想让节点直接落在 Cloudflare 上（WS + TLS 回源）。菜单 1-8：装节点 / 删节点 / 优选订阅 / 改 UUID·端口·路径 / 切换直连·NAT。
- **CF-B**：想要 sing-box 内核，或者一条脚本里同时跑多个 Argo 节点（VLESS-WS + Trojan-WS）。
- **CF-C**：只要 Argo、只要快——邮箱 + API Key 一把梭，隧道、ingress、DNS 全自动，装完就是两条现成链接。**本页讲的就是它。**

> **能不能装在同一台机器上？**
> CF-B 用 `sing-box` 服务 + `/usr/local/etc/sing-box`，和另外两套完全不冲突，可以共存。
> 但 **CF-A 和 CF-C 都会注册名为 `xray` 的服务**（CF-A 走官方 `xray.service` + `/usr/local/etc/xray`，CF-C 用 `/etc/xray` + 自建 `xray.service`），**同一台机器只能装其中一个**，否则会互相覆盖配置、抢同一个服务名。

---

## 🚀 核心特性

*   **☁️ 只做 Argo，一条链路到底**：不装公网端口、不需要公网 IP，服务器真实地址全程隐藏，流量从 Cloudflare 边缘进来。
*   **⚡ 双模隧道（H2 / H3）**：同一次部署生成两条节点链接。`H3-Argo` 第一跳走 UDP（QUIC），`H2-Argo` 走 TCP，网络封 UDP 时直接切过去。
*   **🔧 Cloudflare 全自动搭建**：填邮箱 + Global API Key，脚本自动建命名隧道 → 写 ingress → 建 DNS CNAME → 启动 cloudflared，不用进 CF 后台点。
*   **🛠️ 一键部署 + 菜单管理**：装依赖、装核心、装 cloudflared、生成配置、托管服务、输出链接全自动；装完即用 `xg` 菜单管理。
*   **🧩 单一数据源**：`meta.json` 是唯一事实来源，`config.json` 由它渲染。改了配置模板用 `xg rebuild` 重建，端口 / 密钥 / 链接都不变。
*   **✅ IPv6 支持**：已内置 Cloudflare 安全代理下载通道，IPv6 机型也能装。

> V2.0 起**只保留 Argo 隧道方案**，Reality / H3 直连已移除。需要直连协议请留在 V1.4。

---

## 📦 说明

| 节点 | 第一跳 | 隧道这一跳 | 适用场景 |
| :--- | :--- | :--- | :--- |
| **H3-Argo**（`alpn=h3`） | UDP | 部署时选 `quic` → UDP | 想要端到端 UDP，抗 QoS |
| **H2-Argo**（`alpn=h2`） | TCP | `http2` → TCP | 兼容性最好，UDP 被封时的退路 |

两条链接共用同一个 UUID、同一个隧道域名、同一个 `path`，只是第一跳的 ALPN 不同，客户端里可以同时导入。

---

## 💻 系统支持

| 系统平台 | 版本要求 | 状态 / 备注 |
| :--- | :--- | :--- |
| **Ubuntu** | 20.04+ | ✅ 支持（systemd） |
| **Debian** | 11+ | ✅ 支持（systemd） |
| **CentOS** | 7 / 8 / 9 Stream | ✅ 支持（systemd） |
| **Alpine** | 3.16+ | ✅ 支持（openrc / musl） |
| **容器环境** | 无 systemd/openrc | ✅ 自动降级为 direct 后台模式 |

<br>

**极简Ubuntu一键更新：**
```bash
apt update && apt install -y curl bash
```
<br>

**Alpine一键更新：**

```bash
apk update && apk add curl bash
```
<br>

---

## ⚙️ 快速安装

使用 SSH 登录服务器，以 `root` 权限运行。

### 方式一：一键安装（推荐）

安装管理命令 `xg`，**装完直接进入管理菜单**：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/install.sh)
```

安装完成后看到的就是主菜单：

```
  ══════════════════════════════════════════════
    Xray-go · Argo 隧道管理脚本    V2.0
  ══════════════════════════════════════════════
```

日常使用命令行快捷指令：

```bash
xg 1   # 管理菜单
xg 2   # 部署 / 重新部署 Argo 隧道
xg 3   # 查看节点链接
xg 4   # 查看运行状态
xg 5   # 卸载部署
```

### 方式二：装完直接部署

```bash
bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/install.sh) 2
```

或直接执行主脚本：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/xray-go.sh) deploy
```

**一键部署做了什么：**

1. 自动识别系统包管理器，安装 `curl jq openssl unzip` 等依赖
2. 从 GitHub 官方源下载 Xray-core 与 cloudflared（失败自动切 Cloudflare 安全代理），带 SHA-256 校验
3. 用你的 **CF 邮箱 + Global API Key** 校验凭据，读取账号下的 Zone / Account ID
4. 创建命名隧道 → 写云端 ingress（`http://127.0.0.1:<端口>`）→ 建 DNS CNAME → `<隧道ID>.cfargotunnel.com`
5. 生成 `/etc/xray/meta.json`，由它渲染 `/etc/xray/config.json`，并做 `xray -test` 校验
6. 写入服务（systemd / openrc / direct）并启动 Xray 与 cloudflared，开机自启
7. 输出 **H2-Argo / H3-Argo** 两条节点链接 + Base64 订阅，保存到 `/etc/xray/url.txt`

> 全程**不需要开放任何公网端口**，也不需要填服务器 IP。

---

## ☁️ Argo 隧道：邮箱 + API Key 自动搭建

**不用去 Cloudflare 后台手动建隧道**，脚本用你的邮箱 + Global API Key 全自动完成。

入口：

```bash
xg 2        # 命令行直接部署
xg deploy   # 同上
xg 1        # 菜单 → [1] 部署 / 重新部署 Argo 隧道
```

需要准备：

| 项目 | 说明 |
| :--- | :--- |
| Cloudflare 邮箱 | 账号登录邮箱 |
| Global API Key | CF 后台 → 我的个人资料 → API 令牌 → 查看 Global API Key |
| 隧道域名 | 如 `xnsd.xxxx.com`，域名必须已托管在同一账号下 |

部署时会依次问你三件事（都有默认值，回车即可）：

```
  Argo 隧道域名（如 a.example.com，需已托管在 CF）: xnsd.xxxx.com
  Argo 本地端口（回车 8001，需与 ingress 一致）:
  隧道协议 [http2/quic]（回车 http2）: quic
```

- **域名**：必须是完整主机名，隧道名会自动取首段（`xnsd.xxxx.com` → 隧道名 `xnsd`），同名隧道已存在则复用，不会重复创建
- **本地端口**：Xray 只在 `127.0.0.1:<端口>` 监听，不对外
- **隧道协议**：`quic` = 与 CF 边缘走 UDP；`http2` = 走 TCP（更稳）。选 `quic` 后客户端再用 `H3-Argo` 链接才是全段 UDP

凭据保存在 `/etc/xray/cf.json`（权限 600），下次自动复用。

### 删除 Argo 节点

`[3]` 或 `xg del-argo`：停止 cloudflared → 删除云端隧道（`cascade=true`）→ 删除对应 DNS 解析 → 清理 `argo.env` 与 meta 中的 Argo 字段 → **停掉 Xray**（此时已无任何节点）。

> 手动 Token 部署的节点没有记录隧道 ID，删除时会提示你去控制台手动清理。

### 手动模式（已有 Token）

```bash
ARGO_TOKEN="你的Token" ARGO_DOMAIN="a.example.com" ARGO_PORT="8001" ARGO_PROTOCOL="http2" \
bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/xray-go.sh) deploy
```

> 手动模式下 Cloudflare 后台需把该隧道的 Public Hostname 指向 `http://127.0.0.1:8001`。
> 协议选择建议：`http2` 默认 4 条连接，`quic` 默认 1 条连接，实测后择优。

---

## 🔎 怎么确认 Argo 走的是 UDP（QUIC）

Argo 链路有两跳，**两跳都走 UDP 才算全段 UDP**：

```
客户端 ──①──> Cloudflare 边缘 ──②──> cloudflared ──> 本机 Xray
   ① 由链接决定：H3-Argo(alpn=h3) = UDP，H2-Argo(alpn=h2) = TCP
   ② 由隧道 protocol 决定：quic = UDP，http2 = TCP
```

### 服务端这一跳（②）：`xg diag`

菜单 `[7]` 或 `xg diag`，会多出一段：

```
════════ Argo 传输（UDP / QUIC）════════
  配置协议 : quic   （cloudflared --protocol）
  日志协议 : quic   （protocol=xxx）
  边缘连接 : UDP 4 条 / TCP 0 条   （端口 7844）
  实际传输 : QUIC（UDP）
```

判定依据（按优先级）：

| 证据 | 说明 |
| :--- | :--- |
| 日志出现 `falling back` / `failed to dial to edge with quic` | 已回退，实际是 TCP |
| `ss -aunp` 里有 cloudflared 的 UDP 7844 连接 | 走 QUIC |
| 只有 `ss -atnp` 里的 TCP 7844 连接 | 走 HTTP/2 |
| 都没有连接但日志写 `protocol=quic` | 按日志判断 |

**关键坑**：`--protocol quic` 只是「请求用 QUIC」。如果这台机器到 Cloudflare 的 **UDP 7844 不通**，cloudflared 会**静默回退成 http2**——配置看着是 quic，实际跑的是 TCP。`xg diag` 里「配置 quic，但只有 TCP 连接」就是在报这个。

`xg status` 也有一行直接给结论：`Argo 传输: QUIC (UDP)` / `HTTP/2 (TCP)` / `QUIC 已回退 HTTP/2`。

### 手工核对（不用脚本也能查）

```bash
ps -ef | grep -o -- '--protocol [a-z0-9]*'          # 配置值
ss -aunp | grep cloudflared                          # 有输出 = QUIC 在跑
ss -atnp | grep cloudflared                          # 有输出 = HTTP/2 在跑
journalctl -u xray-argo -n 100 | grep -E 'protocol=|falling back'
tcpdump -ni any udp port 7844                        # 抓到包就是真 UDP
```

---

## 🧹 日志刷 X-Forwarded-For 警告怎么办

```
[Warning] common/protocol/http: received "X-Forwarded-For" from 127.0.0.1:52878
but "sockopt.trustedXForwardedFor" is not configured; ignoring it and using the real remote address
```

**这是无害的**。Argo 的流量是 cloudflared 从 `127.0.0.1` 转进来的，每个 HTTP 请求都带一个 `X-Forwarded-For` 头；Xray 默认不信任任何来源的 XFF，于是忽略它、改用真实地址（`127.0.0.1`），并且**每个请求打一条 Warning**——所以一秒能刷十几条。

- 不影响连通性、不影响速度，只是日志刷屏、`/var/log/xray.log` 长得快
- V2.0 已给 Argo inbound 加上 `sockopt.trustedXForwardedFor: ["127.0.0.1/32", "::1/128"]`（该 inbound 只监听回环，信任本机是安全的）
- **老部署不用重装**，重建一次配置就消掉，端口 / 密钥 / 链接都不变：

```bash
xg update-script     # 先拿到 V2.0
xg rebuild           # 由 meta.json 重建 config.json 并重启
```

`xg diag` 会显示日志里这类警告的条数。如果 `xg rebuild` 之后还在刷，说明核心版本太老、不认识这个字段，用菜单 `[9]` 升级核心即可。

---

## 🎛️ 管理菜单

`xg` 或 `bash xray-go.sh`（不带参数）进入菜单：

| 选项 | 功能 |
| :--- | :--- |
| **[1] 部署 / 重新部署 Argo 隧道** | CF 邮箱 + API Key 自动搭建。重新部署会复用已有 UUID，链接里的密钥不变 |
| **[2] 查看节点链接** | 重新输出 H2-Argo / H3-Argo 两条链接与 Base64 订阅 |
| **[3] 删除 Argo 节点** | 停 cloudflared + 删云端隧道 + 删 DNS 解析 + 清本地配置 |
| **[4] 服务控制** | 启动 / 停止 / 重启 Xray、重启 Argo 隧道、查看状态 |
| **[5] Xray 日志** | 实时查看 `/var/log/xray.log` |
| **[6] Argo 日志** | 实时查看 cloudflared 日志 |
| **[7] 诊断** | `xray -test` 校验配置 + 自检（监听 / Argo 走 UDP 还是 TCP / 日志 / 结论） |
| **[8] 重建配置** | 由 `meta.json` 重新生成 `config.json` 并重启，**端口 / 密钥 / 链接全不变**。改了配置模板不必重新部署 |
| **[9] 更新核心** | 拉取 Xray-core 最新稳定版并热切换 |
| **[10] 更新脚本** | 从仓库拉取最新管理脚本，更新后显示 `V旧 -> V新` |
| **[11] 卸载部署** | 与 `uninstall.sh` 等价：停服务 + 删云端隧道 + 删 DNS 解析 + 删本地全部文件 + 删 `xg`，一次确认走完 |

命令行等价用法：

```bash
xg 1..5                       # 数字快捷指令（1 菜单 / 2 部署 / 3 链接 / 4 状态 / 5 卸载）
xg deploy | argo              # 部署 / 重新部署 Argo 隧道
xg del-argo | del-node        # 删除 Argo 节点（含云端隧道 + DNS）
xg links | status             # 链接 / 状态
xg start | stop | restart     # 控制 Xray 服务
xg log | argo-log             # 两类日志
xg rebuild | check | diag     # 重建配置 / 校验配置 / 连通性自检
xg update-core | update-script
xg uninstall
```

> 命令行数字（`xg 1`~`xg 5`）与菜单内编号（`[1]`~`[11]`）不是同一套，别混用。
> `xg reality` / `xg h3` / `xg custom` 在 V2.0 已移除，执行时会提示改用 Argo。

---

## 🏷️ 版本与更新

当前版本：**V2.0**（构建 2026-11-06）

想确认自己装的是哪一版、更新有没有成功，看这三处任一处即可：

```bash
xg -v                 # 输出: Xray-go V2.0 (2026-11-06)
xg status             # 状态页会显示「脚本版本 : V2.0 (2026-11-06)」
xg                    # 菜单标题栏直接显示 V2.0
```

更新脚本时的反馈规则：

| 情况 | 输出 |
| :--- | :--- |
| 远端版本更新 | `[成功] 脚本已更新: V1.4 -> V2.0` |
| 远端版本相同 | `[成功] 当前已是最新版本 V2.0，无需更新。` |
| 需要强行覆盖重装 | `xg update-script force` → `脚本已覆盖重装: V2.0（版本号未变化）` |

版本号写在 `xray-go.sh` 顶部：`export SCRIPT_VERSION="2.0"`，改这里即可发新版。

### 从 V1.x 升级到 V2.0 会怎样

| 你原来的部署 | 升级后 |
| :--- | :--- |
| 只有 Argo | ✅ 无感，配置和链接都不变 |
| Argo + Reality / H3 | ⚠️ V2.0 **只维护 Argo**。执行 `[1] 部署` 或 `[8] 重建配置` 时会先警告，确认后 Reality / H3 节点会被移除（这两个节点对应的服务停止，公网端口不再监听） |

想继续用 Reality / H3 直连，就**别升级**，留在 V1.4。V2.0 的定位是「只跑 Argo 的精简版」。

---

## 📁 目录与文件

| 路径 | 说明 |
| :--- | :--- |
| `/etc/xray/xray` | Xray-core 二进制 |
| `/etc/xray/cloudflared` | cloudflared 二进制 |
| `/etc/xray/meta.json` | 部署元数据（UUID、端口、Argo Token / 隧道 ID，权限 600）—— **唯一数据源** |
| `/etc/xray/config.json` | 主配置（由 `meta.json` 生成） |
| `/etc/xray/cf.json` | Cloudflare 邮箱 + Global API Key（权限 600） |
| `/etc/xray/argo.env` | Argo 隧道 Token（systemd EnvironmentFile，权限 600） |
| `/etc/xray/url.txt` | 节点链接（含明文凭据，权限 600） |
| `/var/log/xray.log` | Xray 运行日志 |
| `/var/log/xray-argo.log` | cloudflared 日志 |
| `/usr/local/bin/xg` | 管理命令 |

---

## 🗑️ 一键卸载

三种方式**完全等价，任选一条执行即可**，不需要都跑：

```bash
xg 5        # 命令行快捷指令
```

```bash
xg          # 进菜单后选 [11] 卸载部署
```

```bash
# 不依赖本地命令，直接拉最新卸载脚本执行（xg 被删/脚本损坏时用这个）
bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/uninstall.sh)
```

菜单 `[11]` 与 `uninstall.sh` 的清理范围完全一致，**只确认一次就一路走完**：

1. 停止并移除 Xray / Argo 服务（systemd unit、openrc 服务、direct 进程按 pidfile 精确 kill）
2. **删除 Cloudflare 云端隧道**（`cascade=true`）**与对应的 DNS 解析记录**
3. 无条件清理 systemd / openrc 的 unit 文件（不依赖当前运行模式判定，容器等混合环境也不会留残留）
4. 删除 `/etc/xray`（配置、cloudflared、`cf.json`、`argo.env`）、`/run/xraygo` 与 `/var/log/xray*.log`
5. 删除管理命令 `/usr/local/bin/xg`

确认前会先把**完整清单**列出来（含 `xg` 的路径），输入 `y` 后不再二次询问；卸载完成后脚本直接退出，不回主菜单。

**会保留的**：系统依赖（`curl` / `jq` / `openssl` / `unzip`）。

> 卸载后当前终端里如果还敲得动 `xg`，是因为**那个 bash 进程已经在内存里跑着**，磁盘上的 `/usr/local/bin/xg` 确实已删除。`Ctrl+D` 或关掉终端再试就没了（`ls /usr/local/bin/xg` 可验证）。

**唯一需要手动收尾**：Argo 是手动填 Token 部署的（`meta.json` 里没有 `tunnel_id`），脚本无从得知隧道归属，卸载时会提示你去 Cloudflare 控制台手动删隧道与 DNS。

---

## 🔧 Argo 不通怎么排查

Argo 的链路是「客户端 → CF 边缘 → cloudflared → 本机 Xray」，任何一环断都会表现为「连不上」。菜单 `[7]` 或 `xg diag` 会自动跑完下面第 1~3 项并给出结论。

**1. 本机 Xray 有没有在监听**

```bash
ss -lntp | grep 8001        # 换成你的 Argo 本地端口
```

- 有 `127.0.0.1:8001` → 服务端正常，问题在隧道或客户端
- 没有 → Xray 没起来，看 `/var/log/xray.log`；配置损坏就 `xg rebuild`

**2. cloudflared 有没有在跑、走的什么协议**

```bash
xg status                   # 看 Argo 是否「● 运行中」以及传输类型
ss -aunp | grep cloudflared  # 有输出 = QUIC（UDP）
ss -atnp | grep cloudflared  # 有输出 = HTTP/2（TCP）
```

- 两个都没有 → cloudflared 挂了，`[4] 服务控制` → 重启 Argo 隧道，或看 `/var/log/xray-argo.log`
- 只有 TCP 而配置是 `quic` → 本机到 CF 的 UDP 7844 不通，已被动回退。换网络 / 换机器，或干脆用 `H2-Argo` 链接

**3. 隧道与 DNS 有没有配对**

```bash
curl -s -H "X-Auth-Email: 你的邮箱" -H "X-Auth-Key: 你的Key" \
  "https://api.cloudflare.com/client/v4/accounts/账号ID/cfd_tunnel?is_deleted=false" | jq '.result[].name'
dig +short 你的域名          # 应解析到 Cloudflare 的 IP（橙云）
```

- 隧道在、DNS 不在 → 重跑 `[1] 部署`（同名隧道会复用，不会重复建）
- DNS 没走橙云（灰云）→ Argo 隧道只能用橙云代理的 CNAME

**4. 客户端参数**

- Xray 内核 **1.8.19+**（建议 25.x），传输层选 `xhttp`，`mode=auto`
- `H3-Argo` 链接：ALPN 填 `h3`；`H2-Argo` 链接：ALPN 填 `h2`。**ALPN 和链接不匹配直接握手失败**
- `host` 与 `sni` 都必须是隧道域名，`path` 必须和链接里的 `/xxxx-argo` 完全一致
- 本地 DNS 污染时，把链接里的地址换成 CF 优选 IP / 优选域名再试

**5. 运营商限制**

部分网络会干扰长时间 QUIC 连接。先换 `H2-Argo` 验证是不是 UDP 的问题；确认是 UDP 被限，就固定用 `H2-Argo`。
