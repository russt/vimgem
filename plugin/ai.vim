" Copyright (c) 2025-2026 Russ Tremain.
" Released under the MIT License. See LICENSE file for details.
if !has('vim9script')
   finish
endif
vim9script

# vim-ai-plugin/plugin/ai.vim
# Multi-provider AI plugin with extensible architecture
#
# This file is intentionally thin. All the real logic lives under
# autoload/ai/ split by responsibility (config, provider interface, one
# file per concrete provider, buffer display, prompt processing, and the
# core orchestrator) - see autoload/ai/core.vim for the class that ties
# them together. Adding or editing a single command usually only
# requires touching core.vim and, at most, one provider file.

#this plugin uses vim9script features introduced in 9.1, including abstract classes.
if !has('patch-9.1.0000')
    echohl ErrorMsg
    echomsg "vimgem requires Vim 9.1 or higher. Please upgrade your Vim."
    echohl None
    finish
endif

if !executable('curl')
    echoerr "vim-ai-plugin requires curl to be installed"
    finish
endif

# ============================================================================
# Version Configuration
# ============================================================================
# This line is hardcoded/replaced when the distribution package is created.
if !exists('g:vimgem_version')
    g:vimgem_version = '0.1.260914'
endif

if empty(g:vimgem_version)
    var env_version = getenv('VIMGEM_VERSION')
    if !empty(env_version)
        g:vimgem_version = env_version
    else
        g:vimgem_version = 'NULL'
    endif
endif

import '../autoload/ai/core.vim' as Core
import '../autoload/ai/config.vim' as Cfg
import '../autoload/ai/md.vim' as Md
import '../autoload/ai/md_syntax.vim' as Syntax
import '../autoload/ai/util.vim' as u

#this creates a message at startup, default set in util.vim.  RT 09/07/26
#NOTE Debug levels can be set via g:set_debug_levels in .vimrc.
#u.SetDebugLevels("0")
#debug buffer.vim/_LaunchInBrowser
#u.SetDebugLevels("1,5")

#test DBG messages, imported and legacy global:
u.DBG(7, "HELLO FROM %s, using u.DBG, sfile='%s'", expand('<sfile>:t'), expand('<sfile>'))
g:DBG(1, "HELLO FROM ai.vim, using %s", "g:DBG")

# ============================================================================
# Global Plugin Instance
# ============================================================================
var plugin = Core.AIPlugin.new()

# ============================================================================
# Chat Resume Detection
# ============================================================================
# :AIChat writes its transcript to a real file under g:vimgem_chat_home (see
# AIBuffer.CreateChat) so it survives past the current session - but
# AIChatSend needs both b:ai_chat and b:ai_chat_id set, and reopening a
# saved transcript via :e, netrw, MRU, fzf, etc. wouldn't normally set
# either. This autocmd fixes that: any buffer loaded from a file in the
# chat directory is automatically wired up, so resuming a conversation
# ad-hoc (without :AIChatResume) still works.
#
# Note: buffers opened this way are NOT registered in the ChatSessionInfo
# registry (no provider/model snapshot is taken). The user should use
# :AIChatResume to get a properly registered session. AIChatSend will
# report a clear error if the session is not registered.
def OnChatBufRead()
    plugin.buffer.OnChatFileOpened()
enddef

# Called from BufWipeout for any chat-*.md buffer. Removes the session
# from the ChatSessionInfo registry so stale entries do not accumulate.
# Uses expand('<abuf>') rather than bufnr('%') because at BufWipeout
# time the buffer being wiped is not necessarily the current buffer.
def OnChatBufWipeout()
    var bufnr = str2nr(expand('<abuf>'))
    plugin.config.UnregisterChatSession(bufnr)
enddef

augroup AIChatResume
    autocmd!
    execute $'autocmd BufReadPost {fnameescape(plugin.buffer.ChatDir())}/chat-*.md call OnChatBufRead()'
    execute $'autocmd BufWipeout  {fnameescape(plugin.buffer.ChatDir())}/chat-*.md call OnChatBufWipeout()'
augroup END

