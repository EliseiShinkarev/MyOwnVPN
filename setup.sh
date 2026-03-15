#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# MyOwnVPN — автоматическая установка VLESS-Reality
# Запускать от root на свежем Ubuntu/Debian VPS
# ─────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

XRAY_CONFIG="/usr/local/etc/xray/config.json"
CREDENTIALS_FILE="/root/vpn-credentials.txt"
SNI_HOST="www.microsoft.com"
PORT=443

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ── 1. Проверки ──────────────────────────────

echo -e "\n${CYAN}══════════════════════════════════════${NC}"
echo -e "${CYAN}   MyOwnVPN — VLESS-Reality Setup${NC}"
echo -e "${CYAN}══════════════════════════════════════${NC}\n"

[[ $EUID -ne 0 ]] && error "Запустите скрипт от root: sudo bash setup.sh"

if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
    error "Поддерживаются только Ubuntu и Debian"
fi

info "Система: $(. /etc/os-release && echo "$PRETTY_NAME")"

# ── 1.1. Выбор режима ────────────────────────

echo ""
echo -e "${CYAN}Выберите режим установки:${NC}"
echo -e "  [1] Только Reality (по умолчанию)"
echo -e "  [2] Reality + CDN (обход IP-блокировок через Cloudflare)"
echo ""
read -rp "$(echo -e "${CYAN}Ваш выбор [1/2]: ${NC}")" MODE_CHOICE
MODE_CHOICE="${MODE_CHOICE:-1}"

CDN_ENABLED=false
CDN_DOMAIN=""
WS_PATH=""

if [[ "$MODE_CHOICE" == "2" ]]; then
    CDN_ENABLED=true
    echo ""
    read -rp "$(echo -e "${CYAN}Введите домен (привязанный к Cloudflare): ${NC}")" CDN_DOMAIN
    [[ -z "$CDN_DOMAIN" ]] && error "Домен не может быть пустым"
    WS_PATH=$(openssl rand -hex 4)
    info "CDN-режим: домен ${CDN_DOMAIN}, WS path /${WS_PATH}"
fi

# ── 2. Обновление и зависимости ──────────────

info "Обновление системы и установка зависимостей..."
export DEBIAN_FRONTEND=noninteractive
apt-mark hold openssh-server > /dev/null 2>&1
apt-get update -qq
apt-get upgrade -y -qq
apt-mark unhold openssh-server > /dev/null 2>&1
apt-get install -y -qq curl openssl jq qrencode > /dev/null 2>&1
info "Зависимости установлены"

# ── 3. Установка XRay ────────────────────────

if command -v xray &>/dev/null; then
    warn "XRay уже установлен, обновляю..."
fi

info "Устанавливаю XRay-core..."
bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
command -v xray &>/dev/null || error "Не удалось установить XRay"
info "XRay установлен: $(xray version | head -1)"

# ── 4. Генерация ключей ──────────────────────

info "Генерация ключей..."

CLIENT_UUID=$(xray uuid)

X25519_OUTPUT=$(xray x25519 2>&1)
# v25-: "Private key: ... / Public key: ..."
# v26+: "PrivateKey: ... / Password: ..."
PRIVATE_KEY=$(echo "$X25519_OUTPUT" | awk '/PrivateKey|Private key/{print $NF}')
PUBLIC_KEY=$(echo "$X25519_OUTPUT" | awk '/Public key|Password/{print $NF}')

[[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]] && error "Не удалось распарсить xray x25519. Вывод:\n${X25519_OUTPUT}"

SHORT_ID=$(openssl rand -hex 4)

info "UUID:       ${CLIENT_UUID}"
info "Short ID:   ${SHORT_ID}"

# ── 5. Определение IP сервера ────────────────

SERVER_IP=$(curl -s4 https://ifconfig.me || curl -s4 https://api.ipify.org || curl -s4 https://icanhazip.com)
[[ -z "$SERVER_IP" ]] && error "Не удалось определить IP сервера"
info "IP сервера: ${SERVER_IP}"

# ── 6. Запись конфига XRay ────────────────────

info "Создаю конфиг XRay..."
mkdir -p "$(dirname "$XRAY_CONFIG")"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ "$CDN_ENABLED" == true ]]; then
    TEMPLATE="$SCRIPT_DIR/configs/server-template-cdn.json"
else
    TEMPLATE="$SCRIPT_DIR/configs/server-template.json"
fi

if [[ -f "$TEMPLATE" ]]; then
    sed -e "s|__UUID__|${CLIENT_UUID}|g" \
        -e "s|__PRIVATE_KEY__|${PRIVATE_KEY}|g" \
        -e "s|__SNI_HOST__|${SNI_HOST}|g" \
        -e "s|__SHORT_ID__|${SHORT_ID}|g" \
        -e "s|__WS_PATH__|${WS_PATH}|g" \
        "$TEMPLATE" > "$XRAY_CONFIG"
else
    warn "Шаблон не найден, создаю конфиг напрямую..."
    cat > "$XRAY_CONFIG" <<XEOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${CLIENT_UUID}", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${SNI_HOST}:443",
        "xver": 0,
        "serverNames": ["${SNI_HOST}"],
        "privateKey": "${PRIVATE_KEY}",
        "shortIds": ["${SHORT_ID}"]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
  }],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
XEOF
fi

info "Конфиг записан в ${XRAY_CONFIG}"

# ── 7. Файрвол ───────────────────────────────

