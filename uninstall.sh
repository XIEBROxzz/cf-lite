#!/bin/bash
# ==============================================================================
#  Xray-go 一键卸载脚本
#  清理内容：systemd/openrc 服务、direct 后台进程、配置与证书、日志、运行目录
#  用法：bash <(curl -Ls .../uninstall.sh) [-y]
# ==============================================================================

export LANG=en_US.UTF-8
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

_info() { echo -e "${CYAN}[信息] $1${NC}" >&2; }
_success() { echo -e "${GREEN}[成功] $1${NC}" >&2; }
_warn() { echo -e "${YELLOW}[注意] $1${NC}" >&2; }
_error() { echo -e "${RED}[错误] $1${NC}" >&2; }

XRAY_DIR="/etc/xray"
RUNTIME_DIR="/run/xraygo"
LOG_FILE="/var/log/xray.log"
ARGO_LOG_FILE="/var/log/xray-argo.log"
XRAY_BIN="${XRAY_DIR}/xray"
CLOUDFLARED_BIN="${XRAY_DIR}/cloudflared"
PID_FILE="${RUNTIME_DIR}/xray.pid"
ARGO_PID_FILE="${RUNTIME_DIR}/cloudflared.pid"
META_FILE="${XRAY_DIR}/meta.json"
CF_CRED_FILE="${XRAY_DIR}/cf.json"
CF_API_BASE="https://api.cloudflare.com/client/v4"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    _error "请以 root 权限运行。"
    exit 1
fi

_is_pid_running_cmd() {
    local pid="$1" pattern="$2"
    [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    if [ -r "/proc/${pid}/cmdline" ]; then
        tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -Fq "$pattern"
    else
        ps -p "$pid" -o args= 2>/dev/null | grep -Fq "$pattern"
    fi
}

_stop_direct() {
    local pid_file="$1" pattern="$2"
    [ -s "$pid_file" ] || return 0
    local pid
    pid=$(cat "$pid_file" 2>/dev/null)
    if _is_pid_running_cmd "$pid" "$pattern"; then
        kill "$pid" 2>/dev/null
        sleep 1
        _is_pid_running_cmd "$pid" "$pattern" && kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$pid_file"
    return 0
}

# 删除由脚本自动创建的 Cloudflare 隧道与 DNS 记录（需要在删文件之前执行）
_cleanup_cloud() {
    [ -s "$META_FILE" ] || return 0
    local tid zid domain email key acct resp

    tid=$(jq -r '.argo_tunnel_id // ""' "$META_FILE" 2>/dev/null)
    [ -n "$tid" ] || return 0

    if ! command -v jq >/dev/null 2>&1; then
        _warn "未安装 jq，跳过云端隧道清理（隧道: ${tid}）。"
        return 0
    fi
    if [ ! -s "$CF_CRED_FILE" ]; then
        _warn "未找到 Cloudflare 凭据，跳过云端清理（隧道: ${tid}），请手动在控制台删除。"
        return 0
    fi

    email=$(jq -r '.email // ""' "$CF_CRED_FILE" 2>/dev/null)
    key=$(jq -r '.api_key // ""' "$CF_CRED_FILE" 2>/dev/null)
    acct=$(jq -r '.account_id // ""' "$CF_CRED_FILE" 2>/dev/null)
    zid=$(jq -r '.argo_zone_id // ""' "$META_FILE" 2>/dev/null)
    domain=$(jq -r '.argo_domain // ""' "$META_FILE" 2>/dev/null)

    if [ -z "$email" ] || [ -z "$key" ] || [ -z "$acct" ]; then
        _warn "Cloudflare 凭据不完整，跳过云端清理（隧道: ${tid}）。"
        return 0
    fi

    _info "正在删除 Cloudflare 云端隧道 (${tid})..."
    resp=$(curl -sS --connect-timeout 10 --max-time 30 -X DELETE \
        -H "X-Auth-Email: ${email}" -H "X-Auth-Key: ${key}" \
        "${CF_API_BASE}/accounts/${acct}/cfd_tunnel/${tid}?cascade=true" 2>/dev/null || true)
    if printf '%s' "$resp" | jq -e '.success == true' >/dev/null 2>&1; then
        _success "云端隧道已删除。"
    else
        _warn "云端隧道删除失败，请手动在 Cloudflare 控制台清理。"
    fi

    if [ -n "$zid" ] && [ -n "$domain" ]; then
        local rids rid
        rids=$(curl -sS --connect-timeout 10 --max-time 30 \
            -H "X-Auth-Email: ${email}" -H "X-Auth-Key: ${key}" \
            "${CF_API_BASE}/zones/${zid}/dns_records?name=${domain}" 2>/dev/null \
            | jq -r '.result[]?.id // empty' 2>/dev/null)
        for rid in $rids; do
            curl -sS --connect-timeout 10 --max-time 30 -X DELETE \
                -H "X-Auth-Email: ${email}" -H "X-Auth-Key: ${key}" \
                "${CF_API_BASE}/zones/${zid}/dns_records/${rid}" >/dev/null 2>&1 || true
        done
        _success "DNS 记录已清理 (${domain})。"
    fi
    return 0
}

echo "" >&2
echo -e "${YELLOW}  即将停止服务并删除以下内容：${NC}" >&2
echo -e "    - Xray 服务 / Argo 隧道服务（systemd、openrc 或 direct 进程）" >&2
echo -e "    - 配置目录: ${XRAY_DIR}（配置、证书、密钥、cloudflared）" >&2
echo -e "    - 运行目录: ${RUNTIME_DIR}" >&2
echo -e "    - 日志: ${LOG_FILE} / ${ARGO_LOG_FILE}" >&2
echo "" >&2

SKIP_CONFIRM=false
case "${1:-}" in
    -y | --yes | -f) SKIP_CONFIRM=true ;;
