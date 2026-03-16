#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# MyOwnVPN — миграция CDN на nginx SNI-роутер (порт 443)
# Запускать от root на сервере где уже есть CDN inbound (gRPC) в XRay
#
# Целевое состояние:
#   Internet → VPS:443 (nginx ssl_preread)
#              ├── SNI = cdn.DOMAIN  → 127.0.0.1:2053 (XRay gRPC)
#              └── SNI = *           → 127.0.0.1:9443 (XRay Reality)
# ─────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

XRAY_CONFIG="/usr/local/etc/xray/config.json"
CERT_DIR="/usr/local/etc/xray"
CDN_PORT=2053
REALITY_PORT=9443

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

echo -e "\n${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "${CYAN}   MyOwnVPN — Migrate CDN to nginx SNI router${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════${NC}\n"

# ── 1. Проверки ──────────────────────────────

[[ $EUID -ne 0 ]] && error "Запустите от root: sudo bash migrate-cdn-port.sh"

command -v xray &>/dev/null  || error "XRay не найден. Сначала запустите setup.sh"
[[ -f "$XRAY_CONFIG" ]]      || error "Конфиг XRay не найден: ${XRAY_CONFIG}"
[[ -f "${CERT_DIR}/cdn-cert.pem" ]] || error "Сертификат ${CERT_DIR}/cdn-cert.pem не найден. Сначала запустите setup-cdn.sh"

command -v jq &>/dev/null || { info "Устанавливаю jq..."; apt-get install -y -qq jq > /dev/null 2>&1; }

# ── 2. Читаем CDN_DOMAIN из сертификата ──────

info "Читаю CDN_DOMAIN из сертификата..."
CDN_DOMAIN=$(openssl x509 -in "${CERT_DIR}/cdn-cert.pem" -noout -subject 2>/dev/null \
    | grep -oP 'CN\s*=\s*\K[^\s,]+')
[[ -z "$CDN_DOMAIN" ]] && error "Не удалось извлечь CN из сертификата. Проверьте: openssl x509 -in ${CERT_DIR}/cdn-cert.pem -noout -subject"
info "CDN_DOMAIN: ${CDN_DOMAIN}"

# ── 3. Проверяем наличие обоих inbound ───────

info "Проверяю конфиг XRay..."

HAS_443=$(jq -e '.inbounds[] | select(.port == 443)' "$XRAY_CONFIG" > /dev/null 2>&1 && echo "yes" || echo "no")
HAS_2053=$(jq -e '.inbounds[] | select(.port == 2053)' "$XRAY_CONFIG" > /dev/null 2>&1 && echo "yes" || echo "no")
HAS_9443=$(jq -e '.inbounds[] | select(.port == 9443)' "$XRAY_CONFIG" > /dev/null 2>&1 && echo "yes" || echo "no")

# Проверяем что уже не в целевом состоянии
if [[ "$HAS_9443" == "yes" && "$HAS_443" == "no" ]]; then
    warn "Reality уже на порту 9443 (порт 443 свободен). Возможно, миграция уже была выполнена."
    if command -v nginx &>/dev/null && systemctl is-active --quiet nginx 2>/dev/null; then
        warn "nginx уже запущен. Если всё работает, повторная миграция не нужна."
        read -rp "$(echo -e "${YELLOW}Продолжить всё равно? (y/N): ${NC}")" CONFIRM
        [[ "${CONFIRM,,}" == "y" ]] || { echo "Отменено."; exit 0; }
    fi
fi

if [[ "$HAS_443" == "no" && "$HAS_9443" == "no" ]]; then
    error "В конфиге нет Reality inbound ни на порту 443, ни на 9443. Проверьте конфиг: ${XRAY_CONFIG}"
fi
if [[ "$HAS_2053" == "no" ]]; then
    error "CDN inbound (порт 2053) не найден в конфиге. Сначала запустите setup-cdn.sh"
fi

info "Конфиг выглядит корректно"

# ── 4. Обновляем XRay config ─────────────────

info "Обновляю XRay config: Reality 443 → 127.0.0.1:9443, CDN → 127.0.0.1:2053..."

cp "${XRAY_CONFIG}" "${XRAY_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
info "Резервная копия сохранена"

if [[ "$HAS_443" == "yes" ]]; then
    # Перемещаем Reality с 443 на 127.0.0.1:9443
    jq '(.inbounds[] | select(.port == 443) | .port) = 9443 |
        (.inbounds[] | select(.port == 9443) | .listen) = "127.0.0.1" |
        (.inbounds[] | select(.port == 2053) | .listen) = "127.0.0.1"' \
        "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp"
else
    # Reality уже на 9443, только убеждаемся что listen = 127.0.0.1
    jq '(.inbounds[] | select(.port == 9443) | .listen) = "127.0.0.1" |
        (.inbounds[] | select(.port == 2053) | .listen) = "127.0.0.1"' \
        "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp"
fi

mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
info "XRay config обновлён"

# ── 5. Устанавливаем nginx ────────────────────

if ! command -v nginx &>/dev/null; then
    info "Устанавливаю nginx и модуль stream..."
    apt-get install -y nginx libnginx-mod-stream > /dev/null 2>&1
    info "nginx установлен"
else
    info "nginx уже установлен"
fi

# ── 6. Настраиваем nginx SNI-роутер ──────────

info "Настраиваю nginx SNI-роутер..."

rm -f /etc/nginx/sites-enabled/default

# Добавляем include для stream.d если ещё не добавлен
if ! grep -q 'stream\.d' /etc/nginx/nginx.conf; then
    echo 'include /etc/nginx/stream.d/*.conf;' >> /etc/nginx/nginx.conf
    info "Добавлен include stream.d в nginx.conf"
fi

mkdir -p /etc/nginx/stream.d
cat > /etc/nginx/stream.d/vpn-sni.conf <<NGINX_EOF
stream {
    map \$ssl_preread_server_name \$backend {
        ${CDN_DOMAIN}  127.0.0.1:${CDN_PORT};
        default        127.0.0.1:${REALITY_PORT};
    }
    server {
        listen 443;
        listen [::]:443;
        proxy_pass \$backend;
        ssl_preread on;
        proxy_connect_timeout 5s;
        proxy_timeout 600s;
    }
}
NGINX_EOF

nginx -t 2>/dev/null || error "Ошибка конфига nginx. Проверьте: nginx -t"
info "nginx SNI-роутер настроен (${CDN_DOMAIN} → :${CDN_PORT}, * → :${REALITY_PORT})"

# ── 7. Файрвол ───────────────────────────────

if command -v ufw &>/dev/null; then
    ufw allow 22/tcp    > /dev/null 2>&1
    ufw allow 443/tcp   > /dev/null 2>&1
    ufw deny ${CDN_PORT}/tcp  > /dev/null 2>&1
    ufw deny ${REALITY_PORT}/tcp > /dev/null 2>&1
    info "UFW: 22 и 443 открыты; ${CDN_PORT} и ${REALITY_PORT} закрыты снаружи"
else
    warn "UFW не найден — вручную проверьте что 443 открыт, а ${CDN_PORT} и ${REALITY_PORT} закрыты"
fi

# ── 8. Перезапуск XRay, затем nginx ──────────
# Запускаем рестарт в фоне — systemctl restart xray может оборвать SSH-сессию
# (XRay участвует в routing), поэтому скрипт должен завершиться до рестарта.

systemctl enable nginx > /dev/null 2>&1

cat > /tmp/vpn_restart.sh <<'RESTART_EOF'
#!/bin/bash
sleep 2
systemctl restart xray
sleep 3
systemctl restart nginx
echo "$(date '+%H:%M:%S') xray=$(systemctl is-active xray) nginx=$(systemctl is-active nginx)" \
    >> /tmp/vpn_restart.log
RESTART_EOF
chmod +x /tmp/vpn_restart.sh
nohup bash /tmp/vpn_restart.sh > /tmp/vpn_restart.log 2>&1 &

info "Рестарт XRay и nginx запущен в фоне (через ~2 сек)"
info "Проверьте через 10 сек: systemctl status xray nginx"
info "Лог рестарта: cat /tmp/vpn_restart.log"

# ── 9. Итог ──────────────────────────────────

echo ""
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "${CYAN}   Настройка завершена. Сервисы перезапускаются в фоне (~5 сек).${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}Текущая схема:${NC}"
echo -e "  Internet → ${CYAN}ВАШ_IP:443${NC} (nginx SNI-роутер)"
echo -e "    SNI = ${CDN_DOMAIN}  →  127.0.0.1:${CDN_PORT}  (XRay gRPC CDN)"
echo -e "    SNI = *              →  127.0.0.1:${REALITY_PORT} (XRay Reality)"
echo ""
echo -e "${YELLOW}Верификация (подождите ~10 сек после завершения скрипта):${NC}"
echo -e "  cat /tmp/vpn_restart.log          # лог рестарта"
echo -e "  ss -tlnp | grep -E ':443|:2053|:9443'"
echo -e "  # Ожидание:"
echo -e "  #   127.0.0.1:9443   xray"
echo -e "  #   127.0.0.1:2053   xray"
echo -e "  #   0.0.0.0:443      nginx"
echo ""
echo -e "  nginx -t"
echo -e "  # Ожидание: syntax is ok"
echo ""
echo -e "${YELLOW}Верификация (с внешней машины):${NC}"
echo -e "  nc -zv ВАШ_IP 2053   # → Connection refused (порт закрыт снаружи)"
echo -e "  nc -zv ВАШ_IP 443    # → open (nginx слушает)"
echo ""
echo -e "${GREEN}Ссылки на телефоне менять НЕ нужно.${NC}"
echo -e "  Reality: SERVER_IP:443  — nginx прозрачно проксирует к XRay"
echo -e "  CDN:     ${CDN_DOMAIN}:443  — nginx по SNI роутит к gRPC"
echo ""
