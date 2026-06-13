#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPOSITORY="tuxco-de/tuic"
readonly SERVICE_NAME="tuic-server"
readonly INSTALL_BIN="/usr/local/bin/tuic-server"
readonly CONFIG_DIR="/etc/tuic"
readonly CONFIG_FILE="${CONFIG_DIR}/config.toml"
readonly DATA_DIR="/var/lib/tuic"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

VERSION="latest"
DOMAIN=""
PORT="443"
TLS_MODE="acme"
DNS_PROVIDER=""
ACME_EMAIL=""
ACME_PORT="80"
CERTIFICATE=""
PRIVATE_KEY=""
TUIC_UUID=""
TUIC_PASSWORD=""
OPEN_FIREWALL="false"
FORCE_CONFIG="false"
NON_INTERACTIVE="false"
CONFIG_REUSED="false"

# Color Definitions
CLR_HEADER=""
CLR_INFO=""
CLR_SUCCESS=""
CLR_WARNING=""
CLR_ERROR=""
CLR_MUTED=""
CLR_RESET=""

# Check if stdout/stderr support colors
if [[ -t 1 && "${TERM:-}" != "dumb" ]]; then
	CLR_HEADER="$(printf '\033[1;36m')"   # Bold Cyan
	CLR_INFO="$(printf '\033[36m')"       # Cyan
	CLR_SUCCESS="$(printf '\033[1;32m')"  # Bold Green
	CLR_WARNING="$(printf '\033[1;33m')"  # Bold Yellow
	CLR_ERROR="$(printf '\033[1;31m')"    # Bold Red
	CLR_MUTED="$(printf '\033[90m')"      # Dark Gray (Muted)
	CLR_RESET="$(printf '\033[0m')"
fi

log() {
	printf "${CLR_INFO}[tuic-deploy] %s${CLR_RESET}\n" "$*"
}

log_success() {
	printf "${CLR_SUCCESS}[tuic-deploy] ✔ %s${CLR_RESET}\n" "$*"
}

log_warning() {
	printf "${CLR_WARNING}[tuic-deploy] ⚠ %s${CLR_RESET}\n" "$*"
}

fail() {
	printf "${CLR_ERROR}[tuic-deploy] ✘ ERROR: %s${CLR_RESET}\n" "$*" >&2
	exit 1
}

print_step() {
	local step_num="$1"
	local step_desc="$2"
	if [[ "$NON_INTERACTIVE" != "true" && -t 1 && -t 0 ]]; then
		printf "\n${CLR_HEADER}=== [Step %s/5] %s ===${CLR_RESET}\n" "$step_num" "$step_desc"
	else
		log "Step $step_num/5: $step_desc"
	fi
}

# Live validation helpers
validate_port_val() {
	local val="$1"
	if [[ ! "$val" =~ ^[0-9]+$ ]]; then
		printf "端口必须是纯数字"
		return 1
	fi
	if (( val < 1 || val > 65535 )); then
		printf "端口范围必须在 1 到 65535 之间"
		return 1
	fi
	return 0
}

validate_uuid_val() {
	local val="$1"
	if [[ ! "$val" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
		printf "UUID 格式不正确（格式示例: 12345678-1234-1234-1234-123456789abc）"
		return 1
	fi
	return 0
}

validate_domain_val() {
	local val="$1"
	if [[ "$val" == *[[:space:]]* ]]; then
		printf "域名不能包含空格"
		return 1
	fi
	if [[ ! "$val" =~ ^[a-zA-Z0-9.-]+$ ]]; then
		printf "域名或IP地址格式不符合规范"
		return 1
	fi
	return 0
}

validate_file_exists() {
	local val="$1"
	if [[ ! -f "$val" ]]; then
		printf "文件不存在: %s" "$val"
		return 1
	fi
	return 0
}

usage() {
	cat <<'EOF'
TUIC server guided deployment for Linux + systemd.

Usage:
  sudo bash scripts/deploy-server.sh [options]

Running without --non-interactive starts the deployment wizard.

Options:
  --domain DOMAIN           TLS hostname. Required for ACME.
  --port PORT               TUIC UDP listen port (default: 443).
  --tls MODE                acme, acme-dns, acme-dns-manual, self-signed, or manual (default: acme).
  --dns-provider PROVIDER   DNS provider for acme-dns (e.g. dns_cf).
  --email EMAIL             ACME account email.
  --certificate PATH        Certificate file for manual TLS mode.
  --private-key PATH        Private key file for manual TLS mode.
  --uuid UUID               TUIC user UUID (default: generated).
  --password PASSWORD       TUIC user password (default: generated).
  --version VERSION         Release tag such as v1.8.6 (default: latest).
  --open-firewall           Open the TUIC UDP port using ufw/firewalld.
  --force-config            Replace an existing config after backing it up.
  --non-interactive         Fail instead of prompting for missing values.
  -h, --help                Show this help.

Environment variables with matching names are also supported:
  TUIC_DOMAIN, TUIC_PORT, TUIC_TLS_MODE, TUIC_DNS_PROVIDER, TUIC_ACME_EMAIL,
  TUIC_CERTIFICATE, TUIC_PRIVATE_KEY, TUIC_UUID, TUIC_PASSWORD,
  TUIC_VERSION, TUIC_OPEN_FIREWALL, TUIC_FORCE_CONFIG.

Examples:
  sudo bash deploy-server.sh --domain tuic.example.com --email admin@example.com
  sudo bash deploy-server.sh --tls self-signed --domain 203.0.113.10
  sudo bash deploy-server.sh --tls manual --domain tuic.example.com \
    --certificate /root/fullchain.pem --private-key /root/privkey.pem
EOF
}

require_root() {
	[[ "$(id -u)" -eq 0 ]] || fail "run this script as root (use sudo)"
}

require_linux_systemd() {
	[[ "$(uname -s)" == "Linux" ]] || fail "only Linux is supported"
	command -v systemctl >/dev/null 2>&1 || fail "systemd/systemctl is required"
	[[ -d /run/systemd/system ]] || fail "systemd is not running"
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

parse_bool() {
	case "${1,,}" in
		1 | true | yes | y | on) printf 'true' ;;
		0 | false | no | n | off | '') printf 'false' ;;
		*) fail "invalid boolean value: $1" ;;
	esac
}

