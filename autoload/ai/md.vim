"use vim9 script only:
vim9script

# autoload/ai/md.vim
#
# Split out of the old standalone `vimmd.vim` CLI script: this file keeps
# only the parser/emitter classes, with no top-level side effects, so it's
# safe to `import` from core.vim/buffer.vim. (Importing the old file as-is
# would have been unsafe - it unconditionally parsed v:argv and ended with
# qall!, which would have quit the user's running Vim session.)
#
# The standalone CLI tool (md.vim <file>, md.vim --ast <file>) lives on as
# vimmd.vim, now a thin wrapper that imports the classes below - see that
# file for the CLI entry point. MSG()/EMSG()/ERR()/DBG() moved to util.vim,
# shared with the rest of the plugin.

import './util.vim' as Util

# md.vim: A GitHub-Flavored-Markdown-ish parser, split into two stages:
#
#   MdParser       lines -> AST (a list<dict<any>> of typed block nodes)
#   MdHtmlEmitter   AST  -> HTML lines
#
# Keeping these separate means a future backend - e.g. a "Vim :syntax
# region" emitter for markdown syntax highlighting - can walk the same
# AST without touching the parsing logic at all.
#
# Usage:
#   var html_lines = MdVim.new().ParseMarkdown(markdown_lines)
#   " or, to get at the AST directly:
#   var ast = MdParser.new().Parse(markdown_lines)
#   var html_lines = MdHtmlEmitter.Render(ast)
#
# ---------------------------------------------------------------------
# AST node shapes (all nodes are dict<any>, tagged by a 'type' key):
#   {type: 'heading', level: number, text: string}
#   {type: 'paragraph', lines: list<string>}
#   {type: 'hr'}
#   {type: 'codeblock', lang: string, lines: list<string>}
#   {type: 'htmlblock', lines: list<string>}
#   {type: 'blockquote', children: list<dict<any>>}
#       children are {type: 'paragraph', lines: [text]}
#              or    {type: 'blockquote', children: [...]}  (one level deep)
#   {type: 'table', alignments: list<string>, header: list<string>,
#    rows: list<list<string>>}
#   {type: 'list', ordered: bool, items: list<dict<any>>}
#       item: {text: string, checked: bool (optional),
#              children: list<dict<any>> (optional, nested 'list' nodes)}
# 'text'/'lines' fields hold RAW markdown - inline formatting (bold,
# links, code spans, ...) is applied later, by the emitter.
# ---------------------------------------------------------------------

