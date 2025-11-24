#!/usr/bin/env bash
# ABOUTME: Installation script for cs (Claude Code session manager)
# ABOUTME: Copies the cs binary to ~/.local/bin and ensures it's executable

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

info() {
    echo -e "${GREEN}$1${NC}"
}

warn() {
    echo -e "${YELLOW}$1${NC}"
}

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/bin"

# Check for Claude Code
if ! command -v claude >/dev/null 2>&1; then
    warn "Claude Code (claude) not found in PATH"
    warn "Please install Claude Code before using cs"
    warn "Visit: https://github.com/anthropics/claude-code"
    echo ""
fi

# Create install directory if needed
mkdir -p "$INSTALL_DIR"

# Copy cs script
info "Installing cs to $INSTALL_DIR/cs"
cp "$SCRIPT_DIR/bin/cs" "$INSTALL_DIR/cs"
chmod +x "$INSTALL_DIR/cs"

# Check if ~/.local/bin is in PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    warn ""
    warn "WARNING: $INSTALL_DIR is not in your PATH"
    warn ""
    warn "Add this line to your ~/.bashrc, ~/.zshrc, or equivalent:"
    warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    warn ""
fi

info ""
info "Installation complete!"
info ""
info "Usage: cs <session-name>"
info ""
info "Examples:"
info "  cs debug-api    # Create or resume 'debug-api' session"
info "  cs server-fix   # Create or resume 'server-fix' session"
info ""
