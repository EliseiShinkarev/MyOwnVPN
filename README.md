# MyOwnVPN — Личный VPN на VLESS-Reality

Скрипт для автоматической настройки личного VPN на базе VLESS-Reality (XRay). Протокол маскируется под обычный HTTPS-трафик и устойчив к блокировкам.

## Quick Start

### 1. Арендуйте VPS

Любой VPS с Ubuntu 22.04/24.04, 1 vCPU, 512MB RAM. Рекомендуемые локации: Финляндия, Нидерланды, Германия.

Подробнее о провайдерах — в [docs/VPS_GUIDE.md](docs/VPS_GUIDE.md).

### 2. Запустите скрипт

```bash
ssh root@ВАШ_IP

apt install -y git
git clone https://github.com/YOUR_USER/MyOwnVPN.git
cd MyOwnVPN
chmod +x setup.sh

```

Скрипт за ~2 минуты:
- Установит XRay-core
- Сгенерирует ключи
- Настроит файрвол и NTP
- Выдаст `vless://` ссылку и QR-код

### 3. Подключитесь

Скопируйте `vless://` ссылку или сканируйте QR-код:

| Устройство | Приложение | Как |
|-----------|-----------|-----|
| iPhone | [Streisand](https://apps.apple.com/app/streisand/id6450534064) | + → Добавить из буфера / QR |
| Mac | [V2Box](https://apps.apple.com/app/v2box-v2ray-client/id6446814690) или Streisand | Импорт → вставить ссылку |

Подробнее — в [docs/CLIENT_GUIDE.md](docs/CLIENT_GUIDE.md).

## CDN Bypass Mode

**Два способа включить:**
- При установке: `./setup.sh` → выберите `[2] Reality + CDN`
- На существующем сервере: `./setup-cdn.sh`

Требуется домен + бесплатный аккаунт Cloudflare. Подробнее — в [docs/CLOUDFLARE_GUIDE.md](docs/CLOUDFLARE_GUIDE.md).

## Что под капотом

- **Протокол**: VLESS + XTLS-Vision + Reality
- **CDN-режим**: VLESS + gRPC через Cloudflare (порт 443, nginx SNI-роутер)
- **Маскировка**: TLS 1.3, SNI `www.microsoft.com`, uTLS fingerprint `chrome`
- **Порт**: 443 (единственный внешний порт)
- **Файрвол**: только 22 (SSH) + 443 (nginx/VLESS)

## Файлы

```
setup.sh                        — скрипт установки
setup-cdn.sh                    — добавление CDN к существующей установке
configs/server-template.json    — шаблон конфига XRay (Reality)
configs/server-template-cdn.json — шаблон конфига XRay (Reality + CDN)
docs/VPS_GUIDE.md               — где арендовать VPS
docs/CLIENT_GUIDE.md            — настройка клиентов
docs/CLOUDFLARE_GUIDE.md        — настройка Cloudflare для CDN
```

## Troubleshooting

**XRay не запускается**
```bash
journalctl -u xray -n 30
xray run -test -c /usr/local/etc/xray/config.json
```

**Клиент подключается, но сайты не открываются**
- Проверьте время на сервере: `date -u` — Reality требует синхронизации ±2 минуты
- Проверьте файрвол: `ufw status` — порт 443 должен быть открыт

**Потеряли ссылку**
```bash
cat /root/vpn-credentials.txt
```

**Переустановка**
```bash
./setup.sh  # можно запускать повторно, перезапишет конфиг
```
