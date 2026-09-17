"use vim9 script only:
vim9script

# autoload/ai/buffer.vim
# Buffer Management Class
#
# Everything about how AI output gets shown in a Vim buffer lives here:
# throwaway query/info output as well as the persistent :AIChat transcript.
# Self-contained aside from AIConfig (for show_prompt/provider display).

import './config.vim' as Cfg
import './md.vim' as Md
import './util.vim' as Util

# Marker delimiting the start of a new question in an :AIChat buffer.
# Kept as a script-level constant so the create/append/lookup methods
# below can't drift out of sync with each other.
#
# '\>' (word-end) rather than the old '\s*$' because every '## You'
# line now carries a timestamp from the moment it's written (see
# NowStamp, used by CreateChat/AppendChatTurn), e.g.
# '## You  [1800:24.23]' - the pattern needs to match that, not just a
# bare '## You'.
const CHAT_USER_MARKER = '^## You\>'

# Matches a session line as written by DisplayChatHistory below, e.g.
# '- 20240521-153000  (2024-05-21 15:30)  some excerpt text'. Kept as a
# constant so the writer (DisplayChatHistory) and reader
# (ChatIdFromHistoryLine) can't drift out of sync with each other.
const HISTORY_LINE_PATTERN = '^- \(\S\+\)\s\+('

# Matches a model line as written by any provider's ListModels() - all
# three (Gemini, Claude, OpenAI-compatible) format their model lines as
# exactly two leading spaces then the model id/name, e.g.
# '  gemini-3.1-flash-lite - Gemini 3.1 Flash Lite', '  claude-opus-4-8',
# '  gpt-4o'. None of their header/footer lines share that two-space
# indent, so this one pattern works across every provider without
# needing to know which one is active. \S\+ stops at the first
# whitespace, which conveniently drops Gemini's trailing
# ' - description' and leaves just the model id.
const MODELS_LINE_PATTERN = '^  \(\S\+\)'