load_environment() {
	DOMAIN="${TUIC_DOMAIN:-$DOMAIN}"
	PORT="${TUIC_PORT:-$PORT}"
	TLS_MODE="${TUIC_TLS_MODE:-$TLS_MODE}"
	DNS_PROVIDER="${TUIC_DNS_PROVIDER:-$DNS_PROVIDER:-}"
	ACME_EMAIL="${TUIC_ACME_EMAIL:-$ACME_EMAIL}"
	CERTIFICATE="${TUIC_CERTIFICATE:-$CERTIFICATE}"
	PRIVATE_KEY="${TUIC_PRIVATE_KEY:-$PRIVATE_KEY}"
	TUIC_UUID="${TUIC_UUID:-$TUIC_UUID}"
	TUIC_PASSWORD="${TUIC_PASSWORD:-$TUIC_PASSWORD}"
	VERSION="${TUIC_VERSION:-$VERSION}"
	ACME_PORT="${TUIC_ACME_PORT:-$ACME_PORT}"
	OPEN_FIREWALL="$(parse_bool "${TUIC_OPEN_FIREWALL:-$OPEN_FIREWALL}")"
	FORCE_CONFIG="$(parse_bool "${TUIC_FORCE_CONFIG:-$FORCE_CONFIG}")"
}

parse_arguments() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--domain) DOMAIN="${2:?missing value for --domain}"; shift 2 ;;
			--port) PORT="${2:?missing value for --port}"; shift 2 ;;
			--tls) TLS_MODE="${2:?missing value for --tls}"; shift 2 ;;
			--dns-provider) DNS_PROVIDER="${2:?missing value for --dns-provider}"; shift 2 ;;
			--email) ACME_EMAIL="${2:?missing value for --email}"; shift 2 ;;
			--acme-port) ACME_PORT="${2:?missing value for --acme-port}"; shift 2 ;;
			--certificate) CERTIFICATE="${2:?missing value for --certificate}"; shift 2 ;;
			--private-key) PRIVATE_KEY="${2:?missing value for --private-key}"; shift 2 ;;
			--uuid) TUIC_UUID="${2:?missing value for --uuid}"; shift 2 ;;
			--password) TUIC_PASSWORD="${2:?missing value for --password}"; shift 2 ;;
			--version) VERSION="${2:?missing value for --version}"; shift 2 ;;
			--open-firewall) OPEN_FIREWALL="true"; shift ;;
			--force-config) FORCE_CONFIG="true"; shift ;;
			--non-interactive) NON_INTERACTIVE="true"; shift ;;
			-h | --help) usage; exit 0 ;;
			*) fail "unknown option: $1" ;;
		esac
	done
}

prompt_if_needed() {
	[[ "$NON_INTERACTIVE" != "true" ]] || return
	run_wizard
}

read_tty() {
	[[ -r /dev/tty ]] || fail "interactive terminal not available; use --non-interactive with complete options"
	IFS= read -r "$@" </dev/tty
}

prompt_value() {
	local variable="$1" label="$2" default_value="$3" required="${4:-false}" validator="${5:-}" value
	while true; do
		if [[ -n "$default_value" ]]; then
			printf "${CLR_INFO}%s${CLR_RESET} [${CLR_MUTED}%s${CLR_RESET}]: " "$label" "$default_value" >/dev/tty
		else
			printf "${CLR_INFO}%s${CLR_RESET}: " "$label" >/dev/tty
		fi
		read_tty value
		value="${value:-$default_value}"
		if [[ "$required" == "true" && -z "$value" ]]; then
			printf "${CLR_ERROR}✘ 该项不能为空，请重新输入。${CLR_RESET}\n" >/dev/tty
			continue
		fi
		if [[ -n "$value" && -n "$validator" ]]; then
			local err_msg
			err_msg="$("$validator" "$value" 2>&1)"
			if [[ $? -ne 0 ]]; then
				printf "${CLR_ERROR}✘ 输入无效: %s${CLR_RESET}\n" "${err_msg:-格式错误}" >/dev/tty
				continue
			fi
		fi
		printf -v "$variable" '%s' "$value"
		return
	done
}

