#!/usr/bin/env bash

set -Eeuo pipefail

APP_NAME="ippanelreceiver"
APP_VERSION="v0.1.0"
REPO_RAW_URL="https://raw.githubusercontent.com/DarkJimiHole/ippanelreceiver/refs/heads/main"
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

info() { tag "$C_BLUE" "信息" "$*"; }
ok() { tag "$C_GREEN" "完成" "$*"; }
warn() { tag "$C_YELLOW" "警告" "$*"; }
err() { tag "$C_RED" "错误" "$*" >&2; }

prompt() {
  printf "%b[%s]%b %s" "$C_CYAN" "输入" "$C_RESET" "$*" >&2
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
    err "请使用 root 或 sudo 运行。"
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

prompt_required() {
  local message="$1"
  local value=""

  while true; do
    prompt "${message}: "
    value="$(trim "${REPLY:-}")"
    if [ -n "$value" ]; then
      printf "%s" "$value"
      return 0
    fi
    err "该项不能为空。"
  done
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
      y|yes|是) return 0 ;;
      n|no|否) return 1 ;;
      *) err "请输入 yes/no 或 y/n。" ;;
    esac
  done
}

generate_secret() {
  "$PYTHON_BIN" - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
}

generate_report_path() {
  "$PYTHON_BIN" - <<'PY'
import secrets
print("/report-" + secrets.token_urlsafe(12).replace("_", "-"))
PY
}

