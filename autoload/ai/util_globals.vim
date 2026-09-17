" Copyright (c) 2025-2026 Russ Tremain.
" Released under the MIT License. See LICENSE file for details.

" Legacy global shorthand functions
"
" Usage:  g:DBG(99, "hello 99")
"
function! DBG(level, fmt, ...)
    call call('ai#util#DBG', [a:level, a:fmt] + a:000)
endfunction

function! DebugLevelOn(level)
    return ai#util#DebugLevelOn(a:level)
endfunction
