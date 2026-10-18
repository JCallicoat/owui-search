#!/usr/bin/env bash
# Installs Open WebUI + SearXNG (with nginx result cache and Squid fetch cache)
# as rootless Podman Quadlet units managed by systemd --user.
#
# Usage: ./install.sh [--autostart] [--remove-brave]
#                     [--forward-port PORT]... [--remove-forward-port PORT]...
#   --autostart                         start the services at each login
#   --remove-brave                      stop SearXNG using the Brave Search API
#   --forward-port PORT                 let Open WebUI reach a service on the
#                                       host's 127.0.0.1:PORT (repeatable, or
#                                       comma-separated: 8880,9000)
#   --remove-forward-port PORT          stop forwarding PORT
#   WEBUI_SECRET_KEY=... ./install.sh   reuse an existing Open WebUI secret key
#   BRAVE_API_KEY=... ./install.sh      enable SearXNG's Brave Search API engine
#                                       (braveapi) with this key
#
# Nothing is started and lingering is not enabled; the script prints how.
# Safe to re-run: existing configs, CA and secrets are kept; unit files and
# the Squid image are refreshed. A Brave key and forwarded ports set on an
# earlier run are kept unless changed with the options above.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/paths.sh
source "${SRC_DIR}/lib/paths.sh"
LLAMA_BIN="/usr/bin/llama-server"
LLAMA_PRESET="${HOME}/models/models.ini"

SEARXNG_IMAGE="docker.io/searxng/searxng:latest"
NGINX_IMAGE="docker.io/library/nginx:alpine"
SQUID_IMAGE="localhost/squid-bump:latest"
OWUI_IMAGE="ghcr.io/open-webui/open-webui:cuda"

autostart=0 remove_brave=0
add_ports=() del_ports=()
while (( $# > 0 )); do
    case "$1" in
        --autostart) autostart=1 ;;
        --remove-brave) remove_brave=1 ;;
        --forward-port|--remove-forward-port)
            (( $# >= 2 )) || { printf '%s needs a port number\n' "$1" >&2; exit 2; }
            IFS=, read -r -a ports <<<"$2"
            if [[ "$1" == --forward-port ]]; then add_ports+=("${ports[@]}"); else del_ports+=("${ports[@]}"); fi
            shift ;;
        --forward-port=*)        IFS=, read -r -a ports <<<"${1#*=}"; add_ports+=("${ports[@]}") ;;
        --remove-forward-port=*) IFS=, read -r -a ports <<<"${1#*=}"; del_ports+=("${ports[@]}") ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) printf 'unknown option: %s (see --help)\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Preflight -------------------------------------------------------------

[[ ${EUID} -ne 0 ]] || die "run this as your normal user, not root (it sets up rootless containers)"

if [[ -n "${BRAVE_API_KEY:-}" && ${remove_brave} -eq 1 ]]; then
    die "BRAVE_API_KEY and --remove-brave can't be used together"
fi
# Ports the owui pod already uses: Open WebUI listens on 8080 inside it, and
# 10000, 8888 and 3128 are always forwarded.
for p in "${add_ports[@]}" "${del_ports[@]}"; do
    if ! [[ "${p}" =~ ^[0-9]{1,5}$ ]] || (( 10#${p} < 1 || 10#${p} > 65535 )); then
        die "not a port number: '${p}'"
    fi
done
for p in "${add_ports[@]}"; do
    case "$(( 10#${p} ))" in
        8080) die "port 8080 can't be forwarded: Open WebUI listens on it inside the pod" ;;
        10000|8888|3128) die "port ${p} is already forwarded (llama.cpp, SearXNG and Squid)" ;;
    esac
done

# The key is written into YAML, so only accept the characters keys are made of.
if [[ -n "${BRAVE_API_KEY:-}" && ! "${BRAVE_API_KEY}" =~ ^[A-Za-z0-9_-]{8,}$ ]]; then
    die "BRAVE_API_KEY doesn't look like a Brave Search API key (expected letters, digits, '-' or '_')"
