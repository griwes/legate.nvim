+# Legate Threat Model
+
+## Security boundary
+
+Legate launches an explicitly configured ACP adapter and services that adapter's
+requests inside Neovim. The adapter is not sandboxed: it receives prompts,
+transcripts, configuration, workspace metadata, and responses to approved
+operations. A compromised or malicious adapter must be assumed capable of
+sending arbitrary protocol input.
+
+Trusted inputs are the user's Legate configuration, adapter command, permission
+policy callback, and optional Terminalia and Ministry integrations. Adapter
+messages, tool arguments, terminal output, and restored remote identifiers are
+untrusted.
+
+## Adapter process and protocol
+
+The configured adapter command runs with Neovim's operating-system authority
+and configured environment. Authentication settings and MCP server headers may
+contain secrets and are passed to the selected adapter. Legate does not verify
+the adapter binary's provenance.
+
+JSON-RPC frame size, queued bytes, stderr retention, active inbound request
+count and bytes, and inbound request lifetime are bounded. Cancellation and
+late-response accounting prevent stale requests from silently taking over a
+new lifecycle. These controls reduce resource abuse; they do not make the
+adapter safe to run outside the user's trust boundary.
+
+## Filesystem requests
+
+ACP file operations derive their allowed roots from the active local session
+workspace, not from an adapter-supplied root. Existing roots and targets are
+canonicalized. Missing targets are authorized through their nearest existing
+parent, and broken links or symlinks escaping an allowed root are rejected.
+Open-buffer writes retain a canonical-target guard until the later buffer write.
+
+These checks constrain Legate's ACP filesystem handlers only. They do not
+constrain adapter-owned processes, terminal commands, other plugins,
+autocommands, or commands executed through a separately configured MCP server.
+Normal filesystem permissions and races outside Neovim still apply.
+
+## Permissions and terminal execution
+
+The default permission outcome rejects once. Interactive and callback-based
+policies can authorize adapter requests; custom callbacks are trusted code.
+Approval display text is descriptive input from the adapter and should not be
+treated as proof of what an external command will do.
+
+Both native and Terminalia terminal backends execute requested commands with
+the Neovim user's authority. The native backend is hidden but not isolated.
+The Terminalia backend delegates lifecycle and inherits Terminalia's trust
+model. Release, cancellation, deadlines, and bounded output are lifecycle
+controls rather than sandboxing.
+
+Opting into Ministry endpoint injection gives the adapter access to the tools
+and resources authorized by that Ministry instance. Ministry approvals and
+transport policy remain a separate security boundary.
+
+## Persistence and disclosure
+
+Local sessions persist by default and can contain prompts, assistant output,
+tool rows, approval history, drafts, configuration options, slash commands,
+workspace paths, and remote binding metadata. Persistence restores local data
+but does not implicitly trust or resume a remote session. Protect the Neovim
+state directory and disable `persist_sessions` for sensitive conversations.
+
+## Operational guidance
+
+- Install adapter binaries from a trusted source and pin or audit updates.
+- Keep the default rejecting permission policy unless a narrower policy is
+  deliberately configured.
+- Review adapter environment, auth settings, MCP headers, and workspace roots.
+- Treat persisted transcripts and issue-report logs as sensitive.
+- Use operating-system sandboxing or a lower-privilege account for untrusted
+  adapters or workloads.
+

