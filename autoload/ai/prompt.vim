" Copyright (c) 2025-2026 Russ Tremain.
" Released under the MIT License. See LICENSE file for details.
vim9script

# autoload/ai/prompt.vim
# Prompt Processing Class
#
# Register/buffer reference expansion ({='a=}, {=1,10<'#>=}), the
# direct-name :AIChat I/O directives ({=<name=}, {=>name=}, {=>*=}),
# and the canned Explain/Review prompt templates. Fully standalone -
# no dependency on config, providers, or buffer display.
#
# Public API is exposed via prompt_api.vim (facade). All methods here
# are internal - do not import this file directly from core.vim.
#
# Two families of reference syntax coexist deliberately:
#   - {='a=} / {=1,10<'a>=} - register-indirected. The name of the
#     buffer/file is stored in a register first; useful when you've
#     already navigated to and yanked from the source, or want a
#     specific line range. Register content expands inline with no
#     wrapper - it is a direct substitution into the prompt text.
#   - {=<name=} / {=>name=} / {=>*=} - direct-name, :AIChat-only. The
#     name is typed straight into the prompt. No line-range support by
#     design: these are meant for whole-file read/write (e.g. "convert
#     this file to Go"); to operate on a portion of a file, yank it
#     into a register and use the indirected form instead.
# The two never collide: direct forms require '<' or '>' immediately
# after '{=', which the register forms never produce (they start with
# either "'" or a line-range digit).
#
# File reads ({=<name=}, {=1,10<'a>=}) are wrapped with [ID:/END ID:]
# markers (see FILE_ID_BEG/FILE_ID_END) so the model can distinguish
# multiple inlined files and knows how to label its own output for
# round-trip routing via {=>*=} or {=>name=}. The instruction telling
# the model to use these markers on output lives in core.vim alongside
# the write-target directives, not here.
#
# {=>name=} still expects exactly one fenced code block back and
# writes it to that one named buffer. {=>*=} is for when the number of
# output files isn't fixed in advance: every fenced block in the
# response becomes its own new buffer, left for the user to inspect
# and save under whatever name they choose. {=> dir/*=} is the same
# wildcard form with a directory prefix: identified blocks land under
# 'dir/' (created via mkdir -p if needed) instead of their bare path.

