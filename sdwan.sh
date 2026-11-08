#!/usr/bin/env bash
# [KKIX-PATCH] 基于原版 beta-flag-2024-10 的最小补丁版：源码设计、菜单与交互完全保留，
# 仅增强「重启自动恢复」四处（diff 原版即见）：
#   1) 内地恢复脚本：等内网口就绪（<=60s）、等香港可达最长 120s 再决定默认路由
#   2) 内地看门狗：香港恢复可达后自动切回香港路由（原版只切走、不切回）
#   3) 恢复/看门狗的外网网关：优先读原始路由快照 ~/.true_original_default_route 的真实网关
#   4) 香港恢复脚本：等内外网口都就绪（<=60s）再执行
#   5) 修复原版 bug：香港恢复脚本生成内容里有一段空 if，导致其语法错误、开机从未真正运行
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin

# ==================== 全局变量定义 ====================
CONFIG_FILE="/root/.kkix_config"
CONFIG_LOADED=0
STATE_DIR="/root/.kkix_state"
HK_PROXY_FLAG="$STATE_DIR/hk_proxy_ready"
HK_ROUTE_FLAG="$STATE_DIR/hk_route_ready"
HK_ROUTE_META="$STATE_DIR/hk_route_flag"
REMOTE_ROUTE_FLAG="/etc/kkix_route_flag"
REMOTE_DIRECT_FLAG="/etc/kkix_direct_flag"
SCRIPT_VERSION="beta-flag-2024-10"
LAST_ACTION_LOG="$STATE_DIR/last_action.log"

MICROSOCKS_PORT=1080
MICROSOCKS_CHAIN="MICROSOCKS"
MICROSOCKS_SERVICE="/etc/systemd/system/microsocks.service"
NSPROXY_URL="https://github.com/nlzy/nsproxy/releases/download/v0.2.0/nsproxy_x86_64-linux-musl"
NSPROXY_REMOTE_PATH="/usr/local/bin/nsproxy"

# 路由模式相关变量
ROUTE_TABLE_NAME="ix_return"
ROUTE_TABLE_ID="100"
ROUTE_MARK="100"
AUTO_UPGRADE_STATE_FILE="/etc/qh_auto_upgrade_state"

# 状态变量
BASIC_INFO_READY=0
REMOTE_INFO_READY=0
APT_UPDATED=0
REMOTE_KEY_TEMP=""
PASS_FILE=""
GLOBAL_PASS_VAR=""
WORK_MODE=""  # proxy、route 或 violent
SB_MODE=0

# IP配置变量
HK_LAN_IP=""
QIANHAI_LAN_IP=""

# 香港端网卡配置（路由模式）
HK_EXTERNAL_IF=""  # 外网接口
HK_INTERNAL_IF=""  # 内网接口
HK_EXTERNAL_IP=""  # 外网IP
HK_EXTERNAL_GW=""  # 外网网关
HK_INTERNAL_NETWORK=""  # 内网网段

# 中国内地端网卡配置（路由模式）
QH_EXTERNAL_IF=""  # 外网接口
QH_INTERNAL_IF=""  # 内网接口
QH_EXTERNAL_IP=""  # 外网IP
QH_EXTERNAL_GW=""  # 外网网关
QH_EXTERNAL_FAMILY=""  # 外网IP族 (4/6)
CURRENT_QH_INT_GW=""

# SSH连接变量
REMOTE_USER=""
REMOTE_PORT=""
REMOTE_AUTH=""
REMOTE_PASS=""
REMOTE_KEY=""
REMOTE_DEST=""
REMOTE_SUDO="sudo"

SSH_BASE=()
SCP_BASE=()

# ==================== 基础功能函数 ====================
err()  { echo "错误: $*" >&2; }
info() { echo "[INFO] $*" >&2; }
warn() { echo "[WARN] $*" >&2; }

load_saved_config() {
  if [[ $CONFIG_LOADED -eq 1 ]]; then
    return
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
  CONFIG_LOADED=1
}

# ========== 规则清理辅助 ==========
clean_local_legacy_rules() {
  # nft/iptables 旧表/链
  nft delete table ip hk_snat >/dev/null 2>&1 || true
  nft delete table inet qh_mark >/dev/null 2>&1 || true
  nft delete table inet kkix_direct >/dev/null 2>&1 || true
  iptables -t nat -F hk_snat 2>/dev/null || true
  iptables -t nat -X hk_snat 2>/dev/null || true
  iptables -t mangle -D PREROUTING -i "$QH_EXTERNAL_IF" -j CONNMARK --set-mark "$ROUTE_MARK" 2>/dev/null || true
  iptables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null || true
}

clean_remote_legacy_rules() {
  ensure_remote_context || return 1
  remote_sudo "nft delete table ip hk_snat >/dev/null 2>&1 || true"
  remote_sudo "nft delete table inet qh_mark >/dev/null 2>&1 || true"
  remote_sudo "nft delete table inet kkix_direct >/dev/null 2>&1 || true"
  remote_sudo "iptables -t nat -F hk_snat 2>/dev/null || true"
  remote_sudo "iptables -t nat -X hk_snat 2>/dev/null || true"
  remote_sudo "iptables -t mangle -D PREROUTING -i $QH_EXTERNAL_IF -j CONNMARK --set-mark $ROUTE_MARK 2>/dev/null || true"
  remote_sudo "iptables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null || true"
  remote_sudo "if command -v ip6tables >/dev/null 2>&1; then ip6tables -t mangle -D PREROUTING -i $QH_EXTERNAL_IF -j CONNMARK --set-mark $ROUTE_MARK 2>/dev/null || true; ip6tables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null || true; fi"
  remote_sudo "ip rule del fwmark 200 table kkix_direct_rt 2>/dev/null || true"
  remote_sudo "ip rule del table kkix_direct_rt 2>/dev/null || true"
  remote_sudo "ip route flush table kkix_direct_rt 2>/dev/null || true"
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
}

mark_action() {
  ensure_state_dir
  local tag="$1"; shift || true
  local msg="$*"
  echo "$(date -Iseconds) [$tag] ${msg}" >> "$LAST_ACTION_LOG"
}

write_local_flag() {
  ensure_state_dir
  local file="$1"; shift
  mkdir -p "$(dirname "$file")"
  {
    echo "version=$SCRIPT_VERSION"
    echo "updated=$(date -Iseconds)"
    while (($#)); do
      echo "$1"
      shift
    done
  } >"$file"
}

write_remote_flag() {
  local file="$1"; shift
  local lines=("$@")
  local heredoc_content="version=$SCRIPT_VERSION
updated=\$(date -Iseconds)"
  local line
  for line in "${lines[@]}"; do
    heredoc_content="$heredoc_content
$line"
  done
  remote_sudo "cat > $file <<'EOF'
$heredoc_content
EOF"
}

clear_remote_flag() {
  local file="$1"
  remote_sudo "rm -f $file"
}

mark_state_flag() {
  ensure_state_dir
  touch "$1"
}

clear_state_flag() {
  rm -f "$1"
}

is_hk_proxy_ready() {
  if [[ -f "$HK_PROXY_FLAG" ]]; then
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files 2>/dev/null | grep -q '^microsocks.service'; then
      return 0
    fi
  fi
  return 1
}

is_hk_route_ready() {
  if [[ -f "$HK_ROUTE_FLAG" ]]; then
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files 2>/dev/null | grep -q 'hk-snat-restore.service'; then
      return 0
    fi
  fi
  return 1
}

confirm_hk_dependency() {
  local dep_type="$1"
  local action="$2"
  local ready=1
  case "$dep_type" in
    proxy)
      is_hk_proxy_ready || ready=0
      ;;
    route)
      is_hk_route_ready || ready=0
      ;;
  esac

  if (( ready )); then
    return 0
  fi

  if (( SB_MODE )); then
    warn "检测到香港端依赖未就绪，已在 sbmode 下自动中止 ${action}"
    return 1
  fi

  if [[ "$dep_type" == "proxy" ]]; then
    warn "检测到香港端代理尚未配置，执行 $action 可能失败"
  else
    warn "检测到香港端路由尚未配置，执行 $action 可能导致断网"
  fi
  read -rp "仍要继续吗？[y/N]: " confirm_choice
  if [[ "$confirm_choice" == "y" || "$confirm_choice" == "Y" ]]; then
    return 0
  fi
  info "已取消 $action"
  return 1
}

save_basic_info_config() {
  {
    echo "HK_LAN_IP=${HK_LAN_IP}"
    echo "QIANHAI_LAN_IP=${QIANHAI_LAN_IP}"
    [[ -n "$REMOTE_USER" ]] && echo "REMOTE_USER=${REMOTE_USER}"
    [[ -n "$REMOTE_PORT" ]] && echo "REMOTE_PORT=${REMOTE_PORT}"
    [[ -n "$REMOTE_AUTH" ]] && echo "REMOTE_AUTH=${REMOTE_AUTH}"
  } > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

cleanup_temp_key() {
  if [[ -n "${REMOTE_KEY_TEMP:-}" ]]; then
    rm -f "$REMOTE_KEY_TEMP" 2>/dev/null || true
    REMOTE_KEY_TEMP=""
  fi
  if [[ -n "${PASS_FILE:-}" ]]; then
    rm -f "$PASS_FILE" 2>/dev/null || true
    PASS_FILE=""
  fi
}

check_root() {
  if [[ $(id -u) -ne 0 ]]; then
    err "请以 root 身份执行本脚本"
    exit 1
  fi
}

apt_update_once() {
  if [[ $APT_UPDATED -eq 0 ]]; then
    info "更新软件包列表..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1
    APT_UPDATED=1
  fi
}

ensure_packages() {
  local pkg missing=()
  for pkg in "$@"; do
    if ! dpkg -s "$pkg" &>/dev/null; then
      missing+=("$pkg")
    fi
  done
  if ((${#missing[@]})); then
    apt_update_once
    info "安装必要软件包: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 || {
      # 如果静默安装失败，显示错误
      err "软件包安装失败: ${missing[*]}"
      err "尝试手动运行: apt-get install -y ${missing[*]}"
      exit 1
    }
  fi
}

is_valid_ipv4() {
  local ip="$1" IFS=.
  read -r a b c d <<<"$ip" 2>/dev/null || return 1
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  for part in $a $b $c $d; do
    (( part >= 0 && part <= 255 )) || return 1
  done
  return 0
}

is_valid_ipv6() {
  local ip="${1%%/*}"
  [[ -n "$ip" && "$ip" == *:* ]] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY' "$ip"
import ipaddress, sys
try:
    ipaddress.IPv6Address(sys.argv[1])
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
    return $?
  fi
  [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]]
}

is_private_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^10\. ]] || [[ "$ip" =~ ^192\.168\. ]] || [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]
}

is_public_ipv6() {
  local ip="${1%%/*}"
  [[ -n "$ip" ]] || return 1
  if is_valid_ipv6 "$ip"; then
    if command -v python3 >/dev/null 2>&1; then
      python3 - <<'PY' "$ip"
import ipaddress, sys
try:
    addr = ipaddress.IPv6Address(sys.argv[1])
    sys.exit(0 if addr.is_global else 1)
except Exception:
    sys.exit(1)
PY
      return $?
    fi
    [[ "$ip" != fe80:* && "$ip" != fe8?* && "$ip" != fc??:* && "$ip" != fd??:* && "$ip" != ::1 ]]
  else
    return 1
  fi
}

private_ip_priority() {
  local ip="$1"
  if [[ "$ip" =~ ^192\.168\.80\. ]]; then
    echo 4
  elif [[ "$ip" =~ ^192\.168\. ]]; then
    echo 3
  elif [[ "$ip" =~ ^10\. ]]; then
    echo 2
  elif [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
    echo 1
  else
    echo 0
  fi
}

is_public_ipv4() {
  local ip="$1"
  [[ -n "$ip" ]] && is_valid_ipv4 "$ip" && ! is_private_ipv4 "$ip"
}

is_public_ip() {
  local ip="$1"
  if is_public_ipv4 "$ip"; then
    return 0
  fi
  if is_public_ipv6 "$ip"; then
    return 0
  fi
  return 1
}

ip_family() {
  local ip="$1"
  [[ "$ip" == *:* ]] && echo 6 || echo 4
}

prompt_ipv4() {
  local prompt="$1" default="${2:-}" input
  while true; do
    if [[ -n "$default" ]]; then
      read -rp "$prompt [$default]: " input
      input="${input:-$default}"
    else
      read -rp "$prompt: " input
    fi
    if is_valid_ipv4 "$input"; then
      printf '%s\n' "$input"
      return 0
    fi
    echo "请输入合法的 IPv4 地址"
  done
}

local_has_ip() {
  local ip="$1"
  ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$ip"
}

can_ping_ip() {
  local ip="$1"
  ping -c 2 -W 2 "$ip" &>/dev/null
}

detect_default_hk_ip() {
  local best_ip="" best_pri=-1
  while IFS= read -r ip; do
    if is_private_ipv4 "$ip"; then
      local pri
      pri=$(private_ip_priority "$ip")
      if (( pri > best_pri )); then
        best_pri="$pri"
        best_ip="$ip"
      fi
    fi
  done < <(ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1)
  printf '%s\n' "$best_ip"
}

prompt_port() {
  local prompt="$1" default="${2:-22}" input
  while true; do
    read -rp "$prompt [$default]: " input
    input="${input:-$default}"
    if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
      printf '%s\n' "$input"
      return 0
    fi
    echo "端口必须是 1-65535 之间的数字"
  done
}

prompt_port_range() {
  local default="${1:-10000-65535}" input start end
  while true; do
    read -rp "请输入端口范围 (格式 起始-结束) [$default]: " input
    input="${input:-$default}"
    if [[ "$input" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      if (( start >= 1 && start <= 65535 && end >= 1 && end <= 65535 && start <= end )); then
        printf '%s %s\n' "$start" "$end"
        return 0
      fi
    fi
    echo "端口范围无效，请输入 1-65535 之间的起止端口"
  done
}

prompt_password() {
  local prompt="$1"
  while true; do
    read -srp "$prompt: " GLOBAL_PASS_VAR
    echo
    if [[ -n "$GLOBAL_PASS_VAR" ]]; then
      return 0
    fi
    echo "密码不能为空"
  done
}

run_menu_action() {
  local description="$1"
  shift
  if ! "$@"; then
    warn "$description 执行失败，请检查上述输出"
    return 1
  fi
  return 0
}

parse_args() {
  while (($#)); do
    case "$1" in
      --sbmode)
        SB_MODE=1
        ;;
    esac
    shift
  done
}

confirm_violent_mode_entry() {
  echo ""
  echo "========================================"
  echo " [警告] 直接转发模式（不推荐）为高阶功能，可能影响网络连通性"
  echo " - 此模式会在中国内地端直接映射大量端口到香港"
  echo " - 可选择使用 iptables 或 nftables 实现映射"
  echo " - 配置错误可能导致所有入站流量被转发，甚至断开 SSH"
  echo " 请确保充分理解后果再继续"
  echo "========================================"
  read -rp "仍要继续进入直接转发模式？[y/N]: " choice
  if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
    return 0
  fi
  info "已取消进入直接转发模式"
  return 1
}

# ==================== 模式选择函数 ====================
select_work_mode() {
  echo ""
  echo "========================================"
  echo " 请选择工作模式"
  echo "========================================"
  echo "1) 代理模式 - 使用 SOCKS5 代理（不改变VPS本身路由）"
  echo "2) 路由模式（推荐） - 使用策略路由（不需要使用代理）"
  echo "3) 直接转发模式（不推荐） - 大范围端口转发"
  echo "========================================"

  local choice
  while true; do
    read -rp "请选择模式 [1/2/3]: " choice
    case "$choice" in
      1)
        WORK_MODE="proxy"
        info "已选择：代理模式"
        break
        ;;
      2)
        WORK_MODE="route"
        info "已选择：路由模式"
        break
        ;;
      3)
        if confirm_violent_mode_entry; then
          WORK_MODE="violent"
          info "已选择：直接转发模式（不推荐）"
          break
        else
          continue
        fi
        ;;
      *)
        echo "请输入 1、2 或 3"
        ;;
    esac
  done
}

