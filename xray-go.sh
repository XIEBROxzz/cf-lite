#!/bin/bash
# ==============================================================================
#  Xray-go · Argo 隧道版
#  XHTTP-Argo 双模隧道：H2-Argo（TCP）/ H3-Argo（UDP），全程走 Cloudflare
#  Cloudflare 自动搭建（邮箱 + Global API Key）：建隧道 -> ingress -> DNS -> 启动
#  服务托管：systemd / openrc / direct
# ==============================================================================

export LANG=en_US.UTF-8
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

# 配置、元数据、凭据仅 root 可读写
umask 077

# 版本号：更新脚本后对比此值即可确认是否更新成功（xg -v / 菜单标题 / 状态页均显示）
export SCRIPT_VERSION="2.10"
export SCRIPT_BUILD="2026-11-06"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main"
SCRIPT_UPDATE_URL="${GITHUB_RAW_BASE}/xray-go.sh"
# Github Cloudflare 安全代理（优先直连官方，失败后轮询代理）
GITHUB_PROXY=('https://ess.ieshare.workers.dev/')

# --- 路径与常量 ---
XRAY_DIR="/etc/xray"
XRAY_BIN="${XRAY_DIR}/xray"
CONFIG_FILE="${XRAY_DIR}/config.json"
META_FILE="${XRAY_DIR}/meta.json"
LINKS_FILE="${XRAY_DIR}/url.txt"
CLOUDFLARED_BIN="${XRAY_DIR}/cloudflared"
ARGO_ENV_FILE="${XRAY_DIR}/argo.env"
DEP_STATE_FILE="${XRAY_DIR}/dependencies.ok"
CF_CRED_FILE="${XRAY_DIR}/cf.json"
CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_EMAIL=""
CF_KEY=""
CF_ACCOUNT_ID=""
# 保留环境变量传入的值（支持 ARGO_TOKEN=xxx xg deploy 这种用法）
ARGO_TOKEN="${ARGO_TOKEN:-}"
ARGO_DOMAIN="${ARGO_DOMAIN:-}"
ARGO_PORT="${ARGO_PORT:-8001}"
ARGO_PROTOCOL="${ARGO_PROTOCOL:-quic}"
ARGO_TUNNEL_ID="${ARGO_TUNNEL_ID:-}"
ARGO_ZONE_ID="${ARGO_ZONE_ID:-}"
DEP_STATE_VERSION="20261106-2"
LOG_FILE="/var/log/xray.log"
ARGO_LOG_FILE="/var/log/xray-argo.log"
RUNTIME_DIR="/run/xraygo"
PID_FILE="${RUNTIME_DIR}/xray.pid"
ARGO_PID_FILE="${RUNTIME_DIR}/cloudflared.pid"
SERVICE_FILE="/etc/systemd/system/xray.service"
ARGO_SERVICE_FILE="/etc/systemd/system/xray-argo.service"
# 管理命令安装路径（可用 SELF_BIN 覆盖，便于测试/自定义安装位置）
SELF_BIN="${SELF_BIN:-/usr/local/bin/xg}"
# 客户端连接 Argo 用的 Cloudflare 优选地址
CF_ADDR_H2="www.visa.com.hk"
CF_ADDR_H3="www.teamviewer.com"
CF_PORT="443"
INIT_SYSTEM=""

# --- 颜色与输出（统一写 stderr，避免污染命令替换） ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

_info() { echo -e "${CYAN}[信息] $1${NC}" >&2; }
_success() { echo -e "${GREEN}[成功] $1${NC}" >&2; }
_warn() { echo -e "${YELLOW}[注意] $1${NC}" >&2; }
_error() { echo -e "${RED}[错误] $1${NC}" >&2; }


# ==============================================================================
#  基础工具
# ==============================================================================

_version_tag() { printf 'V%s' "${SCRIPT_VERSION}"; }

_version_full() { printf 'V%s (%s)' "${SCRIPT_VERSION}" "${SCRIPT_BUILD}"; }

_check_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        _error "此脚本必须以 root 权限运行。"
        exit 1
    fi
}

_detect_init_system() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
        SERVICE_FILE="/etc/systemd/system/xray.service"
        ARGO_SERVICE_FILE="/etc/systemd/system/xray-argo.service"
    elif [ -f /sbin/openrc-run ] || command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
        SERVICE_FILE="/etc/init.d/xray"
        ARGO_SERVICE_FILE="/etc/init.d/xray-argo"
    else
        INIT_SYSTEM="direct"
        SERVICE_FILE=""
        ARGO_SERVICE_FILE=""
    fi
    export INIT_SYSTEM SERVICE_FILE ARGO_SERVICE_FILE
}

_pkg_install() {
    local pkgs="$*"
    [ -z "$pkgs" ] && return 0
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache $pkgs >/dev/null 2>&1
    elif command -v apt-get >/dev/null 2>&1; then
        if [ ! -d "/var/lib/apt/lists" ] || [ "$(ls -A /var/lib/apt/lists/ 2>/dev/null | wc -l)" -le 1 ]; then
            apt-get update -qq >/dev/null 2>&1
        fi
        DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null 2>&1 || {
            apt-get update -qq >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null 2>&1
        }
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y $pkgs >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y $pkgs >/dev/null 2>&1
    else
        return 1
    fi
}

_install_dependencies() {
    local force="${1:-false}"

    if [ "$force" != "true" ] && [ -s "$DEP_STATE_FILE" ] && grep -qx "$DEP_STATE_VERSION" "$DEP_STATE_FILE" 2>/dev/null; then
        local missing_cached="" cmd
        for cmd in bash curl jq openssl unzip; do
            command -v "$cmd" >/dev/null 2>&1 || missing_cached="$missing_cached $cmd"
        done
        [ -z "$missing_cached" ] && return 0
        _warn "依赖缓存存在，但关键工具缺失:${missing_cached}，执行修复安装。"
    fi

    local core_pkgs="bash curl jq openssl unzip ca-certificates"
    _info "正在安装核心依赖（bash curl jq openssl unzip）..."
    _pkg_install $core_pkgs
    _pkg_install wget >/dev/null 2>&1 || true
    _pkg_install iptables >/dev/null 2>&1 || true

    local missing="" cmd
    for cmd in bash curl jq openssl unzip; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    if [ -n "$missing" ]; then
        _error "以下关键依赖安装失败:${missing}"
        _error "请手动安装后重试（apt/apk/yum install ...）。"
        return 1
    fi

    mkdir -p "$XRAY_DIR" 2>/dev/null || return 1
    printf '%s\n' "$DEP_STATE_VERSION" > "$DEP_STATE_FILE" 2>/dev/null || true
    return 0
}

# 服务文件权限要按 init 系统区分：
#   systemd 的 unit 只需可读，600 没问题；
#   openrc 的 /etc/init.d/xray 是要被 rc-service 执行的脚本，必须 755，
#   否则 rc-service 会报 “* rc-service: Permission denied”。
_fix_service_perms() {
    local f="$1"
    [ -n "$f" ] && [ -f "$f" ] || return 0
    case "$INIT_SYSTEM" in
        openrc) chmod 755 "$f" 2>/dev/null || true ;;
        *)      chmod 600 "$f" 2>/dev/null || true ;;
    esac
    return 0
}

_secure_permissions() {
    [ -d "$XRAY_DIR" ] && chmod 700 "$XRAY_DIR" 2>/dev/null || true
    [ -d "$RUNTIME_DIR" ] && chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
    local f
    for f in "$CONFIG_FILE" "$META_FILE" "$LINKS_FILE" "$ARGO_ENV_FILE" \
             "$DEP_STATE_FILE" "$CF_CRED_FILE"; do
        [ -f "$f" ] && chmod 600 "$f" 2>/dev/null || true
    done
    _fix_service_perms "$SERVICE_FILE"
    _fix_service_perms "$ARGO_SERVICE_FILE"
    return 0
}

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

_is_pid_file_running_cmd() {
    local pid_file="$1" pattern="$2"
    [ -s "$pid_file" ] || return 1
    _is_pid_running_cmd "$(cat "$pid_file" 2>/dev/null)" "$pattern"
}

_port_in_use() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    if command -v ss >/dev/null 2>&1; then
        ss -lntu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${port}$" && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lntu 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$" && return 0
    else
        (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null && return 0
    fi
    return 1
}

_pick_free_port() {
    local port i
    for i in $(seq 1 30); do
        port=$(_rand_port)
        _port_in_use "$port" || { printf '%s' "$port"; return 0; }
    done
    printf '%s' "$port"
}

_gen_uuid() {
    local u=""
    [ -r /proc/sys/kernel/random/uuid ] && u=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
    [ -n "$u" ] || u=$(openssl rand -hex 16 2>/dev/null)
    printf '%s' "$u"
}

_rand_port() {
    local lo=30000 hi=50000 p=""
    if command -v shuf >/dev/null 2>&1; then
        p=$(shuf -i ${lo}-${hi} -n 1 2>/dev/null)
    fi
    [[ "$p" =~ ^[0-9]+$ ]] || p=$(( (RANDOM * 32768 + RANDOM) % (hi - lo + 1) + lo ))
    printf '%s' "$p"
}

_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    else
        openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
    fi
}

_ask_yes() {
    local prompt="$1" default="${2:-n}" answer=""
    read -r -p "$prompt" answer || answer=""
    answer="${answer:-$default}"
    [[ "${answer,,}" =~ ^(y|yes)$ ]]
}

_download() {
    local url="$1" out="$2" proxy
    if curl -fsSL --connect-timeout 8 --max-time 300 -o "$out" "$url" 2>/dev/null && [ -s "$out" ]; then
        return 0
    fi
    for proxy in "${GITHUB_PROXY[@]}"; do
        [ -z "$proxy" ] && continue
        if curl -fsSL --connect-timeout 8 --max-time 300 -o "$out" "${proxy}${url}" 2>/dev/null && [ -s "$out" ]; then
            _warn "官方源不可达，已通过安全代理下载。"
            return 0
        fi
    done
    return 1
}

_api_get() {
    local url="$1" out="" proxy
    out=$(curl -fsSL --connect-timeout 10 --max-time 30 "$url" 2>/dev/null) && [ -n "$out" ] && {
        printf '%s' "$out"; return 0;
    }
    for proxy in "${GITHUB_PROXY[@]}"; do
        [ -z "$proxy" ] && continue
        out=$(curl -fsSL --connect-timeout 10 --max-time 30 "${proxy}${url}" 2>/dev/null) && [ -n "$out" ] && {
            printf '%s' "$out"; return 0;
        }
    done
    return 1
}

_xray_arch_tag() {
    case "$(uname -m)" in
        x86_64 | amd64) echo "64" ;;
        aarch64 | arm64) echo "arm64-v8a" ;;
        armv7l | armv7) echo "arm32-v7a" ;;
        i386 | i686) echo "32" ;;
        riscv64) echo "riscv64" ;;
        *) echo "" ;;
    esac
}

_install_xray_core() {
    local mode="${1:-auto}"

    if [ "$mode" != "update" ] && [ -x "$XRAY_BIN" ] && "$XRAY_BIN" version >/dev/null 2>&1; then
        _info "Xray-core 已就绪: $("$XRAY_BIN" version 2>/dev/null | head -n1)"
        return 0
    fi

    local arch_tag
    arch_tag=$(_xray_arch_tag)
    if [ -z "$arch_tag" ]; then
        _error "不支持的 CPU 架构: $(uname -m)"
        return 1
    fi

    local asset="Xray-linux-${arch_tag}.zip"
    local api="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
    local release_json="" version="" dl_url="" digest=""

    _info "正在获取 Xray-core 最新版本信息..."
    release_json=$(_api_get "$api" 2>/dev/null || true)
    if [ -n "$release_json" ]; then
        IFS=$'\t' read -r version dl_url digest < <(printf '%s' "$release_json" | jq -r --arg n "$asset" '
            [.assets[]? | select(.name == $n)] as $m
            | [(.tag_name // ""), ($m[0].browser_download_url // ""), ($m[0].digest // "")]
            | @tsv' 2>/dev/null)
    fi
    if [ -z "$dl_url" ] || [ "$dl_url" = "null" ]; then
        _warn "无法读取官方发布信息，改用固定下载地址（跳过摘要校验）。"
        dl_url="https://github.com/XTLS/Xray-core/releases/latest/download/${asset}"
        digest=""
    fi

    mkdir -p "$XRAY_DIR" || { _error "无法创建 ${XRAY_DIR}"; return 1; }
    local tmp_dir
    tmp_dir=$(mktemp -d /var/tmp/.xraygo-install.XXXXXX 2>/dev/null) || {
        _error "无法创建临时目录"; return 1;
    }
    local zip_file="${tmp_dir}/${asset}"

    _info "正在下载 ${asset}${version:+ (${version})}..."
    if ! _download "$dl_url" "$zip_file"; then
        rm -rf "$tmp_dir"
        _error "Xray-core 下载失败，请检查网络后重试。"
        return 1
    fi

    if [[ "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
        local expected actual
        expected="${digest#sha256:}"
        actual=$(_sha256 "$zip_file")
        if [ "${actual,,}" != "${expected,,}" ]; then
            rm -rf "$tmp_dir"
            _error "Xray-core 安装包 SHA-256 校验失败，已拒绝安装。"
            return 1
        fi
        _success "安装包 SHA-256 校验通过。"
    fi

    if ! unzip -qo "$zip_file" -d "$tmp_dir" 2>/dev/null; then
        rm -rf "$tmp_dir"
        _error "解压失败，安装包可能已损坏。"
        return 1
    fi

    local new_bin="${tmp_dir}/xray"
    if [ ! -f "$new_bin" ]; then
        rm -rf "$tmp_dir"
        _error "解压后未找到 xray 二进制文件。"
        return 1
    fi
    chmod 755 "$new_bin" || { rm -rf "$tmp_dir"; return 1; }
    if ! "$new_bin" version >/dev/null 2>&1; then
        rm -rf "$tmp_dir"
        _error "下载的核心无法执行（架构或依赖不匹配），已拒绝安装。"
        return 1
    fi

    local backup=""
    if [ -f "$XRAY_BIN" ]; then
        backup="${XRAY_BIN}.rollback.$$"
        cp -p "$XRAY_BIN" "$backup" 2>/dev/null || backup=""
    fi
    if ! mv -f "$new_bin" "$XRAY_BIN"; then
        rm -rf "$tmp_dir"
        [ -n "$backup" ] && rm -f "$backup"
        _error "核心替换失败。"
        return 1
    fi
    chmod 755 "$XRAY_BIN"
    rm -rf "$tmp_dir"
    [ -n "$backup" ] && rm -f "$backup"

    _success "Xray-core 安装完成: $("$XRAY_BIN" version 2>/dev/null | head -n1)"
    return 0
}

_cf_arch_tag() {
    case "$(uname -m)" in
        x86_64 | amd64) echo "amd64" ;;
        aarch64 | arm64) echo "arm64" ;;
        armv7l | armv7) echo "arm" ;;
        i386 | i686) echo "386" ;;
        *) echo "" ;;
    esac
}

