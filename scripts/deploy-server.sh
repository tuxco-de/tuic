#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPOSITORY="Itsusinn/tuic"
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
ACME_EMAIL=""
CERTIFICATE=""
PRIVATE_KEY=""
TUIC_UUID=""
TUIC_PASSWORD=""
OPEN_FIREWALL="false"
FORCE_CONFIG="false"
NON_INTERACTIVE="false"
CONFIG_REUSED="false"

log() {
	printf '[tuic-deploy] %s\n' "$*"
}

fail() {
	printf '[tuic-deploy] ERROR: %s\n' "$*" >&2
	exit 1
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
  --tls MODE                acme, self-signed, or manual (default: acme).
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
  TUIC_DOMAIN, TUIC_PORT, TUIC_TLS_MODE, TUIC_ACME_EMAIL,
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
	ACME_EMAIL="${TUIC_ACME_EMAIL:-$ACME_EMAIL}"
	CERTIFICATE="${TUIC_CERTIFICATE:-$CERTIFICATE}"
	PRIVATE_KEY="${TUIC_PRIVATE_KEY:-$PRIVATE_KEY}"
	TUIC_UUID="${TUIC_UUID:-$TUIC_UUID}"
	TUIC_PASSWORD="${TUIC_PASSWORD:-$TUIC_PASSWORD}"
	VERSION="${TUIC_VERSION:-$VERSION}"
	OPEN_FIREWALL="$(parse_bool "${TUIC_OPEN_FIREWALL:-$OPEN_FIREWALL}")"
	FORCE_CONFIG="$(parse_bool "${TUIC_FORCE_CONFIG:-$FORCE_CONFIG}")"
}

parse_arguments() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--domain) DOMAIN="${2:?missing value for --domain}"; shift 2 ;;
			--port) PORT="${2:?missing value for --port}"; shift 2 ;;
			--tls) TLS_MODE="${2:?missing value for --tls}"; shift 2 ;;
			--email) ACME_EMAIL="${2:?missing value for --email}"; shift 2 ;;
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
	local variable="$1" label="$2" default_value="$3" required="${4:-false}" value
	while true; do
		if [[ -n "$default_value" ]]; then
			printf '%s [%s]: ' "$label" "$default_value" >/dev/tty
		else
			printf '%s: ' "$label" >/dev/tty
		fi
		read_tty value
		value="${value:-$default_value}"
		if [[ "$required" != "true" || -n "$value" ]]; then
			printf -v "$variable" '%s' "$value"
			return
		fi
		printf '该项不能为空。\n' >/dev/tty
	done
}

prompt_secret() {
	local variable="$1" label="$2" current_value value
	current_value="${!variable}"
	if [[ -n "$current_value" ]]; then
		printf '%s（已预设，留空则保留）: ' "$label" >/dev/tty
	else
		printf '%s（留空则自动生成）: ' "$label" >/dev/tty
	fi
	IFS= read -r -s value </dev/tty
	printf '\n' >/dev/tty
	[[ -n "$value" ]] || value="$current_value"
	printf -v "$variable" '%s' "$value"
}

prompt_yes_no() {
	local label="$1" default_value="$2" answer suffix
	if [[ "$default_value" == "true" ]]; then
		suffix="Y/n"
	else
		suffix="y/N"
	fi
	while true; do
		printf '%s [%s]: ' "$label" "$suffix" >/dev/tty
		read_tty answer
		case "${answer,,}" in
			y | yes) return 0 ;;
			n | no) return 1 ;;
			'') [[ "$default_value" == "true" ]] && return 0 || return 1 ;;
			*) printf '请输入 y 或 n。\n' >/dev/tty ;;
		esac
	done
}

select_tls_mode() {
	local selection default_selection
	case "${TLS_MODE,,}" in
		acme) default_selection="1" ;;
		self-signed) default_selection="2" ;;
		manual) default_selection="3" ;;
		*) default_selection="1" ;;
	esac

	cat >/dev/tty <<'EOF'

请选择 TLS 证书方式：
  1) ACME 自动申请（推荐，需域名解析到本机并开放 TCP 80）
  2) 自动生成自签名证书（仅建议测试）
  3) 使用已有证书文件
EOF
	while true; do
		printf '选择 [%s]: ' "$default_selection" >/dev/tty
		read_tty selection
		case "${selection:-$default_selection}" in
			1) TLS_MODE="acme"; return ;;
			2) TLS_MODE="self-signed"; return ;;
			3) TLS_MODE="manual"; return ;;
			*) printf '请输入 1、2 或 3。\n' >/dev/tty ;;
		esac
	done
}

show_deployment_summary() {
	if [[ "$CONFIG_REUSED" == "true" ]]; then
		cat >/dev/tty <<EOF

部署配置确认
----------------------------------------
版本:       ${VERSION}
现有配置:   保留 ${CONFIG_FILE}
操作:       仅升级程序并重启 systemd 服务
----------------------------------------
EOF
		return
	fi
	cat >/dev/tty <<EOF

部署配置确认
----------------------------------------
版本:       ${VERSION}
监听地址:   [::]:${PORT}/udp
TLS 模式:   ${TLS_MODE}
主机名:     ${DOMAIN}
开放防火墙: ${OPEN_FIREWALL}
替换配置:   ${FORCE_CONFIG}
EOF
	cat >/dev/tty <<EOF
UUID:       ${TUIC_UUID}
密码:       ${TUIC_PASSWORD}
EOF
	printf '%s\n' '----------------------------------------' >/dev/tty
}

