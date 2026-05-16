# bb

**This code was fully vibecoded**

## Roadmap

- merge (is it possible?)
- code suggestions
- comments deletion
- comments resolving
- etwa dashboard
- images (haha)
- jira issues resolving
- auto repo recognition

## Overview

Bitbucket PR helper CLI + Neovim plugin.

- Provider command defaults to `bb -reviewers -json` (override via `setup({ provider_cmd = {...} })`).
- Repository/project selection for CLI calls:
  - explicit override flags: `-project <PROJECT_KEY> -repo <repo-slug>`
  - force auto-detection from git remote: `-force-autodetect-repo` (ignores `config.project`/`config.repo` unless explicit `-project`/`-repo` are passed)
  - auto-detection from local git remote (`origin`, fallback `upstream`) when config/flags omit project or repo
  - supports both Bitbucket URL styles:
    - user repo style (for example `.../scm/~username/repo.git`)
    - project repo style (for example `.../scm/PROJ/repo.git`)
- Comment jump mappings default to `[C` / `]C` and can be changed via `setup({ comment_prev_map = "...", comment_next_map = "..." })`.
- In Neovim plugin, you can force CLI repo autodetection for all bb commands via:
  - by default it is enabled (`force_repo_autodetect = true`)
  - you can disable it explicitly: `setup({ force_repo_autodetect = false })`
  - optional flag override: `setup({ force_repo_autodetect_flag = "-force-autodetect-repo" })`
- Force refresh mapping defaults to `<leader>rr` and can be changed via `setup({ refresh_comments_map = "..." })`.

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
  - `<leader>rr` (or `:BBPRRefreshComments`) force-refreshes comments from the server to pick up replies from other participants.
  - `<leader>rt` (or `:BBPRToggleTask`) toggles task comments between open/done from PR Info or line-comments float under cursor.
  - `:BBPRReactComment` adds a reaction to the comment under cursor (works for overview comments and file-scoped comments).
  - `<leader>re` (or `:BBPRReactComment`) toggles a reaction on the comment under cursor (adds if absent, removes if it is already yours), and can be customized via `setup({ react_comment_map = "..." })`.
  - `<leader>rs` (or `:BBPRCreateSuggestion`) opens the comment editor with a prefilled Markdown suggestion block for the commented line in one step. If cursor is on an existing overview or file-scoped comment, it creates a suggestion **reply** to that comment:
    ```suggestion
    <current line text>
    ```

    Mapping is configurable via `setup({ create_suggestion_map = "..." })`.
  - `<leader>rA` (or `:BBPRAcceptSuggestion`) applies the first ```suggestion``` block from the comment under cursor directly to the commented file line (file-scoped comments only). After applying, commit and push with git manually.
    Mapping is configurable via `setup({ accept_suggestion_map = "..." })`.
  - Reaction choices are configurable via `setup({ reaction_choices = { "THUMBS_UP", "HEART", "LAUGH" } })`, and now default to the full rxaviers GitHub emoji reaction list.
  - Reaction picker entries are rendered as emoji/symbol + alias (for example `👍  THUMBS_UP`) so large reaction sets stay readable.
  - Reaction picker ordering is recency-based and persistent: the most recently applied reactions are shown first across Neovim restarts (path configurable via `reaction_recency_store_path`).
  - PR create body can be prefilled from config via `setup({ create_pr_body_template = "..." })` (string with newlines) or `setup({ create_pr_body_template = { "line 1", "line 2" } })`.

  - Your own reactions are marked with `(you)` in comment popups/overview so you can quickly see what you already added.