# MdParser: turns markdown lines into a block-level AST. Does no inline
# formatting and produces no HTML - it only recognizes block structure.
export class MdParser

    var nodes: list<dict<any>> = []

    var in_code: bool = false
    var code_lang: string = ''
    var code_lines: list<string> = []

    var in_indented_code: bool = false
    var indented_code_lines: list<string> = []

    var p_lines: list<string> = []

    # Raw HTML block state (CommonMark-style: a line starting with a
    # block-level HTML tag is captured verbatim, unparsed, until a
    # terminating condition - a blank line for most tags, or a matching
    # closing tag for pre/script/style/textarea).
    var in_html_block: bool = false
    var html_block_end_tag: string = ''
    var html_block_lines: list<string> = []

    var bq_node: dict<any> = {}
    var in_bq: bool = false

    var in_table: bool = false
    var table_alignments: list<string> = []
    var table_node: dict<any> = {}

    # Stack of currently-open list levels while parsing:
    # {node: <list node dict>, indent: number, container: <list<dict> this
    # list node was appended into, so a same-depth type switch can insert
    # a sibling in the right place>}.
    var list_stack: list<dict<any>> = []

    # ---- Static parsing helpers (no instance state) ------------------

    # _ParseTableAlignments: Determines table column alignments from the
    # header separator row (e.g. '| :--- | :---: | ---: |').
    static def _ParseTableAlignments(sep_line: string): list<string>
        var alignments: list<string> = []
        for c in split(sep_line, '|')
            var cell = trim(c)
            if cell =~ '^:.*:$'
                alignments->add(' style="text-align: center;"')
            elseif cell =~ ':$'
                alignments->add(' style="text-align: right;"')
            elseif cell =~ '^:'
                alignments->add(' style="text-align: left;"')
            else
                alignments->add('')
            endif
        endfor
        return alignments
    enddef

    # _SplitRow: Splits a table row into trimmed raw cell texts.
    static def _SplitRow(row: string): list<string>
        var raw_cells = split(row, '|', true)
        if len(raw_cells) > 0 && empty(trim(raw_cells[0]))
            raw_cells->remove(0)
        endif
        if len(raw_cells) > 0 && empty(trim(raw_cells[-1]))
            raw_cells->remove(-1)
        endif
        var cells: list<string> = []
        for c in raw_cells
            cells->add(trim(c))
        endfor
        return cells
    enddef

    # _HtmlBlockStartTag: If `line` starts a CommonMark-style raw HTML
    # block, returns the lowercased tag name; otherwise returns ''.
    # Only lines beginning (after up to 3 spaces) with '<tagname' or
    # '</tagname' for a recognized block-level tag qualify - this keeps
    # inline constructs like autolinks ('<https://...>') from matching.
    static def _HtmlBlockStartTag(line: string): string
        var m = matchlist(line, '^\s\{0,3\}<\/\?\([A-Za-z][A-Za-z0-9-]*\)\(\s\|/\?>\|$\)')
        if empty(m)
            return ''
        endif
        var tag = tolower(m[1])
        var block_tags = ['address', 'article', 'aside', 'base', 'basefont',
            \ 'blockquote', 'body', 'caption', 'center', 'col', 'colgroup',
            \ 'dd', 'details', 'dialog', 'dir', 'div', 'dl', 'dt', 'fieldset',
            \ 'figcaption', 'figure', 'footer', 'form', 'frame', 'frameset',
            \ 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'head', 'header', 'hr',
            \ 'html', 'iframe', 'legend', 'li', 'link', 'main', 'menu',
            \ 'menuitem', 'nav', 'noframes', 'ol', 'optgroup', 'option', 'p',
            \ 'param', 'section', 'summary', 'table', 'tbody', 'td', 'tfoot',
            \ 'th', 'thead', 'title', 'tr', 'track', 'ul',
            \ 'pre', 'script', 'style', 'textarea']
        return index(block_tags, tag) >= 0 ? tag : ''
    enddef

    # ---- Instance flush / close helpers -------------------------------

    def _FlushParagraph()
        if !empty(this.p_lines)
            this.nodes->add({type: 'paragraph', lines: this.p_lines})
            this.p_lines = []
        endif
    enddef

    def _FlushIndentedCode()
        if this.in_indented_code
            if !empty(this.indented_code_lines)
                this.nodes->add({type: 'codeblock', lang: '', lines: this.indented_code_lines})
            endif
            this.in_indented_code = false
            this.indented_code_lines = []
        endif
    enddef

    def _FlushFencedCode()
        if this.in_code
            this.nodes->add({type: 'codeblock', lang: this.code_lang, lines: this.code_lines})
            this.in_code = false
            this.code_lines = []
        endif
    enddef

    def _CloseBlocks(except_type: string = '')
        if except_type != 'paragraph'
            this._FlushParagraph()
        endif
        if except_type != 'indented_code'
            this._FlushIndentedCode()
        endif
        if except_type != 'list'
            this.list_stack = []
        endif
        if except_type != 'bq' && this.in_bq
            this.in_bq = false
            this.bq_node = {}
        endif
        if except_type != 'table' && this.in_table
            this.in_table = false
            this.table_alignments = []
            this.table_node = {}
        endif
    enddef

    # _OpenListLevel: Opens a new nested list level (deeper indent), or
    # switches list type (ul<->ol) at the current depth, attaching the
    # new list node in the right place. `container` is the list<dict>
    # to append the new list node into - the caller computes this,
    # since "going deeper" (nest under the parent's last item) and
    # "switching type at the same depth" (reuse the same slot the old
    # list occupied) need different containers.
    def _OpenListLevel(list_type: string, indent_level: number, container: list<dict<any>>)
        var new_node = {type: 'list', ordered: list_type == 'ol', items: []}
        container->add(new_node)
        this.list_stack->add({node: new_node, indent: indent_level, container: container})
    enddef

    # _NestedContainer: Returns the children-list of the current
    # top-of-stack list's most recent item, creating it if needed. This
    # is where a deeper nested sublist attaches.
    def _NestedContainer(): list<dict<any>>
        var parent_items: list<dict<any>> = this.list_stack[-1].node.items
        if empty(parent_items)
            # Defensive: a sublist normally follows a preceding item at
            # the parent level. Malformed input (a jump straight to a
            # deeper indent) gets a synthetic empty parent item instead
            # of crashing.
            parent_items->add({text: ''})
        endif
        var parent_item = parent_items[-1]
        if !has_key(parent_item, 'children')
            parent_item.children = []
        endif
        return parent_item.children
    enddef

    # Public entry point ------------------------------------------------

    # Parse: Resets internal state and builds a block-level AST for
    # `lines`. The parser instance may be reused across calls.
    def Parse(lines: list<string>): list<dict<any>>
        this.nodes = []
        this.in_code = false
        this.code_lang = ''
        this.code_lines = []
        this.in_indented_code = false
        this.indented_code_lines = []
        this.p_lines = []
        this.in_html_block = false
        this.html_block_end_tag = ''
        this.html_block_lines = []
        this.bq_node = {}
        this.in_bq = false
        this.in_table = false
        this.table_alignments = []
        this.table_node = {}
        this.list_stack = []

        var i = 0
        var n = len(lines)

        while i < n
            var line = lines[i]

            # Fenced code block handling (```)
            if line =~ '^```'
                if this.in_code
                    this._FlushFencedCode()
                else
                    this._CloseBlocks('')
                    this.code_lang = trim(line[3 :])
                    this.in_code = true
                    this.code_lines = []
                endif
                i += 1
                continue
            endif

            if this.in_code
                this.code_lines->add(line)
                i += 1
                continue
            endif

            # Recovery valve: an ATX heading always ends a "soft"
            # (blank-line-terminated) raw HTML block. This bounds how far
            # a misdetected or malformed HTML block can propagate - at
            # worst it swallows content up to the next heading, matching
            # how real Markdown parsers resynchronize on heading lines.
            # "Hard" blocks (pre/script/style/textarea, which have an
            # explicit closing tag) are left untouched, since interrupting
            # genuine code/script content because it contains a '#' line
            # would be wrong.
            if this.in_html_block && empty(this.html_block_end_tag) && line =~ '^#\{1,6\}\s\+'
                this.in_html_block = false
                this.nodes->add({type: 'htmlblock', lines: this.html_block_lines})
                this.html_block_lines = []
            endif

            # Raw HTML block continuation: capture lines verbatim,
            # completely bypassing Markdown parsing, until the block ends.
            if this.in_html_block
                if !empty(this.html_block_end_tag)
                    this.html_block_lines->add(line)
                    if line =~? this.html_block_end_tag
                        this.in_html_block = false
                        this.html_block_end_tag = ''
                        this.nodes->add({type: 'htmlblock', lines: this.html_block_lines})
                        this.html_block_lines = []
                    endif
                else
                    if line =~ '^\s*$'
                        this.in_html_block = false
                        this.nodes->add({type: 'htmlblock', lines: this.html_block_lines})
                        this.html_block_lines = []
                    else
                        this.html_block_lines->add(line)
                    endif
                endif
                i += 1
                continue
            endif

            # Blank lines reset active block elements
            if line =~ '^\s*$'
                this._CloseBlocks('')
                i += 1
                continue
            endif

            # Raw HTML block start: a line beginning with a recognized
            # block-level HTML tag is captured verbatim and further
            # parsing is suspended until the block's terminating
            # condition (see MdParser._HtmlBlockStartTag).
            var html_tag = MdParser._HtmlBlockStartTag(line)
            if !empty(html_tag)
                this._CloseBlocks('')
                this.html_block_lines = [line]
                if index(['pre', 'script', 'style', 'textarea'], html_tag) >= 0
                    var close_tag = '</' .. html_tag .. '>'
                    if line =~? close_tag
                        this.nodes->add({type: 'htmlblock', lines: this.html_block_lines})
                        this.html_block_lines = []
                    else
                        this.in_html_block = true
                        this.html_block_end_tag = close_tag
                    endif
                else
                    this.in_html_block = true
                    this.html_block_end_tag = ''
                endif
                i += 1
                continue
            endif

            # Horizontal Rules (---, ***, ___)
            if line =~ '^\s*\([*_-]\s*\)\{3,\}\s*$'
                this._CloseBlocks('')
                this.nodes->add({type: 'hr'})
                i += 1
                continue
            endif

            # Setext Headers (Alt-H1 = / Alt-H2 -)
            if i + 1 < n && !empty(trim(line)) && lines[i + 1] =~ '^\s*=\{3,\}\s*$'
                this._CloseBlocks('')
                this.nodes->add({type: 'heading', level: 1, text: trim(line)})
                i += 2
                continue
            elseif i + 1 < n && !empty(trim(line)) && line !~ '^\s*[-*+]\s\+' && lines[i + 1] =~ '^\s*-\{3,\}\s*$'
                this._CloseBlocks('')
                this.nodes->add({type: 'heading', level: 2, text: trim(line)})
                i += 2
                continue
            endif

            # ATX Headers (# to ######)
            if line =~ '^#\{1,6\}\s\+'
                this._CloseBlocks('')
                var level = len(matchstr(line, '^#\+'))
                var heading_text = substitute(line, '^#\+\s*', '', '')
                this.nodes->add({type: 'heading', level: level, text: trim(heading_text)})
                i += 1
                continue
            endif

            # Blockquotes (> line)
            if line =~ '^\s*>\s*'
                this._CloseBlocks('bq')
                if !this.in_bq
                    this.bq_node = {type: 'blockquote', children: []}
                    this.nodes->add(this.bq_node)
                    this.in_bq = true
                endif
                var bq_text = substitute(line, '^\s*>\s*', '', '')
                if bq_text =~ '^\s*>\s*'
                    var nested_text = substitute(bq_text, '^\s*>\s*', '', '')
                    this.bq_node.children->add({type: 'blockquote',
                        \ children: [{type: 'paragraph', lines: [nested_text]}]})
                elseif !empty(trim(bq_text))
                    this.bq_node.children->add({type: 'paragraph', lines: [bq_text]})
                endif
                i += 1
                continue
            endif

            # Tables (| Header | Header | ...)
            if line =~ '^\s*|.*|\s*$'
                if !this.in_table && i + 1 < n && lines[i + 1] =~ '^\s*|[: -|]\+|\s*$' && lines[i + 1] =~ '-'
                    this._CloseBlocks('table')
                    this.in_table = true
                    this.table_alignments = MdParser._ParseTableAlignments(lines[i + 1])
                    this.table_node = {type: 'table', alignments: this.table_alignments,
                        \ header: MdParser._SplitRow(line), rows: []}
                    this.nodes->add(this.table_node)
                    i += 2
                    continue
                elseif this.in_table
                    this.table_node.rows->add(MdParser._SplitRow(line))
                    i += 1
                    continue
                endif
            endif

            # Nested List Items (Unordered [-*+], Ordered [0-9.], Task Lists)
            var is_ul = line =~ '^\s*[-*+]\s\+'
            var is_ol = line =~ '^\s*\d\+\.\s\+'

            if is_ul || is_ol
                this._CloseBlocks('list')
                var list_type = is_ul ? 'ul' : 'ol'
                var indent_str = matchstr(line, '^\s*')
                var indent_level = 0
                for char in split(indent_str, '\zs')
                    indent_level += (char == "\t" ? 4 : 1)
                endfor

                # Close deeper levels when indentation decreases
                while !empty(this.list_stack) && this.list_stack[-1].indent > indent_level
                    this.list_stack->remove(-1)
                endwhile

                # Open new nested list level or switch list type
                if empty(this.list_stack)
                    this._OpenListLevel(list_type, indent_level, this.nodes)
                elseif this.list_stack[-1].indent < indent_level
                    this._OpenListLevel(list_type, indent_level, this._NestedContainer())
                elseif this.list_stack[-1].indent == indent_level
                        \ && (this.list_stack[-1].node.ordered != (list_type == 'ol'))
                    var container = this.list_stack[-1].container
                    this.list_stack->remove(-1)
                    this._OpenListLevel(list_type, indent_level, container)
                endif

                # Parse item text and record checkbox state
                var item_text = is_ul ? substitute(line, '^\s*[-*+]\s\+', '', '') : substitute(line, '^\s*\d\+\.\s\+', '', '')
                var item: dict<any> = {}
                if is_ul && item_text =~ '^\[[ xX]\]\s\+'
                    item.checked = item_text =~ '^\[[xX]\]'
                    item_text = substitute(item_text, '^\[[ xX]\]\s\+', '', '')
                endif
                item.text = item_text
                this.list_stack[-1].node.items->add(item)
                i += 1
                continue
            endif

            # Indented Code Block (4 spaces or tab)
            if line =~ '^\(\s\{4\}\|\t\)'
                this._CloseBlocks('indented_code')
                this.in_indented_code = true
                var code_line = substitute(line, '^\(\s\{4\}\|\t\)', '', '')
                this.indented_code_lines->add(code_line)
                i += 1
                continue
            endif

            # Default Paragraph Line
            this._CloseBlocks('paragraph')
            this.p_lines->add(line)
            i += 1
        endwhile

        # Final cleanup of remaining open blocks
        this._FlushFencedCode()
        if this.in_html_block && !empty(this.html_block_lines)
            this.nodes->add({type: 'htmlblock', lines: this.html_block_lines})
        endif
        this._CloseBlocks('')

        return this.nodes
    enddef

