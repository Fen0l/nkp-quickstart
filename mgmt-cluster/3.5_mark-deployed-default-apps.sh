#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

###############################################################################
#  NKP Management Cluster — Mark Default Apps as Deployed
#
#  Prevents the License Controller from re-creating disabled apps (Rook Ceph).
#  Run AFTER 3_install-kommander.sh and BEFORE 4_configure.sh.
#
#  What this does:
#    1. Annotates KommanderCluster to tell the License Controller that
#       Pro/Ultimate default apps have already been processed
#    2. Deletes Rook Ceph AppDeployments (disabled in kommander.yaml)
#    3. Waits for cleanup to complete
#
#  Without this, the License Controller "zombie" behavior re-installs
#  rook-ceph and rook-ceph-cluster even when kommander.yaml has
#  enabled: false, because Pro/Ultimate tiers expect these apps.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()   { echo -e "  ${CYAN}[INFO]${NC} $1"; }
ok()     { echo -e "  ${GREEN}[OK]${NC}   $1"; }
warn()   { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
fail()   { echo -e "  ${RED}[FAIL]${NC} $1"; }
header() { echo -e "\n══════════════════════════════════════════════════════════\n  $1\n══════════════════════════════════════════════════════════"; }

# ── Load config ──────────────────────────────────────────────────────────────

if [[ ! -f "$CONFIG_FILE" ]]; then
  fail "config.json not found."
  exit 1
fi

cfg() { jq -r "$1 // empty" "$CONFIG_FILE"; }

CLUSTER_NAME=$(cfg '.cluster.name')
LICENSE=$(cfg '.license.type')

KUBECONFIG_FILE="${SCRIPT_DIR}/../${CLUSTER_NAME}.conf"
if [[ ! -f "$KUBECONFIG_FILE" ]]; then
  fail "Kubeconfig not found: ${KUBECONFIG_FILE}"
  exit 1
fi
export KUBECONFIG="$KUBECONFIG_FILE"

header "Mark Default Apps as Deployed"
info "Cluster: ${CLUSTER_NAME}"
info "License: ${LICENSE}"

# ── Check cluster reachability ───────────────────────────────────────────────

if ! kubectl cluster-info &>/dev/null; then
  fail "Cluster unreachable."
  exit 1
fi
ok "Cluster reachable"

# ── Check KommanderCluster exists ────────────────────────────────────────────

if ! kubectl get kommandercluster host-cluster -n kommander &>/dev/null; then
  fail "KommanderCluster 'host-cluster' not found. Run 3_install-kommander.sh first."
  exit 1
fi
ok "KommanderCluster host-cluster found"

# ── Annotate KommanderCluster ────────────────────────────────────────────────

header "Annotating KommanderCluster"

kubectl annotate kommandercluster host-cluster -n kommander \
  kommander.d2iq.io/default-pro-app-deployments-created="true" --overwrite
ok "Annotated: default-pro-app-deployments-created=true"

kubectl annotate kommandercluster host-cluster -n kommander \
  kommander.d2iq.io/default-enterprise-app-deployments-created="true" --overwrite
ok "Annotated: default-enterprise-app-deployments-created=true"

# ── Delete disabled AppDeployments ───────────────────────────────────────────

header "Cleaning up disabled apps"

DISABLED_APPS=(rook-ceph rook-ceph-cluster)

for app in "${DISABLED_APPS[@]}"; do
  if kubectl get appdeployment "$app" -n kommander &>/dev/null; then
    kubectl delete appdeployment "$app" -n kommander
    ok "Deleted AppDeployment: ${app}"
  else
    info "AppDeployment ${app} not found (already clean)"
  fi
done

# ── Also clean up ai-navigator if disabled ───────────────────────────────────

if kubectl get appdeployment ai-navigator-app -n kommander &>/dev/null; then
  kubectl delete appdeployment ai-navigator-app -n kommander
  ok "Deleted AppDeployment: ai-navigator-app"
fi

# ── Verify ───────────────────────────────────────────────────────────────────

header "Verification"

echo ""
info "KommanderCluster annotations:"
kubectl get kommandercluster host-cluster -n kommander \
  -o jsonpath='{.metadata.annotations}' 2>/dev/null | python3 -m json.tool 2>/dev/null | grep -E "default.*deploy" || true
echo ""

REMAINING=$(kubectl get appdeployment -n kommander -o name 2>/dev/null | grep -cE "rook-ceph" || true)
if [[ "$REMAINING" -eq 0 ]]; then
  ok "No Rook Ceph AppDeployments remaining"
else
  warn "${REMAINING} Rook Ceph AppDeployment(s) still present — may take a moment to delete"
fi

echo ""
echo "  Next: ./4_configure.sh"
echo ""
