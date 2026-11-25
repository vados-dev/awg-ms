# Common vars
#set -e -o pipefail
#shopt -s extglob
#export LC_ALL=C

SELF="$(readlink -f "${BASH_SOURCE[0]}")"

PROGRAM="${0##*/}"
ARGS=( "$@" )
DTSTAMP="$(date +'%Y%m%d%H%M')"
mod_tmp_ver="3.1-${DTSTAMP}"
mod_branch="master"

# State
ACTION=""
KERNEL="$(uname -r)"
KERNEL_VERSION="$(uname -r)"
MOD_BRANCH="${mod_branch}"
LOCAL_BUILD=0
NONINTERACTIVE=0

# Common functions
cmd()  { printf '  [\033[1;33m✨\033[0m]\033[1m %s \033[0m\n' "$*" >&2; "$@"; }
log()  { printf ' \033[1;34m 📋 INFO:\033[0;8m [%s] - %s.\033[0m\n' "$PROGRAM" "$*"; }
warn() { printf ' \033[1;33m ⚡ WARN:\033[0;1m [%s] - %s.\033[0m\n' "$PROGRAM" "$*" >&2; }
err()  { printf ' \033[0;31m ⚫ ERROR:\033[0;1m [%s] - %s!\033[0m\n' "$PROGRAM" "$*" >&2; }
die()  { printf ' \033[1;31m ❌ CRITICAL:\033[0;1m [%s] - %s!\033[0m\n' "$PROGRAM" "$*" >&2; exit 1; }