endclass

# MdHtmlEmitter: renders an MdParser AST to HTML lines. Stateless -
# every method is static, so no instance is needed.
export class MdHtmlEmitter

    # ---- HTML-escaping and inline shielding helpers -------------------

    # _EscapeHtml: Escapes &, <, > as HTML entities. Order matters: &
    # must be escaped first, or it would double-escape the ampersands
    # introduced by the '<' and '>' replacements.
    static def _EscapeHtml(text: string): string
        var res = substitute(text, '&', '\&amp;', 'g')
        res = substitute(res, '<', '\&lt;', 'g')
        res = substitute(res, '>', '\&gt;', 'g')
        return res
    enddef

    # _Stash: Records a finished HTML fragment and returns an opaque
    # placeholder token to splice into the text in its place, so later
    # regex passes (emphasis, etc.) can't see or corrupt it. Tokens use
    # \x01/\x02, which can't appear in Markdown source text and - unlike
    # \x00 - survive Vim's readfile()/writefile() round-trip unchanged.
    static def _Stash(stash: list<string>, html: string): string
        var token = "\x01" .. len(stash) .. "\x02"
        stash->add(html)
        return token
    enddef

    static def _CodeHtml(content: string): string
        return '<code>' .. MdHtmlEmitter._EscapeHtml(content) .. '</code>'
    enddef

    static def _LinkHtml(text: string, href: string): string
        return '<a href="' .. href .. '">' .. text .. '</a>'
    enddef

    static def _ImageHtml(alt: string, src: string, title: string): string
        return '<img src="' .. src .. '" alt="' .. alt .. '" title="' .. title .. '" />'
    enddef

    static def _ImageHtmlNoTitle(alt: string, src: string): string
        return '<img src="' .. src .. '" alt="' .. alt .. '" />'
    enddef

    # _FormatInline: Renders one line of raw Markdown text to HTML
    # (bold, italic, strikethrough, code spans, links, images, hard
    # breaks). Code spans, links and images are extracted and stashed
    # (see _Stash) before emphasis is applied, so emphasis markers can
    # never reach into - and corrupt - HTML this function already built.
    #
    # Emphasis matching here is deliberately narrower than full
    # CommonMark:
    #  - '*'/'_' emphasis requires non-whitespace immediately inside the
    #    markers, so e.g. pointer dereferences like '*a = *b;' don't get
    #    misread as italics.
    #  - '_' emphasis additionally requires a real word boundary outside
    #    the markers, so identifiers like 'this_type_of_variable' or
    #    '_private_field' are left alone. (This is CommonMark's own
    #    "no intraword underscore emphasis" rule.)
    # This is not the full delimiter-flanking algorithm from the spec,
    # so a rare pathological case - two separate word-boundary-legal
    # underscored identifiers in the same paragraph - could still
    # false-pair. Wrapping identifiers in backticks avoids this entirely.
    static def _FormatInline(text: string): string
        var has_hard_break = text =~ '  $'
        var res = has_hard_break ? substitute(text, '  $', '', '') : text

        var stash: list<string> = []

        # Inline code
        res = substitute(res, '`\(.\{-}\)`',
            \ '\=MdHtmlEmitter._Stash(stash, MdHtmlEmitter._CodeHtml(submatch(1)))', 'g')
        # Images with title
        res = substitute(res, '!\+\[\(.\{-}\)\](\(.\{-}\)\s\+"\(.\{-}\)")',
            \ '\=MdHtmlEmitter._Stash(stash, MdHtmlEmitter._ImageHtml(submatch(1), submatch(2), submatch(3)))', 'g')
        # Images without title
        res = substitute(res, '!\+\[\(.\{-}\)\](\(.\{-}\))',
            \ '\=MdHtmlEmitter._Stash(stash, MdHtmlEmitter._ImageHtmlNoTitle(submatch(1), submatch(2)))', 'g')
        # Links
        res = substitute(res, '\[\(.\{-}\)\](\(.\{-}\))',
            \ '\=MdHtmlEmitter._Stash(stash, MdHtmlEmitter._LinkHtml(submatch(1), submatch(2)))', 'g')

        # Bold+Italic (*** ... ***): no whitespace immediately inside markers
        res = substitute(res, '\*\*\*\%(\S\)\@=\([^*]\{-}\S\)\*\*\*', '<strong><em>\1</em></strong>', 'g')
        # Bold+Italic (___ ... ___): also requires word boundaries outside
        res = substitute(res,
            \ '\%([0-9A-Za-z_]\)\@<!___\%(\S\)\@=\([^_]\{-}\S\)___\%([0-9A-Za-z_]\)\@!',
            \ '<strong><em>\1</em></strong>', 'g')
        # Bold (** ... **)
        res = substitute(res, '\*\*\%(\S\)\@=\([^*]\{-}\S\)\*\*', '<strong>\1</strong>', 'g')
        # Bold (__ ... __): word boundaries outside
        res = substitute(res,
            \ '\%([0-9A-Za-z_]\)\@<!__\%(\S\)\@=\([^_]\{-}\S\)__\%([0-9A-Za-z_]\)\@!',
            \ '<strong>\1</strong>', 'g')
        # Italic (* ... *)
        res = substitute(res, '\*\%(\S\)\@=\([^*]\{-}\S\)\*', '<em>\1</em>', 'g')
        # Italic (_ ... _): word boundaries outside
        res = substitute(res,
            \ '\%([0-9A-Za-z_]\)\@<!_\%(\S\)\@=\([^_]\{-}\S\)_\%([0-9A-Za-z_]\)\@!',
            \ '<em>\1</em>', 'g')
        # Strikethrough
        res = substitute(res, '\~\~\(.\{-}\)\~\~', '<del>\1</del>', 'g')

        # Unshield: splice the stashed HTML fragments back in. Uses \=
        # expression-replacement so stashed content is inserted literally,
        # with no reinterpretation of & or \ inside it.
        for idx in range(len(stash))
            res = substitute(res, "\x01" .. idx .. "\x02", '\=stash[idx]', '')
        endfor

        if has_hard_break
            res ..= '<br />'
        endif
        return res
    enddef

    # ---- Block renderers ------------------------------------------------

    static def _RenderParagraphLines(lines: list<string>): string
        var formatted: list<string> = []
        for line in lines
            formatted->add(MdHtmlEmitter._FormatInline(line))
        endfor
        return '<p>' .. join(formatted, ' ') .. '</p>'
    enddef

    static def _RenderCodeBlock(node: dict<any>): list<string>
        var lines: list<string> = node.lines
        var lang_attr = empty(node.lang) ? '' : printf(' class="language-%s"', node.lang)
        var escaped_lines: list<string> = []
        for c_line in lines
            escaped_lines->add(MdHtmlEmitter._EscapeHtml(c_line))
        endfor
        if empty(escaped_lines)
            return [printf('<pre><code%s></code></pre>', lang_attr)]
        elseif len(escaped_lines) == 1
            return [printf('<pre><code%s>%s</code></pre>', lang_attr, escaped_lines[0])]
        endif
        var out = [printf('<pre><code%s>%s', lang_attr, escaped_lines[0])]
        for idx in range(1, len(escaped_lines) - 2)
            out->add(escaped_lines[idx])
        endfor
        out->add(escaped_lines[-1] .. '</code></pre>')
        return out
    enddef

    static def _RenderBlockquote(node: dict<any>): list<string>
        var out = ['<blockquote>']
        for child in node.children
            if child.type == 'blockquote'
                out->add('<blockquote>')
                for gc in child.children
                    out->add(MdHtmlEmitter._RenderParagraphLines(gc.lines))
                endfor
                out->add('</blockquote>')
            else
                out->add(MdHtmlEmitter._RenderParagraphLines(child.lines))
            endif
        endfor
        out->add('</blockquote>')
        return out
    enddef

    static def _RenderTable(node: dict<any>): list<string>
        var alignments: list<string> = node.alignments
        var out = ['<table><thead><tr>']
        var header: list<string> = node.header
        for idx in range(len(header))
            var align_attr = idx < len(alignments) ? alignments[idx] : ''
            out->add(printf('<th%s>%s</th>', align_attr, MdHtmlEmitter._FormatInline(header[idx])))
        endfor
        out->add('</tr></thead><tbody>')
        var rows: list<list<string>> = node.rows
        for row in rows
            out->add('<tr>')
            for idx in range(len(row))
                var align_attr = idx < len(alignments) ? alignments[idx] : ''
                out->add(printf('<td%s>%s</td>', align_attr, MdHtmlEmitter._FormatInline(row[idx])))
            endfor
            out->add('</tr>')
        endfor
        out->add('</tbody></table>')
        return out
    enddef

    # _RenderList: Recursively renders a (possibly nested) list node.
    # Matches this parser's existing HTML shape: a nested list is
    # emitted as a sibling immediately following its parent <li>...</li>
    # line, not wrapped inside it. (Real GFM nests the <ul> inside the
    # <li>; this preserves the previously-verified output shape rather
    # than changing list structure as a side effect of this refactor.)
    static def _RenderList(node: dict<any>, depth: number): list<string>
        var tag = node.ordered ? 'ol' : 'ul'
        var prefix = repeat('  ', depth)
        var out = [prefix .. '<' .. tag .. '>']
        var item_prefix = repeat('  ', depth + 1)
        var items: list<dict<any>> = node.items
        for item in items
            var formatted_text = MdHtmlEmitter._FormatInline(item.text)
            if has_key(item, 'checked')
                var checked_attr = item.checked ? ' checked=""' : ''
                out->add(printf('%s<li><input type="checkbox"%s disabled="" /> %s</li>',
                    \ item_prefix, checked_attr, formatted_text))
            else
                out->add(item_prefix .. '<li>' .. formatted_text .. '</li>')
            endif
            if has_key(item, 'children')
                var children: list<dict<any>> = item.children
                for child in children
                    out += MdHtmlEmitter._RenderList(child, depth + 1)
                endfor
            endif
        endfor
        out->add(prefix .. '</' .. tag .. '>')
        return out
    enddef

    # ---- Public entry point -------------------------------------------

    # Render: Walks an MdParser AST and returns the equivalent HTML lines.
    static def Render(nodes: list<dict<any>>): list<string>
        var html: list<string> = []
        for node in nodes
            if node.type == 'paragraph'
                html->add(MdHtmlEmitter._RenderParagraphLines(node.lines))
            elseif node.type == 'heading'
                var level: number = node.level
                html->add(printf('<h%d>%s</h%d>', level, MdHtmlEmitter._FormatInline(node.text), level))
            elseif node.type == 'hr'
                html->add('<hr />')
            elseif node.type == 'codeblock'
                html += MdHtmlEmitter._RenderCodeBlock(node)
            elseif node.type == 'htmlblock'
                var lines: list<string> = node.lines
                html += lines
            elseif node.type == 'blockquote'
                html += MdHtmlEmitter._RenderBlockquote(node)
            elseif node.type == 'table'
                html += MdHtmlEmitter._RenderTable(node)
            elseif node.type == 'list'
                html += MdHtmlEmitter._RenderList(node, 0)
            endif
        endfor
        return html
    enddef

