#!/usr/bin/env bash
# Bootstrap nuc-00 (bastion host) — carbide-enclave
#
# Required privilege: root (run as root or: sudo bash bootstrap-nuc-00.sh)
# Required connection: ssh -i ~/.ssh/id_ecdsa-kubernerdes mansible@10.0.0.10
#
# First-time setup on nuc-00:
#   sudo zypper install -y git-core
#   sudo git clone https://github.com/jradtke-rgs/carbide-enclave.kubernerdes.com.git \
#       /srv/www/htdocs/carbide-enclave.kubernerdes.com
#   sudo bash /srv/www/htdocs/carbide-enclave.kubernerdes.com/scripts/bootstrap-nuc-00.sh
#
# Subsequent updates:
#   cd /srv/www/htdocs/carbide-enclave.kubernerdes.com && git pull
#   sudo bash scripts/bootstrap-nuc-00.sh
#
# Idempotent: safe to re-run. Each section checks before overwriting.
#
# What this script does:
#   1. Configures sudo NOPASSWD for mansible
#   2. Installs and configures chrony (NTP sync + serve)
#   3. Installs and configures BIND (authoritative DNS for carbide-enclave.kubernerdes.com)
#   4. Installs and configures ISC DHCP server
#   5. Installs Apache2 + PHP8 + kubectl and deploys web content
#   6. Installs and configures tftp-server (for iPXE ipxe.efi delivery)
#   7. Opens required firewall ports (firewalld)
#
# Config files are deployed from the repo mirror at infra/nuc-00/,
# which maps directly to the host filesystem.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_MIRROR="${REPO_ROOT}/infra/nuc-00"

source "${REPO_ROOT}/scripts/env.d/carbide-enclave.sh"

# Kubernetes repo — needed for kubectl; only reachable pre-airgap
KUBECTL_VERSION="v1.33"
K8S_REPO_URL="https://pkgs.k8s.io/core:/stable:/${KUBECTL_VERSION}/rpm/"
K8S_REPO_ALIAS="kubernetes"

# ── helpers ──────────────────────────────────────────────────────────────────

log() { echo "[enclave] $*"; }

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "ERROR: this script must be run as root" >&2
        exit 1
    fi
}

install_if_missing() {
    local pkg="$1"
    if ! rpm -q "${pkg}" &>/dev/null; then
        log "installing ${pkg}"
        zypper install -y "${pkg}"
    else
        log "${pkg} already installed"
    fi
}

detect_primary_iface() {
    # Return the first non-loopback interface name (no trailing colon)
    ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}'
}

# ── step 1: sudo ─────────────────────────────────────────────────────────────

configure_sudo() {
    log "configuring sudo NOPASSWD for ${ADMIN_USER}"
    local sudoers_file="/etc/sudoers.d/${ADMIN_USER}"
    echo "${ADMIN_USER} ALL=(ALL) NOPASSWD: ALL" > "${sudoers_file}"
    chmod 440 "${sudoers_file}"
    log "sudo configured: ${sudoers_file}"
}

# ── step 2: NTP (chrony) ─────────────────────────────────────────────────────

configure_ntp() {
    log "configuring NTP (chrony)"
    install_if_missing chrony
    cp "${HOST_MIRROR}/etc/chrony.conf" /etc/chrony.conf
    systemctl enable --now chronyd
    log "NTP configured; forcing initial sync"
    chronyc makestep || true
    log "NTP status:"
    chronyc tracking | grep -E "^(Reference|System time|Stratum)"
}

# ── step 3: DNS (BIND) ───────────────────────────────────────────────────────