fi

for cmd in podman systemctl openssl curl; do
    command -v "${cmd}" >/dev/null || die "'${cmd}' not found"
done

podman_version="$(podman version --format '{{.Client.Version}}')"
if [[ "$(printf '%s\n' "5.0.0" "${podman_version}" | sort -V | head -1)" != "5.0.0" ]]; then
    die "Podman ${podman_version} found; 5.0 or newer is needed for Quadlet .pod units"
fi

systemctl --user show-environment >/dev/null 2>&1 \
    || die "can't reach the systemd user manager (are you in a login session?)"

# Quadlet volume paths can't contain whitespace.
for d in "${CONFIG_HOME}" "${CACHE_HOME}"; do
    [[ "${d}" != *[[:space:]]* ]] || die "path contains whitespace, which unit files can't use: ${d}"
done

if [[ "${UNIT_CONFIG_HOME}" != "${CONFIG_HOME}" ]]; then
    warn "XDG_CONFIG_HOME differs between this shell (${CONFIG_HOME}) and the systemd user manager (${UNIT_CONFIG_HOME}); configs go to the former, unit files to the latter so systemd finds them"
fi

info "Using config ${CONFIG_HOME}, cache ${CACHE_HOME}, units ${UNIT_CONFIG_HOME}"

[[ -x "${LLAMA_BIN}" ]] \
    || warn "${LLAMA_BIN} not found; llama-server.service will fail until it is installed"
[[ -e "${LLAMA_PRESET}" ]] \
    || warn "${LLAMA_PRESET} not found; llama-server.service needs it to start"

if command -v nvidia-ctk >/dev/null; then
    nvidia-ctk cdi list 2>/dev/null | grep -q 'nvidia.com/gpu=all' \
        || warn "NVIDIA CDI device 'nvidia.com/gpu=all' not listed; Open WebUI may start without GPU access (try: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml)"
else
    warn "nvidia-ctk not found; can't check that the GPU is available to containers"
fi

# --- Directories ------------------------------------------------------------

info "Creating directories"
mkdir -p "${CONFIG_DIR}"/{searxng,nginx,squid} \
         "${CACHE_DIR}"/{favicons,search,fetch} \
         "${OWUI_CONFIG_DIR}" "${LLAMA_CONFIG_DIR}" "${QUADLET_DIR}" "${SYSTEMD_USER_DIR}"
chmod 700 "${CONFIG_DIR}/squid" "${OWUI_CONFIG_DIR}" "${LLAMA_CONFIG_DIR}"

# install_if_missing SRC DEST: keeps any existing (possibly edited) config.
install_if_missing() {
    if [[ -e "$2" ]]; then
        echo "    keeping existing $2"
    else
        install -m 644 "$1" "$2"
        echo "    installed $2"
    fi
}

# --- Configs ----------------------------------------------------------------

info "Installing configuration"
settings_yml="${CONFIG_DIR}/searxng/settings.yml"
if [[ -e "${settings_yml}" ]]; then
    echo "    keeping existing ${settings_yml}"
else
    # Private until the ownership step below makes it readable for SearXNG
    # only: it holds SearXNG's secret key and possibly the Brave API key.
    (umask 077
     sed "s/@SECRET_KEY@/$(openssl rand -hex 32)/" \
         "${SRC_DIR}/config/searxng/settings.yml.template" > "${settings_yml}")
    echo "    installed ${settings_yml}"
fi
install_if_missing "${SRC_DIR}/config/searxng/favicons.toml" "${CONFIG_DIR}/searxng/favicons.toml"
# Earlier versions let the SearXNG image chown this directory to its own user
# (a subordinate UID). Hand it back to you (UID 0 in the user namespace).
# Group and permissions are set once the SearXNG image is pulled, below.
podman unshare chown -R 0:0 "${CONFIG_DIR}/searxng"

