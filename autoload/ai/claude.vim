" Copyright (c) 2025-2026 Russ Tremain.
" Released under the MIT License. See LICENSE file for details.
vim9script

# autoload/ai/claude.vim
# Claude Provider Implementation
#
# Self-contained: to work on Claude-specific behavior you only need this
# file plus config.vim (for the AIConfig type), provider.vim (for the
# interface it implements) and util.vim (for RedactSecret). None of the
# Gemini/OpenAI provider code is needed.
#
# Per-chat model and api_version are read from the ChatSessionInfo
# registry. ResolveModelAndVersion looks up the session once via
# this.config.GetChatSession(chat_id) and then reads individual fields
# via GetSessionModel / GetSessionApiVersion. When chat_id is ''
# (one-shot commands: :AIQuery, :AIExplain, :AIReview, :AIReviewFile),
# the provider falls back to the global config fields
# this.config.claude_model and this.config.claude_api_version.
#
# This provider never writes to this.config. Model and provider
# selection are config/session concerns managed by AIPlugin (core.vim).
#
# GenerateContent and GenerateChat return dict<any> - see provider.vim
# for the return value convention.

import './config.vim' as Cfg
import './provider.vim' as Provider
import './util.vim' as Util

export class ClaudeProvider extends Provider.AIProvider
    const CLAUDE_MAX_TOKENS = 64000

    def new(config: Cfg.AIConfig)
        this.config = config
    enddef

    def IsValid(): bool
        return !empty(this.config.claude_api_key)
    enddef

    def GetAPIKeyError(): string
        return "Error: ANTHROPIC_API_KEY environment variable not set."
    enddef

    # Returns the global default model for display purposes (:AIInfo,
    # :AIModels, confirmation messages). Not the per-chat model.
    def GetDefaultModel(): string
        return this.config.claude_model
    enddef

    def GetStatusLines(): list<string>
        return [
            $'  Model (default): {this.config.claude_model}',
            $'  API Version: {this.config.claude_api_version}',
            $'  API Key: {!empty(this.config.claude_api_key) ? "Set" : "NOT SET"}',
        ]
    enddef

    def GetConfigLines(): list<string>
        return [
            '  let g:claude_model = "' .. Cfg.PROVIDER_MODEL_DEFAULTS.claude .. '"',
            '  let g:claude_api_version = "2023-06-01"',
            '  export ANTHROPIC_API_KEY="your-api-key"',
        ]
    enddef

    def IsRecognizedModel(model: string): bool
        return model =~ '^claude-'
    enddef

    # Resolve model and api_version for this call. Looks up the session
    # once via GetChatSession, then reads individual fields via the
    # per-field getters (GetSessionModel / GetSessionApiVersion) so
    # active_chats is only scanned once per call.
    # When chat_id is empty, falls back to global config.
    def ResolveModelAndVersion(chat_id: string): dict<string>
        if !empty(chat_id)
            var session = this.config.GetChatSession(chat_id)
            if !empty(session)
                var m = this.config.GetSessionModel(session)
                var v = this.config.GetSessionApiVersion(session)
                return {
                    model:       !empty(m) ? m : this.config.claude_model,
                    api_version: !empty(v) ? v : this.config.claude_api_version,
                }
            endif
        endif
        return {
            model:       this.config.claude_model,
            api_version: this.config.claude_api_version,
        }
    enddef

    # api_version is the Anthropic protocol version (e.g. '2023-06-01'),
    # resolved by ResolveModelAndVersion before this call and passed
    # explicitly so the correct per-chat version is used in the header
    # rather than always reading from global config.
    def ExecuteCurl(url: string, api_version: string, method: string = 'POST', payload: string = ''): dict<any>
        var curl_cmd = 'curl -s -X ' .. method
                    .. ' -H "Content-Type: application/json"'
                    .. ' -H "x-api-key: ' .. this.config.claude_api_key .. '"'
                    .. ' -H "anthropic-version: ' .. api_version .. '"'

        if method == 'POST' && !empty(payload)
            curl_cmd ..= ' -d ' .. shellescape(payload)
        endif

        curl_cmd ..= ' ' .. shellescape(url)

        g:DBG(this.config.curl_trace_level, '[AI debug] %s', Util.RedactSecret(curl_cmd, this.config.claude_api_key))

        var response = system(curl_cmd)
        var exit_code = v:shell_error

        if exit_code != 0
            return {error: $"curl failed with exit code {exit_code}"}
        endif

        try
            return {success: true, data: json_decode(response)}
        catch
            return {error: $"Error parsing JSON: {v:exception}", raw: response}
        endtry
    enddef

    def ListModels(): string
        if !this.IsValid()
            return this.GetAPIKeyError()
        endif

        # Claude doesn't have a public models endpoint, so we return a
        # hardcoded list. Check
        # https://docs.anthropic.com/claude/docs/models-overview for updates.
        var available_models = [
            'claude-opus-4-8',
            'claude-opus-4-7',
            'claude-sonnet-5',
            'claude-sonnet-4-6',
            'claude-haiku-4-5-20251001',
        ]

        var output = "Available Claude Models:\n\n"
        for model in available_models
            output ..= $"  {model}\n"
        endfor
        output ..= $"\nCurrent model: {this.config.claude_model}"
        output ..= "\n\nNote: This is a curated list. See https://docs.anthropic.com/claude/docs/models-overview for the latest models."

        return output
    enddef

    def GenerateContent(prompt: string, chat_id: string): dict<any>
        if !this.IsValid()
            return {ok: false, error: this.GetAPIKeyError()}
        endif

        var resolved = this.ResolveModelAndVersion(chat_id)
        var url = 'https://api.anthropic.com/v1/messages'
        var payload = json_encode({
            model:      resolved.model,
            max_tokens: this.CLAUDE_MAX_TOKENS,
            messages:   [{role: 'user', content: prompt}]
        })

        var result = this.ExecuteCurl(url, resolved.api_version, 'POST', payload)
        return this.ExtractResult(result)
    enddef

    def GenerateChat(messages: list<dict<string>>, chat_id: string): dict<any>
        if !this.IsValid()
            return {ok: false, error: this.GetAPIKeyError()}
        endif

        var resolved = this.ResolveModelAndVersion(chat_id)

        # Claude already uses 'user'/'assistant', so this is a direct map.
        var api_messages = []
        for m in messages
            add(api_messages, {role: m.role, content: m.text})
        endfor

        var url = 'https://api.anthropic.com/v1/messages'
        var payload = json_encode({
            model:      resolved.model,
            max_tokens: this.CLAUDE_MAX_TOKENS,
            messages:   api_messages
        })

        var result = this.ExecuteCurl(url, resolved.api_version, 'POST', payload)
        return this.ExtractResult(result)
    enddef

    # Shared response handling for GenerateContent and GenerateChat.
    # Returns dict<any> - see provider.vim for the return value convention.
    # Truncation is detected via stop_reason from the API metadata,
    # never by grepping the response text content.
    def ExtractResult(result: dict<any>): dict<any>
        if has_key(result, 'error')
            return {ok: false, error: $"Error: {result.error}"}
        endif

        var json_response = result.data

        if has_key(json_response, 'error')
            var error_type = get(json_response.error, 'type', 'unknown')
            var error_msg = get(json_response.error, 'message', 'Unknown error')
            return {ok: false, error: $"API Error ({error_type}): {error_msg}"}
        endif

        if has_key(json_response, 'content') && !empty(json_response.content)
            var content = json_response.content[0]
            if has_key(content, 'text')
                var stop_reason = get(json_response, 'stop_reason', '')
                if stop_reason == 'max_tokens'
                    return {ok: true, text: content.text, truncated: true}
                endif
                return {ok: true, text: content.text}
            endif
        endif

        return {ok: false, error: "Error: Received an empty or malformed response from the API."}
    enddef
endclass