endclass

# MdVim: thin convenience facade over MdParser + MdHtmlEmitter, kept for
# a simple one-call API and backward compatibility with earlier callers.
export class MdVim

    # ParseMarkdown: Parses `lines` and renders them straight to HTML.
    def ParseMarkdown(lines: list<string>): list<string>
Util.DBG('MdVim.ParseMarkdown: %d line(s) in', len(lines))
        return MdHtmlEmitter.Render(MdParser.new().Parse(lines))
    enddef

    # Parse: Exposes the AST directly, for callers (e.g. a future
    # Vim :syntax-region emitter) that want the parsed structure rather
    # than HTML.
    def Parse(lines: list<string>): list<dict<any>>
        return MdParser.new().Parse(lines)
    enddef

endclass

# MdDebug: Pretty-prints an MdParser AST as indented text, for debugging
# (see the --ast CLI flag below). Not used by ParseMarkdown() at all.
export class MdDebug

    static def _DumpNode(value: any, depth: number): list<string>
        var indent = repeat('  ', depth)
        if type(value) == v:t_dict
            var d: dict<any> = value
            var label = has_key(d, 'type') ? d.type : (has_key(d, 'text') ? 'item' : '(node)')
            var out = [indent .. '- ' .. label]
            for key in sort(keys(d))
                if key == 'type'
                    continue
                endif
                var v = d[key]
                if type(v) == v:t_list || type(v) == v:t_dict
                    out->add(indent .. '    ' .. key .. ':')
                    out += MdDebug._DumpNode(v, depth + 3)
                else
                    out->add(indent .. '    ' .. key .. ': ' .. string(v))
                endif
            endfor
            return out
        elseif type(value) == v:t_list
            var out: list<string> = []
            var l: list<any> = value
            if empty(l)
                out->add(indent .. '(empty)')
            endif
            for item in l
                out += MdDebug._DumpNode(item, depth)
            endfor
            return out
        else
            return [indent .. string(value)]
        endif
    enddef

    # Dump: Renders a full AST (list of top-level block nodes) as
    # indented, human-readable text lines.
    static def Dump(nodes: list<dict<any>>): list<string>
        var out: list<string> = []
        for node in nodes
            out += MdDebug._DumpNode(node, 0)
        endfor
        return out
    enddef

endclass
