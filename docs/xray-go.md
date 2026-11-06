<div style="display: flex; align-items: center; gap: 24px; margin: 30px 0 20px 0;">
  <img src="../logo.png" alt="Xray-go Logo" width="100" style="display: block; border-radius: 14px; flex-shrink: 0; border: none;">
  <div style="font-size: 34px; font-weight: 900; line-height: 1.25; color: #24292e;">
  </div>
</div>
<br>

## Xray-go 极速/防QoS/抗封锁 部署方案 （VPS服务器版）
**XHTTP（H3直连）**/ **XHTTP-Argo 双模UDP隧道** / **VLESS-TCP-REALITY Vision**
<br>

<p align="left" style="margin: 20px 0 16px 0;">
  <img src="https://img.shields.io/badge/Ubuntu-20.04%2B-E95420?style=flat-square&logo=ubuntu&logoColor=white" alt="Ubuntu">
  <img src="https://img.shields.io/badge/Debian-11%2B-A81D33?style=flat-square&logo=debian&logoColor=white" alt="Debian">
  <img src="https://img.shields.io/badge/CentOS-7%2F8%2F9-26252D?style=flat-square&logo=centos&logoColor=white" alt="CentOS">
  <img src="https://img.shields.io/badge/Alpine-Linux-0D5BE1?style=flat-square&logo=alpine&logoColor=white" alt="Alpine">
  <img src="https://img.shields.io/badge/Xray--go-V1.2-2ea44f?style=flat-square" alt="Version">
  <img src="https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square" alt="License">
</p>

---

## 🚀 核心特性

*   **⚡ XHTTP H3 直连**：上下行流量分离，使用 HTTP/3 标准UDP传输，实现极低延迟与高并发吞吐。速度对标TUIC协议，但不易被运营商QoS。
*   **☁️ Argo 双模UDP隧道**：隧道protocol选择quic，客户端设置H3，让Argo隧道全段跑UDP！服务器 IP 隐藏、Cloudflare CDN 加速及零端口暴露。
*   **🔒 VLESS-TCP-REALITY Vision**：（最新封端口提醒！）经典抗封锁协议，完美伪装 TLS 流量，Vision流控，免疫主动探测。
*   **🛠️ 一键部署 + 菜单管理**：安装依赖、安装核心、生成配置、托管服务、放行端口、输出链接全自动；装完即用 `xg` 菜单管理。
*   **✅ IPv6支持**：已添加 Cloudflare 备选安全代理下载，完美支持IPv6机型。

---

## 📦 说明

| 协议组合 | 核心优势 | 适用场景 |
| :--- | :--- | :--- |
| **XHTTP + H3 (QUIC)** | ✅HTTP/3 标准 UDP 传输，不易被QoS | 主力高速直连协议 |
| **XHTTP + Argo 双模UDP隧道** | ✅Argo隧道变身UDP协议！隐藏真实 IP，内网穿透，支持优选域名/ip | IP 被墙或极限封锁网络环境 |
| **VLESS + TCP + REALITY Vision** | ✅无域名要求 | 晚高峰易受TCP拥塞影响，建议备选 |

---

## 💻 系统支持

| 系统平台 | 版本要求 | 状态 / 备注 |
| :--- | :--- | :--- |
| **Ubuntu** | 20.04+ | ✅ 支持（systemd） |
| **Debian** | 11+ | ✅ 支持（systemd） |
| **CentOS** | 7 / 8 / 9 Stream | ✅ 支持（自动适配防火墙） |
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
  ╔══════════════════════════════════════════╗
  ║     Xray-go 一键部署管理脚本 V1.2        ║
  ╚══════════════════════════════════════════╝
```

也可以在安装时直接带参数跳过菜单：

```bash
bash install.sh 2        # 装完直接一键部署 Reality + H3
bash install.sh custom   # 装完直接进自定义部署
```

日常使用命令行快捷指令：

```bash
xg 1   # 管理菜单
xg 2   # 一键部署（Reality + H3，端口可指定或回车随机）
xg 3   # 查看节点链接
xg 4   # 查看运行状态
xg 5   # 卸载部署
```

### 方式二：全自动一键部署（免交互）

装完即部署，部署完成后直接打印节点链接与 Base64 订阅：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/install.sh) 2
```