prompt_secret() {
	local variable="$1" label="$2" current_value value
	current_value="${!variable}"
	if [[ -n "$current_value" ]]; then
		printf "${CLR_INFO}%s${CLR_RESET} [${CLR_MUTED}已预设，留空则保留${CLR_RESET}]: " "$label" >/dev/tty
	else
		printf "${CLR_INFO}%s${CLR_RESET} [${CLR_MUTED}留空则自动生成${CLR_RESET}]: " "$label" >/dev/tty
	fi
	IFS= read -r -s value </dev/tty
	printf '\n' >/dev/tty
	[[ -n "$value" ]] || value="$current_value"
	if [[ -n "$value" ]]; then
		if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
			printf "${CLR_ERROR}✘ 密码不能包含换行符，将自动生成新密码。${CLR_RESET}\n" >/dev/tty
			value=""
		fi
	fi
	printf -v "$variable" '%s' "$value"
}

prompt_yes_no() {
	local label="$1" default_value="$2" answer suffix
	if [[ "$default_value" == "true" ]]; then
		suffix="${CLR_SUCCESS}Y${CLR_RESET}/${CLR_MUTED}n${CLR_RESET}"
	else
		suffix="${CLR_MUTED}y${CLR_RESET}/${CLR_ERROR}N${CLR_RESET}"
	fi
	while true; do
		printf "${CLR_INFO}%s${CLR_RESET} [%s]: " "$label" "$suffix" >/dev/tty
		read_tty answer
		case "${answer,,}" in
			y | yes) return 0 ;;
			n | no) return 1 ;;
			'') [[ "$default_value" == "true" ]] && return 0 || return 1 ;;
			*) printf "${CLR_ERROR}✘ 请输入 y 或 n。${CLR_RESET}\n" >/dev/tty ;;
		esac
	done
}

select_dns_provider() {
	local selection default_selection="1"
	case "${DNS_PROVIDER:-}" in
		dns_cf) default_selection="1" ;;
		dns_ali) default_selection="2" ;;
		dns_dp) default_selection="3" ;;
		"") default_selection="1" ;;
		*) default_selection="4" ;;
	esac

	cat >/dev/tty <<EOF

${CLR_HEADER}请选择 DNS API 解析服务商：${CLR_RESET}
  ${CLR_SUCCESS}1)${CLR_RESET} Cloudflare (dns_cf)
  ${CLR_SUCCESS}2)${CLR_RESET} 阿里云 (dns_ali)
  ${CLR_SUCCESS}3)${CLR_RESET} 腾讯云/DNSPod (dns_dp)
  ${CLR_SUCCESS}4)${CLR_RESET} 其他 (手动输入 acme.sh 支持的提供商代码)
EOF
	while true; do
		printf "${CLR_INFO}请选择 [${CLR_MUTED}%s${CLR_RESET}]: " "$default_selection" >/dev/tty
		read_tty selection
		case "${selection:-$default_selection}" in
			1) DNS_PROVIDER="dns_cf"; return ;;
			2) DNS_PROVIDER="dns_ali"; return ;;
			3) DNS_PROVIDER="dns_dp"; return ;;
			4)
				prompt_value DNS_PROVIDER "请输入 acme.sh 支持的 DNS 提供商代码 (如 dns_gd)" "${DNS_PROVIDER:-dns_gd}" true
				return
				;;
			*) printf "${CLR_ERROR}✘ 请输入 1 到 4 之间的数字。${CLR_RESET}\n" >/dev/tty ;;
		esac
	done
}

select_tls_mode() {
	local selection default_selection
	case "${TLS_MODE,,}" in
		acme) default_selection="1" ;;
		acme-dns) default_selection="2" ;;
		acme-dns-manual) default_selection="3" ;;
		self-signed) default_selection="4" ;;
		manual) default_selection="5" ;;
		*) default_selection="1" ;;
	esac

	cat >/dev/tty <<EOF

${CLR_HEADER}请选择 TLS 证书申请/配置方式：${CLR_RESET}
  ${CLR_SUCCESS}1)${CLR_RESET} ACME 自动申请 (推荐，需将域名解析到本机且开放 TCP 80 端口)
  ${CLR_SUCCESS}2)${CLR_RESET} ACME DNS API 自动申请 (适合 NAT VPS 或无法开放 80 端口的用户，需提前 export DNS API Token)
  ${CLR_SUCCESS}3)${CLR_RESET} ACME DNS 手动申请 (需在 DNS 解析商处手动添加 TXT 记录)
  ${CLR_SUCCESS}4)${CLR_RESET} 自动生成自签名证书 (仅建议在测试环境下使用)
  ${CLR_SUCCESS}5)${CLR_RESET} 手动指定已有证书文件 (适合已有证书的用户)
EOF
	while true; do
		printf "${CLR_INFO}请选择 [${CLR_MUTED}%s${CLR_RESET}]: " "$default_selection" >/dev/tty
		read_tty selection
		case "${selection:-$default_selection}" in
			1) TLS_MODE="acme"; return ;;
			2) TLS_MODE="acme-dns"; return ;;
			3) TLS_MODE="acme-dns-manual"; return ;;
			4) TLS_MODE="self-signed"; return ;;
			5) TLS_MODE="manual"; return ;;
			*) printf "${CLR_ERROR}✘ 请输入 1 到 5 之间的数字。${CLR_RESET}\n" >/dev/tty ;;
		esac
	done
}

