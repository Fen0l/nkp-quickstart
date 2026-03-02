#!/usr/bin/env bash
set -uo pipefail
IFS=$'\n\t'

###############################################################################
#  NKP Management Cluster — Post-Deployment Health Check
#
#  Validates cluster health after 2_deploy.sh (or any time).
#  Checks: nodes, versions, pods, CAPI, CSI, networking, HelmReleases,
#  certificates, and platform apps.
#
#  Usage:
#    ./5_healthcheck.sh                 # standard checks
#    ./5_healthcheck.sh --full          # include pod-level detail
#    ./5_healthcheck.sh --json          # output summary as JSON
#    ./5_healthcheck.sh --watch         # re-run every 30s
#
#  Prerequisites:
#    - 2_deploy.sh completed successfully
#    - ${CLUSTER_NAME}.conf kubeconfig exists
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.json"

# Parse args
FULL_MODE=false
JSON_MODE=false
WATCH_MODE=false
for arg in "$@"; do
  case "$arg" in
    --full)  FULL_MODE=true ;;
    --json)  JSON_MODE=true ;;
    --watch) WATCH_MODE=true ;;
  esac
done

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()   { echo -e "  ${CYAN}[INFO]${NC} $1"; }
ok()     { echo -e "  ${GREEN}[OK]${NC}   $1"; }
warn()   { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
fail()   { echo -e "  ${RED}[FAIL]${NC} $1"; }
header() { echo -e "\n══════════════════════════════════════════════════════════\n  $1\n══════════════════════════════════════════════════════════"; }

# Counters
PASS=0; WARN_COUNT=0; FAIL_COUNT=0
count_pass() { ((PASS++)); }
count_warn() { ((WARN_COUNT++)); }
count_fail() { ((FAIL_COUNT++)); }


if [[ ! -f "$CONFIG_FILE" ]]; then
  fail "config.json not found."
  exit 1
fi

cfg() { jq -r "$1 // empty" "$CONFIG_FILE"; }

CLUSTER_NAME=$(cfg '.cluster.name')
CLUSTER_HOSTNAME=$(cfg '.cluster.hostname')
EXPECTED_CP=$(cfg '.nodes.control_plane.count')
EXPECTED_WORKERS=$(cfg '.nodes.worker.count')
EXPECTED_TOTAL=$((EXPECTED_CP + EXPECTED_WORKERS))

KUBECONFIG_FILE="${SCRIPT_DIR}/../${CLUSTER_NAME}.conf"
if [[ ! -f "$KUBECONFIG_FILE" ]]; then
  KUBECONFIG_FILE="${SCRIPT_DIR}/${CLUSTER_NAME}.conf"
fi
if [[ ! -f "$KUBECONFIG_FILE" ]]; then
  fail "Kubeconfig not found for ${CLUSTER_NAME}"
  exit 1
fi

export KUBECONFIG="$KUBECONFIG_FILE"

run_checks() {

# ═══════════════════════════════════════════════════════════════════════════
#  1. CLUSTER CONNECTIVITY
# ═══════════════════════════════════════════════════════════════════════════

header "1. Cluster Connectivity"

if kubectl cluster-info &>/dev/null; then
  ok "Cluster is reachable"
  count_pass
  CLUSTER_IP=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "unknown")
  info "API server: ${CLUSTER_IP}"
else
  fail "Cluster is unreachable — check kubeconfig and network"
  count_fail
  echo ""
  fail "Cannot continue health check. Aborting."
  return
fi

# ═══════════════════════════════════════════════════════════════════════════
#  2. VERSIONS
# ═══════════════════════════════════════════════════════════════════════════

header "2. Versions"

# Kubernetes version
K8S_VERSION_JSON=$(kubectl version -o json 2>/dev/null || echo '{}')
K8S_SERVER=$(echo "$K8S_VERSION_JSON" | jq -r '.serverVersion.gitVersion // "unknown"')
K8S_CLIENT=$(echo "$K8S_VERSION_JSON" | jq -r '.clientVersion.gitVersion // "unknown"')
info "Kubernetes server: ${K8S_SERVER}"
info "kubectl client:    ${K8S_CLIENT}"

# NKP version
NKP_VERSION="unknown"
if command -v nkp &>/dev/null; then
  NKP_VERSION_OUTPUT=$(nkp version 2>/dev/null || true)
  NKP_VERSION=$(echo "$NKP_VERSION_OUTPUT" | awk -F': ' '/^nkp:/{print $2}')
  NKP_VERSION=${NKP_VERSION:-unknown}
  KOMMANDER_VER=$(echo "$NKP_VERSION_OUTPUT" | awk -F': ' '/^kommander:/{print $2}')
  KONVOY_VER=$(echo "$NKP_VERSION_OUTPUT" | awk -F': ' '/^konvoy:/{print $2}')
  info "NKP CLI:           ${NKP_VERSION}"
  info "  Kommander:       ${KOMMANDER_VER:-unknown}"
  info "  Konvoy:          ${KONVOY_VER:-unknown}"
else
  warn "nkp CLI not found in PATH"
fi

# Helper: extract version tag from container image string
extract_version() { echo "$1" | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+[^ ]*' | tail -1; }

# CAPI version
CAPI_IMG=$(kubectl get deployment -n capi-system capi-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
CAPI_VERSION=$(extract_version "$CAPI_IMG")
CAPI_VERSION=${CAPI_VERSION:-unknown}
info "CAPI:              ${CAPI_VERSION}"

# CAPX version
CAPX_IMG=$(kubectl get deployment -n capx-system capx-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
CAPX_VERSION=$(extract_version "$CAPX_IMG")
CAPX_VERSION=${CAPX_VERSION:-unknown}
info "CAPX:              ${CAPX_VERSION}"

# Cilium version
CILIUM_IMG=$(kubectl get daemonset -n kube-system cilium -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
CILIUM_VERSION=$(extract_version "$CILIUM_IMG")
CILIUM_VERSION=${CILIUM_VERSION:-unknown}
info "Cilium:            ${CILIUM_VERSION}"

# CSI version
CSI_IMG=$(kubectl get deployment -n ntnx-system nutanix-csi-controller -o jsonpath='{.spec.template.spec.containers[?(@.name=="nutanix-csi-plugin")].image}' 2>/dev/null || true)
CSI_VERSION=$(extract_version "$CSI_IMG")
CSI_VERSION=${CSI_VERSION:-unknown}
info "Nutanix CSI:       ${CSI_VERSION}"

ok "Version info collected"
count_pass

# ═══════════════════════════════════════════════════════════════════════════
#  3. NODE STATUS
# ═══════════════════════════════════════════════════════════════════════════

header "3. Node Status"

TOTAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true)
NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -v ' Ready' || true)

CP_NODES=$(kubectl get nodes --no-headers -l node-role.kubernetes.io/control-plane 2>/dev/null | wc -l)
WORKER_NODES=$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' 2>/dev/null | wc -l)

info "Total nodes:       ${TOTAL_NODES} (expected ${EXPECTED_TOTAL})"
info "Control plane:     ${CP_NODES} (expected ${EXPECTED_CP})"
info "Workers:           ${WORKER_NODES} (expected ${EXPECTED_WORKERS})"

if [[ "$TOTAL_NODES" -eq "$EXPECTED_TOTAL" && "$READY_NODES" -eq "$EXPECTED_TOTAL" ]]; then
  ok "All ${TOTAL_NODES} nodes Ready"
  count_pass
elif [[ "$READY_NODES" -eq "$TOTAL_NODES" && "$TOTAL_NODES" -ne "$EXPECTED_TOTAL" ]]; then
  warn "All nodes Ready but count mismatch: ${TOTAL_NODES}/${EXPECTED_TOTAL}"
  count_warn
else
  fail "${READY_NODES}/${TOTAL_NODES} nodes Ready (expected ${EXPECTED_TOTAL})"
  count_fail
  if [[ -n "$NOT_READY" ]]; then
    echo ""
    echo "$NOT_READY" | while read -r line; do
      echo "    $line"
    done
  fi
fi

# Node resource pressure
PRESSURE_NODES=$(kubectl get nodes -o json 2>/dev/null | jq -r '
  .items[] | select(
    .status.conditions[] | select(
      (.type == "MemoryPressure" or .type == "DiskPressure" or .type == "PIDPressure")
      and .status == "True"
    )
  ) | .metadata.name' 2>/dev/null || true)

if [[ -z "$PRESSURE_NODES" ]]; then
  ok "No resource pressure on any node"
  count_pass
else
  warn "Resource pressure detected:"
  count_warn
  echo "$PRESSURE_NODES" | while read -r node; do
    echo "    - $node"
  done
fi

# Show node table
if [[ "$FULL_MODE" == "true" ]]; then
  echo ""
  kubectl get nodes -o wide 2>/dev/null
fi

# ═══════════════════════════════════════════════════════════════════════════
#  4. CAPI & NUTANIX INFRASTRUCTURE
# ═══════════════════════════════════════════════════════════════════════════

header "4. CAPI & Nutanix Infrastructure"

# --- Cluster CR ---
CLUSTER_CR=$(kubectl get clusters.cluster.x-k8s.io -A --no-headers 2>/dev/null | head -1 || true)
if [[ -n "$CLUSTER_CR" ]]; then
  CLUSTER_CR_NAME=$(echo "$CLUSTER_CR" | awk '{print $2}')
  CLUSTER_CR_PHASE=$(echo "$CLUSTER_CR" | awk '{print $4}')
  CLUSTER_CR_CLASS=$(echo "$CLUSTER_CR" | awk '{print $3}')
  CLUSTER_CR_VER=$(echo "$CLUSTER_CR" | awk '{print $6}')
  if [[ "$CLUSTER_CR_PHASE" == "Provisioned" ]]; then
    ok "Cluster CR: ${CLUSTER_CR_NAME} (${CLUSTER_CR_PHASE})"
    count_pass
  else
    warn "Cluster CR: ${CLUSTER_CR_NAME} (${CLUSTER_CR_PHASE})"
    count_warn
  fi
  info "  ClusterClass: ${CLUSTER_CR_CLASS}"
  info "  K8s version:  ${CLUSTER_CR_VER}"
else
  warn "No CAPI Cluster CR found"
  count_warn
fi

# --- ClusterClass ---
CC_COUNT=$(kubectl get clusterclasses.cluster.x-k8s.io -A --no-headers 2>/dev/null | wc -l)
if [[ "$CC_COUNT" -gt 0 ]]; then
  info "ClusterClasses: ${CC_COUNT}"
  if [[ "$FULL_MODE" == "true" ]]; then
    kubectl get clusterclasses.cluster.x-k8s.io -A --no-headers 2>/dev/null | awk '{printf "    %-30s %s\n", $2, $1}'
  fi
fi

# --- KubeadmControlPlane ---
KCP_JSON=$(kubectl get kubeadmcontrolplanes.controlplane.cluster.x-k8s.io -A -o json 2>/dev/null || echo '{"items":[]}')
KCP_COUNT=$(echo "$KCP_JSON" | jq '.items | length')
if [[ "$KCP_COUNT" -gt 0 ]]; then
  KCP_NAME=$(echo "$KCP_JSON" | jq -r '.items[0].metadata.name')
  KCP_REPLICAS=$(echo "$KCP_JSON" | jq -r '.items[0].status.replicas // 0')
  KCP_READY=$(echo "$KCP_JSON" | jq -r '.items[0].status.readyReplicas // 0')
  KCP_UPDATED=$(echo "$KCP_JSON" | jq -r '.items[0].status.updatedReplicas // 0')
  KCP_UNAVAIL=$(echo "$KCP_JSON" | jq -r '.items[0].status.unavailableReplicas // 0')
  KCP_INIT=$(echo "$KCP_JSON" | jq -r '.items[0].status.initialized // false')
  KCP_API=$(echo "$KCP_JSON" | jq -r '(.items[0].status.conditions[] | select(.type=="Available") | .status) // "unknown"')
  KCP_VER=$(echo "$KCP_JSON" | jq -r '.items[0].spec.version // "unknown"')

  if [[ "$KCP_READY" == "$KCP_REPLICAS" && "$KCP_INIT" == "true" ]]; then
    ok "KubeadmControlPlane: ${KCP_READY}/${KCP_REPLICAS} Ready, API available"
    count_pass
  else
    warn "KubeadmControlPlane: ${KCP_READY}/${KCP_REPLICAS} Ready (init=${KCP_INIT})"
    count_warn
  fi
  info "  Name:    ${KCP_NAME}"
  info "  Version: ${KCP_VER}"
  if [[ "$KCP_UNAVAIL" -gt 0 ]] 2>/dev/null; then
    warn "  Unavailable: ${KCP_UNAVAIL}"
    count_warn
  fi
else
  info "No KubeadmControlPlane found"
fi

# --- MachineDeployment ---
MD=$(kubectl get machinedeployments.cluster.x-k8s.io -A --no-headers 2>/dev/null || true)
if [[ -n "$MD" ]]; then
  MD_COUNT=$(echo "$MD" | wc -l)
  info "MachineDeployments: ${MD_COUNT}"
  echo "$MD" | while IFS= read -r line; do
    MD_NAME=$(echo "$line" | awk '{print $2}')
    MD_REPLICAS=$(echo "$line" | awk '{print $4}')
    MD_READY_N=$(echo "$line" | awk '{print $5}')
    MD_UNAVAIL=$(echo "$line" | awk '{print $7}')
    MD_PHASE=$(echo "$line" | awk '{print $8}')
    MD_VER=$(echo "$line" | awk '{print $10}')
    if [[ "$MD_READY_N" == "$MD_REPLICAS" && "$MD_PHASE" == "Running" ]]; then
      ok "  ${MD_NAME}: ${MD_READY_N}/${MD_REPLICAS} Ready (${MD_PHASE}) ${MD_VER}"
      count_pass
    else
      warn "  ${MD_NAME}: ${MD_READY_N}/${MD_REPLICAS} Ready (${MD_PHASE}) ${MD_VER}"
      count_warn
    fi
  done
else
  info "No MachineDeployments found"
fi

# --- MachineSet ---
MS=$(kubectl get machinesets.cluster.x-k8s.io -A --no-headers 2>/dev/null || true)
if [[ -n "$MS" ]]; then
  MS_COUNT=$(echo "$MS" | wc -l)
  MS_LINE=$(echo "$MS" | head -1)
  MS_NAME=$(echo "$MS_LINE" | awk '{print $2}')
  MS_REPLICAS=$(echo "$MS_LINE" | awk '{print $4}')
  MS_READY=$(echo "$MS_LINE" | awk '{print $5}')
  MS_AVAIL=$(echo "$MS_LINE" | awk '{print $6}')
  if [[ "$MS_READY" == "$MS_REPLICAS" ]]; then
    ok "MachineSet: ${MS_NAME} (${MS_READY}/${MS_REPLICAS} Ready)"
    count_pass
  else
    warn "MachineSet: ${MS_NAME} (${MS_READY}/${MS_REPLICAS} Ready)"
    count_warn
  fi
fi

# --- Machines ---
TOTAL_MACHINES=$(kubectl get machines.cluster.x-k8s.io -A --no-headers 2>/dev/null | wc -l)
RUNNING_MACHINES=$(kubectl get machines.cluster.x-k8s.io -A --no-headers 2>/dev/null | grep -c 'Running' || true)

if [[ "$RUNNING_MACHINES" -eq "$EXPECTED_TOTAL" ]]; then
  ok "Machines: ${RUNNING_MACHINES}/${EXPECTED_TOTAL} Running"
  count_pass
elif [[ "$TOTAL_MACHINES" -eq 0 ]]; then
  warn "No CAPI Machines found"
  count_warn
else
  NON_RUNNING=$(kubectl get machines.cluster.x-k8s.io -A --no-headers 2>/dev/null | grep -v 'Running' || true)
  if [[ -n "$NON_RUNNING" ]]; then
    warn "Machines: ${RUNNING_MACHINES}/${TOTAL_MACHINES} Running"
    count_warn
    echo "$NON_RUNNING" | awk '{printf "    %-50s %s\n", $2, $5}'
  else
    ok "Machines: ${RUNNING_MACHINES}/${TOTAL_MACHINES} Running"
    count_pass
  fi
fi

# --- MachineHealthCheck ---
MHC=$(kubectl get machinehealthchecks.cluster.x-k8s.io -A --no-headers 2>/dev/null || true)
if [[ -n "$MHC" ]]; then
  MHC_COUNT=$(echo "$MHC" | wc -l)
  ALL_HEALTHY=true
  echo "$MHC" | while IFS= read -r line; do
    MHC_NAME=$(echo "$line" | awk '{print $2}')
    MHC_EXPECTED=$(echo "$line" | awk '{print $4}')
    MHC_MAXUNHEALTHY=$(echo "$line" | awk '{print $5}')
    MHC_HEALTHY=$(echo "$line" | awk '{print $6}')
    if [[ "$MHC_HEALTHY" == "$MHC_EXPECTED" ]]; then
      ok "MachineHealthCheck: ${MHC_NAME} (${MHC_HEALTHY}/${MHC_EXPECTED} healthy, max-unhealthy=${MHC_MAXUNHEALTHY})"
      count_pass
    else
      warn "MachineHealthCheck: ${MHC_NAME} (${MHC_HEALTHY}/${MHC_EXPECTED} healthy, max-unhealthy=${MHC_MAXUNHEALTHY})"
      count_warn
    fi
  done
else
  info "No MachineHealthChecks found"
fi

# --- NutanixCluster ---
NTNX_CLUSTER=$(kubectl get nutanixclusters.infrastructure.cluster.x-k8s.io -A --no-headers 2>/dev/null | head -1 || true)
if [[ -n "$NTNX_CLUSTER" ]]; then
  NTNX_CL_NAME=$(echo "$NTNX_CLUSTER" | awk '{print $2}')
  NTNX_CL_ENDPOINT=$(echo "$NTNX_CLUSTER" | awk '{print $3}')
  NTNX_CL_READY=$(echo "$NTNX_CLUSTER" | awk '{print $4}')
  if [[ "$NTNX_CL_READY" == "true" ]]; then
    ok "NutanixCluster: ${NTNX_CL_NAME} (Ready, endpoint=${NTNX_CL_ENDPOINT})"
    count_pass
  else
    warn "NutanixCluster: ${NTNX_CL_NAME} (Ready=${NTNX_CL_READY}, endpoint=${NTNX_CL_ENDPOINT})"
    count_warn
  fi
fi

# --- NutanixMachines ---
NM_TOTAL=$(kubectl get nutanixmachines.infrastructure.cluster.x-k8s.io -A --no-headers 2>/dev/null | wc -l)
NM_READY=$(kubectl get nutanixmachines.infrastructure.cluster.x-k8s.io -A --no-headers 2>/dev/null | awk '$4 == "true"' | wc -l)
if [[ "$NM_TOTAL" -gt 0 ]]; then
  if [[ "$NM_READY" -eq "$NM_TOTAL" ]]; then
    ok "NutanixMachines: ${NM_READY}/${NM_TOTAL} Ready"
    count_pass
  else
    warn "NutanixMachines: ${NM_READY}/${NM_TOTAL} Ready"
    count_warn
    kubectl get nutanixmachines.infrastructure.cluster.x-k8s.io -A --no-headers 2>/dev/null | awk '$4 != "true" {printf "    %-50s IP=%s Ready=%s\n", $2, $3, $4}'
  fi
  if [[ "$FULL_MODE" == "true" ]]; then
    echo ""
    info "NutanixMachine details:"
    kubectl get nutanixmachines.infrastructure.cluster.x-k8s.io -A --no-headers 2>/dev/null | \
      awk '{printf "    %-50s IP=%-15s Ready=%-5s %s\n", $2, $3, $4, $5}'
  fi
fi

# --- NutanixFailureDomains ---
NFD_COUNT=$(kubectl get nutanixfailuredomains.infrastructure.cluster.x-k8s.io -A --no-headers 2>/dev/null | wc -l)
if [[ "$NFD_COUNT" -gt 0 ]]; then
  info "NutanixFailureDomains: ${NFD_COUNT}"
fi

# --- ClusterResourceSets ---
CRS=$(kubectl get clusterresourcesets.addons.cluster.x-k8s.io -A --no-headers 2>/dev/null || true)
if [[ -n "$CRS" ]]; then
  CRS_COUNT=$(echo "$CRS" | wc -l)
  info "ClusterResourceSets: ${CRS_COUNT}"
  if [[ "$FULL_MODE" == "true" ]]; then
    echo "$CRS" | awk '{printf "    %-40s %s\n", $2, $1}'
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
#  5. POD HEALTH
# ═══════════════════════════════════════════════════════════════════════════

header "5. Pod Health"

TOTAL_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l)
RUNNING_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | grep -cE 'Running|Completed' || true)
PROBLEM_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | grep -vE 'Running|Completed' || true)
PROBLEM_COUNT=$(echo "$PROBLEM_PODS" | grep -c . 2>/dev/null || true)
[[ -z "$PROBLEM_PODS" ]] && PROBLEM_COUNT=0

info "Total pods: ${TOTAL_PODS}"

if [[ "$PROBLEM_COUNT" -eq 0 ]]; then
  ok "All pods Running/Completed"
  count_pass
else
  warn "${PROBLEM_COUNT} pod(s) not Running/Completed:"
  count_warn
  echo ""
  # Group by status
  echo "$PROBLEM_PODS" | awk '{printf "    %-50s %-25s %s\n", $2, $1, $4}'
fi

# Pods with high restart counts
HIGH_RESTARTS=$(kubectl get pods -A --no-headers 2>/dev/null | awk '$5 > 5 {print}' || true)
if [[ -n "$HIGH_RESTARTS" ]]; then
  echo ""
  warn "Pods with >5 restarts:"
  count_warn
  echo "$HIGH_RESTARTS" | awk '{printf "    %-50s %-25s restarts=%s\n", $2, $1, $5}'
else
  ok "No pods with excessive restarts"
  count_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
#  6. CONTROL PLANE COMPONENTS
# ═══════════════════════════════════════════════════════════════════════════

header "6. Control Plane Components"

for COMPONENT in etcd kube-apiserver kube-controller-manager kube-scheduler; do
  COUNT=$(kubectl get pods -n kube-system -l "component=${COMPONENT}" --no-headers 2>/dev/null | grep -c 'Running' || true)
  if [[ "$COUNT" -eq "$EXPECTED_CP" ]]; then
    ok "${COMPONENT}: ${COUNT}/${EXPECTED_CP} Running"
    count_pass
  elif [[ "$COUNT" -gt 0 ]]; then
    warn "${COMPONENT}: ${COUNT}/${EXPECTED_CP} Running"
    count_warn
  else
    fail "${COMPONENT}: not found"
    count_fail
  fi
done

# etcd cluster health (if etcdctl is available on nodes)
ETCD_PODS=$(kubectl get pods -n kube-system -l component=etcd --no-headers 2>/dev/null | awk '{print $1}' | head -1)
if [[ -n "$ETCD_PODS" ]]; then
  ETCD_MEMBERS=$(kubectl exec -n kube-system "$ETCD_PODS" -- etcdctl \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/peer.crt \
    --key=/etc/kubernetes/pki/etcd/peer.key \
    member list -w table 2>/dev/null || true)
  if [[ -n "$ETCD_MEMBERS" ]]; then
    ETCD_MEMBER_COUNT=$(echo "$ETCD_MEMBERS" | grep -c 'started' || true)
    if [[ "$ETCD_MEMBER_COUNT" -eq "$EXPECTED_CP" ]]; then
      ok "etcd cluster: ${ETCD_MEMBER_COUNT} members healthy"
      count_pass
    else
      warn "etcd cluster: ${ETCD_MEMBER_COUNT}/${EXPECTED_CP} members"
      count_warn
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
#  7. NETWORKING
# ═══════════════════════════════════════════════════════════════════════════

header "7. Networking"

# Cilium
CILIUM_READY=$(kubectl get daemonset -n kube-system cilium --no-headers 2>/dev/null | awk '{print $4}' || echo "0")
CILIUM_DESIRED=$(kubectl get daemonset -n kube-system cilium --no-headers 2>/dev/null | awk '{print $2}' || echo "0")
if [[ "$CILIUM_READY" -eq "$CILIUM_DESIRED" && "$CILIUM_READY" -gt 0 ]]; then
  ok "Cilium: ${CILIUM_READY}/${CILIUM_DESIRED} Ready"
  count_pass
elif [[ "$CILIUM_DESIRED" == "0" ]]; then
  # Might be using Calico (pre-2.17)
  CALICO_READY=$(kubectl get daemonset -n kube-system calico-node --no-headers 2>/dev/null | awk '{print $4}' || echo "0")
  if [[ "$CALICO_READY" -gt 0 ]]; then
    ok "Calico: ${CALICO_READY} Ready (pre-2.17 CNI)"
    count_pass
  else
    fail "No CNI daemonset found (cilium or calico-node)"
    count_fail
  fi
else
  warn "Cilium: ${CILIUM_READY}/${CILIUM_DESIRED} Ready"
  count_warn
fi

# CoreDNS
COREDNS_READY=$(kubectl get deployment -n kube-system coredns --no-headers 2>/dev/null | awk '{print $2}' || echo "0/0")
if echo "$COREDNS_READY" | grep -qE '^[0-9]+/[0-9]+$'; then
  COREDNS_AVAIL=$(echo "$COREDNS_READY" | cut -d/ -f1)
  COREDNS_TOTAL=$(echo "$COREDNS_READY" | cut -d/ -f2)
  if [[ "$COREDNS_AVAIL" -eq "$COREDNS_TOTAL" && "$COREDNS_AVAIL" -gt 0 ]]; then
    ok "CoreDNS: ${COREDNS_READY} Ready"
    count_pass
  else
    warn "CoreDNS: ${COREDNS_READY}"
    count_warn
  fi
fi

# MetalLB try both naming conventions (NKE to NKP baby)
METALLB_DS=$(kubectl get daemonset -n metallb-system --no-headers 2>/dev/null | head -1 || true)
if [[ -n "$METALLB_DS" ]]; then
  METALLB_DS_NAME=$(echo "$METALLB_DS" | awk '{print $1}')
  METALLB_DESIRED=$(echo "$METALLB_DS" | awk '{print $2}')
  METALLB_READY=$(echo "$METALLB_DS" | awk '{print $4}')
  ok "MetalLB ${METALLB_DS_NAME}: ${METALLB_READY}/${METALLB_DESIRED} Ready"
  count_pass
  METALLB_CTRL=$(kubectl get deployment -n metallb-system --no-headers 2>/dev/null | head -1 | awk '{print $1, $2}' || true)
  if [[ -n "$METALLB_CTRL" ]]; then
    info "MetalLB controller: ${METALLB_CTRL}"
  fi
  # Show IP pool allocation
  METALLB_IPS=$(kubectl get ipaddresspools -n metallb-system -o jsonpath='{.items[*].spec.addresses[*]}' 2>/dev/null || true)
  if [[ -n "$METALLB_IPS" ]]; then
    info "MetalLB IP pool: ${METALLB_IPS}"
  fi
else
  warn "MetalLB not found in metallb-system namespace"
  count_warn
fi

# Traefik
TRAEFIK_STATUS=$(kubectl get pods -n kommander -l app.kubernetes.io/name=traefik --no-headers 2>/dev/null | head -1 | awk '{print $3}' || echo "not found")
TRAEFIK_IP=$(kubectl get svc -n kommander kommander-traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "none")
if [[ "$TRAEFIK_STATUS" == "Running" ]]; then
  ok "Traefik: Running (LB IP: ${TRAEFIK_IP})"
  count_pass
elif [[ "$TRAEFIK_STATUS" == "not found" ]]; then
  info "Traefik not found (Kommander not fully installed)"
else
  warn "Traefik: ${TRAEFIK_STATUS}"
  count_warn
fi

# ═══════════════════════════════════════════════════════════════════════════
#  8. STORAGE
# ═══════════════════════════════════════════════════════════════════════════

header "8. Storage"

# CSI driver
CSI_PODS=$(kubectl get pods -n ntnx-system -l app=nutanix-csi-controller --no-headers 2>/dev/null | grep -c 'Running' || true)
if [[ "$CSI_PODS" -gt 0 ]]; then
  ok "Nutanix CSI controller: ${CSI_PODS} pod(s) Running"
  count_pass
else
  warn "Nutanix CSI controller not running"
  count_warn
fi

CSI_NODE_PODS=$(kubectl get daemonset -n ntnx-system nutanix-csi-node --no-headers 2>/dev/null | awk '{print $4 "/" $2}' || echo "not found")
if [[ "$CSI_NODE_PODS" != "not found" ]]; then
  ok "Nutanix CSI node: ${CSI_NODE_PODS} Ready"
  count_pass
fi

# StorageClasses
DEFAULT_SC=$(kubectl get sc -o json 2>/dev/null | jq -r '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true") | .metadata.name' || true)
SC_COUNT=$(kubectl get sc --no-headers 2>/dev/null | wc -l)
info "StorageClasses: ${SC_COUNT} total"
if [[ -n "$DEFAULT_SC" ]]; then
  ok "Default StorageClass: ${DEFAULT_SC}"
  count_pass
else
  warn "No default StorageClass set"
  count_warn
fi

# PVC status
PVC_BOUND=$(kubectl get pvc -A --no-headers 2>/dev/null | grep -c 'Bound' || true)
PVC_PENDING=$(kubectl get pvc -A --no-headers 2>/dev/null | grep -c 'Pending' || true)
if [[ "$PVC_PENDING" -gt 0 ]]; then
  warn "PVCs: ${PVC_BOUND} Bound, ${PVC_PENDING} Pending"
  count_warn
  kubectl get pvc -A --no-headers 2>/dev/null | grep 'Pending' | awk '{printf "    %-40s %-30s %s\n", $2, $1, $4}'
elif [[ "$PVC_BOUND" -gt 0 ]]; then
  ok "PVCs: ${PVC_BOUND} Bound, 0 Pending"
  count_pass
else
  info "No PVCs in cluster"
fi

# ═══════════════════════════════════════════════════════════════════════════
#  9. HELMRELEASES (Kommander / Flux)
# ═══════════════════════════════════════════════════════════════════════════

header "9. HelmReleases"

if kubectl get crd helmreleases.helm.toolkit.fluxcd.io &>/dev/null; then
  # Column order: NAMESPACE NAME AGE READY STATUS...
  #               $1        $2   $3  $4    $5+
  HR_TOTAL=$(kubectl get helmreleases -A --no-headers 2>/dev/null | wc -l)
  HR_READY=$(kubectl get helmreleases -A --no-headers 2>/dev/null | awk '$4 == "True"' | wc -l)
  HR_NOT_READY=$(kubectl get helmreleases -A --no-headers 2>/dev/null | awk '$4 != "True"' || true)
  HR_NOT_READY_COUNT=$((HR_TOTAL - HR_READY))

  info "HelmReleases: ${HR_TOTAL} total"

  if [[ "$HR_NOT_READY_COUNT" -eq 0 && "$HR_TOTAL" -gt 0 ]]; then
    ok "All ${HR_READY} HelmReleases Ready"
    count_pass
  elif [[ "$HR_NOT_READY_COUNT" -gt 0 ]]; then
    fail "${HR_NOT_READY_COUNT} HelmRelease(s) not Ready:"
    count_fail
    echo ""
    echo "$HR_NOT_READY" | awk '{printf "    %-45s %-30s Ready=%-6s %s\n", $2, $1, $4, $5}'
  else
    info "No HelmReleases found (Kommander not installed yet)"
  fi
else
  info "HelmRelease CRD not found (Flux not deployed yet)"
fi

# ═══════════════════════════════════════════════════════════════════════════
#  10. CERTIFICATES
# ═══════════════════════════════════════════════════════════════════════════

header "10. Certificates"

if kubectl get crd certificates.cert-manager.io &>/dev/null; then
  CERT_TOTAL=$(kubectl get certificates -A --no-headers 2>/dev/null | wc -l)
  CERT_READY=$(kubectl get certificates -A --no-headers 2>/dev/null | awk '$3 == "True"' | wc -l)
  CERT_NOT_READY=$((CERT_TOTAL - CERT_READY))

  if [[ "$CERT_NOT_READY" -eq 0 && "$CERT_TOTAL" -gt 0 ]]; then
    ok "All ${CERT_TOTAL} certificates Ready"
    count_pass
  elif [[ "$CERT_NOT_READY" -gt 0 ]]; then
    warn "${CERT_NOT_READY} certificate(s) not Ready:"
    count_warn
    kubectl get certificates -A --no-headers 2>/dev/null | awk '$3 != "True" {printf "    %-40s %-30s\n", $2, $1}'
  else
    info "No cert-manager certificates found"
  fi

  # Check for certs expiring within 7 days
  EXPIRING=$(kubectl get certificates -A -o json 2>/dev/null | jq -r '
    .items[] | select(.status.notAfter) |
    select(
      (.status.notAfter | fromdateiso8601) < (now + 604800)
    ) | "\(.metadata.namespace)/\(.metadata.name) expires \(.status.notAfter)"
  ' 2>/dev/null || true)
  if [[ -n "$EXPIRING" ]]; then
    warn "Certificates expiring within 7 days:"
    count_warn
    echo "$EXPIRING" | while read -r line; do echo "    $line"; done
  else
    ok "No certificates expiring within 7 days"
    count_pass
  fi
else
  info "cert-manager CRD not found"
fi

# ═══════════════════════════════════════════════════════════════════════════
#  11. PLATFORM APPS (Kommander)
# ═══════════════════════════════════════════════════════════════════════════

header "11. Platform Apps"

if kubectl get namespace kommander &>/dev/null; then
  # Dashboard
  info "Dashboard access:"
  nkp get dashboard --kubeconfig="$KUBECONFIG_FILE" 2>/dev/null || \
    echo "    https://${CLUSTER_HOSTNAME}/ (could not auto-detect)"
  echo ""

  # Dex
  DEX_STATUS=$(kubectl get pods -n kommander -l app=dex --no-headers 2>/dev/null | head -1 | awk '{print $3}' || echo "not found")
  if [[ "$DEX_STATUS" == "Running" ]]; then
    ok "Dex: Running"
    count_pass
  else
    warn "Dex: ${DEX_STATUS}"
    count_warn
  fi

  # Kommander
  KOMMANDER_STATUS=$(kubectl get pods -n kommander -l app.kubernetes.io/name=kommander --no-headers 2>/dev/null | head -1 | awk '{print $3}' || echo "not found")
  if [[ "$KOMMANDER_STATUS" == "Running" ]]; then
    ok "Kommander: Running"
    count_pass
  else
    info "Kommander: ${KOMMANDER_STATUS}"
  fi

  # License
  LICENSE_JSON=$(kubectl get licenses -n kommander -o json 2>/dev/null || echo '{"items":[]}')
  LICENSE_COUNT=$(echo "$LICENSE_JSON" | jq '.items | length')
  if [[ "$LICENSE_COUNT" -gt 0 ]]; then
    LICENSE_NAME=$(echo "$LICENSE_JSON" | jq -r '.items[0].metadata.name')
    LICENSE_VALID=$(echo "$LICENSE_JSON" | jq -r '.items[0].status.valid // "unknown"')
    LICENSE_LEVEL=$(echo "$LICENSE_JSON" | jq -r '.items[0].status.dkpLevel // "unknown"')
    LICENSE_PRODUCT=$(echo "$LICENSE_JSON" | jq -r '.items[0].status.productName // "unknown"')
    LICENSE_CAPACITY=$(echo "$LICENSE_JSON" | jq -r '.items[0].status.clusterCapacity // 0')
    LICENSE_CORES=$(echo "$LICENSE_JSON" | jq -r '.items[0].status.coreCapacity // 0')

    if [[ "$LICENSE_VALID" == "true" ]]; then
      ok "License: ${LICENSE_NAME} (valid)"
      count_pass
    else
      fail "License: ${LICENSE_NAME} (INVALID)"
      count_fail
    fi
    info "  Product:    ${LICENSE_PRODUCT}"
    info "  Level:      ${LICENSE_LEVEL}"
    info "  Clusters:   ${LICENSE_CAPACITY} (0 = unlimited)"
    info "  Cores:      ${LICENSE_CORES} (0 = unlimited)"

    EXPECTED_LICENSE=$(jq -r '.license.type // empty' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -n "$EXPECTED_LICENSE" ]]; then
      EXPECTED_UPPER=$(echo "$EXPECTED_LICENSE" | tr '[:lower:]' '[:upper:]' | head -c1)$(echo "$EXPECTED_LICENSE" | cut -c2-)
      if [[ "${LICENSE_LEVEL,,}" != "${EXPECTED_LICENSE,,}" ]]; then
        warn "  Expected level '${EXPECTED_UPPER}' but got '${LICENSE_LEVEL}'"
        warn "  Apply the correct license: NKP_LICENSE=<jwt> envsubst < day2/00-license.yaml | kubectl apply -f -"
        count_warn
      fi
    fi
  else
    info "No license applied yet"
    info "Apply: NKP_LICENSE=<jwt> envsubst < day2/00-license.yaml | kubectl apply -f -"
  fi

  # Workspaces
  WS_COUNT=$(kubectl get workspaces.workspaces.kommander.mesosphere.io --no-headers 2>/dev/null | wc -l || true)
  info "Workspaces: ${WS_COUNT}"
  if [[ "$FULL_MODE" == "true" && "$WS_COUNT" -gt 0 ]]; then
    kubectl get workspaces.workspaces.kommander.mesosphere.io --no-headers 2>/dev/null | awk '{printf "    %-30s %s\n", $1, $2}' || true
  fi

else
  info "kommander namespace not found — run 3_install-kommander.sh"
fi

# ═══════════════════════════════════════════════════════════════════════════
#  12. NAMESPACE OVERVIEW
# ═══════════════════════════════════════════════════════════════════════════

if [[ "$FULL_MODE" == "true" ]]; then
  header "12. Namespace Pod Summary"
  echo ""
  printf "    ${BOLD}%-40s %6s %6s %6s${NC}\n" "NAMESPACE" "TOTAL" "READY" "OTHER"
  echo "    ────────────────────────────────────────────────────────────────"
  kubectl get pods -A --no-headers 2>/dev/null | awk '
  {
    ns=$1; status=$4
    total[ns]++
    if (status == "Running" || status == "Completed") ready[ns]++
    else other[ns]++
  }
  END {
    PROCINFO["sorted_in"] = "@ind_str_asc"
    for (ns in total)
      printf "    %-40s %6d %6d %6d\n", ns, total[ns], ready[ns]+0, other[ns]+0
  }'
fi

# ═══════════════════════════════════════════════════════════════════════════
#  SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

header "Health Check Summary"
echo ""
echo -e "  Cluster:   ${BOLD}${CLUSTER_NAME}${NC} (${CLUSTER_HOSTNAME})"
echo -e "  K8s:       ${K8S_SERVER}"
echo -e "  NKP:       ${NKP_VERSION}"
echo -e "  Nodes:     ${READY_NODES}/${EXPECTED_TOTAL} Ready"
echo ""
echo -e "  ${GREEN}PASS: ${PASS}${NC}  ${YELLOW}WARN: ${WARN_COUNT}${NC}  ${RED}FAIL: ${FAIL_COUNT}${NC}"
echo ""

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo -e "  ${RED}${BOLD}Status: UNHEALTHY${NC} — ${FAIL_COUNT} critical issue(s) found"
elif [[ "$WARN_COUNT" -gt 0 ]]; then
  echo -e "  ${YELLOW}${BOLD}Status: DEGRADED${NC} — ${WARN_COUNT} warning(s) found"
else
  echo -e "  ${GREEN}${BOLD}Status: HEALTHY${NC}"
fi
echo ""

# JSON output
if [[ "$JSON_MODE" == "true" ]]; then
  cat <<JSONEOF
{
  "cluster": "${CLUSTER_NAME}",
  "hostname": "${CLUSTER_HOSTNAME}",
  "kubernetes_version": "${K8S_SERVER}",
  "nkp_version": "${NKP_VERSION}",
  "capi_version": "${CAPI_VERSION}",
  "capx_version": "${CAPX_VERSION}",
  "cilium_version": "${CILIUM_VERSION}",
  "csi_version": "${CSI_VERSION}",
  "nodes_ready": ${READY_NODES:-0},
  "nodes_expected": ${EXPECTED_TOTAL},
  "pass": ${PASS},
  "warn": ${WARN_COUNT},
  "fail": ${FAIL_COUNT},
  "status": "$(if [[ "$FAIL_COUNT" -gt 0 ]]; then echo "unhealthy"; elif [[ "$WARN_COUNT" -gt 0 ]]; then echo "degraded"; else echo "healthy"; fi)"
}
JSONEOF
fi

} # end run_checks


if [[ "$WATCH_MODE" == "true" ]]; then
  while true; do
    clear
    echo -e "${DIM}$(date '+%Y-%m-%d %H:%M:%S') — Ctrl+C to stop${NC}"
    PASS=0; WARN_COUNT=0; FAIL_COUNT=0
    run_checks
    sleep 30
  done
else
  run_checks
fi