# Brave Search API: install.sh owns the block between these markers in
# settings.yml and leaves the rest of the file alone.
BRAVE_BEGIN='# >>> braveapi: managed by install.sh >>>'
BRAVE_END='# <<< braveapi: managed by install.sh <<<'

# without_brave_block FILE: FILE's contents minus the managed block.
without_brave_block() {
    awk -v b="${BRAVE_BEGIN}" -v e="${BRAVE_END}" \
        '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$1"
}

# write_settings CONTENT: replace settings.yml atomically, keeping it private.
write_settings() {
    local tmp
    tmp="$(mktemp "${settings_yml}.XXXXXX")"
    printf '%s\n' "$1" > "${tmp}"
    chmod 600 "${tmp}"
    mv -f "${tmp}" "${settings_yml}"
}

brave_status="not configured"
if grep -qxF "${BRAVE_BEGIN}" "${settings_yml}"; then
    brave_status="configured (kept from an earlier run)"
fi

if [[ ${remove_brave} -eq 1 ]]; then
    if grep -qxF "${BRAVE_BEGIN}" "${settings_yml}"; then
        write_settings "$(without_brave_block "${settings_yml}")"
        echo "    removed the Brave Search API engine from ${settings_yml}"
    fi
    brave_status="not configured"
elif [[ -n "${BRAVE_API_KEY:-}" ]]; then
    base="$(without_brave_block "${settings_yml}")"
    # The block adds a top-level engines: list. YAML allows each key only
    # once (a second one silently replaces the first), so if you have your
    # own engines: list, braveapi has to go into it by hand.
    if grep -q '^engines:' <<<"${base}"; then
        die "${settings_yml} already has an engines: section; add braveapi to it yourself (see README, \"Brave Search API\") instead of using BRAVE_API_KEY"
    fi
    write_settings "${base%$'\n'}

${BRAVE_BEGIN}
# Brave Search API engine (official API, uses your key and its quota).
# Change the key: BRAVE_API_KEY=... ./install.sh   Remove: ./install.sh --remove-brave
engines:
  - name: braveapi
    api_key: \"${BRAVE_API_KEY}\"
    inactive: false
    shortcut: bra
${BRAVE_END}"
    echo "    configured the Brave Search API engine in ${settings_yml}"
    brave_status="configured"
fi

install_if_missing "${SRC_DIR}/config/nginx/default.conf"    "${CONFIG_DIR}/nginx/default.conf"
install_if_missing "${SRC_DIR}/config/squid/squid.conf"      "${CONFIG_DIR}/squid/squid.conf"
# Image build inputs are always refreshed.
install -m 644 "${SRC_DIR}/config/squid/Containerfile" "${CONFIG_DIR}/squid/Containerfile"
install -m 755 "${SRC_DIR}/config/squid/entrypoint.sh" "${CONFIG_DIR}/squid/entrypoint.sh"

env_file="${OWUI_CONFIG_DIR}/open-webui.env"
if [[ -e "${env_file}" ]]; then
    echo "    keeping existing ${env_file}"
else
    if [[ -n "${WEBUI_SECRET_KEY:-}" ]]; then
        key="${WEBUI_SECRET_KEY}"
    else
        key="$(openssl rand -hex 32)"
        warn "generated a new WEBUI_SECRET_KEY; existing browser sessions will be signed out (set WEBUI_SECRET_KEY=... to reuse your old one)"
    fi
    (umask 077; printf 'WEBUI_SECRET_KEY=%s\n' "${key}" > "${env_file}")
    echo "    created ${env_file}"
fi

# Extra forwarded ports: one per line, kept between runs.
saved_ports=()
if [[ -r "${FORWARD_PORTS_FILE}" ]]; then
    mapfile -t saved_ports < <(grep -E '^[0-9]+$' "${FORWARD_PORTS_FILE}")
