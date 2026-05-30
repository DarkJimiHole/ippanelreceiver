#!/usr/bin/env bash

set -Eeuo pipefail

APP_NAME="ippanelreceiver"
APP_VERSION="v0.1.0"
REPO_RAW_URL="https://raw.githubusercontent.com/DarkJimiHole/ippanelreceiver/main"
APP_DIR="/opt/${APP_NAME}"
CONFIG_DIR="/etc/${APP_NAME}"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
SHORTCUT_BIN="/usr/local/bin/${APP_NAME}"
PYTHON_BIN="/usr/bin/python3"
RECEIVER_FILE="${APP_DIR}/receiver.py"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET="\033[0m"
  C_RED="\033[31m"
  C_GREEN="\033[32m"
  C_YELLOW="\033[33m"
  C_BLUE="\033[34m"
  C_CYAN="\033[36m"
  C_BOLD="\033[1m"
else
  C_RESET=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_CYAN=""
  C_BOLD=""
fi

tag() {
  local color="$1"
  local name="$2"
  shift 2
  printf "%b[%s]%b %s\n" "$color" "$name" "$C_RESET" "$*"
}

info() { tag "$C_BLUE" "INFO" "$*"; }
ok() { tag "$C_GREEN" "OK" "$*"; }
warn() { tag "$C_YELLOW" "WARN" "$*"; }
err() { tag "$C_RED" "ERROR" "$*" >&2; }

prompt() {
  printf "%b[%s]%b %s" "$C_CYAN" "INPUT" "$C_RESET" "$*" >&2
  IFS= read -r REPLY
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf "%s" "$value"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ensure_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "Please run as root or with sudo."
    exit 1
  fi
}

download_file() {
  local url="$1"
  local output="$2"

  if have_cmd curl; then
    curl -fsSL "$url" -o "$output"
    return $?
  fi
  if have_cmd wget; then
    wget -qO "$output" "$url"
    return $?
  fi
  return 1
}

prompt_default() {
  local message="$1"
  local default="$2"
  local value=""

  prompt "${message} [${default}]: "
  value="$(trim "${REPLY:-}")"
  if [ -z "$value" ]; then
    value="$default"
  fi
  printf "%s" "$value"
}

prompt_yes_no() {
  local message="$1"
  local default="${2:-no}"
  local answer=""

  while true; do
    prompt "$message"
    answer="$(trim "${REPLY:-}")"
    answer="${answer,,}"
    if [ -z "$answer" ]; then
      [ "$default" = "yes" ] && return 0
      return 1
    fi
    case "$answer" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) err "Please enter yes or no." ;;
    esac
  done
}

generate_secret() {
  "$PYTHON_BIN" - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
}

