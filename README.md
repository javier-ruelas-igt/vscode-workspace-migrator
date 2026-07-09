# VS Code Workspace Migrator

Use this script when your top-level work directory has been renamed and you want to restore your GitHub Copilot chat/session history in VS Code.

## Prerequisites

- Windows with **PowerShell 5.1+**
- **Node.js** in your PATH (required for database migration — see [How It Works](#how-it-works))
- **VS Code must be fully closed** before running the real migration (the script will warn you if it isn't)

> **Execution policy error?** If PowerShell blocks the script with "not digitally signed", use `powershell -ExecutionPolicy Bypass -File .\Migrate-VSCodeWorkspaceHistory.ps1 ...` — this bypasses signing for that one invocation only and does not change any system settings.

## Quick Start

### 1. Test first (safe — never touches real files)

```powershell
powershell -ExecutionPolicy Bypass -File .\Migrate-VSCodeWorkspaceHistory.ps1 `
    -OldPathPrefix "C:\OldFolderName" `
    -NewPathPrefix "C:\NewFolderName" `
    -TestMode
```

Inspect the sandbox output at `%TEMP%\VSCodeMigrateTest` to verify results.

### 2. Close VS Code completely, then run the real migration

```powershell
powershell -ExecutionPolicy Bypass -File .\Migrate-VSCodeWorkspaceHistory.ps1 `
    -OldPathPrefix "C:\OldFolderName" `
    -NewPathPrefix "C:\NewFolderName"
```

Reopen VS Code — your chat history will be restored.

> **Why must VS Code be closed?**
> VS Code keeps `state.vscdb` open in memory for every workspace that is loaded. If you run this script while VS Code is open and then reload any window, VS Code will flush its in-memory state back to disk and overwrite the migrated session index. The script detects running `Code.exe` processes and prompts you to abort.

### 3. Re-run for repos opened after the rename

Any repos that show `[WARN] No matching new-path folder found` have not been opened under the new path yet, so there is no destination folder to copy into. Open each one once in VS Code (which creates the storage folder), close VS Code, and re-run the script.

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

VS Code stores workspace history in two separate places. Both must be migrated — **copying only the files is not enough to restore sessions in the UI**.

### 1. History files

Each workspace's storage folder (named by a hash of the workspace path) contains three sub-folders with the actual chat content:

| Folder | Contents |
|---|---|
| `chatSessions\` | Copilot Chat conversation history (`.jsonl` files) |
| `chatEditingSessions\` | Copilot Edit session history |
| `GitHub.copilot-chat\` | Additional Copilot metadata and transcripts |

The script copies these from the old hash folder to the new one. Files that already exist are skipped unless `-Force` is used.

### 2. The session index in `state.vscdb` (SQLite)

This is the part that caused the initial migration to appear to succeed but show nothing in VS Code. Each workspace folder also contains a `state.vscdb` SQLite database. VS Code reads a key called `chat.ChatSessionStore.index` from this database to know which sessions exist. **If that key is missing or empty in the new workspace's database, VS Code shows no sessions — even if all the `.jsonl` files are present.**

When you rename your root directory, VS Code creates a brand-new `state.vscdb` for the new workspace hash with an empty session index. The script uses VS Code's own bundled `@vscode/sqlite3` Node module to merge the old index into the new database, rewriting all path references from the old prefix to the new one. The following keys are migrated:

| Key | Strategy |
|---|---|
| `chat.ChatSessionStore.index` | **Merged** — old and new session entries are combined so nothing is lost |
| `agentSessions.state.cache` | Copied if old has more data than new |
| `agentSessions.readDateBaseline2` | Copied if old has more data than new |
| `workbench.view.chat.sessions.state` | Copied if old has more data than new |
| `memento/interactive-session-view-copilot` | Copied if old has more data than new |

### Why the script uses VS Code's own sqlite3

VS Code ships its own native `@vscode/sqlite3` build inside its installation directory. Using that module (rather than a system-installed one) avoids ABI mismatches and means the script has no additional npm dependencies. The script locates the module by resolving the `code` command from PATH and navigating to the installation directory.

If `node` is not in PATH, or the sqlite3 module cannot be found, the file migration still runs but a warning is printed that the database step was skipped. In that case, sessions will not appear in VS Code until the database is fixed by running the script again with Node available.

## Notes

- Safe to run multiple times — existing files are skipped unless `-Force` is used
- Old workspace storage folders are **not deleted** by this script
- The `-Force` flag only affects file copying; the database merge always runs (it uses a non-destructive merge strategy)


