#!/usr/bin/env bash
# =============================================================================
# add-b2bi-hpa.sh
# Adds Horizontal Pod Autoscalers (HPAs) to an IBM Sterling B2Bi instance
# running on OpenShift / Kubernetes.
#
# Targets the three main B2Bi StatefulSets:
#   - <release>-asi-server  (Application Server Infrastructure)
#   - <release>-ac-server   (Application Container)
#   - <release>-api-server  (REST API Server)
#
# Usage:
#   chmod +x add-b2bi-hpa.sh
#   ./add-b2bi-hpa.sh
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# ── Dependency check ──────────────────────────────────────────────────────────
if command -v oc &>/dev/null; then
  CLI="oc"
elif command -v kubectl &>/dev/null; then
  CLI="kubectl"
else
  die "Neither 'oc' nor 'kubectl' found in PATH. Please install one and try again."
fi
info "Using CLI: ${CLI}"

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  IBM Sterling B2Bi — Horizontal Pod Autoscaler Setup${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""

# ── Prompt: Namespace ─────────────────────────────────────────────────────────
while true; do
  read -rp "$(echo -e "${BOLD}Namespace${NC} (e.g. ibm-b2bi-dev01-app): ")" NAMESPACE
  NAMESPACE="${NAMESPACE// /}"   # strip spaces
  [[ -n "${NAMESPACE}" ]] && break
  warn "Namespace cannot be empty. Please try again."
done

# Verify namespace exists
if ! ${CLI} get namespace "${NAMESPACE}" &>/dev/null; then
  die "Namespace '${NAMESPACE}' not found on the cluster. Check the name and try again."
fi
success "Namespace '${NAMESPACE}' found."

# ── Discover StatefulSets ─────────────────────────────────────────────────────
echo ""
info "Discovering Sterling B2Bi StatefulSets in namespace '${NAMESPACE}'..."

# Look for StatefulSets whose names end in -asi-server, -ac-server, -api-server
ASI_STS=$(${CLI} get statefulsets -n "${NAMESPACE}" \
  --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
  | grep -E '\-asi-server$' | head -1 || true)

AC_STS=$(${CLI} get statefulsets -n "${NAMESPACE}" \
  --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
  | grep -E '\-ac-server$' | head -1 || true)

API_STS=$(${CLI} get statefulsets -n "${NAMESPACE}" \
  --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
  | grep -E '\-api-server$' | head -1 || true)

# Allow user to confirm / override each name
echo ""
echo -e "${BOLD}StatefulSet names detected (press Enter to accept, or type a new name):${NC}"

read -rp "  ASI StatefulSet  [${ASI_STS:-NOT FOUND}]: " INPUT
ASI_STS="${INPUT:-${ASI_STS}}"
[[ -z "${ASI_STS}" ]] && die "ASI StatefulSet name is required."

read -rp "  AC  StatefulSet  [${AC_STS:-NOT FOUND}]: " INPUT
AC_STS="${INPUT:-${AC_STS}}"
[[ -z "${AC_STS}" ]] && die "AC StatefulSet name is required."

read -rp "  API StatefulSet  [${API_STS:-NOT FOUND}]: " INPUT
API_STS="${INPUT:-${API_STS}}"
[[ -z "${API_STS}" ]] && die "API StatefulSet name is required."

# ── Prompt: Min Replicas ──────────────────────────────────────────────────────
echo ""
while true; do
  read -rp "$(echo -e "${BOLD}Minimum replicas${NC} per HPA [default: 2]: ")" MIN_REPLICAS
  MIN_REPLICAS="${MIN_REPLICAS:-2}"
  if [[ "${MIN_REPLICAS}" =~ ^[1-9][0-9]*$ ]]; then
    break
  fi
  warn "Please enter a positive integer (e.g. 1, 2, 3)."
done

# ── Prompt: Max Replicas ──────────────────────────────────────────────────────
while true; do
  read -rp "$(echo -e "${BOLD}Maximum replicas${NC} per HPA [default: 4]: ")" MAX_REPLICAS
  MAX_REPLICAS="${MAX_REPLICAS:-4}"
  if [[ "${MAX_REPLICAS}" =~ ^[1-9][0-9]*$ ]] && (( MAX_REPLICAS >= MIN_REPLICAS )); then
    break
  fi
  warn "Max replicas must be a positive integer >= min replicas (${MIN_REPLICAS})."
done

# ── Prompt: CPU Threshold ─────────────────────────────────────────────────────
while true; do
  read -rp "$(echo -e "${BOLD}CPU utilisation threshold${NC} to trigger scale-out (%) [default: 70]: ")" CPU_THRESHOLD
  CPU_THRESHOLD="${CPU_THRESHOLD:-70}"
  if [[ "${CPU_THRESHOLD}" =~ ^[1-9][0-9]*$ ]] && (( CPU_THRESHOLD <= 100 )); then
    break
  fi
  warn "Please enter an integer between 1 and 100."
done

# ── Derive HPA names from namespace ──────────────────────────────────────────
# Strip trailing "-app" suffix if present, then use as prefix
HPA_PREFIX="${NAMESPACE%-app}"

ASI_HPA_NAME="${HPA_PREFIX}-asi-hpa"
AC_HPA_NAME="${HPA_PREFIX}-ac-hpa"
API_HPA_NAME="${HPA_PREFIX}-api-hpa"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}------------------------------------------------------------${NC}"
echo -e "${BOLD}  Configuration Summary${NC}"
echo -e "${BOLD}------------------------------------------------------------${NC}"
echo -e "  Namespace        : ${CYAN}${NAMESPACE}${NC}"
echo -e "  ASI StatefulSet  : ${CYAN}${ASI_STS}${NC}  →  HPA: ${ASI_HPA_NAME}"
echo -e "  AC  StatefulSet  : ${CYAN}${AC_STS}${NC}  →  HPA: ${AC_HPA_NAME}"
echo -e "  API StatefulSet  : ${CYAN}${API_STS}${NC}  →  HPA: ${API_HPA_NAME}"
echo -e "  Min replicas     : ${CYAN}${MIN_REPLICAS}${NC}"
echo -e "  Max replicas     : ${CYAN}${MAX_REPLICAS}${NC}"
echo -e "  CPU threshold    : ${CYAN}${CPU_THRESHOLD}%${NC}"
echo -e "${BOLD}------------------------------------------------------------${NC}"
echo ""
read -rp "$(echo -e "${BOLD}Proceed? [y/N]:${NC} ")" CONFIRM
CONFIRM="${CONFIRM,,}"   # lowercase
[[ "${CONFIRM}" == "y" || "${CONFIRM}" == "yes" ]] || { info "Aborted by user."; exit 0; }

