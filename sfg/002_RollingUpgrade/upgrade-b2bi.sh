#!/usr/bin/env bash
# =============================================================================
# upgrade-b2bi.sh
# Performs a rolling upgrade of IBM Sterling B2Bi (SFG) via Helm.
#
# Features:
#   - Prompts for namespace, Helm release name, and target app version
#   - Auto-discovers the matching Helm chart version from ibm-helm repo
#   - Detects whether the upgrade is MINOR (no schema change) or MAJOR
#     (database schema migration required)
#   - Backs up current Helm values before upgrading
#   - Generates an upgrade values override file with correct image tags,
#     upgrade flags, and new chart fields
#   - Runs a dry-run first, then prompts for confirmation
#   - Monitors pod health after the upgrade
#
# Usage:
#   chmod +x upgrade-b2bi.sh
#   ./upgrade-b2bi.sh
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# ── Dependency checks ─────────────────────────────────────────────────────────
for bin in helm oc kubectl; do
  if command -v "$bin" &>/dev/null; then
    CLI="${CLI:-$bin}"
  fi
done
command -v helm &>/dev/null || die "helm not found in PATH."
command -v oc   &>/dev/null && CLI="oc" || CLI="kubectl"
info "Using Kubernetes CLI: ${CLI}"
info "Using Helm: $(helm version --short)"

# ── Version comparison helpers ────────────────────────────────────────────────
# Returns the major.minor portion of a version string like 6.2.1.1 → 6.2
major_minor() { echo "$1" | cut -d. -f1,2; }

# Returns the patch level: 6.2.1.1 → 1  (third segment)
patch_level()  { echo "$1" | cut -d. -f3; }