_install_cloudflared() {
    if [ -x "$CLOUDFLARED_BIN" ] && "$CLOUDFLARED_BIN" --version >/dev/null 2>&1; then
        _info "cloudflared 已就绪: $("$CLOUDFLARED_BIN" --version 2>&1 | head -n1)"
        return 0
    fi

    local cf_arch
    cf_arch=$(_cf_arch_tag)
    if [ -z "$cf_arch" ]; then
        _error "cloudflared 不支持当前架构: $(uname -m)"
        return 1
    fi

    local asset="cloudflared-linux-${cf_arch}"
    local api="https://api.github.com/repos/cloudflare/cloudflared/releases/latest"
    local release_json="" dl_url="" digest=""

    _info "正在获取 cloudflared 最新版本信息..."
    release_json=$(_api_get "$api" 2>/dev/null || true)
    if [ -n "$release_json" ]; then
        IFS=$'\t' read -r dl_url digest < <(printf '%s' "$release_json" | jq -r --arg n "$asset" '
            [.assets[]? | select(.name == $n)] as $m
            | [($m[0].browser_download_url // ""), ($m[0].digest // "")]
            | @tsv' 2>/dev/null)
    fi
    if [ -z "$dl_url" ] || [ "$dl_url" = "null" ]; then
        _warn "无法读取官方发布信息，改用固定下载地址（跳过摘要校验）。"
        dl_url="https://github.com/cloudflare/cloudflared/releases/latest/download/${asset}"
        digest=""
    fi

    mkdir -p "$XRAY_DIR" || return 1
    local tmp_bin
    tmp_bin=$(mktemp "${XRAY_DIR}/.cloudflared.new.XXXXXX") || return 1

    _info "正在下载 ${asset}..."
    if ! _download "$dl_url" "$tmp_bin"; then
        rm -f "$tmp_bin"
        _error "cloudflared 下载失败。"
        return 1
    fi

    if [[ "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
        local expected actual
        expected="${digest#sha256:}"
        actual=$(_sha256 "$tmp_bin")
        if [ "${actual,,}" != "${expected,,}" ]; then
            rm -f "$tmp_bin"
            _error "cloudflared SHA-256 校验失败，已拒绝安装。"
            return 1
        fi
    fi

    chmod 755 "$tmp_bin" || { rm -f "$tmp_bin"; return 1; }
    if ! "$tmp_bin" --version >/dev/null 2>&1; then
        rm -f "$tmp_bin"
        _error "下载的 cloudflared 无法执行，已拒绝安装。"
        return 1
    fi
    mv -f "$tmp_bin" "$CLOUDFLARED_BIN" || { rm -f "$tmp_bin"; return 1; }

    _success "cloudflared 安装完成: $("$CLOUDFLARED_BIN" --version 2>&1 | head -n1)"
    return 0
}

_write_config() {
    local tmp
    tmp=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX") || { _error "无法创建临时配置文件"; return 1; }
    if ! _build_config_from_meta > "$tmp" 2>/dev/null || ! jq empty "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        _error "生成 config.json 失败（meta.json 可能损坏）。"
        return 1
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$CONFIG_FILE" || { rm -f "$tmp"; return 1; }
    return 0
}

_check_config() {
    [ -x "$XRAY_BIN" ] || { _error "Xray 核心未安装，无法校验配置。"; return 1; }
    [ -s "$CONFIG_FILE" ] || { _error "配置文件不存在: ${CONFIG_FILE}"; return 1; }

    local out=""
    if out=$("$XRAY_BIN" -test -config "$CONFIG_FILE" 2>&1) \
        || out=$("$XRAY_BIN" run -test -config "$CONFIG_FILE" 2>&1); then
        _success "配置校验通过: ${CONFIG_FILE}"
        return 0
    fi
    # 核心不支持 -test 参数时不算配置错误，避免误判阻断部署
    if printf '%s' "$out" | grep -qiE "flag provided but not defined|unknown flag|incorrect usage|Usage of"; then
        _warn "当前核心不支持 -test 校验，已跳过配置校验。"
        return 0
    fi
    _error "配置校验失败:"
    printf '%s\n' "$out" >&2
    return 1
}

_listen_check() {
    local port="$1" proto="$2"
    [ "$port" = "0" ] && { printf '%s' "-"; return 0; }
    if command -v ss >/dev/null 2>&1; then
        ss -ln"$proto" 2>/dev/null | awk 'NR>1 {print $4}' | grep -qE "[:.]${port}$" \
            && printf '%s' "是" || printf '%s' "否"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ln"$proto" 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$" \
            && printf '%s' "是" || printf '%s' "否"
    else
        printf '%s' "?"
    fi
}

# 统计与 Cloudflare 边缘（7844）的连接数，输出 "udp tcp"
# 依次尝试 ss → netstat → /proc/net/*：Alpine 的 busybox 常常只有 netstat（且不一定认 -p），
# 容器里有时连 netstat 都没有，只能读内核表（7844 = 0x1EA4）。
_count_edge_conns() {
    local udp=0 tcp=0 f out

    if command -v ss >/dev/null 2>&1; then
        out=$(ss -aunp 2>/dev/null); [ -n "$out" ] || out=$(ss -aun 2>/dev/null)
        udp=$(printf '%s\n' "$out" | grep -cE 'cloudflared|:7844')
        out=$(ss -atnp 2>/dev/null); [ -n "$out" ] || out=$(ss -atn 2>/dev/null)
        tcp=$(printf '%s\n' "$out" | grep -cE 'cloudflared|:7844')
        if [ "${udp:-0}" -gt 0 ] || [ "${tcp:-0}" -gt 0 ]; then
            printf '%s %s' "$udp" "$tcp"
            return 0
        fi
    fi

    if command -v netstat >/dev/null 2>&1; then
        out=$(netstat -anup 2>/dev/null); [ -n "$out" ] || out=$(netstat -anu 2>/dev/null)
        udp=$(printf '%s\n' "$out" | grep -cE 'cloudflared|:7844')
        out=$(netstat -antp 2>/dev/null); [ -n "$out" ] || out=$(netstat -ant 2>/dev/null)
        tcp=$(printf '%s\n' "$out" | grep -cE 'cloudflared|:7844')
        if [ "${udp:-0}" -gt 0 ] || [ "${tcp:-0}" -gt 0 ]; then
            printf '%s %s' "$udp" "$tcp"
            return 0
        fi
    fi

    # 兜底：直接数内核套接字表，远端端口 7844(0x1EA4) 即为到边缘的长连接
    udp=0; tcp=0
    for f in /proc/net/udp /proc/net/udp6; do
        [ -r "$f" ] || continue
        udp=$((udp + $(awk '$3 ~ /:1EA4$/ {c++} END{print c+0}' "$f" 2>/dev/null)))
    done
    for f in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$f" ] || continue
        tcp=$((tcp + $(awk '$3 ~ /:1EA4$/ && $4 == "01" {c++} END{print c+0}' "$f" 2>/dev/null)))
    done
    printf '%s %s' "$udp" "$tcp"
}

# 采集 cloudflared 日志文本（三种托管方式落点不同）
_collect_argo_logtext() {
    local text="" f

    # 取够长的尾巴：注册日志在启动时，日志跑久了会被挤出 tail -300 的范围
    [ -s "$ARGO_LOG_FILE" ] && text=$(tail -n 2000 "$ARGO_LOG_FILE" 2>/dev/null)

    if [ -z "$text" ] && command -v journalctl >/dev/null 2>&1; then
        text=$(journalctl -u xray-argo -n 2000 --no-pager 2>/dev/null)
    fi

    # openrc 下日志可能被 supervise-daemon 丢进 syslog
    if [ -z "$text" ]; then
        for f in /var/log/messages /var/log/syslog /var/log/cloudflared.log; do
            [ -s "$f" ] || continue
            text=$(grep -i 'cloudflared' "$f" 2>/dev/null | tail -n 300)
            [ -n "$text" ] && break
        done
    fi

    printf '%s' "$text"
}

# 最近一次启动之后的日志段。
# 日志是累积的（每次重启都会再注册一批），跨重启混在一起会把「以前用过 http2」
# 误判成「现在在回退」。批次边界不止 Starting tunnel：有的版本/日志源会漏掉它，
# 所以 Settings / Initial protocol 也当边界，命中任意一个就从头累积。
_argo_batch() {
    local logtext
    logtext=$(_collect_argo_logtext)
    [ -n "$logtext" ] || return 0
    printf '%s\n' "$logtext" \
        | awk '/Starting tunnel|Initial protocol|Settings: map\[/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}'
}

# 把任意输入规整成非负整数（grep -c 在异常时可能给空串）
_argo_int() {
    case "${1:-}" in
        ''|*[!0-9]*) printf '0' ;;
        *)           printf '%s' "$1" ;;
    esac
}

_argo_transport() {
    local cfg="" proc_proto="" udp=0 tcp=0 log_proto="" logtext="" fallback=false state="unknown"

    [ -s "$META_FILE" ] && cfg=$(jq -r '.argo_protocol // ""' "$META_FILE" 2>/dev/null | tr -d '\r')

    # 进程实际参数（配置里写的和真正跑起来的可能不一致）
    proc_proto=$(ps -eo args= 2>/dev/null | grep -F "cloudflared" | grep -v grep \
        | sed -n 's/.*--protocol[= ]\{1\}\([a-z0-9]*\).*/\1/p' | head -n1)

    # 与 Cloudflare 边缘的连接：QUIC 是 UDP 套接字，http2 是 TCP 连接（端口都是 7844）
    local conns
    conns=$(_count_edge_conns)
    udp=${conns%% *}
    tcp=${conns##* }
    udp=${udp:-0}; tcp=${tcp:-0}

    logtext=$(_collect_argo_logtext)

    local batch=""
    batch=$(_argo_batch)
    [ -n "$batch" ] || batch="$logtext"

    # 统一口径：只认「注册成功」那些行里的 protocol 值。
    # 不能用宽正则扫整段 —— Settings 里的 map[... protocol:http2 ...] 也会被算进去，
    # 于是出现「日志协议 http2 / 明细 http2 0 条」这种自相矛盾的输出。
    local protos=""
    protos=$(printf '%s\n' "$batch" | grep 'Registered tunnel connection' \
        | grep -oE 'protocol[=: ]+[a-z0-9]+' | sed 's/.*[=: ]//')
    if [ -z "$protos" ]; then
        # 日志源把注册行裁掉了，退化为任意 protocol 字段（口径放宽，仅作兜底）
        protos=$(printf '%s\n' "$batch" | grep -oE 'protocol[=: ]+[a-z0-9]+' | sed 's/.*[=: ]//')
    fi

    local mix_q=0 mix_h=0 mix_n=0
    if [ -n "$protos" ]; then
        mix_q=$(_argo_int "$(printf '%s\n' "$protos" | grep -c '^quic$')")
        mix_h=$(_argo_int "$(printf '%s\n' "$protos" | grep -c '^http2$')")
    fi
    mix_n=$((mix_q + mix_h))

    log_proto=$(printf '%s\n' "$protos" | tail -n1)
    # 真正的回退证据只有两种：明确说 failed to dial / falling back，
    # 或者「配置要 quic，但注册结果里一条 quic 都没有」。
    # 不能用 'quic.*fail' 这种宽泛正则 —— precheck 里那行
    # "region2 ... FAIL  QUIC connection failed" 是探针结果，不是隧道回退，
    # 4 条连接全注册成 quic 时照样会命中，属于误报。
    printf '%s' "$batch" | grep -qiE 'falling back|failed to dial to edge with quic' && fallback=true

    # cloudflared 启动时的 UDP 连通性自检（两个区域端点各探一次）
    local pre1="-" pre2="-"
    pre1=$(printf '%s\n' "$batch" | grep -oE 'region1[^|]*(PASS|FAIL)' | grep -oE 'PASS|FAIL' | tail -n1)
    pre2=$(printf '%s\n' "$batch" | grep -oE 'region2[^|]*(PASS|FAIL)' | grep -oE 'PASS|FAIL' | tail -n1)
    pre1=${pre1:--}; pre2=${pre2:--}

    if [ "$fallback" = true ]; then
        state="fallback"
    elif [ "$mix_q" -gt 0 ] 2>/dev/null && [ "$mix_h" -gt 0 ] 2>/dev/null; then
        # 同一批里既有 quic 又有 http2：UDP 7844 只通了一部分，个别连接回退了
        state="mixed"
    elif [ "$mix_h" -gt 0 ] 2>/dev/null && [ "$mix_q" -eq 0 ] 2>/dev/null && [ "$cfg" = "quic" ]; then
        # 要的是 quic，实际一条都没建成 → 真回退
        state="fallback"
    elif [ "$udp" -gt 0 ] 2>/dev/null; then
        state="quic"
    elif [ "$tcp" -gt 0 ] 2>/dev/null; then
        state="http2"
    elif [ -n "$log_proto" ]; then
        state="$log_proto"
    fi

    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s' \
        "$state" "${cfg:-$proc_proto}" "$udp" "$tcp" "$log_proto" "${mix_q}:${mix_h}:${mix_n}" "${pre1}/${pre2}"
}

_write_systemd_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Xray Service (Xray-go)
Documentation=https://xtls.github.io
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BIN} run -config ${CONFIG_FILE}
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    chmod 600 "$SERVICE_FILE" 2>/dev/null || true
}

_write_openrc_service() {
    if command -v supervise-daemon >/dev/null 2>&1; then
        cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run
description="Xray Service (Xray-go)"
supervisor="supervise-daemon"
command="${XRAY_BIN}"
command_args="run -config ${CONFIG_FILE}"
respawn_delay=5
respawn_max=0
pidfile="${PID_FILE}"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"

start_pre() {
    checkpath -d -m 0700 ${RUNTIME_DIR}
}

depend() {
    need net
    after firewall
}
EOF
    else
        cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run
description="Xray Service (Xray-go)"
command="${XRAY_BIN}"
command_args="run -config ${CONFIG_FILE}"
command_background="yes"
pidfile="${PID_FILE}"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"

depend() {
    need net
    after firewall
}
EOF
    fi
    chmod 755 "$SERVICE_FILE" 2>/dev/null || true
}

# 服务文件是不是本脚本写的？
# CF-A（xray_cf_lite.sh）用的就是 /etc/systemd/system/xray.service（官方 unit），
# 它的卸载只删自己的 config、不删 unit，于是本脚本会「以为服务已存在」而直接启动，
# 结果跑的是 CF-A 的 ExecStart=/usr/local/bin/xray，配置早被删了 → 秒退 + 重启循环。
_service_file_is_ours() {
    [ -f "$SERVICE_FILE" ] || return 1
    grep -qF "ExecStart=${XRAY_BIN}" "$SERVICE_FILE" 2>/dev/null && return 0
    grep -qF "command=\"${XRAY_BIN}\"" "$SERVICE_FILE" 2>/dev/null && return 0
    return 1
}

# 启动/重启前确保服务文件归自己；被别人占着就重写（幂等，可反复调用）
_ensure_service_owned() {
    if _service_file_is_ours; then
        # 老版本 _secure_permissions 会把 openrc 的 init 脚本也 chmod 600，
        # 导致 rc-service 报 Permission denied。这里顺手修正，已坏的环境下次 restart 即自愈。
        _fix_service_perms "$SERVICE_FILE"
        _fix_service_perms "$ARGO_SERVICE_FILE"
        # 顺手补回开机自启：CF-A 卸载时执行过 systemctl disable xray
        case "$INIT_SYSTEM" in
            systemd) systemctl enable xray >/dev/null 2>&1 || true ;;
            openrc)  rc-update add xray default >/dev/null 2>&1 || true ;;
        esac
        return 0
    fi
    if [ -f "$SERVICE_FILE" ]; then
        _warn "检测到 ${SERVICE_FILE} 不是本脚本写的（多为 CF-A 遗留），正在重写为本脚本的服务。"
    fi
    _create_service_files
    _service_file_is_ours
}