# ── Generate and apply HPA manifest ──────────────────────────────────────────
echo ""
info "Generating HPA manifest..."

HPA_MANIFEST=$(cat <<EOF
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${ASI_HPA_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ibm-b2bi
    component: asi
    managed-by: sterling-deployer
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: StatefulSet
    name: ${ASI_STS}
  minReplicas: ${MIN_REPLICAS}
  maxReplicas: ${MAX_REPLICAS}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: ${CPU_THRESHOLD}
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 1
          periodSeconds: 120
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${AC_HPA_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ibm-b2bi
    component: ac
    managed-by: sterling-deployer
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: StatefulSet
    name: ${AC_STS}
  minReplicas: ${MIN_REPLICAS}
  maxReplicas: ${MAX_REPLICAS}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: ${CPU_THRESHOLD}
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 1
          periodSeconds: 120
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${API_HPA_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ibm-b2bi
    component: api
    managed-by: sterling-deployer
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: StatefulSet
    name: ${API_STS}
  minReplicas: ${MIN_REPLICAS}
  maxReplicas: ${MAX_REPLICAS}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: ${CPU_THRESHOLD}
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 1
          periodSeconds: 120
EOF
)

# Save manifest to file alongside the script
MANIFEST_FILE="hpa-${NAMESPACE}.yaml"
echo "${HPA_MANIFEST}" > "${MANIFEST_FILE}"
success "Manifest saved to: ${MANIFEST_FILE}"

# Apply to cluster
info "Applying HPAs to namespace '${NAMESPACE}'..."
echo "${HPA_MANIFEST}" | ${CLI} apply -f - -n "${NAMESPACE}"

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
info "Waiting 5 seconds for HPAs to initialise..."
sleep 5

echo ""
echo -e "${BOLD}HPA Status:${NC}"
${CLI} get hpa -n "${NAMESPACE}" \
  -o custom-columns="NAME:.metadata.name,REFERENCE:.spec.scaleTargetRef.name,MINPODS:.spec.minReplicas,MAXPODS:.spec.maxReplicas,REPLICAS:.status.currentReplicas,AGE:.metadata.creationTimestamp"

echo ""
success "Done! HPAs have been applied to namespace '${NAMESPACE}'."
echo -e "  Run ${CYAN}${CLI} get hpa -n ${NAMESPACE}${NC} to monitor scaling activity."
echo -e "  Run ${CYAN}${CLI} describe hpa <name> -n ${NAMESPACE}${NC} for detailed events."
echo ""

# Made with Bob