run_wizard() {
	[[ -r /dev/tty && -w /dev/tty ]] || fail "interactive terminal not available; use --non-interactive with complete options"
	cat >/dev/tty <<'EOF'

TUIC 服务端引导式部署
========================================
脚本将安装预编译服务端、生成配置并创建 systemd 服务。
按 Enter 可接受方括号中的默认值。
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
				prompt_value DOMAIN "证书域名" "$DOMAIN" true
				prompt_value ACME_EMAIL "ACME 邮箱（可留空）" "$ACME_EMAIL" false
				;;
			self-signed)
				prompt_value DOMAIN "证书主机名或服务器 IP" "${DOMAIN:-localhost}" true
				;;
			manual)
				prompt_value DOMAIN "证书对应域名" "$DOMAIN" true
				prompt_value CERTIFICATE "证书文件路径" "$CERTIFICATE" true
				prompt_value PRIVATE_KEY "私钥文件路径" "$PRIVATE_KEY" true
				;;
		esac

		prompt_value PORT "TUIC UDP 监听端口" "$PORT" true
		prompt_value TUIC_UUID "用户 UUID（留空则自动生成）" "$TUIC_UUID" false
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
		log "deployment cancelled"
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
			;;
		self-signed)
			DOMAIN="${DOMAIN:-localhost}"
			;;
		manual)
			[[ -n "$DOMAIN" ]] || fail "--domain is required for manual TLS mode"
			[[ -f "$CERTIFICATE" ]] || fail "certificate file not found: $CERTIFICATE"
			[[ -f "$PRIVATE_KEY" ]] || fail "private key file not found: $PRIVATE_KEY"
			;;
		*) fail "TLS mode must be acme, self-signed, or manual" ;;
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
	local asset url temporary
	asset="$(detect_asset)"
	if [[ "$VERSION" == "latest" ]]; then
		url="https://github.com/${REPOSITORY}/releases/latest/download/${asset}"
	else
		[[ "$VERSION" == v* ]] || VERSION="v${VERSION}"
		url="https://github.com/${REPOSITORY}/releases/download/${VERSION}/${asset}"
	fi

	temporary="$(mktemp)"
	trap "rm -f '$temporary'" EXIT
	log "downloading ${asset} (${VERSION})"
	curl --fail --location --retry 3 --connect-timeout 15 --output "$temporary" "$url"
	chmod 0755 "$temporary"
	"$temporary" --version >/dev/null
	install -m 0755 "$temporary" "$INSTALL_BIN"
	trap - EXIT
	rm -f "$temporary"
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

write_config() {
	local backup tls_config temp_config
	if [[ -e "$CONFIG_FILE" && "$FORCE_CONFIG" != "true" ]]; then
		log "keeping existing configuration: ${CONFIG_FILE}"
		CONFIG_REUSED="true"
		return
	fi

	if [[ -e "$CONFIG_FILE" ]]; then
		backup="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
		cp -a "$CONFIG_FILE" "$backup"
		log "backed up existing configuration to ${backup}"
	fi

	if [[ "$TLS_MODE" == "manual" ]]; then
		install_manual_certificates
	fi

	case "$TLS_MODE" in
		acme)
			tls_config=$(cat <<EOF
self_sign = false
auto_ssl = true
hostname = "$(toml_escape "$DOMAIN")"
acme_email = "$(toml_escape "$ACME_EMAIL")"
alpn = ["h3"]
EOF
			)
			;;
		self-signed)
			tls_config=$(cat <<EOF
self_sign = true
auto_ssl = false
hostname = "$(toml_escape "$DOMAIN")"
alpn = ["h3"]
EOF
			)
			;;
		manual)
			tls_config=$(cat <<EOF
self_sign = false
auto_ssl = false
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
		[[ "$TLS_MODE" != "acme" ]] || ufw allow "80/tcp"
	elif command -v firewall-cmd >/dev/null 2>&1; then
		firewall-cmd --permanent --add-port="${PORT}/udp"
		[[ "$TLS_MODE" != "acme" ]] || firewall-cmd --permanent --add-port="80/tcp"
		firewall-cmd --reload
	else
		log "no supported firewall manager found; open UDP ${PORT} manually"
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

TUIC server binary and systemd service were updated.
The existing configuration was preserved:

  Service: ${SERVICE_NAME}
  Config:  ${CONFIG_FILE}

Commands:
  systemctl status ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -f
EOF
		return
	fi
	cat <<EOF

TUIC server deployment completed.

  Service:  ${SERVICE_NAME}
  Endpoint: ${DOMAIN}:${PORT}/udp
  UUID:     ${TUIC_UUID}
  Password: ${TUIC_PASSWORD}
  TLS mode: ${TLS_MODE}
  Config:   ${CONFIG_FILE}

Client configuration:

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

Commands:
  systemctl status ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -f
EOF
}

main() {
	load_environment
	parse_arguments "$@"
	if [[ "$NON_INTERACTIVE" == "true" && -e "$CONFIG_FILE" && "$FORCE_CONFIG" != "true" ]]; then
		CONFIG_REUSED="true"
	fi
	require_root
	require_linux_systemd
	require_command curl
	require_command getent
	require_command groupadd
	require_command useradd
	require_command install
	require_command od
	prompt_if_needed
	validate_inputs

	create_service_user
	generate_credentials
	download_binary
	write_config
	write_systemd_service
	configure_firewall
	wait_for_service
	print_result
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
	main "$@"
fi