configure_dns() {
    log "configuring DNS (BIND / named)"
    install_if_missing bind

    # Deploy configs
    cp "${HOST_MIRROR}/etc/named.conf" /etc/named.conf
    install -d -m 755 -o root -g root /etc/named.d
    cp "${HOST_MIRROR}/etc/named.d/carbide-enclave.conf" /etc/named.d/

    # Zone data directory
    install -d -m 755 -o named -g named /var/lib/named/master
    cp "${HOST_MIRROR}/var/lib/named/master/"* /var/lib/named/master/
    chown -R named:named /var/lib/named/master

    # Log directory
    install -d -m 750 -o named -g named /var/log/named

    # Validate config before starting
    log "validating named config"
    named-checkconf /etc/named.conf
    named-checkzone carbide-enclave.kubernerdes.com \
        /var/lib/named/master/carbide-enclave.kubernerdes.com.zone
    named-checkzone 0.0.10.in-addr.arpa \
        /var/lib/named/master/10.0.0.rev

    systemctl enable --now named
    log "DNS configured; testing local resolution"
    sleep 2
    dig @127.0.0.1 nuc-00.carbide-enclave.kubernerdes.com +short || true
}

# ── step 4: DHCP (ISC dhcpd) ─────────────────────────────────────────────────

configure_dhcp() {
    log "configuring DHCP (ISC dhcpd)"
    install_if_missing dhcp-server

    cp "${HOST_MIRROR}/etc/dhcpd.conf" /etc/dhcpd.conf
    install -d -m 755 -o root -g root /etc/dhcpd.d
    cp "${HOST_MIRROR}/etc/dhcpd.d/dhcpd-hosts.conf" /etc/dhcpd.d/

    # Ensure the lease file and its directory exist.
    # On OpenSUSE Leap 15.6 the dhcpd user has no matching group name; use its gid directly.
    local dhcpd_gid
    dhcpd_gid="$(id -g dhcpd)"
    install -d -m 755 -o dhcpd -g "${dhcpd_gid}" /var/lib/dhcp/db
    touch /var/lib/dhcp/db/dhcpd.leases
    chown dhcpd:"${dhcpd_gid}" /var/lib/dhcp/db/dhcpd.leases

    # Bind dhcpd to the primary interface
    local iface
    iface="$(detect_primary_iface)"
    log "dhcpd will listen on interface: ${iface}"

    # SUSE reads DHCPD_INTERFACE from /etc/sysconfig/dhcpd
    local sysconfig=/etc/sysconfig/dhcpd
    if [[ -f "${sysconfig}" ]]; then
        sed -i "s|^DHCPD_INTERFACE=.*|DHCPD_INTERFACE=\"${iface}\"|" "${sysconfig}"
    else
        printf 'DHCPD_INTERFACE="%s"\n' "${iface}" > "${sysconfig}"
    fi

    # Validate config
    log "validating dhcpd config"
    dhcpd -t -cf /etc/dhcpd.conf

    systemctl enable --now dhcpd
    log "DHCP configured"
}

# ── step 5: web server (Apache2 + PHP8 + kubectl) ────────────────────────────

configure_web() {
    log "configuring web server (Apache2 + PHP8 + kubectl)"

    # Apache2
    install_if_missing apache2

    # Add mansible to the www group (Apache's group on SUSE) for web content access
    usermod -a -G www "${ADMIN_USER}"

    # PHP8 packages — matches reference machine (10.10.12.10)
    local php_packages=(
        apache2-mod_php8
        php8
        php8-cli
        php8-ctype
        php8-dom
        php8-iconv
        php8-openssl
        php8-pdo
        php8-sqlite
        php8-tokenizer
        php8-xmlreader
        php8-xmlwriter
    )
    for pkg in "${php_packages[@]}"; do
        install_if_missing "${pkg}"
    done

    # kubectl — needed by kubernerdes.php (shell_exec / exec calls)
    # Requires the Kubernetes zypper repo (internet access, pre-airgap only)
    if ! rpm -q kubectl &>/dev/null; then
        log "adding Kubernetes repo for kubectl"
        zypper addrepo --refresh "${K8S_REPO_URL}" "${K8S_REPO_ALIAS}" 2>/dev/null || true
        zypper --gpg-auto-import-keys refresh "${K8S_REPO_ALIAS}"
        zypper install -y kubectl
    else
        log "kubectl already installed"
    fi

    # Deploy web content
    rsync -a --chown=wwwrun:www "${HOST_MIRROR}/srv/www/htdocs/" /srv/www/htdocs/

    # sgid on all dirs so new files inherit www group automatically
    # Dirs: rwxrwsr-x (2775), files: rw-rw-r-- (664)
    find /srv/www/htdocs -type d -exec chmod 2775 {} +
    find /srv/www/htdocs -type f -exec chmod 664 {} +

    # /srv/www/.kube/ — kubeconfig files read by kubernerdes.php
    install -d -m 2775 -o root -g www /srv/www/.kube

    # Ensure DocumentRoot is correct in default vhost
    local docroot_conf=/etc/apache2/default-server.conf
    if [[ -f "${docroot_conf}" ]]; then
        grep -q '/srv/www/htdocs' "${docroot_conf}" \
            && log "DocumentRoot already set to /srv/www/htdocs" \
            || log "WARNING: check DocumentRoot in ${docroot_conf}"
    fi

    # Restart (not just enable) so mod_php8 is loaded if newly installed
    systemctl enable apache2
    systemctl restart apache2
    log "Apache2 + PHP8 configured"
    log "web content deployed to /srv/www/htdocs"
    log "kubeconfig drop directory: /srv/www/.kube/*.kubeconfig"
}

