# acp.nvim

Neovim-native ACP client focused on a single chat buffer and explicit terminal/session seams.

## Status

Core protocol slice in progress. The repo now has a typed setup surface, named ACP adapters with session-aware adapter selection, config-driven ACP option overrides, a single reusable Markdown chat buffer, a real ACP stdio JSON-RPC boundary, local session persistence, prompt submission through `session/prompt`, streamed `session/update` handling, session config-option UX, slash-command UX, metadata-driven terminal-stream rendering for the verified `zed-industries/codex-acp` `_meta` shape, and both native and `terminal-manager.nvim` terminal backends.

## Installation

Example local `lazy.nvim` spec:

```lua
{
    dir = vim.fn.expand("~/projects/neovim-plugin-orchestration/acp.nvim"),
    name = 'acp.nvim',
    opts = {
        default_adapter = 'codex',
        adapters = {
            codex = {
                command = { 'codex-acp' },
                auth_method = 'chatgpt',
                config_option_overrides = {
                    mode = 'code',
                },
            },
        },
    },
}
```

## Commands

- `:ACPChat` opens or reuses the shared ACP chat buffer
- `:ACPNewSession` creates a fresh in-memory ACP session
- `:ACPLoadSession [id]` explicitly binds or reloads a local ACP session against the remote ACP transport
- `:ACPRebindSession [id]` recovers a `load_failed` local ACP session by discarding the stale remote binding and creating a fresh remote ACP session
- `:ACPSessions` lists local ACP sessions
- `:ACPSaveSessions` persists local ACP sessions to disk immediately
- `:ACPRestoreSessions` restores persisted local ACP sessions and opens the shared chat buffer
- `:ACPClearSessionStorage` deletes persisted local ACP session storage from disk
- `:ACPApprovals` lists current-session ACP approval history
- `:ACPConfigOptions` lists ACP session config options for the current local session
- `:ACPSlashCommands` lists ACP slash commands for the current local session
- `:ACPRevealApproval <ordinal>` opens or reuses the shared chat buffer and jumps to a recorded approval entry
- `:ACPSelectApprovalOption <request-id>:<option-id>` resolves the current inline ACP approval by unambiguous selector; bare option ids are still accepted when only one approval is pending
- `:ACPPickApproval` reveals a recorded approval through `vim.ui.select`
- `:ACPSelectSession <id>` switches the shared chat buffer to a local ACP session
- `:ACPPickSession` switches the shared chat buffer through `vim.ui.select`
- `:ACPAdapters` lists configured ACP adapters for the current local session
- `:ACPSelectAdapter <name>` switches the current local session to a configured ACP adapter and drops stale remote binding state
- `:ACPPickAdapter` switches the current local session to a configured ACP adapter through `vim.ui.select`
- `:ACPSetConfigOption <config-id> <value>` changes an ACP session config option through `session/set_config_option`
- `:ACPPickConfigOption` changes an ACP session config option through `vim.ui.select`
- `:ACPRunSlashCommand <name> [input...]` submits an ACP slash command through the normal prompt path
- `:ACPPickSlashCommand` chooses and submits an ACP slash command through `vim.ui.select`, prompting for freeform input when the command expects it
- `:ACPCloseSession [id]` closes a local ACP session, defaulting to the current one; with `auto_create_session = true`, closing the last session immediately replaces it with a fresh empty session
- `:ACPPickCloseSession` closes a local ACP session through `vim.ui.select`
- `:ACPSubmit` submits the editable prompt section from the chat buffer into the current transcript
- `:ACPCancel` cancels the active live ACP turn, even if that turn belongs to a different local session than the one currently selected

## Current Shape