show_deployment_summary() {
	cat >/dev/tty <<EOF

${CLR_HEADER}┌────────────────────────────────────────────────────────┐${CLR_RESET}
${CLR_HEADER}│                   TUIC 部署配置确认                    │${CLR_RESET}
${CLR_HEADER}├────────────────────────────────────────────────────────┤${CLR_RESET}
EOF
	if [[ "$CONFIG_REUSED" == "true" ]]; then
		cat >/dev/tty <<EOF
${CLR_HEADER}│${CLR_RESET}  部署版本:     ${VERSION}
${CLR_HEADER}│${CLR_RESET}  现有配置:     保留 ${CONFIG_FILE}
${CLR_HEADER}│${CLR_RESET}  操作模式:     仅升级程序并重启 systemd 服务
EOF
	else
		local display_tls
		case "$TLS_MODE" in
			acme) display_tls="ACME 自动申请" ;;
			acme-dns) display_tls="ACME DNS API 自动申请" ;;
			acme-dns-manual) display_tls="ACME DNS 手动申请" ;;
			self-signed) display_tls="自签名证书" ;;
			manual) display_tls="手动指定证书" ;;
			*) display_tls="$TLS_MODE" ;;
		esac
		cat >/dev/tty <<EOF
${CLR_HEADER}│${CLR_RESET}  部署版本:     ${VERSION}
${CLR_HEADER}│${CLR_RESET}  监听地址:     [::]:${PORT}/udp
${CLR_HEADER}│${CLR_RESET}  TLS 模式:     ${display_tls}
${CLR_HEADER}│${CLR_RESET}  主机名/域名:  ${DOMAIN}
${CLR_HEADER}│${CLR_RESET}  开放防火墙:   ${OPEN_FIREWALL}
${CLR_HEADER}│${CLR_RESET}  UUID:         ${TUIC_UUID}
${CLR_HEADER}│${CLR_RESET}  密码:         ${TUIC_PASSWORD}
EOF
	fi
	cat >/dev/tty <<EOF
${CLR_HEADER}└────────────────────────────────────────────────────────┘${CLR_RESET}
EOF
}

run_wizard() {
	[[ -r /dev/tty && -w /dev/tty ]] || fail "interactive terminal not available; use --non-interactive with complete options"
	cat >/dev/tty <<EOF

${CLR_HEADER}TUIC 服务端引导式部署${CLR_RESET}
========================================
脚本将下载安装预编译服务端、自动配置并生成 systemd 服务。
按 Enter 可直接接受方括号 [ ] 中的默认值。
EOF

	if [[ -e "$CONFIG_FILE" ]]; then
		if prompt_yes_no "检测到现有配置，是否保留配置并仅升级程序" "true"; then
			CONFIG_REUSED="true"
			FORCE_CONFIG="false"
		else
			FORCE_CONFIG="true"
		fi
	fi

	prompt_value VERSION "部署版本（latest 或 v1.8.6）" "$VERSION" true

	if [[ "$CONFIG_REUSED" != "true" ]]; then
		select_tls_mode
		case "$TLS_MODE" in
			acme)
				prompt_value DOMAIN "证书域名" "$DOMAIN" true validate_domain_val
				prompt_value ACME_EMAIL "ACME 邮箱（可留空）" "$ACME_EMAIL" false
				prompt_value ACME_PORT "ACME 监听端口 (默认 80, 输入 443 则使用 ALPN 模式)" "${ACME_PORT:-80}" false validate_port_val
				;;
			acme-dns)
				prompt_value DOMAIN "证书域名" "$DOMAIN" true validate_domain_val
				select_dns_provider
				;;
			acme-dns-manual)
				prompt_value DOMAIN "证书域名" "$DOMAIN" true validate_domain_val
				;;
			self-signed)
				prompt_value DOMAIN "证书主机名或服务器 IP" "${DOMAIN:-localhost}" true validate_domain_val
				;;
			manual)
				prompt_value DOMAIN "证书对应域名" "$DOMAIN" true validate_domain_val
				prompt_value CERTIFICATE "证书文件路径" "$CERTIFICATE" true validate_file_exists
				prompt_value PRIVATE_KEY "私钥文件路径" "$PRIVATE_KEY" true validate_file_exists
				;;
		esac

		prompt_value PORT "TUIC UDP 监听端口" "$PORT" true validate_port_val
		prompt_value TUIC_UUID "用户 UUID（留空则自动生成）" "$TUIC_UUID" false validate_uuid_val
		prompt_secret TUIC_PASSWORD "用户密码"
		generate_credentials
	else
		OPEN_FIREWALL="false"
	fi

	if [[ "$CONFIG_REUSED" != "true" ]]; then
		if prompt_yes_no "是否自动配置 ufw/firewalld 防火墙" "$OPEN_FIREWALL"; then
			OPEN_FIREWALL="true"
		else
			OPEN_FIREWALL="false"
		fi
	fi

	validate_inputs
	show_deployment_summary
	if ! prompt_yes_no "确认开始部署" "true"; then
		log_warning "部署已被用户取消。"
		exit 0
	fi
}

