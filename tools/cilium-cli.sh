#!/usr/bin/env bash

#------------------------------------------------------------------------------
# Tool installer: Cilium CLI
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
RELEASE=$(curl -s ${_GH_TOKEN:+-H "Authorization: token ${_GH_TOKEN}"} https://api.github.com/repos/cilium/cilium-cli/releases/latest | jq -r .tag_name)
if [[ ${RELEASE} == "null" ]]; then
    echo "github api rate limiting blocked request"
    echo "get latest version failed. Exiting."
    exit 1
fi

# Check if already at latest version
TOOL_PATH=$(command -v cilium 2>/dev/null)
if [ -n "$TOOL_PATH" ]; then
    CURRENT=$("$TOOL_PATH" version --client 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    LATEST="${RELEASE#v}"
    if [[ "$CURRENT" == "$LATEST" ]]; then
        echo "cilium is already at latest version (${RELEASE}), skipping."
        exit 0
    fi
fi

echo "Downloading Cilium CLI ${RELEASE}"
url="https://github.com/cilium/cilium-cli/releases/download/${RELEASE}/cilium-linux-${ARCH}.tar.gz"

# Download the file and check for errors
curl -fsSL -o "cilium-linux-${ARCH}.tar.gz" "$url"
if [ $? -ne 0 ]; then
    echo "Download failed. Exiting."
    exit 1
fi

# Extract the downloaded file and check for errors
tar xzf "cilium-linux-${ARCH}.tar.gz"
if [ $? -ne 0 ]; then
    echo "Extraction failed. Exiting."
    exit 1
fi

# Move binary to /usr/local/bin
chmod +x ./cilium
if [ $? -eq 0 ]; then
    sudo mv ./cilium /usr/local/bin
else
    echo "Failed to make cilium executable. Exiting."
    exit 1
fi

# Clean up downloaded files
rm -f "cilium-linux-${ARCH}.tar.gz"

# Success message
echo "Cilium CLI installed successfully!"
echo "checking version"
cilium version --client
