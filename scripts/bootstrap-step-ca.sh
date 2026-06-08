#!/usr/bin/env bash
# Bootstrap step-ca (internal root CA) — carbide-enclave
#
# Required privilege: root (run as root or: sudo bash bootstrap-step-ca.sh)
# Required connection: internet (downloads step + step-ca binaries from GitHub)
#
# Run from nuc-00 before crossing the airgap boundary:
#   cd /srv/www/htdocs/carbide-enclave.kubernerdes.com && git pull
#   sudo bash scripts/bootstrap-step-ca.sh
#
# Idempotent: safe to re-run. CA init is skipped if already initialized.
#
# Prerequisites:
#   - DNS record: ca.carbide-enclave.kubernerdes.com → 10.0.0.10 (nuc-00)
#     Add to infra/nuc-00/var/lib/named/master/ zone files if not present.
#   - STEP_CA_PASSWORD in ~/.config/RGS/creds (or generated and printed here)
#
# What this script does:
#   1. Creates 'step' system user
#   2. Downloads and installs step CLI + step-ca binaries to /usr/local/bin
#   3. Initializes the PKI (root CA + intermediate CA) under /etc/step-ca
#   4. Adds ACME provisioner (for cert-manager StepIssuer integration)
#   5. Installs the step-ca systemd unit and starts the service
#   6. Adds root CA cert to the system trust store
#   7. Opens firewall port 8443
#
# After this script succeeds:
#   CA URL:       https://ca.carbide-enclave.kubernerdes.com:8443
#   ACME dir:     https://ca.carbide-enclave.kubernerdes.com:8443/acme/acme/directory
#   Root cert:    /etc/step-ca/certs/root_ca.crt
#
# Bootstrap additional nodes with the fingerprint printed at the end:
#   step ca bootstrap \
#       --ca-url https://ca.carbide-enclave.kubernerdes.com:8443 \
#       --fingerprint <fingerprint>

set -euo pipefail

# /usr/local/bin is not always in root's PATH when invoked via sudo
export PATH="/usr/local/bin:${PATH}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/env.d/carbide-enclave.sh"
[[ -f "${HOME}/.config/RGS/creds" ]] && source "${HOME}/.config/RGS/creds"

STEPPATH="/etc/step-ca"
STEP_USER="step"
CA_NAME="carbide-enclave Root CA"
CA_PORT="8443"
CA_DNS="ca.${DOMAIN}"
CA_URL="https://${CA_DNS}:${CA_PORT}"
ACME_PROVISIONER="acme"

log() { echo "[enclave] $*"; }

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "ERROR: this script must be run as root" >&2
        exit 1
    fi
}

# ── step 1: system user ───────────────────────────────────────────────────────

create_step_user() {
    if id "${STEP_USER}" &>/dev/null; then
        log "user '${STEP_USER}' already exists"
        return
    fi
    log "creating system user '${STEP_USER}'"
    useradd --system \
        --home-dir "${STEPPATH}" \
        --shell /sbin/nologin \
        --comment "step-ca service account" \
        "${STEP_USER}"
}

# ── step 2: binaries ──────────────────────────────────────────────────────────

install_step_binaries() {
    local cli_ver="${STEP_CLI_VERSION#v}"
    local ca_ver="${STEP_CA_VERSION#v}"
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp}"' RETURN

    if command -v step &>/dev/null; then
        log "step CLI already installed: $(step version 2>&1 | head -1)"
    else
        log "downloading step CLI v${cli_ver}"
        curl -fsSL \
            "https://github.com/smallstep/cli/releases/download/v${cli_ver}/step_linux_${cli_ver}_amd64.tar.gz" \
            | tar -xz -C "${tmp}"
        local step_bin
        step_bin="$(find "${tmp}" -name "step" -type f | head -1)"
        install -m 755 "${step_bin}" /usr/local/bin/step
        log "step CLI installed: $(step version 2>&1 | head -1)"
    fi

    if command -v step-ca &>/dev/null; then
        log "step-ca already installed: $(step-ca version 2>&1 | head -1)"
    else
        log "downloading step-ca v${ca_ver}"
        curl -fsSL \
            "https://github.com/smallstep/certificates/releases/download/v${ca_ver}/step-ca_linux_${ca_ver}_amd64.tar.gz" \
            | tar -xz -C "${tmp}"
        local stepca_bin
        stepca_bin="$(find "${tmp}" -name "step-ca" -type f | head -1)"
        install -m 755 "${stepca_bin}" /usr/local/bin/step-ca
        log "step-ca installed: $(step-ca version 2>&1 | head -1)"
    fi
}

# ── step 3: CA initialization ─────────────────────────────────────────────────

resolve_password() {
    if [[ -n "${STEP_CA_PASSWORD:-}" ]]; then
        log "using STEP_CA_PASSWORD from credentials file"
        return
    fi
    log "STEP_CA_PASSWORD not set — generating random password"
    STEP_CA_PASSWORD="$(openssl rand -base64 32)"
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────┐"
    echo "  │  GENERATED CA PASSWORD — save this to ~/.config/RGS/creds  │"
    echo "  │  STEP_CA_PASSWORD=${STEP_CA_PASSWORD}  │"
    echo "  └─────────────────────────────────────────────────────────────┘"
    echo ""
}