validate_inputs() {
	if [[ "$CONFIG_REUSED" == "true" ]]; then
		[[ -n "$VERSION" ]] || fail "version must not be empty"
		return
	fi
	TLS_MODE="${TLS_MODE,,}"
	[[ "$PORT" =~ ^[0-9]+$ ]] || fail "port must be numeric"
	(( PORT >= 1 && PORT <= 65535 )) || fail "port must be between 1 and 65535"
	[[ "$DOMAIN" != *[[:space:]]* ]] || fail "domain must not contain whitespace"

	case "$TLS_MODE" in
		acme)
			[[ -n "$DOMAIN" ]] || fail "--domain is required for ACME mode"
			ACME_PORT="${ACME_PORT:-80}"
			[[ "$ACME_PORT" =~ ^[0-9]+$ ]] || fail "acme-port must be numeric"
			(( ACME_PORT >= 1 && ACME_PORT <= 65535 )) || fail "acme-port must be between 1 and 65535"
			;;
		acme-dns)
			[[ -n "$DOMAIN" ]] || fail "--domain is required for ACME DNS mode"
			[[ -n "$DNS_PROVIDER" ]] || fail "--dns-provider is required for ACME DNS mode"
			;;
		acme-dns-manual)
			[[ -n "$DOMAIN" ]] || fail "--domain is required for ACME DNS manual mode"
			;;
		self-signed)
			DOMAIN="${DOMAIN:-localhost}"
			;;
		manual)
			[[ -n "$DOMAIN" ]] || fail "--domain is required for manual TLS mode"
			[[ -f "$CERTIFICATE" ]] || fail "certificate file not found: $CERTIFICATE"
			[[ -f "$PRIVATE_KEY" ]] || fail "private key file not found: $PRIVATE_KEY"
			;;
		*) fail "TLS mode must be acme, acme-dns, acme-dns-manual, self-signed, or manual" ;;
	esac

	if [[ -n "$TUIC_UUID" ]]; then
		[[ "$TUIC_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
			|| fail "invalid UUID format"
	fi
	[[ "$TUIC_PASSWORD" != *$'\n'* && "$TUIC_PASSWORD" != *$'\r'* ]] || fail "password must be a single line"
}

detect_asset() {
	case "$(uname -m)" in
		x86_64 | amd64) printf 'tuic-server-x86_64-linux-musl' ;;
		aarch64 | arm64) printf 'tuic-server-aarch64-linux-musl' ;;
		armv7l | armv7) printf 'tuic-server-armv7-linux-muslhf' ;;
		i386 | i486 | i586 | i686) printf 'tuic-server-i686-linux-musl' ;;
		riscv64) printf 'tuic-server-riscv64gc-linux' ;;
		loongarch64) printf 'tuic-server-loongarch64-linux' ;;
		*) fail "unsupported architecture: $(uname -m)" ;;
	esac
}

download_binary() {
	local asset url checksum_url temporary
	asset="$(detect_asset)"
	if [[ "$VERSION" == "latest" ]]; then
		url="https://github.com/${REPOSITORY}/releases/latest/download/${asset}"
		checksum_url="https://github.com/${REPOSITORY}/releases/latest/download/sha256sum.txt"
	else
		[[ "$VERSION" == v* ]] || VERSION="v${VERSION}"
		url="https://github.com/${REPOSITORY}/releases/download/${VERSION}/${asset}"
		checksum_url="https://github.com/${REPOSITORY}/releases/download/${VERSION}/sha256sum.txt"
	fi

	temporary="$(mktemp -d)"
	trap "rm -rf '$temporary'" EXIT
	log "正在下载二进制服务端 ${asset} (${VERSION})..."
	curl --fail --location --retry 3 --connect-timeout 15 --output "$temporary/${asset}" "$url"

	log "正在验证文件完整性 (SHA256 checksum)..."
	if curl --silent --fail --location --retry 3 --connect-timeout 15 --output "$temporary/sha256sum.txt" "$checksum_url"; then
		(cd "$temporary" && grep "${asset}$" sha256sum.txt | sha256sum -c -) || fail "校验和(Checksum)验证失败，下载的文件可能已损坏"
	else
		log_warning "未找到 sha256sum.txt 校验文件，将跳过完整性校验"
	fi

	chmod 0755 "$temporary/${asset}"
	"$temporary/${asset}" --version >/dev/null
	install -m 0755 "$temporary/${asset}" "$INSTALL_BIN"
	trap - EXIT
	rm -rf "$temporary"
}

create_service_user() {
	local nologin_shell
	nologin_shell="$(command -v nologin || true)"
	[[ -n "$nologin_shell" ]] || nologin_shell="/usr/sbin/nologin"
	if ! getent group "$SERVICE_NAME" >/dev/null 2>&1; then
		groupadd --system "$SERVICE_NAME"
	fi
	if ! id "$SERVICE_NAME" >/dev/null 2>&1; then
		useradd --system --gid "$SERVICE_NAME" --home-dir "$DATA_DIR" --shell "$nologin_shell" "$SERVICE_NAME"
	fi

	install -d -m 0750 -o root -g "$SERVICE_NAME" "$CONFIG_DIR"
	install -d -m 0750 -o "$SERVICE_NAME" -g "$SERVICE_NAME" "$DATA_DIR"
}

random_hex() {
	local byte_count="$1"
	od -An -N "$byte_count" -tx1 /dev/urandom | tr -d ' \n'
}