export class AIPrompt
    # Set by SetError() on any reference resolution failure. Never
    # accessed directly by callers - read via HadError()/LastError()
    # getters exposed through prompt_api.vim. If any single reference
    # fails, ExpandReferences aborts and returns the original prompt
    # unchanged rather than sending a half-expanded result.
    var had_error: bool = false
    var last_error: string = ''

    # ASCII BEL (0x07) - used as a positional placeholder during macro
    # expansion. Chosen because it cannot be typed or pasted into a
    # prompt accidentally, is visible in debug traces (:set list), and
    # has no special meaning to Vim's substitute(). One marker per
    # macro occurrence; ordering between pass 1 and pass 2 is what
    # ties each marker back to its expansion.
    const MACRO_MARKER = "\x07"

    # Matches any {=...=} macro token. Non-greedy .\{-} is required
    # (not [^=]*) because valid macro content can contain '=' - e.g.
    # {=<foo=bar.vim=} or the >= inside {=1,10<'a>=}. Non-greedy
    # stops at the earliest =} rather than the last, so two macros on
    # the same line are extracted independently.
    const MACRO_PATTERN = '{=.\{-}=}'

    # Symmetric [ID:]/[END ID:] markers for file content sent to and
    # received from the model. printf() format strings - call as
    # printf(FILE_ID_BEG, filename) etc. Kept as constants so input
    # labeling (LabelFile, LabelFileForRoundTrip) and output parsing
    # (ExtractIdentifiedBlocks) can't drift out of sync, and the
    # format can be changed in one place if needed.
    # No leading/trailing \n - call sites control spacing explicitly.
    const FILE_ID_BEG = '[ID: %s]'
    const FILE_ID_END = '[END ID: %s]'

    # Two-pass macro expansion. Expanded content is never rescanned
    # for further macros - MACRO_MARKER placeholders inserted in pass 1
    # are replaced with fully-expanded text in pass 2, so {=...=}
    # syntax that happens to appear inside a file's content or a
    # register value is never accidentally processed.
    #
    # Pass 1: walk the original prompt left-to-right, extracting each
    #   {=...=} token verbatim into macro_refs and replacing it with
    #   a single MACRO_MARKER. Only the first match is replaced per
    #   iteration (no 'g' flag) so extraction order matches marker
    #   order exactly.
    #
    # Pass 2: expand each token in macro_refs in order, substituting
    #   the next MACRO_MARKER with the result. On any expansion error,
    #   report it and return the ORIGINAL prompt unchanged.
    # PUBLIC - called from prompt_api.vim.
    def ExpandReferences(prompt: string): string
        this.had_error = false
        this.last_error = ''

        # Pass 1: extract tokens, plant markers.
        var macro_refs: list<string> = []
        var work = prompt
        while work =~ this.MACRO_PATTERN
            add(macro_refs, matchstr(work, this.MACRO_PATTERN))
            work = substitute(work, this.MACRO_PATTERN, this.MACRO_MARKER, '')
        endwhile

        # No macros found - return prompt as-is, nothing to do.
        if empty(macro_refs)
            return prompt
        endif

        # Pass 2: expand each token, replace next marker with result.
        for token in macro_refs
            var expanded = this.ExpandOneMacro(token)
            if this.had_error
                echoerr this.last_error
                return prompt
            endif
            # escape() guards against \ and & in expanded content being
            # misinterpreted as substitute() replacement special chars.
            work = substitute(work, this.MACRO_MARKER, escape(expanded, '\&'), '')
        endfor

        return work
    enddef

    # Records a failure without throwing, and returns '' so call sites
    # can write `return this.SetError(...)` in one line. Never calls
    # echoerr directly - that is left to ExpandReferences so the full
    # substitute() pass always completes before any error is reported.
    def SetError(msg: string): string
        this.had_error = true
        this.last_error = msg
        return ''
    enddef

    # Wraps a range-read reference with [ID:/END ID:] markers so the
    # model can distinguish multiple inlined file fragments. range_desc
    # (e.g. 'lines 1-10') is appended to the opening marker when given.
    # Used by BufferSub only - not DirectSub, which uses
    # LabelFileForRoundTrip to include the round-trip output contract.
    def LabelFile(name: string, content: string, range_desc: string = ''): string
        var suffix = empty(range_desc) ? '' : $' ({range_desc})'
        return printf(this.FILE_ID_BEG, name .. suffix) .. "\n"
            .. content .. "\n"
            .. printf(this.FILE_ID_END, name)
    enddef

    # {=<name=} whole-file round-trip label (used by DirectSub only).
    # Wraps file content with [ID:/END ID:] markers so the model sees
    # the same format it is asked to use on output. The instruction
    # telling the model to echo these markers lives in core.vim alongside
    # the write-target directives - stated once per turn, not per file.
    # [END ID:] closes each block explicitly so multiple files pulled in
    # via a glob stay unambiguous about boundaries.
    # BufferSub uses plain LabelFile instead - a line-range fragment has
    # no round-trip contract implied.
    def LabelFileForRoundTrip(name: string, content: string): string
        return printf(this.FILE_ID_BEG, name) .. "\n"
            .. content .. "\n"
            .. printf(this.FILE_ID_END, name)
    enddef

    # Dispatches one raw {=...=} token to the right handler by
    # inspecting its inner content directly - no submatch() needed.
    #
    # The three forms and how they are distinguished:
    #   {='a=}         inner starts with '     -> RegisterSub(reg)
    #   {=1,10<'a>=}   inner matches range<'X> -> BufferSub(range, reg)
    #   {=<name=}      inner starts with <     -> DirectSub(name)
    #
    # Write forms ({=>name=}, {=>*=}) are stripped by ExtractWriteTarget
    # before ExpandReferences is called, so they never reach here.
    # An empty token {==} expands to '' silently - harmless no-op.
    def ExpandOneMacro(token: string): string
        # Strip the {= =} fences to get the raw inner content.
        var inner = token[2 : -3]

        if empty(inner)
            # {==} - empty macro, silent no-op.
            return ''
        endif

        if inner[0] == "'"
            # {='a=} - single register letter follows the quote.
            return this.RegisterSub(inner[1])

        elseif inner =~ "^[^<]*<'"
            # {=1,10<'a>=} - range then <'X>.
            var range_str = matchstr(inner, '^[^<]\+')
            var reg_name  = matchstr(inner, "<'\\zs[a-zA-Z0-9#%]\\ze>$")
            if empty(reg_name)
                return this.SetError($"Malformed buffer-range macro: {token}")
            endif
            return this.BufferSub(range_str, reg_name)

        elseif inner[0] == '<'
            # {=<name=} - direct file/buffer/glob read.
            return this.DirectSub(inner[1 : ])

        endif

        # Unrecognised form - leave the original token in place so the
        # user can see what wasn't recognised.
        return token
    enddef

    # {='a=} - expands the content of vim register 'a' (or '#', '%',
    # etc.) inline into the prompt with no wrapper. Registers are a
    # direct substitution - the user placed {='r=} mid-sentence and
    # wants the content there, not a labeled block.
    def RegisterSub(reg_name: string): string
        var reg_content = getreg(reg_name)
        if empty(reg_content)
            return this.SetError($"Register '{reg_name}' is empty or does not exist")
        endif
        return reg_content
    enddef

    # {=1,10<'a>=} - reads a line range from the buffer/file whose
    # path is stored in register 'a. Wrapped with [ID:/END ID:] so
    # the model can distinguish multiple inlined fragments.
    def BufferSub(range_str: string, reg_name: string): string
        var buf_name = getreg(reg_name)
        if empty(buf_name)
            return this.SetError($"Register '{reg_name}' is empty or does not exist")
        endif

        var buf_content = this.GetBufferRange(buf_name, range_str)
        if this.had_error || empty(buf_content)
            return ''
        endif
        return this.LabelFile(buf_name, buf_content, $'lines {substitute(range_str, ",", "-", "")}')
    enddef

    # {=<name=} - read the whole contents of buffer/file `name` given
    # directly rather than via a register. Supports glob patterns
    # (e.g. {=<july25/*.vim=}) to inline multiple files at once.
    # Always uses LabelFileForRoundTrip so [ID:/END ID:] markers are
    # present in history for the two-turn round-trip workflow even when
    # the current turn has no {=>*=} write directive.
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
            if this.had_error || empty(content)
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
    # PUBLIC - called from prompt_api.vim.
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

    # Shared fence-scanner used by ExtractCodeBlock and
    # ExtractAllCodeBlocks so the two can't drift out of sync on what
    # counts as a fenced block.
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

    # PUBLIC - called from prompt_api.vim.
    # Pulls the single fenced code block from a write-target response.
    # Falls back to the raw response if there isn't exactly one block.
    def ExtractCodeBlock(response: string): string
        var blocks = this.SplitFencedBlocks(response)
        return len(blocks) == 1 ? join(blocks[0], "\n") : response
    enddef

    # PUBLIC - called from prompt_api.vim.
    # Pulls every fenced code block for a {=>*=} wildcard turn.
    # Falls back to the whole response as one block if none are fenced.
    def ExtractAllCodeBlocks(response: string): list<string>
        var blocks = this.SplitFencedBlocks(response)
        if empty(blocks)
            return [response]
        endif
        return mapnew(blocks, (_, b) => join(b, "\n"))
    enddef

    # {=>*=} response parser for the [ID:/END ID:] round-trip protocol.
    # Drives entirely off the [ID:]/[END ID:] markers - no triple-grave
    # fences required or expected. Any text outside the markers (model
    # preamble like "OK", commentary between files, etc.) is silently
    # ignored, so the model can be conversational around the file blocks
    # without breaking routing.
    #
    # [END ID:] is matched loosely (.\{-} for the name) so a mismatched
    # or slightly malformed closing tag still closes the block correctly
    # rather than collecting lines forever.
    #
    # A block with id == '' means no [ID:] markers appeared at all -
    # the whole response is returned as one unidentified block so the
    # turn still opens something reviewable rather than silently
    # producing nothing.
    def ExtractIdentifiedBlocks(response: string): list<dict<string>>
        var results: list<dict<string>> = []
        var pending_id = ''
        var in_block = false
        var current: list<string> = []

        for line in split(response, '\n')
            if !in_block
                var id_match = matchlist(line, '^\[ID:\s*\(.\{-}\)\s*\]$')
                if !empty(id_match)
                    pending_id = id_match[1]
                    current = []
                    in_block = true
                endif
            elseif line =~# '^\[END ID:\s*.\{-}\s*\]$'
                add(results, {id: pending_id, code: join(current, "\n")})
                pending_id = ''
                in_block = false
                current = []
            else
                add(current, line)
            endif
        endfor

        # No [ID:] blocks found - return whole response as one
        # unidentified block so the turn still produces something
        # reviewable instead of silently opening nothing.
        if empty(results)
            return [{id: '', code: response}]
        endif
        return results
    enddef

    # bufnr() treats a plain string as a file-name pattern (partial
    # match), not an exact name. Anchoring forces an exact match so a
    # near-miss falls through to the disk-read fallback correctly.
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

        # Not a buffer Vim knows about - fall back to disk so
        # {=1,14<'a>=} works even for files never :edit-ed.
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

    # buf_name is a filesystem path; expand() handles '~' and relative
    # paths. Used when the name doesn't match any open buffer.
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

    # PUBLIC - called from prompt_api.vim.
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

    # PUBLIC - called from prompt_api.vim.
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
