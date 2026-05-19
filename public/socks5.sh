#!/usr/bin/env bash
set -Euo pipefail

PORT="10086"
SOCKS_USER="daigua"
RUN_USER="threeproxy"
SERVICE_NAME="daigua-socks5"

CONFIG_DIR="/etc/3proxy"
CONFIG_FILE="${CONFIG_DIR}/daigua-socks5.cfg"
LOG_DIR="/var/log/3proxy"
INSTALL_LOG="/tmp/daigua-socks5-install.log"
INFO_FILE="/root/socks5-info.txt"
SYSCTL_FILE="/etc/sysctl.d/99-daigua-socks5.conf"
LIMITS_FILE="/etc/security/limits.d/99-daigua-socks5.conf"

THREEPROXY_BIN=""
BIN_SOURCE="package"

TOTAL_STEPS=13
CURRENT_STEP=0
LAST_STEP="初始化"

exec 3>&1 4>&2
exec >"$INSTALL_LOG" 2>&1

progress() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  LAST_STEP="$1"

  local msg="$1"
  local percent=$((CURRENT_STEP * 100 / TOTAL_STEPS))
  local filled=$((percent / 5))
  local empty=$((20 - filled))
  local fill=""
  local blank=""

  for ((i=0; i<filled; i++)); do fill="${fill}#"; done
  for ((i=0; i<empty; i++)); do blank="${blank}-"; done

  printf '[%02d/%02d] [%s%s] %3d%%  %s\n' \
    "$CURRENT_STEP" "$TOTAL_STEPS" "$fill" "$blank" "$percent" "$msg" >&3
}

fail() {
  {
    echo
    echo "SOCKS5 安装失败"
    echo "失败步骤：${LAST_STEP}"
    echo "日志文件：${INSTALL_LOG}"
    echo
    echo "最后 120 行日志："
    tail -n 120 "$INSTALL_LOG" 2>/dev/null || true
  } >&3
  exit 1
}

run() {
  "$@" || fail
}

if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 执行：sudo -i" >&3
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "当前系统没有 systemd，不支持此脚本。" >&3
  exit 1
fi

install_deps() {
  progress "安装依赖，可能需要 1-3 分钟"

  if command -v apt-get >/dev/null 2>&1; then
    run apt-get update -y

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      curl openssl ca-certificates iproute2 procps tar lsof \
      git build-essential libssl-dev || fail

    DEBIAN_FRONTEND=noninteractive apt-get install -y 3proxy || true

  elif command -v dnf >/dev/null 2>&1; then
    run dnf install -y \
      curl openssl openssl-devel ca-certificates iproute procps-ng tar lsof \
      git gcc make

  elif command -v yum >/dev/null 2>&1; then
    run yum install -y \
      curl openssl openssl-devel ca-certificates iproute procps-ng tar lsof \
      git gcc make

  else
    echo "不支持的系统，仅支持 Debian / Ubuntu / CentOS / Rocky / AlmaLinux" >&3
    exit 1
  fi
}

find_3proxy_bin() {
  THREEPROXY_BIN="$(command -v 3proxy 2>/dev/null || true)"

  if [ -z "$THREEPROXY_BIN" ] && [ -x /usr/local/bin/3proxy ]; then
    THREEPROXY_BIN="/usr/local/bin/3proxy"
  fi

  if [ -z "$THREEPROXY_BIN" ] && [ -x /usr/bin/3proxy ]; then
    THREEPROXY_BIN="/usr/bin/3proxy"
  fi
}

