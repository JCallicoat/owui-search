#!/usr/bin/env bash
# Checks that SearXNG, both caches and Open WebUI are working.
# Run after: systemctl --user start open-webui.service
set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/paths.sh
source "${SRC_DIR}/lib/paths.sh"
CA="${CONFIG_DIR}/squid/ca.pem"
ok=1

pass() { printf '  \033[1;32mOK\033[0m    %s\n' "$*"; }
fail() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; ok=0; }

header() {  # header URL NAME -> value of response header NAME
    curl -s -o /dev/null -D - "$1" | tr -d '\r' \
        | awk -F': ' -v h="$2" 'tolower($1)==tolower(h){print $2}'
}

echo "Waiting for SearXNG..."
for _ in $(seq 1 30); do
    curl -sf -o /dev/null 'http://127.0.0.1:8888/search?q=test&format=json' && break
    sleep 2
done

url="http://127.0.0.1:8888/search?q=cache+check+$(date +%s)&format=json"
s1="$(header "${url}" X-Cache-Status)"
s2="$(header "${url}" X-Cache-Status)"
if [[ "${s2}" == "HIT" ]]; then
    pass "SearXNG + result cache (${s1:-?} then ${s2})"
else
    fail "SearXNG + result cache (got '${s1:-none}' then '${s2:-none}'; see: journalctl --user -u searxng -u searxng-proxy)"
fi

# Brave Search API engine, if install.sh configured it. Asks SearXNG for
# braveapi results only, so this uses one request of your Brave quota.
if grep -qxF '# >>> braveapi: managed by install.sh >>>' "${CONFIG_DIR}/searxng/settings.yml" 2>/dev/null; then
    brave_json="$(curl -s "http://127.0.0.1:8888/search?q=brave+check+$(date +%s)&format=json&engines=braveapi")"
    brave_err="$(grep -Eo '\["braveapi", ?"[^"]*"\]' <<<"${brave_json}" \
                 | sed -E 's/^\["braveapi", ?"//; s/"\]$//' || true)"
    # If braveapi failed to load, SearXNG ignores engines=braveapi and uses its
    # other engines, so check the results really came from braveapi.
    if [[ -n "${brave_err}" ]]; then
        fail "Brave Search API engine: ${brave_err} (check the key and your plan in the Brave dashboard; see: journalctl --user -u searxng)"
    elif grep -Eq '"engine": ?"braveapi"' <<<"${brave_json}"; then
        pass "Brave Search API engine returns results"
    else
        fail "Brave Search API engine returned no results; it may have failed to load (see: journalctl --user -u searxng)"
    fi
fi

for _ in 1 2; do
    curl -s -o /dev/null --noproxy '' --cacert "${CA}" \
        -x http://127.0.0.1:3128 https://example.com/
done
sleep 1
f2="$(podman exec fetch-cache tail -n 1 /var/log/squid/access.log 2>/dev/null | awk '{print $4}')"
if [[ "${f2}" == *HIT* ]]; then
    pass "Squid fetch cache (${f2})"
else
    fail "Squid fetch cache (last request: '${f2:-none}'; see: journalctl --user -u fetch-cache)"
fi

echo "Waiting for Open WebUI (first start can take a few minutes)..."
for _ in $(seq 1 90); do
    curl -sf -o /dev/null http://127.0.0.1:3000/health && break
    sleep 2
done
if curl -sf -o /dev/null http://127.0.0.1:3000/health; then
    pass "Open WebUI (http://127.0.0.1:3000)"
else
    fail "Open WebUI not responding (see: journalctl --user -u open-webui -f)"
fi

# /health needs no key, so this tests the network path from Open WebUI.
llama_ok=0
for _ in $(seq 1 15); do
    if podman exec open-webui curl -sf -o /dev/null http://127.0.0.1:10000/health 2>/dev/null; then
        llama_ok=1; break
    fi
    sleep 2
done
if [[ ${llama_ok} -eq 1 ]]; then
    pass "llama.cpp reachable from Open WebUI"
else
    fail "llama.cpp not reachable from Open WebUI (see: systemctl --user status llama-server; journalctl --user -u llama-server)"
fi

# The API must refuse requests without the key and accept them with it.
# The key is read from a file descriptor so it never appears in ps output.
no_key="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:10000/v1/models)"
if [[ -r "${LLAMA_KEY_FILE}" ]]; then
    with_key="$(curl -s -o /dev/null -w '%{http_code}' \
        -H @<(printf 'Authorization: Bearer %s\n' "$(head -n 1 "${LLAMA_KEY_FILE}")") \
        http://127.0.0.1:10000/v1/models)"
else
    with_key="no key file"
fi
if [[ "${no_key}" == "401" && "${with_key}" == "200" ]]; then
    pass "llama.cpp API key enforced (no key: 401, with key: 200)"
else
    fail "llama.cpp API key (no key: ${no_key}, with key: ${with_key}; expected 401 and 200)"
fi

# Open WebUI's public config reports whether login and sign-ups are enabled.
owui_cfg="$(curl -s http://127.0.0.1:3000/api/config)"
auth="$(grep -Eo '"auth": ?(true|false)' <<<"${owui_cfg}" | head -n 1 | grep -Eo 'true|false')"
signup="$(grep -Eo '"enable_signup": ?(true|false)' <<<"${owui_cfg}" | head -n 1 | grep -Eo 'true|false')"
if [[ "${auth}" == "true" ]]; then
    pass "Open WebUI requires login"
else
    fail "Open WebUI login is off (auth: ${auth:-unknown}); check WEBUI_AUTH in the unit"
fi
if [[ "${signup}" == "false" ]]; then
    pass "Open WebUI sign-ups disabled"
else
    fail "Open WebUI sign-ups are enabled (${signup:-unknown}); turn off Admin → Settings → General → Enable New Sign Ups"
fi


# Extra ports forwarded with install.sh --forward-port: each should answer an
# HTTP request from inside Open WebUI's container (any status code counts).
if [[ -r "${FORWARD_PORTS_FILE}" ]]; then
    while IFS= read -r port; do
        [[ "${port}" =~ ^[0-9]+$ ]] || continue
        code="$(podman exec open-webui curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                "http://127.0.0.1:${port}/" 2>/dev/null || true)"
        if [[ -n "${code}" && "${code}" != "000" ]]; then
            pass "Forwarded port ${port} reachable from Open WebUI (HTTP ${code})"
        else
            fail "Forwarded port ${port}: no HTTP answer from inside Open WebUI (is the service running on the host's 127.0.0.1:${port}, and was the owui pod restarted after install.sh?)"
        fi
    done < "${FORWARD_PORTS_FILE}"
fi

[[ ${ok} -eq 1 ]]
