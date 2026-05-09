# bb

Bitbucket PR helper CLI + Neovim plugin.

- Provider command defaults to `bb -reviewers -json` (override via `setup({ provider_cmd = {...} })`).

- `:BBPRList` opens a Telescope picker (when available) so selecting a PR with `<CR>` opens it directly in Diffview.
- If Telescope is not installed, it falls back to the built-in list buffer behavior.
- CLI: `bb -pr-comments <id> -json` returns structured PR comments (overview + file anchors) with timestamps for Neovim overlays (virtual text / floating windows).
- Neovim integration:
  - `:BBPRLoadComments` loads PR comments for the PR opened in current tab and renders virtual text on commented lines.
  - `gc` (normal mode) or `:BBPROpenLineComments` opens a floating window with comments for the current line.