generate_credentials() {
	if [[ -z "$TUIC_UUID" ]]; then
		if [[ -r /proc/sys/kernel/random/uuid ]]; then
			TUIC_UUID="$(cat /proc/sys/kernel/random/uuid)"
		else
			local hex
			hex="$(random_hex 16)"
			TUIC_UUID="${hex:0:8}-${hex:8:4}-4${hex:13:3}-a${hex:17:3}-${hex:20:12}"
		fi
	fi
	[[ -n "$TUIC_PASSWORD" ]] || TUIC_PASSWORD="$(random_hex 24)"
}

toml_escape() {
	local value="$1"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	printf '%s' "$value"
}

install_manual_certificates() {
	local tls_dir="${CONFIG_DIR}/tls"
	install -d -m 0750 -o root -g "$SERVICE_NAME" "$tls_dir"
	install -m 0640 -o root -g "$SERVICE_NAME" "$CERTIFICATE" "${tls_dir}/certificate.pem"
	install -m 0640 -o root -g "$SERVICE_NAME" "$PRIVATE_KEY" "${tls_dir}/private-key.pem"
	CERTIFICATE="${tls_dir}/certificate.pem"
	PRIVATE_KEY="${tls_dir}/private-key.pem"
}

issue_acme_cert() {
	local acme_cmd="/root/.acme.sh/acme.sh"
	
	# Check dependencies
	if ! command -v cron >/dev/null 2>&1 && ! command -v crond >/dev/null 2>&1 && ! systemctl is-active --quiet cron && ! systemctl is-active --quiet crond; then
		log_warning "未找到 cron 守护进程，正在尝试自动安装以支持 acme.sh 自动续期..."
		if command -v apt-get >/dev/null 2>&1; then
			export DEBIAN_FRONTEND=noninteractive
			apt-get update -qq && apt-get install -y -qq cron
			systemctl enable --now cron
		elif command -v dnf >/dev/null 2>&1; then
			dnf install -y -q cronie
			systemctl enable --now crond
		elif command -v yum >/dev/null 2>&1; then
			yum install -y -q cronie
			systemctl enable --now crond
		elif command -v pacman >/dev/null 2>&1; then
			pacman -Sy --noconfirm --quiet cronie
			systemctl enable --now cronie
		elif command -v apk >/dev/null 2>&1; then
			apk add --quiet cronie
			rc-update add crond
			rc-service crond start
		else
			log_warning "不支持的包管理器，请手动安装 cron"
		fi
	fi
	
	if [[ "$TLS_MODE" == "acme" ]] && ! command -v socat >/dev/null 2>&1; then
		log_warning "未找到 socat，正在尝试自动安装以支持 acme.sh 独立端口验证模式..."
		if command -v apt-get >/dev/null 2>&1; then
			export DEBIAN_FRONTEND=noninteractive
			apt-get update -qq && apt-get install -y -qq socat
		elif command -v dnf >/dev/null 2>&1; then
			dnf install -y -q epel-release || true
			dnf install -y -q socat
		elif command -v yum >/dev/null 2>&1; then
			yum install -y -q epel-release || true
			yum install -y -q socat
		elif command -v pacman >/dev/null 2>&1; then
			pacman -Sy --noconfirm --quiet socat
		elif command -v apk >/dev/null 2>&1; then
			apk add --quiet socat
		else
			fail "不支持的包管理器，请手动安装 socat"
		fi
	fi

	if [[ ! -x "$acme_cmd" ]]; then
		log "正在安装 acme.sh 证书申请工具..."
		curl https://get.acme.sh | sh
		if [[ -n "$ACME_EMAIL" ]]; then
			log "正在使用邮箱 $ACME_EMAIL 注册 acme.sh 账户..."
			"$acme_cmd" --register-account -m "$ACME_EMAIL"
		fi
	fi

	local cert_dir="${CONFIG_DIR}/tls"
	install -d -m 0750 -o root -g "$SERVICE_NAME" "$cert_dir"
	
	local existing_cert="false"
	if [[ -f "/root/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.cer" || -f "/root/.acme.sh/${DOMAIN}/${DOMAIN}.cer" ]]; then
		existing_cert="true"
	fi

	local do_issue="true"
	if [[ "$existing_cert" == "true" ]]; then
		log_success "检测到域名 $DOMAIN 的证书已在 acme.sh 目录中存在。"
		if [[ "$NON_INTERACTIVE" == "true" ]]; then
			log "非交互模式，默认跳过重新签发，直接应用现有证书。"
			do_issue="false"
		elif ! prompt_yes_no "是否强制重新签发 (renew) 该证书？" "false"; then
			log "跳过证书申请，将直接应用现有证书。"
			do_issue="false"
		fi
	fi

	if [[ "$do_issue" == "true" ]]; then
		log "正在申请域名 $DOMAIN 的 SSL/TLS 证书..."
		local issue_args=("--issue" "-d" "$DOMAIN" "--keylength" "ec-256" "--server" "letsencrypt")
		if [[ "$existing_cert" == "true" ]]; then
			issue_args+=("--force")
		fi

		if [[ "$TLS_MODE" == "acme-dns" ]]; then
			issue_args+=("--dns" "$DNS_PROVIDER")
			"$acme_cmd" "${issue_args[@]}"
		elif [[ "$TLS_MODE" == "acme-dns-manual" ]]; then
			issue_args+=("--dns" "--yes-I-know-dns-manual-mode-enough-go-ahead-please")
			log "正在启动 ACME DNS 手动验证模式，请耐心等待验证信息生成..."
			"$acme_cmd" "${issue_args[@]}" || true
			
			if [[ "$NON_INTERACTIVE" == "true" ]]; then
				fail "检测到 --non-interactive 模式，无法等待人工确认。对于非交互式环境，请使用 --tls acme-dns 并提供 DNS API Token。"
			fi
			
			printf "\n${CLR_WARNING}=== 重要操作提示 ===${CLR_RESET}\n" >/dev/tty
			printf "请前往您的 DNS 托管商控制台，按照上述 acme.sh 的输出，添加相应的 TXT 记录。\n" >/dev/tty
			printf "添加完成后，请等待 1-2 分钟以确保 DNS 记录已在全球生效。\n\n" >/dev/tty
			
			local _junk
			prompt_value _junk "确认 TXT 记录生效后，输入 'y' 并按 Enter 键继续" "y" true
			
			log "正在继续进行证书签发..."
			local renew_args=("--renew" "-d" "$DOMAIN" "--yes-I-know-dns-manual-mode-enough-go-ahead-please" "--ecc" "--server" "letsencrypt")
			if [[ "$existing_cert" == "true" ]]; then
				renew_args+=("--force")
			fi
			"$acme_cmd" "${renew_args[@]}"
		else
			issue_args+=("--standalone")
			if [[ "$ACME_PORT" == "443" ]]; then
				issue_args+=("--alpn")
			elif [[ "$ACME_PORT" != "80" ]]; then
				issue_args+=("--httpport" "$ACME_PORT")
			fi
			"$acme_cmd" "${issue_args[@]}"
		fi
	fi
	
	log "正在为域名 $DOMAIN 安装证书到配置目录..."
	"$acme_cmd" --install-cert -d "$DOMAIN" --ecc \
		--fullchain-file "${cert_dir}/certificate.pem" \
		--key-file "${cert_dir}/private-key.pem" \
		--reloadcmd "systemctl restart $SERVICE_NAME"
		
	chown root:"$SERVICE_NAME" "${cert_dir}/certificate.pem" "${cert_dir}/private-key.pem"
	chmod 0640 "${cert_dir}/certificate.pem" "${cert_dir}/private-key.pem"
	
	CERTIFICATE="${cert_dir}/certificate.pem"
	PRIVATE_KEY="${cert_dir}/private-key.pem"
}

