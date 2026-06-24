#!/usr/bin/env bash
# Bootstrap RKE2 management cluster — carbide-enclave
#
# Required privilege: sles (sudo rights required on nuc-00 for CA cert step)
# SSH to VMs:        sles@<ip> with ~/.ssh/id_ecdsa-kubernerdes
# Run from nuc-00:
#   bash /srv/www/htdocs/carbide-enclave.kubernerdes.com/scripts/bootstrap-rke2.sh
#
# Prerequisites:
#   - Hauler store populated at /var/lib/hauler (hauler.sh sync)
#   - Harvester LB applied (from MBP):
#       KUBECONFIG=~/.kube/carbide-enclave-harvester.kubeconfig \
#       kubectl apply -f infra/harvester/lb-rancher.yaml
#   - RKE2_TOKEN set in ~/config/RGS/creds (or ~/.config/RGS/creds)
#   - Harvester kubeconfig at ~/.kube/carbide-enclave-harvester.kubeconfig
#     (VM IPs resolved dynamically from Harvester VMI status)
#   - step-ca running on nuc-00 (required for CA cert install step)
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
# Accept creds with or without leading dot in path (~/config vs ~/.config)
if   [[ -f "${HOME}/.config/RGS/creds" ]]; then source "${HOME}/.config/RGS/creds"
elif [[ -f "${HOME}/config/RGS/creds"  ]]; then source "${HOME}/config/RGS/creds"
fi

SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ecdsa-kubernerdes}"
SSH_USER="${SSH_USER:-sles}"
HARVESTER_KUBECONFIG="${HARVESTER_KUBECONFIG:-${HOME}/.kube/carbide-enclave-harvester.kubeconfig}"
HARVESTER_VM_NS="vms-rancher"

HAULER_REGISTRY="hauler.${DOMAIN}:5000"
HAULER_FILES="http://hauler.${DOMAIN}:8080"
STORE_DIR="/var/lib/hauler"
STEP_CA_ROOT="/etc/step-ca/certs/root_ca.crt"

RKE2_TOKEN="${RKE2_TOKEN:?RKE2_TOKEN not set — add to ~/config/RGS/creds (or ~/.config/RGS/creds)}"

declare -A NODES=(
    [rancher-01]="${RANCHER_01_IP}"
    [rancher-02]="${RANCHER_02_IP}"
    [rancher-03]="${RANCHER_03_IP}"
)
NODE_ORDER=(rancher-01 rancher-02 rancher-03)

# VM MAC addresses — set by OpenTofu (infra/tofu/rke2-cluster/main.tf)
declare -A NODE_MACS=(
    [rancher-01]="52:54:00:01:00:01"
    [rancher-02]="52:54:00:01:00:02"
    [rancher-03]="52:54:00:01:00:03"
)
DHCPD_LEASES="/var/lib/dhcpd/db/dhcpd.leases"

log() { echo "[enclave] $*"; }

vm_ssh()  { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o BatchMode=yes "${SSH_USER}@$1" "${@:2}"; }
vm_scp()  { scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "$1" "${SSH_USER}@$2:$3"; }

# ── step 0: resolve VM IPs ────────────────────────────────────────────────────
# Strategy: try Harvester VMI status first (requires qemu-guest-agent in guest);
# fall back to parsing the dhcpd lease file by MAC address (always works on nuc-00).

_update_ip_vars() {
    RANCHER_01_IP="${NODES[rancher-01]}"
    RANCHER_02_IP="${NODES[rancher-02]}"
    RANCHER_03_IP="${NODES[rancher-03]}"
    log "node IPs: rancher-01=${RANCHER_01_IP}  rancher-02=${RANCHER_02_IP}  rancher-03=${RANCHER_03_IP}"
}

_resolve_from_vmi() {
    local kctl="kubectl --kubeconfig ${HARVESTER_KUBECONFIG} -n ${HARVESTER_VM_NS}"
    local all_resolved=true
    for name in "${NODE_ORDER[@]}"; do
        local ip
        ip=$(${kctl} get vmi "${name}" \
                -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || true)
        if [[ -n "${ip}" ]]; then
            log "  ${name} → ${ip} (VMI)"
            NODES["${name}"]="${ip}"
        else
            all_resolved=false
        fi
    done
    [[ "${all_resolved}" == "true" ]]
}

