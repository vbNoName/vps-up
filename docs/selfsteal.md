# Selfsteal: свой сайт и сертификат для Reality (3x-ui)

Скрипт [setup-selfsteal.sh](../scripts/setup-selfsteal.sh) готовит серверную часть схемы «selfsteal»:
Reality-inbound на 443 маскируется не под чужой сайт, а под ваш собственный сайт на этом же сервере
с настоящим сертификатом Let's Encrypt. Панель 3x-ui открывается по секретному пути того же домена.

```
клиент ──► :443 (Xray, Reality)
             ├─ свой клиент ─────────► VPN
             └─ чужой / зонд / браузер ─► 127.0.0.1:8443 (nginx)
                                            ├─ /              → сайт-заглушка
                                            └─ /<panel-path>/ → 127.0.0.1:<panel-port> (панель 3x-ui)
```

## Что делает скрипт

1. Предпроверки: root, Debian/Ubuntu, установлена 3x-ui, параметры корректны,
   A-запись домена совпадает с публичным IP сервера, порт 80 свободен (или занят самим nginx).
1. Ставит недостающие пакеты: `nginx`, `certbot`, `curl`.
1. Кладёт заглушку [site/dev-stub.html](../site/dev-stub.html) в `/var/www/site/index.html`
   (только если файла ещё нет или указан `--force-site`).
1. Убирает дефолтный сайт nginx `/etc/nginx/sites-enabled/default` (с бэкапом).
1. Пишет `/etc/nginx/conf.d/site.conf` в два этапа: сначала только `:80` для проверки Let's Encrypt,
   затем выпускает сертификат `certbot certonly --webroot`, затем полный конфиг с `127.0.0.1:8443`.
   Каждая запись проверяется `nginx -t`, при ошибке файл откатывается.
1. Ставит хук `/etc/letsencrypt/renewal-hooks/deploy/nginx.sh` (перезагрузка nginx после продления)
   и проверяет продление `certbot renew --dry-run`.
1. Проверяет, что nginx на 8443 отдаёт сайт и проксирует панель.
1. Печатает отчёт по шагам и список того, что нужно сделать вручную.

Скрипт идемпотентный: повторный запуск ничего не ломает и не дублирует. Любой изменённый файл
сначала копируется в `/root/vps-up-backup-<дата>/` с сохранением полного пути.

## Чего скрипт намеренно НЕ делает

* не трогает inbound'ы и клиентов 3x-ui, БД панели (`/etc/x-ui/x-ui.db`) и конфиг Xray;
* не меняет настройки панели (порт, путь, listen IP, пути сертификата): это делается вручную в веб-интерфейсе;
* не трогает файрвол (ufw, iptables, nftables).

Порт и путь панели скрипт может только прочитать (`/usr/local/x-ui/x-ui setting -show`), если они не переданы флагами.

## Требования

