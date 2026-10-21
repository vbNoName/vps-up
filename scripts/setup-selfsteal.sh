#!/usr/bin/env bash
#
# setup-selfsteal.sh — серверная часть схемы «selfsteal» для 3x-ui.
#
# Ставит nginx с сайтом-заглушкой и сертификатом Let's Encrypt на 127.0.0.1:8443
# и проксирует туда же панель 3x-ui по секретному пути. Reality-inbound на :443
# пересылает (dest) чужие подключения на этот nginx.
#
# Скрипт НЕ трогает inbound'ы, клиентов и настройки 3x-ui, конфиг Xray и файрвол.
# Что нужно сделать вручную, он выводит в конце работы.
#
# Документация: docs/selfsteal.md

set -Eeuo pipefail

readonly SCRIPT_URL="https://raw.githubusercontent.com/vbNoName/vps-up/main/scripts/setup-selfsteal.sh"
readonly DEFAULT_SITE_URL="https://raw.githubusercontent.com/vbNoName/vps-up/main/site/dev-stub.html"
readonly SITE_ROOT="/var/www/site"
readonly SITE_INDEX="${SITE_ROOT}/index.html"
readonly NGINX_CONF="/etc/nginx/conf.d/site.conf"
readonly NGINX_DEFAULT_SITE="/etc/nginx/sites-enabled/default"
readonly RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/nginx.sh"
readonly LOCAL_TLS_PORT="8443"
readonly CERT_MIN_DAYS=30
# Бинарник панели. Обёртка /usr/bin/x-ui подкоманду `setting` не пробрасывает,
# поэтому настройки читаем напрямую (так же делает сам x-ui.sh).
readonly XUI_BIN="${XUI_MAIN_FOLDER:-/usr/local/x-ui}/x-ui"
BACKUP_DIR="/root/vps-up-backup-$(date +%Y%m%d-%H%M%S)"
readonly BACKUP_DIR

# Параметры: флаги имеют приоритет над переменными окружения.
DOMAIN="${DOMAIN:-}"
PANEL_PORT="${PANEL_PORT:-}"
PANEL_PATH="${PANEL_PATH:-}"
EMAIL="${EMAIL:-}"
SITE_URL="${SITE_URL:-}"
FORCE_SITE="${FORCE_SITE:-0}"
DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"

TMP_DIR=""
BACKUP_USED=0
PREFLIGHT_FAILED=0
NGINX_VERSION=""
declare -a RESULT_STEPS=() RESULT_STATUS=() RESULT_NOTES=()

# ---------------------------------------------------------------------------
# Вывод
# ---------------------------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_CYAN=$'\e[36m'
    C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RESET=$'\e[0m'
else
    C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_BOLD="" C_DIM="" C_RESET=""
fi

