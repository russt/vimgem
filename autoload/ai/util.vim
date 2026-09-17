"use vim9 script only:
vim9script

# autoload/ai/util.vim
# Small stateless helpers shared by more than one provider. Kept separate
# so pulling in a single provider file (e.g. to add a new command) doesn't
# require pulling in unrelated provider code just to get these.

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
# Message utilities, moved here from the old standalone vimmd.vim CLI
# script - md.vim (the parser library) and vimmd.vim (the thin CLI
# wrapper that's left of that script) both use these, as does anything
# else in the plugin that wants a quick stdout/stderr trace.
#
# Using call() with function() is the approved workaround for vararg
# forwarding.
export def MSG(fmt: string, ...rest: list<any>)
    var msg = call(function('printf', [fmt]), rest)
    writefile([msg], '/dev/stdout')
enddef

# same, except to stderr
export def EMSG(fmt: string, ...rest: list<any>)
    var msg = call(function('printf', [fmt]), rest)
    writefile([msg], '/dev/stderr')
enddef

export def ERR(fmt: string, ...rest: list<any>)
    var msg = call(function('printf', [fmt]), rest)
    writefile(["ERROR: " .. msg], '/dev/stderr')
enddef

# Debug tracing. Previously vimmd.vim gated this on a hardcoded local
# DEBUG_ON = 0 that nothing could ever turn on. Now it's gated on the
# same g:debug flag :AIDebug already toggles (see core.vim SetDebug) -
# so `:AIDebug on` also gets you these traces, and there's exactly one
# debug switch for the whole plugin instead of two.
export def DBG(fmt: string, ...rest: list<any>)
    if get(g:, 'debug', 0) != 1
        return
    endif
    var msg = call(function('printf', [fmt]), rest)
    writefile(["DEBUG: " .. msg], '/dev/stderr')
enddef
