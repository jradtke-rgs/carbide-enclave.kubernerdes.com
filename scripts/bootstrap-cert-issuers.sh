#!/usr/bin/env bash
# Bootstrap cert-manager ClusterIssuers and wildcard cert — carbide-enclave
#
# Required privilege: mansible (sudo only for reading step-ca root cert and TSIG key)
# Run from nuc-00 after bootstrap-nuc-00.sh and bootstrap-rancher.sh:
#   bash /srv/www/htdocs/carbide-enclave.kubernerdes.com/scripts/bootstrap-cert-issuers.sh
#
# Prerequisites:
#   - RKE2 cluster healthy; kubeconfig at ~/.kube/carbide-enclave-rancher.kubeconfig
#   - cert-manager running in cluster (deployed by bootstrap-rancher.sh)
#   - step-ca running on nuc-00 (bootstrap-step-ca.sh complete)
#   - TSIG key at /etc/named.d/tsig-cert-manager.key (bootstrap-nuc-00.sh creates it)
#   - BIND reloaded with allow-update for cert-manager-dns01 key
#
# What this does:
#   1. Reads the TSIG key from nuc-00 and creates a Kubernetes Secret for it
#   2. Creates ClusterIssuer step-ca-acme  (HTTP01 — individual per-service certs)
#   3. Creates ClusterIssuer step-ca-dns01 (DNS01/RFC2136 — wildcard cert)
#   4. Issues wildcard Certificate *.carbide-enclave.kubernerdes.com
#
# After this script completes, individual service certs (Harbor, Keycloak, etc.)
# are issued automatically by cert-manager when their Certificate objects are created;
# they use step-ca-acme (HTTP01). The wildcard cert lives in cert-manager/wildcard-carbide-enclave-tls
# and must be copied manually to any namespace that needs it.
#
# Idempotent: safe to re-run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/env.d/carbide-enclave.sh"
[[ -f "${HOME}/.config/RGS/creds" ]] && source "${HOME}/.config/RGS/creds"

RKE2_KUBECONFIG="${HOME}/.kube/carbide-enclave-rancher.kubeconfig"
export KUBECONFIG="${RKE2_KUBECONFIG}"

STEP_CA_ROOT="/etc/step-ca/certs/root_ca.crt"
STEP_CA_ACME_DIR="https://ca.${DOMAIN}:8443/acme/acme/directory"
STEP_CA_ADMIN_EMAIL="${STEP_CA_ADMIN_EMAIL:-cloudxabide@gmail.com}"

TSIG_KEY_FILE="/etc/named.d/tsig-cert-manager.key"
TSIG_KEY_NAME="cert-manager-dns01"
TSIG_SECRET_NAME="cert-manager-dns01-tsig"

log() { echo "[enclave] $*"; }
kctl() { kubectl "$@"; }

# ── prerequisites ─────────────────────────────────────────────────────────────

check_prerequisites() {
    local ok=true

    if [[ ! -f "${RKE2_KUBECONFIG}" ]]; then
        log "ERROR: kubeconfig not found: ${RKE2_KUBECONFIG}"
        ok=false
    fi

    if ! kubectl cluster-info &>/dev/null; then
        log "ERROR: cannot reach RKE2 cluster — check kubeconfig and VIP ${RANCHER_VIP}:6443"
        ok=false
    fi

    if ! kctl get deploy cert-manager -n cert-manager &>/dev/null; then
        log "ERROR: cert-manager not found — run bootstrap-rancher.sh first"
        ok=false
    fi

    if ! curl -sf "https://ca.${DOMAIN}:8443/health" &>/dev/null; then
        log "ERROR: step-ca not responding at https://ca.${DOMAIN}:8443"
        log "  Verify: systemctl status step-ca"
        ok=false
    fi

    if ! sudo test -f "${TSIG_KEY_FILE}"; then
        log "ERROR: TSIG key not found: ${TSIG_KEY_FILE}"
        log "  Run bootstrap-nuc-00.sh to generate it, then reload BIND:"
        log "    sudo bash scripts/bootstrap-nuc-00.sh"
        log "    sudo rndc reload"
        ok=false
    fi

    [[ "${ok}" == "true" ]]
}

# ── step 1: TSIG Kubernetes Secret ───────────────────────────────────────────

create_tsig_secret() {
    if kctl get secret "${TSIG_SECRET_NAME}" -n cert-manager &>/dev/null; then
        log "TSIG secret already exists in cert-manager — skipping"
        return
    fi

    log "reading TSIG secret value from ${TSIG_KEY_FILE}"
    # tsig-keygen output: key "name" { algorithm hmac-sha256; secret "BASE64=="; };
    local tsig_secret
    tsig_secret="$(sudo grep -oP '(?<=secret ")[^"]+' "${TSIG_KEY_FILE}")"

    log "creating Kubernetes secret: cert-manager/${TSIG_SECRET_NAME}"
    kctl create secret generic "${TSIG_SECRET_NAME}" \
        --namespace cert-manager \
        --from-literal=tsig-secret-key="${tsig_secret}" \
        --dry-run=client -o yaml | kctl apply -f -
    log "TSIG secret created"
}

# ── step 2: HTTP01 ClusterIssuer ─────────────────────────────────────────────

create_http01_issuer() {
    if kctl get clusterissuer step-ca-acme &>/dev/null; then
        log "ClusterIssuer step-ca-acme already exists — skipping"
        return
    fi

    log "reading step-ca root CA cert"
    local root_ca_b64
    root_ca_b64="$(sudo cat "${STEP_CA_ROOT}" | base64 -w 0)"

    log "creating ClusterIssuer: step-ca-acme (HTTP01)"
    kctl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: step-ca-acme
  labels:
    app.kubernetes.io/part-of: carbide-enclave
    app.kubernetes.io/managed-by: manual
spec:
  acme:
    server: ${STEP_CA_ACME_DIR}
    email: ${STEP_CA_ADMIN_EMAIL}
    caBundle: ${root_ca_b64}
    privateKeySecretRef:
      name: step-ca-acme-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
EOF
    wait_for_issuer "step-ca-acme"
}

