#!/usr/bin/env bash
# RMOS 用户服务器一键安装（Ubuntu / Debian 直接部署，systemd）
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/renminos/rmos-server/main/install.sh | sudo bash
#
# 重复执行同一条命令即为升级：只替换程序本体，配置（/opt/rmos-server/.env）与
# 数据（/opt/rmos-server/data）原样保留，旧程序备份为 rmos-server.bak。
#
# 可用环境变量（一般不需要）：
#   RMOS_VERSION=0.16.8.1   安装指定正式版（默认安装 GitHub 上最新正式版）
#   RMOS_ADMIN_USER / RMOS_ADMIN_PASS  仅首次安装时的管理员账号（默认 admin / change-me-now）
#   RMOS_FORCE_DIRECT=1     本机已有 RMOS 容器在运行时，仍强制执行直接部署
#
# 安装内容：/opt/rmos-server/rmos-server（程序）、.env（配置）、data/（数据 + 网页控制台 +
# 矿机安装脚本）、systemd 服务 rmos-server。网页控制台与矿机安装脚本都内置在程序里，
# 首次启动时自动展开到 data/，所以不需要任何额外发布包。
#
# 维护提示：本文件的源在 RMOS 主仓库 deploy/rmos-server-install.sh，发布后即为
# rmos-server 仓库 main 分支的 install.sh（见 deploy/DEPLOY_RECORD.md）。
set -euo pipefail

REPO="renminos/rmos-server"
APP_DIR="/opt/rmos-server"
SERVICE="rmos-server"
UNIT_FILE="/etc/systemd/system/${SERVICE}.service"
DEFAULT_PORT=18808

info() { echo "==> $*"; }
warn() { echo "!! $*" >&2; }
die() { echo "错误：$*" >&2; exit 1; }

# ---------- 1. 前置检查 ----------
[ "$(id -u)" -eq 0 ] || die "需要 root 权限，请这样运行：curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | sudo bash"

command -v systemctl >/dev/null 2>&1 || die "本机没有 systemd（systemctl），无法直接部署。容器或 NAS 请改用 Docker 方式（见 README）。"

if command -v curl >/dev/null 2>&1; then
  DOWNLOADER=curl
elif command -v wget >/dev/null 2>&1; then
  DOWNLOADER=wget
else
  die "需要 curl 或 wget：apt-get update && apt-get install -y curl"
fi

fetch() { # fetch <url> <dest-file>
  if [ "$DOWNLOADER" = curl ]; then
    curl -fL --retry 3 --connect-timeout 15 -o "$2" "$1"
  else
    wget -q -T 60 -O "$2" "$1"
  fi
}

fetch_stdout() { # fetch_stdout <url>
  if [ "$DOWNLOADER" = curl ]; then
    curl -fsSL --connect-timeout 5 --max-time 10 "$1"
  else
    wget -qO- -T 10 "$1"
  fi
}

# 同一台机器已经用 Docker 跑着 RMOS 时，不要再多装一份直接部署。
if [ "${RMOS_FORCE_DIRECT:-0}" != "1" ] && command -v docker >/dev/null 2>&1; then
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qi rmos; then
    die "检测到本机已有 RMOS 容器在运行，请继续用 Docker 方式维护；确实要再装一份直接部署请加 RMOS_FORCE_DIRECT=1"
  fi
fi

# ---------- 2. 取版本清单 ----------
TMP_DIR="$(mktemp -d /tmp/rmos-server-install.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
MANIFEST="$TMP_DIR/version.json"

if [ -n "${RMOS_VERSION:-}" ]; then
  MANIFEST_URL="https://github.com/${REPO}/releases/download/RMOS-UserServer-${RMOS_VERSION}/version.json"
  info "按指定版本 ${RMOS_VERSION} 安装"
else
  MANIFEST_URL="https://github.com/${REPO}/releases/latest/download/version.json"
fi

info "正在获取版本信息 ..."
fetch "$MANIFEST_URL" "$MANIFEST" 2>/dev/null || die "无法下载版本清单：${MANIFEST_URL}（请确认服务器能访问 GitHub）"

VERSION="$(awk -F'"' '/^[[:space:]]*"version"[[:space:]]*:/{print $4; exit}' "$MANIFEST")"
BIN_URL="$(awk -F'"' '/"linux-amd64"[[:space:]]*:/{f=1} f && /"url"[[:space:]]*:/{print $4; exit}' "$MANIFEST")"
BIN_SHA="$(awk -F'"' '/"linux-amd64"[[:space:]]*:/{f=1} f && /"sha256"[[:space:]]*:/{print $4; exit}' "$MANIFEST")"
[ -n "$VERSION" ] || die "版本清单解析失败：${MANIFEST_URL}"
[ -n "$BIN_URL" ] || BIN_URL="https://github.com/${REPO}/releases/download/RMOS-UserServer-${VERSION}/rmos-server-linux-amd64"

# ---------- 3. 下载并校验 ----------
BIN_TMP="$TMP_DIR/rmos-server"
info "正在下载 RMOS 用户服务器 ${VERSION}（约 11 MB）..."
fetch "$BIN_URL" "$BIN_TMP" 2>/dev/null || die "下载失败：${BIN_URL}"