# ==================== 代理模式相关函数 ====================
ensure_basic_info() {
  if [[ $BASIC_INFO_READY -eq 1 ]]; then
    return
  fi
  load_saved_config
  if [[ -z "$HK_LAN_IP" ]]; then
    HK_LAN_IP=$(detect_default_hk_ip)
  fi
  ensure_packages iproute2 iputils-ping

  if (( SB_MODE )); then
    if [[ -z "$HK_LAN_IP" ]]; then
      HK_LAN_IP=$(detect_default_hk_ip)
    fi
    if [[ -z "$HK_LAN_IP" ]]; then
      err "无法自动检测香港端局域网 IP，请手动填写后重试"
      return 1
    fi
    if ! local_has_ip "$HK_LAN_IP"; then
      err "本机网卡未检测到 ${HK_LAN_IP}，请确认网络配置"
      return 1
    fi

    if [[ -z "$QIANHAI_LAN_IP" ]]; then
      read -rp "请输入中国内地端 SSH 地址/IP: " QIANHAI_LAN_IP
    fi
    if [[ -z "$QIANHAI_LAN_IP" ]]; then
      err "中国内地端地址为空，无法继续"
      return 1
    fi
    if ! can_ping_ip "$QIANHAI_LAN_IP"; then
      warn "无法 ping 通 ${QIANHAI_LAN_IP}，请确认网络连通性"
    fi

    save_basic_info_config
    BASIC_INFO_READY=1
    info "已在 sbmode 下自动使用默认基础信息"
    return 0
  fi

  while true; do
    local hk_ip qh_ip
    hk_ip=$(prompt_ipv4 "请输入香港端局域网 IP" "$HK_LAN_IP")
    if ! local_has_ip "$hk_ip"; then
      local detected_ips
      detected_ips=$(ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')
      err "本机网卡未检测到 ${hk_ip}，当前已分配 IPv4: ${detected_ips:-无}"
      continue
    fi

    qh_ip=$(prompt_ipv4 "请输入中国内地端局域网 IP" "$QIANHAI_LAN_IP")
    if ! can_ping_ip "$qh_ip"; then
      err "无法 ping 通 ${qh_ip}，请确认 SD-WAN 连接是否正常"
      continue
    fi

    HK_LAN_IP="$hk_ip"
    QIANHAI_LAN_IP="$qh_ip"
    save_basic_info_config
    BASIC_INFO_READY=1
    info "基本信息与连通性检查通过"
    break
  done
}

read_private_key() {
  local tmp_key line first_line src
  while true; do
    cat <<'PROMPT' >&2
请输入私钥：
  - 可直接粘贴整段私钥，最后输入一行 END 结束
  - 或输入 FILE:/绝对路径 读取现有私钥文件
PROMPT
    read -rp "> " first_line
    [[ -z "$first_line" ]] && continue

    if [[ "$first_line" =~ ^FILE:(.+)$ ]]; then
      src="${BASH_REMATCH[1]}"
      if [[ -f "$src" ]]; then
        tmp_key=$(mktemp /tmp/nsproxy-key.XXXXXX)
        chmod 600 "$tmp_key"
        cat "$src" >"$tmp_key"
        if grep -q -- "BEGIN" "$tmp_key" && grep -q -- "-----END" "$tmp_key"; then
          printf '%s\n' "$tmp_key"
          return 0
        fi
        echo "文件内容不是有效的私钥，请重新输入" >&2
        rm -f "$tmp_key"
        continue
      else
        echo "指定的文件不存在，请重新输入" >&2
        continue
      fi
    fi

    tmp_key=$(mktemp /tmp/nsproxy-key.XXXXXX)
    chmod 600 "$tmp_key"
    : >"$tmp_key"
    if [[ "$first_line" != "END" ]]; then
      printf '%s\n' "$first_line" >>"$tmp_key"
    fi

    while IFS= read -r line; do
      if [[ "$line" == "END" ]]; then
        break
      fi
      printf '%s\n' "$line" >>"$tmp_key"
      if [[ "$line" == *"-----END"* ]]; then
        break
      fi
    done

    if grep -q -- "BEGIN" "$tmp_key" && grep -q -- "-----END" "$tmp_key"; then
      printf '%s\n' "$tmp_key"
      return 0
    fi
    echo "输入内容似乎不是有效的私钥，请重新输入" >&2
    rm -f "$tmp_key"
  done
}

ensure_remote_context() {
  if [[ $REMOTE_INFO_READY -eq 1 ]]; then
    return
  fi
  ensure_basic_info
  load_saved_config
  ensure_packages openssh-client sshpass
  while true; do
    local user port auth
    local user_default="${REMOTE_USER:-root}"
    read -rp "请输入中国内地端 SSH 用户名 [$user_default]: " user
    user="${user:-$user_default}"
    if [[ -z "$user" ]]; then
      echo "用户名不能为空"
      continue
    fi
    user="${user## }"
    user="${user%% }"

    local port_default="${REMOTE_PORT:-22}"
    port=$(prompt_port "请输入中国内地端 SSH 端口" "$port_default")

    local default_choice="1"
    if [[ "${REMOTE_AUTH:-}" == "key" ]]; then
      default_choice="2"
    fi
    while true; do
      read -rp "请选择认证方式 [1] 密码 [2] 私钥 (默认 $default_choice): " choice
      choice="${choice:-$default_choice}"
      case "$choice" in
        1)
          auth="password"
          break
          ;;
        2)
          auth="key"
          break
          ;;
        *)
          echo "请输入 1 或 2"
          ;;
      esac
    done

    while true; do
      local pass="" key="" KEY_PASSPHRASE=""
      if [[ "$auth" == "password" ]]; then
        prompt_password "请输入 SSH 密码"
        pass="$GLOBAL_PASS_VAR"
      else
        key=$(read_private_key)
        REMOTE_KEY_TEMP="$key"
        if ! ssh-keygen -y -P '' -f "$REMOTE_KEY_TEMP" >/dev/null 2>&1; then
          while true; do
            read -srp "请输入该私钥的密码: " KEY_PASSPHRASE
            echo
            if [[ -z "$KEY_PASSPHRASE" ]]; then
              echo "已取消私钥认证，请重新输入" >&2
              cleanup_temp_key
              continue 3
            fi
            if ssh-keygen -y -P "$KEY_PASSPHRASE" -f "$REMOTE_KEY_TEMP" >/dev/null 2>&1; then
              break
            fi
            echo "私钥密码不正确，请重试" >&2
          done
        fi
      fi

      REMOTE_USER="$user"
      REMOTE_PORT="$port"
      REMOTE_AUTH="$auth"
      REMOTE_PASS="$pass"
      REMOTE_KEY="$key"
      REMOTE_DEST="${REMOTE_USER}@${QIANHAI_LAN_IP}"
      if [[ "$REMOTE_USER" == "root" ]]; then
        REMOTE_SUDO=""
      else
        REMOTE_SUDO="sudo"
      fi

      local -a ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ControlMaster=no -o ControlPath=none -o LogLevel=ERROR -o ConnectTimeout=10)

      if [[ "$REMOTE_AUTH" == "password" ]]; then
        PASS_FILE=$(mktemp /tmp/.sshpass.XXXXXX)
        chmod 600 "$PASS_FILE"
        printf '%s' "$REMOTE_PASS" > "$PASS_FILE"
        SSH_BASE=(sshpass -f "$PASS_FILE" ssh "${ssh_opts[@]}" -p "$REMOTE_PORT" "$REMOTE_DEST")
        SCP_BASE=(sshpass -f "$PASS_FILE" scp "${ssh_opts[@]}" -P "$REMOTE_PORT")
      else
        if [[ -n "$KEY_PASSPHRASE" ]]; then
          SSH_BASE=(sshpass -P "Enter passphrase" -p "$KEY_PASSPHRASE" ssh "${ssh_opts[@]}" -o PubkeyAuthentication=yes -o PasswordAuthentication=no -p "$REMOTE_PORT" -i "$REMOTE_KEY_TEMP" "$REMOTE_DEST")
          SCP_BASE=(sshpass -P "Enter passphrase" -p "$KEY_PASSPHRASE" scp "${ssh_opts[@]}" -o PubkeyAuthentication=yes -o PasswordAuthentication=no -P "$REMOTE_PORT" -i "$REMOTE_KEY_TEMP")
        else
          SSH_BASE=(ssh "${ssh_opts[@]}" -o PubkeyAuthentication=yes -o PasswordAuthentication=no -o BatchMode=yes -p "$REMOTE_PORT" -i "$REMOTE_KEY_TEMP" "$REMOTE_DEST")
          SCP_BASE=(scp "${ssh_opts[@]}" -o PubkeyAuthentication=yes -o PasswordAuthentication=no -o BatchMode=yes -P "$REMOTE_PORT" -i "$REMOTE_KEY_TEMP")
        fi
        REMOTE_KEY="$REMOTE_KEY_TEMP"
      fi

      local ssh_check_output=""
      local ssh_status=0
      set +e
      ssh_check_output=$("${SSH_BASE[@]}" true 2>&1)
      ssh_status=$?
      set -e

      if (( ssh_status == 0 )); then
        REMOTE_INFO_READY=1
        save_basic_info_config
        info "SSH 连接信息已确认"
        return 0
      fi

      err "无法通过 SSH 连接至 ${REMOTE_DEST}:${REMOTE_PORT}"
      err "$ssh_check_output"
      REMOTE_INFO_READY=0
      cleanup_temp_key

      if [[ "$auth" == "password" ]]; then
        read -rp "是否重新输入密码重试？[Y/n]: " retry_pwd
        if [[ "$retry_pwd" != "n" && "$retry_pwd" != "N" ]]; then
          continue
        fi
      fi
      break
    done

    read -rp "是否重新输入 SSH 连接信息再试？[Y/n]: " retry_all
    if [[ "$retry_all" == "y" || "$retry_all" == "Y" || -z "$retry_all" ]]; then
      continue
    fi
    return 1
  done
}

remote_exec() {
  "${SSH_BASE[@]}" "$@"
}

remote_sudo() {
  if [[ -n "$REMOTE_SUDO" ]]; then
    remote_exec "$REMOTE_SUDO" "$@"
  else
    remote_exec "$@"
  fi
}

remote_copy() {
  local src="$1" dst="$2"
  "${SCP_BASE[@]}" "$src" "$REMOTE_DEST:$dst"
}

read_remote_flag() {
  local file="$1" key="$2"
  remote_exec "awk -F= -v k='$key' '\$1==k {print \$2}' $file 2>/dev/null | head -n1"
}

