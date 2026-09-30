#!/usr/bin/env bash
# 兼容旧地址：用户服务器一键安装脚本已经搬到 renminos/rmos-tools。
#
# README 里现在的命令（官方地址）：
#   curl -fsSL https://github.com/renminos/rmos-tools/releases/latest/download/rmos-server-install.sh | sudo bash
#
# 本文件只做转发，保证以前保存过
#   https://raw.githubusercontent.com/renminos/rmos-server/main/install.sh
# 这条旧命令的人依然能装上（脚本很少改动，放在 tools 仓库用固定地址分发）。
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 权限运行：curl ... | sudo bash" >&2
  exit 1
fi

URL="https://github.com/renminos/rmos-tools/releases/latest/download/rmos-server-install.sh"
TMP="$(mktemp /tmp/rmos-server-install.XXXXXX)"
trap 'rm -f "$TMP"' EXIT

if command -v curl >/dev/null 2>&1; then
  curl -fsSL --retry 3 --connect-timeout 15 -o "$TMP" "$URL" || { echo "错误：无法下载安装脚本 $URL" >&2; exit 1; }
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$TMP" "$URL" || { echo "错误：无法下载安装脚本 $URL" >&2; exit 1; }
else
  echo "错误：需要 curl 或 wget" >&2
  exit 1
fi

echo "==> 安装脚本已迁移到 renminos/rmos-tools，正在执行最新版本 ..."
bash "$TMP"