或直接执行主脚本：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/xray-go.sh) deploy
```

**一键部署做了什么：**

1. 自动识别系统包管理器，安装 `curl jq openssl unzip` 等依赖
2. 从 GitHub 官方源下载 Xray-core（失败自动切 Cloudflare 安全代理），带 SHA-256 校验
3. 生成自签证书、Reality 密钥对、UUID、端口（默认 30000-50000 随机，也可手动指定）
4. 生成 `/etc/xray/config.json` 并做 `xray -test` 校验
5. 写入服务（systemd / openrc / direct）并启动、开机自启
6. 自动放行 ufw / firewalld / iptables 端口
7. 输出节点链接 + Base64 订阅，保存到 `/etc/xray/url.txt`

> 部署过程中若没有 Argo 配置，会询问是否顺带用 Cloudflare 邮箱 + API Key 自动搭建 Argo 隧道。

### 方式三：单独部署某个协议

进菜单后按协议单独部署，互不影响：

| 选项 | 作用 |
| :--- | :--- |
| `[1]` | 只部署 / 重部署 **Reality Vision**，会问端口 + SNI（伪装目标） |
| `[2]` | 只部署 / 重部署 **H3 直连**，会问端口 + SNI + 可选自备证书 |
| `[3]` | **Argo 自动搭建**（可单独使用，也可叠加在已有节点上） |

命令行等价写法：

```bash
xg reality      # 只部署 Reality
xg h3           # 只部署 H3
xg argo         # 只搭 Argo
```

单独部署某个协议时，**其它已部署的协议会保留**，密钥与链接不变，不会掉线。

### 方式四：自定义部署（一次选多个协议）

```bash
bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/xray-go.sh) custom
```

交互选择是否部署 Reality、H3、Argo，以及各自端口（回车自动随机）。

### 端口写法（各部署入口通用）

| 输入 | 含义 |
| :--- | :--- |
| 直接回车 | 30000-50000 随机端口，内外一致 |
| `443` | 监听 443，节点也走 443 |
| `443:31000` | **监听 443，节点对外 31000**（NAT / 端口映射） |

`443:31000` 适用于云厂商端口转发、路由器 DNAT 这类场景：本机只在内部端口监听，客户端连的是映射出去的公网端口。配置里的 `port` 用前者，生成的链接用后者。

冒号**中英文都识别**：`443:31000` 和 `443：31000` 效果相同，前后多余空格（含全角空格）也会自动去掉。

状态页会显示成 `Reality=443→31000`，一眼能看出映射关系。

### SNI 与证书（Reality / H3 都能手填）

**Reality** 部署时多问一行（伪装目标域名，需是支持 TLS1.3 + H2 的真实站点）：

```
  Reality SNI (伪装目标) [回车 www.apple.com]:
```

- 直接回车 = 沿用上次部署记录，没有记录才用默认 `www.apple.com`
- 填了带 `http://`、路径或端口的非法值会提示并回退，不会把节点写坏
- 想换默认值：`REALITY_SNI=www.amd.com xg reality`（或部署前 `export REALITY_SNI=...`）

**H3** 走 TLS（QUIC），必须有一张证书。部署 H3 时脚本会多问两行：

```
  H3 SNI [回车 bing.com]:
  证书 crt 路径 [回车自签]:
```

| 场景 | 怎么填 | 生成的链接 |
| :--- | :--- | :--- |
| 默认（自签） | 两行都回车 | `sni=bing.com&...&allowInsecure=1` |
| 只换自签 SNI | 填 SNI，证书那行回车 | `sni=你填的域名&...&allowInsecure=1` |
| 自备域名证书 | 填 SNI + crt / key 路径 | `sni=证书域名&...`（**不再带 allowInsecure**） |

