#!/usr/bin/env bash
# ============================================================
# SK5 / SOCKS5 一键搭建脚本 v2 (基于 gost v2, 单二进制, 支持 UDP)
# v2 审计修复: 随机数生成 SIGPIPE 静默退出 / ARM64 资产名 armv8 / 参数缺值与用户名校验 / 非 systemd 环境识别
# 支持: Debian / Ubuntu / CentOS / Rocky / Alma / Fedora / Alpine
# 架构: x86_64 / aarch64 / armv7
#
# 用法:
#   bash sk5.sh                                  # 一键安装, 随机端口/账号/密码
#   bash sk5.sh --port 1080 --user myuser --pass mypass123
#   SK5_PORT=1080 SK5_USER=myuser SK5_PASS=mypass123 bash sk5.sh
#   bash sk5.sh --status                         # 查看状态和连接信息
#   bash sk5.sh --uninstall                      # 卸载
#
# 说明: 必须用 root 运行。云服务器记得在安全组放行对应端口 TCP+UDP。
# ============================================================
set -euo pipefail

GOST_VERSION="2.11.5"
BIN_PATH="/usr/local/bin/gost"
SERVICE_NAME="sk5"
SERVICE_FILE="/etc/systemd/system/sk5.service"
INFO_DIR="/etc/sk5"
INFO_FILE="${INFO_DIR}/info.txt"

PORT="${SK5_PORT:-}"
USER_NAME="${SK5_USER:-}"
PASS_WORD="${SK5_PASS:-}"
ACTION="install"

# ---------- 参数解析 ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port|--user|--pass)
      [[ $# -ge 2 ]] || { echo "❌ $1 后面缺少值"; exit 1; }
      case "$1" in
        --port) PORT="$2" ;;
        --user) USER_NAME="$2" ;;
        --pass) PASS_WORD="$2" ;;
      esac
      shift 2 ;;
    --status) ACTION="status"; shift ;;
    --uninstall|uninstall) ACTION="uninstall"; shift ;;
    -h|--help)
      echo "用法: bash sk5.sh [--port 端口] [--user 用户名] [--pass 密码] [--status] [--uninstall]"
      exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "❌ 请用 root 运行: sudo bash $0"; exit 1; }

