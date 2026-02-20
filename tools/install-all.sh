#!/usr/bin/env bash

#------------------------------------------------------------------------------
# Install all NKP DevSecOps CLI tools
# Runs each installer sequentially, tracks pass/fail
#------------------------------------------------------------------------------

SKIP_ALIASES=false
for arg in "$@"; do
    case "$arg" in
        --no-aliases) SKIP_ALIASES=true ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check github API rate limit before starting
_GH_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
REMAINING=$(curl -s ${_GH_TOKEN:+-H "Authorization: token ${_GH_TOKEN}"} https://api.github.com/rate_limit | jq -r '.rate.remaining')
if [[ "$REMAINING" -lt 14 ]]; then
    echo "ERROR: GitHub API rate limit too low (${REMAINING} requests remaining, need 14)"
    echo ""
    echo "Fix: set a GitHub token to get 5000 req/hour instead of 60:"
    echo "  export GITHUB_TOKEN=ghp_xxxx"
    echo "  # or if gh cli is configured:"
    echo "  export GITHUB_TOKEN=\$(gh auth token)"
    echo ""
    echo "Then re-run this script."
    exit 1
fi

TOOLS=(
    "yq_cli.sh"
    "helm-cli.sh"
    "flux-cli.sh"
    "k9s_cli.sh"
    "kubectx_cli.sh"
    "velero_cli.sh"
    "clusterctl-cli.sh"
    "cmctl-cli.sh"
    "hubble-cli.sh"
    "stern-cli.sh"
    "pluto-cli.sh"
    "trivy-cli.sh"
    "cilium-cli.sh"
    "fzf-cli.sh"
)

PASSED=()
FAILED=()

echo "============================================"
echo " NKP DevSecOps CLI Tools Installer"
echo "============================================"
echo ""

for tool in "${TOOLS[@]}"; do
    echo "--------------------------------------------"
    echo " Installing: ${tool%.sh}"
    echo "--------------------------------------------"
    if bash "${SCRIPT_DIR}/${tool}"; then
        PASSED+=("$tool")
    else
        FAILED+=("$tool")
    fi
    echo ""
done

# Run set-aliases last (not a CLI download)
if [ "$SKIP_ALIASES" = false ]; then
    echo "--------------------------------------------"
    echo " Configuring: shell aliases"
    echo "--------------------------------------------"
    if bash "${SCRIPT_DIR}/set-aliases.sh"; then
        PASSED+=("set-aliases.sh")
    else
        FAILED+=("set-aliases.sh")
    fi
else
    echo "--------------------------------------------"
    echo " Skipping: shell aliases (--no-aliases)"
    echo "--------------------------------------------"
fi

echo ""
echo "============================================"
echo " Summary"
echo "============================================"
echo " Passed: ${#PASSED[@]}/${#TOOLS[@]}"
for t in "${PASSED[@]}"; do
    echo "   [OK]   $t"
done
if [ ${#FAILED[@]} -gt 0 ]; then
    echo " Failed: ${#FAILED[@]}/${#TOOLS[@]}"
    for t in "${FAILED[@]}"; do
        echo "   [FAIL] $t"
    done
fi
echo "============================================"

[ ${#FAILED[@]} -eq 0 ]