step()  { printf '\n%s==> [%s] %s%s\n' "$C_BOLD" "$1" "$2" "$C_RESET"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    %s✔%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '    %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '    %s✘%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
plan()  { printf '    %s[dry-run]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }

# Печатает файл с отступом (вывод команд, хвосты логов, конфиги в dry-run).
indent() { sed 's/^/        /' "$@"; }

# Запоминает итог шага для финального отчёта.
# Статусы: ok, changed, skipped, planned, warn, manual, failed.
result() {
    RESULT_STEPS+=("$1")
    RESULT_STATUS+=("$2")
    RESULT_NOTES+=("${3:-}")
}

die() {
    error "$*"
    if ((${#RESULT_STEPS[@]} > 0)); then
        print_summary
    fi
    if ((BACKUP_USED)); then
        info "Бэкапы изменённых файлов: ${BACKUP_DIR}"
    fi
    exit 1
}

on_error() {
    local code="$1" line="$2" cmd="$3"
    trap - ERR
    die "Непредвиденная ошибка (код ${code}) в строке ${line}: ${cmd}"
}

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

usage() {
    cat <<EOF
Использование:
  sudo bash setup-selfsteal.sh --domain <домен> [параметры]
  curl -fsSL ${SCRIPT_URL} \\
    | sudo bash -s -- --domain <домен> [параметры]

Готовит серверную часть схемы «selfsteal» для 3x-ui: nginx с сайтом-заглушкой
и сертификатом Let's Encrypt на 127.0.0.1:${LOCAL_TLS_PORT}, плюс проксирование панели
3x-ui по секретному пути того же домена. Inbound'ы, настройки панели, Xray
и файрвол скрипт не меняет: что сделать вручную, он выведет в конце.

Параметры (в скобках — переменная окружения с тем же смыслом):
  --domain <домен>       (DOMAIN)        Домен этого сервера, A-запись должна
                                         вести на его IP. Обязательный.
  --panel-port <порт>    (PANEL_PORT)    Порт, на котором слушает 3x-ui.
                                         По умолчанию берётся из настроек панели.
  --panel-path </путь/>  (PANEL_PATH)    URI-путь панели, слеши с обеих сторон.
                                         По умолчанию берётся из настроек панели.
  --email <email>        (EMAIL)         Email для Let's Encrypt. Если не задан,
                                         регистрация без email.
  --site-url <url>       (SITE_URL)      Откуда скачать HTML-заглушку. По умолчанию
                                         site/dev-stub.html из клона репозитория,
                                         а без клона ${DEFAULT_SITE_URL}
  --force-site           (FORCE_SITE=1)  Перезаписать ${SITE_INDEX}, даже если он есть.
  --dry-run              (DRY_RUN=1)     Ничего не менять, только показать план.
  -y, --yes              (ASSUME_YES=1)  Без вопросов; при несовпадении DNS
                                         продолжить с предупреждением.
  -h, --help                             Показать эту справку.

Переменные окружения sudo по умолчанию не передаёт: пишите их после sudo,
например: sudo DOMAIN=vpn.example.com bash setup-selfsteal.sh

Пример:
  sudo bash scripts/setup-selfsteal.sh --domain vpn.example.com \\
    --panel-port 2053 --panel-path /secret-path/ --email admin@example.com
EOF
}

# ---------------------------------------------------------------------------
# Утилиты
# ---------------------------------------------------------------------------

is_true() {
    case "${1,,}" in
        1 | true | yes | y | on) return 0 ;;
        *) return 1 ;;
    esac
}

dry() { is_true "$DRY_RUN"; }

# Статус шага, который что-то меняет: в dry-run — только план.
changed_or_planned() {
    if dry; then echo planned; else echo changed; fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# Вопрос да/нет. Читаем из /dev/tty: при запуске через `curl | bash` stdin занят скриптом.
confirm() {
    local answer=""
    if is_true "$ASSUME_YES"; then
        return 0
    fi
    if ! { : </dev/tty; } 2>/dev/null; then
        die "Нет терминала для вопроса «$1». Запустите с --yes."
    fi
    printf '    %s [y/N]: ' "$1" >/dev/tty
    read -r answer </dev/tty || true
    [[ "${answer,,}" == y || "${answer,,}" == yes || "${answer,,}" == д || "${answer,,}" == да ]]
}

# В dry-run проблема окружения не прерывает показ плана, в обычном режиме — останавливает.
preflight_fail() {
    if dry; then
        error "$*"
        PREFLIGHT_FAILED=1
    else
        die "$*"
    fi
}

# version_ge A B — истина, если версия A >= B.
version_ge() {
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

is_ipv4() {
    local ip="$1" octet
    local -a parts
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -ra parts <<<"$ip"
    for octet in "${parts[@]}"; do
        ((10#$octet <= 255)) || return 1
    done
}

ip_to_int() {
    local a b c d
    IFS=. read -r a b c d <<<"$1"
    echo $(((10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d))
}

# Адрес из диапазонов Cloudflare (https://www.cloudflare.com/ips-v4)?
is_cloudflare_ip() {
    local ip cidr net bits mask
    ip=$(ip_to_int "$1")
    for cidr in 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 \
        141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 \
        197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 \
        104.24.0.0/14 172.64.0.0/13 131.0.72.0/22; do
        net=$(ip_to_int "${cidr%/*}")
        bits="${cidr#*/}"
        mask=$(((0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF))
        if (((ip & mask) == (net & mask))); then
            return 0
        fi
    done
    return 1
}

# Тело HTTP-ответа в stdout; curl или wget, что есть.
http_get() {
    local url="$1"
    shift
    if have curl; then
        curl -fsSL --max-time 10 "$@" "$url"
    elif have wget; then
        wget -qO- --timeout=10 "$url"
    else
        return 1
    fi
}

# Каталог скрипта, если он запущен из файла (а не через `curl | bash`).
script_dir() {
    local src="${BASH_SOURCE[0]:-}"
    [[ "$src" == *.sh && -f "$src" ]] || return 1
    (cd "$(dirname "$src")" && pwd -P)
}

# Копирует файл в BACKUP_DIR с сохранением полного пути (один раз за запуск).
declare -A BACKED_UP=()
backup_path() {
    local src="$1"
    [[ -e "$src" || -L "$src" ]] || return 0
    [[ -z "${BACKED_UP[$src]:-}" ]] || return 0
    install -d -m 0700 "$BACKUP_DIR"
    # Не `cp --parents`: с абсолютным путём он зависит от текущего каталога (coreutils 9.1).
    mkdir -p "${BACKUP_DIR}$(dirname "$src")"
    cp -a "$src" "${BACKUP_DIR}${src}"
    BACKED_UP[$src]=1
    BACKUP_USED=1
    info "Бэкап: ${src} → ${BACKUP_DIR}${src}"
}

# ---------------------------------------------------------------------------
# Аргументы и валидация
# ---------------------------------------------------------------------------

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --domain | --panel-port | --panel-path | --email | --site-url)
                (($# >= 2)) || die "Флагу $1 нужно значение (см. --help)."
                set_param "$1" "$2"
                shift 2
                ;;
            --domain=* | --panel-port=* | --panel-path=* | --email=* | --site-url=*)
                set_param "${1%%=*}" "${1#*=}"
                shift
                ;;
            --force-site) FORCE_SITE=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            -y | --yes) ASSUME_YES=1; shift ;;
            -h | --help) usage; exit 0 ;;
            --) shift ;;
            *) die "Неизвестный параметр: $1 (см. --help)." ;;
        esac
    done
}

set_param() {
    case "$1" in
        --domain) DOMAIN="$2" ;;
        --panel-port) PANEL_PORT="$2" ;;
        --panel-path) PANEL_PATH="$2" ;;
        --email) EMAIL="$2" ;;
        --site-url) SITE_URL="$2" ;;
        *) die "Неизвестный параметр: $1" ;;
    esac
}