# 注意: 不能用 'tr -dc ... </dev/urandom | head -c' —— 无限流被 head 截断会让 tr 吃 SIGPIPE,
# 在 set -o pipefail 下整脚本以 141 静默退出 (v1 实测踩中, 无参数安装第一步就死)
rand_str() {
  local n="$1" s=""
  while [[ ${#s} -lt $n ]]; do
    s+=$(head -c 32 /dev/urandom | tr -dc 'A-Za-z0-9')
  done
  printf '%s' "${s:0:$n}"
}

# systemd 是否真正在运行 (只有 systemctl 二进制但没跑 systemd 的容器/LXC 里不能用它)
has_systemd() { command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }

show_info() {
  if [[ -f "$INFO_FILE" ]]; then
    cat "$INFO_FILE"
  else
    echo "未找到 $INFO_FILE, 可能尚未安装。"
  fi
}

do_status() {
  echo "== 服务状态 =="
  if has_systemd; then
    systemctl is-active sk5 2>/dev/null || echo "sk5 服务未运行"
    systemctl status sk5 --no-pager -l 2>/dev/null | head -n 20 || true
  fi
  echo
  echo "== 连接信息 =="
  show_info
}

do_uninstall() {
  echo ">>> 卸载 SK5 ..."
  if has_systemd; then
    systemctl stop sk5 2>/dev/null || true
    systemctl disable sk5 2>/dev/null || true
  else
    pkill -f "gost -L socks5" 2>/dev/null || true
  fi
  rm -f "$SERVICE_FILE" "$BIN_PATH"
  rm -rf "$INFO_DIR"
  if has_systemd; then systemctl daemon-reload || true; fi
  echo "✅ 已卸载 (如需关端口, 去云厂商安全组/防火墙手动删除放行规则)"
  exit 0
}

[[ "$ACTION" == "status" ]] && { do_status; exit 0; }
[[ "$ACTION" == "uninstall" ]] && do_uninstall

# ---------- 先校验用户给的值 (在生成随机默认值之前, 报错才干净) ----------
if [[ -n "$PORT" ]]; then
  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    echo "❌ 端口不合法: $PORT"; exit 1
  fi
fi
# 用户名/密码会拼进 gost 的 URL, 只允许字母数字和 _- , 避免 @ : / 等字符把 URL 拼坏
if [[ -n "$USER_NAME" ]] && ! [[ "$USER_NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "❌ 用户名只能含字母/数字/_/- , 请换一个: 当前=$USER_NAME"; exit 1
fi
if [[ -n "$PASS_WORD" ]] && ! [[ "$PASS_WORD" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "❌ 密码只能含字母/数字/_/- , 请换一个: 当前=$PASS_WORD"; exit 1
fi

# ---------- 默认值: 随机端口/账号/密码 ----------
if [[ -z "$PORT" ]]; then
  # 优先 1080, 被占用就随机 20000-50000
  if command -v ss >/dev/null 2>&1 && ss -tuln 2>/dev/null | grep -q ':1080 '; then
    PORT=$((RANDOM % 30000 + 20000))
  else
    PORT=1080
  fi
fi
[[ -z "$USER_NAME" ]] && USER_NAME="sk5$(rand_str 4 | tr 'A-Z' 'a-z')"
[[ -z "$PASS_WORD" ]] && PASS_WORD="$(rand_str 16)"

# ---------- 安装依赖 ----------
echo ">>> [1/5] 安装依赖 ..."
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq || true
  apt-get install -y -qq curl wget gzip iproute2 >/dev/null 2>&1 || apt-get install -y curl wget gzip || true
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y -q curl wget gzip iproute >/dev/null 2>&1 || true
elif command -v yum >/dev/null 2>&1; then
  yum install -y -q curl wget gzip iproute >/dev/null 2>&1 || true
elif command -v apk >/dev/null 2>&1; then
  apk add --no-cache curl wget gzip iproute2 bash >/dev/null 2>&1 || true
fi

# ---------- 下载 gost ----------
echo ">>> [2/5] 下载 gost v${GOST_VERSION} ..."
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  GOST_ARCH="amd64" ;;
  aarch64|arm64) GOST_ARCH="armv8" ;;  # gost v2.11.5 的资产名是 armv8, 没有 arm64 (已对官方资产列表核实)
  armv7l|armv7)  GOST_ARCH="armv7" ;;
  armv6l)        GOST_ARCH="armv6" ;;
  i386|i686)     GOST_ARCH="386" ;;
  *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
esac

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
GZ_FILE="gost-linux-${GOST_ARCH}-${GOST_VERSION}.gz"
URL="https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/${GZ_FILE}"

download_ok=0
if command -v curl >/dev/null 2>&1; then
  curl -fsSL --connect-timeout 15 -o "${TMP_DIR}/${GZ_FILE}" "$URL" && download_ok=1 || true
fi
if [[ "$download_ok" != "1" ]] && command -v wget >/dev/null 2>&1; then
  wget -q -O "${TMP_DIR}/${GZ_FILE}" "$URL" && download_ok=1 || true
fi
# GitHub 直连失败时试镜像加速 (可选兜底)
if [[ "$download_ok" != "1" ]]; then
  echo "    GitHub 直连失败, 尝试镜像..."
  curl -fsSL --connect-timeout 15 -o "${TMP_DIR}/${GZ_FILE}" "https://gh-proxy.com/${URL}" && download_ok=1 || true
fi
[[ "$download_ok" == "1" ]] || { echo "❌ 下载 gost 失败, 检查服务器能否访问 GitHub"; exit 1; }

gzip -dc "${TMP_DIR}/${GZ_FILE}" > "${TMP_DIR}/gost"
install -m 0755 "${TMP_DIR}/gost" "$BIN_PATH"
"$BIN_PATH" -V || { echo "❌ gost 二进制无法运行 (架构不对?)"; exit 1; }

# ---------- 写 systemd 服务 ----------
echo ">>> [3/5] 配置服务 (开机自启) ..."
# 重装/改参数时先停旧服务, 再查端口是否被别的程序占用
if has_systemd; then
  systemctl stop sk5 2>/dev/null || true
else
  pkill -f "gost -L socks5" 2>/dev/null || true
fi
sleep 1
if command -v ss >/dev/null 2>&1 && ss -tuln 2>/dev/null | grep -q ":${PORT} "; then
  echo "❌ 端口 ${PORT} 已被其他程序占用, 换个端口: bash sk5.sh --port 其他端口"
  exit 1
fi
if has_systemd; then
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=SK5 SOCKS5 Proxy (gost)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} -L socks5://${USER_NAME}:${PASS_WORD}@:${PORT}?udp=true
Restart=always
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sk5 >/dev/null 2>&1 || true
  systemctl restart sk5
else
  # 无 systemd (Alpine 等): nohup 兜底
  echo "    未检测到 systemd, 用 nohup 启动 (重启后需手动再跑本脚本)"
  pkill -f "gost -L socks5" 2>/dev/null || true
  nohup "$BIN_PATH" -L "socks5://${USER_NAME}:${PASS_WORD}@:${PORT}?udp=true" >/var/log/sk5.log 2>&1 &
fi

# ---------- 防火墙放行 (本机层, 云安全组仍需手动放行) ----------
echo ">>> [4/5] 放行防火墙端口 ${PORT} (TCP+UDP) ..."
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
  ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
  ufw allow "${PORT}/udp" >/dev/null 2>&1 || true
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port="${PORT}/udp" >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
fi
if command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
  iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || true
fi

# ---------- 验证 + 输出 ----------
echo ">>> [5/5] 验证服务 ..."
sleep 2
RUNNING=0
if has_systemd; then
  systemctl is-active --quiet sk5 && RUNNING=1 || true
else
  pgrep -f "gost -L socks5" >/dev/null && RUNNING=1 || true
fi
if [[ "$RUNNING" != "1" ]]; then
  echo "❌ 服务没起来, 看日志: journalctl -u sk5 -n 50 --no-pager"
  exit 1
fi

PUBLIC_IP="$(curl -fsS --connect-timeout 8 https://api.ipify.org 2>/dev/null || curl -fsS --connect-timeout 8 https://ifconfig.me 2>/dev/null || curl -fsS --connect-timeout 8 https://ip.sb 2>/dev/null || echo '你的服务器IP')"

# 本地自测 (走代理拿 IP, 失败不阻断, 可能只是测试站点被墙)
TEST_IP="$(curl -fsS --connect-timeout 10 --socks5-hostname "${USER_NAME}:${PASS_WORD}@127.0.0.1:${PORT}" https://api.ipify.org 2>/dev/null || echo '')"

mkdir -p "$INFO_DIR"
cat > "$INFO_FILE" <<EOF
================ SK5 / SOCKS5 连接信息 ================
地址 : ${PUBLIC_IP}
端口 : ${PORT}
用户名 : ${USER_NAME}
密码 : ${PASS_WORD}
协议 : SOCKS5 (支持 TCP + UDP, 账号密码认证)

通用链接: socks5://${USER_NAME}:${PASS_WORD}@${PUBLIC_IP}:${PORT}

管理命令:
  查看状态: systemctl status sk5
  重启    : systemctl restart sk5
  查看日志: journalctl -u sk5 -f
  卸载    : bash sk5.sh --uninstall
=======================================================
EOF
chmod 600 "$INFO_FILE"

echo
cat "$INFO_FILE"
if [[ -n "$TEST_IP" ]]; then
  echo "✅ 本地自测通过, 经代理出口 IP: ${TEST_IP}"
else
  echo "⚠️ 服务已运行, 但本地自测没拿到出口 IP (可能是测试站连不上), 请用客户端连一下验证。"
fi
echo "⚠️ 别忘了: 云厂商控制台的安全组也要放行 ${PORT} 的 TCP+UDP, 否则外网连不上。"
