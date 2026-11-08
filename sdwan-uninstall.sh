#!/usr/bin/env bash
# =============================================================================
# sdwan-uninstall.sh — 原版 sdwan.sh 路由模式的独立卸载脚本（在香港机 root 执行）
#
# 适用于「之前装过原版（或装错了）想先卸干净再重装」：清理逻辑与原版菜单里的
# 「清除香港端 SNAT 路由（clear_hk_route）」「清除内地端策略路由（clear_qh_route）」
# 保持一致，只是合成一键：香港机本地清理 + SSH 进内地机远程清理 + 清除记忆。
#
# 做什么：
#   香港机：删 nft hk_snat 表 / iptables SNAT 与 FORWARD 规则、停删 hk-snat-restore
#           服务与恢复脚本、恢复 cloud-init 网络配置、保存 iptables 规则
#   内地机：先按 ~/.true_original_default_route 快照恢复原始默认路由，再删策略路由
#           规则与表、qh_mark 标记、恢复服务、看门狗与定时任务、cloud-init 配置、
#           DNS 恢复原备份、apt 自动升级状态恢复，最后删路由快照与状态文件
#   两端完事后清除香港机记忆（/root/.kkix_config 与 /root/.kkix_state）
# 恢复自检（据 2026-11-09 ECS1419 那套的实测教训补强）：内地机恢复后校验网关
# 可达、清空 conntrack、验 DNS 解析（坏了先拉 systemd-resolved、再不行写静态
# nameserver），最后实测 TCP 出口；自检异常会在结尾明确报警，不再假报成功。
# 内地机 IP/用户/端口从 /root/.kkix_config 读；读不到或连不上时会在终端让你输入。
# 密码在终端输入（不回显），与原版一致。
# =============================================================================
set -uo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

CONFIG_FILE="/root/.kkix_config"
STATE_DIR="/root/.kkix_state"
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $1" >&2; exit "${2:-1}"; }

QH_IP="" HK_LAN_IP="" REMOTE_USER="root" REMOTE_PORT="22" REMOTE_AUTH=""
# 白名单读原版配置（不 source 执行）
if [[ -f "$CONFIG_FILE" ]]; then
  while IFS='=' read -r k v; do
    case "$k" in
      QIANHAI_LAN_IP) QH_IP="$v" ;;
      HK_LAN_IP) HK_LAN_IP="$v" ;;
      REMOTE_USER) [[ -n "$v" ]] && REMOTE_USER="$v" ;;
      REMOTE_PORT) [[ -n "$v" ]] && REMOTE_PORT="$v" ;;
      REMOTE_AUTH) REMOTE_AUTH="$v" ;;
    esac
  done < "$CONFIG_FILE"
