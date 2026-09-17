"use vim9 script only:
vim9script

# autoload/ai/openai.vim
# OpenAI-compatible Provider Implementation
# Works with any server exposing the /v1/chat/completions endpoint:
# local (mlx_lm.server, Ollama, LM Studio, vLLM, ...) or remote (api.openai.com)
#
# Self-contained: to work on OpenAI-compatible behavior you only need this
# file plus config.vim (for the AIConfig type), provider.vim (for the
# interface it implements) and util.vim (for RedactSecret/StripChatArtifacts).
# None of the Gemini/Claude provider code is needed.

import './config.vim' as Cfg
import './provider.vim' as Provider
import './util.vim' as Util

export class OpenAIProvider extends Provider.AIProvider
    def new(config: Cfg.AIConfig)
        this.config = config
    enddef

    def IsValid(): bool
        # A base_url is required; an API key is not (most local servers
        # ignore auth entirely), so we don't check for one here.
        # A model doesn't need to be USER-set: when empty, the "model"
        # field is omitted from the request entirely (see GenerateContent),
        # which matches the official mlx_lm.server's own example requests
        # and works fine for most single-model local servers. Only
        # multi-model servers (Ollama, vLLM, api.openai.com) need the real
        # name, via g:openai_model / :AISetModel.
        return !empty(this.config.openai_base_url)
    enddef

    def GetAPIKeyError(): string
        return "Error: g:openai_base_url is not set."
    enddef

    def GetCurrentModel(): string
        return this.config.openai_model
    enddef

    def SetModel(model: string)
        this.config.openai_model = model
        g:openai_model = model
    enddef

    def RefreshDefaults()
        if empty(this.config.openai_model)
            this.config.openai_model = get(g:, 'openai_model', Cfg.PROVIDER_MODEL_DEFAULTS.openai)
        endif
        this.config.openai_api_key = get(g:, 'openai_api_key', $OPENAI_API_KEY)
    enddef

    def GetStatusLines(): list<string>
        return [
            $'  Base URL: {this.config.openai_base_url}',
            $'  Model: {empty(this.config.openai_model) ? "(not set - no model field sent; server uses whatever it was launched with)" : this.config.openai_model}',
            $'  API Key: {!empty(this.config.openai_api_key) ? "Set" : "Not set (ok for most local servers)"}',
        ]
    enddef

    def GetConfigLines(): list<string>
        return [
            '  let g:openai_base_url = "http://localhost:9090"  # or "https://api.openai.com"',
            '  let g:openai_model = "mlx-community/Mistral-7B-Instruct-v0.3-4bit"  # only needed for multi-model servers (Ollama, vLLM, api.openai.com) - leave unset for single-model servers',
            '  let g:openai_api_key = ""  # optional, most local servers ignore it',
        ]
    enddef

    def IsRecognizedModel(model: string): bool
        # No fixed naming convention for local/OpenAI-compatible models,
        # so never claim ownership - avoids false-positive mismatch warnings.
        return false
    enddef

    def BuildURL(endpoint: string): string
        return $'{this.config.openai_base_url}/v1/{endpoint}'
    enddef

    def ExecuteCurl(url: string, method: string = 'POST', payload: string = ''): dict<any>
        var curl_cmd = 'curl -s -X ' .. method
                    .. ' -H "Content-Type: application/json"'

        if !empty(this.config.openai_api_key)
            curl_cmd ..= ' -H "Authorization: Bearer ' .. this.config.openai_api_key .. '"'
        endif

        if method == 'POST' && !empty(payload)
            curl_cmd ..= ' -d ' .. shellescape(payload)
        endif

        curl_cmd ..= ' ' .. shellescape(url)

        if this.config.debug
            echom '[AI debug] ' .. Util.RedactSecret(curl_cmd, this.config.openai_api_key)
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

        var url = this.BuildURL('models')
        var result = this.ExecuteCurl(url, 'GET')

        if has_key(result, 'error')
            return $"Error: {result.error}"
        endif

        var json_response = result.data

        if has_key(json_response, 'error')
            return $"API Error: {json_response.error.message}"
        endif

        if !has_key(json_response, 'data') || empty(json_response.data)
            return "Error: No models found in API response."
        endif

        var model_list = []
        for model in json_response.data
            add(model_list, $"  {model.id}")
        endfor

        var output = $"Models found at {this.config.openai_base_url} (Note: for local servers "
            .. "this often lists your entire model cache/directory, not just "
            .. "the model actually loaded in memory):\n\n"
        output ..= join(model_list, "\n")
        output ..= $"\n\nCurrent g:openai_model: {empty(this.config.openai_model) ? '(not set - see :AIInfo)' : this.config.openai_model}"
        return output
    enddef

    def GenerateContent(prompt: string): string
        if !this.IsValid()
            return this.GetAPIKeyError()
        endif

        var payload_dict: dict<any> = {
            messages: [{
                role: 'user',
                content: prompt
            }]
        }
        var result = this.ExecuteChatRequest(payload_dict)
        return this.ExtractResult(result)
    enddef

    def GenerateChat(messages: list<dict<string>>): string
        if !this.IsValid()
            return this.GetAPIKeyError()
        endif

        # OpenAI-compatible APIs already use 'user'/'assistant' directly.
        var api_messages = []
        for m in messages
            add(api_messages, {role: m.role, content: m.text})
        endfor

        var payload_dict: dict<any> = {messages: api_messages}
        var result = this.ExecuteChatRequest(payload_dict)
        return this.ExtractResult(result)
    enddef

    # Shared request path for GenerateContent and GenerateChat - only the
    # "messages" entry differs between them.
    def ExecuteChatRequest(payload_dict: dict<any>): dict<any>
        var url = this.BuildURL('chat/completions')
        var dict_copy = copy(payload_dict)
        # Only include "model" if the user actually set one. Omitting it
        # entirely matches the official mlx_lm.server's own example
        # requests, and avoids servers that try to fetch/load whatever
        # name you give them if it isn't already loaded.
        if !empty(this.config.openai_model)
            dict_copy.model = this.config.openai_model
        endif
        var payload = json_encode(dict_copy)
        return this.ExecuteCurl(url, 'POST', payload)
    enddef

    # Shared response handling for GenerateContent and GenerateChat.
    def ExtractResult(result: dict<any>): string
        if has_key(result, 'error')
            return $"Error: {result.error}"
        endif

        var json_response = result.data

        if has_key(json_response, 'error')
            var error_msg = type(json_response.error) == v:t_dict
                        ? get(json_response.error, 'message', 'Unknown error')
                        : json_response.error
            return $"API Error: {error_msg}"
        endif

        if has_key(json_response, 'choices') && !empty(json_response.choices)
            var choice = json_response.choices[0]
            if has_key(choice, 'message') && has_key(choice.message, 'content')
                return Util.StripChatArtifacts(choice.message.content)
            endif
        endif

        return "Error: Received an empty or malformed response from the API."
    enddef
endclass