_create_service_files() {
    mkdir -p "$RUNTIME_DIR" 2>/dev/null
    chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || true

    case "$INIT_SYSTEM" in
        systemd)
            # CF-A（xray_cf_lite.sh）用同一个 unit 路径，且会在 xray.service.d/ 里留
            # RestartSec=1 的 drop-in。接管前先清掉，否则失败后会 1 秒一重启，日志刷爆。
            if [ -d "${SERVICE_FILE}.d" ] && ! _service_file_is_ours; then
                rm -rf "${SERVICE_FILE}.d" 2>/dev/null || true
            fi
            _info "正在创建 systemd 服务..."
            _write_systemd_service
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable xray >/dev/null 2>&1 || true
            ;;
        openrc)
            _info "正在创建 openrc 服务..."
            _write_openrc_service
            rc-update add xray default >/dev/null 2>&1 || true
            ;;
        direct)
            _info "当前环境无 systemd/openrc，使用 direct 后台模式托管。"
            ;;
    esac
    return 0
}

_direct_start() {
    local bin="$1" args="$2" pid_file="$3" log_file="$4"
    if _is_pid_file_running_cmd "$pid_file" "$bin"; then
        _success "$(basename "$bin") 已在 direct 模式运行 (PID: $(cat "$pid_file"))"
        return 0
    fi
    rm -f "$pid_file"
    mkdir -p "$RUNTIME_DIR" 2>/dev/null
    chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
    # shellcheck disable=SC2086
    nohup "$bin" $args >> "$log_file" 2>&1 &
    echo $! > "$pid_file"
    chmod 600 "$pid_file" 2>/dev/null || true
    sleep 1
    if ! _is_pid_file_running_cmd "$pid_file" "$bin"; then
        _error "$(basename "$bin") 启动后立即退出，请检查日志: ${log_file}"
        rm -f "$pid_file"
        return 1
    fi
    _success "$(basename "$bin") 已以 direct 模式启动 (PID: $(cat "$pid_file"))"
    return 0
}

_direct_stop() {
    local pid_file="$1" bin="$2"
    if [ -s "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        if _is_pid_running_cmd "$pid" "$bin"; then
            kill "$pid" 2>/dev/null
            sleep 1
            _is_pid_running_cmd "$pid" "$bin" && kill -9 "$pid" 2>/dev/null
        fi
    fi
    rm -f "$pid_file"
    return 0
}

_manage_service() {
    local action="$1"

    if [[ "$action" == "start" || "$action" == "restart" ]]; then
        _check_config || return 1
    fi

    case "$INIT_SYSTEM" in
        systemd)
            if [[ "$action" == "start" || "$action" == "restart" ]]; then
                _ensure_service_owned || { _error "服务文件写入失败，无法启动。"; return 1; }
            fi
            if [ "$action" == "status" ]; then
                systemctl status xray --no-pager -l
                return $?
            fi
            if [ "$action" == "start" ] || [ "$action" == "restart" ]; then
                systemctl reset-failed xray >/dev/null 2>&1 || true
            fi
            _info "正在执行: systemctl ${action} xray"
            systemctl "$action" xray
            ;;
        openrc)
            if [[ "$action" == "start" || "$action" == "restart" ]]; then
                _ensure_service_owned || { _error "服务文件写入失败，无法启动。"; return 1; }
            fi
            if [ "$action" == "status" ]; then
                rc-service xray status
                return $?
            fi
            _info "正在执行: rc-service xray ${action}"
            rc-service xray "$action"
            ;;
        direct)
            case "$action" in
                start)
                    _direct_start "$XRAY_BIN" "run -config ${CONFIG_FILE}" "$PID_FILE" "$LOG_FILE"
                    ;;
                stop)
                    _direct_stop "$PID_FILE" "$XRAY_BIN"
                    _success "Xray 已停止。"
                    ;;
                restart)
                    _direct_stop "$PID_FILE" "$XRAY_BIN"
                    sleep 1
                    _direct_start "$XRAY_BIN" "run -config ${CONFIG_FILE}" "$PID_FILE" "$LOG_FILE"
                    ;;
                status)
                    if _is_pid_file_running_cmd "$PID_FILE" "$XRAY_BIN"; then
                        _success "Xray 运行中 (direct 模式, PID: $(cat "$PID_FILE"))"
                    else
                        _warn "Xray 未运行 (direct 模式)"
                        return 1
                    fi
                    ;;
                *) _error "direct 模式不支持: $action"; return 1 ;;
            esac
            ;;
    esac
}

_service_is_running() {
    case "$INIT_SYSTEM" in
        systemd) systemctl is-active --quiet xray 2>/dev/null ;;
        openrc) rc-service xray status 2>/dev/null | grep -q "started" ;;
        direct) _is_pid_file_running_cmd "$PID_FILE" "$XRAY_BIN" ;;
        *) return 1 ;;
    esac
}

# 到 Cloudflare 边缘建几条长连接（--ha-connections）
# CF 期望一个 connector 建 4 条、落在至少 2 个机房，少于此数面板会把隧道标成「降级」。
# 以前 quic 只给 1 条 → 面板一直显示降级；quic 同样支持多条，统一给 4。
_argo_connections() {
    local proto="${1,,}"
    case "$proto" in
        http2) echo "4" ;;
        quic)  echo "4" ;;
        *)     echo "4" ;;
    esac
}

_write_argo_service() {
    local proto="$1" conns="$2"

    case "$INIT_SYSTEM" in
        systemd)
            cat > "$ARGO_SERVICE_FILE" <<EOF
[Unit]
Description=Xray Argo Tunnel (Xray-go)
After=network.target xray.service
Wants=network-online.target

[Service]
User=root
EnvironmentFile=${ARGO_ENV_FILE}
ExecStart=${CLOUDFLARED_BIN} tunnel --no-autoupdate --retries 5 --grace-period 1s --protocol ${proto} --ha-connections ${conns} run
Restart=always
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
            chmod 600 "$ARGO_SERVICE_FILE" 2>/dev/null || true
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable xray-argo >/dev/null 2>&1 || true
            ;;
        openrc)
            # 有 supervise-daemon 就用它托管：进程崩溃（OOM / 被 kill / cloudflared
            # 自己 --retries 耗尽退出）后自动拉起。没有则退回 command_background，
            # 那种模式下崩了就是彻底没了，只能人工重启。
            if command -v supervise-daemon >/dev/null 2>&1; then
                cat > "$ARGO_SERVICE_FILE" <<EOF
#!/sbin/openrc-run
description="Xray Argo Tunnel (Xray-go)"
supervisor="supervise-daemon"
command="${CLOUDFLARED_BIN}"
command_args="tunnel --no-autoupdate --retries 5 --grace-period 1s --protocol ${proto} --ha-connections ${conns} run"
respawn_delay=5
respawn_max=0
pidfile="${ARGO_PID_FILE}"
output_log="${ARGO_LOG_FILE}"
error_log="${ARGO_LOG_FILE}"

start_pre() {
    checkpath -d -m 0700 ${RUNTIME_DIR}
    set -a
    . ${ARGO_ENV_FILE}
    set +a
}

depend() {
    need net
    after firewall
}
EOF
            else
                cat > "$ARGO_SERVICE_FILE" <<EOF
#!/sbin/openrc-run
description="Xray Argo Tunnel (Xray-go)"
command="${CLOUDFLARED_BIN}"
command_args="tunnel --no-autoupdate --retries 5 --grace-period 1s --protocol ${proto} --ha-connections ${conns} run"
command_background="yes"
pidfile="${ARGO_PID_FILE}"
output_log="${ARGO_LOG_FILE}"
error_log="${ARGO_LOG_FILE}"

start_pre() {
    checkpath -d -m 0700 ${RUNTIME_DIR}
    set -a
    . ${ARGO_ENV_FILE}
    set +a
}

depend() {
    need net
    after firewall
}
EOF
            fi
            chmod 755 "$ARGO_SERVICE_FILE" 2>/dev/null || true
            rc-update add xray-argo default >/dev/null 2>&1 || true
            ;;
        direct)
            : > "$ARGO_LOG_FILE" 2>/dev/null || true
            ;;
    esac
    return 0
}

_argo_action() {
    local action="$1"
    local proto conns token
    proto=$(jq -r '.argo_protocol // "http2"' "$META_FILE" 2>/dev/null)
    token=$(jq -r '.argo_token // ""' "$META_FILE" 2>/dev/null)
    [ -n "$proto" ] || proto="http2"
    conns=$(_argo_connections "$proto")

    [ -n "$token" ] || { _error "未配置 Argo Token，跳过 Argo 操作。"; return 1; }

    case "$INIT_SYSTEM" in
        systemd)
            case "$action" in
                start | restart)
                    _write_argo_service "$proto" "$conns"
                    systemctl reset-failed xray-argo >/dev/null 2>&1 || true
                    systemctl "$action" xray-argo
                    ;;
                stop) systemctl stop xray-argo ;;
                status) systemctl status xray-argo --no-pager -l ;;
            esac
            ;;
        openrc)
            case "$action" in
                start | restart)
                    _write_argo_service "$proto" "$conns"
                    rc-service xray-argo "$action"
                    ;;
                stop) rc-service xray-argo stop ;;
                status) rc-service xray-argo status ;;
            esac
            ;;
        direct)
            case "$action" in
                start | restart)
                    _direct_stop "$ARGO_PID_FILE" "$CLOUDFLARED_BIN"
                    mkdir -p "$RUNTIME_DIR" 2>/dev/null
                    TUNNEL_TOKEN="$token" nohup "$CLOUDFLARED_BIN" tunnel --no-autoupdate \
                        --retries 5 --grace-period 1s --protocol "$proto" --ha-connections "$conns" run \
                        >> "$ARGO_LOG_FILE" 2>&1 &
                    echo $! > "$ARGO_PID_FILE"
                    chmod 600 "$ARGO_PID_FILE" 2>/dev/null || true
                    sleep 3
                    if _is_pid_file_running_cmd "$ARGO_PID_FILE" "$CLOUDFLARED_BIN"; then
                        _success "Argo 隧道已启动 (direct 模式)"
                    else
                        _error "Argo 隧道启动失败，请检查日志: ${ARGO_LOG_FILE}"
                        return 1
                    fi
                    ;;
                stop)
                    _direct_stop "$ARGO_PID_FILE" "$CLOUDFLARED_BIN"
                    _success "Argo 隧道已停止。"
                    ;;
                status)
                    if _is_pid_file_running_cmd "$ARGO_PID_FILE" "$CLOUDFLARED_BIN"; then
                        _success "Argo 隧道运行中 (PID: $(cat "$ARGO_PID_FILE"))"
                    else
                        _warn "Argo 隧道未运行。"
                        return 1
                    fi
                    ;;
            esac
            ;;
    esac
}

# ── Argo 保活（cron watchdog）─────────────────────────────────────────
# 服务托管层只能救「进程退出」：systemd 靠 Restart=always，openrc 靠
# supervise-daemon；而 openrc 老模板用 command_background，崩了不会自己起来。
# 这一层用 crontab 每分钟巡检一次：进程不在就拉起；进程在但连续 3 分钟
# 一条边缘连接都没有，也重启（对应「4 条通道全断但进程僵着」的情况）。
#
# 保活脚本落到 $XRAY_DIR 下独立执行 —— xg 是临时下载后跑的，没有固定路径，
# 不能像 CF-B 那样直接让 cron 调主脚本。
KEEPALIVE_SCRIPT="${XRAY_DIR}/argo-keepalive.sh"