_resolve_from_dhcpd() {
    if [[ ! -f "${DHCPD_LEASES}" ]]; then
        log "WARNING: dhcpd lease file not found at ${DHCPD_LEASES} — using env file IPs"
        return 1
    fi
    log "resolving node IPs from dhcpd leases..."
    local all_resolved=true
    for name in "${NODE_ORDER[@]}"; do
        local mac="${NODE_MACS[${name}]}"
        # dhcpd.leases is append-only; scan for the last lease matching this MAC
        local ip
        ip=$(awk -v mac="${mac}" '
            /^lease /                                      { cur = $2 }
            tolower($0) ~ "hardware ethernet " tolower(mac) { found = cur }
            END                                            { print found }
        ' "${DHCPD_LEASES}")
        if [[ -n "${ip}" ]]; then
            log "  ${name} → ${ip} (dhcpd, mac ${mac})"
            NODES["${name}"]="${ip}"
        else
            log "  WARNING: no dhcpd lease for ${name} (${mac}) — keeping env file IP ${NODES[${name}]}"
            all_resolved=false
        fi
    done
    [[ "${all_resolved}" == "true" ]]
}

resolve_node_ips() {
    if [[ ! -f "${HARVESTER_KUBECONFIG}" ]]; then
        log "Harvester kubeconfig not found — trying dhcpd leases"
        _resolve_from_dhcpd || true
        _update_ip_vars
        return
    fi

    log "resolving node IPs (VMI → dhcpd fallback)..."
    if _resolve_from_vmi; then
        _update_ip_vars
        return
    fi

    log "VMI interfaces empty (no qemu-guest-agent?) — falling back to dhcpd leases"
    _resolve_from_dhcpd || true
    _update_ip_vars
}

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
    # Root CA cert is public — copy to /tmp so mansible can read it
    local tmp_cert="/tmp/carbide-enclave-root-ca.crt"
    sudo cp "${STEP_CA_ROOT}" "${tmp_cert}"
    sudo chmod 644 "${tmp_cert}"
    vm_scp "${tmp_cert}" "${ip}" "/tmp/carbide-enclave-root-ca.crt"
    vm_ssh "${ip}" "
        sudo cp /tmp/carbide-enclave-root-ca.crt /etc/pki/trust/anchors/
        sudo update-ca-certificates
        rm /tmp/carbide-enclave-root-ca.crt
    "
    sudo rm -f "${tmp_cert}"
}

# ── step 3: RKE2 artifacts ────────────────────────────────────────────────────

_vm_curl() {
    # Usage: _vm_curl <ip> <url> <dest>
    # Downloads <url> to <dest> on the remote VM; logs clearly and fails loudly.
    local ip="$1" url="$2" dest="$3"
    local fname; fname=$(basename "${dest}")
    log "    fetching ${fname}"
    local rc=0
    vm_ssh "${ip}" "sudo curl -fsSL '${url}' -o '${dest}'" || rc=$?
    if [[ ${rc} -ne 0 ]]; then
        log "ERROR: failed to download ${fname} (curl exit ${rc})"
        log "       URL: ${url}"
        log "       Check available files: curl -s ${HAULER_FILES}/"
        exit 1
    fi
}

