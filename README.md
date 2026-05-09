# bb

Bitbucket PR helper CLI + Neovim plugin.

- Provider command defaults to `bb -reviewers -json` (override via `setup({ provider_cmd = {...} })`).

- `:BBPRList` opens a Telescope picker (when available) so selecting a PR with `<CR>` opens it directly in Diffview.
- If Telescope is not installed, it falls back to the built-in list buffer behavior.
