#!/bin/bash
# ==============================================================================
#  Xray-go 一键部署管理脚本
#  协议组合: VLESS-TCP-REALITY-Vision / XHTTP-H3(UDP 直连) / XHTTP-Argo 双模隧道
#  部署流程参考 singbox-lite：依赖安装 -> 核心安装 -> 配置初始化
#  -> 服务托管(systemd / openrc / direct) -> 菜单化管理
#  支持一键部署（免交互）与自定义部署（交互式）
# ==============================================================================

export LANG=en_US.UTF-8
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

# 配置、元数据、私钥仅 root 可读写
umask 077

# 版本号：更新脚本后对比此值即可确认是否更新成功（xg -v / 菜单标题 / 状态页均显示）
export SCRIPT_VERSION="1.0"
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
CERT_FILE="${XRAY_DIR}/cert.pem"
KEY_FILE="${XRAY_DIR}/private.key"
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
ARGO_PROTOCOL="${ARGO_PROTOCOL:-http2}"
ARGO_TUNNEL_ID="${ARGO_TUNNEL_ID:-}"
ARGO_ZONE_ID="${ARGO_ZONE_ID:-}"
DEP_STATE_VERSION="20261106-1"
LOG_FILE="/var/log/xray.log"
ARGO_LOG_FILE="/var/log/xray-argo.log"
RUNTIME_DIR="/run/xraygo"
PID_FILE="${RUNTIME_DIR}/xray.pid"
ARGO_PID_FILE="${RUNTIME_DIR}/cloudflared.pid"
DEFAULT_REALITY_SNI="www.apple.com"
H3_SNI="bing.com"
CF_ADDR_H2="www.visa.com.hk"
CF_ADDR_H3="www.teamviewer.com"
CF_PORT="443"

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

# 统一版本标签：V1.0
_version_tag() { printf 'V%s' "${SCRIPT_VERSION}"; }
# 完整版本串：V1.0 (2026-11-06)
_version_full() { printf 'V%s (%s)' "${SCRIPT_VERSION}" "${SCRIPT_BUILD}"; }

# ==============================================================================
#  基础工具
# ==============================================================================

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

