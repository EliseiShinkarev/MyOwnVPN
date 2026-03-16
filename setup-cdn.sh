#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# MyOwnVPN — добавление CDN-режима (VLESS + gRPC)
# Запускать от root на сервере с уже установленным MyOwnVPN
# ─────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

XRAY_CONFIG="/usr/local/etc/xray/config.json"
CREDENTIALS_FILE="/root/vpn-credentials.txt"
CDN_PORT=2053
CERT_DIR="/usr/local/etc/xray"

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ── 1. Проверки ──────────────────────────────

echo -e "\n${CYAN}══════════════════════════════════════${NC}"
echo -e "${CYAN}   MyOwnVPN — CDN Mode Setup (gRPC)${NC}"
echo -e "${CYAN}══════════════════════════════════════${NC}\n"

[[ $EUID -ne 0 ]] && error "Запустите скрипт от root: sudo bash setup-cdn.sh"

command -v xray &>/dev/null || error "XRay не установлен. Сначала запустите setup.sh"
[[ -f "$XRAY_CONFIG" ]] || error "Конфиг XRay не найден: ${XRAY_CONFIG}"
command -v jq &>/dev/null || { info "Устанавливаю jq..."; apt-get install -y -qq jq > /dev/null 2>&1; }
command -v qrencode &>/dev/null || { info "Устанавливаю qrencode..."; apt-get install -y -qq qrencode > /dev/null 2>&1; }
if ! command -v nginx &>/dev/null; then
    info "Устанавливаю nginx и модуль stream..."
    apt-get install -y -qq nginx libnginx-mod-stream > /dev/null 2>&1
fi

# Проверяем что gRPC inbound ещё не добавлен
if jq -e '.inbounds[] | select(.tag == "vless-grpc-cdn")' "$XRAY_CONFIG" > /dev/null 2>&1; then
    error "CDN inbound уже существует в конфиге. Удалите его вручную, если хотите переустановить."
fi

# Также проверяем старый WS inbound
if jq -e '.inbounds[] | select(.tag == "vless-ws-cdn")' "$XRAY_CONFIG" > /dev/null 2>&1; then
    warn "Обнаружен старый WS CDN inbound. Удалите его вручную перед добавлением gRPC."
    error "Старый CDN inbound (vless-ws-cdn) найден в конфиге."
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

# ── 4. Генерация самоподписанного сертификата ─

info "Генерация самоподписанного TLS-сертификата для gRPC..."

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "${CERT_DIR}/cdn-key.pem" \
    -out "${CERT_DIR}/cdn-cert.pem" \
    -days 3650 -nodes -subj "/CN=${CDN_DOMAIN}" 2>/dev/null

chmod 644 "${CERT_DIR}/cdn-key.pem"
info "Сертификат создан: ${CERT_DIR}/cdn-cert.pem"

# ── 5. Добавляем gRPC inbound в конфиг ────────

info "Перемещаю Reality inbound на 127.0.0.1:9443 (освобождаю порт 443 для nginx)..."
jq '(.inbounds[] | select(.port == 443) | .port) = 9443 |
    (.inbounds[] | select(.port == 9443) | .listen) = "127.0.0.1"' \
    "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp"
mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
info "Reality inbound перемещён на 127.0.0.1:9443"

info "Добавляю CDN inbound (gRPC) в конфиг XRay..."

GRPC_INBOUND=$(cat <<GEOF
{
  "listen": "127.0.0.1",
  "port": ${CDN_PORT},
  "protocol": "vless",
  "tag": "vless-grpc-cdn",
  "settings": {
    "clients": [{"id": "${CLIENT_UUID}"}],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "grpc",
    "security": "tls",
    "tlsSettings": {
      "certificates": [{
        "certificateFile": "${CERT_DIR}/cdn-cert.pem",
        "keyFile": "${CERT_DIR}/cdn-key.pem"
      }]
    },
    "grpcSettings": {
      "serviceName": "cdn"
    }
  },
  "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
}
GEOF
)

jq --argjson inbound "$GRPC_INBOUND" '.inbounds += [$inbound]' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp"
mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
info "Конфиг обновлён"

# ── 6. Настраиваем firewall ─────────────────