select_qh_direct_ifaces() {
  ensure_remote_context || return 1

  local interfaces_raw
  interfaces_raw=$(remote_exec "ip link show | grep -E '^[0-9]+:' | awk '{print \$2}' | sed 's/:$//' | grep -v '^lo$'")
  local interfaces=($interfaces_raw)
  local -a if_names=() if_ip4=() if_ip6=()

  for i in "${!interfaces[@]}"; do
    local if_name="${interfaces[$i]}"
    local ip4=$(remote_exec "ip addr show $if_name 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1 | head -n1")
    local ip6=$(remote_exec "ip addr show $if_name 2>/dev/null | grep 'inet6 ' | grep -v 'fe80' | awk '{print \$2}' | cut -d/ -f1 | head -n1")
    if_names[$i]="$if_name"
    if_ip4[$i]="$ip4"
    if_ip6[$i]="$ip6"
  done

  echo "中国内地端检测到的网卡列表:"
  for i in "${!if_names[@]}"; do
    echo "$((i+1))). ${if_names[$i]} - IPv4: ${if_ip4[$i]:-无} IPv6: ${if_ip6[$i]:-无}"
  done

  local default_ext="" default_int="" pri_int=0
  for i in "${!if_names[@]}"; do
    local ip4="${if_ip4[$i]}"
    local ip6="${if_ip6[$i]}"
    if [[ -z "$default_ext" ]] && is_public_ip "$ip4"; then
      default_ext="${if_names[$i]}"
    fi
    if [[ -z "$default_int" ]] && is_private_ipv4 "$ip4"; then
      default_int="${if_names[$i]}"
    fi
    if is_private_ipv4 "$ip4"; then
      local pri
      pri=$(private_ip_priority "$ip4")
      if (( pri > pri_int )); then
        pri_int=$pri
        default_int="${if_names[$i]}"
      fi
    fi
    # 如果只有IPv6公网，仍可作为外网候选
    if [[ -z "$default_ext" && -n "$ip6" ]]; then
      if is_public_ipv6 "$ip6"; then
        default_ext="${if_names[$i]}"
      fi
    fi
  done

  [[ -z "$default_ext" ]] && default_ext="${if_names[0]:-}"
  if [[ -z "$default_int" || "$default_int" == "$default_ext" ]]; then
    for i in "${!if_names[@]}"; do
      [[ "${if_names[$i]}" == "$default_ext" ]] && continue
      if [[ -n "${if_ip4[$i]}" || -n "${if_ip6[$i]}" ]]; then
        default_int="${if_names[$i]}"
        break
      fi
    done
  fi
  [[ -z "$default_int" ]] && default_int="$default_ext"

  local choice
  while true; do
    read -rp "请选择中国内地端外网接口 (默认 ${default_ext:-无}): " choice
    if [[ -z "$choice" ]]; then
      QH_EXTERNAL_IF="$default_ext"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >=1 && choice <= ${#if_names[@]} )); then
      QH_EXTERNAL_IF="${if_names[$((choice-1))]}"
    else
      QH_EXTERNAL_IF="$choice"
    fi
    if remote_exec "ip link show $QH_EXTERNAL_IF" >/dev/null 2>&1; then
      break
    fi
    warn "外网接口 $QH_EXTERNAL_IF 不存在，请重选"
  done

  while true; do
    read -rp "请选择中国内地端内网接口 (默认 ${default_int:-无}): " choice
    if [[ -z "$choice" ]]; then
      QH_INTERNAL_IF="$default_int"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >=1 && choice <= ${#if_names[@]} )); then
      QH_INTERNAL_IF="${if_names[$((choice-1))]}"
    else
      QH_INTERNAL_IF="$choice"
    fi
    if remote_exec "ip link show $QH_INTERNAL_IF" >/dev/null 2>&1; then
      break
    fi
    warn "内网接口 $QH_INTERNAL_IF 不存在，请重选"
  done
}

create_microsocks_service() {
  info "写入 microsocks systemd 单元"
  cat > "$MICROSOCKS_SERVICE" <<EOF
[Unit]
Description=MicroSocks server
After=network.target

[Service]
ExecStart=/usr/bin/microsocks -i ${HK_LAN_IP} -p ${MICROSOCKS_PORT}
Restart=on-failure
User=nobody
Group=nogroup

[Install]
WantedBy=multi-user.target
EOF
}

apply_firewall_rules() {
  local port="$MICROSOCKS_PORT" chain="$MICROSOCKS_CHAIN"
  info "配置 iptables 访问控制"
  iptables -N "$chain" 2>/dev/null || true
  iptables -F "$chain"
  iptables -A "$chain" -p tcp -s "$QIANHAI_LAN_IP" --dport "$port" -j ACCEPT
  iptables -A "$chain" -p tcp --dport "$port" -j DROP
  if ! iptables -C INPUT -p tcp --dport "$port" -j "$chain" &>/dev/null; then
    iptables -I INPUT -p tcp --dport "$port" -j "$chain"
  fi

  if command -v ip6tables &>/dev/null; then
    ip6tables -N "$chain" 2>/dev/null || true
    ip6tables -F "$chain"
    ip6tables -A "$chain" -p tcp --dport "$port" -j DROP
    if ! ip6tables -C INPUT -p tcp --dport "$port" -j "$chain" &>/dev/null; then
      ip6tables -I INPUT -p tcp --dport "$port" -j "$chain"
    fi
  fi

  netfilter-persistent save >/dev/null 2>&1
}

cleanup_firewall_rules() {
  local port="$MICROSOCKS_PORT" chain="$MICROSOCKS_CHAIN"
  info "清理 iptables 规则"
  while iptables -C INPUT -p tcp --dport "$port" -j "$chain" &>/dev/null; do
    iptables -D INPUT -p tcp --dport "$port" -j "$chain"
  done
  iptables -F "$chain" &>/dev/null || true
  iptables -X "$chain" &>/dev/null || true

  if command -v ip6tables &>/dev/null; then
    while ip6tables -C INPUT -p tcp --dport "$port" -j "$chain" &>/dev/null; do
      ip6tables -D INPUT -p tcp --dport "$port" -j "$chain"
    done
    ip6tables -F "$chain" &>/dev/null || true
    ip6tables -X "$chain" &>/dev/null || true
  fi

  if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save >/dev/null 2>&1
  fi
}

install_hk_proxy() {
  ensure_basic_info
  ensure_packages curl microsocks iptables-persistent
  create_microsocks_service
  apply_firewall_rules
  systemctl daemon-reload >/dev/null 2>&1 >/dev/null 2>&1
  systemctl enable microsocks >/dev/null 2>&1
  systemctl start microsocks >/dev/null 2>&1
  # 检查服务状态但不显示详细输出
  if systemctl is-active microsocks >/dev/null 2>&1; then
    info "香港端 SOCKS 代理已安装并运行在 ${HK_LAN_IP}:${MICROSOCKS_PORT}"
    mark_state_flag "$HK_PROXY_FLAG"
  else
    err "microsocks 服务启动失败，请检查日志"
    systemctl status microsocks --no-pager -l
  fi
}

uninstall_hk_proxy() {
  info "开始卸载香港端代理"
  read -rp "是否同时清理中国内地端自动代理配置？[y/N]: " clear_remote
  if [[ "$clear_remote" == "y" || "$clear_remote" == "Y" ]]; then
    run_menu_action "清理中国内地端自动代理" disable_qh_autoproxy_inner || true
  fi
  if systemctl list-unit-files 2>/dev/null | grep -q '^microsocks.service'; then
    systemctl stop microsocks >/dev/null 2>&1 || true
    systemctl disable microsocks >/dev/null 2>&1 || true
    systemctl reset-failed microsocks >/dev/null 2>&1 || true
  fi
  pkill -x microsocks >/dev/null 2>&1 || true
  pkill -f '/usr/bin/microsocks' >/dev/null 2>&1 || true
  rm -f "$MICROSOCKS_SERVICE"
  cleanup_firewall_rules
  systemctl daemon-reload >/dev/null 2>&1 >/dev/null 2>&1
  clear_state_flag "$HK_PROXY_FLAG"
  info "已卸载 microsocks 代理"
}

download_nsproxy() {
  local tmp
  tmp=$(mktemp)
  info "正在下载 nsproxy 二进制文件"
  curl -fsSL "$NSPROXY_URL" -o "$tmp"
  printf '%s\n' "$tmp"
}

install_qh_proxy() {
  if ! confirm_hk_dependency "proxy" "安装中国内地端代理客户端"; then
    return 1
  fi
  ensure_remote_context || return 1
  local tmp_file remote_tmp="/tmp/nsproxy.$$"
  tmp_file=$(download_nsproxy)
  remote_copy "$tmp_file" "$remote_tmp"
  rm -f "$tmp_file"
  remote_sudo install -m 0755 "$remote_tmp" "$NSPROXY_REMOTE_PATH"
  remote_sudo rm -f "$remote_tmp"
  remote_exec "$NSPROXY_REMOTE_PATH" -h >/dev/null 2>&1 || true
  info "中国内地端 nsproxy 客户端已部署至 ${NSPROXY_REMOTE_PATH}"

  # 询问是否设置自动代理
  echo ""
  read -rp "是否设置中国内地端SSH登录自动代理？[Y/n]: " set_auto
  if [[ "$set_auto" != "n" && "$set_auto" != "N" ]]; then
    enable_qh_autoproxy
  else
    info "未设置自动代理"
    info "您可以稍后通过菜单选项5设置自动代理"
  fi
}

uninstall_qh_proxy() {
  if ! confirm_hk_dependency "proxy" "卸载中国内地端代理客户端"; then
    return 1
  fi
  ensure_remote_context || return 1
  disable_qh_autoproxy_inner
  remote_sudo rm -f "$NSPROXY_REMOTE_PATH"
  info "已删除中国内地端 ${NSPROXY_REMOTE_PATH}"
}

enable_qh_autoproxy() {
  if ! confirm_hk_dependency "proxy" "设置中国内地端自动代理"; then
    return 1
  fi
  ensure_remote_context || return 1
  if ! remote_exec test -x "$NSPROXY_REMOTE_PATH"; then
    err "中国内地端未检测到 nsproxy，可先执行安装中国内地端代理客户端"
    return 1
  fi

  info "配置自动代理..."

  info "创建wrapper脚本..."
  remote_exec "cat > ~/.nsproxy_wrapper.sh" <<EOF
#!/bin/sh
# 兼容所有shell的wrapper脚本
if [ -z "\$NSPROXY_ACTIVE" ]; then
  export NSPROXY_ACTIVE=1
  exec nsproxy -s $HK_LAN_IP -p $MICROSOCKS_PORT "\${SHELL:-/bin/sh}"
fi
EOF

  remote_exec "chmod +x ~/.nsproxy_wrapper.sh"

  local config_snippet='# >>> nsproxy auto start
if [ -z "$NSPROXY_ACTIVE" ] && [ -f "$HOME/.nsproxy_wrapper.sh" ] && [ -t 0 ]; then
  exec "$HOME/.nsproxy_wrapper.sh"
fi
# <<< nsproxy auto end'

  info "配置各种shell启动文件..."

  local user_shell=$(remote_exec 'echo $SHELL')
  info "检测到默认shell: $user_shell"

  local shell_configs=(
    ".profile"
    ".bashrc"
    ".bash_profile"
    ".zshrc"
    ".zprofile"
    ".kshrc"
    ".mkshrc"
    ".config/fish/config.fish"
  )

  local configured_files=""

  for config in "${shell_configs[@]}"; do
    if [[ "$config" == ".config/fish/config.fish" ]]; then
      remote_exec "mkdir -p ~/.config/fish 2>/dev/null || true"
      if remote_exec "test -d ~/.config/fish"; then
        info "配置 Fish shell..."
        remote_exec "sed -i '/# >>> nsproxy auto start/,/# <<< nsproxy auto end/d' ~/$config 2>/dev/null || true"
        remote_exec "cat >> ~/$config" <<'EOF'
# >>> nsproxy auto start
if test -z "$NSPROXY_ACTIVE"; and test -f "$HOME/.nsproxy_wrapper.sh"; and test -t 0
  exec "$HOME/.nsproxy_wrapper.sh"
end
# <<< nsproxy auto end
EOF
        configured_files="$configured_files $config"
      fi
    else
      remote_exec "touch ~/$config 2>/dev/null || true"

      if remote_exec "test -f ~/$config"; then
        remote_exec "sed -i '/# >>> nsproxy auto start/,/# <<< nsproxy auto end/d' ~/$config 2>/dev/null || true"
        remote_exec "echo '' >> ~/$config"
        remote_exec "cat >> ~/$config" <<EOF
$config_snippet
EOF
        configured_files="$configured_files $config"
      fi
    fi
  done

  if remote_exec "test -d /etc/profile.d && test -w /etc/profile.d" 2>/dev/null; then
    info "配置 /etc/profile.d/nsproxy.sh..."
    remote_exec "cat > /etc/profile.d/nsproxy.sh" <<EOF
#!/bin/sh
$config_snippet
EOF
    remote_exec "chmod 644 /etc/profile.d/nsproxy.sh" 2>/dev/null || true
    configured_files="$configured_files /etc/profile.d/nsproxy.sh"
  fi

  info "验证配置文件..."
  remote_exec "ls -la ~/.nsproxy_wrapper.sh 2>/dev/null" || true

  info "已配置以下文件:"
  for file in $configured_files; do
    info "  - $file"
  done

  info ""
  info "已设置中国内地端 SSH 登录自动走 nsproxy 代理"
  info "支持的shell: bash, zsh, sh, dash, ash, ksh, mksh, fish"
  info ""
  info "提示: 需要重新登录SSH才能生效"
}

disable_qh_autoproxy_inner() {
  info "清理自动代理配置..."

  local shell_configs=(
    ".profile"
    ".bashrc"
    ".bash_profile"
    ".zshrc"
    ".zprofile"
    ".kshrc"
    ".mkshrc"
    ".config/fish/config.fish"
  )

  local cleaned_files=""

  for config in "${shell_configs[@]}"; do
    if remote_exec "test -f ~/$config" 2>/dev/null; then
      remote_exec "sed -i '/# >>> nsproxy auto start/,/# <<< nsproxy auto end/d' ~/$config 2>/dev/null || true"
      cleaned_files="$cleaned_files $config"
    fi
  done

  if remote_exec "test -f /etc/profile.d/nsproxy.sh" 2>/dev/null; then
    remote_exec "rm -f /etc/profile.d/nsproxy.sh 2>/dev/null || true"
    cleaned_files="$cleaned_files /etc/profile.d/nsproxy.sh"
  fi

  remote_exec "rm -f ~/.nsproxy_wrapper.sh"

  info "已取消中国内地端 SSH 自动代理配置"

  if [[ -n "$cleaned_files" ]]; then
    info "已清理以下文件:"
    for file in $cleaned_files; do
      info "  - $file"
    done
  fi

  info "已删除: ~/.nsproxy_wrapper.sh"
}

disable_qh_autoproxy() {
  if ! confirm_hk_dependency "proxy" "取消中国内地端自动代理"; then
    return 1
  fi
  ensure_remote_context || return 1
  disable_qh_autoproxy_inner
}

# ==================== 路由模式相关函数 ====================

# 获取网卡IP地址
get_interface_ip() {
  local interface=$1
  local ipv4 ipv6
  ipv4=$(ip -o -4 addr show "$interface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
  if [[ -n "$ipv4" ]]; then
    echo "$ipv4"
    return
  fi
  ipv6=$(ip -o -6 addr show "$interface" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
  echo "$ipv6"
}

# 获取网卡网段
get_interface_network() {
  local interface=$1
  local net4 net6
  net4=$(ip -o -4 addr show "$interface" 2>/dev/null | awk '{print $4}' | head -n1)
  if [[ -n "$net4" ]]; then
    echo "$net4"
    return
  fi
  net6=$(ip -o -6 addr show "$interface" scope global 2>/dev/null | awk '{print $4}' | head -n1)
  echo "$net6"
}

# 自动检测网关
get_gateway_from_route() {
  local interface=$1
  local gw
  gw=$(ip route | grep "dev $interface" | grep via | awk '{print $3}' | head -n1)
  if [[ -n "$gw" ]]; then
    echo "$gw"
    return
  fi
  ip -6 route | grep "dev $interface" | grep via | awk '{print $3}' | head -n1
}

# 检查网卡是否存在
check_interface_exists() {
  local interface=$1
  if ! ip link show "$interface" &>/dev/null; then
    return 1
  fi
  return 0
}

in_detected_interfaces() {
  local target="$1"
  shift
  local iface
  for iface in "$@"; do
    if [[ "$iface" == "$target" ]]; then
      return 0
    fi
  done
  return 1
}

# 配置香港端路由信息
ensure_hk_route_info() {
  ensure_basic_info
  ensure_packages iproute2

  info "配置香港端路由信息..."

  # 自动检测网卡
  local interfaces=($(ip link show | grep -E '^[0-9]+:' | awk '{print $2}' | sed 's/:$//' | grep -v '^lo$'))
  local -a if_ips=()
  local -a if_networks=()

  echo ""
  echo "检测到的网卡列表:"
  for i in "${!interfaces[@]}"; do
    local if_name="${interfaces[$i]}"
    local if_ip=$(get_interface_ip "$if_name")
    local if_net=$(get_interface_network "$if_name")
    if_ips[$i]="$if_ip"
    if_networks[$i]="$if_net"
    echo "$((i+1)). $if_name - IP: ${if_ip:-无} 网段: ${if_net:-无}"
  done

  local default_hk_ext_if=""
  local default_hk_int_if=""
  local default_hk_int_pri=0

  for i in "${!interfaces[@]}"; do
    local if_name="${interfaces[$i]}"
    local if_ip="${if_ips[$i]}"
    if [[ -z "$default_hk_ext_if" ]] && is_public_ip "$if_ip"; then
      default_hk_ext_if="$if_name"
    fi
    if [[ -z "$default_hk_int_if" ]] && is_private_ipv4 "$if_ip"; then
      default_hk_int_if="$if_name"
    fi

    if is_private_ipv4 "$if_ip"; then
      local pri
      pri=$(private_ip_priority "$if_ip")
      if (( pri > default_hk_int_pri )); then
        default_hk_int_pri="$pri"
        default_hk_int_if="$if_name"
      fi
    fi
  done

  if [[ -z "$default_hk_ext_if" ]]; then
    default_hk_ext_if="${interfaces[0]:-}"
  fi

  if [[ -z "$default_hk_int_if" || "$default_hk_int_if" == "$default_hk_ext_if" ]]; then
    for i in "${!interfaces[@]}"; do
      local if_name="${interfaces[$i]}"
      [[ "$if_name" == "$default_hk_ext_if" ]] && continue
      if [[ -n "${if_ips[$i]}" ]]; then
        default_hk_int_if="$if_name"
        break
      fi
    done
  fi

  [[ -z "$default_hk_int_if" ]] && default_hk_int_if="${default_hk_ext_if:-}"

  # 选择外网接口
  local choice
  if (( SB_MODE )); then
    HK_EXTERNAL_IF="${HK_EXTERNAL_IF:-$default_hk_ext_if}"
    [[ -z "$HK_EXTERNAL_IF" ]] && HK_EXTERNAL_IF="${interfaces[0]:-}"
    HK_INTERNAL_IF="${HK_INTERNAL_IF:-$default_hk_int_if}"
    [[ -z "$HK_INTERNAL_IF" ]] && HK_INTERNAL_IF="$HK_EXTERNAL_IF"

    if ! check_interface_exists "$HK_EXTERNAL_IF"; then
      err "自动选择的外网接口 $HK_EXTERNAL_IF 不存在，请检查后重试"
      return 1
    fi
    HK_EXTERNAL_IP=$(get_interface_ip "$HK_EXTERNAL_IF")
    if [[ -z "$HK_EXTERNAL_IP" ]]; then
      err "自动选择的外网接口 $HK_EXTERNAL_IF 未配置IP地址"
      return 1
    fi

    if ! check_interface_exists "$HK_INTERNAL_IF"; then
      err "自动选择的内网接口 $HK_INTERNAL_IF 不存在，请检查后重试"
      return 1
    fi
    HK_INTERNAL_NETWORK=$(get_interface_network "$HK_INTERNAL_IF")
    if [[ -z "$HK_INTERNAL_NETWORK" ]]; then
      err "自动选择的内网接口 $HK_INTERNAL_IF 未配置IP地址"
      return 1
    fi
  else
    while true; do
      read -rp "请选择香港端外网接口 (默认 ${default_hk_ext_if:-无}): " choice
      if [[ -z "$choice" ]]; then
        HK_EXTERNAL_IF="$default_hk_ext_if"
      elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#interfaces[@]} )); then
        HK_EXTERNAL_IF="${interfaces[$((choice-1))]}"
      else
        HK_EXTERNAL_IF="$choice"
      fi

      if ! in_detected_interfaces "$HK_EXTERNAL_IF" "${interfaces[@]}"; then
        warn "输入的网卡 $HK_EXTERNAL_IF 不在检测到的列表中，请检查网卡名称是否正确"
      fi

      if check_interface_exists "$HK_EXTERNAL_IF"; then
        HK_EXTERNAL_IP=$(get_interface_ip "$HK_EXTERNAL_IF")
        if [[ -n "$HK_EXTERNAL_IP" ]]; then
          break
        else
          err "网卡 $HK_EXTERNAL_IF 没有配置IP地址"
        fi
      else
        err "网卡 $HK_EXTERNAL_IF 不存在"
      fi
    done

    # 选择内网接口
    while true; do
      read -rp "请选择香港端内网接口 (默认 ${default_hk_int_if:-无}): " choice
      if [[ -z "$choice" ]]; then
        HK_INTERNAL_IF="$default_hk_int_if"
      elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#interfaces[@]} )); then
        HK_INTERNAL_IF="${interfaces[$((choice-1))]}"
      else
        HK_INTERNAL_IF="$choice"
      fi

      if ! in_detected_interfaces "$HK_INTERNAL_IF" "${interfaces[@]}"; then
        warn "输入的网卡 $HK_INTERNAL_IF 不在检测到的列表中，请检查网卡名称是否正确"
      fi

      if check_interface_exists "$HK_INTERNAL_IF"; then
        HK_INTERNAL_NETWORK=$(get_interface_network "$HK_INTERNAL_IF")
        if [[ -n "$HK_INTERNAL_NETWORK" ]]; then
          break
        else
          err "网卡 $HK_INTERNAL_IF 没有配置IP地址"
        fi
      else
        err "网卡 $HK_INTERNAL_IF 不存在"
      fi
    done
  fi

  # 获取外网网关
  HK_EXTERNAL_GW=$(get_gateway_from_route "$HK_EXTERNAL_IF")
  if [[ -z "$HK_EXTERNAL_GW" ]]; then
    if [[ "$(ip_family "$HK_EXTERNAL_IP")" == "4" ]]; then
      HK_EXTERNAL_GW=$(echo "$HK_EXTERNAL_IP" | awk -F'.' '{print $1"."$2"."$3".1"}')
      warn "自动推算外网网关: $HK_EXTERNAL_GW"
    else
      warn "未检测到外网网关，请确认IPv6网关后输入"
    fi
  else
    info "检测到外网网关: $HK_EXTERNAL_GW"
  fi

  # 提供修改网关的机会
  if ! (( SB_MODE )); then
    local input_gw
    read -rp "请确认外网网关 [$HK_EXTERNAL_GW]: " input_gw
    HK_EXTERNAL_GW="${input_gw:-$HK_EXTERNAL_GW}"
  fi

  info "香港端路由配置信息:"
  info "  外网接口: $HK_EXTERNAL_IF ($HK_EXTERNAL_IP)"
  info "  内网接口: $HK_INTERNAL_IF ($HK_INTERNAL_NETWORK)"
  info "  外网网关: $HK_EXTERNAL_GW"
}

# 配置中国内地端路由信息
ensure_qh_route_info() {
  ensure_remote_context || return 1

  info "获取中国内地端网络配置..."

  # 获取中国内地端网卡列表及IP信息
  echo ""
  echo "中国内地端检测到的网卡列表:"

  local interfaces_raw=$(remote_exec "ip link show | grep -E '^[0-9]+:' | awk '{print \$2}' | sed 's/:$//' | grep -v '^lo\$'")
  local interfaces=($interfaces_raw)
  local -a if_ips=()
  local -a if_networks=()

  for i in "${!interfaces[@]}"; do
    local if_name="${interfaces[$i]}"
    local if_ip=$(remote_exec "ip -o -4 addr show $if_name 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1")
    if [[ -z "$if_ip" ]]; then
      if_ip=$(remote_exec "ip -o -6 addr show $if_name scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1")
    fi

    local if_net=$(remote_exec "ip -o -4 addr show $if_name 2>/dev/null | awk '{print \$4}' | head -n1")
    if [[ -z "$if_net" ]]; then
      if_net=$(remote_exec "ip -o -6 addr show $if_name scope global 2>/dev/null | awk '{print \$4}' | head -n1")
    fi
    if_ips[$i]="$if_ip"
    if_networks[$i]="$if_net"
    echo "$((i+1)). $if_name - IP: ${if_ip:-无} 网段: ${if_net:-无}"
  done

  local default_qh_ext_if=""
  local default_qh_int_if=""
  local default_qh_int_pri=0

  for i in "${!interfaces[@]}"; do
    local if_name="${interfaces[$i]}"
    local if_ip="${if_ips[$i]}"
    if [[ -z "$default_qh_ext_if" ]] && is_public_ip "$if_ip"; then
      default_qh_ext_if="$if_name"
    fi
    if [[ -z "$default_qh_int_if" ]] && is_private_ipv4 "$if_ip"; then
      default_qh_int_if="$if_name"
    fi

    if is_private_ipv4 "$if_ip"; then
      local pri
      pri=$(private_ip_priority "$if_ip")
      if (( pri > default_qh_int_pri )); then
        default_qh_int_pri="$pri"
        default_qh_int_if="$if_name"
      fi
    fi
  done

  if [[ -z "$default_qh_ext_if" ]]; then
    default_qh_ext_if="${interfaces[0]:-}"
  fi

  if [[ -z "$default_qh_int_if" || "$default_qh_int_if" == "$default_qh_ext_if" ]]; then
    for i in "${!interfaces[@]}"; do
      local if_name="${interfaces[$i]}"
      [[ "$if_name" == "$default_qh_ext_if" ]] && continue
      if [[ -n "${if_ips[$i]}" ]]; then
        default_qh_int_if="$if_name"
        break
      fi
    done
  fi

  [[ -z "$default_qh_int_if" ]] && default_qh_int_if="${default_qh_ext_if:-}"

  # 选择中国内地端外网接口
  local choice
  if (( SB_MODE )); then
    QH_EXTERNAL_IF="${QH_EXTERNAL_IF:-$default_qh_ext_if}"
    [[ -z "$QH_EXTERNAL_IF" ]] && QH_EXTERNAL_IF="${interfaces[0]:-}"
    QH_INTERNAL_IF="${QH_INTERNAL_IF:-$default_qh_int_if}"
    [[ -z "$QH_INTERNAL_IF" ]] && QH_INTERNAL_IF="$QH_EXTERNAL_IF"

    if ! remote_exec "ip link show $QH_EXTERNAL_IF" &>/dev/null; then
      err "自动选择的中国内地端外网接口 $QH_EXTERNAL_IF 不存在"
      return 1
    fi
    QH_EXTERNAL_IP=$(remote_exec "ip -o -4 addr show $QH_EXTERNAL_IF 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1")
    if [[ -z "$QH_EXTERNAL_IP" ]]; then
      QH_EXTERNAL_IP=$(remote_exec "ip -o -6 addr show $QH_EXTERNAL_IF scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1")
    fi
    if [[ -z "$QH_EXTERNAL_IP" ]]; then
      err "自动选择的外网接口 $QH_EXTERNAL_IF 未配置IP地址"
      return 1
    fi
    QH_EXTERNAL_FAMILY=$(ip_family "$QH_EXTERNAL_IP")

    if ! remote_exec "ip link show $QH_INTERNAL_IF" &>/dev/null; then
      err "自动选择的中国内地端内网接口 $QH_INTERNAL_IF 不存在"
      return 1
    fi
  else
    while true; do
      read -rp "请选择中国内地端外网接口 (默认 ${default_qh_ext_if:-无}): " choice
      if [[ -z "$choice" ]]; then
        QH_EXTERNAL_IF="$default_qh_ext_if"
      elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#interfaces[@]} )); then
        QH_EXTERNAL_IF="${interfaces[$((choice-1))]}"
      else
        QH_EXTERNAL_IF="$choice"
      fi

      if ! in_detected_interfaces "$QH_EXTERNAL_IF" "${interfaces[@]}"; then
        warn "输入的网卡 $QH_EXTERNAL_IF 不在检测到的列表中，请检查网卡名称是否正确"
      fi

      # 检查接口是否存在并获取IP
      if ! remote_exec "ip link show $QH_EXTERNAL_IF" &>/dev/null; then
        err "中国内地端网卡 $QH_EXTERNAL_IF 不存在"
        continue
      fi

      QH_EXTERNAL_IP=$(remote_exec "ip -o -4 addr show $QH_EXTERNAL_IF 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1")
      if [[ -z "$QH_EXTERNAL_IP" ]]; then
        QH_EXTERNAL_IP=$(remote_exec "ip -o -6 addr show $QH_EXTERNAL_IF scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1")
      fi
      if [[ -z "$QH_EXTERNAL_IP" ]]; then
        err "中国内地端网卡 $QH_EXTERNAL_IF 没有配置IP地址"
        continue
      fi
      QH_EXTERNAL_FAMILY=$(ip_family "$QH_EXTERNAL_IP")
      break
    done

    # 选择中国内地端内网接口
    while true; do
      read -rp "请选择中国内地端内网接口 (默认 ${default_qh_int_if:-无}): " choice
      if [[ -z "$choice" ]]; then
        QH_INTERNAL_IF="$default_qh_int_if"
      elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#interfaces[@]} )); then
        QH_INTERNAL_IF="${interfaces[$((choice-1))]}"
      else
        QH_INTERNAL_IF="$choice"
      fi

      if ! in_detected_interfaces "$QH_INTERNAL_IF" "${interfaces[@]}"; then
        warn "输入的网卡 $QH_INTERNAL_IF 不在检测到的列表中，请检查网卡名称是否正确"
      fi

      # 检查接口是否存在
      if ! remote_exec "ip link show $QH_INTERNAL_IF" &>/dev/null; then
        err "中国内地端网卡 $QH_INTERNAL_IF 不存在"
        continue
      fi
      break
    done
  fi

  # 获取中国内地端网关
  QH_EXTERNAL_GW=$(remote_exec "ip route | awk '/default/ && /dev $QH_EXTERNAL_IF/ {print \$3; exit}'")
  if [[ -z "$QH_EXTERNAL_GW" ]]; then
    QH_EXTERNAL_GW=$(remote_exec "ip -6 route | awk '/default/ && /dev $QH_EXTERNAL_IF/ {for(i=1;i<=NF;i++){if(\$i==\"via\"){print \$(i+1); exit}}}'")
  fi
  if [[ -z "$QH_EXTERNAL_GW" ]]; then
    if [[ "$(ip_family "$QH_EXTERNAL_IP")" == "4" ]]; then
      QH_EXTERNAL_GW=$(echo "$QH_EXTERNAL_IP" | awk -F'.' '{print $1"."$2"."$3".1"}')
      warn "自动推算中国内地端网关: $QH_EXTERNAL_GW"
    else
      warn "未检测到中国内地端外网网关，请确认后输入"
    fi
  else
    info "检测到中国内地端网关: $QH_EXTERNAL_GW"
  fi

  local input_gw
  if (( SB_MODE )); then
    input_gw=""
  else
    read -rp "请确认中国内地端外网网关 [$QH_EXTERNAL_GW]: " input_gw
  fi
  QH_EXTERNAL_GW="${input_gw:-$QH_EXTERNAL_GW}"

  info "中国内地端路由配置信息:"
  info "  外网接口: $QH_EXTERNAL_IF ($QH_EXTERNAL_IP)"
  info "  内网接口: $QH_INTERNAL_IF"
  info "  外网网关: $QH_EXTERNAL_GW"
}

# 检查中国内地端策略路由状态，确保可安全切换默认路由
verify_qh_route_before_default() {
  ensure_basic_info
  ensure_remote_context || return 1

  local -a issues=()

  if ! remote_exec "test -f /etc/qh_route_status"; then
    issues+=("未检测到 /etc/qh_route_status 标记文件")
  fi

  if ! remote_exec "ip rule show | grep -q '$ROUTE_TABLE_NAME'"; then
    issues+=("策略路由规则缺失")
  fi

  if ! remote_exec "ping -c 2 -W 2 $HK_LAN_IP >/dev/null 2>&1"; then
    issues+=("无法从中国内地端连通香港内网 IP $HK_LAN_IP")
  fi

  if ((${#issues[@]})); then
    warn "默认路由切换前检查未通过："
    for msg in "${issues[@]}"; do
      warn "  - $msg"
    done
    warn "请先执行菜单选项3（配置中国内地端策略路由）并确认链路正常后再试。"
    return 1
  fi

  info "策略路由状态已验证，可安全切换默认路由"
  return 0
}

# 使用多种方式更新中国内地端 /etc/resolv.conf，避免DNS修改失败
update_remote_dns_servers() {
  local -a dns_list=("$@")
  if ((${#dns_list[@]} == 0)); then
    warn "未提供DNS服务器，跳过DNS配置"
    return 1
  fi

  if remote_sudo "bash -s" "${dns_list[@]}" <<'EOF'; then
set -euo pipefail
dns_list=("$@")
tmp_file=$(mktemp /tmp/route_resolv.XXXXXX)
{
  echo "# DNS servers configured for route mode"
  for dns in "${dns_list[@]}"; do
    echo "nameserver $dns"
  done
} >"$tmp_file"

if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q systemd-resolved.service; then
  if [ ! -f /etc/qh_systemd_resolved_state ]; then
    was_active=$(systemctl is-active systemd-resolved 2>/dev/null || echo unknown)
    was_enabled=$(systemctl is-enabled systemd-resolved 2>/dev/null || echo unknown)
    printf "was_active=%s\nwas_enabled=%s\n" "$was_active" "$was_enabled" > /etc/qh_systemd_resolved_state
  fi
  systemctl stop systemd-resolved >/dev/null 2>&1 || true
  systemctl disable systemd-resolved >/dev/null 2>&1 || true

  if [ -f /etc/nsswitch.conf ] && grep -Eq '^hosts:.*resolve' /etc/nsswitch.conf; then
    if [ ! -f /etc/nsswitch.conf.qhbackup ]; then
      cp /etc/nsswitch.conf /etc/nsswitch.conf.qhbackup
    fi
    tmp_nss=$(mktemp /tmp/nsswitch.XXXXXX)
    awk '{
      if ($1 == "hosts:") {
        line = $0
        gsub(/\t/, " ", line)
        while (gsub(/  +/, " ", line));
        while (gsub(/ resolve(\s+\[!UNAVAIL=return\])?/, "", line));
        while (gsub(/  +/, " ", line));
        sub(/[[:space:]]+$/, "", line)
        if (line !~ / dns( |$)/) {
          line = line " dns"
        }
        print line
      } else {
        print
      }
    }' /etc/nsswitch.conf > "$tmp_nss"
    cp "$tmp_nss" /etc/nsswitch.conf
    rm -f "$tmp_nss"
  fi
fi

if [ -L /etc/resolv.conf ]; then
  rm -f /etc/resolv.conf
fi
chattr -i /etc/resolv.conf 2>/dev/null || true

if cp "$tmp_file" /etc/resolv.conf 2>/dev/null; then
  chmod 644 /etc/resolv.conf 2>/dev/null || true
  rm -f "$tmp_file"
  exit 0
fi
if install -m 644 "$tmp_file" /etc/resolv.conf 2>/dev/null; then
  rm -f "$tmp_file"
  exit 0
fi
if cat "$tmp_file" | tee /etc/resolv.conf >/dev/null 2>&1; then
  chmod 644 /etc/resolv.conf 2>/dev/null || true
  rm -f "$tmp_file"
  exit 0
fi

rm -f "$tmp_file"
exit 1
EOF
    return 0
  fi

  return 1
}

# 在中国内地端安装并启用 cron，带重试与容错
install_remote_cron() {
  ensure_remote_context || return 1
  if remote_exec "which crontab >/dev/null 2>&1"; then
    return 0
  fi

  local target_gw="${CURRENT_QH_INT_GW:-$HK_LAN_IP}"
  local target_if="$QH_INTERNAL_IF"
  local temp_default_set=0
  local previous_default=""

  if [[ -n "$target_gw" && -n "$target_if" ]]; then
    previous_default=$(remote_exec "ip route show default | head -n1")
    if remote_sudo "ip route replace default via $target_gw dev $target_if" >/dev/null 2>&1; then
      temp_default_set=1
      info "临时切换默认路由以安装 cron (via $target_gw/$target_if)"
    else
      warn "无法临时切换默认路由，cron 安装可能失败"
    fi
  else
    warn "缺少内网网关信息，无法临时调整默认路由"
  fi

  local pkg_mgr=""
  if remote_exec "command -v apt-get >/dev/null 2>&1"; then
    pkg_mgr="apt"
  elif remote_exec "command -v yum >/dev/null 2>&1"; then
    pkg_mgr="yum"
  elif remote_exec "command -v dnf >/dev/null 2>&1"; then
    pkg_mgr="dnf"
  else
    warn "无法识别中国内地端包管理器，跳过 cron 安装"
    return 1
  fi

  local attempt=1 success=0 max_attempts=1
  info "开始在中国内地端安装 cron，此步骤耗时可能较长，请耐心等待..."
  while (( attempt <= max_attempts )); do
    info "尝试在中国内地端安装 cron (${attempt}/${max_attempts})..."
    case "$pkg_mgr" in
      apt)
        if remote_sudo "bash -s" <<'EOF' >/dev/null 2>&1; then
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=3 update -qq
apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=3 -y -qq install cron
EOF
          success=1
          break
        fi
        ;;
      yum)
        if remote_sudo "bash -s" <<'EOF' >/dev/null 2>&1; then
set -e
yum -y -q install cronie
EOF
          success=1
          break
        fi
        ;;
      dnf)
        if remote_sudo "bash -s" <<'EOF' >/dev/null 2>&1; then
set -e
dnf -y -q install cronie
EOF
          success=1
          break
        fi
        ;;
    esac
    attempt=$((attempt + 1))
    if (( attempt <= max_attempts )); then
      sleep 5
    fi
  done

  if (( temp_default_set == 1 )); then
    if [[ -n "$previous_default" ]]; then
      remote_sudo bash -c "ip route replace $previous_default" >/dev/null 2>&1 || \
        remote_sudo bash -c "ip route add $previous_default" >/dev/null 2>&1 || \
        remote_sudo "ip route add default via $QH_EXTERNAL_GW dev $QH_EXTERNAL_IF" >/dev/null 2>&1 || true
    else
      remote_sudo "ip route del default 2>/dev/null || true"
    fi
    info "已恢复原默认路由"
  fi

  if (( success == 0 )); then
    warn "cron 安装失败，将继续使用 systemd timer 方案"
    return 1
  fi

  remote_sudo "systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true"

  if remote_exec "which crontab >/dev/null 2>&1"; then
    info "cron 服务已安装并可用"
    return 0
  fi

  warn "cron 似乎仍不可用，将回退到 systemd timer"
  return 1
}

disable_remote_auto_upgrade() {
  ensure_remote_context || return 1
  if ! remote_exec "test -f /etc/debian_version"; then
    info "中国内地端非 Debian 系统，跳过自动 apt upgrade 服务处理"
    return 0
  fi

  if remote_exec "test -f $AUTO_UPGRADE_STATE_FILE"; then
    info "检测到 ${AUTO_UPGRADE_STATE_FILE} 标签，自动 apt upgrade 服务此前已被禁用"
    return 0
  fi

  if remote_sudo bash -s "$AUTO_UPGRADE_STATE_FILE" <<'EOF'; then
state_file="$1"
set -euo pipefail
units=(apt-daily.timer apt-daily.service apt-daily-upgrade.timer apt-daily-upgrade.service unattended-upgrades.service unattended-upgrades.timer)
tmp=$(mktemp)
touched=0
for unit in "${units[@]}"; do
  if systemctl list-unit-files "$unit" >/dev/null 2>&1; then
    touched=1
    state=$(systemctl is-enabled "$unit" 2>/dev/null || echo unknown)
    printf '%s=%s\n' "$unit" "$state" >>"$tmp"
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl disable "$unit" >/dev/null 2>&1 || true
  fi
done
if [ "$touched" -eq 1 ]; then
  mv "$tmp" "$state_file"
else
  rm -f "$tmp"
fi
systemctl daemon-reload >/dev/null 2>&1 || true
EOF
    info "已禁用自动 apt upgrade 服务，并记录状态至 ${AUTO_UPGRADE_STATE_FILE}"
  else
    warn "禁用自动 apt upgrade 服务失败，请手动检查"
    return 1
  fi
}

restore_remote_auto_upgrade() {
  ensure_remote_context || return 1
  if ! remote_exec "test -f $AUTO_UPGRADE_STATE_FILE"; then
    return 0
  fi

  if remote_sudo bash -s "$AUTO_UPGRADE_STATE_FILE" <<'EOF'; then
state_file="$1"
set -euo pipefail
if [ ! -f "$state_file" ]; then
  exit 0
fi
while IFS='=' read -r unit state; do
  [ -z "$unit" ] && continue
  if ! systemctl list-unit-files "$unit" >/dev/null 2>&1; then
    continue
  fi
  case "$state" in
    enabled|enabled-runtime)
      systemctl unmask "$unit" >/dev/null 2>&1 || true
      systemctl enable "$unit" >/dev/null 2>&1 || true
      systemctl start "$unit" >/dev/null 2>&1 || true
      ;;
    disabled|disabled-runtime)
      systemctl unmask "$unit" >/dev/null 2>&1 || true
      systemctl disable "$unit" >/dev/null 2>&1 || true
      ;;
    masked)
      systemctl mask "$unit" >/dev/null 2>&1 || true
      ;;
    static|unknown|*)
      systemctl unmask "$unit" >/dev/null 2>&1 || true
      ;;
  esac
done < "$state_file"
rm -f "$state_file"
systemctl daemon-reload >/dev/null 2>&1 || true
EOF
    info "已根据 ${AUTO_UPGRADE_STATE_FILE} 恢复自动 apt upgrade 服务状态"
  else
    warn "恢复自动 apt upgrade 服务状态失败，请手动检查 ${AUTO_UPGRADE_STATE_FILE}"
    return 1
  fi
}

# 香港端设置SNAT路由
setup_hk_route() {
  ensure_hk_route_info

  info "开始配置香港端SNAT路由..."
  clean_local_legacy_rules
  mark_action "hk_route" "开始配置，已清理旧规则"

  local use_nft=0
  if command -v nft >/dev/null 2>&1; then
    use_nft=1
    info "检测到 nftables，优先使用 nftables 进行SNAT配置"
  fi

  info "清理可能存在的旧版规则..."
  nft delete table ip hk_snat >/dev/null 2>&1 || true
  iptables -t nat -D POSTROUTING -s "$HK_INTERNAL_NETWORK" -o "$HK_EXTERNAL_IF" -j SNAT --to-source "$HK_EXTERNAL_IP" 2>/dev/null || true
  iptables -D FORWARD -s "$QIANHAI_LAN_IP" -i "$HK_INTERNAL_IF" -o "$HK_EXTERNAL_IF" -j ACCEPT 2>/dev/null || true

  # 启用IP转发
  info "启用IP转发..."
  echo 1 > /proc/sys/net/ipv4/ip_forward
  [[ -f /etc/sysctl.conf ]] || touch /etc/sysctl.conf
  if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
  fi

  # 清除可能存在的旧规则
  info "清理旧的SNAT规则..."
  iptables -t nat -D POSTROUTING -s "$HK_INTERNAL_NETWORK" -o "$HK_EXTERNAL_IF" -j SNAT --to-source "$HK_EXTERNAL_IP" 2>/dev/null || true

  if (( use_nft )); then
    nft delete table ip hk_snat >/dev/null 2>&1 || true
    nft add table ip hk_snat
    nft 'add chain ip hk_snat forward { type filter hook forward priority 0; policy drop; }'
    nft 'add chain ip hk_snat postrouting { type nat hook postrouting priority 100; }'
    nft 'add rule ip hk_snat forward ct state established,related accept'
    nft "add rule ip hk_snat forward ip saddr $QIANHAI_LAN_IP iif $HK_INTERNAL_IF oif $HK_EXTERNAL_IF accept"
    nft "add rule ip hk_snat postrouting ip saddr $HK_INTERNAL_NETWORK oif $HK_EXTERNAL_IF snat to $HK_EXTERNAL_IP"

    info "保存 nftables 规则..."
    if [ -w /etc/nftables.conf ]; then
      nft list ruleset > /etc/nftables.conf 2>/dev/null || true
    elif command -v netfilter-persistent >/dev/null 2>&1; then
      netfilter-persistent save >/dev/null 2>&1 || true
    fi
  else
    # 设置FORWARD链默认策略
    info "设置转发策略..."
    iptables -P FORWARD DROP

    # 允许已建立的连接
    if ! iptables -C FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
      info "允许已建立和相关的连接..."
      iptables -I FORWARD 1 -m state --state ESTABLISHED,RELATED -j ACCEPT
    fi

    # 允许中国内地端IP转发
    info "允许中国内地端 $QIANHAI_LAN_IP 的转发..."
    if ! iptables -C FORWARD -s "$QIANHAI_LAN_IP" -i "$HK_INTERNAL_IF" -o "$HK_EXTERNAL_IF" -j ACCEPT 2>/dev/null; then
      iptables -I FORWARD 2 -s "$QIANHAI_LAN_IP" -i "$HK_INTERNAL_IF" -o "$HK_EXTERNAL_IF" -j ACCEPT
    fi

    # 配置SNAT
    info "配置SNAT规则..."
    iptables -t nat -A POSTROUTING -s "$HK_INTERNAL_NETWORK" -o "$HK_EXTERNAL_IF" -j SNAT --to-source "$HK_EXTERNAL_IP"

    # 保存规则
    info "保存iptables规则..."
    if command -v netfilter-persistent &>/dev/null; then
      netfilter-persistent save >/dev/null 2>&1
    else
      mkdir -p /etc/iptables
      iptables-save > /etc/iptables/rules.v4
    fi
  fi

  # 创建持久化配置
  info "创建香港端持久化配置..."

  # 创建恢复脚本
cat > /usr/local/bin/restore-hk-snat.sh << HKSCRIPT_EOF
#!/bin/bash
# 恢复香港端SNAT配置

USE_NFT=0
if command -v nft >/dev/null 2>&1; then
  USE_NFT=1
fi

# 等待网络接口就绪
sleep 10

# [KKIX-PATCH] 等内外网口都拿到 IPv4 地址再继续（最长 60 秒），避免开机竞态
for _i in \$(seq 1 30); do
  if ip -4 addr show "$HK_INTERNAL_IF" 2>/dev/null | grep -q 'inet ' && ip -4 addr show "$HK_EXTERNAL_IF" 2>/dev/null | grep -q 'inet '; then
    break
  fi
  sleep 2
done

echo 1 > /proc/sys/net/ipv4/ip_forward

if [ "\$USE_NFT" -eq 1 ]; then
  nft delete table ip hk_snat >/dev/null 2>&1 || true
  nft add table ip hk_snat
  nft 'add chain ip hk_snat forward { type filter hook forward priority 0; policy drop; }'
  nft 'add chain ip hk_snat postrouting { type nat hook postrouting priority 100; }'
  nft 'add rule ip hk_snat forward ct state established,related accept'
  nft 'add rule ip hk_snat forward ip saddr $QIANHAI_LAN_IP iif $HK_INTERNAL_IF oif $HK_EXTERNAL_IF accept'
  nft 'add rule ip hk_snat postrouting ip saddr $HK_INTERNAL_NETWORK oif $HK_EXTERNAL_IF snat to $HK_EXTERNAL_IP'
  # [KKIX-PATCH] 原版此处空 if（then 后无语句）导致生成的恢复脚本语法错误，已删除该空块
else
  # 启用IP转发
  echo 1 > /proc/sys/net/ipv4/ip_forward

  # 设置FORWARD链默认策略
  iptables -P FORWARD DROP

  # 允许已建立的连接
  iptables -I FORWARD 1 -m state --state ESTABLISHED,RELATED -j ACCEPT

  # 允许中国内地端IP转发
  iptables -I FORWARD 2 -s $QIANHAI_LAN_IP -i $HK_INTERNAL_IF -o $HK_EXTERNAL_IF -j ACCEPT

  # 配置SNAT
  iptables -t nat -D POSTROUTING -s $HK_INTERNAL_NETWORK -o $HK_EXTERNAL_IF -j SNAT --to-source $HK_EXTERNAL_IP 2>/dev/null || true
  iptables -t nat -A POSTROUTING -s $HK_INTERNAL_NETWORK -o $HK_EXTERNAL_IF -j SNAT --to-source $HK_EXTERNAL_IP
fi

logger -t restore-snat 'HK SNAT configuration restored'
HKSCRIPT_EOF

  chmod +x /usr/local/bin/restore-hk-snat.sh

  # 创建systemd服务
  cat > /etc/systemd/system/hk-snat-restore.service << 'HKSERVICE_EOF'
[Unit]
Description=Restore HK SNAT Configuration
After=network-online.target cloud-init.service
Wants=network-online.target
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/restore-hk-snat.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
HKSERVICE_EOF

  # 启用服务
  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable hk-snat-restore.service >/dev/null 2>&1
  info "已创建香港端开机自动恢复服务"

  # 防止cloud-init重置网络配置
  if [ ! -f /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg ]; then
    info "配置cloud-init..."
    mkdir -p /etc/cloud/cloud.cfg.d/
    cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg << 'CLOUD_EOF'
network: {config: disabled}
CLOUD_EOF
    info "已禁用cloud-init网络重置"
  fi

  # 确保sysctl配置持久化
  [[ -f /etc/sysctl.conf ]] || touch /etc/sysctl.conf
  if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
  fi

  info ""
  info "========================================="
  info "香港端SNAT路由配置完成！"
  info "========================================="
  info "内网段: $HK_INTERNAL_NETWORK ($HK_INTERNAL_IF)"
  info "公网IP: $HK_EXTERNAL_IP ($HK_EXTERNAL_IF)"
  info "允许转发的IP: $QIANHAI_LAN_IP"
  info "配置已持久化，重启后自动恢复"
  info "========================================="
  mark_state_flag "$HK_ROUTE_FLAG"
  write_local_flag "$HK_ROUTE_META" "mode=route" "backend=$([[ $use_nft -eq 1 ]] && echo nft || echo iptables)" "hk_external_if=$HK_EXTERNAL_IF" "hk_internal_if=$HK_INTERNAL_IF"
}

# 香港端清除SNAT路由
clear_hk_route() {
  ensure_hk_route_info

  info "清除香港端SNAT路由配置..."
  clean_local_legacy_rules
  mark_action "hk_route_clear" "开始清除，已清理旧规则"
  local use_nft=0
  if command -v nft >/dev/null 2>&1; then
    use_nft=1
  fi
  read -rp "是否同时清理中国内地端策略路由？[y/N]: " clear_remote_route
  if [[ "$clear_remote_route" == "y" || "$clear_remote_route" == "Y" ]]; then
    run_menu_action "清除中国内地端策略路由" clear_qh_route || true
  fi

  # 删除NAT规则
  info "删除SNAT规则..."
  nft delete table ip hk_snat >/dev/null 2>&1 || true
  iptables -t nat -D POSTROUTING -s "$HK_INTERNAL_NETWORK" -o "$HK_EXTERNAL_IF" -j SNAT --to-source "$HK_EXTERNAL_IP" 2>/dev/null || true
  # 删除FORWARD规则
  info "删除转发规则..."
  iptables -D FORWARD -s "$QIANHAI_LAN_IP" -i "$HK_INTERNAL_IF" -o "$HK_EXTERNAL_IF" -j ACCEPT 2>/dev/null || true

  # 清理持久化配置
  info "清理持久化配置..."

  # 停用并删除systemd服务
  if systemctl list-unit-files 2>/dev/null | grep -q 'hk-snat-restore.service'; then
    systemctl disable hk-snat-restore.service >/dev/null 2>&1 || true
    systemctl stop hk-snat-restore.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/hk-snat-restore.service
    systemctl daemon-reload >/dev/null 2>&1
    info "已删除自动恢复服务"
  fi

  # 删除恢复脚本
  rm -f /usr/local/bin/restore-hk-snat.sh

  # 恢复cloud-init配置（仅在没有其他服务需要时）
  if [ -f /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg ]; then
    # 检查是否还有其他服务需要保留cloud-init配置
    if ! systemctl list-unit-files 2>/dev/null | grep -q 'qh-route-restore.service'; then
      rm -f /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
      info "已恢复cloud-init配置"
    fi
  fi

  # 保存规则
  if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save >/dev/null 2>&1
  else
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
  fi

  info "香港端SNAT路由配置已完全清除"
  clear_state_flag "$HK_ROUTE_FLAG"
  rm -f "$HK_ROUTE_META"
}


# 中国内地端设置策略路由
setup_qh_route() {
  if ! confirm_hk_dependency "route" "设置中国内地端策略路由"; then
    return 1
  fi
  if ! ensure_qh_route_info; then
    warn "无法获取中国内地端网络信息，已取消配置"
    return 1
  fi

  info "开始配置中国内地端策略路由..."
  clean_remote_legacy_rules
  mark_action "qh_route" "开始配置中国内地端策略路由并清理旧规则"
  write_remote_flag "$REMOTE_ROUTE_FLAG" "mode=route" "status=init"

  local qh_is_debian=0
  if remote_exec "test -f /etc/debian_version"; then
    qh_is_debian=1
  fi

  local qh_external_family="${QH_EXTERNAL_FAMILY:-$(ip_family "$QH_EXTERNAL_IP")}"
  local ip_ext_cmd="ip"
  if [[ "$qh_external_family" == "6" ]]; then
    ip_ext_cmd="ip -6"
  fi
  local remote_use_nft=0
  if remote_exec "command -v nft >/dev/null 2>&1"; then
    remote_use_nft=1
    info "检测到中国内地端支持 nftables，优先使用 nftables 配置标记规则"
  fi

  info "清理旧版标记规则..."
  remote_sudo "nft delete table inet qh_mark >/dev/null 2>&1 || true"
  remote_sudo "iptables -t mangle -D PREROUTING -i $QH_EXTERNAL_IF -j CONNMARK --set-mark $ROUTE_MARK 2>/dev/null || true"
  remote_sudo "iptables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null || true"
  if [[ "$qh_external_family" == "6" ]]; then
    remote_sudo "if command -v ip6tables >/dev/null 2>&1; then ip6tables -t mangle -D PREROUTING -i $QH_EXTERNAL_IF -j CONNMARK --set-mark $ROUTE_MARK 2>/dev/null || true; ip6tables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null || true; fi"
  fi

  if (( qh_is_debian )); then
    echo ""
    info "检测到 Debian 自动 apt upgrade 服务可能在重启后还原路由配置"
    local disable_auto_upgrade_choice=""
    if (( SB_MODE )); then
      disable_auto_upgrade_choice="y"
      info "sbmode: 自动选择禁用自动 apt upgrade 服务"
    else
      read -rp "是否禁用该自动 apt upgrade 服务？[Y/n]: " disable_auto_upgrade_choice
    fi
    if [[ "$disable_auto_upgrade_choice" != "n" && "$disable_auto_upgrade_choice" != "N" ]]; then
      if ! disable_remote_auto_upgrade; then
        warn "禁用自动 apt upgrade 服务失败，请稍后确认其状态"
      fi
    else
      info "已按您的选择保留自动 apt upgrade 服务"
    fi
  else
    info "中国内地端似乎不是 Debian 系统，跳过自动 apt upgrade 服务处理"
  fi

  # 保存原始默认路由（智能检测）
  info "检测原始路由配置..."

  # 首先检查是否有真正的原始路由备份（第一次运行时创建的）
  if remote_exec "test -f ~/.true_original_default_route"; then
    info "使用已保存的原始路由配置"
  else
    # 获取当前默认路由
    local current_default=$(remote_exec "ip route show default" | head -n1)
    if [[ -z "$current_default" ]]; then
      current_default=$(remote_exec "ip -6 route show default" | head -n1)
    fi

    # 检查当前路由是否指向内网（可能是已修改的）
    if [[ "$current_default" == *"$QH_INTERNAL_IF"* ]] || [[ "$current_default" == *"192.168"* ]] || [[ "$current_default" == *"10."* ]]; then
      warn "检测到当前默认路由可能已被修改，尝试推测原始路由"
      # 如果当前路由是内网的，说明可能已经被修改过了
      # 使用外网接口和网关作为原始路由
      local guessed_route="default via $QH_EXTERNAL_GW dev $QH_EXTERNAL_IF"
      info "推测原始路由为: $guessed_route"
      remote_exec "echo '$guessed_route' > ~/.true_original_default_route"
    else
      # 当前路由看起来是原始的（指向外网）
      info "当前默认路由: $current_default"
      remote_exec "echo '$current_default' > ~/.true_original_default_route"
    fi
  fi

  # 保存当前状态作为回滚点（但不是真正的原始路由）
  local current_default=$(remote_exec "ip route show default" | head -n1)
  if [[ -z "$current_default" ]]; then
    current_default=$(remote_exec "ip -6 route show default" | head -n1)
  fi
  if [[ -n "$current_default" ]]; then
    remote_exec "echo '$current_default' > ~/.last_default_route"
  fi

  # 创建路由表
  info "创建路由表 $ROUTE_TABLE_NAME..."
  # 先检查文件是否存在，如果不存在则创建
  if ! remote_exec "test -f /etc/iproute2/rt_tables"; then
    info "创建 /etc/iproute2/rt_tables 文件..."
    remote_sudo "mkdir -p /etc/iproute2"
    remote_sudo bash -c "cat > /etc/iproute2/rt_tables << 'RTEOF'
#
# reserved values
#
255	local
254	main
253	default
0	unspec
#
# local
#
RTEOF"
  fi

  if ! remote_exec "grep -q '$ROUTE_TABLE_NAME' /etc/iproute2/rt_tables"; then
    remote_sudo "echo '$ROUTE_TABLE_ID $ROUTE_TABLE_NAME' >> /etc/iproute2/rt_tables"
  fi

  # 清理现有规则（但不删除主路由表的默认路由）
  info "清理现有策略路由配置..."
  # 确保使用纯IP地址进行清理
  local qh_ext_ip_clean="$QH_EXTERNAL_IP"
  if [[ "$qh_ext_ip_clean" == *"/"* ]]; then
    qh_ext_ip_clean=$(echo "$qh_ext_ip_clean" | cut -d/ -f1)
  fi
  remote_sudo "while $ip_ext_cmd rule del from $qh_ext_ip_clean table $ROUTE_TABLE_NAME 2>/dev/null; do :; done"
  remote_sudo "while $ip_ext_cmd rule del fwmark $ROUTE_MARK table $ROUTE_TABLE_NAME 2>/dev/null; do :; done"
  remote_sudo "$ip_ext_cmd route flush table $ROUTE_TABLE_NAME 2>/dev/null || true"

  # 获取网段信息
  local qh_ext_network=$(remote_exec "ip -o -4 addr show $QH_EXTERNAL_IF 2>/dev/null | awk '{print \$4}' | head -n1")
  if [[ -z "$qh_ext_network" ]]; then
    qh_ext_network=$(remote_exec "ip -o -6 addr show $QH_EXTERNAL_IF scope global 2>/dev/null | awk '{print \$4}' | head -n1")
  fi
  local qh_int_network=$(remote_exec "ip -o -4 addr show $QH_INTERNAL_IF 2>/dev/null | awk '{print \$4}' | head -n1")
  if [[ -z "$qh_int_network" ]]; then
    qh_int_network=$(remote_exec "ip -o -6 addr show $QH_INTERNAL_IF scope global 2>/dev/null | awk '{print \$4}' | head -n1")
  fi

  # 智能修正网段掩码
  # 检查外网网段是否合理
  local qh_ext_ip_only=$(echo "$qh_ext_network" | cut -d/ -f1)
  local qh_ext_mask=$(echo "$qh_ext_network" | cut -d/ -f2)

  # 验证掩码是否合理，如果不合理，根据IP地址类型推测
  if [[ "$qh_external_family" == "4" && "$qh_ext_mask" == "24" ]]; then
    local first_octet=$(echo "$qh_ext_ip_only" | cut -d. -f1)
    if [[ "$qh_ext_ip_only" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
      local network_prefix="${BASH_REMATCH[1]}"
      # 仅在网关不在同一 /24 网段时才收窄为 /32，避免无效网关
      if [[ -n "$QH_EXTERNAL_GW" && "$QH_EXTERNAL_GW" != "$network_prefix."* ]] && (( first_octet >= 128 && first_octet <= 191 )); then
        warn "检测到外网网关不在接口网段内，使用单IP路由"
        qh_ext_network="${qh_ext_ip_only}/32"
      fi
    fi
  fi

  # 检查内网网段
  local qh_int_ip_only=$(echo "$qh_int_network" | cut -d/ -f1)
  local qh_int_mask=$(echo "$qh_int_network" | cut -d/ -f2)

  # 对于私有地址，通常使用 /24
  if [[ "$qh_int_ip_only" == 192.168.* ]] || [[ "$qh_int_ip_only" == 10.* ]]; then
    if [[ "$qh_int_mask" == "32" ]] || [[ "$qh_int_mask" == "31" ]]; then
      qh_int_network="${qh_int_ip_only}/24"
    fi
  fi
  # 确保获取的是纯IP地址，不包含掩码
  local qh_int_ip=$(remote_exec "ip -o -4 addr show $QH_INTERNAL_IF 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1")
  if [[ -z "$qh_int_ip" ]]; then
    qh_int_ip=$(remote_exec "ip -o -6 addr show $QH_INTERNAL_IF scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1")
  fi
  local ip_int_cmd="ip"
  if [[ "$qh_int_ip" == *:* ]]; then
    ip_int_cmd="ip -6"
  fi

  # 配置新路由
  info "配置路由规则..."

  # 设置默认路由走内网接口（通过香港端转发）
  # 确保 qh_int_ip 是纯IP地址
  if [[ "$qh_int_ip" == *"/"* ]]; then
    qh_int_ip=$(echo "$qh_int_ip" | cut -d/ -f1)
  fi

  # 内网网关通常是香港端的内网IP
  info "请输入香港端内网IP（用于策略路由）"
  local qh_int_gw
  if (( SB_MODE )); then
    qh_int_gw="$HK_LAN_IP"
    info "sbmode: 自动使用默认香港端内网IP $qh_int_gw"
  else
    read -rp "请输入香港端内网IP [$HK_LAN_IP]: " qh_int_gw
    qh_int_gw="${qh_int_gw:-$HK_LAN_IP}"
  fi
  CURRENT_QH_INT_GW="$qh_int_gw"

  # 注意：不再自动修改默认路由
  info "配置策略路由（保持当前默认路由不变）..."

  # 为内网添加到香港端的路由（不是默认路由）
  # 确保从内网IP发出的包能到达香港端
  remote_sudo "ip route add $HK_LAN_IP/32 via $qh_int_gw dev $QH_INTERNAL_IF 2>/dev/null || true"

  # 配置DNS
  info "配置DNS解析..."
  # 保存原始DNS配置
  if remote_exec "test -f /etc/resolv.conf"; then
    remote_exec "cp /etc/resolv.conf ~/.original_resolv.conf"
  fi

  local -a dns_servers=("8.8.8.8" "1.1.1.1")
  local use_hk_dns=""
  if (( SB_MODE )); then
    use_hk_dns="n"
    info "sbmode: 保持默认DNS配置"
  else
    read -rp "是否使用香港端作为DNS服务器？[y/N]: " use_hk_dns
  fi
  if [[ "$use_hk_dns" == "y" || "$use_hk_dns" == "Y" ]]; then
    dns_servers=("$qh_int_gw" "${dns_servers[@]}")
    info "已将香港端 $qh_int_gw 作为首选DNS"
  fi

  if update_remote_dns_servers "${dns_servers[@]}"; then
    info "DNS配置已更新为: ${dns_servers[*]}"
  else
    warn "DNS配置失败，请稍后确认 /etc/resolv.conf"
  fi

  # 为常用DNS服务器添加明确路由（确保通过香港端访问）
  info "为DNS服务器添加路由..."
  for dns in "${dns_servers[@]}"; do
    if [[ "$dns" == "$qh_int_gw" ]]; then
      continue
    fi
    remote_sudo "ip route add $dns/32 via $qh_int_gw dev $QH_INTERNAL_IF 2>/dev/null || true"
  done

  # 配置策略路由表
  info "配置策略路由表..."

  # 为内网源地址的流量创建单独的路由表
  # 创建一个新的路由表用于内网源流量
  local INTERNAL_TABLE="internal_out"
  local INTERNAL_TABLE_ID="101"

  if ! remote_exec "grep -q '$INTERNAL_TABLE' /etc/iproute2/rt_tables"; then
    remote_sudo "echo '$INTERNAL_TABLE_ID $INTERNAL_TABLE' >> /etc/iproute2/rt_tables"
  fi

  # 清空并配置内网出站路由表
  remote_sudo "$ip_int_cmd route flush table $INTERNAL_TABLE 2>/dev/null || true"
  remote_sudo "$ip_int_cmd route add default via $qh_int_gw dev $QH_INTERNAL_IF table $INTERNAL_TABLE"

  # 为内网源地址添加策略路由规则
  remote_sudo "$ip_int_cmd rule del from $qh_int_ip table $INTERNAL_TABLE 2>/dev/null || true"
  remote_sudo "$ip_int_cmd rule add from $qh_int_ip table $INTERNAL_TABLE priority 90"

  # 为外网接口配置回程路由表
  info "配置外网接口回程路由表..."
  # 在ix_return表中设置通过外网接口的默认路由
  remote_sudo "$ip_ext_cmd route add default via $QH_EXTERNAL_GW dev $QH_EXTERNAL_IF table $ROUTE_TABLE_NAME"

  # 确保使用纯IP地址作为src
  local qh_ext_ip_pure="$QH_EXTERNAL_IP"
  if [[ "$qh_ext_ip_pure" == *"/"* ]]; then
    qh_ext_ip_pure=$(echo "$qh_ext_ip_pure" | cut -d/ -f1)
  fi
  local qh_int_ip_pure="$qh_int_ip"
  if [[ "$qh_int_ip_pure" == *"/"* ]]; then
    qh_int_ip_pure=$(echo "$qh_int_ip_pure" | cut -d/ -f1)
  fi

  # 添加网段路由，但更安全地处理
  # 对于外网，如果网段有问题，只添加连接路由
  if [[ -n "$qh_ext_network" ]]; then
    # 尝试添加，如果失败则跳过
    remote_sudo "$ip_ext_cmd route add $qh_ext_network dev $QH_EXTERNAL_IF src $qh_ext_ip_pure table $ROUTE_TABLE_NAME 2>/dev/null || true"
  fi

  # 对于内网，尝试添加路由
  if [[ -n "$qh_int_network" ]]; then
    remote_sudo "$ip_int_cmd route add $qh_int_network dev $QH_INTERNAL_IF src $qh_int_ip_pure table $ROUTE_TABLE_NAME 2>/dev/null || true"
  fi

  # 添加策略路由规则
  info "添加策略路由规则..."
  # 确保使用纯IP地址
  local qh_ext_ip_for_rule="$QH_EXTERNAL_IP"
  if [[ "$qh_ext_ip_for_rule" == *"/"* ]]; then
    qh_ext_ip_for_rule=$(echo "$qh_ext_ip_for_rule" | cut -d/ -f1)
  fi
  remote_sudo "$ip_ext_cmd rule add from $qh_ext_ip_for_rule table $ROUTE_TABLE_NAME priority 100"
  remote_sudo "$ip_ext_cmd rule add fwmark $ROUTE_MARK table $ROUTE_TABLE_NAME priority 99"

  # 配置连接跟踪
  info "配置连接跟踪..."
  if (( remote_use_nft )); then
    remote_sudo "nft delete table inet qh_mark >/dev/null 2>&1 || true"
    remote_sudo "nft add table inet qh_mark"
    remote_sudo "nft 'add chain inet qh_mark prerouting { type filter hook prerouting priority -150; policy accept; }'"
    remote_sudo "nft 'add chain inet qh_mark output { type route hook output priority -150; policy accept; }'"
    remote_sudo "nft \"add rule inet qh_mark prerouting iif $QH_EXTERNAL_IF ct mark set $ROUTE_MARK\""
    remote_sudo "nft 'add rule inet qh_mark output meta mark set ct mark'"
  else
    remote_sudo "iptables -t mangle -D PREROUTING -i $QH_EXTERNAL_IF -j CONNMARK --set-mark $ROUTE_MARK 2>/dev/null || true"
    remote_sudo "iptables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null || true"

    remote_sudo "iptables -t mangle -A PREROUTING -i $QH_EXTERNAL_IF -j CONNMARK --set-mark $ROUTE_MARK"
    remote_sudo "iptables -t mangle -A OUTPUT -j CONNMARK --restore-mark"
    if [[ "$qh_external_family" == "6" ]]; then
      remote_sudo "if command -v ip6tables >/dev/null 2>&1; then ip6tables -t mangle -D PREROUTING -i $QH_EXTERNAL_IF -j CONNMARK --set-mark $ROUTE_MARK 2>/dev/null || true; ip6tables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null || true; ip6tables -t mangle -A PREROUTING -i $QH_EXTERNAL_IF -j CONNMARK --set-mark $ROUTE_MARK; ip6tables -t mangle -A OUTPUT -j CONNMARK --restore-mark; fi"
    fi
  fi

  # 调整系统参数
  info "调整系统参数..."
  remote_sudo "sysctl -w net.ipv4.conf.$QH_EXTERNAL_IF.rp_filter=2 > /dev/null"
  remote_sudo "sysctl -w net.ipv4.conf.$QH_INTERNAL_IF.rp_filter=2 > /dev/null"
  remote_sudo "sysctl -w net.ipv4.conf.all.rp_filter=2 > /dev/null"
  if [[ "$qh_external_family" == "6" ]]; then
    remote_sudo "sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null; sysctl -w net.ipv6.conf.$QH_EXTERNAL_IF.forwarding=1 > /dev/null; sysctl -w net.ipv6.conf.$QH_INTERNAL_IF.forwarding=1 > /dev/null"
  fi

  # 保存配置
  if (( remote_use_nft )); then
    info "保存 nftables 规则..."
    remote_sudo "if [ -w /etc/nftables.conf ]; then nft list ruleset > /etc/nftables.conf; elif command -v netfilter-persistent >/dev/null 2>&1; then netfilter-persistent save; fi" >/dev/null 2>&1 || true
  else
    info "保存iptables规则..."
    remote_sudo "mkdir -p /etc/iptables"
    remote_sudo "iptables-save > /etc/iptables/rules.v4"
    if [[ "$qh_external_family" == "6" ]]; then
      remote_sudo "if command -v ip6tables-save >/dev/null 2>&1; then ip6tables-save > /etc/iptables/rules.v6; fi"
    fi
  fi

  # 创建持久化脚本
  info "创建网络配置持久化..."

  # 创建恢复脚本
remote_sudo "cat > /usr/local/bin/restore-qh-route.sh << 'SCRIPT_EOF'
#!/bin/bash
# 恢复中国内地端路由配置

# 避免环境中 set -u 导致未定义变量报错
set +u 2>/dev/null || true

# 等待网络接口就绪
sleep 10

# [KKIX-PATCH] 等内网口拿到 IPv4 地址再继续（最长 60 秒），避免开机竞态
for _i in \$(seq 1 30); do
  ip -4 addr show "$QH_INTERNAL_IF" 2>/dev/null | grep -q 'inet ' && break
  sleep 2
done

# [KKIX-PATCH] 外网网关优先用原始路由快照里的真实网关（烘焙值仅作兜底）
EXT_GW='$QH_EXTERNAL_GW'
for _f in /root/.true_original_default_route ~/.true_original_default_route; do
  if [ -f \"\$_f\" ]; then
    _snap_gw=\$(awk '{for(i=1;i<=NF;i++) if(\$i==\"via\") print \$(i+1)}' \"\$_f\" | head -n1)
    [ -n \"\$_snap_gw\" ] && EXT_GW=\"\$_snap_gw\"
    break
  fi
done

IP_EXT_FAMILY=4
IP_EXT_CMD='ip'
IPT6_NEEDED=0
if ip -6 addr show "$QH_EXTERNAL_IF" scope global 2>/dev/null | grep -q .; then
  IP_EXT_FAMILY=6
fi
if [ "\$IP_EXT_FAMILY" = "6" ]; then
  IP_EXT_CMD='ip -6'
  IPT6_NEEDED=1
fi

# 恢复路由表
if ! grep -q 'ix_return' /etc/iproute2/rt_tables 2>/dev/null; then
  echo '100 ix_return' >> /etc/iproute2/rt_tables
fi

if ! grep -q 'internal_out' /etc/iproute2/rt_tables 2>/dev/null; then
  echo '101 internal_out' >> /etc/iproute2/rt_tables
fi

# 检查是否需要恢复默认路由
if [ -f /etc/qh_default_route_mode ]; then
  DEFAULT_MODE=\$(cat /etc/qh_default_route_mode)
  if [ "\$DEFAULT_MODE" = "hk" ]; then
    # 恢复默认路由到香港端
    # [KKIX-PATCH] 最长等香港 120 秒（双机同启时香港可能更慢），通了再切；原版只 ping 一次定生死
    _hk_ok=0
    for _i in \$(seq 1 24); do
      if ping -c 1 -W 2 $qh_int_gw >/dev/null 2>&1; then _hk_ok=1; break; fi
      sleep 5
    done
    if [ \"\$_hk_ok\" = \"1\" ]; then
      ip route del default 2>/dev/null || true
      if [ "\$IP_EXT_FAMILY" = "6" ]; then
        \$IP_EXT_CMD route del default 2>/dev/null || true
      fi
      ip route add default via $qh_int_gw dev $QH_INTERNAL_IF
      logger -t restore-route 'Default route restored to HK'
    else
      # 香港端不可达，使用外网路由
      ip route del default 2>/dev/null || true
      if [ "\$IP_EXT_FAMILY" = "6" ]; then
        \$IP_EXT_CMD route del default 2>/dev/null || true
        \$IP_EXT_CMD route add default via \$EXT_GW dev $QH_EXTERNAL_IF
      else
        ip route add default via \$EXT_GW dev $QH_EXTERNAL_IF
      fi
      logger -t restore-route 'HK unreachable, using external route'
    fi
  fi
  # 如果是 "original" 或其他值，保持原有默认路由
fi

\$IP_EXT_CMD route flush table ix_return 2>/dev/null || true
\$IP_EXT_CMD route add default via \$EXT_GW dev $QH_EXTERNAL_IF table ix_return

# 恢复内网出站路由表
ip route flush table internal_out 2>/dev/null || true
ip route add default via $qh_int_gw dev $QH_INTERNAL_IF table internal_out

# 添加到香港端的路由
ip route add $HK_LAN_IP/32 via $qh_int_gw dev $QH_INTERNAL_IF 2>/dev/null || true

# 清理并恢复策略路由规则
QH_EXT_IP='$QH_EXTERNAL_IP'
QH_EXT_IP_CLEAN=\${QH_EXT_IP%%/*}
QH_INT_IP='$qh_int_ip'
QH_INT_IP_CLEAN=\${QH_INT_IP%%/*}

# 清理旧规则
while \$IP_EXT_CMD rule del from \$QH_EXT_IP_CLEAN table ix_return 2>/dev/null; do :; done
while ip rule del from \$QH_INT_IP_CLEAN table internal_out 2>/dev/null; do :; done
while \$IP_EXT_CMD rule del fwmark 100 table ix_return 2>/dev/null; do :; done

# 恢复策略路由规则
ip rule add from \$QH_INT_IP_CLEAN table internal_out priority 90
\$IP_EXT_CMD rule add from \$QH_EXT_IP_CLEAN table ix_return priority 100
\$IP_EXT_CMD rule add fwmark 100 table ix_return priority 99

  if command -v nft >/dev/null 2>&1; then
    nft delete table inet qh_mark >/dev/null 2>&1 || true
    nft add table inet qh_mark
    nft 'add chain inet qh_mark prerouting { type filter hook prerouting priority -150; policy accept; }'
    nft 'add chain inet qh_mark output { type route hook output priority -150; policy accept; }'
  nft "add rule inet qh_mark prerouting iif $QH_EXTERNAL_IF ct mark set 100"
  nft 'add rule inet qh_mark output meta mark set ct mark'
  else
    # 恢复iptables规则
    iptables -t mangle -D PREROUTING -i $QH_EXTERNAL_IF -j CONNMARK --set-mark 100 2>/dev/null || true
    iptables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null || true
    iptables -t mangle -A PREROUTING -i $QH_EXTERNAL_IF -j CONNMARK --set-mark 100
    iptables -t mangle -A OUTPUT -j CONNMARK --restore-mark
    if [ "\$IPT6_NEEDED" -eq 1 ] && command -v ip6tables >/dev/null 2>&1; then
      ip6tables -t mangle -D PREROUTING -i $QH_EXTERNAL_IF -j CONNMARK --set-mark 100 2>/dev/null || true
      ip6tables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null || true
      ip6tables -t mangle -A PREROUTING -i $QH_EXTERNAL_IF -j CONNMARK --set-mark 100
      ip6tables -t mangle -A OUTPUT -j CONNMARK --restore-mark
    fi
fi

# 恢复DNS路由
for dns in 8.8.8.8 1.1.1.1; do
  ip route add \$dns/32 via $qh_int_gw dev $QH_INTERNAL_IF 2>/dev/null || true
done

# 调整反向路径过滤
sysctl -w net.ipv4.conf.$QH_EXTERNAL_IF.rp_filter=2 > /dev/null
sysctl -w net.ipv4.conf.$QH_INTERNAL_IF.rp_filter=2 > /dev/null
sysctl -w net.ipv4.conf.all.rp_filter=2 > /dev/null
if [ "\$IPT6_NEEDED" -eq 1 ]; then
  sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null
  sysctl -w net.ipv6.conf.$QH_EXTERNAL_IF.forwarding=1 > /dev/null
  sysctl -w net.ipv6.conf.$QH_INTERNAL_IF.forwarding=1 > /dev/null
fi

logger -t restore-route 'QH route configuration restored'
SCRIPT_EOF"

  remote_sudo "chmod +x /usr/local/bin/restore-qh-route.sh"

  # 创建systemd服务
  info "创建systemd服务..."
  remote_sudo "cat > /etc/systemd/system/qh-route-restore.service << 'SERVICE_EOF'
[Unit]
Description=Restore QH Route Configuration
After=network-online.target cloud-init.service
Wants=network-online.target
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/restore-qh-route.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF"

  # 启用服务
  remote_sudo "systemctl daemon-reload"
  remote_sudo "systemctl enable qh-route-restore.service"
  info "已创建开机自动恢复服务"

  # 防止cloud-init重置网络配置
  info "配置cloud-init..."
  remote_sudo "mkdir -p /etc/cloud/cloud.cfg.d/"
  remote_sudo "cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg << 'CLOUD_EOF'
network: {config: disabled}
CLOUD_EOF"

  # 创建紧急恢复机制（防止失联）
  info "创建紧急恢复机制..."
remote_sudo "cat > /usr/local/bin/check-network.sh << 'CHECK_EOF'
#!/bin/bash
# 检查网络连接，如果失败则恢复原始路由

# 避免环境中 set -u 导致未定义变量报错
set +u 2>/dev/null || true

IP_EXT_FAMILY=4
if ip -6 addr show "$QH_EXTERNAL_IF" scope global 2>/dev/null | grep -q .; then
  IP_EXT_FAMILY=6
fi
IP_EXT_CMD='ip'
if [ "\$IP_EXT_FAMILY" = "6" ]; then
  IP_EXT_CMD='ip -6'
fi

# [KKIX-PATCH] 外网网关优先用原始路由快照里的真实网关（烘焙值仅作兜底）
EXT_GW='$QH_EXTERNAL_GW'
for _f in /root/.true_original_default_route ~/.true_original_default_route; do
  if [ -f \"\$_f\" ]; then
    _snap_gw=\$(awk '{for(i=1;i<=NF;i++) if(\$i==\"via\") print \$(i+1)}' \"\$_f\" | head -n1)
    [ -n \"\$_snap_gw\" ] && EXT_GW=\"\$_snap_gw\"
    break
  fi
done

# 检查是否能ping通网关
if ! ping -c 2 -W 2 $qh_int_gw >/dev/null 2>&1; then
  # 恢复默认路由到外网接口
  ip route del default 2>/dev/null || true
  if [ "\$IP_EXT_FAMILY" = "6" ]; then
    \$IP_EXT_CMD route del default 2>/dev/null || true
    \$IP_EXT_CMD route add default via \$EXT_GW dev $QH_EXTERNAL_IF
  else
    ip route add default via \$EXT_GW dev $QH_EXTERNAL_IF
  fi
  logger -t network-check 'Network check failed, restored original route'

  # 解锁并恢复DNS
  chattr -i /etc/resolv.conf 2>/dev/null || true
  if [ -f /etc/resolv.conf.backup ]; then
    cp /etc/resolv.conf.backup /etc/resolv.conf
  fi
fi

# [KKIX-PATCH] 香港恢复可达后自动切回香港路由（原版只切走、不切回，双机同启会永久失效）
if ping -c 1 -W 2 $qh_int_gw >/dev/null 2>&1; then
  if [ -f /etc/qh_default_route_mode ] && [ \"\$(cat /etc/qh_default_route_mode)\" = \"hk\" ]; then
    if ! ip route show default 2>/dev/null | grep -q \"via $qh_int_gw\"; then
      logger -t network-check 'HK reachable again, restoring HK route'
      /usr/local/bin/restore-qh-route.sh >/dev/null 2>&1 || true
    fi
  fi
fi
CHECK_EOF"

  remote_sudo "chmod +x /usr/local/bin/check-network.sh"

  # 在完成策略路由配置后再尝试安装cron，避免网络不通导致卡顿
  install_remote_cron || true

  # 检查crontab是否可用，如果不可用则使用systemd timer
  if remote_exec "which crontab >/dev/null 2>&1"; then
    # 使用crontab
    info "配置crontab定时任务..."
    remote_sudo "crontab -l 2>/dev/null | grep -v check-network.sh > /tmp/crontab.tmp || true"
    remote_sudo "echo '*/5 * * * * /usr/local/bin/check-network.sh' >> /tmp/crontab.tmp"
    remote_sudo "crontab /tmp/crontab.tmp"
    remote_sudo "rm -f /tmp/crontab.tmp"
    info "已添加网络检查定时任务（crontab）"
  else
    # 使用systemd timer作为替代
    info "配置systemd定时器..."

    # 创建systemd service
    remote_sudo "cat > /etc/systemd/system/network-check.service << 'TIMER_SVC_EOF'
[Unit]
Description=Network Connectivity Check
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/check-network.sh
StandardOutput=journal
StandardError=journal
TIMER_SVC_EOF"

    # 创建systemd timer
    remote_sudo "cat > /etc/systemd/system/network-check.timer << 'TIMER_EOF'
[Unit]
Description=Run Network Check every 5 minutes
Requires=network-check.service

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
TIMER_EOF"

    # 启用timer
    remote_sudo "systemctl daemon-reload"
    remote_sudo "systemctl enable network-check.timer"
    remote_sudo "systemctl start network-check.timer"
    info "已添加网络检查定时任务（systemd timer）"
  fi

  # 保护DNS配置
  if remote_exec "which chattr >/dev/null 2>&1"; then
    info "锁定DNS配置文件..."
    remote_sudo "chattr -i /etc/resolv.conf 2>/dev/null || true"
    remote_sudo "cp /etc/resolv.conf /etc/resolv.conf.backup"
    remote_sudo "chattr +i /etc/resolv.conf"
  fi

  # 刷新路由缓存
  remote_sudo "ip route flush cache 2>/dev/null || true"
  if [[ "$qh_external_family" == "6" ]]; then
    remote_sudo "ip -6 route flush cache 2>/dev/null || true"
  fi

  info ""
  info "========================================="
  info "中国内地端策略路由配置完成！"
  info "========================================="
  info "配置信息："
  info "  外网接口: $QH_EXTERNAL_IF ($QH_EXTERNAL_IP)"
  info "  内网接口: $QH_INTERNAL_IF"
  info "  香港端网关: $qh_int_gw"
  info "  策略路由表: $ROUTE_TABLE_NAME (ID: $ROUTE_TABLE_ID)"
  info ""
  info "当前状态："
  info "  ✓ 从内网IP发起的连接会通过香港端"
  info "  ✓ 外网接口仍可接收连接"
  info "  ✓ 默认路由保持不变"
  info "========================================="

  # 记录策略路由状态，供默认路由切换前检查使用
  remote_sudo "bash -c 'cat <<\"EOF\" >/etc/qh_route_status
status=ready
updated=\$(date -Iseconds)
EOF
'"
  remote_sudo "chmod 600 /etc/qh_route_status"
  write_remote_flag "$REMOTE_ROUTE_FLAG" \
    "mode=route" \
    "status=ready" \
    "backend=$([[ $remote_use_nft -eq 1 ]] && echo nft || echo iptables)" \
    "external_if=$QH_EXTERNAL_IF" \
    "internal_if=$QH_INTERNAL_IF"

  # 询问是否设置默认路由
  echo ""
  local set_default=""
  if (( SB_MODE )); then
    set_default="y"
    info "sbmode: 自动将默认路由设置为通过香港端"
  else
    read -rp "是否将默认路由设置为通过香港端？[Y/n]: " set_default
  fi
  if [[ "$set_default" != "n" && "$set_default" != "N" ]]; then
    # 保存并设置默认路由
    info "设置默认路由走香港端..."
    remote_sudo "ip route del default 2>/dev/null || true"
    remote_sudo "ip route add default via $qh_int_gw dev $QH_INTERNAL_IF"
    remote_sudo "echo 'hk' > /etc/qh_default_route_mode"
    info "默认路由已设置为通过香港端"
  else
    # 保持原始路由
    remote_sudo "echo 'original' > /etc/qh_default_route_mode"
    info "保持当前默认路由不变"
    info "您可以稍后通过菜单选项5设置默认路由"
  fi
}

# 中国内地端清除策略路由
clear_qh_route() {
  if ! ensure_qh_route_info; then
    warn "无法获取中国内地端网络信息，已取消操作"
    return 1
  fi

  local qh_external_family="${QH_EXTERNAL_FAMILY:-$(ip_family "$QH_EXTERNAL_IP")}"
  local ip_ext_cmd="ip"
  if [[ "$qh_external_family" == "6" ]]; then
    ip_ext_cmd="ip -6"
  fi
  local remote_use_nft=0
  if remote_exec "command -v nft >/dev/null 2>&1"; then
    remote_use_nft=1
  fi

  clean_remote_legacy_rules
  mark_action "qh_route_clear" "开始清除中国内地端策略路由并清理旧规则"

  info "清除中国内地端策略路由配置..."

  # 删除策略路由规则
  info "删除策略路由规则..."
  # 确保使用纯IP地址进行清理
  local qh_ext_ip_clean="$QH_EXTERNAL_IP"
  if [[ "$qh_ext_ip_clean" == *"/"* ]]; then
    qh_ext_ip_clean=$(echo "$qh_ext_ip_clean" | cut -d/ -f1)
  fi

  # 获取内网IP用于清理
  local qh_int_ip=$(remote_exec "ip -o -4 addr show $QH_INTERNAL_IF 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1")
  if [[ -z "$qh_int_ip" ]]; then
    qh_int_ip=$(remote_exec "ip -o -6 addr show $QH_INTERNAL_IF scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1")
  fi
  local ip_int_cmd="ip"
  if [[ "$qh_int_ip" == *:* ]]; then
    ip_int_cmd="ip -6"
  fi

  remote_sudo "while $ip_ext_cmd rule del from $qh_ext_ip_clean table $ROUTE_TABLE_NAME 2>/dev/null; do :; done"
  remote_sudo "while $ip_int_cmd rule del from $qh_int_ip table internal_out 2>/dev/null; do :; done"
  remote_sudo "while $ip_ext_cmd rule del fwmark $ROUTE_MARK table $ROUTE_TABLE_NAME 2>/dev/null; do :; done"

  # 清空路由表
  remote_sudo "$ip_ext_cmd route flush table $ROUTE_TABLE_NAME 2>/dev/null || true"
  remote_sudo "$ip_int_cmd route flush table internal_out 2>/dev/null || true"

  # 删除到香港端的特定路由
  remote_sudo "ip route del $HK_LAN_IP/32 2>/dev/null || true"

  # 删除iptables规则
  info "删除标记规则..."
  remote_sudo "nft delete table inet qh_mark >/dev/null 2>&1 || true"
  remote_sudo "iptables -t mangle -D PREROUTING -i $QH_EXTERNAL_IF -j CONNMARK --set-mark $ROUTE_MARK 2>/dev/null || true"
  remote_sudo "iptables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null || true"
  if [[ "$qh_external_family" == "6" ]]; then
    remote_sudo "if command -v ip6tables >/dev/null 2>&1; then ip6tables -t mangle -D PREROUTING -i $QH_EXTERNAL_IF -j CONNMARK --set-mark $ROUTE_MARK 2>/dev/null || true; ip6tables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null || true; fi"
  fi

  # 恢复原始默认路由
  info "恢复原始默认路由..."

  # 优先使用真正的原始路由
  if remote_exec "test -f ~/.true_original_default_route"; then
    local true_original=$(remote_exec "cat ~/.true_original_default_route")
    if [[ -n "$true_original" ]]; then
      info "恢复真正的原始路由: $true_original"
      local restore_cmd="ip route add"
      if [[ "$qh_external_family" == "6" || "$true_original" == *:* ]]; then
        restore_cmd="$ip_ext_cmd route add"
      fi
      # 删除当前默认路由
      remote_sudo "ip route del default 2>/dev/null || true"
      if [[ "$qh_external_family" == "6" ]]; then
        remote_sudo "$ip_ext_cmd route del default 2>/dev/null || true"
      fi
      # 恢复原始路由
      remote_sudo "$restore_cmd $true_original"
    fi
  elif remote_exec "test -f ~/.last_default_route"; then
    # 如果没有真正的原始路由，使用最后保存的路由
    local last_route=$(remote_exec "cat ~/.last_default_route")
    # 检查这个路由是否是内网的
    if [[ "$last_route" == *"$QH_EXTERNAL_IF"* ]]; then
      info "恢复到: $last_route"
      remote_sudo "ip route del default 2>/dev/null || true"
      if [[ "$qh_external_family" == "6" ]]; then
        remote_sudo "$ip_ext_cmd route del default 2>/dev/null || true"
      fi
      if [[ "$qh_external_family" == "6" || "$last_route" == *:* ]]; then
        remote_sudo "$ip_ext_cmd route add $last_route"
      else
        remote_sudo "ip route add $last_route"
      fi
    else
      # 如果保存的也是内网路由，强制恢复到外网
      warn "保存的路由指向内网，强制恢复到外网接口"
      remote_sudo "ip route del default 2>/dev/null || true"
      if [[ "$qh_external_family" == "6" ]]; then
        remote_sudo "$ip_ext_cmd route del default 2>/dev/null || true"
        remote_sudo "$ip_ext_cmd route add default via $QH_EXTERNAL_GW dev $QH_EXTERNAL_IF"
      else
        remote_sudo "ip route add default via $QH_EXTERNAL_GW dev $QH_EXTERNAL_IF"
      fi
    fi
  else
    # 如果什么都没有，直接恢复到外网接口
    warn "无保存的路由信息，设置默认路由到外网接口"
    remote_sudo "ip route del default 2>/dev/null || true"
    if [[ "$qh_external_family" == "6" ]]; then
      remote_sudo "$ip_ext_cmd route del default 2>/dev/null || true"
      remote_sudo "$ip_ext_cmd route add default via $QH_EXTERNAL_GW dev $QH_EXTERNAL_IF"
    else
      remote_sudo "ip route add default via $QH_EXTERNAL_GW dev $QH_EXTERNAL_IF"
    fi
  fi

  # 清理临时文件（但保留 true_original_default_route 供将来使用）
  remote_exec "rm -f ~/.last_default_route"
  # 询问是否要清理原始路由记录
  read -rp "是否清除原始路由记录（下次将重新检测）？[y/N]: " clear_original
  if [[ "$clear_original" == "y" || "$clear_original" == "Y" ]]; then
    remote_exec "rm -f ~/.true_original_default_route"
    info "已清除原始路由记录"
  fi

  clear_remote_flag "$REMOTE_ROUTE_FLAG"

  # 恢复原始DNS配置
  info "恢复DNS配置..."
  # 先解锁DNS配置文件
  if remote_exec "which chattr >/dev/null 2>&1"; then
    remote_sudo "chattr -i /etc/resolv.conf 2>/dev/null || true"
  fi

  if remote_exec "test -f ~/.original_resolv.conf"; then
    remote_sudo "cp ~/.original_resolv.conf /etc/resolv.conf"
    remote_exec "rm -f ~/.original_resolv.conf"
    info "DNS配置已恢复"
  elif remote_exec "test -f /etc/resolv.conf.backup"; then
    remote_sudo "cp /etc/resolv.conf.backup /etc/resolv.conf"
    info "从备份恢复DNS配置"
  fi

  remote_sudo "chmod 644 /etc/resolv.conf 2>/dev/null || true"

  # 如有需要，恢复 systemd-resolved 状态
  remote_sudo "bash -s" <<'EOF'
if command -v systemctl >/dev/null 2>&1 && [ -f /etc/qh_systemd_resolved_state ]; then
  # shellcheck disable=SC1091
  . /etc/qh_systemd_resolved_state
  if [ "${was_enabled:-}" = "enabled" ]; then
    systemctl enable systemd-resolved >/dev/null 2>&1 || true
  fi
  if [ "${was_active:-}" = "active" ]; then
    systemctl start systemd-resolved >/dev/null 2>&1 || true
  fi
  rm -f /etc/qh_systemd_resolved_state
fi

if [ -f /etc/nsswitch.conf.qhbackup ]; then
  cp /etc/nsswitch.conf.qhbackup /etc/nsswitch.conf
  rm -f /etc/nsswitch.conf.qhbackup
fi
EOF

  # 删除DNS服务器路由
  info "删除DNS服务器路由..."
  for dns in 8.8.8.8 1.1.1.1; do
    remote_sudo "ip route del $dns/32 2>/dev/null || true"
  done

  # 清理持久化配置
  info "清理持久化配置..."

  # 停用并删除systemd服务
  if remote_exec "systemctl list-unit-files | grep -q qh-route-restore.service"; then
    remote_sudo "systemctl disable qh-route-restore.service 2>/dev/null || true"
    remote_sudo "systemctl stop qh-route-restore.service 2>/dev/null || true"
    remote_sudo "rm -f /etc/systemd/system/qh-route-restore.service"
    remote_sudo "systemctl daemon-reload"
    info "已删除自动恢复服务"
  fi

  # 删除恢复脚本
  remote_sudo "rm -f /usr/local/bin/restore-qh-route.sh"

  # 删除网络检查脚本和定时任务
  remote_sudo "rm -f /usr/local/bin/check-network.sh"

  # 清理crontab（如果存在）
  if remote_exec "which crontab >/dev/null 2>&1"; then
    remote_sudo "crontab -l 2>/dev/null | grep -v check-network.sh > /tmp/crontab.tmp || true"
    remote_sudo "crontab /tmp/crontab.tmp"
    remote_sudo "rm -f /tmp/crontab.tmp"
  fi

  # 清理systemd timer（如果存在）
  if remote_exec "systemctl list-unit-files | grep -q network-check.timer"; then
    remote_sudo "systemctl stop network-check.timer 2>/dev/null || true"
    remote_sudo "systemctl disable network-check.timer 2>/dev/null || true"
    remote_sudo "rm -f /etc/systemd/system/network-check.timer"
    remote_sudo "rm -f /etc/systemd/system/network-check.service"
    remote_sudo "systemctl daemon-reload"
  fi

  info "已删除网络检查任务"

  # 恢复cloud-init配置
  remote_sudo "rm -f /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"
  info "已恢复cloud-init配置"

  # 清除策略路由状态标记
  remote_sudo "rm -f /etc/qh_route_status"

  if remote_exec "test -f $AUTO_UPGRADE_STATE_FILE"; then
    info "检测到自动 apt upgrade 服务曾被禁用，开始恢复..."
    if ! restore_remote_auto_upgrade; then
      warn "自动 apt upgrade 服务恢复失败，请手动检查 ${AUTO_UPGRADE_STATE_FILE}"
    fi
  fi

  # 保存配置
  remote_sudo "mkdir -p /etc/iptables"
  remote_sudo "iptables-save > /etc/iptables/rules.v4"

  info "中国内地端策略路由配置已完全清除并恢复原始路由"
}

# 中国内地端设置默认路由走香港
set_qh_default_route() {
  if ! confirm_hk_dependency "route" "设置中国内地端默认路由走香港"; then
    return 1
  fi
  ensure_basic_info
  if ! ensure_remote_context; then
    warn "SSH 连接失败，无法设置默认路由"
    return 1
 fi

  if ! verify_qh_route_before_default; then
    return 1
  fi

  info "设置中国内地端默认路由走香港..."
  local qh_external_family="${QH_EXTERNAL_FAMILY:-$(ip_family "$QH_EXTERNAL_IP")}"
  local ip_ext_cmd="ip"
  if [[ "$qh_external_family" == "6" ]]; then
    ip_ext_cmd="ip -6"
  fi

  # 获取内网接口信息
  local qh_int_if=$(remote_exec "ip route | grep '$QIANHAI_LAN_IP' | awk '{print \$3}' | head -n1")
  if [[ -z "$qh_int_if" ]]; then
    # 尝试通过网段推测
    if remote_exec "ip addr | grep -q '192.168'"; then
      qh_int_if="ens20"
    elif remote_exec "ip addr | grep -q '10.0'"; then
      qh_int_if="ens20"
    else
      read -rp "请输入中国内地端内网接口名称 [ens20]: " qh_int_if
      qh_int_if="${qh_int_if:-ens20}"
    fi
  fi

  # 保存当前默认路由
  local current_default=$(remote_exec "ip route show default" | head -n1)
  if [[ -z "$current_default" ]]; then
    current_default=$(remote_exec "ip -6 route show default" | head -n1)
  fi
  if [[ -n "$current_default" ]]; then
    remote_exec "echo '$current_default' > ~/.before_hk_default_route"
    info "已保存当前默认路由: $current_default"
  fi

  # 设置默认路由走香港
  remote_sudo "ip route del default 2>/dev/null || true"
  if [[ "$qh_external_family" == "6" ]]; then
    remote_sudo "$ip_ext_cmd route del default 2>/dev/null || true"
  fi
  remote_sudo "ip route add default via $HK_LAN_IP dev $qh_int_if"

  # 标记默认路由模式为香港（用于重启恢复）
  remote_sudo "echo 'hk' > /etc/qh_default_route_mode"

  # 更新恢复脚本中的网关信息
  if remote_exec "test -f /usr/local/bin/restore-qh-route.sh"; then
    remote_sudo "sed -i 's/ip route add default via .* dev $qh_int_if/ip route add default via $HK_LAN_IP dev $qh_int_if/' /usr/local/bin/restore-qh-route.sh 2>/dev/null || true"
  fi

  info "========================================="
  info "默认路由已设置为通过香港端"
  info "网关: $HK_LAN_IP"
  info "接口: $qh_int_if"
  info "配置已持久化，重启后自动恢复"
  info "========================================="
}

# 中国内地端恢复默认路由
restore_qh_default_route() {
  if ! ensure_qh_route_info; then
    warn "无法获取中国内地端网络信息，已取消操作"
    return 1
  fi

  info "恢复中国内地端默认路由..."
  local qh_external_family="${QH_EXTERNAL_FAMILY:-$(ip_family "$QH_EXTERNAL_IP")}"
  local ip_ext_cmd="ip"
  if [[ "$qh_external_family" == "6" ]]; then
    ip_ext_cmd="ip -6"
  fi

  # 尝试恢复之前保存的路由
  if remote_exec "test -f ~/.before_hk_default_route"; then
    local saved_route=$(remote_exec "cat ~/.before_hk_default_route")
    if [[ -n "$saved_route" ]]; then
      info "恢复到: $saved_route"
      remote_sudo "ip route del default 2>/dev/null || true"
      if [[ "$qh_external_family" == "6" || "$saved_route" == *:* ]]; then
        remote_sudo "$ip_ext_cmd route add $saved_route"
      else
        remote_sudo "ip route add $saved_route"
      fi
      remote_exec "rm -f ~/.before_hk_default_route"
    fi
  elif remote_exec "test -f ~/.true_original_default_route"; then
    # 使用原始路由
    local original_route=$(remote_exec "cat ~/.true_original_default_route")
    info "恢复到原始路由: $original_route"
    remote_sudo "ip route del default 2>/dev/null || true"
    if [[ "$qh_external_family" == "6" || "$original_route" == *:* ]]; then
      remote_sudo "$ip_ext_cmd route add $original_route"
    else
      remote_sudo "ip route add $original_route"
    fi
  else
    # 默认恢复到外网
    warn "无保存的路由，恢复到外网接口"
    remote_sudo "ip route del default 2>/dev/null || true"
    if [[ "$qh_external_family" == "6" ]]; then
      remote_sudo "$ip_ext_cmd route del default 2>/dev/null || true"
      remote_sudo "$ip_ext_cmd route add default via $QH_EXTERNAL_GW dev $QH_EXTERNAL_IF"
    else
      remote_sudo "ip route add default via $QH_EXTERNAL_GW dev $QH_EXTERNAL_IF"
    fi
  fi

  # 标记默认路由模式为原始（用于重启恢复）
  remote_sudo "echo 'original' > /etc/qh_default_route_mode"

  info "默认路由已恢复"
  info "配置已持久化，重启后保持原始路由"
}

# ==================== 菜单函数 ====================
show_proxy_menu() {
  cat <<'MENU'
==============================
 代理模式 - 功能菜单
==============================
1) 安装香港端代理服务器
2) 卸载香港端代理服务器
3) 安装中国内地端代理客户端
4) 卸载中国内地端代理客户端
5) 设置中国内地端自动代理
6) 取消中国内地端自动代理
b) 返回模式选择
q) 退出
MENU
}

show_route_menu() {
  cat <<'MENU'
==============================
 路由模式 - 功能菜单
==============================
1) 设置香港端SNAT路由
2) 取消香港端SNAT路由
3) 设置中国内地端策略路由
4) 取消中国内地端策略路由
5) 设置中国内地端默认路由走香港
6) 恢复中国内地端默认路由
b) 返回模式选择
q) 退出
MENU
}

