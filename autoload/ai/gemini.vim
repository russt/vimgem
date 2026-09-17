"use vim9 script only:
vim9script

# autoload/ai/gemini.vim
# Gemini Provider Implementation
#
# Self-contained: to work on Gemini-specific behavior you only need this
# file plus config.vim (for the AIConfig type), provider.vim (for the
# interface it implements) and util.vim (for RedactSecret). None of the
# Claude/OpenAI provider code is needed.

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

    def GetCurrentModel(): string
        return this.config.gemini_model
    enddef

    def SetModel(model: string)
        this.config.gemini_model = model
        g:gemini_model = model
    enddef

    def RefreshDefaults()
        if empty(this.config.gemini_model)
            this.config.gemini_model = get(g:, 'gemini_model', Cfg.PROVIDER_MODEL_DEFAULTS.gemini)
        endif
        this.config.gemini_api_key = $GOOGLE_API_KEY
    enddef

    def GetStatusLines(): list<string>
        return [
            $'  Model: {this.config.gemini_model}',
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

    def BuildURL(endpoint: string): string
        return $'https://generativelanguage.googleapis.com/{this.config.gemini_api_version}/{endpoint}?key={this.config.gemini_api_key}'
    enddef

    def ExecuteCurl(url: string, method: string = 'GET', payload: string = ''): dict<any>
        var curl_cmd: string

        if method == 'POST'
            curl_cmd = 'curl -s -X POST -H "Content-Type: application/json" -d '
                        .. shellescape(payload) .. ' ' .. shellescape(url)
        else
            curl_cmd = 'curl -s -X GET ' .. shellescape(url)
        endif

        if this.config.debug
            echom '[AI debug] ' .. Util.RedactSecret(curl_cmd, this.config.gemini_api_key)
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

    def GenerateContent(prompt: string): string
        if !this.IsValid()
            return this.GetAPIKeyError()
        endif

        var url = this.BuildURL($'models/{this.config.gemini_model}:generateContent')
        var payload = json_encode({
            contents: [{
                parts: [{text: prompt}]
            }]
        })

        var result = this.ExecuteCurl(url, 'POST', payload)
        return this.ExtractResult(result)
    enddef

    def GenerateChat(messages: list<dict<string>>): string
        if !this.IsValid()
            return this.GetAPIKeyError()
        endif

        # Gemini calls the model's own turns 'model', not 'assistant'.
        var contents = []
        for m in messages
            add(contents, {
                role: (m.role == 'assistant' ? 'model' : 'user'),
                parts: [{text: m.text}]
            })
        endfor

        var url = this.BuildURL($'models/{this.config.gemini_model}:generateContent')
        var payload = json_encode({contents: contents})

        var result = this.ExecuteCurl(url, 'POST', payload)
        return this.ExtractResult(result)
    enddef

    # Shared response handling for GenerateContent and GenerateChat -
    # both hit the same endpoint shape, only the request payload differs.
    def ExtractResult(result: dict<any>): string
        if has_key(result, 'error')
            return $"Error: {result.error}"
        endif

        var json_response = result.data

        if has_key(json_response, 'error')
            return $"API Error: {json_response.error.message}"
        endif

        if has_key(json_response, 'candidates') && !empty(json_response.candidates)
            var candidate = json_response.candidates[0]
            if has_key(candidate, 'content') && has_key(candidate.content, 'parts')
                var parts = candidate.content.parts
                if !empty(parts) && has_key(parts[0], 'text')
                    return parts[0].text
                endif
            endif
        endif

        return "Error: Received an empty or malformed response from the API."
    enddef
endclass
