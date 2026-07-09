<#
.SYNOPSIS
    Migrates VS Code workspace chat/session history from an old root path to a new root path.

.DESCRIPTION
    When a top-level workspace directory is renamed, VS Code creates new workspace storage
    folders (keyed by path hash) and loses references to history stored under the old path.
    This script scans all VS Code workspace storage folders, finds entries matching the old
    path prefix, locates the corresponding new-path entry, and copies over the history data.

    Folders migrated per workspace:
      - chatSessions\          (GitHub Copilot chat history)
      - chatEditingSessions\   (Copilot edit session history)
      - GitHub.copilot-chat\   (additional Copilot metadata)

    The script is non-destructive by default (use -WhatIf to preview, -Force to overwrite
    files that already exist in the destination).

.PARAMETER OldPathPrefix
    The old top-level directory path (e.g. "C:\Workspace").
    Case-insensitive. Trailing backslash is optional.

.PARAMETER NewPathPrefix
    The new top-level directory path (e.g. "C:\IGTTools").
    Case-insensitive. Trailing backslash is optional.

.PARAMETER VSCodeStoragePath
    Path to the VS Code workspace storage directory.
    Defaults to the current user's standard location:
    %APPDATA%\Code\User\workspaceStorage

.PARAMETER TestMode
    Copies the entire workspaceStorage folder to a sandbox under
    $env:TEMP\VSCodeMigrateTest and runs the migration there.
    Your real files are NEVER touched. Inspect the sandbox after the run
    to verify results, then re-run without -TestMode to apply for real.

.PARAMETER WhatIf
    Preview all actions without copying any files.

.PARAMETER Force
    Overwrite files that already exist in the destination folder.
    By default, existing files are skipped to protect current history.

.EXAMPLE
    # Preview what would be migrated (no changes made)
    .\Migrate-VSCodeWorkspaceHistory.ps1 -OldPathPrefix "C:\Workspace" -NewPathPrefix "C:\IGTTools" -WhatIf

.EXAMPLE
    # Safe test run - operates on a sandbox copy, real files untouched
    .\Migrate-VSCodeWorkspaceHistory.ps1 -OldPathPrefix "C:\Workspace" -NewPathPrefix "C:\IGTTools" -TestMode

.EXAMPLE
    # Run the real migration (close VS Code first!)
    .\Migrate-VSCodeWorkspaceHistory.ps1 -OldPathPrefix "C:\Workspace" -NewPathPrefix "C:\IGTTools"