json_escape() {
  "$PYTHON_BIN" -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

config_value() {
  local key="$1"
  local default="${2:-}"
  "$PYTHON_BIN" - "$CONFIG_FILE" "$key" "$default" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
default = sys.argv[3]
try:
    value = json.loads(path.read_text(encoding="utf-8"))
    for part in key.split("."):
        if isinstance(value, dict):
            value = value.get(part)
        else:
            value = None
        if value is None:
            print(default)
            raise SystemExit(0)
    if isinstance(value, (dict, list)):
        print(json.dumps(value, ensure_ascii=False))
    else:
        print(value)
except Exception:
    print(default)
PY
}

is_installed() {
  [ -f "$RECEIVER_FILE" ] && [ -f "$CONFIG_FILE" ] && [ -f "$SERVICE_FILE" ]
}

has_install_files() {
  [ -e "$RECEIVER_FILE" ] || [ -e "$CONFIG_FILE" ] || [ -e "$SERVICE_FILE" ] || \
    [ -e "$SHORTCUT_BIN" ] || [ -d "$APP_DIR" ] || [ -d "$CONFIG_DIR" ]
}

require_installed() {
  if is_installed; then
    return 0
  fi
  warn "当前未安装，请先选择 1 安装或执行：sudo ippanelreceiver install"
  return 1
}

ensure_python() {
  if [ -x "$PYTHON_BIN" ]; then
    return 0
  fi
  if ! have_cmd apt-get; then
    err "缺少 python3，且系统没有 apt-get，无法自动安装。"
    return 1
  fi
  info "正在安装 python3..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y python3
}

install_files() {
  local self="" shortcut_real="" tmp_shortcut=""

  ensure_python
  mkdir -p "$APP_DIR" "$CONFIG_DIR"
  chmod 755 "$APP_DIR"
  chmod 700 "$CONFIG_DIR"

  self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  if [ -f "$(dirname "$self")/receiver.py" ]; then
    install -m 0755 "$(dirname "$self")/receiver.py" "$RECEIVER_FILE"
  else
    download_file "${REPO_RAW_URL}/receiver.py" "$RECEIVER_FILE" || {
      err "下载 receiver.py 失败。"
      return 1
    }
    chmod 0755 "$RECEIVER_FILE"
  fi

  shortcut_real="$(readlink -f "$SHORTCUT_BIN" 2>/dev/null || echo "$SHORTCUT_BIN")"
  if [ -f "$self" ] && [ "$self" != "$shortcut_real" ]; then
    install -m 0755 "$self" "$SHORTCUT_BIN"
  else
    tmp_shortcut="$(mktemp)"
    if download_file "${REPO_RAW_URL}/ippanelreceiver.sh" "$tmp_shortcut"; then
      install -m 0755 "$tmp_shortcut" "$SHORTCUT_BIN"
      rm -f "$tmp_shortcut"
    else
      rm -f "$tmp_shortcut"
      if [ -f "$SHORTCUT_BIN" ]; then
        warn "快捷命令更新失败，已保留现有文件。"
      else
        warn "安装快捷命令失败。"
      fi
      return 0
    }
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
  local listen_host listen_port report_path nf_command reporter_id allowed_ip secret target_name remark allow_private
  local listen_host_json report_path_json nf_command_json reporter_id_json allowed_ip_json secret_json target_name_json remark_json

  listen_host="$(prompt_required "监听 IP")"
  listen_port="$(prompt_default "监听端口" "8787")"
  report_path="$(prompt_default "上报路径" "$(generate_report_path)")"
  nf_command="/usr/local/sbin/nf"
  reporter_id="$(prompt_required "ippanelbot 上报方 ID（自定义名称，用于区分不同 bot）")"
  allowed_ip="$(prompt_default "允许上报的 ippanelbot 来源 IP 或 CIDR" "10.77.0.1")"

  prompt "上报密钥，留空则自动生成: "
  secret="$(trim "${REPLY:-}")"
  if [ -z "$secret" ]; then
    secret="$(generate_secret)"
    ok "已生成上报密钥: ${secret}"
    warn "请保存这个密钥，后续配置 ippanelbot 中转同步时需要使用。"
  fi

  target_name="$(prompt_default "目标名称 target_name" "target1")"
  remark="$(prompt_required "easynftables 备注 remark")"
  allow_private="false"
  if prompt_yes_no "是否允许转发目标为私有 IP？[y/N]: " "no"; then
    allow_private="true"
  fi

  listen_host_json="$(json_escape "$listen_host")"
  report_path_json="$(json_escape "$report_path")"
  nf_command_json="$(json_escape "$nf_command")"
  reporter_id_json="$(json_escape "$reporter_id")"
  allowed_ip_json="$(json_escape "$allowed_ip")"
  secret_json="$(json_escape "$secret")"
  target_name_json="$(json_escape "$target_name")"
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
  "targets": {
    ${target_name_json}: {
      "allowed_reporters": [${reporter_id_json}],
      "match_modes": ["remark", "old_ip", "old_ip_unique"],
      "remark": ${remark_json}
    }
  }
}
EOF
  chmod 600 "$CONFIG_FILE"
  ok "配置已保存: ${CONFIG_FILE}"
  ok "上报路径: ${report_path}"
}

validate_config() {
  local output=""

  require_installed || return 1

  if output="$("$PYTHON_BIN" "$RECEIVER_FILE" --config "$CONFIG_FILE" --check-config 2>&1)"; then
    ok "配置已验证。"
    return 0
  fi

  err "配置验证失败："
  printf "%s\n" "$output" >&2
  return 1
}

install_app() {
  install_files
  if [ ! -f "$CONFIG_FILE" ]; then
    write_config_interactive
  else
    info "保留现有配置: ${CONFIG_FILE}"
  fi
  write_service
  validate_config
  systemctl enable "$APP_NAME" >/dev/null
  systemctl restart "$APP_NAME"
  ok "IPPanelReceiver 已安装并启动。"
}

start_app() {
  require_installed || return 1
  systemctl start "$APP_NAME"
  ok "已启动。"
}

stop_app() {
  require_installed || return 1
  systemctl stop "$APP_NAME"
  ok "已停止。"
}

restart_app() {
  require_installed || return 1
  systemctl restart "$APP_NAME"
  ok "已重启。"
}

show_status() {
  require_installed || return 1
  systemctl status "$APP_NAME" --no-pager || true
}

