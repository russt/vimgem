" Copyright (c) 2025-2026 Russ Tremain.
" Released under the MIT License. See LICENSE file for details.
vim9script

# autoload/ai/md_html.vim
#
# MdHtmlEmitter: renders an MdParser AST to HTML lines.
#
# All methods are static - no instance needed. Codeblock rendering uses
# _SynIDCodeBlock which loads the code with the correct filetype into a
# single persistent scratch window per Render() pass so Vim's syntax
# engine activates, then walks each character with synID()/synIDtrans()
# backed by a syntax-style cache to emit <span style="..."> tags directly.
# Falls back to plain escaped <pre><code> if the lang is unrecognized.
# u.ResolveLang() provides the fence-tag -> Vim-filetype mapping, shared
# with md_syntax.vim's :syntax include path.

import './util.vim' as u

export class MdHtmlEmitter

    # Global style cache per Render() pass: sid (number string) -> CSS style string
    static var style_cache: dict<string> = {}

    # Diagnostic timers and counters for benchmarking (DBG level 8)
    static var perf_ft_switch_ms: float = 0.0
    static var perf_synid_ms: float = 0.0
    static var perf_chars_scanned: number = 0
    static var perf_codeblocks_count: number = 0

    # Per-node-type cumulative timers and counts
    static var perf_by_type: dict<float> = {}
    static var perf_count_by_type: dict<number> = {}

    # ---- HTML-escaping and inline shielding helpers -------------------

    # _EscapeHtml: Escapes &, <, > as HTML entities. Order matters: &
    # must be escaped first, or it would double-escape the ampersands
    # introduced by the '<' and '>' replacements.
    static def _EscapeHtml(text: string): string
        if text !~ '[&<>]'
            return text
        endif
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
        return '<code>' .. content .. '</code>'
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

    # _CountChar: fast character occurrence count without regex engine overhead.
    static def _CountChar(s: string, ch: string): number
        var c = 0
        var pos = stridx(s, ch)
        while pos != -1
            c += 1
            pos = stridx(s, ch, pos + 1)
        endwhile
        return c
    enddef

    # _FormatInlineText: Renders inline formatting for an entire block of text
    # (paragraph or single line). Formats across newlines in one unified pass.
    # Employs newline-bounded delimiter patterns ([^_\n], [^*\n]) and frequency
    # guards to prevent catastrophic regex backtracking across un-fenced code.
    static def _FormatInlineText(text: string): string
        var safe_text = MdHtmlEmitter._EscapeHtml(text)

        # Fast-path: if no inline formatting characters exist, return immediately
        if safe_text !~ '[`!\[\*_~]'
            return safe_text
        endif

        var res = safe_text
        var stash: list<string> = []

        # Inline code (requires at least 2 backticks to form a span, single line)
        if MdHtmlEmitter._CountChar(res, '`') >= 2
            res = substitute(res, '`\([^`\n]\{-}\)`',
                \ '\=MdHtmlEmitter._Stash(stash, MdHtmlEmitter._CodeHtml(submatch(1)))', 'g')
        endif

        # Links and Images
        if res =~ '\['
            # Images with title
            if res =~ '!\[.*\](.*".*")'
                res = substitute(res, '!\+\[\([^][\n]\{-}\)\](\([^)\n]\{-}\)\s\+"\([^"\n]\{-}\)")',
                    \ '\=MdHtmlEmitter._Stash(stash, MdHtmlEmitter._ImageHtml(submatch(1), submatch(2), submatch(3)))', 'g')
            endif
            # Images without title
            if res =~ '!\[.*\](.*)'
                res = substitute(res, '!\+\[\([^][\n]\{-}\)\](\([^)\n]\{-}\))',
                    \ '\=MdHtmlEmitter._Stash(stash, MdHtmlEmitter._ImageHtmlNoTitle(submatch(1), submatch(2)))', 'g')
            endif
            # Links
            if res =~ '\[.*\](.*)'
                res = substitute(res, '\[\([^][\n]\{-}\)\](\([^)\n]\{-}\))',
                    \ '\=MdHtmlEmitter._Stash(stash, MdHtmlEmitter._LinkHtml(submatch(1), submatch(2)))', 'g')
            endif
        endif

        # Bold & Italic with asterisks (requires at least 2 asterisks; bounded by newline)
        var count_ast = MdHtmlEmitter._CountChar(res, '*')
        if count_ast >= 2
            if count_ast >= 6
                # Bold+Italic (*** ... ***)
                res = substitute(res, '\*\*\*\%(\S\)\@=\([^*\n]\{-}\S\)\*\*\*', '<strong><em>\1</em></strong>', 'g')
            endif
            if count_ast >= 4
                # Bold (** ... **)
                res = substitute(res, '\*\*\%(\S\)\@=\([^*\n]\{-}\S\)\*\*', '<strong>\1</strong>', 'g')
            endif
            # Italic (* ... *)
            res = substitute(res, '\*\%(\S\)\@=\([^*\n]\{-}\S\)\*', '<em>\1</em>', 'g')
        endif

        # Bold & Italic with underscores (word boundary restricted; bounded by newline)
        # Bounding with [^_\n] prevents catastrophic N^2 backtracking across code variables.
        var count_under = MdHtmlEmitter._CountChar(res, '_')
        if count_under >= 2
            if count_under >= 6 && res =~ '\%([0-9A-Za-z_]\)\@<!___'
                # Bold+Italic (___ ... ___)
                res = substitute(res,
                    \ '\%([0-9A-Za-z_]\)\@<!___\%(\S\)\@=\([^_\n]\{-}\S\)___\%([0-9A-Za-z_]\)\@!',
                    \ '<strong><em>\1</em></strong>', 'g')
            endif
            if count_under >= 4 && res =~ '\%([0-9A-Za-z_]\)\@<!__'
                # Bold (__ ... __)
                res = substitute(res,
                    \ '\%([0-9A-Za-z_]\)\@<!__\%(\S\)\@=\([^_\n]\{-}\S\)__\%([0-9A-Za-z_]\)\@!',
                    \ '<strong>\1</strong>', 'g')
            endif
            # Italic (_ ... _) - only evaluate if isolated delimiter pattern is present
            if res =~ '\%([0-9A-Za-z_]\)\@<!_[^_\n\s]'
                res = substitute(res,
                    \ '\%([0-9A-Za-z_]\)\@<!_\%(\S\)\@=\([^_\n]\{-}\S\)_\%([0-9A-Za-z_]\)\@!',
                    \ '<em>\1</em>', 'g')
            endif
        endif

        # Strikethrough (requires at least 4 tildes: ~~text~~, single line)
        if MdHtmlEmitter._CountChar(res, '~') >= 4
            res = substitute(res, '\~\~\([^~\n]\{-}\)\~\~', '<del>\1</del>', 'g')
        endif

        # Unshield: splice the stashed HTML fragments back in.
        for idx in range(len(stash))
            res = substitute(res, "\x01" .. idx .. "\x02", '\=stash[idx]', '')
        endfor

        return res
    enddef

    # _FormatInline: Renders a single line of Markdown text (used for headings, lists, table cells).
    static def _FormatInline(text: string): string
        var has_hard_break = text =~ '  $'
        var clean_text = has_hard_break ? substitute(text, '  $', '', '') : text
        var formatted = MdHtmlEmitter._FormatInlineText(clean_text)
        return has_hard_break ? formatted .. '<br />' : formatted
    enddef

    # ---- Block renderers ------------------------------------------------

    # _RenderParagraphLines: Formats an entire paragraph node in a single
    # pass, converting inter-line newlines to <br /> and supporting hard breaks.
    static def _RenderParagraphLines(lines: list<string>): string
        if empty(lines)
            return '<p></p>'
        endif

        var joined = ''
        var nlines = len(lines)
        for idx in range(nlines)
            var l = lines[idx]
            var has_break = l =~ '  $'
            var cl = has_break ? substitute(l, '  $', '', '') : l
            joined ..= cl
            if idx < nlines - 1
                joined ..= "\n"
            endif
        endfor

        var formatted = MdHtmlEmitter._FormatInlineText(joined)
        formatted = substitute(formatted, "\n", '<br />', 'g')
        return '<p>' .. formatted .. '</p>'
    enddef

    # _ResolveColor: resolves a syntax attribute ('fg' or 'bg') to a CSS
    # color string for a translated synID. Tries gui first; falls back to
    # cterm mapped through u.CtermToHex().
    static def _ResolveColor(sid: number, attr: string): string
        var c = synIDattr(sid, attr .. '#', 'gui')
        if !empty(c)
            return c
        endif
        var n = synIDattr(sid, attr, 'cterm')
        return empty(n) ? '' : u.CtermToHex(n)
    enddef

    # GetSidStyle: public method so closures and methods can access it without E1366.
    # Returns cached CSS style string for a given sid integer.
    # If not cached, computes it once using synIDattr() and stores it.
    static def GetSidStyle(sid: number): string
        if sid <= 0
            return ''
        endif
        var key = string(sid)
        if has_key(MdHtmlEmitter.style_cache, key)
            return MdHtmlEmitter.style_cache[key]
        endif

        var fg = MdHtmlEmitter._ResolveColor(sid, 'fg')
        var bold = synIDattr(sid, 'bold', 'gui') == '1'
        var italic = synIDattr(sid, 'italic', 'gui') == '1'

        var style = ''
        if !empty(fg)
            style ..= 'color:' .. fg .. ';'
        endif
        if bold
            style ..= 'font-weight:bold;'
        endif
        if italic
            style ..= 'font-style:italic;'
        endif

        MdHtmlEmitter.style_cache[key] = style
        return style
    enddef

    # _SynCodeLine: walks one line of the scratch buffer using synID() and
    # cached style lookups, returning an HTML string with inline <span> tags.
    # Inlined run-flushing avoids E1366 lambda scope restrictions entirely.
    static def _SynCodeLine(lnum: number): string
        var line = getline(lnum)
        if empty(line)
            return ''
        endif

        var out = ''
        var cur_sid = -1
        var run = ''

        var ncols = strchars(line)
        MdHtmlEmitter.perf_chars_scanned += ncols

        for colidx in range(ncols)
            var bcol = byteidx(line, colidx) + 1
            var sid = synIDtrans(synID(lnum, bcol, 0))
            var ch = strcharpart(line, colidx, 1)

            if sid == cur_sid
                run ..= ch
            else
                if !empty(run)
                    var esc = run
                    if esc =~ '[&<>]'
                        esc = substitute(esc, '&', '\&amp;', 'g')
                        esc = substitute(esc, '<', '\&lt;', 'g')
                        esc = substitute(esc, '>', '\&gt;', 'g')
                    endif
                    var style = MdHtmlEmitter.GetSidStyle(cur_sid)
                    if empty(style)
                        out ..= esc
                    else
                        out ..= '<span style="' .. style .. '">' .. esc .. '</span>'
                    endif
                endif
                cur_sid = sid
                run = ch
            endif
        endfor

        if !empty(run)
            var esc = run
            if esc =~ '[&<>]'
                esc = substitute(esc, '&', '\&amp;', 'g')
                esc = substitute(esc, '<', '\&lt;', 'g')
                esc = substitute(esc, '>', '\&gt;', 'g')
            endif
            var style = MdHtmlEmitter.GetSidStyle(cur_sid)
            if empty(style)
                out ..= esc
            else
                out ..= '<span style="' .. style .. '">' .. esc .. '</span>'
            endif
        endif

        return out
    enddef

    # _SynIDCodeBlock: renders a codeblock AST node in the current scratch buffer.
    # Assumes caller is already in the scratch window, avoiding win_gotoid overhead.
    static def _SynIDCodeBlock(node: dict<any>): list<string>
        var resolved = u.ResolveLang(node.lang)
        if empty(resolved)
            return []
        endif

        var fragment: list<string> = []

        try
            deletebufline('%', 1, '$')
            setline(1, node.lines)

            # Measure filetype switch & syntax file execution time
            var t_ft_start = reltime()
            execute 'setlocal filetype=' .. resolved
            var ft_elapsed = reltimefloat(reltime(t_ft_start)) * 1000.0
            MdHtmlEmitter.perf_ft_switch_ms += ft_elapsed

            var normal_sid = synIDtrans(hlID('Normal'))
            var bg = normal_sid > 0 ? MdHtmlEmitter._ResolveColor(normal_sid, 'bg') : ''
            var pre_style = empty(bg) ? '' : printf(' style="background-color:%s;"', bg)

            fragment->add(printf('<pre%s>', pre_style))
            var nlines = len(node.lines)

            # Measure synID character scanning loop
            var t_syn_start = reltime()
            for lnum in range(1, nlines)
                fragment->add(MdHtmlEmitter._SynCodeLine(lnum))
            endfor
            var syn_elapsed = reltimefloat(reltime(t_syn_start)) * 1000.0
            MdHtmlEmitter.perf_synid_ms += syn_elapsed
            MdHtmlEmitter.perf_codeblocks_count += 1

            fragment->add('</pre>')

            if ft_elapsed + syn_elapsed > 100.0
                u.DBG(8, '[PERF] Slow codeblock #%d [%s] (%d lines): ft_switch=%.1fms synID=%.1fms',
                    MdHtmlEmitter.perf_codeblocks_count, resolved, nlines, ft_elapsed, syn_elapsed)
            endif
        catch
            u.DBG(1, '_SynIDCodeBlock: exception: %s', v:exception)
            fragment = []
        endtry

        return fragment
    enddef

    # _RenderCodeBlock: renders a codeblock AST node to HTML lines.
    static def _RenderCodeBlock(node: dict<any>): list<string>
        if !empty(node.lang)
            var fragment = MdHtmlEmitter._SynIDCodeBlock(node)
            if !empty(fragment)
                return fragment
            endif
        endif

        # Plain fallback: escaped <pre><code class="language-LANG">.
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
            out += MdHtmlEmitter._RenderNode(child)
        endfor
        out->add('</blockquote>')
        return out
    enddef

    static def _RenderTable(node: dict<any>): list<string>
        var alignments: list<string> = node.alignments
        var out = ['<table style="border-collapse: collapse; width: 100%; margin: 1em 0; border: 1px solid #d0d7de;"><thead><tr>']
        var header: list<string> = node.header
        for idx in range(len(header))
            var align_style = idx < len(alignments) && !empty(alignments[idx])
                ? substitute(alignments[idx], '^ style="\(.*\)"$', '\1;', '')
                : ''
            var th_style = 'border: 1px solid #d0d7de; background-color: #f6f8fa; padding: 6px 13px; font-weight: bold; border-bottom: 2px solid #afb8c1;' .. align_style
            out->add(printf('<th style="%s">%s</th>', th_style, MdHtmlEmitter._FormatInline(header[idx])))
        endfor
        out->add('</tr></thead><tbody>')
        var rows: list<list<string>> = node.rows
        var row_idx = 0
        for row in rows
            var row_bg = (row_idx % 2 == 1) ? 'background-color: #f6f8fa;' : 'background-color: #ffffff;'
            out->add(printf('<tr style="%s">', row_bg))
            for idx in range(len(row))
                var align_style = idx < len(alignments) && !empty(alignments[idx])
                    ? substitute(alignments[idx], '^ style="\(.*\)"$', '\1;', '')
                    : ''
                var td_style = 'border: 1px solid #d0d7de; padding: 6px 13px;' .. align_style
                out->add(printf('<td style="%s">%s</td>', td_style, MdHtmlEmitter._FormatInline(row[idx])))
            endfor
            out->add('</tr>')
            row_idx += 1
        endfor
        out->add('</tbody></table>')
        return out
    enddef

    # _RenderList: Recursively renders a (possibly nested) list node.
    static def _RenderList(node: dict<any>, depth: number): list<string>
        var tag = node.ordered ? 'ol' : 'ul'
        var prefix = repeat('  ', depth)
        var out = [prefix .. '<' .. tag .. '>']
        var item_prefix = repeat('  ', depth + 1)
        var items: list<dict<any>> = node.items
        for item in items
            var formatted_text = MdHtmlEmitter._FormatInline(item.text)
            var li_start = ''
            if has_key(item, 'checked')
                var checked_attr = item.checked ? ' checked=""' : ''
                li_start = printf('%s<li><input type="checkbox"%s disabled="" /> %s',
                    \ item_prefix, checked_attr, formatted_text)
            else
                li_start = item_prefix .. '<li>' .. formatted_text
            endif

            if has_key(item, 'children') && !empty(item.children)
                out->add(li_start)
                for child in item.children
                    if child.type == 'list'
                        out += MdHtmlEmitter._RenderList(child, depth + 1)
                    else
                        out += MdHtmlEmitter._RenderNode(child)
                    endif
                endfor
                out->add(item_prefix .. '</li>')
            else
                out->add(li_start .. '</li>')
            endif
        endfor
        out->add(prefix .. '</' .. tag .. '>')
        return out
    enddef

    # _RenderNode: Dispatches block rendering and measures execution time by node type.
    static def _RenderNode(node: dict<any>): list<string>
        var ntype = get(node, 'type', 'unknown')
        var t_node_start = reltime()
        var html: list<string> = []

        if ntype == 'paragraph'
            html->add(MdHtmlEmitter._RenderParagraphLines(node.lines))
        elseif ntype == 'heading'
            var level: number = node.level
            var safe_text = MdHtmlEmitter._FormatInline(node.text)
            html->add(printf('<h%d>%s</h%d>', level, safe_text, level))
        elseif ntype == 'hr'
            html->add('<hr />')
        elseif ntype == 'codeblock'
            html += MdHtmlEmitter._RenderCodeBlock(node)
        elseif ntype == 'blockquote'
            html += MdHtmlEmitter._RenderBlockquote(node)
        elseif ntype == 'table'
            html += MdHtmlEmitter._RenderTable(node)
        elseif ntype == 'list'
            html += MdHtmlEmitter._RenderList(node, 0)
        elseif ntype == 'turn'
            var role = get(node, 'role', 'user')
            html->add(printf('<div class="chat-turn %s">', role))
            for child in node.children
                html += MdHtmlEmitter._RenderNode(child)
            endfor
            html->add('</div>')
        endif

        var elapsed_ms = reltimefloat(reltime(t_node_start)) * 1000.0

        # Update per-node-type cumulative metrics
        MdHtmlEmitter.perf_by_type[ntype] = get(MdHtmlEmitter.perf_by_type, ntype, 0.0) + elapsed_ms
        MdHtmlEmitter.perf_count_by_type[ntype] = get(MdHtmlEmitter.perf_count_by_type, ntype, 0) + 1

        if elapsed_ms > 50.0 && ntype != 'turn'
            u.DBG(8, '[PERF] Slow AST node [%s] (lines %d-%d): %.1fms',
                ntype, get(node, 'begin_line', 0), get(node, 'end_line', 0), elapsed_ms)
        endif

        return html
    enddef

    # Render: Walks an MdParser AST and returns the equivalent HTML lines.
    # Stays inside a single scratch window for all codeblocks to eliminate
    # repetitive win_gotoid window-switching overhead.
    static def Render(nodes: list<dict<any>>): list<string>
        var t_total_start = reltime()
        MdHtmlEmitter.style_cache = {}
        MdHtmlEmitter.perf_ft_switch_ms = 0.0
        MdHtmlEmitter.perf_synid_ms = 0.0
        MdHtmlEmitter.perf_chars_scanned = 0
        MdHtmlEmitter.perf_codeblocks_count = 0
        MdHtmlEmitter.perf_by_type = {}
        MdHtmlEmitter.perf_count_by_type = {}

        var prev_winid = win_getid()
        var scratch_winid = -1
        var t_setup_start = reltime()

        try
            noautocmd silent topleft :1split
            scratch_winid = win_getid()
            noautocmd silent :enew
            setlocal buftype=nofile bufhidden=wipe noswapfile modifiable
        catch
            scratch_winid = -1
        endtry
        var setup_ms = reltimefloat(reltime(t_setup_start)) * 1000.0

        var html: list<string> = []
        try
            for node in nodes
                html += MdHtmlEmitter._RenderNode(node)
            endfor
        finally
            if scratch_winid != -1 && win_gotoid(scratch_winid)
                noautocmd silent :quit!
            endif
            win_gotoid(prev_winid)
        endtry

        var total_ms = reltimefloat(reltime(t_total_start)) * 1000.0

        u.DBG(8, '[PERF] MdHtmlEmitter.Render total: %.1fms (top-nodes: %d, blocks: %d, chars: %d)',
            total_ms, len(nodes), MdHtmlEmitter.perf_codeblocks_count, MdHtmlEmitter.perf_chars_scanned)
        u.DBG(8, '[PERF]   - Scratch Window Setup: %.1fms', setup_ms)
        u.DBG(8, '[PERF]   - Filetype Switch/Load: %.1fms', MdHtmlEmitter.perf_ft_switch_ms)
        u.DBG(8, '[PERF]   - synID Character Loop: %.1fms', MdHtmlEmitter.perf_synid_ms)

        u.DBG(8, '[PERF] Node-type breakdown:')
        for ntype in sort(keys(MdHtmlEmitter.perf_by_type))
            var t_ms = MdHtmlEmitter.perf_by_type[ntype]
            var cnt = MdHtmlEmitter.perf_count_by_type[ntype]
            var avg = cnt > 0 ? (t_ms / cnt) : 0.0
            u.DBG(8, '[PERF]   - %-12s: %7.1fms (count: %4d, avg: %5.1fms)', ntype, t_ms, cnt, avg)
        endfor

        return html
    enddef

endclass
