#!/usr/bin/env bash
# Bootstrap Harvester cluster — carbide-enclave
#
# Required privilege: mansible (reads ~/.kube/; no root needed)
# Run from nuc-00 or MBP after Harvester 3-node cluster is formed:
#   KUBECONFIG=~/.kube/carbide-enclave-harvester.kubeconfig \
#   bash scripts/bootstrap-harvester.sh
#
# What this does:
#   1. Creates VM namespaces (vms-rancher, vms-observability, vms-apps)
#   2. Injects step-ca root CA into Harvester additional-ca setting
#   3. Applies LoadBalancer IPPools and LoadBalancer objects for all three VIPs
#
# Idempotent: safe to re-run; namespaces and IPPools use apply, not create.
#
# Prerequisites:
#   - Harvester kubeconfig at ~/.kube/carbide-enclave-harvester.kubeconfig
#   - step-ca root CA served at http://10.0.0.10/step/carbide-enclave-root-ca.crt
#   - kubectl in PATH

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/env.d/carbide-enclave.sh"

KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/carbide-enclave-harvester.kubeconfig}"
export KUBECONFIG

CA_URL="http://${BASTION_IP}/step/carbide-enclave-root-ca.crt"

log() { echo "[enclave] $*"; }

# ── step 1: VM namespaces ─────────────────────────────────────────────────────

create_namespaces() {
    log "creating VM namespaces"
    for ns in vms-rancher vms-observability vms-apps; do
        if kubectl get namespace "${ns}" &>/dev/null; then
            log "  namespace ${ns} already exists"
        else
            kubectl create namespace "${ns}"
            kubectl label namespace "${ns}" \
                app.kubernetes.io/part-of=carbide-enclave \
                app.kubernetes.io/managed-by=manual
            log "  created namespace ${ns}"
        fi
    done
}

# ── step 2: Harvester additional-ca ──────────────────────────────────────────

inject_ca() {
    log "fetching step-ca root cert from ${CA_URL}"
    local ca_pem
    ca_pem=$(curl -fsSL "${CA_URL}")

    if [[ -z "${ca_pem}" ]]; then
        log "ERROR: empty CA cert from ${CA_URL}"
        exit 1
    fi

    log "patching Harvester additional-ca setting"
    # python3 json.dumps escapes PEM newlines correctly for the JSON patch payload
    local ca_json
    ca_json=$(printf '%s' "${ca_pem}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

    kubectl patch settings.harvesterhci.io additional-ca \
        --type merge \
        -p "{\"value\": ${ca_json}}"

    log "additional-ca updated — Harvester nodes will trust ${DOMAIN} CA"
}

# ── step 3: LoadBalancers ─────────────────────────────────────────────────────

apply_loadbalancers() {
    log "applying Harvester LoadBalancer manifests"

    local manifests=(
        "${REPO_ROOT}/infra/harvester/lb-rancher.yaml"
        "${REPO_ROOT}/infra/harvester/lb-observability.yaml"
        "${REPO_ROOT}/infra/harvester/lb-apps.yaml"
    )

    for f in "${manifests[@]}"; do
        log "  applying $(basename "${f}")"
        kubectl apply -f "${f}"
    done

    log "LoadBalancers applied:"
    log "  10.0.0.30  lb-rancher        (RKE2 API + Rancher Manager)"
    log "  10.0.0.40  lb-observability  (Grafana / Prometheus)"
    log "  10.0.0.50  lb-apps           (general workloads)"
}

# ── step 4: verify ───────────────────────────────────────────────────────────

verify() {
    log "verifying LoadBalancer allocation"
    echo
    kubectl get loadbalancer -A 2>/dev/null \
        || kubectl get loadbalancers.loadbalancer.harvesterhci.io -A
    echo
    kubectl get ippools.loadbalancer.harvesterhci.io
    echo
    log "verify CA setting:"
    kubectl get settings.harvesterhci.io additional-ca -o jsonpath='{.value}' \
        | openssl x509 -noout -subject -issuer -dates 2>/dev/null \
        || log "  (CA not yet propagated — normal if just patched)"
}

# ── main ─────────────────────────────────────────────────────────────────────

main() {
    log "Harvester post-install bootstrap — ${ENVIRONMENT}"
    log "KUBECONFIG: ${KUBECONFIG}"
    echo

    if ! kubectl cluster-info &>/dev/null; then
        log "ERROR: cannot reach Harvester API — check KUBECONFIG"
        exit 1
    fi

    create_namespaces
    echo

    inject_ca
    echo

    apply_loadbalancers
    echo

    verify
    echo

    log "bootstrap complete"
    log "next: provision VMs via tofu, then bootstrap-rke2.sh"
}

main "$@"
