# Quick Start

## Prerequisites
- [Node.js](https://nodejs.org/) installed and in your PATH (required for chat session index migration)

## Steps

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

**Not sure it'll work?** Do a safe test run first (no real files touched):

```powershell
powershell -ExecutionPolicy Bypass -File .\Migrate-VSCodeWorkspaceHistory.ps1 -OldPathPrefix "C:\OldFolderName" -NewPathPrefix "C:\NewFolderName" -TestMode
```

See `README.md` for full parameter reference.
