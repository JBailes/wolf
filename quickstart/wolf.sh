#!/usr/bin/env bash
# wolf.sh -- Deploy Wolf cloud gaming with automatic environment detection
#
# Detects the runtime environment and deploys Wolf accordingly:
#   - Proxmox:  Creates a GPU-passthrough LXC, installs Docker, deploys Wolf
#   - LXC:     Creates a GPU-passthrough LXC via lxc-create, deploys Wolf
#   - Incus:   Creates a GPU-passthrough container via Incus, deploys Wolf
#   - Unraid:  Deploys Wolf via docker-compose with persistent appdata
#   - TrueNAS: Deploys Wolf via docker-compose on a ZFS dataset
#   - Podman:  Installs a Podman Quadlet (systemd-managed container)
#   - Docker:  Deploys Wolf via docker-compose
#
# Prereq: GPU drivers must be installed on the host
#
# Usage:
#   ./wolf.sh [OPTIONS]
#
# Options (all are optional; unused flags for a given environment are ignored):
#   --cpu <cores>          CPU cores              (Proxmox, LXC, Incus)
#   --ram <mb>             RAM in MB              (Proxmox, LXC, Incus)
#   --disk <gb>            Disk in GB             (Proxmox, LXC, Incus)
#   --name <name>          Container name         (LXC, Incus; default: wolf)
#   --ctid <id>            Container ID           (Proxmox; default: 120)
#   --ip <addr>            Container IP address   (Proxmox; default: auto)
#   --gw <addr>            Gateway IP             (Proxmox; default: auto)
#   --cidr <bits>          Subnet prefix length   (Proxmox; default: auto)
#   --storage <name>       Proxmox storage name   (Proxmox; default: prompt)
#   --render-node <path>   GPU render device      (all; default: auto-detected)
#   --appdata <path>       App data directory      (Unraid, TrueNAS; default: auto)
#   --pool <name>          ZFS pool name           (TrueNAS; default: auto-detected)

set -euo pipefail

# =========================================================================
# Defaults
# =========================================================================

CTID=120
CT_CPU=4
CT_RAM=4096
CT_DISK=16
CT_IP="auto"
CT_GW="auto"
CT_CIDR="auto"
CT_STORAGE="auto"
LXC_NAME="wolf"
APPDATA="/mnt/user/appdata/wolf"
ZFS_POOL="auto"

IMAGE_STORAGE="${IMAGE_STORAGE:-isos}"
TEMPLATE="${TEMPLATE:-${IMAGE_STORAGE}:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst}"
LAN_BRIDGE="vmbr0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="https://raw.githubusercontent.com/JBailes/wolf/main/quickstart"

# =========================================================================
# Argument parsing
# =========================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ctid)        CTID="${2:?--ctid requires a value}"; shift 2 ;;
            --cpu)         CT_CPU="${2:?--cpu requires a value}"; shift 2 ;;
            --ram)         CT_RAM="${2:?--ram requires a value}"; shift 2 ;;
            --disk)        CT_DISK="${2:?--disk requires a value}"; shift 2 ;;
            --ip)          CT_IP="${2:?--ip requires a value}"; shift 2 ;;
            --gw)          CT_GW="${2:?--gw requires a value}"; shift 2 ;;
            --cidr)        CT_CIDR="${2:?--cidr requires a value}"; shift 2 ;;
            --storage)     CT_STORAGE="${2:?--storage requires a value}"; shift 2 ;;
            --name)        LXC_NAME="${2:?--name requires a value}"; shift 2 ;;
            --render-node) SELECTED_RENDER_NODE="${2:?--render-node requires a value}"; shift 2 ;;
            --appdata)     APPDATA="${2:?--appdata requires a value}"; shift 2 ;;
            --pool)        ZFS_POOL="${2:?--pool requires a value}"; shift 2 ;;
            *)             shift ;;
        esac
    done
}

# =========================================================================
# Script fetching
# =========================================================================

# Download a file. Usage: fetch_url <url> <output_file>
fetch_url() {
    local url="$1" output="$2"
    if command -v curl &>/dev/null; then
        curl -fsSL "$url" -o "$output"
    elif command -v wget &>/dev/null; then
        wget -qO "$output" "$url"
    else
        echo "ERROR: Neither curl nor wget is available. Install one of them and try again." >&2
        exit 1
    fi
}

# Ensure a script exists locally, downloading it if needed.
# Usage: ensure_script <filename>
ensure_script() {
    local name="$1"
    local path="${SCRIPT_DIR}/${name}"

    if [[ -f "$path" ]]; then
        return
    fi

    echo "==> Downloading ${name}..."
    fetch_url "${BASE_URL}/${name}" "$path"
    chmod +x "$path"
}

# =========================================================================
# Environment detection
# =========================================================================

detect_environment() {
    command -v pveversion &>/dev/null && { echo "proxmox"; return; }
    command -v lxc-create &>/dev/null && { echo "lxc"; return; }
    command -v incus &>/dev/null     && { echo "incus"; return; }
    [[ -f /etc/unraid-version ]]     && { echo "unraid"; return; }
    command -v midclt &>/dev/null    && { echo "truenas"; return; }
    command -v podman &>/dev/null    && { echo "podman"; return; }
    command -v docker &>/dev/null    && { echo "docker"; return; }

    echo "ERROR: Could not detect environment. Install Proxmox, LXC, Podman, Docker, or run on Unraid/TrueNAS." >&2
    exit 1
}

# =========================================================================
# Main
# =========================================================================

ENVIRONMENT=$(detect_environment)
parse_args "$@"

# Determine which scripts are needed for this environment
case "$ENVIRONMENT" in
    proxmox) NEEDED_SCRIPTS=(common.sh proxmox.sh configure.sh) ;;
    lxc)     NEEDED_SCRIPTS=(common.sh lxc.sh configure.sh) ;;
    incus)   NEEDED_SCRIPTS=(common.sh incus.sh configure.sh) ;;
    unraid)  NEEDED_SCRIPTS=(common.sh unraid.sh) ;;
    truenas) NEEDED_SCRIPTS=(common.sh truenas.sh) ;;
    podman)  NEEDED_SCRIPTS=(common.sh podman.sh) ;;
    docker)  NEEDED_SCRIPTS=(common.sh docker.sh) ;;
esac

# Fetch any missing scripts
for script in "${NEEDED_SCRIPTS[@]}"; do
    ensure_script "$script"
done

# Source common helpers, then the environment-specific script
source "${SCRIPT_DIR}/common.sh"

case "$ENVIRONMENT" in
    proxmox) source "${SCRIPT_DIR}/proxmox.sh"; proxmox_main ;;
    lxc)     source "${SCRIPT_DIR}/lxc.sh";     lxc_main ;;
    incus)   source "${SCRIPT_DIR}/incus.sh";    incus_main ;;
    unraid)  source "${SCRIPT_DIR}/unraid.sh";   unraid_main ;;
    truenas) source "${SCRIPT_DIR}/truenas.sh";  truenas_main ;;
    podman)  source "${SCRIPT_DIR}/podman.sh";   podman_main ;;
    docker)  source "${SCRIPT_DIR}/docker.sh";   docker_main ;;
esac
