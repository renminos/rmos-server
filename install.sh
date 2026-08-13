#!/usr/bin/env bash
# RMOS 用户服务器一键安装（Ubuntu 直接部署）
# 用法：curl -fsSL https://raw.githubusercontent.com/renminos/rmos-server/main/install.sh | sudo bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 权限运行：curl ... | sudo bash"
  exit 1
fi

API="https://api.github.com/repos/renminos/rmos-server/releases/latest"
TMP="$(mktemp -d /tmp/rmos-server-install.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

echo "==> 正在获取最新版本信息 ..."
if command -v curl >/dev/null 2>&1; then
  JSON="$(curl -fsSL "$API" || true)"
elif command -v wget >/dev/null 2>&1; then
  JSON="$(wget -qO- "$API" || true)"
else
  echo "错误：需要 curl 或 wget"
  exit 1
fi

TAG="$(printf '%s' "$JSON" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
VERSION="$(printf '%s' "$TAG" | sed 's/^RMOS-UserServer-//')"
if [ -z "$VERSION" ]; then
  echo "错误：无法解析最新版本号"
  exit 1
fi

URL="https://github.com/renminos/rmos-server/releases/download/${TAG}/rmos-server-${VERSION}-ubuntu.tar.gz"
ARCHIVE="$TMP/rmos-server.tar.gz"

echo "==> 正在下载 ${VERSION} ..."
if command -v curl >/dev/null 2>&1; then
  curl -fL "$URL" -o "$ARCHIVE"
elif command -v wget >/dev/null 2>&1; then
  wget -q "$URL" -O "$ARCHIVE"
fi

echo "==> 正在解压 ..."
tar -xzf "$ARCHIVE" -C "$TMP"

if [ ! -f "$TMP/ubuntu/install.sh" ]; then
  echo "错误：发布包结构不完整（缺少 ubuntu/install.sh）"
  exit 1
fi

echo "==> 开始安装 ..."
bash "$TMP/ubuntu/install.sh"

echo ""
echo "==> 安装完成，请访问 http://<服务器IP>:18808 完成首次初始化"