* Debian/Ubuntu с systemd, доступ root или sudo.
* Установлена [3x-ui](https://github.com/MHSanaei/3x-ui), в панели задан секретный URI-путь (не `/`).
* Свой домен для каждого сервера, A-запись ведёт на IP этого сервера.
* Если домен на Cloudflare, облако у записи **серое** (DNS only). С оранжевым облаком
  не выпустится сертификат и не заработает Reality.
* Порт 80 свободен (или занят nginx) и открыт снаружи: он нужен Let's Encrypt для выпуска и продления.
* Порт 8443 на 127.0.0.1 свободен.

## Запуск

Сначала имеет смысл посмотреть план без изменений: `--dry-run`.

Из клона репозитория (заглушка берётся локально из `site/dev-stub.html`):
```shell
git clone https://github.com/vbNoName/vps-up.git && cd vps-up
```
```shell
sudo bash scripts/setup-selfsteal.sh --domain vpn.example.com --panel-port 2053 --panel-path /secret-path/ --email admin@example.com --dry-run
```
```shell
sudo bash scripts/setup-selfsteal.sh --domain vpn.example.com --panel-port 2053 --panel-path /secret-path/ --email admin@example.com
```

Одной командой, без клона (заглушка скачивается по `--site-url`):
```shell
curl -fsSL https://raw.githubusercontent.com/vbNoName/vps-up/main/scripts/setup-selfsteal.sh | sudo bash -s -- --domain vpn.example.com --panel-port 2053 --panel-path /secret-path/ --email admin@example.com
```

Если `--panel-port` и `--panel-path` не указать, скрипт попробует прочитать их из настроек панели.
Если не получится, он остановится и попросит указать флаги.

Параметры можно передать и переменными окружения. `sudo` по умолчанию их не пропускает,
поэтому пишите их после `sudo`:
```shell
sudo DOMAIN=vpn.example.com PANEL_PORT=2053 PANEL_PATH=/secret-path/ bash scripts/setup-selfsteal.sh
```

### Параметры

| Флаг                   | Переменная     | По умолчанию                                            | Описание                                                                   |
|------------------------|----------------|---------------------------------------------------------|----------------------------------------------------------------------------|
| `--domain <домен>`     | `DOMAIN`       | —                                                       | Домен этого сервера, A-запись → IP сервера. **Обязательный.**             |
| `--panel-port <порт>`  | `PANEL_PORT`   | из `x-ui setting -show`                                 | Порт, на котором слушает 3x-ui (куда nginx проксирует).                    |
| `--panel-path </путь/>`| `PANEL_PATH`   | из `x-ui setting -show`                                 | URI-путь панели, слеши с обеих сторон: `/secret-path/`.                    |
| `--email <email>`      | `EMAIL`        | без email                                               | Email для Let's Encrypt. Без него `--register-unsafely-without-email`.     |
| `--site-url <url>`     | `SITE_URL`     | локальный `site/dev-stub.html`, иначе raw-ссылка на него | Откуда взять HTML-заглушку.                                                |
| `--force-site`         | `FORCE_SITE=1` | выкл.                                                   | Перезаписать `/var/www/site/index.html`, даже если он уже есть.           |
| `--dry-run`            | `DRY_RUN=1`    | выкл.                                                   | Ничего не менять, только показать план (и итоговый конфиг nginx).         |
| `-y`, `--yes`          | `ASSUME_YES=1` | выкл.                                                   | Без вопросов. При несовпадении DNS продолжить с предупреждением.          |
| `-h`, `--help`         |                |                                                         | Справка.                                                                   |

Raw-ссылка на заглушку по умолчанию: `https://raw.githubusercontent.com/vbNoName/vps-up/main/site/dev-stub.html`.
Свою страницу можно просто положить в `/var/www/site/index.html`: без `--force-site` скрипт её не тронет.

## Что сделать вручную

Скрипт печатает этот список в конце работы, уже со своим доменом, портом и путём.
Ниже `<domain>`, `<panel-port>`, `<panel-path>` — ваши значения.

1) В панели 3x-ui («Настройки панели → Панель → Сертификаты»): очистить оба поля путей сертификата
   (публичный и приватный ключ), сохранить, перезапустить панель.
   Порт и URI-путь панели должны совпадать с `--panel-port` и `--panel-path`.

1) Проверить, что панель открывается по `https://<domain><panel-path>`
   (через 443 это заработает после следующего шага).

1) Изменить Reality inbound на 443:
   * Target (dest) = `127.0.0.1:8443`
   * SNI (serverNames) = `<domain>`
   * uTLS fingerprint = `chrome`
   * Xver = `0`

   Ключи и Short IDs не менять, flow у клиентов `xtls-rprx-vision`.
   Сохранить, при необходимости перезапустить Xray.

1) Проверить снаружи: `https://<domain>/` показывает сайт с валидным сертификатом,
   `https://<domain><panel-path>` открывает панель.

