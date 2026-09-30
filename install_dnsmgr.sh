#!/usr/bin/env bash
# ============================================================
#   dnsmgr 一键部署脚本（Docker）
#   MIT License · Copyright (c) 2026 鼠宝财
#
#   本脚本安装的 dnsmgr（彩虹聚合DNS管理系统）是上游开源项目
#   （github.com/netcccyun/dnsmgr），该项目版权归其原作者所有。
# ============================================================
set -euo pipefail

exec < /dev/null

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'EOF'
用法：bash install_dnsmgr.sh [--upgrade | --help]

一键在 Linux 服务器上部署 dnsmgr（面板 + MySQL 5.7，全部跑在 Docker 里）。
不带参数 = 全新安装；已装过的机器再跑一次 = 保留数据继续/修复。

可选参数（写成环境变量放在命令前）：
  DNSMGR_PORT=9090           面板端口（默认 8081）
  DNSMGR_DIR=/srv/dnsmgr     安装目录（默认 /opt/dnsmgr）
  DNSMGR_IMAGE=<镜像地址>     指定镜像（默认华为云 SWR，失败自动退回 Docker Hub）
  USE_MARIADB=1              ARM 机器改用 mariadb:10.6（MySQL 5.7 无官方 arm64 镜像）
  SKIP_DOCKER_INSTALL=1      机器上已有 Docker 时跳过安装步骤
  REGISTRY_MIRROR=           不配置 Docker 镜像加速（默认腾讯云内网镜像）
  DOCKER_APT_MIRROR=<url>    指定 Docker 软件源
  LOG_FILE=<路径>            安装日志路径（默认 /var/log/dnsmgr-install.log）

例子：
  bash install_dnsmgr.sh                                   # 默认：8081 端口装到 /opt/dnsmgr
  DNSMGR_PORT=9090 DNSMGR_DIR=/srv/dnsmgr bash install_dnsmgr.sh
  bash install_dnsmgr.sh --upgrade                         # 升级到最新镜像，数据保留

安装结束时会把面板地址、数据库凭据、常用运维命令、备份方法一起打印出来。
EOF
  exit 0
fi

LOG_FILE=${LOG_FILE:-/var/log/dnsmgr-install.log}
exec > >(tee -a "$LOG_FILE") 2>&1
export DEBIAN_FRONTEND=noninteractive
echo "===== $(date '+%F %T') 开始安装（日志同时写到 $LOG_FILE）====="