# Compares two version strings; echoes "gt", "lt", or "eq"
version_compare() {
  local v1="$1" v2="$2"
  if [[ "$v1" == "$v2" ]]; then echo "eq"; return; fi
  local sorted
  sorted=$(printf '%s\n%s\n' "$v1" "$v2" \
    | awk -F. '{printf "%05d%05d%05d%05d\n",$1,$2,$3,$4}' \
    | sort -n | head -1)
  local v1_key
  v1_key=$(echo "$v1" | awk -F. '{printf "%05d%05d%05d%05d\n",$1,$2,$3,$4}')
  if [[ "$sorted" == "$v1_key" ]]; then echo "lt"; else echo "gt"; fi
}

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  IBM Sterling B2Bi — Rolling Upgrade Script${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""

# ── Prompt: Namespace ─────────────────────────────────────────────────────────
while true; do
  read -rp "$(echo -e "${BOLD}Namespace${NC} [default: ibm-b2bi-dev01-app]: ")" NAMESPACE
  NAMESPACE="${NAMESPACE:-ibm-b2bi-dev01-app}"
  NAMESPACE="${NAMESPACE// /}"
  [[ -n "${NAMESPACE}" ]] && break
  warn "Namespace cannot be empty."
done

${CLI} get namespace "${NAMESPACE}" &>/dev/null \
  || die "Namespace '${NAMESPACE}' not found on the cluster."
success "Namespace '${NAMESPACE}' found."

# ── Prompt: Helm release name ─────────────────────────────────────────────────
echo ""
info "Helm releases in namespace '${NAMESPACE}':"
helm list -n "${NAMESPACE}" 2>/dev/null || true
echo ""

while true; do
  read -rp "$(echo -e "${BOLD}Helm release name${NC} [default: s0]: ")" RELEASE
  RELEASE="${RELEASE:-s0}"
  RELEASE="${RELEASE// /}"
  [[ -n "${RELEASE}" ]] && break
  warn "Release name cannot be empty."
done

# Verify release exists and get current version
CURRENT_INFO=$(helm list -n "${NAMESPACE}" --filter "^${RELEASE}$" --output json 2>/dev/null)
if [[ -z "${CURRENT_INFO}" || "${CURRENT_INFO}" == "[]" ]]; then
  die "Helm release '${RELEASE}' not found in namespace '${NAMESPACE}'."
fi

CURRENT_CHART=$(echo "${CURRENT_INFO}" | grep -o '"chart":"[^"]*"' | cut -d'"' -f4)
CURRENT_APP_VERSION=$(echo "${CURRENT_INFO}" | grep -o '"app_version":"[^"]*"' | cut -d'"' -f4)
# Strip any _N suffix (e.g. 6.2.1.1_2 → 6.2.1.1)
CURRENT_APP_VERSION="${CURRENT_APP_VERSION%%_*}"

success "Current release: chart=${CURRENT_CHART}  app_version=${CURRENT_APP_VERSION}"

# ── Update Helm repo ──────────────────────────────────────────────────────────
echo ""
info "Updating ibm-helm repository..."
helm repo update ibm-helm 2>&1 | tail -2

# ── Show available versions ───────────────────────────────────────────────────
echo ""
info "Available ibm-b2bi-prod chart versions:"
helm search repo ibm-helm/ibm-b2bi-prod --versions 2>/dev/null \
  | awk 'NR==1 || /ibm-b2bi-prod/' \
  | head -15
echo ""

# ── Prompt: Target app version ────────────────────────────────────────────────
while true; do
  read -rp "$(echo -e "${BOLD}Target app version${NC} (e.g. 6.2.2.0): ")" TARGET_APP_VERSION
  TARGET_APP_VERSION="${TARGET_APP_VERSION// /}"
  # Strip _N suffix if user typed it
  TARGET_APP_VERSION="${TARGET_APP_VERSION%%_*}"
  [[ -n "${TARGET_APP_VERSION}" ]] && break
  warn "Target version cannot be empty."
done

# Validate target > current
CMP=$(version_compare "${TARGET_APP_VERSION}" "${CURRENT_APP_VERSION}")
if [[ "${CMP}" == "eq" ]]; then
  die "Target version ${TARGET_APP_VERSION} is the same as the current version. Nothing to do."
elif [[ "${CMP}" == "lt" ]]; then
  die "Target version ${TARGET_APP_VERSION} is older than current ${CURRENT_APP_VERSION}. Downgrades are not supported."
fi

# ── Determine upgrade type ────────────────────────────────────────────────────
CURRENT_MM=$(major_minor "${CURRENT_APP_VERSION}")
TARGET_MM=$(major_minor "${TARGET_APP_VERSION}")
CURRENT_PATCH=$(patch_level "${CURRENT_APP_VERSION}")
TARGET_PATCH=$(patch_level "${TARGET_APP_VERSION}")

echo ""
echo -e "${BOLD}------------------------------------------------------------${NC}"
echo -e "${BOLD}  Upgrade Type Analysis${NC}"
echo -e "${BOLD}------------------------------------------------------------${NC}"

if [[ "${CURRENT_MM}" != "${TARGET_MM}" ]]; then
  UPGRADE_TYPE="MAJOR"
  DB_SCHEMA_CHANGE=true
  echo -e "  Type   : ${RED}${BOLD}MAJOR UPGRADE${NC}"
  echo -e "  Reason : Major/minor version change (${CURRENT_MM} → ${TARGET_MM})"
  echo -e "  ${RED}⚠  DATABASE SCHEMA MIGRATION REQUIRED${NC}"
  echo -e "  ${RED}   The upgrade job will run DB schema changes.${NC}"
  echo -e "  ${RED}   Ensure a DB backup exists before proceeding.${NC}"
elif [[ "${CURRENT_PATCH}" != "${TARGET_PATCH}" ]]; then
  UPGRADE_TYPE="MINOR"
  DB_SCHEMA_CHANGE=true
  echo -e "  Type   : ${YELLOW}${BOLD}MINOR UPGRADE (patch-level)${NC}"
  echo -e "  Reason : Patch version change (${CURRENT_APP_VERSION} → ${TARGET_APP_VERSION})"
  echo -e "  ${YELLOW}⚠  DATABASE SCHEMA MIGRATION MAY BE REQUIRED${NC}"
  echo -e "  ${YELLOW}   Review the release notes for ${TARGET_APP_VERSION} before proceeding.${NC}"
else
  UPGRADE_TYPE="PATCH"
  DB_SCHEMA_CHANGE=false
  echo -e "  Type   : ${GREEN}${BOLD}PATCH / iFIX UPGRADE${NC}"
  echo -e "  Reason : Fix-pack only (${CURRENT_APP_VERSION} → ${TARGET_APP_VERSION})"
  echo -e "  ${GREEN}✓  No database schema changes expected.${NC}"
fi
echo -e "${BOLD}------------------------------------------------------------${NC}"

# ── Find matching chart version ───────────────────────────────────────────────
echo ""
info "Looking up chart version for app version ${TARGET_APP_VERSION}..."

# Try exact match first, then match with _N suffix
TARGET_CHART_VERSION=$(helm search repo ibm-helm/ibm-b2bi-prod --versions --output json 2>/dev/null \
  | grep -o '"version":"[^"]*","app_version":"'"${TARGET_APP_VERSION}"'[^"]*"' \
  | head -1 \
  | grep -o '"version":"[^"]*"' \
  | cut -d'"' -f4 || true)

if [[ -z "${TARGET_CHART_VERSION}" ]]; then
  warn "Could not auto-detect chart version for app version ${TARGET_APP_VERSION}."
  helm search repo ibm-helm/ibm-b2bi-prod --versions 2>/dev/null | head -20
  while true; do
    read -rp "$(echo -e "${BOLD}Enter chart version manually${NC} (e.g. 3.2.0): ")" TARGET_CHART_VERSION
    TARGET_CHART_VERSION="${TARGET_CHART_VERSION// /}"
    [[ -n "${TARGET_CHART_VERSION}" ]] && break
    warn "Chart version cannot be empty."
  done
else
  success "Found chart version: ibm-b2bi-prod-${TARGET_CHART_VERSION} (app ${TARGET_APP_VERSION})"
fi

# ── Backup current values ─────────────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="s0-values-backup-${CURRENT_APP_VERSION}-${TIMESTAMP}.yaml"
info "Backing up current Helm values to ${BACKUP_FILE}..."
helm get values "${RELEASE}" -n "${NAMESPACE}" -o yaml > "${BACKUP_FILE}"
success "Backup saved: ${BACKUP_FILE}"

# ── Gather current setupCfg values for identityService sub-chart ─────────────
DB_HOST=$(helm get values "${RELEASE}" -n "${NAMESPACE}" 2>/dev/null \
  | grep "dbHost:" | head -1 | awk '{print $2}' | tr -d '"' || echo "")
DB_PORT=$(helm get values "${RELEASE}" -n "${NAMESPACE}" 2>/dev/null \
  | grep "dbPort:" | head -1 | awk '{print $2}' | tr -d '"' || echo "50000")
DB_DATA=$(helm get values "${RELEASE}" -n "${NAMESPACE}" 2>/dev/null \
  | grep "dbData:" | head -1 | awk '{print $2}' | tr -d '"' || echo "")
DB_SECRET=$(helm get values "${RELEASE}" -n "${NAMESPACE}" 2>/dev/null \
  | grep "dbSecret:" | head -1 | awk '{print $2}' | tr -d '"' || echo "")
DB_VENDOR=$(helm get values "${RELEASE}" -n "${NAMESPACE}" 2>/dev/null \
  | grep "dbVendor:" | head -1 | awk '{print $2}' | tr -d '"' || echo "DB2")
DB_DRIVERS=$(helm get values "${RELEASE}" -n "${NAMESPACE}" 2>/dev/null \
  | grep "dbDrivers:" | head -1 | awk '{print $2}' | tr -d '"' || echo "db2jcc4.jar")

# ── Generate upgrade values override file ────────────────────────────────────
UPGRADE_VALUES_FILE="s0-values-upgrade-${TARGET_APP_VERSION}-${TIMESTAMP}.yaml"
info "Generating upgrade values override file: ${UPGRADE_VALUES_FILE}..."

# Set upgrade flags based on upgrade type
if [[ "${DB_SCHEMA_CHANGE}" == "true" ]]; then
  SETUP_CFG_UPGRADE="true"
  DATA_SETUP_UPGRADE="true"
else
  SETUP_CFG_UPGRADE="false"
  DATA_SETUP_UPGRADE="false"
fi

cat > "${UPGRADE_VALUES_FILE}" <<EOF
# =============================================================================
# Helm upgrade override values
# Release       : ${RELEASE}
# Namespace     : ${NAMESPACE}
# From          : ${CURRENT_APP_VERSION}
# To            : ${TARGET_APP_VERSION}
# Upgrade type  : ${UPGRADE_TYPE}
# DB schema chg : ${DB_SCHEMA_CHANGE}
# Generated     : ${TIMESTAMP}
# =============================================================================

# ── Global image tag & license ────────────────────────────────────────────────
global:
  license: true
  image:
    tag: "${TARGET_APP_VERSION}"

# ── API frontend service — fg2https port (added in chart 3.2.0+) ─────────────
api:
  frontendService:
    ports:
      http:
        name: http
        port: 35005
        targetPort: http
        nodePort: 30005
        protocol: TCP
      https:
        name: https
        port: 35006
        targetPort: https
        nodePort: 30006
        protocol: TCP
      fg2https:
        name: fg2https
        port: 35009
        targetPort: fg2https
        nodePort: 30009
        protocol: TCP

# ── Component image tags ──────────────────────────────────────────────────────
dataSetup:
  image:
    tag: "${TARGET_APP_VERSION}"
  upgrade: ${DATA_SETUP_UPGRADE}

resourcesInit:
  image:
    tag: "${TARGET_APP_VERSION}"

purge:
  image:
    tag: "${TARGET_APP_VERSION}"

documentService:
  image:
    tag: "${TARGET_APP_VERSION}"

# ── Upgrade flags ─────────────────────────────────────────────────────────────
env:
  upgradeCompatibilityVerified: true

setupCfg:
  upgrade: ${SETUP_CFG_UPGRADE}
  # New fields introduced in chart 3.2.0+
  enableSfg2: false
  legacyApisAuthType: basic
  licenseAcceptEnableFileOperation: true

# ── Identity Service sub-chart (ibm-identity-service-prod, alias: identityService)
# Required by chart 3.2.0+. All fields set explicitly because --reuse-values
# does not inherit new sub-chart defaults when upgrading from older chart versions.
identityService:
  enabled: false
  license: true
  service:
    type: ClusterIP
    externalPort: 443
    nodePort:
    externalIP:
    loadBalancerIP:
    annotations: {}
  ingress:
    enabled: false
    host: ""
    tls:
      enabled: false
      secretName: ""
    controller: nginx
    annotations: {}
    labels: {}
  autoscaling:
    enabled: false
    minReplicas: 1
    maxReplicas: 2
    targetCPUUtilizationPercentage: 60
  application:
    dbVendor: "${DB_VENDOR}"
    dbHost: "${DB_HOST}"
    dbPort: ${DB_PORT}
    dbData: "${DB_DATA}"
    dbSecret: "${DB_SECRET}"
    dbUseSsl: false
    oracleUseServiceName: false
    mssqlTrustServerCertificate: true
    mssqlEncrypt: true
    clientApplicationName: b2bi
    corsAllowedOrigins: "*"
    clientSecret: identity-client-secret
    token:
      accessTokenExpire: 300
      refreshTokenExpire: 3600
    logging:
      level: ERROR
    server:
      port: 9443
      ssl:
        enabled: true
        skipSniValidation: true
        protocol: TLS
        enabledProtocols: "TLSv1.2,TLSv1.3"
      sessionCookieName: AUTH_SESSION_ID
EOF

success "Upgrade values file saved: ${UPGRADE_VALUES_FILE}"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}------------------------------------------------------------${NC}"
echo -e "${BOLD}  Upgrade Summary${NC}"
echo -e "${BOLD}------------------------------------------------------------${NC}"
echo -e "  Release          : ${CYAN}${RELEASE}${NC}"
echo -e "  Namespace        : ${CYAN}${NAMESPACE}${NC}"
echo -e "  Current version  : ${CYAN}${CURRENT_APP_VERSION}${NC} (chart ${CURRENT_CHART})"
echo -e "  Target version   : ${CYAN}${TARGET_APP_VERSION}${NC} (chart ibm-b2bi-prod-${TARGET_CHART_VERSION})"
echo -e "  Upgrade type     : ${CYAN}${UPGRADE_TYPE}${NC}"
echo -e "  DB schema change : ${CYAN}${DB_SCHEMA_CHANGE}${NC}"
echo -e "  Values backup    : ${CYAN}${BACKUP_FILE}${NC}"
echo -e "  Upgrade values   : ${CYAN}${UPGRADE_VALUES_FILE}${NC}"
echo -e "${BOLD}------------------------------------------------------------${NC}"

