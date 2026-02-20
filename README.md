# Edge Appliance Build System for AI-RA-Infra

Builds immutable Kairos-based OS images with NVIDIA DOCA pre-installed for Spectro Cloud's AI-RA-Infra profile. Wraps the upstream [CanvOS](https://github.com/spectrocloud/CanvOS) build system with an overlay pattern that keeps all customizations separate from the upstream repo.

## How It Works

All custom files live in `src/`. The Makefile applies them into a clean CanvOS clone at build time, runs the Earthly-based build, and collects artifacts back out. CanvOS itself is never modified permanently.

```
CanvOS_edge_builder/
├── Makefile              # Build orchestration
├── src/                  # Our modifications (tracked in git)
│   ├── Dockerfile        # Modified — adds DOCA/BFB installation
│   ├── Earthfile         # Modified — passes Edge Appliance ARGs
│   ├── .arg.template     # Modified — documents Edge Appliance variables
│   └── overlay/files/    # Config overlays baked into the image
│       ├── opt/spectrocloud/nodeprep.sh
│       ├── etc/modprobe.d/blacklist-nouveau.conf
│       ├── etc/modprobe.d/ib_core.conf
│       ├── etc/lldpd.d/rcp-lldpd.conf
│       └── etc/modules-load.d/nfsrdma.conf
│   └── hack/
│       └── launch-qemu.sh          # QEMU smoke test launcher
├── redist/               # Local firmware downloads (gitignored)
├── build/                # Build output — ISO + checksums (gitignored)
└── CanvOS/               # Upstream clone (gitignored)
```

## Prerequisites

- Docker 29.x+
- ~30 GB free disk space

## Quick Start

```bash
# 1. Clone this repo and initialize the CanvOS submodule
git clone https://github.com/blik616287/CanvOS_edge_builder.git
cd CanvOS_edge_builder
git submodule update --init

# 2. Verify prerequisites
make check-prereqs

# 3. Build the Edge Appliance image (fetches DOCA/BFB from URLs)
make build-url

# 4. Verify the build
make test
```

### Build from local firmware files

If you prefer to download firmware first (or have limited build-time network access):

```bash
make download    # Download firmware to redist/ (~2.1 GB)
make build       # Build using local redist/ files
```

Or in one step:

```bash
make build-local
```

### Standard (non-Edge) build

To build a standard CanvOS image without DOCA/BFB:

```bash
make build-provider EDGE_APPLIANCE=false
```

### Full pipeline

```bash
make all         # check-prereqs → build → test
```

## Make Targets

| Target | Description |
|--------|-------------|
| `make help` | Show all available targets |
| `make info` | Show current build configuration |
| `make check-prereqs` | Verify Docker, disk space, source files, firmware |
| `make download` | Download DOCA .deb and BFB firmware to `redist/` |
| `make build` | Build provider image + installer ISO from local files |
| `make build-url` | Build using firmware URLs (no local files needed) |
| `make build-local` | Download firmware, then build from local files |
| `make build-provider` | Build provider image only (no ISO) |
| `make build-iso` | Build installer ISO only |
| `make push` | Build and push provider image to registry |
| `make push-url` | Build and push using firmware URLs |
| `make test` | Verify built image contents + ISO |
| `make verify` | Verify DOCA, BFB, nodeprep, overlays in the built image |
| `make verify-iso` | Check that the installer ISO was created |
| `make smoke-test` | Launch QEMU VM from installer ISO for interactive testing |
| `make clean` | Full cleanup: build artifacts, images, redist/, revert CanvOS/ |
| `make clean-earthly` | Remove Earthly buildkit container and cache |

## Build Configuration

Override any setting via environment or make arguments:

```bash
make build K8S_VERSION=1.34.2 IMAGE_REGISTRY=myregistry.io CUSTOM_TAG=v1
```