if [ -n "$BIN_SHA" ] && command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA="$(sha256sum "$BIN_TMP" | awk '{print $1}')"
  [ "$ACTUAL_SHA" = "$BIN_SHA" ] || die "文件校验不通过，已中止安装（期望 ${BIN_SHA}，实际 ${ACTUAL_SHA}）"
  info "校验通过：sha256 ${ACTUAL_SHA}"
else
  warn "版本清单没有 sha256 或本机没有 sha256sum，已跳过校验"
fi

# ---------- 4. 安装 / 升级 ----------
mkdir -p "$APP_DIR/data"

if [ ! -f "$APP_DIR/.env" ]; then
  ADMIN_USER="${RMOS_ADMIN_USER:-admin}"
  ADMIN_PASS="${RMOS_ADMIN_PASS:-change-me-now}"
  cat > "$APP_DIR/.env" <<ENVEOF
RMOS_MODE=slave
RMOS_ENV=prod
RMOS_SLAVE_ADDR=:${DEFAULT_PORT}
RMOS_RIG_COMM_ADDR=:19809
RMOS_DEPLOY_MODE=direct
RMOS_DATA_PATH=${APP_DIR}/data/rmos.json
RMOS_ADMIN_USER=${ADMIN_USER}
RMOS_ADMIN_PASS=${ADMIN_PASS}
RMOS_HA_POLL_HOURS=12
ENVEOF
  chmod 0600 "$APP_DIR/.env"
  info "已生成配置 ${APP_DIR}/.env（管理员 ${ADMIN_USER}，登录后请立即改密码）"
else
  info "沿用已有配置 ${APP_DIR}/.env（端口、管理员、数据目录都保持不变）"
fi

# 服务文件先写好，此时还没动到正在运行的程序：这一步失败也不会影响现有服务。
mkdir -p "$(dirname "$UNIT_FILE")"
cat > "$UNIT_FILE" <<UNITEOF
[Unit]
Description=RMOS Ordinary Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=${APP_DIR}/rmos-server
Restart=always
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNITEOF
chmod 0644 "$UNIT_FILE"

systemctl stop "$SERVICE" >/dev/null 2>&1 || true
if [ -f "$APP_DIR/rmos-server" ]; then
  cp -f "$APP_DIR/rmos-server" "$APP_DIR/rmos-server.bak" 2>/dev/null || true
fi

# 先写同目录临时文件再原子改名：程序正在运行也不会触发 text file busy。
cp -f "$BIN_TMP" "$APP_DIR/.rmos-server.new"
chmod 0755 "$APP_DIR/.rmos-server.new"
mv -f "$APP_DIR/.rmos-server.new" "$APP_DIR/rmos-server"

info "正在启动服务 ${SERVICE} ..."
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1 || true
systemctl restart "$SERVICE" || die "服务启动失败，请查看：journalctl -u ${SERVICE} -n 50（上一版程序已备份在 ${APP_DIR}/rmos-server.bak）"

# ---------- 5. 等待网页控制台就绪 ----------
CONFIG_PORT="$(awk -F: '/^[[:space:]]*RMOS_SLAVE_ADDR=/{p=$2; gsub(/[^0-9]/, "", p); print p; exit}' "$APP_DIR/.env" 2>/dev/null || true)"
WEB_PORT=""
HEALTH=""
for p in "$CONFIG_PORT" "$DEFAULT_PORT" 18809; do
  if [ -z "$p" ]; then
    continue
  fi
  HEALTH=""
  for _ in $(seq 1 10); do
    HEALTH="$(fetch_stdout "http://127.0.0.1:${p}/healthz" 2>/dev/null || true)"
    if [ -n "$HEALTH" ]; then
      break
    fi
    sleep 1
  done
  if [ -n "$HEALTH" ]; then
    WEB_PORT="$p"
    break
  fi
done

IP_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
if [ -z "$IP_ADDR" ]; then
  IP_ADDR="<服务器IP>"
fi

echo ""
if [ -z "$WEB_PORT" ]; then
  warn "程序已安装，但暂时连不上网页控制台。请检查："
  echo "     systemctl status ${SERVICE}"
  echo "     journalctl -u ${SERVICE} -n 50"
  exit 1
fi

HEALTH_MODE="$(printf '%s' "$HEALTH" | sed -n 's/.*"mode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
HEALTH_VER="$(printf '%s' "$HEALTH" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

echo "==> 安装完成：RMOS 用户服务器 ${VERSION} 已运行（systemd 服务 ${SERVICE}）"
echo "    网页控制台： http://${IP_ADDR}:${WEB_PORT}"
echo "    首次打开请按引导完成初始化（需要服务器能访问外网）。"
echo "    配置： ${APP_DIR}/.env        数据： ${APP_DIR}/data"
echo "    再次执行本命令即为升级（配置与数据都会保留）。"
echo "    需要放通的端口：18808（控制台）、19808（平台通信）、19809（矿机通信）、21080-21089（客户端下载）。"

if [ "$HEALTH_VER" != "$VERSION" ]; then
  warn "网页控制台报告的版本是 ${HEALTH_VER:-未知}，与刚安装的 ${VERSION} 不一致：本机可能还有另一个 RMOS 实例占着这个端口。"
fi
if [ "$HEALTH_MODE" != "slave" ]; then
  warn "端口 ${WEB_PORT} 上运行的不是用户服务器（mode=${HEALTH_MODE:-未知}）。"
fi
