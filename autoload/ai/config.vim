"use vim9 script only:
vim9script

# autoload/ai/config.vim
# Configuration Class
#
# Holds all provider settings plus the plugin-wide toggles (show_prompt,
# debug). Providers read/write their own fields on this object rather than
# keeping any state themselves, so switching providers never loses settings.

# Single source of truth for each provider's default model, so it's not
# repeated (and risking drift) across the config constructor, the
# SetProvider re-sync, and the docs shown by :AIInfo.
# openai defaults to empty (no model field sent) rather than a placeholder:
# the official mlx_lm.server docs show requests with NO "model" field at
# all, and if a model name IS given but isn't already loaded, mlx_lm.server
# tries to fetch it from Hugging Face - a made-up placeholder actively
# breaks things there. Other single-model servers commonly behave the
# same (ignore or don't require the field). Multi-model servers (Ollama,
# vLLM, api.openai.com) DO route based on this value - set g:openai_model
# / :AISetModel to the real name for those.
export const PROVIDER_MODEL_DEFAULTS: dict<string> = {
    gemini: 'gemini-3.5-flash-lite',
    claude: 'claude-sonnet-4-6',
    openai: '',
}

export class AIConfig
    public var provider: string
    public var show_prompt: bool
    public var debug: bool
    # Controls how a {=>*=} response block tagged with a real filename
    # (see AIPrompt.ExtractIdentifiedBlocks) gets written back. Default
    # (true): open a new tab under the real filename with buftype=
    # (so a plain :w just works) instead, for review before it touches
    # disk. False: write straight to disk. Has no effect on
    # UNIDENTIFIED blocks - those still always open as [AI-output-N]
    # review tabs, same as before this flag existed.
    public var always_review_received_files: bool
    public var vimgem_version: string
    public var vimgem_chat_home: string

    # Provider-specific configs
    public var gemini_model: string
    public var gemini_api_version: string
    public var gemini_api_key: string

    public var claude_model: string
    public var claude_api_version: string
    public var claude_api_key: string

    # OpenAI-compatible config (works for local servers like mlx_lm.server,
    # Ollama, LM Studio, vLLM, as well as api.openai.com itself)
    public var openai_base_url: string
    public var openai_model: string
    public var openai_api_key: string

    # Every configurable setting, provider-specific or plugin-wide,
    # reachable via :AISet. Dedicated commands (:AIModel, :AIUrl,
    # :AIDebug, :AIPrompt) still exist for the extra behavior they add
    # (mismatch warnings, toggle-with-no-arg) - they are not gatekeeping;
    # :AISet reaches every one of these same fields too, for the expert
    # user who wants direct access without a command per field.
    static const CONFIGURABLE_KEYS: list<string> = [
        'gemini_model', 'gemini_api_version', 'gemini_api_key',
        'claude_model', 'claude_api_version', 'claude_api_key',
        'openai_model', 'openai_api_key', 'openai_base_url',
        'show_prompt', 'debug', 'always_review_received_files',
        'vimgem_version', 'vimgem_chat_home',
    ]

    def new()
        this.provider = get(g:, 'ai_provider', 'gemini')
        this.show_prompt = get(g:, 'show_prompt', 1) == 1
        this.debug = get(g:, 'debug', 0) == 1
        this.always_review_received_files = get(g:, 'always_review_received_files', 1) == 1
        this.vimgem_version = get(g:, 'vimgem_version', 'NULL')

        # Chat Directory config
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

        # Gemini config
        this.gemini_model = get(g:, 'gemini_model', PROVIDER_MODEL_DEFAULTS.gemini)
        this.gemini_api_version = get(g:, 'gemini_api_version', 'v1')
        this.gemini_api_key = $GOOGLE_API_KEY

        # Claude config
        this.claude_model = get(g:, 'claude_model', PROVIDER_MODEL_DEFAULTS.claude)
        this.claude_api_version = get(g:, 'claude_api_version', '2023-06-01')
        this.claude_api_key = $ANTHROPIC_API_KEY

        # OpenAI-compatible config
        # base_url should have no trailing slash and no path suffix,
        # e.g. 'http://localhost:9090' or 'https://api.openai.com'
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

    # Returns '' (and echoerr's) for an unknown key rather than throwing,
    # since this is driven by user-typed command args via :AISet.
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
        elseif key == 'debug'              | return this.debug ? '1' : '0'
        elseif key == 'always_review_received_files' | return this.always_review_received_files ? '1' : '0'
        elseif key == 'vimgem_version'     | return this.vimgem_version
        elseif key == 'vimgem_chat_home'   | return this.vimgem_chat_home
        else
            echoerr $"Unknown config key '{key}'. Run :AISet with no args to list valid keys."
            return ''
        endif
    enddef

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
        elseif key == 'debug'              | this.debug = (value == '1' || value == 'on')
        elseif key == 'always_review_received_files' | this.always_review_received_files = (value == '1' || value == 'on')
        elseif key == 'vimgem_version'     | this.vimgem_version = value
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

        # g: is a real dict, so this works directly - no execute() needed.
        # Bool fields store an int (matches the `get(g:, key, default) == 1`
        # read-back in new()); everything else stores the raw string.
        if key == 'show_prompt' || key == 'debug' || key == 'always_review_received_files'
            g:[key] = this.Get(key) == '1' ? 1 : 0
        else
            g:[key] = value
        endif
        return true
    enddef

    def GetHeaderLines(): list<string>
        return [
            '# AI Plugin Information',
            '',
            '## Configuration',
            $'  Current Provider: {this.provider}',
            $'  Show Prompt: {this.show_prompt ? "Yes" : "No"}',
            $'  Debug Mode: {this.debug ? "On" : "Off"}',
            $'  Always Review Received Files: {this.always_review_received_files ? "Yes" : "No"}',
            $'  Chat Home: {this.vimgem_chat_home}',
        ]
    enddef

    def GetCommandsAndVarsLines(): list<string>
        return [
            '## Available Commands',
            '  :AIProvider <name>          - Set provider (gemini|claude|openai)',
            '  :AIQuery <prompt>           - Ask AI a question',
            '  :AIChat                     - Open a persistent chat buffer',
            '  :AIChatSend                 - Send the chat buffer (or a',
            '                                visual selection within it)',
            '                                as the next turn. Supports',
            '                                register refs ({=''a=},',
            '                                {=1,10<''#>=}) plus two',
            '                                directives only valid here:',
            '                                {=<name=}  read whole file/',
            '                                           buffer `name`',
            '                                {=>name=}  write the reply to',
            '                                           `name` (created if',
            '                                           needed) instead of',
            '                                           the chat buffer;',
            '                                           {=>new(scratch)=}',
            '                                           for a fresh scratch',
            '                                           buffer',
            '  :AIChatClear                - Clear this chat''s history',
            '                                (context only - the visible',
            '                                transcript is untouched)',
            '  :AIChatHistory              - List saved chat sessions',
            '  :AIChatResume               - Resume a chat: put the',
            '                                cursor on a session line',
            '                                (from :AIChatHistory) and',
            '                                run this, or run it anywhere',
            '                                else to resume the most',
            '                                recent session.',
            '  :AIChatDelete                - Delete the chat under the',
            '                                cursor (run from',
            '                                :AIChatHistory; no fallback,',
            '                                errors if not on a session',
            '                                line)',
            '  :AIChatDisplay               - Open a chat''s rendered',
            '                                HTML in the OS default',
            '                                browser. Cursor on a',
            '                                :AIChatHistory session line,',
            '                                or run from inside a chat',
            '                                buffer to view that session;',
            '                                otherwise opens the most',
            '                                recent one. Mac: uses `open`.',
            '                                Linux: `xdg-open`/`wslview`',
            '                                if present. Windows: `start`',
            '                                via cmd.exe. Untested beyond',
            '                                mac.',
            '  :AIAsk                      - Send selected text as prompt',
            '                                Supports register refs: {=''a=}',
            '                                and buffer refs: {=1,10<''#>=}',
            '  :AIExplain                  - Explain selected code',
            '  :AIReview                   - Review selected code',
            '  :AIReviewFile               - Review entire file',
            '  :AIModels                   - List available models',
            '  :AIInfo                     - Show this information',
            '  :AIModel [model]            - Set model for current',
            '                                provider. With no name: uses',
            '                                the model under the cursor',
            '                                if run from :AIModels,',
            '                                otherwise shows the current',
            '                                model.',
            '  :AIDebug [on|off]           - Toggle/set debug mode (echoes curl commands, API keys redacted)',
            '  :AIPrompt [on|off]          - Toggle/set whether responses include the prompt',
            '  :AIReviewReceived [on|off]  - Set whether {=>*=} blocks',
            '                                tagged with a real filename',
            '                                (via {=<name=} round-trip) open',
            '                                in a review tab instead of being',
            '                                written straight to disk. No',
            '                                arg reports the current value',
            '                                only - unlike :AIPrompt/',
            '                                :AIDebug, it does NOT toggle,',
            '                                since this flag guards against',
            '                                clobbering files on disk.',
            '  :AIUrl [url]                - Set base URL (openai provider only)',
            '  :AISet [key] [value]        - Get/set any config key (model,',
            '                                api version, api key, or base',
            '                                url per provider, plus',
            '                                show_prompt/debug). No args:',
            '                                list valid keys. Key only:',
            '                                show its value. Both: set it.',
            '                                Tab-completes the key.',
            '                                Examples:',
            '                                  :AISet',
            '                                  :AISet claude_api_version',
            '                                  :AISet claude_api_version 2024-01-01',
            '                                Note: values are literal text,',
            '                                NOT evaluated like :let - do',
            '                                not quote strings.',
            '                                  Right: :AISet gemini_api_version v1beta',
            '                                  Wrong: :AISet gemini_api_version "v1beta"',
            '                                (the wrong form sets the value',
            '                                to the 8 characters "v1beta",',
            '                                quotes included, which breaks',
            '                                the API request)',
            '',
            '## Configuration Options (set in .vimrc)',
            '  let g:ai_provider = "gemini"  # or "claude" or "openai"',
            '  let g:show_prompt = 1',
            '  let g:debug = 0',
            '  let g:always_review_received_files = 1  # 0 = write straight to disk, no review',
            '  let g:vimgem_chat_home = "~/.vimgem/ai-chat"  # where :AIChat transcripts are saved',
            '  let g:ai_chat_autosave = 1            # write transcript to disk after each turn',
            '  let g:ai_chat_html_autosave = 1       # also render transcript to chat-<id>.html after each turn',
        ]
    enddef
endclass
