#!/usr/bin/env bash
# Smoke-test all carbide-enclave components — run from nuc-00 as mansible
#
# Required privilege: mansible (kubectl reads ~/.kube/; systemctl status is public)
# Run: bash scripts/verify-enclave.sh [--skip-dgx]
#
# Checks each layer in bootstrap order; reports PASS / FAIL / SKIP per check
# and exits non-zero if any check fails. Does NOT stop on first failure.
#
# Flags / env overrides:
#   --skip-dgx    skip DGX Spark checks (if not yet joined to the cluster)
#   SKIP_DGX=1   same as above

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/env.d/carbide-enclave.sh"

SKIP_DGX="${SKIP_DGX:-0}"
[[ "${1:-}" == "--skip-dgx" ]] && SKIP_DGX=1

PASS=0
FAIL=0
SKIP=0

if [[ -t 1 ]]; then
    GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'
    BOLD='\033[1m'; RESET='\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; BOLD=''; RESET=''
fi

pass()    { echo -e "  ${GREEN}PASS${RESET}  $*"; PASS=$((PASS + 1)); }
fail()    { echo -e "  ${RED}FAIL${RESET}  $*"; FAIL=$((FAIL + 1)); }
skip()    { echo -e "  ${YELLOW}SKIP${RESET}  $*"; SKIP=$((SKIP + 1)); }
section() { echo; echo -e "${BOLD}── $* ──${RESET}"; }

CA_CERT="/etc/step-ca/certs/root_ca.crt"
HARVESTER_KC="${HOME}/.kube/carbide-enclave-harvester.kubeconfig"
RKE2_KC="${HOME}/.kube/carbide-enclave-rke2.kubeconfig"

# curl with the internal CA cert if available, -k if not yet bootstrapped
curl_ca() {
    if [[ -f "${CA_CERT}" ]]; then
        curl -fsSL --cacert "${CA_CERT}" --max-time 10 "$@"
    else
        curl -fsSL -k --max-time 10 "$@"
    fi
}

hkubectl() { kubectl --kubeconfig "${HARVESTER_KC}" "$@"; }
rkubectl() { kubectl --kubeconfig "${RKE2_KC}"     "$@"; }

# ── 1. nuc-00 local services ─────────────────────────────────────────────────

check_nuc00_services() {
    section "nuc-00 local services"
    for svc in chronyd named dhcpd apache2 tftp.socket step-ca; do
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            pass "${svc}"
        else
            fail "${svc} not active  (systemctl start ${svc})"
        fi
    done

    if curl -fsSL --max-time 5 "http://localhost/" &>/dev/null; then
        pass "apache2 serving http://localhost/"
    else
        fail "apache2 not serving http://localhost/"
    fi
}

# ── 2. step-ca ───────────────────────────────────────────────────────────────

check_step_ca() {
    section "step-ca"

    if [[ -f "${CA_CERT}" ]]; then
        local expiry
        expiry=$(openssl x509 -noout -enddate -in "${CA_CERT}" 2>/dev/null | cut -d= -f2)
        pass "root CA cert present  (expires: ${expiry})"
    else
        fail "root CA cert not found at ${CA_CERT}"
    fi

    local acme_url="https://ca.${DOMAIN}:8443/acme/acme/directory"
    if curl_ca --output /dev/null "${acme_url}" 2>/dev/null; then
        pass "ACME directory reachable  (${acme_url})"
    else
        fail "ACME directory unreachable  (${acme_url})"
    fi
}

# ── 3. DNS resolution ─────────────────────────────────────────────────────────

check_dns() {
    section "DNS resolution"

    # Ordered list of "fqdn expected_ip" pairs
    local checks=(
        "ca.${DOMAIN}:${BASTION_IP}"
        "hauler.${DOMAIN}:${BASTION_IP}"
        "rancher-01.${DOMAIN}:${RANCHER_01_IP}"
        "rancher-02.${DOMAIN}:${RANCHER_02_IP}"
        "rancher-03.${DOMAIN}:${RANCHER_03_IP}"
        "rke2.${DOMAIN}:${RANCHER_VIP}"
        "rancher.${DOMAIN}:${RANCHER_VIP}"
        "harbor.${DOMAIN}:${HARBOR_VIP}"
        "keycloak.${DOMAIN}:${KEYCLOAK_VIP}"
    )

    for entry in "${checks[@]}"; do
        local fqdn="${entry%%:*}"
        local want="${entry##*:}"
        local got
        got=$(dig +short A "${fqdn}" 2>/dev/null | tail -1)
        if [[ "${got}" == "${want}" ]]; then
            pass "${fqdn} → ${got}"
        else
            fail "${fqdn} → '${got:-<no answer>}'  (expected ${want})"
        fi
    done
}

