"use vim9 script only:
vim9script

# autoload/ai/md_html.vim
#
# MdHtmlEmitter: renders an MdParser AST to HTML lines. Stateless -
# every method is static, so no instance is needed.

#no longer need, use g:DBG
#import './util.vim' as Util

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
        var safe_text = MdHtmlEmitter._EscapeHtml(text)
        var has_hard_break = safe_text =~ '  $'
        var res = has_hard_break ? substitute(safe_text, '  $', '', '') : safe_text

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
        return '<p>' .. join(formatted, '<br />') .. '</p>'
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
        endif
        var out = [printf('<pre><code%s>%s', lang_attr, escaped_lines[0])]
        for idx in range(1, len(escaped_lines) - 1)
            out->add(escaped_lines[idx])
        endfor
        out[-1] ..= '</code></pre>'
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

    static def _RenderNode(node: dict<any>): list<string>
        g:DBG(1, '_RenderNode: type=%s', get(node, 'type', 'unknown'))
        var html: list<string> = []
        if node.type == 'paragraph'
            html->add(MdHtmlEmitter._RenderParagraphLines(node.lines))
        elseif node.type == 'heading'
            var level: number = node.level
            var safe_text = MdHtmlEmitter._FormatInline(node.text)
            g:DBG(1, '_RenderNode: heading level=%d text=%s', level, safe_text)
            html->add(printf('<h%d>%s</h%d>', level, safe_text, level))
        elseif node.type == 'hr'
            html->add('<hr />')
        elseif node.type == 'codeblock'
            html += MdHtmlEmitter._RenderCodeBlock(node)
        elseif node.type == 'blockquote'
            html += MdHtmlEmitter._RenderBlockquote(node)
        elseif node.type == 'table'
            html += MdHtmlEmitter._RenderTable(node)
        elseif node.type == 'list'
            html += MdHtmlEmitter._RenderList(node, 0)
        elseif node.type == 'turn'
            var role = get(node, 'role', 'user')
            g:DBG(1, '_RenderNode: turn role=%s children_count=%d', role, len(node.children))
            html->add(printf('<div class="chat-turn %s">', role))
            for child in node.children
                html += MdHtmlEmitter._RenderNode(child)
            endfor
            html->add('</div>')
        endif
        return html
    enddef

    # Render: Walks an MdParser AST and returns the equivalent HTML lines.
    static def Render(nodes: list<dict<any>>): list<string>
        g:DBG(1, 'MdHtmlEmitter.Render: %d top-level nodes', len(nodes))
        var html: list<string> = []
        for node in nodes
            html += MdHtmlEmitter._RenderNode(node)
        endfor
        return html
    enddef

endclass
