#!/usr/bin/env bash
# Hauler artifact lifecycle — carbide-enclave
#
# Required privilege: root for serve/install; mansible for sync/save/push
# Credentials:        ~/.config/RGS/creds (CARBIDE_USERNAME, CARBIDE_PASSWORD)
#
# Usage:
#   bash scripts/hauler.sh sync    # pull artifacts from upstream (needs internet)
#   bash scripts/hauler.sh save    # package store → timestamped tarball in web root
#   bash scripts/hauler.sh load <tarball>  # load tarball into store (airgap side)
#   bash scripts/hauler.sh serve   # start Hauler registry on :5000
#   bash scripts/hauler.sh push    # push store → Harbor (after Harbor is up)
#   bash scripts/hauler.sh all     # sync → save in one shot (pre-airgap)
#
# Manifests are generated from env vars into ${MANIFEST_DIR} and are
# browseable at http://10.0.0.10/hauler/manifests/ for reference.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/env.d/carbide-enclave.sh"
[[ -f "${HOME}/.config/RGS/creds" ]] && source "${HOME}/.config/RGS/creds"

STORE_DIR="/var/lib/hauler"
MANIFEST_DIR="/srv/www/htdocs/hauler/manifests"
TARBALL_DIR="/srv/www/htdocs/hauler"

# RKE2 image tag — replace + with - for OCI compatibility
RKE2_TAG="${RKE2_VERSION//+/-}"

# RKE2 URL — replace + with %2B for GitHub download URLs
RKE2_URL_VERSION="${RKE2_VERSION//+/%2B}"

log() { echo "[hauler] $*"; }

# ── install ───────────────────────────────────────────────────────────────────

install_hauler() {
    if command -v hauler &>/dev/null; then
        log "hauler already installed: $(hauler version 2>/dev/null | head -1)"
        return
    fi
    # get.hauler.dev prepends its own 'v'; strip ours to avoid vv1.0.0
    local hauler_ver="${HAULER_VERSION#v}"
    log "installing hauler ${HAULER_VERSION}"
    if [[ $EUID -eq 0 ]]; then
        curl -sfL https://get.hauler.dev | HAULER_VERSION="${hauler_ver}" bash
    else
        # Non-root: install to ~/.local/bin and add to PATH for this session
        local user_bin="${HOME}/.local/bin"
        install -d -m 755 "${user_bin}"
        curl -sfL https://get.hauler.dev \
            | HAULER_VERSION="${hauler_ver}" HAULER_INSTALL_DIR="${user_bin}" bash
        export PATH="${user_bin}:${PATH}"
    fi
}

# ── manifest generation ───────────────────────────────────────────────────────

generate_manifests() {
    log "generating manifests → ${MANIFEST_DIR}"
    install -d -m 755 "${MANIFEST_DIR}"

    generate_rke2_manifest
    generate_cert_manager_manifest
    generate_rancher_manifest
    generate_harvester_manifest
    generate_harbor_manifest
    generate_keycloak_manifest
    generate_gpu_operator_manifest

    log "manifests written:"
    ls -1 "${MANIFEST_DIR}/"
}