export class AIBuffer
    var config: Cfg.AIConfig

    def new(config: Cfg.AIConfig)
        this.config = config
    enddef

    def Create(filetype: string = 'markdown')
        new
        setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
        execute 'setlocal filetype=' .. filetype
    enddef

    def SetContent(lines: list<string>)
        setline(1, lines)
    enddef

    # Like SetContent, but also trims any lines left over from whatever
    # was in the buffer before - SetContent alone only overwrites the
    # first len(lines) lines, so it can't shrink a buffer. Needed for
    # RefreshChatHistory below, where a delete can make the new listing
    # shorter than the old one.
    def ReplaceContent(lines: list<string>)
        setline(1, lines)
        if line('$') > len(lines)
            deletebufline('%', len(lines) + 1, '$')
        endif
    enddef

    def AppendContent(lines: list<string>)
        append(line('$'), lines)
    enddef

    def DisplayResponse(prompt: string, response: string, model: string)
        this.Create('markdown')

        if this.config.show_prompt
            var header = [
                '# AI Response',
                '',
                $'**Provider:** {this.config.provider}',
                $'**Model:** {model}',
                '',
                '## Prompt',
                ''
            ]

            var footer = [
                '',
                '---',
                '',
                '## Response',
                ''
            ]

            this.SetContent(header)
            this.AppendContent(split(prompt, '\n', 1))
            this.AppendContent(footer)
            this.AppendContent(split(response, '\n'))
        else
            this.SetContent(split(response, '\n'))
        endif
    enddef

    def DisplayText(lines: list<string>, filetype: string = 'text')
        this.Create(filetype)
        this.SetContent(lines)
    enddef

    # ------------------------------------------------------------------
    # :AIChat support
    #
    # The visible .md buffer is a LOG, not the conversation state - the
    # API-facing history lives separately as a JSON array in a sidecar
    # file (see LoadHistory/SaveHistory below), so sending a turn never
    # requires reparsing anything the buffer contains. This is also why
    # write-target turns can summarize their AI reply in the log
    # ("-> wrote to foo.go (95 lines)") instead of dumping the full
    # response inline - the full text still went into the JSON history,
    # it's just not duplicated into the buffer you look at.
    #
    # The '## You' marker still matters for one thing: GetNewPromptText
    # uses it to find where your latest, not-yet-sent question starts,
    # so ChatSend knows what's new without needing a visual selection.
    #
    # Unlike the other Create()-based buffers (throwaway query/info
    # output), a chat is worth keeping: it's backed by a real file under
    # g:vimgem_chat_home rather than an unnamed 'nofile' buffer, and uses
    # bufhidden=hide instead of the default 'wipe' - so switching to
    # another file in the same window just hides it (recoverable via
    # :ls / :buffer / CTRL-^), it doesn't destroy it. A chat session's
    # two files - chat-<id>.md (log) and chat-<id>.json (history) -
    # share the same <id>, a timestamp slug, linked by the buffer-local
    # b:ai_chat_id.
    # ------------------------------------------------------------------
    def ChatDir(): string
        return expand(get(g:, 'vimgem_chat_home', '~/.vimgem/ai-chat'))
    enddef

    def LogPath(chat_id: string): string
        return this.ChatDir() .. '/chat-' .. chat_id .. '.md'
    enddef

    def HistoryPath(chat_id: string): string
        return this.ChatDir() .. '/chat-' .. chat_id .. '.json'
    enddef

    # Rendered-HTML sidecar for a chat session, kept alongside the .md
    # log and .json history under the same chat_id - see MaybeRenderHtml.
    def HtmlPath(chat_id: string): string
        return this.ChatDir() .. '/chat-' .. chat_id .. '.html'
    enddef

    # Parses the model name back out of a log's header line, e.g.
    # '# AI Chat [gemini/gemini-3.1-flash-lite]' -> 'gemini-3.1-flash-lite'.
    # Kept in sync with the exact header format CreateChat writes below.
    # Returns '' for a missing/blank header, or one rewritten by
    # ResumeChat's recreate-a-minimal-log fallback ('# AI Chat (resumed)'),
    # which carries no model info.
    def ChatModelFromHeader(header: string): string
        var matches = matchlist(header, '^# AI Chat \[[^/]\+/\(.\+\)\]$')
        return empty(matches) ? '' : matches[1]
    enddef

    def CreateChat(provider: string, model: string): string
        var chat_dir = this.ChatDir()
        if !isdirectory(chat_dir)
            mkdir(chat_dir, 'p')
        endif
        var chat_id = strftime('%Y%m%d-%H%M%S')

        execute 'new ' .. fnameescape(this.LogPath(chat_id))
        setlocal bufhidden=hide
        b:ai_chat = 1
        b:ai_chat_id = chat_id

        this.SaveHistory(chat_id, [])
        this.SetContent([
            # Bracket style matches how AIBuffer.BuildChatHistoryLines
            # shows the model in the :AIChatHistory listing ('[model]').
            $'# AI Chat [{provider}/{model}]',
            '',
            $'## You  [{this.NowStamp()}]',
            '',
        ])
        normal! G
        this.MaybeAutosave()
        return chat_id
    enddef

    # model is tagged into the visible header only ('## AI  [sent_at]
    # (model)') - the JSON history stays exactly {role, text},
    # untouched, since that's fed straight into
    # AIProvider.GenerateChat and there's no need to risk leaking an
    # extra field into the API request just to label the transcript.
    # This is what lets you switch providers/models mid-chat
    # (:AIProvider, :AIModel) and still tell which turn came from
    # which model when scrolling back.
    #
    # sent_at is captured by the caller (AIPlugin.ChatSend) right
    # before the request goes out, since by the time this method runs
    # the round trip has already happened - AppendChatTurn can't
    # recover that moment on its own. The *trailing* '## You' this
    # writes gets its own fresh timestamp, taken here, marking when
    # the response was received - so scrolling back, each '## You'
    # timestamp marks when that slot opened (session start, from
    # CreateChat, or the previous response's arrival, from here) and
    # each '## AI' timestamp marks when that turn's prompt was sent.
    def AppendChatTurn(display_text: string, model: string, sent_at: string)
        var received_at = this.NowStamp()
        this.AppendContent(['', $'## AI  [{sent_at}] ({model})', ''] + split(display_text, '\n') + ['', $'## You  [{received_at}]', ''])
        normal! G
        this.MaybeAutosave()
    enddef

    # g:ai_chat_autosave defaults on: a chat transcript costs real API
    # calls to regenerate, so persisting it to disk after every turn
    # (not just on bufhidden=hide, which only protects against losing
    # the in-memory buffer) is the safer default. Set to 0 to disable.
    # Only affects the visible .md log - the .json history is always
    # written immediately regardless of this setting, since losing it
    # silently would break context continuity on resume.
    def MaybeAutosave()
        if get(g:, 'ai_chat_autosave', 1) == 1
            silent write
            this.MaybeRenderHtml()
        endif
    enddef

    # Renders the whole visible chat log to HTML on every turn (CreateChat
    # and AppendChatTurn both call this via MaybeAutosave above), writing
    # it to the .html sidecar next to that session's .md/.json files. The
    # parse runs off the CURRENT BUFFER rather than rereading from disk,
    # so it always reflects exactly what MaybeAutosave just wrote, and
    # only costs one more markdown parse of a chat-log-sized buffer -
    # not noticeable per turn.
    #
    # Nothing displays this file yet - it's here so a future
    # :AIChatDisplay (open the rendered chat in a browser) has nothing
    # left to compute on demand, just a file to open. Whether that ends
    # up shelling out to `open`/`xdg-open`/$BROWSER is a separate,
    # OS-dependent decision for that command, not this one.
    #
    # Off by its own flag (default on) as well as ai_chat_autosave's,
    # in case a very large chat's markdown ever makes the per-turn parse
    # noticeable. Wrapped in try/catch so a malformed line can't turn a
    # routine autosave into a visible error mid-chat - callers don't
    # expect this side effect to be able to fail loudly.
    def MaybeRenderHtml()
        if get(g:, 'ai_chat_html_autosave', 1) != 1 || !exists('b:ai_chat_id')
            return
        endif
        try
            var html = Md.MdVim.new().ParseMarkdown(getline(1, '$'))
            writefile(html, this.HtmlPath(b:ai_chat_id))
        catch
            Util.DBG('MaybeRenderHtml: failed for chat %s: %s', b:ai_chat_id, v:exception)
        endtry
    enddef

    # Best-effort "open this file in whatever the OS considers the
    # default handler for .html" - Vim has no built-in cross-platform
    # equivalent of macOS's `open`, so this picks the right external
    # command per platform, in order of confidence:
    #   mac    -> `open`                      (always present)
    #   win32  -> `cmd.exe /c start`           (start is a cmd builtin,
    #             not a real executable, so it has to be invoked
    #             through cmd.exe; the empty '' arg is the (title)
    #             parameter `start` expects before a path, so a path
    #             that happens to look like a flag isn't misread as one)
    #   other  -> `xdg-open` if present (most Linux desktops), else
    #             `wslview` if present (WSL, where there's no Linux
    #             browser to hand off to - wslview forwards to Windows)
    # job_start (not system()) so control returns to Vim immediately;
    # the browser process outlives Vim and nothing here waits on it or
    # captures its output. Untested beyond mac by me - error message
    # says so on the paths that couldn't be verified here.
    static def _LaunchInBrowser(path: string): dict<any>
        var cmd: list<string> = []
        if has('mac')
            cmd = ['open', path]
        elseif has('win32')
            cmd = ['cmd.exe', '/c', 'start', '', path]
        elseif executable('xdg-open')
            cmd = ['xdg-open', path]
        elseif executable('wslview')
            cmd = ['wslview', path]
        else
            return {ok: false, error: 'no known way to open a browser on this platform (tried xdg-open/wslview) - open the file manually: ' .. path}
        endif

        try
            job_start(cmd)
        catch
            return {ok: false, error: $'failed to launch {cmd[0]}: {v:exception}'}
        endtry
        return {ok: true}
    enddef

    # Opens the rendered HTML for chat_id in the OS default browser.
    # Renders on the fly if the .html sidecar is missing, or older than
    # the .md log it should reflect - covers chats from before
    # MaybeRenderHtml existed, or resumed sessions where
    # g:ai_chat_html_autosave was off - so :AIChatDisplay never shows
    # stale or nonexistent output, independent of that autosave setting.
    def OpenHtmlInBrowser(chat_id: string): dict<any>
        var md_path = this.LogPath(chat_id)
        if !filereadable(md_path)
            return {ok: false, error: $"no saved chat log for '{chat_id}'"}
        endif

        var html_path = this.HtmlPath(chat_id)
        if !filereadable(html_path) || getftime(html_path) < getftime(md_path)
            try
                var html = Md.MdVim.new().ParseMarkdown(readfile(md_path))
                writefile(html, html_path)
            catch
                return {ok: false, error: $'failed to render chat: {v:exception}'}
            endtry
        endif

        return AIBuffer._LaunchInBrowser(html_path)
    enddef

    # Scans backward from end_line for the most recent '## You' marker
    # and returns everything after it up to end_line - i.e. whatever
    # you've typed for your next question. Returns '' if no marker is
    # found (shouldn't happen in a buffer created by CreateChat/
    # ResumeChat, both of which always seed one).
    def FindLastUserMarkerLine(end_line: number): number
        for lnum in range(end_line, 1, -1)
            if getline(lnum) =~# CHAT_USER_MARKER
                return lnum
            endif
        endfor
        return 0
    enddef

    def GetNewPromptText(end_line: number): string
        var marker_line = this.FindLastUserMarkerLine(end_line)
        if marker_line == 0
            return ''
        endif
        return trim(join(getline(marker_line + 1, end_line), "\n"))
    enddef

    # Vim has no built-in "current time to the hundredth of a second"
    # primitive. reltime()'s absolute baseline isn't guaranteed to be a
    # real, timezone-correct Unix epoch on every platform (it's
    # gettimeofday()-backed on typical Unix builds, but that's not a
    # documented contract) - so the date/hour/minute/second portion comes
    # from localtime(), which strftime() is guaranteed to render in
    # local time correctly. reltime() is only used for the sub-second
    # fraction, which is safe even if its baseline differs from
    # localtime()'s, since only the fractional part (mod 1 second) is
    # taken. Format is YYMMDD HHMM:SS.hh, 24-hour clock - e.g. '260303 1800:22.88'.
    def NowStamp(): string
        var whole = localtime()
        var frac = reltimefloat(reltime())
        frac -= floor(frac)
        var hundredths = float2nr(round(frac * 100))
        if hundredths >= 100
            hundredths = 0
            whole += 1
        endif
        return strftime('%y%m%d %H%M:%S', whole) .. printf('.%02d', hundredths)
    enddef

    # ------------------------------------------------------------------
    # JSON-backed history: the actual source of truth for conversation
    # context. One flat array of {role, text} per session, matching
    # AIProvider.GenerateChat's expected shape directly - no translation
    # layer needed between "what's persisted" and "what's sent".
    # ------------------------------------------------------------------
    def LoadHistory(chat_id: string): list<dict<string>>
        var path = this.HistoryPath(chat_id)
        if !filereadable(path)
            return []
        endif
        try
            return json_decode(join(readfile(path), "\n"))
        catch
            echoerr $"Failed to read chat history '{path}': {v:exception}"
            return []
        endtry
    enddef

    def SaveHistory(chat_id: string, history: list<dict<string>>)
        writefile([json_encode(history)], this.HistoryPath(chat_id))
    enddef

    def AppendHistoryTurn(chat_id: string, user_text: string, assistant_text: string)
        var history = this.LoadHistory(chat_id)
        add(history, {role: 'user', text: user_text})
        add(history, {role: 'assistant', text: assistant_text})
        this.SaveHistory(chat_id, history)
    enddef

    # Erases persisted context for this session so future turns stop
    # resending earlier ones - does NOT touch the visible .md log,
    # which stays around to read/copy from even after the API-facing
    # memory is cleared.
    def ClearHistory(chat_id: string)
        this.SaveHistory(chat_id, [])
    enddef

    # ------------------------------------------------------------------
    # Session discovery/resume
    # ------------------------------------------------------------------
    # Pure formatting, shared by DisplayChatHistory (new buffer) and
    # RefreshChatHistory (in-place update) below so the two can't drift
    # out of sync with each other or with HISTORY_LINE_PATTERN.
    def BuildChatHistoryLines(sessions: list<dict<any>>): list<string>
        var lines = ['# AI Chat Sessions', '']
        for s in sessions
            var excerpt = empty(s.excerpt) ? '(empty)' : s.excerpt
            var model = empty(s.model) ? '?' : s.model
            add(lines, $'- {s.id}  ({s.modified})  {s.line_count} lines  [{model}]  {excerpt}')
        endfor
        add(lines, '')
        add(lines, 'Put the cursor on a session line and run :AIChatResume to resume it, or :AIChatDelete to delete it. :AIChatResume run elsewhere resumes the most recent chat.')
        return lines
    enddef

    # Renders the session list built by ListSessions. Each session line
    # is formatted so ChatIdFromHistoryLine can recover its id later -
    # that's what lets :AIChatResume/:AIChatDelete, run with the cursor
    # on one of these lines, act on that specific session with no
    # argument.
    def DisplayChatHistory(sessions: list<dict<any>>)
        this.Create('markdown')
        this.SetContent(this.BuildChatHistoryLines(sessions))
    enddef

    # Re-renders an already-open chat-history listing buffer in place
    # (no new split/window) - used by AIPlugin.ChatDelete so deleting a
    # session removes its line immediately instead of requiring a
    # manual :AIChatHistory rerun (which would also stack a second
    # listing window on top of this one).
    def RefreshChatHistory(sessions: list<dict<any>>)
        if empty(sessions)
            this.ReplaceContent(['# AI Chat Sessions', '', 'No saved AI chats found.'])
            return
        endif
        this.ReplaceContent(this.BuildChatHistoryLines(sessions))
    enddef

    # Recovers a session id from one line of a chat-history listing
    # buffer (see DisplayChatHistory). Returns '' for header/footer/
    # blank lines that don't match the session-line format.
    def ChatIdFromHistoryLine(line_text: string): string
        var matches = matchlist(line_text, HISTORY_LINE_PATTERN)
        return empty(matches) ? '' : matches[1]
    enddef

    # Recovers a model id/name from one line of a :AIModels listing
    # buffer (see AIProvider.ListModels implementations). Returns '' for
    # header/footer/blank lines that don't match the two-space-indent
    # model-line format shared by every provider.
    def ModelNameFromModelsLine(line_text: string): string
        var matches = matchlist(line_text, MODELS_LINE_PATTERN)
        return empty(matches) ? '' : matches[1]
    enddef

    def ListSessions(): list<dict<any>>
        var chat_dir = this.ChatDir()
        if !isdirectory(chat_dir)
            return []
        endif

        var sessions: list<dict<any>> = []
        for path in glob(chat_dir .. '/chat-*.json', false, true)
            var chat_id = substitute(fnamemodify(path, ':t:r'), '^chat-', '', '')
            var excerpt = ''
            for msg in this.LoadHistory(chat_id)
                if msg.role == 'user'
                    # Vim buffer lines can't contain an embedded newline
                    # - setline() would store \n as a literal NUL byte,
                    # which displays as ^@. Flatten any run of newlines/
                    # carriage returns to a single space before
                    # truncating, since at 60 chars there's no room for
                    # a multi-line prompt to read as anything but noise
                    # anyway.
                    excerpt = strpart(substitute(msg.text, '[\r\n]\+', ' ', 'g'), 0, 60)
                    break
                endif
            endfor
            var md_path = this.LogPath(chat_id)
            var md_lines = filereadable(md_path) ? readfile(md_path) : []
            var line_count = len(md_lines)
            var model = this.ChatModelFromHeader(get(md_lines, 0, ''))
            add(sessions, {
                id: chat_id,
                mtime: getftime(path),
                modified: strftime('%Y-%m-%d %H:%M', getftime(path)),
                excerpt: excerpt,
                line_count: line_count,
                model: model,
            })
        endfor

        return sort(sessions, (a, b) => b.mtime - a.mtime)
    enddef

    # Called via autocmd whenever a chat-*.md file is opened directly
    # (:e, netrw, MRU, fzf, ...) rather than through :AIChat/
    # :AIChatResume, so ad-hoc reopening still wires up b:ai_chat and
    # b:ai_chat_id correctly.
    def OnChatFileOpened()
        b:ai_chat = 1
        b:ai_chat_id = substitute(fnamemodify(bufname('%'), ':t:r'), '^chat-', '', '')
        setlocal bufhidden=hide
    enddef

    # Opens the log for chat_id (most recently modified session if
    # chat_id is empty) and wires up b:ai_chat/b:ai_chat_id. Returns the
    # resolved chat_id, or '' if chat_id was given but doesn't match any
    # saved session.
    def ResumeChat(chat_id: string): string
        var sessions = this.ListSessions()
        if empty(sessions)
            return ''
        endif

        var target = chat_id
        if empty(target)
            target = sessions[0].id
        elseif index(mapnew(sessions, (_, s) => s.id), target) == -1
            return ''
        endif

        var md_path = this.LogPath(target)
        if !filereadable(md_path)
            # History survived but the log file was deleted/moved -
            # recreate a minimal log rather than failing outright.
            writefile(['# AI Chat (resumed)', '', $'## You  [{this.NowStamp()}]', ''], md_path)
        endif

        execute 'edit ' .. fnameescape(md_path)
        setlocal bufhidden=hide
        b:ai_chat = 1
        b:ai_chat_id = target
        normal! G
        return target
    enddef

    # Deletes the files backing a session (chat-<id>.md log,
    # chat-<id>.json history, and chat-<id>.html render, if that last
    # one exists - older sessions predating MaybeRenderHtml won't have
    # one, which is fine). Returns false if chat_id doesn't match a
    # known session (no .md or .json), or if a file that exists fails
    # to delete. A missing .html is never itself a failure condition.
    def DeleteChat(chat_id: string): bool
        var md_path = this.LogPath(chat_id)
        var json_path = this.HistoryPath(chat_id)
        var html_path = this.HtmlPath(chat_id)

        if !filereadable(md_path) && !filereadable(json_path)
            return false
        endif

        var ok = true
        if filereadable(md_path)
            ok = delete(md_path) == 0 && ok
        endif
        if filereadable(json_path)
            ok = delete(json_path) == 0 && ok
        endif
        if filereadable(html_path)
            ok = delete(html_path) == 0 && ok
        endif
        return ok
    enddef

    # ------------------------------------------------------------------
    # Write-target routing for {=>name=} / {=>new(scratch)=} directives.
    # Opens (creating if needed) the destination buffer and sets its
    # content, but deliberately never touches disk itself - :w!/:w is
    # left to the user, same trust model as any other Vim edit. Refuses
    # to clobber a same-named buffer that already has unsaved changes.
    # ------------------------------------------------------------------
    def WriteResponseToTarget(target: string, code: string): dict<any>
        var origin_win = win_getid()
        var lines = split(code, '\n')

        if target =~? '^new(\s*scratch\s*)$'
            new
            setlocal buftype=nofile bufhidden=hide noswapfile nobuflisted
            this.SetContent(lines)
            win_gotoid(origin_win)
            return {ok: true, summary: $'wrote to a new scratch buffer ({len(lines)} lines)'}
        endif

        var buf_num = bufnr(target)
        if buf_num != -1 && getbufvar(buf_num, '&modified')
            return {ok: false, error: $"buffer '{target}' has unsaved changes - not overwriting"}
        endif

        if buf_num != -1
            execute 'buffer ' .. buf_num
        else
            new
            execute 'file ' .. fnameescape(target)
        endif
        this.SetContent(lines)
        win_gotoid(origin_win)
        return {ok: true, summary: $"wrote to '{target}' ({len(lines)} lines) - not saved to disk, use :w! to persist"}
    enddef

    # Routing for {=>*=} - the wildcard form used when the number of
    # output files isn't known in advance, or the model can't be
    # trusted to label its own blocks correctly (see
    # AIPrompt.ExtractAllCodeBlocks). No attempt is made here to guess
    # a real filename for any block; each just becomes its own new tab
    # ([AI-output-1], [AI-output-2], ...) for the user to look over and
    # save wherever it actually belongs, e.g. :file real_name.go then
    # :w. Opened as tabs rather than splits so each buffer gets the
    # full window to itself for comparing against existing files.
    #
    # Restores focus to the caller's original window before returning,
    # same as WriteResponseToTarget - the caller (AIPlugin.ChatSend)
    # still has to append this turn to the visible chat log buffer
    # afterward, and every AIBuffer append/write method operates on
    # whatever the *current* buffer happens to be rather than taking an
    # explicit buffer argument. Leaving the cursor in a newly created
    # scratch tab here would mean that append (and its autosave) landed
    # in the wrong buffer instead - which is exactly what happened
    # before this fix: the turn silently never reached the chat log, and
    # autosave's `:write` failed outright since scratch buffers are
    # buftype=nofile. first_win is handed back so the caller can
    # deliberately jump to the new tabs afterward, once it's done with
    # the chat buffer.
    # See AIPrompt.ExactBufNr - same reasoning (bufnr() with a plain
    # String argument matches like :buffer completion, not an exact
    # name). Duplicated rather than imported, to keep this file
    # self-contained per the header comment above.
    def ExactBufNr(buf_name: string): number
        return bufnr('^' .. escape(buf_name, '\.*$~[]') .. '$')
    enddef

    # Clears the way for `:file {name}` to succeed by wiping out any
    # EXISTING buffer already carrying that exact name - typically a
    # bufhidden=hide leftover from a previous WriteResponseToWildcard
    # review tab whose tab was closed but whose buffer, per
    # bufhidden=hide, was kept around rather than wiped. Without this,
    # a second round trip for the same id (rerun the same query, or a
    # glob matching the same relative path twice) collides with E95
    # ("buffer name already in use") and - since that used to be
    # wrapped in silent! - silently left the new tab as [No Name]
    # instead of under its real name.
    #
    # Returns false (and leaves the stale buffer alone) only if it has
    # unsaved changes - never wipe modified content out from under the
    # user, even content this same feature created. Returns true
    # otherwise, whether or not a stale buffer actually existed.
    def ReplaceStaleBuffer(name: string): bool
        var existing = this.ExactBufNr(name)
        if existing == -1
            return true
        endif
        if getbufvar(existing, '&modified')
            return false
        endif
        execute 'bwipeout ' .. existing
        return true
    enddef

    # blocks come from AIPrompt.ExtractIdentifiedBlocks: each is
    # {id: string, code: string}. Three outcomes per block:
    #
    #   - id == ''  (model didn't tag it, or this was a plain {=>*=}
    #     turn with no {=<name=} round-trip reads involved) - always
    #     opens its own new tab named [AI-output-N], exactly the old
    #     behavior. No config flag affects this path.
    #
    #   - id is a real filename AND config.always_review_received_files
    #     - opens a new tab under that real name, buftype= (not nofile)
    #     so a plain :w saves it where it belongs once reviewed.
    #
    #   - id is a real filename and the flag is off - writes straight
    #     to disk, creating any missing parent directories. Refused
    #     (block skipped, reported back) if a buffer for that exact
    #     path is already open and modified - same unsaved-changes
    #     guard WriteResponseToTarget uses, so a direct write never
    #     silently discards edits you haven't saved yet. If a *clean*
    #     buffer for that path is open, :checktime is run on it
    #     afterward so it doesn't silently go stale.
    #
    # output_dir (from {=> dir/*=} - see AIPrompt.ExtractWriteTarget)
    # prefixes every id with a real filename, so 'foo.go' lands at
    # 'dir/foo.go' and an id that already carries its own subpath (e.g.
    # from a {=<name=} round trip like 'src/foo.go') lands at
    # 'dir/src/foo.go'. Left '' (the default) this behaves exactly as
    # before. Applies to both outcomes that carry a real filename - the
    # straight-to-disk write AND the always_review_received_files tab,
    # so a newdir directive isn't silently dropped just because review
    # mode is on: the tab is named with the full 'dir/...' path too,
    # and its parent dir is pre-created, so a later :w in that tab
    # lands exactly where the directive said it should. Only the
    # id-less [AI-output-N] tabs are unaffected - there's no real
    # filename to prefix there in the first place.
    #
    # Tabs are used for the two open-a-buffer outcomes (not splits) so
    # each gets the full window, same as the pre-existing behavior -
    # useful for comparing against what's already on disk.
    def WriteResponseToWildcard(blocks: list<dict<string>>, output_dir: string = ''): dict<any>
        var origin_win = win_getid()
        var first_win = -1
        var unidentified_count = 0
        var written: list<string> = []
        var opened_for_review: list<string> = []
        var skipped: list<string> = []

        for block in blocks
            var id = get(block, 'id', '')
            var lines = split(get(block, 'code', ''), '\n')

            if empty(id)
                unidentified_count += 1
                var scratch_name = $'[AI-output-{unidentified_count}]'
                this.ReplaceStaleBuffer(scratch_name)
                tabnew
                setlocal buftype=nofile bufhidden=hide noswapfile nobuflisted
                try
                    execute 'file ' .. fnameescape(scratch_name)
                catch
                    # Leave it as [No Name] rather than pretending this
                    # succeeded - ReplaceStaleBuffer above should have
                    # prevented E95 here, but if the rename fails for
                    # some other reason the content is still visible
                    # and usable, just unlabeled.
                endtry
                this.SetContent(lines)
                if first_win == -1
                    first_win = win_getid()
                endif
                continue
            endif

            var path = empty(output_dir) ? id : output_dir .. '/' .. id

            if this.config.always_review_received_files
                # Pre-create the parent dir (if output_dir named one
                # that doesn't exist yet) even though this branch never
                # writes to disk itself - otherwise a later :w in this
                # tab fails with E212 once the user approves it.
                var review_dir = fnamemodify(path, ':h')
                if !empty(review_dir) && review_dir != '.' && !isdirectory(review_dir)
                    mkdir(review_dir, 'p')
                endif

                # A previous review tab for this exact path may still be
                # sitting around as a hidden buffer - bufhidden=hide
                # keeps it in the buffer list after its tab is closed,
                # and re-running the same round trip (or a glob that
                # matches the same id twice) hits it again. Without
                # clearing it first, the :file rename below fails with
                # E95 (buffer name already in use); previously that
                # failure was wrapped in silent! and swallowed
                # entirely, leaving the new tab as [No Name] with no
                # indication anything went wrong.
                if !this.ReplaceStaleBuffer(path)
                    add(skipped, path)
                    continue
                endif

                tabnew
                setlocal buftype= bufhidden=hide noswapfile
                try
                    execute 'file ' .. fnameescape(path)
                    add(opened_for_review, path)
                catch
                    add(opened_for_review, $'{path} (rename failed, opened as [No Name]: {v:exception})')
                endtry
                this.SetContent(lines)
                if first_win == -1
                    first_win = win_getid()
                endif
                continue
            endif

            var buf_num = this.ExactBufNr(path)
            if buf_num != -1 && getbufvar(buf_num, '&modified')
                add(skipped, path)
                continue
            endif

            var dir = fnamemodify(path, ':h')
            if !empty(dir) && dir != '.' && !isdirectory(dir)
                mkdir(dir, 'p')
            endif

            # Overwrite even a read-only-on-disk file rather than
            # skipping it - the user's stated preference, since
            # always_review_received_files (checked above) is already
            # the escape hatch for anyone who'd rather review first.
            # writefile() respects filesystem permissions and simply
            # fails silently against a read-only file, so the owner
            # write bit is granted before writing. Deliberately left
            # in place afterward (not restored) - the user wants the
            # now-rw permission visible via `ls`/`git diff`/etc. as a
            # signal that this file was force-overwritten, rather than
            # silently restoring read-only and hiding that it happened.
            var was_readonly = filereadable(path) && !filewritable(path)
            if was_readonly
                var orig_perm = getfperm(path)
                setfperm(path, orig_perm[0] .. 'w' .. orig_perm[2 :])
            endif

            writefile(lines, path)
            add(written, was_readonly ? $'{path} (was read-only, now rw)' : path)
            if buf_num != -1
                execute 'checktime ' .. buf_num
            endif
        endfor

        win_gotoid(origin_win)

        # Tab labels can lag behind a :file rename until something else
        # forces a repaint - harmless but confusing right after a batch
        # of tabs just got renamed above. One explicit redraw here
        # covers every tab opened in this call, in a single pass.
        redrawtabline

        var summary_parts: list<string> = []
        if !empty(written)
            add(summary_parts, $'wrote {len(written)} file(s) to disk: {join(written, ", ")}')
        endif
        if !empty(opened_for_review)
            add(summary_parts, $'opened {len(opened_for_review)} for review (always-review-received-files): {join(opened_for_review, ", ")}')
        endif
        if unidentified_count > 0
            add(summary_parts, $'opened {unidentified_count} unidentified block(s) as [AI-output-N] tabs for review')
        endif
        if !empty(skipped)
            add(summary_parts, $'SKIPPED (unsaved changes open in buffer): {join(skipped, ", ")}')
        endif

        if empty(summary_parts)
            return {ok: false, error: 'no output produced'}
        endif
        return {ok: true, summary: join(summary_parts, '; '), first_win: first_win}
    enddef
endclass
