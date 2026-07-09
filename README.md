# VS Code Workspace Migrator

Use this script when your top-level work directory has been renamed and you want to restore your GitHub Copilot chat/session history in VS Code.

## Prerequisites

- Windows with PowerShell 5.1+
- VS Code must be **closed** before running the real migration

## Quick Start

### 1. Test first (safe — never touches real files)

```powershell
.\Migrate-VSCodeWorkspaceHistory.ps1 `
    -OldPathPrefix "C:\OldFolderName" `
    -NewPathPrefix "C:\NewFolderName" `
    -TestMode
```

Inspect the sandbox output at `%TEMP%\VSCodeMigrateTest` to verify results.

### 2. Run the real migration

Close VS Code, then:

```powershell
.\Migrate-VSCodeWorkspaceHistory.ps1 `
    -OldPathPrefix "C:\OldFolderName" `
    -NewPathPrefix "C:\NewFolderName"
```

Reopen VS Code — your chat history will be restored.

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-OldPathPrefix` | Yes | The old top-level directory (e.g. `C:\Workspace`) |
| `-NewPathPrefix` | Yes | The new top-level directory (e.g. `C:\IGTTools`) |
| `-VSCodeStoragePath` | No | Override the default storage path (useful for migrating another user's profile) |
| `-TestMode` | No | Clones storage to a sandbox and runs there — real files are never touched |
| `-WhatIf` | No | Preview all actions without copying anything |
| `-Force` | No | Overwrite files that already exist in the destination |

## How It Works

1. Scans every folder under VS Code's `workspaceStorage\` directory that contains a `workspace.json`
2. Builds a lookup table of all known URI → storage folder mappings
3. Finds any entry whose path starts with `-OldPathPrefix`
4. Derives the equivalent new URI by swapping the prefix
5. Looks up that new URI in the lookup table
   - **Found** → copies `chatSessions\`, `chatEditingSessions\`, and `GitHub.copilot-chat\` from the old folder into the new one
   - **Not found** → prints a `[WARN]` and skips (see Notes below)
6. Skips files that already exist in the destination (unless `-Force` is used)
7. Prints a summary when complete

Nothing is deleted — old storage folders are left completely intact.

## Notes

- Safe to run multiple times — existing files are skipped unless `-Force` is used
- Old workspace storage folders are **not deleted** by this script
- Repos that appear as `[WARN] No matching new-path folder found` have not been opened under the new path yet in VS Code. Simply open the repo once in VS Code under the new path (which creates the storage folder), then re-run the script
  > VS Code names each storage folder using a hash of the workspace path. Until you open a folder under the new path, no hash exists for it and there is nowhere for the script to copy the history to.