- 自签证书按 SNI 生成 `CN` 与 `SAN`（含 `DNS:<SNI>` 和服务器 IP），有效期 10 年
- 填了 crt/key 但**没填 SNI** 时，脚本读证书的 `CN` 自动把 SNI 对齐过去，避免「证书是 a.com、SNI 写 b.com」导致客户端握手失败
- 证书路径写错或文件不存在 → 自动退回自签，不会中断部署
- 重新部署 Reality 不会改动已配置的 H3 SNI / 证书
- `xg diag` 会打印证书 `CN` / `SAN` 和当前配置的 SNI，两者不一致会直接报警

> SNI 只影响 TLS 握手的域名与证书校验，**不影响 UDP 能否到达服务器**。H3 完全不通时，先看 `xg diag` 里的 UDP 监听那几项。

### Argo 隧道：邮箱 + API Key 自动搭建（推荐）

**不用去 Cloudflare 后台手动建隧道**，脚本用你的邮箱 + Global API Key 全自动完成：

1. 校验凭据并读取账号下的 Zone / Account ID
2. 创建命名隧道（**隧道名 = 域名首段**，如 `xnsd.xxxx.com` → `xnsd`；同名隧道已存在则复用，不会重复创建）
3. 写入云端 ingress（`http://127.0.0.1:<端口>`）
4. 自动创建 DNS CNAME → `<隧道ID>.cfargotunnel.com`（橙云代理）
5. 取回隧道 Token 并启动 cloudflared

入口三选一：

```bash
xg 1        # 菜单 → [3] Argo 自动搭建
xg argo     # 直接执行
```

或在 `[1]` 部署 Reality / `[2]` 部署 H3 / `[3]` Argo 自动搭建 的流程中按提示选择。

**可以只装 Argo，不装直连**：服务器上还没有任何部署时直接跑 `xg argo`（或菜单 `[3]`），脚本会创建「仅 Argo」节点——只生成 H2-Argo / H3-Argo 两条隧道节点，不开公网端口、不需要公网 IP。之后想要直连节点，再跑 `[1]` 一键部署即可。

需要准备：

| 项目 | 说明 |
| :--- | :--- |
| Cloudflare 邮箱 | 账号登录邮箱 |
| Global API Key | CF 后台 → 我的个人资料 → API 令牌 → 查看 Global API Key |
| 隧道域名 | 如 `xnsd.xxxx.com`，域名必须已托管在同一账号下 |

凭据保存在 `/etc/xray/cf.json`（权限 600），下次自动复用。

**删除 Argo 节点**（`[4]` 或 `xg del-argo`）：停止 cloudflared → 删除云端隧道（cascade）→ 删除对应 DNS 解析 → 清理 `argo.env` 与 meta 中的 Argo 字段 → 重建配置并重启 Xray。

> 手动 Token 部署的节点没有记录隧道 ID，删除时会提示你去控制台手动清理。

**手动模式（已有 Token）**

```bash
ARGO_TOKEN="你的Token" ARGO_DOMAIN="a.example.com" ARGO_PORT="8001" ARGO_PROTOCOL="http2" \
bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/xray-go.sh) deploy
```

> 手动模式下 Cloudflare 后台需把该隧道的 Public Hostname 指向 `http://127.0.0.1:8001`。
> 协议选择建议：`http2` 默认 4 条连接，`quic` 默认 1 条连接，实测后择优。

### 兼容旧版参数写法