show_violent_menu() {
  cat <<'MENU'
==============================
 直接转发模式（不推荐） - 高阶功能
==============================
1) 启用端口映射（可选 iptables/nftables）
2) 卸载端口映射
b) 返回模式选择
q) 退出
MENU
}

# ==================== 直接转发模式（不推荐） ====================
select_direct_backend() {
  local default_choice="2" choice backend
  {
    echo "请选择实现方式："
    echo "1) iptables"
    echo "2) nftables"
  } >&2
  while true; do
    read -rp "选择 [1/2] (默认 $default_choice): " choice
    choice="${choice:-$default_choice}"
    case "$choice" in
      1) backend="iptables" ;;
      2) backend="nftables" ;;
      *) echo "请输入 1 或 2"
         continue ;;
    esac
    printf '%s\n' "$backend"
    return 0
  done
}

apply_violent_mode_rules() {
  local action="$1" start_port="$2" end_port="$3" backend="${4:-iptables}" ext_if="${5:-$QH_EXTERNAL_IF}" int_if="${6:-$QH_INTERNAL_IF}"
  if [[ -z "$ext_if" ]]; then
    ext_if="$QH_EXTERNAL_IF"
  fi
  if [[ -z "$int_if" ]]; then
    int_if="$ext_if"
  fi
  local target_ip="$HK_LAN_IP"
  local snat_ip="$QIANHAI_LAN_IP"
  local action_label
  local direct_flag="$STATE_DIR/direct_flag"

  backend=$(echo "$backend" | tr 'A-Z' 'a-z')
  if [[ "$backend" != "iptables" && "$backend" != "nftables" ]]; then
    err "未知实现方式: $backend"
    return 1
  fi

  local target_family snat_family
  target_family=$(ip_family "$target_ip")
  snat_family=$(ip_family "$snat_ip")
  if [[ "$target_family" != "$snat_family" ]]; then
    err "目标IP($target_ip)与SNAT IP($snat_ip)协议族不一致，直接转发模式暂不支持该组合"
    return 1
  fi

  if [[ "$action" == "apply" ]]; then
    action_label="配置"
  else
    action_label="清理"
  fi

  info "${action_label}中国内地端 ${backend}，将 ${start_port}-${end_port} 端口映射至 ${target_ip}"

if remote_sudo "bash -s" "$start_port" "$end_port" "$target_ip" "$snat_ip" "$action" "$backend" "$target_family" "$ext_if" "$int_if" <<'EOF'; then
set -euo pipefail
START_PORT="$1"
END_PORT="$2"
TARGET_IP="$3"
SNAT_ADDR="$4"
MODE="$5"
BACKEND="$6"
IP_FAMILY="$7"
EXT_IF="$8"
INT_IF="$9"
RANGE="${START_PORT}:${END_PORT}"
BACKEND=$(echo "$BACKEND" | tr 'A-Z' 'a-z')
TABLE_NAME="kkix_direct"

# 基础网络准备
sysctl -w net.ipv4.ip_forward=1 >/dev/null || true
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null || true
sysctl -w net.ipv4.conf.$EXT_IF.rp_filter=2 >/dev/null || true
sysctl -w net.ipv4.conf.$INT_IF.rp_filter=2 >/dev/null || true
if [ "$IP_FAMILY" = "6" ]; then
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null || true
  sysctl -w net.ipv6.conf.$EXT_IF.forwarding=1 >/dev/null || true
  sysctl -w net.ipv6.conf.$INT_IF.forwarding=1 >/dev/null || true
fi

# 确认接口存在
if ! ip link show "$EXT_IF" >/dev/null 2>&1; then
  echo "外网接口 $EXT_IF 不存在" >&2
  exit 1
fi
if ! ip link show "$INT_IF" >/dev/null 2>&1; then
  echo "内网接口 $INT_IF 不存在" >&2
  exit 1
fi

case "$BACKEND" in
  iptables)
    IPT_CMD="iptables"
    SAVE_CMD="iptables-save"
    RULES_FILE="/etc/iptables/rules.v4"
    SNAT_ADDR="$SNAT_ADDR"
    if [ "$IP_FAMILY" = "6" ]; then
      IPT_CMD="ip6tables"
      SAVE_CMD="ip6tables-save"
      RULES_FILE="/etc/iptables/rules.v6"
      sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null || true
      sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null || true
      if ! grep -q '^net.ipv6.conf.all.forwarding=1' /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
      fi
    else
      sysctl -w net.ipv4.ip_forward=1 >/dev/null
      if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
      fi
    fi

    if ! command -v "$IPT_CMD" >/dev/null 2>&1; then
      echo "$IPT_CMD 未安装" >&2
      exit 1
    fi

    # 确保转发表允许回程流量
    if ! $IPT_CMD -C FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
      $IPT_CMD -I FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
    fi
    # 允许新连接的方向
    if ! $IPT_CMD -C FORWARD -i "$EXT_IF" -o "$INT_IF" -j ACCEPT 2>/dev/null; then
      $IPT_CMD -A FORWARD -i "$EXT_IF" -o "$INT_IF" -j ACCEPT
    fi

    # 确保有到 TARGET_IP 的路由
    ip route replace "$TARGET_IP"/32 dev "$INT_IF" >/dev/null 2>&1 || true

    for proto in tcp udp; do
      while $IPT_CMD -t nat -C PREROUTING -i "$EXT_IF" -p "$proto" --dport "$RANGE" -j DNAT --to-destination "$TARGET_IP" 2>/dev/null; do
        $IPT_CMD -t nat -D PREROUTING -i "$EXT_IF" -p "$proto" --dport "$RANGE" -j DNAT --to-destination "$TARGET_IP"
      done
      while $IPT_CMD -t nat -C POSTROUTING -o "$INT_IF" -p "$proto" -d "$TARGET_IP" --dport "$RANGE" -j SNAT --to-source "$SNAT_ADDR" 2>/dev/null; do
        $IPT_CMD -t nat -D POSTROUTING -o "$INT_IF" -p "$proto" -d "$TARGET_IP" --dport "$RANGE" -j SNAT --to-source "$SNAT_ADDR"
      done
      while $IPT_CMD -C FORWARD -i "$EXT_IF" -o "$INT_IF" -p "$proto" -d "$TARGET_IP" --dport "$RANGE" -j ACCEPT 2>/dev/null; do
        $IPT_CMD -D FORWARD -i "$EXT_IF" -o "$INT_IF" -p "$proto" -d "$TARGET_IP" --dport "$RANGE" -j ACCEPT
      done

      if [ "$MODE" = "apply" ]; then
        $IPT_CMD -t nat -A PREROUTING -i "$EXT_IF" -p "$proto" --dport "$RANGE" -j DNAT --to-destination "$TARGET_IP"
        $IPT_CMD -t nat -A POSTROUTING -o "$INT_IF" -p "$proto" -d "$TARGET_IP" --dport "$RANGE" -j SNAT --to-source "$SNAT_ADDR"
        $IPT_CMD -I FORWARD 1 -i "$EXT_IF" -o "$INT_IF" -p "$proto" -d "$TARGET_IP" --dport "$RANGE" -j ACCEPT
      fi
    done

    if command -v netfilter-persistent >/dev/null 2>&1; then
      netfilter-persistent save >/dev/null 2>&1 || true
    else
      mkdir -p /etc/iptables >/dev/null 2>&1 || true
      if command -v "$SAVE_CMD" >/dev/null 2>&1; then
        $SAVE_CMD > "$RULES_FILE"
      fi
    fi
    ;;
  nftables)
    if ! command -v nft >/dev/null 2>&1; then
      echo "nft 未安装" >&2
      exit 1
    fi

    TABLE_FAMILY="ip"
    ADDR_KEY="ip"
    if [ "$IP_FAMILY" = "6" ]; then
      TABLE_FAMILY="ip6"
      ADDR_KEY="ip6"
      sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null || true
      sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null || true
      if ! grep -q '^net.ipv6.conf.all.forwarding=1' /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
      fi
    else
      EXT_ADDR4=$(ip -o -4 addr show "$EXT_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
      if [ -z "$EXT_ADDR4" ]; then
        echo "外网接口 $EXT_IF 缺少 IPv4 地址，无法映射到 IPv4 目标" >&2
        exit 1
      fi
      sysctl -w net.ipv4.ip_forward=1 >/dev/null
      if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
      fi
    fi

    nft delete table $TABLE_FAMILY $TABLE_NAME >/dev/null 2>&1 || true
    nft add table $TABLE_FAMILY $TABLE_NAME

    nft "add chain $TABLE_FAMILY $TABLE_NAME prerouting { type nat hook prerouting priority -100; }"
    nft "add chain $TABLE_FAMILY $TABLE_NAME postrouting { type nat hook postrouting priority 100; }"
    nft "add chain $TABLE_FAMILY $TABLE_NAME forward { type filter hook forward priority 0; policy accept; }"
    nft "add rule $TABLE_FAMILY $TABLE_NAME forward ct state established,related accept"

    if [ "$MODE" = "apply" ]; then
      ip route replace "$TARGET_IP"/32 dev "$INT_IF" >/dev/null 2>&1 || true
      for proto in tcp udp; do
        nft add rule $TABLE_FAMILY $TABLE_NAME prerouting iif "$EXT_IF" $proto dport "$START_PORT-$END_PORT" dnat to $TARGET_IP
        nft add rule $TABLE_FAMILY $TABLE_NAME postrouting oif "$INT_IF" $ADDR_KEY daddr $TARGET_IP $proto dport "$START_PORT-$END_PORT" snat to $SNAT_ADDR
        nft add rule $TABLE_FAMILY $TABLE_NAME forward iif "$EXT_IF" oif "$INT_IF" $ADDR_KEY daddr $TARGET_IP $proto dport "$START_PORT-$END_PORT" accept
      done
    else
      nft delete table $TABLE_FAMILY $TABLE_NAME >/dev/null 2>&1 || true
    fi

    if [ -w /etc/nftables.conf ]; then
      nft list ruleset >/etc/nftables.conf 2>/dev/null || true
    elif command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q nftables.service; then
      nft list ruleset >/etc/nftables.conf 2>/dev/null || true
      systemctl enable nftables >/dev/null 2>&1 || true
      systemctl restart nftables >/dev/null 2>&1 || true
    fi
    ;;
  *)
    echo "未知实现: $BACKEND" >&2
    exit 1
    ;;