generate_rke2_manifest() {
    cat > "${MANIFEST_DIR}/rke2.yaml" <<EOF
# RKE2 ${RKE2_VERSION} — images and install tarballs
# Source: ${CARBIDE_REGISTRY:-registry.ranchercarbide.dev}
---
apiVersion: content.hauler.cattle.io/v1alpha1
kind: Images
metadata:
  name: rke2-images
spec:
  images:
    # RKE2 runtime — consumed by platform/rke2
    - name: ${CARBIDE_REGISTRY}/rancher/rke2-runtime:${RKE2_TAG}
      platforms:
        - linux/amd64
        - linux/arm64
---
apiVersion: content.hauler.cattle.io/v1alpha1
kind: Files
metadata:
  name: rke2-binaries
spec:
  files:
    # Install script
    - path: https://get.rke2.io
      name: rke2-install.sh
    # amd64 binaries
    - path: https://github.com/rancher/rke2/releases/download/${RKE2_URL_VERSION}/rke2.linux-amd64.tar.gz
    - path: https://github.com/rancher/rke2/releases/download/${RKE2_URL_VERSION}/rke2-images.linux.amd64.tar.zst
    - path: https://github.com/rancher/rke2/releases/download/${RKE2_URL_VERSION}/sha256sum-amd64.txt
    # arm64 binaries — required for DGX Spark
    - path: https://github.com/rancher/rke2/releases/download/${RKE2_URL_VERSION}/rke2.linux-arm64.tar.gz
    - path: https://github.com/rancher/rke2/releases/download/${RKE2_URL_VERSION}/rke2-images.linux.arm64.tar.zst
    - path: https://github.com/rancher/rke2/releases/download/${RKE2_URL_VERSION}/sha256sum-arm64.txt
EOF
}

generate_cert_manager_manifest() {
    cat > "${MANIFEST_DIR}/cert-manager.yaml" <<EOF
# cert-manager ${CERT_MANAGER_VERSION} — consumed by platform/cert-manager
---
apiVersion: content.hauler.cattle.io/v1alpha1
kind: Charts
metadata:
  name: cert-manager-chart
spec:
  charts:
    - name: cert-manager
      repoURL: https://charts.jetstack.io
      version: "${CERT_MANAGER_VERSION}"
---
apiVersion: content.hauler.cattle.io/v1alpha1
kind: Images
metadata:
  name: cert-manager-images
spec:
  images:
    - name: quay.io/jetstack/cert-manager-controller:${CERT_MANAGER_VERSION}
      platforms:
        - linux/amd64
        - linux/arm64
    - name: quay.io/jetstack/cert-manager-webhook:${CERT_MANAGER_VERSION}
      platforms:
        - linux/amd64
        - linux/arm64
    - name: quay.io/jetstack/cert-manager-cainjector:${CERT_MANAGER_VERSION}
      platforms:
        - linux/amd64
        - linux/arm64
    - name: quay.io/jetstack/cert-manager-acmesolver:${CERT_MANAGER_VERSION}
      platforms:
        - linux/amd64
        - linux/arm64
    - name: quay.io/jetstack/cert-manager-startupapicheck:${CERT_MANAGER_VERSION}
      platforms:
        - linux/amd64
        - linux/arm64
EOF
}

generate_rancher_manifest() {
    cat > "${MANIFEST_DIR}/rancher.yaml" <<EOF
# Rancher Manager ${RANCHER_VERSION} — consumed by platform/rancher
# Source: Carbide registry (authenticated)
---
apiVersion: content.hauler.cattle.io/v1alpha1
kind: Charts
metadata:
  name: rancher-chart
spec:
  charts:
    - name: rancher
      repoURL: https://charts.rancher.com/server-charts/prime
      version: "${RANCHER_VERSION}"
---
apiVersion: content.hauler.cattle.io/v1alpha1
kind: Images
metadata:
  name: rancher-images
spec:
  images:
    - name: ${CARBIDE_REGISTRY}/rancher/rancher:${RANCHER_VERSION}
      platforms:
        - linux/amd64
        - linux/arm64
    - name: ${CARBIDE_REGISTRY}/rancher/shell:v0.1.24
      platforms:
        - linux/amd64
        - linux/arm64
EOF
}

generate_harvester_manifest() {
    # Harvester version tag without leading 'v' for some asset filenames
    local HV="${HARVESTER_VERSION}"
    cat > "${MANIFEST_DIR}/harvester.yaml" <<EOF
# Harvester ${HARVESTER_VERSION} — ISO and iPXE assets for bare-metal install
---
apiVersion: content.hauler.cattle.io/v1alpha1
kind: Files
metadata:
  name: harvester-iso
spec:
  files:
    # Full ISO — for USB/IPMI installation
    - path: https://releases.rancher.com/harvester/${HV}/harvester-${HV}-amd64.iso
    # iPXE assets — served via Apache for network boot
    - path: https://releases.rancher.com/harvester/${HV}/harvester-${HV}-vmlinuz-amd64
    - path: https://releases.rancher.com/harvester/${HV}/harvester-${HV}-initrd-amd64
    - path: https://releases.rancher.com/harvester/${HV}/harvester-${HV}-rootfs.squashfs-amd64
    # Checksums
    - path: https://releases.rancher.com/harvester/${HV}/harvester-${HV}-amd64.sha512
EOF
}

