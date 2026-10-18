#!/usr/bin/env bash
# Shows what's in the nginx search-result cache and the Squid page cache,
# plus disk usage against each cache's configured limit.
#
# Usage: ./cache-report.sh              summary: cached searches, cached sites
#        ./cache-report.sh --urls       also list every cached page URL
#        ./cache-report.sh --clear      delete all cached searches, pages and
#                                       favicons (asks first; add --yes to skip)
#
# Reads the cache files on disk, so it works whether or not the services are
# running. Cache files belong to container users, so they're read inside your
# user namespace (podman unshare). --clear stops the cache services that are
# running, empties the caches, and starts those services again.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/paths.sh
source "${SRC_DIR}/lib/paths.sh"

show_urls=0 clear=0 assume_yes=0
for arg in "$@"; do
    case "${arg}" in
        --urls) show_urls=1 ;;
        --clear) clear=1 ;;
        -y|--yes) assume_yes=1 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) printf 'unknown option: %s (see --help)\n' "${arg}" >&2; exit 2 ;;
    esac
done

SEARCH_DIR="${CACHE_DIR}/search"
FETCH_DIR="${CACHE_DIR}/fetch/cache"
FAVICON_DIR="${CACHE_DIR}/favicons"

# Run a command as the files' owner: inside the user namespace when rootless.
as_owner() {
    if [[ ${EUID} -eq 0 ]]; then "$@"; else podman unshare "$@"; fi
}

bold() { printf '\033[1m%s\033[0m\n' "$*"; }

# --- Clear -------------------------------------------------------------------------
# Squid keeps an index of its cache files, and nginx and SearXNG keep track of
# theirs, so each service is stopped while its files are deleted. Only the
# services that were running are started again.