esac
EOF
    if [[ "$action" == "apply" ]]; then
      info "直接转发模式端口映射已配置完成"
    else
      info "直接转发模式端口映射已清理"
    fi
  else
    if [[ "$action" == "apply" ]]; then
      err "直接转发模式端口映射配置失败"
    else
      err "直接转发模式端口映射清理失败"
    fi
    return 1
  fi

  if [[ "$action" == "apply" ]]; then
    write_remote_flag "$REMOTE_DIRECT_FLAG" \
      "mode=direct" \
      "backend=$backend" \
      "ports=${start_port}-${end_port}" \
      "target=$target_ip" \
      "snat=$snat_ip" \
      "ext_if=$ext_if" \
      "int_if=$int_if"
    write_local_flag "$direct_flag" "mode=direct" "backend=$backend" "ports=${start_port}-${end_port}" "target=$target_ip" "snat=$snat_ip" "ext_if=$ext_if" "int_if=$int_if"
  else
    clear_remote_flag "$REMOTE_DIRECT_FLAG"
    rm -f "$direct_flag"
  fi
}

violent_mode_enable() {
  if ! ensure_remote_context; then
    warn "无法建立中国内地端 SSH 连接，已取消操作"
    return 1
  fi
  select_qh_direct_ifaces || return 1
  clean_remote_legacy_rules

  local start_port end_port
  read -r start_port end_port < <(prompt_port_range "10000-65535")

  local ssh_port="${REMOTE_PORT:-22}"
  if [[ "$ssh_port" =~ ^[0-9]+$ ]] && (( ssh_port >= start_port && ssh_port <= end_port )); then
    warn "警告：端口范围包含当前 SSH 端口 ${ssh_port}，可能导致连接异常，请确保已准备备用管理通道"
    read -rp "仍要继续配置该端口范围？[y/N]: " confirm_choice
    if [[ "$confirm_choice" != "y" && "$confirm_choice" != "Y" ]]; then
      info "已取消直接转发模式端口映射配置"
      return 1
    fi
  fi

  local backend
  backend=$(select_direct_backend) || return 1

  local existing_backend="" existing_ports=""
  if remote_exec "test -f $REMOTE_DIRECT_FLAG"; then
    existing_backend=$(read_remote_flag "$REMOTE_DIRECT_FLAG" "backend")
    existing_ports=$(read_remote_flag "$REMOTE_DIRECT_FLAG" "ports")
  fi

  if [[ -n "$existing_backend" && "$existing_backend" != "$backend" ]]; then
    err "已存在 ${existing_backend} 实现的直接转发，请先卸载后再切换实现"
    return 1
  fi

  apply_violent_mode_rules "apply" "$start_port" "$end_port" "$backend"
  mark_action "direct_forward_apply" "使用 $backend ${start_port}-${end_port} -> $HK_LAN_IP via $QH_EXTERNAL_IF->$QH_INTERNAL_IF"
}

