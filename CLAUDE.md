# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Bitbucket PR helper: a Go CLI binary (`bb`) plus a Neovim Lua plugin that drives it. The CLI talks to **Bitbucket Server 8.9.7** REST API and returns JSON or tabular output. The plugin spawns the CLI asynchronously via `vim.system`, parses JSON, and renders UI (virtual text, floating windows, Diffview).

## Build

```sh
go build -o bb .       # produces ./bb binary
go vet ./...           # lint
```

No external Go dependencies — stdlib only. There are no tests.

The CLI is installed to a location on `$PATH` so the plugin can invoke `bb`. Default config path is `/etc/bb/config.json` (override with `-config`).

## Config

`config.json` fields: `base_url`, `project`, `repo`, `auth` (bearer/basic/none), `token`, `user`, `password`, `state` (OPEN/MERGED/DECLINED/ALL), `limit`, `timeout`, `insecure_tls`.

## Architecture

### Go CLI (`main.go`)

Single-file; all types, API client, and flag handling live there.

- `main()` parses flags then dispatches to the appropriate `client.*` method.
- `Client` wraps `*http.Client` with `setAuth()`, `doJSON()` (generic request), and named methods per API endpoint.
- PR comments are fetched from the **activities** API (`/pull-requests/{id}/activities`), not the comments endpoint, because activities carry anchor/reply-thread context. `flattenCommentTree` walks the nested `Comments` slice into `[]FlatComment`.
- `Anchor.UnmarshalJSON` uses a dual-unmarshal strategy: standard decode first, then raw-map fallback via `pickString`/`pickInt` helpers, because Bitbucket 8.9.7 returns path/line under different keys depending on the activity type.
- Output is either JSON (with `enc.SetIndent`) or a `tabwriter` table.
- Reactions use `/rest/comment-likes/1.0/...` (PUT/DELETE) with automatic fallback to the older likes endpoint for `THUMBS_UP`.

### Neovim plugin (`lua/bb_pr/`)

- `init.lua` — all plugin logic. Requires `bb_pr.reactions`.
- `reactions.lua` — emoji map + `format_line`, `render_choice` helpers, and `all_reaction_choices` list.

**State** is module-level, tab-scoped via `state.pr_by_tab[tab_key]` and `state.comments_by_tab[tab_key]`. A `pending_comments_by_tab` slot holds comments waiting to be applied on the next `BufEnter`.

**Comment rendering**: `apply_comments_to_current_buffer` matches file comments to the current buffer by normalized path (`normalize_repo_path` strips `a/`, `b/`, `./`, leading `/`), then places extmarks (sign + virtual text) via the `bb_pr_comments` namespace. `path_matches` uses suffix matching.

**Diff-side detection**: `current_diff_side()` checks `vim.wo[win].diff` and window column position to return `"left"` / `"right"` / `"single"`. `comment_matches_side` then filters file comments by `file_type` (FROM/TO) and `line_type` (REMOVED/ADDED/CONTEXT).

**PR info window**: built by `build_pr_info_content` → `apply_pr_info_content`. Overview comments appear after the approvals block; line numbers are tracked in `vim.b[buf].bb_pr_overview_comment_lines` and `bb_pr_overview_comment_ids_by_line` for navigation and comment actions.

**Reaction recency**: persisted to `vim.fn.stdpath("state")/bb_pr_reaction_recency.json`; the most-recently used reactions sort first in the picker.

## Development rules (from AGENTS.md)

- Every new comment action must work for **both overview and file-scoped comments**.
- All keymaps must have the `<leader>r` prefix.
- Every keymap must be configurable via `setup({...})`.
