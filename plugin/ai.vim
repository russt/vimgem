if !has('vim9script')
   finish
endif
"use vim9 script only:
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
    g:vimgem_version = '0.1.260817'
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
def OnChatBufRead()
    plugin.buffer.OnChatFileOpened()
enddef

augroup AIChatResume
    autocmd!
    execute $'autocmd BufReadPost {fnameescape(plugin.buffer.ChatDir())}/chat-*.md call OnChatBufRead()'
augroup END

# ============================================================================
# Completion Functions
# ============================================================================
def CompleteConfigKeys(argLead: string, cmdLine: string, cursorPos: number): list<string>
    return filter(copy(Cfg.AIConfig.CONFIGURABLE_KEYS), (_, key) => key =~ '^' .. argLead)
enddef

# ============================================================================
# Command Definitions
# ============================================================================
command -nargs=1 AIProvider plugin.SetProvider(<q-args>)
command -nargs=+ AIQuery plugin.Query('AIQuery', <q-args>)
command AIChat plugin.Chat()
command -range=% AIChatSend plugin.ChatSend(<line2>)
command AIChatClear plugin.ChatClear()
command AIChatHistory plugin.ChatHistory()
command -range AIChatDisplay plugin.ChatDisplay(<line1>)
command -range AIChatResume plugin.ChatResume(<line1>)
command -range AIChatDelete plugin.ChatDelete(<line1>)
command -range AIAsk plugin.Ask(getline(<line1>, <line2>))
command AIModels plugin.ShowModels()
command AIInfo plugin.ShowInfo()
command -range -nargs=? AIModel plugin.SetModel(<q-args>, <line1>)
command -range AIExplain plugin.Explain(getline(<line1>, <line2>))
command -range AIReview plugin.Review(getline(<line1>, <line2>))
command AIReviewFile plugin.ReviewFile()
command -nargs=? AIDebug plugin.SetDebug(<q-args>)
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
MapDefault('n', '\i', ':AIInfo<CR>')
MapDefault('n', '\m', ':AIModel<CR>')
MapDefault('n', '\l', ':AIModels<CR>')
MapDefault('n', '\p', ':AIProvider<Space>')
MapDefault('n', '\w', ':AIReviewReceived<Space>')