_write_keepalive_script() {
    local init="$1"
    cat > "$KEEPALIVE_SCRIPT" <<'KEEPEOF'
#!/bin/sh
# Xray-go Argo 隧道保活（由 xg 生成，crontab 每分钟调用，请勿手改）
STATE="@XRAY_DIR@"
INIT_SYSTEM="@INIT@"
CLOUDFLARED="@CLOUDFLARED@"
ARGO_LOG="@ARGO_LOG@"
META="$STATE/meta.json"
ARGO_PID="@ARGO_PID@"
STRIKE="$STATE/argo-keepalive.strike"

[ -s "$META" ] || exit 0
grep -q 'argo_token' "$META" 2>/dev/null || exit 0

# 上一轮还没跑完就跳过，避免 cron 叠加
if command -v flock >/dev/null 2>&1; then
    exec 9>"$STATE/argo-keepalive.lock" 2>/dev/null || exit 0
    flock -n 9 2>/dev/null || exit 0
fi

_log() { command -v logger >/dev/null 2>&1 && logger -t xg-keepalive "$*" 2>/dev/null; }

_restart() {
    case "$INIT_SYSTEM" in
        systemd)
            systemctl reset-failed xray-argo >/dev/null 2>&1
            systemctl restart xray-argo >/dev/null 2>&1
            ;;
        openrc)
            rc-service xray-argo stop >/dev/null 2>&1
            sleep 1
            rc-service xray-argo start >/dev/null 2>&1
            ;;
        *)
            [ -x "$CLOUDFLARED" ] || return 0
            [ -f "$STATE/argo.env" ] || return 0
            set -a; . "$STATE/argo.env"; set +a
            _proto=$(sed -n 's/.*"argo_protocol"[^,}]*"\([a-z0-9]*\)".*/\1/p' "$META" 2>/dev/null | head -n1)
            [ -n "$_proto" ] || _proto="quic"
            nohup "$CLOUDFLARED" tunnel --no-autoupdate --retries 5 --grace-period 1s \
                --protocol "$_proto" --ha-connections 4 run >> "$ARGO_LOG" 2>&1 &
            echo $! > "$ARGO_PID"
            ;;
    esac
}

running=0
case "$INIT_SYSTEM" in
    systemd) systemctl is-active --quiet xray-argo 2>/dev/null && running=1 ;;
    openrc)  rc-service xray-argo status 2>/dev/null | grep -q started && running=1 ;;
    *)
        if [ -f "$ARGO_PID" ]; then
            _pid=$(cat "$ARGO_PID" 2>/dev/null)
            [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null && running=1
        fi
        ;;
esac

if [ "$running" = "0" ]; then
    _log "Argo 隧道未运行，正在拉起"
    _restart
    echo 0 > "$STRIKE" 2>/dev/null
    exit 0
fi

# 进程在，但到边缘一条连接都没有：连续 3 次才动手，避开刚启动的空窗期
conns=0
for f in /proc/net/udp /proc/net/udp6; do
    [ -r "$f" ] || continue
    n=$(awk 'FNR>1 && $3 ~ /:1EA4$/ {c++} END{print c+0}' "$f" 2>/dev/null)
    conns=$((conns + ${n:-0}))
done
for f in /proc/net/tcp /proc/net/tcp6; do
    [ -r "$f" ] || continue
    n=$(awk 'FNR>1 && $3 ~ /:1EA4$/ && $4=="01" {c++} END{print c+0}' "$f" 2>/dev/null)
    conns=$((conns + ${n:-0}))
done

if [ "$conns" -gt 0 ] 2>/dev/null; then
    echo 0 > "$STRIKE" 2>/dev/null
    exit 0
fi

strike=$(cat "$STRIKE" 2>/dev/null)
strike=${strike:-0}
strike=$((strike + 1))
echo "$strike" > "$STRIKE" 2>/dev/null
if [ "$strike" -ge 3 ]; then
    _log "Argo 隧道连续 3 分钟无边缘连接，正在重启"
    echo 0 > "$STRIKE" 2>/dev/null
    _restart
fi
exit 0
KEEPEOF
    # 注入本机路径与托管方式（用占位符替换，避免 heredoc 里大量转义）
    sed -i \
        -e "s#@XRAY_DIR@#${XRAY_DIR}#g" \
        -e "s#@INIT@#${init}#g" \
        -e "s#@CLOUDFLARED@#${CLOUDFLARED_BIN}#g" \
        -e "s#@ARGO_LOG@#${ARGO_LOG_FILE}#g" \
        -e "s#@ARGO_PID@#${ARGO_PID_FILE}#g" \
        "$KEEPALIVE_SCRIPT" 2>/dev/null || true
    chmod 755 "$KEEPALIVE_SCRIPT" 2>/dev/null || true
}

# cron 命令在、服务也在跑才算可用（Alpine 是 dcron，Debian 是 cron）
_ensure_cron_service() {
    local s started=false pkg="cron"
    if ! command -v crontab >/dev/null 2>&1; then
        command -v apk >/dev/null 2>&1 && pkg="dcron"
        command -v apt-get >/dev/null 2>&1 && pkg="cron"
        command -v dnf >/dev/null 2>&1 && pkg="cronie"
        command -v yum >/dev/null 2>&1 && pkg="cronie"
        _info "正在安装 cron 依赖: ${pkg} ..."
        _pkg_install "$pkg" >/dev/null 2>&1 || true
        command -v crontab >/dev/null 2>&1 || return 1
    fi
    case "$INIT_SYSTEM" in
        systemd)
            for s in cron crond cronie; do
                if systemctl enable --now "${s}.service" >/dev/null 2>&1; then
                    started=true; break
                fi
            done
            ;;
        openrc)
            for s in dcron crond cronie cron; do
                if rc-service "$s" start >/dev/null 2>&1; then
                    rc-update add "$s" default >/dev/null 2>&1 || true
                    started=true; break
                fi
            done
            ;;
        *)
            for s in cron crond; do
                if service "$s" start >/dev/null 2>&1; then started=true; break; fi
            done
            ;;
    esac
    [ "$started" = true ]
}

_watchdog_enabled() {
    command -v crontab >/dev/null 2>&1 || return 1
    crontab -l 2>/dev/null | grep -Fq "$KEEPALIVE_SCRIPT"
}

_enable_argo_watchdog() {
    local job
    _write_keepalive_script "$INIT_SYSTEM" || return 1
    if ! _ensure_cron_service; then
        _warn "cron 不可用，保活未启用（服务托管层仍会兜底）。"
        return 1
    fi
    if _watchdog_enabled; then
        _info "Argo 保活已在运行（每分钟巡检）。"
        return 0
    fi
    job="* * * * * /bin/sh ${KEEPALIVE_SCRIPT} >/dev/null 2>&1"
    if (crontab -l 2>/dev/null; echo "$job") | crontab - 2>/dev/null; then
        _success "Argo 保活已启用：每分钟巡检，进程退出或无边缘连接时自动重启。"
        return 0
    fi
    _warn "写入 crontab 失败，保活未启用。"
    return 1
}

_disable_argo_watchdog() {
    if _watchdog_enabled; then
        crontab -l 2>/dev/null | grep -Fv "$KEEPALIVE_SCRIPT" | crontab - 2>/dev/null || true
        _info "Argo 保活已移除。"
    fi
    rm -f "$KEEPALIVE_SCRIPT" 2>/dev/null || true
    return 0
}

_setup_argo() {
    local token="$1" proto="$2" conns
    conns=$(_argo_connections "$proto")

    printf 'TUNNEL_TOKEN=%s\n' "$token" > "$ARGO_ENV_FILE" || {
        _error "写入 Argo 凭据文件失败。"; return 1;
    }
    chmod 600 "$ARGO_ENV_FILE" 2>/dev/null || true

    _info "正在启动 Cloudflare Argo 隧道 (协议: ${proto}, 连接数: ${conns})..."
    if ! _argo_action start; then
        _error "Argo 隧道启动失败，请检查域名、Token 与 Cloudflare 后台路由配置。"
        return 1
    fi
    return 0
}

_stop_all_services() {
    case "$INIT_SYSTEM" in
        systemd)
            systemctl stop xray-argo >/dev/null 2>&1 || true
            systemctl stop xray >/dev/null 2>&1 || true
            ;;
        openrc)
            rc-service xray-argo stop >/dev/null 2>&1 || true
            rc-service xray stop >/dev/null 2>&1 || true
            ;;
        direct)
            _direct_stop "$ARGO_PID_FILE" "$CLOUDFLARED_BIN"
            _direct_stop "$PID_FILE" "$XRAY_BIN"
            ;;
    esac
    return 0
}

_cf_load_cred() {
    [ -s "$CF_CRED_FILE" ] || return 1
    CF_EMAIL=$(jq -r '.email // ""' "$CF_CRED_FILE" 2>/dev/null)
    CF_KEY=$(jq -r '.api_key // ""' "$CF_CRED_FILE" 2>/dev/null)
    CF_ACCOUNT_ID=$(jq -r '.account_id // ""' "$CF_CRED_FILE" 2>/dev/null)
    [ -n "$CF_EMAIL" ] && [ -n "$CF_KEY" ]
}

_cf_save_cred() {
    mkdir -p "$XRAY_DIR" 2>/dev/null || return 1
    local tmp
    tmp=$(mktemp "${CF_CRED_FILE}.tmp.XXXXXX") || return 1
    if ! jq -n --arg e "$CF_EMAIL" --arg k "$CF_KEY" --arg a "$CF_ACCOUNT_ID" \
        '{email: $e, api_key: $k, account_id: $a}' > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$CF_CRED_FILE" || { rm -f "$tmp"; return 1; }
    return 0
}

