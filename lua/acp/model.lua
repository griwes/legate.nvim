---@alias acp.MessageRole
---| 'user'
---| 'assistant'
---| 'system'
---| 'status'

---@alias acp.SessionStatus
---| 'idle'
---| 'waiting'
---| 'cancelled'

---@alias acp.RemoteSyncState
---| 'unbound'
---| 'created'
---| 'loaded'
---| 'load_failed'

---@alias acp.StopReason
---| 'end_turn'
---| 'max_tokens'
---| 'max_turn_requests'
---| 'refusal'
---| 'cancelled'

---@alias acp.TerminalBackendName
---| 'native'
---| 'terminal_manager'

---@alias acp.PermissionOptionKind
---| 'allow_once'
---| 'allow_always'
---| 'reject_once'
---| 'reject_always'

---@alias acp.PermissionStrategy
---| 'default'
---| 'select'

---@alias acp.SessionConfigOptionType
---| 'select'

---@alias acp.ToolCallStatus
---| 'pending'
---| 'in_progress'
---| 'waiting_for_approval'
---| 'completed'
---| 'failed'
---| 'cancelled'

---@alias acp.ToolKind
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

---@class acp.Message
---@field id integer
---@field role acp.MessageRole
---@field text string
---@field created_at integer
---@field stream_kind? 'tool_call'|'approval'
---@field stream_key? string
---@field status_state? string
---@field status_title? string

---@class acp.Session
---@field id string
---@field ordinal integer
---@field adapter_name string
---@field status acp.SessionStatus
---@field messages acp.Message[]
---@field draft_prompt string
---@field pending_prompt string?
---@field pending_approvals acp.PendingApproval[]
---@field remote_id string?
---@field transport_remote_id string?
---@field remote_sync_state acp.RemoteSyncState
---@field remote_sync_error string?
---@field stop_reason acp.StopReason?
---@field plan_entries acp.PlanEntry[]
---@field available_commands acp.AvailableCommand[]
---@field tool_calls acp.ToolCallState[]
---@field approval_entries acp.ApprovalEntry[]
---@field agent_info acp.AgentInfo?
---@field config_options acp.SessionConfigOption[]
---@field cwd string?
---@field turn_id integer
---@field created_at integer
---@field updated_at integer

---@class acp.BufferState
---@field bufnr integer?

---@class acp.BufferLocator
---@field local_id string?
---@field remote_id string?
---@field pending boolean?

---@class acp.TerminalHandle
---@field id string
---@field backend acp.TerminalBackendName
---@field session_id? string

---@class acp.TerminalBackend
---@field name acp.TerminalBackendName
---@field create fun(opts: acp.TerminalCreateRequest): acp.TerminalHandle?, table?
---@field send fun(handle: acp.TerminalHandle, data: string)
---@field output fun(handle: acp.TerminalHandle): acp.TerminalOutputResponse?, table?
---@field wait fun(handle: acp.TerminalHandle, timeout_ms?: integer): acp.TerminalWaitForExitResponse?, table?
---@field kill fun(handle: acp.TerminalHandle): acp.TerminalKillResponse?, table?
---@field release fun(handle: acp.TerminalHandle): acp.TerminalReleaseResponse?, table?
---@field reveal fun(handle: acp.TerminalHandle): table?

---@class acp.ClientInfo
---@field name string
---@field title string
---@field version string

---@class acp.ClientCapabilities
---@field fs? { readTextFile?: boolean, writeTextFile?: boolean }
---@field terminal? boolean

---@class acp.AdapterConfig
---@field command string[]
---@field env table<string, string>
---@field protocol_version integer
---@field client_info acp.ClientInfo
---@field client_capabilities acp.ClientCapabilities
---@field cwd string?
---@field mcp_servers table[]
---@field enable_mcp_nvim boolean
---@field mcp_nvim_guidance boolean
---@field auth_method string?
---@field request_timeout_ms integer
---@field config_option_overrides table<string, string>
---@field title? string
---@field description? string

