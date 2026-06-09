#!/usr/bin/env bash
# Bootstrap RKE2 management cluster — carbide-enclave
#
# Required privilege: mansible (runs on nuc-00; sudo used only for Hauler serve)
# Run from nuc-00:
#   bash /srv/www/htdocs/carbide-enclave.kubernerdes.com/scripts/bootstrap-rke2.sh
#
# Prerequisites:
#   - Hauler store populated at /var/lib/hauler (hauler.sh sync)
#   - Harvester LB applied (from MBP):
#       KUBECONFIG=~/.kube/carbide-enclave-harvester.kubeconfig \
#       kubectl apply -f infra/harvester/lb-rancher.yaml
#   - RKE2_TOKEN set in ~/.config/RGS/creds
#   - VMs running: rancher-01/02/03 at 10.0.0.31/32/33
#   - step-ca running on nuc-00
#
# Idempotent: safe to re-run; checks state before each step.
#
# What this does:
#   1.  Starts Hauler OCI registry (:5000) and file server (:8080)
#   2.  Installs step-ca root CA cert on each VM
#   3.  Downloads RKE2 artifacts from Hauler file server to each VM
#   4.  Writes RKE2 config + registries.yaml on each VM
#   5.  Installs RKE2 on rancher-01 (cluster-init)
#   6.  Waits for rancher-01 to be Ready
#   7.  Installs RKE2 on rancher-02 and rancher-03 (server join via VIP)
#   8.  Waits for all nodes to be Ready
#   9.  Retrieves kubeconfig → ~/.kube/carbide-enclave-rke2.kubeconfig

set -euo pipefail

# hauler lives in mansible's local bin; sudo loses this PATH
HAULER_BIN="${HOME}/.local/bin/hauler"
[[ -x "/usr/local/bin/hauler" ]] && HAULER_BIN="/usr/local/bin/hauler"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/env.d/carbide-enclave.sh"
[[ -f "${HOME}/.config/RGS/creds" ]] && source "${HOME}/.config/RGS/creds"

HAULER_REGISTRY="hauler.${DOMAIN}:5000"
HAULER_FILES="http://hauler.${DOMAIN}:8080"
STORE_DIR="/var/lib/hauler"
STEP_CA_ROOT="/etc/step-ca/certs/root_ca.crt"

RKE2_TOKEN="${RKE2_TOKEN:?RKE2_TOKEN not set — add to ~/.config/RGS/creds}"

declare -A NODES=(
    [rancher-01]="${RANCHER_01_IP}"
    [rancher-02]="${RANCHER_02_IP}"
    [rancher-03]="${RANCHER_03_IP}"
)
NODE_ORDER=(rancher-01 rancher-02 rancher-03)

log() { echo "[enclave] $*"; }

vm_ssh()  { ssh -o StrictHostKeyChecking=no -o BatchMode=yes mansible@"$1" "${@:2}"; }
vm_scp()  { scp -o StrictHostKeyChecking=no "$1" "mansible@$2:$3"; }

# ── step 1: Hauler services ───────────────────────────────────────────────────

start_hauler_services() {
    _wait_for_port() {
        local url="$1" label="$2" attempt=0
        until curl -sf "${url}" &>/dev/null; do
            attempt=$((attempt + 1))
            [[ ${attempt} -gt 15 ]] && { log "ERROR: ${label} not ready after 30s"; exit 1; }
            sleep 2
        done
        log "${label} up"
    }

    if curl -sf "http://localhost:5000/v2/" &>/dev/null; then
        log "Hauler registry already running on :5000"
    else
        log "starting Hauler OCI registry on :5000"
        # No sudo needed — ports >1024 don't require root
        nohup "${HAULER_BIN}" store serve registry \
            --store "${STORE_DIR}" \
            --port 5000 \
            >> /tmp/hauler-registry.log 2>&1 &
        _wait_for_port "http://localhost:5000/v2/" "Hauler registry :5000"
    fi

    if curl -sf "http://localhost:8080/" &>/dev/null; then
        log "Hauler file server already running on :8080"
    else
        log "starting Hauler file server on :8080"
        local files_dir="/tmp/hauler-files"
        mkdir -p "${files_dir}"
        nohup "${HAULER_BIN}" store serve fileserver \
            --store "${STORE_DIR}" \
            --directory "${files_dir}" \
            --port 8080 \
            >> /tmp/hauler-fileserver.log 2>&1 &
        _wait_for_port "http://localhost:8080/" "Hauler file server :8080"
    fi
}

