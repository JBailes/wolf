#!/usr/bin/env bash
# common.sh -- Shared helpers for Wolf cloud gaming deployment scripts
#
# Sourced by wolf.sh and environment-specific scripts. Not run directly.

# =========================================================================
# Defaults (set once, not overwritten if already set by caller)
# =========================================================================

: "${CTID:=120}"
: "${CT_CPU:=4}"
: "${CT_RAM:=4096}"
: "${CT_DISK:=16}"
: "${CT_IP:=auto}"
: "${CT_GW:=auto}"
: "${CT_CIDR:=auto}"
: "${CT_STORAGE:=auto}"
: "${LXC_NAME:=wolf}"
: "${APPDATA:=/mnt/user/appdata/wolf}"
: "${ZFS_POOL:=auto}"

: "${IMAGE_STORAGE:=isos}"
: "${PROXMOX_TEMPLATE_FILE:=debian-13-standard_13.1-2_amd64.tar.zst}"
: "${TEMPLATE:=auto}"
: "${LAN_BRIDGE:=vmbr0}"

# =========================================================================
# Argument parsing
# =========================================================================

# Parse shared CLI flags into globals. Unknown flags are silently ignored
# so environment-specific scripts can extend with their own flags.
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
            --image-storage) IMAGE_STORAGE="${2:?--image-storage requires a value}"; shift 2 ;;
            --template)    TEMPLATE="${2:?--template requires a value}"; shift 2 ;;
            --name)        LXC_NAME="${2:?--name requires a value}"; shift 2 ;;
            --render-node) SELECTED_RENDER_NODE="${2:?--render-node requires a value}"; shift 2 ;;
            --appdata)     APPDATA="${2:?--appdata requires a value}"; shift 2 ;;
            --pool)        ZFS_POOL="${2:?--pool requires a value}"; shift 2 ;;
            *)             shift ;;
        esac
    done
}

# =========================================================================
# Output helpers
# =========================================================================

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

# =========================================================================
# Prompt helpers
# =========================================================================

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

# =========================================================================
# Udev rules
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

# Write the udev rules content to stdout (for scripts that store rules elsewhere).
write_udev_rules_content() {
    cat <<'UDEV'
KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput", TAG+="uaccess"
KERNEL=="uhid", GROUP="input", MODE="0660", TAG+="uaccess"
KERNEL=="hidraw*", ATTRS{name}=="Wolf PS5 (virtual) pad", GROUP="input", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf X-Box One (virtual) pad", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf PS5 (virtual) pad", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf gamepad (virtual) motion sensors", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf Nintendo (virtual) pad", MODE="0660", ENV{ID_SEAT}="seat9"
UDEV
}

# =========================================================================
# NVIDIA helpers
# =========================================================================

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
    local -a build_cmd

    [[ -z "${NV_VERSION:-}" ]] && detect_nvidia_version
    info "NVIDIA driver version: ${NV_VERSION}"

    if "$tool" volume inspect nvidia-driver-vol &>/dev/null; then
        info "NVIDIA driver volume already exists"
        return
    fi

    info "Building NVIDIA driver volume (this may take a few minutes)..."
    if [[ "$tool" == "docker" ]]; then
        if ! docker buildx version &>/dev/null; then
            err "Docker buildx is required to build the NVIDIA driver volume. Install the Docker buildx plugin and rerun the quickstart."
        fi
        build_cmd=(docker buildx build --load)
    else
        build_cmd=("$tool" build)
    fi

    "${build_cmd[@]}" -t gow/nvidia-driver:latest -f - \
            --build-arg "NV_VERSION=${NV_VERSION}" . <<'DOCKERFILE'
FROM fedora:43 AS nvidia-installer

