#Requires -Version 7.0
# ABOUTME: PowerShell 7 installation script for cs (Claude Code session manager)
# ABOUTME: Installs binaries, hooks, commands, skills, and shell completions

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$SkipCompletions,
    [string]$InstallPath = "$HOME/.local/bin"
)

$ErrorActionPreference = 'Stop'

# Colors for output
function Write-Success { param($Message) Write-Host $Message -ForegroundColor Green }
function Write-Warn { param($Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Err { param($Message) Write-Host "Error: $Message" -ForegroundColor Red }

# Configuration
$script:Config = @{
    InstallDir       = $InstallPath
    HooksDir         = "$HOME/.claude/hooks"
    CommandsDir      = "$HOME/.claude/commands"
    SkillsDir        = "$HOME/.claude/skills"
    ClaudeSettings   = "$HOME/.claude/settings.json"
    SessionsDir      = "$HOME/.claude-sessions"
    PwshCompletionDir = "$HOME/.config/powershell/completions"
    RepoUrl          = "https://raw.githubusercontent.com/hex/claude-sessions/main"
}

# Detect if running from cloned repo or web install
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { $null }
$IsLocalInstall = $ScriptDir -and (Test-Path "$ScriptDir/bin/cs")

function Get-FileFromSource {
    param(
        [string]$LocalPath,
        [string]$RemoteUrl,
        [string]$Destination
    )

    $destDir = Split-Path -Parent $Destination
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    if ($IsLocalInstall -and (Test-Path $LocalPath)) {
        Copy-Item -Path $LocalPath -Destination $Destination -Force
    } else {
        Invoke-RestMethod -Uri $RemoteUrl -OutFile $Destination
    }
}

function Set-UnixExecutable {
    param([string]$Path)

    if (-not $IsWindows) {
        & chmod +x $Path
    }
}

function Install-CsBinaries {
    Write-Success "Installing cs to $($Config.InstallDir)/cs"

    if (-not (Test-Path $Config.InstallDir)) {
        New-Item -ItemType Directory -Path $Config.InstallDir -Force | Out-Null
    }

    # Install cs
    Get-FileFromSource `
        -LocalPath "$ScriptDir/bin/cs" `
        -RemoteUrl "$($Config.RepoUrl)/bin/cs" `
        -Destination "$($Config.InstallDir)/cs"

    Set-UnixExecutable "$($Config.InstallDir)/cs"

    # Install cs-secrets
    Write-Success "Installing cs-secrets to $($Config.InstallDir)/cs-secrets"
    Get-FileFromSource `
        -LocalPath "$ScriptDir/bin/cs-secrets" `
        -RemoteUrl "$($Config.RepoUrl)/bin/cs-secrets" `
        -Destination "$($Config.InstallDir)/cs-secrets"

    Set-UnixExecutable "$($Config.InstallDir)/cs-secrets"
}

function Install-ClaudeHooks {
    Write-Success "Installing hooks to $($Config.HooksDir)"

    $hooks = @(
        'session-start.sh',
        'artifact-tracker.sh',
        'changes-tracker.sh',
        'discoveries-reminder.sh',
        'session-end.sh'
    )

    foreach ($hook in $hooks) {
        Get-FileFromSource `
            -LocalPath "$ScriptDir/hooks/$hook" `
            -RemoteUrl "$($Config.RepoUrl)/hooks/$hook" `
            -Destination "$($Config.HooksDir)/$hook"

        Set-UnixExecutable "$($Config.HooksDir)/$hook"
    }
}

function Install-ClaudeCommands {
    Write-Success "Installing commands to $($Config.CommandsDir)"

    Get-FileFromSource `
        -LocalPath "$ScriptDir/commands/summary.md" `
        -RemoteUrl "$($Config.RepoUrl)/commands/summary.md" `
        -Destination "$($Config.CommandsDir)/summary.md"
}

function Install-ClaudeSkills {
    Write-Success "Installing skills to $($Config.SkillsDir)"

    Get-FileFromSource `
        -LocalPath "$ScriptDir/skills/store-secret/SKILL.md" `
        -RemoteUrl "$($Config.RepoUrl)/skills/store-secret/SKILL.md" `
        -Destination "$($Config.SkillsDir)/store-secret/SKILL.md"
}

function Merge-ClaudeSettings {
    Write-Success "Configuring Claude Code hooks"

    $settingsDir = Split-Path -Parent $Config.ClaudeSettings
    if (-not (Test-Path $settingsDir)) {
        New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
    }

    # Load existing settings or start fresh
    $settings = if (Test-Path $Config.ClaudeSettings) {
        Get-Content $Config.ClaudeSettings -Raw | ConvertFrom-Json -AsHashtable
    } else {
        @{}
    }

    # Ensure hooks structure exists
    if (-not $settings.ContainsKey('hooks')) {
        $settings['hooks'] = @{}
    }

    # Helper to add/update a hook
    function Add-Hook {
        param(
            [string]$EventName,
            [string]$HookPath,
            [string]$Matcher = $null
        )

        $hookEntry = @{
            hooks = @(
                @{
                    type    = 'command'
                    command = $HookPath
                    timeout = 10
                }
            )
        }

        if ($null -ne $Matcher) {
            $hookEntry['matcher'] = $Matcher
        }

        # Get existing hooks for this event, filter out our hook if present
        $existingHooks = @()
        if ($settings['hooks'].ContainsKey($EventName)) {
            $existingHooks = @($settings['hooks'][$EventName] | Where-Object {
                $dominated = $false
                if ($_.hooks) {
                    foreach ($h in $_.hooks) {
                        if ($h.command -eq $HookPath) {
                            $dominated = $true
                            break
                        }
                    }
                }
                -not $dominated
            })
        }

        $settings['hooks'][$EventName] = @($existingHooks) + @($hookEntry)
    }

    # Configure all hooks
    Add-Hook -EventName 'SessionStart' -HookPath "$HOME/.claude/hooks/session-start.sh"
    Add-Hook -EventName 'PreToolUse' -HookPath "$HOME/.claude/hooks/artifact-tracker.sh" -Matcher 'Write'
    Add-Hook -EventName 'PostToolUse' -HookPath "$HOME/.claude/hooks/changes-tracker.sh" -Matcher ''
    Add-Hook -EventName 'Stop' -HookPath "$HOME/.claude/hooks/discoveries-reminder.sh"
    Add-Hook -EventName 'SessionEnd' -HookPath "$HOME/.claude/hooks/session-end.sh"

    # Write settings back
    $settings | ConvertTo-Json -Depth 10 | Set-Content $Config.ClaudeSettings -Encoding UTF8
}

function Install-PwshCompletions {
    if ($SkipCompletions) {
        Write-Warn "Skipping PowerShell completions (--SkipCompletions specified)"
        return
    }

    Write-Success "Installing PowerShell completions to $($Config.PwshCompletionDir)"

    Get-FileFromSource `
        -LocalPath "$ScriptDir/completions/cs.ps1" `
        -RemoteUrl "$($Config.RepoUrl)/completions/cs.ps1" `
        -Destination "$($Config.PwshCompletionDir)/cs.ps1"

    # Check if profile sources completions
    $profileDir = Split-Path -Parent $PROFILE
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }

    $completionSource = ". `"$($Config.PwshCompletionDir)/cs.ps1`""

    if (-not (Test-Path $PROFILE)) {
        Write-Warn "PowerShell profile not found. Creating it..."
        $completionSource | Set-Content $PROFILE -Encoding UTF8
    } elseif (-not (Select-String -Path $PROFILE -Pattern 'completions/cs\.ps1' -Quiet)) {
        Write-Warn ""
        Write-Warn "To enable tab completion, add to your PowerShell profile ($PROFILE):"
        Write-Warn "  $completionSource"
        Write-Warn ""
    }
}

function Test-PathInEnvironment {
    $pathDirs = $env:PATH -split [IO.Path]::PathSeparator
    $normalizedInstallDir = $Config.InstallDir.Replace('\', '/').TrimEnd('/')

    foreach ($dir in $pathDirs) {
        $normalizedDir = $dir.Replace('\', '/').TrimEnd('/')
        if ($normalizedDir -eq $normalizedInstallDir) {
            return $true
        }
    }
    return $false
}

function Show-PathWarning {
    if (-not (Test-PathInEnvironment)) {
        Write-Warn ""
        Write-Warn "WARNING: $($Config.InstallDir) is not in your PATH"
        Write-Warn ""

        if ($IsWindows) {
            Write-Warn "Add to your PowerShell profile ($PROFILE):"
            Write-Warn "  `$env:PATH = `"$($Config.InstallDir)`" + [IO.Path]::PathSeparator + `$env:PATH"
        } else {
            Write-Warn "Add to your shell profile (~/.bashrc, ~/.zshrc, or $PROFILE):"
            Write-Warn "  export PATH=`"$($Config.InstallDir):`$PATH`""
        }
        Write-Warn ""
    }
}

