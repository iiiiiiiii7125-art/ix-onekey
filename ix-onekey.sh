#!/usr/bin/env bash
# =============================================================================
# ix-onekey.sh — HaloCloud IX 组网「路由模式」一键脚本（IP 自动识别 + 密码交互输入 + 双层自动守护）
#
# v3.0 设计（吸取原版在真实双机上的全部教训）：
#   - 网关绝不猜测：两端外网网关只取「改动前真实默认路由」或对端保存的原始
#     路由快照，取不到就停。原版把深圳网关猜成 x.x.145.1（真实 .144.1）并写死进
#     恢复脚本，导致每次恢复后公网 SSH 回程被打断——本版从源头杜绝。
#   - 网卡不用启发式猜：内网口 = `ip route get 对端IP` 实际走的网卡/源地址。
#   - 重启不丢失三件套：① 开机恢复脚本等网卡就绪、等香港可达（最长 120s）再决策
#     ② 深圳本地看门狗（每 2 分钟）双向全量收敛：默认路由、ix_return 回程表、
#     标记表缺一即整套重跑恢复 ③ 香港机守护定时器（每 2 分钟）本机自检 +
#     SSH 进对端触发其恢复。任何一层单独工作都能在重启后自愈。
#   - nft 一律 iifname/oifname，开机时网卡未出现也不会加不上规则。
#   - 安装切默认路由前武装死人开关，控制器新 SSH 验出口通过才解除。
#
# 由原 sdwan.sh (beta-flag-2024-10, 3673 行) 的 --sbmode 路径重构而来：
#   原版问题：号称免交互，但 SSH 信息收集函数 ensure_remote_context() 没有
#   sbmode 分支，一次运行最多要回答 44 处 read 中的 6~10 处；且先改香港端、
#   后连前海端，失败不回滚；默认路由一切错就断联，没有看门狗。
#
# 本版原则：
#   1. 与原版一致的人机分工：IP 类信息一律自动识别（香港端 IP 探测、对端 IP
#      先读已保存配置、没有就扫内网段按 SSH banner 识别，多台时终端编号选）；
#      密码由用户在终端交互输入（不回显、只输一次）。其余参数来自命令行 /
#      环境变量 / 配置文件；检测不确定 -> 在「任何修改发生之前」报错退出（退出码 3）。
#   2. 先体检后动刀：preflight 只读探测（本机 + 一次 SSH 批量探测前海端），
#      打印最终计划，校验接口/IP/网段/网关/SSH/sudo，全部通过才开始改。
#   3. 切默认路由前先武装「死人开关」：N 秒内控制器没确认成功，前海端自动
#      把默认路由切回快照值，不会因切错而失联等救援。
#   4. 幂等：重复运行结果一致；只动自己的 nft 表/链和 sysctl.d 文件，
#      不再 `iptables -P FORWARD DROP`、不整表覆盖 /etc/nftables.conf、
#      不 chattr +i 锁 resolv.conf、不擅自关 apt 自动升级（改为可选）。
#   5. 兼容原版：路由表名/ID、fwmark、systemd 服务名、状态旗标文件保持一致，
#      原版菜单的「取消」仍可清理本版的配置，反之亦然。
#
# 用法示例（在香港节点以 root 运行）：
#   ./ix-onekey.sh --sbmode                            # 对端 IP 自动识别，密码运行时输入（不回显）
#   ./ix-onekey.sh --qh-ip 192.168.80.20 --ssh-key /root/.ssh/id_ed25519
#   ./ix-onekey.sh --config /root/kkix.env --dry-run     # 只探测+打印计划
#   ./ix-onekey.sh --config /root/kkix.env --status      # 查看两端状态
#   ./ix-onekey.sh --config /root/kkix.env --rollback    # 按快照回滚两端
# =============================================================================
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

SCRIPT_VERSION="3.1.0-onekey"
STATE_DIR="/root/.kkix_state"
CONFIG_FILE_DEFAULT="/root/.kkix_config"
BACKUP_DIR=""                       # apply 时生成: $STATE_DIR/backup-<ts>
LOG_FILE=""                         # apply 时生成: $STATE_DIR/sbmode-<ts>.log

ROUTE_TABLE_ID=100  ROUTE_TABLE_NAME="ix_return"
INTERNAL_TABLE_ID=101 INTERNAL_TABLE_NAME="internal_out"
ROUTE_MARK=100
MICROSOCKS_PORT=1080                # 仅为兼容保留，本脚本不涉及代理模式

# ----------------------------- 可配置参数 -----------------------------------
# 命令行 > 环境变量 KKIX_* > 配置文件 > 自动探测/默认值
QH_IP="${KKIX_QH_IP:-}"             # 前海端局域网 IP（SSH 目标兼内网地址）
HK_LAN_IP="${KKIX_HK_LAN_IP:-}"     # 香港端内网 IP（前海端的内网网关）
SSH_USER="${KKIX_SSH_USER:-root}"
SSH_PORT="${KKIX_SSH_PORT:-22}"
SSH_KEY="${KKIX_SSH_KEY:-}"         # 私钥路径；为空且无密码时用 ssh 默认密钥/agent
SSH_PASS_ENV="${KKIX_SSH_PASS_ENV:-KKIX_SSH_PASS}"  # 存放密码的「环境变量名」
HK_EXT_IF="${KKIX_HK_EXT_IF:-}"  HK_INT_IF="${KKIX_HK_INT_IF:-}"
QH_EXT_IF="${KKIX_QH_EXT_IF:-}"  QH_INT_IF="${KKIX_QH_INT_IF:-}"
CONFIG_FILE="${KKIX_CONFIG:-}"
DEADMAN_SECONDS="${KKIX_DEADMAN_SECONDS:-180}"
MODE="apply"                        # apply | dry-run | status | rollback
KEEP_DEFAULT_ROUTE=0                # 1=不切前海默认路由（只配策略路由）
CHANGE_DNS=0                        # 1=才给 DNS 加 /32 路由（仍不锁 resolv.conf）
DISABLE_AUTO_UPGRADE=0              # 1=才禁用前海端 apt 自动升级（原版默认偷偷关）
ALLOW_SINGLE_NIC=0                  # 1=允许内/外网共用一块网卡
ASSUME_YES=0                        # 兼容参数：本脚本本就无需确认

# ----------------------------- 运行时状态 -----------------------------------
SSH_BASE=()                         # 含目标地址的 ssh 命令前缀
REMOTE_SUDO=""                      # "sudo -n" 或 ""
HK_EXT_IP="" HK_EXT_CIDR="" HK_INT_IP="" HK_INT_CIDR="" HK_INT_NET="" HK_EXT_GW=""
QH_EXT_IP="" QH_EXT_CIDR="" QH_INT_IP="" QH_INT_CIDR="" QH_INT_NET="" QH_EXT_GW=""
QH_RGET="" QH_SNAP_ROUTE="" QH_RGET_SRC=""
QH_IS_DEBIAN=0 QH_HAS_NFT=0 QH_DEFAULT_ROUTE=""

log()  { printf '%s [%s] %s\n' "$(date -Iseconds)" "$1" "$2"; }
info() { log INFO "$*"; [[ -n "$LOG_FILE" ]] && log INFO "$*" >>"$LOG_FILE" || true; }
warn() { log WARN "$*" >&2; }
err()  { log ERROR "$*" >&2; }
die()  { local _msg="$1" _code="${2:-1}"; err "$_msg"; exit "$_code"; }   # die "msg" [exitcode]

usage() {
  cat <<'EOF'
用法: ix-onekey.sh --sbmode [选项]        # 在香港节点 root 下运行

连接参数（IP 自动识别，密码运行时在终端输入）:
  --qh-ip IP            前海端局域网 IP（可省略：先读 /root/.kkix_config，再自动扫描内网识别）
  --hk-lan-ip IP        香港端内网 IP（默认: 自动探测内网网卡地址）
  --ssh-user USER       前海端 SSH 用户（默认 root）
  --ssh-port PORT       前海端 SSH 端口（默认 22）
  --ssh-key FILE        私钥文件（推荐）
  --ssh-pass-env NAME   存放 SSH 密码的环境变量名（默认 KKIX_SSH_PASS，仅自动化场景用）
                        未提供密钥/密码时，运行时会在终端提示输入前海端密码：
                        不回显、只输一次、全程复用、不落盘

接口参数（默认按「公网IP=外网口 / 私网IP=内网口」自动探测，可显式指定）:
  --hk-ext-if IF --hk-int-if IF --qh-ext-if IF --qh-int-if IF
  --allow-single-nic    允许内/外网同网卡（单网卡机器）

行为选项:
  --config FILE         key=value 配置文件（白名单解析，不 source 执行）
  --dry-run             只做只读探测并打印计划，不做任何修改
  --status              只读查看两端当前状态
  --rollback            按最近快照回滚两端到 apply 之前
  --keep-default-route  只配策略路由，不切前海端默认路由
  --change-dns          额外为 8.8.8.8/1.1.1.1 添加经香港的 /32 路由
  --disable-auto-upgrade 禁用前海端 apt 自动升级（原版 sbmode 的默认行为）
  --deadman-seconds N   切默认路由后的失联自救等待秒数（默认 180）
  --help                显示本帮助

退出码: 0 成功 | 2 参数错误 | 3 体检未通过（未做任何修改）
        4 香港端配置失败 | 5 前海端配置失败 | 6 验证未通过（死人开关已武装）
EOF
}