init_ca() {
    if [[ -f "${STEPPATH}/config/ca.json" ]]; then
        log "CA already initialized at ${STEPPATH} — skipping init"
        return
    fi

    log "initializing CA: '${CA_NAME}'"
    install -d -m 700 -o "${STEP_USER}" -g "${STEP_USER}" "${STEPPATH}"

    # Password file — root-owned, step-readable; never world-readable
    install -m 640 -o root -g "${STEP_USER}" /dev/null "${STEPPATH}/password.txt"
    printf '%s' "${STEP_CA_PASSWORD}" > "${STEPPATH}/password.txt"

    STEPPATH="${STEPPATH}" step ca init \
        --name "${CA_NAME}" \
        --dns "${CA_DNS}" \
        --dns "${BASTION_IP}" \
        --address ":${CA_PORT}" \
        --provisioner "admin" \
        --password-file "${STEPPATH}/password.txt" \
        --deployment-type standalone

    chown -R "${STEP_USER}:${STEP_USER}" "${STEPPATH}"
    # Password file ownership: root owns it, step can read it
    chown root:"${STEP_USER}" "${STEPPATH}/password.txt"
    log "CA initialized"
}

# ── step 4: ACME provisioner ──────────────────────────────────────────────────

add_acme_provisioner() {
    local ca_json="${STEPPATH}/config/ca.json"

    if python3 -c "
import json, sys
with open('${ca_json}') as f:
    cfg = json.load(f)
provisioners = cfg.get('authority', {}).get('provisioners', [])
sys.exit(0 if any(p.get('type') == 'ACME' for p in provisioners) else 1)
" 2>/dev/null; then
        log "ACME provisioner already configured"
        return
    fi

    log "adding ACME provisioner '${ACME_PROVISIONER}'"
    python3 - <<PYEOF
import json

ca_json = "${ca_json}"
with open(ca_json) as f:
    cfg = json.load(f)

cfg.setdefault('authority', {}).setdefault('provisioners', []).append({
    "type": "ACME",
    "name": "${ACME_PROVISIONER}"
})

with open(ca_json, 'w') as f:
    json.dump(cfg, f, indent=4)

print("[enclave] ACME provisioner written to ca.json")
PYEOF
    chown "${STEP_USER}:${STEP_USER}" "${ca_json}"
    log "ACME provisioner added"
}

# ── step 5: systemd unit ──────────────────────────────────────────────────────

configure_systemd() {
    local unit_file="/etc/systemd/system/step-ca.service"

    if [[ ! -f "${unit_file}" ]]; then
        log "writing systemd unit: ${unit_file}"
        cat > "${unit_file}" <<EOF
[Unit]
Description=step-ca — carbide-enclave internal CA
Documentation=https://smallstep.com/docs/step-ca
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${STEP_USER}
Group=${STEP_USER}
Environment=STEPPATH=${STEPPATH}
ExecStart=/usr/local/bin/step-ca ${STEPPATH}/config/ca.json --password-file ${STEPPATH}/password.txt
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    else
        log "systemd unit already exists: ${unit_file}"
    fi

    systemctl daemon-reload
    systemctl enable --now step-ca
    log "step-ca enabled and started"
}

# ── step 6: system trust store ────────────────────────────────────────────────

trust_root_ca() {
    local trust_anchor="/etc/pki/trust/anchors/carbide-enclave-root-ca.crt"
    if [[ -f "${trust_anchor}" ]]; then
        log "root CA already in system trust store"
        return
    fi
    log "adding root CA to system trust store"
    cp "${STEPPATH}/certs/root_ca.crt" "${trust_anchor}"
    update-ca-certificates
    log "system trust store updated"
}

# ── step 7: firewall ──────────────────────────────────────────────────────────

configure_firewall() {
    if firewall-cmd --list-ports | grep -q "${CA_PORT}/tcp"; then
        log "firewall port ${CA_PORT}/tcp already open"
        return
    fi
    log "opening firewall port ${CA_PORT}/tcp (step-ca API + ACME)"
    firewall-cmd --permanent --add-port="${CA_PORT}/tcp"
    firewall-cmd --reload
    log "port ${CA_PORT}/tcp open"
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
    require_root
    log "starting step-ca bootstrap (environment: ${ENVIRONMENT})"
    log "CA: ${CA_NAME}  |  URL: ${CA_URL}"
    echo

    resolve_password
    echo
    create_step_user
    echo
    install_step_binaries
    echo
    init_ca
    echo
    add_acme_provisioner
    echo
    configure_systemd
    echo
    trust_root_ca
    echo
    configure_firewall
    echo

    local fingerprint
    fingerprint="$(step certificate fingerprint "${STEPPATH}/certs/root_ca.crt")"

    log "bootstrap complete"
    echo
    log "CA URL:         ${CA_URL}"
    log "ACME directory: ${CA_URL}/acme/${ACME_PROVISIONER}/directory"
    log "Root cert:      ${STEPPATH}/certs/root_ca.crt"
    log "Fingerprint:    ${fingerprint}"
    echo
    log "Bootstrap other nodes:"
    log "  step ca bootstrap \\"
    log "      --ca-url ${CA_URL} \\"
    log "      --fingerprint ${fingerprint}"
    echo
    log "Verify:"
    log "  systemctl status step-ca"
    log "  curl -s ${CA_URL}/health"
}

main "$@"
