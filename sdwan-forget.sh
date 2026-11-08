#!/usr/bin/env bash
# sdwan-forget.sh — 清除 sdwan.sh 的「记忆」（在香港机 root 执行）
#
# 原版会把基本信息存进 /root/.kkix_config（香港IP、内地IP、SSH用户/端口/认证方式），
# 下次运行直接读它、不再询问——IP 填错一次就会一直用错的。这个脚本把记忆清掉，
# 下次运行 sdwan.sh 时会重新识别/重新问。
#
# 只清记忆文件，不动已经配好的路由、规则和恢复服务（要连配置一起清请用原版菜单的卸载）。
# 用法：bash sdwan-forget.sh
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin

CONFIG_FILE="/root/.kkix_config"
STATE_DIR="/root/.kkix_state"

[[ $(id -u) -eq 0 ]] || { echo "[ERROR] 请以 root 执行"; exit 1; }

found=0
if [[ -f "$CONFIG_FILE" ]]; then
  echo "当前记住的连接信息（$CONFIG_FILE）："
  grep -E '^(HK_LAN_IP|QIANHAI_LAN_IP|REMOTE_USER|REMOTE_PORT|REMOTE_AUTH)=' "$CONFIG_FILE" 2>/dev/null | sed 's/^/  /' || true
  rm -f "$CONFIG_FILE"
  echo "已清除：$CONFIG_FILE"
  found=1
else
  echo "没有找到 $CONFIG_FILE（本来就没有记住连接信息）"
fi

if [[ -d "$STATE_DIR" ]]; then
  rm -rf "$STATE_DIR"
  echo "已清除：$STATE_DIR（完成标记与动作日志）"
  found=1
fi

if (( found )); then
  echo ""
  echo "记忆已清空。下次运行 sdwan.sh 时会重新识别香港 IP、重新询问内地 IP 和 SSH 信息。"
else
  echo "没有需要清除的记忆。"
fi
