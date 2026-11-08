#!/usr/bin/env bash
# =============================================================================
# ix-uninstall.sh — ix-onekey.sh 的独立卸载脚本（在香港机以 root 执行）
#
# 做什么：
#   香港机：停用并删除守护定时器、SNAT 恢复服务、nft hk_snat 表、sysctl.d 文件，
#           按安装快照决定是否把 ip_forward 改回 0，删除配置与状态目录、守护密钥
#   内地机（SSH 远程）：先把默认路由恢复成安装前快照的原始默认路由，再删除
#           策略路由表/规则、qh_mark 标记表、恢复服务、看门狗、死人开关、状态文件，
#           并摘掉香港机守护公钥（按公钥内容精确匹配）
# 兼容：对原版 sdwan.sh 路由模式留下的同名文件/服务也会一并清理（尽力而为）。
# 用法：
#   bash ix-uninstall.sh --qh-ip <内地机内网IP>   # 运行时会提示输入内地机密码（不回显、不落盘）
#   bash ix-uninstall.sh --ssh-key /root/.ssh/id_ed25519   # 或已有 /root/.kkix_config 时可省略参数
# 说明：/etc/iproute2/rt_tables 里的 ix_return/internal_out 登记行无害，保留不删。
# =============================================================================
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

QH_IP="${KKIX_QH_IP:-}" SSH_USER="${KKIX_SSH_USER:-root}" SSH_PORT="${KKIX_SSH_PORT:-22}"
SSH_KEY="${KKIX_SSH_KEY:-}" CONFIG_FILE="${KKIX_CONFIG:-/root/.kkix_config}"
STATE_DIR="/root/.kkix_state"
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $1" >&2; exit "${2:-1}"; }

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

while (($#)); do
  case "$1" in
    --qh-ip) QH_IP="${2:?}"; shift ;;
    --ssh-user) SSH_USER="${2:?}"; shift ;;
    --ssh-port) SSH_PORT="${2:?}"; shift ;;
    --ssh-key) SSH_KEY="${2:?}"; shift ;;
    --config) CONFIG_FILE="${2:?}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1（--help 查看用法）" 2 ;;
  esac
  shift
done

# 从原版/ix-onekey 的配置文件补全参数（白名单解析，不 source）
if [[ -f "$CONFIG_FILE" ]]; then
  while IFS='=' read -r k v; do
    v="${v%\"}"; v="${v#\"}"
    case "$k" in
      QIANHAI_LAN_IP) [[ -z "$QH_IP" ]] && QH_IP="$v" ;;
      REMOTE_USER) SSH_USER="$v" ;;
      REMOTE_PORT) SSH_PORT="$v" ;;
    esac
  done < "$CONFIG_FILE"
fi

[[ $(id -u) -eq 0 ]] || die "请以 root 执行" 1
[[ -n "$QH_IP" ]] || die "缺少内地机 IP：--qh-ip 或配置文件 QIANHAI_LAN_IP" 2

# ---------- 准备 SSH（优先守护密钥，其次 --ssh-key / 密码 / 默认密钥） ----------
GUARD_BLOB=""
[[ -f /root/.ssh/kkix_guard.pub ]] && GUARD_BLOB=$(awk '{print $2}' /root/.ssh/kkix_guard.pub)
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$STATE_DIR/known_hosts.uninstall"
          -o ConnectTimeout=10 -o LogLevel=ERROR -p "$SSH_PORT")
mkdir -p "$STATE_DIR"
SSH_BASE=()
if [[ -n "$SSH_KEY" ]]; then
  SSH_BASE=(ssh "${SSH_OPTS[@]}" -o BatchMode=yes -i "$SSH_KEY" "${SSH_USER}@${QH_IP}")
elif [[ -n "${KKIX_SSH_PASS:-}" ]]; then
  command -v sshpass >/dev/null 2>&1 || die "密码方式需要 sshpass（apt-get install -y sshpass）" 1
  export SSHPASS="$KKIX_SSH_PASS"
  SSH_BASE=(sshpass -e ssh "${SSH_OPTS[@]}" -o PreferredAuthentications=password "${SSH_USER}@${QH_IP}")
elif [[ -f /root/.ssh/kkix_guard ]]; then
  SSH_BASE=(ssh "${SSH_OPTS[@]}" -o BatchMode=yes -i /root/.ssh/kkix_guard "${SSH_USER}@${QH_IP}")
