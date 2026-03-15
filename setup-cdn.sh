#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# MyOwnVPN — добавление CDN-режима (VLESS + WebSocket)
# Запускать от root на сервере с уже установленным MyOwnVPN
# ─────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

XRAY_CONFIG="/usr/local/etc/xray/config.json"
CREDENTIALS_FILE="/root/vpn-credentials.txt"
CDN_PORT=2082

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ── 1. Проверки ──────────────────────────────

echo -e "\n${CYAN}══════════════════════════════════════${NC}"
echo -e "${CYAN}   MyOwnVPN — CDN Mode Setup${NC}"
echo -e "${CYAN}══════════════════════════════════════${NC}\n"

[[ $EUID -ne 0 ]] && error "Запустите скрипт от root: sudo bash setup-cdn.sh"

command -v xray &>/dev/null || error "XRay не установлен. Сначала запустите setup.sh"
[[ -f "$XRAY_CONFIG" ]] || error "Конфиг XRay не найден: ${XRAY_CONFIG}"
command -v jq &>/dev/null || { info "Устанавливаю jq..."; apt-get install -y -qq jq > /dev/null 2>&1; }
command -v qrencode &>/dev/null || { info "Устанавливаю qrencode..."; apt-get install -y -qq qrencode > /dev/null 2>&1; }

# Проверяем что WS inbound ещё не добавлен
if jq -e '.inbounds[] | select(.tag == "vless-ws-cdn")' "$XRAY_CONFIG" > /dev/null 2>&1; then
    error "CDN inbound уже существует в конфиге. Удалите его вручную, если хотите переустановить."
fi

# ── 2. Читаем UUID из конфига ─────────────────

CLIENT_UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")
[[ -z "$CLIENT_UUID" || "$CLIENT_UUID" == "null" ]] && error "Не удалось прочитать UUID из конфига"
info "UUID: ${CLIENT_UUID}"

# ── 3. Запрос домена ─────────────────────────

echo ""
read -rp "$(echo -e "${CYAN}Введите домен (привязанный к Cloudflare): ${NC}")" CDN_DOMAIN
[[ -z "$CDN_DOMAIN" ]] && error "Домен не может быть пустым"
info "Домен: ${CDN_DOMAIN}"

# ── 4. Генерация WS path ────────────────────

WS_PATH=$(openssl rand -hex 4)
info "WS path: /${WS_PATH}"

# ── 5. Добавляем WS inbound в конфиг ─────────

info "Добавляю CDN inbound в конфиг XRay..."

WS_INBOUND=$(cat <<WEOF
{
  "listen": "0.0.0.0",
  "port": ${CDN_PORT},
  "protocol": "vless",
  "tag": "vless-ws-cdn",
  "settings": {
    "clients": [{"id": "${CLIENT_UUID}"}],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "xhttp",
    "xhttpSettings": {"path": "/${WS_PATH}", "mode": "auto"}
  },
  "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
}
WEOF
)

jq --argjson inbound "$WS_INBOUND" '.inbounds += [$inbound]' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp"
mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
info "Конфиг обновлён"

# ── 6. Открываем порт ───────────────────────

if command -v ufw &>/dev/null; then
    ufw allow ${CDN_PORT}/tcp > /dev/null 2>&1
    info "UFW: порт ${CDN_PORT} открыт"
else
    warn "UFW не найден — откройте порт ${CDN_PORT}/tcp вручную"
fi

# ── 7. Перезапуск XRay ──────────────────────

info "Перезапускаю XRay..."
systemctl restart xray

sleep 2
if systemctl is-active --quiet xray; then
    info "XRay запущен и работает"
else
    error "XRay не запустился. Проверьте: journalctl -u xray -n 20"
fi

# ── 8. Генерация CDN-ссылки и QR ─────────────

CDN_LINK="vless://${CLIENT_UUID}@${CDN_DOMAIN}:443?encryption=none&security=tls&sni=${CDN_DOMAIN}&type=xhttp&host=${CDN_DOMAIN}&path=/${WS_PATH}&fp=chrome#MyVPN-CDN"

echo ""
echo -e "${CYAN}══════════════════════════════════════${NC}"
echo -e "${CYAN}   CDN-режим добавлен!${NC}"
echo -e "${CYAN}══════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}CDN-ссылка для подключения:${NC}"
echo ""
echo "$CDN_LINK"
echo ""

echo -e "${GREEN}QR-код:${NC}"
echo ""
qrencode -t ansiutf8 "$CDN_LINK"
echo ""

# ── 9. Обновляем креденшалы ──────────────────

if [[ -f "$CREDENTIALS_FILE" ]]; then
    cat >> "$CREDENTIALS_FILE" <<CEOF

── CDN-режим (Cloudflare) ──
Домен:        ${CDN_DOMAIN}
WS Path:      /${WS_PATH}
Порт CDN:     ${CDN_PORT} (origin) → 443 (Cloudflare)

CDN-ссылка:
${CDN_LINK}
CEOF
    info "Креденшалы дополнены в ${CREDENTIALS_FILE}"
fi

# ── Инструкция Cloudflare ────────────────────

echo -e "${YELLOW}Настройте Cloudflare:${NC}"
echo -e "  1. Домен ${CDN_DOMAIN} должен быть добавлен в Cloudflare"
echo -e "  2. DNS → A-запись: ${CDN_DOMAIN} → IP сервера, Proxy ON (оранжевое облако)"
echo -e "  3. SSL/TLS → режим ${CYAN}Flexible${NC}"
echo -e "  4. Подробнее: docs/CLOUDFLARE_GUIDE.md"
echo ""
echo -e "${YELLOW}Когда использовать:${NC}"
echo -e "  • ${CYAN}Reality-ссылка (MyVPN)${NC} — по умолчанию, быстрее"
echo -e "  • ${CYAN}CDN-ссылка (MyVPN-CDN)${NC} — если Reality не подключается (IP-блокировки)"
echo ""
