#!/bin/bash
# ==============================================================================
#  Xray-go 一键安装入口
#  作用：安装管理脚本到 /usr/local/bin/xg，并按需立即执行一键部署
#
#  用法：
#    bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/install.sh)
#         -> 安装管理命令 xg，然后询问是否立即部署
#    bash <(curl -Ls .../install.sh) deploy
#         -> 安装后直接一键部署（全自动，无需交互）
#    bash <(curl -Ls .../install.sh) -y
#         -> 安装后直接一键部署（同上）
# ==============================================================================

export LANG=en_US.UTF-8
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
umask 077

GITHUB_RAW_BASE="${XRAYGO_RAW:-https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main}"
MANAGER_URL="${GITHUB_RAW_BASE}/xray-go.sh"
GITHUB_PROXY=('https://ess.ieshare.workers.dev/')
TARGET_BIN="/usr/local/bin/xg"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

_info() { echo -e "${CYAN}[信息] $1${NC}" >&2; }
_success() { echo -e "${GREEN}[成功] $1${NC}" >&2; }
_warn() { echo -e "${YELLOW}[注意] $1${NC}" >&2; }
_error() { echo -e "${RED}[错误] $1${NC}" >&2; }

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    _error "请以 root 权限运行。"
    exit 1
fi

_pkg_install() {
    local pkgs="$*"
    [ -z "$pkgs" ] && return 0
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache $pkgs >/dev/null 2>&1
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y $pkgs >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y $pkgs >/dev/null 2>&1
    else
        return 1
    fi
}

_download() {
    local url="$1" out="$2" proxy
    if curl -fsSL --connect-timeout 8 --max-time 120 -o "$out" "$url" 2>/dev/null && [ -s "$out" ]; then
        return 0
    fi
    for proxy in "${GITHUB_PROXY[@]}"; do
        [ -z "$proxy" ] && continue
        if curl -fsSL --connect-timeout 8 --max-time 120 -o "$out" "${proxy}${url}" 2>/dev/null && [ -s "$out" ]; then
            _warn "官方源不可达，已通过安全代理下载。"
            return 0
        fi
    done
    return 1
}

echo "" >&2
echo -e "${CYAN}  ╔══════════════════════════════════════════╗${NC}" >&2
echo -e "${CYAN}  ║        Xray-go 一键安装 / 部署           ║${NC}" >&2
echo -e "${CYAN}  ╚══════════════════════════════════════════╝${NC}" >&2
echo "" >&2

# 1. 基础依赖
_info "正在检查基础依赖 (curl bash)..."
for cmd in curl bash; do
    command -v "$cmd" >/dev/null 2>&1 || _pkg_install "$cmd"
done
if ! command -v curl >/dev/null 2>&1; then
    _error "缺少 curl，且自动安装失败，请手动安装后重试。"
    exit 1
fi

# 2. 下载管理脚本
_stage=$(mktemp /var/tmp/.xray-go.install.XXXXXX) || {
    _error "无法创建临时文件。"
    exit 1
}
_info "正在下载管理脚本..."
if ! _download "${MANAGER_URL}?v=$(date +%s)" "$_stage"; then
    rm -f "$_stage"
    _error "管理脚本下载失败，请检查网络或使用代理重试。"
    exit 1
fi

if ! head -n 1 "$_stage" | grep -q '^#!/bin/bash' || ! bash -n "$_stage" 2>/dev/null; then
    rm -f "$_stage"
    _error "下载的脚本未通过语法校验，已拒绝安装。"
    exit 1
fi

# 3. 安装为全局命令 xg
mkdir -p "$(dirname "$TARGET_BIN")" || exit 1
chmod 755 "$_stage" || { rm -f "$_stage"; exit 1; }
if ! mv -f "$_stage" "$TARGET_BIN"; then
    rm -f "$_stage"
    _error "安装到 ${TARGET_BIN} 失败。"
    exit 1
fi
_success "管理命令已安装: ${TARGET_BIN}"

# 4. 是否立即部署
case "${1:-}" in
    deploy | -y | --yes | install)
        _info "开始一键部署..."
        exec "$TARGET_BIN" deploy
        ;;
esac

echo "" >&2
echo -e "  常用命令：" >&2
echo -e "    ${GREEN}xg${NC}              进入管理菜单（推荐）" >&2
echo -e "    ${GREEN}xg deploy${NC}       一键部署 Reality + H3" >&2
echo -e "    ${GREEN}xg links${NC}        查看节点链接" >&2
echo -e "    ${GREEN}xg status${NC}       查看运行状态" >&2
echo -e "    ${GREEN}xg uninstall${NC}    卸载部署" >&2
echo "" >&2

if [ -t 0 ]; then
    read -r -p "是否立即执行一键部署? (Y/n): " answer || answer=""
    answer="${answer:-y}"
    if [[ "${answer,,}" =~ ^(y|yes)$ ]]; then
        exec "$TARGET_BIN" deploy
    fi
    _info "已跳过部署，可稍后运行: xg deploy"
else
    _info "非交互环境，可手动执行: xg deploy"
fi