# ── step 3: DNS01 ClusterIssuer ───────────────────────────────────────────────

create_dns01_issuer() {
    if kctl get clusterissuer step-ca-dns01 &>/dev/null; then
        log "ClusterIssuer step-ca-dns01 already exists — skipping"
        return
    fi

    log "reading step-ca root CA cert"
    local root_ca_b64
    root_ca_b64="$(sudo cat "${STEP_CA_ROOT}" | base64 -w 0)"

    log "creating ClusterIssuer: step-ca-dns01 (DNS01/RFC2136 → BIND at ${BASTION_IP}:53)"
    kctl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: step-ca-dns01
  labels:
    app.kubernetes.io/part-of: carbide-enclave
    app.kubernetes.io/managed-by: manual
spec:
  acme:
    server: ${STEP_CA_ACME_DIR}
    email: ${STEP_CA_ADMIN_EMAIL}
    caBundle: ${root_ca_b64}
    privateKeySecretRef:
      name: step-ca-dns01-account-key
    solvers:
      - dns01:
          rfc2136:
            nameserver: ${BASTION_IP}:53
            tsigAlgorithm: HMACSHA256
            tsigKeyName: ${TSIG_KEY_NAME}
            tsigSecretSecretRef:
              name: ${TSIG_SECRET_NAME}
              key: tsig-secret-key
EOF
    wait_for_issuer "step-ca-dns01"
}

# ── step 4: wildcard Certificate ──────────────────────────────────────────────

issue_wildcard_cert() {
    if kctl get certificate wildcard-carbide-enclave -n cert-manager &>/dev/null; then
        log "wildcard Certificate already exists — skipping"
        log "  Status: $(kctl get certificate wildcard-carbide-enclave -n cert-manager \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
        return
    fi

    log "creating wildcard Certificate: *.${DOMAIN}"
    kctl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-carbide-enclave
  namespace: cert-manager
  labels:
    app.kubernetes.io/part-of: carbide-enclave
    app.kubernetes.io/managed-by: manual
spec:
  secretName: wildcard-carbide-enclave-tls
  issuerRef:
    name: step-ca-dns01
    kind: ClusterIssuer
  dnsNames:
    - "*.${DOMAIN}"
    - "${DOMAIN}"
  duration: 2160h
  renewBefore: 360h
EOF

    log "waiting for wildcard cert (DNS01 challenge — BIND must accept updates)..."
    local attempt=0
    until kctl get certificate wildcard-carbide-enclave -n cert-manager \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
            2>/dev/null | grep -q "True"; do
        attempt=$((attempt + 1))
        [[ ${attempt} -gt 36 ]] && {
            log "ERROR: wildcard cert not issued after 6 min"
            log "  check: kubectl describe certificate wildcard-carbide-enclave -n cert-manager"
            log "  check: kubectl describe certificaterequest -n cert-manager"
            log "  check: kubectl logs -n cert-manager deploy/cert-manager --tail=60"
            log "  verify TXT update: dig _acme-challenge.${DOMAIN} TXT @${BASTION_IP}"
            log "  verify BIND:       sudo rndc status && sudo journalctl -u named --tail=30"
            exit 1
        }
        log "  waiting... (${attempt}/36)"
        sleep 10
    done
    log "wildcard cert issued → secret: cert-manager/wildcard-carbide-enclave-tls"
}

# ── helpers ───────────────────────────────────────────────────────────────────

wait_for_issuer() {
    local name="${1}"
    local attempt=0
    until kctl get clusterissuer "${name}" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
            2>/dev/null | grep -q "True"; do
        attempt=$((attempt + 1))
        [[ ${attempt} -gt 18 ]] && {
            log "ERROR: ClusterIssuer ${name} not Ready after 3 min"
            log "  check: kubectl describe clusterissuer ${name}"
            log "  check: kubectl logs -n cert-manager deploy/cert-manager --tail=40"
            exit 1
        }
        log "  waiting for ${name}... (${attempt}/18)"
        sleep 10
    done
    log "ClusterIssuer ${name} is Ready"
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
    log "cert-manager issuer bootstrap — ${ENVIRONMENT}"
    log "ACME server: ${STEP_CA_ACME_DIR}"
    log "DNS01 BIND:  ${BASTION_IP}:53 (key: ${TSIG_KEY_NAME})"
    echo

    check_prerequisites
    echo

    create_tsig_secret
    echo

    create_http01_issuer
    echo

    create_dns01_issuer
    echo

    issue_wildcard_cert
    echo

    log "bootstrap complete"
    echo
    log "ClusterIssuers:"
    kctl get clusterissuer
    echo
    log "Wildcard cert:"
    kctl get certificate wildcard-carbide-enclave -n cert-manager
    echo
    log "Use step-ca-acme (HTTP01) for per-service certs — it handles Harbor, Keycloak, etc."
    log "Use step-ca-dns01 (DNS01) or copy the wildcard secret for generic/backup use."
    echo
    log "Copy wildcard secret to another namespace:"
    log "  kubectl get secret wildcard-carbide-enclave-tls -n cert-manager -o yaml \\"
    log "    | sed 's/namespace: cert-manager/namespace: TARGET_NS/' \\"
    log "    | kubectl apply -f -"
}

main "$@"
