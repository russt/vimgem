" Copyright (c) 2025-2026 Russ Tremain.
" Released under the MIT License. See LICENSE file for details.
vim9script

# autoload/ai/config.vim
# AIConfig - plugin-wide configuration container and chat session registry.
#
# Constructed once at plugin load time (by AIPlugin.new()) and shared by
# reference with every provider and AIBuffer. Reads from g: variables
# and environment at new() time; most fields can also be updated at
# runtime via Set() (called by :AISet / :AIProvider / :AIModel etc.).
#
# Every configurable field has a matching g: variable that is kept in
# sync on every Set() call, so :let g:claude_model in a script or
# .vimrc written AFTER plugin load still takes effect via :AISet.
#
# CONFIGURABLE_KEYS is the single authoritative list of fields exposed
# to :AISet and its tab-completion; adding a new field here is the only
# change needed to make it user-accessible. The Get()/Set() chain-of-
# elseif blocks must also be updated when a new key is added.
#
# ChatSessionInfo registry:
# Each open chat buffer gets an entry in active_chats keyed by chat_id.
# This lets providers, buffer.vim, and core.vim all look up per-chat
# provider/model/api_version without going through global config, which
# means global :AIProvider / :AIModel changes don't silently affect
# in-flight chats. AIPlugin (core.vim) is the only caller of
# RegisterChatSession / UnregisterChatSession - providers and buffer.vim
# only read via the getter methods.
#
# Note on base_url: intentionally not stored in ChatSessionInfo for now.
# It is a provider-level global attribute (openai only). Deferred to a
# future iteration when per-chat URL snapshots become useful.

# Fallback model names used when neither g: nor the provider's own
# config specifies one. Centralized here so every provider picks up the
# same default without repeating the string in multiple files.
export const PROVIDER_MODEL_DEFAULTS: dict<string> = {
    gemini: 'gemini-3.5-flash-lite',
    claude: 'claude-sonnet-4-6',
    openai: '',
}

# ChatSessionInfo - per-chat snapshot of provider, model, and api_version
# taken at the moment the chat is created or resumed. Keyed in
# active_chats by chat_id (e.g. 'chat-20260824-104203').
#
# Fields:
#   chat_id:     string  - the chat's unique identifier
#   bufnr:       number  - vim buffer number, for BufWipeout matching
#   provider:    string  - 'gemini' | 'claude' | 'openai'
#   model:       string  - model name at creation/resume time
#   api_version: string  - api version at creation/resume time
#   pid:         number  - getpid(), for future multi-process use
#   md_file:     string  - full path to the chat's .md transcript file
#
# base_url is deferred - it is a provider-level global, not per-chat.
export type ChatSessionInfo = dict<any>

