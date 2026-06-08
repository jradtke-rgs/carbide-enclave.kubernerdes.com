#!/usr/bin/env bash
# Generate Harvester node configs and iPXE menu — carbide-enclave
#
# Required privilege: mansible (no root needed — writes to web root)
# Run from nuc-00:
#   bash /srv/www/htdocs/carbide-enclave.kubernerdes.com/infra/nuc-00/srv/www/htdocs/harvester/harvester/generate-harvester-configs.sh
#
# Or from MBP (generates files locally for review before pushing):
#   bash infra/nuc-00/srv/www/htdocs/harvester/harvester/generate-harvester-configs.sh
#
# Idempotent: safe to re-run. Overwrites existing configs.
#
# What this script generates (all in the same directory as this script):
#   config-create-nuc-01.yaml  — nuc-01 install config (create cluster)
#   config-join-nuc-02.yaml    — nuc-02 install config (join cluster)
#   config-join-nuc-03.yaml    — nuc-03 install config (join cluster)
#   ipxe-menu                  — iPXE boot menu served to all three nodes
#
# Credentials sourced from ~/.config/RGS/creds:
#   HARVESTER_TOKEN     — cluster join token (must match on all nodes)
#   HARVESTER_PASSWORD  — OS password set on each node

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../../../.." && pwd)"

source "${REPO_ROOT}/scripts/env.d/carbide-enclave.sh"
[[ -f "${HOME}/.config/RGS/creds" ]] && source "${HOME}/.config/RGS/creds"

# Fall back to current values if not set in creds
HARVESTER_TOKEN="${HARVESTER_TOKEN:-KentuckyHarvester}"
HARVESTER_PASSWORD="${HARVESTER_PASSWORD:-Passw0rd01##}"

HVFULL="${HARVESTER_VERSION}-${HARVESTER_EDITION}"
ISO_BASE_URL="http://${BASTION_IP}/harvester/${HARVESTER_VERSION}-amd64-${HARVESTER_EDITION}"
IPXE_BASE_URL="${ISO_BASE_URL}"
CONFIG_URL="http://${BASTION_IP}/harvester/harvester"

log() { echo "[enclave] $*"; }

# ── SSH authorized keys ───────────────────────────────────────────────────────
# Public keys — not secrets. Add/remove entries here as operators change.
# These are injected into every Harvester node's authorized_keys at install time.
SSH_KEYS="    - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCozGnmSeEzFQovxzvwgLaQmfE5/eGDfzKHMwofs1rvdef6WD89ubQjh2bFDe69IPGh0kV93QraLUXL1hDa3J+k9LIhr7HqAg365bm3UtY7jIDADmAjDo8yVJ5oiSMvmgUlaw3REFjaMXwQXCddDVWhoWFk/gE1w/14/EbFfSJni9iohl+A76s5GRlVZXSTVb/zYxeQFAlstUaxQVFD8EGNcWI5Ptydgil+hlrA7k16qrkj+5l5muDkRLndcsR/zrpLy2cdNWmI6s/aGQ/IHpUmLf92AAIbzMskK4Asdno1RiuNFybfjoPomo1NlYh6J/VS2uEq4Zg4zWuVbl7yjTRx mansible@kubernerd
    - ecdsa-sha2-nistp521 AAAAE2VjZHNhLXNoYTItbmlzdHA1MjEAAAAIbmlzdHA1MjEAAACFBADUeWpBo8XY3ePFn/vX2yMjx8MfC3ZO1Jl6t5jZ0hCHwcc9x4Yp4ASXn1epmfEFqmhTJkEKunJafpKnQ0lm1yW/KgA+ew7t+dq2l0yck6/X3cPZlxf8nYIvTXmHf6DYhJ54U26bTaB8iSaXkhRt2RiKWDeqbFp6oJkiWQMtppJuHJlIbA== mansible@nuc-00-02"

# ── config generators ─────────────────────────────────────────────────────────

generate_create_config() {
    local out="${SCRIPT_DIR}/config-create-nuc-01.yaml"
    log "generating ${out##*/}"
    cat > "${out}" <<EOF
---
scheme_version: 1
token: ${HARVESTER_TOKEN}
os:
  hostname: nuc-01
  ssh_authorized_keys:
${SSH_KEYS}
  password: ${HARVESTER_PASSWORD}
  ntp_servers:
    - ${BASTION_IP}
  dns_nameservers:
    - ${BASTION_IP}
    - 8.8.8.8
install:
  skipchecks: true
  mode: create
  management_interface:
    interfaces:
      - name: ${HARVESTER_NIC}
        hwAddr: "${NUC01_MAC}"
    default_route: true
    method: static
    ip: ${IP_PREFIX}.101
    subnet_mask: ${HARVESTER_SUBNET_MASK}
    gateway: ${GATEWAY}
    bond_options:
      mode: active-backup
      miimon: 100
  device: ${HARVESTER_OS_DISK}
  data_disk: ${HARVESTER_DATA_DISK}
  iso_url: ${ISO_BASE_URL}/harvester-${HVFULL}-amd64.iso
  vip: ${HARVESTER_VIP}
  vip_mode: static
sans:
  - harvester.${DOMAIN}
  - ${HARVESTER_VIP}
  - nuc-01.${DOMAIN}
  - nuc-02.${DOMAIN}
  - nuc-03.${DOMAIN}
  - ${IP_PREFIX}.101
  - ${IP_PREFIX}.102
  - ${IP_PREFIX}.103
EOF
}

