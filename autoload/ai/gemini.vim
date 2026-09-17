" Copyright (c) 2025-2026 Russ Tremain.
" Released under the MIT License. See LICENSE file for details.
vim9script

# autoload/ai/gemini.vim
# Gemini Provider Implementation
#
# Self-contained: to work on Gemini-specific behavior you only need this
# file plus config.vim (for the AIConfig type), provider.vim (for the
# interface it implements) and util.vim (for RedactSecret). None of the
# Claude/OpenAI provider code is needed.
#
# Per-chat model and api_version are read from the ChatSessionInfo
# registry. ResolveModelAndVersion looks up the session once via
# this.config.GetChatSession(chat_id) and then reads individual fields
# via GetSessionModel / GetSessionApiVersion. When chat_id is ''
# (one-shot commands: :AIQuery, :AIExplain, :AIReview, :AIReviewFile),
# the provider falls back to the global config fields
# this.config.gemini_model and this.config.gemini_api_version.
#
# This provider never writes to this.config. Model and provider
# selection are config/session concerns managed by AIPlugin (core.vim).
#
# GenerateContent and GenerateChat return dict<any> - see provider.vim
# for the return value convention.

import './config.vim' as Cfg
import './provider.vim' as Provider
import './util.vim' as Util

export class GeminiProvider extends Provider.AIProvider
    def new(config: Cfg.AIConfig)
        this.config = config
    enddef

    def IsValid(): bool
        return !empty(this.config.gemini_api_key)
    enddef

    def GetAPIKeyError(): string
        return "Error: GOOGLE_API_KEY environment variable not set."
    enddef

    # Returns the global default model for display purposes (:AIInfo,
    # :AIModels, confirmation messages). Not the per-chat model.
    def GetDefaultModel(): string
        return this.config.gemini_model
    enddef

    def GetStatusLines(): list<string>
        return [
            $'  Model (default): {this.config.gemini_model}',
            $'  API Version: {this.config.gemini_api_version}',
            $'  API Key: {!empty(this.config.gemini_api_key) ? "Set" : "NOT SET"}',
        ]
    enddef

    def GetConfigLines(): list<string>
        return [
            '  let g:gemini_model = "' .. Cfg.PROVIDER_MODEL_DEFAULTS.gemini .. '"',
            '  let g:gemini_api_version = "v1"',
            '  export GOOGLE_API_KEY="your-api-key"',
        ]
    enddef

    def IsRecognizedModel(model: string): bool
        return model =~ '^gemini-'
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
                    model:       !empty(m) ? m : this.config.gemini_model,
                    api_version: !empty(v) ? v : this.config.gemini_api_version,
                }
            endif
        endif
        return {
            model:       this.config.gemini_model,
            api_version: this.config.gemini_api_version,
        }
    enddef

    def BuildURL(endpoint: string, api_version: string): string
        return $'https://generativelanguage.googleapis.com/{api_version}/{endpoint}?key={this.config.gemini_api_key}'
    enddef

    def ExecuteCurl(url: string, method: string = 'GET', payload: string = ''): dict<any>
        var curl_cmd: string

        if method == 'POST'
            curl_cmd = 'curl -s -X POST -H "Content-Type: application/json" -d '
                        .. shellescape(payload) .. ' ' .. shellescape(url)
        else
            curl_cmd = 'curl -s -X GET ' .. shellescape(url)
        endif

        g:DBG(this.config.curl_trace_level, '[AI debug] %s', Util.RedactSecret(curl_cmd, this.config.gemini_api_key))

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

        # ListModels is not chat-specific; use the global api_version.
        var url = this.BuildURL('models', this.config.gemini_api_version)
        var result = this.ExecuteCurl(url)

        if has_key(result, 'error')
            return $"Error: {result.error}"
        endif

        var json_response = result.data

        if has_key(json_response, 'error')
            return $"API Error: {json_response.error.message}"
        endif

        if !has_key(json_response, 'models') || empty(json_response.models)
            return "Error: No models found in API response."
        endif

        var model_list = []
        for model in json_response.models
            var model_name = model.name
            var short_name = substitute(model_name, '^models/', '', '')

            if has_key(model, 'supportedGenerationMethods')
                var methods = model.supportedGenerationMethods
                if index(methods, 'generateContent') >= 0
                    var display_name = get(model, 'displayName', short_name)
                    add(model_list, $"  {short_name} - {display_name}")
                endif
            endif
        endfor

        if empty(model_list)
            return "No models found that support generateContent."
        endif

        var output = "Available Gemini Models (supporting generateContent):\n\n"
        output ..= join(model_list, "\n")
        output ..= $"\n\nCurrent model: {this.config.gemini_model}"
        return output
    enddef

    def GenerateContent(prompt: string, chat_id: string): dict<any>
        if !this.IsValid()
            return {ok: false, error: this.GetAPIKeyError()}
        endif

        var resolved = this.ResolveModelAndVersion(chat_id)
        var url = this.BuildURL($'models/{resolved.model}:generateContent', resolved.api_version)
        var payload = json_encode({
            contents: [{
                parts: [{text: prompt}]
            }]
        })

        var result = this.ExecuteCurl(url, 'POST', payload)
        return this.ExtractResult(result)
    enddef

    def GenerateChat(messages: list<dict<string>>, chat_id: string): dict<any>
        if !this.IsValid()
            return {ok: false, error: this.GetAPIKeyError()}
        endif

        var resolved = this.ResolveModelAndVersion(chat_id)

        # Gemini calls the model's own turns 'model', not 'assistant'.
        var contents = []
        for m in messages
            add(contents, {
                role: (m.role == 'assistant' ? 'model' : 'user'),
                parts: [{text: m.text}]
            })
        endfor

        var url = this.BuildURL($'models/{resolved.model}:generateContent', resolved.api_version)
        var payload = json_encode({contents: contents})

        var result = this.ExecuteCurl(url, 'POST', payload)
        return this.ExtractResult(result)
    enddef

    # Shared response handling for GenerateContent and GenerateChat.
    # Returns dict<any> - see provider.vim for the return value convention.
    # Gemini does not expose a stop_reason equivalent in the same way
    # Claude does; truncation is indicated by finishReason == 'MAX_TOKENS'.
    def ExtractResult(result: dict<any>): dict<any>
        if has_key(result, 'error')
            return {ok: false, error: $"Error: {result.error}"}
        endif

        var json_response = result.data

        if has_key(json_response, 'error')
            return {ok: false, error: $"API Error: {json_response.error.message}"}
        endif

        if has_key(json_response, 'candidates') && !empty(json_response.candidates)
            var candidate = json_response.candidates[0]
            if has_key(candidate, 'content') && has_key(candidate.content, 'parts')
                var parts = candidate.content.parts
                if !empty(parts) && has_key(parts[0], 'text')
                    var text = parts[0].text
                    var finish_reason = get(candidate, 'finishReason', '')
                    if finish_reason == 'MAX_TOKENS'
                        return {ok: true, text: text, truncated: true}
                    endif
                    return {ok: true, text: text}
                endif
            endif
        endif

        return {ok: false, error: "Error: Received an empty or malformed response from the API."}
    enddef
endclass