setup_tls_certificates() {
	if [[ "$CONFIG_REUSED" == "true" ]]; then
		return
	fi

	if [[ "$TLS_MODE" == "manual" ]]; then
		install_manual_certificates
	elif [[ "$TLS_MODE" == "acme" || "$TLS_MODE" == "acme-dns" || "$TLS_MODE" == "acme-dns-manual" ]]; then
		issue_acme_cert
	fi
}

write_config() {
	local backup tls_config temp_config
	if [[ -e "$CONFIG_FILE" && "$FORCE_CONFIG" != "true" ]]; then
		log "保留现有配置文件: ${CONFIG_FILE}"
		CONFIG_REUSED="true"
		return
	fi

	if [[ -e "$CONFIG_FILE" ]]; then
		backup="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
		cp -a "$CONFIG_FILE" "$backup"
		log_success "已将现有配置备份至: ${backup}"
	fi

	case "$TLS_MODE" in
		self-signed)
			tls_config=$(cat <<EOF
self_sign = true
hostname = "$(toml_escape "$DOMAIN")"
alpn = ["h3"]
EOF
			)
			;;
		*)
			tls_config=$(cat <<EOF
self_sign = false
certificate = "$(toml_escape "$CERTIFICATE")"
private_key = "$(toml_escape "$PRIVATE_KEY")"
hostname = "$(toml_escape "$DOMAIN")"
alpn = ["h3"]
EOF
			)
			;;
	esac

	temp_config="$(mktemp "${CONFIG_DIR}/config.toml.XXXXXX")"
	cat >"$temp_config" <<EOF
# Generated by scripts/deploy-server.sh
log_level = "info"
server = "[::]:${PORT}"
data_dir = "${DATA_DIR}"
dual_stack = true
zero_rtt_handshake = false

[users]
"$(toml_escape "$TUIC_UUID")" = "$(toml_escape "$TUIC_PASSWORD")"

[tls]
${tls_config}

[quic]
initial_mtu = 1200
min_mtu = 1200
gso = true
pmtu = true
send_window = 16777216
receive_window = 8388608
max_idle_time = "30s"
max_concurrent_streams = 1280

[quic.congestion_control]
controller = "bbr"
initial_window = 1048576

[outbound.default]
type = "direct"
ip_mode = "v4first"

[experimental]
drop_loopback = true
drop_private = true
EOF

	chown root:"$SERVICE_NAME" "$temp_config"
	chmod 0640 "$temp_config"
	mv -f "$temp_config" "$CONFIG_FILE"
}