---@class acp.ReadTextFileRequest
---@field path string
---@field sessionId string
---@field line? integer
---@field limit? integer

---@class acp.ReadTextFileResponse
---@field content string

---@class acp.WriteTextFileRequest
---@field path string
---@field sessionId string
---@field content string

---@class acp.WriteTextFileResponse

---@class acp.EnvVariable
---@field name string
---@field value string

---@class acp.TerminalExitStatus
---@field exitCode integer?
---@field signal string?

---@class acp.TerminalCreateRequest
---@field sessionId string
---@field command string
---@field args? string[]
---@field env? acp.EnvVariable[]
---@field cwd? string
---@field outputByteLimit? integer

---@class acp.TerminalCreateResponse
---@field terminalId string

---@class acp.TerminalOutputRequest
---@field sessionId string
---@field terminalId string

---@class acp.TerminalOutputResponse
---@field output string
---@field truncated boolean
---@field exitStatus? acp.TerminalExitStatus

---@class acp.TerminalWaitForExitRequest
---@field sessionId string
---@field terminalId string

---@class acp.TerminalWaitForExitResponse
---@field exitCode integer?
---@field signal string?

---@class acp.TerminalKillRequest
---@field sessionId string
---@field terminalId string

---@class acp.TerminalKillResponse

---@class acp.TerminalReleaseRequest
---@field sessionId string
---@field terminalId string

---@class acp.TerminalReleaseResponse

---@class acp.AgentInfo
---@field name string
---@field title? string
---@field version? string

---@class acp.AgentCapabilities
---@field loadSession? boolean
---@field promptCapabilities? table<string, boolean>
---@field mcpCapabilities? table<string, boolean>

---@class acp.AuthMethod
---@field id string
---@field name? string

---@class acp.ContentBlock
---@field type 'text'
---@field text string

---@class acp.ToolCallLocation
---@field path string
---@field line? integer

---@class acp.ToolCallContentContent
---@field type 'content'
---@field content { type?: string, text?: string }

---@class acp.ToolCallContentDiff
---@field type 'diff'
---@field path string
---@field oldText? string
---@field newText string

---@class acp.ToolCallContentTerminal
---@field type 'terminal'
---@field terminalId string

---@class acp.MetaTerminalStream
---@field terminal_id string
---@field cwd? string
---@field output string
---@field exit_code? integer
---@field signal? string?

---@alias acp.ToolCallContent
---| acp.ToolCallContentContent
---| acp.ToolCallContentDiff
---| acp.ToolCallContentTerminal

---@class acp.ToolCallState
---@field tool_call_id string
---@field stream_key string
---@field title string
---@field status acp.ToolCallStatus
---@field kind? acp.ToolKind
---@field locations acp.ToolCallLocation[]
---@field content acp.ToolCallContent[]
---@field raw_input? table
---@field raw_output? table
---@field terminal_streams? table<string, acp.MetaTerminalStream>

---@class acp.ApprovalEntry
---@field ordinal integer
---@field stream_key string
---@field tool_call_id string?
---@field title string
---@field outcome 'selected'|'cancelled'
---@field source acp.PermissionStrategy
---@field selected_kind? acp.PermissionOptionKind
---@field selected_option_name? string
---@field selected_option_id? string
---@field options acp.PermissionOption[]

---@class acp.PermissionOption
---@field optionId string
---@field name string
---@field kind acp.PermissionOptionKind

---@class acp.PermissionRequest
---@field sessionId string
---@field toolCall { toolCallId?: string, title?: string }
---@field options acp.PermissionOption[]

---@class acp.PermissionOutcome
---@field outcome 'cancelled'|'selected'
---@field optionId? string

---@class acp.PlanEntry
---@field content string
---@field priority? string
---@field status string

---@class acp.AvailableCommandInput
---@field hint string