# ── 4. Hauler services ────────────────────────────────────────────────────────

check_hauler() {
    section "Hauler services"

    if curl -fsSL --max-time 5 "http://localhost:5000/v2/" &>/dev/null; then
        pass "OCI registry  :5000"
    else
        skip "OCI registry :5000 not running  (hauler store serve registry --store /var/lib/hauler)"
    fi

    if curl -fsSL --max-time 5 "http://localhost:8080/" &>/dev/null; then
        pass "file server  :8080"
    else
        skip "file server :8080 not running  (hauler store serve fileserver --store /var/lib/hauler)"
    fi
}

# ── 5. Harvester cluster ──────────────────────────────────────────────────────

check_harvester() {
    section "Harvester cluster"

    if [[ ! -f "${HARVESTER_KC}" ]]; then
        skip "no kubeconfig at ${HARVESTER_KC}"
        return
    fi

    if ! hkubectl cluster-info &>/dev/null; then
        fail "cannot reach Harvester API  (check KUBECONFIG or VPN)"
        return
    fi
    pass "Harvester API reachable"

    local not_ready
    not_ready=$(hkubectl get nodes --no-headers 2>/dev/null \
        | awk '$2 != "Ready" {print}' || true)
    if [[ -z "${not_ready}" ]]; then
        local count
        count=$(hkubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
        pass "all ${count} Harvester node(s) Ready"
    else
        fail "Harvester node(s) not Ready:"
        echo "${not_ready}" | sed 's/^/        /'
    fi

    # step-ca CA injected into Harvester trust
    local ca_subject
    ca_subject=$(hkubectl get settings.harvesterhci.io additional-ca \
        -o jsonpath='{.value}' 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null || true)
    if [[ -n "${ca_subject}" ]]; then
        pass "step-ca in Harvester additional-ca  (${ca_subject})"
    else
        fail "step-ca NOT in Harvester additional-ca  (run bootstrap-harvester.sh)"
    fi

    # LoadBalancers allocated
    local lb_count
    lb_count=$(hkubectl get loadbalancers.loadbalancer.harvesterhci.io -A \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${lb_count}" -ge 3 ]]; then
        pass "${lb_count} Harvester LoadBalancer(s) configured"
    else
        fail "expected ≥3 Harvester LoadBalancers, found ${lb_count}  (run bootstrap-harvester.sh)"
    fi
}

# ── 6. RKE2 management cluster ────────────────────────────────────────────────

check_rke2() {
    section "RKE2 management cluster"

    if [[ ! -f "${RKE2_KC}" ]]; then
        skip "no kubeconfig at ${RKE2_KC}"
        return
    fi

    if ! rkubectl cluster-info &>/dev/null; then
        fail "cannot reach RKE2 API  (${RANCHER_VIP}:6443)"
        return
    fi
    pass "RKE2 API reachable  (${RANCHER_VIP}:6443)"

    local not_ready
    not_ready=$(rkubectl get nodes --no-headers 2>/dev/null \
        | awk '$2 != "Ready" {print}' || true)
    if [[ -z "${not_ready}" ]]; then
        local count
        count=$(rkubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
        pass "all ${count} RKE2 node(s) Ready"
    else
        fail "RKE2 node(s) not Ready:"
        echo "${not_ready}" | sed 's/^/        /'
    fi

    # System pods — flag anything not Running or Completed
    local bad_pods
    bad_pods=$(rkubectl get pods -A --no-headers 2>/dev/null \
        | grep -vE '\s(Running|Completed)\s' | grep -v '^$' || true)
    if [[ -z "${bad_pods}" ]]; then
        pass "all system pods Running/Completed"
    else
        local count
        count=$(echo "${bad_pods}" | wc -l | tr -d ' ')
        fail "${count} pod(s) not Running/Completed:"
        echo "${bad_pods}" | sed 's/^/        /'
    fi
}

# ── 7. cert-manager ───────────────────────────────────────────────────────────

check_cert_manager() {
    section "cert-manager"

    if [[ ! -f "${RKE2_KC}" ]]; then
        skip "no RKE2 kubeconfig — skipping cert-manager"
        return
    fi

    if ! rkubectl get namespace cert-manager &>/dev/null 2>&1; then
        skip "cert-manager namespace not found  (not yet deployed)"
        return
    fi

    local not_running
    not_running=$(rkubectl get pods -n cert-manager --no-headers 2>/dev/null \
        | grep -v 'Running' | grep -v '^$' || true)
    if [[ -z "${not_running}" ]]; then
        local count
        count=$(rkubectl get pods -n cert-manager --no-headers 2>/dev/null | wc -l | tr -d ' ')
        pass "${count} cert-manager pod(s) Running"
    else
        fail "cert-manager pods not Running:"
        echo "${not_running}" | sed 's/^/        /'
    fi

    local ready_count
    ready_count=$(rkubectl get clusterissuer --no-headers 2>/dev/null \
        | awk '$2 == "True"' | wc -l | tr -d ' ' || echo 0)
    if [[ "${ready_count}" -ge 1 ]]; then
        pass "${ready_count} ClusterIssuer(s) Ready"
    else
        skip "no Ready ClusterIssuers found  (not yet deployed)"
    fi
}

# ── 8. Harbor registry ────────────────────────────────────────────────────────

check_harbor() {
    section "Harbor registry"

    local url="https://harbor.${DOMAIN}/api/v2.0/systeminfo"
    local code
    code=$(curl_ca -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null || echo "000")

    case "${code}" in
        200|401) pass "Harbor API responding  (HTTP ${code})" ;;
        000)     skip "Harbor not reachable  (not yet deployed?)" ;;
        *)       fail "Harbor API returned HTTP ${code}  (${url})" ;;
    esac
}