1) Обновить клиентов: SNI = `<domain>`, fingerprint = `chrome`, flow = `xtls-rprx-vision`, порт 443.
   Проще всего заново импортировать ссылку из панели.

1) Опционально, но рекомендуется: в настройках панели поставить Listen IP = `127.0.0.1`
   (nginx продолжает ходить на панель по 127.0.0.1) и проверить:
   ```shell
   sudo ss -tlnp | grep <panel-port>
   ```

1) Порт панели снаружи больше не нужен: его можно закрыть в файрволе (ufw или панель хостера).
   Скрипт файрвол не меняет. **Не закрывайте** SSH и порты 80/443: 80 нужен для продления
   сертификата, 443 нужен Xray.
   ```shell
   sudo ufw delete allow <panel-port>
   ```

### Почему Reality не нужен сертификат

Reality не использует свой сертификат: чужому клиенту он показывает TLS того сайта, что указан
в Target (dest), то есть nginx на `127.0.0.1:8443`. Сертификат нужен только nginx, лежит в
`/etc/letsencrypt/live/<domain>/` и продлевается certbot'ом (systemd-таймер или cron из пакета
certbot, хук перезагружает nginx). Панель после очистки путей сертификата работает по HTTP
на локальном порту, TLS для неё тоже делает nginx. Поэтому сертификат в панели и выпуск через
`x-ui` больше не нужны.

## Как проверить

На сервере:
```shell
curl --resolve <domain>:8443:127.0.0.1 https://<domain>:8443/
```
```shell
curl -s -o /dev/null -w '%{http_code}\n' --resolve <domain>:8443:127.0.0.1 https://<domain>:8443<panel-path>
```
Первая команда должна вернуть HTML заглушки, вторая — `200` или `30x`.
Проверка продления:
```shell
sudo certbot renew --dry-run
```
Снаружи: открыть `https://<domain>/` и `https://<domain><panel-path>` в браузере.

## Откат

Все изменённые файлы лежат в `/root/vps-up-backup-<дата>/` с полными путями
(например, `/root/vps-up-backup-20260101-120000/etc/nginx/conf.d/site.conf`).

Убрать конфиг скрипта:
```shell
sudo rm /etc/nginx/conf.d/site.conf
sudo nginx -t && sudo systemctl reload nginx
```
Вернуть дефолтный сайт nginx (если он был):
```shell
sudo cp -a /root/vps-up-backup-<дата>/etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```
В панели вернуть прежний Target (dest) и SNI у Reality inbound и, если нужно, пути сертификата.

## Частые проблемы

* **404 на панели.** URI-путь в панели и `--panel-path` не совпадают. Путь должен быть одинаковым
  и со слешами с обеих сторон: `/secret-path/`. В nginx `proxy_pass` указан без пути на конце,
  чтобы префикс не обрезался.
* **502 на панели.** Панель ещё отвечает по HTTPS (не очищены пути сертификата, ручной шаг 1),
  или она слушает другой порт, или не запущена (`systemctl status x-ui`). Скрипт в конце
  подсказывает, какой из случаев похож на ваш.
* **Порт 80 занят.** Скрипт покажет процесс (`ss -tlnp`). Часто это другой веб-сервер
  (apache2, caddy) или inbound Xray на 80. Освободите порт и запустите скрипт снова.
* **Домен не резолвится на сервер.** Проверьте A-запись и подождите обновления DNS.
  Если домен на Cloudflare, переключите облако в серое (DNS only).
* **`certbot renew --dry-run` не проходит.** Проверьте, что порт 80 открыт снаружи (ufw и
  файрвол хостера). Если сертификат раньше выпускался в режиме standalone, переключите его
  на webroot: `sudo certbot certonly --webroot -w /var/www/site -d <domain> --cert-name <domain> --force-renewal`.
* **Сертификат панели выпускался через `x-ui` (acme.sh).** После перехода на схему он не нужен,
  а его автопродление в режиме standalone будет падать: порт 80 теперь занят nginx.
