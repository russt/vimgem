"use vim9 script only:
vim9script

# autoload/ai/core.vim
# AIPlugin - the top-level orchestrator.
#
# Owns: one AIConfig, one AIBuffer, one AIPrompt, and a dict of all
# AIProvider instances (one per supported provider, all created at
# startup). Commands in plugin/ai.vim delegate directly to methods here;
# this file never calls back into ai.vim.
#
# Design notes:
#   - GetCurrentProvider() returns the globally-active provider for
#     non-chat commands (:AIQuery, :AIExplain, etc.). Chat commands
#     resolve their provider from the ChatSessionInfo registry instead,
#     via this.config.GetChatSessionForCurrentBuffer().
#   - Per-chat provider/model/api_version are snapshotted into
#     ChatSessionInfo at Chat()/ChatResume() time. Global :AIProvider
#     and :AIModel changes do not affect in-flight chats unless the user
#     runs those commands from within a chat buffer, in which case both
#     the global default AND the current chat's snapshot are updated.
#   - Providers never write to AIConfig. Model/provider selection is
#     exclusively a core.vim + config.vim concern.
#   - Providers return dict<any> from GenerateContent/GenerateChat with
#     keys {ok, text, error, truncated} - core.vim inspects these keys
#     only, never the text content, to detect errors or truncation.
#   - The .buffer and .config members are intentionally public so ai.vim
#     can wire up the BufReadPost and BufWipeout autocmds without needing
#     dedicated accessor methods.
#   - Error handling follows the Vim convention: echoerr for unexpected
#     failures the user needs to know about; plain echo for soft "nothing
#     to do" feedback; try/catch around every external API call since
#     GenerateContent/GenerateChat can throw on unexpected response shapes.

import './config.vim' as Cfg
import './provider.vim' as Provider
import './gemini.vim' as Gemini
import './claude.vim' as Claude
import './openai.vim' as OpenAI
import './buffer.vim' as Buf
import './prompt.vim' as Prm
import './util.vim' as Util