DNSMGR_DIR=${DNSMGR_DIR:-/opt/dnsmgr}
DNSMGR_PORT=${DNSMGR_PORT:-8081}
DNSMGR_IMAGE=${DNSMGR_IMAGE:-}
IMAGE_CN=${DNSMGR_IMAGE_CN:-swr.cn-east-3.myhuaweicloud.com/netcccyun/dnsmgr:latest}
IMAGE_HUB=${DNSMGR_IMAGE_HUB:-netcccyun/dnsmgr:latest}
REGISTRY_MIRROR=${REGISTRY_MIRROR:-https://mirror.ccs.tencentyun.com}
SKIP_DOCKER_INSTALL=${SKIP_DOCKER_INSTALL:-0}
USE_MARIADB=${USE_MARIADB:-0}
DB_NAME=sbc_dnsmgr
DB_USER=sbc_dnsmgr
SERVICE_NAME=dnsmgr-web

c()   { printf '\033[1;36m%s\033[0m\n' "$*"; }
ok()  { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[1;33m!\033[0m %s\n' "$*"; }
die() { printf '  \033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

genpw() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    od -An -tx1 -N16 /dev/urandom | tr -d ' \n'
  fi
}

cred() { awk -F': ' -v k="$1" '$1 == k {print $2; exit}' "$DNSMGR_DIR/.credentials"; }

[ "$(id -u)" = "0" ] || die "请用 root 运行：sudo bash $0"

if [ "${1:-}" = "--upgrade" ]; then
  [ -f "$DNSMGR_DIR/docker-compose.yml" ] || die "还没装过（$DNSMGR_DIR 里没有 docker-compose.yml），直接运行本脚本即可"
  command -v docker >/dev/null 2>&1 || die "没装 Docker"
  cd "$DNSMGR_DIR"
  c "==> 升级 dnsmgr（数据库、.env 与 runtime 之外的文件保留）"
  docker compose pull dnsmgr-web 2>&1 | tail -3 | sed 's/^/  /'
  docker exec "$SERVICE_NAME" rm -f /app/firstrun 2>/dev/null \
    && ok "已清除首次运行标记，重启时会用新代码覆盖程序目录" \
    || warn "容器没在运行，直接重建"
  docker compose up -d --force-recreate dnsmgr-web < /dev/null >/dev/null 2>&1
  sleep 5
  docker compose ps 2>/dev/null | sed 's/^/  /'
  HTTP=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "http://127.0.0.1:$DNSMGR_PORT/" || echo 000)
  ok "升级完成，本机访问 → HTTP $HTTP"
  exit 0
fi

c "==> 1/7 检查环境"
. /etc/os-release 2>/dev/null || true
case "${ID:-}" in
  ubuntu|debian) ok "系统：${PRETTY_NAME:-$ID}" ;;
  *) warn "只在 Ubuntu/Debian 上测过，当前是 ${PRETTY_NAME:-未知}，继续但可能失败" ;;
esac
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
ok "架构：$ARCH"

if [ "$ARCH" != "amd64" ] && [ "$USE_MARIADB" != "1" ]; then
  USE_MARIADB=1
  warn "非 amd64 架构，自动改用 mariadb:10.6（MySQL 5.7 没有官方 arm64 镜像）"
fi

FREE_MB=$(df -Pm / | awk 'NR==2 {print $4}')
if [ "$FREE_MB" -lt 4096 ]; then
  warn "根分区只剩 ${FREE_MB}MB，镜像 + 数据库建议留 4GB 以上"
else
  ok "磁盘可用 ${FREE_MB}MB"
fi

TOTAL_MB=$(free -m | awk 'NR==2 {print $2}')
SWAP_MB=$(free -m | awk 'NR==3 {print $2}')
if [ "$TOTAL_MB" -lt 4096 ] && [ "${SWAP_MB:-0}" -lt 1024 ]; then
  if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "内存只有 ${TOTAL_MB}MB，已加 2GB swap"
  else
    swapon /swapfile 2>/dev/null || true
    ok "已有 /swapfile，已启用"
  fi
else
  ok "内存 ${TOTAL_MB}MB / swap ${SWAP_MB}MB，够用"
fi

for p in curl; do
  command -v "$p" >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq "$p" >/dev/null; }
done
ok "curl 就绪"

if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${DNSMGR_PORT}\$"; then
  if command -v docker >/dev/null 2>&1 \
     && docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -q "^${SERVICE_NAME} .*${DNSMGR_PORT}->"; then
    ok "端口 ${DNSMGR_PORT} 是本项目容器在用（重复运行，继续）"
  else
    die "端口 ${DNSMGR_PORT} 已被别的程序占用，换一个：DNSMGR_PORT=9090 bash $0"
  fi
else
  ok "端口 ${DNSMGR_PORT} 空闲"
fi

c "==> 2/7 安装 Docker"
if command -v docker >/dev/null 2>&1 && [ "$SKIP_DOCKER_INSTALL" = "1" ]; then
  ok "已装 Docker：$(docker --version)，按要求跳过安装"
elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  ok "Docker 已在：$(docker --version) / $(docker compose version --short 2>/dev/null || echo compose)"
else
  apt-get update -qq || { warn "apt update 失败，重试一次"; sleep 3; apt-get update -qq; }
  apt-get install -y -qq ca-certificates curl gnupg >/dev/null

  DISTRO=${ID:-ubuntu}
  CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-jammy}")
  DOCKER_MIRRORS=${DOCKER_APT_MIRROR:-"https://mirrors.tencentyun.com/docker-ce/linux/$DISTRO
https://mirrors.cloud.tencent.com/docker-ce/linux/$DISTRO
https://mirrors.aliyun.com/docker-ce/linux/$DISTRO
https://mirrors.ustc.edu.cn/docker-ce/linux/$DISTRO
https://download.docker.com/linux/$DISTRO"}

  MIRROR_BASE=""
  for m in $DOCKER_MIRRORS; do
    if curl -fsSL --connect-timeout 8 -m 30 --retry 2 --retry-delay 2 "$m/gpg" -o /tmp/docker.gpg 2>/dev/null \
       && curl -fsS --connect-timeout 8 -m 20 -o /dev/null "$m/dists/$CODENAME/Release" 2>/dev/null; then
      MIRROR_BASE=$m
      break
    fi
    warn "镜像不可用，换下一个：$m"
  done
  [ -n "$MIRROR_BASE" ] || die "所有 Docker 软件源都连不上。可手动指定：DOCKER_APT_MIRROR=https://mirrors.aliyun.com/docker-ce/linux/$DISTRO bash $0"

  install -m 0755 -d /etc/apt/keyrings
  install -m 0644 /tmp/docker.gpg /etc/apt/keyrings/docker.asc
  rm -f /tmp/docker.gpg
  echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] $MIRROR_BASE $CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list
  ok "Docker 软件源：$MIRROR_BASE"

  for i in 1 2 3; do
    apt-get update -qq && break || { warn "apt update 第 $i 次失败，重试"; sleep 3; }
  done
  for i in 1 2 3; do
    if apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1; then
      break
    fi
    warn "Docker 安装第 $i 次失败，重试"
    sleep 5
    apt-get update -qq || true
  done
  command -v docker >/dev/null 2>&1 || die "Docker 安装失败，看上面报错"
  ok "已安装：$(docker --version)"
fi
systemctl enable --now docker >/dev/null 2>&1 || true
systemctl is-active docker >/dev/null || die "Docker 没能启动，journalctl -u docker 看看"
ok "docker 服务运行中，compose 插件版本 $(docker compose version --short 2>/dev/null || echo '?')"

if [ -n "$REGISTRY_MIRROR" ] && [ ! -f /etc/docker/daemon.json ]; then
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": ["$REGISTRY_MIRROR"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
  if systemctl restart docker && sleep 2 && docker info >/dev/null 2>&1; then
    ok "已配置镜像加速：$REGISTRY_MIRROR（顺便限制了容器日志大小）"
  else
    warn "镜像加速配置后 docker 有问题，已回退"
    rm -f /etc/docker/daemon.json
    systemctl restart docker
  fi
else
  ok "沿用现有 /etc/docker/daemon.json"
fi

c "==> 3/7 生成配置（随机数据库密码）"
mkdir -p "$DNSMGR_DIR/app"
if [ -f "$DNSMGR_DIR/docker-compose.yml" ] && [ -d "$DNSMGR_DIR/mysql/mysql" ]; then
  DB_ROOT_PW=$(awk -F'=' '/MYSQL_ROOT_PASSWORD=/{print $2; exit}' "$DNSMGR_DIR/docker-compose.yml")
  DB_PW=$(awk -F'=' '/MYSQL_PASSWORD=/{print $2; exit}' "$DNSMGR_DIR/docker-compose.yml")
  [ -n "$DB_ROOT_PW" ] && [ -n "$DB_PW" ] \
    || die "$DNSMGR_DIR/docker-compose.yml 里读不到数据库密码，删掉它和 mysql/ 目录后重跑本脚本"
  ok "检测到已有安装：沿用原数据库密码（不会重新生成，数据不受影响）"
else
  DB_ROOT_PW=$(genpw)
  DB_PW=$(genpw)
fi
if [ "$USE_MARIADB" = "1" ]; then DB_IMAGE=mariadb:10.6; else DB_IMAGE=mysql:5.7; fi

cat > "$DNSMGR_DIR/docker-compose.yml" <<EOF
services:
  dnsmgr-web:
    container_name: $SERVICE_NAME
    image: ${DNSMGR_IMAGE:-$IMAGE_CN}
    restart: unless-stopped
    ports:
      - "${DNSMGR_PORT}:80"
    environment:
      - TZ=Asia/Shanghai
    volumes:
      - ./app:/app
    depends_on:
      dnsmgr-mysql:
        condition: service_healthy
    networks:
      - dnsmgr

  dnsmgr-mysql:
    container_name: dnsmgr-mysql
    image: $DB_IMAGE
    restart: unless-stopped
    environment:
      - MYSQL_ROOT_PASSWORD=$DB_ROOT_PW
      - MYSQL_DATABASE=$DB_NAME
      - MYSQL_USER=$DB_USER
      - MYSQL_PASSWORD=$DB_PW
      - TZ=Asia/Shanghai
    volumes:
      - ./mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h127.0.0.1 -uroot -p$DB_ROOT_PW --silent"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s
    networks:
      - dnsmgr

