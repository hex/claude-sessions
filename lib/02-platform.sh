# ABOUTME: cs_platform() — the single OS/environment seam (macos|wsl|msys|linux).
# ABOUTME: Everything that branches on platform keys off this; nothing else calls uname.

# Returns one of: macos | wsl | msys | linux   (cached after first detect)
cs_platform() {
    # Test/override seam: FIRST branch, validated, cache-bypassing.
    if [ -n "${CS_PLATFORM_OVERRIDE:-}" ]; then
        case "$CS_PLATFORM_OVERRIDE" in
            macos|wsl|msys|linux) printf '%s' "$CS_PLATFORM_OVERRIDE"; return 0 ;;
            *) printf 'cs: invalid CS_PLATFORM_OVERRIDE: %s\n' "$CS_PLATFORM_OVERRIDE" >&2; return 1 ;;
        esac
    fi
    [ -n "${_CS_PLATFORM:-}" ] && { printf '%s' "$_CS_PLATFORM"; return 0; }
    local p
    case "$(uname -s 2>/dev/null)" in
        Darwin) p=macos ;;
        MINGW*|MSYS*|CYGWIN*) p=msys ;;
        Linux)
            if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
                p=wsl
            else
                p=linux
            fi ;;
        *) p=linux ;;
    esac
    _CS_PLATFORM="$p"; printf '%s' "$p"
}