function Show-CompletionSummary {
    Write-Host ""
    Write-Host "Installed:" -ForegroundColor Cyan
    Write-Host "  - cs command to $($Config.InstallDir)/cs" -ForegroundColor Cyan
    Write-Host "  - cs-secrets command to $($Config.InstallDir)/cs-secrets" -ForegroundColor Cyan
    Write-Host "  - Session hooks to $($Config.HooksDir)/" -ForegroundColor Cyan
    Write-Host "  - Slash commands to $($Config.CommandsDir)/" -ForegroundColor Cyan
    Write-Host "  - Skills to $($Config.SkillsDir)/" -ForegroundColor Cyan
    Write-Host "  - PowerShell completions to $($Config.PwshCompletionDir)/" -ForegroundColor Cyan
    Write-Host "  - Hook configuration in $($Config.ClaudeSettings)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage: cs <session-name>" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor DarkGray
    Write-Host "  cs debug-api    # Create or resume 'debug-api' session" -ForegroundColor DarkGray
    Write-Host "  cs server-fix   # Create or resume 'server-fix' session" -ForegroundColor DarkGray
    Write-Host ""
}

# Main installation flow
function Install-Cs {
    # Check for Claude Code
    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $claudeCmd) {
        Write-Warn "Claude Code (claude) not found in PATH"
        Write-Warn "Please install Claude Code before using cs"
        Write-Warn "Visit: https://github.com/anthropics/claude-code"
        Write-Host ""
    }

    Install-CsBinaries
    Install-ClaudeHooks
    Install-ClaudeCommands
    Install-ClaudeSkills
    Merge-ClaudeSettings
    Install-PwshCompletions

    Show-PathWarning

    Write-Success ""
    Write-Success "Installation complete!"

    Show-CompletionSummary
}

# Run installation
Install-Cs