_cf_verify() {
    local r
    r=$(curl -sS --connect-timeout 10 --max-time 30 \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" \
        "${CF_API_BASE}/zones?per_page=1" 2>/dev/null || true)
    printf '%s' "$r" | jq -e '.success == true' >/dev/null 2>&1
}

_cf_call() {
    local method="$1" endpoint="$2" data="${3:-}" resp msg
    local args=(curl -sS --connect-timeout 10 --max-time 40 -X "$method"
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY"
        -H "Content-Type: application/json")
    [ -n "$data" ] && args+=(-d "$data")
    resp=$("${args[@]}" "${CF_API_BASE}${endpoint}" 2>/dev/null) || true

    if ! printf '%s' "$resp" | jq -e '.success == true' >/dev/null 2>&1; then
        msg=$(printf '%s' "$resp" | jq -r '[.errors[]?.message] | join("; ")' 2>/dev/null)
        _error "Cloudflare API 失败 [${method} ${endpoint}]: ${msg:-无响应或网络错误}"
        return 1
    fi
    printf '%s' "$resp"
}

_cf_prompt_cred() {
    if _cf_load_cred; then
        local masked="${CF_KEY:0:6}...${CF_KEY: -4}"
        if _ask_yes "  检测到已保存的 Cloudflare 凭据 (${CF_EMAIL} / ${masked})，直接复用? (Y/n): " y; then
            if _cf_verify; then
                _success "Cloudflare 凭据校验通过。"
                return 0
            fi
            _warn "已保存的凭据校验失败，请重新输入。"
        fi
    fi

    local email key
    while true; do
        read -r -p "  Cloudflare 邮箱: " email || return 1
        read -r -s -p "  Global API Key (输入不回显): " key || return 1
        echo "" >&2
        email=$(printf '%s' "$email" | tr -d '[:space:]')
        key=$(printf '%s' "$key" | tr -d '[:space:]')
        if [ -z "$email" ] || [ -z "$key" ]; then
            _warn "邮箱与 API Key 不能为空，请重新输入。"
            continue
        fi
        CF_EMAIL="$email"
        CF_KEY="$key"
        _info "正在校验 Cloudflare 凭据..."
        if _cf_verify; then
            _success "Cloudflare 凭据校验通过。"
            _cf_save_cred || _warn "凭据保存失败，本次部署仍可继续。"
            return 0
        fi
        _error "凭据校验失败（邮箱/Key 错误，或账号未开通 API），请重新输入，Ctrl+C 退出。"
    done
}

_cf_find_zone() {
    local domain="$1" zones zn zi za best="" best_id="" best_acct=""
    zones=$(_cf_call GET "/zones?per_page=100") || return 1
    while read -r zn zi za; do
        [ -n "$zn" ] || continue
        if [ "$domain" = "$zn" ] || [[ "$domain" == *".${zn}" ]]; then
            if [ "${#zn}" -gt "${#best}" ]; then
                best="$zn"; best_id="$zi"; best_acct="$za"
            fi
        fi
    done < <(printf '%s' "$zones" | jq -r '.result[]? | "\(.name) \(.id) \(.account.id)"' 2>/dev/null)
    if [ -z "$best_id" ]; then
        _error "在 Cloudflare 账号中找不到 ${domain} 所属 Zone（请确认域名已托管在该账号）。"
        return 1
    fi
    printf '%s %s\n' "$best_id" "$best_acct"
}

_argo_tunnel_name() {
    local d name
    d="${1%%.*}"
    name=$(printf '%s' "$d" | tr -cd 'a-zA-Z0-9-_')
    [ -n "$name" ] || name="xraygo-$(_rand_port)"
    printf '%s' "$name"
}

_cf_find_tunnel_by_name() {
    local name="$1"
    _cf_call GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=${name}&is_deleted=false&per_page=50" 2>/dev/null \
        | jq -r --arg n "$name" '
            [.result[]? | select(.name == $n and (.deleted_at // null) == null)][0].id // ""
        ' 2>/dev/null
}

_cf_create_tunnel() {
    local name="$1" resp tid token existing
    existing=$(_cf_find_tunnel_by_name "$name")

    if [ -n "$existing" ]; then
        _info "检测到同名隧道 ${name} (${existing})，复用该隧道。"
        tid="$existing"
        token=$(_cf_call GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tid}/token" 2>/dev/null \
            | jq -r '.result // ""' 2>/dev/null)
        if [ -z "$token" ]; then
            _error "复用隧道失败：无法获取 ${tid} 的 Token。"
            return 1
        fi
        printf '%s %s\n' "$tid" "$token"
        return 0
    fi

    resp=$(_cf_call POST "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" \
        "$(jq -n --arg n "$name" '{name: $n, config_src: "cloudflare"}')") || return 1
    tid=$(printf '%s' "$resp" | jq -r '.result.id // ""' 2>/dev/null)
    token=$(printf '%s' "$resp" | jq -r '.result.token // ""' 2>/dev/null)
    if [ -z "$tid" ]; then
        _error "创建隧道失败：接口未返回 tunnel id。"
        return 1
    fi
    if [ -z "$token" ]; then
        token=$(_cf_call GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tid}/token" 2>/dev/null \
            | jq -r '.result // ""' 2>/dev/null)
    fi
    if [ -z "$token" ]; then
        _error "获取隧道 Token 失败（隧道 ${tid} 已创建，可稍后重试）。"
        return 1
    fi
    printf '%s %s\n' "$tid" "$token"
}

_cf_set_ingress() {
    local tid="$1" domain="$2" port="$3"
    _cf_call PUT "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tid}/configurations" \
        "$(jq -n --arg h "$domain" --arg p "$port" \
            '{config: {ingress: [{hostname: $h, service: ("http://127.0.0.1:" + $p)}, {service: "http_status:404"}]}}')" >/dev/null
}

_cf_ensure_dns() {
    local zone_id="$1" domain="$2" tid="$3" target rec rid content
    target="${tid}.cfargotunnel.com"
    rec=$(_cf_call GET "/zones/${zone_id}/dns_records?name=${domain}") || return 1
    rid=$(printf '%s' "$rec" | jq -r '.result[0].id // ""' 2>/dev/null)
    content=$(printf '%s' "$rec" | jq -r '.result[0].content // ""' 2>/dev/null)
    if [ -n "$rid" ] && [ "$content" = "$target" ]; then
        _info "DNS 记录已存在且指向正确: ${domain} -> ${target}"
        return 0
    fi
    if [ -n "$rid" ]; then
        _info "删除旧的 DNS 记录 (${content})..."
        _cf_call DELETE "/zones/${zone_id}/dns_records/${rid}" >/dev/null || true
    fi
    _cf_call POST "/zones/${zone_id}/dns_records" \
        "$(jq -n --arg n "$domain" --arg c "$target" \
            '{type: "CNAME", name: $n, content: $c, proxied: true, ttl: 1}')" >/dev/null
}

_cf_delete_tunnel() {
    local tid="$1"
    [ -n "$tid" ] || return 0
    _cf_call DELETE "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tid}?cascade=true" >/dev/null
}

_cf_delete_dns() {
    local zone_id="$1" domain="$2" rids rid
    [ -n "$zone_id" ] && [ -n "$domain" ] || return 0
    rids=$(_cf_call GET "/zones/${zone_id}/dns_records?name=${domain}" 2>/dev/null \
        | jq -r '.result[]?.id // empty' 2>/dev/null)
    for rid in $rids; do
        _cf_call DELETE "/zones/${zone_id}/dns_records/${rid}" >/dev/null 2>&1 || true
    done
    return 0
}

_argo_auto_setup() {
    ARGO_TOKEN=""
    ARGO_DOMAIN=""
    ARGO_PORT="8001"
    ARGO_PROTOCOL="quic"
    ARGO_TUNNEL_ID=""
    ARGO_ZONE_ID=""

    _info "=== Cloudflare 自动搭建 Argo 隧道 ==="
    _cf_prompt_cred || return 1

    local domain port proto out zone acct
    read -r -p "  Argo 隧道域名（如 a.example.com，需已托管在 CF）: " domain || return 1
    domain=$(printf '%s' "$domain" | tr -d '[:space:]')
    if [ -z "$domain" ] || [[ "$domain" != *.* ]]; then
        _error "域名格式不正确，应为 a.example.com 这类完整主机名。"
        return 1
    fi

    read -r -p "  Argo 本地端口（回车 8001，需与 ingress 一致）: " port || port=""
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || port="8001"

    read -r -p "  隧道协议 [1.quic 2.http2]（回车 quic）: " proto || proto=""
    case "${proto,,}" in
        1 | quic | q)          proto="quic" ;;
        2 | http2 | h2 | tcp)  proto="http2" ;;
        *)                     proto="quic" ;;
    esac

    _info "正在查询 ${domain} 所属 Zone..."
    out=$(_cf_find_zone "$domain") || return 1
    read -r zone acct <<< "$out"
    [ -n "$acct" ] && CF_ACCOUNT_ID="$acct"
    [ -n "$CF_ACCOUNT_ID" ] || { _error "未获取到 Cloudflare Account ID。"; return 1; }
    _cf_save_cred >/dev/null 2>&1 || true

    local tname tid token
    tname=$(_argo_tunnel_name "$domain")
    _info "正在创建命名隧道: ${tname} ..."
    out=$(_cf_create_tunnel "$tname") || return 1
    read -r tid token <<< "$out"
    [ -n "$tid" ] && [ -n "$token" ] || { _error "隧道创建结果异常。"; return 1; }
    _success "隧道已创建: ${tid}"

    _info "正在写入 ingress 规则 (http://127.0.0.1:${port})..."
    if _cf_set_ingress "$tid" "$domain" "$port"; then
        _success "ingress 规则已写入。"
    else
        _warn "ingress 写入失败，可在 CF 控制台手动添加 Public Hostname。"
    fi

    _info "正在创建 DNS CNAME ..."
    if _cf_ensure_dns "$zone" "$domain" "$tid"; then
        _success "DNS 解析已就绪: ${domain} -> ${tid}.cfargotunnel.com"
    else
        _warn "DNS 自动创建失败，请手动添加 CNAME 到 ${tid}.cfargotunnel.com（橙云）。"
    fi

    ARGO_TOKEN="$token"
    ARGO_DOMAIN="$domain"
    ARGO_PORT="$port"
    ARGO_PROTOCOL="$proto"
    ARGO_TUNNEL_ID="$tid"
    ARGO_ZONE_ID="$zone"
    return 0
}

_argo_auto_cleanup() {
    local tid="$1" zid="$2" domain="$3"
    [ -n "$tid" ] || return 0
    if ! _cf_load_cred; then
        _warn "未找到 Cloudflare 凭据，跳过云端清理（隧道: ${tid}），请手动在控制台删除。"
        return 0
    fi
    _info "正在删除 Cloudflare 云端隧道 (${tid})..."
    if _cf_delete_tunnel "$tid"; then
        _success "云端隧道已删除。"
    else
        _warn "云端隧道删除失败，请手动清理。"
    fi
    if [ -n "$zid" ] && [ -n "$domain" ]; then
        _info "正在删除 DNS 记录 (${domain})..."
        _cf_delete_dns "$zid" "$domain" && _success "DNS 记录已删除。"
    fi
    return 0
}

_server_ip() {
    local ip=""
    ip=$(curl -4 -fsS --connect-timeout 4 --max-time 8 "https://api.ipify.org" 2>/dev/null)
    [ -n "$ip" ] || ip=$(curl -4 -fsS --connect-timeout 4 --max-time 8 "https://ip.sb" 2>/dev/null | head -n1)
    [ -n "$ip" ] || ip=$(curl -6 -fsS --connect-timeout 4 --max-time 8 "https://api64.ipify.org" 2>/dev/null)
    printf '%s' "$ip" | tr -d '[:space:]'
}

_isp_tag() {
    local uc="" isp
    declare -A sc=([A]=ᴀ [B]=ʙ [C]=ᴄ [D]=ᴅ [E]=ᴇ [F]=ꜰ [G]=ɢ [H]=ʜ [I]=ɪ [J]=ᴊ [K]=ᴋ [L]=ʟ [M]=ᴍ [N]=ɴ [O]=ᴏ [P]=ᴘ [Q]=ꞯ [R]=ʀ [S]=ꜱ [T]=ᴛ [U]=ᴜ [V]=ᴠ [W]=ᴡ [X]=x [Y]=ʏ [Z]=ᴢ)
    uc=$(curl -sm 4 "https://ipinfo.io/country" 2>/dev/null | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    if [ -z "$uc" ] || [ "${#uc}" -ne 2 ]; then
        uc=$(curl -sm 4 "https://api.ip.sb/geoip" 2>/dev/null | grep -o '"country_code":"[^"]*"' | cut -d'"' -f4 | tr '[:lower:]' '[:upper:]')
    fi
    isp="${sc[${uc:0:1}]}${sc[${uc:1:1}]}"
    [ -z "$isp" ] && isp="ɴᴅ"
    printf '%s' "$isp"
}

_argo_delete_node() {
    _check_root
    _detect_init_system

    if [ ! -s "$META_FILE" ]; then
        _error "尚未部署，没有可删除的 Argo 节点。"
        return 1
    fi

    local token domain tid zid tname remain
    token=$(jq -r '.argo_token // ""' "$META_FILE" 2>/dev/null)
    domain=$(jq -r '.argo_domain // ""' "$META_FILE" 2>/dev/null)
    tid=$(jq -r '.argo_tunnel_id // ""' "$META_FILE" 2>/dev/null)
    zid=$(jq -r '.argo_zone_id // ""' "$META_FILE" 2>/dev/null)

    if [ -z "$token" ] && [ -z "$tid" ]; then
        _warn "当前没有 Argo 节点可删除。"
        return 0
    fi

    tname=$(_argo_tunnel_name "$domain")

    echo "" >&2
    echo -e "${RED}  即将删除 Argo 节点：${NC}" >&2
    echo -e "    域名      : ${domain:-未知}" >&2
    echo -e "    隧道名称  : ${tname}" >&2
    echo -e "    隧道 ID   : ${tid:-未知（手动 Token 部署）}" >&2
    echo -e "    - 停止 cloudflared，移除 Argo 服务与本地配置" >&2
    if [ -n "$tid" ]; then
        echo -e "    - ${YELLOW}删除 Cloudflare 云端隧道 ${tid} 及其 DNS 解析${NC}" >&2
    else
        echo -e "    - ${YELLOW}未记录隧道 ID，云端资源需手动删除${NC}" >&2
    fi
    echo "" >&2

    if ! _ask_yes "  确认删除该 Argo 节点? (y/N): " n; then
        _info "已取消。"
        return 0
    fi

    # 1. 停止并移除 Argo 服务
    _info "正在停止 Argo 隧道..."
    case "$INIT_SYSTEM" in
        systemd)
            systemctl disable --now xray-argo >/dev/null 2>&1 || true
            rm -f "$ARGO_SERVICE_FILE"
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl reset-failed xray-argo >/dev/null 2>&1 || true
            ;;
        openrc)
            rc-service xray-argo stop >/dev/null 2>&1 || true
            rc-update del xray-argo default >/dev/null 2>&1 || true
            rm -f "$ARGO_SERVICE_FILE"
            ;;
        direct)
            _direct_stop "$ARGO_PID_FILE" "$CLOUDFLARED_BIN"
            ;;
    esac

    # 2. 删除云端隧道与 DNS（必须在删除凭据文件之前）
    if [ -n "$tid" ]; then
        _argo_auto_cleanup "$tid" "$zid" "$domain"
    else
        _warn "该节点为手动 Token 部署，未记录隧道 ID，请在 Cloudflare 控制台手动删除隧道与 DNS。"
    fi

    # 3. 清理本地 Argo 配置
    rm -f "$ARGO_ENV_FILE"
    local tmp
    tmp=$(mktemp "${META_FILE}.tmp.XXXXXX") || return 1
    if ! jq 'del(.argo_token, .argo_tunnel_id, .argo_zone_id)
             | .argo_domain = ""
             | .argo_port = 0
             | .argo_protocol = ""' "$META_FILE" > "$tmp"; then
        rm -f "$tmp"
        _error "更新 meta.json 失败。"
        return 1
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$META_FILE" || { rm -f "$tmp"; return 1; }

    # 4. 已无任何节点，停掉 Xray（空 inbounds 不是合法配置）
    _info "正在停止 Xray 服务..."
    case "$INIT_SYSTEM" in
        systemd) systemctl stop xray >/dev/null 2>&1 || true ;;
        openrc)  rc-service xray stop >/dev/null 2>&1 || true ;;
        direct)  _direct_stop "$PID_FILE" "$XRAY_BIN" ;;
    esac

    _success "Argo 节点已删除：云端隧道、DNS 解析、本地配置均已清理。"
    _info "如需彻底清理本机文件，执行菜单 [11] 卸载部署。"
    return 0
}

_view_log() {
    if [ -s "$LOG_FILE" ]; then
        _info "按 Ctrl+C 退出日志查看 (${LOG_FILE})。"
        tail -f "$LOG_FILE"
    elif [ "$INIT_SYSTEM" = "systemd" ]; then
        _info "按 Ctrl+C 退出日志查看 (journalctl -u xray)。"
        journalctl -u xray -f --no-pager
    else
        _warn "日志文件不存在: ${LOG_FILE}"
        return 1
    fi
}

_view_argo_log() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        _info "按 Ctrl+C 退出日志查看。"
        journalctl -u xray-argo -f --no-pager
    else
        [ -f "$ARGO_LOG_FILE" ] || { _warn "日志文件不存在: ${ARGO_LOG_FILE}"; return 1; }
        _info "按 Ctrl+C 退出日志查看 (${ARGO_LOG_FILE})。"
        tail -f "$ARGO_LOG_FILE"
    fi
}

_service_menu() {
    while true; do
        echo "" >&2
        echo -e "${CYAN}  ───── 服务控制 ─────${NC}" >&2
        echo -e "    ${GREEN}[1]${NC} 启动 Xray" >&2
        echo -e "    ${GREEN}[2]${NC} 停止 Xray" >&2
        echo -e "    ${GREEN}[3]${NC} 重启 Xray" >&2
        echo -e "    ${GREEN}[4]${NC} 重启 Argo 隧道" >&2
        echo -e "    ${GREEN}[5]${NC} 查看状态" >&2
        echo -e "    ${YELLOW}[0]${NC} 返回" >&2
        local c=""
        read -r -p "  请选择 [0-5]: " c || return 0
        case "$c" in
            1) _manage_service start ;;
            2) _manage_service stop ;;
            3) _manage_service restart ;;
            4) _argo_action restart ;;
            5) _show_status ;;
            0) return 0 ;;
            *) _error "无效选项" ;;
        esac
        echo "" >&2
        read -n 1 -s -r -p "按任意键继续..." || return 0
    done
}

_update_core() {
    _check_root
    _detect_init_system
    _install_dependencies || return 1
    _install_xray_core update || return 1

    if [ -s "$META_FILE" ]; then
        _write_config || return 1
        if _check_config; then
            _manage_service restart || _warn "核心已更新，但服务重启失败。"
        else
            _error "现有配置无法被新核心加载，请检查后手动处理。"
            return 1
        fi
    fi
    return 0
}