_secure_permissions() {
    [ -d "$XRAY_DIR" ] && chmod 700 "$XRAY_DIR" 2>/dev/null || true
    [ -d "$RUNTIME_DIR" ] && chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
    local f
    for f in "$CONFIG_FILE" "$META_FILE" "$LINKS_FILE" "$KEY_FILE" "$ARGO_ENV_FILE" \
             "$CERT_FILE" "$DEP_STATE_FILE" "$CF_CRED_FILE" "$SERVICE_FILE" "$ARGO_SERVICE_FILE"; do
        [ -f "$f" ] && chmod 600 "$f" 2>/dev/null || true
    done
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

_rand_port() {
    local lo=20000 hi=60000 p=""
    if command -v shuf >/dev/null 2>&1; then
        p=$(shuf -i ${lo}-${hi} -n 1 2>/dev/null)
    fi
    [[ "$p" =~ ^[0-9]+$ ]] || p=$(( (RANDOM * 32768 + RANDOM) % (hi - lo + 1) + lo ))
    printf '%s' "$p"
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

_num_or_zero() {
    [[ "$1" =~ ^[0-9]+$ ]] && printf '%s' "$1" || printf '0'
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

# ==============================================================================
#  下载（官方优先，失败后走 Cloudflare 代理）
# ==============================================================================

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

# ==============================================================================
#  核心安装
# ==============================================================================

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

# ==============================================================================
#  证书 / 密钥 / 配置
# ==============================================================================

_gen_certificate() {
    _info "正在生成 H3 自签证书..."
    if ! openssl ecparam -genkey -name prime256v1 -out "$KEY_FILE" 2>/dev/null; then
        _error "生成私钥失败（缺少 openssl）。"
        return 1
    fi
    if ! openssl req -new -x509 -days 3650 -key "$KEY_FILE" -out "$CERT_FILE" \
        -subj "/CN=${H3_SNI}" 2>/dev/null; then
        _error "生成自签证书失败。"
        return 1
    fi
    chmod 600 "$KEY_FILE" "$CERT_FILE" 2>/dev/null || true
    return 0
}

_gen_reality_keypair() {
    local out pk pub
    out=$("$XRAY_BIN" x25519 2>/dev/null)
    pk=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*PrivateKey:[[:space:]]*//p' | head -n1)
    pub=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*Password:[[:space:]]*//p' | head -n1)
    if [ -z "$pk" ] || [ -z "$pub" ]; then
        pk=$(printf '%s\n' "$out" | awk -F': *' '/Private/ {print $2; exit}')
        pub=$(printf '%s\n' "$out" | awk -F': *' '/Public|Password/ {print $2; exit}')
    fi
    [ -n "$pk" ] && [ -n "$pub" ] || return 1
    printf '%s %s\n' "$pk" "$pub"
}

# 由 meta.json 生成 config.json（单一数据源，可随时重建）
_build_config_from_meta() {
    jq --arg cert "$CERT_FILE" --arg key "$KEY_FILE" --arg logfile "$LOG_FILE" '
        . as $m
        | ([
            (if (($m.reality_port // 0) > 0) then {
                tag: "tcp-reality",
                listen: "::",
                port: ($m.reality_port | tonumber),
                protocol: "vless",
                settings: {
                    clients: [{id: $m.uuid, flow: "xtls-rprx-vision"}],
                    decryption: "none"
                },
                streamSettings: {
                    network: "tcp",
                    security: "reality",
                    realitySettings: {
                        fingerprint: "chrome",
                        target: (($m.reality_sni // "www.apple.com") + ":443"),
                        serverNames: [($m.reality_sni // "www.apple.com")],
                        privateKey: $m.reality_private_key,
                        shortIds: [$m.reality_short_id]
                    }
                },
                sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], metadataOnly: false}
            } else empty end),
            (if (($m.h3_port // 0) > 0) then {
                tag: "xhttp-h3",
                listen: "::",
                port: ($m.h3_port | tonumber),
                protocol: "vless",
                settings: {
                    clients: [{id: $m.uuid, flow: ""}],
                    decryption: "none"
                },
                streamSettings: {
                    network: "xhttp",
                    security: "tls",
                    xhttpSettings: {mode: "auto", path: ("/" + ($m.h3_path // "h3"))},
                    tlsSettings: {
                        alpn: ["h3"],
                        certificates: [{certificateFile: $cert, keyFile: $key}]
                    }
                },
                sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], metadataOnly: false}
            } else empty end),
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
                    xhttpSettings: {path: ("/" + ($m.argo_path // "argo")), mode: "auto"}
                },
                sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], metadataOnly: false}
            } else empty end)
        ]) as $inbounds
        | {
            log: {loglevel: "warning", error: $logfile},
            inbounds: $inbounds,
            outbounds: [{tag: "direct", protocol: "freedom"}]
        }
    ' "$META_FILE"
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

# ==============================================================================
#  服务托管
# ==============================================================================

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

_create_service_files() {
    mkdir -p "$RUNTIME_DIR" 2>/dev/null
    chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || true

    case "$INIT_SYSTEM" in
        systemd)
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
                [ -f "$SERVICE_FILE" ] || _create_service_files
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
                [ -f "$SERVICE_FILE" ] || _create_service_files
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

# ==============================================================================
#  Argo 隧道
# ==============================================================================

_argo_connections() {
    local proto="${1,,}"
    if [ "$proto" = "http2" ]; then echo "4"; else echo "1"; fi
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

# ==============================================================================
#  Cloudflare API：邮箱 + Global API Key 自动搭建 Argo 固定隧道
#  自动完成：创建命名隧道 -> 写入 ingress -> 创建 DNS CNAME(proxied) -> 取回 Token
#  卸载时自动删除云端隧道与 DNS 记录
# ==============================================================================

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

# 统一 CF API 调用；成功时把原始 JSON 输出到 stdout
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

# 域名 -> "zone_id account_id"（取最长后缀匹配的 Zone）
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

# 按名称查找未删除的同名隧道 -> tunnel_id（找不到返回空）
_cf_find_tunnel_by_name() {
    local name="$1"
    _cf_call GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=${name}&is_deleted=false&per_page=50" 2>/dev/null \
        | jq -r --arg n "$name" '
            [.result[]? | select(.name == $n and (.deleted_at // null) == null)][0].id // ""
        ' 2>/dev/null
}

# 创建命名隧道 -> "tunnel_id token"（同名隧道已存在则复用，避免重复部署堆积）
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

# 自动搭建主流程：成功时写入 ARGO_* 全局变量
_argo_auto_setup() {
    ARGO_TOKEN=""
    ARGO_DOMAIN=""
    ARGO_PORT="8001"
    ARGO_PROTOCOL="http2"
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

    read -r -p "  隧道协议 [http2/quic]（回车 http2）: " proto || proto=""
    case "${proto,,}" in
        quic) proto="quic" ;;
        *) proto="http2" ;;
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

# 清理云端资源（卸载时调用）
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

# ==============================================================================
#  防火墙
# ==============================================================================

_apply_firewall() {
    local p
    for p in "$@"; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw allow "$p"/tcp >/dev/null 2>&1 || true
            ufw allow "$p"/udp >/dev/null 2>&1 || true
        fi
        if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --permanent --add-port="${p}/udp" >/dev/null 2>&1 || true
        fi
        if command -v iptables >/dev/null 2>&1; then
            iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
                || iptables -A INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
            iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null \
                || iptables -A INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
        fi
    done
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    return 0
}

# ==============================================================================
#  节点链接
# ==============================================================================

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

_show_links() {
    [ -s "$META_FILE" ] || { _error "尚未部署，请先执行一键部署。"; return 1; }

    local uuid reality_port reality_sni reality_pub reality_sid h3_port h3_path \
          argo_port argo_path argo_domain argo_protocol saved_ip
    # 用 \x1f(US) 分隔：制表符属于空白字符，连续出现会被 read 合并，导致空字段错位
    IFS=$'\x1f' read -r uuid reality_port reality_sni reality_pub reality_sid h3_port h3_path \
        argo_port argo_path argo_domain argo_protocol saved_ip < <(
        jq -r '[.uuid // "",
                ((.reality_port // 0) | tostring), (.reality_sni // ""), (.reality_public_key // ""), (.reality_short_id // ""),
                ((.h3_port // 0) | tostring), (.h3_path // ""),
                ((.argo_port // 0) | tostring), (.argo_path // ""), (.argo_domain // ""), (.argo_protocol // ""),
                (.server_ip // "")]
               | join("\u001f")' "$META_FILE" 2>/dev/null
    )

    if [ -z "$uuid" ]; then
        _error "元数据缺失，无法生成节点链接。"
        return 1
    fi

    local ip isp host
    ip=$(_server_ip)
    [ -n "$ip" ] || ip="$saved_ip"
    if [ -z "$ip" ]; then
        _error "无法获取服务器 IP，请检查网络。"
        return 1
    fi
    if [[ "$ip" == *:* ]]; then host="[${ip}]"; else host="$ip"; fi
    isp=$(_isp_tag)

    local lines=()
    if [ "${reality_port:-0}" != "0" ] && [ -n "$reality_port" ]; then
        lines+=("vless://${uuid}@${host}:${reality_port}?encryption=none&security=reality&sni=${reality_sni}&fp=chrome&pbk=${reality_pub}&sid=${reality_sid}&type=tcp&flow=xtls-rprx-vision#${isp}%20Reality%20Vision%20ESS")
    fi
    if [ "${h3_port:-0}" != "0" ] && [ -n "$h3_port" ]; then
        lines+=("vless://${uuid}@${host}:${h3_port}?encryption=none&security=tls&sni=${H3_SNI}&alpn=h3&fp=chrome&type=xhttp&mode=auto&path=/${h3_path}&allowInsecure=1#${isp}%20H3-XHTTP%20ESS")
    fi
    if [ -n "$argo_domain" ] && [ "${argo_port:-0}" != "0" ] && [ -n "$argo_port" ]; then
        lines+=("vless://${uuid}@${CF_ADDR_H2}:${CF_PORT}?encryption=none&security=tls&alpn=h2&sni=${argo_domain}&fp=chrome&type=xhttp&mode=auto&host=${argo_domain}&path=/${argo_path}#${isp}%20H2-Argo%20XHTTP%20ESS")
        lines+=("vless://${uuid}@${CF_ADDR_H3}:${CF_PORT}?encryption=none&security=tls&alpn=h3&sni=${argo_domain}&fp=chrome&type=xhttp&mode=auto&host=${argo_domain}&path=/${argo_path}#${isp}%20H3-Argo%20XHTTP%20ESS")
    fi

    if [ "${#lines[@]}" -eq 0 ]; then
        _error "未找到任何已启用的协议。"
        return 1
    fi

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
    echo -e "${GREEN}════════════════════ 订阅内容 ════════════════════${NC}" >&2
    echo -e "${YELLOW}${base64_str}${NC}" >&2
    echo -e "${GREEN}══════════════════════════════════════════════════${NC}" >&2
    echo -e "链接已保存: ${LINKS_FILE}（含明文凭据，权限 600）" >&2
    echo "" >&2
    return 0
}

# ==============================================================================
#  部署
# ==============================================================================

_deploy_all() {
    local reality_port="$1" h3_port="$2" argo_protocol="$3" argo_port="$4" argo_domain="$5" argo_token="$6"
    local argo_tunnel_id="${7:-}" argo_zone_id="${8:-}"

    _check_root
    _detect_init_system

    reality_port=$(_num_or_zero "$reality_port")
    h3_port=$(_num_or_zero "$h3_port")
    argo_port=$(_num_or_zero "$argo_port")

    if [ "$reality_port" = "0" ] && [ "$h3_port" = "0" ] && [ -z "$argo_token" ]; then
        _error "未选择任何协议（Reality / H3 / Argo 均为空），已取消部署。"
        return 1
    fi
    if [ -n "$argo_token" ] && { [ "$argo_port" = "0" ] || [ -z "$argo_domain" ]; }; then
        _error "Argo 隧道需要同时提供「本地端口 + 隧道域名 + Token」，已取消部署。"
        return 1
    fi
    [ -n "$argo_protocol" ] || argo_protocol="http2"

    _info "=== 开始部署 Xray-go ==="
    _stop_all_services

    local p
    for p in "$reality_port" "$h3_port"; do
        [ "$p" = "0" ] && continue
        if _port_in_use "$p"; then
            _error "端口 ${p} 已被占用，请更换端口后重试。"
            return 1
        fi
    done

    _install_dependencies || return 1
    _install_xray_core auto || return 1
    if [ -n "$argo_token" ]; then
        _install_cloudflared || return 1
    fi

    mkdir -p "$XRAY_DIR" "$RUNTIME_DIR" || { _error "创建目录失败"; return 1; }
    chmod 700 "$XRAY_DIR" "$RUNTIME_DIR" 2>/dev/null || true

    local uuid=""
    [ -s "$META_FILE" ] && uuid=$(jq -r '.uuid // ""' "$META_FILE" 2>/dev/null)
    [ -n "$uuid" ] || uuid=$(_gen_uuid)

    _gen_certificate || return 1

    local keypair private_key public_key short_id
    _info "正在生成 Reality 密钥对..."
    keypair=$(_gen_reality_keypair) || { _error "生成 Reality 密钥对失败。"; return 1; }
    private_key="${keypair%% *}"
    public_key="${keypair##* }"
    short_id=$(openssl rand -hex 4)

    local h3_path="${uuid}-xu"
    local argo_path="${uuid}-argo"
    local server_ip
    server_ip=$(_server_ip)

    _info "正在写入部署元数据..."
    local meta_tmp
    meta_tmp=$(mktemp "${META_FILE}.tmp.XXXXXX") || return 1
    if ! jq -n \
        --arg uuid "$uuid" \
        --argjson reality_port "$reality_port" \
        --arg reality_sni "$DEFAULT_REALITY_SNI" \
        --arg reality_private_key "$private_key" \
        --arg reality_public_key "$public_key" \
        --arg reality_short_id "$short_id" \
        --argjson h3_port "$h3_port" \
        --arg h3_path "$h3_path" \
        --argjson argo_port "$argo_port" \
        --arg argo_path "$argo_path" \
        --arg argo_domain "$argo_domain" \
        --arg argo_protocol "$argo_protocol" \
        --arg argo_token "$argo_token" \
        --arg argo_tunnel_id "$argo_tunnel_id" \
        --arg argo_zone_id "$argo_zone_id" \
        --arg server_ip "$server_ip" \
        --arg created_at "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{
            uuid: $uuid,
            reality_port: $reality_port,
            reality_sni: $reality_sni,
            reality_private_key: $reality_private_key,
            reality_public_key: $reality_public_key,
            reality_short_id: $reality_short_id,
            h3_port: $h3_port,
            h3_path: $h3_path,
            argo_port: $argo_port,
            argo_path: $argo_path,
            argo_domain: $argo_domain,
            argo_protocol: $argo_protocol,
            argo_token: $argo_token,
            argo_tunnel_id: $argo_tunnel_id,
            argo_zone_id: $argo_zone_id,
            server_ip: $server_ip,
            created_at: $created_at
        }' > "$meta_tmp"; then
        rm -f "$meta_tmp"
        _error "写入 meta.json 失败。"
        return 1
    fi
    chmod 600 "$meta_tmp" 2>/dev/null || true
    mv -f "$meta_tmp" "$META_FILE" || { rm -f "$meta_tmp"; return 1; }

    _info "正在生成 config.json..."
    _write_config || return 1
    _check_config || {
        _error "配置未通过校验，部署已中止。"
        return 1
    }

    _create_service_files
    _secure_permissions

    _info "正在启动 Xray 服务..."
    if ! _manage_service restart; then
        _error "Xray 启动失败，请查看日志: journalctl -u xray -n 50 或 ${LOG_FILE}"
        return 1
    fi
    _success "Xray 服务已启动。"

    if [ -n "$argo_token" ]; then
        if _setup_argo "$argo_token" "$argo_protocol"; then
            _success "Argo 隧道已启动。"
        else
            _warn "Argo 隧道启动失败，其余协议不受影响。"
        fi
    fi

    _apply_firewall "$reality_port" "$h3_port"

    echo "" >&2
    echo -e "${GREEN}──────────── 部署完成 ────────────${NC}" >&2
    echo -e "  Reality 端口 : ${reality_port}" >&2
    echo -e "  H3 端口      : ${h3_port}" >&2
    echo -e "  Argo 端口    : ${argo_port}  (${argo_protocol})" >&2
    echo -e "  服务模式     : ${INIT_SYSTEM}" >&2

    _show_links
    return 0
}

_one_click_deploy() {
    _check_root
    _detect_init_system

    if [ -s "$META_FILE" ]; then
        _warn "检测到已存在的部署（重新部署会生成新端口与凭据）。"
        if [ -t 0 ]; then
            if ! _ask_yes "是否重新部署? (y/N): " n; then
                _info "已取消，直接展示现有节点链接。"
                _show_links
                return $?
            fi
        else
            _info "非交互环境：保留现有部署，直接输出节点链接。"
            _show_links
            return $?
        fi
    fi

    local reality_port h3_port
    reality_port=$(_pick_free_port)
    h3_port=$(_pick_free_port)
    while [ "$h3_port" = "$reality_port" ]; do
        h3_port=$(_pick_free_port)
    done

    # 已存在的 Argo 配置在重部署时沿用，避免掉线
    local argo_token="" argo_domain="" argo_protocol="http2" argo_port="0"
    local argo_tunnel_id="" argo_zone_id=""
    if [ -s "$META_FILE" ]; then
        argo_token=$(jq -r '.argo_token // ""' "$META_FILE" 2>/dev/null)
        argo_domain=$(jq -r '.argo_domain // ""' "$META_FILE" 2>/dev/null)
        argo_protocol=$(jq -r '.argo_protocol // "http2"' "$META_FILE" 2>/dev/null)
        argo_port=$(jq -r '.argo_port // 0' "$META_FILE" 2>/dev/null)
        argo_tunnel_id=$(jq -r '.argo_tunnel_id // ""' "$META_FILE" 2>/dev/null)
        argo_zone_id=$(jq -r '.argo_zone_id // ""' "$META_FILE" 2>/dev/null)
    fi
    [ -n "${ARGO_TOKEN:-}" ] && argo_token="$ARGO_TOKEN"
    [ -n "${ARGO_DOMAIN:-}" ] && argo_domain="$ARGO_DOMAIN"
    [ -n "${ARGO_PROTOCOL:-}" ] && argo_protocol="$ARGO_PROTOCOL"
    [ -n "${ARGO_PORT:-}" ] && argo_port="$ARGO_PORT"

    # 无 Argo 配置时，交互询问是否用 CF 凭据自动搭建
    if [ -z "$argo_token" ] && [ -t 0 ]; then
        echo "" >&2
        if _ask_yes "  是否顺带自动搭建 Argo 隧道（用 Cloudflare 邮箱 + API Key）? (y/N): " n; then
            if _argo_auto_setup; then
                argo_token="$ARGO_TOKEN"
                argo_domain="$ARGO_DOMAIN"
                argo_protocol="$ARGO_PROTOCOL"
                argo_port="$ARGO_PORT"
                argo_tunnel_id="$ARGO_TUNNEL_ID"
                argo_zone_id="$ARGO_ZONE_ID"
            else
                _warn "Argo 自动搭建未完成，本次只部署 Reality + H3。"
                argo_token=""
                argo_domain=""
                argo_port="0"
            fi
        fi
    fi

    echo "" >&2
    echo -e "${CYAN}  一键部署预览${NC}" >&2
    echo -e "    VLESS-TCP-REALITY-Vision : 端口 ${GREEN}${reality_port}${NC}" >&2
    echo -e "    VLESS-XHTTP-H3 (UDP)     : 端口 ${GREEN}${h3_port}${NC}" >&2
    if [ -n "$argo_token" ]; then
        echo -e "    XHTTP-Argo 隧道          : ${argo_protocol} / ${argo_domain}" >&2
    else
        echo -e "    XHTTP-Argo 隧道          : ${YELLOW}未启用${NC}" >&2
    fi
    echo "" >&2

    _deploy_all "$reality_port" "$h3_port" "$argo_protocol" "$argo_port" \
        "$argo_domain" "$argo_token" "$argo_tunnel_id" "$argo_zone_id"
}

_custom_deploy() {
    _check_root
    _detect_init_system

    echo "" >&2
    echo -e "${CYAN}  === 自定义部署 ===${NC}" >&2

    local reality_port="0" h3_port="0" input=""

    if _ask_yes "  是否部署 VLESS-TCP-REALITY-Vision? (Y/n): " y; then
        read -r -p "  Reality 端口 (回车随机): " input || input=""
        if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le 65535 ]; then
            reality_port="$input"
        else
            reality_port=$(_pick_free_port)
            _info "已分配 Reality 随机端口: ${reality_port}"
        fi
    fi

    input=""
    if _ask_yes "  是否部署 XHTTP-H3 直连 (UDP)? (Y/n): " y; then
        read -r -p "  H3 端口 (回车随机): " input || input=""
        if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le 65535 ]; then
            h3_port="$input"
        else
            h3_port=$(_pick_free_port)
            _info "已分配 H3 随机端口: ${h3_port}"
        fi
    fi

    local argo_token="" argo_domain="" argo_protocol="http2" argo_port="0"
    local argo_tunnel_id="" argo_zone_id=""
    if _ask_yes "  是否部署 XHTTP-Argo 隧道? (y/N): " n; then
        echo "" >&2
        echo -e "    ${GREEN}[1]${NC} 自动搭建（Cloudflare 邮箱 + Global API Key，推荐）" >&2
        echo -e "    ${GREEN}[2]${NC} 手动填写（已有 Tunnel Token + 域名）" >&2
        read -r -p "  请选择 [1/2] (回车 1): " input || input=""
        case "$input" in
            2)
                read -r -p "  Argo 本地端口 (回车 8001): " input || input=""
                if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le 65535 ]; then
                    argo_port="$input"
                else
                    argo_port="8001"
                fi

                read -r -p "  Argo 隧道协议 [http2/quic] (回车 http2): " input || input=""
                case "${input,,}" in
                    quic) argo_protocol="quic" ;;
                    *) argo_protocol="http2" ;;
                esac

                read -r -p "  Cloudflare Tunnel 完整域名 (如 a.example.com): " argo_domain || argo_domain=""
                argo_domain=$(printf '%s' "$argo_domain" | tr -d '[:space:]')

                read -r -p "  Cloudflare Tunnel Token: " argo_token || argo_token=""
                argo_token=$(printf '%s' "$argo_token" | tr -d '[:space:]')

                if [ -z "$argo_domain" ] || [ -z "$argo_token" ]; then
                    _warn "域名或 Token 为空，已跳过 Argo 部署。"
                    argo_token=""
                    argo_domain=""
                    argo_port="0"
                fi
                ;;
            *)
                if _argo_auto_setup; then
                    argo_token="$ARGO_TOKEN"
                    argo_domain="$ARGO_DOMAIN"
                    argo_protocol="$ARGO_PROTOCOL"
                    argo_port="$ARGO_PORT"
                    argo_tunnel_id="$ARGO_TUNNEL_ID"
                    argo_zone_id="$ARGO_ZONE_ID"
                else
                    _warn "Argo 自动搭建未完成，已跳过。"
                    argo_token=""
                    argo_domain=""
                    argo_port="0"
                fi
                ;;
        esac
    fi

    if [ "$reality_port" = "0" ] && [ "$h3_port" = "0" ] && [ -z "$argo_token" ]; then
        _error "未选择任何协议，已取消。"
        return 1
    fi

    _deploy_all "$reality_port" "$h3_port" "$argo_protocol" "$argo_port" \
        "$argo_domain" "$argo_token" "$argo_tunnel_id" "$argo_zone_id"
}

# 已部署 Reality/H3 后，单独补充/重建 Argo 隧道（自动建隧道 + DNS）
_add_argo_only() {
    _check_root
    _detect_init_system

    if [ ! -s "$META_FILE" ]; then
        _error "尚未部署基础协议，请先执行 [1] 一键部署。"
        return 1
    fi

    _install_dependencies || return 1
    _install_xray_core auto || return 1
    _install_cloudflared || return 1

    _argo_auto_setup || return 1

    local tmp
    tmp=$(mktemp "${META_FILE}.tmp.XXXXXX") || return 1
    if ! jq --arg t "$ARGO_TOKEN" --arg d "$ARGO_DOMAIN" --arg p "$ARGO_PROTOCOL" \
        --argjson port "$ARGO_PORT" --arg tid "$ARGO_TUNNEL_ID" --arg zid "$ARGO_ZONE_ID" '
        .argo_token = $t
        | .argo_domain = $d
        | .argo_protocol = $p
        | .argo_port = $port
        | .argo_tunnel_id = $tid
        | .argo_zone_id = $zid
        | .argo_path = (if (.argo_path // "") == "" then ((.uuid // "argo") + "-argo") else .argo_path end)
    ' "$META_FILE" > "$tmp"; then
        rm -f "$tmp"
        _error "更新 meta.json 失败。"
        return 1
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$META_FILE" || { rm -f "$tmp"; return 1; }

    _write_config || return 1
    _check_config || return 1
    _manage_service restart || return 1
    if ! _setup_argo "$ARGO_TOKEN" "$ARGO_PROTOCOL"; then
        _error "Argo 隧道启动失败，请检查 cloudflared 日志。"
        return 1
    fi

    _success "Argo 隧道已就绪: ${ARGO_DOMAIN}"
    _show_links
    return 0
}

# 删除 Argo 节点：停服务 -> 删云端隧道与 DNS -> 清 meta/本地文件 -> 重建配置并重启
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

    # 4. 重建配置并重启（若已无其他协议则跳过）
    remain=$(jq -r '[(.reality_port // 0), (.h3_port // 0)] | map(select(. > 0)) | length' "$META_FILE" 2>/dev/null)
    if [ "${remain:-0}" -gt 0 ]; then
        _write_config || return 1
        _check_config || return 1
        _manage_service restart || _warn "Xray 重启失败，请手动检查。"
    else
        _warn "已无其他协议在运行，建议直接执行 [卸载部署]。"
    fi

    _success "Argo 节点已删除：云端隧道、DNS 解析、本地配置均已清理。"
    if [ "${remain:-0}" -gt 0 ]; then
        _show_links
    fi
    return 0
}

# ==============================================================================
#  维护
# ==============================================================================

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
        local argo_run=false
        case "$INIT_SYSTEM" in
            systemd) systemctl is-active --quiet xray-argo 2>/dev/null && argo_run=true ;;
            openrc) rc-service xray-argo status 2>/dev/null | grep -q started && argo_run=true ;;
            direct) _is_pid_file_running_cmd "$ARGO_PID_FILE" "$CLOUDFLARED_BIN" && argo_run=true ;;
        esac
        if [ "$argo_run" = true ]; then
            echo -e "  Argo     : ${GREEN}● 运行中${NC}" >&2
        else
            echo -e "  Argo     : ${YELLOW}○ 已安装 (未运行)${NC}" >&2
        fi
    else
        echo -e "  Argo     : ${RED}○ 未安装${NC}" >&2
    fi

    if [ -s "$META_FILE" ]; then
        echo -e "  端口     : $(jq -r '[
            (if (.reality_port // 0) > 0 then "Reality=\(.reality_port)" else empty end),
            (if (.h3_port // 0) > 0 then "H3=\(.h3_port)" else empty end),
            (if (.argo_port // 0) > 0 and (.argo_token // "") != "" then "Argo=\(.argo_port)" else empty end)
        ] | join("  ")' "$META_FILE" 2>/dev/null)" >&2
        echo -e "  部署时间 : $(jq -r '.created_at // "-"' "$META_FILE" 2>/dev/null)" >&2
    else
        echo -e "  端口     : ${YELLOW}尚未部署${NC}" >&2
    fi
    echo "" >&2
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

_uninstall_deploy() {
    _check_root
    _detect_init_system

    local cloud_tid="" cloud_zid="" cloud_domain="" cloud_token=""
    if [ -s "$META_FILE" ]; then
        cloud_tid=$(jq -r '.argo_tunnel_id // ""' "$META_FILE" 2>/dev/null)
        cloud_zid=$(jq -r '.argo_zone_id // ""' "$META_FILE" 2>/dev/null)
        cloud_domain=$(jq -r '.argo_domain // ""' "$META_FILE" 2>/dev/null)
        cloud_token=$(jq -r '.argo_token // ""' "$META_FILE" 2>/dev/null)
    fi

    echo "" >&2
    echo -e "${RED}  即将删除以下内容：${NC}" >&2
    echo -e "    - Xray 服务与 Argo 隧道服务" >&2
    echo -e "    - 配置目录: ${XRAY_DIR}（含配置、证书、密钥、cloudflared、CF 凭据）" >&2
    echo -e "    - 日志: ${LOG_FILE} / ${ARGO_LOG_FILE}" >&2
    echo -e "    - 运行目录: ${RUNTIME_DIR}" >&2
    if [ -n "$cloud_tid" ]; then
        echo -e "    - ${YELLOW}Cloudflare 云端隧道 ${cloud_tid}${NC}" >&2
        [ -n "$cloud_domain" ] && echo -e "    - ${YELLOW}DNS 解析记录 ${cloud_domain}${NC}" >&2
    elif [ -n "$cloud_token" ]; then
        echo -e "    - ${YELLOW}注意：该 Argo 为手动 Token 部署，云端隧道需手动删除${NC}" >&2
    fi
    echo "" >&2

    if ! _ask_yes "  确认卸载 Xray-go? (y/N): " n; then
        _info "已取消卸载。"
        return 0
    fi

    _info "正在停止服务..."
    _stop_all_services

    # 先清理云端（需要在删除凭据文件之前完成）
    if [ -n "$cloud_tid" ]; then
        _argo_auto_cleanup "$cloud_tid" "$cloud_zid" "$cloud_domain"
    elif [ -n "$cloud_token" ]; then
        _warn "未记录隧道 ID（手动 Token 部署），跳过云端清理，请手动在 Cloudflare 控制台删除隧道与 DNS。"
    fi

    case "$INIT_SYSTEM" in
        systemd)
            systemctl disable --now xray >/dev/null 2>&1 || true
            systemctl disable --now xray-argo >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray-argo.service
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl reset-failed xray xray-argo >/dev/null 2>&1 || true
            ;;
        openrc)
            rc-update del xray default >/dev/null 2>&1 || true
            rc-update del xray-argo default >/dev/null 2>&1 || true
            rm -f /etc/init.d/xray /etc/init.d/xray-argo
            ;;
    esac

    _info "正在清理文件..."
    rm -rf "$XRAY_DIR" "$RUNTIME_DIR"
    rm -f "$LOG_FILE" "$ARGO_LOG_FILE"

    _success "Xray-go 已卸载完成。"

    # 管理命令 xg 默认保留，按需一并删除，避免"卸完还留个 xg"的疑惑
    local self_cmd="/usr/local/bin/xg"
    if [ -f "$self_cmd" ]; then
        if _ask_yes "  是否同时删除管理命令 ${self_cmd}? (y/N): " n; then
            rm -f "$self_cmd" 2>/dev/null \
                && _success "管理命令已删除: ${self_cmd}" \
                || _warn "删除 ${self_cmd} 失败，请手动执行 rm -f ${self_cmd}"
        else
            _info "已保留管理命令: ${self_cmd}（可继续用它重新部署）"
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

# ==============================================================================
#  兼容旧版参数
# ==============================================================================

_legacy_deploy() {
    local ARG_H3="" ARG_REALITY="" ARG_ARGO_PROTOCOL="quic" ARG_ARGO_PORT="8001"
    local ARG_ARGO_DOMAIN="" ARG_ARGO_TOKEN="" arg clean_arg

    for arg in "$@"; do
        clean_arg="${arg//\"/}"
        clean_arg="${clean_arg//\'/}"

        if [[ "$clean_arg" =~ ^[hH]3(.*)$ ]]; then
            ARG_H3="${BASH_REMATCH[1]}"
        elif [[ "$clean_arg" =~ ^[rR][eE][aA][lL][iI][tT][yY](.*)$ ]]; then
            ARG_REALITY="${BASH_REMATCH[1]}"
        elif [[ "$clean_arg" =~ ^argo[pP][rR][oO][tT][oO][cC][oO][lL](.*)$ ]] || [[ "$clean_arg" =~ ^[pP][rR][oO][tT][oO][cC][oO][lL](.*)$ ]]; then
            ARG_ARGO_PROTOCOL="${BASH_REMATCH[1]}"
        elif [[ "$clean_arg" =~ ^argo[pP][oO][rR][tT](.*)$ ]] || [[ "$clean_arg" =~ ^[pP][oO][rR][tT](.*)$ ]]; then
            ARG_ARGO_PORT="${BASH_REMATCH[1]}"
        elif [[ "$clean_arg" =~ ^argo[dD][oO][mM][aA][iI][nN](.*)$ ]] || [[ "$clean_arg" =~ ^[dD][oO][mM][aA][iI][nN](.*)$ ]]; then
            ARG_ARGO_DOMAIN="${BASH_REMATCH[1]}"
        elif [[ "$clean_arg" =~ ^argo[tT][oO][kK][eE][nN](.*)$ ]] || [[ "$clean_arg" =~ ^[tT][oO][kK][eE][nN](.*)$ ]]; then
            ARG_ARGO_TOKEN="${BASH_REMATCH[1]}"
        elif [[ "$clean_arg" =~ ^[0-9]+$ ]] || [[ "$clean_arg" =~ ^[yYnN]$ ]]; then
            if [ -z "$ARG_H3" ]; then
                ARG_H3="$clean_arg"
            elif [ -z "$ARG_REALITY" ]; then
                ARG_REALITY="$clean_arg"
            fi
        fi
    done

    _parse_port() {
        local input="$1"
        [ -z "$input" ] && { echo ""; return; }
        case "$input" in
            n | N) echo "" ;;
            y | Y) _rand_port ;;
            *)
                if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le 65535 ]; then
                    echo "$input"
                else
                    echo ""
                fi
                ;;
        esac
    }

    local h3_port reality_port
    h3_port=$(_parse_port "$ARG_H3")
    reality_port=$(_parse_port "$ARG_REALITY")

    local argo_port="$ARG_ARGO_PORT" argo_token="$ARG_ARGO_TOKEN" argo_domain="$ARG_ARGO_DOMAIN"
    local argo_protocol="${ARG_ARGO_PROTOCOL:-quic}"

    if [ -z "$argo_port" ] || [ -z "$argo_domain" ] || [ -z "$argo_token" ]; then
        argo_token=""
        argo_domain=""
        argo_port="0"
    fi

    if [ -z "$h3_port" ] && [ -z "$reality_port" ] && [ -z "$argo_token" ]; then
        _warn "未检测到有效参数（H3、Reality 及 Argo 均未启用）。"
        _info "如需交互式部署，请不带参数运行本脚本。"
        return 0
    fi

    _deploy_all "$reality_port" "$h3_port" "$argo_protocol" "$argo_port" "$argo_domain" "$argo_token"
}

# ==============================================================================
#  主菜单
# ==============================================================================

_main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}"
        echo '  __  __ ____             ____       '
        echo '  \ \/ // __ \____ ___  _/ __ \____  '
        echo '   \  // /_/ / __ `/ / / / / / / __ \ '
        echo '   / // _, _/ /_/ / /_/ / /_/ / /_/ / '
        echo '  /_//_/ |_|\__,_/\__, /\____/\____/  '
        echo '                 /____/   Xray-go    '
        echo -e "${NC}"
        echo -e "${CYAN}  ╔══════════════════════════════════════════╗"
        echo -e "  ║     Xray-go 一键部署管理脚本 V${SCRIPT_VERSION}        ║"
        echo -e "  ╚══════════════════════════════════════════╝${NC}"
        echo "" >&2

        _show_status

        echo -e "  ${CYAN}【部署】${NC}" >&2
        echo -e "    ${GREEN}[1]${NC} 一键部署 (Reality + H3，随机端口)" >&2
        echo -e "    ${GREEN}[2]${NC} 自定义部署 (可选协议/端口/Argo)" >&2
        echo -e "    ${GREEN}[3]${NC} Argo 自动搭建 (CF 邮箱 + API Key)" >&2
        echo "" >&2
        echo -e "  ${CYAN}【节点】${NC}" >&2
        echo -e "    ${RED}[4]${NC} 删除 Argo 节点 (含云端隧道 + DNS)" >&2
        echo "" >&2
        echo -e "  ${CYAN}【管理】${NC}" >&2
        echo -e "    ${GREEN}[5]${NC} 查看节点链接" >&2
        echo -e "    ${GREEN}[6]${NC} 服务控制" >&2
        echo -e "    ${GREEN}[7]${NC} 查看实时日志" >&2
        echo -e "    ${GREEN}[8]${NC} 查看 Argo 日志" >&2
        echo -e "    ${GREEN}[9]${NC} 检查配置文件" >&2
        echo "" >&2
        echo -e "  ${CYAN}【维护】${NC}" >&2
        echo -e "    ${GREEN}[10]${NC} 更新 Xray 核心" >&2
        echo -e "    ${GREEN}[11]${NC} 更新脚本" >&2
        echo -e "    ${RED}[12]${NC} 卸载部署" >&2
        echo "" >&2
        echo -e "  ───────────────────────────────────────────" >&2
        echo -e "    ${YELLOW}[0]${NC} 退出" >&2
        echo "" >&2

        local choice=""
        read -r -p "  请输入选项 [0-12]: " choice || return 0
        case "$choice" in
            1) _one_click_deploy ;;
            2) _custom_deploy ;;
            3) _add_argo_only ;;
            4) _argo_delete_node ;;
            5) _show_links ;;
            6) _service_menu ;;
            7) _view_log ;;
            8) _view_argo_log ;;
            9) _check_config ;;
            10) _update_core ;;
            11) _update_script && exit 0 ;;
            12) _uninstall_deploy ;;
            0) exit 0 ;;
            *) _error "无效输入，请重试。" ;;
        esac
        echo "" >&2
        read -n 1 -s -r -p "按任意键返回主菜单..." || return 0
    done
}