clear_caches() {
    local services=(searxng-proxy.service fetch-cache.service searxng.service)
    local running=() svc answer

    if [[ ${assume_yes} -ne 1 ]]; then
        read -r -p "Delete all cached searches, pages and favicons? [y/N] " answer
        [[ "${answer}" == [yY]* ]] || { echo "Nothing deleted."; exit 0; }
    fi

    for svc in "${services[@]}"; do
        systemctl --user is-active --quiet "${svc}" 2>/dev/null && running+=("${svc}")
    done
    if (( ${#running[@]} > 0 )); then
        echo "Stopping ${running[*]}"
        systemctl --user stop "${running[@]}"
    fi

    # Search results: everything in the nginx cache directory.
    [[ -d "${SEARCH_DIR}" ]] && as_owner find "${SEARCH_DIR}" -mindepth 1 -delete
    # Pages: Squid's cache_dir, including its index. Squid's startup recreates
    # it. The generated site certificates (ssl_db) are kept.
    as_owner rm -rf "${FETCH_DIR}"
    # Favicons: SearXNG's SQLite cache and its journal files.
    [[ -d "${FAVICON_DIR}" ]] && as_owner find "${FAVICON_DIR}" -mindepth 1 -delete
    echo "Caches emptied."

    if (( ${#running[@]} > 0 )); then
        echo "Starting ${running[*]}"
        systemctl --user start "${running[@]}"
    fi
    echo
}

# human_age SECONDS -> 42s / 17m / 5h / 3d
human_age() {
    local s=$1
    if   (( s < 60 ));    then printf '%ds' "${s}"
    elif (( s < 3600 ));  then printf '%dm' $(( s / 60 ))
    elif (( s < 86400 )); then printf '%dh' $(( s / 3600 ))
    else                       printf '%dd' $(( s / 86400 ))
    fi
}

# urldecode STRING: + to space, %XX to the byte.
urldecode() {
    local s="${1//+/ }"
    printf '%b' "${s//%/\\x}"
}

# duration_secs 1h / 30m / 2d / 90s / 90 -> seconds (nginx time syntax)
duration_secs() {
    local v=${1%[smhd]} unit=${1: -1}
    [[ "${v}" =~ ^[0-9]+$ ]] || { echo 0; return; }
    case "${unit}" in
        m) echo $(( v * 60 )) ;;
        h) echo $(( v * 3600 )) ;;
        d) echo $(( v * 86400 )) ;;
        *) echo "${v}" ;;
    esac
}

# usage_line LABEL DIR LIMIT
usage_line() {
    local label=$1 dir=$2 limit=$3 size="-" files=0
    if [[ -d "${dir}" ]]; then
        size="$(as_owner du -sh "${dir}" 2>/dev/null | cut -f1)"
        files="$(as_owner find "${dir}" -type f 2>/dev/null | wc -l)"
    fi
    printf '  %-24s %7s  %7s files  limit %-8s  %s\n' \
        "${label}" "${size}" "${files}" "${limit}" "${dir/#${HOME}/\~}"
}

[[ ${clear} -eq 1 ]] && clear_caches

# Configured limits, read from the live configs.
nginx_limit="$(grep -Eo 'max_size=[^ ;]+' "${CONFIG_DIR}/nginx/default.conf" 2>/dev/null | cut -d= -f2 || true)"
squid_limit="$(awk '$1=="cache_dir"{print $4 " MB"; exit}' "${CONFIG_DIR}/squid/squid.conf" 2>/dev/null || true)"
favicon_bytes="$(sed -n 's/^LIMIT_TOTAL_BYTES *= *\([0-9]*\).*/\1/p' "${CONFIG_DIR}/searxng/favicons.toml" 2>/dev/null || true)"
favicon_limit="${favicon_bytes:+$(( favicon_bytes / 1048576 )) MB}"
nginx_ttl="$(grep -Eo 'proxy_cache_valid +200 +[^;]+' "${CONFIG_DIR}/nginx/default.conf" 2>/dev/null | awk '{print $3}' || true)"
nginx_inactive="$(grep -Eo 'inactive=[^ ;]+' "${CONFIG_DIR}/nginx/default.conf" 2>/dev/null | cut -d= -f2 || true)"

# --- Disk usage -----------------------------------------------------------------

bold "Disk usage"
usage_line "Search results (nginx)" "${SEARCH_DIR}"       "${nginx_limit:-?}"
usage_line "Pages (Squid)"          "${CACHE_DIR}/fetch" "${squid_limit:-?}"
usage_line "Favicons (SearXNG)"     "${FAVICON_DIR}"      "${favicon_limit:-?}"
echo

# --- nginx: cached searches ---------------------------------------------------------
# Each cache file has a "KEY: <request URI>" line; its mtime is when it was stored.

bold "Cached searches (nginx, valid for ${nginx_ttl:-?} after caching)"
now="$(date +%s)"
ttl_secs="$(duration_secs "${nginx_ttl:-0}")"
# shellcheck disable=SC2016  # expanded by the inner sh, not here
searches="$(as_owner sh -c '
    find "$1" -type f 2>/dev/null | while IFS= read -r f; do
        key="$(LC_ALL=C grep -a -m1 "^KEY: " "$f" 2>/dev/null)" || continue
        printf "%s\t%s\n" "$(stat -c %Y "$f")" "${key#KEY: }"
    done' _ "${SEARCH_DIR}" | sort -rn)"

if [[ -z "${searches}" ]]; then
    echo "  (none)"
else
    count=0 expired=0
    while IFS=$'\t' read -r mtime uri; do
        q="$(sed -n 's/.*[?&]q=\([^&]*\).*/\1/p' <<<"${uri}")"
        age=$(( now - mtime )) mark=""
        if (( ttl_secs > 0 && age > ttl_secs )); then
            mark="  (expired)"; expired=$(( expired + 1 ))
        fi
        printf '  %5s ago  %s%s\n' "$(human_age "${age}")" "$(urldecode "${q:-${uri}}")" "${mark}"
        count=$(( count + 1 ))
    done <<<"${searches}"
    echo "  ${count} cached search(es), ${expired} expired (refetched on next use, removed after ${nginx_inactive:-a while} unused)"
fi
echo

# --- Squid: cached pages -------------------------------------------------------------
# Each stored object starts with metadata containing its URL. Squid may keep a
# superseded copy for a while, so URLs are de-duplicated.

bold "Cached pages (Squid)"
# shellcheck disable=SC2016  # expanded by the inner sh, not here
urls="$(as_owner sh -c '
    find "$1" -type f -name "0*" 2>/dev/null | while IFS= read -r f; do
        head -c 4096 "$f" | LC_ALL=C grep -aom1 "https\?://[[:print:]]*"
    done' _ "${FETCH_DIR}" | sort -u)"

if [[ -z "${urls}" ]]; then
    echo "  (none on disk yet; very recent pages may still be only in memory)"
else
    total="$(wc -l <<<"${urls}")"
    echo "  ${total} page(s) from these sites:"
    sed -E 's#^https?://([^/:]+).*#\1#' <<<"${urls}" | sort | uniq -c | sort -rn \
        | awk '{printf "  %5d  %s\n", $1, $2}'
    if [[ ${show_urls} -eq 1 ]]; then
        echo
        bold "Cached page URLs"
        while IFS= read -r u; do printf '  %s\n' "${u}"; done <<<"${urls}"
    else
        echo "  (run with --urls to list every page)"
    fi
fi
