# bb

**This code was fully vibecoded**

## Roadmap

- review mode support

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

- The PR tab always shows the working tree files on the right, so LSP attaches and you can edit them. Accepted suggestions are written to the file when it is not shown in a window.

- `:BBPRList` opens a Telescope picker (when available) so selecting a PR with `<CR>` opens it directly in Diffview.
- If Telescope is not installed, it falls back to the built-in list buffer behavior.
- CLI: `bb -no-draft` hides draft PRs (title contains `[DRAFT]`) from the PR list; works with both table and `-json` output.
- CLI: `bb -pr-comments <id> -json` returns structured PR comments (overview + file anchors) with timestamps for Neovim overlays (virtual text / floating windows).
- CLI review actions:
  - `bb -pr-review <id> -review-action approve`
  - `bb -pr-review <id> -review-action disapprove`
  - `bb -pr-review <id> -review-action needs-work`
  - Note: `needs-work` requires `user` to be set in config so the participant can be resolved.
- Neovim integration:
  - In `:BBPRInfo` window:
    - `a` approve PR
    - `d` disapprove PR
    - `o` mark PR as needs work
    - after action, PR info window auto-refreshes approval block
  - PR comments are auto-loaded when opening a PR diff and then auto-applied on buffer enter.
  - `:BBPRLoadComments` loads PR comments for the PR opened in current tab and renders virtual text on commented lines.
  - `gc` (normal mode) or `:BBPROpenLineComments` opens a floating window with comments for the current line; in a diff buffer, `gc` on a line without comments opens the new-comment input instead.
  - `[C` / `]C` jump between PR comments (works in both file diffs and PR overview comments).
  - `<leader>rr` (or `:BBPRRefreshComments`) force-refreshes comments from the server to pick up replies from other participants.
  - `<leader>rt` (or `:BBPRToggleTask`) toggles task comments between open/done from PR Info or line-comments float under cursor.
  - `:BBPRReactComment` adds a reaction to the comment under cursor (works for overview comments and file-scoped comments).
  - `<leader>re` (or `:BBPRReactComment`) toggles a reaction on the comment under cursor (adds if absent, removes if it is already yours), and can be customized via `setup({ react_comment_map = "..." })`.
  - `<leader>rx` (or `:BBPRDeleteComment`) deletes the comment under cursor (supports both overview comments and file-scoped comments), and can be customized via `setup({ delete_comment_map = "..." })`.
  - `<leader>rv` (or `:BBPRResolveComment`) toggles the resolve state of the comment thread under cursor (resolve if open, unresolve if already resolved). Works for both regular comment threads and task comments, in both overview and file-scoped contexts. Resolved threads are shown with a `[~]` prefix instead of `-`. Mapping is configurable via `setup({ resolve_comment_map = "..." })`.
  - `<leader>rs` (or `:BBPRCreateSuggestion`) opens the comment editor with a prefilled Markdown suggestion block for the commented line in one step. If cursor is on an existing overview or file-scoped comment, it creates a suggestion **reply** to that comment:

    ```suggestion
    <current line text>
    ```

    Mapping is configurable via `setup({ create_suggestion_map = "..." })`.
  - `<leader>rA` (or `:BBPRAcceptSuggestion`) applies the first ```suggestion``` block from the comment under cursor directly to the commented file line (file-scoped comments only). Path matching is normalized (including diffview-style paths and `a/`/`b/` prefixes) before apply, and the edit is applied to the real file buffer (not the diffview virtual buffer). After applying, commit and push with git manually.
    Mapping is configurable via `setup({ accept_suggestion_map = "..." })`.
  - Reaction choices are configurable via `setup({ reaction_choices = { "THUMBS_UP", "HEART", "LAUGH" } })`, and now default to the full rxaviers GitHub emoji reaction list.
  - Reaction picker entries are rendered as emoji/symbol + alias (for example `👍  THUMBS_UP`) so large reaction sets stay readable.
  - Reaction picker ordering is recency-based and persistent: the most recently applied reactions are shown first across Neovim restarts (path configurable via `reaction_recency_store_path`).
  - Last-view tracking: `setup({ since_last_view = { enabled = true, store_path = <state>/bb_pr_seen.json, max_count = 200, diff_map = "<leader>rn", viewed_map = "<leader>rv", use_bitbucket_baseline = true, sort_done_last = true } })`. Records when each PR was last viewed (seen commit and comment counts) so changes since then can be shown; `max_count` caps stored PRs (oldest evicted, their `refs/bb_pr/seen/...` git refs deleted), `diff_map` is the mapping for the since-last-view diff, `viewed_map` the mapping that toggles a file's viewed mark, `use_bitbucket_baseline` falls back to Bitbucket's own last-reviewed commit. `sort_done_last` moves done PRs to the end of the PR list (see below).
  - The PR list (`:BBPR`, Telescope and the plain buffer) starts each line with a since-last-view column: `·` you never opened the PR and have not reviewed it in Bitbucket, `◆` new commits since your last view (or, never opened, since the commit you last approved / marked needs-work on in Bitbucket), `+N` N new comments and tasks since your last view (only for PRs you have opened); `◆+3` shows both. The column is blank when nothing changed, for your own PRs and for PRs that are not OPEN. It is computed from the local store only. With `since_last_view.sort_done_last` (default), done PRs go to the end of the list, keeping their relative order: open PRs of others with a blank column whose files you all viewed (`Files viewed: y/y` in PR Info) at the current PR tip. New commits make a PR not done again, and so do new comments or tasks and unmarking a file. A list showing MERGED or DECLINED PRs (bb config `state`) drops their stored records and `refs/bb_pr/seen/...` refs. Without `since_last_view.enabled` the column is absent.
  - `<leader>rn` (or `:BBPRSinceLastView`) in a PR tab opens a separate Diffview of the commits added since your last view (`<seen commit>..<PR tip>`). Nothing opens when there is no earlier view, no new commits, or the PR is your own. A seen commit missing locally (e.g. Bitbucket's last-reviewed commit) is fetched once from `origin`; if that fails, you get a notice instead. When the merge base moved since then (the author merged the target branch or rebased), the diff is limited to the PR's own files and you are told so. The diff tab is not a PR tab: close it with `:DiffviewClose`. Registered only with `since_last_view.enabled`; the mapping is `since_last_view.diff_map`.
  - `<leader>rv` (or `:BBPRToggleViewed`) toggles the viewed mark of PR files in a PR tab. In the Diffview file panel it toggles the file under the cursor; on a directory line, all PR files under that directory. In visual mode in the panel it takes every selected file, with directory lines expanded to their files. In a diff buffer it toggles the file shown. A set of files is marked viewed when any of them is not viewed yet, otherwise all of them are unmarked. A file you unmark while it is shown stays unviewed until you switch to another file and back. Your own PRs and PRs that are not OPEN are not tracked; while the state of the PR files is still loading you get a notice instead. Registered (normal and visual mode) only with `since_last_view.enabled`; the mapping is `since_last_view.viewed_map`.
  - In a tracked PR tab the Diffview file panel dims the rows of viewed files (highlight group `BbPrViewedFile`, linked to `Comment` by default); the 💬 sign of files with comments stays. PR Info shows `Files viewed: x/y` (viewed files out of the PR's files) in its "Since Last View" section once the state of the PR files has loaded, and updates it on every mark and unmark.
  - PR Info shows `Changes: <N> files, +<added> -<deleted>` after the `Opened:` line (before `Merge: CONFLICT ...`) for the PR of its own PR tab; PR Info opened from the list for a PR without a tab has no such line. It is counted locally with `git diff --numstat -M` from the merge base of the PR branch and the target to the PR branch tip, as in Bitbucket (renames count once, whitespace changes count, binary files count as files with no lines), and appears once the background git run finishes; on git failure it is absent and the error is only logged. It can differ from the per-file `+/-` in the Diffview file panel, which compare the target tip with the working tree.
  - Opening a PR opens its PR Info once per PR tab, as soon as the comments have loaded (or failed to load, then without them); later comment reloads do not reopen it. In a tracked tab the file shown is marked viewed only once you close PR Info. If you are on another tab by then, it opens when you return to the PR tab. When the PR was opened to jump to a specific comment, it opens only if that jump fails.
  - PR create body can be prefilled from config via `setup({ create_pr_body_template = "..." })` (string with newlines) or `setup({ create_pr_body_template = { "line 1", "line 2" } })`.
  - PR target branch selection is loaded from Bitbucket branch API; when unavailable/empty, plugin asks you to type any target branch manually (no hardcoded `main`/`master` fallback).
  - `:BBPRMerge` merges the PR opened in the current tab and prompts for merge commit message.
  - Before merge, CLI runs Bitbucket mergeability precheck (`.../pull-requests/{id}/merge` GET). If user has no merge permissions, error now includes explicit hint about required rights (`REPO_WRITE` + branch merge permissions).
  - Merge message defaults:
    - title: title of the latest commit in the PR branch
    - body: generated from `setup({ merge_pr_body_template_fn = function(commits) ... end })`, where `commits` is a list from Bitbucket API.
  - Merge mapping defaults to `<leader>rm` and can be changed via `setup({ merge_pr_map = "..." })`.
  - Merge conflicts do not block review: when the PR branch conflicts with its target, the PR still opens with the full diff against the target, and conflicted files carry inline `<<<<<<<` markers. The conflict is reported with a warning and marked as `Merge: CONFLICT with origin/<target>` in the `:BBPRInfo` header. For a 3-way resolve, run `:DiffviewOpen` with no arguments — Diffview only builds its **Conflicts** section for a revless invocation, since `git diff --name-status <rev>` reports unmerged paths as `M` rather than `U`.
  - Leaving a conflicted PR is automatic: opening another PR first runs `git merge --abort` (falling back to `git reset --hard HEAD`) so the new branch can be checked out. Only a real in-progress merge is rolled back — an ordinary dirty working tree is still reported instead of being reset, and untracked files are never removed.
  - `<leader>rq` (or `:BBPRClose`) closes the open PR tabs and rolls back the conflicted merge without opening another PR. Mapping is configurable via `setup({ pr = { close_map = "..." } })`.
  - `<leader>rb` (or `:BBPRBrowse`) opens the most specific thing at the cursor in the browser: a comment, else a PR file, else the PR. `:BBPRBrowse pr|file|comment` opens that kind only and warns when there is none at the cursor.
    - PR list (Telescope and the plain buffer): the PR under the cursor (Telescope keeps the list open).
    - PR Info: the comment or reply on the cursor line, else the PR (also for a PR opened from the list without a tab).
    - Line comments float: the comment or reply on the cursor line.
    - Diff buffer of a PR tab: the file in the Bitbucket PR diff at the cursor line, translated to Bitbucket's line numbers (left side: the original version, right side: the PR branch). A line that is not in the PR diff (e.g. from the merged target branch) opens the file without a line and tells you why.
    - Diffview file panel: the file on the cursor line; a directory line opens the PR.
    - Any other buffer of a PR tab: the PR.
    URLs come from the PR's Bitbucket link and open with `vim.ui.open()` (as do Jira tickets and attachments). Keys: `setup({ browse = { map = "<leader>rb", float_map = "gx", picker_map = "<C-o>" } })` — `map` is global, `float_map` works in PR Info, the line comments float, the plain PR list buffer and Telescope normal mode, `picker_map` in Telescope insert mode; `""` disables a key. The diff buffers keep the built-in `gx`.

  - Your own reactions are marked with `(you)` in comment popups/overview so you can quickly see what you already added.