export class AIPlugin
    var config: Cfg.AIConfig
    var providers: dict<Provider.AIProvider>
    var buffer: Buf.AIBuffer
    var prompt: Prm.AIPrompt

    # Initialize all subsystems once at plugin load time. Every provider
    # is instantiated eagerly (not lazily) so a missing import or class
    # error surfaces immediately at startup rather than the first time a
    # user tries to switch providers.
    def new()
        this.config = Cfg.AIConfig.new()
        this.providers = {}
        this.providers.gemini = Gemini.GeminiProvider.new(this.config)
        this.providers.claude = Claude.ClaudeProvider.new(this.config)
        this.providers.openai = OpenAI.OpenAIProvider.new(this.config)
        this.buffer = Buf.AIBuffer.new(this.config)
        this.prompt = Prm.AIPrompt.new()
    enddef

    # Returns the globally-active provider. Used only by non-chat
    # commands (:AIQuery, :AIExplain, :AIReview, :AIReviewFile,
    # :AIModels, :AIInfo). Chat commands resolve their provider from the
    # ChatSessionInfo registry to avoid being affected by global changes.
    def GetCurrentProvider(): Provider.AIProvider
        return this.providers[this.config.provider]
    enddef

    # Returns the provider for a specific chat session. Errors (returns
    # the global provider as a safe fallback) if the session is not found
    # or the session's provider name is not registered.
    def GetChatSessionProvider(chat_id: string): Provider.AIProvider
        var provider_name = this.config.GetChatSessionProvider(chat_id)
        if empty(provider_name) || !has_key(this.providers, provider_name)
            echoerr $"GetChatSessionProvider: no registered session for chat '{chat_id}', using global provider."
            return this.GetCurrentProvider()
        endif
        return this.providers[provider_name]
    enddef

    # Switch the active global provider. If called from within a chat
    # buffer, also updates that chat's session snapshot and sets the
    # per-chat model to the new provider's default (since the previous
    # model name almost certainly does not apply to a different provider).
    # Emits a message that distinguishes the two cases so the user knows
    # what changed.
    def SetProvider(provider_name: string)
        if !this.config.SetProvider(provider_name)
            var valid = keys(this.providers)
            echoerr $"Invalid provider. Choose from: {join(valid, ', ')}"
            return
        endif

        var new_provider = this.providers[provider_name]
        var default_model = new_provider.GetDefaultModel()
        var session = this.config.GetChatSessionForCurrentBuffer()

        if !empty(session)
            # Called from a chat buffer: update the session snapshot too.
            var chat_id = session.chat_id
            var api_version = this.config.ApiVersionForProvider(provider_name)
            this.config.UpdateChatSessionProvider(chat_id, provider_name)
            this.config.UpdateChatSessionModel(chat_id, default_model)
            this.config.UpdateChatSessionApiVersion(chat_id, api_version)
            echo $"Provider is now '{provider_name}' for new chats, and for the current chat, model is '{default_model}'. Use :AIModel to change."
        else
            echo $"AI provider set to: {provider_name}"
        endif
    enddef

    # One-shot prompt -> response. The provider is echoed before the
    # (potentially slow) API call so the user gets immediate feedback
    # that something is happening. The response is shown in a new scratch
    # buffer via AIBuffer.DisplayResponse. chat_id is '' for all
    # one-shot commands; providers fall back to global config model.
    def Query(command_name: string, user_prompt: string)
        if empty(user_prompt)
            echo command_name .. ": Please provide a prompt."
            return
        endif

        var provider = this.GetCurrentProvider()
        echo $"Querying {this.config.provider}..."

        try
            var result = provider.GenerateContent(user_prompt, '')
            if !result.ok
                echoerr $"Error calling AI API: {result.error}"
                return
            endif
            if get(result, 'truncated', false)
                echohl WarningMsg
                echo "Warning: response was truncated before completion."
                echohl None
            endif
            this.buffer.DisplayResponse(user_prompt, result.text, provider.GetDefaultModel())
            echo "AI response received."
        catch
            echoerr "Error calling AI API: " .. v:exception
        endtry
    enddef

    # :AIChat - open a fresh chat buffer backed by a real file under
    # g:vimgem_chat_home. The buffer is not a throwaway nofile scratch -
    # it persists across window changes (bufhidden=hide) and autosaves
    # on every turn. Registers the new session in the ChatSessionInfo
    # registry, snapshotting the current global provider/model/api_version
    # so future global changes do not affect this chat.
    def Chat()
        var provider = this.GetCurrentProvider()
        var provider_name = this.config.provider
        var model = provider.GetDefaultModel()
        var api_version = this.config.ApiVersionForProvider(provider_name)

        var chat_id = this.buffer.CreateChat(provider_name, model)
        var bufnr = bufnr('%')
        this.config.RegisterChatSession(chat_id, bufnr, provider_name, model, api_version)

        echo $"AI Chat buffer created with provider '{provider_name}', model '{model}'. Type under '## You', then :AIChatSend."
    enddef

    # :AIChatSend - the core chat-send logic:
    #   1. Confirm we are in a registered chat buffer.
    #   2. Locate the new question text (since the last '## You' marker).
    #   3. Expand any {=...=} references in it.
    #   4. Strip any {=>...=} write-target directive, appending the
    #      appropriate instruction to the prompt if present.
    #   5. Resolve provider and model from the ChatSessionInfo registry
    #      (never from global config) so in-flight chats are immune to
    #      global :AIProvider / :AIModel changes.
    #   6. Send the full history + new turn to the provider.
    #   7. Inspect result.ok and result.truncated - never grep result.text.
    #   8. Route the response to a write-target buffer/file if requested,
    #      otherwise show it inline in the chat transcript.
    def ChatSend(end_line: number)
        if !exists('b:ai_chat')
            echoerr "AIChatSend: not in an AI Chat buffer. Start one with :AIChat, or reopen a saved one with :AIChatResume."
            return
        endif

        var chat_id = b:ai_chat_id
        var session = this.config.GetChatSession(chat_id)
        if empty(session)
            echoerr $"AIChatSend: no registered session for chat '{chat_id}'. The chat may have been reopened without :AIChatResume."
            return
        endif

        var raw_prompt = this.buffer.GetNewPromptText(end_line)
        if empty(raw_prompt)
            echo "AIChatSend: no new question found under '## You'."
            return
        endif

        var write_info = this.prompt.ExtractWriteTarget(raw_prompt)
        var expanded_prompt = this.prompt.ExpandReferences(write_info.stripped)
        if this.prompt.had_error
            echoerr $"AIChatSend: {this.prompt.last_error}"
            return
        endif

        # history_prompt keeps the user-visible text (no injected
        # instructions); the instructions are appended only to
        # expanded_prompt, which IS sent to the API. This means the JSON
        # history doesn't accumulate boilerplate "respond with only the
        # code" instructions across turns, keeping the context cleaner.
        var history_prompt = expanded_prompt

        if write_info.wildcard
            expanded_prompt ..= "\n\nRespond with only the resulting code, one fenced code block per file needed, with no other commentary."
        elseif !empty(write_info.target)
            expanded_prompt ..= "\n\nRespond with only the resulting code, in a single fenced code block, with no explanation."
        endif

        var history = this.buffer.LoadHistory(chat_id)

        # Resolve provider from the session registry - never from global config.
        var provider = this.GetChatSessionProvider(chat_id)
        var provider_name = this.config.GetChatSessionProvider(chat_id)
        var model = this.config.GetChatSessionModel(chat_id)

        echo $"Querying {provider_name} ({model})..."

        # first_win captures the first review tab opened by
        # WriteResponseToWildcard (if any) so we can jump there after
        # finishing all chat-buffer housekeeping.
        var wildcard_first_win = -1
        var sent_at = this.buffer.NowStamp()

        try
            var result = provider.GenerateChat(
                history + [{role: 'user', text: expanded_prompt}],
                chat_id
            )

            # Inspect result.ok and result.truncated only - never grep
            # result.text for signals. Source code, markdown, anything
            # can appear in result.text without triggering false positives.
            if !result.ok
                this.buffer.AppendChatTurn(result.error, model, sent_at)
                echohl WarningMsg
                echo "AI API returned an error (not saved to chat history)."
                echohl None
                return
            endif

            if get(result, 'truncated', false)
                # Truncated: show partial text in chat but do not write
                # to filesystem targets and do not save to JSON history,
                # since partial content is not reliable context.
                var trunc_msg = $"[Warning: Response was truncated before completion - output not written.]"
                if write_info.wildcard || !empty(write_info.target)
                    trunc_msg = $"[Warning: Response was truncated before completion - output not written. Increase max_tokens or reduce file size.]"
                endif
                this.buffer.AppendChatTurn(trunc_msg, model, sent_at)
                echo "AI response truncated."
                return
            endif

            this.buffer.AppendHistoryTurn(chat_id, history_prompt, result.text)

            var display = result.text
            if write_info.wildcard
                var blocks = this.prompt.ExtractIdentifiedBlocks(result.text)
                var write_result = this.buffer.WriteResponseToWildcard(blocks, write_info.output_dir)
                display = write_result.ok ? $'-> {write_result.summary}' : $'-> Error: {write_result.error}'
                if write_result.ok
                    wildcard_first_win = write_result.first_win
                endif
            elseif !empty(write_info.target)
                var code = this.prompt.ExtractCodeBlock(result.text)
                var write_result = this.buffer.WriteResponseToTarget(write_info.target, code)
                display = write_result.ok ? $'-> {write_result.summary}' : $'-> Error: {write_result.error}'
            endif

            this.buffer.AppendChatTurn(display, model, sent_at)
            echo "AI response received."

            if wildcard_first_win != -1
                win_gotoid(wildcard_first_win)
            endif
        catch
            echoerr "Error calling AI API: " .. v:exception
        endtry
    enddef

    # :AIChatDisplay - render the session's .md transcript to HTML and
    # open it in the OS default browser. Must be called from a chat
    # buffer or from a history list line with a valid session id.
    # Deliberately does NOT fall back to any arbitrary loaded buffer or
    # most-recent session on disk, which could belong to a different
    # Vim process.
    def ChatDisplay(lnum: number)
        var target = this.buffer.ChatIdFromHistoryLine(getline(lnum))
        if empty(target)
            # Only accept b:ai_chat_id from a registered session buffer.
            var session = this.config.GetChatSessionForCurrentBuffer()
            if !empty(session)
                target = session.chat_id
            endif
        endif
        if empty(target)
            echoerr "AIChatDisplay: run this command from a chat buffer or a chat history line."
            return
        endif

        var result = this.buffer.OpenHtmlInBrowser(target)
        if !result.ok
            echoerr $"AIChatDisplay: {result.error}"
            return
        endif
        echo $"Opened chat '{target}' in browser."
    enddef

    def ChatClear()
        if !exists('b:ai_chat')
            echoerr "AIChatClear: not in an AI Chat buffer."
            return
        endif
        this.buffer.ClearHistory(b:ai_chat_id)
        echo "AI Chat history cleared for this session."
    enddef

    def ChatHistory()
        var sessions = this.buffer.ListSessions()
        if empty(sessions)
            echo "No saved AI chats found."
            return
        endif
        this.buffer.DisplayChatHistory(sessions)
        echo "AI Chat sessions listed."
    enddef

    # :AIChatResume - if the cursor line carries a valid session id (from
    # :AIChatHistory), that session is resumed; otherwise the most
    # recently modified session is used as a fallback. Registers the
    # resumed session in the ChatSessionInfo registry, snapshotting the
    # current global provider/model/api_version.
    def ChatResume(lnum: number)
        var target = this.buffer.ChatIdFromHistoryLine(getline(lnum))
        var resolved = this.buffer.ResumeChat(target)
        if empty(resolved)
            echoerr "AIChatResume: could not find session."
            return
        endif

        var provider_name = this.config.provider
        var provider = this.GetCurrentProvider()
        var model = provider.GetDefaultModel()
        var api_version = this.config.ApiVersionForProvider(provider_name)
        var bufnr = bufnr('%')

        this.config.RegisterChatSession(resolved, bufnr, provider_name, model, api_version)

        echo $"Resuming chat '{resolved}' with provider '{provider_name}', model '{model}'."
    enddef

    def ChatDelete(lnum: number)
        var target = this.buffer.ChatIdFromHistoryLine(getline(lnum))
        if empty(target)
            echoerr "AIChatDelete: current line isn't a saved chat session."
            return
        endif
        if !this.buffer.DeleteChat(target)
            echoerr $"AIChatDelete: could not delete chat '{target}'."
            return
        endif
        this.buffer.RefreshChatHistory(this.buffer.ListSessions())
        echo $"Deleted AI Chat '{target}'."
    enddef

    # :AIAsk - send visually selected text (or a range) as a raw prompt,
    # after expanding any {=...=} references it contains.
    def Ask(lines: list<string>)
        if empty(lines)
            echo "AIAsk: Please make a visual selection or provide a range."
            return
        endif
        var user_prompt = join(lines, "\n")
        var expanded_prompt = this.prompt.ExpandReferences(user_prompt)
        if this.prompt.had_error
            echoerr $"AIAsk: {this.prompt.last_error}"
            return
        endif
        this.Query('AIAsk', expanded_prompt)
    enddef

    # :AIExplain - wrap the selection in a canned "explain this code"
    # prompt. Refuses to run in nofile buffers (the plugin's own output
    # windows) since they have no meaningful filetype/filename context.
    def Explain(lines: list<string>)
        if &buftype == 'nofile'
            echoerr "AIExplain cannot be run in this buffer."
            return
        endif
        var selection = join(lines, "\n")
        var user_prompt = this.prompt.BuildExplainPrompt(selection, &filetype, expand('%:t'))
        this.Query('AIExplain', user_prompt)
    enddef

    # :AIReview - same guard as Explain; wraps selection in a canned
    # "review this code strictly on what's provided" prompt.
    def Review(lines: list<string>)
        if &buftype == 'nofile'
            echoerr "AIReview cannot be run in this buffer."
            return
        endif
        var selection = join(lines, "\n")
        var user_prompt = this.prompt.BuildReviewPrompt(selection, &filetype, expand('%:t'))
        this.Query('AIReview', user_prompt)
    enddef

    def ReviewFile()
        if &buftype == 'nofile'
            echoerr "AIReviewFile cannot be run in this buffer."
            return
        endif
        var file_content = getline(1, '$')
        var file_text = join(file_content, "\n")
        var user_prompt = this.prompt.BuildReviewPrompt(file_text, &filetype, expand('%:t'))
        this.Query('AIReviewFile', user_prompt)
    enddef

    def ShowModels()
        var provider = this.GetCurrentProvider()
        echo $"Fetching available models for {this.config.provider}..."

        try
            var response = provider.ListModels()
            var lines = [$'# {toupper(this.config.provider)} Models', '', ''] + split(response, '\n')
            add(lines, '')
            add(lines, 'Put the cursor on a model line and run :AIModel to switch to it.')
            this.buffer.DisplayText(lines)
            echo "Model list retrieved."
        catch
            echoerr "Error fetching models: " .. v:exception
        endtry
    enddef

    # :DBGShowLog - display the debug message log for the current Vim
    # session in a named scratch buffer ('message_log.txt'). The log is
    # written by Util.DBG() to a per-session file under the vimgem log
    # directory (named debug_<pid>.log). The file is initialized at
    # startup by util.vim even when all debug levels are off, so it
    # should always exist. If it is somehow missing, a soft echo message
    # is shown rather than an error.
    def ShowLog()
        var logpath = Util.GetMessageLogPath()
        if !filereadable(logpath)
            echo $"DBGShowLog: log file not found: {logpath}"
            return
        endif
        var lines = readfile(logpath)
        this.buffer.DisplayText(lines, 'text', 'message_log.txt')
    enddef

    # :DBGShowJson - display a human-readable rendering of the JSON chat
    # history for the current chat session. Must be called from a
    # registered chat buffer. Deliberately does NOT fall back to any
    # arbitrary loaded buffer or most-recent session on disk.
    # Requires jq to be installed.
    def ShowJsonHistory()
        if !executable('jq')
            echo "DBGShowJson: 'jq' is not installed or not on PATH. Install jq to use this command."
            return
        endif

        # Only accept a session that is registered in the ChatSessionInfo
        # registry - not just any buffer with b:ai_chat_id set.
        var session = this.config.GetChatSessionForCurrentBuffer()
        if empty(session)
            echoerr "DBGShowJson: run this command from an active chat buffer (opened via :AIChat or :AIChatResume)."
            return
        endif

        var chat_id = session.chat_id
        var lines = this.buffer.ShowJsonHistory(chat_id)
        if empty(lines)
            echo $"DBGShowJson: no history found for chat '{chat_id}'."
            return
        endif

        this.buffer.DisplayText(lines, 'text', 'json_readable.txt')
        echo $"DBGShowJson: showing JSON history for chat '{chat_id}'."
    enddef

    # :AIPrompt [on|off] - toggle or explicitly set whether query
    # responses include the original prompt and a provider/model header.
    def SetShowPrompt(arg: string)
        if arg == 'on'
            this.config.show_prompt = true
        elseif arg == 'off'
            this.config.show_prompt = false
        elseif empty(arg)
            this.config.show_prompt = !this.config.show_prompt
        else
            echoerr "AIPrompt: expected 'on', 'off', or no argument to toggle."
            return
        endif
        g:show_prompt = this.config.show_prompt ? 1 : 0
        echo $"Show prompt: {this.config.show_prompt ? 'On' : 'Off'}"
    enddef

    # :AIReviewReceived [on|off] - unlike :AIPrompt, no-argument reports
    # rather than toggles, because this flag gates file writes and
    # silently toggling it off could cause unexpected disk modifications.
    def SetReviewReceived(arg: string)
        if arg == 'on'
            this.config.always_review_received_files = true
        elseif arg == 'off'
            this.config.always_review_received_files = false
        elseif empty(arg)
            echo $"Always review received files: {this.config.always_review_received_files ? 'On' : 'Off'}"
            return
        else
            echoerr "AIReviewReceived: expected 'on' or 'off'."
            return
        endif
        g:always_review_received_files = this.config.always_review_received_files ? 1 : 0
        echo $"Always review received files: {this.config.always_review_received_files ? 'On' : 'Off'}"
    enddef

    # :AIUrl [url] - get or set the openai provider's base URL at runtime.
    # Only applies to the openai provider; errors if another is active so
    # accidental use with gemini/claude doesn't silently set a field that
    # has no effect on the current provider.
    def SetBaseUrl(arg: string)
        if this.config.provider != 'openai'
            echoerr $"AIUrl only applies to the openai provider."
            return
        endif
        if empty(arg)
            echo "Current openai_base_url: " .. this.config.openai_base_url
            return
        endif
        this.config.openai_base_url = arg
        g:openai_base_url = arg
        echo "OpenAI base URL set to: " .. arg
    enddef

    # :AISet [key] [value] - generic get/set for any AIConfig field.
    # No args  -> list all valid keys.
    # key only -> show current value of that key.
    # key+val  -> set it globally (mirror to g:), and if called from a
    #             chat buffer, also update the session snapshot for
    #             model/api_version fields that have per-chat meaning.
    def SetConfig(key: string = '', value: string = '')
        if empty(key)
            echo join(Cfg.AIConfig.CONFIGURABLE_KEYS, "\n")
            return
        endif
        if empty(value)
            echo $'{key} = {this.config.Get(key)}'
            return
        endif
        if !this.config.Set(key, value)
            return
        endif
        echo $'{key} set to: {value}'

        # If called from a chat buffer, mirror model/api_version changes
        # into the session snapshot so the current chat is also affected.
        var session = this.config.GetChatSessionForCurrentBuffer()
        if empty(session)
            return
        endif
        var chat_id = session.chat_id
        if key == 'gemini_model' || key == 'claude_model' || key == 'openai_model'
            this.config.UpdateChatSessionModel(chat_id, value)
        elseif key == 'gemini_api_version' || key == 'claude_api_version'
            this.config.UpdateChatSessionApiVersion(chat_id, value)
        endif
    enddef

    # :AIInfo - assemble and display the full status page: config header,
    # active provider's current settings, all commands, and .vimrc examples.
    def ShowInfo()
        var provider = this.GetCurrentProvider()
        var lines = this.config.GetHeaderLines()
            + ['', $'## {toupper(this.config.provider)} Configuration']
            + provider.GetStatusLines()
            + ['']
            + this.config.GetCommandsAndVarsLines()
            + ['', $'  # {toupper(this.config.provider)} settings']
            + provider.GetConfigLines()

        # Find the header index matching '## ... Configuration' and insert version string
        var insert_idx = -1
        for idx in range(len(lines))
            if lines[idx] =~? '^##.*Configuration'
                insert_idx = idx
                break
            endif
        endfor

        if insert_idx != -1
            insert(lines, $'  vimgem version: {g:vimgem_version}', insert_idx + 1)
        endif

        this.buffer.DisplayText(lines)
        echo "Plugin info displayed."
    enddef

    # :AIModel [name] - set the active provider's default model globally.
    # With no name: if the cursor is on a model line from :AIModels,
    # switch to that model; otherwise just report the current default.
    # With a name: set it directly, regardless of cursor position.
    # If called from a chat buffer, also updates that chat's session
    # snapshot so the change takes effect immediately for the current chat.
    def SetModel(model: string, lnum: number)
        var provider = this.GetCurrentProvider()
        var target = model
        if empty(target)
            target = this.buffer.ModelNameFromModelsLine(getline(lnum))
        endif
        if empty(target)
            echo "Current default model: " .. provider.GetDefaultModel()
            return
        endif

        # Update the global config default for the current provider.
        var model_key = this.config.provider .. '_model'
        this.config.Set(model_key, target)

        # If called from a chat buffer, also update that chat's snapshot.
        var session = this.config.GetChatSessionForCurrentBuffer()
        if !empty(session)
            this.config.UpdateChatSessionModel(session.chat_id, target)
            echo $"Model set to '{target}' (global default and current chat)."
        else
            echo $"Model set to '{target}' (global default for new chats)."
        endif
    enddef
endclass