build_3proxy_if_needed() {
  progress "安装 3proxy，优先系统包，失败则自动编译"

  find_3proxy_bin

  if [ -n "$THREEPROXY_BIN" ]; then
    BIN_SOURCE="package"
    return 0
  fi

  BIN_SOURCE="built"

  rm -rf /tmp/3proxy-build /tmp/3proxy.tar.gz

  if ! git clone --depth=1 https://github.com/3proxy/3proxy.git /tmp/3proxy-build; then
    mkdir -p /tmp/3proxy-build
    run curl -L --connect-timeout 8 --max-time 90 \
      https://github.com/3proxy/3proxy/archive/refs/heads/master.tar.gz \
      -o /tmp/3proxy.tar.gz

    run tar -xzf /tmp/3proxy.tar.gz --strip-components=1 -C /tmp/3proxy-build
  fi

  cd /tmp/3proxy-build || fail
  run make -f Makefile.Linux

  if [ -x "/tmp/3proxy-build/bin/3proxy" ]; then
    run install -m 755 /tmp/3proxy-build/bin/3proxy /usr/local/bin/3proxy
  elif [ -x "/tmp/3proxy-build/src/3proxy" ]; then
    run install -m 755 /tmp/3proxy-build/src/3proxy /usr/local/bin/3proxy
  else
    echo "3proxy 编译成功但未找到可执行文件" >&3
    fail
  fi

  THREEPROXY_BIN="/usr/local/bin/3proxy"
  rm -rf /tmp/3proxy-build /tmp/3proxy.tar.gz
}

create_user() {
  progress "创建后台运行用户"

  if ! getent group "$RUN_USER" >/dev/null 2>&1; then
    groupadd -r "$RUN_USER" || true
  fi

  if ! id "$RUN_USER" >/dev/null 2>&1; then
    if [ -x /usr/sbin/nologin ]; then
      useradd -r -M -s /usr/sbin/nologin -g "$RUN_USER" "$RUN_USER" || fail
    else
      useradd -r -M -s /sbin/nologin -g "$RUN_USER" "$RUN_USER" || fail
    fi
  fi
}

stop_old_service() {
  progress "清理旧服务，避免端口冲突"

  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true

  systemctl stop 3proxy >/dev/null 2>&1 || true
  systemctl disable 3proxy >/dev/null 2>&1 || true
}

check_port() {
  progress "检查端口 10086 是否可用"

  if ss -lnt | awk '{print $4}' | grep -q ":${PORT}$"; then
    {
      echo "端口 ${PORT} 已被占用，无法继续。"
      echo
      echo "占用情况："
      ss -lntp | grep ":${PORT}" || true
      lsof -iTCP:${PORT} -sTCP:LISTEN -n -P || true
    } >&3
    exit 1
  fi
}

optimize_network() {
  progress "优化网络参数和后台连接能力"

  mkdir -p /etc/sysctl.d /etc/security/limits.d

  BBR_CONFIG=""
  if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    BBR_CONFIG="
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr"
  fi

  cat > "$SYSCTL_FILE" <<SYSCTL
fs.file-max = 1048576
net.core.somaxconn = 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_tw_reuse = 1
${BBR_CONFIG}
SYSCTL

  sysctl -p "$SYSCTL_FILE" || true

  cat > "$LIMITS_FILE" <<LIMITS
${RUN_USER} soft nofile 1048576
${RUN_USER} hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMITS
}

write_config() {
  progress "生成 SOCKS5 配置和随机密码"

  SOCKS_PASS="$(openssl rand -hex 12)"

  mkdir -p "$CONFIG_DIR" "$LOG_DIR"
  chown -R "$RUN_USER:$RUN_USER" "$LOG_DIR" || true

  cat > "$CONFIG_FILE" <<CONF
nserver 1.1.1.1
nserver 8.8.8.8
nserver 9.9.9.9
nscache 65536

timeouts 1 5 30 60 180 1800 15 60
maxconn 1000

log ${LOG_DIR}/daigua-socks5.log D
rotate 14

users ${SOCKS_USER}:CL:${SOCKS_PASS}
auth strong
allow ${SOCKS_USER}

socks -p${PORT} -i0.0.0.0

flush
CONF

  chown root:"$RUN_USER" "$CONFIG_FILE" || true
  chmod 640 "$CONFIG_FILE" || true

  echo "$BIN_SOURCE" > "${CONFIG_DIR}/.daigua-bin-source"
}

write_service() {
  progress "创建 systemd 后台保活服务"

  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<SERVICE
[Unit]
Description=Daigua 3proxy SOCKS5 Server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
ExecStart=${THREEPROXY_BIN} ${CONFIG_FILE}
Restart=always
RestartSec=2
LimitNOFILE=1048576
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
SERVICE

  run systemctl daemon-reload
  run systemctl enable "$SERVICE_NAME"

  if ! systemctl restart "$SERVICE_NAME"; then
    {
      echo "systemd 服务启动失败："
      journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
    } >&3
    fail
  fi
}

