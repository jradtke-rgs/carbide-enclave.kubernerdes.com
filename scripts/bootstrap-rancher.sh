#!/usr/bin/env bash
# Bootstrap cert-manager + Rancher Manager — carbide-enclave
#
# Required privilege: mansible (sudo only for reading step-ca root cert)
# Helm: >= 3.11 required (--plain-http for OCI registry)
# Run from nuc-00:
#   bash /srv/www/htdocs/carbide-enclave.kubernerdes.com/scripts/bootstrap-rancher.sh
#
# Prerequisites:
#   - RKE2 cluster healthy; kubeconfig at ~/.kube/carbide-enclave-rancher.kubeconfig
#   - Hauler store populated at /var/lib/hauler (hauler.sh sync)
#   - step-ca running on nuc-00 (bootstrap-step-ca.sh complete)
#   - DNS A record: rancher.carbide-enclave.kubernerdes.com → 10.0.0.30 (RANCHER_VIP)
#   - DNS A record: ca.carbide-enclave.kubernerdes.com → 10.0.0.10 (nuc-00)
#   - RANCHER_BOOTSTRAP_PASSWORD set in ~/.config/RGS/creds
#
# Idempotent: safe to re-run. Helm releases already deployed are skipped.
#
# What this does:
#   1.  Starts Hauler OCI registry (:5000)
#   2.  Installs cert-manager from Hauler OCI registry
#   3.  Creates an ACME ClusterIssuer pointing to step-ca
#        (cert-manager uses HTTP01 challenge via the RKE2 nginx ingress;
#         step-ca validates from nuc-00 — both are on the same LAN)
#   4.  Issues a TLS Certificate for rancher.<domain> via cert-manager
#   5.  Stores the step-ca root CA cert in cattle-system/tls-ca (for agent trust)
#   6.  Installs Rancher Manager from Hauler OCI registry
#   7.  Waits for Rancher to be healthy
#   8.  Prints access URL and bootstrap password
#
# After Harbor is deployed:
#   Switch systemDefaultRegistry from Hauler to Harbor:
#     helm upgrade rancher oci://localhost:5000/rancher \
#       --version ${RANCHER_VERSION} --reuse-values --plain-http \
#       --set systemDefaultRegistry=harbor.carbide-enclave.kubernerdes.com

set -euo pipefail

HAULER_BIN="${HOME}/.local/bin/hauler"
[[ -x "/usr/local/bin/hauler" ]] && HAULER_BIN="/usr/local/bin/hauler"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/env.d/carbide-enclave.sh"
if   [[ -f "${HOME}/.config/RGS/creds" ]]; then source "${HOME}/.config/RGS/creds"
elif [[ -f "${HOME}/config/RGS/creds"  ]]; then source "${HOME}/config/RGS/creds"
fi

RKE2_KUBECONFIG="${HOME}/.kube/carbide-enclave-rancher.kubeconfig"
export KUBECONFIG="${RKE2_KUBECONFIG}"

STORE_DIR="/var/lib/hauler"
# Use localhost to avoid hostname TLS negotiation against the plain-HTTP Hauler registry
HAULER_REGISTRY="localhost:5000"

STEP_CA_ROOT="/etc/step-ca/certs/root_ca.crt"
STEP_CA_URL="https://ca.${DOMAIN}:8443"
STEP_CA_ACME_DIR="${STEP_CA_URL}/acme/acme/directory"
STEP_CA_ADMIN_EMAIL="${STEP_CA_ADMIN_EMAIL:-cloudxabide@gmail.com}"

RANCHER_BOOTSTRAP_PASSWORD="${RANCHER_BOOTSTRAP_PASSWORD:?RANCHER_BOOTSTRAP_PASSWORD not set — add to ~/.config/RGS/creds}"

log() { echo "[enclave] $*"; }

kctl() { kubectl "$@"; }

# ── prerequisites ─────────────────────────────────────────────────────────────

check_prerequisites() {
    local ok=true

    if [[ ! -f "${RKE2_KUBECONFIG}" ]]; then
        log "ERROR: kubeconfig not found: ${RKE2_KUBECONFIG}"
        ok=false
    fi

    if ! command -v helm &>/dev/null; then
        log "ERROR: helm not found — install helm >= 3.11 on nuc-00 first:"
        log "  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
        ok=false
    else
        local helm_ver
        helm_ver="$(helm version --short 2>/dev/null | grep -oP '(?<=v)\d+\.\d+' | head -1)"
        local helm_minor="${helm_ver##*.}"
        local helm_major="${helm_ver%%.*}"
        if [[ "${helm_major}" -lt 3 || ( "${helm_major}" -eq 3 && "${helm_minor}" -lt 11 ) ]]; then
            log "ERROR: helm ${helm_ver} too old — need >= 3.11 (--plain-http support)"
            ok=false
        fi
    fi

    if ! curl -sf "${STEP_CA_URL}/health" &>/dev/null; then
        log "ERROR: step-ca not responding at ${STEP_CA_URL}"
        log "  Verify: systemctl status step-ca && curl -sk ${STEP_CA_URL}/health"
        ok=false
    fi

    if ! kubectl cluster-info &>/dev/null; then
        log "ERROR: cannot reach RKE2 cluster — check kubeconfig and VIP ${RANCHER_VIP}:6443"
        ok=false
    fi

    [[ "${ok}" == "true" ]]
}

