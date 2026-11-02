#!/usr/bin/env bash
# Idempotent Cursor cloud-agent bootstrap for this REA checkout.
# Installs the pinned Node.js toolchain, procps, a full JDK, and Ghidra, then
# builds REA from this repository so the fork's source is what the MCP server runs.
# Hopper is intentionally omitted: the Linux package is optional and this
# environment selects Ghidra for native analysis.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/bin:${PATH}"

NODE_VERSION="24.22.1"
NODE_SHA256="6c172a9ab6718f7b801fb5a7bd486af2ee5e32758086a04b84fcce2aa77095e6"
NPM_VERSION="11.16.0"
GHIDRA_DIR_NAME="ghidra_12.1.4_PUBLIC"
GHIDRA_URL="https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/ghidra_12.1.4_PUBLIC_20260921.zip"
GHIDRA_SHA256="ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db"
GHIDRA_INSTALL_DIR="/opt/${GHIDRA_DIR_NAME}"
JAVA_HOME_PATH="/usr/lib/jvm/java-21-openjdk-amd64"

if [[ "$(id -u)" -eq 0 ]]; then
  sudo() { "$@"; }
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Installing OS packages (procps, JDK 21, build tools)"
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  xz-utils \
  unzip \
  procps \
  build-essential \
  openjdk-21-jdk

if [[ ! -x "${JAVA_HOME_PATH}/bin/javac" ]]; then
  echo "Expected a full JDK 21 at ${JAVA_HOME_PATH}" >&2
  exit 1
fi

if ! /usr/local/bin/node -v 2>/dev/null | grep -qx "v${NODE_VERSION}"; then
  echo "Installing Node.js ${NODE_VERSION} into /usr/local"
  tmp="$(mktemp)"
  trap 'rm -f "${tmp}"' RETURN
  curl --fail --location --retry 5 --retry-all-errors \
    "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    --output "${tmp}"
  echo "${NODE_SHA256}  ${tmp}" | sha256sum -c -
  sudo tar -xJf "${tmp}" -C /usr/local --strip-components=1 --no-same-owner
  rm -f "${tmp}"
  trap - RETURN
else
  echo "Node.js ${NODE_VERSION} already installed at /usr/local/bin/node"
fi

hash -r
if ! /usr/local/bin/node -v | grep -qx "v${NODE_VERSION}"; then
  echo "Node.js ${NODE_VERSION} was not available at /usr/local/bin/node after install" >&2
  exit 1
fi

# `corepack enable` without a name leaves Node's bundled npm in place.
# Enabling npm specifically replaces that binary with the Corepack shim.
if ! /usr/local/bin/npm -v 2>/dev/null | grep -qx "${NPM_VERSION}"; then
  echo "Activating npm ${NPM_VERSION} with corepack"
  sudo /usr/local/bin/corepack enable npm
  sudo /usr/local/bin/corepack prepare "npm@${NPM_VERSION}" --activate
fi
npm_version="$(/usr/local/bin/npm -v 2>/dev/null | tail -n 1)"
if [[ "${npm_version}" != "${NPM_VERSION}" ]]; then
  echo "npm ${NPM_VERSION} was not activated; /usr/local/bin/npm is ${npm_version}" >&2
  exit 1
fi

if [[ ! -x "${GHIDRA_INSTALL_DIR}/support/analyzeHeadless" ]]; then
  echo "Installing Ghidra 12.1.4 into ${GHIDRA_INSTALL_DIR}"
  if [[ -e "${GHIDRA_INSTALL_DIR}" ]]; then
    sudo rm -rf "${GHIDRA_INSTALL_DIR}"
  fi
  tmp="$(mktemp)"
  trap 'rm -f "${tmp}"' RETURN
  curl --fail --location --retry 5 --retry-all-errors \
    "${GHIDRA_URL}" \
    --output "${tmp}"
  echo "${GHIDRA_SHA256}  ${tmp}" | sha256sum -c -
  sudo unzip -q "${tmp}" -d /opt
  rm -f "${tmp}"
  trap - RETURN
else
  echo "Ghidra already installed at ${GHIDRA_INSTALL_DIR}"
fi

if [[ ! -x "${GHIDRA_INSTALL_DIR}/support/analyzeHeadless" ]]; then
  echo "Ghidra headless launcher is missing at ${GHIDRA_INSTALL_DIR}" >&2
  exit 1
fi

# Login shells (including the cloud-agent install/start bash -l) source this.
# MCP registration in .cursor/mcp.json sets the same values for the server process.
sudo tee /etc/profile.d/rea-cloud-agent.sh >/dev/null <<EOF
export PATH="/usr/local/bin:\${PATH}"
export JAVA_HOME="${JAVA_HOME_PATH}"
export GHIDRA_INSTALL_DIR="${GHIDRA_INSTALL_DIR}"
export REA_ANALYSIS_PROVIDER="ghidra"
EOF
sudo chmod 644 /etc/profile.d/rea-cloud-agent.sh

export JAVA_HOME="${JAVA_HOME_PATH}"
export GHIDRA_INSTALL_DIR="${GHIDRA_INSTALL_DIR}"
export REA_ANALYSIS_PROVIDER="ghidra"

echo "Building REA from ${root}"
cd "${root}"
npm ci
npm run build:cached

# A login shell on the cloud image sources nvm after /etc/profile.d and can
# put an older Node ahead of /usr/local/bin. The rea command always uses the
# pinned runtime. Appending to ~/.profile puts that runtime first for later
# login shells as well.
# Remove any previous symlink first. tee follows symlinks, so writing through
# a link to scripts/rea.mjs would overwrite the source entry.
sudo rm -f /usr/local/bin/rea
sudo tee /usr/local/bin/rea >/dev/null <<EOF
#!/bin/sh
export PATH="/usr/local/bin:\${PATH}"
export JAVA_HOME="${JAVA_HOME_PATH}"
export GHIDRA_INSTALL_DIR="${GHIDRA_INSTALL_DIR}"
if [ -z "\${REA_ANALYSIS_PROVIDER:-}" ]; then
  export REA_ANALYSIS_PROVIDER="ghidra"
fi
exec /usr/local/bin/node "${root}/scripts/rea.mjs" "\$@"
EOF
sudo chmod 755 /usr/local/bin/rea

profile="${HOME}/.profile"
marker="# rea-cloud-agent node path"
if [[ -f "${profile}" ]] && ! grep -q "${marker}" "${profile}"; then
  cat >>"${profile}" <<'EOF'

# rea-cloud-agent node path
export PATH="/usr/local/bin:${PATH}"
EOF
fi

echo "REA cloud-agent install complete"
/usr/local/bin/node -v
/usr/local/bin/npm -v
command -v ps
"${JAVA_HOME}/bin/java" -version
test -x "${GHIDRA_INSTALL_DIR}/support/analyzeHeadless"
