" Copyright (c) 2025-2026 Russ Tremain.
" Released under the MIT License. See LICENSE file for details.
vim9script

# autoload/ai/md_syntax.vim
#
# MdSyntaxEmitter: renders Vim `:syntax`/`:highlight` Ex-command strings
# that colorize a Markdown buffer - the syntax-highlighting backend that
# parallels md_html.vim's MdHtmlEmitter.
#
# Like MdHtmlEmitter, Render() walks the MdParser AST rather than
# rescanning raw lines. Each block node drives its own constrained rules:
#
#   heading    -> one \%Nl-anchored match for the whole line + level color
#   hr         -> one \%Nl-anchored match
#   paragraph  -> content-aware line-range inline rules (bold/italic/links/code spans)
#                 constrained to the node's line range (\%>Nl\%<Ml)
#   blockquote -> '>' marker match + content-aware inline rules on content range
#   list       -> list-marker match + content-aware inline rules on item range, plus
#                 recursive processing of item.children (e.g. codeblocks)
#   table      -> pipe/cell matches constrained to table line range; the
#                 separator line was consumed by the parser and is simply
#                 left uncolored (no defensive regex needed)
#   codeblock  -> one syntax region per block, line-range constrained via
#                 \%Nl atoms, with :syntax include for the named language;
#                 language syntax files are included once per unique language
#                 to keep syntax trees fast and memory-efficient;
#                 emphasis patterns can't bleed in because regions take
#                 priority over matches
#   turn       -> recurses into children (chat-log wrapper)
#
# Inline rules (bold, italic, links, code spans, strikethrough) mirror
# MdHtmlEmitter._FormatInline's precedence order and use the same
# conservative emphasis rules (no intraword _ emphasis, non-whitespace
# immediately inside markers). Rules are emitted only when matching marker
# characters actually exist in the node's text.
#
# Lang-tag-to-filetype mapping delegates to u.ResolveLang() in util.vim,
# the single source shared with md_html.vim's :TOhtml path.
#
# FindFencedCodeBlocks is kept as a public static utility for callers
# that only have raw lines; Render() uses the AST instead.
#
# Callers execute() every returned string in order against the target
# buffer, then assign b:current_syntax = 'aimd' themselves (bare
# assignment can't be execute()'d from vim9script - E1126).

import './util.vim' as u

