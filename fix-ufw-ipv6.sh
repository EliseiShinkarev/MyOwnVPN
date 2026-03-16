#!/usr/bin/env bash
set -e

# fix-ufw-ipv6.sh — ensure UFW allows IPv6 on port 443 for Cloudflare origin connections
# Problem: if IPV6=no in /etc/default/ufw, rules added with `ufw allow 443/tcp`
# only cover IPv4, so Cloudflare's IPv6 connections to origin are silently dropped.

if [[ "$EUID" -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
fi

# Step 1: Enable IPv6 in UFW if disabled
if grep -q 'IPV6=no' /etc/default/ufw 2>/dev/null; then
    echo "Enabling IPv6 in UFW..."
    sed -i 's/IPV6=no/IPV6=yes/' /etc/default/ufw
    ufw disable
    ufw --force enable
else
    echo "IPv6 already enabled in UFW (or /etc/default/ufw not found)"
fi

# Step 2: Re-apply rules so IPv6 variants are added
ufw allow 22/tcp
ufw allow 443/tcp

echo ""
echo "UFW status:"
ufw status verbose | grep -E '443|22|Status'
echo ""
echo "IPv6 listener on :443:"
ss -tlnp | grep ':443'
