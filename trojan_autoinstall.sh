#!/usr/bin/env bash
# ============================================================
# Xray Trojan + Domain TLS (acme.sh) One-Click Installer (v2)
# For: Debian 11/12 x64, Ubuntu 20.04/22.04 x64 (low-memory VPS friendly)
#
# ✅ 自动创建 Swap（fallocate 不支持则自动用 dd）
# ✅ 只需输入：域名 + 邮箱
# ✅ 自动检测域名 A 记录是否解析到本机公网 IPv4（需要 dig，脚本会安装）
# ✅ 自动申请/安装 Let's Encrypt 证书（acme.sh standalone）
# ✅ 自动配置 Xray (Trojan+TLS 443) + Nginx 回落(80)
# ✅ 自动生成 UUID 作为 Trojan 密码
# ✅ 自动输出 Trojan 分享链接
# ✅ 自动尝试放行 80/443（ufw / firewalld / iptables）
#
# 结合你最新遇到的问题，已做关键修复：
# ⭐ 修复 Xray 以 nobody 运行导致无法读取 /etc/xray/cert/private.key
#    -> 改为专用用户 xray，并自动调整证书目录权限与文件权限
# ⭐ 自动安装 dig（dnsutils），避免因缺少 dig 无法检测解析
# ⭐ 启动后强制验证 443 LISTEN，失败则输出诊断信息
#
# 使用：
#   sudo -i
#   bash trojan_xray_tls_oneclick_v2.sh 你的域名 你的邮箱
# 或：
#   sudo -i
#   bash trojan_xray_tls_oneclick_v2.sh   # 交互输入
# ============================================================

set -euo pipefail

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; NC="\033[0m"
log() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
die() { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "请用 root 执行：sudo -i 然后再运行脚本。"
  fi
}

detect_os() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
  else
    die "无法识别系统（缺少 /etc/os-release）。"
  fi

  OS_ID="${ID:-}"
  OS_VER="${VERSION_ID:-}"

  case "$OS_ID" in
    debian|ubuntu) ;;
    *) die "仅支持 Debian / Ubuntu。当前：$OS_ID $OS_VER" ;;
  esac
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl wget unzip socat cron ca-certificates jq lsof python3 openssl >/dev/null
  (apt-get install -y dnsutils >/dev/null) || (apt-get install -y bind9-dnsutils >/dev/null) || true
  ok "依赖安装完成（curl/wget/socat/cron/jq/lsof/python3/openssl + dig）。"
}

get_public_ip() {
  local ip
  ip="$(curl -4fsS https://api.ipify.org || true)"
  if [[ -z "$ip" ]]; then ip="$(curl -4fsS https://ifconfig.me || true)"; fi
  if [[ -z "$ip" ]]; then ip="$(curl -4fsS https://ipv4.icanhazip.com | tr -d '\n' || true)"; fi
  [[ -n "$ip" ]] || die "无法获取公网 IPv4（可能无法访问外网）。"
  echo "$ip"
}

domain_points_to_me() {
  local domain="$1"
  local myip="$2"
  command -v dig >/dev/null 2>&1 || die "dig 未安装，请执行 apt install dnsutils 后重试。"
  local ips
  ips="$(dig +short A "$domain" | tr '\n' ' ' | xargs || true)"
  [[ -n "$ips" ]] || return 1
  for i in $ips; do
    if [[ "$i" == "$myip" ]]; then return 0; fi
  done
  return 1
}

ensure_swap() {
  if swapon --show | grep -qE '^/'; then
    ok "已存在 Swap，跳过创建。"
    return 0
  fi

  local mem_mb
  mem_mb="$(free -m | awk '/^Mem:/{print $2}')"
  [[ -n "$mem_mb" ]] || mem_mb=1024

  local swap_mb
  if (( mem_mb <= 1024 )); then
    swap_mb=1024
  elif (( mem_mb <= 2048 )); then
    swap_mb=2048
  elif (( mem_mb <= 4096 )); then
    swap_mb=2048
  else
    swap_mb=4096
  fi

  log "未检测到 Swap，将创建 ${swap_mb}MB Swap（小内存 VPS 建议）…"
  swapoff /swapfile 2>/dev/null || true
  rm -f /swapfile

  if fallocate -l "${swap_mb}M" /swapfile 2>/dev/null; then
    ok "使用 fallocate 创建 swapfile 成功。"
  else
    warn "fallocate 不支持，改用 dd 创建（更通用但稍慢）。"
    dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb" status=progress
  fi

  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile

  if ! grep -qE '^/swapfile\s+swap\s+swap' /etc/fstab; then
    echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
  fi

  ok "Swap 已启用：$(swapon --show | awk 'NR==2{print $1, $2, $3}' || true)"
}

