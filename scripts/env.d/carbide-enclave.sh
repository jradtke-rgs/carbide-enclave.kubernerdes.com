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

# Service VIPs
HARVESTER_VIP="${IP_PREFIX}.100"
RANCHER_VIP="${IP_PREFIX}.30"
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

# Software versions — update here first, scripts inherit
RKE2_VERSION="v1.30.13+rke2r1"       # last confirmed multi-arch stable
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