export class AIConfig
    public var provider: string
    public var show_prompt: bool
    public var curl_trace_level: number
    public var always_review_received_files: bool
    public var vimgem_version: string
    public var vimgem_chat_home: string
    public var html_display_url: string

    public var gemini_model: string
    public var gemini_api_version: string
    public var gemini_api_key: string

    public var claude_model: string
    public var claude_api_version: string
    public var claude_api_key: string

    public var openai_base_url: string
    public var openai_model: string
    public var openai_api_key: string

    # Active chat session registry. Keyed by chat_id. Only AIPlugin
    # (core.vim) writes to this via Register/Unregister; all other
    # callers use the read-only getter methods below.
    var active_chats: dict<ChatSessionInfo> = {}

    # All keys the user can read/write via :AISet. Also used by
    # CompleteConfigKeys in ai.vim for tab-completion. Must stay in sync
    # with the Get()/Set() dispatch blocks below.
    static const CONFIGURABLE_KEYS: list<string> = [
        'gemini_model', 'gemini_api_version', 'gemini_api_key',
        'claude_model', 'claude_api_version', 'claude_api_key',
        'openai_model', 'openai_api_key', 'openai_base_url',
        'show_prompt', 'curl_trace_level', 'always_review_received_files',
        'vimgem_version', 'vimgem_chat_home', 'html_display_url',
    ]

    def new()
        this.provider = get(g:, 'ai_provider', 'gemini')
        this.show_prompt = get(g:, 'show_prompt', 1) == 1
        this.curl_trace_level = get(g:, 'ai_curl_trace_level', 9)
        this.always_review_received_files = get(g:, 'always_review_received_files', 1) == 1
        this.vimgem_version = get(g:, 'vimgem_version', 'NULL')

        # Chat home resolution order:
        #   1. g:vimgem_chat_home (set in .vimrc)
        #   2. $VIMGEM_CHAT_HOME  (shell environment)
        #   3. ~/.vimgem/ai-chat  (built-in default)
        # The resolved path is written back to g: so buffer.vim's
        # ChatDir() and other g: readers see the same value without
        # needing a reference to this config object.
        var env_chat_home = getenv('VIMGEM_CHAT_HOME')
        var chat_home = get(g:, 'vimgem_chat_home', '')
        if empty(chat_home) && !empty(env_chat_home)
            chat_home = env_chat_home
        endif
        if empty(chat_home)
            chat_home = '~/.vimgem/ai-chat'
        endif
        g:vimgem_chat_home = chat_home
        this.vimgem_chat_home = chat_home

        if !empty(chat_home)
            var expanded_home = expand(chat_home)
            if !isdirectory(expanded_home)
                mkdir(expanded_home, 'p')
            endif
        endif

        this.gemini_model = get(g:, 'gemini_model', PROVIDER_MODEL_DEFAULTS.gemini)
        this.gemini_api_version = get(g:, 'gemini_api_version', 'v1')
        this.gemini_api_key = $GOOGLE_API_KEY

        this.claude_model = get(g:, 'claude_model', PROVIDER_MODEL_DEFAULTS.claude)
        this.claude_api_version = get(g:, 'claude_api_version', '2023-06-01')
        this.claude_api_key = $ANTHROPIC_API_KEY

        this.html_display_url = get(g:, 'ai_html_display_url', '')

        this.openai_base_url = get(g:, 'openai_base_url', 'http://localhost:9090')
        this.openai_model = get(g:, 'openai_model', PROVIDER_MODEL_DEFAULTS.openai)
        this.openai_api_key = get(g:, 'openai_api_key', $OPENAI_API_KEY)
    enddef

    def SetProvider(provider_name: string): bool
        var valid_providers = ['gemini', 'claude', 'openai']
        if index(valid_providers, provider_name) == -1
            return false
        endif
        this.provider = provider_name
        g:ai_provider = provider_name
        return true
    enddef

    def IsValidKey(key: string): bool
        return index(CONFIGURABLE_KEYS, key) != -1
    enddef

    # Returns the api_version string for the named provider from global
    # config. Used by RegisterChatSession to snapshot the current
    # api_version at chat creation/resume time.
    def ApiVersionForProvider(provider: string): string
        if provider == 'gemini'
            return this.gemini_api_version
        elseif provider == 'claude'
            return this.claude_api_version
        else
            return ''
        endif
    enddef

    # ========================================================================
    # ChatSessionInfo Registry
    # ========================================================================
    # Register a new chat session. Called by AIPlugin.Chat() and
    # AIPlugin.ChatResume() after the buffer is confirmed open. Snapshots
    # provider, model, and api_version from the current global config so
    # later global changes do not affect this chat's execution.
    # md_file is the full path to the chat's .md transcript on disk,
    # used by ShowChatInfo to count lines without reconstructing the path.
    # Returns the newly created ChatSessionInfo so the caller can inspect
    # it (e.g. to echo the confirmation message) without a second lookup.
    def RegisterChatSession(chat_id: string, bufnr: number, provider: string, model: string, api_version: string, md_file: string): ChatSessionInfo
        var entry: ChatSessionInfo = {
            chat_id:     chat_id,
            bufnr:       bufnr,
            provider:    provider,
            model:       model,
            api_version: api_version,
            pid:         getpid(),
            md_file:     md_file,
        }
        this.active_chats[chat_id] = entry
        return entry
    enddef

    # Unregister the chat session whose buffer number matches bufnr.
    # Called from the BufWipeout autocmd in ai.vim. Silently does nothing
    # if no session matches (e.g. a non-chat buffer was wiped).
    def UnregisterChatSession(bufnr: number)
        for chat_id in keys(this.active_chats)
            if this.active_chats[chat_id].bufnr == bufnr
                remove(this.active_chats, chat_id)
                return
            endif
        endfor
    enddef

    # -------------------------------------------------------------------------
    # Whole-record lookups. Return {} when not found so callers can use
    # empty(session) as the "not in a chat" check.
    # -------------------------------------------------------------------------

    # Look up a session by chat_id.
    def GetChatSession(chat_id: string): ChatSessionInfo
        return get(this.active_chats, chat_id, {})
    enddef

    # Look up a session by buffer number. Scans active_chats linearly;
    # the registry is small (one entry per open chat buffer) so this is fine.
    def GetChatSessionForBuffer(bufnr: number): ChatSessionInfo
        for chat_id in keys(this.active_chats)
            if this.active_chats[chat_id].bufnr == bufnr
                return this.active_chats[chat_id]
            endif
        endfor
        return {}
    enddef

    # Convenience: look up by the current buffer's number.
    def GetChatSessionForCurrentBuffer(): ChatSessionInfo
        return this.GetChatSessionForBuffer(bufnr('%'))
    enddef

    # Returns all registered chat sessions as a list, sorted by chat_id
    # (which is timestamp-based, so this is chronological order).
    # Used by ShowChatInfo to render the session list in :AIInfo.
    def GetAllChatSessions(): list<ChatSessionInfo>
        var all = values(this.active_chats)
        return sort(all, (a, b) => a.chat_id < b.chat_id ? -1 : a.chat_id > b.chat_id ? 1 : 0)
    enddef

    # -------------------------------------------------------------------------
    # Per-field getters. All take session: ChatSessionInfo (already looked
    # up by the caller via GetChatSession / GetChatSessionForBuffer /
    # GetChatSessionForCurrentBuffer). Return a safe zero value ('', -1, 0)
    # when the session is empty, so callers do not need to guard every field
    # access after confirming non-empty session.
    #
    # Callers look up the session once and pass it here; this avoids
    # repeated linear scans of active_chats for each field access.
    # -------------------------------------------------------------------------

    def GetSessionChatId(session: ChatSessionInfo): string
        return get(session, 'chat_id', '')
    enddef

    def GetSessionBufNr(session: ChatSessionInfo): number
        return get(session, 'bufnr', -1)
    enddef

    def GetSessionProvider(session: ChatSessionInfo): string
        return get(session, 'provider', '')
    enddef

    def GetSessionModel(session: ChatSessionInfo): string
        return get(session, 'model', '')
    enddef

    def GetSessionApiVersion(session: ChatSessionInfo): string
        return get(session, 'api_version', '')
    enddef

    def GetSessionPid(session: ChatSessionInfo): number
        return get(session, 'pid', 0)
    enddef

    def GetSessionMdFile(session: ChatSessionInfo): string
        return get(session, 'md_file', '')
    enddef

    # -------------------------------------------------------------------------
    # Per-field updaters. Called from AIPlugin only, when the user runs
    # :AIProvider, :AIModel, or :AISet from within a chat buffer. These
    # update only the named chat's snapshot; the global config is updated
    # separately by the command handler in core.vim.
    # -------------------------------------------------------------------------

    def UpdateChatSessionProvider(chat_id: string, provider: string)
        if has_key(this.active_chats, chat_id)
            this.active_chats[chat_id].provider = provider
        endif
    enddef

    def UpdateChatSessionModel(chat_id: string, model: string)
        if has_key(this.active_chats, chat_id)
            this.active_chats[chat_id].model = model
        endif
    enddef

    def UpdateChatSessionApiVersion(chat_id: string, api_version: string)
        if has_key(this.active_chats, chat_id)
            this.active_chats[chat_id].api_version = api_version
        endif
    enddef

    # ========================================================================
    # Global config Get / Set
    # ========================================================================

    # Read any CONFIGURABLE_KEY by name. Returns a string in all cases
    # (booleans as '1'/'0', numbers as their decimal representation) so
    # callers always get a printable value without needing to know the
    # field's type. Echoes an error and returns '' for unknown keys.
    def Get(key: string): string
        if key == 'gemini_model'           | return this.gemini_model
        elseif key == 'gemini_api_version' | return this.gemini_api_version
        elseif key == 'gemini_api_key'     | return this.gemini_api_key
        elseif key == 'claude_model'       | return this.claude_model
        elseif key == 'claude_api_version' | return this.claude_api_version
        elseif key == 'claude_api_key'     | return this.claude_api_key
        elseif key == 'openai_model'       | return this.openai_model
        elseif key == 'openai_api_key'     | return this.openai_api_key
        elseif key == 'openai_base_url'    | return this.openai_base_url
        elseif key == 'show_prompt'        | return this.show_prompt ? '1' : '0'
        elseif key == 'curl_trace_level'   | return string(this.curl_trace_level)
        elseif key == 'always_review_received_files' | return this.always_review_received_files ? '1' : '0'
        elseif key == 'vimgem_version'     | return this.vimgem_version
        elseif key == 'vimgem_chat_home'   | return this.vimgem_chat_home
        elseif key == 'html_display_url'   | return this.html_display_url
        else
            echoerr $"Unknown config key '{key}'. Run :AISet with no args to list valid keys."
            return ''
        endif
    enddef

    # Set any CONFIGURABLE_KEY by name. Mirrors the new value back to
    # the corresponding g: variable so later g: reads are consistent.
    # Boolean fields accept '1'/'on' as true; vimgem_chat_home also
    # creates the directory on disk if it doesn't exist yet.
    def Set(key: string, value: string): bool
        if key == 'gemini_model'           | this.gemini_model = value
        elseif key == 'gemini_api_version' | this.gemini_api_version = value
        elseif key == 'gemini_api_key'     | this.gemini_api_key = value
        elseif key == 'claude_model'       | this.claude_model = value
        elseif key == 'claude_api_version' | this.claude_api_version = value
        elseif key == 'claude_api_key'     | this.claude_api_key = value
        elseif key == 'openai_model'       | this.openai_model = value
        elseif key == 'openai_api_key'     | this.openai_api_key = value
        elseif key == 'openai_base_url'    | this.openai_base_url = value
        elseif key == 'show_prompt'        | this.show_prompt = (value == '1' || value == 'on')
        elseif key == 'curl_trace_level'   | this.curl_trace_level = str2nr(value)
        elseif key == 'always_review_received_files' | this.always_review_received_files = (value == '1' || value == 'on')
        elseif key == 'vimgem_version'     | this.vimgem_version = value
        elseif key == 'html_display_url'   | this.html_display_url = value
        elseif key == 'vimgem_chat_home'
            this.vimgem_chat_home = value
            if !empty(value)
                var expanded_home = expand(value)
                if !isdirectory(expanded_home)
                    mkdir(expanded_home, 'p')
                endif
            endif
        else
            echoerr $"Unknown config key '{key}'. Run :AISet with no args to list valid keys."
            return false
        endif

        # Mirror to g: so scripts/plugins that read g: directly stay
        # in sync. Boolean fields are stored as 0/1 integers (not '1'/'0'
        # strings) to match the convention in .vimrc let statements.
        if key == 'show_prompt' || key == 'always_review_received_files'
            g:[key] = this.Get(key) == '1' ? 1 : 0
        elseif key == 'curl_trace_level'
            g:ai_curl_trace_level = this.curl_trace_level
        else
            g:[key] = value
        endif
        return true
    enddef

    # Lines used by :AIInfo to display the current plugin configuration.
    def GetHeaderLines(): list<string>
        return [
            '# AI Plugin Information',
            '',
            '## Configuration',
            $'  Current Provider: {this.provider}',
            $'  Show Prompt: {this.show_prompt ? "Yes" : "No"}',
            $'  Curl Trace Level: {this.curl_trace_level}',
            $'  Always Review Received Files: {this.always_review_received_files ? "Yes" : "No"}',
            $'  Chat Home: {this.vimgem_chat_home}',
        ]
    enddef

    # Lines used by :AIInfo for the command reference and .vimrc examples.
    def GetCommandsAndVarsLines(): list<string>
        return [
            '## Available Commands',
            '  :AIProvider <name>          - Set provider (gemini|claude|openai)',
            '  :AIQuery <prompt>           - Ask AI a question',
            '  :AIChat                     - Open a persistent chat buffer',
            '  :AIChatSend                 - Send the chat buffer',
            '  :AIChatClear                - Clear this chat''s history',
            '  :AIChatHistory              - List saved chat sessions',
            '  :AIChatResume               - Resume a chat session',
            '  :AIChatDelete               - Delete chat under cursor',
            '  :AIChatDisplay              - Open chat in default browser',
            '  :AIAsk                      - Send selected text as prompt',
            '  :AIExplain                  - Explain selected code',
            '  :AIReview                   - Review selected code',
            '  :AIReviewFile               - Review entire file',
            '  :AIModels                   - List available models',
            '  :AIInfo                     - Show plugin information',
            '  :AIModel [model]            - Set model for current provider',
            '  :AIPrompt [on|off]          - Toggle/set whether responses include the prompt',
            '  :AIReviewReceived [on|off]  - Set review behavior for received files',
            '  :AIUrl [url]                - Set base URL (openai provider only)',
            '  :DBGSet [levels]            - Configure active debug levels (e.g. 1,2, 1-4, 0 to disable)',
            '  :DBGShowLog                 - Display the debug message log for this session',
            '  :DBGShowAST                 - Display the Markdown AST for the current buffer',
            '  :AISet [key] [value]        - Get/set any config key',
            '',
            '## Configuration Options (set in .vimrc)',
            '  let g:ai_provider = "gemini"',
            '  let g:show_prompt = 1',
            '  let g:ai_curl_trace_level = 9',
            '  let g:always_review_received_files = 1',
            '  let g:vimgem_chat_home = "~/.vimgem/ai-chat"',
            '  let g:ai_html_display_url = ""   " e.g. \"http://127.0.0.1:8765\" for remote browser display',
            '  let g:set_debug_levels = "1,5"  " e.g. \"1-4\" or \"1,5\" to enable debug tracing',
        ]
    enddef
endclass
