" Copyright (c) 2025-2026 Russ Tremain.
" Released under the MIT License. See LICENSE file for details.
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

# ResolveLang: maps a fenced-code-block lang tag to the Vim filetype
# whose syntax/<ft>.vim defines its highlighting. Only tags that differ
# from their Vim filetype name need an entry - anything not listed is
# passed through verbatim (e.g. 'python', 'ruby', 'rust' match directly).
# Returns '' for an empty/untagged fence.
# Used by both md_syntax.vim (:syntax include) and md_html.vim (:TOhtml
# scratch buffer setlocal filetype=) - single source so the two paths
# always agree on the mapping.
export def ResolveLang(lang: string): string
    if empty(lang)
        return ''
    endif
    var aliases: dict<string> = {
        js:        'javascript',   jsx:    'javascriptreact',
        ts:        'typescript',   tsx:    'typescriptreact',
        py:        'python',       rb:     'ruby',
        rs:        'rust',         golang: 'go',
        sh:        'sh',           bash:   'sh',
        zsh:       'zsh',          shell:  'sh',
        yml:       'yaml',         htm:    'html',
        kt:        'kotlin',       'c++':  'cpp',
        'c#':      'cs',           cs:     'cs',
        vim9script: 'vim',
    }
    return get(aliases, lang, lang)
enddef

# SynWhatTerm: returns 'gui' when Vim is using true-color GUI colors
# (gui_running or termguicolors), 'cterm' otherwise. Mirrors the
# s:whatterm detection in 2html.vim. Pass the result to synIDattr() as
# the third argument so color queries always return hex strings rather
# than terminal color numbers.
export def SynWhatTerm(): string
    return (&termguicolors || has('gui_running')) ? 'gui' : 'cterm'
enddef

# CtermToHex: converts an xterm-256 terminal color number (returned by
# synIDattr(..., 'fg#', 'cterm') when termguicolors is off) to a CSS hex
# string like '#af5f00'. Returns '' for unrecognized values. The table is
# taken verbatim from 2html.vim (s:cterm_color, 256-color branch).
export def CtermToHex(color: any): string
    if empty(color)
        return ''
    endif
    var n = str2nr(string(color))
    var cterm256: dict<string> = {
        0: '#000000',   1: '#c00000',   2: '#008000',   3: '#804000',
        4: '#0000c0',   5: '#c000c0',   6: '#008080',   7: '#c0c0c0',
        8: '#808080',   9: '#ff6060',  10: '#00ff00',  11: '#ffff00',
       12: '#8080ff',  13: '#ff40ff',  14: '#00ffff',  15: '#ffffff',
       16: '#000000',  17: '#00005f',  18: '#000087',  19: '#0000af',
       20: '#0000d7',  21: '#0000ff',  22: '#005f00',  23: '#005f5f',
       24: '#005f87',  25: '#005faf',  26: '#005fd7',  27: '#005fff',
       28: '#008700',  29: '#00875f',  30: '#008787',  31: '#0087af',
       32: '#0087d7',  33: '#0087ff',  34: '#00af00',  35: '#00af5f',
       36: '#00af87',  37: '#00afaf',  38: '#00afd7',  39: '#00afff',
       40: '#00d700',  41: '#00d75f',  42: '#00d787',  43: '#00d7af',
       44: '#00d7d7',  45: '#00d7ff',  46: '#00ff00',  47: '#00ff5f',
       48: '#00ff87',  49: '#00ffaf',  50: '#00ffd7',  51: '#00ffff',
       52: '#5f0000',  53: '#5f005f',  54: '#5f0087',  55: '#5f00af',
       56: '#5f00d7',  57: '#5f00ff',  58: '#5f5f00',  59: '#5f5f5f',
       60: '#5f5f87',  61: '#5f5faf',  62: '#5f5fd7',  63: '#5f5fff',
       64: '#5f8700',  65: '#5f875f',  66: '#5f8787',  67: '#5f87af',
       68: '#5f87d7',  69: '#5f87ff',  70: '#5faf00',  71: '#5faf5f',
       72: '#5faf87',  73: '#5fafaf',  74: '#5fafd7',  75: '#5fafff',
       76: '#5fd700',  77: '#5fd75f',  78: '#5fd787',  79: '#5fd7af',
       80: '#5fd7d7',  81: '#5fd7ff',  82: '#5fff00',  83: '#5fff5f',
       84: '#5fff87',  85: '#5fffaf',  86: '#5fffd7',  87: '#5fffff',
       88: '#870000',  89: '#87005f',  90: '#870087',  91: '#8700af',
       92: '#8700d7',  93: '#8700ff',  94: '#875f00',  95: '#875f5f',
       96: '#875f87',  97: '#875faf',  98: '#875fd7',  99: '#875fff',
      100: '#878700', 101: '#87875f', 102: '#878787', 103: '#8787af',
      104: '#8787d7', 105: '#8787ff', 106: '#87af00', 107: '#87af5f',
      108: '#87af87', 109: '#87afaf', 110: '#87afd7', 111: '#87afff',
      112: '#87d700', 113: '#87d75f', 114: '#87d787', 115: '#87d7af',
      116: '#87d7d7', 117: '#87d7ff', 118: '#87ff00', 119: '#87ff5f',
      120: '#87ff87', 121: '#87ffaf', 122: '#87ffd7', 123: '#87ffff',
      124: '#af0000', 125: '#af005f', 126: '#af0087', 127: '#af00af',
      128: '#af00d7', 129: '#af00ff', 130: '#af5f00', 131: '#af5f5f',
      132: '#af5f87', 133: '#af5faf', 134: '#af5fd7', 135: '#af5fff',
      136: '#af8700', 137: '#af875f', 138: '#af8787', 139: '#af87af',
      140: '#af87d7', 141: '#af87ff', 142: '#afaf00', 143: '#afaf5f',
      144: '#afaf87', 145: '#afafaf', 146: '#afafd7', 147: '#afafff',
      148: '#afd700', 149: '#afd75f', 150: '#afd787', 151: '#afd7af',
      152: '#afd7d7', 153: '#afd7ff', 154: '#afff00', 155: '#afff5f',
      156: '#afff87', 157: '#afffaf', 158: '#afffd7', 159: '#afffff',
      160: '#d70000', 161: '#d7005f', 162: '#d70087', 163: '#d700af',
      164: '#d700d7', 165: '#d700ff', 166: '#d75f00', 167: '#d75f5f',
      168: '#d75f87', 169: '#d75faf', 170: '#d75fd7', 171: '#d75fff',
      172: '#d78700', 173: '#d7875f', 174: '#d78787', 175: '#d787af',
      176: '#d787d7', 177: '#d787ff', 178: '#d7af00', 179: '#d7af5f',
      180: '#d7af87', 181: '#d7afaf', 182: '#d7afd7', 183: '#d7afff',
      184: '#d7d700', 185: '#d7d75f', 186: '#d7d787', 187: '#d7d7af',
      188: '#d7d7d7', 189: '#d7d7ff', 190: '#d7ff00', 191: '#d7ff5f',
      192: '#d7ff87', 193: '#d7ffaf', 194: '#d7ffd7', 195: '#d7ffff',
      196: '#ff0000', 197: '#ff005f', 198: '#ff0087', 199: '#ff00af',
      200: '#ff00d7', 201: '#ff00ff', 202: '#ff5f00', 203: '#ff5f5f',
      204: '#ff5f87', 205: '#ff5faf', 206: '#ff5fd7', 207: '#ff5fff',
      208: '#ff8700', 209: '#ff875f', 210: '#ff8787', 211: '#ff87af',
      212: '#ff87d7', 213: '#ff87ff', 214: '#ffaf00', 215: '#ffaf5f',
      216: '#ffaf87', 217: '#ffafaf', 218: '#ffafd7', 219: '#ffafff',
      220: '#ffd700', 221: '#ffd75f', 222: '#ffd787', 223: '#ffd7af',
      224: '#ffd7d7', 225: '#ffd7ff', 226: '#ffff00', 227: '#ffff5f',
      228: '#ffff87', 229: '#ffffaf', 230: '#ffffd7', 231: '#ffffff',
      232: '#080808', 233: '#121212', 234: '#1c1c1c', 235: '#262626',
      236: '#303030', 237: '#3a3a3a', 238: '#444444', 239: '#4e4e4e',
      240: '#585858', 241: '#626262', 242: '#6c6c6c', 243: '#767676',
      244: '#808080', 245: '#8a8a8a', 246: '#949494', 247: '#9e9e9e',
      248: '#a8a8a8', 249: '#b2b2b2', 250: '#bcbcbc', 251: '#c6c6c6',
      252: '#d0d0d0', 253: '#dadada', 254: '#e4e4e4', 255: '#eeeeee',
    }
    return get(cterm256, n, '')
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

