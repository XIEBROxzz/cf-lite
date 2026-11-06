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

Cloudflare 需要**域名已托管**：

- 版本 A：邮箱 + **Global API Key**
- 版本 B：临时隧道零配置；固定隧道用同样的邮箱 + Global API Key（隧道 / DNS 全自动创建）

## 快速开始

### 版本 A：DNS + Origin Rules（需公网 IP）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/XIEBROxzz/xray-cf-lite/main/xray_cf_lite.sh)
```

安装后自动创建快捷命令 `x`（任何系统可直接 `x` 调起最新版）。

### 版本 B：sing-box + Argo 隧道（无需公网 IP / 端口映射）

```bash
(curl -LfsS https://raw.githubusercontent.com/XIEBROxzz/xray-cf-lite/main/singbox-lite_tunnel.sh -o /usr/local/bin/sb || wget -q https://raw.githubusercontent.com/XIEBROxzz/xray-cf-lite/main/singbox-lite_tunnel.sh -O /usr/local/bin/sb) && chmod +x /usr/local/bin/sb && sb
```

快捷命令：`sb`