# ── 9. Keycloak ───────────────────────────────────────────────────────────────

check_keycloak() {
    section "Keycloak"

    local url="https://keycloak.${DOMAIN}/health/ready"
    local code
    code=$(curl_ca -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null || echo "000")

    case "${code}" in
        200) pass "Keycloak health ready  (${url})" ;;
        000) skip "Keycloak not reachable  (not yet deployed?)" ;;
        *)   fail "Keycloak health returned HTTP ${code}  (${url})" ;;
    esac
}

# ── 10. Rancher Manager ───────────────────────────────────────────────────────

check_rancher() {
    section "Rancher Manager"

    local url="https://rancher.${DOMAIN}/ping"
    local code
    code=$(curl_ca -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null || echo "000")

    case "${code}" in
        200) pass "Rancher ping OK  (${url})" ;;
        000) skip "Rancher not reachable  (not yet deployed?)" ;;
        *)   fail "Rancher ping returned HTTP ${code}  (${url})" ;;
    esac
}

# ── 11. DGX Spark ─────────────────────────────────────────────────────────────

check_dgx() {
    section "DGX Spark (arm64)"

    if [[ "${SKIP_DGX}" == "1" ]]; then
        skip "skipped via --skip-dgx"
        return
    fi

    if ! ping -c1 -W2 "${DGX_IP}" &>/dev/null; then
        skip "DGX not pingable at ${DGX_IP}  (not yet joined?)"
        return
    fi
    pass "DGX reachable  (${DGX_IP})"

    if [[ ! -f "${RKE2_KC}" ]]; then
        skip "no RKE2 kubeconfig — cannot check DGX node status"
        return
    fi

    local status
    status=$(rkubectl get node spark --no-headers 2>/dev/null | awk '{print $2}' || true)
    case "${status}" in
        Ready)  pass "DGX Spark node Ready in RKE2 cluster" ;;
        '')     skip "DGX Spark not yet joined to RKE2 cluster" ;;
        *)      fail "DGX Spark node status: ${status}" ;;
    esac

    local gpu_count
    gpu_count=$(rkubectl get node spark \
        -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "")
    if [[ "${gpu_count:-0}" -gt 0 ]]; then
        pass "GPU allocatable on spark node  (nvidia.com/gpu=${gpu_count})"
    else
        skip "nvidia.com/gpu not yet allocatable on spark  (GPU Operator not deployed?)"
    fi
}

# ── summary ───────────────────────────────────────────────────────────────────

summary() {
    echo
    echo "════════════════════════════════════════════════"
    echo -e "  ${GREEN}PASS${RESET} ${PASS}   ${RED}FAIL${RESET} ${FAIL}   ${YELLOW}SKIP${RESET} ${SKIP}"
    echo "════════════════════════════════════════════════"
    if [[ ${FAIL} -gt 0 ]]; then
        echo "[enclave] verification FAILED — ${FAIL} check(s) need attention"
        return 1
    else
        echo "[enclave] verification PASSED"
    fi
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
    echo "[enclave] carbide-enclave smoke test"
    echo "[enclave] env:    ${ENVIRONMENT}"
    echo "[enclave] domain: ${DOMAIN}"
    echo "[enclave] date:   $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    check_nuc00_services
    check_step_ca
    check_dns
    check_hauler
    check_harvester
    check_rke2
    check_cert_manager
    check_harbor
    check_keycloak
    check_rancher
    check_dgx

    summary
}

main "$@"
