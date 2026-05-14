# bb

**This code was fully vibecoded**

## Roadmap

- pr creation
- merge (is it possible?)
- comments deletion
- comments resolving
- all comments overview
- etwa dashboard
- images (haha)
- jira issues resolving

## Overview

Bitbucket PR helper CLI + Neovim plugin.

- Provider command defaults to `bb -reviewers -json` (override via `setup({ provider_cmd = {...} })`).
- Comment jump mappings default to `[C` / `]C` and can be changed via `setup({ comment_prev_map = "...", comment_next_map = "..." })`.
- Force refresh mapping defaults to `<leader>pr` and can be changed via `setup({ refresh_comments_map = "..." })`.

- `:BBPRList` opens a Telescope picker (when available) so selecting a PR with `<CR>` opens it directly in Diffview.
- If Telescope is not installed, it falls back to the built-in list buffer behavior.
- CLI: `bb -pr-comments <id> -json` returns structured PR comments (overview + file anchors) with timestamps for Neovim overlays (virtual text / floating windows).
- CLI review actions:
  - `bb -pr-review <id> -review-action approve`
  - `bb -pr-review <id> -review-action disapprove`
  - `bb -pr-review <id> -review-action needs-work`
  - Note: `needs-work` requires `user` to be set in config so the participant can be resolved.
- Neovim integration:
  - In `:BBPRInfo` window:
    - `<leader>ra` approve PR
    - `<leader>rd` disapprove PR
    - `<leader>rn` mark PR as needs work
    - after action, PR info window auto-refreshes approval block
  - PR comments are auto-loaded when opening a PR diff and then auto-applied on buffer enter.
  - `:BBPRLoadComments` loads PR comments for the PR opened in current tab and renders virtual text on commented lines.
  - `gc` (normal mode) or `:BBPROpenLineComments` opens a floating window with comments for the current line.
  - `[C` / `]C` jump between PR comments (works in both file diffs and PR overview comments).
  - `<leader>pr` (or `:BBPRRefreshComments`) force-refreshes comments from the server to pick up replies from other participants.
  - `<leader>pt` (or `:BBPRToggleTask`) toggles task comments between open/done from PR Info or line-comments float under cursor.
  - `:BBPRReactComment` adds a reaction to the comment under cursor (works for overview comments and file-scoped comments).
  - `<leader>re` (or `:BBPRReactComment`) toggles a reaction on the comment under cursor (adds if absent, removes if it is already yours), and can be customized via `setup({ react_comment_map = "..." })`.
  - `<leader>rs` (or `:BBPRCreateSuggestion`) opens the comment editor with a prefilled Markdown suggestion block for the commented line in one step:
    ```suggestion
    <current line text>
    ```
    Mapping is configurable via `setup({ create_suggestion_map = "..." })`.
  - Reaction choices are configurable via `setup({ reaction_choices = { "THUMBS_UP", "HEART", "LAUGH" } })`, and now default to the full rxaviers GitHub emoji reaction list.
  - Reaction picker entries are rendered as emoji/symbol + alias (for example `👍  THUMBS_UP`) so large reaction sets stay readable.
  - Reaction picker ordering is recency-based and persistent: the most recently applied reactions are shown first across Neovim restarts (path configurable via `reaction_recency_store_path`).

  - Your own reactions are marked with `(you)` in comment popups/overview so you can quickly see what you already added.
