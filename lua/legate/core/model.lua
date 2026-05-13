---@alias legate.MessageRole
---| 'user'
---| 'assistant'
---| 'system'
---| 'status'

---@alias legate.SessionStatus
---| 'idle'
---| 'waiting'
---| 'cancelled'

---@alias legate.RemoteSyncState
---| 'unbound'
---| 'created'
---| 'loaded'
---| 'load_failed'

---@alias legate.StopReason
---| 'end_turn'
---| 'max_tokens'
---| 'max_turn_requests'
---| 'refusal'
---| 'cancelled'

---@alias legate.TerminalBackendName
---| 'native'
---| 'terminalia'

---@alias legate.PermissionOptionKind
---| 'allow_once'
---| 'allow_always'
---| 'reject_once'
---| 'reject_always'

---@alias legate.PermissionStrategy
---| 'default'
---| 'ministry'
---| 'policy'
---| 'select'

---@alias legate.SessionConfigOptionType
---| 'select'

---@alias legate.ToolCallStatus
---| 'pending'
---| 'in_progress'
---| 'waiting_for_approval'
---| 'completed'
---| 'failed'
---| 'cancelled'

---@alias legate.ToolKind
---| 'read'
---| 'edit'
---| 'delete'
---| 'move'
---| 'search'
---| 'execute'
---| 'think'
---| 'fetch'
---| 'switch_mode'
---| 'other'

---@class legate.Message
---@field id integer
---@field role legate.MessageRole
---@field text string
---@field created_at integer
---@field stream_kind? 'tool_call'|'approval'
---@field stream_key? string
---@field status_state? string
---@field status_title? string

---@class legate.Session
---@field id string
---@field ordinal integer
---@field adapter_name string
---@field status legate.SessionStatus
---@field messages legate.Message[]
---@field draft_prompt string
---@field pending_prompt string?
---@field pending_approvals legate.PendingApproval[]
---@field remote_id string?
---@field transport_remote_id string?
---@field remote_sync_state legate.RemoteSyncState
---@field remote_sync_error string?
---@field stop_reason legate.StopReason?
---@field plan_entries legate.PlanEntry[]
---@field available_commands legate.AvailableCommand[]
---@field tool_calls legate.ToolCallState[]
---@field approval_entries legate.ApprovalEntry[]
---@field agent_info legate.AgentInfo?
---@field config_options legate.SessionConfigOption[]
---@field cwd string?
---@field turn_id integer
---@field created_at integer
---@field updated_at integer

---@class legate.BufferState
---@field bufnr integer?

---@class legate.BufferLocator
---@field local_id string?
---@field remote_id string?
---@field pending boolean?

---@class legate.TerminalHandle
---@field id string
---@field backend legate.TerminalBackendName
---@field session_id? string

---@class legate.TerminalBackend
---@field name legate.TerminalBackendName
---@field create fun(opts: legate.TerminalCreateRequest): legate.TerminalHandle?, table?
---@field send fun(handle: legate.TerminalHandle, data: string)
---@field output fun(handle: legate.TerminalHandle): legate.TerminalOutputResponse?, table?
---@field wait fun(handle: legate.TerminalHandle, timeout_ms?: integer): legate.TerminalWaitForExitResponse?, table?
---@field kill fun(handle: legate.TerminalHandle): legate.TerminalKillResponse?, table?
---@field release fun(handle: legate.TerminalHandle): legate.TerminalReleaseResponse?, table?
---@field reveal fun(handle: legate.TerminalHandle): table?

---@class legate.ClientInfo
---@field name string
---@field title string
---@field version string

---@class legate.ClientCapabilities
---@field fs? { readTextFile?: boolean, writeTextFile?: boolean }
---@field terminal? boolean

---@class legate.AdapterConfig
---@field name? string
---@field command string[]
---@field env table<string, string>
---@field protocol_version integer
---@field client_info legate.ClientInfo
---@field client_capabilities legate.ClientCapabilities
---@field cwd string?
---@field mcp_servers table[]
---@field enable_mcphub boolean
---@field enable_mcp_nvim boolean
---@field mcp_nvim_guidance boolean
---@field auth_method string?
---@field request_timeout_ms integer
---@field config_option_overrides table<string, string>
---@field prompt_prelude? string
---@field prompt_decorator? fun(prompt: string, adapter: legate.AdapterConfig, session?: legate.Session, agent_capabilities?: legate.AgentCapabilities): string?
---@field title? string
---@field description? string