show_logs() {
  require_installed || return 1
  journalctl -u "$APP_NAME" -n 80 --no-pager || true
}

show_config() {
  require_installed || return 1

  "$PYTHON_BIN" - "$CONFIG_FILE" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    config = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"读取配置失败：{exc}", file=sys.stderr)
    raise SystemExit(1)
for reporter in config.get("reporters", {}).values():
    if isinstance(reporter, dict) and "secret" in reporter:
        reporter["secret"] = "********"
print(json.dumps(config, ensure_ascii=False, indent=2))
PY
}

after_config_change() {
  chmod 600 "$CONFIG_FILE"
  validate_config || return 1
  if systemctl is-active --quiet "$APP_NAME"; then
    if prompt_yes_no "现在重启服务使配置生效？[Y/n]: " "yes"; then
      restart_app
    else
      warn "配置已保存，服务尚未重启。"
    fi
  fi
}

show_report_info() {
  require_installed || return 1
  local listen_host listen_port report_path
  listen_host="$(config_value listen.host "")"
  listen_port="$(config_value listen.port "8787")"
  report_path="$(config_value listen.path "/report")"
  ok "当前上报路径: ${report_path}"
  info "监听地址: ${listen_host}:${listen_port}"
  info "ippanelbot 里的 Receiver 上报地址应填写: http://中转VPS可访问IP:${listen_port}${report_path}"
}

configure_listen() {
  require_installed || return 1
  local listen_host listen_port report_path default_path

  listen_host="$(prompt_default "监听 IP" "$(config_value listen.host "")")"
  listen_port="$(prompt_default "监听端口" "$(config_value listen.port "8787")")"
  default_path="$(config_value listen.path "/report")"
  if prompt_yes_no "是否生成新的随机上报路径？[y/N]: " "no"; then
    default_path="$(generate_report_path)"
  fi
  report_path="$(prompt_default "上报路径" "$default_path")"

  "$PYTHON_BIN" - "$CONFIG_FILE" "$listen_host" "$listen_port" "$report_path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
host = sys.argv[2].strip()
port = int(sys.argv[3])
report_path = sys.argv[4].strip()
if not report_path.startswith("/"):
    report_path = "/" + report_path
config = json.loads(path.read_text(encoding="utf-8"))
listen = config.setdefault("listen", {})
listen["host"] = host
listen["port"] = port
listen["path"] = report_path
path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(report_path)
PY
  ok "监听配置已保存。"
  show_report_info
  after_config_change
}

upsert_reporter() {
  require_installed || return 1
  local reporter_id allowed_ip secret generated

  reporter_id="$(prompt_required "上报方 ID reporter")"
  allowed_ip="$(prompt_required "允许来源 IP 或 CIDR")"
  prompt "上报密钥，留空则新建时自动生成、修改时保留原密钥: "
  secret="$(trim "${REPLY:-}")"

  generated="$("$PYTHON_BIN" - "$CONFIG_FILE" "$reporter_id" "$allowed_ip" "$secret" <<'PY'
import json
import secrets
import sys
from pathlib import Path

path = Path(sys.argv[1])
reporter_id = sys.argv[2].strip()
allowed_ip = sys.argv[3].strip()
secret = sys.argv[4].strip()
config = json.loads(path.read_text(encoding="utf-8"))
reporters = config.setdefault("reporters", {})
existing = reporters.get(reporter_id, {}) if isinstance(reporters.get(reporter_id), dict) else {}
generated = ""
if not secret:
    secret = str(existing.get("secret") or "")
if not secret:
    secret = secrets.token_urlsafe(32)
    generated = secret
reporters[reporter_id] = {"allowed_ips": [allowed_ip], "secret": secret}
path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(generated)
PY
)"
  ok "上报方已保存: ${reporter_id}"
  if [ -n "$generated" ]; then
    ok "已生成上报密钥: ${generated}"
    warn "请保存这个密钥，配置 ippanelbot 中转同步时需要使用。"
  fi
  after_config_change
}

