# Wolf Cloud Gaming Setup

This directory contains `wolf.sh`, a single self-contained script that turns a Linux machine with a GPU into a cloud gaming host using [Wolf](https://github.com/games-on-whales/wolf) and [Moonlight](https://moonlight-stream.org/).

## What is this?

**Wolf** is a program that lets you play games on a powerful computer (your server) while viewing and controlling them from another device -- your phone, tablet, laptop, or TV. Think of it like Netflix, but for games: the server does all the hard work, and you just watch and play over your network.

**Moonlight** is the app you install on the device you want to play on (the "client"). It connects to Wolf and shows you the game.

**Wolf Den** is a web interface that makes it easy to manage Wolf -- you can pair new devices, add apps, and configure settings from your browser. It's deployed automatically alongside Wolf on all platforms.

## What does this script do?

`wolf.sh` detects what kind of system you're running and sets everything up automatically:

| Environment | What happens |
|---|---|
| **Proxmox** (a server hypervisor) | Creates a container, passes your GPU into it, installs Docker, and deploys Wolf + Wolf Den inside |
| **LXC / Incus** (Linux container tools) | Same as Proxmox but using standalone LXC tools or Incus instead |
| **Docker** (on any Linux machine) | Deploys Wolf + Wolf Den directly using Docker Compose |
| **Podman** (on any Linux machine) | Deploys Wolf + Wolf Den as systemd services using Podman Quadlets |

You don't need to choose -- the script figures out which one you have and does the right thing. It checks in this order: Proxmox, LXC/Incus, Podman, Docker.

> **What's a "container"?** On Proxmox, LXC, and Incus, the script creates a lightweight virtual environment (a "container") on your server to run Wolf in. Think of it as a mini computer running inside your computer. Your GPU is shared with this container so Wolf can use it for gaming. On Docker and Podman, Wolf runs directly on your machine without this extra layer.

After setup, **Steam** is pre-configured as a launchable app in Moonlight. You can add more apps (like other game launchers or desktop environments) through Wolf Den or by editing the Wolf config file.

## What you need before starting

### On the server (the computer that will run the games)

- **A Linux machine with a GPU** -- this can be:
  - A Proxmox VE server (version 7.x or 8.x)
  - Any Linux machine with LXC tools (`lxc-create`) or Incus installed
  - Any Linux machine with Docker installed
  - Any Linux machine with Podman installed
- **GPU drivers installed and working**:
  - **Intel** -- usually works out of the box (driver loads automatically)
  - **AMD** -- usually works out of the box (driver loads automatically)
  - **NVIDIA** -- you must install the proprietary NVIDIA driver yourself first
- **Root access** -- you need to run the script as root (using `sudo`)

### On the client (the device you want to play on)

- **The Moonlight app** -- download it for free from [moonlight-stream.org](https://moonlight-stream.org/)
  - Available for: Windows, Mac, Linux, Android, iOS, Apple TV, Raspberry Pi, and more

### Proxmox only (extra requirement)

- **A Debian 13 LXC template** downloaded in Proxmox (the script expects `debian-13-standard_13.1-2_amd64.tar.zst` in your ISO storage)

### How to check if your GPU driver is loaded

Open a terminal on your server and run:

```bash
ls /dev/dri/renderD*
```

If you see output like `/dev/dri/renderD128`, your GPU driver is loaded and you're good to go. If you see nothing, you need to install GPU drivers first -- search for "[your Linux distro] install [Intel/AMD/NVIDIA] GPU driver" for instructions.

## Quick start

### Step 1: Copy the script to your server

From your local machine, copy the script to your server:

```bash
scp wolf.sh root@your-server-ip:/root/
```

Or, if you're already on the server, download it directly or copy it however you prefer.

### Step 2: Run the script

SSH into your server and run:

```bash
ssh root@your-server-ip
chmod +x /root/wolf.sh
./wolf.sh
```

The script will:
- Figure out if you're on Proxmox, LXC, Incus, Docker, or Podman
- Detect your GPU automatically
- Set everything up

### Step 3: Read the output

When it finishes, you'll see a summary with your server's IP and instructions. For example:

```
================================================================
Wolf cloud gaming is deployed (Docker).

  Wolf:      streaming on ports 47984-48200 (Moonlight)
  Wolf Den:  http://192.168.1.50:8080 (web management)
  Compose:   /opt/wolf/docker-compose.yml
  GPU:       AMD Radeon RX 6900 XT (amdgpu) at /dev/dri/renderD128

To pair with Moonlight:
  1. Open Wolf Den at http://192.168.1.50:8080 to manage apps and clients
  2. Open Moonlight and add server: 192.168.1.50
  3. Enter the pairing PIN shown in Moonlight into Wolf Den
================================================================
```

### Step 4: Connect with Moonlight

1. Open the **Moonlight** app on your phone/tablet/laptop/TV
2. Tap **Add Host** (or the `+` button) and type in the server IP shown in the output
3. Moonlight will show a **4-digit PIN** -- enter it into **Wolf Den** (the web management page shown in the output) to complete pairing
4. You're connected -- launch a game from Moonlight

## Options

All options are optional. The script auto-detects sensible defaults for everything. Just running `./wolf.sh` with no options works in most cases. Flags that don't apply to your environment are silently ignored, so the same command works everywhere.

| Option | What it does | Default | Used by |
|---|---|---|---|
| `--cpu <cores>` | How many CPU cores to give the container | `4` | Proxmox, LXC, Incus |
| `--ram <mb>` | How much memory (in MB) to give the container | `4096` (4 GB) | Proxmox, LXC, Incus |
| `--disk <gb>` | How much disk space (in GB) | `16` | Proxmox, LXC, Incus |
| `--name <name>` | Name for the container | `wolf` | LXC, Incus |
| `--ctid <id>` | Container ID number | `120` | Proxmox |
| `--ip <addr>` | IP address for the container | Auto: uses your network + CTID | Proxmox |
| `--gw <addr>` | Your router's IP address | Auto: detected from your network | Proxmox |
| `--cidr <bits>` | Subnet size (you probably don't need to change this) | Auto: detected from your network | Proxmox |
| `--storage <name>` | Which Proxmox storage pool to use | Auto: asks you if there are multiple | Proxmox |
| `--render-node <path>` | Which GPU to use (e.g. `/dev/dri/renderD128`) | Auto: you choose if there are multiple | All |

### Examples

Run with all defaults (auto-detect everything):

```bash
./wolf.sh
```

Proxmox -- specify a custom container ID and IP:

```bash
./wolf.sh --ctid 150 --ip 192.168.1.150
```

LXC / Incus -- give the container a custom name and more resources:

```bash
./wolf.sh --name my-wolf --cpu 8 --ram 8192
```

Proxmox -- give the container more resources for demanding games:

```bash
./wolf.sh --cpu 8 --ram 8192 --disk 32
```

Use a specific GPU (skip the selection prompt):

```bash
./wolf.sh --render-node /dev/dri/renderD129
```

## What gets created on your system

### Proxmox

- An LXC container (default ID: 120, hostname: `wolf`)
- GPU passthrough configuration in `/etc/pve/lxc/<CTID>.conf`
- Inside the container: Docker, Wolf, and Wolf Den (see Docker section below)

### LXC (standalone)

- An LXC container (default name: `wolf`) in `/var/lib/lxc/wolf/`
- GPU passthrough configuration appended to the container config
- Inside the container: Docker, Wolf, and Wolf Den (see Docker section below)

### Incus

- An Incus container (default name: `wolf`)
- GPU devices added via `incus config device add`
- Inside the container: Docker, Wolf, and Wolf Den (see Docker section below)

### Docker

| Path | What it is |
|---|---|
| `/opt/wolf/docker-compose.yml` | Configuration file that tells Docker how to run Wolf + Wolf Den |
| `/etc/wolf/cfg/config.toml` | Wolf configuration (apps, codec support) |
| `/etc/wolf/steam/` | Persistent storage for Steam (game installs, saves) |
| `/etc/wolf/wolf-den/` | Wolf Den state |
| `/etc/wolf/covers/` | App cover art images |
| `/etc/udev/rules.d/85-wolf-virtual-inputs.rules` | Rules that let Wolf create virtual game controllers |

### Podman

| Path | What it is |
|---|---|
| `/etc/containers/systemd/wolf.container` | Quadlet file for the Wolf streaming service |
| `/etc/containers/systemd/wolf-den.container` | Quadlet file for the Wolf Den web management UI |
| `/etc/wolf/` | Wolf's configuration and data directory |
| `/etc/udev/rules.d/85-wolf-virtual-inputs.rules` | Rules that let Wolf create virtual game controllers |

## GPU support

The script automatically detects your GPU vendor and configures the correct passthrough settings:

| Vendor | Driver | Notes |
|---|---|---|
| **Intel** | `i915` / `xe` | Passthrough via `/dev/dri` only. Works with integrated and Arc GPUs. |
| **AMD** | `amdgpu` | Passthrough via `/dev/dri` + `/dev/kfd` (if available for compute). |
| **NVIDIA** | `nvidia` | Passthrough via `/dev/dri` + NVIDIA device nodes. Requires building a driver volume inside the container (done automatically, takes a few minutes on first run). |

If your server has multiple GPUs, the script lists them with their product names and lets you choose:

```
Available GPUs:
  1) AMD Radeon RX 6900 XT (amdgpu, /dev/dri/renderD128)
  2) Intel UHD Graphics 770 (i915, /dev/dri/renderD129)

Select GPU for Wolf [1]:
```

## Managing Wolf after installation

### Docker

```bash
cd /opt/wolf

# Check if Wolf is running
docker compose ps

# View logs (press Ctrl+C to stop watching)
docker compose logs -f

# Stop Wolf
docker compose stop

# Restart Wolf
docker compose restart

# Update to the latest version
docker compose pull
docker compose up -d
```

### Podman

```bash
# Check if Wolf is running
systemctl status wolf wolf-den

# View logs (press Ctrl+C to stop watching)
journalctl -u wolf -f         # Wolf logs
journalctl -u wolf-den -f     # Wolf Den logs

# Stop Wolf
systemctl stop wolf wolf-den

# Restart Wolf
systemctl restart wolf wolf-den

# Update to the latest version
podman pull ghcr.io/games-on-whales/wolf:stable
podman pull ghcr.io/games-on-whales/wolf-den:stable
systemctl restart wolf wolf-den
```

### Proxmox

First enter the container, then use Docker commands:

```bash
# Enter the container (replace 120 with your CTID)
pct enter 120

# Then use the Docker commands listed above
cd /opt/wolf
docker compose ps
docker compose logs -f
# etc.
```

### LXC (standalone)

```bash
# Enter the container
lxc-attach -n wolf

# Then use the Docker commands listed above
cd /opt/wolf
docker compose ps
# etc.
```

### Incus

```bash
# Enter the container
incus exec wolf -- bash

# Then use the Docker commands listed above
cd /opt/wolf
docker compose ps
# etc.
```

## Re-running the script

The script is safe to re-run. It won't break anything if you run it again:

- **Proxmox / LXC / Incus**: If the container already exists, it skips creation and reconfigures GPU passthrough
- **Docker**: If the compose file exists, it updates and restarts the services
- **Podman**: If the Quadlet file exists, it overwrites it with the latest configuration

## Troubleshooting

### "No GPU render devices found"

This means your GPU driver is not loaded. Check with:

```bash
ls /dev/dri/renderD*
```

If nothing shows up, your GPU driver isn't installed or loaded. Search for how to install your GPU driver on your Linux distribution.

### "Could not detect environment"

The script couldn't find Proxmox, LXC, Podman, or Docker. You need at least one of these installed:

- **Docker**: Follow the [official Docker install guide](https://docs.docker.com/engine/install/)
- **Podman**: Install with your package manager (e.g. `apt install podman` on Debian/Ubuntu)
- **LXC**: Install with `apt install lxc` on Debian/Ubuntu
- **Incus**: Follow the [Incus install guide](https://linuxcontainers.org/incus/docs/main/installing/)
- **Proxmox**: Install from [proxmox.com](https://www.proxmox.com/)

### Moonlight can't find the server

- Make sure Wolf is running (see "Managing Wolf" above)
- Make sure your device (phone/tablet/laptop) is on the **same network** as the server
- Try typing the server's IP address manually in Moonlight instead of waiting for auto-discovery
- Check that your firewall isn't blocking ports 47984-48200

### Games are laggy or stuttering

- Use a **wired ethernet cable** instead of Wi-Fi on the server (Wi-Fi adds lag)
- If on Proxmox, LXC, or Incus, give the container more resources: re-run with `--cpu 8 --ram 8192`
- On the Moonlight client, try lowering the resolution or frame rate in settings
- Make sure no other heavy programs are using your GPU at the same time

### NVIDIA: "Cannot determine NVIDIA driver version"

The NVIDIA driver isn't properly installed. Run:

```bash
nvidia-smi
```

If this command doesn't work or isn't found, you need to install the NVIDIA driver first. Search for "install NVIDIA driver on [your Linux distro]".

## Uninstalling Wolf

### Docker

```bash
cd /opt/wolf
docker compose down
rm -rf /opt/wolf /etc/wolf
rm /etc/udev/rules.d/85-wolf-virtual-inputs.rules
```

### Podman

```bash
systemctl stop wolf wolf-den
systemctl disable wolf wolf-den
rm /etc/containers/systemd/wolf.container /etc/containers/systemd/wolf-den.container
systemctl daemon-reload
podman volume rm wolf-socket
rm -rf /etc/wolf
rm /etc/udev/rules.d/85-wolf-virtual-inputs.rules
```

### Proxmox

```bash
# Replace 120 with your CTID
pct stop 120
pct destroy 120
```

### LXC (standalone)

```bash
lxc-stop -n wolf
lxc-destroy -n wolf
```

### Incus

```bash
incus stop wolf
incus delete wolf
```

## Network ports

Wolf uses the following network ports. If you have a firewall on your server, you'll need to allow these for Moonlight to connect. On most home networks, no firewall changes are needed.

| Port | Protocol | Purpose |
|---|---|---|
| 47984 | TCP | HTTPS (Moonlight control) |
| 47989 | TCP | HTTP (Moonlight control) |
| 48010 | TCP | RTSP (stream setup) |
| 47998-48000 | UDP | Video stream |
| 48002-48010 | UDP | Audio / input |
| 8080 | TCP | Wolf Den web UI |

To open these ports on a Linux firewall (if needed):

```bash
# Using ufw (Ubuntu/Debian)
sudo ufw allow 47984:48200/tcp
sudo ufw allow 47998:48200/udp
sudo ufw allow 8080/tcp

# Using firewalld (Fedora/CentOS)
sudo firewall-cmd --permanent --add-port=47984-48200/tcp
sudo firewall-cmd --permanent --add-port=47998-48200/udp
sudo firewall-cmd --permanent --add-port=8080/tcp
sudo firewall-cmd --reload
```