# ── step 1: Hauler registry ───────────────────────────────────────────────────

start_hauler_registry() {
    if curl -sf "http://localhost:5000/v2/" &>/dev/null; then
        log "Hauler registry already running on :5000"
        return
    fi
    log "starting Hauler OCI registry on :5000"
    nohup "${HAULER_BIN}" store serve registry \
        --store "${STORE_DIR}" \
        --port 5000 \
        >> /tmp/hauler-registry.log 2>&1 &
    local attempt=0
    until curl -sf "http://localhost:5000/v2/" &>/dev/null; do
        attempt=$((attempt + 1))
        [[ ${attempt} -gt 15 ]] && { log "ERROR: Hauler registry not ready after 30s"; exit 1; }
        sleep 2
    done
    log "Hauler registry up"
}

# ── step 2: cert-manager ──────────────────────────────────────────────────────

install_cert_manager() {
    # Check by deployment presence, not helm release — cert-manager may have
    # been installed via manifests (e.g. as part of an earlier cluster setup).
    if kctl get deploy cert-manager -n cert-manager &>/dev/null 2>&1; then
        local ver
        ver="$(kctl get deploy cert-manager -n cert-manager \
                -o jsonpath='{.spec.template.spec.containers[0].image}' \
                2>/dev/null | grep -oP '(?<=:v?)[0-9]+\.[0-9]+\.[0-9]+' || echo unknown)"
        log "cert-manager already running in cluster (version: ${ver}) — skipping install"
        log "  deploy: $(kctl get deploy -n cert-manager --no-headers | awk '{print $1}' | tr '\n' ' ')"
        return
    fi
    log "installing cert-manager ${CERT_MANAGER_VERSION}"
    kctl create namespace cert-manager --dry-run=client -o yaml | kctl apply -f -

    helm upgrade --install cert-manager \
        "oci://${HAULER_REGISTRY}/cert-manager" \
        --version "${CERT_MANAGER_VERSION}" \
        --plain-http \
        --namespace cert-manager \
        --set installCRDs=true \
        --set global.leaderElection.namespace=cert-manager \
        --wait \
        --timeout 10m

    log "cert-manager installed — pods:"
    kctl get pods -n cert-manager
}

# ── step 3: step-ca ACME ClusterIssuer ───────────────────────────────────────
#
# cert-manager uses the step-ca ACME endpoint to issue certs.
# HTTP01 challenges are served by the RKE2 nginx ingress; step-ca
# (on nuc-00, same LAN as RANCHER_VIP) validates them over port 80.
# The caBundle field tells cert-manager to trust the step-ca root cert
# when connecting to the ACME server over HTTPS.

create_step_ca_issuer() {
    if kctl get clusterissuer step-ca-acme &>/dev/null 2>&1; then
        log "step-ca ACME ClusterIssuer already exists — skipping"
        return
    fi

    log "reading step-ca root CA cert (requires sudo)"
    local root_ca_b64
    root_ca_b64="$(sudo cat "${STEP_CA_ROOT}" | base64 -w 0)"

    log "creating ClusterIssuer: step-ca-acme"
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

    log "waiting for ClusterIssuer to be Ready..."
    local attempt=0
    until kctl get clusterissuer step-ca-acme \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
            2>/dev/null | grep -q "True"; do
        attempt=$((attempt + 1))
        [[ ${attempt} -gt 18 ]] && {
            log "ERROR: ClusterIssuer not Ready after 3 min"
            log "  check: kubectl describe clusterissuer step-ca-acme"
            log "  check: kubectl logs -n cert-manager deploy/cert-manager --tail=40"
            exit 1
        }
        log "  waiting... (${attempt}/18)"
        sleep 10
    done
    log "ClusterIssuer step-ca-acme is Ready"
}

# ── step 4: Rancher TLS cert ──────────────────────────────────────────────────