_update_script() {
    _check_root
    local force="${1:-}"
    _info "正在检查脚本更新... 当前版本 $(_version_tag)"

    local stage
    stage=$(mktemp /var/tmp/.xray-go.sh.new.XXXXXX) || return 1
    local url="${SCRIPT_UPDATE_URL}?v=$(date +%s)"

    if ! _download "$url" "$stage"; then
        rm -f "$stage"
        _error "脚本下载失败，请检查网络。"
        return 1
    fi
    if ! head -n 1 "$stage" | grep -q '^#!/bin/bash' || ! bash -n "$stage" 2>/dev/null; then
        rm -f "$stage"
        _error "下载的脚本未通过语法校验，已拒绝覆盖。"
        return 1
    fi

    # 从新脚本中提取版本号，用于更新前后的对比提示
    local new_ver
    new_ver=$(sed -n 's/^export SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$stage" 2>/dev/null | head -n1)

    if [ -n "$new_ver" ] && [ "$new_ver" = "$SCRIPT_VERSION" ] && [ "$force" != "force" ]; then
        rm -f "$stage"
        _success "当前已是最新版本 V${SCRIPT_VERSION}，无需更新。"
        _info "如需强制覆盖重装: $(basename "$0") update-script force"
        return 0
    fi

    local self_path target
    self_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
    case "$self_path" in
        /dev/* | /proc/* | "")
            target="/usr/local/bin/xg"
            ;;
        *)
            if [ -f "$self_path" ] && [ -w "$(dirname "$self_path")" ]; then
                target="$self_path"
            else
                target="/usr/local/bin/xg"
            fi
            ;;
    esac
    mkdir -p "$(dirname "$target")" 2>/dev/null || true

    chmod 755 "$stage" || { rm -f "$stage"; return 1; }
    if ! mv -f "$stage" "$target" 2>/dev/null; then
        rm -f "$stage"
        _error "写入 ${target} 失败。"
        return 1
    fi

    if [ -n "$new_ver" ] && [ "$new_ver" != "$SCRIPT_VERSION" ]; then
        _success "脚本已更新: V${SCRIPT_VERSION}  ->  V${new_ver}"
    elif [ -n "$new_ver" ]; then
        _success "脚本已覆盖重装: V${new_ver}（版本号未变化）"
    else
        _success "脚本已更新（远端未标注版本号）"
    fi
    _info "文件位置: ${target}"
    _info "重新运行 ${target} 即可应用变更；用 -v 可确认版本。"
    return 0
}

_uninstall_deploy() {
    _check_root
    _detect_init_system

    local cloud_tid="" cloud_zid="" cloud_domain="" cloud_token=""
    if [ -s "$META_FILE" ]; then
        if command -v jq >/dev/null 2>&1; then
            cloud_tid=$(jq -r '.argo_tunnel_id // ""' "$META_FILE" 2>/dev/null)
            cloud_zid=$(jq -r '.argo_zone_id // ""' "$META_FILE" 2>/dev/null)
            cloud_domain=$(jq -r '.argo_domain // ""' "$META_FILE" 2>/dev/null)
            cloud_token=$(jq -r '.argo_token // ""' "$META_FILE" 2>/dev/null)
        else
            _warn "未安装 jq，读不到 Argo 隧道信息；云端隧道与 DNS 需手动在 Cloudflare 控制台删除。"
        fi
    fi

    echo "" >&2
    echo -e "${RED}  即将删除以下内容：${NC}" >&2
    echo -e "    - Xray 服务与 Argo 隧道服务" >&2
    echo -e "    - 配置目录: ${XRAY_DIR}（含配置、cloudflared、CF 凭据）" >&2
    echo -e "    - 日志: ${LOG_FILE} / ${ARGO_LOG_FILE}" >&2
    echo -e "    - 运行目录: ${RUNTIME_DIR}" >&2
    local self_cmd="$SELF_BIN"
    [ -f "$self_cmd" ] && echo -e "    - 管理命令: ${self_cmd}" >&2
    if [ -n "$cloud_tid" ]; then
        echo -e "    - ${YELLOW}Cloudflare 云端隧道 ${cloud_tid}${NC}" >&2
        [ -n "$cloud_domain" ] && echo -e "    - ${YELLOW}DNS 解析记录 ${cloud_domain}${NC}" >&2
    elif [ -n "$cloud_token" ]; then
        echo -e "    - ${YELLOW}注意：该 Argo 为手动 Token 部署，云端隧道需手动删除${NC}" >&2
    fi
    echo "" >&2

    if ! _ask_yes "  确认卸载以上全部内容? (y/N): " n; then
        _info "已取消卸载。"
        return 0
    fi

    _info "正在停止服务..."
    _disable_argo_watchdog
    _stop_all_services

    # 先清理云端（需要在删除凭据文件之前完成）
    if [ -n "$cloud_tid" ]; then
        _argo_auto_cleanup "$cloud_tid" "$cloud_zid" "$cloud_domain"
    elif [ -n "$cloud_token" ]; then
        _warn "未记录隧道 ID（手动 Token 部署），跳过云端清理，请手动在 Cloudflare 控制台删除隧道与 DNS。"
    fi

    # 无条件清理所有托管痕迹：不依赖 INIT_SYSTEM 判定，避免容器/混合环境残留 unit
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now xray-argo >/dev/null 2>&1 || true
        systemctl disable --now xray >/dev/null 2>&1 || true
    fi
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray-argo.service
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed xray xray-argo >/dev/null 2>&1 || true
    fi

    if command -v rc-service >/dev/null 2>&1; then
        rc-service xray-argo stop >/dev/null 2>&1 || true
        rc-service xray stop >/dev/null 2>&1 || true
    fi
    if command -v rc-update >/dev/null 2>&1; then
        rc-update del xray-argo default >/dev/null 2>&1 || true
        rc-update del xray default >/dev/null 2>&1 || true
    fi
    rm -f /etc/init.d/xray /etc/init.d/xray-argo

    _info "正在清理文件..."
    rm -rf "$XRAY_DIR" "$RUNTIME_DIR"
    rm -f "$LOG_FILE" "$ARGO_LOG_FILE"

    # 管理命令一并删除：确认时已列在清单里，不再二次询问
    if [ -f "$self_cmd" ]; then
        rm -f "$self_cmd" 2>/dev/null \
            && _success "管理命令已删除: ${self_cmd}" \
            || _warn "删除 ${self_cmd} 失败，请手动执行 rm -f ${self_cmd}"
    fi

    _success "Xray-go 已卸载完成。"
    echo -e "  ${CYAN}当前终端里的 xg 进程还在内存中，退出后 xg 命令即不可用。${NC}" >&2
    echo -e "  如需重新部署: ${CYAN}bash <(curl -Ls https://raw.githubusercontent.com/XIEBROxzz/cf-lite/main/install.sh)${NC}" >&2
    # 标记已卸载，调用方据此直接退出，不再回主菜单
    XG_UNINSTALLED=1
    return 0
}

# 由 meta.json 生成 config.json（只有 Argo 一个 inbound，单一数据源，可随时重建）
_build_config_from_meta() {
    jq --arg logfile "$LOG_FILE" '
        . as $m
        | {
            log: {loglevel: "warning", error: $logfile},
            inbounds: ([
                (if ((($m.argo_port // 0) > 0) and (($m.argo_token // "") != "")) then {
                    tag: "xhttp-argo",
                    listen: "127.0.0.1",
                    port: ($m.argo_port | tonumber),
                    protocol: "vless",
                    settings: {
                        clients: [{id: $m.uuid}],
                        decryption: "none"
                    },
                    streamSettings: {
                        network: "xhttp",
                        security: "none",
                        xhttpSettings: {path: ("/" + ($m.argo_path // "argo")), mode: "auto"},
                        # cloudflared 会带 X-Forwarded-For；不声明信任来源时核心每次请求都刷一条 Warning
                        # 这个 inbound 只监听 127.0.0.1，信任本机回环是安全的
                        sockopt: {trustedXForwardedFor: ["127.0.0.1/32", "::1/128"]}
                    },
                    sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], metadataOnly: false}
                } else empty end)
            ]),
            outbounds: [{tag: "direct", protocol: "freedom"}]
        }
    ' "$META_FILE"
}


# Argo 隧道进程是否在跑（三种托管模式统一判断）
_argo_is_running() {
    case "$INIT_SYSTEM" in
        systemd) systemctl is-active --quiet xray-argo 2>/dev/null ;;
        openrc)  rc-service xray-argo status 2>/dev/null | grep -q started ;;
        direct)  _is_pid_file_running_cmd "$ARGO_PID_FILE" "$CLOUDFLARED_BIN" ;;
        *)       return 1 ;;
    esac
}


# 已部署 Argo 但进程没在跑时，顺手拉起来。
# 典型场景：跑大流量时 cloudflared 被 OOM kill / --retries 耗尽退出，
# openrc 老模板没有 supervise-daemon，崩了就再也不会自己起来。
_ensure_argo_running() {
    [ -s "$META_FILE" ] || return 0
    local token
    token=$(jq -r '.argo_token // ""' "$META_FILE" 2>/dev/null | tr -d '\r')
    [ -n "$token" ] || return 0
    _argo_is_running && return 0
    _warn "Argo 隧道当前未运行，正在拉起..."
    if _argo_action restart; then
        _success "Argo 隧道已恢复。"
        return 0
    fi
    _error "Argo 隧道拉起失败，执行 xg argo-log 查看原因。"
    return 1
}


# 连通性自检：环境 / 隧道 / Argo 传输 / 日志 / 结论
_diag() {
    _check_root
    _detect_init_system

    echo "" >&2
    echo -e "${CYAN}════════ 环境 ════════${NC}" >&2
    echo -e "  脚本版本 : $(_version_full)" >&2
    local core_ver="未安装"
    [ -x "$XRAY_BIN" ] && core_ver=$("$XRAY_BIN" version 2>/dev/null | head -n1)
    echo -e "  核心版本 : ${core_ver}" >&2
    echo -e "  服务模式 : ${INIT_SYSTEM}" >&2
    if _service_is_running; then
        echo -e "  Xray     : ${GREEN}运行中${NC}" >&2
    else
        echo -e "  Xray     : ${RED}已停止${NC}" >&2
    fi
    if _argo_is_running; then
        echo -e "  Argo     : ${GREEN}运行中${NC}" >&2
    else
        echo -e "  Argo     : ${RED}未运行${NC}" >&2
    fi
    # 服务文件被别人占着时，本脚本怎么启都是启别人的服务（CF-A 遗留的典型症状）
    if [ -n "$SERVICE_FILE" ] && [ -f "$SERVICE_FILE" ]; then
        if _service_file_is_ours; then
            # openrc 的 init 脚本必须可执行，否则 rc-service 直接 Permission denied
            if [ "$INIT_SYSTEM" = "openrc" ] && [ ! -x "$SERVICE_FILE" ]; then
                echo -e "  服务文件 : ${RED}权限异常${NC}（${SERVICE_FILE} 不可执行）" >&2
            else
                echo -e "  服务文件 : 正常（本脚本）" >&2
            fi
        else
            echo -e "  服务文件 : ${RED}被其他脚本占用${NC}（${SERVICE_FILE}）" >&2
        fi
    fi

    if [ ! -s "$META_FILE" ]; then
        _warn "尚未部署，无法继续自检。"
        return 1
    fi

    local ap adom aproto
    IFS=$'\x1f' read -r ap adom aproto < <(
        jq -r '[((.argo_port // 0) | tostring), (.argo_domain // ""), (.argo_protocol // "")]
               | join("\u001f")' "$META_FILE" 2>/dev/null | tr -d '\r'
    )

    if [ "${ap:-0}" = "0" ] || [ -z "${adom:-}" ]; then
        _warn "尚未配置 Argo 隧道。"
        return 1
    fi

    echo "" >&2
    echo -e "${CYAN}════════ 隧道 ════════${NC}" >&2
    echo -e "  域名     : ${adom}" >&2
    echo -e "  隧道协议 : ${aproto:-未记录}" >&2
    echo -e "  本地监听 : 127.0.0.1:${ap}   TCP:$(_listen_check "${ap}" t)" >&2

    local at_state="" at_cfg="" at_udp=0 at_tcp=0 at_log="" at_mix="" at_pre="" xff=0 xff_cfg=0
    IFS=$'\x1f' read -r at_state at_cfg at_udp at_tcp at_log at_mix at_pre < <(_argo_transport)
    echo "" >&2
    echo -e "${CYAN}════════ Argo 传输（UDP / QUIC）════════${NC}" >&2
    echo -e "  配置协议 : ${at_cfg:-未记录}   （cloudflared --protocol）" >&2
    echo -e "  日志协议 : ${at_log:-未采集到}   （protocol=xxx）" >&2
    echo -e "  边缘连接 : UDP ${at_udp:-0} 条 / TCP ${at_tcp:-0} 条   （端口 7844）" >&2
    # 最近一次启动注册了几条、各用什么协议（CF 期望 4 条）
    if [ -n "${at_mix:-}" ]; then
        local mq="${at_mix%%:*}" mrest="${at_mix#*:}" mh="${mrest%%:*}" mn="${mrest##*:}"
        echo -e "  连接明细 : quic ${mq:-0} 条 / http2 ${mh:-0} 条（最近一次启动，共 ${mn:-0} 条）" >&2
        if [ "${mn:-0}" -lt 4 ] 2>/dev/null; then
            echo -e "     ${YELLOW}不足 4 条${NC}：CF 面板会把隧道标成「降级」，可稍等再查。" >&2
        fi
    fi
    case "$at_state" in
        quic)     echo -e "  实际传输 : ${GREEN}QUIC（UDP）${NC}" >&2 ;;
        http2)    echo -e "  实际传输 : ${YELLOW}HTTP/2（TCP）${NC}" >&2 ;;
        mixed)    echo -e "  实际传输 : ${YELLOW}部分 QUIC、部分 HTTP/2${NC}（UDP 7844 只通了一部分）" >&2 ;;
        fallback) echo -e "  实际传输 : ${RED}已从 QUIC 回退到 HTTP/2${NC}" >&2 ;;
        *)        echo -e "  实际传输 : ${YELLOW}无法判定${NC}（连接计数与隧道日志都没取到）" >&2 ;;
    esac
    # 混合/回退时把每条连接的协议列出来，省得再手工翻日志
    if [ "${at_state:-}" = "mixed" ] || [ "${at_state:-}" = "fallback" ]; then
        local conns
        conns=$(_argo_batch | grep 'Registered tunnel connection' | tail -n 8 \
            | sed -n 's/.*connIndex=\([0-9]*\).*location=\([a-z0-9]*\).*protocol=\([a-z0-9]*\).*/       conn\1  \2  \3/p')
        [ -n "$conns" ] && printf '%s\n' "$conns" >&2
    fi
    # cloudflared 启动时的 UDP 连通性自检结果（region1/region2 各探一次）
    if [ -n "${at_pre:-}" ] && [ "${at_pre}" != "-/-" ]; then
        echo -e "  UDP 自检 : region1 ${at_pre%%/*} / region2 ${at_pre##*/}   （cloudflared precheck）" >&2
    fi
    if [ "${at_udp:-0}" = "0" ] && [ "${at_tcp:-0}" = "0" ] && _argo_is_running; then
        echo -e "     ${CYAN}cloudflared 在跑但数不到连接${NC}：本机没有 ss/netstat，内核表也读不到。" >&2
        echo -e "     不影响使用，可看 ${CYAN}xg argo-log${NC} 里的 protocol=xxx。" >&2
    fi
    if [ "${at_state:-}" = "unknown" ] && _argo_is_running; then
        local lsz
        lsz=$(wc -c < "$ARGO_LOG_FILE" 2>/dev/null | tr -d ' ')
        echo -e "     ${CYAN}诊断${NC}：日志 ${ARGO_LOG_FILE} 共 ${lsz:-0} 字节" >&2
        echo -e "     为 0 → cloudflared 没往这里写（openrc 下可能进了 syslog）" >&2
        echo -e "     非 0 → ${CYAN}grep -c 'Registered tunnel connection' ${ARGO_LOG_FILE}${NC} 看有没有注册记录" >&2
    fi

    # cloudflared 每个请求都带 X-Forwarded-For；核心没声明信任来源就刷 Error（无害但很吵）
    # 注意日志原文是 "ignored potentially forged \"X-Forwarded-For\""，不是 trustedXForwardedFor
    if [ -s "$LOG_FILE" ]; then
        xff=$(grep -c 'ignored potentially forged' "$LOG_FILE" 2>/dev/null)
        xff=${xff:-0}
    fi
    # 当前 config.json 里是否已经声明了信任来源（区分「历史日志」和「还没修」）
    if [ -s "$CONFIG_FILE" ] && grep -q 'trustedXForwardedFor' "$CONFIG_FILE" 2>/dev/null; then
        xff_cfg=1
    fi
    if [ "$xff" -gt 0 ] 2>/dev/null; then
        echo -e "  XFF 警告 : ${xff} 条（不影响使用，仅刷日志）" >&2
    fi

    echo "" >&2
    echo -e "${CYAN}════════ Xray 日志（末 10 行）════════${NC}" >&2
    tail -n 10 "$LOG_FILE" 2>/dev/null | sed 's/^/  /' >&2 || echo "  (无日志)" >&2

    echo "" >&2
    echo -e "${CYAN}════════ 结论 ════════${NC}" >&2
    local issues=0

    if [ "$(_listen_check "${ap}" t)" = "否" ]; then
        issues=$((issues + 1))
        _error "Xray 没有在 127.0.0.1:${ap} 监听 —— cloudflared 转进来的流量无处可去。"
        echo -e "     处理：菜单 [8] 重建配置，或查看 ${LOG_FILE}。" >&2
    fi
    if [ -n "$SERVICE_FILE" ] && [ -f "$SERVICE_FILE" ] && ! _service_file_is_ours; then
        issues=$((issues + 1))
        _error "服务文件 ${SERVICE_FILE} 不是本脚本写的 —— 启动的是别人的 xray，配置对不上就会秒退重启。"
        echo -e "     处理：${CYAN}xg restart${NC}（或菜单 [4] → 重启），会自动重写服务文件。" >&2
    fi
    if ! _service_is_running; then
        issues=$((issues + 1))
        _error "Xray 服务未运行，节点一定不通。"
        echo -e "     处理：菜单 [4] 服务控制 → 启动。" >&2
    fi
    if ! _argo_is_running; then
        issues=$((issues + 1))
        _error "cloudflared 未运行，Cloudflare 边缘无法把流量送到本机。"
        echo -e "     处理：${CYAN}xg restart${NC}（会顺带拉起 Argo），或 ${CYAN}xg argo-log${NC} 看退出原因。" >&2

        # 大流量下崩溃最常见的原因是 OOM，先看一眼内核有没有留证据
        local oom=""
        oom=$(dmesg 2>/dev/null | grep -iE 'oom-kill|killed process.*cloudflared' | tail -n1)
        [ -n "$oom" ] || oom=$(grep -ihE 'oom-kill|killed process.*cloudflared' \
            /var/log/messages /var/log/syslog 2>/dev/null | tail -n1)
        if [ -n "$oom" ]; then
            echo -e "     ${YELLOW}疑似内存不足被内核 kill${NC}：$(printf '%s' "$oom" | cut -c1-120)" >&2
            echo -e "     加 swap 或换更大内存的机器；自动重启仍会被反复杀。" >&2
        fi

        # openrc 老模板用 command_background，崩了不会自己起来
        if [ "$INIT_SYSTEM" = "openrc" ] && [ -f "$ARGO_SERVICE_FILE" ] \
           && ! grep -q 'supervise-daemon' "$ARGO_SERVICE_FILE" 2>/dev/null; then
            echo -e "     ${YELLOW}当前 Argo 服务脚本是旧模板${NC}（无自动重启）：${CYAN}xg argo restart${NC} 会重写为守护模式。" >&2
        fi
    fi

    case "$at_state" in
        fallback)
            issues=$((issues + 1))
            _warn "Argo 隧道已从 QUIC 回退到 HTTP/2 —— 本机到 Cloudflare 的 UDP 7844 不通。" >&2
            echo -e "     此时客户端用 H3-Argo 链接，第一跳是 UDP，但隧道这一跳已经是 TCP。" >&2
            echo -e "     处理：换网络/换机器，或直接改用 H2-Argo 链接（更稳）。" >&2
            ;;
        mixed)
            issues=$((issues + 1))
            _warn "隧道里同时有 QUIC 和 HTTP/2 连接 —— UDP 7844 只通了一部分（部分连接回退）。" >&2
            echo -e "     常见原因：运营商/云厂商对 UDP 限速或丢包，或出口 NAT 会话数受限。" >&2
            echo -e "     能用，但性能不稳定。想稳定就重部署选 ${CYAN}http2${NC}；想全 UDP 只能换网络/换机器。" >&2
            ;;
        http2)
            if [ "$at_cfg" = "quic" ]; then
                issues=$((issues + 1))
                _warn "配置是 quic，但只有 TCP 连接 —— UDP 不通，已回退 HTTP/2。" >&2
            else
                echo -e "  ${CYAN}Argo 隧道走 HTTP/2（TCP）${NC}：http2 模式的正常表现。" >&2
                echo -e "     想要全段 UDP：重部署时选 quic，客户端再用 H3-Argo 链接。" >&2
            fi
            ;;
        quic)
            echo -e "  ${GREEN}Argo 隧道走 QUIC（UDP 7844）${NC}：客户端用 H3-Argo 链接即为全段 UDP。" >&2
            # 自检里有个区域探针失败但连接都注册上了：说明 UDP 是「部分可用」，
            # 现在能跑，但网络抖动时可能出现个别连接重建
            if [ -n "${at_pre:-}" ] && [ "${at_pre##*/}" = "FAIL" ]; then
                echo -e "     ${YELLOW}注意${NC}：UDP 自检 region2 失败，UDP 7844 属「部分可用」。" >&2
                echo -e "     当前连接都注册成功，可正常使用；若以后频繁掉线，改用 http2 更稳。" >&2
            fi
            ;;
    esac

    if [ "${xff:-0}" -gt 0 ] 2>/dev/null; then
        if [ "${xff_cfg:-0}" = "1" ]; then
            echo -e "  ${CYAN}X-Forwarded-For 记录${NC}：config.json 已声明 trustedXForwardedFor，这些是改配置之前的历史日志。" >&2
            echo -e "     想清空：${CYAN}> ${LOG_FILE}${NC}（不影响运行），之后应不再新增。" >&2
        else
            echo -e "  ${CYAN}X-Forwarded-For 警告${NC}：Argo 每个请求都会带该头，核心未声明信任来源就忽略它并记一条 Error。" >&2
            echo -e "     影响：日志里的客户端 IP 全是 127.0.0.1，连通性不受影响。" >&2
            echo -e "     消除办法：${CYAN}xg rebuild${NC}（会用新版模板给 Argo inbound 加 sockopt.trustedXForwardedFor）。" >&2
        fi
    fi

    # quic-go 的接收缓冲区告警：rmem_max 太小会限制 QUIC 单连接吞吐
    if _collect_argo_logtext | grep -qi 'increase receive buffer size'; then
        echo -e "  ${CYAN}UDP 缓冲区偏小${NC}：quic-go 提示 rmem_max 不足，会限制 QUIC 吞吐（不影响连通性）。" >&2
        echo -e "     能改就 ${CYAN}sysctl -w net.core.rmem_max=7500000${NC}；容器里通常无权限，改不了可忽略。" >&2
    fi

    [ "$issues" -eq 0 ] && echo -e "  ${GREEN}未发现服务端明显异常${NC}" >&2

    echo "" >&2
    return 0
}


