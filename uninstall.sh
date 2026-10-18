#!/usr/bin/env bash
# Stops and removes the Open WebUI and search pods and their systemd units.
#
# Usage: ./uninstall.sh           keep configs, caches and Open WebUI data
#        ./uninstall.sh --purge   also delete the searxng, open-webui and
#                                 llama-server config dirs (incl. the llama
#                                 API key), the searxng cache dir and the
#                                 Squid image
# Paths follow XDG_CONFIG_HOME / XDG_CACHE_HOME, the same way install.sh does.
# The "open-webui" volume (chats, settings) is never deleted by this script.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/paths.sh
source "${SRC_DIR}/lib/paths.sh"
FILES=(owui.pod open-webui.container search.pod searxng.container
       searxng-proxy.container fetch-cache.container)

purge=0
[[ "${1:-}" == "--purge" ]] && purge=1

systemctl --user stop open-webui.service owui-pod.service fetch-cache.service \
    searxng-proxy.service searxng.service search-pod.service llama-server.service 2>/dev/null || true

rm -f "${SYSTEMD_USER_DIR}/llama-server.service"

for f in "${FILES[@]}"; do
    rm -f "${QUADLET_DIR}/${f}"
done
systemctl --user daemon-reload

for p in owui search; do
    podman pod rm -f --ignore "${p}" >/dev/null
done

if [[ ${purge} -eq 1 ]]; then
    # Cache files are owned by container users, so delete them inside the user namespace.
    podman unshare rm -rf "${CACHE_DIR}"
    # Also inside the user namespace: files a container chowned to one of
    # your subordinate UIDs can't be removed by a plain rm.
    podman unshare rm -rf "${CONFIG_DIR}" "${OWUI_CONFIG_DIR}" "${LLAMA_CONFIG_DIR}"
    podman rmi --ignore localhost/squid-bump:latest >/dev/null
    echo "Removed units, configs, caches and the Squid image."
else
    echo "Removed units. Configs and caches kept; run with --purge to delete them."
fi
echo "The open-webui volume was kept (remove with: podman volume rm open-webui)."
