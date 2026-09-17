"use vim9 script only:
vim9script

# autoload/ai/prompt.vim
# Prompt Processing Class
#
# Register/buffer reference expansion ({='a=}, {=1,10<'#>=}), the
# direct-name :AIChat I/O directives ({=<name=}, {=>name=}, {=>*=}),
# and the canned Explain/Review prompt templates. Fully standalone -
# no dependency on config, providers, or buffer display.
#
# Two families of reference syntax coexist deliberately:
#   - {='a=} / {=1,10<'a>=} - register-indirected. The name of the
#     buffer/file is stored in a register first; useful when you've
#     already navigated to and yanked from the source, or want a
#     specific line range.
#   - {=<name=} / {=>name=} / {=>*=} - direct-name, :AIChat-only. The
#     name is typed straight into the prompt. No line-range support by
#     design: these are meant for whole-file read/write (e.g. "convert
#     this file to Go"); to operate on a portion of a file, yank it
#     into a register and use the indirected form instead.
# The two never collide: direct forms require '<' or '>' immediately
# after '{=', which the register forms never produce (they start with
# either "'" or a line-range digit).
#
# Multiple {=<name=} (or register/range) reads in a single prompt each
# get wrapped with a "##### FILE: name #####" / "##### END FILE #####"
# delimiter (see LabelFile) so the model can tell several inlined
# files apart - important for multi-file requests like "rework these
# three files and write new versions", where unlabeled content
# concatenated together would be ambiguous about which file is which.
#
# {=>name=} still expects exactly one fenced code block back and
# writes it to that one named buffer. {=>*=} is for when the number of
# output files isn't fixed in advance, or you don't want to trust the
# model to label its own output correctly: every fenced block in the
# response becomes its own new buffer, left for the user to inspect
# and save under whatever name they choose - no attempt is made to
# guess which block corresponds to which real file. {=> dir/*=} is the
# same wildcard form with a directory prefix: identified blocks that
# get written straight to disk land under 'dir/' (created via mkdir -p
# if it doesn't exist yet) instead of at their bare id-derived path.

