# VS Code Extension Recommendations

## Why

The vibeshield-bicep agent depends on two VS Code extensions that provide MCP servers for design-time consultation:

| Extension | Marketplace ID | Purpose |
|-----------|---------------|---------|
| Bicep | `ms-azuretools.vscode-bicep` | Language server, lint, and MCP tools (`get_bicep_best_practices`, `list_avm_metadata`) |
| Azure MCP Server | `ms-azuretools.vscode-azure-mcp-server` | Azure MCP tools (`get_bestpractices`, resource schema queries) |

Without these extensions, MCP consultation fails silently and the agent falls back to general knowledge -- producing lower-quality templates that require more validation cycles.

## Two-Layer Strategy

`Install-VsCodeExtensions.ps1` uses two layers to ensure extensions are available:

### Layer 1: Recommend (always runs)

Adds extension IDs to `.vscode/extensions.json` in the project root. This is the standard VS Code mechanism -- users see a prompt to install recommended extensions when they open the project.

- Creates `.vscode/` directory and `extensions.json` if missing
- Preserves existing recommendations (additive only, never removes)
- Case-insensitive deduplication prevents double entries
- Uses `ConvertFrom-Json` / `ConvertTo-Json` (safe for this file structure)

### Layer 2: Install (best-effort)

If the `code` CLI is on PATH, attempts direct installation via `code --install-extension`:

- Checks `code --list-extensions` first to skip already-installed extensions
- Each extension install is wrapped in its own `try/catch` -- one failure does not block others
- Gracefully handles: CLI not found, no network, marketplace errors
- Produces warnings only -- never terminates the parent install pipeline

The script always exits 0.

## Integration

Called as step 7 in `Install-VibeShield.ps1`, after skill runtime deployment and before SpecKit integration. The agent definition references these extensions in the MCP troubleshooting section -- if MCP calls fail, the agent directs users to verify extension installation.

## Troubleshooting

If MCP server tools are unavailable during agent use:

1. Check VS Code Extensions panel for `ms-azuretools.vscode-bicep` and `ms-azuretools.vscode-azure-mcp-server`
2. If missing, run: `code --install-extension ms-azuretools.vscode-bicep` and `code --install-extension ms-azuretools.vscode-azure-mcp-server`
3. Reload the VS Code window after installation
4. If using Copilot CLI, verify `.mcp.json` exists at the project root (see [Copilot CLI MCP Configuration](#copilot-cli-mcp-configuration) below)

## Copilot CLI MCP Configuration

### VS Code vs Copilot CLI

VS Code discovers MCP servers through **extensions** (handled by `Install-VsCodeExtensions.ps1`) or via `.vscode/mcp.json` (uses `"servers"` root key). Copilot CLI is a separate terminal-based agent that reads from a different path:

| Client | Config Path | Root Key | Discovery |
|--------|------------|----------|-----------|
| VS Code | Extensions / `.vscode/mcp.json` | `servers` | Automatic via extensions |
| Copilot CLI | `.mcp.json` (repo root) | `mcpServers` | Project-level config file |
| Copilot CLI | `~/.copilot/mcp-config.json` | `mcpServers` | User-level fallback |

Project-level config (`.mcp.json`) takes precedence over user-level config when server names conflict.

### Installation

`Install-McpConfig.ps1` handles the Copilot CLI configuration:

- Creates `.mcp.json` at the target repo root if missing (from `assets/mcp.json` template)
- Additively merges server entries if the file exists but lacks Bicep/Azure MCP servers
- Preserves all existing MCP server configurations
- Called automatically as part of `Install-VibeShield.ps1`

### Troubleshooting Copilot CLI MCP

If MCP server tools are unavailable in Copilot CLI:

1. Verify `.mcp.json` exists at the project root
2. Check it contains `azure_mcp` and `bicep_mcp` entries under `mcpServers`
3. Run `/mcp` in Copilot CLI to list discovered servers
4. Verify prerequisites are installed (both are .NET global tools):
   - Bicep MCP: `dotnet tool install -g Azure.Bicep.McpServer`
   - Azure MCP: `dotnet tool install -g azure.mcp`
5. Ensure Azure CLI authentication is active (`az login`) — both servers authenticate via the user's existing session

### Updating MCP Server Tools

Both MCP servers are .NET global tools. To update to the latest versions:

```bash
dotnet tool update -g Azure.Bicep.McpServer
dotnet tool update -g azure.mcp
```