# ----------------------------- 参数与配置 -----------------------------------
load_config_file() {
  local file="$1" line key val
  [[ -f "$file" ]] || die "配置文件不存在: $file" 2
  # 白名单解析，绝不 source —— 原版 source /root/.kkix_config 等于把文件当代码跑
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    case "$key" in
      QH_IP|QIANHAI_LAN_IP) [[ -z "$QH_IP" ]] && QH_IP="$val" ;;
      HK_LAN_IP)    [[ -z "$HK_LAN_IP" ]]    && HK_LAN_IP="$val" ;;
      SSH_USER|REMOTE_USER) SSH_USER="$val" ;;
      SSH_PORT|REMOTE_PORT) SSH_PORT="$val" ;;
      SSH_KEY)      [[ -z "$SSH_KEY" ]]      && SSH_KEY="$val" ;;
      HK_EXT_IF)    [[ -z "$HK_EXT_IF" ]]    && HK_EXT_IF="$val" ;;
      HK_INT_IF)    [[ -z "$HK_INT_IF" ]]    && HK_INT_IF="$val" ;;
      QH_EXT_IF)    [[ -z "$QH_EXT_IF" ]]    && QH_EXT_IF="$val" ;;
      QH_INT_IF)    [[ -z "$QH_INT_IF" ]]    && QH_INT_IF="$val" ;;
      DEADMAN_SECONDS) DEADMAN_SECONDS="$val" ;;
      *) : ;;  # 未知键忽略
    esac
  done < "$file"
}

parse_args() {
  while (($#)); do
    case "$1" in
      --sbmode)              : ;;  # 兼容原版入口：本脚本只有路由模式一键路径
      --qh-ip)               QH_IP="${2:?--qh-ip 需要参数}"; shift ;;
      --hk-lan-ip)           HK_LAN_IP="${2:?--hk-lan-ip 需要参数}"; shift ;;
      --ssh-user)            SSH_USER="${2:?}"; shift ;;
      --ssh-port)            SSH_PORT="${2:?}"; shift ;;
      --ssh-key)             SSH_KEY="${2:?}"; shift ;;
      --ssh-pass-env)        SSH_PASS_ENV="${2:?}"; shift ;;
      --hk-ext-if)           HK_EXT_IF="${2:?}"; shift ;;
      --hk-int-if)           HK_INT_IF="${2:?}"; shift ;;
      --qh-ext-if)           QH_EXT_IF="${2:?}"; shift ;;
      --qh-int-if)           QH_INT_IF="${2:?}"; shift ;;
      --config)              CONFIG_FILE="${2:?}"; shift ;;
      --deadman-seconds)     DEADMAN_SECONDS="${2:?}"; shift ;;
      --dry-run)             MODE="dry-run" ;;
      --status)              MODE="status" ;;
      --rollback)            MODE="rollback" ;;
      --keep-default-route)  KEEP_DEFAULT_ROUTE=1 ;;
      --change-dns)          CHANGE_DNS=1 ;;
      --disable-auto-upgrade) DISABLE_AUTO_UPGRADE=1 ;;
      --allow-single-nic)    ALLOW_SINGLE_NIC=1 ;;
      -y|--yes)              ASSUME_YES=1 ;;
      -h|--help)             usage; exit 0 ;;
      *) err "未知参数: $1"; usage >&2; exit 2 ;;
    esac
    shift
  done
}

# ----------------------------- 基础校验 -------------------------------------
is_ipv4() {
  local ip="$1" a b c d
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for a in "${BASH_REMATCH[@]:1:4}"; do (( a <= 255 )) || return 1; done
  return 0
}
is_private_ipv4() { [[ "$1" =~ ^10\. ]] || [[ "$1" =~ ^192\.168\. ]] || [[ "$1" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; }

# ip_in_cidr IP CIDR —— 有 python3 用标准库，否则纯 bash 位运算
ip_in_cidr() {
  local ip="$1" cidr="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$ip" "$cidr" <<'PY' >/dev/null 2>&1
import ipaddress, sys
sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2], strict=False) else 1)
PY
    return $?
  fi
  local net="${cidr%/*}" bits="${cidr#*/}" i1 i2 i3 i4 n1 n2 n3 n4 mask
  IFS=. read -r i1 i2 i3 i4 <<<"$ip"; IFS=. read -r n1 n2 n3 n4 <<<"$net"
  (( bits == 32 )) && mask=4294967295 || mask=$(( (4294967295 << (32-bits)) & 4294967295 ))
  local x=$(( (i1<<24)|(i2<<16)|(i3<<8)|i4 )) y=$(( (n1<<24)|(n2<<16)|(n3<<8)|n4 ))
  (( (x & mask) == (y & mask) ))
}
cidr_network() {  # CIDR -> 网络地址/前缀（打印 a.b.c.d/bits）
  local cidr="$1" ip="${1%/*}" bits="${1#*/}" a b c d mask
  IFS=. read -r a b c d <<<"$ip"
  (( bits == 32 )) && mask=4294967295 || mask=$(( (4294967295 << (32-bits)) & 4294967295 ))
  local x=$(( (a<<24)|(b<<16)|(c<<8)|d )); x=$(( x & mask ))
  printf '%d.%d.%d.%d/%s\n' $((x>>24&255)) $((x>>16&255)) $((x>>8&255)) $((x&255)) "$bits"
}

require_root() { [[ $(id -u) -eq 0 ]] || die "请以 root 身份执行" 3; }