free_port_or_stop_web() {
  local port="$1"
  if ss -lntp 2>/dev/null | grep -qE ":${port}\s"; then
    local procs
    procs="$(lsof -iTCP:"$port" -sTCP:LISTEN -n -P 2>/dev/null | awk 'NR>1{print $1}' | sort -u | tr '\n' ' ' | xargs || true)"
    warn "端口 ${port} 已被占用（可能是：${procs:-unknown}）。尝试停止 nginx/apache2…"
    systemctl stop nginx 2>/dev/null || true
    systemctl disable nginx 2>/dev/null || true
    systemctl stop apache2 2>/dev/null || true
    systemctl disable apache2 2>/dev/null || true
  fi
  if ss -lntp 2>/dev/null | grep -qE ":${port}\s"; then
    die "端口 ${port} 仍被占用。请先释放端口再运行（ss -lntp | grep :${port}）。"
  fi
  ok "端口 ${port} 可用。"
}

open_firewall_ports() {
  log "尝试放行 80/443（仅当本机防火墙已启用时生效；云安全组仍可能需要手动放行）…"

  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qi "active"; then
      ufw allow 80/tcp >/dev/null || true
      ufw allow 443/tcp >/dev/null || true
      ok "ufw 已放行 80/443。"
    else
      warn "ufw 未启用，跳过。"
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    if systemctl is-active --quiet firewalld; then
      firewall-cmd --permanent --add-service=http >/dev/null || true
      firewall-cmd --permanent --add-service=https >/dev/null || true
      firewall-cmd --reload >/dev/null || true
      ok "firewalld 已放行 http/https。"
    fi
  fi

  if command -v iptables >/dev/null 2>&1; then
    local policy
    policy="$(iptables -S INPUT 2>/dev/null | head -n1 | awk '{print $3}' || true)"
    if [[ "${policy:-}" == "DROP" ]]; then
      warn "检测到 iptables INPUT 默认策略为 DROP，尝试添加 80/443 放行规则…"
      iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 80 -j ACCEPT
      iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 443 -j ACCEPT
      ok "iptables 已添加 80/443 放行规则（注意：重启后可能丢失，需自行持久化）。"
    fi
  fi

  warn "提示：云厂商安全组/控制台防火墙若未放行 TCP 80/443，外部仍会超时。"
}

ensure_xray_user() {
  if id xray >/dev/null 2>&1; then
    ok "xray 用户已存在。"
  else
    useradd -r -s /usr/sbin/nologin xray
    ok "已创建 xray 系统用户。"
  fi
}

install_acmesh() {
  if [[ -d /root/.acme.sh ]]; then
    ok "已检测到 acme.sh，跳过安装。"
    return 0
  fi
  curl -fsS https://get.acme.sh | sh
  ok "acme.sh 安装完成。"
}

issue_cert() {
  local domain="$1"
  local email="$2"

  /root/.acme.sh/acme.sh --set-account-email "$email" >/dev/null || true
  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null

  mkdir -p /etc/xray/cert

  log "申请证书（standalone 模式，需 80 端口外网可访问）…"
  /root/.acme.sh/acme.sh --issue -d "$domain" --standalone --keylength 2048

  /root/.acme.sh/acme.sh --install-cert -d "$domain" \
    --key-file       /etc/xray/cert/private.key \
    --fullchain-file /etc/xray/cert/fullchain.crt \
    --reloadcmd     "systemctl restart xray"

  ok "证书已安装到 /etc/xray/cert/"
}

install_xray() {
  log "安装 Xray（官方脚本）…"
  bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
  ok "Xray 安装完成。"
}

write_xray_config() {
  local domain="$1"
  local uuid="$2"

  local cfg_dir="/usr/local/etc/xray"
  mkdir -p "$cfg_dir"

  cat > "${cfg_dir}/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 443,
      "protocol": "trojan",
      "settings": {
        "clients": [
          { "password": "${uuid}", "email": "user@${domain}" }
        ],
        "fallbacks": [
          { "dest": 80 }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${domain}",
          "certificates": [
            {
              "certificateFile": "/etc/xray/cert/fullchain.crt",
              "keyFile": "/etc/xray/cert/private.key"
            }
          ]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "settings": {} }
  ]
}
EOF

  ok "已写入 Xray 配置：${cfg_dir}/config.json"
}