---@alias legate.PermissionPolicyResult string|{ optionId?: string, kind?: legate.PermissionOptionKind, outcome?: 'selected', selected?: string }

---@class legate.ReadTextFileRequest
---@field path string
---@field sessionId string
---@field line? integer
---@field limit? integer

---@class legate.ReadTextFileResponse
---@field content string

---@class legate.WriteTextFileRequest
---@field path string
---@field sessionId string
---@field content string

---@class legate.WriteTextFileResponse

---@class legate.EnvVariable
---@field name string
---@field value string

---@class legate.TerminalExitStatus
---@field exitCode integer?
---@field signal string?

---@class legate.TerminalCreateRequest
---@field sessionId string
---@field command string
---@field args? string[]
---@field env? legate.EnvVariable[]
---@field cwd? string
---@field outputByteLimit? integer

---@class legate.TerminalCreateResponse
---@field terminalId string

---@class legate.TerminalOutputRequest
---@field sessionId string
---@field terminalId string

---@class legate.TerminalOutputResponse
---@field output string
---@field truncated boolean
---@field exitStatus? legate.TerminalExitStatus

---@class legate.TerminalWaitForExitRequest
---@field sessionId string
---@field terminalId string

---@class legate.TerminalWaitForExitResponse
---@field exitCode integer?
---@field signal string?

---@class legate.TerminalKillRequest
---@field sessionId string
---@field terminalId string

---@class legate.TerminalKillResponse

---@class legate.TerminalReleaseRequest
---@field sessionId string
---@field terminalId string

---@class legate.TerminalReleaseResponse

---@class legate.AgentInfo
---@field name string
---@field title? string
---@field version? string

---@class legate.AgentCapabilities
---@field loadSession? boolean
---@field promptCapabilities? table<string, boolean>
---@field mcpCapabilities? table<string, boolean>

---@class legate.AuthMethod
---@field id string
---@field name? string

---@class legate.ContentBlock
---@field type 'text'
---@field text string

---@class legate.ToolCallLocation
---@field path string
---@field line? integer

---@class legate.ToolCallContentContent
---@field type 'content'
---@field content { type?: string, text?: string }

---@class legate.ToolCallContentDiff
---@field type 'diff'
---@field path string
---@field oldText? string
---@field newText string

---@class legate.ToolCallContentTerminal
---@field type 'terminal'
---@field terminalId string

---@class legate.MetaTerminalStream
---@field terminal_id string
---@field cwd? string
---@field output string
---@field exit_code? integer
---@field signal? string?

---@alias legate.ToolCallContent
---| legate.ToolCallContentContent
---| legate.ToolCallContentDiff
---| legate.ToolCallContentTerminal

---@class legate.ToolCallState
---@field tool_call_id string
---@field stream_key string
---@field title string
---@field status legate.ToolCallStatus
---@field kind? legate.ToolKind
---@field locations legate.ToolCallLocation[]
---@field content legate.ToolCallContent[]
---@field raw_input? table
---@field raw_output? table
---@field terminal_streams? table<string, legate.MetaTerminalStream>

---@class legate.ApprovalEntry
---@field ordinal integer
---@field stream_key string
---@field tool_call_id string?
---@field title string
---@field outcome 'selected'|'cancelled'
---@field source legate.PermissionStrategy
---@field selected_kind? legate.PermissionOptionKind
---@field selected_option_name? string
---@field selected_option_id? string
---@field options legate.PermissionOption[]

---@class legate.PermissionOption
---@field optionId string
---@field name string
---@field kind legate.PermissionOptionKind

---@class legate.PermissionRequest
---@field sessionId string
---@field toolCall { toolCallId?: string, title?: string }
---@field options legate.PermissionOption[]

---@class legate.PermissionOutcome
---@field outcome 'cancelled'|'selected'
---@field optionId? string

---@class legate.PlanEntry
---@field content string
---@field priority? string
---@field status string