# ----------------------------------------------------------------------
# Message utilities - send messages to message log
# ----------------------------------------------------------------------

# Using call() with function() is the approved workaround for vararg forwarding.
export def MSG(fmt: string, ...rest: list<any>)
    # if no log dir...
    if !isdirectory(LOG_ROOT)
        # ...then no logging:
        return
    endif

    var logfn = GetMessageLogPath()
    var msg = call('printf', [fmt] + rest)
    writefile(["MESSAGE: " .. msg], logfn, "a")

    # Refresh the message_log.txt buffer in place if it is open,
    # so :DBGShowLog stays live without any polling overhead.
    uf.RefreshMessageLog(logfn)
enddef

export def EMSG(fmt: string, ...rest: list<any>)
    var msg = call(function('printf', [fmt]), rest)
    writefile([msg], '/dev/stderr')
enddef

export def ERR(fmt: string, ...rest: list<any>)
    var msg = call(function('printf', [fmt]), rest)
    writefile(["ERROR: " .. msg], '/dev/stderr')
enddef

# ----------------------------------------------------------------------
# DEBUG utilities with debug level tracing
# ----------------------------------------------------------------------

#this sets the initial active_debug_levels to disabled by default:
var active_debug_levels: dict<bool> = {}

export def SetDebugLevels(spec: string = '', silent: bool = false)
    var trimmed = trim(spec)
    if empty(trimmed)
        var current = keys(active_debug_levels)->map((_, v) => str2nr(v))
        sort(current, 'n')
        if !silent
            echo $"Current DBG levels: {empty(current) ? 'Off (0)' : join(current, ', ')}"
        endif
        return
    endif

    if trimmed == '0'
        active_debug_levels = {}
        if !silent
            echo "DBG mode: Off (all levels disabled)"
        endif
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
    if !silent
        echo $"DBG levels set to: {join(active_list, ', ')}"
    endif
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
# Initialization of DEBUG levels
# ----------------------------------------------------------------------

#set intial debug level from g:set_debug_levels if set during vim startup:
var set_debug_levels = get(g:, 'set_debug_levels', '')
if !empty(set_debug_levels)
    MSG("util.vim: set_debug_levels='%s'", set_debug_levels)
    SetDebugLevels(set_debug_levels, true)
endif

const P = expand('<sfile>:t')
const autoload_dir = expand('<sfile>:h')
var util_globals = printf("%s/%s", autoload_dir, "util_globals.vim")

DBG(1, "%s: uf.GetChatDir()=%s", P, uf.GetChatDir())

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
g:DBG(1, "%s: initialized message log, '%s'", P, GetMessageLogPath())
