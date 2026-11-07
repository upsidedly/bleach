# MCP

Bleach serves MCP over local stdio using the official Swift SDK. The installed CLI is the server; no daemon, port, account or API key is needed.

```sh
/Applications/Bleach.app/Contents/MacOS/bleach mcp
```

The default is read only. In **Settings → MCP**, copy a Claude configuration or Codex setup command. Copying changes no settings. To register it with Codex:

```sh
codex mcp add bleach -- /Applications/Bleach.app/Contents/MacOS/bleach mcp
```

For Claude Desktop, merge this into its MCP configuration:

```json
{
  "mcpServers": {
    "bleach": {
      "command": "/Applications/Bleach.app/Contents/MacOS/bleach",
      "args": ["mcp"]
    }
  }
}
```

Restart/reconnect the client after changing its configuration. `--root /absolute/folder` selects a different home; folder tools cannot escape it through `..` or symlinks. App removal accepts only exact installed-app inventory paths. Scanning a custom root does not inherit the operator's cache configuration.

## Tools

| Tool | Purpose |
| --- | --- |
| `bleach_status` | Measured disk/CPU/GPU/memory and enabled server permissions. GPU is unavailable if the driver supplies no counter. |
| `bleach_scan` | Caches, old logs and installers; retain an exact session plan. |
| `bleach_discover` | Generated output and verified redundant archives/installers. |
| `bleach_inactive` | Old dependencies with inactivity evidence and a locked reinstall recipe. |
| `bleach_analyze` | Separate private, shared, hard-linked, unverified and logical storage. |
| `bleach_duplicates` | Full-content duplicate comparison. |
| `bleach_apps` / `bleach_uninstall_preview` | App inventory and exact removal choices. |
| `bleach_processes` | User-owned processes, memory footprint and CPU deltas. No process arguments or environment. |
| `bleach_recovery` / `bleach_preferences` | Existing recovery outcomes and current protections. |
| `bleach_plan` / `bleach_preview` | Page a plan and create an exact selected-path preview token. |

`bleach://safety` provides the accounting and protection contract. The `review-cleanup` prompt starts an investigation that asks before mutation. Tool responses contain both structured JSON and a text JSON equivalent. Plans return 50 candidates initially; `bleach_plan` pages up to 200 at a time. Up to eight plans and eight previews remain in each server session; restart or eviction requires a fresh scan. Plans expire after 24 hours and mutations repeat current policy and complete file-state checks.

## Optional mutations

Add `--allow-mutations` to expose `bleach_apply` and `bleach_restore`. Add **both** `--allow-mutations --allow-permanent-delete` to also expose `bleach_delete_permanently`. Default clients receive none of these tools.

1. Scan, then use `bleach_preview` with `plan_id` and explicitly chosen `paths`.
2. Show the user that exact selection, its consequences and the chosen operation.
3. After approval, supply its `preview_token` to `bleach_apply` with `confirmation: "MOVE TO RECOVERY"`, or `bleach_delete_permanently` with `confirmation: "DELETE PERMANENTLY"`.
4. Restore using `batch_id` and `confirmation: "RESTORE"`.

Confirmation strings are operation checks, **not proof of human approval**. Configure the client's own tool approval policy accordingly. Preview tokens are single use; an unsuccessful mutation may still leave a partial batch, so inspect Recovery before retrying. Another mutation in the same server is rejected while one is running. Existing cross-process locks still apply.

Permanent deletion journals first and erases only the new selected batch. It never sweeps old Recovery batches or your Mac's Trash. No MCP tool enables Auto mode, quits processes or silently changes protections. File names and other scanned text are untrusted data, never instructions. The client receives local metadata/paths; Bleach itself opens no network connection.

## Build and verification

The official SDK is pinned to upstream commit `960e77e55acafc266f4d3ca2994a4c8a81e87d19`, containing concurrency and stdio lifecycle fixes needed by the selected Swift 6.3 compiler. Release 0.11.0 failed strict concurrency compilation here; no SDK source or compiler safety checks were patched. Transitive versions are recorded in `Package.resolved`. SDK dependencies are isolated from the native GUI.

```sh
python3 scripts/verify-mcp.py --binary build/bleach
```

The disposable-home canary exercises a real JSON-RPC handshake, tool permissions, resources, prompts, pagination, root/symlink boundaries, exact previews, operation confirmation, move/restore, stale-file rejection, permanent deletion, preserved session files and EOF shutdown.

Protocol references: [MCP stdio](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), [tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools), [official Swift SDK](https://github.com/modelcontextprotocol/swift-sdk), [upstream concurrency fix](https://github.com/modelcontextprotocol/swift-sdk/pull/301).
