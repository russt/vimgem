"use vim9 script only:
vim9script

# autoload/ai/core.vim
# Main Plugin Class
#
# Thin orchestrator: owns one instance each of AIConfig, every provider,
# AIBuffer, and AIPrompt, and delegates to them. This is the one file
# that DOES need to know about every provider (to build the `providers`
# dict) - individual provider files don't need to know about each other.

import './config.vim' as Cfg
import './provider.vim' as Provider
import './gemini.vim' as Gemini
import './claude.vim' as Claude
import './openai.vim' as OpenAI
import './buffer.vim' as Buf
import './prompt.vim' as Prm

export class AIPlugin
    var config: Cfg.AIConfig
    var providers: dict<Provider.AIProvider>
    var buffer: Buf.AIBuffer
    var prompt: Prm.AIPrompt

    def new()
        this.config = Cfg.AIConfig.new()
        this.providers = {}
        this.providers.gemini = Gemini.GeminiProvider.new(this.config)
        this.providers.claude = Claude.ClaudeProvider.new(this.config)
        this.providers.openai = OpenAI.OpenAIProvider.new(this.config)
        this.buffer = Buf.AIBuffer.new(this.config)
        this.prompt = Prm.AIPrompt.new()
    enddef

    def GetCurrentProvider(): Provider.AIProvider
        return this.providers[this.config.provider]
    enddef

    def SetProvider(provider_name: string)
        if !this.config.SetProvider(provider_name)
            var valid = keys(this.providers)
            echoerr $"Invalid provider. Choose from: {join(valid, ', ')}"
            return
        endif
        # Delegate the "fill in sensible defaults" logic to the provider
        # itself - AIPlugin doesn't need to know each provider's fields.
        this.providers[provider_name].RefreshDefaults()
        echo $"AI provider set to: {provider_name}"
    enddef

    def Query(command_name: string, user_prompt: string)
        if empty(user_prompt)
            echo command_name .. ": Please provide a prompt."
            return
        endif

        var provider = this.GetCurrentProvider()
        echo $"Querying {this.config.provider}..."

        try
            var response = provider.GenerateContent(user_prompt)
            this.buffer.DisplayResponse(user_prompt, response, provider.GetCurrentModel())
            echo "AI response received."
        catch
            echoerr "Error calling AI API: " .. v:exception
        endtry
    enddef

    def Chat()
        var provider = this.GetCurrentProvider()
        this.buffer.CreateChat(this.config.provider, provider.GetCurrentModel())
        echo "AI Chat buffer created. Type under '## You', then :AIChatSend."
    enddef

    # end_line is normally the end of the buffer - AIChatSend is defined
    # with -range=% in plugin/ai.vim, so a plain :AIChatSend with no
    # explicit selection covers everything you've typed. An explicit
    # :'<,'>AIChatSend still works too.
    #
    # Unlike the old design, this does NOT reparse the buffer for
    # context - GetNewPromptText only pulls out this turn's new question
    # (everything since the last '## You'), which gets appended to the
    # persisted JSON history (see AIBuffer.LoadHistory/AppendHistoryTurn)
    # alongside every prior turn from this session.
    def ChatSend(end_line: number)
        if !exists('b:ai_chat')
            echoerr "AIChatSend: not in an AI Chat buffer. Start one with :AIChat, or reopen a saved one with :AIChatResume."
            return
        endif

        var chat_id = b:ai_chat_id
        var raw_prompt = this.buffer.GetNewPromptText(end_line)
        if empty(raw_prompt)
            echo "AIChatSend: no new question found under '## You'."
            return
        endif

        # {=>name=} / {=>*=} route the response to a file/buffer (or, for
        # {=>*=}, a batch of new buffers) instead of displaying it inline
        # - see AIPrompt.ExtractWriteTarget. The directive itself is
        # stripped before the prompt is expanded and sent; the model
        # never sees it.
        var write_info = this.prompt.ExtractWriteTarget(raw_prompt)
        var expanded_prompt = this.prompt.ExpandReferences(write_info.stripped)
        if this.prompt.had_error
            echoerr $"AIChatSend: {this.prompt.last_error}"
            return
        endif

        if write_info.wildcard
            expanded_prompt ..= "\n\nRespond with only the resulting code, one fenced code block per file needed, with no other commentary. For any file you're returning a full replacement version of that was tagged earlier in this conversation with a `[ID: name]` round-trip instruction, begin that file's answer with its exact `[ID: name]` marker on its own line, immediately followed by the fenced code block."
        elseif !empty(write_info.target)
            expanded_prompt ..= "\n\nRespond with only the resulting code, in a single fenced code block, with no explanation."
        endif

        var history = this.buffer.LoadHistory(chat_id)
        var provider = this.GetCurrentProvider()
        echo $"Querying {this.config.provider}..."

        # Set inside the try block below, only for a successful wildcard
        # turn - used after AppendChatTurn to jump the user to the new
        # output tabs, once it's safe to leave the chat buffer (see
        # AIBuffer.WriteResponseToWildcard for why that ordering matters).
        var wildcard_first_win = -1

        # Captured right before the request goes out, so the '## AI'
        # header (written by AppendChatTurn below) records when THIS
        # prompt was actually sent - not when the response happened to
        # come back. See AIBuffer.AppendChatTurn/CreateChat for how
        # this pairs with the '## You' timestamps (session-start /
        # previous-response-received).
        var sent_at = this.buffer.NowStamp()

        try
            var response = provider.GenerateChat(history + [{role: 'user', text: expanded_prompt}])
            # The full expanded prompt and full raw response are always
            # persisted to JSON history, even for write-target turns -
            # only the visible .md log gets the shortened summary below.
            this.buffer.AppendHistoryTurn(chat_id, expanded_prompt, response)

            var display = response
            if write_info.wildcard
                var blocks = this.prompt.ExtractIdentifiedBlocks(response)
                var result = this.buffer.WriteResponseToWildcard(blocks, write_info.output_dir)
                display = result.ok ? $'-> {result.summary}' : $'-> Error: {result.error}'
                if result.ok
                    wildcard_first_win = result.first_win
                endif
            elseif !empty(write_info.target)
                var code = this.prompt.ExtractCodeBlock(response)
                var result = this.buffer.WriteResponseToTarget(write_info.target, code)
                display = result.ok ? $'-> {result.summary}' : $'-> Error: {result.error}'
            endif

            this.buffer.AppendChatTurn(display, provider.GetCurrentModel(), sent_at)
            echo "AI response received."

            # Only jump to the new output tabs now that the chat log
            # buffer has been safely appended to and autosaved above -
            # doing this any earlier is what caused the chat turn to
            # land in the wrong buffer (see WriteResponseToWildcard).
            if wildcard_first_win != -1
                win_gotoid(wildcard_first_win)
            endif
        catch
            echoerr "Error calling AI API: " .. v:exception
        endtry
    enddef

    # Clears the persisted JSON history for the current session only -
    # the visible .md log is untouched, so you can still read or copy
    # from it. Future turns simply stop resending everything before
    # this point.
    # Opens the rendered HTML for a chat session in the OS default
    # browser (see AIBuffer.OpenHtmlInBrowser/_LaunchInBrowser).
    # Resolution order:
    #   1. A session line under the cursor, as listed by
    #      :AIChatHistory - same lookup ChatResume/ChatDelete use.
    #   2. Otherwise, if the current buffer IS a chat, that session -
    #      the "pause mid-chat and look at it" case, so a plain
    #      :AIChatDisplay run from inside the chat you're looking at
    #      does what you'd expect.
    #   3. Otherwise, the most recently modified saved session.
    # AIChatDisplay is defined with -range in plugin/ai.vim, so a plain
    # :AIChatDisplay with no selection passes the current line as lnum.
    def ChatDisplay(lnum: number)
        var target = this.buffer.ChatIdFromHistoryLine(getline(lnum))
        if empty(target) && exists('b:ai_chat_id')
            target = b:ai_chat_id
        endif
        if empty(target)
            var sessions = this.buffer.ListSessions()
            if empty(sessions)
                echoerr "AIChatDisplay: no saved AI chats found."
                return
            endif
            target = sessions[0].id
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
        echo "AI Chat history cleared for this session. The visible transcript is unchanged."
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

    # Resumes the session named on lnum (a session line as written by
    # AIBuffer.DisplayChatHistory, e.g. from the :AIChatHistory listing)
    # if there is one - otherwise falls back to the most recent session.
    # AIChatResume is defined with -range in plugin/ai.vim, so a plain
    # :AIChatResume with no selection passes the current line, which is
    # what makes "put the cursor on a session line and run
    # :AIChatResume" work without needing to know which buffer you're
    # in or type an id.
    def ChatResume(lnum: number)
        var target = this.buffer.ChatIdFromHistoryLine(getline(lnum))

        var resolved = this.buffer.ResumeChat(target)
        if empty(resolved)
            var target_desc = empty(target) ? 'any saved chat' : $"a chat matching '{target}'"
            echoerr $"AIChatResume: could not find {target_desc}. Try :AIChatHistory to list sessions."
            return
        endif
        echo $"Resumed AI Chat '{resolved}'."
    enddef

    # Deletes the session named on lnum. Unlike ChatResume, this has no
    # "most recent" fallback - if the cursor isn't on a valid session
    # line, it errors out rather than guessing, since deleting the wrong
    # chat isn't recoverable.
    def ChatDelete(lnum: number)
        var target = this.buffer.ChatIdFromHistoryLine(getline(lnum))
        if empty(target)
            echoerr "AIChatDelete: the current line isn't a saved chat session. Run this from :AIChatHistory with the cursor on a session line."
            return
        endif

        if !this.buffer.DeleteChat(target)
            echoerr $"AIChatDelete: could not delete chat '{target}'."
            return
        endif

        this.buffer.RefreshChatHistory(this.buffer.ListSessions())
        echo $"Deleted AI Chat '{target}'."
    enddef

    def Ask(lines: list<string>)
        if empty(lines)
            echo "AIAsk: Please make a visual selection or provide a range."
            return
        endif

        var user_prompt = join(lines, "\n")
        if empty(user_prompt)
            echo "AIAsk: Selection is empty."
            return
        endif

        var expanded_prompt = this.prompt.ExpandReferences(user_prompt)
        if this.prompt.had_error
            echoerr $"AIAsk: {this.prompt.last_error}"
            return
        endif
        this.Query('AIAsk', expanded_prompt)
    enddef

    def Explain(lines: list<string>)
        if &buftype == 'nofile'
            echoerr "AIExplain cannot be run in this buffer."
            return
        endif

        var selection = join(lines, "\n")
        if empty(selection)
            echo "AIExplain: Please make a visual selection or provide a range."
            return
        endif

        var user_prompt = this.prompt.BuildExplainPrompt(selection, &filetype, expand('%:t'))
        this.Query('AIExplain', user_prompt)
    enddef

    def Review(lines: list<string>)
        if &buftype == 'nofile'
            echoerr "AIReview cannot be run in this buffer."
            return
        endif

        var selection = join(lines, "\n")
        if empty(selection)
            echo "AIReview: Please make a visual selection or provide a range."
            return
        endif

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

        if empty(file_text)
            echo "AIReviewFile: The file is empty."
            return
        endif

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

    def SetDebug(arg: string)
        if arg == 'on'
            this.config.debug = true
        elseif arg == 'off'
            this.config.debug = false
        elseif empty(arg)
            this.config.debug = !this.config.debug
        else
            echoerr "AIDebug: expected 'on', 'off', or no argument to toggle."
            return
        endif
        g:debug = this.config.debug ? 1 : 0
        echo $"AI debug mode: {this.config.debug ? 'On' : 'Off'} (curl commands will be echoed via :messages, API keys redacted)"
    enddef

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

    # Deliberately NOT the same toggle-on-no-arg pattern as
    # SetShowPrompt/SetDebug above. Those are safe to toggle blind -
    # you already know your own show_prompt/debug state, so running
    # the command with no args is a deliberate flip. This flag is
    # different: it's the one guard standing between a {=>*=}/{=>name=}
    # response and files getting overwritten on disk (see
    # AIBuffer.WriteResponseToWildcard/WriteResponseToTarget), so
    # running :AIReviewReceived to check its current value should never
    # itself be the action that silently turns review mode off. No
    # argument reports the current value only; only an explicit 'on' or
    # 'off' changes it.
    def SetReviewReceived(arg: string)
        if arg == 'on'
            this.config.always_review_received_files = true
        elseif arg == 'off'
            this.config.always_review_received_files = false
        elseif empty(arg)
            echo $"Always review received files: {this.config.always_review_received_files ? 'On' : 'Off'}"
            return
        else
            echoerr "AIReviewReceived: expected 'on' or 'off' to change it, or no argument to report the current value."
            return
        endif
        g:always_review_received_files = this.config.always_review_received_files ? 1 : 0
        echo $"Always review received files: {this.config.always_review_received_files ? 'On' : 'Off'}"
    enddef

    def SetBaseUrl(arg: string)
        if this.config.provider != 'openai'
            echoerr $"AIUrl only applies to the openai provider (current provider is '{this.config.provider}')."
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

    # Generic get/set for any key in Cfg.AIConfig.CONFIGURABLE_KEYS -
    # the "expert" escape hatch that reaches every configurable setting
    # without needing a dedicated command per field. No args: list valid
    # keys. Key only: show its current value. Both: set it. Unlike
    # :AIModel, this does NOT check the value against the current
    # provider - if you're using :AISet you're assumed to know what
    # you're doing (e.g. pre-configuring a provider before switching to it).
    def SetConfig(key: string = '', value: string = '')
        if empty(key)
            echo join(Cfg.AIConfig.CONFIGURABLE_KEYS, "\n")
            return
        endif
        if empty(value)
            echo $'{key} = {this.config.Get(key)}'
            return
        endif
        if this.config.Set(key, value)
            echo $'{key} set to: {value}'
        endif
    enddef

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

    # With an explicit model name, sets it directly (unchanged). With no
    # name, tries to read one off lnum first - a model line from a
    # :AIModels listing, per AIBuffer.ModelNameFromModelsLine - so a bare
    # :AIModel run with the cursor on such a line switches to it. If
    # lnum isn't a model line (e.g. :AIModel run somewhere else
    # entirely), falls back to the original no-arg behavior: just show
    # the current model. AIModel is defined with -range in
    # plugin/ai.vim, so a plain :AIModel with no selection passes the
    # current line as lnum.
    def SetModel(model: string, lnum: number)
        var provider = this.GetCurrentProvider()
        var target = model

        if empty(target)
            target = this.buffer.ModelNameFromModelsLine(getline(lnum))
        endif

        if empty(target)
            echo "Current model: " .. provider.GetCurrentModel()
            return
        endif

        this.WarnIfModelMismatched(target)

        provider.SetModel(target)
        echo "Model set to: " .. target
    enddef

    # Soft sanity check: ask every OTHER provider whether this model name
    # looks like it's theirs (via IsRecognizedModel). Warns but doesn't
    # block, since custom/local model names can't always be predicted.
    # New providers get this check for free - no hardcoded names here.
    def WarnIfModelMismatched(model: string)
        for [name, provider] in items(this.providers)
            if name != this.config.provider && provider.IsRecognizedModel(model)
                echoerr $"Warning: '{model}' looks like a {name} model, but the current provider is '{this.config.provider}'."
            endif
        endfor
    enddef
endclass
