"use vim9 script only:
vim9script

# autoload/ai/md_syntax.vim
#
# MdSyntaxEmitter: renders Vim `:syntax`/`:highlight` Ex-command
# strings that give a buffer decent, hand-rolled Markdown coloring -
# the "future backend" md.vim's header comment once anticipated, an
# alternative to md_html.vim's MdHtmlEmitter that targets `:syntax
# region`/`:match` instead of HTML tags. Callers execute() every
# returned string, in order, against the buffer `lines` came from (see
# AIBuffer.ApplyMarkdownHighlighting in buffer.vim).
#
# Unlike MdHtmlEmitter, this doesn't walk MdParser's block AST at all -
# inline markup (bold/italic/links/...) and structural markers
# (headings/blockquotes/lists/hr/tables) are just well-anchored
# regexes, the same way Vim's own bundled syntax files work, and don't
# need node boundaries to be unambiguous. The one place line-accurate
# boundaries genuinely matter is fenced code blocks: two ```python
# blocks in the same buffer need their own non-overlapping regions so
# `:syntax include`d language highlighting from one can never bleed
# into the other, or into surrounding prose. FindFencedCodeBlocks does
# one dedicated pass to locate those exactly, using the same
# fence-detection rule md.vim's MdParser.Parse uses (any line matching
# '^```' toggles code state).
#
# fenced-code regions this emits are naturally immune to having stray
# `*`/`_` characters in someone's code misread as emphasis, with no
# extra bookkeeping needed on the "prose" side.
export class MdSyntaxEmitter

    # FindFencedCodeBlocks: single pass over raw buffer `lines`,
    # returns one {lang: string, start: number, end: number} per fenced
    # code block, 1-based and inclusive of both fence lines. `end` is
    # the last line of the buffer if a fence is never closed - same
    # "don't lose unterminated content" behavior as MdParser.Parse's
    # own EOF cleanup.
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

    # _ResolveLang: maps a fence tag to the Vim filetype whose
    # syntax/<name>.vim actually defines its highlighting - e.g. a
    # fence tagged ```js should embed syntax/javascript.vim, not go
    # looking for a nonexistent syntax/js.vim. Anything not listed here
    # is tried verbatim (covers the common case where the fence tag
    # already matches its Vim filetype name, e.g. python, ruby, rust).
    # Returns '' for an untagged fence, which callers leave as a plain
    # (non-language-highlighted) code block.
    static def _ResolveLang(lang: string): string
        if empty(lang)
            return ''
        endif
        var aliases: dict<string> = {
            js: 'javascript', jsx: 'javascriptreact',
            ts: 'typescript', tsx: 'typescriptreact',
            py: 'python', rb: 'ruby', rs: 'rust', golang: 'go',
            sh: 'sh', bash: 'sh', zsh: 'zsh', shell: 'sh',
            yml: 'yaml', htm: 'html', kt: 'kotlin',
            'c++': 'cpp', 'c#': 'cs', cs: 'cs',
        }
        return get(aliases, lang, lang)
    enddef

    # _SafeGroupSuffix: Vim group/cluster names are bare identifiers
    # ([A-Za-z0-9_]) - fence tags can contain characters that aren't
    # (`c++`, `objective-c`), so this sanitizes one into something safe
    # to splice into a generated group name.
    static def _SafeGroupSuffix(lang: string): string
        return substitute(lang, '[^A-Za-z0-9_]', '_', 'g')
    enddef

    # _StaticRules: the content-independent half of Render() - generic
    # Markdown-ish inline/structural highlighting that doesn't need to
    # know anything about this specific buffer's content. Ordered to
    # roughly match MdHtmlEmitter._FormatInline (code spans and links
    # shielded as regions before emphasis is tried, bold+italic before
    # bold before italic).
    static def _StaticRules(): list<string>
        return [
            'syntax case match',

            # Inline code spans as a region (not a match) so the
            # emphasis patterns below can't reach inside one - see this
            # class's header comment on why regions are immune to that.
            'syntax region aimdCode matchgroup=aimdCodeDelim start=/`/ end=/`/ oneline',

            # Links / images: [text](url) / ![alt](url) - one region
            # per link so the brackets/parens get a distinct (dim)
            # delimiter color from the link text itself.
            'syntax region aimdLink matchgroup=aimdLinkDelim start=/!\?\[/ end=/)/ contains=aimdLinkText oneline',
            'syntax match aimdLinkText /\[\zs[^][]*\ze]/ contained',

            'syntax match aimdBoldItalic /\*\*\*\S\@=[^*]\{-}\S\*\*\*/',
            'syntax match aimdBoldItalic /\%(\w\)\@<!___\S\@=[^_]\{-}\S___\%(\w\)\@!/',
            'syntax match aimdBold /\*\*\S\@=[^*]\{-}\S\*\*/',
            'syntax match aimdBold /\%(\w\)\@<!__\S\@=[^_]\{-}\S__\%(\w\)\@!/',
            'syntax match aimdItalic /\*\S\@=[^*]\{-}\S\*/',
            'syntax match aimdItalic /\%(\w\)\@<!_\S\@=[^_]\{-}\S_\%(\w\)\@!/',
            'syntax match aimdStrike /\~\~[^~]\{-}\~\~/',

            # Structural markers - anchored to start-of-line so they
            # can't misfire mid-sentence (e.g. a literal '# ' inside a
            # paragraph).
            'syntax match aimdH1 /^#\s\+.*$/',
            'syntax match aimdH2 /^##\s\+.*$/',
            'syntax match aimdH3to6 /^###\{1,4}\s\+.*$/',
            'syntax match aimdHeaderMark /^#\{1,6}\ze\s/ contained containedin=aimdH1,aimdH2,aimdH3to6',
            'syntax match aimdHR /^\s*\([*_-]\s*\)\{3,\}\s*$/',
            'syntax match aimdBlockquote /^\s*>.*$/',
            'syntax match aimdListMarker /^\s*\([-*+]\|\d\+\.\)\s\+/',
            'syntax match aimdTableSep /^\s*|\?\s*:\?-\{3,\}:\?\s*\(|\s*:\?-\{3,\}:\?\s*\)*|\?\s*$/',
            'syntax match aimdTablePipe /|/',

            # Highlight-group links - `default` so a user's own
            # colorscheme tweaks (:highlight aimdBold ...) always win
            # over these.
            'highlight default link aimdH1 Title',
            'highlight default link aimdH2 Title',
            'highlight default link aimdH3to6 Title',
            'highlight default link aimdHeaderMark Comment',
            'highlight default aimdBold term=bold cterm=bold gui=bold',
            'highlight default aimdItalic term=italic cterm=italic gui=italic',
            'highlight default aimdBoldItalic term=bold,italic cterm=bold,italic gui=bold,italic',
            'highlight default link aimdStrike Comment',
            'highlight default link aimdCode String',
            'highlight default link aimdCodeDelim Comment',
            'highlight default link aimdLink Underlined',
            'highlight default link aimdLinkText Underlined',
            'highlight default link aimdLinkDelim Comment',
            'highlight default link aimdHR Comment',
            'highlight default link aimdBlockquote Comment',
            'highlight default link aimdListMarker Identifier',
            'highlight default link aimdTablePipe Special',
            'highlight default link aimdTableSep Special',
            'highlight default link aimdCodeFence Comment',
            'highlight default link aimdCodeBlock Normal',
        ]
    enddef

    # _FencedCodeRules: the content-dependent half of Render() - one
    # `:syntax region` per fenced code block actually found in `lines`,
    # each restricted to its own exact line range via the `\%NUMl` line
    # atom (so two blocks, same or different language, never bleed
    # into each other) and, when the fence names a language Vim ships a
    # syntax file for, filled with that language's real highlighting
    # via `:syntax include` into a per-block cluster - so e.g. a
    # ```python block and a ```javascript block in the same response
    # each get correct, independent highlighting.
    static def _FencedCodeRules(lines: list<string>): list<string>
        var cmds: list<string> = []
        var blocks = MdSyntaxEmitter.FindFencedCodeBlocks(lines)
        for idx in range(len(blocks))
            var block = blocks[idx]
            var start: number = block.start
            var end: number = block.end
            var lang: string = block.lang
            var region = printf('aimdFenced%d', idx)
            var resolved = MdSyntaxEmitter._ResolveLang(lang)
            var contains = ''

            if !empty(resolved)
                var cluster = printf('aimdLang%d_%s', idx, MdSyntaxEmitter._SafeGroupSuffix(resolved))
                # silent!: not every fence tag names a real Vim
                # filetype with a bundled syntax file (typos, made-up
                # languages, "text", ...) - fall through to the plain
                # body group below rather than erroring the whole
                # render over one bad tag.
                cmds->add(printf('silent! syntax include @%s syntax/%s.vim', cluster, resolved))
                cmds->add('unlet! b:current_syntax')
                contains = printf(' contains=@%s', cluster)
            endif

            # keepend: so an embedded language's own region items (a
            # multi-line string, say) can never grow past this block's
            # own closing fence.
            cmds->add(printf(
                \ 'syntax region %s matchgroup=aimdCodeFence start=/\%%%dl^```/ end=/\%%%dl^```/ keepend%s',
                \ region, start, end, contains))
            if empty(resolved)
                cmds->add(printf('highlight default link %s aimdCodeBlock', region))
            endif
        endfor
        return cmds
    enddef

    # Render: the full, ordered command list for `lines` - callers
    # execute() each one, in order, in the buffer `lines` came from,
    # then set b:current_syntax = 'aimd' themselves (see
    # AIBuffer.ApplyMarkdownHighlighting) - that assignment can't be
    # part of this list, since `:let`/bare-assignment Ex-command
    # strings aren't legal to execute() from a vim9script (E1126),
    # only real vim9 assignment statements are. Leads with `syntax
    # clear` so calling this again on a buffer whose content changed
    # (e.g. a chat log buffer after AppendChatTurn adds another turn)
    # starts from a clean slate rather than accumulating duplicate or
    # stale region definitions from the previous render.
    static def Render(lines: list<string>): list<string>
        return ['silent! syntax clear', 'unlet! b:current_syntax']
            \ + MdSyntaxEmitter._StaticRules()
            \ + MdSyntaxEmitter._FencedCodeRules(lines)
    enddef

endclass