issue_rancher_cert() {
    log "creating cattle-system namespace"
    kctl create namespace cattle-system --dry-run=client -o yaml | kctl apply -f -

    # The step-ca root cert must be in cattle-system/tls-ca so Rancher
    # agents trust the internal CA when they pull from harbor / connect to Rancher.
    if kctl get secret tls-ca -n cattle-system &>/dev/null 2>&1; then
        log "tls-ca secret already exists in cattle-system — skipping"
    else
        log "creating tls-ca secret in cattle-system (step-ca root CA)"
        kctl create secret generic tls-ca \
            --namespace cattle-system \
            --from-file=cacerts.pem=<(sudo cat "${STEP_CA_ROOT}") \
            --dry-run=client -o yaml | kctl apply -f -
    fi

    if kctl get certificate rancher-tls -n cattle-system &>/dev/null 2>&1; then
        log "rancher-tls Certificate already exists — skipping"
        return
    fi

    log "creating Certificate for rancher.${DOMAIN}"
    kctl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: rancher-tls
  namespace: cattle-system
  labels:
    app.kubernetes.io/part-of: carbide-enclave
    app.kubernetes.io/managed-by: manual
spec:
  secretName: tls-rancher-ingress
  issuerRef:
    name: step-ca-acme
    kind: ClusterIssuer
  dnsNames:
    - rancher.${DOMAIN}
  ipAddresses:
    - ${RANCHER_VIP}
  duration: 2160h     # 90 days (step-ca default ACME cert lifetime)
  renewBefore: 360h   # renew 15 days before expiry
EOF

    log "waiting for Certificate to be issued (HTTP01 challenge via nginx ingress)..."
    local attempt=0
    until kctl get certificate rancher-tls -n cattle-system \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
            2>/dev/null | grep -q "True"; do
        attempt=$((attempt + 1))
        [[ ${attempt} -gt 36 ]] && {
            log "ERROR: Certificate not issued after 6 min"
            log "  check: kubectl describe certificate rancher-tls -n cattle-system"
            log "  check: kubectl describe certificaterequest -n cattle-system"
            log "  check: kubectl logs -n cert-manager deploy/cert-manager --tail=60"
            log "  verify: curl http://rancher.${DOMAIN}/.well-known/acme-challenge/test"
            exit 1
        }
        log "  waiting for cert... (${attempt}/36)"
        sleep 10
    done
    log "TLS certificate issued → secret: cattle-system/tls-rancher-ingress"
}

# ── step 5: Rancher Manager ───────────────────────────────────────────────────

install_rancher() {
    if helm status rancher -n cattle-system &>/dev/null 2>&1; then
        log "Rancher already installed — skipping"
        return
    fi
    log "installing Rancher Manager ${RANCHER_VERSION}"

    helm upgrade --install rancher \
        "oci://${HAULER_REGISTRY}/rancher" \
        --version "${RANCHER_VERSION}" \
        --plain-http \
        --namespace cattle-system \
        --set hostname="rancher.${DOMAIN}" \
        --set replicas=3 \
        --set bootstrapPassword="${RANCHER_BOOTSTRAP_PASSWORD}" \
        --set systemDefaultRegistry="${HAULER_REGISTRY}" \
        --set useBundledSystemChart=true \
        --set ingress.tls.source=secret \
        --set privateCA=true \
        --wait \
        --timeout 15m

    log "Rancher Manager installed"
}

# ── step 6: wait for Rancher ──────────────────────────────────────────────────

wait_for_rancher() {
    log "waiting for Rancher rollout to complete..."
    kctl rollout status deploy/rancher -n cattle-system --timeout=10m
    log "Rancher pods:"
    kctl get pods -n cattle-system -l app=rancher
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
    log "Rancher Manager bootstrap — ${ENVIRONMENT}"
    log "kubeconfig: ${RKE2_KUBECONFIG}"
    log "registry:   ${HAULER_REGISTRY}"
    log "hostname:   rancher.${DOMAIN}"
    log "CA:         ${STEP_CA_URL}"
    echo

    check_prerequisites
    echo

    start_hauler_registry
    echo

    install_cert_manager
    echo

    create_step_ca_issuer
    echo

    issue_rancher_cert
    echo

    install_rancher
    echo

    wait_for_rancher
    echo

    log "bootstrap complete"
    echo
    log "Rancher URL:        https://rancher.${DOMAIN}"
    log "Bootstrap password: ${RANCHER_BOOTSTRAP_PASSWORD}"
    echo
    log "After Harbor is deployed, switch the system-default-registry:"
    log "  helm upgrade rancher oci://${HAULER_REGISTRY}/rancher \\"
    log "      --version ${RANCHER_VERSION} --plain-http --reuse-values \\"
    log "      --namespace cattle-system \\"
    log "      --set systemDefaultRegistry=harbor.${DOMAIN}"
    echo
    log "Verify:"
    log "  KUBECONFIG=${RKE2_KUBECONFIG} kubectl get pods -n cattle-system"
    log "  curl -sk https://rancher.${DOMAIN}/ping"
}

main "$@"
