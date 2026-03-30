#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

###############################################################################
#  NKP Air-Gap — Check registry & push bundles
#
#  Reads config.json for registry info, validates the registry is reachable,
#  then pushes all airgap bundles (images + charts) to the private registry.
#
#  Prerequisites:
#    - config.json exists (run configure.py first)
#    - nkp CLI installed
#    - Airgap bundle extracted (tools/0_get-nkp-airgap-bundle)
#    - jq installed
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.json"
DEFAULT_BUNDLE_DIR="${SCRIPT_DIR}/../nkp-airgap-bundle"

# Beautiful colors :)
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "  ${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "  ${GREEN}[OK]${NC}   $1"; }
warn()  { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
fail()  { echo -e "  ${RED}[FAIL]${NC} $1"; }
header() { echo -e "\n══════════════════════════════════════════════════════════\n  $1\n══════════════════════════════════════════════════════════"; }

# Config load
# TODO full check config file, config format regex etcc
# 
header "Loading config"

if [[ ! -f "$CONFIG_FILE" ]]; then
  fail "config.json not found. Run configure.py first."
  exit 1
fi

DEPLOYMENT_TYPE=$(jq -r '.deployment_type // empty' "$CONFIG_FILE")
AIRGAP_METHOD=$(jq -r '.airgap_method // empty' "$CONFIG_FILE")

if [[ "$DEPLOYMENT_TYPE" != "airgap" ]]; then
  fail "deployment_type is '${DEPLOYMENT_TYPE}', not 'airgap'. This script is for airgap only."
  exit 1
fi

if [[ "$AIRGAP_METHOD" == "bundle" ]]; then
  warn "airgap_method is 'bundle' — NKP will create an internal registry from bundles."
  warn "Pushing to external registry is only needed for the 'external' method."
  read -rp "  Continue anyway? [y/N]: " cont < /dev/tty
  if [[ "${cont,,}" != "y" && "${cont,,}" != "yes" ]]; then
    echo "  Aborted."
    exit 0
  fi
fi
ok "Deployment type: airgap"

REGISTRY_URL_RAW=$(jq -r '.registry.registry_url // empty' "$CONFIG_FILE")
REGISTRY_USER=$(jq -r '.registry.registry_username // empty' "$CONFIG_FILE")
REGISTRY_CA=$(jq -r '.registry.ca_cert_path // empty' "$CONFIG_FILE")

if [[ -z "$REGISTRY_URL_RAW" ]]; then
  fail "registry.registry_url is empty in config.json."
  exit 1
fi

# Parse registry URL: strip scheme, separate host from project path
REG_SCHEME="https"
REG_NO_SCHEME="$REGISTRY_URL_RAW"
if [[ "$REG_NO_SCHEME" =~ ^https?:// ]]; then
  REG_SCHEME="${REG_NO_SCHEME%%://*}"
  REG_NO_SCHEME="${REG_NO_SCHEME#*://}"
fi

# Remove trailing slash
REG_NO_SCHEME="${REG_NO_SCHEME%/}"
# Split into host and path (e.g. "harbor.local/nkp" → host="harbor.local", path="/nkp")
REG_HOST="${REG_NO_SCHEME%%/*}"
REG_PATH=""
[[ "$REG_NO_SCHEME" == *"/"* ]] && REG_PATH="/${REG_NO_SCHEME#*/}"

# Full registry URL for nkp push (scheme + host + path)
REGISTRY_URL="${REG_SCHEME}://${REG_NO_SCHEME}"

ok "Registry URL: ${REGISTRY_URL}"
info "  Host: ${REG_HOST}  Path: ${REG_PATH:-/}  Scheme: ${REG_SCHEME}"

# Creds for harbor (TODO Docker registry and scaleway for test)

header "Registry credentials"

if [[ -n "${REGISTRY_PASSWORD:-}" ]]; then
  info "Using REGISTRY_PASSWORD from environment."
  REG_PASS="$REGISTRY_PASSWORD"
else
  read -rsp "  Registry password for ${REGISTRY_USER:-<no user>}: " REG_PASS < /dev/tty
  echo ""
fi

# Required tools installed ?
# TODO All PC-All-In-One
header "Prerequisites"

for tool in nkp jq curl; do
  if command -v "$tool" &>/dev/null; then
    ok "${tool} found"
  else
    fail "${tool} not found — install it first."
    exit 1
  fi
done

# Registry reachable ?
# TODO redo a good one, AI Generated ask local lab is fucked
header "Registry connectivity"

CURL_OPTS=(-s --connect-timeout 10 --max-time 15)
[[ -n "$REGISTRY_CA" && -f "$REGISTRY_CA" ]] && CURL_OPTS+=(--cacert "$REGISTRY_CA")

# /v2/ endpoint lives at the registry root (host), not under the project path
V2_URL="${REG_SCHEME}://${REG_HOST}/v2/"

HTTP_CODE=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" "$V2_URL" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "401" ]]; then
  ok "Registry reachable at ${V2_URL} (HTTP ${HTTP_CODE})"
else
  # Try the other scheme
  ALT_SCHEME="http"
  [[ "$REG_SCHEME" == "http" ]] && ALT_SCHEME="https"
  ALT_V2="${ALT_SCHEME}://${REG_HOST}/v2/"
  HTTP_CODE=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" "$ALT_V2" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "401" ]]; then
    ok "Registry reachable at ${ALT_V2} (HTTP ${HTTP_CODE})"
    warn "Switching scheme to ${ALT_SCHEME}:// (config says ${REG_SCHEME}://)"
    REG_SCHEME="$ALT_SCHEME"
    REGISTRY_URL="${REG_SCHEME}://${REG_NO_SCHEME}"
  else
    fail "Registry unreachable at ${V2_URL} (HTTP ${HTTP_CODE})"
    fail "Make sure the registry is running and the URL is correct."
    exit 1
  fi
fi

# Authenticate — required for registries that return 401
if [[ -n "$REGISTRY_USER" && -n "$REG_PASS" ]]; then
  AUTH_V2="${REG_SCHEME}://${REG_HOST}/v2/"
  AUTH_CODE=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" -u "${REGISTRY_USER}:${REG_PASS}" "$AUTH_V2" 2>/dev/null || echo "000")
  if [[ "$AUTH_CODE" == "200" ]]; then
    ok "Registry authentication successful"
  else
    fail "Registry authentication failed (HTTP ${AUTH_CODE})"
    fail "Check username/password for ${REGISTRY_USER}@${REG_HOST}"
    exit 1
  fi
elif [[ "$HTTP_CODE" == "401" ]]; then
  fail "Registry requires authentication but no credentials provided"
  exit 1
fi

# END SHIT TODO

# CA cert check
if [[ -n "$REGISTRY_CA" ]]; then
  if [[ -f "$REGISTRY_CA" ]]; then
    ok "CA cert found: ${REGISTRY_CA}"
  else
    fail "CA cert not found: ${REGISTRY_CA}"
    exit 1
  fi
fi

# Check bundles. 2.16 and 17 removed apps. 
header "Locating bundles"

BUNDLE_DIR="${1:-$DEFAULT_BUNDLE_DIR}"
if [[ ! -d "$BUNDLE_DIR" ]]; then
  fail "Bundle directory not found: ${BUNDLE_DIR}"
  echo ""
  echo "  Usage: $0 [bundle-dir]"
  echo "  Default: ${DEFAULT_BUNDLE_DIR}"
  echo ""
  echo "  Run tools/0_get-nkp-airgap-bundle first to download and extract."
  exit 1
fi

# Auto-detect versioned subdirectory (e.g. nkp-v2.17.0/)
VERSION_DIRS=()
while IFS= read -r d; do
  [[ -n "$d" ]] && VERSION_DIRS+=("$d")
done < <(ls -d "${BUNDLE_DIR}"/nkp-v* 2>/dev/null | sort -V)

if [[ ${#VERSION_DIRS[@]} -eq 1 ]]; then
  info "Found versioned subdirectory: $(basename "${VERSION_DIRS[0]}")"
  BUNDLE_DIR="${VERSION_DIRS[0]}"
elif [[ ${#VERSION_DIRS[@]} -gt 1 ]]; then
  echo ""
  echo "  Multiple NKP versions found:"
  for i in "${!VERSION_DIRS[@]}"; do
    echo "    $((i+1))) $(basename "${VERSION_DIRS[$i]}")"
  done
  echo ""
  read -rp "  Select version [1-${#VERSION_DIRS[@]}]: " choice < /dev/tty
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#VERSION_DIRS[@]} )); then
    BUNDLE_DIR="${VERSION_DIRS[$((choice-1))]}"
    info "Selected: $(basename "$BUNDLE_DIR")"
  else
    fail "Invalid selection: ${choice}"
    exit 1
  fi
fi
ok "Bundle directory: ${BUNDLE_DIR}"

# Find tar bundles 
find_bundle() {
  local pattern="$1"
  find "$BUNDLE_DIR" -maxdepth 2 -name "$pattern" -type f 2>/dev/null | head -1
}
find_all_bundles() {
  local pattern="$1"
  find "$BUNDLE_DIR" -maxdepth 2 -name "$pattern" -type f 2>/dev/null
}

IMAGE_BUNDLES=()
while IFS= read -r f; do
  [[ -n "$f" ]] && IMAGE_BUNDLES+=("$f")
done < <(find_all_bundles "*-image-bundle-*.tar")

if [[ ${#IMAGE_BUNDLES[@]} -gt 0 ]]; then
  for b in "${IMAGE_BUNDLES[@]}"; do
    ok "Image bundle: $(basename "$b") ($(du -h "$b" | cut -f1))"
  done
else
  fail "No image bundles (*-image-bundle-*.tar) found"
  find "$BUNDLE_DIR" -maxdepth 2 -type f -name "*.tar*" -exec ls -lh {} \; 2>/dev/null || true
  exit 1
fi

# Chart bundles (application-charts/*.tar.gz) — push with nkp push chart-bundle
CHART_BUNDLES=()
while IFS= read -r f; do
  [[ -n "$f" ]] && CHART_BUNDLES+=("$f")
done < <(find_all_bundles "*-charts-bundle*.tar.gz")

if [[ ${#CHART_BUNDLES[@]} -gt 0 ]]; then
  for b in "${CHART_BUNDLES[@]}"; do
    ok "Chart bundle: $(basename "$b") ($(du -h "$b" | cut -f1))"
  done
else
  warn "No chart bundles (*-charts-bundle*.tar.gz) found — skipping chart push"
fi

# ── Bootstrap image (docker load locally)
BOOTSTRAP_IMAGE=$(find_bundle "konvoy-bootstrap-image-*.tar")
if [[ -n "$BOOTSTRAP_IMAGE" ]]; then
  info "Bootstrap image: $(basename "$BOOTSTRAP_IMAGE") ($(du -h "$BOOTSTRAP_IMAGE" | cut -f1)) — docker load"
fi


# Add Steps: TODO: Push custom apps and demo apps
# Recap and confirm
header "Push plan"
echo "  Registry:  ${REGISTRY_URL}"
echo "  Username:  ${REGISTRY_USER:-<none>}"
echo "  CA cert:   ${REGISTRY_CA:-<none>}"
echo ""

TOTAL_STEPS=0

echo "  Image bundles to push (nkp push bundle):"
for b in "${IMAGE_BUNDLES[@]}"; do
  TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
  echo "    ${TOTAL_STEPS}) $(basename "$b")"
done

if [[ ${#CHART_BUNDLES[@]} -gt 0 ]]; then
  echo "  Chart bundles to push (nkp push chart-bundle):"
  for b in "${CHART_BUNDLES[@]}"; do
    TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
    echo "    ${TOTAL_STEPS}) $(basename "$b")"
  done
fi

if [[ -n "$BOOTSTRAP_IMAGE" ]]; then
  TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
  BOOTSTRAP_STEP=$TOTAL_STEPS
  echo "  Bootstrap image to load locally (docker load):"
  echo "    ${TOTAL_STEPS}) $(basename "$BOOTSTRAP_IMAGE")"
fi

echo ""

read -rp "  Proceed? [Y/n]: " confirm < /dev/tty
confirm="${confirm,,}"
if [[ "$confirm" == "n" || "$confirm" == "no" ]]; then
  echo "  Aborted."
  exit 0
fi

# Create commands
NKP_REG_FLAGS=(--to-registry "$REGISTRY_URL")
[[ -n "$REGISTRY_USER" ]] && NKP_REG_FLAGS+=(--to-registry-username "$REGISTRY_USER")
[[ -n "$REG_PASS" ]]      && NKP_REG_FLAGS+=(--to-registry-password "$REG_PASS")
[[ -n "$REGISTRY_CA" && -f "$REGISTRY_CA" ]] && NKP_REG_FLAGS+=(--to-registry-ca-cert-file "$REGISTRY_CA")

STEP=0
for b in "${IMAGE_BUNDLES[@]}"; do
  STEP=$(( STEP + 1 ))
  header "${STEP}/${TOTAL_STEPS} — Pushing $(basename "$b")"
  info "This may take 10-30 minutes depending on bundle size..."

  CMD=(nkp push bundle --bundle "$b" "${NKP_REG_FLAGS[@]}")
  # Show command with password masked
  echo -e "  ${CYAN}\$${NC} ${CMD[*]//$REG_PASS/********}"

  "${CMD[@]}"

  ok "$(basename "$b") pushed successfully"
done

# Push Charts
for b in "${CHART_BUNDLES[@]}"; do
  STEP=$(( STEP + 1 ))
  header "${STEP}/${TOTAL_STEPS} — Pushing $(basename "$b")"

  CMD=(nkp push chart-bundle --bundle "$b" "${NKP_REG_FLAGS[@]}")
  echo -e "  ${CYAN}\$${NC} ${CMD[*]//$REG_PASS/********}"

  "${CMD[@]}"

  ok "$(basename "$b") pushed successfully"
done

# Load image - Lab with podman but wsl docker
if [[ -n "$BOOTSTRAP_IMAGE" ]]; then
  STEP=$(( STEP + 1 ))
  header "${STEP}/${TOTAL_STEPS} — Loading bootstrap image locally"
  info "Running: docker load --input $(basename "$BOOTSTRAP_IMAGE")"

  if command -v docker &>/dev/null; then
    docker load --input "$BOOTSTRAP_IMAGE"
    ok "Bootstrap image loaded into local Docker"
  elif command -v podman &>/dev/null; then
    podman load --input "$BOOTSTRAP_IMAGE"
    ok "Bootstrap image loaded into local Podman"
  else
    warn "Neither docker nor podman found — skipping bootstrap image load"
    warn "You must run: docker load --input $BOOTSTRAP_IMAGE"
  fi
fi

## end

header "Complete"
echo ""
echo -e "  ${GREEN}All bundles pushed to ${REGISTRY_URL}${NC}"
echo ""
echo "  Next steps:"
echo "    1. Run ./1_preflight.sh to validate all prerequisites"
echo "    2. Create the management cluster"
echo ""
