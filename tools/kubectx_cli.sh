#!/usr/bin/env bash

#------------------------------------------------------------------------------

# Copyright 2024 Nutanix, Inc
#
# Licensed under the MIT License;
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”),
# to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#------------------------------------------------------------------------------

# Maintainer:   Eric De Witte (eric.dewitte@nutanix.com)
# Contributors: 

#------------------------------------------------------------------------------

#check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "jq is not installed. Please install jq to run this script."
    exit 1
fi  

case "$(uname -m)" in
    x86_64)  ARCH="x86_64" ;;
    aarch64) ARCH="arm64" ;;
    *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac

_GH_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
RELEASE=$(curl -s ${_GH_TOKEN:+-H "Authorization: token ${_GH_TOKEN}"} https://api.github.com/repos/ahmetb/kubectx/releases/latest | jq -r .tag_name)
if [[ ${RELEASE} == "null" ]]; then
    echo "github api rate limiting blocked request"
    echo "get latest version failed. Exiting."
    exit 1
fi

echo "Downloading kubectx ${RELEASE}"
url="https://github.com/ahmetb/kubectx/releases/download/${RELEASE}/kubectx_${RELEASE}_linux_${ARCH}.tar.gz"
# Download the file and check for errors
curl -fsSL -o "kubectx_linux_${ARCH}.tar.gz" "$url"
if [ $? -ne 0 ]; then
    echo "Download failed. Exiting."
    exit 1
fi

# Extract the downloaded file and check for errors
tar xzf "kubectx_linux_${ARCH}.tar.gz"
if [ $? -ne 0 ]; then
    echo "Extraction failed. Exiting."
    exit 1
fi

echo "Downloading kubens ${RELEASE}"
url="https://github.com/ahmetb/kubectx/releases/download/${RELEASE}/kubens_${RELEASE}_linux_${ARCH}.tar.gz"
# Download the file and check for errors
curl -fsSL -o "kubens_linux_${ARCH}.tar.gz" "$url"
if [ $? -ne 0 ]; then
    echo "Download failed. Exiting."
    exit 1
fi

# Extract the downloaded file and check for errors
tar xzf "kubens_linux_${ARCH}.tar.gz"
if [ $? -ne 0 ]; then
    echo "Extraction failed. Exiting."
    exit 1
fi

# Make the file executable and move it to /usr/local/bin
sudo mv ./kubectx /usr/local/bin
sudo mv ./kubens /usr/local/bin

# Clean up downloaded files
rm -f "kubectx_linux_${ARCH}.tar.gz" "kubens_linux_${ARCH}.tar.gz"

# Success message
echo "kubectx and kubens CLI installed successfully!"
echo "installed kubectx ${RELEASE}"
echo "installed kubens ${RELEASE}"