# ==============================================================================
#  入口
# ==============================================================================

_print_help() {
    cat >&2 <<EOF
Xray-go 管理脚本 V${SCRIPT_VERSION}  (构建 ${SCRIPT_BUILD})

用法: $(basename "$0") [快捷指令 | 命令]

  快捷指令：
    1              进入管理菜单（推荐）
    2              一键部署 Reality + H3
    3              查看节点链接
    4              查看运行状态
    5              卸载部署
    0              退出

  完整命令：
    menu              进入管理菜单
    deploy            一键部署 Reality + H3（随机端口）
    custom            自定义部署（可选协议/端口/Argo）
    argo              Argo 自动搭建（CF 邮箱 + Global API Key）
    del-argo          删除 Argo 节点（含云端隧道 + DNS 解析）
    links             查看节点链接与 Base64 订阅
    status            查看运行状态
    start|stop|restart 控制 Xray 服务
    log               查看实时日志
    check             校验配置文件
    update-core       更新 Xray 核心
    update-script     更新本脚本（同版本自动跳过，加 force 强制覆盖）
    -v | --version    查看当前脚本版本号
    uninstall         卸载部署（含云端隧道 + DNS + 本地文件）

兼容旧版参数写法（示例）:
  $(basename "$0") reality"n" h3"y" argo protocol"http2" port"8001" domain"" token""

环境变量（一键部署时可选）:
  ARGO_TOKEN / ARGO_DOMAIN / ARGO_PROTOCOL / ARGO_PORT
  CF_EMAIL / CF_API_KEY   （提供后 Argo 走自动搭建，无需手动建隧道）
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
            _one_click_deploy
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
            ;;
        0 | q | quit | exit)
            exit 0
            ;;
        # ---- 完整命令 ----
        deploy | install | onekey)
            _install_dependencies || exit 1
            _one_click_deploy
            ;;
        custom)
            _install_dependencies || exit 1
            _custom_deploy
            ;;
        argo | add-argo | argo-setup)
            _add_argo_only
            ;;
        del-argo | rm-argo | delete-argo)
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
            ;;
        log)
            _view_log
            ;;
        argo-log)
            _view_argo_log
            ;;
        check)
            _install_dependencies >/dev/null 2>&1
            _check_config
            ;;
        update-core)
            _update_core
            ;;
        update-script)
            _update_script "${2:-}"
            ;;
        uninstall)
            _uninstall_deploy
            ;;
        menu)
            _install_dependencies || _warn "依赖安装未完全成功，部分功能可能不可用。"
            _main_menu
            ;;
        help | -h | --help)
            _print_help
            ;;
        *)
            _legacy_deploy "$@"
            ;;
    esac
}

main "$@"
