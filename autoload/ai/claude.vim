"use vim9 script only:
vim9script

# autoload/ai/claude.vim
# Claude Provider Implementation
#
# Self-contained: to work on Claude-specific behavior you only need this
# file plus config.vim (for the AIConfig type), provider.vim (for the
# interface it implements) and util.vim (for RedactSecret). None of the
# Gemini/OpenAI provider code is needed.

import './config.vim' as Cfg
import './provider.vim' as Provider
import './util.vim' as Util

export class ClaudeProvider extends Provider.AIProvider
    def new(config: Cfg.AIConfig)
        this.config = config
    enddef

    def IsValid(): bool
        return !empty(this.config.claude_api_key)
    enddef

    def GetAPIKeyError(): string
        return "Error: ANTHROPIC_API_KEY environment variable not set."
    enddef

    def GetCurrentModel(): string
        return this.config.claude_model
    enddef

    def SetModel(model: string)
        this.config.claude_model = model
        g:claude_model = model
    enddef

    def RefreshDefaults()
        if empty(this.config.claude_model)
            this.config.claude_model = get(g:, 'claude_model', Cfg.PROVIDER_MODEL_DEFAULTS.claude)
        endif
        this.config.claude_api_key = $ANTHROPIC_API_KEY
    enddef

    def GetStatusLines(): list<string>
        return [
            $'  Model: {this.config.claude_model}',
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

    def ExecuteCurl(url: string, method: string = 'POST', payload: string = ''): dict<any>
        var curl_cmd = 'curl -s -X ' .. method
                    .. ' -H "Content-Type: application/json"'
                    .. ' -H "x-api-key: ' .. this.config.claude_api_key .. '"'
                    .. ' -H "anthropic-version: ' .. this.config.claude_api_version .. '"'

        if method == 'POST' && !empty(payload)
            curl_cmd ..= ' -d ' .. shellescape(payload)
        endif

        curl_cmd ..= ' ' .. shellescape(url)

        if this.config.debug
            echom '[AI debug] ' .. Util.RedactSecret(curl_cmd, this.config.claude_api_key)
        endif

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

        # Claude doesn't have a public models endpoint, so we return a hardcoded list
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

    def GenerateContent(prompt: string): string
        if !this.IsValid()
            return this.GetAPIKeyError()
        endif

        var url = 'https://api.anthropic.com/v1/messages'
        var payload = json_encode({
            model: this.config.claude_model,
            max_tokens: 4096,
            messages: [{
                role: 'user',
                content: prompt
            }]
        })

        var result = this.ExecuteCurl(url, 'POST', payload)
        return this.ExtractResult(result)
    enddef

    def GenerateChat(messages: list<dict<string>>): string
        if !this.IsValid()
            return this.GetAPIKeyError()
        endif

        # Claude already uses 'user'/'assistant', so this is a direct map.
        var api_messages = []
        for m in messages
            add(api_messages, {role: m.role, content: m.text})
        endfor

        var url = 'https://api.anthropic.com/v1/messages'
        var payload = json_encode({
            model: this.config.claude_model,
            max_tokens: 4096,
            messages: api_messages
        })

        var result = this.ExecuteCurl(url, 'POST', payload)
        return this.ExtractResult(result)
    enddef

    # Shared response handling for GenerateContent and GenerateChat.
    def ExtractResult(result: dict<any>): string
        if has_key(result, 'error')
            return $"Error: {result.error}"
        endif

        var json_response = result.data

        if has_key(json_response, 'error')
            var error_type = get(json_response.error, 'type', 'unknown')
            var error_msg = get(json_response.error, 'message', 'Unknown error')
            return $"API Error ({error_type}): {error_msg}"
        endif

        if has_key(json_response, 'content') && !empty(json_response.content)
            var content = json_response.content[0]
            if has_key(content, 'text')
                return content.text
            endif
        endif

        return "Error: Received an empty or malformed response from the API."
    enddef
endclass
