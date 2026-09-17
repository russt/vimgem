"use vim9 script only:
vim9script

# autoload/ai/md.vim
#
# Holds the Markdown parser (MdParser), its AST debug-dumper (MdDebug),
# and the MdVim convenience facade. No top-level side effects, so it's
# safe to `import` from core.vim/buffer.vim.
#
# The emitters live in their own sibling files, since neither needs
# the parser (or each other) - see each file's header for why:
#   md_html.vim    MdHtmlEmitter    AST        -> HTML lines
#   md_syntax.vim  MdSyntaxEmitter  raw buffer -> :syntax/:highlight cmds
#
# MSG()/EMSG()/ERR()/DBG() live in util.vim, shared with the rest of
# the plugin.

import './md_html.vim' as Html

#no longer need, use g:DBG
#import './util.vim' as Util

# md.vim: A GitHub-Flavored-Markdown-ish parser, split into two stages:
#
#   MdParser       lines -> AST (a list<dict<any>> of typed block nodes)
#   MdHtmlEmitter   AST  -> HTML lines (md_html.vim)
#
# Keeping these separate means an alternative backend - e.g.
# MdSyntaxEmitter in md_syntax.vim, for Vim :syntax-region markdown
# highlighting - can work from the same AST, or bypass it entirely,
# without touching the parsing logic at all.
#
# Usage:
#   var html_lines = MdVim.new().ParseMarkdown(markdown_lines)
#   " or, to get at the AST directly:
#   var ast = MdParser.new().Parse(markdown_lines)
#   var html_lines = Html.MdHtmlEmitter.Render(ast)
#
# ---------------------------------------------------------------------
# AST node shapes (all nodes are dict<any>, tagged by a 'type' key):
#   {type: 'turn', role: string, begin_line: number, end_line: number, children: list<dict<any>>}
#   {type: 'heading', level: number, text: string, begin_line: number, end_line: number}
#   {type: 'paragraph', lines: list<string>, begin_line: number, end_line: number}
#   {type: 'hr', begin_line: number, end_line: number}
#   {type: 'codeblock', lang: string, lines: list<string>, begin_line: number, end_line: number}
#   {type: 'blockquote', children: list<dict<any>>, begin_line: number, end_line: number}
#   {type: 'table', alignments: list<string>, header: list<string>,
#    rows: list<list<string>>, begin_line: number, end_line: number}
#   {type: 'list', ordered: bool, items: list<dict<any>>, begin_line: number, end_line: number}
#       item: {text: string, checked: bool (optional),
#              children: list<dict<any>> (optional, nested 'list' nodes)}
# 'text'/'lines' fields hold RAW markdown - inline formatting (bold,
# links, code spans, ...) is applied later, by the emitter.
# ---------------------------------------------------------------------