open_firewall() {
  progress "放行系统防火墙端口"

  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qi active; then
      ufw allow "${PORT}/tcp" || true
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    if systemctl is-active firewalld >/dev/null 2>&1; then
      firewall-cmd --permanent --add-port="${PORT}/tcp" || true
      firewall-cmd --reload || true
    fi
  fi
}

get_public_ip() {
  progress "获取服务器公网 IP"

  PUBLIC_IP=""

  set +e
  PUBLIC_IP="$(curl -4 -fsS --connect-timeout 3 --max-time 6 https://api.ipify.org 2>/dev/null)"
  [ -z "$PUBLIC_IP" ] && PUBLIC_IP="$(curl -4 -fsS --connect-timeout 3 --max-time 6 https://ifconfig.me 2>/dev/null)"
  [ -z "$PUBLIC_IP" ] && PUBLIC_IP="$(curl -4 -fsS --connect-timeout 3 --max-time 6 https://icanhazip.com 2>/dev/null | tr -d '\n')"
  [ -z "$PUBLIC_IP" ] && PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  set -e 2>/dev/null || true

  if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP="服务器公网IP"
  fi
}

write_uninstall() {
  progress "生成卸载脚本"

  cat > /root/uninstall_daigua_socks5.sh <<UNEOF
#!/usr/bin/env bash
set -e

systemctl stop ${SERVICE_NAME} >/dev/null 2>&1 || true
systemctl disable ${SERVICE_NAME} >/dev/null 2>&1 || true

rm -f /etc/systemd/system/${SERVICE_NAME}.service
systemctl daemon-reload >/dev/null 2>&1 || true

if [ -f "${CONFIG_DIR}/.daigua-bin-source" ] && grep -q built "${CONFIG_DIR}/.daigua-bin-source"; then
  rm -f "${THREEPROXY_BIN}"
fi

rm -f "${CONFIG_FILE}"
rm -f "${CONFIG_DIR}/.daigua-bin-source"
rm -f "${SYSCTL_FILE}"
rm -f "${LIMITS_FILE}"
rm -f "${INFO_FILE}"
rm -f /root/install_daigua_socks5.sh
rm -f /tmp/daigua-socks5-install.log

rm -f "${LOG_DIR}/daigua-socks5.log"*

userdel ${RUN_USER} >/dev/null 2>&1 || true

echo "Daigua SOCKS5 已卸载"
UNEOF

  chmod +x /root/uninstall_daigua_socks5.sh || true
}

final_check() {
  progress "检查服务状态"

  sleep 1

  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    {
      echo "服务未运行："
      journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
    } >&3
    fail
  fi

  if ! ss -lnt | awk '{print $4}' | grep -q ":${PORT}$"; then
    {
      echo "服务已启动，但端口 ${PORT} 未监听。"
      ss -lntp || true
      journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
    } >&3
    fail
  fi
}

main() {
  progress "检测系统环境"
  install_deps
  build_3proxy_if_needed
  create_user
  stop_old_service
  check_port
  optimize_network
  write_config
  write_service
  open_firewall
  get_public_ip
  write_uninstall
  final_check

  cat > "$INFO_FILE" <<INFO
SOCKS5 搭建完成

状态：运行中
地址：${PUBLIC_IP}
端口：${PORT}
用户名：${SOCKS_USER}
密码：${SOCKS_PASS}
协议：SOCKS5

快捷信息：
socks5://${SOCKS_USER}:${SOCKS_PASS}@${PUBLIC_IP}:${PORT}

测试命令：
curl -x socks5h://${SOCKS_USER}:${SOCKS_PASS}@${PUBLIC_IP}:${PORT} https://ipinfo.io/ip

后台保活：
systemctl status ${SERVICE_NAME} --no-pager
systemctl restart ${SERVICE_NAME}

日志：
journalctl -u ${SERVICE_NAME} -f
tail -f ${LOG_DIR}/daigua-socks5.log

安装日志：
${INSTALL_LOG}

卸载命令：
bash /root/uninstall_daigua_socks5.sh
INFO

  echo >&3
  cat "$INFO_FILE" >&3
}

main