# shellcheck shell=bash disable=SC2034
# Path resolution shared by install.sh, uninstall.sh and check.sh.
# Sourced, not executed.
#
# Follows the XDG Base Directory spec: XDG_CONFIG_HOME / XDG_CACHE_HOME are
# used when set to an absolute path, otherwise ~/.config and ~/.cache.

# xdg_dir VAR DEFAULT: value of VAR if it's an absolute path, else DEFAULT.
xdg_dir() {
    local val="${!1:-}"
    if [[ "${val}" == /* ]]; then
        printf '%s' "${val%/}"
    else
        printf '%s' "$2"
    fi
}

CONFIG_HOME="$(xdg_dir XDG_CONFIG_HOME "${HOME}/.config")"
CACHE_HOME="$(xdg_dir XDG_CACHE_HOME "${HOME}/.cache")"

# systemd and Quadlet look for user units under the *systemd user manager's*
# XDG_CONFIG_HOME, which can differ from this shell's if it was only set in a
# shell rc file. Use the manager's value for unit directories.
UNIT_CONFIG_HOME="${CONFIG_HOME}"
if manager_env="$(systemctl --user show-environment 2>/dev/null)"; then
    manager_cfg="$(printf '%s\n' "${manager_env}" | sed -n 's/^XDG_CONFIG_HOME=//p')"
    if [[ "${manager_cfg}" == /* ]]; then
        UNIT_CONFIG_HOME="${manager_cfg%/}"
    else
        UNIT_CONFIG_HOME="${HOME}/.config"
    fi
fi

CONFIG_DIR="${CONFIG_HOME}/searxng"
CACHE_DIR="${CACHE_HOME}/searxng"
OWUI_CONFIG_DIR="${CONFIG_HOME}/open-webui"
# Extra host loopback ports forwarded into the owui pod (install.sh --forward-port)
FORWARD_PORTS_FILE="${OWUI_CONFIG_DIR}/forward-ports"
LLAMA_CONFIG_DIR="${CONFIG_HOME}/llama-server"
LLAMA_KEY_FILE="${LLAMA_CONFIG_DIR}/api-key"
QUADLET_DIR="${UNIT_CONFIG_HOME}/containers/systemd"
SYSTEMD_USER_DIR="${UNIT_CONFIG_HOME}/systemd/user"