原有的复合参数仍然可用（`port"xxxx"` 的解析已修复）：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/xray-go.sh) reality"n" h3"y" argo protocol"http2" port"8001" domain"" token""
```

| 参数 | 说明 |
| :--- | :--- |
| **reality"n"** | 放弃部署 reality 协议；`reality"y"` 随机端口；`reality"443"` 指定端口 |
| **h3"y"** | 部署 XHTTP H3 直连 + 随机端口；`h3"12345"` 指定端口；`h3"n"` 放弃 |
| **protocol"http2"** | Argo 隧道协议，可改 `quic` |
| **port"8001"** | Argo 本地端口，需与 Cloudflare Tunnel 服务 URL 末尾端口一致 |
| **domain""** | Cloudflare Tunnel 路由设置的完整主机名 |
| **token""** | 固定隧道 Token |

---

## 🎛️ 管理菜单

`xg` 或 `bash xray-go.sh`（不带参数）进入菜单：

| 选项 | 功能 |
| :--- | :--- |
| **[1] 部署 Reality** | 只部署 / 重部署 Reality Vision，端口可填 `443` / `443:31000` / 回车随机 |
| **[2] 部署 H3** | 只部署 / 重部署 H3 直连，端口写法同上 |
| **[3] Argo 自动搭建** | CF 邮箱 + API Key 建隧道。无部署时创建「仅 Argo」节点；已有部署时只补 Argo，不动现有直连 |
| **[4] 删除节点** | 子菜单任选：删 Reality / 删 H3 / 删 Argo（含云端隧道 + DNS 解析） |
| **[5] 查看节点链接** | 重新输出链接与 Base64 订阅 |
| **[6] 服务控制** | 启动 / 停止 / 重启 / 重启 Argo / 状态 |
| **[7] [8] 日志** | Xray 日志、Argo 日志实时查看 |
| **[9] 诊断** | `xray -test` 校验配置 + 连通性自检（TCP/UDP 监听、防火墙、证书、日志、结论） |
| **[10] 更新核心** | 拉取 Xray-core 最新稳定版并热切换 |
| **[11] 更新脚本** | 从仓库拉取最新管理脚本，更新后显示 `V旧 -> V新` |
| **[12] 卸载部署** | 与 `uninstall.sh` 等价：停服务 + 删云端隧道 + 删 DNS 解析 + 删本地全部文件 + 删 `xg`，一次确认走完 |

命令行等价用法：

```bash
xg 1..5                       # 命令行数字快捷指令（1 菜单 / 2 部署两者 / 3 链接 / 4 状态 / 5 卸载）
xg reality | h3 | argo        # 只部署单个协议
xg del-node | del-argo        # 删除节点（前者可选协议，后者直删 Argo）
xg deploy | custom | links | status | start | stop | restart | log | check | diag | update-core | update-script | uninstall
```

> 命令行数字（`xg 1`~`xg 5`）与菜单内编号（`[1]`~`[12]`）不是同一套，别混用。

---

## 🏷️ 版本与更新

当前版本：**V1.2**（构建 2026-11-06）

想确认自己装的是哪一版、更新有没有成功，看这三处任一处即可：

```bash
xg -v                 # 输出: Xray-go V1.2 (2026-11-06)
xg status             # 状态页会显示「脚本版本 : V1.2 (2026-11-06)」
xg                    # 菜单标题栏直接显示 V1.2
```

更新脚本时的反馈规则：

| 情况 | 输出 |
| :--- | :--- |
| 远端版本更新 | `[成功] 脚本已更新: V1.1 -> V1.2` |
| 远端版本相同 | `[成功] 当前已是最新版本 V1.2，无需更新。` |
| 需要强行覆盖重装 | `xg update-script force` → `脚本已覆盖重装: V1.2（版本号未变化）` |

版本号写在 `xray-go.sh` 顶部：`export SCRIPT_VERSION="1.2"`，改这里即可发新版。

---

## 📁 目录与文件

| 路径 | 说明 |
| :--- | :--- |
| `/etc/xray/xray` | Xray-core 二进制 |
| `/etc/xray/config.json` | 主配置（由 `meta.json` 生成） |
| `/etc/xray/meta.json` | 部署元数据（UUID、端口、密钥、Argo Token / 隧道 ID，权限 600） |
| `/etc/xray/cf.json` | Cloudflare 邮箱 + Global API Key（权限 600） |
| `/etc/xray/argo.env` | Argo 隧道 Token（systemd EnvironmentFile，权限 600） |
| `/etc/xray/url.txt` | 节点链接（含明文凭据，权限 600） |
| `/etc/xray/cert.pem` `private.key` | H3 自签证书 |
| `/var/log/xray.log` | 运行日志 |
| `/usr/local/bin/xg` | 管理命令 |

---

## 🗑️ 一键卸载

三种方式**完全等价，任选一条执行即可**，不需要都跑：

```bash
xg 5        # 命令行快捷指令
```

```bash
xg          # 进菜单后选 [12] 卸载部署
```

```bash
# 不依赖本地命令，直接拉最新卸载脚本执行（xg 被删/脚本损坏时用这个）
bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/uninstall.sh)
```

菜单 `[12]` 与 `uninstall.sh` 的清理范围完全一致，**只确认一次就一路走完**：

1. 停止并移除 Xray / Argo 服务（systemd unit、openrc 服务、direct 进程按 pidfile 精确 kill）
2. **删除 Cloudflare 云端隧道**（`cascade=true`）**与对应的 DNS 解析记录**
3. 无条件清理 systemd / openrc 的 unit 文件（不依赖当前运行模式判定，容器等混合环境也不会留残留）
4. 删除 `/etc/xray`（配置、证书、密钥、cloudflared、`cf.json`、`argo.env`）、`/run/xraygo` 与 `/var/log/xray*.log`
5. 删除管理命令 `/usr/local/bin/xg`

确认前会先把**完整清单**列出来（含 `xg` 的路径），输入 `y` 后不再二次询问；卸载完成后脚本直接退出，不回主菜单。

**会保留的**：系统依赖（`curl` / `jq` / `openssl` / `unzip`）。

> 卸载后当前终端里如果还敲得动 `xg`，是因为**那个 bash 进程已经在内存里跑着**，磁盘上的 `/usr/local/bin/xg` 确实已删除。`Ctrl+D` 或关掉终端再试就没了（`ls /usr/local/bin/xg` 可验证）。

**唯一需要手动收尾**：Argo 是手动填 Token 部署的（`meta.json` 里没有 `tunnel_id`），脚本无从得知隧道归属，卸载时会提示你去 Cloudflare 控制台手动删隧道与 DNS。

---

## 🔧 H3 不通怎么排查

H3 走 **UDP**，和 Reality 的 TCP 是两条完全独立的通道。菜单 `[9]` 或 `xg diag` 会自动跑完下面第 1~3 项并给出结论。

**1. 服务端到底有没有监听 UDP**

```bash
ss -lunp | grep -E ':(443|你的端口)\b'
```

- 有 `UNCONN ... 0.0.0.0:443` → 服务端在监听，问题在后面几项
- 完全没有 UDP 记录 → 核心没起 QUIC 监听，通常是 **Xray 版本低于 1.8.19**，用菜单 `[10]` 更新核心后重启

**2. 防火墙与云安全组**

本机 `ufw` / `firewalld` / `iptables` 脚本会自动放行 TCP 和 UDP，但**云厂商安全组需要你手动加 UDP 规则**——这一步最容易漏。

**3. NAT 映射有没有带 UDP**

用了 `443:31000` 这种写法时，云厂商端口转发 / 路由器 DNAT 必须**同时映射 TCP 和 UDP**。只映射 TCP 时 Reality 能通、H3 一定不通，这是最常见的坑。

**4. 客户端版本与参数**

- v2rayN 的 Xray 内核需 **1.8.19+**（建议 25.x）
- 传输层选 `xhttp`，ALPN 填 `h3`
- SNI 必须和证书域名一致：自签时用链接里的 `sni`，自备证书时用证书上的域名（不一致会握手失败，`xg diag` 会提示）
- 链接里带 `allowInsecure=1` 表示自签证书；Clash Meta 对应 `skip-cert-verify: true`。用自备域名证书时链接不带该参数，请保持证书校验开启

**5. 运营商 UDP 限制**

部分网络会限速或封锁 UDP 443。换个端口（比如 `8443`）试；仍不行就走 Reality 或 Argo，这两条不依赖 UDP 直连。
