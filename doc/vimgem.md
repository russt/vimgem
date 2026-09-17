# VIMGEM README.md Version 0.1.260914

A rich AI-assisted coding environment for Vim, supporting Gemini, Claude, OpenAI, and local models.

---

## Requirements

- Vim 9.1 or greater
- `curl` in your `$PATH`
- `jq` in your `$PATH` (for JSON pretty-print of chat histories)
- An API key from Google and/or Anthropic (for cloud models)
- A network URL for any local models (recommend [LM Studio](https://lmstudio.ai) for managing local models)

---

## Installation

Assuming you have copied the vimgem release `*.tgz` files to your home directory:

**Simple install (no plugin manager, shared plugins):**
```sh
cd ~/.vim
tar xvf ~/vimgem_0.1.260827_nopack.tgz
```

**With a plugin manager:**
```sh
cd ~/.vim/pack/myplugins/start/
tar xvf ~/vimgem_0.1.260827_pack.tgz
```
---

## Verifying the Installation

**1. Open Vim:**
```sh
vim
```

**2. Check the help file** (works even if your Vim is too old to run the plugin):
```vim
:h vimgem
```

**3. Show keyboard mappings** (a full listing appears if the plugin installed successfully):
```vim
:map \
```

**4. Show plugin info and configuration:**
```vim
:AIInfo
```
> Keyboard shortcut: `\i`

---

## Configuration

Global options can be `set` in `~/.vimrc` or in the `VIMINIT` environment variable:

```vim
let g:ai_provider = "gemini"
let g:show_prompt = 1
let g:always_review_received_files = 1
let g:set_debug_levels = '1-2,5,6'
let g:ai_html_display_url = 'http://127.0.0.1:8765'
```

### Example `:AIInfo` Output

```
# AI Plugin Information

## Configuration
  vimgem version: 0.1.260914
  Current Provider: gemini
  Show Prompt: Yes
  Curl Trace Level: 9
  Always Review Received Files: Yes
  Chat Home: ~/.vimgem/ai-chat

## GEMINI Configuration
  Model (default): gemini-3.5-flash-lite
  API Version: v1
  API Key: Set
```

---

## Commands

| Command | Description |
|---|---|
| `:AIProvider <name>` | Set provider, one of {gemini, claude, openai} |
| `:AIQuery <prompt>` | Ask AI a question |
| `:AIChat` | Open a persistent chat buffer |
| `:AIChatSend` | Send the chat buffer |
| `:AIChatClear` | Clear this chat's history |
| `:AIChatHistory` | List saved chat sessions |
| `:AIChatResume` | Resume a chat session |
| `:AIChatDelete` | Delete chat under cursor in AIChatHistory buffer |
| `:AIChatDisplay` | Open chat in default browser |
| `:AIAsk` | Send selected text as prompt |
| `:AIExplain` | Explain selected code |
| `:AIReview` | Review selected code |
| `:AIReviewFile` | Review entire file |
| `:AIModels` | List available models |
| `:AIInfo` | Show information for chat or globally, depending on context |
| `:AIModel [model]` | Set model for current provider for chat or globally, depending on context |
| `:AIPrompt {on, off}` | Toggle whether responses include the prompt |
| `:AIReviewReceived {on, off}` | Set review behavior for received files |
| `:AIUrl [url]` | Set base URL (OpenAI provider only) |
| `:AISet [key] [value]` | Get/set any config key |
| `:DBGSet [levels]` | Configure active debug levels (e.g. `1,2`, `1-4`, `0` to disable) |
| `:DBGShowLog` | Display the debug message log for this session |
| `:DBGShowAST` | Display the Markdown AST for the current buffer |
| `:DBGShowJson` | Display human-readable API interactions |

---

## Key Mappings

| Mode | Key | Command |
|---|---|---|
| normal | `\i` | `:AIInfo` |
| normal | `\p` | `:AIProvider` |
| normal | `\l` | `:AIModels` |
| normal | `\m` | `:AIModel` |
| normal | `\c` | `:AIChat` |
| normal | `\s` | Send current line + `v:count` lines via `:AIChatSend` |
| visual | `\s` | `:AIChatSend` (selected text) |
| normal | `\r` | `:AIChatResume` |
| normal | `\h` | `:AIChatHistory` |
| normal | `\d` | `:AIChatDelete` |
| normal | `\v` | `:AIChatDisplay` |
| normal | `\w` | `:AIReviewReceived` |
| normal | `\g` | `:DBGShowLog` |
| normal | `\j` | `:DBGShowJson` |

---

## Architecture Notes

- **Curl calls are synchronous** — you wait for the response, but you can run as many Vim sessions as you like in parallel.
- **Chats are stored as triplets** (`*.md`, `*.json`, `*.html`), default location `~/.vimgem/ai-chats`. Change this location freely; copy the directory to preserve history.
- The `*.json` file holds the raw API interactions, rendered in human-readable form by `:DBGShowJson` (`\j`). Requires `jq`.
- Chats are **re-rendered to `.html`** after each turn; view in your default browser with `:AIChatDisplay` (`\v`).
- **Markdown is rendered** by an included vim9script Markdown parser that produces an Abstract Syntax Tree (AST). View the AST with `:DBGShowAST`. Separate emitters generate HTML and Vim syntax coloring from the AST.
- **Message logs** are stored in `~/.vimgem/log`, numbered by Vim session PID. Display the current log with `:DBGShowLog` (`\g`).
- The **chat triplet is autosaved** after each AI turn. Rewrite the chat (`*.md` buffer) any time you want. Editing the chat buffer has no effect on the chat history saved in the *.json file. However, see `:AIChatClear`
- **Resuming the same chat from multiple Vim sessions** will trigger a Vim swap file warning.
- **Elapsed time** can be calculated using the timestamps displayed with each turn, measured from send to response.
- **Each chat session has its own configuration** (provider, model). Use `:AIInfo` from within a chat buffer to see that chat's context. Outside a chat buffer, `:AIInfo` shows the global configuration.

---

## Selected Release Notes

### v0.1.260914

* New Feature - colorized html markdown rendering! See colorized code-blocks in your favorite programming languages.
  - Feature uses builtin vim syntax coloring for hundreds of languages.  For color to appear in html, you must have it turned on:
```vim
:syntax on
:colorscheme (opional - <tab> to see the many choices)
```
* New Feature - Colorized markdown display in browser for arbitray files:
  - added `:AIMarkdownDisplay` (\k) command, which renders any buffer to html and displays in browser.
  - `:AIChatDisplay` (\v) will still render chat markdown, and uses same rendering path as \k.

* New Feature - markdown tables now appear in style when rendered to html.  No more boring tables!

* New Feature - added `:VimgemDoc` command, to view `doc/vimgem.md` (this README file). Use \k to see it in browser.

* New Feature - added helper `vimgem-server.go` - a standalone html *relay* server, used to display html-rendered markdown on a remote browser. For example, you can point an ssh session on a headless vimgem instance to render html on your laptop browser.
  - The server is written in Go, and requries compilation.
    + See: `helpers/server/vimgem-server.go` for build instructions and usage.
    + Use `g:ai_html_display_url` `.vimrc` or `VIMINIT` setting to configure vimgem-server host:port
```vim
let g:ai_html_display_url = 'http://127.0.0.1:8765'
```
- New feature (debugging) -  added `g:set_debug_levels` vim setup variable, to configure debug levels at vim initialization time.
```vim
let  g:set_debug_levels = '1-2,5,6'
```
* Major improvements in vim syntax markdown coloring emitter performance. Now walks AST to isolate correct application of `aimd` (vimgem-ai-markdown) syntax rules. Pre-examines each node's text to avoid unneccesary and expensive calls to vim syntax engine.  

* Major improvements in html markdown rendering, adding syntax coloring:
  - Now renders colorized code-blocks for html display using native vim syntax coloring rules.
  - This is done in pure vim9script, using C-level builtins (synID()/synIDattr()) for vim character-level syntax coloring.
  - This process was further optimized by eliminating buffer management overhead - making html rendering nearly instantenous.
  - The legacy ":TOhtml" command, used for file-level conversion, lended guidance for this effort.

* Bug fix - add `vim9script` alias for "vim" language type in fenced code-blocks. Moved ResolveLang() function to util.vim, since it is a static table for defining common programming language aliases.

* Bug fix - correct markdown AST to handle list items correctly (not break on space), and to allow codeblocks as list-items.

* UX fix - always fully render chat buffer (\v) to html, eliminating check for turn-generated cached version. Nobody wants stale html.

- README.md now displays release version.

* added copyright and MIT License notices to all vimgem sources.


### v0.1.260827

- `:AIInfo` is now context-sensitive: displays chat session configuration when called from a chat buffer.
- `:AIProvider` now changes only the current chat session's provider when launched from a chat buffer.
- `:AIModels` displays models for the chat session's provider when launched from a chat buffer.
- `:AIModel` can be selected from the `:AIModels` list for the current chat provider.
- Added `GetAllChatSessions` to show all chat sessions in `:AIInfo`, with the current chat marked `*`.
- Rearchitected `prompt.vim`; fixed download macros and register macro expansions.

> **Note:** Upload/download testing **passed** on `qwen2.5-coder-7b-instruct-mlx` and **failed** on `qwen2.5-coder-1.5b-instruct-mlx`.

### v0.1.260825

- Added `:DBGSet` command for per-level curl tracing (try `:DBGSet 9`).
- Added `:DBGShowAST` command to display the Markdown AST for any buffer.
- Added `:DBGShowLog` to display the auto-updated message log.
- Added `:DBGShowJson` to display human-readable API interactions (requires `jq`).
- Rearchitected chat configurations: multiple chats per Vim session, each with its own provider/model.
- Rearchitected API message parsing: now returns `<dict>` instead of raw text.
- Fixed bug in upper-layer API message parsing (was scanning for an error that always matched provider source).
- Fixed bugs introduced by a substandard coding assistant, including `:AIModels` where the entire `ListModels()` implementation for Gemini was deleted.
- Updated help file; added version.

## License

Copyright (c) 2025-2026 Russ Tremain.
Released under the MIT License. See [LICENSE](LICENSE) for details.
