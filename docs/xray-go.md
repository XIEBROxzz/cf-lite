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

安装管理命令 `xg`，安装完可直接进入菜单：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/install.sh)
```

安装后：

```bash
xg          # 进入管理菜单
xg deploy   # 一键部署（Reality + H3 随机端口）
```

### 方式二：全自动一键部署（免交互）

装完即部署，部署完成后直接打印节点链接与 Base64 订阅：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/install.sh) deploy
```

或直接执行主脚本：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/xray-go.sh) deploy
```

**一键部署做了什么：**

1. 自动识别系统包管理器，安装 `curl jq openssl unzip` 等依赖
2. 从 GitHub 官方源下载 Xray-core（失败自动切 Cloudflare 安全代理），带 SHA-256 校验
3. 生成自签证书、Reality 密钥对、UUID、随机端口（20000-60000）
4. 生成 `/etc/xray/config.json` 并做 `xray -test` 校验
5. 写入服务（systemd / openrc / direct）并启动、开机自启
6. 自动放行 ufw / firewalld / iptables 端口
7. 输出节点链接 + Base64 订阅，保存到 `/etc/xray/url.txt`

### 方式三：自定义部署（可选协议）

```bash
bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/xray-go.sh) custom
```

交互选择是否部署 Reality、H3、Argo，以及各自端口（回车自动随机）。

### Argo 隧道（可选）

一键部署默认不启用 Argo（需要你自己的 Cloudflare Tunnel Token）。启用方式二选一：

**A. 环境变量（免交互）**

```bash
ARGO_TOKEN="你的Token" ARGO_DOMAIN="a.example.com" ARGO_PORT="8001" ARGO_PROTOCOL="http2" \
bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/xray-go.sh) deploy
```

**B. 菜单里交互填写**

```bash
xg   # 选择 [2] 自定义部署
```

> Cloudflare 后台需把该隧道的 Public Hostname 指向 `http://127.0.0.1:8001`（端口与 `ARGO_PORT` 保持一致）。
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
| **[1] 一键部署** | Reality + H3，随机端口，全自动 |
| **[2] 自定义部署** | 可选协议 / 端口 / Argo |
| **[3] 查看节点链接** | 重新输出链接与 Base64 订阅 |
| **[4] 服务控制** | 启动 / 停止 / 重启 / 重启 Argo / 状态 |
| **[5] [6] 日志** | Xray 日志、Argo 日志实时查看 |
| **[7] 检查配置** | `xray -test` 校验 `config.json` |
| **[8] 更新核心** | 拉取 Xray-core 最新稳定版并热切换 |
| **[9] 更新脚本** | 从仓库拉取最新管理脚本 |
| **[10] 卸载部署** | 停服务、删配置、清日志 |

命令行等价用法：

```bash
xg deploy | custom | links | status | start | stop | restart | log | check | update-core | update-script | uninstall
```

---

## 📁 目录与文件

| 路径 | 说明 |
| :--- | :--- |
| `/etc/xray/xray` | Xray-core 二进制 |
| `/etc/xray/config.json` | 主配置（由 `meta.json` 生成） |
| `/etc/xray/meta.json` | 部署元数据（UUID、端口、密钥、Argo 凭据，权限 600） |
| `/etc/xray/url.txt` | 节点链接（含明文凭据，权限 600） |
| `/etc/xray/cert.pem` `private.key` | H3 自签证书 |
| `/var/log/xray.log` | 运行日志 |
| `/usr/local/bin/xg` | 管理命令 |

---

## 🗑️ 一键卸载

```bash
bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/uninstall.sh)
```

或：

```bash
xg uninstall
```

卸载会停止并移除服务、删除 `/etc/xray`、`/run/xraygo` 与日志；管理命令 `xg` 会保留（如需删除：`rm -f /usr/local/bin/xg`）。
