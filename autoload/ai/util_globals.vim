" Pure legacy - global shorthand functions

function! DBG(level, fmt, ...)
    call call('ai#util#DBG', [a:level, a:fmt] + a:000)
endfunction

function! DebugLevelOn(level)
    return ai#util#DebugLevelOn(a:level)
endfunction