# ============================================================================
# Re-highlight on :syntax off / :syntax on
# ============================================================================
# AIBuffer.ApplyMarkdownHighlighting builds our 'aimd' filetype's
# highlighting by hand (see MdSyntaxEmitter) rather than shipping a
# runtime syntax/aimd.vim, since it depends on the buffer's actual
# content (which languages appear in which fenced code blocks). That
# means nothing reapplies it the way Vim normally would for a real
# syntax file: `:syntax off` throws all syntax items away, and
# `:syntax on`/`:syntax enable` afterward only reloads highlighting by
# firing the `Syntax` autocmd event for the buffer's current filetype -
# it doesn't call this plugin's code on its own. This hook is what
# makes that reload actually happen, exactly the way a bundled
# syntax/aimd.vim would if one existed.
def OnAimdSyntax()
    plugin.buffer.ApplyMarkdownHighlighting()
enddef

augroup AIMarkdownSyntax
    autocmd!
    autocmd Syntax aimd call OnAimdSyntax()
augroup END

# ============================================================================
# General Markdown File Handling & Dynamic Syntax Updates
# ============================================================================
# Any .md file opened outside of the chat infrastructure gets the same
# 'aimd' filetype treatment as chat buffers - our AST-driven syntax
# highlighting and \k HTML preview both work on arbitrary markdown files.
# BufWinEnter and BufEnter fire to apply and restore dynamic syntax rules
# when opening files or navigating between buffers.
# BufWritePost re-runs the emitter on save to keep line anchors in sync.
def OnMdBufWinEnter()
    if &filetype !=# 'aimd'
        setlocal filetype=aimd
    endif
    setlocal redrawtime=5000
    plugin.buffer.ApplyMarkdownHighlighting()
enddef

def OnAimdBufRehighlight()
    if &filetype ==# 'aimd'
        plugin.buffer.ApplyMarkdownHighlighting()
    endif
enddef

augroup AIMarkdownFiles
    #clear all autocmds for this group:
    autocmd!
    #refesh on window/buf, buf entry, and write:
    autocmd BufWinEnter,BufEnter *.md call OnMdBufWinEnter()
    autocmd BufWritePost *.md call OnAimdBufRehighlight()
augroup END

# ============================================================================
# Completion Functions
# ============================================================================
def CompleteConfigKeys(argLead: string, cmdLine: string, cursorPos: number): list<string>
    return filter(copy(Cfg.AIConfig.CONFIGURABLE_KEYS), (_, key) => key =~ '^' .. argLead)
enddef

# ============================================================================
# Documentation
# ============================================================================
def OpenVimgemDoc()
    var doc_path = findfile('doc/vimgem.md', &rtp)
    if empty(doc_path)
        echohl ErrorMsg
        echomsg 'vimgem: doc/vimgem.md not found in &runtimepath'
        echohl None
        return
    endif

    execute $'view {fnameescape(doc_path)}'

    setlocal buftype=nofile
    setlocal bufhidden=wipe
    setlocal nobuflisted

    nnoremap <buffer><silent> q <ScriptCmd>close<CR>
enddef

# ============================================================================
# Debug Commands
# ============================================================================
# Developer-facing introspection, kept out of the AI* namespace and
# grouped under a DBG prefix so they read as "not for normal use" at
# a glance. Add future debug helpers here.

# Shows the Markdown AST (see md.vim's MdParser) for the CURRENT
# buffer's content, via MdDebug, in a throwaway scratch buffer. If you
# have multiple chat buffers open, switch to the one you want to
# inspect before running this - it always reads the buffer you're in.
command DBGShowAST plugin.buffer.DisplayText(Md.MdDebug.Dump(Md.MdVim.new().Parse(getline(1, '$'))), 'text')

# Shows the debug message log for the current Vim session. The log file
# is created at startup by util.vim (see GetMessageLogPath / DBG) under
# the vimgem log directory, named debug_<pid>.log. The buffer is named
# 'message_log.txt' to leave room for other message types in future.
# Use :DBGSet to control which debug levels are active.
# DBGColorMd: apply aimd syntax highlighting to the current buffer
# with full tracing. Use this to diagnose why ApplyMarkdownHighlighting
# may not be working for non-chat buffers.
command DBGColorMd call DBGColorMdFunc()
def DBGColorMdFunc()
    u.DBG(7, 'DBGColorMd: start bufnr=%d ft=%s winid=%d', bufnr('%'), &filetype, win_getid())
    var lines = getline(1, '$')
    u.DBG(7, 'DBGColorMd: lines=%d', len(lines))
    var ast = Md.MdVim.new().Parse(lines)
    u.DBG(7, 'DBGColorMd: ast nodes=%d', len(ast))
    var cmds = Syntax.MdSyntaxEmitter.Render(ast)
    u.DBG(7, 'DBGColorMd: cmds=%d', len(cmds))
    var errors = 0
    for cmd in cmds
        try
            execute cmd
        catch
            errors += 1
            u.DBG(7, 'ai.vim: DBGColorMd: %d ERRORS on cmd [%s]: %s', errors, cmd, v:exception)
            if errors <= 3
                u.DBG(7, 'ai.vim: DBGColorMd: %d ERRORS on cmd [%s]: %s', errors, cmd, v:exception)
            endif
        endtry
    endfor
    b:current_syntax = 'aimd'
    u.DBG(7, 'DBGColorMd: done errors=%d b:current_syntax=%s', errors, b:current_syntax)
    u.DBG(7, 'DBGColorMd: aimdH1 check: %s', execute('syntax list aimdH1'))