ARG NV_VERSION
RUN dnf install -y --setopt=install_weak_deps=False \
        curl kmod libglvnd-devel pkg-config && \
    curl -fLO "https://download.nvidia.com/XFree86/Linux-x86_64/${NV_VERSION}/NVIDIA-Linux-x86_64-${NV_VERSION}.run" && \
    chmod +x "NVIDIA-Linux-x86_64-${NV_VERSION}.run" && \
    mkdir -p /usr/nvidia && \
    "./NVIDIA-Linux-x86_64-${NV_VERSION}.run" --silent -z \
        --skip-depmod --skip-module-unload \
        --no-nvidia-modprobe --no-kernel-modules --no-kernel-module-source \
        --opengl-prefix=/usr/nvidia \
        --wine-prefix=/usr/nvidia \
        --utility-prefix=/usr/nvidia --utility-libdir=lib \
        --compat32-prefix=/usr/nvidia --compat32-libdir=lib32 \
        --egl-external-platform-config-path=/usr/nvidia/share/egl/egl_external_platform.d \
        --glvnd-egl-config-path=/usr/nvidia/share/glvnd/egl_vendor.d \
        --no-distro-scripts && \
    rm "NVIDIA-Linux-x86_64-${NV_VERSION}.run"

RUN printf '/usr/nvidia/lib\n/usr/nvidia/lib32\n' > /etc/ld.so.conf.d/nvidia.conf && ldconfig

FROM scratch

COPY --from=nvidia-installer /usr/nvidia/ /usr/nvidia
COPY --from=nvidia-installer /etc/vulkan/icd.d/nvidia_icd.json /usr/nvidia/share/vulkan/icd.d/
COPY --from=nvidia-installer /bin/sh /bin/sh
DOCKERFILE

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
# LXC GPU passthrough config (shared between Proxmox, standalone LXC, and configure)
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
            # Detect dynamic major numbers — these vary by kernel/driver version.
            local uvm_major caps_major
            uvm_major=$(printf '%d' "0x$(stat -c '%t' /dev/nvidia-uvm 2>/dev/null)") || uvm_major=""
            caps_major=$(printf '%d' "0x$(stat -c '%t' /dev/nvidia-caps/nvidia-cap1 2>/dev/null)") || caps_major=""

            cat >> "$conf" <<EOF
lxc.cgroup2.devices.allow${sep} c 195:* rwm
EOF
            [[ -n "$uvm_major" ]] \
                && printf 'lxc.cgroup2.devices.allow%s c %d:* rwm\n' "$sep" "$uvm_major" >> "$conf"
            [[ -n "$caps_major" ]] \
                && printf 'lxc.cgroup2.devices.allow%s c %d:* rwm\n' "$sep" "$caps_major" >> "$conf"
            cat >> "$conf" <<EOF
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
clean_lxc_gpu_config() {
    local conf="$1"
    if grep -q "# Wolf cloud gaming" "$conf" 2>/dev/null; then
        info "Removing old Wolf config"
        sed -i '/# Wolf cloud gaming/,$ d' "$conf"
    fi
}

install_nvidia_userspace_driver() {
    local nv_version="$1"

    if ldconfig -p 2>/dev/null | grep -q "libnvidia-ml.so.${nv_version}"; then
        info "NVIDIA userspace driver ${nv_version} already installed"
        return
    fi

    info "Installing NVIDIA ${nv_version} userspace driver (no kernel modules)"
    local installer="NVIDIA-Linux-x86_64-${nv_version}.run"
    local installer_path="/tmp/${installer}"

    if [[ ! -f "$installer_path" ]]; then
        curl -fL -o "$installer_path" \
            "https://download.nvidia.com/XFree86/Linux-x86_64/${nv_version}/${installer}"
    fi

    chmod +x "$installer_path"
    DEBIAN_FRONTEND=noninteractive "$installer_path" \
        --silent \
        --no-kernel-modules \
        --no-kernel-module-source \
        --no-check-for-alternate-installs \
        --skip-module-unload \
        --skip-depmod \
        --no-nvidia-modprobe \
        --no-distro-scripts

    rm -f "$installer_path"
    info "NVIDIA userspace driver ${nv_version} installed"
}