if command -v ufw &>/dev/null; then
    ufw allow 443/tcp > /dev/null 2>&1
    ufw deny ${CDN_PORT}/tcp > /dev/null 2>&1
    ufw deny 9443/tcp > /dev/null 2>&1
    info "UFW: порт 443 открыт; порты ${CDN_PORT} и 9443 закрыты снаружи"
else
    warn "UFW не найден — убедитесь что порт 443 открыт, а 2053 и 9443 закрыты"
fi

# ── 7. Настройка nginx SNI-роутера ───────────

info "Настраиваю nginx SNI-роутер..."

rm -f /etc/nginx/sites-enabled/default

if ! grep -q 'stream.d' /etc/nginx/nginx.conf; then
    echo 'include /etc/nginx/stream.d/*.conf;' >> /etc/nginx/nginx.conf
fi

mkdir -p /etc/nginx/stream.d
cat > /etc/nginx/stream.d/vpn-sni.conf <<NGINX_EOF
stream {
    map \$ssl_preread_server_name \$backend {
        ${CDN_DOMAIN}  127.0.0.1:${CDN_PORT};
        default        127.0.0.1:9443;
    }
    server {
        listen 443;
        proxy_pass \$backend;
        ssl_preread on;
        proxy_connect_timeout 5s;
        proxy_timeout 600s;
    }
}
NGINX_EOF

nginx -t 2>/dev/null || error "Ошибка в конфиге nginx. Проверьте: nginx -t"
info "Конфиг nginx создан"

# ── 8. Перезапуск XRay, затем nginx ─────────

info "Перезапускаю XRay..."
systemctl restart xray

sleep 2
if systemctl is-active --quiet xray; then
    info "XRay запущен и работает"
else
    error "XRay не запустился. Проверьте: journalctl -u xray -n 20"
fi

info "Запускаю nginx..."
systemctl enable nginx > /dev/null 2>&1
systemctl restart nginx

sleep 1
if systemctl is-active --quiet nginx; then
    info "nginx запущен и работает"
else
    error "nginx не запустился. Проверьте: journalctl -u nginx -n 20"
fi

# ── 9. Генерация CDN-ссылки и QR ─────────────

CDN_LINK="vless://${CLIENT_UUID}@${CDN_DOMAIN}:443?encryption=none&security=tls&sni=${CDN_DOMAIN}&type=grpc&serviceName=cdn&fp=chrome#MyVPN-CDN"

echo ""
echo -e "${CYAN}══════════════════════════════════════${NC}"
echo -e "${CYAN}   CDN-режим добавлен! (gRPC)${NC}"
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

# ── 10. Обновляем креденшалы ─────────────────

if [[ -f "$CREDENTIALS_FILE" ]]; then
    cat >> "$CREDENTIALS_FILE" <<CEOF

── CDN-режим (Cloudflare gRPC) ──
Домен:        ${CDN_DOMAIN}
Порт CDN:     443 (nginx SNI-роутер → XRay gRPC:${CDN_PORT})

CDN-ссылка:
${CDN_LINK}
CEOF
    info "Креденшалы дополнены в ${CREDENTIALS_FILE}"
fi

# ── Инструкция Cloudflare ────────────────────

echo -e "${YELLOW}Настройте Cloudflare:${NC}"
echo -e "  1. Домен ${CDN_DOMAIN} должен быть добавлен в Cloudflare"
echo -e "  2. DNS → A-запись: ${CDN_DOMAIN} → IP сервера, Proxy ON (оранжевое облако)"
echo -e "  3. SSL/TLS → режим ${CYAN}Full${NC} (НЕ Flexible!)"
echo -e "  4. Network → ${CYAN}gRPC: ON${NC}"
echo -e "  5. Подробнее: docs/CLOUDFLARE_GUIDE.md"
echo ""
echo -e "${YELLOW}Когда использовать:${NC}"
echo -e "  • ${CYAN}Reality-ссылка (MyVPN)${NC} — по умолчанию, быстрее"
echo -e "  • ${CYAN}CDN-ссылка (MyVPN-CDN)${NC} — если Reality не подключается (IP-блокировки)"
echo ""