- one shared chat buffer, not a sidebar
- transcript and editable prompt live in the same buffer
- the chat buffer is real `markdown` content and is intended to stay compatible with `render-markdown.nvim`
- multiple local ACP sessions can coexist, with API support to list/select them and preserve a separate unsent draft per session
- each local ACP session now also records which configured ACP adapter it uses
- adapter selection is session-aware: changing adapters clears stale remote binding state for that session instead of pretending remote ids are reusable across adapters
- local ACP sessions can now be saved to disk, restored later, and optionally restored during `setup()`
- persisted ACP state is local-session state only; remote ACP continuity still goes through explicit binding or reload via `:ACPLoadSession`
- sessions that were still waiting on a live turn persist and restore as cancelled local sessions, with any pending prompt moved back into the editable draft
- session management now supports both commands-first and `vim.ui.select` picker flows for list/select/close operations
- session surfaces now also show remote-sync state (`unbound`, `created`, `loaded`, `load_failed`) so remote binding/reload behavior is visible
- background updates for a non-selected session do not steal the visible chat buffer; they render when that session is selected again
- ACP transport is grounded in the official protocol over newline-delimited stdio JSON-RPC
- the current slice handles `initialize`, optional `authenticate`, `session/new`, `session/prompt`, `session/update`, and `session/cancel`
- ACP now renders session config options inline in the Markdown chat buffer and supports changing them through commands, pickers, and official `session/set_config_option` requests
- ACP now renders the active adapter and its config-driven ACP option overrides inline in the Markdown chat buffer
- adapter config can now preselect transport/auth/runtime settings and apply ACP `session/set_config_option` overrides automatically after bind/load
- ACP now stores slash commands from official `available_commands_update` notifications, renders them inline in the Markdown chat buffer, and exposes list/run/picker UX that submits normal `/command ...` prompt text
- ACP now defers chat-buffer rerenders out of fast event contexts so live transport notifications do not hit `E5560` under real agent traffic
- tool calls now render in a dedicated Markdown tools section instead of collapsing into transcript status noise
- permission requests now support either configured default outcomes or an inline approval surface that stays visible in the shared chat buffer until it is explicitly resolved
- approval history now records decision source plus per-option metadata, and approvals can be reviewed or revisited through commands/picker UX without leaving the shared Markdown chat buffer
- ACP now advertises `fs/read_text_file` and `fs/write_text_file`, reads from unsaved open buffers when possible, and writes through open buffers so Neovim state and disk stay aligned
- ACP now advertises `terminal = true` and handles `terminal/create`, `terminal/output`, `terminal/wait_for_exit`, `terminal/kill`, and `terminal/release` through either a native hidden-process backend or an optional `terminal-manager.nvim` adapter
- the native backend remains the default, and the `terminal-manager.nvim` backend keeps ACP `terminal/release` scoped to ACP handle invalidation instead of deleting the terminal-manager terminal object
- ACP now also renders bounded inline terminal previews and hover details for the verified `zed-industries/codex-acp` `_meta.terminal_info` / `_meta.terminal_output` / `_meta.terminal_exit` compatibility path without weakening official ACP `terminal/*`
- ACP can now auto-inject the live `mcp.nvim` endpoint into its configured `mcp_servers` list when `enable_mcp_nvim = true` (opt-in)
- this gives ACP/Codex a stable local MCP surface for buffer-id/file-path-based edits and terminal lifecycle routing, while still leaving ACP-native terminal methods available when the agent actually uses them
- ACP can now also prepend `neovim` MCP routing guidance into submitted prompts when `mcp_nvim_guidance = true` (default)
- that guidance tells the agent to prefer the identifier-based `neovim/editor/...` tools and to use `neovim/terminal/...` tools only when ACP-native terminal methods are not actually being used
- ACP does not invent a separate terminal proxy server for this fallback; the only intended MCP fallback is the existing `mcp.nvim` `neovim/terminal/*` surface
- follow-up turns rebind the transport channel between prompts to fail closed on stale cross-turn updates
- when the agent advertises `loadSession`, follow-up turns resume the existing remote ACP session with `session/load`
- when the agent does not advertise `loadSession`, follow-up turns fall back to a fresh remote session plus explicit transcript replay in the prompt content
- explicit session loading is now user-facing too: unbound sessions bind through `session/new`, already-bound sessions reload through `session/load` when supported, failed explicit reloads mark the local session as `load_failed` and rerender the selected chat buffer with the sync error, and ACP refuses to steal the transport away from a different local session that still has a running turn
- `load_failed` recovery is now explicit too: `:ACPLoadSession` retries the recorded remote session, while `:ACPRebindSession` creates a fresh remote ACP session for the same local transcript when retrying the stale binding is not enough
- when `persist_sessions = true`, ACP writes local session state on `VimLeavePre`; `restore_sessions_on_setup = true` opts into restoring that local state during `setup()`
- prompt execution is still serialized globally for now; multiple local sessions are supported, but only one live prompt turn runs at a time
- this transport slice has been smoke-tested against `codex-acp 0.11.1` using the `chatgpt` auth method
- a repo-owned opt-in live restore smoke now proves that a persisted local ACP session can be restored in a fresh Neovim process, explicitly rebound through `session/load`, and also that a follow-up without explicit load does not auto-resume the old remote
- a second repo-owned opt-in live smoke now proves `load_failed` recovery against real `codex-acp`: retrying the recorded remote id fails closed as expected, `ACPRebindSession` creates a fresh remote session, and a follow-up prompt succeeds on that rebound session
- a repo-owned opt-in live terminal-selection probe now requires an observed terminal or ACP tool-call path and records whether `codex-acp` actually used ACP `terminal/*` plus which ACP tool-call kinds were observed instead
- current local probe runs with both `terminal_backend = 'native'` and `terminal_backend = 'terminal_manager'` still chose an `execute` tool call and made zero ACP `terminal/*` requests
- terminal support is defined as a contract now, and the current slice ships both the default native hidden-process backend and a `terminal-manager.nvim` adapter backend