| Variable | Default | Description |
|----------|---------|-------------|
| `OS_DISTRIBUTION` | `ubuntu` | Base OS |
| `OS_VERSION` | `24.04` | Ubuntu version (must match DOCA .deb) |
| `K8S_DISTRIBUTION` | `kubeadm` | Kubernetes flavor |
| `K8S_VERSION` | `1.34.2` | Kubernetes version |
| `ARCH` | `amd64` | Target architecture |
| `IMAGE_REGISTRY` | `ttl.sh` | Container registry for provider image |
| `CUSTOM_TAG` | `demo` | Image tag suffix |
| `EDGE_APPLIANCE` | `true` | Enable DOCA/BFB pre-installation |
| `UPDATE_KERNEL` | `false` | Must be false — HWE kernel breaks DOCA DKMS |

### Firmware URLs

The default firmware URLs point to GitHub releases. Override them if needed:

```bash
make build-url \
  DOCA_DEB_URL=https://example.com/doca-host.deb \
  BFB_URL=https://example.com/bf-bundle.bfb
```

## Build Output

A successful build produces:

- **Provider image** — `ttl.sh/ubuntu:kubeadm-<K8S_VERSION>-<PE_VERSION>-<CUSTOM_TAG>`
- **Installer ISO** — `build/palette-edge-installer.iso` (~4.2 GB)
- **SHA256 checksum** — `build/palette-edge-installer.iso.sha256`
- **Palette profile YAML** — printed to stdout for pasting into the cluster profile

## What Gets Baked Into the Image

When `EDGE_APPLIANCE=true`, the Dockerfile installs:

| Package | Purpose |
|---------|---------|
| `doca-all` | Full NVIDIA DOCA suite (OFED, SDK, runtime, mft, rshim) |
| `gcc-14` / `libgcc-14-dev` | Compiler for DOCA DKMS kernel modules (gcc-12 on 22.04) |
| `lldpd` | LLDP daemon for network discovery |
| `netplan.io` | Network configuration |
| `pv`, `psmisc` | Process monitoring utilities |
| `nfs-common` | NFS client for Longhorn and NFSoRDMA |
| `grepcidr` | CIDR matching for IP selection |

Additionally staged in the image:
- BFB firmware at `/opt/spectrocloud/spcx/bfb/<filename>`
- Adapted nodeprep script at `/opt/spectrocloud/nodeprep.sh`

## Nodeprep Script

