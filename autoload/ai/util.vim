"use vim9script only:
vim9script

# autoload/ai/util.vim
# Small stateless helpers shared by more than one provider. Kept separate
# so pulling in a single provider file (e.g. to add a new command) doesn't
# require pulling in unrelated provider code just to get these.

import './util_facade.vim' as uf

const VIMGEM_HOME = fnamemodify(expand(get(g:, 'vimgem_chat_home', '~/.vimgem/xx')), ':h')
const LOG_ROOT = VIMGEM_HOME .. '/log'

# Replace a secret (API key) with a placeholder before echoing a command,
# so :AIDebug output never leaks credentials. No-op if secret is empty.
export def RedactSecret(text: string, secret: string): string
    if empty(secret)
        return text
    endif
    return substitute(text, escape(secret, '\/.*$^~[]'), '***REDACTED***', 'g')
enddef

# Strip common chat-template special tokens that some local servers
# (e.g. certain mlx_lm.server / llama.cpp builds) fail to trim from the
# end of a completion before returning it - most visible with ChatML-style
# models (Qwen, etc.) as a trailing "<|im_end|>".
export def StripChatArtifacts(text: string): string
    var cleaned = text
    var known_tokens = [
        '<|im_end|>', '<|im_start|>', '<|endoftext|>',
        '<|eot_id|>', '<|end_of_text|>', '<|end|>', '</s>',
    ]
    for token in known_tokens
        cleaned = substitute(cleaned, '\V' .. escape(token, '\'), '', 'g')
    endfor
    return trim(cleaned)
enddef

# ----------------------------------------------------------------------
# Message utilities - convenient notation for tracing
# ----------------------------------------------------------------------

# Using call() with function() is the approved workaround for vararg forwarding.
export def MSG(fmt: string, ...rest: list<any>)
    var msg = call(function('printf', [fmt]), rest)
    writefile([msg], '/dev/stdout')
enddef

export def EMSG(fmt: string, ...rest: list<any>)
    var msg = call(function('printf', [fmt]), rest)
    writefile([msg], '/dev/stderr')
enddef

export def ERR(fmt: string, ...rest: list<any>)
    var msg = call(function('printf', [fmt]), rest)
    writefile(["ERROR: " .. msg], '/dev/stderr')
enddef

#this sets the initial active_debug_levels to 0:
#TODO:  this should be a configuration option:
var active_debug_levels: dict<bool> = {0: true}

export def SetDebugLevels(spec: string = '')
    var trimmed = trim(spec)
    if empty(trimmed)
        var current = keys(active_debug_levels)->map((_, v) => str2nr(v))
        sort(current, 'n')
        echo $"Current DBG levels: {empty(current) ? 'Off (0)' : join(current, ', ')}"
        return
    endif

    if trimmed == '0'
        active_debug_levels = {}
        echo "DBG mode: Off (all levels disabled)"
        return
    endif

    var new_levels: dict<bool> = {}
    var parts = split(trimmed, ',')
    for part in parts
        var range_parts = split(part, '-')
        if len(range_parts) == 1
            var lvl = str2nr(trim(range_parts[0]))
            if lvl > 0
                new_levels[lvl] = true
            endif
        elseif len(range_parts) == 2
            var start_lvl = str2nr(trim(range_parts[0]))
            var end_lvl = str2nr(trim(range_parts[1]))
            if start_lvl > 0 && end_lvl >= start_lvl
                for l in range(start_lvl, end_lvl)
                    new_levels[l] = true
                endfor
            endif
        endif
    endfor

    active_debug_levels = new_levels
    var active_list = keys(active_debug_levels)->map((_, v) => str2nr(v))
    sort(active_list, 'n')
    echo $"DBG levels set to: {join(active_list, ', ')}"
enddef

export def DebugLevelOn(level: number): bool
    return get(active_debug_levels, level, false)
enddef

export def GetMessageLogPath(): string
    return $"{LOG_ROOT}/debug_{getpid()}.log"
enddef

export def DBG(level: number, fmt: string, ...rest: list<any>)
    # if debug level for this message isn't on...
    if !DebugLevelOn(level)
        # ...then no logging:
        return
    endif

    # if no log dir...
    if !isdirectory(LOG_ROOT)
        # ...then no logging:
        return
    endif

    var logfn = GetMessageLogPath()
    var msg = call('printf', [fmt] + rest)
    writefile(["DEBUG: " .. msg], logfn, "a")

    # Refresh the message_log.txt buffer in place if it is open,
    # so :DBGShowLog stays live without any polling overhead.
    uf.RefreshMessageLog(logfn)
enddef

# ----------------------------------------------------------------------
# PrettyJson - render a JSON string (as a list of raw lines) into a
# human-readable form using `jq -M .` for structural pretty-printing,
# then post-process jq's output to expand embedded newlines inside
# string values into real display lines, aligned to the start of the
# string value (Option C alignment).
#
# The two-character sequence problem:
#   jq renders a real embedded newline (from JSON \n) as the two
#   characters backslash + n in its output. A literal backslash-n that
#   appeared in the original content is rendered as four characters:
#   backslash + backslash + n. We split only on the unescaped two-char
#   form.
#
#   We avoid regex entirely for this split. stridx() is used to locate
#   the two-char needle (constructed as "\\" .. "n" so vim9script does
#   not interpret it as a real newline). All slicing uses strpart()
#   with byte offsets to stay consistent with stridx(), which is
#   critical for correctness when the string contains multibyte
#   characters (e.g. em-dash, curly quotes) - stridx() returns byte
#   positions, and Vim9 string[n] indexing uses character positions,
#   so mixing the two causes truncation bugs when multibyte chars
#   appear earlier in the line.
#
# Double blank lines:
#   A paragraph break in the original text becomes \n\n in the JSON,
#   which jq renders as two consecutive \n sequences. Each produces an
#   empty segment, which would become two consecutive blank display
#   lines. After splitting we collapse runs of consecutive empty parts
#   to a single empty string so paragraph breaks render as one blank
#   line rather than two.
#
# Alignment (Option C):
#   For a jq output line like:
#       "text": "line one\nline two"
#   continuation lines are indented to the column immediately after
#   the opening quote of the value:
#       "text": "line one
#                line two"
#
# Returns [] on jq failure - callers should check executable('jq')
# first and report the error themselves.
export def PrettyJson(raw_lines: list<string>): list<string>
    if !executable('jq')
        return []
    endif

    var raw = join(raw_lines, "\n")

    g:DBG(4, 'PrettyJson: input (%d chars): %s', len(raw), strpart(raw, 0, 200))

    # -M = monochrome (no ANSI colour codes), . = identity filter.
    var jq_out = system('jq -M .', raw)
    if v:shell_error != 0
        g:DBG(4, 'PrettyJson: jq failed with shell_error=%d', v:shell_error)
        return []
    endif

    g:DBG(4, 'PrettyJson: jq output (%d chars)', len(jq_out))

    # Split jq's output on real newlines (from jq's line-by-line
    # pretty-printing) to get one jq output line per list entry.
    var jq_lines = split(jq_out, "\n", true)

    # The two-char needle we scan for: backslash followed by n.
    # Constructed this way so vim9script doesn't collapse it to 0x0A.
    const NEEDLE = "\\" .. "n"
    const NEEDLE_LEN = 2

    # The single backslash byte, for the escaped-backslash check.
    # strpart(line, pos - 1, 1) returns one byte regardless of whether
    # it is part of a multibyte character - safe to compare to this.
    const BACKSLASH = "\\"

    var result: list<string> = []
    for line in jq_lines
        # Fast path: no backslash-n sequence at all in this line.
        if stridx(line, NEEDLE) == -1
            add(result, line)
            continue
        endif

        g:DBG(4, 'PrettyJson: processing line with needle: [%s]', strpart(line, 0, 120))

        # Find the value-start column for Option C alignment.
        # matchlist() works on characters, but value_col is used only
        # to build the padding string via repeat(), so character-level
        # length is correct here (we want N display columns of spaces,
        # not N bytes).
        var value_col = 0
        var key_match = matchlist(line, '^\(\s*"[^"]*":\s*"\)')
        if !empty(key_match)
            value_col = len(key_match[1])
        else
            var indent_match = matchlist(line, '^\(\s*\)')
            value_col = empty(indent_match) ? 0 : len(indent_match[1])
        endif
        var pad = repeat(' ', value_col)

        g:DBG(4, 'PrettyJson: value_col=%d', value_col)

        # Walk the line with stridx(), which returns BYTE positions.
        # All slicing is done with strpart(line, byte_start, byte_len)
        # to stay consistent - never mix stridx() byte positions with
        # Vim9 line[n] character indexing, since multibyte characters
        # (em-dash, curly quotes, etc.) make byte and character offsets
        # diverge and cause silent truncation.
        var parts: list<string> = []
        var seg_start = 0   # byte offset of current segment start
        var search_from = 0 # byte offset to start next stridx() from
        while true
            var pos = stridx(line, NEEDLE, search_from)
            if pos == -1
                # No more occurrences - emit the remainder and stop.
                var remainder = strpart(line, seg_start)
                g:DBG(4, 'PrettyJson: final segment [%s]', strpart(remainder, 0, 80))
                add(parts, remainder)
                break
            endif

            # Check whether this backslash is itself escaped (preceded
            # by another backslash). strpart(line, pos - 1, 1) gives
            # the single byte before the needle - safe for the
            # backslash comparison since backslash is ASCII.
            var prev_byte = pos > 0 ? strpart(line, pos - 1, 1) : ''
            g:DBG(4, 'PrettyJson: found needle at pos=%d prev_byte=[%s]', pos, prev_byte)

            if prev_byte == BACKSLASH
                # Escaped: this is \\n in the source, not a real
                # embedded newline. Skip past it and keep scanning.
                g:DBG(4, 'PrettyJson: skipping escaped \\n at pos=%d', pos)
                search_from = pos + NEEDLE_LEN
                continue
            endif

            # Unescaped backslash-n: emit the bytes from seg_start up
            # to (but not including) pos, then advance past the needle.
            var segment = strpart(line, seg_start, pos - seg_start)
            g:DBG(4, 'PrettyJson: segment [%s]', strpart(segment, 0, 80))
            add(parts, segment)
            seg_start = pos + NEEDLE_LEN
            search_from = seg_start
        endwhile

        # Collapse consecutive empty parts to a single empty string so
        # that a paragraph break (\n\n in the original) becomes one
        # blank display line rather than two. This mirrors how the
        # markdown buffer renders the same content.
        var collapsed: list<string> = []
        var prev_empty = false
        for p in parts
            var is_empty = empty(p)
            if is_empty && prev_empty
                # Skip: previous part was already empty.
                continue
            endif
            add(collapsed, p)
            prev_empty = is_empty
        endfor

        # Emit each collapsed part: the first keeps the line as-is
        # (it already has the key and opening structure).
        # Continuations are indented to value_col so they align under
        # the opening quote of the value (Option C).
        for i in range(len(collapsed))
            if i == 0
                add(result, collapsed[i])
            else
                var cont = pad .. collapsed[i]
                g:DBG(4, 'PrettyJson: continuation line [%s]', strpart(cont, 0, 80))
                add(result, cont)
            endif
        endfor
    endfor

    g:DBG(4, 'PrettyJson: result has %d lines', len(result))
    return result
enddef

const P = expand('<sfile>:t')
const autoload_dir = expand('<sfile>:h')
var util_globals = printf("%s/%s", autoload_dir, "util_globals.vim")

DBG(0, "%s: uf.GetChatDir()=%s", P, uf.GetChatDir())

DBG(1, "%s: autoload_dir=%s util_globals=%s", P, autoload_dir, util_globals)
DBG(1, '%s: expand(util_globals)=%s', P, expand(util_globals))
DBG(1, "<sfile>:t=%s, using Util.DBG, <sfile>:h='%s'", expand('<sfile>:t'), expand('<sfile>:h'))
DBG(1, "%s: <sfile>:.='%s'", P, expand('<sfile>:.'))

# formulate and execute legacy notation g:DBG() - has to be full system
# path or load will fail:
var execstr = printf("source %s", util_globals)
DBG(1, "%s: execstr='%s'", P, execstr)
execute(execstr)
# NOTE: now we can no longer use the module DBG(), have to use g:DBG()
# test that we have the legacy shorthand:
g:DBG(0, "%s: initialized message log, '%s'", P, GetMessageLogPath())