fi
if (( ${#add_ports[@]} + ${#del_ports[@]} > 0 )); then
    new_ports=()
    for p in "${saved_ports[@]}" "${add_ports[@]}"; do
        p=$(( 10#${p} ))
        for d in "${del_ports[@]}"; do (( p == 10#${d} )) && continue 2; done
        new_ports+=("${p}")
    done
    if (( ${#new_ports[@]} > 0 )); then
        printf '%s\n' "${new_ports[@]}" | sort -nu > "${FORWARD_PORTS_FILE}"
    else
        rm -f "${FORWARD_PORTS_FILE}"
    fi
    saved_ports=()
    [[ -r "${FORWARD_PORTS_FILE}" ]] && mapfile -t saved_ports < "${FORWARD_PORTS_FILE}"
    echo "    forwarded ports saved in ${FORWARD_PORTS_FILE}: ${saved_ports[*]:-none}"
fi
extra_forwards=""
for p in "${saved_ports[@]}"; do extra_forwards+=",-T,${p}"; done

new_llama_key=0
if [[ -e "${LLAMA_KEY_FILE}" ]]; then
    echo "    keeping existing ${LLAMA_KEY_FILE}"
else
    (umask 077; printf 'sk-local-%s\n' "$(openssl rand -hex 24)" > "${LLAMA_KEY_FILE}")
    new_llama_key=1
    echo "    created ${LLAMA_KEY_FILE}"
fi

# --- Squid CA ---------------------------------------------------------------

if [[ -e "${CONFIG_DIR}/squid/ca.pem" && -e "${CONFIG_DIR}/squid/ca.key" ]]; then
    info "Keeping existing Squid CA"
else
    info "Generating local CA for Squid"
    (umask 077
     openssl req -new -newkey rsa:2048 -sha256 -days 825 -nodes -x509 \
         -subj "/CN=Local Squid Cache CA" \
         -keyout "${CONFIG_DIR}/squid/ca.key" -out "${CONFIG_DIR}/squid/ca.pem" 2>/dev/null)
    chmod 600 "${CONFIG_DIR}/squid/ca.key"
    chmod 644 "${CONFIG_DIR}/squid/ca.pem"
fi

# --- Images -----------------------------------------------------------------

info "Building Squid image (${SQUID_IMAGE})"
# Rebuilt from scratch each run so Squid gets current Debian packages:
#   --layers=false  no build cache, no intermediate images
#   --pull=newer    pull a newer debian:stable-slim if the registry has one
old_squid_id="$(podman image inspect --format '{{.Id}}' "${SQUID_IMAGE}" 2>/dev/null || true)"
podman build --layers=false --pull=newer -q -t "${SQUID_IMAGE}" "${CONFIG_DIR}/squid" >/dev/null
new_squid_id="$(podman image inspect --format '{{.Id}}' "${SQUID_IMAGE}")"
# Remove only the image this build replaced. It stays if a running
# fetch-cache container still uses it; restarting the service frees it.
if [[ -n "${old_squid_id}" && "${old_squid_id}" != "${new_squid_id}" ]]; then
    if podman rmi "${old_squid_id}" >/dev/null 2>&1; then
        echo "    removed previous image ${old_squid_id:0:12}"
    else
        echo "    previous image ${old_squid_id:0:12} still in use; remove it later with: podman rmi ${old_squid_id:0:12}"
    fi
fi

info "Pulling images"
for img in "${SEARXNG_IMAGE}" "${NGINX_IMAGE}" "${OWUI_IMAGE}"; do
    echo "    ${img}"
    podman pull -q "${img}" >/dev/null
done

# CA bundle for Open WebUI: Debian's system roots + the local CA.
info "Building CA bundle for Open WebUI"
podman run --rm --entrypoint cat "${SQUID_IMAGE}" /etc/ssl/certs/ca-certificates.crt \
    > "${CONFIG_DIR}/squid/owui-bundle.pem"
cat "${CONFIG_DIR}/squid/ca.pem" >> "${CONFIG_DIR}/squid/owui-bundle.pem"
chmod 644 "${CONFIG_DIR}/squid/owui-bundle.pem"

# --- Cache directory ownership ----------------------------------------------
# In rootless Podman a directory you own appears as root inside the
# container, so hand each cache directory to the user the service runs as.

# image_user IMAGE [USERNAME]: prints "uid:gid" of the image's default user,
# or of USERNAME if the default user is root.
image_user() {
    local ids
    ids="$(podman run --rm --entrypoint sh "$1" -c 'echo "$(id -u):$(id -g)"')"
    if [[ "${ids}" == "0:0" && -n "${2:-}" ]]; then
        ids="$(podman run --rm --entrypoint sh "$1" -c "echo \"\$(id -u $2):\$(id -g $2)\"")"
    fi
    printf '%s' "${ids}"
}

info "Setting cache directory ownership"
searxng_ids="$(image_user "${SEARXNG_IMAGE}" searxng)"
nginx_ids="$(image_user "${NGINX_IMAGE}" nginx)"
podman unshare chown -R "${searxng_ids}" "${CACHE_DIR}/favicons"
podman unshare chown -R "${nginx_ids}"   "${CACHE_DIR}/search"
# Squid's entrypoint fixes ownership of the fetch cache itself.
echo "    favicons -> ${searxng_ids}, search -> ${nginx_ids}"

# SearXNG's config holds its secret key and possibly the Brave API key: owned
# by you, group-readable for the container's searxng group, nothing for other
# users on this machine.
podman unshare chown -R "0:${searxng_ids#*:}" "${CONFIG_DIR}/searxng"
chmod 750 "${CONFIG_DIR}/searxng"
find "${CONFIG_DIR}/searxng" -type f -exec chmod 640 {} +
echo "    searxng config -> 0:${searxng_ids#*:}, mode 750/640"

# --- Quadlet units ----------------------------------------------------------

info "Installing systemd units to ${QUADLET_DIR}"
# Quadlet enables any unit with an [Install] section on daemon-reload, so
# that section is only added with --autostart.
# render SRC DEST: fill in @CONFIG_HOME@ / @CACHE_HOME@ with resolved paths,
# and @EXTRA_FORWARDS@ with the extra forwarded ports (digits and commas only).
render() {
    local cfg cache
    cfg="$(printf '%s' "${CONFIG_HOME}" | sed 's/[\\&|]/\\&/g')"
    cache="$(printf '%s' "${CACHE_HOME}" | sed 's/[\\&|]/\\&/g')"
    sed -e "s|@CONFIG_HOME@|${cfg}|g" -e "s|@CACHE_HOME@|${cache}|g" \
        -e "s|@EXTRA_FORWARDS@|${extra_forwards}|g" "$1" > "$2"
    chmod 644 "$2"
}

for f in "${SRC_DIR}"/quadlet/*; do
    dest="${QUADLET_DIR}/$(basename "${f}")"
    render "${f}" "${dest}"
    if [[ ${autostart} -eq 1 ]]; then
        printf '\n[Install]\nWantedBy=default.target\n' >> "${dest}"
    fi
    echo "    $(basename "${f}")"
done

quadlet_bin=""
for p in /usr/libexec/podman/quadlet /usr/lib/podman/quadlet; do
    [[ -x "${p}" ]] && quadlet_bin="${p}" && break
done
if [[ -n "${quadlet_bin}" ]]; then
    "${quadlet_bin}" -dryrun -user >/dev/null 2>"${CACHE_DIR}/.quadlet-check.log" \
        || die "Quadlet rejected the unit files; see ${CACHE_DIR}/.quadlet-check.log"
    rm -f "${CACHE_DIR}/.quadlet-check.log"
fi

info "Installing llama-server.service to ${SYSTEMD_USER_DIR}"
# A plain user unit (not a container). It has no [Install] section; Open WebUI
# pulls it in when it starts.
render "${SRC_DIR}/systemd/llama-server.service" "${SYSTEMD_USER_DIR}/llama-server.service"

systemctl --user daemon-reload

# --- Next steps ---------------------------------------------------------------

info "Installed. Nothing has been started."

if systemctl --user is-active --quiet open-webui.service \
   || systemctl --user is-active --quiet search-pod.service \
   || systemctl --user is-active --quiet llama-server.service; then
    cat <<EOF

The services are already running. Restart them to apply updated units:
  systemctl --user restart llama-server.service search-pod.service open-webui.service
EOF
elif command -v ss >/dev/null && ss -Hltn 'sport = :10000' | grep -q .; then
    cat <<EOF

Something is already listening on port 10000, probably a llama-server you
started by hand. Stop it first, or llama-server.service will fail to bind.
EOF
fi

cat <<EOF

Start everything (open-webui pulls in llama-server, the search pod and its
containers):
  systemctl --user start open-webui.service
Starting replaces any existing containers or pods with the same names
(open-webui, searxng, searxng-proxy, fetch-cache; pods owui and search),
including an open-webui container you started by hand.

Then check the caches and Open WebUI:
  ${SRC_DIR}/check.sh

Open WebUI now requires a login. If you used it without one before, sign in
as admin@localhost / admin, then change the password right away in
Settings → Account. New sign-ups are disabled.

llama-server now requires an API key. In Open WebUI, Admin → Settings →
Connections, edit the http://127.0.0.1:10000/v1 connection and set its key
to the contents of:
  ${LLAMA_KEY_FILE}
(show it with: cat ${LLAMA_KEY_FILE})
EOF

if [[ ${new_llama_key} -eq 0 ]]; then
    echo "  The key file already existed, so if the connection was set up before, it's unchanged."
fi

if [[ ${autostart} -eq 1 ]]; then
    cat <<EOF

Autostart is on: the services start when you log in.
To turn it off, re-run ./install.sh without --autostart.
EOF
else
    cat <<EOF

To start the services automatically at login, re-run:
  ./install.sh --autostart
EOF
fi

cat <<EOF

User services stop when your last session ends. To keep them running while
you're logged out (and, with --autostart, start them at boot), enable
lingering for your user:
  loginctl enable-linger ${USER}
This lets any of your user's services run without a login session.
Undo it with:
  loginctl disable-linger ${USER}

In Open WebUI (Admin → Settings → Web Search):
  Engine:                  searxng
  SearXNG query URL:       http://127.0.0.1:8888/search?q=<query>
  Trust proxy environment: on (so page fetches go through the Squid cache)
llama.cpp connection:      http://127.0.0.1:10000/v1, key from ${LLAMA_KEY_FILE}

Brave Search API engine:   ${brave_status}
Extra forwarded ports:     ${saved_ports[*]:-none}
EOF

if (( ${#saved_ports[@]} > 0 )); then
    cat <<EOF
  Open WebUI reaches these at http://127.0.0.1:PORT; restart the owui pod
  to apply changes: systemctl --user restart owui-pod.service open-webui.service
EOF
fi

if [[ "${brave_status}" == configured* ]]; then
    cat <<EOF
  SearXNG now queries Brave's API alongside its other engines. To use only
  Brave, set the SearXNG query URL to:
    http://127.0.0.1:8888/search?engines=braveapi
  Restart SearXNG to apply a changed key: systemctl --user restart searxng
EOF
else
    cat <<EOF
  To enable it: BRAVE_API_KEY=<your key> ./install.sh (see README)
EOF
fi

cat <<EOF

Manage:  systemctl --user {status,restart,stop} open-webui.service search-pod.service llama-server.service
Logs:    journalctl --user -u open-webui -u llama-server -u searxng -u searxng-proxy -u fetch-cache
EOF