---@class acp.AvailableCommand
---@field name string
---@field description string
---@field input? acp.AvailableCommandInput

---@class acp.SessionConfigOptionValue
---@field value string
---@field name string
---@field description? string

---@class acp.SessionConfigOptionGroup
---@field group string
---@field name string
---@field options acp.SessionConfigOptionValue[]

---@alias acp.SessionConfigOptionEntry
---| acp.SessionConfigOptionValue
---| acp.SessionConfigOptionGroup

---@class acp.SessionConfigOption
---@field id string
---@field name string
---@field currentValue string
---@field description? string
---@field category? string
---@field type? acp.SessionConfigOptionType
---@field options? acp.SessionConfigOptionEntry[]

---@class acp.InitializeResult
---@field protocolVersion integer
---@field agentCapabilities? acp.AgentCapabilities
---@field agentInfo? acp.AgentInfo
---@field authMethods? acp.AuthMethod[]

---@class acp.SessionNewResult
---@field sessionId string
---@field configOptions? acp.SessionConfigOption[]

---@class acp.SessionLoadResult
---@field configOptions? acp.SessionConfigOption[]

---@class acp.SessionSetConfigOptionResult
---@field configOptions acp.SessionConfigOption[]

---@class acp.PromptResult
---@field stopReason acp.StopReason

---@class acp.ToolCall
---@field toolCallId string
---@field title string
---@field status? acp.ToolCallStatus
---@field kind? acp.ToolKind
---@field locations? acp.ToolCallLocation[]
---@field content? acp.ToolCallContent[]
---@field rawInput? table
---@field rawOutput? table

---@class acp.ToolCallUpdate
---@field toolCallId string
---@field title? string
---@field status? acp.ToolCallStatus
---@field kind? acp.ToolKind
---@field locations? acp.ToolCallLocation[]
---@field content? acp.ToolCallContent[]
---@field rawInput? table
---@field rawOutput? table

---@class acp.RpcClient
---@field start fun(self: acp.RpcClient): boolean, string?
---@field request_sync fun(self: acp.RpcClient, method: string, params: table, timeout_ms?: integer): any, table?
---@field request fun(self: acp.RpcClient, method: string, params: table, callback: fun(result?: any, error?: table))
---@field notify fun(self: acp.RpcClient, method: string, params: table)
---@field close fun(self: acp.RpcClient)

---@class acp.Config
---@field chat_buffer_name string
---@field filetype string
---@field auto_create_session boolean
---@field persist_sessions boolean
---@field restore_sessions_on_setup boolean
---@field session_state_file string
---@field terminal_backend acp.TerminalBackendName
---@field auto_open_on_setup boolean
---@field enable_hover_lsp boolean
---@field prompt_header string
---@field transcript_header string
---@field protocol_version integer
---@field client_info acp.ClientInfo
---@field client_capabilities acp.ClientCapabilities
---@field cwd string?
---@field mcp_servers table[]
---@field enable_mcp_nvim boolean
---@field mcp_nvim_guidance boolean
---@field auth_method string?
---@field request_timeout_ms integer
---@field default_adapter string
---@field adapters table<string, acp.AdapterConfig>
---@field permission_strategy acp.PermissionStrategy
---@field permission_default acp.PermissionOptionKind

---@class acp.SessionPersistencePayload
---@field current_id string?
---@field next_ordinal integer
---@field next_message_id integer
---@field next_pending_approval_ordinal integer
---@field sessions acp.Session[]

---@class acp.PendingApproval
---@field request_id string
---@field ordinal integer
---@field tool_call_id string?
---@field title string
---@field options acp.PermissionOption[]
---@field generation integer
---@field created_at integer

---@class acp.PendingPermissionState
---@field request_id string
---@field generation integer
---@field local_session_id string
---@field permission acp.PermissionRequest
---@field respond fun(result?: any, error?: table)