info "Настраиваю файрвол..."
if command -v ufw &>/dev/null; then
    ufw allow 22/tcp > /dev/null 2>&1
    ufw allow 443/tcp > /dev/null 2>&1
    if [[ "$CDN_ENABLED" == true ]]; then
        ufw allow 2082/tcp > /dev/null 2>&1
    fi
    ufw --force enable > /dev/null 2>&1
    if [[ "$CDN_ENABLED" == true ]]; then
        info "UFW: открыты порты 22 (SSH), 443 (VLESS) и 2082 (CDN)"
    else
        info "UFW: открыты порты 22 (SSH) и 443 (VLESS)"
    fi
else
    warn "UFW не найден, пропускаю настройку файрвола"
fi

# ── 8. Синхронизация времени ──────────────────

info "Синхронизация времени (NTP)..."
timedatectl set-ntp true 2>/dev/null || true
if command -v chronyc &>/dev/null; then
    chronyc makestep > /dev/null 2>&1 || true
elif command -v ntpd &>/dev/null; then
    ntpd -gq > /dev/null 2>&1 || true
fi
info "Время: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# ── 9. Запуск XRay ───────────────────────────

info "Запускаю XRay..."
systemctl daemon-reload
systemctl enable xray > /dev/null 2>&1
systemctl restart xray

sleep 2
if systemctl is-active --quiet xray; then
    info "XRay запущен и работает"
else
    error "XRay не запустился. Проверьте: journalctl -u xray -n 20"
fi

# ── 10. Генерация ссылки и QR ─────────────────

VLESS_LINK="vless://${CLIENT_UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI_HOST}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#MyVPN"

if [[ "$CDN_ENABLED" == true ]]; then
    CDN_LINK="vless://${CLIENT_UUID}@${CDN_DOMAIN}:443?encryption=none&security=tls&sni=${CDN_DOMAIN}&type=httpupgrade&host=${CDN_DOMAIN}&path=/${WS_PATH}&fp=chrome#MyVPN-CDN"
fi

echo ""
echo -e "${CYAN}══════════════════════════════════════${NC}"
echo -e "${CYAN}   Установка завершена!${NC}"
echo -e "${CYAN}══════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}Reality-ссылка для подключения:${NC}"
echo ""
echo "$VLESS_LINK"
echo ""

echo -e "${GREEN}QR-код (сканируйте в Streisand / V2Box):${NC}"
echo ""
qrencode -t ansiutf8 "$VLESS_LINK"
echo ""

if [[ "$CDN_ENABLED" == true ]]; then
    echo -e "${GREEN}CDN-ссылка (через Cloudflare):${NC}"
    echo ""
    echo "$CDN_LINK"
    echo ""
    echo -e "${GREEN}QR-код CDN:${NC}"
    echo ""
    qrencode -t ansiutf8 "$CDN_LINK"
    echo ""
fi

# ── 11. Сохранение креденшалов ────────────────

cat > "$CREDENTIALS_FILE" <<CEOF
═══════════════════════════════════
  MyOwnVPN — Credentials
  $(date '+%Y-%m-%d %H:%M')
═══════════════════════════════════

Server IP:    ${SERVER_IP}
Port:         ${PORT}
Protocol:     VLESS-Reality
UUID:         ${CLIENT_UUID}
Public Key:   ${PUBLIC_KEY}
Private Key:  ${PRIVATE_KEY}
Short ID:     ${SHORT_ID}
SNI:          ${SNI_HOST}
Fingerprint:  chrome
Flow:         xtls-rprx-vision

── Ссылка для подключения ──
${VLESS_LINK}

── Клиенты ──
iPhone:  Streisand (App Store) — вставить ссылку или QR
Mac:     V2Box / Streisand — вставить ссылку
CEOF

if [[ "$CDN_ENABLED" == true ]]; then
    cat >> "$CREDENTIALS_FILE" <<CEOF

── CDN-режим (Cloudflare) ──
Домен:        ${CDN_DOMAIN}
WS Path:      /${WS_PATH}
Порт CDN:     2082 (origin) → 443 (Cloudflare)

CDN-ссылка:
${CDN_LINK}
CEOF
fi

chmod 600 "$CREDENTIALS_FILE"
info "Креденшалы сохранены в ${CREDENTIALS_FILE}"

echo ""
echo -e "${YELLOW}Следующие шаги:${NC}"
echo -e "  1. Скопируйте ссылку или сканируйте QR-код"
echo -e "  2. На iPhone: откройте Streisand → + → вставьте ссылку"
echo -e "  3. На Mac: откройте V2Box → импорт → вставьте ссылку"

if [[ "$CDN_ENABLED" == true ]]; then
    echo ""
    echo -e "${YELLOW}Настройте Cloudflare:${NC}"
    echo -e "  4. Домен ${CDN_DOMAIN} должен быть добавлен в Cloudflare"
    echo -e "  5. DNS → A-запись: ${CDN_DOMAIN} → ${SERVER_IP}, Proxy ON (оранжевое облако)"
    echo -e "  6. SSL/TLS → режим ${CYAN}Flexible${NC}"
    echo -e "  7. Подробнее: docs/CLOUDFLARE_GUIDE.md"
    echo ""
    echo -e "${YELLOW}Когда какую ссылку использовать:${NC}"
    echo -e "  • ${CYAN}MyVPN (Reality)${NC} — по умолчанию, быстрее"
    echo -e "  • ${CYAN}MyVPN-CDN${NC} — если Reality не подключается (IP-блокировки)"
fi
echo ""