generate_harbor_manifest() {
    cat > "${MANIFEST_DIR}/harbor.yaml" <<EOF
# Harbor ${HARBOR_VERSION} — consumed by services/harbor
---
apiVersion: content.hauler.cattle.io/v1alpha1
kind: Charts
metadata:
  name: harbor-chart
spec:
  charts:
    - name: harbor
      repoURL: https://helm.goharbor.io
      version: "${HARBOR_CHART_VERSION}"
---
apiVersion: content.hauler.cattle.io/v1alpha1
kind: Images
metadata:
  name: harbor-images
spec:
  images:
    - name: goharbor/harbor-core:v${HARBOR_VERSION}
      platforms: [linux/amd64]
    - name: goharbor/harbor-db:v${HARBOR_VERSION}
      platforms: [linux/amd64]
    - name: goharbor/harbor-jobservice:v${HARBOR_VERSION}
      platforms: [linux/amd64]
    - name: goharbor/harbor-log:v${HARBOR_VERSION}
      platforms: [linux/amd64]
    - name: goharbor/harbor-portal:v${HARBOR_VERSION}
      platforms: [linux/amd64]
    - name: goharbor/harbor-redis:v${HARBOR_VERSION}
      platforms: [linux/amd64]
    - name: goharbor/harbor-registryctl:v${HARBOR_VERSION}
      platforms: [linux/amd64]
    - name: goharbor/registry-photon:v${HARBOR_VERSION}
      platforms: [linux/amd64]
    - name: goharbor/harbor-exporter:v${HARBOR_VERSION}
      platforms: [linux/amd64]
    - name: goharbor/trivy-adapter-photon:v${HARBOR_VERSION}
      platforms: [linux/amd64]
    - name: goharbor/nginx-photon:v${HARBOR_VERSION}
      platforms: [linux/amd64]
EOF
}

generate_keycloak_manifest() {
    cat > "${MANIFEST_DIR}/keycloak.yaml" <<EOF
# Keycloak ${KEYCLOAK_VERSION} — consumed by services/keycloak
---
apiVersion: content.hauler.cattle.io/v1alpha1
kind: Charts
metadata:
  name: keycloak-chart
spec:
  charts:
    - name: keycloak
      repoURL: https://charts.bitnami.com/bitnami
      version: "${KEYCLOAK_VERSION}"
---
apiVersion: content.hauler.cattle.io/v1alpha1
kind: Images
metadata:
  name: keycloak-images
spec:
  images:
    - name: quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}
      platforms:
        - linux/amd64
        - linux/arm64
EOF
}

generate_gpu_operator_manifest() {
    cat > "${MANIFEST_DIR}/gpu-operator.yaml" <<EOF
# NVIDIA GPU Operator ${GPU_OPERATOR_VERSION} — consumed by services/gpu-operator
# Both platforms required: amd64 (Harvester nodes) + arm64 (DGX Spark)
---
apiVersion: content.hauler.cattle.io/v1alpha1
kind: Charts
metadata:
  name: gpu-operator-chart
spec:
  charts:
    - name: gpu-operator
      repoURL: https://helm.ngc.nvidia.com/nvidia
      version: "${GPU_OPERATOR_VERSION}"
---
apiVersion: content.hauler.cattle.io/v1alpha1
kind: Images
metadata:
  name: gpu-operator-images
spec:
  images:
    - name: nvcr.io/nvidia/gpu-operator:${GPU_OPERATOR_VERSION}
      platforms:
        - linux/amd64
        - linux/arm64
    # TODO: verify full CUDA/driver sidecar image list against
    #       https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/
    #       and add platform-specific driver images here
EOF
}