write_systemd_service() {
	cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=TUIC Proxy Server
Documentation=https://github.com/${REPOSITORY}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_NAME}
Group=${SERVICE_NAME}
ExecStart=${INSTALL_BIN} --config ${CONFIG_FILE}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${DATA_DIR}
UMask=0027

[Install]
WantedBy=multi-user.target
EOF

	chmod 0644 "$SERVICE_FILE"
	systemctl daemon-reload
	systemctl enable "$SERVICE_NAME"
	systemctl restart "$SERVICE_NAME"
}

configure_firewall() {
	[[ "$OPEN_FIREWALL" == "true" ]] || return
	if command -v ufw >/dev/null 2>&1; then
		ufw allow "${PORT}/udp"
		[[ "$TLS_MODE" != "acme" ]] || ufw allow "${ACME_PORT:-80}/tcp"
	elif command -v firewall-cmd >/dev/null 2>&1; then
		firewall-cmd --permanent --add-port="${PORT}/udp"
		[[ "$TLS_MODE" != "acme" ]] || firewall-cmd --permanent --add-port="${ACME_PORT:-80}/tcp"
		firewall-cmd --reload
	else
		log_warning "未检测到支持的防火墙管理器，请手动开放 UDP ${PORT} 端口"
	fi
}

wait_for_service() {
	local attempt
	for attempt in {1..10}; do
		if systemctl is-active --quiet "$SERVICE_NAME"; then
			return
		fi
		sleep 1
	done
	systemctl status "$SERVICE_NAME" --no-pager || true
	journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
	fail "service failed to become active"
}

print_result() {
	local insecure="false"
	[[ "$TLS_MODE" == "self-signed" ]] && insecure="true"
	if [[ "$CONFIG_REUSED" == "true" ]]; then
		cat <<EOF

${CLR_SUCCESS}✔ TUIC 服务升级并部署完成！${CLR_RESET}
========================================
现有配置已成功保留且程序已升级并启动。

  ${CLR_INFO}服务名称:${CLR_RESET}  ${SERVICE_NAME}
  ${CLR_INFO}配置文件:${CLR_RESET}  ${CONFIG_FILE}

${CLR_HEADER}管理命令:${CLR_RESET}
  查看服务状态:  ${CLR_SUCCESS}systemctl status ${SERVICE_NAME}${CLR_RESET}
  查看实时日志:  ${CLR_SUCCESS}journalctl -u ${SERVICE_NAME} -f${CLR_RESET}
========================================
EOF
		return
	fi

	cat <<EOF

${CLR_SUCCESS}✔ TUIC 服务端部署成功！${CLR_RESET}
========================================
  ${CLR_INFO}服务名称:${CLR_RESET}  ${SERVICE_NAME}
  ${CLR_INFO}服务地址:${CLR_RESET}  ${DOMAIN}:${PORT}/udp
  ${CLR_INFO}用户 UUID:${CLR_RESET} ${TUIC_UUID}
  ${CLR_INFO}用户密码:${CLR_RESET} ${TUIC_PASSWORD}
  ${CLR_INFO}TLS 模式:${CLR_RESET}  ${TLS_MODE}
  ${CLR_INFO}配置文件:${CLR_RESET}  ${CONFIG_FILE}

${CLR_HEADER}┌────────────────────────────────────────────────────────┐${CLR_RESET}
${CLR_HEADER}│                  客户端配置 (TOML)                     │${CLR_RESET}
${CLR_HEADER}├────────────────────────────────────────────────────────┤${CLR_RESET}
[relay]
server = "${DOMAIN}:${PORT}"
uuid = "${TUIC_UUID}"
password = "${TUIC_PASSWORD}"
udp_relay_mode = "native"
congestion_control = "bbr"
alpn = ["h3"]
skip_cert_verify = ${insecure}

[local]
server = "127.0.0.1:1080"
${CLR_HEADER}└────────────────────────────────────────────────────────┘${CLR_RESET}

${CLR_HEADER}管理命令:${CLR_RESET}
  查看服务状态:  ${CLR_SUCCESS}systemctl status ${SERVICE_NAME}${CLR_RESET}
  查看实时日志:  ${CLR_SUCCESS}journalctl -u ${SERVICE_NAME} -f${CLR_RESET}
========================================
EOF
}

main() {
	load_environment
	parse_arguments "$@"
	if [[ "$NON_INTERACTIVE" == "true" && -e "$CONFIG_FILE" && "$FORCE_CONFIG" != "true" ]]; then
		CONFIG_REUSED="true"
	fi

	print_step "1" "检测运行环境与系统依赖"
	require_root
	require_linux_systemd
	require_command curl
	require_command getent
	require_command groupadd
	require_command useradd
	require_command install
	require_command od
	log_success "运行环境检测通过"

	print_step "2" "配置部署参数"
	prompt_if_needed
	validate_inputs

	print_step "3" "申请与配置 TLS 证书"
	create_service_user
	generate_credentials
	setup_tls_certificates
	log_success "TLS 证书配置完成"

	print_step "4" "下载并安装 TUIC 程序与配置防火墙"
	download_binary
	configure_firewall
	write_config
	log_success "程序安装与配置参数写入成功"

	print_step "5" "启动并激活 systemd 服务"
	write_systemd_service
	wait_for_service
	log_success "服务已成功启动并拉起"

	print_result
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
	main "$@"
fi
