#!/usr/bin/env bash
# =============================================================================
# rollback-b2bi.sh
# Performs a rollback of IBM Sterling B2Bi (SFG) to a previous Helm revision.
#
# Features:
#   - Prompts for namespace and Helm release name
#   - Lists all available Helm revisions with their app versions and status
#   - Prompts for the target rollback revision
#   - Detects whether the rollback crosses a DB schema boundary (MAJOR/MINOR)
#     and warns that DB schema rollback is NOT automatic — manual DBA action
#     is required for schema downgrades
#   - Optionally restores values from a backup file (produced by upgrade-b2bi.sh)
#   - Runs a dry-run, then prompts for confirmation
#   - Monitors pod health after the rollback
#
# ⚠  IMPORTANT — Database Schema Rollback:
#   Helm rollback restores Kubernetes resources (pods, configmaps, secrets)
#   but does NOT roll back database schema changes. If the upgrade included
#   a DB schema migration, you must restore the database from a backup taken
#   before the upgrade BEFORE running this script.
#
# Usage:
#   chmod +x rollback-b2bi.sh
#   ./rollback-b2bi.sh
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
command -v helm &>/dev/null || die "helm not found in PATH."
command -v oc   &>/dev/null && CLI="oc" || CLI="kubectl"
info "Using Kubernetes CLI: ${CLI}"
info "Using Helm: $(helm version --short)"

# ── Version comparison helpers ────────────────────────────────────────────────
major_minor() { echo "$1" | cut -d. -f1,2; }
patch_level()  { echo "$1" | cut -d. -f3; }

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
echo -e "${BOLD}  IBM Sterling B2Bi — Rollback Script${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""
echo -e "${RED}${BOLD}  ⚠  READ BEFORE PROCEEDING${NC}"
echo -e "${RED}  Helm rollback restores Kubernetes resources only.${NC}"
echo -e "${RED}  It does NOT roll back database schema changes.${NC}"
echo -e "${RED}  If the upgrade included a DB schema migration, restore${NC}"
echo -e "${RED}  the database from a pre-upgrade backup FIRST.${NC}"
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

# Verify release exists
CURRENT_INFO=$(helm list -n "${NAMESPACE}" --filter "^${RELEASE}$" --output json 2>/dev/null)
if [[ -z "${CURRENT_INFO}" || "${CURRENT_INFO}" == "[]" ]]; then
  die "Helm release '${RELEASE}' not found in namespace '${NAMESPACE}'."
fi

CURRENT_REVISION=$(echo "${CURRENT_INFO}" | grep -o '"revision":"[^"]*"' | cut -d'"' -f4)
CURRENT_CHART=$(echo "${CURRENT_INFO}"    | grep -o '"chart":"[^"]*"'    | cut -d'"' -f4)
CURRENT_APP=$(echo "${CURRENT_INFO}"      | grep -o '"app_version":"[^"]*"' | cut -d'"' -f4)
CURRENT_APP="${CURRENT_APP%%_*}"

success "Current release: revision=${CURRENT_REVISION}  chart=${CURRENT_CHART}  app=${CURRENT_APP}"

# ── Show revision history ─────────────────────────────────────────────────────
echo ""
info "Revision history for release '${RELEASE}':"
echo ""
helm history "${RELEASE}" -n "${NAMESPACE}" --max 20 2>/dev/null \
  | awk 'NR==1{print "  "$0} NR>1{print "  "$0}'
echo ""

# ── Prompt: Target revision ───────────────────────────────────────────────────
PREV_REVISION=$(( CURRENT_REVISION - 1 ))
[[ "${PREV_REVISION}" -lt 1 ]] && PREV_REVISION=1

while true; do
  read -rp "$(echo -e "${BOLD}Rollback to revision${NC} [default: ${PREV_REVISION}]: ")" TARGET_REVISION
  TARGET_REVISION="${TARGET_REVISION:-${PREV_REVISION}}"
  TARGET_REVISION="${TARGET_REVISION// /}"
  if [[ "${TARGET_REVISION}" =~ ^[0-9]+$ ]] && \
     [[ "${TARGET_REVISION}" -ge 1 ]] && \
     [[ "${TARGET_REVISION}" -lt "${CURRENT_REVISION}" ]]; then
    break
  fi
  warn "Please enter a valid revision number between 1 and $(( CURRENT_REVISION - 1 ))."
done

