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
- 版本 C：Argo 同样支持**邮箱 + Global API Key 全自动搭建**（建隧道 / ingress / DNS 一次搞定）

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

安装完直接显示数字菜单，输入数字即可执行：

```
1) 进入管理菜单（推荐）
2) 一键部署 Reality + H3
3) 查看节点链接
4) 查看运行状态
5) 卸载部署
0) 退出
```

也可以直接带数字：`xg 1` ~ `xg 5`。

当前版本 **V1.0**（构建 2026-11-06），随时可确认装的是哪一版：

```bash
xg -v        # 输出: Xray-go V1.0 (2026-11-06)
xg status    # 状态页显示「脚本版本 : V1.0 (2026-11-06)」
xg           # 菜单标题栏直接显示 V1.0
```

更新脚本会明确回显版本变化：`V1.0 -> V1.1`；版本相同则提示「当前已是最新版本」；需要强制覆盖重装用 `xg update-script force`。

**特点**

- **XHTTP H3 直连**：HTTP/3 标准 UDP 传输，低延迟高吞吐，不易被运营商 QoS
- **XHTTP-Argo 双模隧道**：隧道跑 quic 时全段 UDP，隐藏真实 IP、零端口暴露
- **VLESS-TCP-REALITY Vision**：无需域名，伪装 TLS，免疫主动探测
- **Argo 全自动搭建**：填 Cloudflare 邮箱 + Global API Key，脚本自动建隧道、写 ingress、建 DNS CNAME、取 Token、启动 cloudflared
  - 隧道名取域名首段：`xnsd.xxxx.com` → 隧道 `xnsd`；同名隧道自动复用，不会重复创建
  - **可以只装 Argo**：服务器上还没有任何部署时直接跑 `xg argo`（或菜单 `[3]`），创建「仅 Argo」节点——只生成 H2-Argo / H3-Argo 两条隧道节点，不开公网端口、不需要公网 IP
  - 删除节点（`[4]` / `xg del-argo`）会一并删除云端隧道 + DNS 解析
  - 卸载（`xg 5` / `uninstall.sh`）会一并删除云端隧道 + DNS 解析 + 本地全部文件
- 自动装依赖 → 装核心（SHA-256 校验）→ 生成配置 → 托管服务（systemd / openrc / direct）→ 放行端口 → 输出链接与 Base64 订阅
- 菜单化管理：查看链接、服务控制、日志、配置校验、更新核心、删除节点、卸载

详细说明见 **[docs/xray-go.md](docs/xray-go.md)**。

---

## 卸载

| 版本 | 卸载方式 |
| :--- | :--- |
| A | 运行 `x` → 菜单内卸载 |
| B | 运行 `sb` → 菜单内卸载 |
| C | **二选一**：`xg 5`，或 `bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/uninstall.sh)` |

> 两种方式**等价，跑一条即可**，不是两条都要执行。
>
> - `xg 5`：本机还留着 `xg` 命令时用，走菜单里的卸载项。
> - `bash <(curl -Ls ...)`：不依赖本地命令，直接从仓库拉最新卸载脚本执行。适合 `xg` 已被删除、脚本文件损坏，或想确保用最新卸载逻辑的情况。

**清理范围（两条路径完全一致）**

1. 停止并移除服务：systemd unit（`xray.service` / `xray-argo.service`）、openrc 服务、direct 模式后台进程（按 pidfile 精确 kill）
2. 删除 Cloudflare 云端隧道（`?cascade=true`）及对应 DNS 解析记录
3. 删除 `/etc/xray`：配置、证书、私钥、`cloudflared`、CF 凭据
4. 删除 `/run/xraygo`（pidfile）与 `/var/log/xray.log`、`/var/log/xray-argo.log`
5. 最后询问是否一并删除 `/usr/local/bin/xg`

**会保留的**：系统依赖（`curl` / `jq` / `openssl` / `unzip`）；`/usr/local/bin/xg` 默认保留，第 5 步选 `y` 才删。

**唯一需要手动收尾的情况**：Argo 是手动填 Token 部署的（`meta.json` 里没有 `tunnel_id`），脚本无从得知隧道归属，卸载时会提示你去 Cloudflare 控制台手动删除隧道和 DNS。