install_rke2_artifacts() {
    local name="$1" ip="$2"
    log "downloading RKE2 artifacts on ${name} (${ip})"
    local base="${HAULER_FILES}"

    vm_ssh "${ip}" "sudo mkdir -p /var/lib/rancher/rke2/agent/images /var/lib/rancher/rke2/tmp"

    log "  install script + binary tarball → /var/lib/rancher/rke2/tmp/"
    _vm_curl "${ip}" "${base}/rke2-install.sh"         "/var/lib/rancher/rke2/tmp/rke2-install.sh"
    _vm_curl "${ip}" "${base}/rke2.linux-amd64.tar.gz" "/var/lib/rancher/rke2/tmp/rke2.linux-amd64.tar.gz"
    _vm_curl "${ip}" "${base}/sha256sum-amd64.txt"     "/var/lib/rancher/rke2/tmp/sha256sum-amd64.txt"

    log "  image bundles → /var/lib/rancher/rke2/agent/images/"
    vm_ssh "${ip}" "sudo rm -f /var/lib/rancher/rke2/agent/images/*.tar.zst"
    _vm_curl "${ip}" "${base}/rke2-images-core.linux-amd64.tar.zst" \
        "/var/lib/rancher/rke2/agent/images/rke2-images-core.linux-amd64.tar.zst"
    _vm_curl "${ip}" "${base}/rke2-images-canal.linux-amd64.tar.zst" \
        "/var/lib/rancher/rke2/agent/images/rke2-images-canal.linux-amd64.tar.zst"

    log "  verifying image bundle..."
    vm_ssh "${ip}" "
        sudo bash -c '
            shopt -s nullglob
            bundles=(/var/lib/rancher/rke2/agent/images/rke2-images*.tar.zst)
            if [[ \${#bundles[@]} -eq 0 ]]; then
                echo \"[enclave] ERROR: no rke2-images*.tar.zst found in agent/images/\"
                exit 1
            fi
            for f in \"\${bundles[@]}\"; do
                result=\$(file \"\$f\" 2>/dev/null)
                if echo \"\$result\" | grep -qi \"html|ascii|text\"; then
                    echo \"[enclave] ERROR: \$f is not a valid zstd archive\"
                    echo \"          file: \$result\"
                    exit 1
                fi
                sz=\$(du -sh \"\$f\" | cut -f1)
                echo \"[enclave]   ok: \$(basename \$f) (\$sz)\"
            done
        '
    "
    log "RKE2 artifacts ready on ${name}"
}

# ── step 4: RKE2 config ───────────────────────────────────────────────────────

write_rke2_config() {
    local name="$1" ip="$2" mode="$3"
    log "writing RKE2 config on ${name} (mode: ${mode})"

    vm_ssh "${ip}" "sudo mkdir -p /etc/rancher/rke2"

    # registries.yaml — Hauler runs HTTP only during bootstrap phase.
    # Mirror the registry to itself with http:// so containerd uses plain HTTP
    # (insecure_skip_verify alone doesn't fix scheme mismatch).
    # Replace with Harbor TLS config after Harbor is deployed.
    # Plain http:// endpoint in mirrors is sufficient for HTTP registry.
    # Do NOT add a configs.tls section — containerd interprets it as HTTPS.
    vm_ssh "${ip}" "sudo tee /etc/rancher/rke2/registries.yaml > /dev/null" <<EOF
mirrors:
  "${HAULER_REGISTRY}":
    endpoint:
      - "http://${HAULER_REGISTRY}"
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

uninstall_rke2() {
    local name="$1" ip="$2"
    # Skip uninstall if RKE2 is already running — idempotent re-runs leave a
    # healthy cluster alone. Only clean up when the node is not yet active.
    if vm_ssh "${ip}" "systemctl is-active rke2-server &>/dev/null" 2>/dev/null; then
        log "RKE2 active on ${name} — skipping uninstall"
        return
    fi
    log "uninstalling RKE2 on ${name} (if present)"
    vm_ssh "${ip}" "
        if [[ -x /opt/rke2/bin/rke2-uninstall.sh ]]; then
            sudo /opt/rke2/bin/rke2-uninstall.sh
        elif [[ -x /usr/local/bin/rke2-uninstall.sh ]]; then
            sudo /usr/local/bin/rke2-uninstall.sh
        else
            sudo systemctl stop rke2-server 2>/dev/null || true
            sudo systemctl disable rke2-server 2>/dev/null || true
        fi
        sudo rm -rf /var/lib/rancher/rke2 /etc/rancher/rke2
    " 2>/dev/null || true
    log "uninstall complete on ${name}"
}

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
        sudo systemctl start rke2-server || true
    "
    log "RKE2 start initiated on ${name} — wait_for_node will poll readiness"
}

# ── step 6: wait for node ready ───────────────────────────────────────────────

wait_for_node() {
    local name="$1" ip="$2"
    log "waiting for ${name} to be Ready..."
    local attempt=0
    # kubectl lives under /var/lib/rancher/rke2/data/<version>/bin/kubectl
    # (not in /opt/rke2/bin); find it dynamically to avoid version-pinning here
    until vm_ssh "${ip}" "
        KUBECTL=\$(find /var/lib/rancher/rke2/data -name kubectl 2>/dev/null | head -1)
        [[ -n \"\${KUBECTL}\" ]] || exit 1
        sudo \"\${KUBECTL}\" --kubeconfig /etc/rancher/rke2/rke2.yaml \
            get node ${name} --no-headers 2>/dev/null | grep -q ' Ready'
    "; do
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
    log "VIP:      ${RANCHER_VIP}:6443 / :9345"
    log "registry: ${HAULER_REGISTRY}"
    echo

    resolve_node_ips
    log "nodes:    ${NODE_ORDER[*]} (${RANCHER_01_IP} ${RANCHER_02_IP} ${RANCHER_03_IP})"
    echo

    start_hauler_services
    echo

    for name in "${NODE_ORDER[@]}"; do
        install_ca_cert "${name}" "${NODES[${name}]}"
    done
    echo

    for name in "${NODE_ORDER[@]}"; do
        uninstall_rke2 "${name}" "${NODES[${name}]}"
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
    log "rke2 bin path on VMs: /opt/rke2/bin/ (SL-Micro immutable /usr/local)"
    log "next:   cert-manager + StepIssuer, then Harbor"
}

main "$@"