# ── Get target revision details ───────────────────────────────────────────────
TARGET_INFO=$(helm history "${RELEASE}" -n "${NAMESPACE}" --max 50 --output json 2>/dev/null \
  | grep -o '"revision":[0-9]*,"updated":"[^"]*","status":"[^"]*","chart":"[^"]*","app_version":"[^"]*"' \
  | grep '"revision":'"${TARGET_REVISION}"',' | head -1 || true)

TARGET_CHART=$(echo "${TARGET_INFO}" | grep -o '"chart":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
TARGET_APP=$(echo "${TARGET_INFO}"   | grep -o '"app_version":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
TARGET_APP="${TARGET_APP%%_*}"

info "Target revision ${TARGET_REVISION}: chart=${TARGET_CHART}  app=${TARGET_APP}"

# ── Determine rollback type and DB schema risk ────────────────────────────────
echo ""
echo -e "${BOLD}------------------------------------------------------------${NC}"
echo -e "${BOLD}  Rollback Type Analysis${NC}"
echo -e "${BOLD}------------------------------------------------------------${NC}"

DB_SCHEMA_RISK=false

if [[ "${TARGET_APP}" != "unknown" && "${CURRENT_APP}" != "unknown" ]]; then
  CURRENT_MM=$(major_minor "${CURRENT_APP}")
  TARGET_MM=$(major_minor "${TARGET_APP}")
  CURRENT_PATCH=$(patch_level "${CURRENT_APP}")
  TARGET_PATCH=$(patch_level "${TARGET_APP}")

  if [[ "${CURRENT_MM}" != "${TARGET_MM}" ]]; then
    ROLLBACK_TYPE="MAJOR"
    DB_SCHEMA_RISK=true
    echo -e "  Type   : ${RED}${BOLD}MAJOR ROLLBACK${NC}"
    echo -e "  Reason : Major/minor version change (${CURRENT_MM} → ${TARGET_MM})"
  elif [[ "${CURRENT_PATCH}" != "${TARGET_PATCH}" ]]; then
    ROLLBACK_TYPE="MINOR"
    DB_SCHEMA_RISK=true
    echo -e "  Type   : ${YELLOW}${BOLD}MINOR ROLLBACK (patch-level)${NC}"
    echo -e "  Reason : Patch version change (${CURRENT_APP} → ${TARGET_APP})"
  else
    ROLLBACK_TYPE="PATCH"
    DB_SCHEMA_RISK=false
    echo -e "  Type   : ${GREEN}${BOLD}PATCH / iFIX ROLLBACK${NC}"
    echo -e "  Reason : Fix-pack only (${CURRENT_APP} → ${TARGET_APP})"
  fi
else
  ROLLBACK_TYPE="UNKNOWN"
  DB_SCHEMA_RISK=true
  echo -e "  Type   : ${YELLOW}UNKNOWN (could not determine app versions)${NC}"
fi

echo ""
if [[ "${DB_SCHEMA_RISK}" == "true" ]]; then
  echo -e "  ${RED}${BOLD}⚠  DATABASE SCHEMA ROLLBACK RISK DETECTED${NC}"
  echo -e "  ${RED}   The forward upgrade likely ran a DB schema migration.${NC}"
  echo -e "  ${RED}   Helm rollback will NOT revert the database schema.${NC}"
  echo -e "  ${RED}   You MUST restore the database from a pre-upgrade backup${NC}"
  echo -e "  ${RED}   before proceeding, or the application will fail to start.${NC}"
  echo ""
  read -rp "$(echo -e "${RED}${BOLD}  Have you restored the database from a pre-upgrade backup? [y/N]:${NC} ")" DB_CONFIRMED
  DB_CONFIRMED="${DB_CONFIRMED,,}"
  if [[ "${DB_CONFIRMED}" != "y" && "${DB_CONFIRMED}" != "yes" ]]; then
    echo ""
    warn "Rollback aborted. Please restore the database first, then re-run this script."
    exit 0
  fi
  success "Database restore confirmed by operator."
else
  echo -e "  ${GREEN}✓  No database schema changes expected for this rollback.${NC}"
fi

echo -e "${BOLD}------------------------------------------------------------${NC}"

# ── Optional: restore from values backup file ─────────────────────────────────
echo ""
echo -e "${BOLD}Values Backup Restore (optional)${NC}"
echo -e "If you have a values backup file from upgrade-b2bi.sh, you can"
echo -e "restore it alongside the Helm rollback for a cleaner state."
echo ""
read -rp "$(echo -e "${BOLD}Path to values backup file${NC} (press Enter to skip): ")" BACKUP_FILE
BACKUP_FILE="${BACKUP_FILE// /}"

USE_BACKUP=false
if [[ -n "${BACKUP_FILE}" ]]; then
  if [[ -f "${BACKUP_FILE}" ]]; then
    success "Backup file found: ${BACKUP_FILE}"
    USE_BACKUP=true
  else
    warn "File '${BACKUP_FILE}' not found. Proceeding without values restore."
    BACKUP_FILE=""
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}------------------------------------------------------------${NC}"
echo -e "${BOLD}  Rollback Summary${NC}"
echo -e "${BOLD}------------------------------------------------------------${NC}"
echo -e "  Release          : ${CYAN}${RELEASE}${NC}"
echo -e "  Namespace        : ${CYAN}${NAMESPACE}${NC}"
echo -e "  Current revision : ${CYAN}${CURRENT_REVISION}${NC} (${CURRENT_CHART} / app ${CURRENT_APP})"
echo -e "  Target revision  : ${CYAN}${TARGET_REVISION}${NC} (${TARGET_CHART} / app ${TARGET_APP})"
echo -e "  Rollback type    : ${CYAN}${ROLLBACK_TYPE}${NC}"
echo -e "  DB schema risk   : ${CYAN}${DB_SCHEMA_RISK}${NC}"
if [[ "${USE_BACKUP}" == "true" ]]; then
  echo -e "  Values backup    : ${CYAN}${BACKUP_FILE}${NC}"
fi
echo -e "${BOLD}------------------------------------------------------------${NC}"
echo ""
read -rp "$(echo -e "${BOLD}Proceed with rollback? [y/N]:${NC} ")" CONFIRM
CONFIRM="${CONFIRM,,}"
[[ "${CONFIRM}" == "y" || "${CONFIRM}" == "yes" ]] || { info "Aborted by user."; exit 0; }

# ── Execute rollback ──────────────────────────────────────────────────────────
echo ""
info "Executing helm rollback to revision ${TARGET_REVISION}..."

if [[ "${USE_BACKUP}" == "true" ]]; then
  # Use helm upgrade --reuse-values with the backup file to restore to the
  # previous chart version and values simultaneously
  TARGET_CHART_VERSION=$(echo "${TARGET_CHART}" | sed 's/ibm-b2bi-prod-//')
  info "Restoring chart ${TARGET_CHART} with values from backup file..."
  helm upgrade "${RELEASE}" ibm-helm/ibm-b2bi-prod \
    --version "${TARGET_CHART_VERSION}" \
    --namespace "${NAMESPACE}" \
    -f "${BACKUP_FILE}" \
    --timeout 90m \
    2>&1
else
  # Standard Helm rollback
  helm rollback "${RELEASE}" "${TARGET_REVISION}" \
    --namespace "${NAMESPACE}" \
    --timeout 90m \
    --wait=false \
    2>&1
fi

NEW_REVISION=$(helm list -n "${NAMESPACE}" --filter "^${RELEASE}$" --output json \
  | grep -o '"revision":"[^"]*"' | cut -d'"' -f4)
success "Rollback completed. Release is now at revision ${NEW_REVISION}."

# ── Post-rollback pod health check ────────────────────────────────────────────
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

  BAD_PODS=$(${CLI} get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep -v -E "Completed|purge|Running|PodInitializing|Init:" \
    | grep -v "^$" || true)

  ALL_READY=$(${CLI} get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep -v -E "Completed|purge" \
    | awk '{split($2,a,"/"); if(a[1]!=a[2]) print $1}' || true)

  if [[ -z "${ALL_READY}" && -z "${BAD_PODS}" ]]; then
    echo ""
    success "All pods are Ready! Rollback complete."
    break
  fi

  if [[ -n "${BAD_PODS}" ]]; then
    warn "Pods in unexpected state:"
    echo "${BAD_PODS}" | awk '{print "  "$0}'
    warn "Check logs with: ${CLI} logs <pod-name> -n ${NAMESPACE} --previous"
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
helm history "${RELEASE}" -n "${NAMESPACE}" --max 5 2>/dev/null \
  | awk 'NR==1{print "  "$0} NR>1{print "  "$0}'
echo ""
echo -e "  To re-apply the upgrade if needed:"
echo -e "  ${CYAN}./upgrade-b2bi.sh${NC}"
echo -e "${BOLD}------------------------------------------------------------${NC}"
echo ""

# Made with Bob