# ── step 2: CA cert ───────────────────────────────────────────────────────────

install_ca_cert() {
    local name="$1" ip="$2"
    log "installing step-ca root cert on ${name} (${ip})"
    vm_scp "${STEP_CA_ROOT}" "${ip}" "/tmp/carbide-enclave-root-ca.crt"
    vm_ssh "${ip}" "
        sudo cp /tmp/carbide-enclave-root-ca.crt /etc/pki/trust/anchors/
        sudo update-ca-certificates
        rm /tmp/carbide-enclave-root-ca.crt
    "
}

# ── step 3: RKE2 artifacts ────────────────────────────────────────────────────

install_rke2_artifacts() {
    local name="$1" ip="$2"
    log "downloading RKE2 artifacts on ${name} (${ip})"

    # Try both URL patterns — Hauler fileserver path format varies
    vm_ssh "${ip}" "
        sudo mkdir -p /var/lib/rancher/rke2/agent/images
        sudo mkdir -p /var/lib/rancher/rke2/tmp
        cd /var/lib/rancher/rke2/tmp

        fetch() {
            local file=\"\$1\" dest=\"\$2\"
            curl -sfL \"${HAULER_FILES}/hauler/\${file}\" -o \"\${dest}\" 2>/dev/null || \
            curl -sfL \"${HAULER_FILES}/\${file}\" -o \"\${dest}\" || \
            { echo \"ERROR: could not download \${file}\"; exit 1; }
        }

        sudo sh -c 'fetch() {
            curl -sfL \"${HAULER_FILES}/hauler/\$1\" -o \"\$2\" 2>/dev/null || \
            curl -sfL \"${HAULER_FILES}/\$1\" -o \"\$2\"
        }
        fetch rke2-install.sh /var/lib/rancher/rke2/tmp/rke2-install.sh
        fetch rke2.linux-amd64.tar.gz /var/lib/rancher/rke2/tmp/rke2.linux-amd64.tar.gz
        fetch sha256sum-amd64.txt /var/lib/rancher/rke2/tmp/sha256sum-amd64.txt
        fetch rke2-images.linux.amd64.tar.zst /var/lib/rancher/rke2/agent/images/rke2-images.linux.amd64.tar.zst'
    "
}

# ── step 4: RKE2 config ───────────────────────────────────────────────────────

write_rke2_config() {
    local name="$1" ip="$2" mode="$3"
    log "writing RKE2 config on ${name} (mode: ${mode})"

    vm_ssh "${ip}" "sudo mkdir -p /etc/rancher/rke2"

    # registries.yaml — Hauler runs HTTP only during bootstrap phase
    # Replace with Harbor TLS config after Harbor is deployed
    vm_ssh "${ip}" "sudo tee /etc/rancher/rke2/registries.yaml > /dev/null" <<EOF
mirrors:
  "*":
    endpoint:
      - "http://${HAULER_REGISTRY}"
configs:
  "${HAULER_REGISTRY}":
    tls:
      insecure_skip_verify: true
EOF

    local server_line=""
    [[ "${mode}" == "init" ]] && server_line="cluster-init: true" \
                              || server_line="server: https://${RANCHER_VIP}:9345"

    vm_ssh "${ip}" "sudo tee /etc/rancher/rke2/config.yaml > /dev/null" <<EOF
${server_line}
token: ${RKE2_TOKEN}
tls-san:
  - ${RANCHER_VIP}
  - rke2.${DOMAIN}
  - rancher.${DOMAIN}
  - rancher-01.${DOMAIN}
  - rancher-02.${DOMAIN}
  - rancher-03.${DOMAIN}
  - ${RANCHER_01_IP}
  - ${RANCHER_02_IP}
  - ${RANCHER_03_IP}
system-default-registry: ${HAULER_REGISTRY}
EOF
}

