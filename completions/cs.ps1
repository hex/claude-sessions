# ABOUTME: PowerShell completion script for cs (Claude Code session manager)
# ABOUTME: Provides tab-completion for session names, commands, and subcommands

using namespace System.Management.Automation
using namespace System.Management.Automation.Language

# Get session names from sessions directory
function Get-CsSessions {
    $sessionsRoot = if ($env:CS_SESSIONS_ROOT) { $env:CS_SESSIONS_ROOT } else { "$HOME/.claude-sessions" }

    if (Test-Path $sessionsRoot) {
        Get-ChildItem -Path $sessionsRoot -Directory | Select-Object -ExpandProperty Name
    }
}

Register-ArgumentCompleter -Native -CommandName cs -ScriptBlock {
    param(
        [string]$wordToComplete,
        [CommandAst]$commandAst,
        [int]$cursorPosition
    )

    # Parse command elements
    $elements = $commandAst.CommandElements
    $tokens = @($elements | ForEach-Object { $_.Extent.Text })

    # Define completion data
    $globalFlags = @{
        '-list'      = 'List all sessions'
        '-ls'        = 'List all sessions (alias)'
        '-remove'    = 'Remove a session'
        '-rm'        = 'Remove a session (alias)'
        '-sync'      = 'Sync current session'
        '-s'         = 'Sync current session (alias)'
        '-secrets'   = 'Manage session secrets'
        '-update'    = 'Update cs to latest version'
        '-uninstall' = 'Uninstall cs'
        '-help'      = 'Show help message'
        '-h'         = 'Show help message (alias)'
        '-version'   = 'Show version'
        '-v'         = 'Show version (alias)'
    }

    $syncCmds = @{
        'init'   = 'Initialize git repo with remote URL'
        'push'   = 'Commit and push changes'
        'pull'   = 'Pull changes from remote'
        'status' = 'Show sync status'
        'st'     = 'Show sync status (alias)'
        'auto'   = 'Toggle/show auto-sync setting'
        'clone'  = 'Clone session from remote'
    }

    $secretsCmds = @{
        'set'         = 'Store a secret'
        'store'       = 'Store a secret (alias)'
        'get'         = 'Retrieve a secret value'
        'list'        = 'List all secrets'
        'ls'          = 'List all secrets (alias)'
        'delete'      = 'Delete a secret'
        'rm'          = 'Delete a secret (alias)'
        'purge'       = 'Delete ALL secrets'
        'export'      = 'Export as environment variables'
        'export-file' = 'Export to encrypted file'
        'import-file' = 'Import from encrypted file'
        'migrate'     = 'Migrate plaintext secrets'
        'backend'     = 'Show storage backend'
    }

    $sessionOpts = @{
        '-sync'    = 'Run sync command'
        '-s'       = 'Run sync command (alias)'
        '-secrets' = 'Run secrets command'
    }

    # Determine context by examining previous tokens
    $inSync = $false
    $inSecrets = $false
    $hasSession = $false
    $afterRemove = $false

    for ($i = 1; $i -lt $tokens.Count; $i++) {
        $token = $tokens[$i]

        # Skip the word currently being completed
        if ($i -eq ($tokens.Count - 1) -and $token -eq $wordToComplete) {
            continue
        }

        switch -Regex ($token) {
            '^(-sync|-s)$' { $inSync = $true; $inSecrets = $false }
            '^-secrets$' { $inSecrets = $true; $inSync = $false }
            '^(-remove|-rm)$' { $afterRemove = $true }
            '^-' { }
            default {
                if (-not $inSync -and -not $inSecrets -and -not $afterRemove) {
                    $hasSession = $true
                }
            }
        }
    }

    # Helper to create completion results
    function New-Completion {
        param([string]$Text, [string]$Tooltip)
        [CompletionResult]::new($Text, $Text, 'ParameterValue', $Tooltip)
    }

    # Context: after -remove/-rm - complete with session names
    if ($afterRemove -and $tokens.Count -eq 3) {
        Get-CsSessions | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
            New-Completion $_ "Session: $_"
        }
        return
    }

    # Context: after -sync/-s - complete with sync subcommands
    if ($inSync) {
        $syncCmds.GetEnumerator() | Where-Object { $_.Key -like "$wordToComplete*" } | ForEach-Object {
            New-Completion $_.Key $_.Value
        }
        return
    }

    # Context: after -secrets - complete with secrets subcommands
    if ($inSecrets) {
        $secretsCmds.GetEnumerator() | Where-Object { $_.Key -like "$wordToComplete*" } | ForEach-Object {
            New-Completion $_.Key $_.Value
        }
        return
    }

    # Context: after session name - complete with session options
    if ($hasSession) {
        $sessionOpts.GetEnumerator() | Where-Object { $_.Key -like "$wordToComplete*" } | ForEach-Object {
            New-Completion $_.Key $_.Value
        }
        return
    }

    # First argument: flags or session names
    if ($tokens.Count -le 2) {
        if ($wordToComplete -like '-*') {
            # Complete flags
            $globalFlags.GetEnumerator() | Where-Object { $_.Key -like "$wordToComplete*" } | ForEach-Object {
                New-Completion $_.Key $_.Value
            }
        } else {
            # Complete session names
            Get-CsSessions | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
                New-Completion $_ "Session: $_"
            }
        }
    }
}
