<div style="display: flex; align-items: center; gap: 24px; margin: 30px 0 20px 0;">
  <img src="./logo.png" alt="cf-lite" width="96" style="display: block; border-radius: 14px; flex-shrink: 0; border: none;">
  <div style="font-size: 32px; font-weight: 900; line-height: 1.25; color: #24292e;">
  </div>
</div>
<br>

## cf-lite · Cloudflare 轻量部署脚本集

三条路线，按需选择。均以 `root` 运行，装完自带快捷命令。

| 版本 | 脚本 | 适用场景 | 快捷命令 |
| :--- | :--- | :--- | :--- |
| **A. Xray + Cloudflare（DNS + Origin Rules）** | `xray_cf_lite.sh` | 有公网 IP，走 CF 回源 | `x` |
| **B. sing-box + Argo 隧道** | `singbox-lite_tunnel.sh` | 无公网 IP / 无端口映射 | `sb` |
| **C. Xray-go（Reality + H3 + Argo）** | `xray-go.sh` | 低延迟、抗 QoS、一键部署 | `xg` |

---

## 前置依赖

按系统先装这几条，其余依赖（xray-core / sing-box / cloudflared 等）脚本自动安装：

**Debian / Ubuntu**

```bash
apt-get update && apt-get install -y curl jq bash
```

**Alpine**

```sh
apk add bash curl jq
```

> 版本 C（`xray-go.sh`）会自动安装 `curl jq openssl unzip` 等依赖，无需手动准备。

Cloudflare 需要**域名已托管**：

- 版本 A：邮箱 + **Global API Key**
- 版本 B：临时隧道零配置；固定隧道用同样的邮箱 + Global API Key（隧道 / DNS 全自动创建）
- 版本 C：Argo 为可选项，需要 Cloudflare Tunnel 的 **Token + 域名**（也可只跑 Reality / H3 直连）

---

## 快速开始

### 版本 A：DNS + Origin Rules（需公网 IP）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/xray_cf_lite.sh)
```

安装后自动创建快捷命令 `x`（任何系统可直接 `x` 调起最新版）。

### 版本 B：sing-box + Argo 隧道（无需公网 IP / 端口映射）

```bash
(curl -LfsS https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/singbox-lite_tunnel.sh -o /usr/local/bin/sb || wget -q https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/singbox-lite_tunnel.sh -O /usr/local/bin/sb) && chmod +x /usr/local/bin/sb && sb
```

快捷命令：`sb`

### 版本 C：Xray-go（Reality + XHTTP-H3 + Argo，一键部署）

```bash
bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/install.sh)
```

安装后：

```bash
xg          # 管理菜单
xg deploy   # 一键部署（Reality + H3 随机端口，全自动）
```

**特点**

- **XHTTP H3 直连**：HTTP/3 标准 UDP 传输，低延迟高吞吐，不易被运营商 QoS
- **XHTTP-Argo 双模隧道**：隧道跑 quic 时全段 UDP，隐藏真实 IP、零端口暴露
- **VLESS-TCP-REALITY Vision**：无需域名，伪装 TLS，免疫主动探测
- 自动装依赖 → 装核心（SHA-256 校验）→ 生成配置 → 托管服务（systemd / openrc / direct）→ 放行端口 → 输出链接与 Base64 订阅
- 菜单化管理：查看链接、服务控制、日志、配置校验、更新核心、卸载

详细说明见 **[docs/xray-go.md](docs/xray-go.md)**。

---

## 卸载

| 版本 | 卸载方式 |
| :--- | :--- |
| A | 运行 `x` → 菜单内卸载 |
| B | 运行 `sb` → 菜单内卸载 |
| C | `xg uninstall`，或 `bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/uninstall.sh)` |