upsert_target() {
  require_installed || return 1
  local target_name allowed_reporters remark

  target_name="$(prompt_required "目标名称 target_name")"
  allowed_reporters="$(prompt_required "允许的上报方 ID，多个用英文逗号分隔")"
  remark="$(prompt_required "easynftables 备注 remark")"

  "$PYTHON_BIN" - "$CONFIG_FILE" "$target_name" "$allowed_reporters" "$remark" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
target_name = sys.argv[2].strip()
allowed_reporters = [item.strip() for item in sys.argv[3].split(",") if item.strip()]
remark = sys.argv[4].strip()
if not allowed_reporters:
    print("allowed_reporters 不能为空", file=sys.stderr)
    raise SystemExit(1)
config = json.loads(path.read_text(encoding="utf-8"))
targets = config.setdefault("targets", {})
targets[target_name] = {
    "allowed_reporters": allowed_reporters,
    "match_modes": ["remark", "old_ip", "old_ip_unique"],
    "remark": remark,
}
path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
  ok "目标已保存: ${target_name}"
  after_config_change
}

uninstall_app() {
  if ! has_install_files; then
    warn "当前未安装，无需卸载。"
    return 1
  fi

  warn "该操作会删除 IPPanelReceiver 服务、程序文件和配置。"
  if ! prompt_yes_no "是否继续？[y/N]: " "no"; then
    warn "已取消。"
    return 0
  fi
  systemctl stop "$APP_NAME" >/dev/null 2>&1 || true
  systemctl disable "$APP_NAME" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$SHORTCUT_BIN"
  rm -rf "$APP_DIR" "$CONFIG_DIR"
  systemctl daemon-reload >/dev/null 2>&1 || true
  ok "卸载完成。"
}

print_header() {
  echo ""
  echo "$(printf "%bIPPanelReceiver %s%b" "$C_BOLD$C_CYAN" "$APP_VERSION" "$C_RESET")"
  echo "用于接收 ippanelbot 上报并更新 easynftables 转发目标"
}

print_menu() {
  echo ""
  echo "1. 安装或更新"
  echo "2. 查看配置"
  echo "3. 查看上报信息"
  echo "4. 修改监听和上报路径"
  echo "5. 添加或修改上报方"
  echo "6. 添加或修改目标"
  echo "7. 启动"
  echo "8. 停止"
  echo "9. 重启"
  echo "10. 查看状态"
  echo "11. 查看日志"
  echo "12. 卸载"
  echo "0. 退出"
}

main_menu() {
  local choice
  while true; do
    print_header
    print_menu
    prompt "请选择 [0-12]: "
    choice="$(trim "${REPLY:-}")"
    case "$choice" in
      1) install_app ;;
      2) show_config ;;
      3) show_report_info ;;
      4) configure_listen ;;
      5) upsert_reporter ;;
      6) upsert_target ;;
      7) start_app ;;
      8) stop_app ;;
      9) restart_app ;;
      10) show_status ;;
      11) show_logs ;;
      12) uninstall_app ;;
      0) exit 0 ;;
      *) err "无效选项。" ;;
    esac
    echo ""
    prompt "按回车继续..."
  done
}

main() {
  ensure_root
  case "${1:-}" in
    install|--install) install_app ;;
    config|show-config|view-config) show_config ;;
    report|report-info) show_report_info ;;
    listen|path|set-path) configure_listen ;;
    reporter|set-reporter) upsert_reporter ;;
    target|set-target) upsert_target ;;
    start) start_app ;;
    stop) stop_app ;;
    restart) restart_app ;;
    status) show_status ;;
    logs) show_logs ;;
    uninstall|--uninstall) uninstall_app ;;
    ""|menu) main_menu ;;
    *)
      err "未知命令: $1"
      echo "用法: $0 [install|config|report|listen|reporter|target|start|stop|restart|status|logs|uninstall]"
      exit 1
      ;;
  esac
}

main "$@"