check_root() { [ "$(id -u)" -eq 0 ] || die "Запускайте от root."; }
check_os() {
    # shellcheck disable=SC1091
    [[ -r /etc/os-release ]] && source "/etc/os-release"; os_id="$ID"; os_ver="$VERSION_ID" || die "Нет /etc/os-release!"
    version_ge() {
        local a="$1" b="$2"
        [[ "$a" == "$b" ]] && return 0
        local -a pa pb; IFS='.' read -ra pa <<<"$a"; IFS='.' read -ra pb <<<"$b"
        local i
        for ((i = 0; i < ${#pb[@]}; i++)); do
            local x="${pa[i]:-0}" y="${pb[i]:-0}"
            ((10#${x:-0} > 10#${y:-0})) && return 0
            ((10#${x:-0} < 10#${y:-0})) && return 1
        done
        return 0
    }
    case "$os_id" in
        "ubuntu") version_ge "$os_ver" "22.04" && os_type="deb"  || die "Ubuntu ${os_ver}: проверялось на 24.04+!" ;;
        "debian") version_ge "$os_ver" "12"    && os_type="deb"  || die "Debian ${os_ver}: проверялось на 12+!" ;;
        "almalinux") version_ge "$os_ver" "9"  && os_type="rhel" || die "Almalinux ${os_ver}: проверялось на 9+!" ;;
        "rocky") version_ge "$os_ver" "9"      && os_type="rhel" || die "Rocky ${os_ver}: проверялось на 9+!" ;;
        "centos") version_ge "$os_ver" "9"     && os_type="rhel" || die "CentOS ${os_ver}: проверялось на 9+!" ;;
        *) die "ОС '${os_ver}' не проверялась; ожидается Ubuntu 24.04+ / Debian 12+ / Almalinux 9+ / Rocky 9+ / Centos 9+." ;;
    esac
    log "ОС: ${os_id} ${os_ver}, Тип ОС: ${os_type}"
    if [[ "$os_type" == "rhel" ]]; then
        SRC_DIR="/usr/src"
        BASE_PKGS="amneziawg-dkms gcc make git tar gzip which curl libmnl-dev pkg-config"
        #setup_tmp="${SELF_DIR}/${mod_repo}-${mod_tmp_ver}"
    else
        SRC_DIR="${SRC_DIR:-/usr/local/src}"
        BASE_PKGS="dkms make curl ca-certificates iproute2 iptables python3 python3-venv python3-pip golang-go"
    fi
}
check_root
check_os

# /etc/pm-compat.sh — оверлей apt → pm для dnf-систем.
# Подключается через BASH_ENV=/etc/pm-compat.sh (см. /etc/environment).

PM_REAL=${PM_REAL:-/usr/local/bin/pm}

_pm() { PM_COMPAT_ACTIVE=1 "$PM_REAL" "$@"; }

apt-get() {
    # защита от рекурсии: если вызов пришёл изнутри pm — уходим в настоящий бинарник
    if [ -n "${PM_COMPAT_ACTIVE:-}" ]; then
        [ -x /usr/bin/apt-get ] && /usr/bin/apt-get "$@"
        return $?
    fi

    local cmd="$1"; shift
    local -a rest=()
    local a
    # apt-флаги снимаем: pm уже сам вызывает бэкенд с -y
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes|-q|-qq|-f|--allow-unauthenticated|--no-install-recommends) ;;
            *) rest+=("$1") ;;
        esac
        shift
    done

    case "$cmd" in
        update)                    _pm update ;;
        upgrade)                   _pm upgrade ;;
        dist-upgrade|full-upgrade) _pm full-upgrade ;;
        install)
            local -a good=(); local failed=0
            for a in "${rest[@]}"; do
                case "$a" in
                    *.deb)
                        printf 'pm-compat: %s — .deb на dnf-системе не поставить\n' "$a" >&2
                        failed=1 ;;
                    *) good+=("$a") ;;
                esac
            done
            if [ ${#good[@]} -gt 0 ]; then
                _pm install "${good[@]}" || return 1
            fi
            return $failed ;;
        reinstall)   [ ${#rest[@]} -gt 0 ] && _pm reinstall "${rest[@]}" ;;
        remove|purge)
            if [ ${#rest[@]} -gt 0 ]; then _pm remove "${rest[@]}"; else _pm autoremove; fi ;;
        autoremove)  _pm autoremove ;;
        clean|autoclean) _pm clean ;;
        search)      _pm search "${rest[@]}" ;;
        show|policy|depends) _pm show "${rest[@]}" ;;
        list)
            case "${rest[0]}" in
                --installed)  _pm list installed ;;
                --upgradable) _pm list upgradable ;;
                *)            _pm list all ;;
            esac ;;
        *)
            # непереводимое не валим чужой скрипт: предупреждаем и пропускаем.
            # Хочется жёсткого поведения — экспортируй PM_COMPAT_STRICT=1.
            printf 'pm-compat: apt-get %s %s — перевода нет, пропускаю\n' "$cmd" "${rest[*]}" >&2
            if [ -n "${PM_COMPAT_STRICT:-}" ]; then return 127; else return 0; fi ;;
    esac
}

apt() { apt-get "$@"; }

export -f apt-get apt

check_dnf_updates() { ! dnf check-update -y > /dev/null 2>&1 && err "dnf обновления не проверены!" || log "dnf обновления проверены."; }