# ── step 6: TFTP (iPXE binary delivery) ──────────────────────────────────────

configure_tftp() {
    log "configuring TFTP server (tftp)"
    install_if_missing tftp

    # TFTP root is /srv/tftpboot — create it and ensure it's world-readable
    install -d -m 755 -o root -g root /srv/tftpboot

    # Enable and start the tftp socket (systemd socket-activated)
    systemctl enable --now tftp.socket
    log "TFTP configured; root: /srv/tftpboot"
    log "place ipxe.efi at /srv/tftpboot/ipxe.efi once Hauler is seeded"
}

# ── step 7: firewall ─────────────────────────────────────────────────────────

configure_firewall() {
    log "configuring firewall (firewalld)"
    install_if_missing firewalld
    systemctl enable --now firewalld

    local zone
    zone="$(firewall-cmd --get-default-zone)"
    log "default zone: ${zone}"

    firewall-cmd --permanent --zone="${zone}" --add-service=ssh
    firewall-cmd --permanent --zone="${zone}" --add-service=dns
    firewall-cmd --permanent --zone="${zone}" --add-service=dhcp
    firewall-cmd --permanent --zone="${zone}" --add-service=ntp
    firewall-cmd --permanent --zone="${zone}" --add-service=http
    firewall-cmd --permanent --zone="${zone}" --add-service=https
    firewall-cmd --permanent --zone="${zone}" --add-service=tftp
    # Hauler registry (port 5000) and file server (port 8080)
    firewall-cmd --permanent --zone="${zone}" --add-port=5000/tcp
    firewall-cmd --permanent --zone="${zone}" --add-port=8080/tcp

    firewall-cmd --reload
    log "firewall rules applied (services):"
    firewall-cmd --list-services --zone="${zone}"
    log "firewall rules applied (ports):"
    firewall-cmd --list-ports --zone="${zone}"
}

# ── main ─────────────────────────────────────────────────────────────────────

main() {
    require_root
    log "starting nuc-00 bootstrap (environment: ${ENVIRONMENT})"
    log "repo root: ${REPO_ROOT}  (expected: /srv/www/htdocs/carbide-enclave.kubernerdes.com)"
    echo

    configure_sudo
    echo
    configure_ntp
    echo
    configure_dns
    echo
    configure_dhcp
    echo
    configure_web
    echo
    configure_tftp
    echo
    configure_firewall
    echo

    log "bootstrap complete"
    log "verify services:"
    log "  systemctl status chronyd named dhcpd apache2"
    log "  dig @${BASTION_IP} nuc-00.${DOMAIN}"
    log "  curl http://${BASTION_IP}/"
    log ""
    log "repo is live at http://${BASTION_IP}/carbide-enclave.kubernerdes.com/"
}

main "$@"