# ── phases ────────────────────────────────────────────────────────────────────

cmd_sync() {
    install_hauler
    generate_manifests

    log "authenticating to Carbide registry: ${CARBIDE_REGISTRY}"
    hauler login "${CARBIDE_REGISTRY}" \
        --username "${CARBIDE_USERNAME:?CARBIDE_USERNAME not set — source ~/.config/RGS/creds}" \
        --password "${CARBIDE_PASSWORD:?CARBIDE_PASSWORD not set — source ~/.config/RGS/creds}"

    log "authenticating to Docker Hub (avoid anonymous rate limits)"
    hauler login docker.io \
        --username "${DOCKER_USERNAME:?DOCKER_USERNAME not set — source ~/.config/RGS/creds}" \
        --password "${DOCKER_PASSWORD:?DOCKER_PASSWORD not set — source ~/.config/RGS/creds}"

    log "syncing all manifests into Hauler store: ${STORE_DIR}"
    for manifest in "${MANIFEST_DIR}"/*.yaml; do
        log "syncing: $(basename "${manifest}")"
        hauler store sync \
            --files "${manifest}" \
            --store "${STORE_DIR}"
    done

    log "sync complete — store size: $(du -sh "${STORE_DIR}" | cut -f1)"
}

cmd_save() {
    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"
    local tarball="${TARBALL_DIR}/carbide-enclave-${timestamp}.tar.zst"

    install -d -m 755 "${TARBALL_DIR}"
    log "packaging store → ${tarball}"
    hauler store save \
        --filename "${tarball}" \
        --store "${STORE_DIR}"

    log "saved: $(du -sh "${tarball}" | cut -f1)  →  ${tarball}"
    log "browseable at: http://${BASTION_IP}/hauler/$(basename "${tarball}")"
}

cmd_load() {
    local tarball="${1:?usage: hauler.sh load <path-to-tarball>}"
    log "loading ${tarball} → ${STORE_DIR}"
    hauler store load \
        --filename "${tarball}" \
        --store "${STORE_DIR}"
    log "load complete"
}

cmd_serve() {
    log "starting Hauler registry on :5000 (store: ${STORE_DIR})"
    log "press Ctrl-C to stop"
    hauler store serve registry \
        --port 5000 \
        --store "${STORE_DIR}"
}

cmd_push() {
    local registry="harbor.${DOMAIN}"
    log "pushing store → ${registry}"
    hauler store push \
        --registry "${registry}" \
        --username "${HARBOR_ADMIN_USER:-admin}" \
        --password "${HARBOR_ADMIN_PASSWORD:?HARBOR_ADMIN_PASSWORD not set}" \
        --store "${STORE_DIR}"
    log "push complete"
}

cmd_all() {
    log "running full pre-airgap sequence: sync → save"
    cmd_sync
    echo
    cmd_save
}

# ── usage / main ──────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: bash scripts/hauler.sh <command>

Commands:
  sync            Pull all artifacts from upstream into the Hauler store
  save            Package store into a timestamped tarball (web-accessible)
  load <tarball>  Load a tarball into the store (airgap side)
  serve           Start Hauler registry on :5000
  push            Push store contents to Harbor
  all             sync + save in one shot (pre-airgap convenience)

Manifests are generated from version vars in scripts/env.d/carbide-enclave.sh
and written to ${MANIFEST_DIR} before each sync.
EOF
    exit 1
}

main() {
    case "${1:-}" in
        sync)   cmd_sync ;;
        save)   cmd_save ;;
        load)   cmd_load "${2:-}" ;;
        serve)  cmd_serve ;;
        push)   cmd_push ;;
        all)    cmd_all ;;
        *)      usage ;;
    esac
}

main "$@"