violent_mode_disable() {
  if ! ensure_remote_context; then
    warn "无法建立中国内地端 SSH 连接，已取消操作"
    return 1
  fi
  select_qh_direct_ifaces || return 1
  clean_remote_legacy_rules

  local start_port end_port backend selected_from_flag=0
  local existing_backend="" existing_ports="" existing_ext="" existing_int=""
  if remote_exec "test -f $REMOTE_DIRECT_FLAG"; then
    existing_backend=$(read_remote_flag "$REMOTE_DIRECT_FLAG" "backend")
    existing_ports=$(read_remote_flag "$REMOTE_DIRECT_FLAG" "ports")
    existing_ext=$(read_remote_flag "$REMOTE_DIRECT_FLAG" "ext_if")
    existing_int=$(read_remote_flag "$REMOTE_DIRECT_FLAG" "int_if")
  fi

  if [[ -n "$existing_ports" && "$existing_ports" =~ ^[0-9]+-[0-9]+$ ]]; then
    start_port="${existing_ports%-*}"
    end_port="${existing_ports#*-}"
    selected_from_flag=1
  else
    read -r start_port end_port < <(prompt_port_range "10000-65535")
  fi

  if [[ -n "$existing_backend" ]]; then
    backend="$existing_backend"
    selected_from_flag=1
  else
    backend=$(select_direct_backend) || return 1
  fi

  local ext_if="${existing_ext:-$QH_EXTERNAL_IF}"
  local int_if="${existing_int:-$QH_INTERNAL_IF}"
  if [[ -z "$int_if" ]]; then
    int_if="$ext_if"
  fi

  local ssh_port="${REMOTE_PORT:-22}"
  if [[ "$ssh_port" =~ ^[0-9]+$ ]] && (( ssh_port >= start_port && ssh_port <= end_port )); then
    warn "警告：端口范围包含当前 SSH 端口 ${ssh_port}，如果此前映射生效可能影响连接"
    read -rp "仍要继续卸载该端口范围的映射？[y/N]: " confirm_choice
    if [[ "$confirm_choice" != "y" && "$confirm_choice" != "Y" ]]; then
      info "已取消直接转发模式端口映射卸载"
      return 1
    fi
  fi

  apply_violent_mode_rules "clear" "$start_port" "$end_port" "$backend" "$ext_if" "$int_if"
  mark_action "direct_forward_clear" "使用 $backend 清理 ${start_port}-${end_port} (from_flag=$selected_from_flag) $ext_if->$int_if"
}

