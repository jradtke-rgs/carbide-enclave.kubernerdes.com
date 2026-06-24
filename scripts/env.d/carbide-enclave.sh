#!/usr/bin/env bash
# carbide-enclave environment — sourced by all scripts
# Do not hardcode IPs or hostnames outside this file.
# Sensitive values (passwords, tokens, keys) belong in a separate
# gitignored file: scripts/env.d/carbide-enclave.secrets.sh

ENVIRONMENT="carbide-enclave"
DOMAIN="carbide-enclave.kubernerdes.com"
IP_PREFIX="10.0.0"

# Network
GATEWAY="${IP_PREFIX}.1"
BASTION_IP="${IP_PREFIX}.10"      # nuc-00
NAS_IP="${IP_PREFIX}.11"
DGX_IP="${IP_PREFIX}.251"         # NVIDIA DGX Spark (arm64)

# RKE2 management cluster VM IPs (fixed via DHCP MAC binding)
# bootstrap-rke2.sh overrides these at runtime by querying Harvester VMI status
RANCHER_01_IP="${IP_PREFIX}.31"
RANCHER_02_IP="${IP_PREFIX}.32"
RANCHER_03_IP="${IP_PREFIX}.33"

# Service VIPs
HARVESTER_VIP="${IP_PREFIX}.100"
RANCHER_VIP="${IP_PREFIX}.30"       # shared: RKE2 API :6443 + Rancher Manager :443
HARBOR_VIP="${IP_PREFIX}.99"
KEYCLOAK_VIP="${IP_PREFIX}.98"

# DHCP
DHCP_RANGE_START="${IP_PREFIX}.172"
DHCP_RANGE_END="${IP_PREFIX}.254"
DHCP_NEXT_SERVER="${BASTION_IP}"

# NTP — nuc-00 primary; nuc-01/02/03 serve once Harvester is up
NTP_PRIMARY="${BASTION_IP}"
NTP_SERVERS="${BASTION_IP} ${IP_PREFIX}.101 ${IP_PREFIX}.102 ${IP_PREFIX}.103"

# Admin user
ADMIN_USER="mansible"

# Harvester node hardware (NUC10i7FNH) — used by DHCP and Harvester install configs
NUC01_MAC="88:ae:dd:0b:90:70"
NUC02_MAC="1c:69:7a:ab:23:50"
NUC03_MAC="88:ae:dd:0b:af:9c"

# IP-KVM management interfaces (one per Harvester node)
NUC01_KVM_IP="${IP_PREFIX}.111"
NUC02_KVM_IP="${IP_PREFIX}.112"
NUC03_KVM_IP="${IP_PREFIX}.113"
NUC01_KVM_MAC="48:da:35:6f:72:b3"
NUC02_KVM_MAC="48:da:35:6f:3e:c2"
NUC03_KVM_MAC="48:da:35:6f:e4:4f"
HARVESTER_NIC="eno1"
HARVESTER_OS_DISK="/dev/sda"
HARVESTER_DATA_DISK="/dev/nvme0n1"
HARVESTER_SUBNET_MASK="255.255.252.0"

# Software versions — update here first, scripts inherit
RKE2_VERSION="v1.32.13+rke2r2"       # latest stable v1.32
RANCHER_VERSION="v2.9.3"
HARVESTER_VERSION="v1.7.1"
HARVESTER_EDITION="govt.2"            # RGS government edition suffix
CERT_MANAGER_VERSION="v1.14.5"
HARBOR_VERSION="2.11.0"              # app / image tag version
HARBOR_CHART_VERSION="1.14.0"        # Helm chart version (≠ app version)
KEYCLOAK_VERSION="24.0.4"
HAULER_VERSION="v1.0.0"
GPU_OPERATOR_VERSION="v24.3.0"
STEP_CA_VERSION="v0.27.4"             # smallstep/certificates
STEP_CLI_VERSION="v0.27.4"            # smallstep/cli (separate release cadence)