dnf_install() {
    local packages=("$@")
    local to_install=()
    local dnf_pkg
    log "Список пакетов: ${packages[*]}"
    for dnf_pkg in "${packages[@]}"; do
      dnf list installed -q "$dnf_pkg" 2>/dev/null | grep -q "Installed Packages" || to_install+=("$dnf_pkg")
    done
        [ ${#to_install[@]} -eq 0 ] && { log "Все пакеты установлены."; return 0; }
        log "Установка: ${to_install[*]}..."
        dnf install -q -y ${to_install[*]} || return 1
        log "Установка завершена."
}

install_dnf_repos() {
    log "Проверка dnf обновлений..."
    check_dnf_updates > /dev/null 2>&1 || warn "check_dnf_updates не завершилась корректно: $?"
    log "Настройка dnf репозиториев..."
    dnf_install dnf-plugins-core || err "Ошибка установки dnf-plugins-core!"
    do_enable() { out=$(dnf config-manager --enable $1) > /dev/null 2>&1 || err "$1 не включилась ${out}!"; }
    is_enabled() { dnf -q repoinfo "$1" 2>/dev/null | grep -qi 'status[[:space:]]*:[[:space:]]*enabled'; }
    is_copr() { dnf -q repolist --enabled | grep -qi "copr.*$1"; }
    is_enabled crb > /dev/null 2>&1 || do_enable crb
    is_enabled epel > /dev/null 2>&1 || { dnf install -y epel-release; do_enable epel; }
    is_copr "tigro/amneziawg" > /dev/null 2>&1 || { dnf copr enable -y tigro/amneziawg centos-stream-${os_ver}-$(arch); } 
    ret=$(dnf clean all && dnf makecache) > /dev/null 2>&1 || err "Ошибка 'dnf clean all && dnf makecache': ${ret}"
    log "Настройка dnf репозиториев закончена."
}

rhel_install_deps() {
    local pkgs=("$@")
    log "Проверка и установка зависимостей"
    install_dnf_repos > /dev/null 2>&1 || die "Ошибка настройки dnf репозиториев!"
    log "Установка зависимостей: ${pkgs[*]}"
    dnf_install "${pkgs[@]}" > /dev/null 2>&1 && log "Зависимости установлены" || die "Зависимости не установлены!"
}

rhel_remove_deps() {
    dnf remove -y dkms || {
        err "Не удалось удалить dkms."
        return 1
    }
    log "Зависимости удалены."
}

rhel_start_setup() {
    local mod_ver src_dir
    if ! command -v make >/dev/null 2>&1 || ! command -v gcc >/dev/null 2>&1 \
    || ! dnf list installed "amneziawg-dkms" 2>/dev/null | grep -q "Installed Packages"; then
        install_deps "$BASE_PKGS"
    fi
    if [ "$LOCAL_BUILD" -eq 1 ]; then
        src_dir="${repo_root}/src"
        [ -d "$src_dir" ] || die "Каталог src не найден в ${repo_root}."
        log "Сборка локального дерева: $src_dir"
    else
        rm -rf "$setup_tmp"
        git clone --branch "$MOD_BRANCH" "$MOD_REPO" "$setup_tmp" || return 1
        src_dir="${setup_tmp}/src"
    fi
    
    cd ${src_dir}
    ! make print-version > /dev/null 2>&1 && mod_ver="$(cat version.h | grep "define WIREGUARD_VERSION" | awk -F'[/" ]+' '{print $3}')" \
    || mod_ver="$(make print-version)"

    sudo make dkms-install && \
    sudo dkms install -m amneziawg -v ${mod_ver}
    add_awg_to_modules
    log "Установлен amneziawg $mod_ver."
}

rhel_start_remove() {
    local ver

    confirm "Удалить регистрацию DKMS amneziawg?" || return 1

    ver="$(dkms status -m amneziawg 2>/dev/null | awk -F'[/, ]+' '{print $2}' | head -n1)"
    if [ -n "$ver" ]; then
        dkms remove "amneziawg/${ver}" --all || return 1
        log "Удалена регистрация DKMS amneziawg/${ver}."
    else
        warn "Регистрация DKMS amneziawg не найдена."
    fi

    del_awg_from_modules || return 1
    del_wg_from_modules || return 1
}

rhel_load_module() {
    local out
    if ! out="$(modprobe amneziawg 2>&1)"; then
        err "Модуль не загрузился: $out"
        return 1
    fi
    return 0
}

rhel_check_module() {
    if ! lsmod | grep -q -w amneziawg; then
        log "Модуль не загружен, загружаю."
        load_module || return 1
        log "Модуль загружен."
        add_awg_to_modules || return 1
    else
        log "Модуль amneziawg загружен."
    fi
    log "Информация о модуле:"
    modinfo amneziawg | grep -E "filename|version|vermagic|srcversion" || true
}