# ==================== 主函数 ====================
main() {
  trap cleanup_temp_key EXIT
  info "HaloCloud SD-WAN 网络配置工具"
  info "Script By Telegram @AstroQore"
  info "路由模式部分逻辑参考 By Telegram @shenlr2011"
  check_root
  ensure_packages curl

  if (( SB_MODE )); then
    WORK_MODE="route"
    info "检测到 sbmode 参数：将自动执行路由模式（菜单 1 和菜单 3）"
    if ! run_menu_action "设置香港端SNAT路由" setup_hk_route; then
      err "sbmode: 香港端SNAT路由配置失败，已停止自动执行"
      exit 1
    fi
    if ! run_menu_action "设置中国内地端策略路由" setup_qh_route; then
      err "sbmode: 中国内地端策略路由配置失败，已停止自动执行"
      exit 1
    fi
    info "sbmode 自动执行完成"
    exit 0
  fi

  while true; do
    select_work_mode

    if [[ "$WORK_MODE" == "proxy" ]]; then
      while true; do
        show_proxy_menu
        read -rp "请选择操作: " choice
        case "$choice" in
          1) run_menu_action "安装香港端代理服务器" install_hk_proxy ;;
          2) run_menu_action "卸载香港端代理服务器" uninstall_hk_proxy ;;
          3) run_menu_action "安装中国内地端代理客户端" install_qh_proxy ;;
          4) run_menu_action "卸载中国内地端代理客户端" uninstall_qh_proxy ;;
          5) run_menu_action "设置中国内地端自动代理" enable_qh_autoproxy ;;
          6) run_menu_action "取消中国内地端自动代理" disable_qh_autoproxy ;;
          b|B)
            break
            ;;
          q|Q)
            echo "已退出"
            exit 0
            ;;
          *)
            echo "无效选项，请重新输入"
          ;;
        esac
        echo
      done
    elif [[ "$WORK_MODE" == "route" ]]; then
      while true; do
        show_route_menu
        read -rp "请选择操作: " choice
        case "$choice" in
          1) run_menu_action "设置香港端SNAT路由" setup_hk_route ;;
          2) run_menu_action "取消香港端SNAT路由" clear_hk_route ;;
          3) run_menu_action "设置中国内地端策略路由" setup_qh_route ;;
          4) run_menu_action "取消中国内地端策略路由" clear_qh_route ;;
          5) run_menu_action "设置中国内地端默认路由走香港" set_qh_default_route ;;
          6) run_menu_action "恢复中国内地端默认路由" restore_qh_default_route ;;
          b|B)
            break
            ;;
          q|Q)
            echo "已退出"
            exit 0
            ;;
          *)
            echo "无效选项，请重新输入"
          ;;
        esac
        echo
      done
    else
      while true; do
        show_violent_menu
        read -rp "请选择操作: " choice
        case "$choice" in
          1) run_menu_action "启用直接转发模式端口映射" violent_mode_enable ;;
          2) run_menu_action "卸载直接转发模式端口映射" violent_mode_disable ;;
          b|B)
            break
            ;;
          q|Q)
            echo "已退出"
            exit 0
            ;;
          *)
            echo "无效选项，请重新输入"
            ;;
        esac
        echo
      done
    fi
  done
}

parse_args "$@"
main "$@"