esac

if [ "$SKIP_CONFIRM" != "true" ]; then
    read -r -p "  确认卸载? (y/N): " confirm || confirm=""
    if [[ ! "${confirm,,}" =~ ^(y|yes)$ ]]; then
        _info "已取消卸载。"
        exit 0
    fi
fi

# 1. systemd
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    _info "正在停止 systemd 服务..."
    systemctl disable --now xray-argo >/dev/null 2>&1 || true
    systemctl disable --now xray >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray-argo.service
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed xray xray-argo >/dev/null 2>&1 || true
fi

# 2. openrc
if [ -f /sbin/openrc-run ] || command -v rc-service >/dev/null 2>&1; then
    _info "正在停止 openrc 服务..."
    rc-service xray-argo stop >/dev/null 2>&1 || true
    rc-service xray stop >/dev/null 2>&1 || true
    rc-update del xray-argo default >/dev/null 2>&1 || true
    rc-update del xray default >/dev/null 2>&1 || true
    rm -f /etc/init.d/xray /etc/init.d/xray-argo
fi

# 3. direct 后台进程（只按 pidfile 精确清理，不做全局 pkill）
_info "正在清理残留进程..."
_stop_direct "$ARGO_PID_FILE" "$CLOUDFLARED_BIN"
_stop_direct "$PID_FILE" "$XRAY_BIN"

# 4. 清理云端隧道（必须在删除 /etc/xray 之前）
_cleanup_cloud

# 5. 删除文件
_info "正在删除配置与日志..."
rm -rf "$XRAY_DIR" "$RUNTIME_DIR"
rm -f "$LOG_FILE" "$ARGO_LOG_FILE"

echo "" >&2
_success "Xray-go 已卸载完成。"

if [ -x "/usr/local/bin/xg" ]; then
    if [ "$SKIP_CONFIRM" = "true" ]; then
        _info "管理命令仍保留：/usr/local/bin/xg（删除: rm -f /usr/local/bin/xg）"
    else
        read -r -p "  是否同时删除管理命令 /usr/local/bin/xg? (y/N): " del_xg || del_xg=""
        if [[ "${del_xg,,}" =~ ^(y|yes)$ ]]; then
            rm -f /usr/local/bin/xg 2>/dev/null \
                && _success "管理命令已删除: /usr/local/bin/xg" \
                || _warn "删除失败，请手动执行 rm -f /usr/local/bin/xg"
        else
            _info "已保留管理命令：/usr/local/bin/xg"
        fi
    fi
fi
echo "" >&2