install_nvidia_container_toolkit() {
    if command -v nvidia-ctk &>/dev/null; then
        info "NVIDIA Container Toolkit already installed"
    else
        info "Installing NVIDIA Container Toolkit"
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
            | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
            | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
            > /etc/apt/sources.list.d/nvidia-container-toolkit.list
        apt-get update -qq
        apt-get install -y --no-install-recommends nvidia-container-toolkit
        info "NVIDIA Container Toolkit installed"
    fi

    nvidia-ctk runtime configure --runtime=docker --set-as-default
    systemctl restart docker
    info "Docker configured to use NVIDIA runtime"
}

ensure_nvidia_modules_loaded() {
    [[ "$SELECTED_VENDOR" == "NVIDIA" ]] || return 0
    command -v modprobe &>/dev/null || return 0

    local module
    for module in nvidia nvidia_modeset nvidia_uvm; do
        modprobe "$module" 2>/dev/null || true
    done
    modprobe nvidia_drm modeset=1 2>/dev/null || true

    # nvidia-modprobe creates /dev/nvidia-modeset and /dev/nvidia-caps/* which
    # the kernel driver does not create automatically via udev on bare installs.
    command -v nvidia-modprobe &>/dev/null && nvidia-modprobe -m 2>/dev/null || true
}

# =========================================================================
# Docker compose generation
# =========================================================================

# Write compose file to /opt/wolf/. Usage: write_compose <vendor> <render_node>
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
    runtime: nvidia
    environment:
      - WOLF_RENDER_NODE=${render_node}
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=all
      - XDG_RUNTIME_DIR=/tmp/sockets
      - WOLF_CFG_FILE=/etc/wolf/cfg/config.toml
      - WOLF_DOCKER_SOCKET=/var/run/docker.sock
      - WOLF_PULSE_IMAGE=ghcr.io/games-on-whales/pulseaudio:fedora-43
    volumes:
      - /etc/wolf:/etc/wolf:rw
      - /var/run/docker.sock:/var/run/docker.sock:rw
      - /dev/:/dev/:rw
      - /run/udev:/run/udev:rw
      - wolf-socket:/tmp/sockets
    devices:
      - /dev/dri
      - /dev/uinput
      - /dev/uhid
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
    runtime: nvidia
    environment:
      - WOLF_RENDER_NODE=${render_node}
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=all
      - XDG_RUNTIME_DIR=/tmp/sockets
      - WOLF_CFG_FILE=/etc/wolf/cfg/config.toml
      - WOLF_DOCKER_SOCKET=/var/run/docker.sock
      - WOLF_PULSE_IMAGE=ghcr.io/games-on-whales/pulseaudio:fedora-43
    volumes:
      - ${wolf_cfg}:/etc/wolf/cfg:rw
      - ${steam}:/etc/wolf/steam:rw
      - /var/run/docker.sock:/var/run/docker.sock:rw
      - /dev/:/dev/:rw
      - /run/udev:/run/udev:rw
      - wolf-socket:/tmp/sockets
    devices:
      - /dev/dri
      - /dev/uinput
      - /dev/uhid
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
# Wolf config generation
# =========================================================================

# Write default Wolf config with Steam. Usage: write_wolf_config <cfg_dir>
# Skips if config already exists.
write_wolf_config() {
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
image = "ghcr.io/games-on-whales/steam:fedora-43"
mounts = ["/etc/wolf/steam:/home/retro:rw"]
env = ["PROTON_LOG=1", "RUN_SWAY=true"]
TOML
}

# =========================================================================
# Docker helpers
# =========================================================================

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
# Container deployment helper (Proxmox, LXC, Incus)
# =========================================================================

# Deploy Wolf into a container by pushing configure.sh + common.sh and running configure.sh.
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
         /root/configure.sh"
}