The nodeprep script (`src/overlay/files/opt/spectrocloud/nodeprep.sh`) is adapted from [nodeprep-v102](https://gist.github.com/kreeuwijk/4bbd2b76586f5f80229ee92aebce3f6c) to work on both mutable (MaaS) and immutable (Kairos) OS.

On Kairos, it detects the immutable OS via `/etc/kairos` and:
- **Skips** all `apt-get`/`dpkg` package installation (packages are pre-baked)
- **Skips** BFB/DOCA downloads (files are pre-staged in the image)
- **Skips** GRUB modifications (handled via Kairos cloud-init)
- **Runs** all hardware operations: BFB firmware flash, NIC config via mlxconfig, SR-IOV VF setup, K8s node labeling

## Overlay Configuration Files

Baked into the immutable rootfs via `src/overlay/files/`:

| File | Purpose |
|------|---------|
| `etc/modprobe.d/blacklist-nouveau.conf` | Blacklists Nouveau GPU driver (required for NVIDIA) |
| `etc/modprobe.d/ib_core.conf` | RDMA namespace config (`netns_mode=0`) for SR-IOV |
| `etc/lldpd.d/rcp-lldpd.conf` | LLDP discovery configuration |
| `etc/modules-load.d/nfsrdma.conf` | Auto-loads NFSoRDMA kernel modules (rpcrdma, xprtrdma, svcrdma) |

## QEMU Smoke Testing

The `make smoke-test` target boots the installer ISO in a local QEMU VM for interactive verification. Requires KVM and QEMU installed on the host.

```bash
make build-iso    # Build the installer ISO first
make smoke-test   # Launch QEMU VM
```

The VM boots into the Kairos live environment with serial console. Use `Ctrl+A X` to exit QEMU.

What to verify in the QEMU smoke test:
- VM reaches the Kairos login prompt ("Welcome to Kairos!")
- `kairos-agent.service` and `kairos-installer.service` start
- `lldpd.service` starts (confirms overlay config)
- `mst start` fails gracefully when no NVIDIA hardware is present (expected in QEMU)

The QEMU script lives at `src/hack/launch-qemu.sh` and is overlaid into `CanvOS/hack/` at build time. It can be customized via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `MEMORY` | `10096` | VM memory in MB |
| `CORES` | `5` | Number of CPU cores |
| `CPU` | `host` | CPU model |

## Standard vs Edge Appliance Builds

The build system supports both standard CanvOS images and Edge Appliance images with DOCA pre-installed. Set `EDGE_APPLIANCE=false` to build a standard image without DOCA/BFB.

```bash
make build-provider EDGE_APPLIANCE=false    # Standard image (no DOCA)
make build-provider                          # Edge Appliance image (DOCA included)
```

| Attribute | Edge Appliance | Standard |
|-----------|---------------|----------|
| Image size | ~7 GB | ~3.5 GB |
| Package count | ~700 | ~430 |
| DOCA/OFED | Installed | Not installed |
| gcc-14 | Installed | Not installed |
| mst tools | Installed | Not installed |
| BFB firmware | 1.5 GB staged | Not present |
| nodeprep.sh | Present | Not present |
| Overlay configs | Present | Present |

## Deployment Notes

### PERSISTENT_STATE_PATHS

Edge Appliance deployments must add these paths to `PERSISTENT_STATE_PATHS` in the Kairos agent install user-data so that overlay configurations survive reboots:

```
/etc/default
/etc/lldpd.d
/etc/modprobe.d
/etc/modules-load.d
```

`/opt` is already persistent by default (includes `/opt/spectrocloud/` for nodeprep and BFB firmware).

Example `user-data` YAML snippet for the Kairos `install` block:

```yaml
install:
  bind_mounts:
    - /etc/default
    - /etc/lldpd.d
    - /etc/modprobe.d
    - /etc/modules-load.d
  grub_options:
    extra_cmdline: "intel_iommu=on iommu=pt"
```

These paths are added to the existing Kairos `PERSISTENT_STATE_PATHS` list alongside the defaults (`/etc/systemd`, `/etc/ssh`, `/etc/kubernetes`, `/opt`, etc.).

### `/run/mellanox` — Boot-Time Workaround

`/run` is a tmpfs filesystem that is cleared on every reboot. The `/run/mellanox` directory (used by DOCA/OFED tools like `mst status`) does not need to be in `PERSISTENT_STATE_PATHS`. Instead, `nodeprep.sh` recreates it at runtime during the `fn_inventory_hw` and `fn_config_stage` stages via `mst start`, which sets up `/run/mellanox` automatically each boot.

### Palette Cluster Profile

The target profile stack (AI-RA-Infra-Agent):

| Layer | Pack | Version |
|-------|------|---------|
| OS | edge-native-byoi | 2.1.0 |
| K8s | edge-k8s (kubeadm agent) | 1.34.2 |
| CNI | cni-cilium-oss | 1.18.4 |
| CSI | csi-longhorn | 1.10.1 |
| Addon | nodeprep-controller | 1.0.0 |
| Addon | network-operator (NVIDIA) | 25.10.0 |

### Known Constraints

- **DOCA kernel compatibility**: DOCA 3.2.1 DKMS modules require the GA kernel (6.8.x on Ubuntu 24.04). The HWE kernel (6.14.x) is not supported. `UPDATE_KERNEL=false` prevents this.
- **No UKI/Trusted Boot**: The Edge Appliance image (~7 GB) far exceeds UKI/EFI partition limits (~1 GB). Grub-based boot is required.
- **Ubuntu version must match**: The DOCA .deb and BFB firmware are version-specific. A 22.04 .deb will not work on a 24.04 image.
- **Image size**: Edge Appliance images are significantly larger than standard CanvOS images (~7 GB vs ~3.5 GB) due to DOCA packages and 1.5 GB BFB firmware.
