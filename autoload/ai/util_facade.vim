vim9script

# autoload/ai/util_facade.vim
# Facade for classes needed by util.vim.
# Only exports the methods util.vim actually needs, keeping the
# dependency surface minimal and avoiding circular imports
# (util.vim <- util_facade.vim -> buffer.vim -> util.vim would
# be circular if buffer.vim imported util.vim at the top level,
# but vim9script autoload breaks the cycle at load time).

import './buffer.vim' as Buf
import './config.vim' as Cfg

# Single AIBuffer instance for the facade. AIConfig is required by
# AIBuffer.new() but none of its fields are read by the methods
# this facade exposes, so the default-constructed instance is fine.
var buf = Buf.AIBuffer.new(Cfg.AIConfig.new())

export def GetChatDir(): string
    return buf.ChatDir()
enddef

# Refreshes the message_log.txt buffer in place if it is currently
# loaded. Delegates to AIBuffer.RefreshMessageLog - see that method
# for the full contract. Called by Util.DBG() after every writefile()
# so the log buffer stays live without polling.
export def RefreshMessageLog(logfn: string)
    buf.RefreshMessageLog(logfn)
enddef