validate_domain() {
    [[ -n "$DOMAIN" ]] || die "Не указан домен: --domain vpn.example.com (см. --help)."
    DOMAIN="${DOMAIN,,}"
    DOMAIN="${DOMAIN%.}"
    if ((${#DOMAIN} > 253)) ||
        ! [[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9-]{1,59})$ ]]; then
        die "Некорректный домен: '${DOMAIN}'. Ожидается вида vpn.example.com (кириллические домены — в punycode)."
    fi
}

validate_email() {
    [[ -z "$EMAIL" ]] && return 0
    [[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] ||
        die "Некорректный email: '${EMAIL}'."
}

validate_panel() {
    if ! [[ "$PANEL_PORT" =~ ^[0-9]{1,5}$ ]] || ((10#$PANEL_PORT < 1 || 10#$PANEL_PORT > 65535)); then
        die "Некорректный порт панели: '${PANEL_PORT}'. Ожидается число 1–65535."
    fi
    PANEL_PORT=$((10#$PANEL_PORT))
    if ((PANEL_PORT == 80 || PANEL_PORT == LOCAL_TLS_PORT)); then
        die "Порт панели ${PANEL_PORT} конфликтует с nginx (80 и ${LOCAL_TLS_PORT} заняты схемой). Перенесите панель на другой порт."
    fi
    if ((PANEL_PORT == 443)); then
        warn "Панель на порту 443: этот порт нужен Reality-inbound'у Xray. Проверьте, что это не ошибка."
    fi

    if [[ "$PANEL_PATH" == "/" ]]; then
        die "Путь панели '/' не подходит: на / будет сайт. Задайте в панели URI-путь вида /secret-path/ и укажите его в --panel-path."
    fi
    if ! [[ "$PANEL_PATH" =~ ^/([A-Za-z0-9._~-]+/)+$ ]]; then
        die "Некорректный путь панели: '${PANEL_PATH}'. Нужен формат /xxx/ — со слешами с обеих сторон, символы A-Z a-z 0-9 . _ ~ -"
    fi
    if [[ "$PANEL_PATH" =~ (^|/)\.{1,2}/ || "$PANEL_PATH" == /.well-known/* ]]; then
        die "Путь панели '${PANEL_PATH}' недопустим (сегменты . и .., /.well-known/)."
    fi
}

# Порт и путь панели только читаем: `x-ui setting -show` ничего не меняет.
detect_panel_settings() {
    local missing="" help out port path
    [[ -z "$PANEL_PORT" ]] && missing+=" --panel-port"
    [[ -z "$PANEL_PATH" ]] && missing+=" --panel-path"
    [[ -n "$missing" ]] || return 0

    info "Не заданы${missing}, читаю настройки панели: ${XUI_BIN} setting -show"
    [[ -x "$XUI_BIN" ]] ||
        die "Не найден бинарник 3x-ui (${XUI_BIN}), определить${missing} нельзя. Укажите явно:${missing}"
    ((EUID == 0)) ||
        die "Чтение настроек панели требует root. Запустите через sudo или укажите явно:${missing}"

    # Проверяем, что эта версия панели знает флаг -show, а не угадываем.
    help=$(timeout 20 "$XUI_BIN" setting -h 2>&1 || true)
    grep -Eq '^[[:space:]]*-show([[:space:]]|$)' <<<"$help" ||
        die "Установленная версия 3x-ui не поддерживает 'setting -show'. Укажите явно:${missing}"

    out=$(timeout 20 "$XUI_BIN" setting -show 2>&1 || true)
    port=$(sed -n 's/^port:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' <<<"$out" | head -n 1)
    path=$(sed -n 's/^webBasePath:[[:space:]]*\([^[:space:]]*\)[[:space:]]*$/\1/p' <<<"$out" | head -n 1)

    if [[ -z "$PANEL_PORT" ]]; then
        [[ -n "$port" ]] || die "Не удалось определить порт панели из 'setting -show'. Укажите --panel-port."
        PANEL_PORT="$port"
        ok "Порт панели из настроек 3x-ui: ${PANEL_PORT}"
    fi
    if [[ -z "$PANEL_PATH" ]]; then
        [[ -n "$path" ]] || die "Не удалось определить путь панели из 'setting -show'. Укажите --panel-path."
        if [[ "$path" == "/" ]]; then
            die "В панели не задан URI-путь (webBasePath = /), а на / будет сайт. Задайте в панели секретный путь (Настройки панели → Общие → URI-путь), перезапустите панель и запустите скрипт снова."
        fi
        PANEL_PATH="$path"
        ok "Путь панели из настроек 3x-ui получен (${#PANEL_PATH} символов)"
    fi
}

# ---------------------------------------------------------------------------
# Шаг 1. Предпроверки
# ---------------------------------------------------------------------------

check_root() {
    local dir hint=""
    if ((EUID == 0)); then
        return 0
    fi
    if dry; then
        warn "Запуск не от root: в dry-run часть проверок (процессы на портах, сертификаты) будет неполной."
        return 0
    fi
    if dir=$(script_dir); then
        hint+=$'\n        sudo bash '"${dir}"'/setup-selfsteal.sh --domain ... [параметры]'
    fi
    hint+=$'\n        curl -fsSL '"${SCRIPT_URL}"' | sudo bash -s -- --domain ... [параметры]'
    die "Нужны права root. Запустите через sudo:${hint}"
}

check_os() {
    local id="" id_like=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        id=$(. /etc/os-release && echo "${ID:-}")
        # shellcheck disable=SC1091
        id_like=$(. /etc/os-release && echo "${ID_LIKE:-}")
    fi
    if ! have apt-get || [[ " ${id} ${id_like} " != *" debian "* && " ${id} ${id_like} " != *" ubuntu "* ]]; then
        preflight_fail "Поддерживаются только Debian/Ubuntu (apt). Обнаружено: ${id:-неизвестно}."
        return 0
    fi
    have systemctl || preflight_fail "Не найден systemctl: скрипт рассчитан на systemd."
    ok "ОС: ${id}${id_like:+ (${id_like})}, apt есть"
}

check_xui() {
    if have x-ui || [[ -x "$XUI_BIN" ]] || systemctl cat x-ui.service >/dev/null 2>&1; then
        ok "3x-ui установлена"
        if ! systemctl is-active --quiet x-ui 2>/dev/null; then
            warn "Сервис x-ui сейчас не активен: проверка панели в конце, скорее всего, не пройдёт."
        fi
    else
        preflight_fail "3x-ui не найдена (нет команды x-ui, ${XUI_BIN} и сервиса x-ui). Сначала установите панель: https://github.com/MHSanaei/3x-ui"
    fi
}

# A-записи домена через публичные резолверы: локальный /etc/hosts часто
# указывает собственный домен на 127.0.1.1 и сбивает проверку.
resolve_domain() {
    local out=""
    {
        out=$(http_get "https://cloudflare-dns.com/dns-query?name=${DOMAIN}&type=A" \
            -H 'accept: application/dns-json' 2>/dev/null || true)
        [[ -n "$out" ]] || out=$(http_get "https://dns.google/resolve?name=${DOMAIN}&type=A" 2>/dev/null || true)
        if [[ -n "$out" ]]; then
            grep -Eo '"data": *"[0-9.]+"' <<<"$out" | grep -Eo '[0-9]+(\.[0-9]+){3}' || true
        elif have dig; then
            dig +short +time=3 +tries=2 A "$DOMAIN" @1.1.1.1 2>/dev/null || true
        else
            getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' || true
        fi
    } | while read -r ip; do
        if is_ipv4 "$ip" && [[ "$ip" != 127.* ]]; then
            echo "$ip"
        fi
    done | sort -u
}

detect_public_ips() {
    local url ip
    {
        for url in https://ifconfig.me https://api.ipify.org https://ipv4.icanhazip.com; do
            ip=$(http_get "$url" -4 2>/dev/null | tr -d '[:space:]' || true)
            if is_ipv4 "$ip"; then
                echo "$ip"
            fi
        done
    } | sort -u
}

check_dns() {
    local -a a_records=() public_ips=()
    local ip match=0 problem="" cf=0

    info "Если домен на Cloudflare, облако у A-записи должно быть серым (DNS only), иначе Reality и выпуск сертификата не заработают."
    mapfile -t a_records < <(resolve_domain)
    mapfile -t public_ips < <(detect_public_ips)
    if ((${#public_ips[@]} == 0)) && have ip; then
        if have curl || have wget; then
            warn "Внешние сервисы IP не ответили, сравниваю с адресами интерфейсов."
        else
            warn "Нет curl и wget, внешний IP не узнать: сравниваю с адресами интерфейсов."
        fi
        mapfile -t public_ips < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u)
    fi

    info "A-записи ${DOMAIN}: ${a_records[*]:-нет}"
    info "Публичный IP сервера: ${public_ips[*]:-не определён}"

    for ip in ${a_records[@]+"${a_records[@]}"}; do
        if [[ " ${public_ips[*]:-} " == *" ${ip} "* ]]; then
            match=1
        fi
        if is_cloudflare_ip "$ip"; then
            cf=1
        fi
    done

    if ((${#a_records[@]} == 0)); then
        problem="Домен ${DOMAIN} не резолвится: нет A-записи (или она ещё не разошлась)."
    elif ((${#public_ips[@]} == 0)); then
        problem="Не удалось определить публичный IP сервера (нужен curl или wget и доступ в интернет)."
    elif ((!match)); then
        problem="A-запись ${DOMAIN} (${a_records[*]}) не совпадает с IP сервера (${public_ips[*]})."
        if ((cf)); then
            problem+=" Адрес принадлежит Cloudflare: переключите облако в серое (DNS only)."
        fi
    fi

    if [[ -z "$problem" ]]; then
        ok "DNS: ${DOMAIN} → ${a_records[*]}, совпадает с IP сервера"
        if ((${#a_records[@]} > 1)); then
            warn "У домена несколько A-записей: Let's Encrypt может обратиться к любой из них."
        fi
    elif is_true "$ASSUME_YES"; then
        warn "${problem}"
        warn "Продолжаю из-за --yes: выпуск сертификата может не пройти."
        return 1
    else
        preflight_fail "${problem} Исправьте DNS или запустите с --yes, чтобы продолжить на свой риск."
        return 1
    fi
}

# Кто слушает порт. Пустой вывод — порт свободен.
port_listeners() {
    ss -Htlnp "sport = :$1" 2>/dev/null || true
}

# Порт свободен или занят только nginx.
check_port() {
    local port="$1" what="$2" listeners
    if ! have ss; then
        warn "Нет утилиты ss (пакет iproute2): не могу проверить порт ${port}."
        return 0
    fi
    listeners=$(port_listeners "$port")
    if [[ -z "$listeners" ]]; then
        ok "Порт ${port} свободен"
    elif ((EUID != 0)); then
        warn "Порт ${port} занят, но без root не видно, каким процессом:"
        indent <<<"$listeners"
    elif grep -qv 'users:(("nginx"' <<<"$listeners"; then
        error "Порт ${port} (${what}) занят не nginx:"
        indent <<<"$listeners"
        preflight_fail "Освободите порт ${port} (остановите процесс выше) и запустите скрипт снова."
    else
        ok "Порт ${port} занят самим nginx — это нормально"
    fi
}

check_nginx_current() {
    if have nginx && ((EUID == 0)); then
        if nginx -t >"${TMP_DIR}/nginx-pre.log" 2>&1; then
            ok "Текущая конфигурация nginx проходит nginx -t"
        else
            indent "${TMP_DIR}/nginx-pre.log"
            preflight_fail "Текущая конфигурация nginx уже не проходит nginx -t. Исправьте её, прежде чем запускать скрипт."
        fi
    fi
}

step_preflight() {
    local dns_note=""
    step 1 "Предпроверки"
    validate_domain
    validate_email
    check_root
    check_os
    check_xui
    detect_panel_settings
    validate_panel
    ok "Параметры: домен ${DOMAIN}, порт панели ${PANEL_PORT}, путь панели задан"
    if [[ -z "$EMAIL" ]]; then
        warn "Email не указан: сертификат будет выпущен с --register-unsafely-without-email (без писем об истечении)."
    fi
    if ! check_dns; then
        dns_note="DNS не совпадает"
    fi
    check_port 80 "HTTP, нужен для Let's Encrypt"
    check_port "$LOCAL_TLS_PORT" "локальный TLS для Reality"
    check_nginx_current

    if ((PREFLIGHT_FAILED)); then
        result "Предпроверки" failed "есть проблемы, см. выше"
    elif [[ -n "$dns_note" ]]; then
        result "Предпроверки" warn "$dns_note (продолжено из-за --yes)"
    else
        result "Предпроверки" ok
    fi
}

# ---------------------------------------------------------------------------
# Шаг 2. Пакеты
# ---------------------------------------------------------------------------

step_packages() {
    local -a need=()
    local log="${TMP_DIR}/apt.log"
    step 2 "Пакеты: nginx, certbot, curl"
    have nginx || need+=(nginx)
    have certbot || need+=(certbot)
    have curl || need+=(curl)
    have openssl || need+=(openssl)

    if ((${#need[@]} == 0)); then
        ok "Всё уже установлено"
        result "Пакеты" skipped "уже установлены"
    elif dry; then
        plan "apt-get update && apt-get install -y --no-install-recommends ${need[*]}"
        result "Пакеты" planned "установить: ${need[*]}"
    else
        info "Устанавливаю: ${need[*]}"
        if ! { apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
            --no-install-recommends "${need[@]}"; } >"$log" 2>&1; then
            tail -n 20 "$log" | indent
            result "Пакеты" failed
            die "Не удалось установить пакеты: ${need[*]}"
        fi
        ok "Установлено: ${need[*]}"
        result "Пакеты" changed "установлены: ${need[*]}"
    fi

    # Наш конфиг лежит в conf.d — убедимся, что nginx.conf его подключает.
    if [[ -r /etc/nginx/nginx.conf ]] &&
        ! grep -Eq '^[[:space:]]*include[[:space:]]+/etc/nginx/conf\.d/\*\.conf' /etc/nginx/nginx.conf; then
        die "/etc/nginx/nginx.conf не подключает /etc/nginx/conf.d/*.conf — конфиг ${NGINX_CONF} не будет загружен. Добавьте include в блок http."
    fi

    if [[ -d "$SITE_ROOT" ]]; then
        ok "Каталог ${SITE_ROOT} есть"
    elif dry; then
        plan "mkdir -p ${SITE_ROOT}"
    else
        install -d -m 0755 "$SITE_ROOT"
        ok "Создан ${SITE_ROOT}"
    fi

    nginx_detect_version
}

nginx_detect_version() {
    local raw=""
    if have nginx; then
        raw=$(nginx -v 2>&1 || true)
        NGINX_VERSION=$(grep -Eo 'nginx/[0-9]+(\.[0-9]+)+' <<<"$raw" | cut -d/ -f2 || true)
    elif have apt-cache; then
        # В dry-run nginx может быть ещё не установлен: берём версию-кандидата из apt.
        raw=$(apt-cache policy nginx 2>/dev/null | awk '/Candidate:/ {print $2}' || true)
        NGINX_VERSION=$(sed -E 's/^[0-9]+://; s/[-+~].*$//' <<<"$raw")
    fi
    if [[ -n "$NGINX_VERSION" ]]; then
        info "Версия nginx: ${NGINX_VERSION}"
    else
        warn "Не удалось определить версию nginx, использую совместимый синтаксис 'listen ... ssl http2'."
    fi
}

# ---------------------------------------------------------------------------
# Шаг 3. Сайт-заглушка
# ---------------------------------------------------------------------------

step_site() {
    local src="" dir tmp="${TMP_DIR}/index.html"
    step 3 "Сайт-заглушка → ${SITE_INDEX}"

    if [[ -f "$SITE_INDEX" ]] && ! is_true "$FORCE_SITE"; then
        ok "${SITE_INDEX} уже есть, не трогаю (перезаписать: --force-site)"
        result "Сайт-заглушка" skipped "файл уже есть"
        return 0
    fi

    # Явный --site-url важнее локального файла; без него — локальная копия из клона.
    if [[ -z "$SITE_URL" ]] && dir=$(script_dir) && [[ -f "${dir}/../site/dev-stub.html" ]]; then
        src="$(cd "${dir}/../site" && pwd -P)/dev-stub.html"
        cp "$src" "$tmp"
        info "Источник: ${src}"
    else
        src="${SITE_URL:-$DEFAULT_SITE_URL}"
        info "Источник: ${src}"
        if ! http_get "$src" >"$tmp" 2>"${TMP_DIR}/site-dl.log"; then
            : >"$tmp"
        fi
    fi

    if [[ ! -s "$tmp" ]] || ! grep -qi '<html' "$tmp"; then
        if [[ -f "$SITE_INDEX" ]]; then
            warn "Не удалось получить заглушку из ${src}; оставляю существующий ${SITE_INDEX}."
            result "Сайт-заглушка" warn "не скачалась, оставлен старый файл"
            return 0
        fi
        die "Не удалось получить HTML-заглушку из ${src}. Проверьте --site-url или положите свою страницу в ${SITE_INDEX} и запустите снова."
    fi

    if [[ -f "$SITE_INDEX" ]] && cmp -s "$tmp" "$SITE_INDEX"; then
        ok "${SITE_INDEX} уже совпадает с заглушкой"
        result "Сайт-заглушка" skipped "без изменений"
    elif dry; then
        plan "записать ${SITE_INDEX} ($(wc -c <"$tmp") байт)"
        result "Сайт-заглушка" planned
    else
        backup_path "$SITE_INDEX"
        install -m 0644 "$tmp" "$SITE_INDEX"
        ok "Записан ${SITE_INDEX}"
        result "Сайт-заглушка" changed
    fi
}

# ---------------------------------------------------------------------------
# Шаг 4. Дефолтный сайт nginx
# ---------------------------------------------------------------------------

step_default_site() {
    step 4 "Дефолтный сайт nginx"
    if [[ ! -e "$NGINX_DEFAULT_SITE" && ! -L "$NGINX_DEFAULT_SITE" ]]; then
        ok "${NGINX_DEFAULT_SITE} отсутствует"
        result "Дефолтный сайт nginx" skipped "отсутствует"
    elif dry; then
        plan "бэкап и удаление ${NGINX_DEFAULT_SITE}"
        result "Дефолтный сайт nginx" planned "удалить"
    else
        backup_path "$NGINX_DEFAULT_SITE"
        rm -f "$NGINX_DEFAULT_SITE"
        ok "Удалён ${NGINX_DEFAULT_SITE} (оригинал остаётся в sites-available)"
        result "Дефолтный сайт nginx" changed "удалён"
    fi
}

# ---------------------------------------------------------------------------
# Шаг 5. nginx + сертификат
# ---------------------------------------------------------------------------

cert_file() { echo "/etc/letsencrypt/live/${DOMAIN}/$1"; }

cert_exists() {
    [[ -r "$(cert_file fullchain.pem)" && -r "$(cert_file privkey.pem)" ]]
}

cert_valid() {
    cert_exists && openssl x509 -checkend $((CERT_MIN_DAYS * 86400)) -noout \
        -in "$(cert_file fullchain.pem)" >/dev/null 2>&1
}

cert_enddate() {
    openssl x509 -enddate -noout -in "$(cert_file fullchain.pem)" 2>/dev/null | cut -d= -f2
}

ipv6_enabled() { [[ -e /proc/net/if_inet6 ]]; }

# Конфиг nginx. Этап "http" — только :80 (до сертификата), "full" — :80 и 127.0.0.1:8443.
render_nginx_conf() {
    local stage="$1" conf tls_listen listen6=""

    if ipv6_enabled; then
        listen6=$'    listen [::]:80;\n'
    fi
    if [[ -n "$NGINX_VERSION" ]] && version_ge "$NGINX_VERSION" 1.25.1; then
        tls_listen=$'    listen 127.0.0.1:@TLS_PORT@ ssl;\n    http2 on;'
    else
        tls_listen='    listen 127.0.0.1:@TLS_PORT@ ssl http2;'
    fi

    conf=$(
        cat <<'NGINX'
# Сгенерировано vps-up/scripts/setup-selfsteal.sh.
# Повторный запуск скрипта перезапишет этот файл (с бэкапом в /root/vps-up-backup-*).
NGINX
    )
    conf+=$'\n'

    if [[ "$stage" == full ]]; then
        conf+=$(
            cat <<'NGINX'

map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
NGINX
        )
        conf+=$'\n'
    fi

    conf+=$(
        cat <<'NGINX'

server {
    listen 80;
@LISTEN6@    server_name @DOMAIN@;
    server_tokens off;

    location /.well-known/acme-challenge/ {
        root /var/www/site;
    }
    location / {
        return 301 https://$host$request_uri;
    }
}
NGINX
    )
    conf+=$'\n'

    if [[ "$stage" == full ]]; then
        conf+=$(
            cat <<'NGINX'

server {
@TLS_LISTEN@
    server_name @DOMAIN@;
    server_tokens off;

    ssl_certificate     /etc/letsencrypt/live/@DOMAIN@/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/@DOMAIN@/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_tickets off;

    root /var/www/site;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    # proxy_pass без пути в конце: префикс не обрезается, панель видит свой webBasePath.
    location @PANEL_PATH@ {
        proxy_pass http://127.0.0.1:@PANEL_PORT@;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 300s;
    }
}
NGINX
        )
        conf+=$'\n'
    fi

    # Замены в кавычках: в bash 5.2 символ & в незакавыченной замене означает найденный текст.
    conf="${conf//@LISTEN6@/"$listen6"}"
    conf="${conf//@TLS_LISTEN@/"$tls_listen"}"
    conf="${conf//@TLS_PORT@/"$LOCAL_TLS_PORT"}"
    conf="${conf//@DOMAIN@/"$DOMAIN"}"
    conf="${conf//@PANEL_PATH@/"$PANEL_PATH"}"
    conf="${conf//@PANEL_PORT@/"$PANEL_PORT"}"
    printf '%s' "$conf"
}

nginx_reload() {
    systemctl enable nginx >/dev/null 2>&1 || true
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
    else
        systemctl restart nginx
    fi
}

# Записывает конфиг этапа, проверяет nginx -t и перечитывает nginx.
# При провале nginx -t возвращает файл в состояние до записи.
# Код возврата: 0 — файл изменён, 3 — уже актуален.
apply_nginx_conf() {
    local stage="$1" new="${TMP_DIR}/site.conf.${1}" prev="${TMP_DIR}/site.conf.prev" had_prev=0

    render_nginx_conf "$stage" >"$new"
    if [[ -f "$NGINX_CONF" ]] && cmp -s "$new" "$NGINX_CONF"; then
        return 3
    fi
    if dry; then
        plan "записать ${NGINX_CONF} (этап: ${stage}), nginx -t, systemctl reload nginx"
        if [[ "$stage" == full ]]; then
            indent "$new"
        fi
        return 0
    fi

    if [[ -f "$NGINX_CONF" ]]; then
        cp -a "$NGINX_CONF" "$prev"
        had_prev=1
        backup_path "$NGINX_CONF"
    fi
    install -m 0644 "$new" "$NGINX_CONF"

    if ! nginx -t >"${TMP_DIR}/nginx-t.log" 2>&1; then
        indent "${TMP_DIR}/nginx-t.log"
        if ((had_prev)); then
            cp -a "$prev" "$NGINX_CONF"
        else
            rm -f "$NGINX_CONF"
        fi
        result "nginx: конфиг (${stage})" failed "nginx -t не прошёл, откат"
        die "nginx -t не прошёл с новым ${NGINX_CONF} (этап: ${stage}). Файл возвращён в прежнее состояние, nginx не перезагружался."
    fi
    nginx_reload
    ok "${NGINX_CONF} записан (этап: ${stage}), nginx -t OK, nginx перечитан"
}

issue_cert() {
    local -a cmd=(certbot certonly --webroot -w "$SITE_ROOT" -d "$DOMAIN" --cert-name "$DOMAIN"
        --non-interactive --agree-tos --keep-until-expiring)
    local log="${TMP_DIR}/certbot.log"

    if [[ -n "$EMAIL" ]]; then
        cmd+=(--email "$EMAIL" --no-eff-email)
    else
        cmd+=(--register-unsafely-without-email)
    fi

    if dry; then
        plan "${cmd[*]}"
        return 0
    fi
    info "Выпускаю сертификат: certbot certonly --webroot -w ${SITE_ROOT} -d ${DOMAIN}"
    if ! "${cmd[@]}" >"$log" 2>&1; then
        tail -n 25 "$log" | indent
        result "Сертификат" failed "certbot не смог выпустить"
        die "certbot не смог выпустить сертификат. Частые причины: A-запись не на этот сервер, оранжевое облако Cloudflare, порт 80 закрыт у хостера или в файрволе."
    fi
    ok "Сертификат получен, действует до: $(cert_enddate)"
}

check_renewal_authenticator() {
    local conf="/etc/letsencrypt/renewal/${DOMAIN}.conf" auth
    [[ -r "$conf" ]] || return 0
    auth=$(sed -n 's/^authenticator[[:space:]]*=[[:space:]]*//p' "$conf" | head -n 1)
    if [[ -n "$auth" && "$auth" != webroot ]]; then
        warn "Сертификат ${DOMAIN} продлевается через '${auth}', а не webroot: при занятом nginx порте 80 продление может не пройти."
        warn "Переключить на webroot: certbot certonly --webroot -w ${SITE_ROOT} -d ${DOMAIN} --cert-name ${DOMAIN} --force-renewal"
    fi
}

step_nginx_and_cert() {
    local rc cert_issued=0
    step 5 "Конфиг nginx и сертификат Let's Encrypt"

    # 5.1. Без сертификата блок 8443 не пройдёт nginx -t — сначала только :80.
    if cert_exists; then
        ok "Сертификат для ${DOMAIN} уже есть (до $(cert_enddate)), этап только с :80 не нужен"
        result "nginx: этап :80" skipped "сертификат уже есть"
    else
        rc=0
        apply_nginx_conf http || rc=$?
        if ((rc == 3)); then
            ok "${NGINX_CONF} уже содержит этап :80"
            result "nginx: этап :80" skipped "без изменений"
        else
            result "nginx: этап :80" "$(changed_or_planned)"
        fi
    fi

    # 5.2. Сертификат.
    if cert_valid; then
        ok "Сертификат действителен ещё больше ${CERT_MIN_DAYS} дней, выпуск пропускаю"
        result "Сертификат" skipped "до $(cert_enddate)"
    else
        issue_cert
        cert_issued=1
        if dry; then
            result "Сертификат" planned "выпустить"
        else
            result "Сертификат" changed "до $(cert_enddate)"
        fi
    fi
    check_renewal_authenticator

    # 5.3. Полный конфиг с 127.0.0.1:8443.
    rc=0
    apply_nginx_conf full || rc=$?
    if ((rc == 3)); then
        ok "${NGINX_CONF} уже актуален"
        if ((cert_issued)) && ! dry; then
            nginx_reload
            ok "nginx перечитан, чтобы подхватить новый сертификат"
        fi
        result "nginx: полный конфиг" skipped "без изменений"
    else
        result "nginx: полный конфиг" "$(changed_or_planned)"
    fi
}

# ---------------------------------------------------------------------------
# Шаг 6. Автопродление
# ---------------------------------------------------------------------------

step_renewal() {
    local hook_tmp="${TMP_DIR}/nginx-hook.sh" log="${TMP_DIR}/renew.log"
    local -a renew=(certbot renew --dry-run --cert-name "$DOMAIN")
    step 6 "Автопродление сертификата"

    printf '#!/bin/sh\nsystemctl reload nginx\n' >"$hook_tmp"
    if [[ -f "$RENEW_HOOK" && -x "$RENEW_HOOK" ]] && cmp -s "$hook_tmp" "$RENEW_HOOK"; then
        ok "Хук ${RENEW_HOOK} уже на месте"
        result "Хук продления" skipped "без изменений"
    elif dry; then
        plan "записать ${RENEW_HOOK} (systemctl reload nginx), chmod +x"
        result "Хук продления" planned
    else
        backup_path "$RENEW_HOOK"
        install -d -m 0755 "$(dirname "$RENEW_HOOK")"
        install -m 0755 "$hook_tmp" "$RENEW_HOOK"
        ok "Записан ${RENEW_HOOK}"
        result "Хук продления" changed
    fi

    if dry; then
        plan "${renew[*]}"
        result "certbot renew --dry-run" planned
        return 0
    fi
    # Без tty certbot renew может «спать» до 8 минут перед запуском — отключаем, если флаг есть.
    if certbot --help renew 2>/dev/null | grep -q -- '--no-random-sleep-on-renew'; then
        renew+=(--no-random-sleep-on-renew)
    fi
    info "Проверяю продление: certbot renew --dry-run (может занять до минуты)"
    if "${renew[@]}" >"$log" 2>&1; then
        ok "certbot renew --dry-run прошёл"
        result "certbot renew --dry-run" ok
    else
        tail -n 15 "$log" | indent
        warn "certbot renew --dry-run не прошёл. Сертификат выпущен, но автопродление стоит проверить."
        result "certbot renew --dry-run" warn "не прошёл, см. вывод выше"
    fi
}

# ---------------------------------------------------------------------------
# Шаг 7. Проверки (только чтение)
# ---------------------------------------------------------------------------

local_curl() {
    curl -sS --max-time 15 --resolve "${DOMAIN}:${LOCAL_TLS_PORT}:127.0.0.1" "$@"
}

# Подсказка, почему панель не открывается через nginx.
diagnose_panel() {
    if [[ -z "$(port_listeners "$PANEL_PORT")" ]]; then
        info "На порту ${PANEL_PORT} никто не слушает: панель на другом порту или не запущена."
        info "Сверьте порт в панели с --panel-port, проверьте: systemctl status x-ui"
    elif curl -sk -o /dev/null --max-time 5 "https://127.0.0.1:${PANEL_PORT}/" 2>/dev/null; then
        info "Панель на 127.0.0.1:${PANEL_PORT} отвечает по HTTPS, а nginx ходит к ней по HTTP."
        info "Очистите в панели пути сертификата и перезапустите её (ручной шаг 1)."
    else
        info "Панель слушает ${PANEL_PORT}. Сверьте URI-путь в панели с --panel-path (слеши с обеих сторон)."
    fi
}

step_checks() {
    local code body="${TMP_DIR}/check-body.html"
    step 7 "Проверки"

    if dry; then
        plan "curl --resolve ${DOMAIN}:${LOCAL_TLS_PORT}:127.0.0.1 https://${DOMAIN}:${LOCAL_TLS_PORT}/ → ожидается 200 и заглушка"
        plan "curl --resolve ${DOMAIN}:${LOCAL_TLS_PORT}:127.0.0.1 https://${DOMAIN}:${LOCAL_TLS_PORT}<panel-path> → ожидается 200/3xx"
        result "Проверка сайта" planned
        result "Проверка панели" planned
        return 0
    fi

    code=$(local_curl -o "$body" -w '%{http_code}' "https://${DOMAIN}:${LOCAL_TLS_PORT}/" 2>"${TMP_DIR}/curl.log" || true)
    if [[ "$code" == 200 ]] && cmp -s "$body" "$SITE_INDEX"; then
        ok "Сайт: https://${DOMAIN}:${LOCAL_TLS_PORT}/ → 200, отдаётся ${SITE_INDEX}"
        result "Проверка сайта" ok "200"
    elif [[ "$code" == 200 ]]; then
        warn "Сайт отвечает 200, но содержимое не совпадает с ${SITE_INDEX}."
        result "Проверка сайта" warn "200, другое содержимое"
    else
        indent "${TMP_DIR}/curl.log"
        error "Сайт: https://${DOMAIN}:${LOCAL_TLS_PORT}/ → ${code:-нет ответа}"
        result "Проверка сайта" failed "HTTP ${code:-000}"
    fi

    # GET, а не HEAD: веб-сервер панели (gin) не отвечает на HEAD для GET-маршрутов и вернул бы 404.
    code=$(local_curl -o /dev/null -w '%{http_code}' "https://${DOMAIN}:${LOCAL_TLS_PORT}${PANEL_PATH}" 2>/dev/null || true)
    case "$code" in
        200 | 301 | 302 | 303 | 307 | 308)
            ok "Панель: проксируется через nginx (HTTP ${code})"
            result "Проверка панели" ok "HTTP ${code}"
            ;;
        *)
            warn "Панель через nginx: HTTP ${code:-000}. Это ожидаемо, пока не выполнены ручные шаги."
            diagnose_panel
            result "Проверка панели" manual "HTTP ${code:-000}, ожидает ручных действий"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Шаг 8. Отчёт
# ---------------------------------------------------------------------------

print_summary() {
    local i status label color name pad
    # Ширину колонки считаем в символах, а не байтах (кириллица в UTF-8 — 2 байта).
    local LC_ALL=C.UTF-8 2>/dev/null
    printf '\n%sИтог по шагам:%s\n' "$C_BOLD" "$C_RESET"
    for i in "${!RESULT_STEPS[@]}"; do
        status="${RESULT_STATUS[$i]}"
        case "$status" in
            ok) label="OK" color="$C_GREEN" ;;
            changed) label="ИЗМЕНЕНО" color="$C_GREEN" ;;
            skipped) label="ПРОПУЩЕНО" color="$C_DIM" ;;
            planned) label="ПЛАН" color="$C_CYAN" ;;
            warn) label="ВНИМАНИЕ" color="$C_YELLOW" ;;
            manual) label="ЖДЁТ РУЧНЫХ ДЕЙСТВИЙ" color="$C_YELLOW" ;;
            *) label="ОШИБКА" color="$C_RED" ;;
        esac
        name="${RESULT_STEPS[$i]}"
        pad=$((26 - ${#name}))
        ((pad > 0)) || pad=1
        printf '    %s%*s%s%s%s%s\n' "$name" "$pad" "" "$color" "$label" "$C_RESET" \
            "${RESULT_NOTES[$i]:+ — ${RESULT_NOTES[$i]}}"
    done
}

print_manual_steps() {
    cat <<EOF

${C_BOLD}Что нужно сделать вручную${C_RESET}

1. В панели 3x-ui («Настройки панели → Общие»): очистите оба поля путей
   сертификата (публичный и приватный ключ), сохраните, перезапустите панель.
   Порт панели должен быть ${PANEL_PORT}, URI-путь — ${PANEL_PATH}
   TLS теперь делает nginx, панель работает по HTTP на локальном порту.

2. Проверьте, что панель открывается по https://${DOMAIN}${PANEL_PATH}
   (заработает через 443 после следующего шага).

3. Измените Reality inbound на порту 443:
     Target (dest)      = 127.0.0.1:${LOCAL_TLS_PORT}
     SNI (serverNames)  = ${DOMAIN}
     uTLS fingerprint   = chrome
     Xver               = 0
   Ключи и Short IDs не меняйте; flow у клиентов — xtls-rprx-vision.
   Сохраните, при необходимости перезапустите Xray.

4. Проверьте снаружи: https://${DOMAIN}/ показывает сайт с валидным
   сертификатом, https://${DOMAIN}${PANEL_PATH} открывает панель.

5. Обновите клиентов: SNI = ${DOMAIN}, fingerprint = chrome,
   flow = xtls-rprx-vision, порт 443 (проще заново импортировать ссылку из панели).

6. Опционально, но рекомендуется: в настройках панели поставьте
   Listen IP = 127.0.0.1 (nginx продолжит ходить на панель по 127.0.0.1)
   и проверьте: ss -tlnp | grep ${PANEL_PORT}

7. Порт панели ${PANEL_PORT} снаружи больше не нужен: закройте его в файрволе
   (ufw или панель хостера), например: ufw delete allow ${PANEL_PORT}
   Скрипт файрвол не меняет. НЕ закрывайте SSH и порты 80/443:
   80 нужен для продления сертификата, 443 — для Xray.
EOF
}

step_report() {
    step 8 "Отчёт"
    print_summary
    if dry; then
        printf '\n    %sЭто был dry-run: в системе ничего не изменено.%s\n' "$C_CYAN" "$C_RESET"
    fi
    if ((BACKUP_USED)); then
        info "Бэкапы изменённых файлов: ${BACKUP_DIR}"
    fi
    print_manual_steps
}

# ---------------------------------------------------------------------------

main() {
    # При `curl | bash` stdin — это сам скрипт: дочерние команды не должны его читать.
    exec </dev/null
    trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
    trap cleanup EXIT

    parse_args "$@"
    TMP_DIR=$(mktemp -d)

    printf "%ssetup-selfsteal: nginx + Let's Encrypt на 127.0.0.1:%s для 3x-ui%s\n" \
        "$C_BOLD" "$LOCAL_TLS_PORT" "$C_RESET"
    if dry; then
        printf '%sРежим dry-run: ничего не меняется, только план.%s\n' "$C_CYAN" "$C_RESET"
    fi

    step_preflight
    if ((PREFLIGHT_FAILED)); then
        warn "Предпроверки не пройдены — показываю план, но реальный запуск сейчас остановится."
    fi

    if ! dry; then
        printf '\n'
        info "Будут изменены: пакеты (nginx, certbot, curl), ${SITE_ROOT}, ${NGINX_CONF},"
        info "${NGINX_DEFAULT_SITE}, /etc/letsencrypt. Бэкапы: ${BACKUP_DIR}"
        confirm "Продолжить?" || die "Отменено пользователем."
    fi

    step_packages
    step_site
    step_default_site
    step_nginx_and_cert
    step_renewal
    step_checks
    step_report

    if ((PREFLIGHT_FAILED)); then
        exit 1
    fi
}

main "$@"