---@class legate.AvailableCommandInput
---@field hint string

---@class legate.AvailableCommand
---@field name string
---@field description string
---@field input? legate.AvailableCommandInput

---@class legate.SessionConfigOptionValue
---@field value string
---@field name string
---@field description? string

---@class legate.SessionConfigOptionGroup
---@field group string
---@field name string
---@field options legate.SessionConfigOptionValue[]

---@alias legate.SessionConfigOptionEntry
---| legate.SessionConfigOptionValue
---| legate.SessionConfigOptionGroup

---@class legate.SessionConfigOption
---@field id string
---@field name string
---@field currentValue string
---@field description? string
---@field category? string
---@field type? legate.SessionConfigOptionType
---@field options? legate.SessionConfigOptionEntry[]

---@class legate.InitializeResult
---@field protocolVersion integer
---@field agentCapabilities? legate.AgentCapabilities
---@field agentInfo? legate.AgentInfo
---@field authMethods? legate.AuthMethod[]

---@class legate.SessionNewResult
---@field sessionId string
---@field configOptions? legate.SessionConfigOption[]

---@class legate.SessionLoadResult
---@field configOptions? legate.SessionConfigOption[]

---@class legate.SessionSetConfigOptionResult
---@field configOptions legate.SessionConfigOption[]

---@class legate.PromptResult
---@field stopReason legate.StopReason

---@class legate.ToolCall
---@field toolCallId string
---@field title string
---@field status? legate.ToolCallStatus
---@field kind? legate.ToolKind
---@field locations? legate.ToolCallLocation[]
---@field content? legate.ToolCallContent[]
---@field rawInput? table
---@field rawOutput? table

---@class legate.ToolCallUpdate
---@field toolCallId string
---@field title? string
---@field status? legate.ToolCallStatus
---@field kind? legate.ToolKind
---@field locations? legate.ToolCallLocation[]
---@field content? legate.ToolCallContent[]
---@field rawInput? table
---@field rawOutput? table

---@class legate.RpcClient
---@field start fun(self: legate.RpcClient): boolean, string?
---@field request_sync fun(self: legate.RpcClient, method: string, params: table, timeout_ms?: integer): any, table?
---@field request fun(self: legate.RpcClient, method: string, params: table, callback: fun(result?: any, error?: table))
---@field notify fun(self: legate.RpcClient, method: string, params: table)
---@field close fun(self: legate.RpcClient)

---@class legate.Config
---@field chat_buffer_name string
---@field filetype string
---@field auto_create_session boolean
---@field persist_sessions boolean
---@field restore_sessions_on_setup boolean
---@field session_state_file string
---@field terminal_backend legate.TerminalBackendName
---@field auto_open_on_setup boolean
---@field enable_hover_lsp boolean
---@field prompt_header string
---@field transcript_header string
---@field protocol_version integer
---@field client_info legate.ClientInfo
---@field client_capabilities legate.ClientCapabilities
---@field cwd string?
---@field mcp_servers table[]
---@field enable_mcp_nvim boolean
---@field mcp_nvim_guidance boolean
---@field auth_method string?
---@field request_timeout_ms integer
---@field default_adapter string
---@field adapters table<string, legate.AdapterConfig>
---@field permission_strategy legate.PermissionStrategy
---@field permission_default legate.PermissionOptionKind
---@field permission_policy? fun(current_session: legate.Session, permission: legate.PermissionRequest, adapter: legate.AdapterConfig, matched_tool_call?: legate.ToolCallState): legate.PermissionPolicyResult?

---@class legate.SessionPersistencePayload
---@field current_id string?
---@field next_ordinal integer
---@field next_message_id integer
---@field next_pending_approval_ordinal integer
---@field sessions legate.Session[]

---@class legate.PendingApproval
---@field request_id string
---@field ordinal integer
---@field tool_call_id string?
---@field title string
---@field options legate.PermissionOption[]
---@field generation integer
---@field created_at integer

---@class legate.PendingPermissionState
---@field request_id string
---@field generation integer
---@field local_session_id string
---@field permission legate.PermissionRequest
---@field source? string
---@field ministry_request? { server: string, method: string, arguments: table, context: table }
---@field respond fun(result?: any, error?: table)