elif [[ -r /dev/tty ]] && ( : >/dev/tty ) 2>/dev/null; then
  # 交互输入密码：不回显、不落盘，只输一次
  printf '请输入内地机 %s@%s 的登录密码（输入不回显）: ' "$SSH_USER" "$QH_IP" > /dev/tty
  IFS= read -r -s KKIX_RUNTIME_PW < /dev/tty && printf '\n' > /dev/tty || KKIX_RUNTIME_PW=""
  if [[ -n "${KKIX_RUNTIME_PW:-}" ]]; then
    command -v sshpass >/dev/null 2>&1 || die "密码方式需要 sshpass（apt-get install -y sshpass）" 1
    export SSHPASS="$KKIX_RUNTIME_PW"
    SSH_BASE=(sshpass -e ssh "${SSH_OPTS[@]}" -o PreferredAuthentications=password "${SSH_USER}@${QH_IP}")
  else
    SSH_BASE=(ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${SSH_USER}@${QH_IP}")
  fi
else
  SSH_BASE=(ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${SSH_USER}@${QH_IP}")
fi
REMOTE_SUDO="sudo -n"; [[ "$SSH_USER" == "root" ]] && REMOTE_SUDO=""
remote_exec() { "${SSH_BASE[@]}" "$*"; }

# ---------- 1. 内地机远程清理 ----------
info "连接内地机 ${SSH_USER}@${QH_IP}:${SSH_PORT} 执行远程清理..."
REMOTE_CLEAN=$(cat <<'RCLEAN'
set +e
# 1) 先恢复安装前的原始默认路由（回滚锚点）
ORIG=""
for f in /etc/kkix_state/true_original_default_route /root/.true_original_default_route ~/.true_original_default_route; do
  [ -s "$f" ] && ORIG=$(head -n1 "$f") && break
done
if [ -n "$ORIG" ]; then
  ip route replace $ORIG 2>/dev/null || ip route add $ORIG 2>/dev/null
  echo "[remote] 默认路由已恢复: $ORIG"
else
  echo "[remote] 未找到原始路由快照，默认路由保持现状，请人工确认"
fi
# 2) 策略路由与标记
nft delete table inet qh_mark >/dev/null 2>&1
EXT_IF=$(awk -F= '$1=="external_if"{print $2}' /etc/kkix_route_flag 2>/dev/null)
if [ -n "$EXT_IF" ]; then
  iptables -t mangle -D PREROUTING -i "$EXT_IF" -j CONNMARK --set-mark 100 2>/dev/null
  iptables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null
fi
while ip rule del table ix_return 2>/dev/null; do :; done
while ip rule del table internal_out 2>/dev/null; do :; done
ip route flush table ix_return 2>/dev/null
ip route flush table internal_out 2>/dev/null
# 3) 服务与文件
systemctl disable --now network-check.timer qh-route-restore.service >/dev/null 2>&1
rm -f /etc/systemd/system/qh-route-restore.service /etc/systemd/system/network-check.service /etc/systemd/system/network-check.timer
rm -f /usr/local/bin/restore-qh-route.sh /usr/local/bin/check-network.sh /usr/local/bin/kkix-deadman.sh
rm -f /etc/qh_route_status /etc/kkix_route_flag /etc/qh_default_route_mode /etc/sysctl.d/99-kkix-route.conf
rm -f ~/.true_original_default_route ~/.last_default_route ~/.before_hk_default_route ~/.original_resolv.conf
rm -rf /etc/kkix_state
chattr -i /etc/resolv.conf 2>/dev/null
systemctl daemon-reload >/dev/null 2>&1
echo "[remote] 内地机清理完成"
RCLEAN
)
if ! printf '%s' "$REMOTE_CLEAN" | "${SSH_BASE[@]}" "$REMOTE_SUDO bash -s" ; then
  die "内地机远程清理失败：先确认能 SSH 登录内地机；香港机本地部分尚未清理，可修好后重跑本脚本" 1
fi
# 摘掉守护公钥（按公钥 blob 精确匹配）
if [[ -n "$GUARD_BLOB" ]]; then
  remote_exec "grep -v '$GUARD_BLOB' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp 2>/dev/null && cat ~/.ssh/authorized_keys.tmp > ~/.ssh/authorized_keys && rm -f ~/.ssh/authorized_keys.tmp" >/dev/null 2>&1 || true
  info "已摘除内地机上的香港机守护公钥"
fi

# ---------- 2. 香港机本地清理 ----------
info "清理香港机本地配置..."
HK_EXT_IF=$(awk -F= '$1=="hk_external_if"{print $2}' "$STATE_DIR/hk_route_flag" 2>/dev/null || true)
HK_INT_IF=$(awk -F= '$1=="hk_internal_if"{print $2}' "$STATE_DIR/hk_route_flag" 2>/dev/null || true)
systemctl disable --now kkix-guard-hk.timer >/dev/null 2>&1 || true
systemctl disable hk-snat-restore.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/kkix-guard-hk.service /etc/systemd/system/kkix-guard-hk.timer /usr/local/bin/kkix-guard-hk.sh
rm -f /etc/systemd/system/hk-snat-restore.service /usr/local/bin/restore-hk-snat.sh
rm -rf /etc/kkix-guard
systemctl daemon-reload >/dev/null 2>&1 || true
nft delete table ip hk_snat >/dev/null 2>&1 || true
if [[ -n "$HK_EXT_IF" && -n "$HK_INT_IF" ]]; then
  EXT_IP=$(ip -o -4 addr show "$HK_EXT_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
  INT_CIDR=$(ip -o -4 addr show "$HK_INT_IF" 2>/dev/null | awk '{print $4}' | head -n1)
  if [[ -n "$EXT_IP" && -n "$INT_CIDR" ]]; then
    NET=$(python3 -c "import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False))" "$INT_CIDR" 2>/dev/null || echo "")
    if [[ -n "$NET" ]]; then
      iptables -t nat -D POSTROUTING -s "$NET" -o "$HK_EXT_IF" -j SNAT --to-source "$EXT_IP" 2>/dev/null || true
      iptables -D FORWARD -s "$QH_IP" -i "$HK_INT_IF" -o "$HK_EXT_IF" -j ACCEPT 2>/dev/null || true
    fi
  fi
fi
rm -f /etc/sysctl.d/99-kkix-route.conf
if [[ -f "$STATE_DIR/latest_backup" ]]; then
  BD=$(cat "$STATE_DIR/latest_backup" 2>/dev/null || true)
  if [[ -n "$BD" && -f "$BD/ip_forward.before" && "$(cat "$BD/ip_forward.before")" == "0" ]]; then
    sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
    info "ip_forward 已按安装前快照改回 0"
  fi
fi
rm -rf "$STATE_DIR" /root/.kkix_config /root/.ssh/kkix_guard /root/.ssh/kkix_guard.pub /root/.ssh/kkix_known_hosts
info "卸载完成：两端组网配置、守护与恢复机制均已移除（rt_tables 登记行无害保留）"
info "内地机当前默认路由请再用 'ip route show default' 人工确认一次"