# ── step 5: install RKE2 ──────────────────────────────────────────────────────

install_rke2() {
    local name="$1" ip="$2"
    log "installing RKE2 on ${name}"

    if vm_ssh "${ip}" "systemctl is-active rke2-server &>/dev/null"; then
        log "RKE2 already running on ${name} — skipping install"
        return
    fi

    vm_ssh "${ip}" "
        sudo INSTALL_RKE2_TYPE=server \
             INSTALL_RKE2_ARTIFACT_PATH=/var/lib/rancher/rke2/tmp \
             sh /var/lib/rancher/rke2/tmp/rke2-install.sh
        sudo systemctl enable rke2-server
        sudo systemctl start rke2-server
    "
    log "RKE2 started on ${name}"
}

# ── step 6: wait for node ready ───────────────────────────────────────────────

wait_for_node() {
    local name="$1" ip="$2"
    log "waiting for ${name} to be Ready..."
    local attempt=0
    until vm_ssh "${ip}" \
        "sudo /var/lib/rancher/rke2/bin/kubectl \
            --kubeconfig /etc/rancher/rke2/rke2.yaml \
            get node ${name} --no-headers 2>/dev/null | grep -q ' Ready'"; do
        attempt=$((attempt + 1))
        [[ ${attempt} -gt 36 ]] && { log "ERROR: timeout waiting for ${name}"; exit 1; }
        log "  ${name} not ready yet (${attempt}/36, ~${attempt} min elapsed)"
        sleep 20
    done
    log "${name} is Ready"
}

# ── step 7: kubeconfig ────────────────────────────────────────────────────────

retrieve_kubeconfig() {
    local out="${HOME}/.kube/carbide-enclave-rke2.kubeconfig"
    mkdir -p "${HOME}/.kube"
    log "retrieving kubeconfig from rancher-01 → ${out}"
    vm_ssh "${RANCHER_01_IP}" "sudo cat /etc/rancher/rke2/rke2.yaml" \
        | sed "s|127.0.0.1|${RANCHER_VIP}|g" \
        | sed "s|default|carbide-enclave-rke2|g" \
        > "${out}"
    chmod 600 "${out}"
    log "kubeconfig saved: ${out}"
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
    log "RKE2 bootstrap — ${ENVIRONMENT}"
    log "nodes:    ${NODE_ORDER[*]}"
    log "VIP:      ${RANCHER_VIP}:6443 / :9345"
    log "registry: ${HAULER_REGISTRY}"
    echo

    start_hauler_services
    echo

    for name in "${NODE_ORDER[@]}"; do
        install_ca_cert "${name}" "${NODES[${name}]}"
    done
    echo

    for name in "${NODE_ORDER[@]}"; do
        install_rke2_artifacts "${name}" "${NODES[${name}]}"
    done
    echo

    write_rke2_config "rancher-01" "${RANCHER_01_IP}" "init"
    write_rke2_config "rancher-02" "${RANCHER_02_IP}" "join"
    write_rke2_config "rancher-03" "${RANCHER_03_IP}" "join"
    echo

    install_rke2 "rancher-01" "${RANCHER_01_IP}"
    wait_for_node "rancher-01" "${RANCHER_01_IP}"
    echo

    install_rke2 "rancher-02" "${RANCHER_02_IP}"
    install_rke2 "rancher-03" "${RANCHER_03_IP}"
    wait_for_node "rancher-02" "${RANCHER_02_IP}"
    wait_for_node "rancher-03" "${RANCHER_03_IP}"
    echo

    retrieve_kubeconfig
    echo

    log "bootstrap complete"
    log "verify: KUBECONFIG=~/.kube/carbide-enclave-rke2.kubeconfig kubectl get nodes"
    log "next:   cert-manager + StepIssuer, then Harbor"
}

main "$@"