require_local_cmds() {
  local missing=() c
  for c in ip ping curl ssh; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if [[ -z "$SSH_KEY" ]] && ! command -v sshpass >/dev/null 2>&1; then missing+=("sshpass"); fi
  ((${#missing[@]}==0)) && return 0
  if command -v apt-get >/dev/null 2>&1 && [[ "$MODE" == "apply" ]]; then
    info "自动安装缺失命令: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq iproute2 iputils-ping curl openssh-client sshpass >/dev/null 2>&1 \
      || die "依赖安装失败，请手动安装: ${missing[*]}" 3
  else
    die "缺少命令: ${missing[*]}（dry-run/status 不自动安装）" 3
  fi
}

# ----------------------------- 本机（香港端）探测 -----------------------------
# 接口事实以全局关联数组保存: LIF_IP4[if]=a.b.c.d/prefix
declare -A LIF_IP4=() LIF_IP6=()
local_probe() {
  local line ifname cidr
  while IFS= read -r line; do
    ifname=$(awk '{print $2}' <<<"$line"); cidr=$(awk '{print $4}' <<<"$line")
    [[ -z "${LIF_IP4[$ifname]:-}" ]] && LIF_IP4[$ifname]="$cidr"
  done < <(ip -o -4 addr show 2>/dev/null)
  while IFS= read -r line; do
    ifname=$(awk '{print $2}' <<<"$line"); cidr=$(awk '{print $4}' <<<"$line")
    [[ -z "${LIF_IP6[$ifname]:-}" ]] && LIF_IP6[$ifname]="$cidr"
  done < <(ip -o -6 addr show scope global 2>/dev/null)
}
local_ifaces() { ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -v '^lo$'; }
default_gw_for() { ip route show default dev "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' | head -n1; }

pick_local_ifaces() {
  # 用户指定优先；否则：带公网 IPv4 的口=外网口，带 192.168.80/私网的口=内网口
  local ifname cidr ip best_int="" best_pri=-1 pri
  for ifname in $(local_ifaces); do
    cidr="${LIF_IP4[$ifname]:-}"; [[ -n "$cidr" ]] || continue
    ip="${cidr%/*}"
    if [[ -z "$HK_EXT_IF" ]] && is_ipv4 "$ip" && ! is_private_ipv4 "$ip"; then HK_EXT_IF="$ifname"; fi
    if is_private_ipv4 "$ip"; then
      pri=0; [[ "$ip" =~ ^192\.168\.80\. ]] && pri=4; [[ "$ip" =~ ^192\.168\. ]] && pri=3
      [[ "$ip" =~ ^10\. ]] && pri=2; [[ "$ip" =~ ^172\. ]] && pri=1
      (( pri > best_pri )) && { best_pri=$pri; best_int="$ifname"; }
    fi
  done
  [[ -z "$HK_EXT_IF" ]] && HK_EXT_IF=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  [[ -z "$HK_INT_IF" ]] && HK_INT_IF="$best_int"
  if [[ -z "$HK_INT_IF" || "$HK_INT_IF" == "$HK_EXT_IF" ]]; then
    for ifname in $(local_ifaces); do
      [[ "$ifname" != "$HK_EXT_IF" && -n "${LIF_IP4[$ifname]:-}" ]] && { HK_INT_IF="$ifname"; break; }
    done
  fi
  [[ -z "$HK_INT_IF" ]] && HK_INT_IF="$HK_EXT_IF"
}

# ----------------------------- SSH（前海端） ---------------------------------
SSH_PASS_SET=""
RUNTIME_SSH_PASS=""
# 交互输入密码：从 /dev/tty 读（curl 管道执行时 stdin 不是终端也能问），不回显、不落盘
prompt_ssh_password() {
  [[ -r /dev/tty ]] && ( : >/dev/tty ) 2>/dev/null || return 1
  local pw=""
  printf '请输入前海端 %s@%s 的登录密码（输入不回显）: ' "$SSH_USER" "$QH_IP" > /dev/tty
  IFS= read -r -s pw < /dev/tty || return 1
  printf '\n' > /dev/tty
  [[ -n "$pw" ]] || return 1
  RUNTIME_SSH_PASS="$pw"
  return 0
}
setup_ssh() {
  [[ -n "${!SSH_PASS_ENV:-}" ]] && SSH_PASS_SET=1
  local -a opts=(-o StrictHostKeyChecking=accept-new
                 -o UserKnownHostsFile="$STATE_DIR/known_hosts"
                 -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3
                 -o LogLevel=ERROR -p "$SSH_PORT")
  # accept-new 取代原版 StrictHostKeyChecking=no：首次记录、变更报警，不再裸奔
  mkdir -p "$STATE_DIR"
  if [[ -n "$SSH_KEY" ]]; then
    [[ -f "$SSH_KEY" ]] || die "私钥文件不存在: $SSH_KEY" 3
    SSH_BASE=(ssh "${opts[@]}" -o BatchMode=yes -o PubkeyAuthentication=yes
              -o PasswordAuthentication=no -i "$SSH_KEY" "${SSH_USER}@${QH_IP}")
  elif [[ -n "$SSH_PASS_SET" ]]; then
    command -v sshpass >/dev/null 2>&1 || die "密码认证需要 sshpass" 3
    # sshpass -e 从环境变量读密码：不落盘、不进 argv（原版写 /tmp 明文文件）
    SSH_BASE=(sshpass -e ssh "${opts[@]}" -o BatchMode=no -o PubkeyAuthentication=no
              -o PreferredAuthentications=password "${SSH_USER}@${QH_IP}")
    export SSHPASS="${!SSH_PASS_ENV}"
  elif prompt_ssh_password; then
    command -v sshpass >/dev/null 2>&1 || die "密码认证需要 sshpass" 3
    SSH_BASE=(sshpass -e ssh "${opts[@]}" -o BatchMode=no -o PubkeyAuthentication=no
              -o PreferredAuthentications=password "${SSH_USER}@${QH_IP}")
    export SSHPASS="$RUNTIME_SSH_PASS"
  else
    # 默认密钥/agent：BatchMode 保证不会卡在密码提示上
    SSH_BASE=(ssh "${opts[@]}" -o BatchMode=yes "${SSH_USER}@${QH_IP}")
  fi
}
remote_exec() { "${SSH_BASE[@]}" "$*"; }
remote_sudo_str() { [[ "$SSH_USER" == "root" ]] && echo "" || echo "sudo -n"; }

# 一次 SSH 批量探测前海端（原版 ensure_qh_route_info 对每块网卡逐个 ssh，十几次往返）
declare -A RIF_IP4=() RIF_IP6=()
remote_probe() {
  local out line k v probe_script
  probe_script=$(cat <<'PROBE'
set +e
echo "DEBIAN=$(test -f /etc/debian_version && echo 1 || echo 0)"
echo "NFT=$(command -v nft >/dev/null 2>&1 && echo 1 || echo 0)"
echo "SUDO_NOPASS=$(if [ "$(id -u)" = 0 ]; then echo 1; elif sudo -n true 2>/dev/null; then echo 1; else echo 0; fi)"
echo "DEFAULT4=$(ip route show default | head -n1)"
echo "RGET=$(ip route get "$1" 2>/dev/null | head -n1)"
snap=$(cat /root/.true_original_default_route 2>/dev/null | head -n1)
[ -z "$snap" ] && snap=$(cat ~/.true_original_default_route 2>/dev/null | head -n1)
echo "SNAP=$snap"
ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -v '^lo$' | while read -r i; do
  echo "IF4.$i=$(ip -o -4 addr show "$i" 2>/dev/null | awk '{print $4}' | head -n1)"
  echo "IF6.$i=$(ip -o -6 addr show "$i" scope global 2>/dev/null | awk '{print $4}' | head -n1)"
done
PROBE
)
  out=$(printf '%s' "$probe_script" | remote_exec 'bash -s' "$HK_LAN_IP" 2>/dev/null) || return 1
  while IFS='=' read -r k v; do
    case "$k" in
      DEBIAN) QH_IS_DEBIAN="$v" ;;
      NFT)    QH_HAS_NFT="$v" ;;
      SUDO_NOPASS) [[ "$v" == "1" ]] || die "前海端 $SSH_USER 无免密 sudo，非交互模式无法继续（请用 root 或配置 NOPASSWD）" 3 ;;
      DEFAULT4) QH_DEFAULT_ROUTE="$v" ;;
      RGET)   QH_RGET="$v" ;;
      SNAP)   QH_SNAP_ROUTE="$v" ;;
      IF4.*)  RIF_IP4["${k#IF4.}"]="$v" ;;
      IF6.*)  RIF_IP6["${k#IF6.}"]="$v" ;;
      *) : ;;
    esac
  done <<<"$out"
  QH_EXT_GW=""   # 网关在 pick 阶段按选定的外网口单独精确查询
}

