#!/usr/bin/env bash
# wolf.sh -- Deploy Wolf cloud gaming with automatic environment detection
#
# Detects the runtime environment and deploys Wolf accordingly:
#   - Proxmox:  Creates a GPU-passthrough LXC via pct, installs Docker
#               inside, deploys Wolf + Wolf Den via docker-compose
#   - LXC:     Creates a GPU-passthrough LXC via lxc-create, same as above
#   - Incus:   Creates a GPU-passthrough container via Incus, same as above
#   - Unraid:  Deploys Wolf + Wolf Den via docker-compose with persistent
#              appdata paths and boot-persistent udev rules
#   - TrueNAS: Deploys Wolf + Wolf Den via docker-compose on a ZFS
#              dataset with update-persistent init scripts
#   - Podman:  Installs a Podman Quadlet (systemd-managed container)
#   - Docker:  Deploys Wolf + Wolf Den via docker-compose
#
# Prereq: GPU drivers must be installed on the host
#
# Usage:
#   ./wolf.sh [OPTIONS]
#   ./wolf.sh --configure   # (internal) Run inside an LXC container
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

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

# =========================================================================
# Argument parsing
# =========================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --configure)   shift ;;
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
# Shared helpers
# =========================================================================

install_udev_rules() {
    info "Setting up udev rules for virtual input"
    cat > /etc/udev/rules.d/85-wolf-virtual-inputs.rules <<'UDEV'
KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput", TAG+="uaccess"
KERNEL=="uhid", GROUP="input", MODE="0660", TAG+="uaccess"
KERNEL=="hidraw*", ATTRS{name}=="Wolf PS5 (virtual) pad", GROUP="input", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf X-Box One (virtual) pad", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf PS5 (virtual) pad", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf gamepad (virtual) motion sensors", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf Nintendo (virtual) pad", MODE="0660", ENV{ID_SEAT}="seat9"
UDEV
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger 2>/dev/null || true
}

# Detect NVIDIA driver version. Sets NV_VERSION or exits.
detect_nvidia_version() {
    NV_VERSION=$(cat /sys/module/nvidia/version 2>/dev/null) || true
    [[ -n "$NV_VERSION" ]] && return

    if [[ -f /proc/driver/nvidia/version ]]; then
        NV_VERSION=$(awk '/NVRM version/{print $8}' /proc/driver/nvidia/version) || true
        [[ -n "$NV_VERSION" ]] && return
    fi

    if command -v nvidia-smi &>/dev/null; then
        NV_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1) || true
        [[ -n "$NV_VERSION" ]] && return
    fi

    err "Cannot determine NVIDIA driver version. Is the NVIDIA driver installed?"
}

# Build NVIDIA driver volume. Usage: build_nvidia_volume <docker|podman>
build_nvidia_volume() {
    local tool="$1"

    [[ -z "${NV_VERSION:-}" ]] && detect_nvidia_version
    info "NVIDIA driver version: ${NV_VERSION}"

    if "$tool" volume inspect nvidia-driver-vol &>/dev/null; then
        info "NVIDIA driver volume already exists"
        return
    fi

    info "Building NVIDIA driver volume (this may take a few minutes)..."
    curl -fsSL https://raw.githubusercontent.com/games-on-whales/gow/master/images/nvidia-driver/Dockerfile \
        | "$tool" build -t gow/nvidia-driver:latest -f - --build-arg NV_VERSION="${NV_VERSION}" .

    if [[ "$tool" == "podman" ]]; then
        local tmp_ctr
        tmp_ctr=$("$tool" create --mount source=nvidia-driver-vol,destination=/usr/nvidia gow/nvidia-driver:latest sh)
        "$tool" start "$tmp_ctr"
        "$tool" rm "$tmp_ctr" 2>/dev/null || true
    else
        "$tool" create --rm --mount source=nvidia-driver-vol,destination=/usr/nvidia gow/nvidia-driver:latest sh
    fi
    info "NVIDIA driver volume created"
}

# Deploy Wolf into a container by pushing this script and running --configure.
# Usage: deploy_configure <exec_fn> <push_fn>
deploy_configure() {
    local exec_fn="$1" push_fn="$2"

    local nv_version=""
    if [[ "$SELECTED_VENDOR" == "NVIDIA" ]]; then
        detect_nvidia_version
        nv_version="$NV_VERSION"
        info "Host NVIDIA driver version: ${nv_version}"
    fi

    info "Deploying Wolf configuration into container"
    "$push_fn"
    "$exec_fn" \
        "WOLF_GPU_VENDOR='${SELECTED_VENDOR}' \
         WOLF_GPU_DRIVER='${SELECTED_DRIVER}' \
         WOLF_GPU_NAME='${SELECTED_NAME}' \
         WOLF_RENDER_NODE='${SELECTED_RENDER_NODE}' \
         WOLF_NV_VERSION='${nv_version}' \
         DEBIAN_FRONTEND=noninteractive \
         /root/wolf.sh --configure"
}

# Prompt user to pick from a numbered list. Returns 0-based index in CHOICE_IDX.
# Usage: prompt_choice <prompt_text> <array_of_labels>
prompt_choice() {
    local prompt_text="$1"; shift
    local labels=("$@")

    echo ""
    local i
    for i in "${!labels[@]}"; do
        printf "  %d) %s\n" $((i + 1)) "${labels[$i]}"
    done
    echo ""

    local choice
    while true; do
        read -rp "${prompt_text} [1]: " choice
        choice="${choice:-1}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#labels[@]} )); then
            break
        fi
        echo "Invalid selection. Enter a number between 1 and ${#labels[@]}."
    done
    CHOICE_IDX=$((choice - 1))
}

# Get local IP for summary output.
get_local_ip() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    echo "${ip:-<HOST_IP>}"
}

# Pull, start, and verify Wolf via docker compose in /opt/wolf.
docker_start_wolf() {
    info "Pulling and starting Wolf + Wolf Den"
    docker compose -f /opt/wolf/docker-compose.yml pull
    docker compose -f /opt/wolf/docker-compose.yml up -d

    sleep 5
    if docker compose -f /opt/wolf/docker-compose.yml ps --format '{{.Service}} {{.State}}' | grep -q "running"; then
        info "Services are running"
    else
        warn "Some services may not be running yet. Check: docker compose -f /opt/wolf/docker-compose.yml ps"
    fi
}

# =========================================================================
# GPU detection and selection
# =========================================================================