export class MdSyntaxEmitter

    # FindFencedCodeBlocks: single pass over raw buffer `lines`, returns
    # one {lang, start, end} per fenced code block, 1-based line numbers,
    # inclusive of both fence lines. Kept as a public utility for callers
    # that only have raw lines; Render() uses the AST instead.
    static def FindFencedCodeBlocks(lines: list<string>): list<dict<any>>
        var blocks: list<dict<any>> = []
        var in_code = false
        var lang = ''
        var start = 0
        var n = len(lines)
        for idx in range(n)
            var line = lines[idx]
            if line =~ '^```'
                if in_code
                    blocks->add({lang: lang, start: start, end: idx + 1})
                    in_code = false
                else
                    in_code = true
                    var tag = tolower(trim(line[3 :]))
                    lang = empty(tag) ? '' : split(tag)[0]
                    start = idx + 1
                endif
            endif
        endfor
        if in_code
            blocks->add({lang: lang, start: start, end: n})
        endif
        return blocks
    enddef

    # _SafeGroupSuffix: sanitizes a lang string into a valid Vim syntax
    # group name fragment ([A-Za-z0-9_] only). Needed because fence tags
    # can contain characters like '+' or '-' (e.g. 'c++', 'objective-c').
    static def _SafeGroupSuffix(lang: string): string
        return substitute(lang, '[^A-Za-z0-9_]', '_', 'g')
    enddef

    # _HighlightGroups: one-time highlight group definitions, independent
    # of buffer content. Emitted once at the top of Render()'s output.
    # Uses 'default' so user colorscheme overrides always win.
    static def _HighlightGroups(): list<string>
        return [
            'syntax case match',
            'highlight default link aimdH1         Title',
            'highlight default link aimdH2         Title',
            'highlight default link aimdH3to6      Title',
            'highlight default link aimdHeaderMark Comment',
            'highlight default      aimdBold       term=bold cterm=bold gui=bold',
            'highlight default      aimdItalic     term=italic cterm=italic gui=italic',
            'highlight default      aimdBoldItalic term=bold,italic cterm=bold,italic gui=bold,italic',
            'highlight default link aimdStrike     Comment',
            'highlight default link aimdCode       String',
            'highlight default link aimdCodeDelim  Comment',
            'highlight default link aimdLink       Underlined',
            'highlight default link aimdLinkText   Underlined',
            'highlight default link aimdLinkDelim  Comment',
            'highlight default link aimdHR         Comment',
            'highlight default link aimdBlockquote Comment',
            'highlight default link aimdListMarker Identifier',
            'highlight default link aimdTablePipe  Special',
            'highlight default link aimdCodeFence  Comment',
            'highlight default link aimdCodeBlock  Normal',
        ]
    enddef

    # _InlineRulesForRange: inline emphasis/link/code-span rules for a
    # range of lines from `start_line` to `end_line` (1-based, inclusive).
    # Content-aware: inspects `raw_text` to only emit rules when corresponding
    # markers exist in the node, avoiding rule bloat on plain prose.
    # Constrained via \%>Nl\%<Ml atoms so one command covers the whole node.
    # Precedence order mirrors MdHtmlEmitter._FormatInline: code spans and
    # links first (regions, so emphasis can't reach in), then bold+italic,
    # bold, italic, strikethrough.
    static def _InlineRulesForRange(start_line: number, end_line: number, raw_text: string): list<string>
        var cmds: list<string> = []
        if empty(raw_text)
            return cmds
        endif

        var l = start_line == end_line
            ? printf('\%%%dl', start_line)
            : printf('\%%>%dl\%%<%dl', start_line - 1, end_line + 1)

        # Inline code spans: only emit if backtick exists
        if raw_text =~ '`'
            cmds->add(printf('syntax region aimdCode matchgroup=aimdCodeDelim'
                .. ' start=/%s`/ end=/`/ oneline', l))
        endif

        # Links / images: only emit if square bracket exists
        if raw_text =~ '\['
            cmds->add(printf('syntax region aimdLink matchgroup=aimdLinkDelim'
                .. ' start=/%s!\?\[/ end=/)/ contains=aimdLinkText oneline', l))
            cmds->add(printf('syntax match aimdLinkText /%s\[\zs[^][]*\ze]/ contained', l))
        endif

        # Bold+italic, bold, italic: only emit if asterisks or underscores exist
        if raw_text =~ '\*'
            cmds->add(printf('syntax match aimdBoldItalic /%s\*\*\*\S\@=[^*]\{-}\S\*\*\*/', l))
            cmds->add(printf('syntax match aimdBold       /%s\*\*\S\@=[^*]\{-}\S\*\*/', l))
            cmds->add(printf('syntax match aimdItalic     /%s\*\S\@=[^*]\{-}\S\*/', l))
        endif

        if raw_text =~ '_'
            cmds->add(printf('syntax match aimdBoldItalic /%s\%%(\w\)\@<!___\S\@=[^_]\{-}\S___\%%(\w\)\@!/', l))
            cmds->add(printf('syntax match aimdBold       /%s\%%(\w\)\@<!__\S\@=[^_]\{-}\S__\%%(\w\)\@!/', l))
            cmds->add(printf('syntax match aimdItalic     /%s\%%(\w\)\@<!_\S\@=[^_]\{-}\S_\%%(\w\)\@!/', l))
        endif

        # Strikethrough: only emit if tilde exists
        if raw_text =~ '\~\~'
            cmds->add(printf('syntax match aimdStrike /%s\~\~[^~]\{-}\~\~/', l))
        endif

        return cmds
    enddef

    # _HeadingRules: colors the full heading line and dims the '#' marks.
    # The heading is always a single line (begin_line == end_line).
    static def _HeadingRules(node: dict<any>): list<string>
        var lnum = node.begin_line
        var group = node.level <= 2 ? printf('aimdH%d', node.level) : 'aimdH3to6'
        return [
            printf('syntax match %s /\%%%dl.*$/', group, lnum),
            printf('syntax match aimdHeaderMark /\%%%dl#\{1,6}\ze\s/'
                .. ' contained containedin=%s', lnum, group),
        ]
    enddef

    # _HRRules: colors the horizontal rule line.
    static def _HRRules(node: dict<any>): list<string>
        return [printf('syntax match aimdHR /\%%%dl.*$/', node.begin_line)]
    enddef

    # _ParagraphRules: applies inline rules once across the node's line range.
    static def _ParagraphRules(node: dict<any>): list<string>
        var text = join(get(node, 'lines', []), ' ')
        return MdSyntaxEmitter._InlineRulesForRange(node.begin_line, node.end_line, text)
    enddef

    # _BlockquoteRules: colors the '>' marker across the line range, then
    # applies inline rules across the line range.
    static def _BlockquoteRules(node: dict<any>): list<string>
        var l = node.begin_line == node.end_line
            ? printf('\%%%dl', node.begin_line)
            : printf('\%%>%dl\%%<%dl', node.begin_line - 1, node.end_line + 1)
        var cmds: list<string> = [
            printf('syntax match aimdBlockquote /%s^\s*>/', l)
        ]
        var texts: list<string> = []
        for child in get(node, 'children', [])
            if has_key(child, 'lines')
                texts += child.lines
            endif
        endfor
        cmds += MdSyntaxEmitter._InlineRulesForRange(node.begin_line, node.end_line, join(texts, ' '))
        return cmds
    enddef

    # _ListRules: colors the list marker (-, *, +, or N.) across the item line
    # range, then applies inline rules across the line range.
    static def _ListRules(node: dict<any>): list<string>
        var l = node.begin_line == node.end_line
            ? printf('\%%%dl', node.begin_line)
            : printf('\%%>%dl\%%<%dl', node.begin_line - 1, node.end_line + 1)
        var cmds: list<string> = [
            printf('syntax match aimdListMarker /%s^\s*\([-*+]\|\d\+\.\)\s\+/', l)
        ]
        var texts: list<string> = []
        for item in get(node, 'items', [])
            if has_key(item, 'text')
                texts->add(item.text)
            endif
        endfor
        cmds += MdSyntaxEmitter._InlineRulesForRange(node.begin_line, node.end_line, join(texts, ' '))
        return cmds
    enddef

    # _TableRules: colors pipe delimiters across the table line range. The
    # separator line (---|---) was consumed by MdParser to build
    # alignments and has no AST node - leaving it uncolored is cleaner
    # than a defensive regex to find it again. Inline rules color cells.
    static def _TableRules(node: dict<any>): list<string>
        var l = node.begin_line == node.end_line
            ? printf('\%%%dl', node.begin_line)
            : printf('\%%>%dl\%%<%dl', node.begin_line - 1, node.end_line + 1)
        var cmds: list<string> = [
            printf('syntax match aimdTablePipe /%s|/', l)
        ]
        var texts: list<string> = copy(get(node, 'header', []))
        for row in get(node, 'rows', [])
            texts += row
        endfor
        cmds += MdSyntaxEmitter._InlineRulesForRange(node.begin_line, node.end_line, join(texts, ' '))
        return cmds
    enddef

    # _CodeBlockRules: one syntax region per codeblock node, line-range
    # constrained via \%Nl so two blocks never bleed into each other.
    # u.ResolveLang() corrects fence tags that differ from Vim filetype
    # names (e.g. 'vim9script' -> 'vim', 'py' -> 'python').
    # Syntax files are included once per unique language across the entire
    # render pass (tracked via `included_langs`) to prevent duplicate cluster
    # definitions and keep screen redraws fast.
    # 'silent!' swallows errors for unknown/misspelled tags.
    # 'keepend' prevents an embedded language's own multi-line regions
    # from growing past this block's closing fence.
    # \%Nl alone anchors to the line; ^ after \%Nl is a literal ^ that
    # breaks the match (fixed from the old buffer-wide approach).
    static def _CodeBlockRules(node: dict<any>, idx: number, included_langs: dict<bool>): list<string>
        var cmds: list<string> = []
        var start = node.begin_line
        var end = node.end_line
        var resolved = u.ResolveLang(node.lang)
        var region = printf('aimdFenced%d', idx)
        var contains = ''

        if !empty(resolved)
            var cluster = printf('aimdLang_%s', MdSyntaxEmitter._SafeGroupSuffix(resolved))
            if !has_key(included_langs, resolved)
                cmds->add(printf('silent! syntax include @%s syntax/%s.vim', cluster, resolved))
                cmds->add('unlet! b:current_syntax')
                included_langs[resolved] = true
            endif
            contains = printf(' contains=@%s', cluster)
        endif

        cmds->add(printf(
            'syntax region %s matchgroup=aimdCodeFence'
            .. ' start=/\%%%dl```/ end=/\%%%dl```/ keepend%s',
            region, start, end, contains))

        if empty(resolved)
            cmds->add(printf('highlight default link %s aimdCodeBlock', region))
        endif

        return cmds
    enddef

    # _RenderNode: dispatches to the appropriate rule-builder for one
    # AST node. Mirrors MdHtmlEmitter._RenderNode's dispatch structure.
    # 'turn' nodes (chat-log wrappers) and 'list' nodes recurse into
    # their children.
    # codeblock_idx is threaded through to give each codeblock region a
    # unique name; returned (incremented) so the caller tracks the count
    # across siblings.
    static def _RenderNode(node: dict<any>, codeblock_idx: number, included_langs: dict<bool>): list<any>
        # Returns [cmds: list<string>, next_codeblock_idx: number]
        var cmds: list<string> = []
        var cb_idx = codeblock_idx

        if node.type == 'heading'
            cmds += MdSyntaxEmitter._HeadingRules(node)
        elseif node.type == 'hr'
            cmds += MdSyntaxEmitter._HRRules(node)
        elseif node.type == 'paragraph'
            cmds += MdSyntaxEmitter._ParagraphRules(node)
        elseif node.type == 'blockquote'
            cmds += MdSyntaxEmitter._BlockquoteRules(node)
        elseif node.type == 'list'
            cmds += MdSyntaxEmitter._ListRules(node)
            var items: list<dict<any>> = get(node, 'items', [])
            for item in items
                if has_key(item, 'children')
                    var children: list<dict<any>> = item.children
                    for child in children
                        var result = MdSyntaxEmitter._RenderNode(child, cb_idx, included_langs)
                        cmds += result[0]
                        cb_idx = result[1]
                    endfor
                endif
            endfor
        elseif node.type == 'table'
            cmds += MdSyntaxEmitter._TableRules(node)
        elseif node.type == 'codeblock'
            cmds += MdSyntaxEmitter._CodeBlockRules(node, cb_idx, included_langs)
            cb_idx += 1
        elseif node.type == 'turn'
            for child in node.children
                var result = MdSyntaxEmitter._RenderNode(child, cb_idx, included_langs)
                cmds += result[0]
                cb_idx = result[1]
            endfor
        endif

        return [cmds, cb_idx]
    enddef

    # Render: walks the MdParser AST and returns the full ordered list of
    # Ex commands to syntax-highlight the buffer. Callers execute() each
    # one in order against the target buffer, then assign:
    #   b:current_syntax = 'aimd'
    # themselves (bare assignment can't be execute()'d from vim9script,
    # E1126). Leads with 'syntax clear' so re-rendering after content
    # changes starts from a clean slate.
    # 'syntax sync fromstart' is placed at the end so foreign included
    # syntax files (e.g. vim.vim, c.vim) cannot override buffer synchronization.
    static def Render(ast: list<dict<any>>): list<string>
        var cmds: list<string> = [
            'silent! syntax clear',
            'unlet! b:current_syntax',
        ]
        cmds += MdSyntaxEmitter._HighlightGroups()

        var included_langs: dict<bool> = {}
        var cb_idx = 0
        for node in ast
            var result = MdSyntaxEmitter._RenderNode(node, cb_idx, included_langs)
            cmds += result[0]
            cb_idx = result[1]
        endfor

        cmds->add('syntax sync fromstart')
        return cmds
    enddef

endclass
