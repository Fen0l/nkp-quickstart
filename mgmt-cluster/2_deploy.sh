#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

###############################################################################
#  NKP Management Cluster — Deploy
#
#  Reads config.json and runs nkp create cluster nutanix with all flags.
#  Passwords are prompted at runtime or read from env vars.
#
#  Run 1_preflight.sh first to validate everything.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.json"

# Parse args
VERBOSE=false
for arg in "$@"; do
  case "$arg" in
    --verbose|-v) VERBOSE=true ;;
  esac
done

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()   { echo -e "  ${CYAN}[INFO]${NC} $1"; }
ok()     { echo -e "  ${GREEN}[OK]${NC}   $1"; }
warn()   { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
fail()   { echo -e "  ${RED}[FAIL]${NC} $1"; }
header() { echo -e "\n══════════════════════════════════════════════════════════\n  $1\n══════════════════════════════════════════════════════════"; }

# ── Load config ─────────────────────────────────────────────────────────────

header "Loading config"

if [[ ! -f "$CONFIG_FILE" ]]; then
  fail "config.json not found. Run configure.py first."
  exit 1
fi

if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
  fail "config.json is not valid JSON."
  exit 1
fi

cfg() { jq -r "$1 // empty" "$CONFIG_FILE"; }

# Read all config values
DEPLOYMENT_TYPE=$(cfg '.deployment_type')
AIRGAP_METHOD=$(cfg '.airgap_method')
CLUSTER_NAME=$(cfg '.cluster.name')
CLUSTER_HOSTNAME=$(cfg '.cluster.hostname')
EXTRA_SANS=$(cfg '.cluster.extra_sans')

NTX_ENDPOINT=$(cfg '.nutanix.endpoint')
NTX_PORT=$(cfg '.nutanix.port')
NTX_USER=$(cfg '.nutanix.username')
NTX_INSECURE=$(cfg '.nutanix.insecure')
NTX_TRUST_BUNDLE=$(cfg '.nutanix.additional_trust_bundle')
NTX_PE=$(cfg '.nutanix.prism_element_cluster')
NTX_SUBNET=$(cfg '.nutanix.subnet')
NTX_STORAGE=$(cfg '.nutanix.storage_container')

NET_VIP=$(cfg '.networking.control_plane_vip')
NET_LB=$(cfg '.networking.metallb_ip_range')
POD_CIDR=$(cfg '.networking.pod_cidr')
SVC_CIDR=$(cfg '.networking.service_cidr')

CP_COUNT=$(cfg '.nodes.control_plane.count')
CP_VCPUS=$(cfg '.nodes.control_plane.vcpus')
CP_MEM=$(cfg '.nodes.control_plane.memory_gb')
W_COUNT=$(cfg '.nodes.worker.count')
W_VCPUS=$(cfg '.nodes.worker.vcpus')
W_MEM=$(cfg '.nodes.worker.memory_gb')

NIB_IMAGE=$(cfg '.images.nib_image')
WORKER_IMAGE=$(cfg '.images.worker_image')

REG_MIRROR_URL=$(cfg '.registry.mirror_url')
REG_MIRROR_USER=$(cfg '.registry.mirror_username')
REG_MIRROR_CA=$(cfg '.registry.mirror_ca_cert_path')
REG_URL=$(cfg '.registry.registry_url')
REG_USER=$(cfg '.registry.registry_username')
REG_CA=$(cfg '.registry.ca_cert_path')

PROXY_HTTP=$(cfg '.proxy.http_proxy')
PROXY_HTTPS=$(cfg '.proxy.https_proxy')
PROXY_NO=$(cfg '.proxy.no_proxy')

SSH_USER=$(cfg '.options.ssh_username')
SSH_KEY=$(cfg '.options.ssh_public_key_file')
SELF_MANAGED=$(cfg '.options.self_managed')
CP_CATS=$(cfg '.options.cp_categories')
W_CATS=$(cfg '.options.worker_categories')
CSI_HV=$(cfg '.options.csi_hypervisor_attached')
CSI_FS=$(cfg '.options.csi_file_system')
KIND_IMAGE=$(cfg '.options.kind_cluster_image')
BUNDLE_DIR=$(cfg '.bundle_dir')

ok "Config loaded: ${CLUSTER_NAME} (${DEPLOYMENT_TYPE}${AIRGAP_METHOD:+, ${AIRGAP_METHOD}})"

# ── Credentials ─────────────────────────────────────────────────────────────

header "Credentials"

# Nutanix PC password (required by nkp via NUTANIX_USER / NUTANIX_PASSWORD env)
if [[ -n "${NUTANIX_PASSWORD:-}" ]]; then
  info "Using NUTANIX_PASSWORD from environment."
else
  read -rsp "  Prism Central password for ${NTX_USER}: " NUTANIX_PASSWORD < /dev/tty
  echo ""
fi
export NUTANIX_USER="$NTX_USER"
export NUTANIX_PASSWORD

# Registry passwords — only needed for external registry method
REG_MIRROR_PASS=""
REG_PASS=""

if [[ "$AIRGAP_METHOD" != "bundle" && -n "$REG_MIRROR_URL" ]]; then
  if [[ -n "${REGISTRY_MIRROR_PASSWORD:-}" ]]; then
    info "Using REGISTRY_MIRROR_PASSWORD from environment."
    REG_MIRROR_PASS="$REGISTRY_MIRROR_PASSWORD"
  else
    read -rsp "  Registry mirror password for ${REG_MIRROR_USER:-<none>} (Enter to skip): " REG_MIRROR_PASS < /dev/tty
    echo ""
  fi
fi

if [[ "$AIRGAP_METHOD" == "bundle" ]]; then
  info "Bundle mode: no registry credentials needed for cluster creation."
fi

# ── Pre-flight auth checks ────────────────────────────────────────────────

header "Auth pre-checks"

# Prism Central quick API call to verify creds before we spend 30 min deploying
AUTH_CURL=(-s --connect-timeout 10 --max-time 15)
[[ "$NTX_INSECURE" == "true" ]] && AUTH_CURL+=(-k)
PC_API="https://${NTX_ENDPOINT}:${NTX_PORT}/api"

PC_AUTH_OK=false
for api_path in \
  "/clustermgmt/v4.0.b2/config/clusters?\$limit=1" \
  "/clustermgmt/v4.0/config/clusters?\$limit=1"; do

  PC_CODE=$(curl "${AUTH_CURL[@]}" \
    -u "${NTX_USER}:${NUTANIX_PASSWORD}" \
    -H "Accept: application/json" \
    -o /dev/null -w "%{http_code}" \
    "${PC_API}${api_path}" 2>/dev/null || echo "000")

  if [[ "$PC_CODE" == "200" ]]; then
    PC_AUTH_OK=true
    break
  fi
done

if [[ "$PC_AUTH_OK" == "true" ]]; then
  ok "Prism Central: ${NTX_USER}@${NTX_ENDPOINT} (HTTP 200)"
else
  fail "Prism Central auth failed (HTTP ${PC_CODE})"
  fail "Check username/password for ${NTX_USER}@${NTX_ENDPOINT}:${NTX_PORT}"
  exit 1
fi

# Registry  check /v2/ auth if we have mirror creds
if [[ "$AIRGAP_METHOD" != "bundle" && -n "$REG_MIRROR_URL" && -n "$REG_MIRROR_USER" && -n "$REG_MIRROR_PASS" ]]; then
  # Parse mirror URL: strip scheme, extract host
  REG_SCHEME="https"
  REG_HOST="$REG_MIRROR_URL"
  if [[ "$REG_HOST" =~ ^https?:// ]]; then
    REG_SCHEME="${REG_HOST%%://*}"
    REG_HOST="${REG_HOST#*://}"
  fi
  REG_HOST="${REG_HOST%%/*}"

  REG_AUTH_OK=false
  for try_scheme in "$REG_SCHEME" "$([ "$REG_SCHEME" = "https" ] && echo "http" || echo "https")"; do
    REG_CODE=$(curl -s --connect-timeout 10 --max-time 15 \
      -u "${REG_MIRROR_USER}:${REG_MIRROR_PASS}" \
      -o /dev/null -w "%{http_code}" \
      "${try_scheme}://${REG_HOST}/v2/" 2>/dev/null || echo "000")

    if [[ "$REG_CODE" == "200" ]]; then
      REG_AUTH_OK=true
      ok "Registry: ${REG_MIRROR_USER}@${REG_HOST} (HTTP 200, ${try_scheme}://)"
      break
    fi
  done

  if [[ "$REG_AUTH_OK" != "true" ]]; then
    if [[ "$REG_CODE" == "401" ]]; then
      fail "Registry auth failed: ${REG_MIRROR_USER}@${REG_HOST} (HTTP 401 — bad credentials)"
    else
      fail "Registry unreachable: ${REG_HOST} (HTTP ${REG_CODE})"
    fi
    exit 1
  fi
elif [[ "$AIRGAP_METHOD" != "bundle" && -n "$REG_MIRROR_URL" ]]; then
  # No creds just check reachability
  REG_HOST="$REG_MIRROR_URL"
  [[ "$REG_HOST" =~ ^https?:// ]] && REG_HOST="${REG_HOST#*://}"
  REG_HOST="${REG_HOST%%/*}"
  info "Registry mirror: ${REG_HOST} (no credentials to test auth)"
fi

# ── Build command ───────────────────────────────────────────────────────────

header "Building nkp command"

NKP_VERSION=$(nkp version -o=json | jq -r '.nkp.gitVersion')

# TODO: Validate VM image K8s version matches NKP expected version
# NKP 2.x → K8s 1.(x+17): 2.12=1.29, 2.13=1.30, 2.14=1.31, 2.15=1.32, 2.16=1.33, 2.17=1.34
# If mismatch, user can: build with `nkp create image nutanix`, download pre-built from portal,
# or skip with --skip-preflight-checks=NutanixVMImageKubernetesVersion
info "NKP version: ${NKP_VERSION}"

# Required flags
CMD=(nkp create cluster nutanix
  -c "$CLUSTER_NAME"
  --endpoint "https://${NTX_ENDPOINT}:${NTX_PORT}"
  --control-plane-endpoint-ip "$NET_VIP"
  --control-plane-prism-element-cluster "$NTX_PE"
  --control-plane-subnets "$NTX_SUBNET"
  --control-plane-vm-image "$NIB_IMAGE"
  --control-plane-replicas "$CP_COUNT"
  --worker-prism-element-cluster "$NTX_PE"
  --worker-subnets "$NTX_SUBNET"
  --worker-vm-image "${WORKER_IMAGE:-$NIB_IMAGE}"
  --worker-replicas "$W_COUNT"
  --csi-storage-container "$NTX_STORAGE"
  --kubernetes-service-load-balancer-ip-range "$NET_LB"
)

# Node sizing
[[ -n "$CP_VCPUS" ]] && CMD+=(--control-plane-vcpus "$CP_VCPUS")
[[ -n "$CP_MEM" ]]   && CMD+=(--control-plane-memory "$CP_MEM")
[[ -n "$W_VCPUS" ]]  && CMD+=(--worker-vcpus "$W_VCPUS")
[[ -n "$W_MEM" ]]    && CMD+=(--worker-memory "$W_MEM")

# Networking
[[ -n "$POD_CIDR" && "$POD_CIDR" != "192.168.0.0/16" ]] && CMD+=(--kubernetes-pod-network-cidr "$POD_CIDR")
[[ -n "$SVC_CIDR" && "$SVC_CIDR" != "10.96.0.0/12" ]]   && CMD+=(--kubernetes-service-cidr "$SVC_CIDR")

# Nutanix TLS
if [[ "$NTX_INSECURE" == "true" ]]; then
  CMD+=(--insecure)
fi
[[ -n "$NTX_TRUST_BUNDLE" ]] && CMD+=(--additional-trust-bundle "$NTX_TRUST_BUNDLE")

# Cluster hostname + extra SANs
[[ -n "$CLUSTER_HOSTNAME" ]] && CMD+=(--cluster-hostname "$CLUSTER_HOSTNAME")
[[ -n "$EXTRA_SANS" ]]       && CMD+=(--extra-sans "$EXTRA_SANS")

# SSH
[[ -n "$SSH_USER" ]] && CMD+=(--ssh-username "$SSH_USER")
[[ -n "$SSH_KEY" ]]  && CMD+=(--ssh-public-key-file "${SSH_KEY/#\~/$HOME}")

# CSI options
[[ "$CSI_HV" == "true" || "$CSI_HV" == "false" ]] && CMD+=(--csi-hypervisor-attached-volumes="$CSI_HV")
[[ -n "$CSI_FS" && "$CSI_FS" != "ext4" ]]         && CMD+=(--csi-file-system "$CSI_FS")

# Self-managed
[[ "$SELF_MANAGED" == "true" ]] && CMD+=(--self-managed)

# PC categories
[[ -n "$CP_CATS" ]] && CMD+=(--control-plane-pc-categories "$CP_CATS")
[[ -n "$W_CATS" ]]  && CMD+=(--worker-pc-categories "$W_CATS")

# Airgap mode
[[ "$DEPLOYMENT_TYPE" == "airgap" ]] && CMD+=(--airgapped)

# -- Airgap: bundle method vs external registry (mutually exclusive) --
if [[ "$DEPLOYMENT_TYPE" == "airgap" && "$AIRGAP_METHOD" == "bundle" ]]; then
  # Bundle method: NKP creates internal registry from local tar files
  # Do NOT use --registry-mirror-url (would conflict with --bundle)
  info "Bundle mode: looking for image bundles..."

  # Auto-detect versioned subdirectory
  RESOLVED_BUNDLE_DIR="$BUNDLE_DIR"
  VERSION_DIR=$(ls -d "${BUNDLE_DIR}"/nkp-v* 2>/dev/null | head -1 || true)
  if [[ -n "$VERSION_DIR" && -d "$VERSION_DIR" ]]; then
    RESOLVED_BUNDLE_DIR="$VERSION_DIR"
  fi

  # Find all image bundles and add each as --bundle
  BUNDLES_FOUND=0
  while IFS= read -r b; do
    [[ -z "$b" ]] && continue
    CMD+=(--bundle "$b")
    info "Bundle: $(basename "$b")"
    BUNDLES_FOUND=$(( BUNDLES_FOUND + 1 ))
  done < <(find "$RESOLVED_BUNDLE_DIR" -maxdepth 2 -name "*-image-bundle-*.tar" -type f 2>/dev/null)

  if [[ $BUNDLES_FOUND -eq 0 ]]; then
    fail "No image bundles found in ${BUNDLE_DIR}"
    exit 1
  fi
  ok "${BUNDLES_FOUND} bundle(s) found"

elif [[ "$DEPLOYMENT_TYPE" == "airgap" && "$AIRGAP_METHOD" == "external" ]]; then
  # External registry: use --registry-mirror-url (images already pushed)
  # Do NOT use --bundle (would conflict with --registry-mirror-url)
  if [[ -n "$REG_MIRROR_URL" ]]; then
    CMD+=(--registry-mirror-url "$REG_MIRROR_URL")
    [[ -n "$REG_MIRROR_USER" ]] && CMD+=(--registry-mirror-username "$REG_MIRROR_USER")
    [[ -n "$REG_MIRROR_PASS" ]] && CMD+=(--registry-mirror-password "$REG_MIRROR_PASS")
    [[ -n "$REG_MIRROR_CA" ]]   && CMD+=(--registry-mirror-cacert "$REG_MIRROR_CA")
  else
    fail "External airgap requires registry.mirror_url"
    exit 1
  fi

  # Bootstrap image for KinD cluster
  # If bootstrap was docker-loaded locally, leave kind_cluster_image empty in config
  # NKP will find the local image automatically. Only set this if you need to
  # point to a specific registry/tag that Docker can actually pull.
  if [[ -n "$KIND_IMAGE" ]]; then
    [[ "$KIND_IMAGE" != *:* ]] && KIND_IMAGE="${KIND_IMAGE}:${NKP_VERSION}"
    CMD+=(--bootstrap-cluster-image "$KIND_IMAGE")
  fi

else
  # Connected mode: optional registry mirror (Docker Hub rate limit avoidance)
  if [[ -n "$REG_MIRROR_URL" ]]; then
    CMD+=(--registry-mirror-url "$REG_MIRROR_URL")
    [[ -n "$REG_MIRROR_USER" ]] && CMD+=(--registry-mirror-username "$REG_MIRROR_USER")
    [[ -n "$REG_MIRROR_PASS" ]] && CMD+=(--registry-mirror-password "$REG_MIRROR_PASS")
    [[ -n "$REG_MIRROR_CA" ]]   && CMD+=(--registry-mirror-cacert "$REG_MIRROR_CA")
  fi

  # Bootstrap image override (optional in connected)
  if [[ -n "$KIND_IMAGE" ]]; then
    [[ "$KIND_IMAGE" != *:* ]] && KIND_IMAGE="${KIND_IMAGE}:${NKP_VERSION}"
    CMD+=(--bootstrap-cluster-image "$KIND_IMAGE")
  fi
fi

# Proxy
[[ -n "$PROXY_HTTP" ]]  && CMD+=(--http-proxy "$PROXY_HTTP")
[[ -n "$PROXY_HTTPS" ]] && CMD+=(--https-proxy "$PROXY_HTTPS")
[[ -n "$PROXY_NO" ]]    && CMD+=(--no-proxy "$PROXY_NO")

# Verbose mode (--verbose or -v → nkp -v 5)
if [[ "$VERBOSE" == "true" ]]; then
  CMD+=(-v 5)
  info "Verbose mode enabled (-v 5)"
fi

# ── Review ──────────────────────────────────────────────────────────────────

header "Deployment summary"

echo ""
echo "  Cluster:      ${CLUSTER_NAME}"
echo "  Hostname:     ${CLUSTER_HOSTNAME:-<none>}"
echo "  Type:         ${DEPLOYMENT_TYPE}"
echo "  NKP version:  ${NKP_VERSION}"
echo ""
echo "  Nutanix:"
echo "    PC:         ${NTX_ENDPOINT}:${NTX_PORT} (user: ${NTX_USER})"
echo "    PE:         ${NTX_PE}"
echo "    Subnet:     ${NTX_SUBNET}"
echo "    Storage:    ${NTX_STORAGE}"
echo ""
echo "  Nodes:"
echo "    CP:         ${CP_COUNT}x (${CP_VCPUS} vCPU / ${CP_MEM} GB)"
echo "    Workers:    ${W_COUNT}x (${W_VCPUS} vCPU / ${W_MEM} GB)"
echo "    CP image:   ${NIB_IMAGE}"
[[ "$WORKER_IMAGE" != "$NIB_IMAGE" ]] && echo "    W image:    ${WORKER_IMAGE}"
echo ""
echo "  Networking:"
echo "    VIP:        ${NET_VIP}"
echo "    MetalLB:    ${NET_LB}"
echo "    Pod CIDR:   ${POD_CIDR}"
echo "    Svc CIDR:   ${SVC_CIDR}"
echo ""

if [[ "$DEPLOYMENT_TYPE" == "airgap" ]]; then
  echo "  Airgap method: ${AIRGAP_METHOD}"
  if [[ "$AIRGAP_METHOD" == "bundle" ]]; then
    echo "    Bundles:    ${BUNDLE_DIR}"
    echo "    (NKP creates internal registry — no --registry-mirror-url)"
  else
    echo "    Mirror:     ${REG_MIRROR_URL}"
    [[ -n "$KIND_IMAGE" ]] && echo "    Bootstrap:  ${KIND_IMAGE}"
  fi
  echo ""
fi

# Show the full command (mask passwords)
header "Command"
DISPLAY_CMD=$(printf '%s ' "${CMD[@]}")
DISPLAY_CMD=$(echo "$DISPLAY_CMD" | sed 's/--registry-mirror-password [^ ]*/--registry-mirror-password ****/g')
DISPLAY_CMD=$(echo "$DISPLAY_CMD" | sed 's/--registry-password [^ ]*/--registry-password ****/g')
echo ""
echo "  $DISPLAY_CMD"
echo ""

# ── Confirm and run ─────────────────────────────────────────────────────────

read -rp "  Deploy cluster? [Y/n]: " confirm < /dev/tty
confirm="${confirm,,}"
if [[ "$confirm" == "n" || "$confirm" == "no" ]]; then
  echo "  Aborted."
  exit 0
fi

header "Deploying ${CLUSTER_NAME}"
info "Starting nkp create cluster nutanix..."
info "This will take 20-45 minutes. Use tmux to avoid losing the session."
echo ""

# Run it
"${CMD[@]}"

# ── Post-deploy ─────────────────────────────────────────────────────────────

KUBECONFIG_FILE="${CLUSTER_NAME}.conf"
if [[ -f "$KUBECONFIG_FILE" ]]; then
  ok "Cluster created successfully"
  ok "Kubeconfig: ${KUBECONFIG_FILE}"
  echo ""
  echo "  Export it:"
  echo "    export KUBECONFIG=$(pwd)/${KUBECONFIG_FILE}"
  echo ""
  echo "  Test:"
  echo "    kubectl get nodes"
  echo "    kubectl get pods -A"
  echo ""
else
  warn "Cluster creation may have completed but kubeconfig not found at ${KUBECONFIG_FILE}"
  warn "Check nkp output above for errors."
fi