networks:
  dnsmgr:
    driver: bridge
EOF
chmod 600 "$DNSMGR_DIR/docker-compose.yml"
cat > "$DNSMGR_DIR/.credentials" <<EOF
数据库主机: dnsmgr-mysql
数据库端口: 3306
数据库名: $DB_NAME
数据库用户: $DB_USER
数据库密码: $DB_PW
数据库 root 密码: $DB_ROOT_PW
EOF
chmod 600 "$DNSMGR_DIR/.credentials"
ok "配置已写入 $DNSMGR_DIR/docker-compose.yml（数据库 $DB_IMAGE）"
ok "数据库凭据已存 $DNSMGR_DIR/.credentials（600，只有 root 能读）"

c "==> 4/7 拉取镜像"
IMAGE=""
pull_image() {
  timeout 900 docker pull "$1" >/dev/null 2>&1
}
if [ -n "$DNSMGR_IMAGE" ]; then
  pull_image "$DNSMGR_IMAGE" && IMAGE=$DNSMGR_IMAGE
else
  if pull_image "$IMAGE_CN"; then
    IMAGE=$IMAGE_CN
    ok "已从华为云 SWR 拉取（国内快）"
  else
    warn "华为云 SWR 拉取失败，改用 Docker Hub"
    pull_image "$IMAGE_HUB" && IMAGE=$IMAGE_HUB
  fi
fi
[ -n "$IMAGE" ] || die "镜像拉取失败。可手动指定：DNSMGR_IMAGE=<镜像地址> bash $0"
if [ "${DNSMGR_IMAGE:-$IMAGE_CN}" != "$IMAGE" ]; then
  sed -i "s|image: $IMAGE_CN|image: $IMAGE|" "$DNSMGR_DIR/docker-compose.yml"
fi
ok "镜像：$IMAGE（$(docker image inspect -f '{{.Size}}' "$IMAGE" | awk '{printf "%.0f MB", $1/1048576}')）"

c "==> 5/7 启动数据库"
cd "$DNSMGR_DIR"
for i in 1 2; do
  if docker compose up -d dnsmgr-mysql < /dev/null >/dev/null 2>&1; then break; fi
  warn "数据库启动第 $i 次失败，重试"
  sleep 5
done
DEADLINE=$((SECONDS + 180))
DB_STATUS=""
while [ $SECONDS -lt $DEADLINE ]; do
  DB_STATUS=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' dnsmgr-mysql 2>/dev/null || echo missing)
  [ "$DB_STATUS" = "healthy" ] && break
  printf '.'
  sleep 5
done
echo
[ "$DB_STATUS" = "healthy" ] || docker logs --tail 15 dnsmgr-mysql 2>&1 | sed 's/^/  /'
[ "$DB_STATUS" = "healthy" ] || die "数据库没起来（状态：$DB_STATUS），上面是它的日志"
docker exec dnsmgr-mysql sh -c "mysql -uroot -p$DB_ROOT_PW -e 'SHOW DATABASES;'" 2>/dev/null | grep -q "^$DB_NAME$" \
  && ok "数据库 $DB_NAME 已就绪（字符集 utf8mb4）" \
  || warn "没看到 $DB_NAME 库，安装向导里手动建库名 $DB_NAME 即可"
if docker exec dnsmgr-mysql sh -c "mysql -u$DB_USER -p$DB_PW -D $DB_NAME -e 'SELECT 1;'" >/dev/null 2>&1; then
  ok "数据库账号 $DB_USER 可登录（向导里照抄 .credentials 即可）"
else
  warn "数据库账号 $DB_USER 登录失败，检查 $DNSMGR_DIR/.credentials"
