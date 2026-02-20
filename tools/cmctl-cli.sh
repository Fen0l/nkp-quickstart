#!/usr/bin/env bash

#------------------------------------------------------------------------------
# Tool installer: cmctl (cert-manager CLI)
# For use with NKP DevSecOps toolkit
#------------------------------------------------------------------------------

#check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "jq is not installed. Please install jq to run this script."
    exit 1
fi

case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac

_GH_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
RELEASE=$(curl -s ${_GH_TOKEN:+-H "Authorization: token ${_GH_TOKEN}"} https://api.github.com/repos/cert-manager/cmctl/releases/latest | jq -r .tag_name)
if [[ ${RELEASE} == "null" ]]; then
    echo "github api rate limiting blocked request"
    echo "get latest version failed. Exiting."
    exit 1
fi

# Check if already at latest version
TOOL_PATH=$(command -v cmctl 2>/dev/null)
if [ -n "$TOOL_PATH" ]; then
    CURRENT=$("$TOOL_PATH" version --client 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    LATEST="${RELEASE#v}"
    if [[ "$CURRENT" == "$LATEST" ]]; then
        echo "cmctl is already at latest version (${RELEASE}), skipping."
        exit 0
    fi
fi

echo "Downloading cmctl ${RELEASE}"
url="https://github.com/cert-manager/cmctl/releases/download/${RELEASE}/cmctl_linux_${ARCH}"

# Download the binary and check for errors
curl -fsSL -o cmctl "$url"
if [ $? -ne 0 ]; then
    echo "Download failed. Exiting."
    exit 1
fi

# Make the file executable and move it to /usr/local/bin
chmod +x ./cmctl
if [ $? -eq 0 ]; then
    sudo mv ./cmctl /usr/local/bin
else
    echo "Failed to make cmctl executable. Exiting."
    exit 1
fi

# Success message
echo "cmctl CLI installed successfully!"
echo "checking version"
cmctl version --client
