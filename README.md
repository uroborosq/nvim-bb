# bb

**This code was fully vibecoded**

Bitbucket PR helper CLI + Neovim plugin.

- Provider command defaults to `bb -reviewers -json` (override via `setup({ provider_cmd = {...} })`).
- Comment jump mappings default to `[C` / `]C` and can be changed via `setup({ comment_prev_map = "...", comment_next_map = "..." })`.

- `:BBPRList` opens a Telescope picker (when available) so selecting a PR with `<CR>` opens it directly in Diffview.
- If Telescope is not installed, it falls back to the built-in list buffer behavior.
- CLI: `bb -pr-comments <id> -json` returns structured PR comments (overview + file anchors) with timestamps for Neovim overlays (virtual text / floating windows).
- Neovim integration:
  - PR comments are auto-loaded when opening a PR diff and then auto-applied on buffer enter.
  - `:BBPRLoadComments` loads PR comments for the PR opened in current tab and renders virtual text on commented lines.
  - `gc` (normal mode) or `:BBPROpenLineComments` opens a floating window with comments for the current line.
  - `[C` / `]C` jump between PR comments (works in both file diffs and PR overview comments).