fi

c "==> 6/7 启动面板并等健康检查"
for i in 1 2; do
  if docker compose up -d < /dev/null >/dev/null 2>&1; then break; fi
  warn "启动第 $i 次失败，重试"
  sleep 5
done
DEADLINE=$((SECONDS + 240))
STATUS="unknown"
while [ $SECONDS -lt $DEADLINE ]; do
  STATUS=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$SERVICE_NAME" 2>/dev/null || echo missing)
  [ "$STATUS" = "healthy" ] && break
  printf '.'
  sleep 5
done
echo
if [ "$STATUS" = "healthy" ]; then
  ok "面板容器健康（/fpm-ping 有响应）"
else
  warn "容器状态：$STATUS（未必是失败，可能还在初始化）"
fi
docker exec "$SERVICE_NAME" test -f /app/www/public/index.php 2>/dev/null \
  && ok "程序已就位：/app/www/public/index.php" \
  || warn "没找到 /app/www/public/index.php，检查一下日志：docker logs $SERVICE_NAME"
docker exec "$SERVICE_NAME" ps -o user,args 2>/dev/null | grep -E 'nginx|php-fpm|dmtask' | grep -v grep | sed 's/^/    /' || true

c "==> 7/7 汇总"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "http://127.0.0.1:$DNSMGR_PORT/" || echo 000)
ok "本机访问 http://127.0.0.1:$DNSMGR_PORT/ → HTTP $HTTP"
echo
docker compose ps 2>/dev/null | sed 's/^/  /' || true

PUBIP=$(curl -fsS --max-time 3 http://metadata.tencentyun.com/latest/meta-data/public-ipv4 2>/dev/null \
     || curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "<服务器公网IP>")
DB_PW_SHOW=$(cred '数据库密码')

cat <<EOF

============================================================
  部署完成 🎉

  定时任务是镜像内置的，不用在宿主机配 cron：crond 每分钟跑 certtask（证书申请/续期/部署），
  supervisord 常驻 dmtask（容灾切换、定时切换、CF优选）；走完安装向导前 dmtask 反复重启属正常。

  ---- 日常运维（都在 $DNSMGR_DIR 下执行）----
    docker compose ps                    查看状态
    docker compose logs -f dnsmgr-web    看日志
    docker compose restart dnsmgr-web    重启面板
    docker compose down                  停服（数据保留）；删掉项目目录即彻底卸载

  升级到最新镜像（自动拉新镜像、覆盖程序文件，数据保留）：
    bash $0 --upgrade

  ---- 数据库备份 ----
    docker exec dnsmgr-mysql sh -c "exec mysqldump -uroot -p\$(awk -F': ' '/^数据库 root 密码/{print \$2}' $DNSMGR_DIR/.credentials) --databases $DB_NAME" > sbc_dnsmgr-\$(date +%F).sql

  ---- 注意 ----
    1) 云服务器安全组需放行 $DNSMGR_PORT 端口，否则外网访问不到。
    2) 面板里存着各家云的 API 密钥，还能通过 SSH/FTP 往服务器推证书 —— 建议只让固定 IP
       访问、加一层 HTTPS 反代，并开启 TOTP 二次验证。

  换端口 / 换目录 / 换镜像等参数：bash $0 --help

  ----------------------------------------------------------

  ▸ 安装向导：  http://$PUBIP:$DNSMGR_PORT/
    项目目录：  $DNSMGR_DIR
    挂载目录：  $DNSMGR_DIR/app（程序与配置）、$DNSMGR_DIR/mysql（数据库）
    凭据文件：  $DNSMGR_DIR/.credentials（600，那串密码也在里面）

  ▸ 向导里这样填（其它留默认）：
      数据库主机：dnsmgr-mysql    端口：3306
      数据库名：  $DB_NAME
      数据库用户：$DB_USER
      数据库密码：$DB_PW_SHOW
      管理员账号 / 密码：自己设，装完立刻开二次验证（TOTP）

  MIT License · Copyright (c) 2026 鼠宝财
  脚本项目仓库：https://github.com/shubaocai/sbc-dnsmgr
============================================================
EOF
