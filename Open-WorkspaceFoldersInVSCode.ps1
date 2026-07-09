<#
.SYNOPSIS
    Opens every immediate sub-folder of a directory as a new VS Code window.

.DESCRIPTION
    Run this from your top-level workspace root (e.g. C:\IGTTools) to open all
    repository folders in VS Code at once. This is useful before running
    Migrate-VSCodeWorkspaceHistory.ps1 — VS Code must have opened each folder at
    least once under the new path so that it creates the workspace storage entry
    (the hash folder) that the migration script copies history into.

    Place this script at your workspace root, or pass -RootPath explicitly.

.PARAMETER RootPath
    The directory whose immediate sub-folders will be opened in VS Code.
    Defaults to the current working directory.

.PARAMETER Recurse
    Open all descendant folders that contain a .git directory, rather than
    just the immediate children of RootPath. Useful if repos are nested
    more than one level deep.

.EXAMPLE
    # Run from your workspace root — opens every immediate sub-folder
    cd C:\IGTTools
    .\Open-WorkspaceFoldersInVSCode.ps1

.EXAMPLE
    # Specify the root explicitly
    .\Open-WorkspaceFoldersInVSCode.ps1 -RootPath "C:\IGTTools"

.EXAMPLE
    # Open all git repos found anywhere under the root (nested layout)
    .\Open-WorkspaceFoldersInVSCode.ps1 -RootPath "C:\IGTTools" -Recurse

.NOTES
    Each folder opens in its own VS Code window (-n flag).
    VS Code must be in your PATH (the 'code' command must work).
    After all windows have opened and VS Code has registered them, close VS Code
    and run Migrate-VSCodeWorkspaceHistory.ps1 to restore chat history.
#>

param(
    [string] $RootPath = (Get-Location).Path,
    [switch] $Recurse
)

$codeCmd = Get-Command code -ErrorAction SilentlyContinue
if (-not $codeCmd) {
    Write-Error "The 'code' command was not found. Make sure VS Code is installed and 'code' is in your PATH."
    exit 1
}

if (-not (Test-Path $RootPath -PathType Container)) {
    Write-Error "RootPath not found: $RootPath"
    exit 1
}

if ($Recurse) {
    $folders = Get-ChildItem -Path $RootPath -Recurse -Directory -Filter ".git" |
               ForEach-Object { $_.Parent }
} else {
    $folders = Get-ChildItem -Path $RootPath -Directory
}

if (-not $folders) {
    Write-Host "No folders found under: $RootPath" -ForegroundColor Yellow
    exit 0
}

Write-Host "Opening $($folders.Count) folder(s) in VS Code..." -ForegroundColor Cyan
foreach ($folder in $folders) {
    Write-Host "  $($folder.FullName)"
    code -n $folder.FullName
}

Write-Host ""
Write-Host "Done. Once VS Code finishes loading all windows:" -ForegroundColor Green
Write-Host "  1. Close VS Code completely" -ForegroundColor Green
Write-Host "  2. Run Migrate-VSCodeWorkspaceHistory.ps1 to restore chat history" -ForegroundColor Green
