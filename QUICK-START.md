# Quick Start

## Prerequisites
- [Node.js](https://nodejs.org/) installed and in your PATH (required for chat session index migration)

## Steps

### Step 0 — Open every repo in VS Code first (skip if already done)

The migration script can only restore history for folders that VS Code has already opened under the new path. If you haven't opened your repos yet, this companion script does it in one go:

```powershell
cd C:\IGTTools   # your new workspace root
powershell -ExecutionPolicy Bypass -File path\to\Open-WorkspaceFoldersInVSCode.ps1
```

> **Warning — resource intensive:** this opens every sub-folder as a separate VS Code window simultaneously. On a machine with many repos this will spike CPU and RAM while each window loads extensions and indexes files. Wait for things to settle, then close all VS Code windows before continuing.
>
> For repos nested more than one level deep (e.g. `github\org\repo`), add `-Recurse` to find them by `.git` directory instead of by immediate sub-folder.

---

### Step 1 — Run the migration

1. Close all VS Code windows
2. Open PowerShell, navigate to this folder, and run:

```powershell
cd C:\IGTTools\github\vscode-workspace-migrator
powershell -ExecutionPolicy Bypass -File .\Migrate-VSCodeWorkspaceHistory.ps1 -OldPathPrefix "C:\OldFolderName" -NewPathPrefix "C:\NewFolderName"
```

> **Getting a security error?** The `-ExecutionPolicy Bypass` flag above bypasses the script signing requirement for this one invocation only — it does not change any system settings.

3. Reopen VS Code — your chat history will be restored

> If you see `DB migration : DISABLED` in the output, Node.js was not found and the session index was not migrated. Install Node.js and re-run with VS Code closed.

---

### Step 2 — Re-run for any remaining repos

Any repos that printed `[WARN] No matching new-path folder found` were not yet opened under the new path when the script ran. Open them in VS Code, close VS Code, and re-run Step 1.

---

**Not sure it'll work?** Do a safe test run first (no real files touched):

```powershell
powershell -ExecutionPolicy Bypass -File .\Migrate-VSCodeWorkspaceHistory.ps1 -OldPathPrefix "C:\OldFolderName" -NewPathPrefix "C:\NewFolderName" -TestMode
```

See `README.md` for full parameter reference.