generate_join_config() {
    local node="$1"
    local ip="$2"
    local mac="$3"
    local out="${SCRIPT_DIR}/config-join-${node}.yaml"
    log "generating ${out##*/}"
    cat > "${out}" <<EOF
---
scheme_version: 1
server_url: https://${HARVESTER_VIP}
token: ${HARVESTER_TOKEN}
os:
  hostname: ${node}
  ssh_authorized_keys:
${SSH_KEYS}
  password: ${HARVESTER_PASSWORD}
  ntp_servers:
    - ${BASTION_IP}
  dns_nameservers:
    - ${BASTION_IP}
    - 8.8.8.8
install:
  skipchecks: true
  mode: join
  management_interface:
    interfaces:
      - name: ${HARVESTER_NIC}
        hwAddr: "${mac}"
    default_route: true
    method: static
    ip: ${ip}
    subnet_mask: ${HARVESTER_SUBNET_MASK}
    gateway: ${GATEWAY}
    bond_options:
      mode: active-backup
      miimon: 100
  device: ${HARVESTER_OS_DISK}
  data_disk: ${HARVESTER_DATA_DISK}
  iso_url: ${ISO_BASE_URL}/harvester-${HVFULL}-amd64.iso
sans:
  - harvester.${DOMAIN}
  - ${HARVESTER_VIP}
  - nuc-01.${DOMAIN}
  - nuc-02.${DOMAIN}
  - nuc-03.${DOMAIN}
  - ${IP_PREFIX}.101
  - ${IP_PREFIX}.102
  - ${IP_PREFIX}.103
EOF
}

generate_ipxe_menu() {
    local out="${SCRIPT_DIR}/ipxe-menu"
    log "generating ${out##*/}"
    cat > "${out}" <<EOF
#!ipxe
###############################################################################
# Harvester HCI iPXE Network Boot Menu — ${DOMAIN}
# Harvester ${HVFULL}
# Generated by generate-harvester-configs.sh — do not edit by hand
###############################################################################

:start
menu Harvester Deployment Menu
item --gap --                   --------------------------------------------
item --key l local                 Boot from local disk (default in 5s)
item --gap --                   ----------- Carbide ${HVFULL} -----------
item --key 1 nuc-01             Deploy Harvester to nuc-01 (create cluster)
item --key 2 nuc-02             Deploy Harvester to nuc-02 (join cluster)
item --key 3 nuc-03             Deploy Harvester to nuc-03 (join cluster)
item --gap --                   -------------------------------------------
item --key r reboot             Reboot system
item --key s shell              Drop to iPXE shell
choose --timeout 5000 --default local target && goto \${target}

:local
echo Booting from local disk...
sanboot --no-describe --drive 0x80 || goto failed

:nuc-01
echo Deploying Harvester ${HVFULL} to nuc-01 (create mode)...
kernel ${IPXE_BASE_URL}/harvester-${HVFULL}-vmlinuz-amd64 root=live:${IPXE_BASE_URL}/harvester-${HVFULL}-rootfs-amd64.squashfs console=tty1 harvester.install.automatic=true harvester.install.skipchecks=true ip=dhcp rd.cos.disable rd.net.dhcp.retry=3 rd.noverifyssl net.ifnames=1 harvester.install.config_url=${CONFIG_URL}/config-create-nuc-01.yaml
initrd ${IPXE_BASE_URL}/harvester-${HVFULL}-initrd-amd64
boot

:nuc-02
echo Deploying Harvester ${HVFULL} to nuc-02 (join mode)...
kernel ${IPXE_BASE_URL}/harvester-${HVFULL}-vmlinuz-amd64 root=live:${IPXE_BASE_URL}/harvester-${HVFULL}-rootfs-amd64.squashfs console=tty1 harvester.install.automatic=true harvester.install.skipchecks=true ip=dhcp rd.cos.disable rd.net.dhcp.retry=3 rd.noverifyssl net.ifnames=1 harvester.install.config_url=${CONFIG_URL}/config-join-nuc-02.yaml
initrd ${IPXE_BASE_URL}/harvester-${HVFULL}-initrd-amd64
boot

:nuc-03
echo Deploying Harvester ${HVFULL} to nuc-03 (join mode)...
kernel ${IPXE_BASE_URL}/harvester-${HVFULL}-vmlinuz-amd64 root=live:${IPXE_BASE_URL}/harvester-${HVFULL}-rootfs-amd64.squashfs console=tty1 harvester.install.automatic=true harvester.install.skipchecks=true ip=dhcp rd.cos.disable rd.net.dhcp.retry=3 rd.noverifyssl net.ifnames=1 harvester.install.config_url=${CONFIG_URL}/config-join-nuc-03.yaml
initrd ${IPXE_BASE_URL}/harvester-${HVFULL}-initrd-amd64
boot

:reboot
echo Rebooting in 2 seconds...
sleep 2
reboot

:shell
echo Dropping to iPXE shell...
shell

:failed
echo Boot failed! Dropping to shell for debugging...
prompt
shell
EOF
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
    log "generating Harvester configs (${HVFULL})"
    log "bastion: ${BASTION_IP}  VIP: ${HARVESTER_VIP}  domain: ${DOMAIN}"
    echo

    generate_create_config
    generate_join_config "nuc-02" "${IP_PREFIX}.102" "${NUC02_MAC}"
    generate_join_config "nuc-03" "${IP_PREFIX}.103" "${NUC03_MAC}"
    generate_ipxe_menu

    echo
    log "generated files in ${SCRIPT_DIR}:"
    ls -1 "${SCRIPT_DIR}"/*.yaml "${SCRIPT_DIR}/ipxe-menu"
    echo
    log "deploy to nuc-00 if running on MBP:"
    log "  rsync -av ${SCRIPT_DIR}/*.yaml ${SCRIPT_DIR}/ipxe-menu mansible@${BASTION_IP}:/srv/www/htdocs/harvester/harvester/"
}

main "$@"