export class AIPrompt
    # Set by SetError() (called from every *Sub()/GetBufferRange*()
    # failure point below) when a reference can't be resolved. {= =}
    # are meant to be absolute quotes: the only thing that should ever
    # come out of them is a register/buffer/file lookup performed
    # against the raw prompt the user typed. If any single reference
    # in that raw prompt fails to resolve, the whole expansion is
    # aborted and the original prompt is returned unchanged, rather
    # than returning a prompt that's half-expanded - see
    # ExpandReferences below.
    #
    # Deliberately does NOT use echoerr from inside the *Sub() methods
    # to signal this: echoerr throws a catchable exception, and doing
    # that from inside the \=expr callback substitute() evaluates
    # would abort substitute() itself mid-pass, meaning had_error would
    # never actually get set and ExpandReferences would never reach
    # its own fallback return - the exception would just propagate,
    # uncaught, straight out of the caller. SetError()/last_error let
    # the whole substitute() pass finish normally, so this flag (and
    # the fallback behavior below) actually works. Callers (see
    # AIPlugin.Ask/ChatSend) must check had_error after calling
    # ExpandReferences and decline to send the query if it's set,
    # rather than silently sending back whatever came out.
    var had_error: bool = false
    var last_error: string = ''

    # All three reference families are matched in ONE pass over the
    # ORIGINAL prompt string via substitute(..., 'g'). This is
    # deliberate and load-bearing: substitute() evaluates the
    # replacement expression once per match found in the *source*
    # string and never rescans replacement text for further matches.
    #
    # The previous implementation used `while expanded =~ pattern` and
    # manually spliced in replacement text, then re-ran the regex
    # search against the *whole*, now-mutated string on every
    # iteration. That meant register/buffer/file content - arbitrary
    # data the user doesn't control the shape of (an old AI reply
    # quoting this plugin's own {=...=} syntax, a code sample
    # containing a similar-looking token, etc.) - could itself be
    # re-matched and expanded again on the next loop pass. {= =} must
    # only ever be recognized in what the user actually typed; this
    # single substitute() pass guarantees that.
    def ExpandReferences(prompt: string): string
        this.had_error = false
        this.last_error = ''
        var pattern = '{=\%(''\([a-zA-Z0-9#%]\)\|\([^<]\+\)<''\([a-zA-Z0-9#%]\)>\|<\([^=]\+\)\)=}'
        var expanded = substitute(prompt, pattern, '\=this.ReferenceSub()', 'g')
        if this.had_error
            echoerr this.last_error
            return prompt
        endif
        return expanded
    enddef

    # Records a failure without throwing (see the had_error comment
    # above for why this matters), and returns '' so call sites can
    # write `return this.SetError(...)` in one line.
    def SetError(msg: string): string
        this.had_error = true
        this.last_error = msg
        return ''
    enddef

    # Wraps a read reference's content with a delimiter naming its
    # source, so multiple {=<name=}/{=1,10<'a>=} references expanded
    # into the same prompt are distinguishable from each other. Before
    # this, three unlabeled file bodies concatenated back to back gave
    # the model no way to tell where one file ended and the next
    # began, or which was which - fine for the original single-file
    # use case, silently broken for multi-file prompts.
    def LabelFile(name: string, content: string, range_desc: string = ''): string
        var suffix = empty(range_desc) ? '' : $' ({range_desc})'
        return $"##### FILE: {name}{suffix} #####\n" .. content .. $"\n##### END FILE: {name} #####"
    enddef

    # {=<name=} whole-file round-trip label (used by DirectSub only).
    # Replaces the "##### FILE: name #####" / "##### END FILE #####"
    # fence pair with a single instruction line, for two reasons at
    # once: it's shorter (fewer tokens per file, which matters once
    # {=<july25/*.vim=} is pulling in a whole directory), and unlike
    # the old delimiter - which only ever labeled the INPUT - it also
    # tells the model how to label its OUTPUT, by asking it to open its
    # reply with a matching `[ID: name]` marker. That marker is what
    # lets a later {=>*=} response be routed straight back to the real
    # file instead of landing in a generic, unlabeled [AI-output-N]
    # buffer - see ExtractIdentifiedBlocks below and
    # AIBuffer.WriteResponseToWildcard.
    #
    # Kept to whole-file reads only (DirectSub) - not BufferSub's
    # line-range reads. A range is a fragment; even if the model tagged
    # it, writing that reply back over the whole real file would
    # clobber everything outside the range. BufferSub keeps the plain
    # LabelFile wrapper, with no round-trip contract implied.
    #
    # [END ID: name] closes the block explicitly (rather than relying
    # on the next `[ID: ...]` line, or end of prompt, to imply a
    # boundary) so multiple whole files pulled into one prompt via a
    # glob - each wrapped separately in DirectSub - stay unambiguous
    # about where one file's content ends and the next begins.
    #
    # The instruction is deliberately conditional ("if - and only if -
    # you return an updated version") rather than an unconditional
    # "start your response with the tagged file" demand. An earlier,
    # unconditional version of this wording caused a plain "here's a
    # file, just answer this question about it" turn (no {=>*=} in
    # sight) to have the model dump the entire file back into the
    # visible chat log anyway, just to comply with the instruction,
    # even though the round-trip protocol was never going to be used.
    # Making it conditional keeps the ID-tagging contract available for
    # the genuine two-turn workflow this exists for - read a file now,
    # ask for it back reshaped via {=>*=} in a LATER turn, relying on
    # this instruction still being present in that earlier turn's
    # history for the model to know what name to tag - without forcing
    # a tag-and-dump on every turn that merely reads a file for
    # context.
    def LabelFileForRoundTrip(name: string, content: string): string
        return $"The following file, '{name}', is provided for this request. If - and only if - your response includes a full replacement version of this file, begin that portion of your reply with exactly `[ID: {name}]` on its own line, immediately followed by the code, with nothing else in between. If you are not returning an updated version of this file (e.g. you were only asked a question about it, or the request doesn't call for changing it), just respond normally - do not include the `[ID: {name}]` marker or repeat the file's contents.\n" .. content .. $"\n[END ID: {name}]"
    enddef

    # Dispatches a single matched {=...=} token to the right family
    # based on which submatch group is non-empty. Called once per
    # match in the original prompt, never on already-expanded text.
    def ReferenceSub(): string
        if submatch(1) != ''
            return this.RegisterSub(submatch(1))
        elseif submatch(3) != ''
            return this.BufferSub(submatch(2), submatch(3))
        elseif submatch(4) != ''
            return this.DirectSub(submatch(4))
        endif
        # Shouldn't happen given the pattern, but leave untouched
        # rather than silently dropping text.
        return submatch(0)
    enddef

    # {='a=} - register-indirected read. Not associated with a
    # filename, so labeled by register letter rather than by name -
    # still needed once two different registers land in the same
    # prompt.
    def RegisterSub(reg_name: string): string
        var reg_content = getreg(reg_name)
        if empty(reg_content)
            return this.SetError($"Register '{reg_name}' is empty or does not exist")
        endif
        return $"##### REGISTER '{reg_name} #####\n" .. reg_content .. $"\n##### END REGISTER '{reg_name} #####"
    enddef

    # {=1,10<'a>=} - register-indirected read of a line range from the
    # buffer/file whose name is stored in register 'a.
    def BufferSub(range_str: string, reg_name: string): string
        var buf_name = getreg(reg_name)
        if empty(buf_name)
            return this.SetError($"Register '{reg_name}' is empty or does not exist")
        endif

        var buf_content = this.GetBufferRange(buf_name, range_str)
        if empty(buf_content)
            return ''
        endif
        return this.LabelFile(buf_name, buf_content, $'lines {substitute(range_str, ",", "-", "")}')
    enddef

    # {=<name=} - read the WHOLE contents of buffer/file `name`, given
    # directly rather than via a register. Reuses GetBufferRange's
    # existing buffer-then-disk-fallback lookup with an implicit
    # "1,$" range, so this is just sugar over the same resolution logic
    # the register-indirected form uses.
    # Supports glob patterns (e.g. {=<july25/*.vim=}) to read and inline
    # multiple matching files at once.
    #
    # Always uses LabelFileForRoundTrip (not a plain LabelFile) even
    # when the current turn has no {=>*=}/{=>name=} write directive of
    # its own - the two-turn workflow (read a file now, ask for it back
    # reshaped via {=>*=} in a LATER turn) depends on this turn's
    # history still carrying the `[ID: name]` instruction for the model
    # to reuse then. See LabelFileForRoundTrip for how the instruction
    # itself stays conditional so this doesn't cause the model to dump
    # the file back on a turn that never asked for it.
    def DirectSub(name_raw: string): string
        var pattern = trim(name_raw)
        if pattern =~ '[*?{}]'
            var paths = glob(pattern, false, true)
            if empty(paths)
                return this.SetError($"No files matched glob pattern '{pattern}'")
            endif
            var results = []
            for path in paths
                if filereadable(path)
                    var content = join(readfile(path), "\n")
                    add(results, this.LabelFileForRoundTrip(path, content))
                endif
            endfor
            if empty(results)
                return this.SetError($"No readable files matched glob pattern '{pattern}'")
            endif
            return join(results, "\n\n")
        else
            var name = pattern
            var content = this.GetBufferRange(name, '1,$')
            if empty(content)
                return ''
            endif
            return this.LabelFileForRoundTrip(name, content)
        endif
    enddef

    # {=>name=} / {=>new(scratch)=} - marks where the AI's *response*
    # (not something to read now) should be routed once it comes back.
    # {=>*=} - wildcard form for an unknown NUMBER of output files:
    # rather than betting on the model naming each block correctly (it
    # doesn't reliably), every fenced code block in the response gets
    # opened as its own new buffer for the user to inspect and save
    # themselves - see AIBuffer.WriteResponseToWildcard. The two never
    # combine; a prompt uses one or the other.
    #
    # {=> dir/*=} - same wildcard form, but with a directory prefix:
    # every identified block that gets written straight to disk lands
    # under 'dir/' instead of directly at its own id-derived path (the
    # id-less [AI-output-N] review tabs and always-review-received-files
    # tabs are unaffected, since neither of those touches disk here -
    # see AIBuffer.WriteResponseToWildcard). 'dir' is captured as
    # everything between '{=>' and the literal '*', minus surrounding
    # whitespace and any trailing slash; '{=>*=}' still parses the same
    # as before with an empty output_dir.
    #
    # Unlike the read directives, neither is ever expanded inline - the
    # model should never see raw plugin syntax in its prompt. Instead
    # the directive is stripped out here and the target/wildcard flag
    # is handed back separately so the caller can route the response
    # after the API call returns.
    #
    # Both branches strip with the 'g' flag (not just the first match)
    # even though only one write directive per prompt is the supported
    # case - so a prompt that accidentally contains a second one still
    # gets it removed instead of leaking raw {=...=} syntax into what's
    # sent to the model.
    def ExtractWriteTarget(prompt: string): dict<any>
        var wildcard_pattern = '{=>\s*\([^=*]*\)\*\s*=}'
        var wildcard_match = matchlist(prompt, wildcard_pattern)
        if !empty(wildcard_match)
            var output_dir = substitute(trim(wildcard_match[1]), '/\+$', '', '')
            var stripped = trim(substitute(prompt, wildcard_pattern, '', 'g'))
            return {stripped: stripped, target: '', wildcard: true, output_dir: output_dir}
        endif

        var pattern = '{=>\([^=]\+\)=}'
        if prompt !~ pattern
            return {stripped: prompt, target: '', wildcard: false, output_dir: ''}
        endif

        var full_match = matchstr(prompt, pattern)
        var target = trim(substitute(full_match, pattern, '\1', ''))
        var stripped = trim(substitute(prompt, pattern, '', 'g'))
        return {stripped: stripped, target: target, wildcard: false, output_dir: ''}
    enddef

    # Shared fence-scanner used by both ExtractCodeBlock (single named
    # target) and ExtractAllCodeBlocks (wildcard target) below, so the
    # two can't drift out of sync on what counts as a fenced block.
    def SplitFencedBlocks(response: string): list<list<string>>
        var blocks: list<list<string>> = []
        var current: list<string> = []
        var in_fence = false

        for line in split(response, '\n')
            if line =~# '^```'
                if in_fence
                    add(blocks, current)
                else
                    current = []
                endif
                in_fence = !in_fence
            elseif in_fence
                add(current, line)
            endif
        endfor

        return blocks
    enddef

    # Pulls the contents of a single fenced code block out of an AI
    # response, for write-target turns where only the code - not the
    # model's commentary - should land in the destination file/buffer.
    # Falls back to the raw response if there isn't exactly one fenced
    # block, so a malformed or chatty reply doesn't silently write
    # nothing.
    def ExtractCodeBlock(response: string): string
        var blocks = this.SplitFencedBlocks(response)
        return len(blocks) == 1 ? join(blocks[0], "\n") : response
    enddef

    # Pulls out EVERY fenced code block for a {=>*=} wildcard turn, one
    # per output file the model produced, in response order - deciding
    # which block belongs to which real filename is left to the user
    # (see AIBuffer.WriteResponseToWildcard), not guessed here. Falls
    # back to the whole response as a single block if the model didn't
    # fence anything at all, so a malformed reply still opens one
    # reviewable buffer instead of silently opening none.
    def ExtractAllCodeBlocks(response: string): list<string>
        var blocks = this.SplitFencedBlocks(response)
        if empty(blocks)
            return [response]
        endif
        return mapnew(blocks, (_, b) => join(b, "\n"))
    enddef

    # {=>*=} response parser for the `[ID: name]` round-trip protocol
    # (see LabelFileForRoundTrip). Walks the response the same way
    # SplitFencedBlocks does, but also watches for a `[ID: name]`
    # marker line immediately before a fence and attaches it to the
    # block that follows, so a reply built from one or more {=<name=}
    # round-trip reads can be routed straight back to the real file
    # (see AIBuffer.WriteResponseToWildcard) instead of a generic
    # [AI-output-N] buffer.
    #
    # A block with no preceding marker comes back with id == '' - this
    # is the normal case for a plain {=>*=} wildcard turn that never
    # used {=<name=} round-trip reads, and it's routed through the same
    # id-less fallback path WriteResponseToWildcard already had, so
    # nothing changes for that use case.
    #
    # This is a separate scan rather than a wrapper around
    # SplitFencedBlocks: that helper discards every non-fence line
    # outright, but the `[ID: ...]` marker line has to be read and
    # correlated with the block that follows it, not thrown away.
    def ExtractIdentifiedBlocks(response: string): list<dict<string>>
        var results: list<dict<string>> = []
        var pending_id = ''
        var in_fence = false
        var current: list<string> = []

        for line in split(response, '\n')
            if !in_fence
                var id_match = matchlist(line, '^\[ID:\s*\(.\{-}\)\s*\]$')
                if !empty(id_match)
                    pending_id = id_match[1]
                    continue
                endif
            endif

            if line =~# '^```'
                if in_fence
                    add(results, {id: pending_id, code: join(current, "\n")})
                    pending_id = ''
                else
                    current = []
                endif
                in_fence = !in_fence
            elseif in_fence
                add(current, line)
            endif
        endfor

        # Malformed/chatty reply with no fenced blocks at all - same
        # fallback ExtractAllCodeBlocks uses: one unidentified block
        # covering the whole response, so the turn still opens
        # something reviewable instead of silently producing nothing.
        if empty(results)
            return [{id: '', code: response}]
        endif
        return results
    enddef

    # bufnr() treats a plain String argument as a file-name *pattern*
    # (same partial-match rules as :buffer completion), not an exact
    # name - e.g. "main" can silently match an open "domain.txt" or
    # "main_test.go". Anchoring the pattern forces an exact match, so a
    # near-miss correctly falls through to the disk-read fallback below
    # instead of silently pulling a different buffer's content.
    def ExactBufNr(buf_name: string): number
        return bufnr('^' .. escape(buf_name, '\.*$~[]') .. '$')
    enddef

    def GetBufferRange(buf_name: string, range_str: string): string
        var range_parts = split(range_str, ',')
        if len(range_parts) != 2
            return this.SetError($"Invalid range format: {range_str}")
        endif
        var start_line = str2nr(range_parts[0])
        var end_str = trim(range_parts[1])

        var buf_num = this.ExactBufNr(buf_name)
        if buf_num != -1
            return this.GetBufferRangeFromBuffer(buf_num, buf_name, start_line, end_str)
        endif

        # Not a buffer Vim already knows about - fall back to reading it
        # straight off disk. This is what lets {=1,14<'a>=} pull from any
        # file whose path is in register 'a', even if you've never
        # :edit-ed it, not just files already open as buffers.
        return this.GetBufferRangeFromDisk(buf_name, start_line, end_str)
    enddef

    def GetBufferRangeFromBuffer(buf_num: number, buf_name: string, start_line: number, end_str: string): string
        if !bufloaded(buf_num)
            try
                bufload(buf_num)
                if !bufloaded(buf_num)
                    return this.SetError($"Failed to load buffer '{buf_name}'")
                endif
            catch
                return this.SetError($"Error loading buffer '{buf_name}': {v:exception}")
            endtry
        endif

        var end_line = end_str == '$' ? len(getbufline(buf_num, 1, '$')) : str2nr(end_str)

        var buf_lines = getbufline(buf_num, start_line, end_line)
        if empty(buf_lines)
            return this.SetError($"Could not read lines {start_line}-{end_line} from buffer '{buf_name}'")
        endif

        return join(buf_lines, "\n")
    enddef

    # buf_name here is a filesystem path (expand() handles '~' and
    # relative paths against cwd) rather than an open buffer - used when
    # the register content doesn't match any buffer Vim already knows
    # about, so this file can be pulled in without ever :edit-ing it.
    def GetBufferRangeFromDisk(buf_name: string, start_line: number, end_str: string): string
        var path = expand(buf_name)
        if !filereadable(path)
            return this.SetError($"'{buf_name}' is neither an open buffer nor a readable file.")
        endif

        var file_lines = readfile(path)
        var end_line = end_str == '$' ? len(file_lines) : str2nr(end_str)

        if start_line < 1 || end_line > len(file_lines) || start_line > end_line
            return this.SetError($"Invalid line range {start_line}-{end_line} for '{path}' ({len(file_lines)} lines)")
        endif

        return join(file_lines[start_line - 1 : end_line - 1], "\n")
    enddef

    def BuildExplainPrompt(selection: string, filetype: string, filename: string): string
        return "You are an expert developer. The following "
            .. filetype .. " code from file '" .. filename
            .. "' needs explanation. Provide a detailed explanation focusing on:\n"
            .. "1. The overall purpose and design.\n"
            .. "2. Key algorithms and data structures.\n"
            .. "3. Important implementation details.\n"
            .. "4. Potential edge cases or concerns.\n\n"
            .. "Here is the code:\n" .. selection
    enddef

    def BuildReviewPrompt(selection: string, filetype: string, filename: string): string
        return "You are an expert code reviewer. Review ONLY the "
            .. filetype .. " code from file '" .. filename
            .. "' provided below. Do not invent functions or scenarios. "
            .. "Based STRICTLY on the provided code, provide:\n"
            .. "1. Overall code quality assessment\n"
            .. "2. Potential bugs or issues\n"
            .. "3. Performance considerations\n"
            .. "4. Best practice recommendations\n"
            .. "5. Security concerns if any\n\n"
            .. "Here is the code:\n" .. selection
    enddef
endclass
