#!/usr/bin/env bash
# Generic step-ca certificate renewal for host-level (non-Kubernetes) services.
#
# Required privilege: the user that owns the cert/key files (mansible for Hauler)
# Run by:            OS cron (see infra/nuc-00/etc/cron.d/step-cert-renew)
#
# Usage:
#   step-cert-renew.sh <cert> <key> <reload-command>
#
# Arguments:
#   cert            Path to the PEM certificate file to renew
#   key             Path to the matching private key file
#   reload-command  Shell command to run after a successful renewal
#                   (quoted string; runs via eval)
#
# Notes:
# - Renews only when the cert is within 2/3 of its lifetime (step-ca default).
#   For 24 h ACME certs this means renewal triggers after ~8 h. Running this
#   every 6 h from cron gives a comfortable margin with two retry windows.
# - No ACME challenge needed for renewal — step ca renew authenticates via
#   the existing cert (mTLS), so Apache does not need to serve a challenge token.
# - cert-manager + StepIssuer (bootstrap step 6) handles renewal for all
#   Kubernetes-hosted services. This script is for host-level daemons only.
#
# To add a new service: add a cron line in infra/nuc-00/etc/cron.d/step-cert-renew
# pointing at the same script with the service-specific cert, key, and reload cmd.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/env.d/carbide-enclave.sh"

CERT="${1:?usage: step-cert-renew.sh <cert> <key> <reload-cmd>}"
KEY="${2:?usage: step-cert-renew.sh <cert> <key> <reload-cmd>}"
RELOAD_CMD="${3:?usage: step-cert-renew.sh <cert> <key> <reload-cmd>}"

CA_URL="https://ca.${DOMAIN}:8443"
CA_ROOT="/srv/www/htdocs/step-ca/carbide-enclave-root-ca.crt"

log() { echo "[step-renew] $(date -Iseconds) $*"; }

if [[ ! -f "${CERT}" ]]; then
    log "ERROR: cert not found: ${CERT}"
    exit 1
fi

log "checking ${CERT}"

if step ca renew \
    "${CERT}" "${KEY}" \
    --ca-url "${CA_URL}" \
    --root "${CA_ROOT}"; then
    log "renewed — running reload: ${RELOAD_CMD}"
    eval "${RELOAD_CMD}"
    log "done"
else
    log "no renewal needed (cert not yet within renewal window)"
fi