.EXAMPLE
    # Run for a different user's storage path
    .\Migrate-VSCodeWorkspaceHistory.ps1 `
        -OldPathPrefix "C:\OldRoot" `
        -NewPathPrefix "C:\NewRoot" `
        -VSCodeStoragePath "C:\Users\otheruser\AppData\Roaming\Code\User\workspaceStorage"

.NOTES
    Safe to run multiple times - existing files in the destination are skipped unless -Force is used.
    The old workspace storage folders are NOT deleted by this script.
    IMPORTANT: Close VS Code before running a real (non-TestMode) migration. VS Code locks
    its .vscdb files while open, which may cause copy errors.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $OldPathPrefix,

    [Parameter(Mandatory)]
    [string] $NewPathPrefix,

    [string] $VSCodeStoragePath = (Join-Path $env:APPDATA "Code\User\workspaceStorage"),

    [switch] $TestMode,

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Normalize-PathPrefix ([string]$p) {
    # Remove trailing slashes, normalise separators, lower-case for comparison
    $p = $p.TrimEnd('\', '/')
    return $p.ToLowerInvariant()
}

# URL-encode a local path the same way VS Code does in workspace.json
# VS Code stores paths as  file:///c%3A/Some/Path  (colon encoded, forward slashes)
function Path-ToVSCodeUri ([string]$localPath) {
    # Normalise separators to forward slash
    $fwd = $localPath.Replace('\', '/')
    # Encode the colon after the drive letter
    $encoded = $fwd -replace '^([a-zA-Z]):', '$1%3A'
    return "file:///$encoded"
}

function Uri-ToLocalPath ([string]$uri) {
    # Reverse of above: file:///c%3A/Foo/Bar  ->  c:\Foo\Bar
    $inner = $uri -replace '^file:///', ''
    $decoded = $inner -replace '%3A', ':' -replace '/', '\'
    return $decoded
}

# Locate VS Code's bundled @vscode/sqlite3 Node module.
# VS Code installs to <base>/<hash>/resources/app/node_modules/@vscode/sqlite3
function Find-VsCodeSqliteModule {
    $codeCmd = Get-Command code -ErrorAction SilentlyContinue
    if (-not $codeCmd) { return $null }

    # code (or code.cmd) lives in <install>\bin\  -- go up one level
    $binDir     = Split-Path $codeCmd.Source -Parent
    $installDir = Split-Path $binDir -Parent

    # The hash sub-folder name is a hex string
    $hashDir = Get-ChildItem $installDir -Directory |
               Where-Object { $_.Name -match '^[0-9a-fA-F]{6,}$' } |
               Select-Object -First 1
    if (-not $hashDir) { return $null }

    $candidate = Join-Path $hashDir.FullName "resources\app\node_modules\@vscode\sqlite3"
    if (Test-Path (Join-Path $candidate "lib\sqlite3.js")) { return $candidate }
    return $null
}

# Migrate the chat session index (and a few other keys) from old state.vscdb to new.
# The critical key is chat.ChatSessionStore.index – without it VS Code shows no sessions
# even though the .jsonl files are present.
function Invoke-StateDatabaseMigration {
    param(
        [string] $OldDbPath,
        [string] $NewDbPath,
        [string] $OldPathPrefix,
        [string] $NewPathPrefix,
        [string] $NodeExe,
        [string] $SqliteModulePath
    )

    if (-not (Test-Path $OldDbPath)) { return }
    if (-not (Test-Path $NewDbPath)) { return }

    # Inline Node.js script written to a temp file so we avoid quoting nightmares
    $nodeScript = @'
const sqlite3 = require(process.env.SQLITE_MODULE);
const oldDbPath  = process.env.OLD_DB;
const newDbPath  = process.env.NEW_DB;
const oldPrefix  = process.env.OLD_PREFIX;
const newPrefix  = process.env.NEW_PREFIX;

// Keys whose JSON "entries" object should be merged (old+new) rather than replaced.
const MERGE_KEYS = ['chat.ChatSessionStore.index'];
// Keys to copy from old if missing in new (or if old has substantially more data).
const COPY_KEYS  = [
    'agentSessions.state.cache',
    'agentSessions.readDateBaseline2',
    'workbench.view.chat.sessions.state',
    'memento/interactive-session-view-copilot'
];

function replacePaths(str) {
    function escRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
    // JSON-escaped backslash form:  C:\\Workspace\\  ->  C:\\IGTTools\\
    const oldJson = oldPrefix.replace(/\\/g, '\\\\');
    const newJson = newPrefix.replace(/\\/g, '\\\\');
    str = str.replace(new RegExp(escRe(oldJson), 'gi'), newJson);
    // Forward-slash form:  C:/Workspace/  ->  C:/IGTTools/
    const oldFwd = oldPrefix.replace(/\\/g, '/');
    const newFwd = newPrefix.replace(/\\/g, '/');
    str = str.replace(new RegExp(escRe(oldFwd), 'gi'), newFwd);
    return str;
}

const oldDb = new sqlite3.Database(oldDbPath, sqlite3.OPEN_READONLY);
const newDb = new sqlite3.Database(newDbPath, sqlite3.OPEN_READWRITE);

function done() { oldDb.close(); newDb.close(); }

function processKeys(keys, idx) {
    if (idx >= keys.length) { done(); return; }
    const key = keys[idx];
    const next = () => processKeys(keys, idx + 1);

    oldDb.get('SELECT value FROM ItemTable WHERE key = ?', [key], (err, oldRow) => {
        if (err || !oldRow) { next(); return; }

        const oldFixed = replacePaths(oldRow.value.toString());

        newDb.get('SELECT value FROM ItemTable WHERE key = ?', [key], (err2, newRow) => {
            let finalValue;

            if (MERGE_KEYS.includes(key)) {
                try {
                    const oldParsed = JSON.parse(oldFixed);
                    if (newRow) {
                        const newParsed = JSON.parse(newRow.value.toString());
                        // Merge entries: old provides base, new takes priority on conflicts
                        const merged = Object.assign({}, oldParsed.entries || {}, newParsed.entries || {});
                        finalValue = JSON.stringify(Object.assign({}, newParsed, { entries: merged }));
                    } else {
                        finalValue = oldFixed;
                    }
                } catch(e) {
                    process.stderr.write('Merge error for ' + key + ': ' + e.message + '\n');
                    next(); return;
                }
            } else {
                // Copy only if old has more data than new (or new is missing it)
                if (newRow && newRow.value.toString().length >= oldFixed.length) { next(); return; }
                finalValue = oldFixed;
            }

            newDb.run('INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)',
                      [key, finalValue], (err3) => {
                if (err3) process.stderr.write('Write error for ' + key + ': ' + err3.message + '\n');
                else      process.stdout.write('  DB-OK  ' + key + '\n');
                next();
            });
        });
    });
}

processKeys([...MERGE_KEYS, ...COPY_KEYS], 0);
'@

    $tmpScript = Join-Path $env:TEMP "vscode_migrate_db_$([System.IO.Path]::GetRandomFileName()).js"
    try {
        Set-Content -Path $tmpScript -Value $nodeScript -Encoding UTF8

        $env:SQLITE_MODULE = $SqliteModulePath
        $env:OLD_DB        = $OldDbPath
        $env:NEW_DB        = $NewDbPath
        $env:OLD_PREFIX    = $OldPathPrefix
        $env:NEW_PREFIX    = $NewPathPrefix

        & $NodeExe $tmpScript
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "state.vscdb migration returned non-zero exit code for $OldDbPath"
        }
    } finally {
        Remove-Item $tmpScript -ErrorAction SilentlyContinue
        Remove-Item Env:\SQLITE_MODULE -ErrorAction SilentlyContinue
        Remove-Item Env:\OLD_DB        -ErrorAction SilentlyContinue
        Remove-Item Env:\NEW_DB        -ErrorAction SilentlyContinue
        Remove-Item Env:\OLD_PREFIX    -ErrorAction SilentlyContinue
        Remove-Item Env:\NEW_PREFIX    -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# TestMode: clone workspaceStorage into a sandbox before doing anything
# ---------------------------------------------------------------------------

if ($TestMode) {
    $sandbox = Join-Path $env:TEMP "VSCodeMigrateTest"
    if (Test-Path $sandbox) {
        Remove-Item $sandbox -Recurse -Force
    }
    Write-Host ""
    Write-Host "TEST MODE: Cloning workspaceStorage to sandbox..." -ForegroundColor Yellow
    Write-Host "  Source : $VSCodeStoragePath" -ForegroundColor Yellow
    Write-Host "  Sandbox: $sandbox"            -ForegroundColor Yellow
    Copy-Item -Path $VSCodeStoragePath -Destination $sandbox -Recurse -Force
    $VSCodeStoragePath = $sandbox
    Write-Host "  Clone complete. Real files will NOT be touched." -ForegroundColor Yellow
    Write-Host ""
}

if (-not (Test-Path $VSCodeStoragePath -PathType Container)) {
    Write-Error "VS Code storage path not found: $VSCodeStoragePath"
    exit 1
}

$oldNorm = Normalize-PathPrefix $OldPathPrefix
$newNorm = Normalize-PathPrefix $NewPathPrefix

if ($oldNorm -eq $newNorm) {
    Write-Error "OldPathPrefix and NewPathPrefix are identical. Nothing to do."
    exit 1
}

Write-Host ""
Write-Host "VS Code Workspace History Migration" -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan
Write-Host "  Storage path : $VSCodeStoragePath"
Write-Host "  Old prefix   : $OldPathPrefix"
Write-Host "  New prefix   : $NewPathPrefix"
if ($WhatIfPreference) { Write-Host "  Mode         : DRY RUN (WhatIf)" -ForegroundColor Yellow }
else                    { Write-Host "  Mode         : LIVE"              -ForegroundColor Green  }

# Locate Node.js and VS Code's sqlite3 module for state.vscdb migration
$nodeExe       = (Get-Command node -ErrorAction SilentlyContinue)?.Source
$sqliteModule  = if ($nodeExe) { Find-VsCodeSqliteModule } else { $null }

if (-not $nodeExe) {
    Write-Host "  DB migration : DISABLED (node.exe not found in PATH)" -ForegroundColor Yellow
} elseif (-not $sqliteModule) {
    Write-Host "  DB migration : DISABLED (VS Code sqlite3 module not found)" -ForegroundColor Yellow
} else {
    Write-Host "  DB migration : ENABLED  (chat session index will be merged)" -ForegroundColor Green
}
Write-Host ""

# ---------------------------------------------------------------------------
# Build a lookup: VSCode-URI (lower-case) -> storage folder path
# ---------------------------------------------------------------------------

$uriToFolder = @{}   # new-path uri -> folder path

$allFolders = Get-ChildItem -Path $VSCodeStoragePath -Directory

foreach ($folder in $allFolders) {
    $jsonPath = Join-Path $folder.FullName "workspace.json"
    if (-not (Test-Path $jsonPath)) { continue }

    try {
        $json = Get-Content $jsonPath -Raw | ConvertFrom-Json
        $uri  = if ($json.folder) { $json.folder } elseif ($json.workspace) { $json.workspace } else { $null }
        if ($uri) {
            $uriToFolder[$uri.ToLowerInvariant()] = $folder.FullName
        }
    } catch {
        Write-Warning "Could not parse $jsonPath - skipping."
    }
}

# ---------------------------------------------------------------------------
# The sub-folders we want to migrate
# ---------------------------------------------------------------------------

$historyFolders = @(
    "chatSessions",
    "chatEditingSessions",
    "GitHub.copilot-chat"
)

# ---------------------------------------------------------------------------
# Main migration loop
# ---------------------------------------------------------------------------

$totalMigrated  = 0
$totalSkipped   = 0
$totalWorkspaces = 0

foreach ($folder in $allFolders) {
    $jsonPath = Join-Path $folder.FullName "workspace.json"
    if (-not (Test-Path $jsonPath)) { continue }

    try {
        $json = Get-Content $jsonPath -Raw | ConvertFrom-Json
        $uri  = if ($json.folder) { $json.folder } elseif ($json.workspace) { $json.workspace } else { $null }
        if (-not $uri) { continue }
    } catch { continue }

    # Check if this entry belongs to the old prefix
    $localPath = Uri-ToLocalPath $uri
    if ($localPath.ToLowerInvariant() -notlike "$oldNorm*") { continue }

    # Derive what the new path would be
    $newLocalPath = $NewPathPrefix + $localPath.Substring($OldPathPrefix.Length)
    $newUri       = (Path-ToVSCodeUri $newLocalPath).ToLowerInvariant()

    # Find the corresponding new-path storage folder
    $newFolder = $uriToFolder[$newUri]
    if (-not $newFolder) {
        Write-Host "  [WARN] No matching new-path folder found for:" -ForegroundColor Yellow
        Write-Host "         Old: $localPath"
        Write-Host "         New: $newLocalPath  (not yet opened in VS Code?)"
        Write-Host ""
        continue
    }

    Write-Host "Workspace: $localPath" -ForegroundColor White
    Write-Host "     -> $newLocalPath"

    $workspaceMigrated = 0
    $workspaceSkipped  = 0

    foreach ($subDir in $historyFolders) {
        $srcDir = Join-Path $folder.FullName $subDir
        if (-not (Test-Path $srcDir -PathType Container)) { continue }

        $dstDir = Join-Path $newFolder $subDir

        $files = Get-ChildItem -Path $srcDir -File -Recurse
        if ($files.Count -eq 0) { continue }

        foreach ($file in $files) {
            # Preserve relative sub-path within the history folder
            $relative = $file.FullName.Substring($srcDir.Length).TrimStart('\')
            $dstFile  = Join-Path $dstDir $relative

            if ((Test-Path $dstFile) -and -not $Force) {
                Write-Host "    SKIP  (already exists) $subDir\$relative" -ForegroundColor DarkGray
                $workspaceSkipped++
                continue
            }

            $action = if (Test-Path $dstFile) { "OVERWRITE" } else { "COPY" }

            if ($PSCmdlet.ShouldProcess($dstFile, "$action from $($file.FullName)")) {
                $dstParent = Split-Path $dstFile -Parent
                if (-not (Test-Path $dstParent)) {
                    New-Item -ItemType Directory -Path $dstParent -Force | Out-Null
                }
                Copy-Item -Path $file.FullName -Destination $dstFile -Force
                Write-Host "    OK    $subDir\$relative" -ForegroundColor Green
                $workspaceMigrated++
            } else {
                # WhatIf mode - ShouldProcess printed the action
                $workspaceMigrated++
            }
        }
    }

    if ($workspaceMigrated -eq 0 -and $workspaceSkipped -eq 0) {
        Write-Host "    (no history files found in old folder)" -ForegroundColor DarkGray
    } else {
        Write-Host "    Copied: $workspaceMigrated  |  Skipped (already exist): $workspaceSkipped"
    }

    # Migrate chat session index from state.vscdb so VS Code can discover the sessions
    if ($nodeExe -and $sqliteModule -and -not $WhatIfPreference) {
        $oldDb = Join-Path $folder.FullName "state.vscdb"
        $newDb = Join-Path $newFolder      "state.vscdb"
        Write-Host "    Merging state.vscdb..." -ForegroundColor DarkCyan
        Invoke-StateDatabaseMigration `
            -OldDbPath       $oldDb `
            -NewDbPath       $newDb `
            -OldPathPrefix   $OldPathPrefix `
            -NewPathPrefix   $NewPathPrefix `
            -NodeExe         $nodeExe `
            -SqliteModulePath $sqliteModule
    } elseif ($WhatIfPreference -and $nodeExe -and $sqliteModule) {
        Write-Host "    WHATIF state.vscdb: would merge chat.ChatSessionStore.index and related keys" -ForegroundColor Yellow
    }

    Write-Host ""
    $totalMigrated  += $workspaceMigrated
    $totalSkipped   += $workspaceSkipped
    $totalWorkspaces++
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host "====================================" -ForegroundColor Cyan
Write-Host "Done.  Workspaces processed : $totalWorkspaces"
Write-Host "       Files copied         : $totalMigrated"
Write-Host "       Files skipped        : $totalSkipped"
if ($WhatIfPreference) {
    Write-Host ""
    Write-Host "This was a DRY RUN. Re-run without -WhatIf to apply changes." -ForegroundColor Yellow
}
if ($TestMode) {
    Write-Host ""
    Write-Host "TEST MODE - your real files were NOT touched." -ForegroundColor Yellow
    Write-Host "Inspect the sandbox here: $VSCodeStoragePath"   -ForegroundColor Yellow
    Write-Host "When satisfied, close VS Code and re-run WITHOUT -TestMode." -ForegroundColor Yellow
}
Write-Host ""