detect_gpus() {
    GPU_RENDER_NODES=()
    GPU_DRIVERS=()
    GPU_VENDORS=()
    GPU_NAMES=()

    local node driver vendor name pci_slot device_dir
    for node in /sys/class/drm/renderD*/device/driver; do
        [[ -e "$node" ]] || continue
        device_dir="$(dirname "$node")"
        local render_dev="/dev/dri/$(basename "$(dirname "$device_dir")")"
        driver=$(basename "$(readlink "$node")")

        case "$driver" in
            i915|xe) vendor="Intel"  ;;
            amdgpu)  vendor="AMD"    ;;
            nvidia)  vendor="NVIDIA" ;;
            *)       vendor="Unknown ($driver)" ;;
        esac

        name="Unknown"
        pci_slot=$(basename "$(readlink -f "$device_dir")") 2>/dev/null || true
        if [[ -n "$pci_slot" ]] && command -v lspci &>/dev/null; then
            name=$(lspci -s "$pci_slot" -mm 2>/dev/null | awk -F'"' '{print $6}') || true
            [[ -z "$name" ]] && name="Unknown"
        fi

        GPU_RENDER_NODES+=("$render_dev")
        GPU_DRIVERS+=("$driver")
        GPU_VENDORS+=("$vendor")
        GPU_NAMES+=("$name")
    done

    [[ ${#GPU_RENDER_NODES[@]} -gt 0 ]] \
        || err "No GPU render devices found in /sys/class/drm/. Are GPU drivers installed on the host?"
}

# Set the SELECTED_* globals from a GPU index.
_use_gpu() {
    local idx="$1"
    SELECTED_RENDER_NODE="${GPU_RENDER_NODES[$idx]}"
    SELECTED_DRIVER="${GPU_DRIVERS[$idx]}"
    SELECTED_VENDOR="${GPU_VENDORS[$idx]}"
    SELECTED_NAME="${GPU_NAMES[$idx]}"
}

_gpu_label() {
    local idx="$1"
    echo "${GPU_VENDORS[$idx]} ${GPU_NAMES[$idx]} (${GPU_DRIVERS[$idx]}, ${GPU_RENDER_NODES[$idx]})"
}

# Format the currently selected GPU for display.
selected_gpu_label() {
    echo "${SELECTED_VENDOR} ${SELECTED_NAME} (${SELECTED_DRIVER}, ${SELECTED_RENDER_NODE})"
}

select_gpu() {
    detect_gpus

    # If --render-node was specified, match it
    if [[ -n "${SELECTED_RENDER_NODE:-}" ]]; then
        local i
        for i in "${!GPU_RENDER_NODES[@]}"; do
            if [[ "${GPU_RENDER_NODES[$i]}" == "$SELECTED_RENDER_NODE" ]]; then
                _use_gpu "$i"
                info "Using GPU: $(_gpu_label "$i")"
                return
            fi
        done
        err "Render node ${SELECTED_RENDER_NODE} not found. Available: ${GPU_RENDER_NODES[*]}"
    fi

    if [[ ${#GPU_RENDER_NODES[@]} -eq 1 ]]; then
        _use_gpu 0
        info "Detected GPU: $(_gpu_label 0)"
        return
    fi

    local labels=()
    local i
    for i in "${!GPU_RENDER_NODES[@]}"; do
        labels+=("$(_gpu_label "$i")")
    done
    prompt_choice "Select GPU for Wolf" "${labels[@]}"
    _use_gpu "$CHOICE_IDX"
    info "Selected GPU: $(_gpu_label "$CHOICE_IDX")"
}

# =========================================================================
# Storage selection (Proxmox only)
# =========================================================================

select_storage() {
    local storages=()
    local labels=()

    while IFS='|' read -r name type _ enabled; do
        [[ "$enabled" == "1" ]] || continue
        storages+=("$name")
        labels+=("${name} (${type})")
    done < <(pvesm status --content rootdir 2>/dev/null \
        | awk 'NR>1 {printf "%s|%s|rootdir|%s\n", $1, $2, ($3=="active"?"1":"0")}')

    [[ ${#storages[@]} -gt 0 ]] || err "No active Proxmox storage with rootdir content found"

    if [[ ${#storages[@]} -eq 1 ]]; then
        CT_STORAGE="${storages[0]}"
        info "Using storage: ${labels[0]}"
        return
    fi

    prompt_choice "Select storage for Wolf CT" "${labels[@]}"
    CT_STORAGE="${storages[$CHOICE_IDX]}"
    info "Selected storage: ${CT_STORAGE}"
}

# =========================================================================
# Network detection (Proxmox only)
# =========================================================================

detect_network() {
    local host_ip host_cidr
    read -r host_ip host_cidr < <(
        ip -4 -o addr show scope global | awk '{split($4,a,"/"); print a[1], a[2]; exit}'
    ) || true

    [[ -n "$host_ip" ]] || err "Could not detect a local IPv4 address. Specify --ip, --gw, and --cidr manually."

    if [[ "$CT_GW" == "auto" ]]; then
        CT_GW=$(ip -4 route show default | awk '{print $3; exit}') || true
        [[ -n "$CT_GW" ]] || err "Could not detect default gateway. Specify one with --gw."
        info "Detected gateway: ${CT_GW}"
    fi

    if [[ "$CT_CIDR" == "auto" ]]; then
        [[ -n "$host_cidr" ]] || err "Could not detect subnet prefix length. Specify one with --cidr."
        CT_CIDR="$host_cidr"
        info "Detected CIDR: /${CT_CIDR}"
    fi

    if [[ "$CT_IP" == "auto" ]]; then
        CT_IP="${host_ip%.*}.${CTID}"
        info "Derived container IP from host (${host_ip}): ${CT_IP}"
    fi
}

# =========================================================================
# LXC GPU passthrough config (shared between Proxmox and standalone LXC)
# =========================================================================

# Write GPU passthrough entries to an LXC config file.
# Usage: write_lxc_gpu_config <conf_file> <separator>
#   separator: ":" for Proxmox (lxc.key: value), "=" for standalone (lxc.key = value)
write_lxc_gpu_config() {
    local conf="$1" sep="$2"

    cat >> "$conf" <<EOF

# GPU passthrough (Wolf cloud gaming)
lxc.cgroup2.devices.allow${sep} c 226:* rwm
lxc.mount.entry${sep} /dev/dri dev/dri none bind,optional,create=dir

# Virtual input devices
lxc.cgroup2.devices.allow${sep} c 13:* rwm
lxc.cgroup2.devices.allow${sep} c 10:223 rwm
lxc.mount.entry${sep} /dev/uinput dev/uinput none bind,optional,create=file
lxc.mount.entry${sep} /dev/uhid dev/uhid none bind,optional,create=file
lxc.mount.entry${sep} /dev/input dev/input none bind,optional,create=dir
lxc.mount.entry${sep} /run/udev run/udev none bind,optional,create=dir
EOF

    case "$SELECTED_VENDOR" in
        NVIDIA)
            cat >> "$conf" <<EOF
lxc.cgroup2.devices.allow${sep} c 195:* rwm
lxc.cgroup2.devices.allow${sep} c 507:* rwm
lxc.mount.entry${sep} /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry${sep} /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry${sep} /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file
lxc.mount.entry${sep} /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry${sep} /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
lxc.mount.entry${sep} /dev/nvidia-caps dev/nvidia-caps none bind,optional,create=dir
EOF
            ;;
        AMD)
            if [[ -e /dev/kfd ]]; then
                cat >> "$conf" <<EOF
lxc.cgroup2.devices.allow${sep} c 234:* rwm
lxc.mount.entry${sep} /dev/kfd dev/kfd none bind,optional,create=file
EOF
            fi
            ;;
    esac
}

# Remove previous Wolf config from an LXC conf file (idempotent).
# Matches both "# Wolf cloud gaming -- resource limits" and
# "# GPU passthrough (Wolf cloud gaming)" since the latter contains
# the substring "Wolf cloud gaming".
clean_lxc_gpu_config() {
    local conf="$1"
    if grep -q "# Wolf cloud gaming" "$conf" 2>/dev/null; then
        info "Removing old Wolf config"
        sed -i '/# Wolf cloud gaming/,$ d' "$conf"
    fi
}

# =========================================================================
# Docker compose generation
# =========================================================================

# Write compose file. Usage: write_compose <vendor> <render_node>
write_compose() {
    local vendor="$1" render_node="$2"

    case "$vendor" in
        NVIDIA)  _write_compose_nvidia "$render_node" ;;
        AMD|Intel) _write_compose_standard "$render_node" ;;
        *)       err "Unsupported GPU vendor: $vendor" ;;
    esac
}

_write_compose_standard() {
    local render_node="$1"
    cat > /opt/wolf/docker-compose.yml <<YAML
services:
  wolf:
    image: ghcr.io/games-on-whales/wolf:stable
    environment:
      - WOLF_RENDER_NODE=${render_node}
      - XDG_RUNTIME_DIR=/tmp/sockets
      - WOLF_CFG_FILE=/etc/wolf/cfg/config.toml
      - WOLF_DOCKER_SOCKET=/var/run/docker.sock
    volumes:
      - /etc/wolf:/etc/wolf:rw
      - /var/run/docker.sock:/var/run/docker.sock:rw
      - /dev/:/dev/:rw
      - /run/udev:/run/udev:rw
      - wolf-socket:/tmp/sockets
    device_cgroup_rules:
      - 'c 13:* rmw'
    devices:
      - /dev/dri
      - /dev/uinput
      - /dev/uhid
    network_mode: host
    restart: unless-stopped

  wolf-den:
    image: ghcr.io/games-on-whales/wolf-den:stable
    environment:
      - WOLF_SOCKET_PATH=/tmp/sockets/wolf.sock
    volumes:
      - wolf-socket:/tmp/sockets
      - /etc/wolf/wolf-den:/app/wolf-den
      - /etc/wolf/covers:/etc/wolf/covers
    ports:
      - "8080:8080"
    restart: unless-stopped
    depends_on:
      - wolf

volumes:
  wolf-socket:
YAML
}

_write_compose_nvidia() {
    local render_node="$1"
    cat > /opt/wolf/docker-compose.yml <<YAML
services:
  wolf:
    image: ghcr.io/games-on-whales/wolf:stable
    environment:
      - WOLF_RENDER_NODE=${render_node}
      - NVIDIA_DRIVER_VOLUME_NAME=nvidia-driver-vol
      - XDG_RUNTIME_DIR=/tmp/sockets
      - WOLF_CFG_FILE=/etc/wolf/cfg/config.toml
      - WOLF_DOCKER_SOCKET=/var/run/docker.sock
    volumes:
      - /etc/wolf:/etc/wolf:rw
      - /var/run/docker.sock:/var/run/docker.sock:rw
      - /dev/:/dev/:rw
      - /run/udev:/run/udev:rw
      - nvidia-driver-vol:/usr/nvidia:rw
      - wolf-socket:/tmp/sockets
    devices:
      - /dev/dri
      - /dev/uinput
      - /dev/uhid
      - /dev/nvidia-uvm
      - /dev/nvidia-uvm-tools
      - /dev/nvidia-caps/nvidia-cap1
      - /dev/nvidia-caps/nvidia-cap2
      - /dev/nvidiactl
      - /dev/nvidia0
      - /dev/nvidia-modeset
    device_cgroup_rules:
      - 'c 13:* rmw'
    network_mode: host
    restart: unless-stopped

  wolf-den:
    image: ghcr.io/games-on-whales/wolf-den:stable
    environment:
      - WOLF_SOCKET_PATH=/tmp/sockets/wolf.sock
    volumes:
      - wolf-socket:/tmp/sockets
      - /etc/wolf/wolf-den:/app/wolf-den
      - /etc/wolf/covers:/etc/wolf/covers
    ports:
      - "8080:8080"
    restart: unless-stopped
    depends_on:
      - wolf

volumes:
  nvidia-driver-vol:
    external: true
  wolf-socket:
YAML
}

# Write compose file with custom paths.
# Usage: write_compose_paths <vendor> <render_node> <wolf_cfg> <wolf_den> <covers> <steam> <compose_dir>
write_compose_paths() {
    local vendor="$1" render_node="$2"
    local wolf_cfg="$3" wolf_den="$4" covers="$5" steam="$6" compose_dir="$7"

    local compose_file="${compose_dir}/docker-compose.yml"

    case "$vendor" in
        NVIDIA)
            cat > "$compose_file" <<YAML
services:
  wolf:
    image: ghcr.io/games-on-whales/wolf:stable
    environment:
      - WOLF_RENDER_NODE=${render_node}
      - NVIDIA_DRIVER_VOLUME_NAME=nvidia-driver-vol
      - XDG_RUNTIME_DIR=/tmp/sockets
      - WOLF_CFG_FILE=/etc/wolf/cfg/config.toml
      - WOLF_DOCKER_SOCKET=/var/run/docker.sock
    volumes:
      - ${wolf_cfg}:/etc/wolf/cfg:rw
      - ${steam}:/etc/wolf/steam:rw
      - /var/run/docker.sock:/var/run/docker.sock:rw
      - /dev/:/dev/:rw
      - /run/udev:/run/udev:rw
      - nvidia-driver-vol:/usr/nvidia:rw
      - wolf-socket:/tmp/sockets
    devices:
      - /dev/dri
      - /dev/uinput
      - /dev/uhid
      - /dev/nvidia-uvm
      - /dev/nvidia-uvm-tools
      - /dev/nvidia-caps/nvidia-cap1
      - /dev/nvidia-caps/nvidia-cap2
      - /dev/nvidiactl
      - /dev/nvidia0
      - /dev/nvidia-modeset
    device_cgroup_rules:
      - 'c 13:* rmw'
    network_mode: host
    restart: unless-stopped

  wolf-den:
    image: ghcr.io/games-on-whales/wolf-den:stable
    environment:
      - WOLF_SOCKET_PATH=/tmp/sockets/wolf.sock
    volumes:
      - wolf-socket:/tmp/sockets
      - ${wolf_den}:/app/wolf-den
      - ${covers}:/etc/wolf/covers
    ports:
      - "8080:8080"
    restart: unless-stopped
    depends_on:
      - wolf

volumes:
  nvidia-driver-vol:
    external: true
  wolf-socket:
YAML
            ;;
        AMD|Intel)
            cat > "$compose_file" <<YAML
services:
  wolf:
    image: ghcr.io/games-on-whales/wolf:stable
    environment:
      - WOLF_RENDER_NODE=${render_node}
      - XDG_RUNTIME_DIR=/tmp/sockets
      - WOLF_CFG_FILE=/etc/wolf/cfg/config.toml
      - WOLF_DOCKER_SOCKET=/var/run/docker.sock
    volumes:
      - ${wolf_cfg}:/etc/wolf/cfg:rw
      - ${steam}:/etc/wolf/steam:rw
      - /var/run/docker.sock:/var/run/docker.sock:rw
      - /dev/:/dev/:rw
      - /run/udev:/run/udev:rw
      - wolf-socket:/tmp/sockets
    device_cgroup_rules:
      - 'c 13:* rmw'
    devices:
      - /dev/dri
      - /dev/uinput
      - /dev/uhid
    network_mode: host
    restart: unless-stopped

  wolf-den:
    image: ghcr.io/games-on-whales/wolf-den:stable
    environment:
      - WOLF_SOCKET_PATH=/tmp/sockets/wolf.sock
    volumes:
      - wolf-socket:/tmp/sockets
      - ${wolf_den}:/app/wolf-den
      - ${covers}:/etc/wolf/covers
    ports:
      - "8080:8080"
    restart: unless-stopped
    depends_on:
      - wolf

volumes:
  wolf-socket:
YAML
            ;;
        *) err "Unsupported GPU vendor: $vendor" ;;
    esac
}

# =========================================================================
# Container-side configuration (runs inside an LXC via --configure)
# =========================================================================

configure() {
    local gpu_vendor="${WOLF_GPU_VENDOR:?WOLF_GPU_VENDOR not set}"
    local gpu_driver="${WOLF_GPU_DRIVER:?WOLF_GPU_DRIVER not set}"
    local gpu_name="${WOLF_GPU_NAME:-Unknown}"
    local render_node="${WOLF_RENDER_NODE:-/dev/dri/renderD128}"

    info "Configuring Wolf for ${gpu_vendor} ${gpu_name} (${gpu_driver}, ${render_node})"

    # Install Docker
    if ! command -v docker &>/dev/null; then
        info "Installing Docker"
        apt-get update -qq
        apt-get install -y --no-install-recommends ca-certificates curl gnupg

        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            > /etc/apt/sources.list.d/docker.list

        apt-get update -qq
        apt-get install -y --no-install-recommends \
            docker-ce docker-ce-cli containerd.io docker-compose-plugin
        info "Docker installed"
    else
        info "Docker already installed"
    fi

    install_udev_rules

    mkdir -p /etc/wolf/cfg /etc/wolf/wolf-den /etc/wolf/covers /opt/wolf

    # Write Wolf config with Steam (skip if already customised)
    if [[ ! -f /etc/wolf/cfg/config.toml ]]; then
        info "Writing Wolf config with Steam"
        cat > /etc/wolf/cfg/config.toml <<'TOML'
hostname = "Wolf"
support_hevc = true
support_av1 = true

[[profiles]]
uid = "default"

[[profiles.apps]]
title = "Steam"
start_virtual_compositor = true

[profiles.apps.runner]
type = "docker"
name = "WolfSteam"
image = "ghcr.io/games-on-whales/steam:edge"
mounts = ["/etc/wolf/steam:/home/retro:rw"]
env = ["PROTON_LOG=1", "RUN_SWAY=true"]
TOML
        mkdir -p /etc/wolf/steam
    else
        info "Wolf config already exists, skipping"
    fi

    info "Writing docker-compose.yml for ${gpu_vendor}"
    write_compose "$gpu_vendor" "$render_node"

    if [[ "$gpu_vendor" == "NVIDIA" ]]; then
        NV_VERSION="${WOLF_NV_VERSION:?WOLF_NV_VERSION not set}"
        build_nvidia_volume docker
    fi

    docker_start_wolf

    local ip; ip=$(get_local_ip)
    cat <<EOF

================================================================
Wolf cloud gaming is deployed.

  Wolf:      streaming on ports 47984-48200 (Moonlight)
  Wolf Den:  http://${ip}:8080 (web management)
  GPU:       ${gpu_vendor} ${gpu_name} (${gpu_driver}) at ${render_node}

To pair with Moonlight:
  1. Open Wolf Den at http://${ip}:8080 to manage apps and clients
  2. Open Moonlight and add server: ${ip}
  3. Enter the pairing PIN shown in Moonlight into Wolf Den
================================================================
EOF
}

# =========================================================================
# Proxmox deployment
# =========================================================================

proxmox_main() {
    [[ $EUID -eq 0 ]] || err "Run as root"

    if [[ "$CT_IP" == "auto" || "$CT_GW" == "auto" || "$CT_CIDR" == "auto" ]]; then
        detect_network
    fi

    select_gpu

    info "Wolf Cloud Gaming Setup (Proxmox)"
    echo "  CTID:    ${CTID}"
    echo "  IP:      ${CT_IP}/${CT_CIDR}"
    echo "  Gateway: ${CT_GW}"
    echo "  CPU:     ${CT_CPU} cores"
    echo "  RAM:     ${CT_RAM} MB"
    echo "  Disk:    ${CT_DISK} GB"
    echo "  Storage: ${CT_STORAGE}"
    echo ""

    [[ "$CT_STORAGE" == "auto" ]] && select_storage

    # Create container
    if ! pct status "$CTID" &>/dev/null; then
        info "Creating CT $CTID (wolf) at $CT_IP"
        pct create "$CTID" "$TEMPLATE" \
            --hostname wolf \
            --memory "$CT_RAM" \
            --cores "$CT_CPU" \
            --rootfs "${CT_STORAGE}:${CT_DISK}" \
            --net0 "name=eth0,bridge=${LAN_BRIDGE},ip=${CT_IP}/${CT_CIDR},gw=${CT_GW}" \
            --unprivileged 0 \
            --features nesting=1 \
            --start 0 \
            || err "Failed to create CT $CTID"
        pct start "$CTID"
        sleep 3
    else
        info "SKIP: CT $CTID already exists"
    fi

    # Configure GPU passthrough (must stop container to edit config)
    pct stop "$CTID" 2>/dev/null || true
    sleep 2

    local conf="/etc/pve/lxc/${CTID}.conf"
    clean_lxc_gpu_config "$conf"
    write_lxc_gpu_config "$conf" ":"

    pct start "$CTID"
    sleep 3

    _pve_push() { pct push "$CTID" "$0" /root/wolf.sh --perms 0755; }
    _pve_exec() { pct exec "$CTID" -- bash -c "$1"; }
    deploy_configure _pve_exec _pve_push
    info "Done"
}

# =========================================================================
# Standalone LXC deployment
# =========================================================================

lxc_main() {
    [[ $EUID -eq 0 ]] || err "Run as root"

    select_gpu

    info "Wolf Cloud Gaming Setup (LXC)"
    echo "  Name:  ${LXC_NAME}"
    echo "  CPU:   ${CT_CPU} cores"
    echo "  RAM:   ${CT_RAM} MB"
    echo "  Disk:  ${CT_DISK} GB"
    echo "  GPU:   $(selected_gpu_label)"
    echo ""

    if ! lxc-info -n "$LXC_NAME" &>/dev/null; then
        info "Creating container '$LXC_NAME'"
        lxc-create -t download -n "$LXC_NAME" \
            -B loop --fssize "${CT_DISK}G" \
            -- -d debian -r trixie -a amd64
    else
        info "SKIP: Container '$LXC_NAME' already exists"
    fi

    local conf="/var/lib/lxc/${LXC_NAME}/config"
    clean_lxc_gpu_config "$conf"

    # Resource limits
    cat >> "$conf" <<EOF

# Wolf cloud gaming -- resource limits
lxc.cgroup2.memory.max = ${CT_RAM}M
lxc.cgroup2.cpu.max = $((CT_CPU * 1000000)) 1000000
EOF
    write_lxc_gpu_config "$conf" " ="

    lxc-stop -n "$LXC_NAME" 2>/dev/null || true
    lxc-start -n "$LXC_NAME"
    sleep 3

    _lxc_push() {
        cp "$0" "/var/lib/lxc/${LXC_NAME}/rootfs/root/wolf.sh"
        chmod 755 "/var/lib/lxc/${LXC_NAME}/rootfs/root/wolf.sh"
    }
    _lxc_exec() { lxc-attach -n "$LXC_NAME" -- bash -c "$1"; }
    deploy_configure _lxc_exec _lxc_push
    info "Done"
}

# =========================================================================
# Incus deployment
# =========================================================================

incus_main() {
    [[ $EUID -eq 0 ]] || err "Run as root"

    select_gpu

    info "Wolf Cloud Gaming Setup (Incus)"
    echo "  Name:  ${LXC_NAME}"
    echo "  CPU:   ${CT_CPU} cores"
    echo "  RAM:   ${CT_RAM} MB"
    echo "  Disk:  ${CT_DISK} GB"
    echo "  GPU:   $(selected_gpu_label)"
    echo ""

    if ! incus info "$LXC_NAME" &>/dev/null; then
        info "Creating container '$LXC_NAME'"
        incus launch images:debian/trixie "$LXC_NAME" \
            -c security.privileged=true \
            -c security.nesting=true \
            -c limits.cpu="$CT_CPU" \
            -c limits.memory="${CT_RAM}MiB" \
            -d root,size="${CT_DISK}GiB"
    else
        info "SKIP: Container '$LXC_NAME' already exists"
    fi

    info "Configuring GPU passthrough"

    # Remove old devices first so re-runs apply the latest config
    for dev in gpu-dri uinput uhid nvidia0 nvidiactl nvidia-modeset \
               nvidia-uvm nvidia-uvm-tools nvidia-caps kfd; do
        incus config device remove "$LXC_NAME" "$dev" 2>/dev/null || true
    done

    incus config device add "$LXC_NAME" gpu-dri disk \
        source=/dev/dri path=/dev/dri
    incus config device add "$LXC_NAME" uinput unix-char \
        source=/dev/uinput path=/dev/uinput
    incus config device add "$LXC_NAME" uhid unix-char \
        source=/dev/uhid path=/dev/uhid

    case "$SELECTED_VENDOR" in
        NVIDIA)
            for dev in nvidia0 nvidiactl nvidia-modeset nvidia-uvm nvidia-uvm-tools; do
                [[ -e "/dev/$dev" ]] || continue
                incus config device add "$LXC_NAME" "$dev" unix-char \
                    source="/dev/$dev" path="/dev/$dev"
            done
            [[ -d /dev/nvidia-caps ]] && incus config device add "$LXC_NAME" nvidia-caps disk \
                source=/dev/nvidia-caps path=/dev/nvidia-caps
            ;;
        AMD)
            [[ -e /dev/kfd ]] && incus config device add "$LXC_NAME" kfd unix-char \
                source=/dev/kfd path=/dev/kfd
            ;;
    esac

    incus start "$LXC_NAME" 2>/dev/null || true
    sleep 3

    _incus_push() { incus file push "$0" "${LXC_NAME}/root/wolf.sh" --mode 0755; }
    _incus_exec() { incus exec "$LXC_NAME" -- bash -c "$1"; }
    deploy_configure _incus_exec _incus_push
    info "Done"
}

# =========================================================================
# Podman deployment
# =========================================================================

_write_wolf_quadlet() {
    local nvidia_devices="" nvidia_volumes="" nvidia_env=""
    if [[ "$SELECTED_VENDOR" == "NVIDIA" ]]; then
        nvidia_devices="AddDevice=/dev/nvidia-uvm
AddDevice=/dev/nvidia-uvm-tools
AddDevice=/dev/nvidia-caps/nvidia-cap1
AddDevice=/dev/nvidia-caps/nvidia-cap2
AddDevice=/dev/nvidiactl
AddDevice=/dev/nvidia0
AddDevice=/dev/nvidia-modeset"
        nvidia_volumes="Volume=nvidia-driver-vol:/usr/nvidia"
        nvidia_env="Environment=NVIDIA_DRIVER_VOLUME_NAME=nvidia-driver-vol"
    fi

    cat <<QUADLET
[Unit]
Description=Wolf Cloud Gaming (Games On Whales)
Requires=network-online.target podman.socket
After=network-online.target podman.socket

[Service]
TimeoutStartSec=900
ExecStartPre=-/usr/bin/podman rm --force WolfPulseAudio
Restart=on-failure
RestartSec=5
StartLimitBurst=5

[Container]
AutoUpdate=registry
ContainerName=%p
HostName=%p
Image=ghcr.io/games-on-whales/wolf:stable
Network=host
SecurityLabelDisable=true
PodmanArgs=--ipc=host --device-cgroup-rule "c 13:* rmw"
AddDevice=/dev/dri
AddDevice=/dev/uinput
AddDevice=/dev/uhid
${nvidia_devices:+${nvidia_devices}
}${nvidia_volumes:+${nvidia_volumes}
}Volume=/dev/:/dev/:rw
Volume=/run/udev:/run/udev:rw
Volume=/etc/wolf/:/etc/wolf:z
Volume=/run/podman/podman.sock:/var/run/docker.sock:ro
Volume=wolf-socket:/tmp/sockets
Environment=WOLF_STOP_CONTAINER_ON_EXIT=TRUE
Environment=XDG_RUNTIME_DIR=/tmp/sockets
${nvidia_env:+${nvidia_env}
}Environment=WOLF_RENDER_NODE=${SELECTED_RENDER_NODE}

[Install]
WantedBy=multi-user.target
QUADLET
}

_write_wolf_den_quadlet() {
    cat <<QUADLET
[Unit]
Description=Wolf Den Web Management (Games On Whales)
Requires=wolf.service
After=wolf.service

[Service]
Restart=on-failure
RestartSec=5

[Container]
AutoUpdate=registry
ContainerName=%p
Image=ghcr.io/games-on-whales/wolf-den:stable
PublishPort=8080:8080
Volume=wolf-socket:/tmp/sockets
Volume=/etc/wolf/wolf-den:/app/wolf-den:z
Volume=/etc/wolf/covers:/etc/wolf/covers:z
Environment=WOLF_SOCKET_PATH=/tmp/sockets/wolf.sock

[Install]
WantedBy=multi-user.target
QUADLET
}

podman_main() {
    [[ $EUID -eq 0 ]] || err "Run as root"

    select_gpu

    info "Wolf Cloud Gaming Setup (Podman Quadlet)"
    echo "  GPU:  $(selected_gpu_label)"
    echo "  Node: ${SELECTED_RENDER_NODE}"
    echo ""

    install_udev_rules

    info "Enabling Podman socket"
    systemctl enable --now podman.socket

    [[ "$SELECTED_VENDOR" == "NVIDIA" ]] && build_nvidia_volume podman

    mkdir -p /etc/wolf/wolf-den /etc/wolf/covers
    local quadlet_dir="/etc/containers/systemd"
    mkdir -p "$quadlet_dir"

    info "Writing Podman Quadlets"
    _write_wolf_quadlet > "${quadlet_dir}/wolf.container"
    _write_wolf_den_quadlet > "${quadlet_dir}/wolf-den.container"

    # Create the shared socket volume
    podman volume create wolf-socket 2>/dev/null || true

    info "Reloading systemd and starting Wolf + Wolf Den"
    systemctl daemon-reload
    systemctl enable wolf.service wolf-den.service
    # restart (not just enable --now) so updated Quadlet config is applied on re-runs
    systemctl restart wolf.service wolf-den.service

    sleep 5
    local running=true
    systemctl is-active --quiet wolf.service || running=false
    systemctl is-active --quiet wolf-den.service || running=false
    if $running; then
        info "Services are running"
    else
        warn "Some services may not be running yet. Check: systemctl status wolf wolf-den"
    fi

    local ip; ip=$(get_local_ip)
    cat <<EOF

================================================================
Wolf cloud gaming is deployed (Podman Quadlet).

  Wolf:      streaming on ports 47984-48200 (Moonlight)
  Wolf Den:  http://${ip}:8080 (web management)
  Services:  systemctl status wolf wolf-den
  GPU:       ${SELECTED_VENDOR} ${SELECTED_NAME} (${SELECTED_DRIVER}) at ${SELECTED_RENDER_NODE}

To pair with Moonlight:
  1. Open Wolf Den at http://${ip}:8080 to manage apps and clients
  2. Open Moonlight and add server: ${ip}
  3. Enter the pairing PIN shown in Moonlight into Wolf Den

Manage with:
  systemctl stop wolf wolf-den       # stop
  systemctl restart wolf wolf-den    # restart
  journalctl -u wolf -f              # view Wolf logs
  journalctl -u wolf-den -f          # view Wolf Den logs
================================================================
EOF
}

# =========================================================================
# Unraid deployment
# =========================================================================

# Install udev rules persistently on Unraid. The root filesystem is a tmpfs,
# so rules written to /etc/ are lost on reboot. Unraid's convention is to
# store custom udev rules in /boot/config/ and restore them via /boot/config/go.
install_udev_rules_unraid() {
    local rules_src="/boot/config/wolf-virtual-inputs.rules"
    local rules_dst="/etc/udev/rules.d/85-wolf-virtual-inputs.rules"

    info "Setting up persistent udev rules for virtual input"

    # Write the canonical copy to the flash drive
    cat > "$rules_src" <<'UDEV'
KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput", TAG+="uaccess"
KERNEL=="uhid", GROUP="input", MODE="0660", TAG+="uaccess"
KERNEL=="hidraw*", ATTRS{name}=="Wolf PS5 (virtual) pad", GROUP="input", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf X-Box One (virtual) pad", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf PS5 (virtual) pad", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf gamepad (virtual) motion sensors", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf Nintendo (virtual) pad", MODE="0660", ENV{ID_SEAT}="seat9"
UDEV

    # Copy into the live tmpfs so it takes effect immediately
    cp "$rules_src" "$rules_dst"
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger 2>/dev/null || true

    # Ensure /boot/config/go restores the rules on every boot.
    # The go script runs at the end of Unraid's boot process.
    local go="/boot/config/go"
    local marker="# Wolf udev rules"
    if ! grep -qF "$marker" "$go" 2>/dev/null; then
        info "Adding udev restore to /boot/config/go"
        cat >> "$go" <<EOF

$marker
cp ${rules_src} ${rules_dst}
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true
EOF
    fi
}

# Write Wolf config.toml for Unraid (same content, different path).
write_wolf_config_unraid() {
    local cfg_dir="$1"

    if [[ -f "${cfg_dir}/config.toml" ]]; then
        info "Wolf config already exists, skipping"
        return
    fi

    info "Writing Wolf config with Steam"
    cat > "${cfg_dir}/config.toml" <<'TOML'
hostname = "Wolf"
support_hevc = true
support_av1 = true

[[profiles]]
uid = "default"

[[profiles.apps]]
title = "Steam"
start_virtual_compositor = true

[profiles.apps.runner]
type = "docker"
name = "WolfSteam"
image = "ghcr.io/games-on-whales/steam:edge"
mounts = ["/etc/wolf/steam:/home/retro:rw"]
env = ["PROTON_LOG=1", "RUN_SWAY=true"]
TOML
}

unraid_main() {
    [[ $EUID -eq 0 ]] || err "Run as root"

    command -v docker &>/dev/null || err "Docker is not available. Enable Docker in Unraid Settings > Docker."

    select_gpu

    local cfg_dir="${APPDATA}/cfg"
    local wolf_den_dir="${APPDATA}/wolf-den"
    local covers_dir="${APPDATA}/covers"
    local steam_dir="${APPDATA}/steam"
    local compose_dir="${APPDATA}"

    info "Wolf Cloud Gaming Setup (Unraid)"
    echo "  Appdata: ${APPDATA}"
    echo "  GPU:     $(selected_gpu_label)"
    echo "  Node:    ${SELECTED_RENDER_NODE}"
    echo ""

    install_udev_rules_unraid

    mkdir -p "$cfg_dir" "$wolf_den_dir" "$covers_dir" "$steam_dir"

    write_wolf_config_unraid "$cfg_dir"

    info "Writing docker-compose.yml for ${SELECTED_VENDOR}"
    write_compose_paths "$SELECTED_VENDOR" "$SELECTED_RENDER_NODE" \
        "$cfg_dir" "$wolf_den_dir" "$covers_dir" "$steam_dir" "$compose_dir"

    if [[ "$SELECTED_VENDOR" == "NVIDIA" ]]; then
        detect_nvidia_version
        build_nvidia_volume docker
    fi

    info "Pulling and starting Wolf + Wolf Den"
    docker compose -f "${compose_dir}/docker-compose.yml" pull
    docker compose -f "${compose_dir}/docker-compose.yml" up -d

    sleep 5
    if docker compose -f "${compose_dir}/docker-compose.yml" ps --format '{{.Service}} {{.State}}' | grep -q "running"; then
        info "Services are running"
    else
        warn "Some services may not be running yet. Check: docker compose -f ${compose_dir}/docker-compose.yml ps"
    fi

    # Ensure Wolf starts on boot via /boot/config/go
    local go="/boot/config/go"
    local marker="# Wolf docker-compose"
    if ! grep -qF "$marker" "$go" 2>/dev/null; then
        info "Adding Wolf auto-start to /boot/config/go"
        cat >> "$go" <<EOF

$marker
docker compose -f ${compose_dir}/docker-compose.yml up -d &
EOF
    fi

    local ip; ip=$(get_local_ip)
    cat <<EOF

================================================================
Wolf cloud gaming is deployed (Unraid).

  Wolf:      streaming on ports 47984-48200 (Moonlight)
  Wolf Den:  http://${ip}:8080 (web management)
  Compose:   ${compose_dir}/docker-compose.yml
  Appdata:   ${APPDATA}
  GPU:       ${SELECTED_VENDOR} ${SELECTED_NAME} (${SELECTED_DRIVER}) at ${SELECTED_RENDER_NODE}

  Persistence: udev rules and auto-start are saved to
               /boot/config/go (survives reboots)

To pair with Moonlight:
  1. Open Wolf Den at http://${ip}:8080 to manage apps and clients
  2. Open Moonlight and add server: ${ip}
  3. Enter the pairing PIN shown in Moonlight into Wolf Den

Manage with:
  cd ${compose_dir}
  docker compose stop       # stop
  docker compose restart    # restart
  docker compose logs -f    # view logs
  docker compose pull && docker compose up -d   # update
================================================================
EOF
}

# =========================================================================
# TrueNAS SCALE deployment
# =========================================================================

# Auto-detect or validate ZFS pool. Sets ZFS_POOL.
select_pool() {
    local pools=()
    local labels=()

    while read -r name size alloc; do
        pools+=("$name")
        labels+=("${name} (${size}, ${alloc} used)")
    done < <(zpool list -Ho name,size,alloc 2>/dev/null)

    [[ ${#pools[@]} -gt 0 ]] || err "No ZFS pools found. TrueNAS requires at least one storage pool."

    if [[ "$ZFS_POOL" != "auto" ]]; then
        local i
        for i in "${!pools[@]}"; do
            if [[ "${pools[$i]}" == "$ZFS_POOL" ]]; then
                info "Using pool: ${labels[$i]}"
                return
            fi
        done
        err "Pool '${ZFS_POOL}' not found. Available: ${pools[*]}"
    fi

    if [[ ${#pools[@]} -eq 1 ]]; then
        ZFS_POOL="${pools[0]}"
        info "Detected pool: ${labels[0]}"
        return
    fi

    prompt_choice "Select ZFS pool for Wolf appdata" "${labels[@]}"
    ZFS_POOL="${pools[$CHOICE_IDX]}"
    info "Selected pool: ${ZFS_POOL}"
}

# Write a self-contained init script to the ZFS dataset. This script restores
# udev rules and starts Wolf on boot. It is registered with TrueNAS via midclt
# so it survives system updates (unlike files in /etc/).
write_truenas_init_script() {
    local appdata="$1" compose_file="$2" rules_src="$3"

    local init_script="${appdata}/wolf-init.sh"
    cat > "$init_script" <<INITEOF
#!/usr/bin/env bash
# Wolf cloud gaming -- TrueNAS POSTINIT script
# Restores udev rules and starts Wolf on boot.

# Restore udev rules (system partition is overwritten on updates)
cp "${rules_src}" /etc/udev/rules.d/85-wolf-virtual-inputs.rules
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true

# Start Wolf
docker compose -f "${compose_file}" up -d &
INITEOF
    chmod 755 "$init_script"
}

# Register the init script with TrueNAS via midclt. Idempotent: checks for
# an existing Wolf init script before creating a new one.
register_truenas_init() {
    local init_script="$1"

    # Check if we already registered a Wolf init script
    local existing
    existing=$(midclt call initshutdownscript.query \
        '[["script", "~", "wolf-init.sh"]]' 2>/dev/null) || true

    if [[ -n "$existing" && "$existing" != "[]" ]]; then
        info "TrueNAS init script already registered, updating path"
        local script_id
        script_id=$(echo "$existing" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])" 2>/dev/null) || true
        if [[ -n "$script_id" ]]; then
            midclt call initshutdownscript.update "$script_id" \
                "{\"script\": \"${init_script}\", \"when\": \"POSTINIT\", \"enabled\": true, \"type\": \"SCRIPT\"}" \
                >/dev/null
            return
        fi
    fi

    info "Registering init script with TrueNAS"
    midclt call initshutdownscript.create \
        "{\"type\": \"SCRIPT\", \"script\": \"${init_script}\", \"when\": \"POSTINIT\", \"enabled\": true}" \
        >/dev/null
}

truenas_main() {
    [[ $EUID -eq 0 ]] || err "Run as root"

    command -v docker &>/dev/null \
        || err "Docker is not available. TrueNAS SCALE Electric Eel (24.10+) is required for Docker support."
    command -v midclt &>/dev/null \
        || err "midclt not found. This script supports TrueNAS SCALE only (not TrueNAS CORE)."

    select_gpu

    # Resolve appdata path: if --appdata was not explicitly set, derive from pool
    if [[ "$APPDATA" == "/mnt/user/appdata/wolf" ]]; then
        select_pool
        APPDATA="/mnt/${ZFS_POOL}/appdata/wolf"
    fi

    local cfg_dir="${APPDATA}/cfg"
    local wolf_den_dir="${APPDATA}/wolf-den"
    local covers_dir="${APPDATA}/covers"
    local steam_dir="${APPDATA}/steam"
    local compose_dir="${APPDATA}"
    local rules_src="${APPDATA}/wolf-virtual-inputs.rules"

    info "Wolf Cloud Gaming Setup (TrueNAS SCALE)"
    echo "  Appdata: ${APPDATA}"
    echo "  GPU:     $(selected_gpu_label)"
    echo "  Node:    ${SELECTED_RENDER_NODE}"
    echo ""

    mkdir -p "$cfg_dir" "$wolf_den_dir" "$covers_dir" "$steam_dir"

    # Write udev rules to the ZFS dataset (persistent) and install live
    info "Setting up udev rules for virtual input"
    cat > "$rules_src" <<'UDEV'
KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput", TAG+="uaccess"
KERNEL=="uhid", GROUP="input", MODE="0660", TAG+="uaccess"
KERNEL=="hidraw*", ATTRS{name}=="Wolf PS5 (virtual) pad", GROUP="input", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf X-Box One (virtual) pad", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf PS5 (virtual) pad", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf gamepad (virtual) motion sensors", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf Nintendo (virtual) pad", MODE="0660", ENV{ID_SEAT}="seat9"
UDEV
    cp "$rules_src" /etc/udev/rules.d/85-wolf-virtual-inputs.rules
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger 2>/dev/null || true

    # Write Wolf config (skip if already customised)
    if [[ ! -f "${cfg_dir}/config.toml" ]]; then
        info "Writing Wolf config with Steam"
        cat > "${cfg_dir}/config.toml" <<'TOML'
hostname = "Wolf"
support_hevc = true
support_av1 = true

[[profiles]]
uid = "default"

[[profiles.apps]]
title = "Steam"
start_virtual_compositor = true

[profiles.apps.runner]
type = "docker"
name = "WolfSteam"
image = "ghcr.io/games-on-whales/steam:edge"
mounts = ["/etc/wolf/steam:/home/retro:rw"]
env = ["PROTON_LOG=1", "RUN_SWAY=true"]
TOML
    else
        info "Wolf config already exists, skipping"
    fi

    info "Writing docker-compose.yml for ${SELECTED_VENDOR}"
    write_compose_paths "$SELECTED_VENDOR" "$SELECTED_RENDER_NODE" \
        "$cfg_dir" "$wolf_den_dir" "$covers_dir" "$steam_dir" "$compose_dir"

    if [[ "$SELECTED_VENDOR" == "NVIDIA" ]]; then
        detect_nvidia_version
        build_nvidia_volume docker
    fi

    # Write and register the boot init script
    local compose_file="${compose_dir}/docker-compose.yml"
    write_truenas_init_script "$APPDATA" "$compose_file" "$rules_src"
    register_truenas_init "${APPDATA}/wolf-init.sh"

    info "Pulling and starting Wolf + Wolf Den"
    docker compose -f "$compose_file" pull
    docker compose -f "$compose_file" up -d

    sleep 5
    if docker compose -f "$compose_file" ps --format '{{.Service}} {{.State}}' | grep -q "running"; then
        info "Services are running"
    else
        warn "Some services may not be running yet. Check: docker compose -f ${compose_file} ps"
    fi

    local ip; ip=$(get_local_ip)
    cat <<EOF

================================================================
Wolf cloud gaming is deployed (TrueNAS SCALE).

  Wolf:      streaming on ports 47984-48200 (Moonlight)
  Wolf Den:  http://${ip}:8080 (web management)
  Compose:   ${compose_file}
  Appdata:   ${APPDATA}
  GPU:       ${SELECTED_VENDOR} ${SELECTED_NAME} (${SELECTED_DRIVER}) at ${SELECTED_RENDER_NODE}

  Persistence: init script registered with TrueNAS (survives updates).
               View in TrueNAS UI: System > Advanced > Init/Shutdown Scripts

To pair with Moonlight:
  1. Open Wolf Den at http://${ip}:8080 to manage apps and clients
  2. Open Moonlight and add server: ${ip}
  3. Enter the pairing PIN shown in Moonlight into Wolf Den

Manage with:
  cd ${compose_dir}
  docker compose stop       # stop
  docker compose restart    # restart
  docker compose logs -f    # view logs
  docker compose pull && docker compose up -d   # update
================================================================
EOF
}

# =========================================================================
# Docker deployment
# =========================================================================

docker_main() {
    [[ $EUID -eq 0 ]] || err "Run as root"

    select_gpu

    info "Wolf Cloud Gaming Setup (Docker)"
    echo "  GPU:  $(selected_gpu_label)"
    echo "  Node: ${SELECTED_RENDER_NODE}"
    echo ""

    install_udev_rules

    [[ "$SELECTED_VENDOR" == "NVIDIA" ]] && build_nvidia_volume docker

    mkdir -p /etc/wolf/wolf-den /etc/wolf/covers /opt/wolf

    info "Writing docker-compose.yml"
    write_compose "$SELECTED_VENDOR" "$SELECTED_RENDER_NODE"

    docker_start_wolf

    local ip; ip=$(get_local_ip)
    cat <<EOF

================================================================
Wolf cloud gaming is deployed (Docker).

  Wolf:      streaming on ports 47984-48200 (Moonlight)
  Wolf Den:  http://${ip}:8080 (web management)
  Compose:   /opt/wolf/docker-compose.yml
  GPU:       ${SELECTED_VENDOR} ${SELECTED_NAME} (${SELECTED_DRIVER}) at ${SELECTED_RENDER_NODE}

To pair with Moonlight:
  1. Open Wolf Den at http://${ip}:8080 to manage apps and clients
  2. Open Moonlight and add server: ${ip}
  3. Enter the pairing PIN shown in Moonlight into Wolf Den

Manage with:
  cd /opt/wolf
  docker compose stop       # stop
  docker compose restart    # restart
  docker compose logs -f    # view logs
  docker compose pull && docker compose up -d   # update
================================================================
EOF
}

# =========================================================================
# Environment detection and main dispatch
# =========================================================================

detect_environment() {
    local arg
    for arg in "$@"; do
        [[ "$arg" == "--configure" ]] && { echo "configure"; return; }
    done

    command -v pveversion &>/dev/null && { echo "proxmox"; return; }
    command -v lxc-create &>/dev/null && { echo "lxc"; return; }
    command -v incus &>/dev/null     && { echo "incus"; return; }
    [[ -f /etc/unraid-version ]]     && { echo "unraid"; return; }
    command -v midclt &>/dev/null    && { echo "truenas"; return; }
    command -v podman &>/dev/null    && { echo "podman"; return; }
    command -v docker &>/dev/null    && { echo "docker"; return; }

    err "Could not detect environment. Install Proxmox, LXC, Podman, Docker, or run on Unraid/TrueNAS."
}

ENVIRONMENT=$(detect_environment "$@")
parse_args "$@"

case "$ENVIRONMENT" in
    configure) configure ;;
    proxmox)   proxmox_main ;;
    lxc)       lxc_main ;;
    incus)     incus_main ;;
    unraid)    unraid_main ;;
    truenas)   truenas_main ;;
    podman)    podman_main ;;
    docker)    docker_main ;;
esac