patch_xray_service_user() {
  local svc="/etc/systemd/system/xray.service"
  if [[ -f "$svc" ]]; then
    if grep -q '^User=' "$svc"; then
      sed -i 's/^User=.*/User=xray/' "$svc"
    else
      sed -i '/^\[Service\]/a User=xray' "$svc"
    fi
    if grep -q '^Group=' "$svc"; then
      sed -i 's/^Group=.*/Group=xray/' "$svc"
    else
      sed -i '/^User=xray/a Group=xray' "$svc"
    fi
    ok "已修复 xray.service：使用 User/Group = xray（避免 nobody 无法读私钥导致 443 不监听）。"
  else
    warn "未找到 $svc，跳过 service 修复。"
  fi
}

fix_cert_permissions_for_xray() {
  mkdir -p /etc/xray/cert
  chown -R xray:xray /etc/xray/cert
  chmod 700 /etc/xray/cert
  chmod 644 /etc/xray/cert/fullchain.crt 2>/dev/null || true
  chmod 600 /etc/xray/cert/private.key 2>/dev/null || true
  ok "证书权限已调整：/etc/xray/cert 归属 xray，private.key 仅 xray 可读。"
}

install_nginx_fallback() {
  log "安装并配置 Nginx（80 回落伪装）…"
  apt-get install -y nginx >/dev/null
  systemctl enable nginx >/dev/null || true

  cat > /etc/nginx/sites-available/default <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/html;
    index index.html;
    location / { try_files $uri $uri/ =404; }
}
EOF

  cat > /var/www/html/index.html <<'EOF'
<!doctype html>
<html>
<head><meta charset="utf-8"><title>Welcome</title></head>
<body><h1>It works.</h1></body>
</html>
EOF

  systemctl restart nginx
  ok "Nginx 已在 80 端口运行。"
}

generate_uuid() { cat /proc/sys/kernel/random/uuid; }

verify_listen_ports() {
  if ! ss -lntp 2>/dev/null | grep -qE ':443\s'; then
    warn "未检测到 443 监听。输出诊断信息："
    echo "---- ss -lntp ----"; ss -lntp || true
    echo "---- systemctl status xray ----"; systemctl status xray --no-pager || true
    echo "---- journalctl -u xray -n 50 ----"; journalctl -u xray -n 50 --no-pager || true
    die "Xray 未监听 443，无法提供 Trojan 服务。"
  fi
  ok "已确认：443 正在监听。"
}

print_result() {
  local domain="$1"
  local uuid="$2"
  local name="Trojan-${domain}"
  local enc_name
  enc_name="$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("${name}", safe=""))
PY
)"
  local link="trojan://${uuid}@${domain}:443?security=tls&sni=${domain}&alpn=http%2F1.1&type=tcp#${enc_name}"

  echo
  echo -e "${GREEN}================== 安装完成 ==================${NC}"
  echo -e "域名: ${domain}"
  echo -e "端口: 443"
  echo -e "密码(UUID): ${uuid}"
  echo -e "TLS: 开启"
  echo -e "SNI: ${domain}"
  echo
  echo -e "${GREEN}Trojan 分享链接（可直接导入 Shadowrocket）：${NC}"
  echo "$link"
  echo
  echo -e "${YELLOW}提示：若外部仍提示超时，请确认云厂商安全组已放行 TCP 443（以及 80）。${NC}"
}

main() {
  require_root
  detect_os

  local domain="${1:-}"
  local email="${2:-}"

  if [[ -z "$domain" ]]; then read -rp "请输入域名（已解析到本机）： " domain; fi
  if [[ -z "$email" ]]; then read -rp "请输入邮箱（用于 Let's Encrypt 证书）： " email; fi
  [[ -n "$domain" ]] || die "域名不能为空。"
  [[ -n "$email" ]] || die "邮箱不能为空。"

  apt_install
  ensure_swap

  local myip
  myip="$(get_public_ip)"
  log "本机公网 IPv4：$myip"

  if domain_points_to_me "$domain" "$myip"; then
    ok "域名 A 记录已指向本机：$domain → $myip"
  else
    local resolved
    resolved="$(dig +short A "$domain" | tr '\n' ' ' | xargs || true)"
    die "域名未解析到本机。\n当前解析：${resolved:-无}\n本机IP：$myip\n请先把域名 A 记录指向本机后再运行。"
  fi

  open_firewall_ports

  free_port_or_stop_web 80
  free_port_or_stop_web 443

  ensure_xray_user
  install_xray

  systemctl stop xray 2>/dev/null || true

  install_acmesh
  issue_cert "$domain" "$email"

  local uuid
  uuid="$(generate_uuid)"

  write_xray_config "$domain" "$uuid"

  patch_xray_service_user
  fix_cert_permissions_for_xray

  install_nginx_fallback

  systemctl daemon-reload
  systemctl enable xray >/dev/null || true
  systemctl restart xray

  verify_listen_ports
  print_result "$domain" "$uuid"
}

main "$@"