if [[ "${DB_SCHEMA_CHANGE}" == "true" ]]; then
  echo ""
  echo -e "${RED}${BOLD}  ⚠  DATABASE SCHEMA MIGRATION WILL RUN${NC}"
  echo -e "${RED}     Ensure a database backup exists before proceeding.${NC}"
  echo -e "${RED}     The upgrade job may take 15-60 minutes depending on data volume.${NC}"
fi

echo ""
read -rp "$(echo -e "${BOLD}Run dry-run first? [Y/n]:${NC} ")" DO_DRYRUN
DO_DRYRUN="${DO_DRYRUN:-Y}"

if [[ "${DO_DRYRUN,,}" == "y" || "${DO_DRYRUN,,}" == "yes" ]]; then
  echo ""
  info "Running helm upgrade dry-run..."
  if helm upgrade "${RELEASE}" ibm-helm/ibm-b2bi-prod \
    --version "${TARGET_CHART_VERSION}" \
    --namespace "${NAMESPACE}" \
    --reuse-values \
    -f "${UPGRADE_VALUES_FILE}" \
    --dry-run \
    2>&1 | tail -20; then
    success "Dry-run passed."
  else
    die "Dry-run failed. Review the errors above and fix the upgrade values file before retrying."
  fi
fi

# ── Final confirmation ────────────────────────────────────────────────────────
echo ""
read -rp "$(echo -e "${BOLD}Proceed with the actual upgrade? [y/N]:${NC} ")" CONFIRM
CONFIRM="${CONFIRM,,}"
[[ "${CONFIRM}" == "y" || "${CONFIRM}" == "yes" ]] || { info "Aborted by user."; exit 0; }

