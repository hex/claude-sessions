# ABOUTME: Release verification (SHA-256 + minisign) and the self-update mechanism.
# ABOUTME: Backs 'cs -update' and the non-blocking update-available notice.

# --- Release verification ---

# Verify SHA-256 checksum (hard gate — always runs)
verify_checksum() {
    local file="$1" checksumfile="$2"
    local expected actual
    expected=$(awk '{print $1}' "$checksumfile")
    if command -v sha256sum &>/dev/null; then
        actual=$(sha256sum "$file" | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
    else
        # Fail closed: a verification gate that can't verify must not pass.
        echo "Error: no sha256sum or shasum found — cannot verify download. Install one and retry." >&2
        return 1
    fi
    [ "$expected" = "$actual" ]
}

# Verify minisign signature (soft gate — only if minisign installed)
verify_signature() {
    local file="$1" sigfile="$2"
    local ms_bin
    ms_bin=$(command -v minisign 2>/dev/null) || ms_bin="$HOME/.local/bin/minisign"
    [ -x "$ms_bin" ] || return 0
    "$ms_bin" -Vm "$file" -P "$CS_SIGN_PUBKEY" -x "$sigfile" >/dev/null 2>&1
}

# --- Update mechanism ---

# Fetch latest version from GitHub Releases
get_remote_version() {
    curl -fsSL --connect-timeout 2 --max-time 4 \
        "${RELEASES_BASE}/latest" -o /dev/null -w '%{url_effective}' 2>/dev/null \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//'
}

# Compare versions (YYYY.MM.N format). Returns 0 if v1 > v2, 1 otherwise
version_greater() {
    local v1="$1" v2="$2"

    # Split into components
    local y1 m1 n1 y2 m2 n2
    IFS='.' read -r y1 m1 n1 <<< "$v1"
    IFS='.' read -r y2 m2 n2 <<< "$v2"

    # Compare year
    if [ "$y1" -gt "$y2" ] 2>/dev/null; then return 0; fi
    if [ "$y1" -lt "$y2" ] 2>/dev/null; then return 1; fi

    # Compare month
    if [ "$m1" -gt "$m2" ] 2>/dev/null; then return 0; fi
    if [ "$m1" -lt "$m2" ] 2>/dev/null; then return 1; fi

    # Compare patch
    if [ "$n1" -gt "$n2" ] 2>/dev/null; then return 0; fi

    return 1
}

# Check for updates
check_update() {
    local remote_version
    remote_version=$(get_remote_version) || {
        error "Failed to check for updates. Check your internet connection."
    }

    echo -e "Current version: ${GREEN}$VERSION${NC}"
    echo -e "Latest version:  ${GREEN}$remote_version${NC}"

    if version_greater "$remote_version" "$VERSION"; then
        echo ""
        info "Update available. Run 'cs -update' to install."
        return 0
    else
        echo ""
        info "Already up to date."
        return 0
    fi
}

# Perform update (downloads signed installer from GitHub Releases)
do_update() {
    local force="${1:-false}"
    local remote_version

    remote_version=$(get_remote_version) || {
        error "Failed to fetch update. Check your internet connection."
    }

    local is_upgrade=false
    if version_greater "$remote_version" "$VERSION"; then
        is_upgrade=true
    fi

    echo ""
    if [ "$is_upgrade" = true ]; then
        echo -e "   ${COMMENT}Updating${NC} cs ${COMMENT}from${NC} ${RUST}$VERSION${NC} ${COMMENT}→${NC} ${GREEN}$remote_version${NC}"
    else
        echo -e "   ${COMMENT}Reinstalling${NC} cs ${GREEN}$VERSION${NC}"
    fi
    echo ""

    local releases_url="${RELEASES_BASE}/download/v${remote_version}"
    local tmpdir
    tmpdir=$(mktemp -d)

    # Download install.sh + checksum + signature from release assets
    curl -fsSL "$releases_url/install.sh" -o "$tmpdir/install.sh" || {
        rm -rf "$tmpdir"; error "Failed to download installer."
    }
    curl -fsSL "$releases_url/install.sh.sha256" -o "$tmpdir/install.sh.sha256" || {
        rm -rf "$tmpdir"; error "Failed to download checksum."
    }
    # Signature file is optional (best-effort)
    curl -fsSL "$releases_url/install.sh.minisig" -o "$tmpdir/install.sh.minisig" 2>/dev/null

    # Verify checksum (hard gate)
    if ! verify_checksum "$tmpdir/install.sh" "$tmpdir/install.sh.sha256"; then
        rm -rf "$tmpdir"
        error "Checksum verification failed. Update aborted."
    fi

    # Verify signature if minisign available (soft enhancement)
    if [ -f "$tmpdir/install.sh.minisig" ]; then
        if ! verify_signature "$tmpdir/install.sh" "$tmpdir/install.sh.minisig"; then
            rm -rf "$tmpdir"
            error "Signature verification failed. Update aborted."
        fi
    fi

    info "Verified"

    # Run the verified installer, pinning the payload (cs, cs-secrets, hooks,
    # …) to the same immutable release tag rather than letting it fetch from the
    # mutable main branch. The installer is signature-verified, so it is trusted
    # to fetch its payload from the tag it was published at.
    CS_INSTALL_REF="v${remote_version}" bash "$tmpdir/install.sh"
    rm -rf "$tmpdir"

    # Clear update cache so notification disappears
    rm -f "$HOME/.cache/cs/update-check"

    # Show release notes for the installed version
    local new_version
    new_version=$(grep '^VERSION=' "$HOME/.local/bin/cs" 2>/dev/null | head -1 | cut -d'"' -f2)
    if [ -n "$new_version" ]; then
        local changelog
        local script_dir
        script_dir="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"
        changelog="$(dirname "$script_dir")/CHANGELOG.md"
        if [ -f "$changelog" ]; then
            echo ""
            # Extract section between "## $new_version" and next "## "
            sed -n "/^## ${new_version}$/,/^## [0-9]/{ /^## [0-9]/!p; }" "$changelog" \
                | sed '/^$/N;/^\n$/d'
        else
            echo ""
            echo "  See ${RELEASES_BASE} for what's new."
        fi
    fi

    # Exit immediately to prevent bash from reading more of the old script
    # (the file was just overwritten, continuing would cause errors)
    exit 0
}

# Check for updates periodically and notify (non-blocking)
UPDATE_CACHE="$HOME/.cache/cs/update-check"
UPDATE_CHECK_INTERVAL=3600  # 1 hour in seconds
UPDATE_AVAILABLE=""  # Set by check_update_notify if update available

check_update_notify() {
    # Opt out of the network check + cache write (tests set this so a session
    # launch never hits GitHub or touches the real ~/.cache/cs).
    [ -n "${CS_NO_UPDATE_CHECK:-}" ] && return 0

    local cache_dir
    cache_dir="$(dirname "$UPDATE_CACHE")"
    mkdir -p "$cache_dir"

    local now
    now=$(date +%s)

    # Check if cache exists and is fresh
    if [ -f "$UPDATE_CACHE" ]; then
        local cache_time cached_version
        read -r cache_time cached_version < "$UPDATE_CACHE" 2>/dev/null || true

        # If cache is fresh, use it
        if [ -n "$cache_time" ] && [ $((now - cache_time)) -lt $UPDATE_CHECK_INTERVAL ]; then
            # Set update available if cached version is newer
            if [ -n "$cached_version" ] && version_greater "$cached_version" "$VERSION"; then
                UPDATE_AVAILABLE="$cached_version"
            fi
        fi
    fi

    # No fresh cache - do a quick synchronous check
    if [ -z "$UPDATE_AVAILABLE" ]; then
        local remote_version
        remote_version=$(get_remote_version 2>/dev/null) || remote_version=""

        if [ -n "$remote_version" ]; then
            echo "$now $remote_version" > "$UPDATE_CACHE"
            if version_greater "$remote_version" "$VERSION"; then
                UPDATE_AVAILABLE="$remote_version"
            fi
        fi
    fi

}

# Check dependencies