json_escape() {
  "$PYTHON_BIN" -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

ensure_python() {
  if [ -x "$PYTHON_BIN" ]; then
    return 0
  fi
  if ! have_cmd apt-get; then
    err "python3 is missing and apt-get is unavailable."
    return 1
  fi
  info "Installing python3..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y python3
}

install_files() {
  local self=""

  ensure_python
  mkdir -p "$APP_DIR" "$CONFIG_DIR"
  chmod 755 "$APP_DIR"
  chmod 700 "$CONFIG_DIR"

  self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  if [ -f "$(dirname "$self")/receiver.py" ]; then
    install -m 0755 "$(dirname "$self")/receiver.py" "$RECEIVER_FILE"
  else
    download_file "${REPO_RAW_URL}/receiver.py" "$RECEIVER_FILE" || {
      err "Failed to download receiver.py."
      return 1
    }
    chmod 0755 "$RECEIVER_FILE"
  fi

  if [ -f "$self" ]; then
    install -m 0755 "$self" "$SHORTCUT_BIN"
  else
    download_file "${REPO_RAW_URL}/ippanelreceiver.sh" "$SHORTCUT_BIN" || {
      warn "Failed to install shortcut command."
      return 0
    }
    chmod 0755 "$SHORTCUT_BIN"
  fi
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=IPPanelReceiver
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${PYTHON_BIN} ${RECEIVER_FILE} --config ${CONFIG_FILE}
Restart=always
RestartSec=3
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SERVICE_FILE"
  systemctl daemon-reload
}

write_config_interactive() {
  local listen_host listen_port report_path nf_command reporter_id allowed_ip secret node_id remark allow_private
  local listen_host_json report_path_json nf_command_json reporter_id_json allowed_ip_json secret_json node_id_json remark_json

  listen_host="$(prompt_default "Receiver listen IP, usually this VPS WireGuard IP" "10.77.0.2")"
  listen_port="$(prompt_default "Receiver listen port" "8787")"
  report_path="$(prompt_default "Report path" "/report")"
  nf_command="$(prompt_default "nf command path" "/usr/local/sbin/nf")"
  reporter_id="$(prompt_default "Reporter id for ippanelbot" "bot-main")"
  allowed_ip="$(prompt_default "Allowed ippanelbot WireGuard IP or CIDR" "10.77.0.1")"

  prompt "Reporter secret, leave empty to generate: "
  secret="$(trim "${REPLY:-}")"
  if [ -z "$secret" ]; then
    secret="$(generate_secret)"
    ok "Generated reporter secret: ${secret}"
    warn "Save this secret for ippanelbot relay sync config."
  fi

  node_id="$(prompt_default "Node id" "hk-home")"
  remark="$(prompt_default "easynftables remark for node mode" "$node_id")"
  allow_private="false"
  if prompt_yes_no "Allow private target IPs? [y/N]: " "no"; then
    allow_private="true"
  fi

  listen_host_json="$(json_escape "$listen_host")"
  report_path_json="$(json_escape "$report_path")"
  nf_command_json="$(json_escape "$nf_command")"
  reporter_id_json="$(json_escape "$reporter_id")"
  allowed_ip_json="$(json_escape "$allowed_ip")"
  secret_json="$(json_escape "$secret")"
  node_id_json="$(json_escape "$node_id")"
  remark_json="$(json_escape "$remark")"

  cat > "$CONFIG_FILE" <<EOF
{
  "listen": {
    "host": ${listen_host_json},
    "port": ${listen_port},
    "path": ${report_path_json}
  },
  "max_body_bytes": 4096,
  "timestamp_window_seconds": 120,
  "nonce_ttl_seconds": 600,
  "nf_command": ${nf_command_json},
  "nf_timeout_seconds": 30,
  "allow_private_target_ips": ${allow_private},
  "reporters": {
    ${reporter_id_json}: {
      "allowed_ips": [${allowed_ip_json}],
      "secret": ${secret_json}
    }
  },
  "nodes": {
    ${node_id_json}: {
      "allowed_reporters": [${reporter_id_json}],
      "match_modes": ["node", "old_ip", "old_ip_unique"],
      "remark": ${remark_json}
    }
  }
}
EOF
  chmod 600 "$CONFIG_FILE"
  ok "Config saved: ${CONFIG_FILE}"
}

check_config() {
  "$PYTHON_BIN" "$RECEIVER_FILE" --config "$CONFIG_FILE" --check-config
}

install_app() {
  install_files
  if [ ! -f "$CONFIG_FILE" ]; then
    write_config_interactive
  else
    info "Keeping existing config: ${CONFIG_FILE}"
  fi
  write_service
  check_config
  systemctl enable "$APP_NAME" >/dev/null
  systemctl restart "$APP_NAME"
  ok "IPPanelReceiver installed and started."
}

configure_app() {
  install_files
  if [ -f "$CONFIG_FILE" ]; then
    warn "This will overwrite the current config."
    if ! prompt_yes_no "Continue? [y/N]: " "no"; then
      warn "Canceled."
      return 0
    fi
  fi
  write_config_interactive
  write_service
  check_config
  if systemctl is-enabled --quiet "$APP_NAME" 2>/dev/null; then
    systemctl restart "$APP_NAME"
    ok "Service restarted."
  fi
}

show_status() {
  systemctl status "$APP_NAME" --no-pager || true
}

show_logs() {
  journalctl -u "$APP_NAME" -n 80 --no-pager || true
}

uninstall_app() {
  warn "This removes IPPanelReceiver service, files, and config."
  if ! prompt_yes_no "Continue? [y/N]: " "no"; then
    warn "Canceled."
    return 0
  fi
  systemctl stop "$APP_NAME" >/dev/null 2>&1 || true
  systemctl disable "$APP_NAME" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$SHORTCUT_BIN"
  rm -rf "$APP_DIR" "$CONFIG_DIR"
  systemctl daemon-reload >/dev/null 2>&1 || true
  ok "Uninstalled."
}

print_header() {
  echo ""
  echo "$(printf "%bIPPanelReceiver %s%b" "$C_BOLD$C_CYAN" "$APP_VERSION" "$C_RESET")"
  echo "WireGuard-side receiver for ippanelbot relay sync"
}

print_menu() {
  echo ""
  echo "1. Install or update"
  echo "2. Reconfigure"
  echo "3. Check config"
  echo "4. Start"
  echo "5. Stop"
  echo "6. Restart"
  echo "7. Status"
  echo "8. Logs"
  echo "9. Uninstall"
  echo "0. Exit"
}

main_menu() {
  local choice
  while true; do
    print_header
    print_menu
    prompt "Choose [0-9]: "
    choice="$(trim "${REPLY:-}")"
    case "$choice" in
      1) install_app ;;
      2) configure_app ;;
      3) check_config ;;
      4) systemctl start "$APP_NAME"; ok "Started." ;;
      5) systemctl stop "$APP_NAME"; ok "Stopped." ;;
      6) systemctl restart "$APP_NAME"; ok "Restarted." ;;
      7) show_status ;;
      8) show_logs ;;
      9) uninstall_app ;;
      0) exit 0 ;;
      *) err "Invalid choice." ;;
    esac
    echo ""
    prompt "Press Enter to continue..."
  done
}

main() {
  ensure_root
  case "${1:-}" in
    install|--install) install_app ;;
    configure|config|--configure) configure_app ;;
    check|--check-config) check_config ;;
    start) systemctl start "$APP_NAME" ;;
    stop) systemctl stop "$APP_NAME" ;;
    restart) systemctl restart "$APP_NAME" ;;
    status) show_status ;;
    logs) show_logs ;;
    uninstall|--uninstall) uninstall_app ;;
    ""|menu) main_menu ;;
    *)
      err "Unknown command: $1"
      echo "Usage: $0 [install|configure|check|start|stop|restart|status|logs|uninstall]"
      exit 1
      ;;
  esac
}

main "$@"