pick_remote_ifaces_and_gw() {
  local ifname cidr ip best_int="" best_pri=-1 pri
  local user_qh_int="$QH_INT_IF" user_qh_ext="$QH_EXT_IF"
  for ifname in "${!RIF_IP4[@]}"; do
    cidr="${RIF_IP4[$ifname]}"; [[ -n "$cidr" ]] || continue
    ip="${cidr%/*}"
    if [[ -z "$QH_EXT_IF" ]] && ! is_private_ipv4 "$ip"; then QH_EXT_IF="$ifname"; fi
    if is_private_ipv4 "$ip"; then
      pri=0; [[ "$ip" =~ ^192\.168\.80\. ]] && pri=4; [[ "$ip" =~ ^192\.168\. ]] && pri=3
      [[ "$ip" =~ ^10\. ]] && pri=2; [[ "$ip" =~ ^172\. ]] && pri=1
      (( pri > best_pri )) && { best_pri=$pri; best_int="$ifname"; }
    fi
    # 内网口的最可靠判据：QIANHAI_LAN_IP 就绑在这块口上
    [[ "$ip" == "$QH_IP" ]] && best_int="$ifname" && best_pri=99
  done
  [[ -z "$QH_INT_IF" ]] && QH_INT_IF="$best_int"
  # v3: 用户未显式指定内网口时，以对端「实际去香港的路由」(route get) 为准
  if [[ -z "$user_qh_int" && -n "$QH_RGET" ]]; then
    local rdev rsrc
    rdev=$(awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' <<<"$QH_RGET")
    rsrc=$(awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' <<<"$QH_RGET")
    if [[ -n "$rdev" && -n "${RIF_IP4[$rdev]:-}" ]]; then QH_INT_IF="$rdev"; QH_RGET_SRC="$rsrc"; fi
  fi
  [[ -z "$QH_EXT_IF" ]] && QH_EXT_IF=$(awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' <<<"$QH_DEFAULT_ROUTE" | head -n1)
  # 外网口若被默认路由现状误导（重跑场景默认已走内网），用原始快照的 dev 纠正
  if [[ -n "$QH_SNAP_ROUTE" ]]; then
    local snapdev; snapdev=$(awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' <<<"$QH_SNAP_ROUTE")
    if [[ -n "$snapdev" && "$QH_EXT_IF" == "$QH_INT_IF" && "$snapdev" != "$QH_INT_IF" ]]; then QH_EXT_IF="$snapdev"; fi
  fi
  if [[ -z "$QH_INT_IF" || "$QH_INT_IF" == "$QH_EXT_IF" ]]; then
    for ifname in "${!RIF_IP4[@]}"; do
      [[ "$ifname" != "$QH_EXT_IF" && -n "${RIF_IP4[$ifname]}" ]] && { QH_INT_IF="$ifname"; break; }
    done
  fi
  [[ -z "$QH_INT_IF" ]] && QH_INT_IF="$QH_EXT_IF"
  QH_EXT_CIDR="${RIF_IP4[$QH_EXT_IF]:-}"; QH_EXT_IP="${QH_EXT_CIDR%/*}"
  QH_INT_CIDR="${RIF_IP4[$QH_INT_IF]:-}"; QH_INT_IP="${QH_INT_CIDR%/*}"
  [[ -n "$QH_EXT_CIDR" ]] && QH_INT_NET=$(cidr_network "$QH_INT_CIDR")
  QH_EXT_GW=$(remote_exec "ip route show default dev $QH_EXT_IF 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(\$i==\"via\") print \$(i+1)}' | head -n1")
  # v3: 现状取不到网关时，只允许用对端保存的原始路由快照（真实值），绝不猜 x.x.x.1
  if [[ -z "$QH_EXT_GW" && -n "$QH_SNAP_ROUTE" ]]; then
    QH_EXT_GW=$(awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' <<<"$QH_SNAP_ROUTE")
    [[ -n "$QH_EXT_GW" ]] && info "前海端外网网关取自其原始路由快照: $QH_EXT_GW"
  fi
}

# ----------------------------- Preflight ------------------------------------
# ----------------------------- 前海 IP 自动识别 ------------------------------
_ip2int() { local IFS=. a b c d; read -r a b c d <<<"$1"; echo $(( (a<<24) + (b<<16) + (c<<8) + d )); }
_int2ip() { local n="$1"; printf '%d.%d.%d.%d\n' $(( (n>>24)&255 )) $(( (n>>16)&255 )) $(( (n>>8)&255 )) $(( n&255 )); }
# 探一个 IP 的 SSH 端口并核对 banner（SSH-* 才算），命中写进结果文件；供 xargs 并行调用
_ssh_banner_probe() {
  local banner=""
  banner=$(timeout 3 bash -c 'exec 3<>/dev/tcp/$1/$2 2>/dev/null; IFS= read -r -t 2 line <&3; printf %s "$line"' _ "$1" "$2" 2>/dev/null) || banner=""
  [[ "$banner" == SSH-* ]] && printf '%s\n' "$1" >> "$3"
  return 0
}
export -f _ssh_banner_probe
# 候选 = 内网段里开放 SSH 且 banner 正确的主机（已知邻居与全段扫描合并去重，排除本机）
discover_qh_candidates() {
  local tmp; tmp=$(mktemp)
  local -a hosts=() uniq=()
  local -A seen=() own=()
  local ip cidr bits ip_int mask net_int count i
  while read -r ip; do is_ipv4 "$ip" && hosts+=("$ip"); done < <(ip neigh show dev "$HK_INT_IF" 2>/dev/null | awk '{print $1}')
  cidr="$HK_INT_CIDR"; bits="${cidr##*/}"
  ip_int=$(_ip2int "${cidr%/*}")
  mask=$(( bits==0 ? 0 : (4294967295 << (32-bits)) & 4294967295 ))
  net_int=$(( ip_int & mask ))
  count=$(( 1 << (32-bits) ))
  if (( count > 2050 )); then warn "内网段 $cidr 主机数过大，扫描只覆盖前 2048 台"; count=2050; fi
  for (( i=1; i<count-1; i++ )); do hosts+=("$(_int2ip $(( net_int + i )) )"); done
  for ip in "${LIF_IP4[@]}"; do own["${ip%/*}"]=1; done
  for ip in "${hosts[@]}"; do [[ -n "${own[$ip]:-}" || -n "${seen[$ip]:-}" ]] && continue; seen[$ip]=1; uniq+=("$ip"); done
  if ((${#uniq[@]})); then
    printf '%s\n' "${uniq[@]}" | xargs -P 48 -I{} bash -c '_ssh_banner_probe "$@"' _ {} "$SSH_PORT" "$tmp" || true
  fi
  sort -u "$tmp" 2>/dev/null
  rm -f "$tmp"
}
resolve_qh_ip() {
  [[ -n "$QH_IP" ]] && return 0
  info "未提供前海 IP，自动识别中（扫描内网段 $HK_INT_NET 找 SSH 服务）..."
  local -a cands=()
  mapfile -t cands < <(discover_qh_candidates)
  if (( ${#cands[@]} == 1 )); then
    QH_IP="${cands[0]}"; info "自动识别到前海端: $QH_IP"; return 0
  fi
  if (( ${#cands[@]} > 1 )); then
    if [[ -r /dev/tty ]] && ( : >/dev/tty ) 2>/dev/null; then
      local i sel=""
      { echo "内网段里找到多台开 SSH 的主机，请选择前海端："
        for i in "${!cands[@]}"; do echo "  $((i+1))) ${cands[$i]}"; done; } > /dev/tty
      printf '输入序号: ' > /dev/tty
      IFS= read -r sel < /dev/tty || sel=""
      if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel>=1 && sel<=${#cands[@]} )); then
        QH_IP="${cands[$((sel-1))]}"; info "已选择前海端: $QH_IP"; return 0
      fi
      die "序号无效: $sel" 2
    fi
    die "自动识别到多台 SSH 主机（${cands[*]}），非交互环境无法选择，请用 --qh-ip 指定" 3
  fi
  if [[ -r /dev/tty ]] && ( : >/dev/tty ) 2>/dev/null; then
    local typed=""
    printf '未自动识别到前海端，请输入前海端局域网 IP: ' > /dev/tty
    IFS= read -r typed < /dev/tty || typed=""
    if is_ipv4 "$typed"; then QH_IP="$typed"; return 0; fi
    die "输入的 IP 不合法: $typed" 2
  fi
  die "自动识别失败：在 $HK_INT_NET 未找到开放 SSH 的主机；请确认前海端已开机且与香港在同一云联网，或用 --qh-ip 指定" 3
}

preflight() {
  require_root
  [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT>=1 && SSH_PORT<=65535 )) || die "SSH 端口非法: $SSH_PORT" 3
  [[ "$DEADMAN_SECONDS" =~ ^[0-9]+$ ]] && (( DEADMAN_SECONDS>=30 )) || die "--deadman-seconds 至少 30" 2

  require_local_cmds

  info "探测香港端网络..."
  local_probe; pick_local_ifaces
  [[ -n "$HK_EXT_IF" && -n "${LIF_IP4[$HK_EXT_IF]:-}" ]] || die "香港端外网口无法确定/无 IPv4（--hk-ext-if 显式指定）" 3
  [[ -n "$HK_INT_IF" && -n "${LIF_IP4[$HK_INT_IF]:-}" ]] || die "香港端内网口无法确定/无 IPv4（--hk-int-if 显式指定）" 3
  HK_EXT_CIDR="${LIF_IP4[$HK_EXT_IF]}"; HK_EXT_IP="${HK_EXT_CIDR%/*}"
  HK_INT_CIDR="${LIF_IP4[$HK_INT_IF]}"; HK_INT_IP="${HK_INT_CIDR%/*}"
  HK_INT_NET=$(cidr_network "$HK_INT_CIDR")
  resolve_qh_ip
  is_ipv4 "$QH_IP" || die "前海端 IP 不是合法 IPv4: $QH_IP" 3
  setup_ssh
  # v3: 内网口以「实际去对端的路由」为准（route get 的 dev/src），启发式选错时纠正
  local rget rdev rsrc
  rget=$(ip route get "$QH_IP" 2>/dev/null | head -n1)
  rdev=$(awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' <<<"$rget")
  rsrc=$(awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' <<<"$rget")
  if [[ -n "$rdev" && -n "${LIF_IP4[$rdev]:-}" ]] && ! ip_in_cidr "$QH_IP" "$HK_INT_NET"; then
    info "内网口纠正: $HK_INT_IF -> $rdev（按 route get 到对端的实际路径）"
    HK_INT_IF="$rdev"; HK_INT_CIDR="${LIF_IP4[$rdev]}"; HK_INT_IP="${HK_INT_CIDR%/*}"; HK_INT_NET=$(cidr_network "$HK_INT_CIDR")
  fi
  [[ -z "$HK_LAN_IP" && -n "$rsrc" ]] && HK_LAN_IP="$rsrc"
  [[ -z "$HK_LAN_IP" ]] && HK_LAN_IP="$HK_INT_IP"
  [[ "$HK_LAN_IP" == "$HK_INT_IP" ]] || die "HK_LAN_IP($HK_LAN_IP) 不是香港端内网口 $HK_INT_IF 的地址($HK_INT_IP)" 3
  HK_EXT_GW=$(default_gw_for "$HK_EXT_IF")
  if [[ "$HK_EXT_IF" == "$HK_INT_IF" ]] && (( ! ALLOW_SINGLE_NIC )); then
    die "香港端内/外网为同一网卡 $HK_EXT_IF，确认无误请加 --allow-single-nic" 3
  fi
  ip_in_cidr "$QH_IP" "$HK_INT_NET" || die "前海 IP $QH_IP 不在香港内网段 $HK_INT_NET 内，两端可能不在同一云联网" 3
  is_private_ipv4 "$HK_EXT_IP" && warn "香港外网口 IP $HK_EXT_IP 是私网地址（运营商 NAT？），SNAT 后出口以实际公网为准"
  ping -c 2 -W 2 "$QH_IP" >/dev/null 2>&1 || die "香港端 ping 不通前海 $QH_IP，先检查云联网连通性" 3

  info "探测前海端（单次 SSH 批量探测）..."
  remote_probe || die "SSH 连接前海端 ${SSH_USER}@${QH_IP}:${SSH_PORT} 失败：检查地址/端口，或密码是否输对" 3
  pick_remote_ifaces_and_gw
  [[ -n "$QH_EXT_IP" ]] || die "前海端外网口无法确定/无 IPv4（--qh-ext-if 显式指定）" 3
  [[ -n "$QH_INT_IP" ]] || die "前海端内网口无法确定/无 IPv4（--qh-int-if 显式指定）" 3
  if [[ "$QH_EXT_IF" == "$QH_INT_IF" ]] && (( ! ALLOW_SINGLE_NIC )); then
    die "前海端内/外网为同一网卡 $QH_EXT_IF，确认无误请加 --allow-single-nic" 3
  fi
  [[ "$QH_INT_IP" == "$QH_IP" ]] || warn "前海内网口地址 $QH_INT_IP 与 SSH 目标 $QH_IP 不一致，请确认 --qh-int-if 是否选对"
  if (( ! KEEP_DEFAULT_ROUTE )); then
    # 原版网关取不到就猜 x.x.x.1 —— 本版宁可停也不猜
    [[ -n "$QH_EXT_GW" ]] || die "取不到前海端外网默认网关（回滚锚点），拒绝切默认路由；可改用 --keep-default-route" 3
    [[ -n "$QH_DEFAULT_ROUTE" ]] || die "取不到前海端当前默认路由（回滚锚点），拒绝继续" 3
  fi

  cat <<EOF

================ 最终计划（路由模式 / sbmode 优化版 $SCRIPT_VERSION）================
香港端: 外网 $HK_EXT_IF ($HK_EXT_CIDR)  内网 $HK_INT_IF ($HK_INT_CIDR)
        SNAT: $HK_INT_NET 经 $HK_EXT_IF 出，源地址改写为 $HK_EXT_IP
        仅放行前海 $QH_IP 的转发；ip_forward=1（写 sysctl.d，可逆）
前海端: 外网 $QH_EXT_IF ($QH_EXT_CIDR gw ${QH_EXT_GW:-无})
        内网 $QH_INT_IF ($QH_INT_CIDR)  内网网关(香港) $HK_LAN_IP
        策略路由: 表 $ROUTE_TABLE_ID/$ROUTE_TABLE_NAME + $INTERNAL_TABLE_ID/$INTERNAL_TABLE_NAME, fwmark $ROUTE_MARK
        默认路由: $( ((KEEP_DEFAULT_ROUTE)) && echo "保持不变" || echo "切到 via $HK_LAN_IP dev $QH_INT_IF（先武装 ${DEADMAN_SECONDS}s 死人开关，验证通过才解除）")
        DNS 改动: $( ((CHANGE_DNS)) && echo "加 8.8.8.8/1.1.1.1 的 /32 路由（不改 resolv.conf）" || echo "无")
        apt 自动升级: $( ((DISABLE_AUTO_UPGRADE)) && echo "禁用并记录原状态" || echo "不动（与原版 sbmode 不同）")
================================================================================
EOF
}

# ----------------------------- 快照 -----------------------------------------
snapshot_local() {
  BACKUP_DIR="$STATE_DIR/backup-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$BACKUP_DIR" "$STATE_DIR"
  LOG_FILE="$STATE_DIR/sbmode-$(date +%Y%m%d%H%M%S).log"
  {
    echo "# local snapshot $(date -Iseconds)"
    ip rule show; ip route show table all; ip route show default
    command -v nft >/dev/null && nft list ruleset 2>/dev/null || true
  } > "$BACKUP_DIR/local-before.txt" 2>&1 || true
  cat /proc/sys/net/ipv4/ip_forward > "$BACKUP_DIR/ip_forward.before" 2>/dev/null || true
  echo "$BACKUP_DIR" > "$STATE_DIR/latest_backup"
  info "本机快照: $BACKUP_DIR（回滚锚点）"
}

# ----------------------------- 香港端 apply ---------------------------------
apply_hk() {
  info "配置香港端 SNAT（nft 优先）..."
  mkdir -p /etc/sysctl.d
  printf '# kkix route mode\nnet.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-kkix-route.conf
  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  if command -v nft >/dev/null 2>&1; then
    nft delete table ip hk_snat >/dev/null 2>&1 || true
    nft add table ip hk_snat
    nft 'add chain ip hk_snat forward { type filter hook forward priority 0; policy drop; }'
    nft 'add chain ip hk_snat postrouting { type nat hook postrouting priority 100; }'
    nft 'add rule ip hk_snat forward ct state established,related accept'
    nft "add rule ip hk_snat forward ip saddr $QH_IP iifname $HK_INT_IF oifname $HK_EXT_IF accept"
    nft "add rule ip hk_snat postrouting ip saddr $HK_INT_NET oifname $HK_EXT_IF snat to $HK_EXT_IP"
    # 注意：不再把 `nft list ruleset` 整表写进 /etc/nftables.conf（会冲掉别人的表）
    # 持久化只靠下面的 restore 服务，职责单一、可审计。
  else
    # iptables 回退：只插自己的规则，绝不改全局 FORWARD 默认策略（原版会 -P DROP）
    iptables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
      iptables -I FORWARD 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -C FORWARD -s "$QH_IP" -i "$HK_INT_IF" -o "$HK_EXT_IF" -j ACCEPT 2>/dev/null || \
      iptables -I FORWARD 2 -s "$QH_IP" -i "$HK_INT_IF" -o "$HK_EXT_IF" -j ACCEPT
    iptables -t nat -C POSTROUTING -s "$HK_INT_NET" -o "$HK_EXT_IF" -j SNAT --to-source "$HK_EXT_IP" 2>/dev/null || \
      iptables -t nat -A POSTROUTING -s "$HK_INT_NET" -o "$HK_EXT_IF" -j SNAT --to-source "$HK_EXT_IP"
    if command -v netfilter-persistent >/dev/null 2>&1; then netfilter-persistent save >/dev/null 2>&1 || true
    else mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4 || true; fi
  fi

  # 开机恢复脚本（值在生成时定格，逻辑与本次 apply 完全一致）
  cat > /usr/local/bin/restore-hk-snat.sh <<EOF
#!/bin/bash
# 由 ix-onekey.sh $SCRIPT_VERSION 生成：恢复香港端 SNAT
for i in \$(seq 1 30); do ip link show $HK_INT_IF >/dev/null 2>&1 && ip link show $HK_EXT_IF >/dev/null 2>&1 && break; sleep 1; done
echo 1 > /proc/sys/net/ipv4/ip_forward
if command -v nft >/dev/null 2>&1; then
  nft delete table ip hk_snat >/dev/null 2>&1 || true
  nft add table ip hk_snat
  nft 'add chain ip hk_snat forward { type filter hook forward priority 0; policy drop; }'
  nft 'add chain ip hk_snat postrouting { type nat hook postrouting priority 100; }'
  nft 'add rule ip hk_snat forward ct state established,related accept'
  nft 'add rule ip hk_snat forward ip saddr $QH_IP iifname $HK_INT_IF oifname $HK_EXT_IF accept'
  nft 'add rule ip hk_snat postrouting ip saddr $HK_INT_NET oifname $HK_EXT_IF snat to $HK_EXT_IP'
else
  iptables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -C FORWARD -s $QH_IP -i $HK_INT_IF -o $HK_EXT_IF -j ACCEPT 2>/dev/null || iptables -I FORWARD 2 -s $QH_IP -i $HK_INT_IF -o $HK_EXT_IF -j ACCEPT
  iptables -t nat -C POSTROUTING -s $HK_INT_NET -o $HK_EXT_IF -j SNAT --to-source $HK_EXT_IP 2>/dev/null || iptables -t nat -A POSTROUTING -s $HK_INT_NET -o $HK_EXT_IF -j SNAT --to-source $HK_EXT_IP
fi
logger -t restore-snat 'HK SNAT configuration restored (kkix)'
EOF
  chmod +x /usr/local/bin/restore-hk-snat.sh
  cat > /etc/systemd/system/hk-snat-restore.service <<'EOF'
[Unit]
Description=Restore HK SNAT Configuration (kkix)
After=network-online.target
Wants=network-online.target
Before=ssh.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/restore-hk-snat.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable hk-snat-restore.service >/dev/null 2>&1 || warn "hk-snat-restore 服务 enable 失败，请手动检查"
  mkdir -p "$STATE_DIR"; touch "$STATE_DIR/hk_route_ready"
  { echo "version=$SCRIPT_VERSION"; echo "updated=$(date -Iseconds)"; echo "mode=route"
    echo "hk_external_if=$HK_EXT_IF"; echo "hk_internal_if=$HK_INT_IF"; } > "$STATE_DIR/hk_route_flag"
  info "香港端完成：SNAT $HK_INT_NET -> $HK_EXT_IP ($HK_EXT_IF)，放行 $QH_IP"
}

# ----------------------------- 前海端 apply ---------------------------------
# 生成远端脚本（参数头 %q 安全引用 + 正文单引号 heredoc），一次 SSH 执行完毕，
# 取代原版上百次 remote_sudo 字符串拼接（引号/变量展开是原版最脆弱的部分）。
gen_remote_apply() {
  local f="$1"
  {
    printf 'QH_EXT_IF=%q QH_INT_IF=%q QH_EXT_IP=%q QH_INT_IP=%q QH_EXT_GW=%q\n' \
      "$QH_EXT_IF" "$QH_INT_IF" "$QH_EXT_IP" "$QH_INT_IP" "$QH_EXT_GW"
    printf 'HK_LAN_IP=%q QH_IP=%q ROUTE_MARK=%q DEADMAN_SECONDS=%q\n' \
      "$HK_LAN_IP" "$QH_IP" "$ROUTE_MARK" "$DEADMAN_SECONDS"
    printf 'SWITCH_DEFAULT=%q CHANGE_DNS=%q DISABLE_AUTO_UPGRADE=%q BACKUP_TS=%q\n' \
      "$((1-KEEP_DEFAULT_ROUTE))" "$CHANGE_DNS" "$DISABLE_AUTO_UPGRADE" "$(date +%Y%m%d%H%M%S)"
    cat <<'RBODY'
set -euo pipefail
RSTATE=/etc/kkix_state; mkdir -p "$RSTATE/backup-$BACKUP_TS"
BK="$RSTATE/backup-$BACKUP_TS"
{ ip rule show; ip route show table all; ip route show default; nft list ruleset 2>/dev/null || true; } > "$BK/before.txt" 2>&1 || true
ip route show default | head -n1 > "$BK/default_route.txt" || true
echo "$BK" > "$RSTATE/latest_backup"
# 原始默认路由锚点：只在当前默认还走外网口时才认作「原始」，已有锚点永不覆盖
if [ ! -s "$RSTATE/true_original_default_route" ]; then
  cur=$(cat "$BK/default_route.txt")
  case "$cur" in *"dev $QH_EXT_IF"*) echo "$cur" > "$RSTATE/true_original_default_route" ;; esac
fi

# 路由表登记（文件不存在才建最小版，不再整表重写）
if [ ! -f /etc/iproute2/rt_tables ]; then
  mkdir -p /etc/iproute2
  printf '255\tlocal\n254\tmain\n253\tdefault\n0\tunspec\n' > /etc/iproute2/rt_tables
fi
grep -qw ix_return /etc/iproute2/rt_tables    || echo '100 ix_return'    >> /etc/iproute2/rt_tables
grep -qw internal_out /etc/iproute2/rt_tables || echo '101 internal_out' >> /etc/iproute2/rt_tables

# 清旧（幂等）
nft delete table inet qh_mark >/dev/null 2>&1 || true
iptables -t mangle -D PREROUTING -i "$QH_EXT_IF" -j CONNMARK --set-mark "$ROUTE_MARK" 2>/dev/null || true
iptables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null || true
while ip rule del from "$QH_EXT_IP" table ix_return 2>/dev/null; do :; done
while ip rule del from "$QH_INT_IP" table internal_out 2>/dev/null; do :; done
while ip rule del fwmark "$ROUTE_MARK" table ix_return 2>/dev/null; do :; done
ip route flush table ix_return 2>/dev/null || true
ip route flush table internal_out 2>/dev/null || true

# 到香港端的 /32 主机路由：香港就在内网口对面，用 on-link 设备路由（原版 via 自己是错的且被 ||true 吞掉）
ip route replace "$HK_LAN_IP/32" dev "$QH_INT_IF"
# internal_out：源为内网口地址的流量默认走香港
ip route add default via "$HK_LAN_IP" dev "$QH_INT_IF" table internal_out
ip rule add from "$QH_INT_IP" table internal_out priority 90
# ix_return：从外网口进来的连接，回包仍走外网口原网关（入站路径不变）
ip route add default via "$QH_EXT_GW" dev "$QH_EXT_IF" table ix_return
ip route add "$QH_INT_IP/32" dev "$QH_INT_IF" table ix_return 2>/dev/null || true
ip rule add from "$QH_EXT_IP" table ix_return priority 100
ip rule add fwmark "$ROUTE_MARK" table ix_return priority 99

# 连接标记：入站连接打标，出站回包恢复标记 -> 查 ix_return
if command -v nft >/dev/null 2>&1; then
  nft add table inet qh_mark
  nft 'add chain inet qh_mark prerouting { type filter hook prerouting priority -150; policy accept; }'
  nft 'add chain inet qh_mark output { type route hook output priority -150; policy accept; }'
  nft "add rule inet qh_mark prerouting iifname $QH_EXT_IF ct mark set $ROUTE_MARK"
  nft 'add rule inet qh_mark output meta mark set ct mark'
else
  iptables -t mangle -A PREROUTING -i "$QH_EXT_IF" -j CONNMARK --set-mark "$ROUTE_MARK"
  iptables -t mangle -A OUTPUT -j CONNMARK --restore-mark
fi

# rp_filter 放宽（策略路由必需），写 sysctl.d 而非改 sysctl.conf
mkdir -p /etc/sysctl.d
printf '# kkix route mode\nnet.ipv4.conf.all.rp_filter=2\nnet.ipv4.conf.%s.rp_filter=2\nnet.ipv4.conf.%s.rp_filter=2\n' \
  "$QH_EXT_IF" "$QH_INT_IF" > /etc/sysctl.d/99-kkix-route.conf
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
sysctl -w "net.ipv4.conf.$QH_EXT_IF.rp_filter=2" >/dev/null
sysctl -w "net.ipv4.conf.$QH_INT_IF.rp_filter=2" >/dev/null

if [ "$CHANGE_DNS" = 1 ]; then
  for dns in 8.8.8.8 1.1.1.1; do ip route replace "$dns/32" via "$HK_LAN_IP" dev "$QH_INT_IF" 2>/dev/null || true; done
fi

# 可选：禁用 apt 自动升级，并把原 enabled 状态记下来以便回滚（原版 sbmode 默认就关，本版默认不动）
if [ "$DISABLE_AUTO_UPGRADE" = 1 ] && [ -f /etc/debian_version ] && [ ! -f /etc/qh_auto_upgrade_state ]; then
  : > /etc/qh_auto_upgrade_state
  for u in apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service unattended-upgrades.service; do
    if systemctl list-unit-files "$u" >/dev/null 2>&1; then
      echo "$u=$(systemctl is-enabled "$u" 2>/dev/null || echo unknown)" >> /etc/qh_auto_upgrade_state
      systemctl disable --now "$u" >/dev/null 2>&1 || true
    fi
  done
fi

# ---- 开机恢复脚本 ----
cat > /usr/local/bin/restore-qh-route.sh <<EOF2
#!/bin/bash
set +e
for i in \$(seq 1 30); do ip link show $QH_INT_IF >/dev/null 2>&1 && break; sleep 1; done
grep -qw ix_return /etc/iproute2/rt_tables 2>/dev/null || echo '100 ix_return' >> /etc/iproute2/rt_tables
grep -qw internal_out /etc/iproute2/rt_tables 2>/dev/null || echo '101 internal_out' >> /etc/iproute2/rt_tables
ip route replace $HK_LAN_IP/32 dev $QH_INT_IF
ip route flush table internal_out 2>/dev/null; ip route add default via $HK_LAN_IP dev $QH_INT_IF table internal_out
ip route flush table ix_return 2>/dev/null;    ip route add default via $QH_EXT_GW dev $QH_EXT_IF table ix_return
while ip rule del from $QH_INT_IP table internal_out 2>/dev/null; do :; done
while ip rule del from $QH_EXT_IP table ix_return 2>/dev/null; do :; done
while ip rule del fwmark $ROUTE_MARK table ix_return 2>/dev/null; do :; done
ip rule add from $QH_INT_IP table internal_out priority 90
ip rule add from $QH_EXT_IP table ix_return priority 100
ip rule add fwmark $ROUTE_MARK table ix_return priority 99
if command -v nft >/dev/null 2>&1; then
  nft delete table inet qh_mark >/dev/null 2>&1
  nft add table inet qh_mark
  nft 'add chain inet qh_mark prerouting { type filter hook prerouting priority -150; policy accept; }'
  nft 'add chain inet qh_mark output { type route hook output priority -150; policy accept; }'
  nft 'add rule inet qh_mark prerouting iifname $QH_EXT_IF ct mark set $ROUTE_MARK'
  nft 'add rule inet qh_mark output meta mark set ct mark'
fi
if [ "\$(cat /etc/qh_default_route_mode 2>/dev/null)" = hk ]; then
  # 开机竞态修复（v2.0.1）：原版只 ping 一次就定生死，香港端启动稍慢就永久回退。
  # 这里最多等 120 秒；仍不通先走外网保命，之后由 check-network 在香港恢复后自动切回。
  ok=0
  for i in \$(seq 1 60); do ping -c 1 -W 2 $HK_LAN_IP >/dev/null 2>&1 && { ok=1; break; }; sleep 2; done
  if [ "\$ok" = 1 ]; then
    ip route replace default via $HK_LAN_IP dev $QH_INT_IF
  else
    ip route replace default via $QH_EXT_GW dev $QH_EXT_IF
    logger -t restore-route 'HK unreachable after 120s at boot, kept original default; check-network will re-converge'
  fi
fi
logger -t restore-route 'QH route configuration restored (kkix)'
EOF2
chmod +x /usr/local/bin/restore-qh-route.sh
cat > /etc/systemd/system/qh-route-restore.service <<'EOF3'
[Unit]
Description=Restore QH Route Configuration (kkix)
After=network-online.target
Wants=network-online.target
Before=ssh.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/restore-qh-route.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF3

# ---- 全量收敛看门狗（v3）：每 2 分钟把「默认路由 + ix_return 回程表 + 标记表」
# 三件套拉回正确状态。原版 check-network 只处理默认路由一个方向、且 ix_return 里
# 写死的是猜错的网关——本版看门狗发现结构漂移就整套重跑恢复脚本（网关来自真实快照）----
cat > /usr/local/bin/check-network.sh <<EOF4
#!/bin/bash
[ "\$(cat /etc/qh_default_route_mode 2>/dev/null)" = hk ] || exit 0
cur() { ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(\$i=="via") print \$(i+1)}' | head -n1; }
if ping -c 2 -W 2 $HK_LAN_IP >/dev/null 2>&1; then
  if ! nft list table inet qh_mark >/dev/null 2>&1 || ! ip rule show | grep -q ix_return || ! ip route show table ix_return 2>/dev/null | grep -q "^default via $QH_EXT_GW "; then
    /usr/local/bin/restore-qh-route.sh >/dev/null 2>&1
    logger -t network-check 'structure drift detected, full restore re-applied (kkix)'
  fi
  if [ "\$(cur)" != "$HK_LAN_IP" ]; then
    ip route replace default via $HK_LAN_IP dev $QH_INT_IF
    logger -t network-check 'HK reachable, default route re-converged to HK (kkix)'
  fi
else
  if [ "\$(cur)" = "$HK_LAN_IP" ]; then
    ip route replace default via $QH_EXT_GW dev $QH_EXT_IF
    logger -t network-check 'HK gateway lost, default route temporarily restored to external (kkix)'
  fi
fi
EOF4
chmod +x /usr/local/bin/check-network.sh
cat > /etc/systemd/system/network-check.service <<'EOF5'
[Unit]
Description=KKIX full-convergence watchdog
[Service]
Type=oneshot
ExecStart=/usr/local/bin/check-network.sh
EOF5
cat > /etc/systemd/system/network-check.timer <<'EOF6'
[Unit]
Description=Run KKIX watchdog every 2 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
[Install]
WantedBy=timers.target
EOF6
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable qh-route-restore.service >/dev/null 2>&1 || true
systemctl enable --now network-check.timer >/dev/null 2>&1 || true

printf 'status=ready\nupdated=%s\n' "$(date -Iseconds)" > /etc/qh_route_status; chmod 600 /etc/qh_route_status
{ echo "version=3.0.0-onekey"; echo "mode=route"; echo "status=ready"
  echo "external_if=$QH_EXT_IF"; echo "internal_if=$QH_INT_IF"; } > /etc/kkix_route_flag

# ---- 死人开关 + 切默认路由（顺序不可反）----
if [ "$SWITCH_DEFAULT" = 1 ]; then
  cat > /usr/local/bin/kkix-deadman.sh <<EOF7
#!/bin/bash
[ -f $RSTATE/deadman_armed ] || exit 0
orig=\$(cat $RSTATE/true_original_default_route 2>/dev/null)
if [ -n "\$orig" ]; then ip route replace \$orig 2>/dev/null || ip route add \$orig 2>/dev/null; fi
[ -z "\$orig" ] && ip route replace default via $QH_EXT_GW dev $QH_EXT_IF
echo original > /etc/qh_default_route_mode
rm -f $RSTATE/deadman_armed
logger -t kkix-deadman 'Controller did not confirm in time, default route rolled back'
EOF7
  chmod +x /usr/local/bin/kkix-deadman.sh
  touch "$RSTATE/deadman_armed"
  if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --unit=kkix-deadman --on-active="${DEADMAN_SECONDS}s" /usr/local/bin/kkix-deadman.sh >/dev/null 2>&1 \
      || { setsid bash -c "sleep $DEADMAN_SECONDS; exec /usr/local/bin/kkix-deadman.sh" >/dev/null 2>&1 & }
  else
    setsid bash -c "sleep $DEADMAN_SECONDS; exec /usr/local/bin/kkix-deadman.sh" >/dev/null 2>&1 &
  fi
  ip route replace default via "$HK_LAN_IP" dev "$QH_INT_IF"
  echo hk > /etc/qh_default_route_mode
  # 远端自检：切完立刻 ping 香港，通不了当场切回，不等死人开关
  if ! ping -c 3 -W 2 "$HK_LAN_IP" >/dev/null 2>&1; then
    /usr/local/bin/kkix-deadman.sh
    echo 'QH_SELFCHECK_FAIL' >&2
    exit 21
  fi
else
  echo original > /etc/qh_default_route_mode
fi
ip route flush cache 2>/dev/null || true
echo 'QH_APPLY_OK'
RBODY
  } > "$f"
}

apply_qh() {
  local tmp; tmp=$(mktemp /tmp/kkix-qh-apply.XXXXXX.sh)
  gen_remote_apply "$tmp"
  info "配置前海端策略路由（单次 SSH 下发）..."
  local sudo_str; sudo_str=$(remote_sudo_str)
  if ! "${SSH_BASE[@]}" "$sudo_str bash -s" < "$tmp" > "$STATE_DIR/qh-apply.out" 2>&1; then
    cat "$STATE_DIR/qh-apply.out" >&2 || true
    rm -f "$tmp"
    if grep -q QH_SELFCHECK_FAIL "$STATE_DIR/qh-apply.out"; then
      die "前海端切默认路由后自检不通，已当场切回原默认路由；香港端 SNAT 已保留，可用 --rollback 全清或排查链路后重跑" 5
    fi
    die "前海端配置失败（输出见 $STATE_DIR/qh-apply.out）。香港端 SNAT 已配置但未被使用，可用 --rollback 清理" 5
  fi
  rm -f "$tmp"
  grep -q QH_APPLY_OK "$STATE_DIR/qh-apply.out" || warn "前海端未返回完成标记，请用 --status 复核"
  info "前海端策略路由已下发"
}

# ----------------------------- 香港机守护层 ---------------------------------
# 第二层守护：香港机每 2 分钟自检（转发/SNAT），并用专用密钥 SSH 进对端，
# 发现其默认路由漂移就远程触发它的恢复脚本。与对端本地看门狗互为冗余。
setup_hk_guard() {
  info "安装香港机守护层（专用密钥 + 每 2 分钟定时器）..."
  mkdir -p /etc/kkix-guard /root/.ssh
  if [[ ! -f /root/.ssh/kkix_guard ]]; then
    ssh-keygen -t ed25519 -N '' -f /root/.ssh/kkix_guard >/dev/null
  fi
  local pub; pub=$(cat /root/.ssh/kkix_guard.pub)
  # 把守护公钥装到对端（复用当前已验证可用的 SSH 通道，无需再输密码）
  remote_exec "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" >/dev/null 2>&1 || true
  if ! remote_exec "grep -qxF '$pub' ~/.ssh/authorized_keys" >/dev/null 2>&1; then
    remote_exec "echo '$pub' >> ~/.ssh/authorized_keys" >/dev/null 2>&1 || warn "守护公钥安装失败，香港机守护的远程纠偏暂不可用（对端本地看门狗不受影响）"
  fi
  printf '%s %s %s %s\n' "$QH_IP" "$SSH_USER" "$SSH_PORT" "$HK_LAN_IP" > /etc/kkix-guard/peers.conf

  cat > /usr/local/bin/kkix-guard-hk.sh <<'GUARD_EOF'
#!/bin/bash
# kkix-guard（香港机）：本机自检 + 逐个对端远程纠偏（与 ix-onekey.sh 配套）
PEERS_FILE=/etc/kkix-guard/peers.conf
KEY=/root/.ssh/kkix_guard
[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ] || echo 1 > /proc/sys/net/ipv4/ip_forward
if command -v nft >/dev/null 2>&1; then
  nft list table ip hk_snat >/dev/null 2>&1 || systemctl restart hk-snat-restore.service
fi
[ -f "$PEERS_FILE" ] || exit 0
while read -r PEER_IP SSH_USER SSH_PORT HK_IP; do
  [[ -z "${PEER_IP:-}" || "$PEER_IP" == \#* ]] && continue
  ssh -i "$KEY" -p "${SSH_PORT:-22}" -o BatchMode=yes -o ConnectTimeout=8 \
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/root/.ssh/kkix_known_hosts \
      "${SSH_USER:-root}@${PEER_IP}" 'bash -s' "$HK_IP" <<'EOS' >/dev/null 2>&1
HK_IP="$1"
[ "$(cat /etc/qh_default_route_mode 2>/dev/null)" = "hk" ] || exit 0
ping -c 2 -W 2 "$HK_IP" >/dev/null 2>&1 || exit 0
cur() { ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' | head -n1; }
[ "$(cur)" = "$HK_IP" ] && exit 0
/usr/local/bin/restore-qh-route.sh >/dev/null 2>&1
sleep 2
[ "$(cur)" != "$HK_IP" ] && /usr/local/bin/restore-qh-route.sh >/dev/null 2>&1
[ "$(cur)" = "$HK_IP" ] && logger -t kkix-guard "default route fixed back to HK $HK_IP"
exit 0
EOS
done < "$PEERS_FILE"
exit 0
GUARD_EOF
  chmod +x /usr/local/bin/kkix-guard-hk.sh
  cat > /etc/systemd/system/kkix-guard-hk.service <<'EOF'
[Unit]
Description=KKIX guard (HK side; fixes peers' default route via SSH)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/kkix-guard-hk.sh
EOF
  cat > /etc/systemd/system/kkix-guard-hk.timer <<'EOF'
[Unit]
Description=Run KKIX guard every 2 minutes
[Timer]
OnBootSec=3min
OnUnitActiveSec=2min
Unit=kkix-guard-hk.service
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now kkix-guard-hk.timer >/dev/null 2>&1 || warn "kkix-guard-hk.timer 启用失败，请手动检查"
  # 免密实测一次
  if ssh -i /root/.ssh/kkix_guard -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=8 \
       -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/root/.ssh/kkix_known_hosts \
       "${SSH_USER}@${QH_IP}" true 2>/dev/null; then
    info "香港机守护层就绪（免密 SSH 已通，定时器已启用）"
  else
    warn "守护密钥免密登录未通：远程纠偏暂不可用，但对端本地看门狗 + 开机恢复不受影响"
  fi
}

# ----------------------------- 验证与解除死人开关 -----------------------------
verify_and_disarm() {
  (( KEEP_DEFAULT_ROUTE )) && { info "未切默认路由，跳过出口验证"; return 0; }
  info "用新 SSH 连接验证前海端（连接本身能通即证明回程正常）..."
  local out egress defrt
  out=$(remote_exec 'echo DEF=$(ip route show default | head -n1); echo EGRESS=$(curl -4 -s --max-time 10 https://ipinfo.io/ip || curl -4 -s --max-time 10 https://ifconfig.me || echo FAIL); ping -c 2 -W 2 '"$HK_LAN_IP"' >/dev/null 2>&1 && echo HK_PING=ok || echo HK_PING=fail' 2>/dev/null) \
    || die "新 SSH 连不上前海端：不要再操作，${DEADMAN_SECONDS}s 内死人开关会自动切回原默认路由；恢复后先 --status 再排查" 6
  defrt=$(grep '^DEF=' <<<"$out" | cut -d= -f2-)
  egress=$(grep '^EGRESS=' <<<"$out" | cut -d= -f2-)
  info "前海当前默认路由: ${defrt:-未知}"
  info "前海当前出口 IP: ${egress:-未知}（香港外网口 IP: $HK_EXT_IP）"
  grep -q 'HK_PING=ok' <<<"$out" || die "前海 ping 不通香港 $HK_LAN_IP，保留死人开关等待自动回滚" 6
  [[ "$egress" != "FAIL" && -n "$egress" ]] || die "前海出网验证失败（curl 无结果），保留死人开关等待自动回滚，或确认恢复后重跑" 6
  [[ "$egress" == "$HK_EXT_IP" ]] || warn "出口 IP 与香港外网口 IP 不一致（上游 NAT 时正常），以实际出口为准"
  # 验证全过 -> 解除死人开关
  local sudo_str; sudo_str=$(remote_sudo_str)
  remote_exec "$sudo_str rm -f /etc/kkix_state/deadman_armed; $sudo_str systemctl stop kkix-deadman.timer kkix-deadman.service >/dev/null 2>&1; true" >/dev/null 2>&1 || true
  info "验证通过，死人开关已解除"
}

# ----------------------------- Status / Rollback -----------------------------
do_status() {
  setup_ssh
  echo "== 香港端 =="
  command -v nft >/dev/null && nft list table ip hk_snat 2>/dev/null || echo "(无 nft hk_snat 表)"
  systemctl is-enabled hk-snat-restore.service 2>/dev/null || echo "hk-snat-restore: 未启用"
  echo "ip_forward=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
  echo "== 前海端 =="
  remote_exec 'echo "默认路由: $(ip route show default | head -n1)"; echo "策略规则:"; ip rule show | grep -E "ix_return|internal_out|fwmark" || echo "  (无)"; echo "默认路由模式: $(cat /etc/qh_default_route_mode 2>/dev/null || echo 未知)"; echo "出口IP: $(curl -4 -s --max-time 8 https://ipinfo.io/ip || echo 取不到)"' \
    || die "SSH 连接前海端失败" 3
}

do_rollback() {
  setup_ssh
  info "回滚香港端..."
  nft delete table ip hk_snat >/dev/null 2>&1 || true
  iptables -t nat -D POSTROUTING -s "$HK_INT_NET" -o "$HK_EXT_IF" -j SNAT --to-source "$HK_EXT_IP" 2>/dev/null || true
  iptables -D FORWARD -s "$QH_IP" -i "$HK_INT_IF" -o "$HK_EXT_IF" -j ACCEPT 2>/dev/null || true
  systemctl disable hk-snat-restore.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/hk-snat-restore.service /usr/local/bin/restore-hk-snat.sh
  systemctl disable --now kkix-guard-hk.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/kkix-guard-hk.service /etc/systemd/system/kkix-guard-hk.timer /usr/local/bin/kkix-guard-hk.sh
  rm -rf /etc/kkix-guard
  systemctl daemon-reload >/dev/null 2>&1 || true
  if [[ -f "$STATE_DIR/latest_backup" ]]; then
    local bd; bd=$(cat "$STATE_DIR/latest_backup")
    if [[ -f "$bd/ip_forward.before" && "$(cat "$bd/ip_forward.before")" == "0" ]]; then
      rm -f /etc/sysctl.d/99-kkix-route.conf; sysctl -w net.ipv4.ip_forward=0 >/dev/null || true
    fi
  fi
  rm -f "$STATE_DIR/hk_route_ready" "$STATE_DIR/hk_route_flag"

  info "回滚前海端（按其本地快照恢复默认路由）..."
  local sudo_str; sudo_str=$(remote_sudo_str)
  remote_exec "$sudo_str bash -s" <<'RROLL' || die "前海端回滚失败，请手动检查" 5
set +e
RSTATE=/etc/kkix_state
orig=$(cat "$RSTATE/true_original_default_route" 2>/dev/null)
if [ -n "$orig" ]; then ip route replace $orig 2>/dev/null || ip route add $orig 2>/dev/null; fi
nft delete table inet qh_mark >/dev/null 2>&1
while ip rule del table ix_return 2>/dev/null; do :; done
while ip rule del table internal_out 2>/dev/null; do :; done
ip route flush table ix_return 2>/dev/null; ip route flush table internal_out 2>/dev/null
systemctl disable --now network-check.timer qh-route-restore.service >/dev/null 2>&1
rm -f /etc/systemd/system/qh-route-restore.service /etc/systemd/system/network-check.service /etc/systemd/system/network-check.timer
rm -f /usr/local/bin/restore-qh-route.sh /usr/local/bin/check-network.sh /usr/local/bin/kkix-deadman.sh
rm -f /etc/qh_route_status /etc/kkix_route_flag /etc/qh_default_route_mode "$RSTATE/deadman_armed"
rm -f /etc/sysctl.d/99-kkix-route.conf
systemctl daemon-reload >/dev/null 2>&1
# apt 自动升级按记录恢复
if [ -f /etc/qh_auto_upgrade_state ]; then
  while IFS='=' read -r u st; do [ "$st" = enabled ] && systemctl enable "$u" >/dev/null 2>&1; done < /etc/qh_auto_upgrade_state
  rm -f /etc/qh_auto_upgrade_state
fi
echo QH_ROLLBACK_OK
RROLL
  info "回滚完成。注意：路由表登记（rt_tables 中的 ix_return/internal_out 行）无害，予以保留"
}

# ----------------------------- Main -----------------------------------------
main() {
  parse_args "$@"
  [[ -n "$CONFIG_FILE" ]] && load_config_file "$CONFIG_FILE"
  [[ -z "$CONFIG_FILE" && -f "$CONFIG_FILE_DEFAULT" ]] && load_config_file "$CONFIG_FILE_DEFAULT"
  case "$MODE" in
    status)
      if [[ -z "$QH_IP" ]]; then
        require_root; local_probe; pick_local_ifaces
        HK_INT_CIDR="${LIF_IP4[$HK_INT_IF]:-}"; HK_INT_NET=$(cidr_network "${HK_INT_CIDR:-0.0.0.0/24}")
        resolve_qh_ip
      fi
      do_status ;;
    rollback)
      # 回滚需要接口信息来删本机规则：做轻量本机探测（不要求 SSH 先行成功）
      require_root; local_probe; pick_local_ifaces
      HK_EXT_CIDR="${LIF_IP4[$HK_EXT_IF]:-}"; HK_EXT_IP="${HK_EXT_CIDR%/*}"
      HK_INT_CIDR="${LIF_IP4[$HK_INT_IF]:-}"; HK_INT_NET=$(cidr_network "${HK_INT_CIDR:-0.0.0.0/24}")
      resolve_qh_ip
      do_rollback ;;
    dry-run)  preflight; info "dry-run 结束：未做任何修改" ;;
    apply)
      preflight
      snapshot_local
      apply_hk   || die "香港端配置失败（前海端尚未动），可 --rollback 清理" 4
      apply_qh
      setup_hk_guard || warn "香港机守护层安装未完全成功，不影响本次组网结果，可重跑脚本补装"
      verify_and_disarm
      echo ""
      info "全部完成。前海出口应为香港 IP $HK_EXT_IP（验证结果见上）"
      info "回滚命令: $0 --config ${CONFIG_FILE:-$CONFIG_FILE_DEFAULT} --rollback（或加 --qh-ip $QH_IP）"
      ;;
  esac
}
main "$@"
