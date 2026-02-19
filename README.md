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
├── redist/               # Local firmware downloads (gitignored)
├── build/                # Build output — ISO + checksums (gitignored)
└── CanvOS/               # Upstream clone (gitignored)
```

## Prerequisites

- Docker 29.x+
- ~30 GB free disk space
- CanvOS cloned into `CanvOS/`:
  ```bash
  git clone https://github.com/spectrocloud/CanvOS.git
  ```

## Quick Start

### Build from URLs (no local downloads needed)

```bash
make build-url
```

This fetches the DOCA .deb and BFB firmware directly from URLs during the Docker build.

### Build from local files

```bash
make download    # Download firmware to redist/ (~2.1 GB)
make build       # Build using local redist/ files
```

Or in one step:

```bash
make build-local
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

## Deployment Notes

### PERSISTENT_STATE_PATHS

Edge Appliance deployments must add these paths to `PERSISTENT_STATE_PATHS` in the Kairos user-data:

```
/etc/default
/etc/lldpd.d
/etc/modprobe.d
/etc/modules-load.d
```

`/opt` is already persistent by default.

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
- **No UKI/Trusted Boot**: DOCA makes images too large for the EFI partition. Grub-based boot only.
- **Ubuntu version must match**: The DOCA .deb and BFB firmware are version-specific. A 22.04 .deb will not work on a 24.04 image.
