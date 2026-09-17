"use vim9 script only:
vim9script

# autoload/ai/provider.vim
# Abstract Base Provider Class
#
# Defines the interface every concrete provider (Gemini, Claude, OpenAI-
# compatible, or any future one) must implement. AIPlugin and AIConfig
# only ever talk to providers through this interface, so adding a new
# provider never requires touching this file or the orchestrator.

import './config.vim' as Cfg

export abstract class AIProvider
    public var config: Cfg.AIConfig

    # Abstract methods that must be implemented by subclasses
    abstract def IsValid(): bool
    abstract def GetAPIKeyError(): string
    abstract def ListModels(): string
    abstract def GenerateContent(prompt: string): string

    # Multi-turn variant used by :AIChat. Takes the whole conversation so
    # far as an ordered list of {role: 'user'|'assistant', text: string}
    # and returns the model's next reply. Each provider maps 'assistant'
    # to whatever its API calls that role (Gemini: 'model').
    abstract def GenerateChat(messages: list<dict<string>>): string

    abstract def GetCurrentModel(): string
    abstract def SetModel(model: string)

    # Re-pull this provider's model default (if unset) and API key from
    # g:/env, in case they were set or changed after the plugin loaded.
    # Called whenever this provider becomes the active one.
    abstract def RefreshDefaults()

    # Lines describing this provider's current runtime settings (model,
    # api version, key status), shown near the top of :AIInfo for
    # whichever provider is currently active.
    abstract def GetStatusLines(): list<string>

    # Lines showing how to configure this provider via .vimrc / env vars,
    # shown at the bottom of :AIInfo alongside the other config examples.
    abstract def GetConfigLines(): list<string>

    # Does this model name look like it belongs to THIS provider's
    # naming convention? Used to catch "wrong provider" mistakes in
    # :AISetModel without needing a hardcoded provider-name check.
    abstract def IsRecognizedModel(model: string): bool
endclass