fi
# 命令行可覆盖内地 IP（记忆里的 IP 是错的时候用）
while (($#)); do
  case "$1" in
    --qh-ip) QH_IP="${2:?}"; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数: $1" 2 ;;
  esac
  shift
done

[[ $(id -u) -eq 0 ]] || die "请以 root 执行" 1

_ip2int() { local IFS=. a b c d; read -r a b c d <<<"$1"; echo $(( (a<<24) + (b<<16) + (c<<8) + d )); }
_net_of() { # $1=ip/cidr -> a.b.c.d/prefix
  local ip="${1%/*}" bits="${1##*/}" n mask
  n=$(_ip2int "$ip"); mask=$(( bits==0 ? 0 : (4294967295 << (32-bits)) & 4294967295 )); n=$(( n & mask ))
  printf '%d.%d.%d.%d/%s' $(( (n>>24)&255 )) $(( (n>>16)&255 )) $(( (n>>8)&255 )) $(( n&255 )) "$bits"
}

# ---------------- 香港端接口信息（与原版探测口径一致） ----------------
HK_EXT_IF=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
HK_EXT_IP=$(ip -o -4 addr show "$HK_EXT_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
if [[ -z "$HK_LAN_IP" ]]; then
  # 自动挑私网地址（原版 detect_default_hk_ip 同口径：私网优先）
  HK_LAN_IP=$(ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -E '^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)' | head -n1)
fi
HK_INT_IF=""
if [[ -n "$HK_LAN_IP" ]]; then
  HK_INT_IF=$(ip -o -4 addr show | awk -v ip="$HK_LAN_IP" '$4 ~ "^" ip "/" {print $2; exit}')
fi
HK_INT_CIDR=$(ip -o -4 addr show "$HK_INT_IF" 2>/dev/null | awk '{print $4}' | head -n1)
HK_INT_NET=""; [[ -n "$HK_INT_CIDR" ]] && HK_INT_NET=$(_net_of "$HK_INT_CIDR")

# ---------------- 1. 香港机本地清理（对应原版 clear_hk_route） ----------------
info "清理香港端..."
nft delete table ip hk_snat >/dev/null 2>&1 || true
if [[ -n "$HK_INT_NET" && -n "$HK_EXT_IF" && -n "$HK_EXT_IP" ]]; then
  iptables -t nat -D POSTROUTING -s "$HK_INT_NET" -o "$HK_EXT_IF" -j SNAT --to-source "$HK_EXT_IP" 2>/dev/null || true
fi
if [[ -n "$QH_IP" && -n "$HK_INT_IF" && -n "$HK_EXT_IF" ]]; then
  iptables -D FORWARD -s "$QH_IP" -i "$HK_INT_IF" -o "$HK_EXT_IF" -j ACCEPT 2>/dev/null || true
fi
if systemctl list-unit-files 2>/dev/null | grep -q 'hk-snat-restore.service'; then
  systemctl disable hk-snat-restore.service >/dev/null 2>&1 || true
  systemctl stop hk-snat-restore.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/hk-snat-restore.service
  systemctl daemon-reload >/dev/null 2>&1 || true
fi
rm -f /usr/local/bin/restore-hk-snat.sh
rm -f /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save >/dev/null 2>&1 || true
else
  mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi
info "香港端清理完成"

# ---------------- 2. 内地机远程清理（对应原版 clear_qh_route） ----------------
tty_ok() { [[ -r /dev/tty ]] && ( : >/dev/tty ) 2>/dev/null; }
if [[ -z "$QH_IP" ]] && tty_ok; then
  printf '请输入内地机局域网 IP: ' > /dev/tty
  IFS= read -r QH_IP < /dev/tty || QH_IP=""
fi
[[ -n "$QH_IP" ]] || die "不知道内地机 IP（配置里没有、也没法问）：香港端已清理，内地机请用 --qh-ip 指定后重跑本脚本补清" 1

if ! command -v sshpass >/dev/null 2>&1 && [[ "$REMOTE_AUTH" != "key" ]]; then
  info "自动安装 sshpass（与原版 ensure_packages 相同处理）..."
  apt-get update -qq >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass >/dev/null 2>&1 || warn "sshpass 安装失败，若内地机是密钥登录可忽略"
fi

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o LogLevel=ERROR -p "$REMOTE_PORT")
build_ssh() { # $1=password|key
  if [[ "$1" == "key" ]] || ! command -v sshpass >/dev/null 2>&1; then
    SSH_BASE=(ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${REMOTE_USER}@${QH_IP}")
  else
    SSH_BASE=(sshpass -e ssh "${SSH_OPTS[@]}" -o PreferredAuthentications=password "${REMOTE_USER}@${QH_IP}")
  fi
}
ssh_try() { "${SSH_BASE[@]}" true >/dev/null 2>&1; }

connect_remote() {
  # 优先按记住的认证方式；失败且有终端时让用户输密码（原版口径）
  if [[ "$REMOTE_AUTH" == "key" ]]; then build_ssh key; ssh_try && return 0; fi
  build_ssh key; ssh_try && return 0
  if tty_ok && command -v sshpass >/dev/null 2>&1; then
    local pw=""
    printf '请输入内地机 %s@%s 的登录密码（输入不回显）: ' "$REMOTE_USER" "$QH_IP" > /dev/tty
    IFS= read -r -s pw < /dev/tty || pw=""
    printf '\n' > /dev/tty
    [[ -n "$pw" ]] || return 1
    export SSHPASS="$pw"
    build_ssh password; ssh_try && return 0
  fi
  return 1
}
if ! connect_remote; then
  # 记住的 IP 可能就是错的：让用户改输一次
  if tty_ok; then
    warn "连不上内地机 $QH_IP（记住的 IP 可能有误）"
    printf '请重新输入内地机局域网 IP（直接回车放弃）: ' > /dev/tty
    _new=""; IFS= read -r _new < /dev/tty || _new=""
    if [[ -n "$_new" ]]; then QH_IP="$_new"; connect_remote || die "仍连不上内地机 $QH_IP：香港端已清理，内地机待手动清理" 1; fi
  fi
  [[ -n "${_new:-}" ]] || die "SSH 连不上内地机 $QH_IP：香港端已清理，内地机待手动清理（或修好后重跑本脚本）" 1
fi
info "已连接内地机 ${REMOTE_USER}@${QH_IP}，执行远程清理..."
REMOTE_SUDO="sudo -n"; [[ "$REMOTE_USER" == "root" ]] && REMOTE_SUDO=""

REMOTE_CLEAN=$(cat <<'RCLEAN'
set +e
QH_INT_IP="$1"; HK_LAN_IP="$2"
# 找外网口：优先原始路由快照的 dev，其次当前默认路由 dev（且不是内网口）
SNAP=""
for f in ~/.true_original_default_route /root/.true_original_default_route; do [ -s "$f" ] && SNAP=$(head -n1 "$f") && break; done
QH_EXT_IF=$(awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' <<<"$SNAP" | head -n1)
QH_INT_IF=$(ip -o -4 addr show | awk -v ip="$QH_INT_IP" '$4 ~ "^" ip "/" {print $2; exit}')
[ -z "$QH_EXT_IF" ] && QH_EXT_IF=$(ip route show default | awk '{print $5; exit}')
[ "$QH_EXT_IF" = "$QH_INT_IF" ] && QH_EXT_IF=""
QH_EXT_IP=$(ip -o -4 addr show "$QH_EXT_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
# 1) 策略路由规则与表
while ip rule del from "$QH_EXT_IP" table ix_return 2>/dev/null; do :; done
while ip rule del from "$QH_INT_IP" table internal_out 2>/dev/null; do :; done
while ip rule del fwmark 100 table ix_return 2>/dev/null; do :; done
ip route flush table ix_return 2>/dev/null
ip route flush table internal_out 2>/dev/null
[ -n "$HK_LAN_IP" ] && ip route del "$HK_LAN_IP"/32 2>/dev/null
for dns in 8.8.8.8 1.1.1.1; do ip route del "$dns"/32 2>/dev/null; done
# 2) 标记规则
nft delete table inet qh_mark >/dev/null 2>&1
[ -n "$QH_EXT_IF" ] && iptables -t mangle -D PREROUTING -i "$QH_EXT_IF" -j CONNMARK --set-mark 100 2>/dev/null
iptables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null
# 3) 恢复原始默认路由（快照优先；没有快照不猜，保持现状并提示）
if [ -n "$SNAP" ]; then
  ip route del default 2>/dev/null
  ip route add $SNAP 2>/dev/null || ip route replace $SNAP
  echo "[remote] 默认路由已恢复: $SNAP"
elif [ -s ~/.last_default_route ]; then
  LAST=$(head -n1 ~/.last_default_route)
  case "$LAST" in *"$QH_INT_IF"*) echo "[remote] 最后保存的路由指向内网，未采用，请人工确认默认路由" ;;
    *) ip route del default 2>/dev/null; ip route add $LAST 2>/dev/null; echo "[remote] 默认路由已恢复: $LAST" ;;
  esac
else
  echo "[remote] 无原始路由快照，默认路由保持现状，请人工确认"
fi
# 3.5) 网关校验 + 清空连接跟踪（路由大改后旧 conntrack 状态会让 TCP 卡死，实测教训）
GW_IP=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' | head -n1)
if [ -n "$GW_IP" ]; then
  if ping -c1 -W2 "$GW_IP" >/dev/null 2>&1; then echo "[remote] 网关 $GW_IP 可达"; else echo "[remote] 警告: 网关 $GW_IP ping 不通，请人工确认默认路由"; fi
fi
conntrack -F >/dev/null 2>&1
# 4) DNS 恢复
chattr -i /etc/resolv.conf 2>/dev/null
if [ -f ~/.original_resolv.conf ]; then cp ~/.original_resolv.conf /etc/resolv.conf; rm -f ~/.original_resolv.conf;
elif [ -f /etc/resolv.conf.backup ]; then cp /etc/resolv.conf.backup /etc/resolv.conf; fi
chmod 644 /etc/resolv.conf 2>/dev/null
if [ -f /etc/qh_systemd_resolved_state ]; then
  . /etc/qh_systemd_resolved_state
  [ "${was_enabled:-}" = "enabled" ] && systemctl enable systemd-resolved >/dev/null 2>&1
  [ "${was_active:-}" = "active" ] && systemctl start systemd-resolved >/dev/null 2>&1
  rm -f /etc/qh_systemd_resolved_state
fi
[ -f /etc/nsswitch.conf.qhbackup ] && cp /etc/nsswitch.conf.qhbackup /etc/nsswitch.conf && rm -f /etc/nsswitch.conf.qhbackup
# 4.5) DNS 解析自检与修复（无备份可恢复时 resolv.conf 可能残留坏状态，实测教训）
if ! getent hosts www.baidu.com >/dev/null 2>&1; then
  echo "[remote] DNS 解析异常，尝试修复..."
  systemctl enable --now systemd-resolved >/dev/null 2>&1
  sleep 1
  if ! getent hosts www.baidu.com >/dev/null 2>&1; then
    chattr -i /etc/resolv.conf 2>/dev/null
    [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
    printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\n' > /etc/resolv.conf
  fi
fi
if getent hosts www.baidu.com >/dev/null 2>&1; then echo "[remote] DNS 解析正常"; else echo "[remote] DNS 仍异常，请人工检查 /etc/resolv.conf"; fi
# 5) 服务/脚本/定时任务
systemctl disable --now network-check.timer >/dev/null 2>&1
systemctl disable qh-route-restore.service >/dev/null 2>&1
systemctl stop qh-route-restore.service >/dev/null 2>&1
rm -f /etc/systemd/system/qh-route-restore.service /etc/systemd/system/network-check.service /etc/systemd/system/network-check.timer
rm -f /usr/local/bin/restore-qh-route.sh /usr/local/bin/check-network.sh
if command -v crontab >/dev/null 2>&1; then
  crontab -l 2>/dev/null | grep -v check-network.sh > /tmp/crontab.tmp || true
  crontab /tmp/crontab.tmp 2>/dev/null; rm -f /tmp/crontab.tmp
fi
systemctl daemon-reload >/dev/null 2>&1
# 6) cloud-init 与状态文件、路由快照
rm -f /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
rm -f /etc/qh_route_status /etc/qh_default_route_mode
rm -f ~/.last_default_route ~/.true_original_default_route
# 7) apt 自动升级状态恢复（原版曾关过的话）
if [ -f /etc/qh_auto_upgrade_state ]; then
  while IFS='=' read -r unit state; do
    [ -z "$unit" ] && continue
    case "$state" in enabled|enabled-runtime) systemctl enable "$unit" >/dev/null 2>&1 ;; esac
  done < /etc/qh_auto_upgrade_state
  rm -f /etc/qh_auto_upgrade_state
fi
# 8) 保存 iptables
mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4 2>/dev/null
# 9) 出口自检（TCP 实测，不让"卸载完成"掩盖公网异常，实测教训）
EGRESS_IP=$(curl -s -m 6 https://ifconfig.me 2>/dev/null)
if [ -n "$EGRESS_IP" ]; then
  echo "[remote] 出口自检正常，当前出口 IP: $EGRESS_IP"
  echo "REMOTE_TCP_OK"
elif ping -c1 -W2 223.5.5.5 >/dev/null 2>&1; then
  echo "[remote] 出口自检异常: ICMP 通但 TCP 不通，多为云厂商侧公网 IP 状态问题，请在控制台对本机关机再开机后再重装"
  echo "REMOTE_TCP_BAD"
else
  echo "[remote] 出口自检异常: 公网不通，请人工检查默认路由与网关"
  echo "REMOTE_TCP_BAD"
fi
echo "[remote] 内地机清理完成"
RCLEAN
)
REMOTE_OUT=$(printf '%s' "$REMOTE_CLEAN" | "${SSH_BASE[@]}" "$REMOTE_SUDO bash -s -- '$QH_IP' '$HK_LAN_IP'") || die "内地机远程清理执行失败：香港端已清理，内地机请检查后重跑本脚本" 1
printf '%s\n' "$REMOTE_OUT"

# ---------------- 3. 清除记忆 ----------------
rm -f "$CONFIG_FILE"
rm -rf "$STATE_DIR"
if grep -q "REMOTE_TCP_BAD" <<<"$REMOTE_OUT"; then
  warn "卸载完成（两端配置已清除、记忆已清空），但内地机出口自检异常（见上方 [remote] 提示）：先按提示处理再重装"
else
  info "卸载完成：两端原版配置已清除、记忆已清空，内地机出口自检正常，现在可以重新安装"
fi
