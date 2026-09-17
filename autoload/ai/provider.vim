" Copyright (c) 2025-2026 Russ Tremain.
" Released under the MIT License. See LICENSE file for details.
vim9script

# autoload/ai/provider.vim
# Abstract Base Provider Class
#
# Defines the interface every concrete provider (Gemini, Claude, OpenAI-
# compatible, or any future one) must implement. AIPlugin and AIConfig
# only ever talk to providers through this interface, so adding a new
# provider never requires touching this file or the orchestrator.
#
# Design note on chat_id parameter:
#   GenerateContent and GenerateChat both receive a chat_id string.
#   Providers use this to look up their per-chat model and api_version
#   via this.config.GetChatSessionModel(chat_id) and
#   this.config.GetChatSessionApiVersion(chat_id), rather than reading
#   from the shared global config fields. This means a global
#   :AIProvider / :AIModel change does not silently affect in-flight
#   chats. For one-shot commands (:AIQuery, :AIExplain, :AIReview,
#   :AIReviewFile) that have no chat buffer, chat_id is passed as ''
#   and providers fall back to the global config model.
#
# Return value convention for GenerateContent and GenerateChat:
#   Both return a dict<any> with well-defined keys, never a plain string.
#   This avoids the fragile pattern of grepping response text for error
#   or warning signals, which breaks when source code is the content.
#
#   Success:   {ok: true,  text: 'response text'}
#   Truncated: {ok: true,  text: 'partial text', truncated: true}
#   Error:     {ok: false, error: 'description'}
#
#   core.vim unwraps this dict and never inspects .text for signals.
#
# Removed from this interface (compared to earlier versions):
#   SetModel()        - nuked. Model selection is a config/session concern
#                       managed by AIPlugin. Providers never write to config.
#   RefreshDefaults() - nuked. Was only needed to re-sync after SetModel
#                       side effects. With immutable provider state those
#                       side effects no longer exist.
#   GetCurrentModel() - renamed to GetDefaultModel() to make clear it
#                       returns the global default, not a per-chat value.

import './config.vim' as Cfg

export abstract class AIProvider
    public var config: Cfg.AIConfig

    # Abstract methods that must be implemented by subclasses
    abstract def IsValid(): bool
    abstract def GetAPIKeyError(): string
    abstract def ListModels(): string

    # One-shot prompt -> response. chat_id is '' for non-chat commands;
    # providers fall back to global config model when chat_id is empty.
    # Returns dict<any>: {ok: true, text: ...} or {ok: false, error: ...}
    # or {ok: true, text: ..., truncated: true}.
    abstract def GenerateContent(prompt: string, chat_id: string): dict<any>

    # Multi-turn variant used by :AIChat. Takes the whole conversation so
    # far as an ordered list of {role: 'user'|'assistant', text: string}
    # and returns the model's next reply. Each provider maps 'assistant'
    # to whatever its API calls that role (Gemini: 'model').
    # chat_id is always non-empty here; providers read their per-chat
    # model and api_version from the session registry via config.
    # Returns dict<any>: {ok: true, text: ...} or {ok: false, error: ...}
    # or {ok: true, text: ..., truncated: true}.
    abstract def GenerateChat(messages: list<dict<string>>, chat_id: string): dict<any>

    # Returns the global default model for this provider (from config).
    # Used for display in :AIInfo, :AIModels, and confirmation messages.
    # This is NOT the per-chat model - use
    # config.GetChatSessionModel(chat_id) for that.
    abstract def GetDefaultModel(): string

    # Lines describing this provider's current runtime settings (model,
    # api version, key status), shown near the top of :AIInfo for
    # whichever provider is currently active.
    abstract def GetStatusLines(): list<string>

    # Lines showing how to configure this provider via .vimrc / env vars,
    # shown at the bottom of :AIInfo alongside the other config examples.
    abstract def GetConfigLines(): list<string>

    # Does this model name look like it belongs to THIS provider's
    # naming convention? Used to catch "wrong provider" mistakes in
    # :AIModel without needing a hardcoded provider-name check.
    abstract def IsRecognizedModel(model: string): bool
endclass