# 生成 H2-Argo / H3-Argo 两条节点链接
_show_links() {
    [ -s "$META_FILE" ] || { _error "尚未部署，请先执行 [1] 部署 Argo 隧道。"; return 1; }

    local uuid argo_port argo_path argo_domain argo_protocol
    # 用 \x1f(US) 分隔：制表符属于空白字符，连续出现会被 read 合并，导致空字段错位
    IFS=$'\x1f' read -r uuid argo_port argo_path argo_domain argo_protocol < <(
        jq -r '[.uuid // "", ((.argo_port // 0) | tostring), (.argo_path // ""),
                (.argo_domain // ""), (.argo_protocol // "")]
               | join("\u001f")' "$META_FILE" 2>/dev/null | tr -d '\r'
    )

    if [ -z "$uuid" ]; then
        _error "元数据缺失，无法生成节点链接。"
        return 1
    fi
    if [ -z "$argo_domain" ] || [ "${argo_port:-0}" = "0" ]; then
        _error "未找到 Argo 节点，请先执行 [1] 部署。"
        return 1
    fi

    local isp
    isp=$(_isp_tag)

    local lines=()
    lines+=("vless://${uuid}@${CF_ADDR_H2}:${CF_PORT}?encryption=none&security=tls&alpn=h2&sni=${argo_domain}&fp=chrome&type=xhttp&mode=auto&host=${argo_domain}&path=/${argo_path}#${isp}%20H2-Argo%20XHTTP")
    lines+=("vless://${uuid}@${CF_ADDR_H3}:${CF_PORT}?encryption=none&security=tls&alpn=h3&sni=${argo_domain}&fp=chrome&type=xhttp&mode=auto&host=${argo_domain}&path=/${argo_path}#${isp}%20H3-Argo%20XHTTP")

    printf '%s\n' "${lines[@]}" > "$LINKS_FILE" 2>/dev/null || true
    chmod 600 "$LINKS_FILE" 2>/dev/null || true

    local base64_str
    base64_str=$(printf '%s\n' "${lines[@]}" | base64 2>/dev/null | tr -d '\n\r')

    echo "" >&2
    echo -e "${GREEN}════════════════════ 节点链接 ════════════════════${NC}" >&2
    local l
    for l in "${lines[@]}"; do
        echo -e "${CYAN}${l}${NC}" >&2
    done
    echo "" >&2
    echo -e "${GREEN}════════════════════ 订阅内容 ════════════════════${NC}" >&2
    echo -e "${YELLOW}${base64_str}${NC}" >&2
    echo -e "${GREEN}══════════════════════════════════════════════════${NC}" >&2
    echo -e "链接已保存: ${LINKS_FILE}（含明文凭据，权限 600）" >&2
    echo -e "${YELLOW}提示${NC}: H3-Argo 走 UDP（快、抗 QoS）；网络封 UDP 时用 H2-Argo。" >&2
    echo "" >&2
    return 0
}


# 部署 / 重新部署 Argo 隧道（唯一部署入口）
_deploy_argo() {
    _check_root
    _detect_init_system

    # 老版本 meta 里可能还留着 Reality / H3：本版本只维护 Argo
    if [ -s "$META_FILE" ]; then
        local legacy
        legacy=$(jq -r '[(.reality_port // 0), (.h3_port // 0)] | map(select(. > 0)) | length' "$META_FILE" 2>/dev/null)
        if [ "${legacy:-0}" -gt 0 ]; then
            _warn "检测到旧的 Reality / H3 配置：本版本只维护 Argo 隧道，继续部署会移除这两个节点。"
            _ask_yes "  继续? (y/N): " n || { _info "已取消。"; return 0; }
        fi
    fi

    _install_dependencies || return 1
    _install_xray_core auto || return 1
    _install_cloudflared || return 1

    _argo_auto_setup || return 1

    _info "正在写入部署元数据..."
    local uuid="" tmp
    [ -s "$META_FILE" ] && uuid=$(jq -r '.uuid // ""' "$META_FILE" 2>/dev/null)
    [ -n "$uuid" ] || uuid=$(_gen_uuid)

    tmp=$(mktemp "${META_FILE}.tmp.XXXXXX") || return 1
    if ! jq -n \
        --arg uuid "$uuid" \
        --argjson port "$ARGO_PORT" \
        --arg path "${uuid}-argo" \
        --arg domain "$ARGO_DOMAIN" \
        --arg protocol "$ARGO_PROTOCOL" \
        --arg token "$ARGO_TOKEN" \
        --arg tid "$ARGO_TUNNEL_ID" \
        --arg zid "$ARGO_ZONE_ID" \
        --arg ip "$(_server_ip)" \
        --arg created_at "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{
            uuid: $uuid,
            argo_port: $port,
            argo_path: $path,
            argo_domain: $domain,
            argo_protocol: $protocol,
            argo_token: $token,
            argo_tunnel_id: $tid,
            argo_zone_id: $zid,
            server_ip: $ip,
            created_at: $created_at
        }' > "$tmp"; then
        rm -f "$tmp"
        _error "写入 meta.json 失败。"
        return 1
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$META_FILE" || { rm -f "$tmp"; return 1; }

    _info "正在生成 config.json..."
    _write_config || return 1
    _check_config || { _error "配置未通过校验，部署已中止。"; return 1; }

    _create_service_files
    _secure_permissions

    _info "正在启动 Xray 服务..."
    if ! _manage_service restart; then
        _error "Xray 启动失败，请查看日志: ${LOG_FILE}"
        return 1
    fi
    _success "Xray 服务已启动。"

    if ! _setup_argo "$ARGO_TOKEN" "$ARGO_PROTOCOL"; then
        _error "Argo 隧道启动失败，请检查: ${ARGO_LOG_FILE}"
        return 1
    fi
    _success "Argo 隧道已启动。"

    # 第二层保活：cron 每分钟巡检，进程退出或无边缘连接时自动重启
    _enable_argo_watchdog || _warn "保活未启用，隧道崩溃后需要手动 xg restart。"

    echo "" >&2
    echo -e "${GREEN}──────────── 部署完成 ────────────${NC}" >&2
    echo -e "  隧道域名 : ${ARGO_DOMAIN}" >&2
    echo -e "  隧道协议 : ${ARGO_PROTOCOL}" >&2
    echo -e "  本地端口 : 127.0.0.1:${ARGO_PORT}" >&2
    echo -e "  服务模式 : ${INIT_SYSTEM}" >&2

    _show_links
    return 0
}