## Terminal Backends

Default backend:

```lua
require('acp').setup({
    terminal_backend = 'native',
})
```

Optional `terminal-manager.nvim` backend:

```lua
require('acp').setup({
    terminal_backend = 'terminal_manager',
})
```

When using `terminal_manager`, `acp.nvim` expects `terminal-manager.nvim` to be installed and on the runtimepath.

## Adapters

Adapters are explicit named transport profiles. `default_adapter` picks which one
new local ACP sessions inherit, and each session can later switch adapters
through `:ACPSelectAdapter` or `:ACPPickAdapter`.

Example:

```lua
require('acp').setup({
    default_adapter = 'codex',
    adapters = {
        codex = {
            command = { 'codex-acp' },
            auth_method = 'chatgpt',
            enable_mcp_nvim = true,
            mcp_nvim_guidance = true,
            config_option_overrides = {
                mode = 'code',
                model = 'gpt-5.4',
            },
        },
        cautious = {
            command = { 'codex-acp' },
            auth_method = 'chatgpt',
            config_option_overrides = {
                mode = 'ask',
                model = 'gpt-5.4-mini',
            },
            title = 'Codex Cautious',
        },
    },
})
```

Each adapter can override:

- `command`
- `env`
- `auth_method`
- `cwd`
- `protocol_version`
- `client_info`
- `client_capabilities`
- `mcp_servers`
- `enable_mcp_nvim`
- `mcp_nvim_guidance`
- `request_timeout_ms`
- `config_option_overrides`

## Approval Strategy

Default approval behavior keeps the current non-interactive safety-first flow:

```lua
require('acp').setup({
    permission_strategy = 'default',
    permission_default = 'reject_once',
})
```

Interactive approval behavior renders an inline approval surface inside the ACP chat buffer:

```lua
require('acp').setup({
    permission_strategy = 'select',
})
```

When an approval is pending, ACP keeps it visible above the prompt section until it is explicitly resolved or the underlying request becomes stale. Resolve it through the inline affordance or `:ACPSelectApprovalOption <request-id>:<option-id>`.

## Session Persistence

Local ACP session state persists by default on Neovim exit and can be restored explicitly or during setup:

```lua
require('acp').setup({
    persist_sessions = true,
    restore_sessions_on_setup = true,
})
```

By default, ACP stores session state at `stdpath('state') .. '/acp.nvim/sessions.json'`. Override `session_state_file` if you want a different location.

Restored state is intentionally local only: transcript, draft, tool rows, approvals, config options, slash commands, and remote binding metadata come back, but ACP still treats renewed remote continuity as an explicit load/bind step instead of assuming the old remote session is still valid.

## Development

- tests live in `tests/`
- opt-in live restore smoke:
  `nvim --headless -u tests/minimal_init.lua -l tests/live_restore_smoke.lua`
- opt-in live `load_failed` recovery smoke:
  `nvim --headless -u tests/minimal_init.lua -l tests/live_load_failed_recovery_smoke.lua`
- opt-in live terminal-selection probe:
  `nvim --headless -u tests/minimal_init.lua -l tests/live_terminal_selection_probe.lua`
- formatting is enforced with Stylua
- Lua modules should carry LuaLS annotations and doc comments
- CI lives in `.github/workflows/ci.yml`

The live restore and load-failed recovery smokes use real `codex-acp` with `auth_method = 'chatgpt'`, so they expect working local Codex auth before you run them.
The live terminal-selection probe also uses real `codex-acp` with `auth_method = 'chatgpt'`; it enables `mcp.nvim` injection and guidance during the run, fails if no terminal or ACP tool-call path is observed, reports whether the agent actually used ACP `terminal/*`, whether it used `neovim/terminal/*`, which ACP tool-call kinds were observed instead, and whether any observed tool calls were `execute`, and accepts:

- `ACP_LIVE_TERMINAL_BACKEND=native|terminal_manager`
- `ACP_LIVE_PROBE_MODE=balanced|strict_acp_first|strict_mcp_terminal|hard_mcp_terminal_only|split_mcp_routing`

for backend and guidance-strength comparison. The latest real `native` probes against installed `zed-industries/codex-acp` do reach the injected MCP server now: they issue `tools/list`, attempt `neovim/terminal/create`, and report why they rejected fallback. The remaining blocker is that current `codex-acp` MCP calls still arrive as `server = "neovim"` plus `tool = "neovim/terminal/create"`, and those calls are then cancelled before execution.
ACP now auto-approves the injected `neovim/terminal/*` permission path in default mode, so the strict live probe reaches full MCP execution: `tools/list`, `tools/call` for `create|wait|output|release`, and a successful `ACP_TERMINAL_SELECTION_PROBE_OK` response without any generic execute fallback.
