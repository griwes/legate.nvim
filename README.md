# Legate

Neovim-native ACP client focused on a single chat buffer and explicit terminal/session seams.

## Status

Core protocol slice in progress. The repo now has a typed setup surface, named Legate adapters with session-aware adapter selection, config-driven ACP option overrides, a single reusable Markdown chat buffer, a real ACP stdio JSON-RPC boundary, local session persistence, prompt submission through `session/prompt`, streamed `session/update` handling, session config-option UX, slash-command UX, metadata-driven terminal-stream rendering for the verified `zed-industries/codex-acp` `_meta` shape, and both native and `terminalia.nvim` terminal backends.

## Installation

Example local `lazy.nvim` spec:

```lua
{
    dir = vim.fn.expand("~/projects/neovim-plugin-orchestration/legate.nvim"),
    name = 'legate.nvim',
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

- `:LegateChat` opens or reuses the shared Legate chat buffer
- `:LegateNewSession` creates a fresh in-memory Legate session
- `:LegateLoadSession [id]` explicitly binds or reloads a local Legate session against the remote ACP transport
- `:LegateRebindSession [id]` recovers a `load_failed` local Legate session by discarding the stale remote binding and creating a fresh remote ACP session
- `:LegateSessions` lists local Legate sessions
- `:LegateSaveSessions` persists local Legate sessions to disk immediately
- `:LegateRestoreSessions` restores persisted local Legate sessions and opens the shared chat buffer
- `:LegateClearSessionStorage` deletes persisted local Legate session storage from disk
- `:LegateApprovals` lists current-session Legate approval history
- `:LegateConfigOptions` lists Legate session config options for the current local session
- `:LegateSlashCommands` lists Legate slash commands for the current local session
- `:LegateRevealApproval <ordinal>` opens or reuses the shared chat buffer and jumps to a recorded approval entry
- `:LegateSelectApprovalOption <request-id>:<option-id>` resolves the current inline Legate approval by unambiguous selector; bare option ids are still accepted when only one approval is pending
- `:LegatePickApproval` reveals a recorded approval through `vim.ui.select`
- `:LegateSelectSession <id>` switches the shared chat buffer to a local Legate session
- `:LegatePickSession` switches the shared chat buffer through `vim.ui.select`
- `:LegateAdapters` lists configured Legate adapters for the current local session
- `:LegateSelectAdapter <name>` switches the current local session to a configured ACP adapter and drops stale remote binding state
- `:LegatePickAdapter` switches the current local session to a configured ACP adapter through `vim.ui.select`
- `:LegateSetConfigOption <config-id> <value>` changes a Legate session config option through `session/set_config_option`
- `:LegatePickConfigOption` changes a Legate session config option through `vim.ui.select`
- `:LegateRunSlashCommand <name> [input...]` submits a Legate slash command through the normal prompt path
- `:LegatePickSlashCommand` chooses and submits a Legate slash command through `vim.ui.select`, prompting for freeform input when the command expects it
- `:LegateCloseSession [id]` closes a local Legate session, defaulting to the current one; with `auto_create_session = true`, closing the last session immediately replaces it with a fresh empty session
- `:LegatePickCloseSession` closes a local Legate session through `vim.ui.select`
- `:LegateSubmit` submits the editable prompt section from the chat buffer into the current transcript
- `:LegateCancel` cancels the active live ACP turn, even if that turn belongs to a different local session than the one currently selected

## Current Shape

- one shared chat buffer, not a sidebar
- transcript and editable prompt live in the same buffer
- the chat buffer is real `markdown` content and is intended to stay compatible with `render-markdown.nvim`
- multiple local Legate sessions can coexist, with API support to list/select them and preserve a separate unsent draft per session
- each local Legate session now also records which configured Legate adapter it uses
- adapter selection is session-aware: changing adapters clears stale remote binding state for that session instead of pretending remote ids are reusable across adapters
- local Legate sessions can now be saved to disk, restored later, and optionally restored during `setup()`
- persisted ACP state is local-session state only; remote ACP continuity still goes through explicit binding or reload via `:LegateLoadSession`
- sessions that were still waiting on a live turn persist and restore as cancelled local sessions, with any pending prompt moved back into the editable draft
- session management now supports both commands-first and `vim.ui.select` picker flows for list/select/close operations
- session surfaces now also show remote-sync state (`unbound`, `created`, `loaded`, `load_failed`) so remote binding/reload behavior is visible
- background updates for a non-selected session do not steal the visible chat buffer; they render when that session is selected again
- ACP transport is grounded in the official protocol over newline-delimited stdio JSON-RPC
- the current slice handles `initialize`, optional `authenticate`, `session/new`, `session/prompt`, `session/update`, and `session/cancel`
- ACP now renders session config options inline in the Markdown chat buffer and supports changing them through commands, pickers, and official `session/set_config_option` requests
- ACP now renders the active adapter and its config-driven ACP option overrides inline in the Markdown chat buffer
- adapter config can now preselect transport/auth/runtime settings and apply ACP `session/set_config_option` overrides automatically after bind/load
- adapter config can now also prepend static prompt instructions and apply a last-mile prompt decorator on submission/replay without mutating locally stored user transcript text
- ACP now stores slash commands from official `available_commands_update` notifications, renders them inline in the Markdown chat buffer, and exposes list/run/picker UX that submits normal `/command ...` prompt text
- ACP now defers chat-buffer rerenders out of fast event contexts so live transport notifications do not hit `E5560` under real agent traffic
- tool calls now render in a dedicated Markdown tools section instead of collapsing into transcript status noise
- permission requests now support either configured default outcomes or an inline approval surface that stays visible in the shared chat buffer until it is explicitly resolved
- ACP config can now also supply a first-class `permission_policy` callback so adapter- or request-specific approval decisions do not require monkeypatching ACP internals
- approval history now records decision source plus per-option metadata, and approvals can be reviewed or revisited through commands/picker UX without leaving the shared Markdown chat buffer
- ACP now advertises `fs/read_text_file` and `fs/write_text_file`, reads from unsaved open buffers when possible, and writes through open buffers so Neovim state and disk stay aligned
- ACP now advertises `terminal = true` and handles `terminal/create`, `terminal/output`, `terminal/wait_for_exit`, `terminal/kill`, and `terminal/release` through either a native hidden-process backend or an optional `terminalia.nvim` adapter
- the native backend remains the default, and the `terminalia.nvim` backend keeps ACP `terminal/release` scoped to ACP handle invalidation instead of deleting the Terminalia terminal object
- ACP now also renders bounded inline terminal previews and hover details for the verified `zed-industries/codex-acp` `_meta.terminal_info` / `_meta.terminal_output` / `_meta.terminal_exit` compatibility path without weakening official ACP `terminal/*`
- ACP can now auto-inject the live `ministry.nvim` endpoint into its configured `mcp_servers` list when `enable_mcp_nvim = true` (opt-in)
- ACP adapter config can now also add MCPHub proxy integration declaratively through `enable_mcphub = true`
- this gives ACP/Codex a stable local MCP surface for buffer-id/file-path-based edits and terminal lifecycle routing, while still leaving ACP-native terminal methods available when the agent actually uses them
- ACP can now also prepend Ministry-owned `neovim` MCP routing guidance into submitted prompts when `mcp_nvim_guidance = true` (default)
- Legate forwards guidance advertised by Ministry servers instead of synthesizing Ministry tool/resource instructions itself, keeping prompt decoration in ACP and tool-specific guidance in the server that owns the tools
- ACP does not invent a separate terminal proxy server for this fallback; the only intended MCP fallback is the existing `ministry.nvim` `neovim/terminal/*` surface
- follow-up turns rebind the transport channel between prompts to fail closed on stale cross-turn updates
- when the agent advertises `loadSession`, follow-up turns resume the existing remote ACP session with `session/load`
- when the agent does not advertise `loadSession`, follow-up turns fall back to a fresh remote session plus explicit transcript replay in the prompt content
- explicit session loading is now user-facing too: unbound sessions bind through `session/new`, already-bound sessions reload through `session/load` when supported, failed explicit reloads mark the local session as `load_failed` and rerender the selected chat buffer with the sync error, and ACP refuses to steal the transport away from a different local session that still has a running turn
- `load_failed` recovery is now explicit too: `:LegateLoadSession` retries the recorded remote session, while `:LegateRebindSession` creates a fresh remote ACP session for the same local transcript when retrying the stale binding is not enough
- when `persist_sessions = true`, ACP writes local session state on `VimLeavePre`; `restore_sessions_on_setup = true` opts into restoring that local state during `setup()`
- `:LegateContinueLastSession` restores local state when needed, selects the most recently updated local session, and opens the shared chat buffer without implicitly loading remote ACP state
- prompt execution is still serialized globally for now; multiple local sessions are supported, but only one live prompt turn runs at a time
- this transport slice has been smoke-tested against `codex-acp 0.11.1` using the `chatgpt` auth method
- a repo-owned opt-in live restore smoke now proves that a persisted local Legate session can be restored in a fresh Neovim process, explicitly rebound through `session/load`, and also that a follow-up without explicit load does not auto-resume the old remote
- a second repo-owned opt-in live smoke now proves `load_failed` recovery against real `codex-acp`: retrying the recorded remote id fails closed as expected, `LegateRebindSession` creates a fresh remote session, and a follow-up prompt succeeds on that rebound session
- a repo-owned opt-in live terminal-selection probe now requires an observed terminal or ACP tool-call path and records whether `codex-acp` actually used ACP `terminal/*` plus which ACP tool-call kinds were observed instead
- current local probe runs with both `terminal_backend = 'native'` and `terminal_backend = 'terminalia'` still chose an `execute` tool call and made zero ACP `terminal/*` requests
- terminal support is defined as a contract now, and the current slice ships both the default native hidden-process backend and a `terminalia.nvim` adapter backend
- Legate contributes a producer-owned Statuesque widget at `statuesque.widgets.legate`; use `{ name = 'legate', optional = true }` in a Statuesque surface to show active session, adapter, turn state, approval count, and remote-sync state without extra user-side wiring

## Terminal Backends

Default backend:

```lua
require('legate').setup({
    terminal_backend = 'native',
})
```

Optional `terminalia.nvim` backend:

```lua
require('legate').setup({
    terminal_backend = 'terminalia',
})
```

## Adapters

Adapters are explicit named transport profiles. `default_adapter` picks which one
new local Legate sessions inherit, and each session can later switch adapters
through `:LegateSelectAdapter` or `:LegatePickAdapter`.

Example:

```lua
require('legate').setup({
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
- `enable_mcphub`
- `enable_mcp_nvim`
- `mcp_nvim_guidance`
- `request_timeout_ms`
- `config_option_overrides`
- `prompt_prelude`
- `prompt_decorator`

Declarative MCPHub example:

```lua
require('legate').setup({
    adapters = {
        codex = {
            command = { 'codex-acp' },
            auth_method = 'chatgpt',
            enable_mcphub = true,
            enable_mcp_nvim = true,
        },
    },
})
```

Example prompt steering:

```lua
require('legate').setup({
    adapters = {
        codex = {
            command = { 'codex-acp' },
            auth_method = 'chatgpt',
            prompt_prelude = [[<additional_instructions>
Prefer MCP tools in all cases.
</additional_instructions>]],
            prompt_decorator = function(prompt, adapter)
                if adapter.name == 'codex' then
                    return prompt .. '\n\n[workspace policy applied]'
                end

                return prompt
            end,
        },
    },
})
```

## Approval Strategy

Default approval behavior keeps the current non-interactive safety-first flow:

```lua
require('legate').setup({
    permission_strategy = 'default',
    permission_default = 'reject_once',
})
```

Interactive approval behavior renders an inline approval surface inside the Legate chat buffer:

```lua
require('legate').setup({
    permission_strategy = 'select',
})
```

When an approval is pending, ACP keeps it visible above the prompt section until it is explicitly resolved or the underlying request becomes stale. Resolve it through the inline affordance or `:LegateSelectApprovalOption <request-id>:<option-id>`.

Policy-driven approval example:

```lua
require('legate').setup({
    permission_policy = function(current_session, permission, adapter, tool_call)
        if adapter.command[1] == 'codex-acp' and tool_call and tool_call.kind == 'read' then
            return 'allow_once'
        end
    end,
})
```

The callback may return:

- an option kind such as `'allow_once'`
- an explicit ACP option id
- a table with `optionId`, `selected`, or `kind`

Returning `nil` falls back to the normal configured `permission_strategy`.

## Session Persistence

Local Legate session state persists by default on Neovim exit and can be restored explicitly or during setup:

```lua
require('legate').setup({
    persist_sessions = true,
    restore_sessions_on_setup = true,
})
```

By default, ACP stores a compact session index at
`stdpath('state') .. '/legate.nvim/sessions.json'` and writes each local ACP
session to a separate JSON file under `sessions.json.d/sessions/`. Override
`session_state_file` if you want a different index location; the fragmented
record directory is derived from that path.

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
The live terminal-selection probe also uses real `codex-acp` with `auth_method = 'chatgpt'`; it enables `ministry.nvim` injection and guidance during the run, fails if no terminal or ACP tool-call path is observed, reports whether the agent actually used ACP `terminal/*`, whether it used `neovim/terminal/*`, which ACP tool-call kinds were observed instead, and whether any observed tool calls were `execute`, and accepts:

- `LEGATE_LIVE_TERMINAL_BACKEND=native|terminalia`
- `LEGATE_LIVE_PROBE_MODE=balanced|strict_acp_first|strict_mcp_terminal|hard_mcp_terminal_only|split_mcp_routing` (legacy `ACP_LIVE_PROBE_MODE` also works)

for backend and guidance-strength comparison. The latest real `native` probes against installed `zed-industries/codex-acp` do reach the injected MCP server now: they issue `tools/list`, call `neovim/terminal/create|wait|output|release`, and complete the probe without any generic execute fallback. The remaining split-routing mismatch is narrower now: current `codex-acp` MCP calls still arrive as `server = "neovim"` plus `tool = "neovim/terminal/create"` instead of the canonical `tool = "terminal/create"` shape, but Legate now tolerates that duplicate-prefixed form in the default terminal approval path and records the routing mismatch as probe evidence instead of blocking execution.
ACP now auto-approves the injected `neovim/terminal/*` permission path in default mode, so both the strict and split-routing live probes reach full MCP execution and a successful `ACP_TERMINAL_SELECTION_PROBE_OK` response without any generic execute fallback, even though the split-routing probe still records the duplicated tool-field prefix from the current upstream runtime.
