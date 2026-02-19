# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

CanvOS_edge_builder creates immutable Kairos-based OS images with NVIDIA DOCA pre-installed for Spectro Cloud's AI-RA-Infra profile. It targets edge appliances with BlueField-3 DPU support. The project uses an **overlay pattern**: all customizations live in `src/` and are copied into a cloned upstream `CanvOS/` directory at build time, keeping custom code cleanly separated from upstream.

## Build Commands

```bash
# Prerequisites: Docker 29.x+, 30 GB disk, CanvOS/ clone must exist
make check-prereqs          # Verify all prerequisites

# Primary build targets
make build-url              # Build using firmware URLs (no local downloads)
make build-local            # Download firmware to redist/, then build from local files
make build                  # Build from local files (assumes firmware already in redist/)
make all                    # Full pipeline: check-prereqs → build → test

# Individual stages
make setup                  # Apply src/ overlay into CanvOS/ (resets CanvOS/ first)
make configure              # Generate CanvOS/.arg from current settings
make download               # Download DOCA .deb and BFB firmware to redist/
make build-provider         # Build provider image only
make build-iso              # Build installer ISO only
make push                   # Build and push provider image to registry

# Verification
make test                   # Run verify + verify-iso
make verify                 # Check DOCA, BFB, nodeprep, overlays in built image
make verify-iso             # Check installer ISO exists with valid SHA256

# Cleanup
make clean                  # Full cleanup: artifacts, images, redist/, revert CanvOS/
make clean-earthly          # Remove Earthly buildkit container and cache

# Info
make help                   # List all targets
make info                   # Show current build configuration
```

All build variables can be overridden on the command line:
```bash
make build K8S_VERSION=1.34.2 OS_VERSION=24.04 IMAGE_REGISTRY=myregistry.io CUSTOM_TAG=mytag
```

## Architecture

### Build Pipeline Flow

```
make build
  → check-prereqs   (Docker, disk space, source files, firmware)
  → setup           (copy src/* → CanvOS/, reset CanvOS/ first)
  → setup-firmware   (copy redist/* firmware → CanvOS/ if local files)
  → configure       (generate CanvOS/.arg with all build variables)
  → Earthly build    (cd CanvOS && ./earthly.sh +build-all-images)
  → Collect artifacts (CanvOS/build/* → ./build/)
```

### Key Files

- **Makefile** — Build orchestrator. Manages the overlay pattern, prerequisite checking, firmware staging, .arg generation, and Earthly invocation.
- **src/Dockerfile** — Custom Dockerfile extending the Kairos base. When `EDGE_APPLIANCE=true`, installs GCC, DOCA host package, stages BFB firmware at `/opt/spectrocloud/spcx/bfb/`, holds kernel packages, and installs supporting packages (lldpd, netplan, nfs-common, etc.). Accepts both local file paths and URLs for DOCA/BFB.
- **src/Earthfile** — Modified Earthly build config. Passes Edge Appliance arguments (`EDGE_APPLIANCE`, `DOCA_DEB_PATH`, `BFB_PATH`, `BFB_FILENAME`) through to Dockerfile. Key targets: `+build-all-images`, `+base-image`, `+provider-image`, `+iso-image`.
- **src/.arg.template** — Self-documenting template of all build variables with defaults.
- **src/overlay/files/opt/spectrocloud/nodeprep.sh** — Node preparation script adapted for both mutable (MaaS) and immutable (Kairos) OS. Detects `/etc/kairos` to determine mode: on immutable OS it skips package installs and downloads (pre-baked), running only hardware operations (BFB flash, NIC config, SR-IOV VF setup, node labeling).
- **src/overlay/files/etc/** — Configuration overlays baked into the image (Nouveau blacklist, InfiniBand RDMA namespace config, LLDP discovery, NFSoRDMA kernel modules).

### Directory Layout

- `src/` — All custom modifications (tracked in git)
- `CanvOS/` — Upstream clone (gitignored, not modified directly)
- `redist/` — Local firmware downloads (gitignored)
- `build/` — Build output: installer ISO (~4.2 GB), SHA256, provider images (gitignored)

## Critical Constraints

- **`UPDATE_KERNEL` must be `false`** — The HWE kernel breaks DOCA DKMS module compilation. Only the GA kernel is compatible.
- **`OS_VERSION` must match the DOCA .deb** — The DOCA package has version-specific dependencies (e.g., Ubuntu 24.04 .deb won't work on 22.04).
- **No UKI/Trusted Boot** — DOCA packages make the image too large for the EFI partition; must use GRUB-based boot.
- **Kernel packages are held** (`apt-mark hold`) to prevent upgrades from breaking DOCA DKMS.
- **Immutable OS detection** — `nodeprep.sh` checks for `/etc/kairos` to differentiate mutable vs. immutable behavior. Do not remove this check.

## Build Output

A successful build produces:
1. **Provider Docker image** pushed to the configured registry (default `ttl.sh`)
2. **Installer ISO** at `build/palette-edge-installer.iso`
3. **SHA256 checksum** at `build/palette-edge-installer.iso.sha256`
