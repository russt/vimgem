vim9script

# autoload/ai/prompt_api.vim
# Public facade for AIPrompt.
#
# This is the only file core.vim (or anything else) should import for
# prompt processing. All implementation lives in prompt.vim; only the
# methods explicitly exported here form the public API. Internal methods
# (prefixed with _) are not reachable through this facade.

import './prompt.vim' as Prm

var prompt = Prm.AIPrompt.new()

# Expand all {=...=} read macros in the prompt. Returns the original
# prompt unchanged on any error - check HadError() after calling.
export def ExpandReferences(p: string): string
    return prompt.ExpandReferences(p)
enddef

# Strip any {=>name=} / {=>*=} write directive from the prompt and
# return it alongside routing metadata. Always call this before
# ExpandReferences so write directives are never seen by the model.
export def ExtractWriteTarget(p: string): dict<any>
    return prompt.ExtractWriteTarget(p)
enddef

# True if the last ExpandReferences call failed to resolve a reference.
export def HadError(): bool
    return prompt.had_error
enddef

# The error message from the last failed ExpandReferences call.
export def LastError(): string
    return prompt.last_error
enddef

# Extract the single fenced code block from a write-target response.
# Falls back to the raw response if there isn't exactly one block.
export def ExtractCodeBlock(r: string): string
    return prompt.ExtractCodeBlock(r)
enddef

# Extract every fenced code block from a {=>*=} wildcard response,
# one per output file. Falls back to the whole response as one block.
export def ExtractAllCodeBlocks(r: string): list<string>
    return prompt.ExtractAllCodeBlocks(r)
enddef

# Extract fenced blocks with their [ID: name] round-trip markers for
# routing responses back to named files via {=>*=}.
export def ExtractIdentifiedBlocks(r: string): list<dict<string>>
    return prompt.ExtractIdentifiedBlocks(r)
enddef

# Build the canned "explain this code" prompt for :AIExplain.
export def BuildExplainPrompt(selection: string, filetype: string, filename: string): string
    return prompt.BuildExplainPrompt(selection, filetype, filename)
enddef

# Build the canned "review this code" prompt for :AIReview.
export def BuildReviewPrompt(selection: string, filetype: string, filename: string): string
    return prompt.BuildReviewPrompt(selection, filetype, filename)
enddef
