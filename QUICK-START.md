# Quick Start

## Prerequisites
- [Node.js](https://nodejs.org/) installed and in your PATH (required for chat session index migration)

## Steps

1. Close all VS Code windows
2. Open PowerShell, navigate to this folder, and run:

```powershell
cd C:\IGTTools\github\vscode-workspace-migrator
.\Migrate-VSCodeWorkspaceHistory.ps1 -OldPathPrefix "C:\OldFolderName" -NewPathPrefix "C:\NewFolderName"
```

3. Reopen VS Code — your chat history will be restored

> If you see `DB migration : DISABLED` in the output, Node.js was not found and the session index was not migrated. Install Node.js and re-run with VS Code closed.

---

**Not sure it'll work?** Do a safe test run first (no real files touched):

```powershell
.\Migrate-VSCodeWorkspaceHistory.ps1 -OldPathPrefix "C:\OldFolderName" -NewPathPrefix "C:\NewFolderName" -TestMode
```

See `README.md` for full parameter reference.