enddef

command DBGShowLog plugin.ShowLog()

# Shows a human-readable rendering of the JSON chat history for the
# current chat session. Requires jq to be installed. Only valid when
# the current buffer is an active registered chat (opened via :AIChat or
# :AIChatResume). The buffer is named 'json_readable.txt' and is kept
# live after each turn via RefreshJsonHistory - no need to re-run this
# command to see new turns appended.
command DBGShowJson plugin.ShowJsonHistory()
command -nargs=? DBGSet u.SetDebugLevels(<q-args>)

# ============================================================================
# Command Definitions
# ============================================================================
command! -bar VimgemDoc OpenVimgemDoc()
command -nargs=1 AIProvider plugin.SetProvider(<q-args>)
command -nargs=+ AIQuery plugin.Query('AIQuery', <q-args>)
command AIChat plugin.Chat()
command -range=% AIChatSend plugin.ChatSend(<line2>)
command AIChatClear plugin.ChatClear()
command AIChatHistory plugin.ChatHistory()
command -range AIChatDisplay plugin.ChatDisplay(<line1>)
command AIMarkdownDisplay plugin.MarkdownDisplay()
command -range AIChatResume plugin.ChatResume(<line1>)
command -range AIChatDelete plugin.ChatDelete(<line1>)
command -range AIAsk plugin.Ask(getline(<line1>, <line2>))
command AIModels plugin.ShowModels()
command AIInfo plugin.ShowInfo()
command -range -nargs=? AIModel plugin.SetModel(<q-args>, <line1>)
command -range AIExplain plugin.Explain(getline(<line1>, <line2>))
command -range AIReview plugin.Review(getline(<line1>, <line2>))
command AIReviewFile plugin.ReviewFile()
command -nargs=? AIPrompt plugin.SetShowPrompt(<q-args>)
command -nargs=? AIReviewReceived plugin.SetReviewReceived(<q-args>)
command -nargs=? AIUrl plugin.SetBaseUrl(<q-args>)
command -nargs=* -complete=customlist,CompleteConfigKeys AISet plugin.SetConfig(<f-args>)

# ============================================================================
# Default Key Mappings
# ============================================================================
# Set g:ai_no_mappings = 1 (before this file loads) to skip all of these.
# Each one is only defined if the user hasn't already mapped that key
# themselves, so anything set in a vimrc/$VIMINIT always takes precedence.
if get(g:, 'ai_no_mappings', false)
    finish
endif

def MapDefault(mode: string, lhs: string, rhs: string, expr: bool = false)
    if !empty(maparg(lhs, mode))
        return
    endif
    var exprFlag = expr ? '<expr> ' : ''
    execute $'{mode}noremap {exprFlag}{lhs} {rhs}'
enddef

MapDefault('n', '\s', "printf(':.,+%dAIChatSend<CR>', v:count)", true)
MapDefault('v', '\s', ':AIChatSend<CR>')
MapDefault('n', '\c', ':AIChat<CR>')
MapDefault('n', '\r', ':AIChatResume<CR>')
MapDefault('n', '\d', ':AIChatDelete<CR>')
MapDefault('n', '\h', ':AIChatHistory<CR>')
MapDefault('n', '\v', ':AIChatDisplay<CR>')
MapDefault('n', '\k', ':AIMarkdownDisplay<CR>')
MapDefault('n', '\i', ':AIInfo<CR>')
MapDefault('n', '\m', ':AIModel<CR>')
MapDefault('n', '\l', ':AIModels<CR>')
MapDefault('n', '\p', ':AIProvider<Space>')
MapDefault('n', '\w', ':AIReviewReceived<Space>')
MapDefault('n', '\g', ':DBGShowLog<CR>')
MapDefault('n', '\j', ':DBGShowJson<CR>')
