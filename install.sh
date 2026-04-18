#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Claurst Installer
# Builds and installs claurst CLI from source by default, or downloads a release binary.
# Usage: ./install.sh [--binary] [--uninstall] [-h|--help]
# =============================================================================

REPO="kuberwastaken/claurst"
GITHUB_URL="https://github.com/${REPO}"
RELEASES_URL="${GITHUB_URL}/releases/latest"
INSTALL_DIR="/usr/local/bin"
FALLBACK_INSTALL_DIR="$HOME/.local/bin"
VERSION=""

# ── Helpers ──────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install or uninstall Claurst terminal coding agent.

Options:
  --binary       Download and install a pre-built release binary instead of building from source.
  --uninstall    Remove the installed claurst binary.
  -h, --help     Show this help message and exit.

Examples:
  $(basename "$0")                  # Build from source via cargo (default)
  $(basename "$0") --binary         # Download latest release binary
  $(basename "$0") --uninstall      # Remove claurst installation
EOF
}

log() { echo -e "\033[1m→\033[0m $*"; }
warn() { echo -e "\033[33m⚠ \033[0m$*" >&2; }
die()  { echo -e "\033[31m✗ \033[0m$*" >&2; exit 1; }

# ── Install helper: try sudo first, fall back to ~/.local/bin ────────────────

install_file() {
    local src="$1" dest_dir="$2" bin_name="claurst"

    # Try installing to the preferred directory (requires sudo)
    if install -m 755 "$src" "${dest_dir}/${bin_name}" 2>/dev/null; then
        echo "${dest_dir}/${bin_name}"
        return 0
    fi

    # Fall back to user-local bin directory
    warn "Cannot write to ${dest_dir} (requires sudo). Falling back to ${FALLBACK_INSTALL_DIR} ..."
    mkdir -p "${FALLBACK_INSTALL_DIR}"
    install -m 755 "$src" "${FALLBACK_INSTALL_DIR}/${bin_name}"

    # Ensure PATH includes fallback dir if not already present
    case ":${PATH}:" in
        *":${FALLBACK_INSTALL_DIR}:") ;;
        *) export PATH="${FALLBACK_INSTALL_DIR}:${PATH}" ;;
    esac

    echo "${FALLBACK_INSTALL_DIR}/${bin_name}"
    return 0
}

# ── Platform detection ───────────────────────────────────────────────────────

detect_platform() {
    local os arch platform
    case "$(uname -s)" in
        Darwin)   os="macos" ;;
        Linux)    os="linux" ;;
        CYGWIN*|MINGW*|MSYS*)
            echo "claurst-windows-x86_64.zip"; return 0 ;;
        *)        die "Unsupported OS: $(uname -s)" ;;
    esac

    case "$(uname -m)" in
        x86_64)   arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *)        die "Unsupported architecture: $(uname -m)" ;;
    esac

    echo "claurst-${os}-${arch}.tar.gz"
}

# ── Fetch latest version tag ────────────────────────────────────────────────

fetch_version() {
    if command -v curl &>/dev/null; then
        VERSION=$(curl -sL --max-time 10 "https://api.github.com/repos/${REPO}/releases/latest" \
            | grep '"tag_name"' | head -n1 | sed 's/.*"tag_name": *"//;s/".*//')
    elif command -v wget &>/dev/null; then
        VERSION=$(wget -qO- --timeout=10 "https://api.github.com/repos/${REPO}/releases/latest" \
            | grep '"tag_name"' | head -n1 | sed 's/.*"tag_name": *"//;s/".*//')
    else
        die "Neither curl nor wget found. Install one and retry."
    fi

    [ -z "$VERSION" ] && die "Could not determine latest version from GitHub."
    log "Latest release: ${VERSION}"
}

# ── Download & install binary ───────────────────────────────────────────────

install_binary() {
    fetch_version

    local asset
    asset=$(detect_platform)
    [ -z "$asset" ] && die "Could not detect platform for download."

    log "Downloading ${asset} ..."

    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    local url="${GITHUB_URL}/releases/download/${VERSION}/${asset}"
    if ! curl -fSL --max-time 120 -o "${tmpdir}/${asset}" "$url"; then
        die "Download failed. Check your connection."
    fi

    log "Extracting ..."
    mkdir -p "${tmpdir}/extracted"
    tar -xzf "${tmpdir}/${asset}" -C "${tmpdir}/extracted"

    # Find the binary (it may be named differently inside the archive)
    local bin
    bin=$(find "${tmpdir}/extracted" -type f -name 'claurst' ! -name '*.dylib' ! -name '*.so' ! -name '*.dll')
    [ -z "$bin" ] && die "Binary 'claurst' not found in archive."

    log "Installing to ${INSTALL_DIR}/claurst ..."
    local installed_path
    installed_path=$(install_file "$bin" "${INSTALL_DIR}")

    log "Installed claurst ${VERSION} to ${installed_path}"
    log "Run 'claurst' to start, or 'claurst -p \"explain this codebase\"' for a one-shot query."
}

# ── Build from source ───────────────────────────────────────────────────────

install_source() {
    if ! command -v cargo &>/dev/null; then
        die "cargo (Rust toolchain) is not installed. Install Rust via https://rustup.rs and retry."
    fi

    log "Building claurst from source ..."

    # Detect the project root: prefer a src-rust/ subdirectory, fall back to current dir
    local project_dir=""
    if [ -d "$(dirname "$0")/src-rust" ]; then
        project_dir="$(dirname "$0")/src-rust"
    elif [ -d "./src-rust" ]; then
        project_dir="./src-rust"
    else
        die "Could not find src-rust directory. Run this script from the claurst repository root."
    fi

    # Convert to absolute path so it stays valid after cd
    project_dir="$(cd "${project_dir}" && pwd)"

    log "Using source tree: ${project_dir}"

    log "Running cargo build --release ..."
    cd "${project_dir}"
    cargo build --release --package claurst

    local bin="${project_dir}/target/release/claurst"
    [ ! -f "$bin" ] && die "Build failed: binary not found at target/release/claurst."

    log "Installing to ${INSTALL_DIR}/claurst ..."
    local installed_path
    installed_path=$(install_file "$bin" "${INSTALL_DIR}")

    VERSION=$(grep '^version' "${project_dir}/Cargo.toml" | head -1 | sed 's/.*= *"\([^"]*\)".*/\1/')
    log "Installed claurst ${VERSION} to ${installed_path}"
    log "Run 'claurst' to start, or 'claurst -p \"explain this codebase\"' for a one-shot query."
}

# ── Uninstall ────────────────────────────────────────────────────────────────

uninstall() {
    if [ ! -f "${INSTALL_DIR}/claurst" ]; then
        warn "claurst not found at ${INSTALL_DIR}/claurst — nothing to uninstall."
        exit 0
    fi

    log "Removing ${INSTALL_DIR}/claurst ..."
    sudo rm -f "${INSTALL_DIR}/claurst"
    log "Uninstalled claurst."
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    case "${1:-}" in
        --binary)      install_binary ;;
        --source)      install_source ;;
        --uninstall)   uninstall ;;
        -h|--help)     usage ;;
        *)             install_source ;;
    esac
}

main "$@"
