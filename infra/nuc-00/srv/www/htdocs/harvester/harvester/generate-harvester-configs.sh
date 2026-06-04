#!/usr/bin/env bash
# generate-harvester-configs.sh
#
# Render Harvester config and iPXE menu files from .tmpl templates using envsubst.
#
# Usage:
#   cd <repo-root>
#   bash Files/nuc-00/srv/www/htdocs/harvester/harvester/generate-harvester-configs.sh
#
# Override environment before running:
#   ENVIRONMENT=enclave bash Files/.../generate-harvester-configs.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../../../.." && pwd)"

source "${REPO_ROOT}/Scripts/env.sh"

echo "Generating Harvester configs for ENVIRONMENT=${ENVIRONMENT}"
echo "  IP_PREFIX=${IP_PREFIX}  HARVESTER_VERSION=${HARVESTER_VERSION}  BASE_DOMAIN=${BASE_DOMAIN}"
echo ""

# Variables substituted in YAML config files
YAML_VARS='${HARVESTER_TOKEN}${HARVESTER_PASSWORD}${HARVESTER_VERSION}${HARVESTER_VIP}'
YAML_VARS+='${DNS1_IP}${DNS2_IP}${GATEWAY}${ADMIN_IP}${BASE_DOMAIN}${NIC_NAME}'
YAML_VARS+='${NUC01_IP}${NUC02_IP}${NUC03_IP}${NUC01_MAC}${NUC02_MAC}${NUC03_MAC}'

# Variables substituted in iPXE menu files (uppercase only — leaves iPXE ${lowercase} vars intact)
IPXE_VARS='${ADMIN_IP}${DNS2_IP}${HARVESTER_VERSION}'

render() {
  local tmpl="$1"
  local out="${tmpl%.tmpl}"
  local vars="$2"
  envsubst "${vars}" < "${tmpl}" > "${out}"
  echo "  rendered: $(basename "${out}")"
}

render "${SCRIPT_DIR}/config-create-nuc-01.yaml.tmpl" "${YAML_VARS}"
render "${SCRIPT_DIR}/config-join-nuc-02.yaml.tmpl"   "${YAML_VARS}"
render "${SCRIPT_DIR}/config-join-nuc-03.yaml.tmpl"   "${YAML_VARS}"
render "${SCRIPT_DIR}/ipxe-menu.tmpl"                 "${IPXE_VARS}"
render "${SCRIPT_DIR}/ipxe-menu-complicated.tmpl"     "${IPXE_VARS}"

echo ""
echo "Done. Copy files to the HTTP server if running remotely:"
echo "  rsync -av ${SCRIPT_DIR}/*.yaml ${SCRIPT_DIR}/ipxe-menu* nuc-00:/srv/www/htdocs/harvester/harvester/"
