#!/usr/bin/env bash
set -e
CONFIG="/etc/nginx/stream.d/vpn-sni.conf"

if grep -q '\[::\]:443' "$CONFIG"; then
    echo "Already has IPv6 listen, nothing to do."
    exit 0
fi

# Добавить listen [::]:443; после строки listen 443;
sed -i 's/listen 443;/listen 443;\n        listen [::]:443;/' "$CONFIG"

nginx -t
systemctl reload nginx
echo "Done. Checking listeners:"
ss -tlnp | grep ':443'