# ── Execute upgrade ───────────────────────────────────────────────────────────
echo ""
info "Executing helm upgrade..."
helm upgrade "${RELEASE}" ibm-helm/ibm-b2bi-prod \
  --version "${TARGET_CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --reuse-values \
  -f "${UPGRADE_VALUES_FILE}" \
  --timeout 90m \
  2>&1

success "Helm upgrade completed. Release revision: $(helm list -n "${NAMESPACE}" --filter "^${RELEASE}$" --output json | grep -o '"revision":"[^"]*"' | cut -d'"' -f4)"

# ── Post-upgrade pod health check ─────────────────────────────────────────────
echo ""
info "Waiting 30 seconds for pods to start rolling..."
sleep 30

echo ""
info "Pod status (checking every 60 s for up to 20 min)..."
for i in $(seq 1 20); do
  echo ""
  echo -e "${BOLD}--- Check ${i}/20 ---${NC}"
  ${CLI} get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep -v -E "Completed|purge" \
    | awk '{printf "  %-45s %-12s %-8s %s\n", $1, $3, $4, $5}'

  # Check if any pods are in bad state
  BAD_PODS=$(${CLI} get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep -v -E "Completed|purge|Running|PodInitializing|Init:" \
    | grep -v "^$" || true)

  ALL_READY=$(${CLI} get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep -v -E "Completed|purge" \
    | awk '{split($2,a,"/"); if(a[1]!=a[2]) print $1}' || true)

  if [[ -z "${ALL_READY}" && -z "${BAD_PODS}" ]]; then
    echo ""
    success "All pods are Ready! Upgrade complete."
    break
  fi

  if [[ -n "${BAD_PODS}" ]]; then
    warn "Pods in unexpected state:"
    echo "${BAD_PODS}" | awk '{print "  "$0}'
  fi

  if [[ $i -lt 20 ]]; then
    info "Waiting 60 s before next check..."
    sleep 60
  else
    warn "Timeout reached. Some pods may still be initialising."
    warn "Run: ${CLI} get pods -n ${NAMESPACE}"
  fi
done

# ── Final status ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}------------------------------------------------------------${NC}"
echo -e "${BOLD}  Final Status${NC}"
echo -e "${BOLD}------------------------------------------------------------${NC}"
helm list -n "${NAMESPACE}" --filter "^${RELEASE}$" 2>/dev/null
echo ""
echo -e "  To rollback if needed:"
echo -e "  ${CYAN}helm rollback ${RELEASE} -n ${NAMESPACE}${NC}"
echo -e ""
echo -e "  To restore from values backup:"
echo -e "  ${CYAN}helm upgrade ${RELEASE} ibm-helm/ibm-b2bi-prod --version <prev-chart> -f ${BACKUP_FILE} -n ${NAMESPACE}${NC}"
echo -e "${BOLD}------------------------------------------------------------${NC}"
echo ""

# Made with Bob