_show_status() {
    local ver="未安装"
    [ -x "$XRAY_BIN" ] && ver=$("$XRAY_BIN" version 2>/dev/null | head -n1)

    echo "" >&2
    echo -e "${CYAN}  ───── 运行状态 ─────${NC}" >&2
    echo -e "  系统环境 : $(uname -s) $(uname -m)  |  服务模式: ${INIT_SYSTEM}" >&2
    echo -e "  脚本版本 : ${GREEN}$(_version_full)${NC}" >&2
    echo -e "  核心版本 : ${ver}" >&2

    if _service_is_running; then
        echo -e "  Xray     : ${GREEN}● 运行中${NC}" >&2
    else
        echo -e "  Xray     : ${RED}○ 已停止${NC}" >&2
    fi
    if [ -x "$CLOUDFLARED_BIN" ]; then
        if _argo_is_running; then
            echo -e "  Argo     : ${GREEN}● 运行中${NC}" >&2
        else
            echo -e "  Argo     : ${YELLOW}○ 已安装 (未运行)${NC}" >&2
            echo -e "             ${CYAN}xg restart${NC} 自动拉起，或 ${CYAN}xg diag${NC} 查原因" >&2
        fi
    else
        echo -e "  Argo     : ${RED}○ 未安装${NC}" >&2
    fi

    if [ -s "$META_FILE" ]; then
        local st at_cfg
        IFS=$'\x1f' read -r st at_cfg _ < <(_argo_transport 2>/dev/null)
        case "$st" in
            quic)     echo -e "  Argo 传输: ${GREEN}QUIC (UDP)${NC}" >&2 ;;
            http2)    echo -e "  Argo 传输: ${YELLOW}HTTP/2 (TCP)${NC}" >&2 ;;
            mixed)    echo -e "  Argo 传输: ${YELLOW}QUIC + HTTP/2 混合${NC}" >&2 ;;
            fallback) echo -e "  Argo 传输: ${RED}QUIC 已回退 HTTP/2${NC}" >&2 ;;
            *)
                # 连接计数和日志都没取到，退而用进程参数：只说明「被要求用什么」，
                # 不代表实际传输，所以标注清楚来源
                if [ -n "${at_cfg:-}" ]; then
                    echo -e "  Argo 传输: ${YELLOW}${at_cfg}${NC} （进程参数，未取到连接/日志）" >&2
                else
                    echo -e "  Argo 传输: ${YELLOW}未知${NC} （可执行 ${CYAN}xg diag${NC} 查看原因）" >&2
                fi
                ;;
        esac
        echo -e "  隧道     : $(jq -r 'if (.argo_port // 0) > 0 then ((.argo_domain // "-") + "  (" + (.argo_protocol // "http2") + " / 127.0.0.1:" + (.argo_port | tostring) + ")") else "未配置" end' "$META_FILE" 2>/dev/null)" >&2
        echo -e "  部署时间 : $(jq -r '.created_at // "-"' "$META_FILE" 2>/dev/null)" >&2
        if _watchdog_enabled; then
            echo -e "  自动保活 : ${GREEN}已开启${NC}（cron 每分钟巡检，崩溃自动拉起）" >&2
        elif [ -x "$KEEPALIVE_SCRIPT" ]; then
            echo -e "  自动保活 : ${YELLOW}脚本在但 cron 未挂${NC}（${CYAN}xg keepalive-on${NC}）" >&2
        else
            echo -e "  自动保活 : ${YELLOW}未开启${NC}（${CYAN}xg keepalive-on${NC} 开启）" >&2
        fi
    else
        echo -e "  隧道     : ${YELLOW}尚未部署${NC}" >&2
    fi
    echo "" >&2
}


# 由 meta.json 重建 config.json 并重启：端口 / 密钥 / 节点链接都不变
# 用于「改了脚本里的配置模板」这类修复（例如 Argo inbound 的 sockopt），不必重新部署
_rebuild_config() {
    _check_root
    _detect_init_system

    if [ ! -s "$META_FILE" ]; then
        _error "尚未部署，没有可重建的配置。"
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        _error "缺少 jq，无法由 meta.json 重建配置。"
        return 1
    fi

    # 老版本可能留着 Reality / H3，重建后这两个节点会消失，先问一句
    local legacy
    legacy=$(jq -r '[(.reality_port // 0), (.h3_port // 0)] | map(select(. > 0)) | length' "$META_FILE" 2>/dev/null)
    if [ "${legacy:-0}" -gt 0 ]; then
        _warn "meta.json 里还有旧的 Reality / H3 配置，重建后只剩 Argo 节点。"
        _ask_yes "  继续? (y/N): " n || { _info "已取消。"; return 0; }
    fi

    _info "正在由 meta.json 重建 config.json..."
    local bak=""
    if [ -s "$CONFIG_FILE" ]; then
        bak="${CONFIG_FILE}.bak.$$"
        cp -f "$CONFIG_FILE" "$bak" 2>/dev/null || bak=""
    fi

    if ! _write_config; then
        [ -n "$bak" ] && mv -f "$bak" "$CONFIG_FILE"
        _error "重建失败，已保留原配置。"
        return 1
    fi
    if ! _check_config; then
        if [ -n "$bak" ]; then
            mv -f "$bak" "$CONFIG_FILE"
            _warn "新配置未通过校验，已恢复原配置。"
        else
            _error "新配置未通过校验。"
        fi
        return 1
    fi
    [ -n "$bak" ] && rm -f "$bak"

    # 服务文件被 CF-A 之类占着时，这里顺手重写（否则下面重启只会拉起别人的服务）
    _ensure_service_owned || _warn "服务文件修复失败，请手动检查: ${SERVICE_FILE}"

    if _service_is_running; then
        _info "正在重启 Xray 服务..."
        if ! _manage_service restart; then
            _error "重启失败，请查看日志: ${LOG_FILE}"
            return 1
        fi
        _success "配置已重建并重启，端口与节点链接保持不变。"
    else
        _info "服务当前未运行，配置已更新，下次启动生效。"
    fi
    return 0
}


_main_menu() {
    while true; do
        echo "" >&2
        echo -e "${CYAN}  ══════════════════════════════════════════════${NC}" >&2
        echo -e "${CYAN}    Xray-go · Argo 隧道管理脚本    $(_version_tag)${NC}" >&2
        echo -e "${CYAN}  ══════════════════════════════════════════════${NC}" >&2
        _show_status
        echo -e "${CYAN}  ───── 菜单 ─────${NC}" >&2
        echo -e "    ${GREEN}[1]${NC} 部署 / 重新部署 Argo 隧道 (CF 邮箱 + API Key)" >&2
        echo -e "    ${GREEN}[2]${NC} 查看节点链接" >&2
        echo -e "    ${GREEN}[3]${NC} 删除 Argo 节点 (云端隧道 + DNS)" >&2
        echo -e "    ${GREEN}[4]${NC} 服务控制" >&2
        echo -e "    ${GREEN}[5]${NC} Xray 日志" >&2
        echo -e "    ${GREEN}[6]${NC} Argo 日志" >&2
        echo -e "    ${GREEN}[7]${NC} 诊断 (监听 / 传输 / 日志 / 结论)" >&2
        echo -e "    ${GREEN}[8]${NC} 重建配置 (改模板后免重装)" >&2
        echo -e "    ${GREEN}[9]${NC} 更新 Xray 核心" >&2
        echo -e "    ${GREEN}[10]${NC} 更新脚本" >&2
        echo -e "    ${RED}[11]${NC} 卸载部署 (云端隧道 + DNS + 本地文件)" >&2
        echo "" >&2
        echo -e "  ───────────────────────────────────────────" >&2
        echo -e "    ${YELLOW}[0]${NC} 退出" >&2
        echo "" >&2

        local choice=""
        read -r -p "  请输入选项 [0-11]: " choice || return 0
        case "$choice" in
            1) _deploy_argo ;;
            2) _show_links ;;
            3) _argo_delete_node ;;
            4) _service_menu ;;
            5) _view_log ;;
            6) _view_argo_log ;;
            7) _check_config; echo "" >&2; _diag ;;
            8) _rebuild_config ;;
            9) _update_core ;;
            10) _update_script && exit 0 ;;
            11) _uninstall_deploy
                [ "${XG_UNINSTALLED:-0}" = "1" ] && exit 0 ;;
            0) exit 0 ;;
            *) _error "无效输入，请重试。" ;;
        esac
        echo "" >&2
        read -n 1 -s -r -p "按任意键返回主菜单..." || return 0
    done
}


_print_help() {
    cat >&2 <<EOF
Xray-go · Argo 隧道版 V${SCRIPT_VERSION}  (构建 ${SCRIPT_BUILD})

用法: $(basename "$0") [快捷指令 | 命令]

  快捷指令：
    1              进入管理菜单（推荐）
    2              部署 / 重新部署 Argo 隧道
    3              查看节点链接
    4              查看运行状态
    5              卸载部署
    0              退出

  注：以上是命令行快捷指令，进入菜单后是另一套编号（见下方「菜单」）。

  完整命令：
    menu              进入管理菜单
    deploy | argo     部署 / 重新部署 Argo 隧道（CF 邮箱 + Global API Key）
    del-argo          删除 Argo 节点（含云端隧道 + DNS 解析）
    links             查看节点链接与 Base64 订阅
    status            查看运行状态
    start|stop|restart 控制 Xray 服务
    log               查看 Xray 实时日志
    argo-log          查看 Argo 实时日志
    keepalive         手动执行一次保活巡检（cron 也是调它）
    keepalive-on      开启 Argo 自动保活（cron 每分钟巡检，崩溃自动拉起）
    keepalive-off     关闭 Argo 自动保活
    rebuild           由 meta.json 重建配置并重启（端口/链接不变）
    check             校验配置文件
    diag              连通性自检（本地监听 / Argo 走 UDP 还是 TCP / 日志 / 结论）
    update-core       更新 Xray 核心
    update-script     更新本脚本（同版本自动跳过，加 force 强制覆盖）
    -v | --version    查看当前脚本版本号
    uninstall         卸载部署（含云端隧道 + DNS + 本地文件）

  菜单：
    [1] 部署   [2] 链接   [3] 删节点   [4] 服务   [5] Xray 日志   [6] Argo 日志
    [7] 诊断   [8] 重建配置   [9] 更新核心   [10] 更新脚本   [11] 卸载

环境变量（部署时可选，免去交互）:
  ARGO_DOMAIN / ARGO_PROTOCOL(1=quic 2=http2) / ARGO_PORT
  CF_EMAIL / CF_API_KEY
EOF
}


main() {
    local cmd="${1:-menu}"

    case "$cmd" in
        help | -h | --help)
            _print_help
            return 0
            ;;
        -v | --version)
            echo "Xray-go $(_version_full)"
            return 0
            ;;
    esac

    _check_root
    _detect_init_system

    case "$cmd" in
        # ---- 快捷指令 1-5 ----
        1)
            _install_dependencies || _warn "依赖安装未完全成功，部分功能可能不可用。"
            _main_menu
            ;;
        2)
            _install_dependencies || exit 1
            _deploy_argo
            ;;
        3)
            _install_dependencies >/dev/null 2>&1
            _show_links
            ;;
        4)
            _install_dependencies >/dev/null 2>&1
            _show_status
            ;;
        5)
            _uninstall_deploy
            exit 0
            ;;
        0 | q | quit | exit)
            exit 0
            ;;
        # ---- 完整命令 ----
        deploy | install | onekey | argo | argo-setup)
            _install_dependencies || exit 1
            _deploy_argo
            ;;
        del-argo | rm-argo | delete-argo | del-node)
            _argo_delete_node
            ;;
        links | show)
            _install_dependencies >/dev/null 2>&1
            _show_links
            ;;
        status)
            _install_dependencies >/dev/null 2>&1
            _show_status
            ;;
        start | stop | restart)
            _install_dependencies >/dev/null 2>&1
            _manage_service "$cmd"
            if [ "$cmd" != "stop" ]; then
                _ensure_argo_running
            fi
            ;;
        log)
            _view_log
            ;;
        argo-log)
            _view_argo_log
            ;;
        keepalive | watchdog)
            # 手动跑一次巡检（cron 也是调这个脚本，行为完全一致）
            if [ -x "$KEEPALIVE_SCRIPT" ]; then
                /bin/sh "$KEEPALIVE_SCRIPT"
                _success "已执行一次保活巡检。"
            else
                _error "保活脚本不存在，先执行: xg keepalive-on"
                return 1
            fi
            ;;
        keepalive-on | watchdog-on)
            _enable_argo_watchdog || return 1
            ;;
        keepalive-off | watchdog-off)
            _disable_argo_watchdog
            _success "Argo 保活已关闭。"
            ;;
        check)
            _install_dependencies >/dev/null 2>&1
            _check_config
            ;;
        rebuild | rebuild-config)
            _install_dependencies >/dev/null 2>&1
            _rebuild_config
            ;;
        diag | diagnose)
            _install_dependencies >/dev/null 2>&1
            _diag
            ;;
        update-core)
            _update_core
            ;;
        update-script)
            _update_script "${2:-}"
            ;;
        uninstall)
            _uninstall_deploy
            exit 0
            ;;
        menu)
            _install_dependencies || _warn "依赖安装未完全成功，部分功能可能不可用。"
            _main_menu
            ;;
        # 已移除的功能：给个明确说法，而不是 "未知命令"
        reality | h3 | custom | reality-only | h3-only)
            _error "V2.0 起只保留 Argo 隧道方案，Reality / H3 直连已移除。"
            _info "部署 Argo：xg deploy（或菜单 [1]）"
            return 1
            ;;
        *)
            _error "未知命令: ${cmd}"
            _print_help
            return 1
            ;;
    esac
}

main "$@"