# MdParser: turns markdown lines into a block-level AST. Does no inline
# formatting and produces no HTML - it only recognizes block structure.
export class MdParser

    var nodes: list<dict<any>> = []
    var active_turn: dict<any> = {}

    var in_code: bool = false
    var code_lang: string = ''
    var code_lines: list<string> = []
    var code_begin_line: number = 0

    var in_indented_code: bool = false
    var indented_code_lines: list<string> = []
    var indented_code_begin_line: number = 0

    var p_lines: list<string> = []
    var p_begin_line: number = 0

    var bq_node: dict<any> = {}
    var in_bq: bool = false

    var in_table: bool = false
    var table_alignments: list<string> = []
    var table_node: dict<any> = {}
    var table_begin_line: number = 0

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

    # ---- Instance flush / close helpers -------------------------------

    def _AddNode(node: dict<any>)
        if !empty(this.active_turn)
            this.active_turn.children->add(node)
        else
            this.nodes->add(node)
        endif
    enddef

    def _FlushParagraph(current_line: number)
        if !empty(this.p_lines)
            this._AddNode({
                type: 'paragraph',
                lines: this.p_lines,
                begin_line: this.p_begin_line,
                end_line: current_line
            })
            this.p_lines = []
            this.p_begin_line = 0
        endif
    enddef

    def _FlushIndentedCode(current_line: number)
        if this.in_indented_code
            if !empty(this.indented_code_lines)
                this._AddNode({
                    type: 'codeblock',
                    lang: '',
                    lines: this.indented_code_lines,
                    begin_line: this.indented_code_begin_line,
                    end_line: current_line
                })
            endif
            this.in_indented_code = false
            this.indented_code_lines = []
            this.indented_code_begin_line = 0
        endif
    enddef

    def _FlushFencedCode(current_line: number)
        if this.in_code
            this._AddNode({
                type: 'codeblock',
                lang: this.code_lang,
                lines: this.code_lines,
                begin_line: this.code_begin_line,
                end_line: current_line
            })
            this.in_code = false
            this.code_lines = []
            this.code_begin_line = 0
        endif
    enddef

    def _CloseBlocks(except_type: string = '', current_line: number = 0)
        if except_type != 'paragraph'
            this._FlushParagraph(current_line)
        endif
        if except_type != 'indented_code'
            this._FlushIndentedCode(current_line)
        endif
        if except_type != 'list'
            this.list_stack = []
        endif
        if except_type != 'bq' && this.in_bq
            if !empty(this.bq_node)
                this.bq_node.end_line = current_line
            endif
            this.in_bq = false
            this.bq_node = {}
        endif
        if except_type != 'table' && this.in_table
            if !empty(this.table_node)
                this.table_node.end_line = current_line
            endif
            this.in_table = false
            this.table_alignments = []
            this.table_node = {}
            this.table_begin_line = 0
        endif
    enddef

    # _OpenListLevel: Opens a new nested list level (deeper indent), or
    # switches list type (ul<->ol) at the current depth, attaching the
    # new list node in the right place. `container` is the list<dict>
    # to append the new list node into - the caller computes this,
    # since "going deeper" (nest under the parent's last item) and
    # "switching type at the same depth" (reuse the same slot the old
    # list occupied) need different containers.
    def _OpenListLevel(list_type: string, indent_level: number, container: list<dict<any>>, current_line: number)
        var new_node = {
            type: 'list',
            ordered: list_type == 'ol',
            items: [],
            begin_line: current_line,
            end_line: current_line
        }
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
        g:DBG(2, 'MdParser.Parse: parsing %d lines', len(lines))
        this.nodes = []
        this.active_turn = {}
        this.in_code = false
        this.code_lang = ''
        this.code_lines = []
        this.code_begin_line = 0
        this.in_indented_code = false
        this.indented_code_lines = []
        this.indented_code_begin_line = 0
        this.p_lines = []
        this.p_begin_line = 0
        this.bq_node = {}
        this.in_bq = false
        this.in_table = false
        this.table_alignments = []
        this.table_node = {}
        this.table_begin_line = 0
        this.list_stack = []

        var i = 0
        var n = len(lines)

        while i < n
            var line = lines[i]
            var current_line_num = i + 1

            # Fault Isolation / Hard Resynchronization: Check for Turn Boundary Markers
            var is_user_turn = line =~ '^## You\>'
            var is_ai_turn = line =~ '^## AI\>'
            if is_user_turn || is_ai_turn
                # Force close and flush any active blocks within the previous turn context
                this._CloseBlocks('', current_line_num - 1)

                # Reset all mutable parsing states to guarantee fresh, uncorrupted parsing for the new turn
                this.in_code = false
                this.code_lang = ''
                this.code_lines = []
                this.code_begin_line = 0
                this.in_indented_code = false
                this.indented_code_lines = []
                this.indented_code_begin_line = 0
                this.p_lines = []
                this.p_begin_line = 0
                this.list_stack = []
                this.in_bq = false
                this.bq_node = {}
                this.in_table = false
                this.table_node = {}

                var role = is_user_turn ? 'user' : 'assistant'
                this.active_turn = {
                    type: 'turn',
                    role: role,
                    begin_line: current_line_num,
                    end_line: current_line_num,
                    children: []
                }
                this.nodes->add(this.active_turn)
                g:DBG(2, 'MdParser: opened %s turn at line %d', role, current_line_num)
            endif

            # Fenced code block handling (```)
            if line =~ '^```'
                if this.in_code
                    this._FlushFencedCode(current_line_num)
                else
                    this._CloseBlocks('', current_line_num)
                    this.code_lang = trim(line[3 :])
                    this.in_code = true
                    this.code_lines = []
                    this.code_begin_line = current_line_num
                endif
                if !empty(this.active_turn)
                    this.active_turn.end_line = current_line_num
                endif
                i += 1
                continue
            endif

            if this.in_code
                this.code_lines->add(line)
                if !empty(this.active_turn)
                    this.active_turn.end_line = current_line_num
                endif
                i += 1
                continue
            endif

            # Blank lines reset active block elements
            if line =~ '^\s*$'
                this._CloseBlocks('', current_line_num)
                if !empty(this.active_turn)
                    this.active_turn.end_line = current_line_num
                endif
                i += 1
                continue
            endif

            # Horizontal Rules (---, ***, ___)
            if line =~ '^\s*\([*_-]\s*\)\{3,\}\s*$'
                this._CloseBlocks('', current_line_num)
                this._AddNode({
                    type: 'hr',
                    begin_line: current_line_num,
                    end_line: current_line_num
                })
                if !empty(this.active_turn)
                    this.active_turn.end_line = current_line_num
                endif
                i += 1
                continue
            endif

            # Setext Headers (Alt-H1 = / Alt-H2 -) - guard against diff lines starting with <
            if i + 1 < n && !empty(trim(line)) && line !~ '^<' && lines[i + 1] =~ '^\s*=\{3,\}\s*$'
                this._CloseBlocks('', current_line_num)
                this._AddNode({
                    type: 'heading',
                    level: 1,
                    text: trim(line),
                    begin_line: current_line_num,
                    end_line: current_line_num + 1
                })
                if !empty(this.active_turn)
                    this.active_turn.end_line = current_line_num + 1
                endif
                i += 2
                continue
            elseif i + 1 < n && !empty(trim(line)) && line !~ '^<' && line !~ '^\s*[-*+]\s\+' && lines[i + 1] =~ '^\s*-\{3,\}\s*$'
                this._CloseBlocks('', current_line_num)
                this._AddNode({
                    type: 'heading',
                    level: 2,
                    text: trim(line),
                    begin_line: current_line_num,
                    end_line: current_line_num + 1
                })
                if !empty(this.active_turn)
                    this.active_turn.end_line = current_line_num + 1
                endif
                i += 2
                continue
            endif

            # ATX Headers (# to ######)
            if line =~ '^#\{1,6\}\s\+'
                this._CloseBlocks('', current_line_num)
                var level = len(matchstr(line, '^#\+'))
                var heading_text = substitute(line, '^#\+\s*', '', '')
                this._AddNode({
                    type: 'heading',
                    level: level,
                    text: trim(heading_text),
                    begin_line: current_line_num,
                    end_line: current_line_num
                })
                if !empty(this.active_turn)
                    this.active_turn.end_line = current_line_num
                endif
                i += 1
                continue
            endif

            # Blockquotes (> line)
            if line =~ '^\s*>\s*'
                this._CloseBlocks('bq', current_line_num)
                if !this.in_bq
                    this.bq_node = {
                        type: 'blockquote',
                        children: [],
                        begin_line: current_line_num,
                        end_line: current_line_num
                    }
                    this._AddNode(this.bq_node)
                    this.in_bq = true
                else
                    this.bq_node.end_line = current_line_num
                endif
                var bq_text = substitute(line, '^\s*>\s*', '', '')
                if bq_text =~ '^\s*>\s*'
                    var nested_text = substitute(bq_text, '^\s*>\s*', '', '')
                    this.bq_node.children->add({type: 'blockquote',
                        \ children: [{type: 'paragraph', lines: [nested_text]}]})
                elseif !empty(trim(bq_text))
                    this.bq_node.children->add({type: 'paragraph', lines: [bq_text]})
                endif
                if !empty(this.active_turn)
                    this.active_turn.end_line = current_line_num
                endif
                i += 1
                continue
            endif

            # Tables (| Header | Header | ...)
            if line =~ '^\s*|.*|\s*$'
                if !this.in_table && i + 1 < n && lines[i + 1] =~ '^\s*|[: -|]\+|\s*$' && lines[i + 1] =~ '-'
                    this._CloseBlocks('table', current_line_num)
                    this.in_table = true
                    this.table_begin_line = current_line_num
                    this.table_alignments = MdParser._ParseTableAlignments(lines[i + 1])
                    this.table_node = {
                        type: 'table',
                        alignments: this.table_alignments,
                        header: MdParser._SplitRow(line),
                        rows: [],
                        begin_line: current_line_num,
                        end_line: current_line_num + 1
                    }
                    this._AddNode(this.table_node)
                    if !empty(this.active_turn)
                        this.active_turn.end_line = current_line_num + 1
                    endif
                    i += 2
                    continue
                elseif this.in_table
                    this.table_node.rows->add(MdParser._SplitRow(line))
                    this.table_node.end_line = current_line_num
                    if !empty(this.active_turn)
                        this.active_turn.end_line = current_line_num
                    endif
                    i += 1
                    continue
                endif
            endif

            # Nested List Items (Unordered [-*+], Ordered [0-9.], Task Lists)
            var is_ul = line =~ '^\s*[-*+]\s\+'
            var is_ol = line =~ '^\s*\d\+\.\s\+'

            if is_ul || is_ol
                this._CloseBlocks('list', current_line_num)
                var list_type = is_ul ? 'ul' : 'ol'
                var indent_str = matchstr(line, '^\s*')
                var indent_level = 0
                for char in split(indent_str, '\zs')
                    indent_level += (char == "\t" ? 4 : 1)
                endfor

                # Close deeper levels when indentation decreases
                while !empty(this.list_stack) && this.list_stack[-1].indent > indent_level
                    this.list_stack[-1].node.end_line = current_line_num - 1
                    this.list_stack->remove(-1)
                endwhile

                # Open new nested list level or switch list type
                if empty(this.list_stack)
                    var target_container = !empty(this.active_turn) ? this.active_turn.children : this.nodes
                    this._OpenListLevel(list_type, indent_level, target_container, current_line_num)
                elseif this.list_stack[-1].indent < indent_level
                    this._OpenListLevel(list_type, indent_level, this._NestedContainer(), current_line_num)
                elseif this.list_stack[-1].indent == indent_level
                        \ && (this.list_stack[-1].node.ordered != (list_type == 'ol'))
                    this.list_stack[-1].node.end_line = current_line_num - 1
                    var container = this.list_stack[-1].container
                    this.list_stack->remove(-1)
                    this._OpenListLevel(list_type, indent_level, container, current_line_num)
                endif

                this.list_stack[-1].node.end_line = current_line_num

                # Parse item text and record checkbox state
                var item_text = is_ul ? substitute(line, '^\s*[-*+]\s\+', '', '') : substitute(line, '^\s*\d\+\.\s\+', '', '')
                var item: dict<any> = {}
                if is_ul && item_text =~ '^\[[ xX]\]\s\+'
                    item.checked = item_text =~ '^\[[xX]\]'
                    item_text = substitute(item_text, '^\[[ xX]\]\s\+', '', '')
                endif
                item.text = item_text
                this.list_stack[-1].node.items->add(item)
                if !empty(this.active_turn)
                    this.active_turn.end_line = current_line_num
                endif
                i += 1
                continue
            endif

            # Indented Code Block (4 spaces or tab)
            if line =~ '^\(\s\{4\}\|\t\)'
                if !this.in_indented_code
                    this._CloseBlocks('indented_code', current_line_num)
                    this.in_indented_code = true
                    this.indented_code_begin_line = current_line_num
                    this.indented_code_lines = []
                endif
                var code_line = substitute(line, '^\(\s\{4\}\|\t\)', '', '')
                this.indented_code_lines->add(code_line)
                if !empty(this.active_turn)
                    this.active_turn.end_line = current_line_num
                endif
                i += 1
                continue
            endif

            # Default Paragraph Line
            if empty(this.p_lines)
                this._CloseBlocks('paragraph', current_line_num)
                this.p_begin_line = current_line_num
            endif
            this.p_lines->add(line)
            if !empty(this.active_turn)
                this.active_turn.end_line = current_line_num
            endif
            i += 1
        endwhile

        # Final cleanup of remaining open blocks
        this._FlushFencedCode(n)
        if this.in_indented_code
            this._FlushIndentedCode(n)
        endif
        this._CloseBlocks('', n)

        return this.nodes
    enddef

endclass

export class MdVim

    # ParseMarkdown: Parses `lines` and renders them straight to HTML.
    def ParseMarkdown(lines: list<string>): list<string>
        g:DBG(2, 'MdVim.ParseMarkdown: %d line(s) in', len(lines))
        return Html.MdHtmlEmitter.Render(MdParser.new().Parse(lines))
    enddef

    # Parse: Exposes the AST directly, for callers (e.g. MdDebug below,
    # or md_syntax.vim's MdSyntaxEmitter, which works off raw lines
    # instead) that want the parsed structure rather than HTML.
    def Parse(lines: list<string>): list<dict<any>>
        return MdParser.new().Parse(lines)
    enddef

endclass

# MdDebug: Pretty-prints an MdParser AST as indented text, for
# debugging. Not used by ParseMarkdown() at all.
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
