local M = {}
local reactions = require("bb_pr.reactions")
local linemap = require("bb_pr.linemap")

local default_config = {
	-- internals
	provider_cmd = { "bb", "-reviewers", "-builds", "-json" },
	comments_cmd = { "bb", "-json", "-pr-comments" },
	builds_cmd = { "bb", "-json", "-pr-builds" },
	force_repo_autodetect = true,
	force_repo_autodetect_flag = "-force-autodetect-repo",
	diffview_cmd = "DiffviewOpen",
	-- what the right side of the PR tab shows:
	--   "worktree": the working tree files (LSP, editing; every new file runs the
	--               full BufRead/FileType chain, so the first open is slower)
	--   "commits":  read-only diffview buffers of the merge commit (faster to open,
	--               no LSP); falls back to "worktree" when the merge conflicts
	diff_mode = "worktree",

	-- comment actions: popup windows use the key as-is; diff buffer prepends "g"
	comments = {
		prev_map = "[C",
		next_map = "]C",
		refresh_map = "<C-r>",
		reply_map = "r",
		react_map = "R",
		reaction_users_map = "gK",
		delete_map = "D",
		edit_map = "u",
		resolve_map = "<space>",
		toggle_task_map = "<Tab>",
		convert_task_map = "t",
		create_map = "C",
		create_task_map = "K",
		create_suggestion_map = "s",
		accept_suggestion_map = "A",
		-- inside the comment input window: submit the text as a comment or as a task
		submit_comment_map = "<C-s>",
		submit_task_map = "<C-t>",
	},

	-- reactions
	reactions = {
		default = "THUMBS_UP",
		-- merge_config deep-copies the defaults, so the shared list is never mutated
		choices = reactions.all_reaction_choices,
		recency_store_path = vim.fn.stdpath("state") .. "/bb_pr_reaction_recency.json",
	},

	-- PR overview window
	overview = {
		approve_map = "a",
		disapprove_map = "d",
		needs_work_map = "o",
		edit_description_map = "<CR>",
		open_file_map = "gf",
		open_image_map = "i",
	},

	-- PR management (global keymaps + templates)
	pr = {
		create_map = "<leader>rC",
		create_toggle_draft_map = "<leader>rt",
		create_body_template = "",
		merge_map = "<leader>rm",
		merge_body_template_fn = nil,
		close_map = "<leader>rq",
	},

	-- Jira
	jira = {
		base_url = "",
		open_map = "J",
		open_url_map = "o",
	},

	-- stats
	stats = {
		map = "<leader>rS",
		repos = "",
		project = "",
		since_days = 30,
		concurrency = 10,
		top = 20,
		ignore_users = "",
	},

	-- drafts
	drafts = {
		store_path = vim.fn.stdpath("state") .. "/bb_pr_drafts.json",
		max_count = 50,
		-- autosave while typing; the draft also survives :qa and terminal close
		autosave_debounce_ms = 400,
	},

	-- debug log: rotated when it exceeds max_size_bytes or max_age_seconds
	log = {
		path             = vim.fn.stdpath("state") .. "/bb_pr.log",
		max_size_bytes   = 1024 * 1024,
		max_age_seconds  = 24 * 60 * 60,
	},
}
M.config = vim.deepcopy(default_config)

local state = {
	prs = {},
	-- tab_key -> per-tab state (see tab_state):
	--   pr, comments, pending_comments (applied by the next BufEnter/CursorMoved), builds,
	--   conflict ({ to_ref } while the PR branch sits on an unresolved merge),
	--   diff_base ({ root, base, source }: the commits Bitbucket anchors FROM / TO lines to)
	tabs = {},
	comment_ns = vim.api.nvim_create_namespace("bb_pr_comments"),
	diffview_panel_ns = vim.api.nvim_create_namespace("bb_pr_diffview_panel"),
	git_text_cache = {},
	hunks_cache = {},
	buf_hunks_cache = {},
	-- bufnr -> what the comment extmarks of that buffer were last rendered from
	rendered_by_buf = {},
	-- diffview file panel bufnr -> what its comment signs were last rendered from
	panel_rendered_by_buf = {},
	pending_nav_by_pr_id = {},
	reaction_usage_by_key = {},
	reaction_usage_seq = 0,
	drafts = {},
	-- bufnr -> { [line] = { comment, ... } }; kept in Lua because vim.b turns the sparse
	-- line-keyed table into a list as long as the last commented line on every write/read
	line_comments_by_buf = {},
	-- bufnr -> what a comment view buffer shows (Lua-side for the same reason):
	--   kind = "float" (line comments float) or "overview" (PR Info),
	--   ids_by_line = { [line] = comment_id } for the lines that act on a comment,
	--   reaction_segments = { [line] = { comment_id, segments } } for reaction lines,
	--   thread_lines (overview) = ascending lines of the "### Thread" headings,
	--   pr (overview) = the PR the buffer renders
	comment_view_by_buf = {},
}

local function rotate_log_if_needed(path, max_size, max_age)
	local stat = vim.uv and vim.uv.fs_stat(path) or vim.loop.fs_stat(path)
	if not stat then
		return
	end
	local too_big = max_size and stat.size > max_size
	local mtime = (stat.mtime and stat.mtime.sec) or 0
	local too_old = max_age and (os.time() - mtime) > max_age
	if too_big or too_old then
		os.remove(path)
	end
end

local function log(...)
	local cfg = M.config.log or {}
	local path = cfg.path
	if not path or path == "" then
		return
	end
	rotate_log_if_needed(path, cfg.max_size_bytes, cfg.max_age_seconds)
	local parts = {}
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if type(v) == "table" then
			parts[#parts + 1] = vim.inspect(v, { indent = "", newline = " " })
		else
			parts[#parts + 1] = tostring(v)
		end
	end
	local fd = io.open(path, "a")
	if not fd then
		return
	end
	fd:write(string.format("[%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), table.concat(parts, " ")))
	fd:close()
end

local function tab_key(tabpage)
	return tostring(tabpage)
end

-- Per-tab state of `tabpage` (default: current tab), created on first use.
local function tab_state(tabpage)
	local key = tab_key(tabpage or vim.api.nvim_get_current_tabpage())
	local ts = state.tabs[key]
	if not ts then
		ts = {}
		state.tabs[key] = ts
	end
	return ts
end

local function set_tab_pr(tabpage, pr, opts)
	local ts = tab_state(tabpage)
	ts.pr = pr
	if not (opts and opts.preserve_comments) then
		ts.comments = nil
	end
end

local function set_current_tab_pr(pr, opts)
	set_tab_pr(nil, pr, opts)
end

local function get_tab_pr(tabpage)
	return tab_state(tabpage).pr
end

local function get_current_tab_pr()
	return get_tab_pr()
end

local function format_opened_age(ms)
	if type(ms) ~= "number" or ms <= 0 then
		return "unknown"
	end

	local seconds = os.time() - math.floor(ms / 1000)
	if seconds < 0 then
		seconds = -seconds
	end

	local days = math.floor(seconds / 86400)
	if days >= 365 then
		return string.format("%dy%dd", math.floor(days / 365), days % 365)
	end
	if days >= 1 then
		return string.format("%dd", days)
	end

	local hours = math.floor(seconds / 3600)
	if hours > 0 then
		return string.format("%dh", hours)
	end

	return string.format("%dm", math.floor(seconds / 60))
end

local function normalize_my_review_status(pr)
	local raw = type(pr.my_review_status) == "string" and string.upper(pr.my_review_status) or ""
	if raw ~= "" then
		return raw
	end
	if pr.my_approved == true then
		return "APPROVED"
	end
	return "UNKNOWN"
end

local function format_my_review_marker(pr)
	local st = normalize_my_review_status(pr)
	if st == "APPROVED" then
		return "+"
	end
	if st == "NEEDS_WORK" then
		return "x"
	end
	if st == "NOT_REVIEWER" or st == "UNKNOWN" then
		return "-"
	end
	return "?"
end

-- build state -> marker, shared by the PR list and the PR Info "## Build" section
local BUILD_ICONS = {
	SUCCESSFUL = "✓",
	FAILED = "✗",
	INPROGRESS = "●",
	NONE = "○",
}

local function format_build_marker(pr)
	local st = type(pr.build_status) == "string" and string.upper(pr.build_status) or ""
	return BUILD_ICONS[st] or " "
end

-- APPROVED / NEEDS_WORK / UNAPPROVED / PENDING (no status), or the upper-cased raw status
local function reviewer_status(reviewer)
	if reviewer.approved or reviewer.status == "APPROVED" then
		return "APPROVED"
	end
	local raw = type(reviewer.status) == "string" and string.upper(reviewer.status) or ""
	return raw == "" and "PENDING" or raw
end

local function format_pr_entry(pr)
	local approvals = 0
	local has_needs_work = false
	for _, reviewer in ipairs(pr.reviewers or {}) do
		local status = reviewer_status(reviewer)
		if status == "APPROVED" then
			approvals = approvals + 1
		elseif status == "NEEDS_WORK" then
			has_needs_work = true
		end
	end
	local needs_work_status = has_needs_work and "NW" or "OK"

	return string.format(
		"%s appr: %d %s %s • open %s, comm %s • %s - %s",
		format_build_marker(pr),
		approvals,
		needs_work_status,
		format_my_review_marker(pr),
		format_opened_age(pr.createdDate),
		format_opened_age(pr.updatedDate),
		pr.author.user.displayName,
		pr.title or ""
	)
end

-- Lists (e.g. provider_cmd) in the user config replace the default list wholesale.
local function merge_config(user)
	M.config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), user or {})
end

-- Decoded JSON object stored at `path`, or nil when the path is unset, missing or invalid.
local function read_json_file(path)
	path = tostring(path or "")
	if path == "" then
		return nil
	end
	local ok_read, lines = pcall(vim.fn.readfile, path)
	if not ok_read or type(lines) ~= "table" or #lines == 0 then
		return nil
	end
	local ok_json, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
	if not ok_json or type(decoded) ~= "table" then
		return nil
	end
	return decoded
end

local function write_json_file(path, data)
	path = tostring(path or "")
	if path == "" then
		return
	end
	pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p")
	pcall(vim.fn.writefile, { vim.json.encode(data) }, path)
end

local function load_reaction_recency_state()
	local decoded = read_json_file(M.config.reactions.recency_store_path)
	if not decoded then
		return
	end
	state.reaction_usage_by_key = type(decoded.by_key) == "table" and decoded.by_key or {}
	state.reaction_usage_seq = tonumber(decoded.seq) or 0
end

local function persist_reaction_recency_state()
	write_json_file(M.config.reactions.recency_store_path, {
		seq = state.reaction_usage_seq,
		by_key = state.reaction_usage_by_key,
	})
end

local function load_drafts()
	local decoded = read_json_file(M.config.drafts.store_path)
	if not decoded then
		return
	end
	state.drafts = type(decoded.drafts) == "table" and decoded.drafts or {}
end

local function persist_drafts()
	write_json_file(M.config.drafts.store_path, { drafts = state.drafts })
end

local function drafts_without(key)
	local kept = {}
	for _, d in ipairs(state.drafts) do
		if d.key ~= key then
			table.insert(kept, d)
		end
	end
	return kept
end

local function save_draft(key, text, base)
	if not key or vim.trim(text or "") == "" then
		return
	end
	local kept = drafts_without(key)
	table.insert(kept, { key = key, text = text, base = base, saved_at = os.time() })
	local max = tonumber(M.config.drafts.max_count or 50) or 50
	if #kept > max then
		table.sort(kept, function(a, b)
			return (a.saved_at or 0) > (b.saved_at or 0)
		end)
		local trimmed = {}
		for i = 1, max do
			trimmed[i] = kept[i]
		end
		kept = trimmed
	end
	state.drafts = kept
	persist_drafts()
end

-- Keeps a draft on disk while the user types, so it survives every way the
-- editor can go away: closing the window, :qa (WinClosed never fires there),
-- closing the terminal (SIGHUP), or the process being killed outright.
local function attach_draft_autosave(opts)
	local buf, win, key, get_text = opts.buf, opts.win, opts.key, opts.get_text
	if not key or not buf then
		return { cancel = function() end }
	end

	local group = vim.api.nvim_create_augroup("bb_pr_draft_" .. tostring(buf), { clear = true })
	local timer = (vim.uv or vim.loop).new_timer()
	local cancelled = false
	local last_saved = nil

	local function save_now()
		if cancelled then
			return
		end
		timer:stop()
		local text = get_text()
		if type(text) == "string" and text ~= last_saved then
			last_saved = text
			save_draft(key, text, opts.base)
		end
	end

	local function cancel()
		if cancelled then
			return
		end
		cancelled = true
		timer:stop()
		if not timer:is_closing() then
			timer:close()
		end
		pcall(vim.api.nvim_del_augroup_by_id, group)
	end

	local delay = tonumber(M.config.drafts.autosave_debounce_ms or 400) or 400
	local function schedule_save()
		if cancelled then
			return
		end
		timer:stop()
		timer:start(delay, 0, vim.schedule_wrap(save_now))
	end

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
		group = group,
		buffer = buf,
		callback = schedule_save,
	})
	vim.api.nvim_create_autocmd("BufLeave", {
		group = group,
		buffer = buf,
		callback = save_now,
	})
	-- the buffer is gone: save what it held, then release the timer and autocmds
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = buf,
		callback = function()
			save_now()
			cancel()
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = save_now,
	})
	if win then
		vim.api.nvim_create_autocmd("WinClosed", {
			group = group,
			pattern = tostring(win),
			callback = save_now,
		})
	end

	return { cancel = cancel }
end

local function get_draft(key)
	if not key then
		return nil
	end
	local found = nil
	for _, d in ipairs(state.drafts) do
		if d.key == key then
			if not found or (d.saved_at or 0) > (found.saved_at or 0) then
				found = d
			end
		end
	end
	return found
end

local function delete_draft(key)
	if not key then
		return
	end
	local kept = drafts_without(key)
	if #kept ~= #state.drafts then
		state.drafts = kept
		persist_drafts()
	end
end

local function draft_age_label(saved_at)
	local diff = os.time() - (saved_at or 0)
	if diff < 60 then
		return diff .. "s ago"
	elseif diff < 3600 then
		return math.floor(diff / 60) .. "m ago"
	elseif diff < 86400 then
		return math.floor(diff / 3600) .. "h ago"
	else
		return math.floor(diff / 86400) .. "d ago"
	end
end

-- The draft saved under `key` (nil when none) and whether it conflicts: it was written
-- against a different starting text than `fresh_base` (template or original changed).
local function load_draft(key, fresh_base)
	local draft = get_draft(key)
	local conflict = draft ~= nil and draft.base ~= nil and draft.base ~= fresh_base
	return draft, conflict
end

-- Tells the user about the draft load_draft found for the editor in `buf`: a matching
-- draft was restored; a conflicting one is offered on <C-r>, which calls restore()
-- (returning false means there was nothing to restore).
local function announce_draft(buf, draft, conflict, restore)
	if not draft then
		return
	end
	if not conflict then
		vim.notify("bb_pr: draft restored (" .. draft_age_label(draft.saved_at) .. ")", vim.log.levels.INFO)
		return
	end
	vim.notify(
		string.format(
			"bb_pr: draft from %s conflicts with updated template — <C-r> to restore draft",
			draft_age_label(draft.saved_at)
		),
		vim.log.levels.WARN
	)
	vim.keymap.set({ "n", "i" }, "<C-r>", function()
		if vim.api.nvim_buf_is_valid(buf) and restore() ~= false then
			vim.notify("bb_pr: draft loaded", vim.log.levels.INFO)
		end
	end, { buffer = buf, silent = true })
end

local function with_repo_autodetect_flag(cmd)
	local out = vim.deepcopy(cmd or {})
	if not M.config.force_repo_autodetect then
		return out
	end
	if type(out[1]) ~= "string" or out[1] ~= "bb" then
		return out
	end
	local wanted = tostring(M.config.force_repo_autodetect_flag or "-force-autodetect-repo")
	for _, part in ipairs(out) do
		if part == wanted then
			return out
		end
	end
	table.insert(out, 2, wanted)
	return out
end

local function bb_cmd(parts)
	local cmd = { "bb" }
	for _, part in ipairs(parts or {}) do
		table.insert(cmd, part)
	end
	return with_repo_autodetect_flag(cmd)
end

-- Runs a bb command. On success on_ok runs on the main loop (nvim API is safe there)
-- with the decoded JSON when opts.json, otherwise with the vim.system result.
-- Failures notify "bb_pr: <opts.fail_msg>: <stderr>" and, for undecodable JSON,
-- "bb_pr: <opts.invalid_msg>", unless opts.notify_errors == false.
local function run_bb_cmd(cmd, opts, on_ok)
	opts = opts or {}
	local notify_errors = opts.notify_errors ~= false
	vim.system(
		cmd,
		{ text = true },
		vim.schedule_wrap(function(res)
			if res.code ~= 0 then
				log("bb command failed:", cmd, "code=", res.code, "stderr=", res.stderr or "")
				if notify_errors then
					vim.notify(
						"bb_pr: " .. (opts.fail_msg or "bb failed") .. ": " .. (res.stderr or ""),
						vim.log.levels.ERROR
					)
				end
				return
			end
			if not opts.json then
				on_ok(res)
				return
			end
			local ok, decoded = pcall(vim.json.decode, res.stdout)
			if not ok or type(decoded) ~= "table" then
				if notify_errors then
					vim.notify("bb_pr: " .. (opts.invalid_msg or "invalid bb JSON output"), vim.log.levels.ERROR)
				end
				return
			end
			on_ok(decoded)
		end)
	)
end

-- run_bb_cmd for `bb <args>`
local function run_bb(args, opts, on_ok)
	run_bb_cmd(bb_cmd(args), opts, on_ok)
end

-- cb(prs) runs on the main loop. opts.without_builds drops "-builds" from
-- provider_cmd: the CLI then skips the build lookup it does for every open PR.
local function run_provider(cb, opts)
	local cmd = M.config.provider_cmd
	if opts and opts.without_builds then
		cmd = vim.tbl_filter(function(part)
			return part ~= "-builds"
		end, cmd)
	end
	run_bb_cmd(
		with_repo_autodetect_flag(cmd),
		{ json = true, fail_msg = "provider failed", invalid_msg = "invalid JSON provider output" },
		cb
	)
end

-- cb(pr or nil) runs on the main loop. Build status is not fetched: the PR tab
-- shows builds from run_builds_provider, never pr.build_status.
local function fetch_pr_by_id(pr_id, cb)
	run_provider(function(prs)
		for _, pr in ipairs(prs) do
			if tonumber(pr.id or 0) == pr_id then
				cb(pr)
				return
			end
		end
		cb(nil)
	end, { without_builds = true })
end

-- cb(fresh_pr or nil) for the PR of `tabpage` (default: current tab)
local function refresh_current_pr(cb, tabpage)
	local current = get_tab_pr(tabpage)
	local current_id = type(current) == "table" and (tonumber(current.id or 0) or 0) or 0
	if current_id <= 0 then
		cb(nil)
		return
	end
	fetch_pr_by_id(current_id, cb)
end

local apply_comments_to_current_buffer
local apply_pr_info_content
local find_comment_by_id
local resolve_reply_target_comment_id
local set_diff_buffer_keymaps
local open_help_float
local open_pr_info_with_comments
local ticket_under_cursor
local open_jira_ticket
local open_attachment_at_cursor

-- cb(payload) runs on the main loop
local function run_comments_provider(pr_id, cb, opts)
	local cmd = with_repo_autodetect_flag(M.config.comments_cmd)
	table.insert(cmd, tostring(pr_id))
	run_bb_cmd(cmd, {
		json = true,
		notify_errors = not (opts and opts.notify_errors == false),
		fail_msg = "comments provider failed",
		invalid_msg = "invalid PR comments JSON",
	}, cb)
end

local prefetch_comment_file_texts

local function set_tab_comments(tabpage, payload)
	local ts = tab_state(tabpage)
	ts.comments = payload
	ts.pending_comments = payload
	-- the render memos are keyed on the payload anyway; drop the stale entries
	state.rendered_by_buf = {}
	state.panel_rendered_by_buf = {}
	if ts.diff_base then
		prefetch_comment_file_texts(ts.diff_base, payload)
	end
end

local function set_current_tab_comments(payload)
	set_tab_comments(nil, payload)
end

local function get_current_tab_comments()
	return tab_state().comments
end

local function get_buf_line_comments(bufnr)
	return state.line_comments_by_buf[bufnr] or {}
end

-- `info` is { to_ref = "<branch>" } while the PR branch sits on top of an unresolved
-- merge with its target, nil otherwise.
local function set_current_tab_conflict(info)
	tab_state().conflict = info
end

local function get_current_tab_conflict()
	return tab_state().conflict
end

-- Records the commits Bitbucket anchors comment lines to: FROM lines to the merge
-- base of source and target, TO lines to the source tip. Left unset (comments then
-- use raw line numbers) when git cannot resolve them.
local function set_current_tab_diff_base(repo_root, from_ref, to_ref)
	local ts = tab_state()
	local opts = { cwd = repo_root, text = true }
	-- both run concurrently; wait for each
	local source_job = vim.system({ "git", "rev-parse", "origin/" .. from_ref }, opts)
	local base_job = vim.system({ "git", "merge-base", "origin/" .. from_ref, "origin/" .. to_ref }, opts)
	local source = source_job:wait()
	local base = base_job:wait()
	if source.code ~= 0 or base.code ~= 0 then
		log("set_current_tab_diff_base failed:", source.stderr, base.stderr)
		ts.diff_base = nil
		return
	end
	ts.diff_base = {
		root = repo_root,
		base = vim.trim(base.stdout),
		source = vim.trim(source.stdout),
	}
	log("set_current_tab_diff_base:", ts.diff_base)
end

local function consume_pending_tab_comments()
	local ts = tab_state()
	local payload = ts.pending_comments
	ts.pending_comments = nil
	return payload
end

-- cb(builds) runs on the main loop; errors are silent unless opts.notify_errors
local function run_builds_provider(pr_id, cb, opts)
	local cmd = with_repo_autodetect_flag(M.config.builds_cmd)
	table.insert(cmd, tostring(pr_id))
	run_bb_cmd(cmd, {
		json = true,
		notify_errors = (opts and opts.notify_errors) and true or false,
		fail_msg = "builds provider failed",
		invalid_msg = "invalid PR builds JSON",
	}, cb)
end

local function set_tab_builds(tabpage, payload)
	tab_state(tabpage).builds = payload
end

local function get_current_tab_builds()
	return tab_state().builds
end

local function split_first_line(text)
	if type(text) ~= "string" or text == "" then
		return "(empty)"
	end
	return (vim.split(text, "\n", { plain = true })[1] or ""):gsub("%s+", " ")
end

local function as_array(value)
	if type(value) == "table" then
		return value
	end

	-- vim.json.decode can return vim.empty_dict() userdata for empty JSON objects.
	return {}
end

local function normalize_repo_path(path)
	if type(path) ~= "string" then
		return ""
	end

	local p = path:gsub("\\", "/")
	p = p:gsub("^%./", "")
	p = p:gsub("^a/", "")
	p = p:gsub("^b/", "")
	p = p:gsub("^/", "")
	return p
end

local function path_matches(current_file, anchor_path)
	local cur = normalize_repo_path(current_file)
	local anc = normalize_repo_path(anchor_path)
	if anc == "" or cur == "" then
		return false
	end

	if cur == anc then
		return true
	end

	return cur:sub(-#anc) == anc
end

local function extract_repo_relative_path(bufname)
	if type(bufname) ~= "string" or bufname == "" then
		return ""
	end

	local name = bufname
	if name:match("^diffview://") then
		name = name:gsub("^diffview://", "")
		local git_idx = name:find("/.git/")
		if git_idx then
			local after_git = name:sub(git_idx + 6)
			local slash_after_hash = after_git:find("/")
			if slash_after_hash then
				name = after_git:sub(slash_after_hash + 1)
			end
		end
	end

	local rel = vim.fn.fnamemodify(name, ":.")
	return normalize_repo_path(rel)
end

local function current_buffer_repo_path(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	local primary = extract_repo_relative_path(name)
	if primary ~= "" then
		return primary
	end

	local alt_expand = normalize_repo_path(vim.fn.expand("%:."))
	if alt_expand ~= "" then
		return alt_expand
	end

	local alt_name = normalize_repo_path(name)
	if alt_name ~= "" then
		return alt_name
	end

	return ""
end

local function resolve_apply_target_bufnr(target_path, repo_root)
	-- a buffer of a working tree file (not a diffview:// revision) showing target_path
	local function candidate(b)
		return vim.api.nvim_buf_is_valid(b)
			and not vim.api.nvim_buf_get_name(b):match("^diffview://")
			and (target_path == "" or path_matches(current_buffer_repo_path(b), target_path))
	end

	local cur = vim.api.nvim_get_current_buf()
	local source = vim.b[cur].bb_pr_float_source_bufnr
	local has_source = type(source) == "number" and source > 0 and vim.api.nvim_buf_is_valid(source)
	if has_source and candidate(source) then
		return source
	end
	if candidate(cur) then
		return cur
	end

	if target_path ~= "" then
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.bo[b].buftype == "" and vim.api.nvim_buf_get_name(b) ~= "" and candidate(b) then
				return b
			end
		end

		local abs = repo_root and vim.fs.joinpath(repo_root, target_path) or vim.fn.fnamemodify(target_path, ":p")
		local file_buf = vim.fn.bufadd(abs)
		pcall(vim.fn.bufload, file_buf)
		if type(file_buf) == "number" and file_buf > 0 and vim.api.nvim_buf_is_valid(file_buf) then
			return file_buf
		end
	end

	if has_source then
		return source
	end
	return cur
end

local function apply_suggestion_lines(buf, line, replacement_lines)
	if not (type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)) then
		return false, "invalid target buffer"
	end
	local was_modifiable = vim.bo[buf].modifiable
	if not was_modifiable then
		vim.bo[buf].modifiable = true
	end
	local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, line - 1, line, false, replacement_lines)
	if not was_modifiable then
		vim.bo[buf].modifiable = false
	end
	if not ok then
		return false, tostring(err or "failed to apply suggestion")
	end
	return true, nil
end
-- "left" / "right" for a window of a two-way diff (by column among the diff windows
-- of its tab), "single" otherwise
local function diff_side(win)
	if not vim.api.nvim_win_is_valid(win) then
		return "single"
	end
	if not vim.wo[win].diff then
		return "single"
	end

	local tab_wins = vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))
	local diff_wins = {}
	for _, w in ipairs(tab_wins) do
		if vim.api.nvim_win_is_valid(w) and vim.wo[w].diff then
			table.insert(diff_wins, w)
		end
	end
	if #diff_wins < 2 then
		return "single"
	end

	local min_col = math.huge
	local max_col = -math.huge
	local cur_col = nil

	for _, w in ipairs(diff_wins) do
		local pos = vim.api.nvim_win_get_position(w)
		local col = pos[2]
		if col < min_col then
			min_col = col
		end
		if col > max_col then
			max_col = col
		end
		if w == win then
			cur_col = col
		end
	end

	if not cur_col or min_col == max_col then
		return "single"
	end

	local mid = (min_col + max_col) / 2
	if cur_col <= mid then
		return "left"
	end
	return "right"
end

local function current_diff_side()
	return diff_side(vim.api.nvim_get_current_win())
end

-- Locates the diffview file shown in `win`. The repo path comes from the view's
-- entry, so it does not depend on the cwd, worktree layout or buffer name.
-- Returns nil when `win` is not a file window of a diffview layout.
local function diffview_window_file(win)
	local ok, lib = pcall(require, "diffview.lib")
	if not ok then
		return nil
	end
	local view = lib.get_current_view()
	local layout = view and view.cur_layout
	local entry = view and view.cur_entry
	if not (layout and entry and type(layout.windows) == "table") then
		return nil
	end
	for _, w in ipairs(layout.windows) do
		if w.id == win and w.file then
			return {
				path = entry.path,
				from_path = entry.oldpath,
				symbol = w.file.symbol,
				nulled = w.file.nulled or w.file.binary,
			}
		end
	end
	return nil
end

-- Repo-relative path of a plain file buffer, computed from its git root.
local function plain_buffer_repo_path(bufnr)
	if vim.bo[bufnr].buftype ~= "" then
		return nil
	end
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" or name:match("^%a[%w+.-]*://") then
		return nil
	end
	local abs = vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
	local root = vim.fs.root(abs, ".git")
	if not root then
		return nil
	end
	root = vim.fs.normalize(root)
	if abs:sub(1, #root + 1) ~= root .. "/" then
		return nil
	end
	return abs:sub(#root + 2)
end

-- Describes the file shown in `win`: repo path (BB anchor path), path on the FROM
-- side (differs for renames) and diff side. Returns nil, reason when the window
-- shows no repository file (file panel, commit log, null side of an added file).
local function window_file_info(win)
	local bufnr = vim.api.nvim_win_get_buf(win)
	local dv = diffview_window_file(win)
	if dv then
		if dv.nulled then
			return nil, "this side of the diff has no file"
		end
		local side
		if dv.symbol == "a" then
			side = "left"
		elseif dv.symbol == "b" then
			side = vim.wo[win].diff and "right" or "single"
		else
			return nil, "comments are only supported in a two-way diff"
		end
		if type(dv.path) ~= "string" or dv.path == "" then
			return nil, "cannot determine the file path"
		end
		return { bufnr = bufnr, path = dv.path, from_path = dv.from_path or dv.path, side = side }
	end
	local rel = plain_buffer_repo_path(bufnr)
	if not rel then
		return nil, "current buffer is not a repository file"
	end
	return { bufnr = bufnr, path = rel, from_path = rel, side = diff_side(win) }
end

-- PR line translation.
--
-- Bitbucket anchors FROM lines to the merge base and TO lines to the source tip.
-- The PR tab instead shows the target tip (left) against the working tree with
-- the target merged in (right), so line numbers drift whenever the target branch
-- touched a PR file. Each window's content is diffed against the commit
-- Bitbucket uses for that side, and line types come from the merge-base..source
-- diff — the same diff Bitbucket renders.

local function git_file_text(root, rev, path)
	local key = rev .. ":" .. path
	local cached = state.git_text_cache[key]
	if cached then
		return cached
	end
	local res = vim.system({ "git", "show", key }, { cwd = root, text = true }):wait()
	-- a path missing at that commit (added or deleted file) is an empty version
	local text = res.code == 0 and (res.stdout or "") or ""
	state.git_text_cache[key] = text
	return text
end

-- Parses `git cat-file --batch` output into one text per requested object, in
-- request order; a missing object (file absent at that commit) is "", anything
-- else unexpected is false.
local function parse_cat_file_batch(out, count)
	local texts = {}
	local pos = 1
	for i = 1, count do
		local eol = out:find("\n", pos, true)
		if not eol then
			break
		end
		local header = out:sub(pos, eol - 1)
		local size = header:match("^%x+ blob (%d+)$")
		if size then
			size = tonumber(size)
			texts[i] = out:sub(eol + 1, eol + size)
			pos = eol + size + 2 -- content is followed by a newline
		else
			texts[i] = header:match(" missing$") and "" or false
			pos = eol + 1
		end
	end
	return texts
end

-- cb({ { from_path, path }, ... }) on the main loop with the files the PR changes
-- (merge base → source tip); the name-status pass maps renamed files to their
-- merge-base path. Parsed once per diff-base object, i.e. per (base, source).
local function with_pr_changed_files(info, cb)
	if info.changed_files then
		cb(info.changed_files)
		return
	end
	local diff_cmd = { "git", "diff", "--name-status", "-z", "-M", info.base, info.source }
	vim.system(diff_cmd, { cwd = info.root, text = true }, function(diff_res)
		if diff_res.code ~= 0 then
			return
		end
		local fields = vim.split(diff_res.stdout or "", "\0", { plain = true })
		local changed = {}
		local i = 1
		while i <= #fields and fields[i] ~= "" do
			local renamed = fields[i]:match("^[RC]") ~= nil
			local from_path = fields[i + 1]
			local path = renamed and fields[i + 2] or from_path
			i = i + (renamed and 3 or 2)
			if path then
				table.insert(changed, { from_path = from_path, path = path })
			end
		end
		vim.schedule(function()
			info.changed_files = changed
			cb(changed)
		end)
	end)
end

-- Loads both versions of every file that has comments into state.git_text_cache
-- in one background git process, so opening such a file does not wait on
-- `git show`. Files without comments are not read: they only need their text
-- when a comment is created there.
prefetch_comment_file_texts = function(info, payload)
	local commented = {}
	for _, c in ipairs(as_array(payload and payload.file_comments)) do
		if not c.is_outdated and type(c.path) == "string" and c.path ~= "" then
			commented[normalize_repo_path(c.path)] = true
		end
	end
	if next(commented) == nil then
		return
	end
	with_pr_changed_files(info, function(changed)
		local keys = {}
		local function want(rev, path)
			local key = rev .. ":" .. path -- same key as git_file_text
			-- cat-file --batch reads one object name per line
			if state.git_text_cache[key] == nil and not key:find("\n", 1, true) then
				table.insert(keys, key)
			end
		end
		for _, f in ipairs(changed) do
			if commented[normalize_repo_path(f.path)] then
				want(info.base, f.from_path)
				want(info.source, f.path)
			end
		end
		if #keys == 0 then
			return
		end
		-- binary output: text mode rewrites \r\n and would shift the blob sizes
		local cat_opts = { cwd = info.root, text = false, stdin = table.concat(keys, "\n") .. "\n" }
		vim.system({ "git", "cat-file", "--batch" }, cat_opts, function(cat_res)
			if cat_res.code ~= 0 then
				return
			end
			local texts = parse_cat_file_batch(cat_res.stdout or "", #keys)
			vim.schedule(function()
				for idx, key in ipairs(keys) do
					if texts[idx] and state.git_text_cache[key] == nil then
						-- match git_file_text, which reads `git show` in text mode
						state.git_text_cache[key] = texts[idx]:gsub("\r\n", "\n")
					end
				end
				log("prefetch_comment_file_texts: cached", #keys, "file versions")
			end)
		end)
	end)
end

-- merge base → source tip: the PR diff as Bitbucket shows it
local function pr_hunks(info, finfo)
	local key = table.concat({ info.base, info.source, finfo.from_path, finfo.path }, "\0")
	local hunks = state.hunks_cache[key]
	if not hunks then
		hunks = linemap.hunks(
			git_file_text(info.root, info.base, finfo.from_path),
			git_file_text(info.root, info.source, finfo.path)
		)
		state.hunks_cache[key] = hunks
	end
	return hunks
end

-- Bitbucket's version of this side → what the window shows (recomputed on edits)
local function window_hunks(info, finfo)
	local rev = finfo.side == "left" and info.base or info.source
	local path = finfo.side == "left" and finfo.from_path or finfo.path
	local tick = vim.api.nvim_buf_get_changedtick(finfo.bufnr)
	local key = table.concat({ rev, path }, "\0")
	local cached = state.buf_hunks_cache[finfo.bufnr]
	if cached and cached.key == key and cached.tick == tick then
		return cached.hunks
	end
	local shown = linemap.lines_to_text(vim.api.nvim_buf_get_lines(finfo.bufnr, 0, -1, false))
	local hunks = linemap.hunks(git_file_text(info.root, rev, path), shown)
	state.buf_hunks_cache[finfo.bufnr] = { key = key, tick = tick, hunks = hunks }
	return hunks
end

local function tab_diff_base(tabpage)
	return tab_state(tabpage).diff_base
end

-- Local line of the window described by `finfo` → Bitbucket anchor
-- { line, line_type, file_type }, or nil, reason when Bitbucket has no such line.
local function local_line_to_anchor(info, finfo, line)
	local local_to_bb = linemap.b_to_a(window_hunks(info, finfo), line)
	if finfo.side == "left" then
		if not local_to_bb then
			return nil, "this line was changed in the target branch after the PR branched off"
		end
		local removed = linemap.in_a(pr_hunks(info, finfo), local_to_bb)
		return { line = local_to_bb, line_type = removed and "REMOVED" or "CONTEXT", file_type = "FROM" }
	end
	if not local_to_bb then
		return nil, "this line is not in the PR source (it comes from the merged target branch or a local edit)"
	end
	local added = linemap.in_b(pr_hunks(info, finfo), local_to_bb)
	return { line = local_to_bb, line_type = added and "ADDED" or "CONTEXT", file_type = "TO" }
end

-- Bitbucket comment anchor → line in the window described by `finfo`, or nil
-- when the commented line is not shown there.
local function anchor_to_local_line(info, finfo, c)
	local line = tonumber(c.line or 0) or 0
	if line <= 0 then
		return nil
	end
	local file_type = tostring(c.file_type or ""):upper()
	local bb_line = line
	if finfo.side == "left" then
		if file_type ~= "FROM" then
			-- a context line anchored on the TO side still exists in the merge base
			bb_line = linemap.b_to_a(pr_hunks(info, finfo), line)
		end
	elseif file_type == "FROM" then
		bb_line = linemap.a_to_b(pr_hunks(info, finfo), line)
	end
	if not bb_line then
		return nil
	end
	return linemap.a_to_b(window_hunks(info, finfo), bb_line)
end

local function comment_matches_side(c, side)
	local file_type = tostring(c.file_type or ""):upper()
	local line_type = tostring(c.line_type or ""):upper()
	if side == "left" then
		return file_type == "FROM" or line_type == "REMOVED"
	end
	if side == "right" then
		return file_type == "TO" or file_type == "" or line_type == "ADDED" or line_type == "CONTEXT"
	end
	return true
end

local function enable_markview(buf, win)
	local markview = nil
	local commands = nil
	do
		local ok_markview, mod_markview = pcall(require, "markview")
		if ok_markview then
			markview = mod_markview
		end
		local ok_commands, mod_commands = pcall(require, "markview.commands")
		if ok_commands then
			commands = mod_commands
		end
	end

	if not markview and not commands then
		return
	end

	local function try_attach()
		if markview and type(markview.attach) == "function" then
			if pcall(markview.attach) then
				return true
			end
			if pcall(markview.attach, buf) then
				return true
			end
		end

		if markview and type(markview.enable) == "function" then
			if pcall(markview.enable) then
				return true
			end
			if pcall(markview.enable, buf) then
				return true
			end
		end

		if commands and type(commands.attach) == "function" then
			if pcall(commands.attach, buf) then
				return true
			end
			if pcall(commands.attach) then
				return true
			end
		end

		return false
	end

	vim.schedule(function()
		pcall(vim.api.nvim_win_call, win, function()
			if not try_attach() then
				vim.cmd("silent! Markview attach")
			end
		end)
	end)
end

local function set_wrapped_window_options(win)
	vim.api.nvim_set_option_value("wrap", true, { win = win })
	vim.api.nvim_set_option_value("linebreak", true, { win = win })
	vim.api.nvim_set_option_value("breakindent", true, { win = win })
	vim.api.nvim_set_option_value("breakindentopt", "shift:2,sbr", { win = win })
end

-- Scratch buffer (nofile, no swap file) wiped once no window shows it. A filetype also
-- turns diagnostics off: the editors and views hold prose, not code.
local function create_scratch_buf(filetype)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	if filetype then
		vim.bo[buf].filetype = filetype
		vim.diagnostic.enable(false, { bufnr = buf })
	end
	return buf
end

-- Opens and enters a minimal, rounded float of opts.width x opts.height centered in the
-- editor, titled opts.title, with opts.footer (if any) on the right.
local function open_centered_float(buf, opts)
	local width, height = opts.width, opts.height
	return vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = opts.title,
		title_pos = "center",
		footer = opts.footer,
		footer_pos = opts.footer and "right" or nil,
	})
end

-- Sets the normal-mode maps of `specs` on `buf` (nil: global maps). A spec is
-- { key, rhs, desc = ..., help = ... }: rhs is a command string or a function, nil to
-- only list the spec in the help; a nil or "" key skips the spec. `help` is its help
-- text (default: desc), false leaves it out. With `help_title`, "?" opens a help float
-- listing the specs in order.
local function bind_keymaps(buf, specs, help_title)
	local entries = {}
	for _, spec in ipairs(specs) do
		local key, rhs = spec[1], spec[2]
		if key and key ~= "" then
			if rhs then
				vim.keymap.set("n", key, rhs, { buffer = buf, silent = true, desc = spec.desc })
			end
			local help = spec.help
			if help == nil then
				help = spec.desc
			end
			if help then
				table.insert(entries, { key, help })
			end
		end
	end
	if help_title then
		vim.keymap.set("n", "?", function()
			open_help_float(entries, help_title)
		end, { buffer = buf, desc = "Show keymap help", silent = true })
	end
end

-- The comment actions of the comment views, in help order: key in M.config.comments,
-- command, map description; `help` replaces the description in the help float, and
-- `overview` in PR Info, which binds none of the `float_only` actions.
local COMMENT_ACTIONS = {
	{ "reply_map", "BBPRReplyComment", "Reply to comment" },
	{ "react_map", "BBPRReactComment", "React / emoji" },
	{ "reaction_users_map", "BBPRReactionUsers", "Who reacted", help = "Who reacted (cursor on a reaction)" },
	{ "delete_map", "BBPRDeleteComment", "Delete comment" },
	{ "edit_map", "BBPREditComment", "Edit comment" },
	{ "resolve_map", "BBPRResolveComment", "Resolve / unresolve thread" },
	{ "toggle_task_map", "BBPRToggleTask", "Toggle task done/open" },
	{ "convert_task_map", "BBPRConvertTask", "Convert comment <-> task" },
	{ "create_map", "BBPRCreateComment", "Create comment", overview = "Create overview comment" },
	{ "create_task_map", "BBPRCreateTask", "Create task", float_only = true },
	{ "create_suggestion_map", "BBPRCreateSuggestion", "Create suggestion", float_only = true },
	{ "accept_suggestion_map", "BBPRAcceptSuggestion", "Accept suggestion", float_only = true },
}

-- bind_keymaps specs of the comment actions of the line comments float, or of PR Info
-- with `overview`, ending with the help entry of the q map open_comment_view_float sets
local function comment_action_specs(overview)
	local specs = {}
	for _, action in ipairs(COMMENT_ACTIONS) do
		if not (overview and action.float_only) then
			table.insert(specs, {
				M.config.comments[action[1]],
				"<cmd>" .. action[2] .. "<CR>",
				desc = overview and action.overview or action[3],
				help = action.help,
			})
		end
	end
	table.insert(specs, { "q", nil, help = "Close" })
	return specs
end

-- Opens the float of a comment view (line comments float, PR Info) on `buf`; q closes it
local function open_comment_view_float(buf, title)
	local win = open_centered_float(buf, {
		width = math.floor(vim.o.columns * 0.8),
		height = math.floor(vim.o.lines * 0.8),
		title = title,
		footer = " ? help ",
	})
	set_wrapped_window_options(win)
	enable_markview(buf, win)
	vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf, silent = true })
	return win
end

-- Comment views: the line comments float and the PR Info overview render comments
-- the same way and record per line which comment it acts on.

local function comment_view(buf)
	return state.comment_view_by_buf[buf]
end

-- PR rendered by the PR Info buffer `buf`, nil for any other buffer
local function pr_info_buffer_pr(buf)
	local view = comment_view(buf)
	return view and view.kind == "overview" and view.pr or nil
end

-- First line of `view` that acts on comment `cid`, nil when none does
local function line_of_comment(view, cid)
	local found = nil
	for line, id in pairs(view and view.ids_by_line or {}) do
		if id == cid and (not found or line < found) then
			found = line
		end
	end
	return found
end

-- Cursor of `win` plus the comment its line acts on in the view of `buf`
local function save_comment_cursor(win, buf)
	local cur = vim.api.nvim_win_get_cursor(win)
	local view = comment_view(buf)
	return { line = cur[1], col = cur[2], comment_id = view and view.ids_by_line[cur[1]] }
end

-- Puts the cursor of `win` (showing `buf`) back on the comment of `saved`, or on its old
-- line when that comment is gone, clamped to the buffer.
local function restore_comment_cursor(win, buf, saved)
	local line = saved.comment_id and line_of_comment(comment_view(buf), saved.comment_id) or saved.line
	line = math.max(math.min(line, vim.api.nvim_buf_line_count(buf)), 1)
	pcall(vim.api.nvim_win_set_cursor, win, { line, saved.col or 0 })
end

local function trim_edge_empty_lines(items)
	local first = 1
	local last = #items
	while first <= last and (items[first] or ""):match("^%s*$") do
		first = first + 1
	end
	while last >= first and (items[last] or ""):match("^%s*$") do
		last = last - 1
	end
	local out = {}
	for i = first, last do
		table.insert(out, items[i])
	end
	return out
end

local function is_task_done(c)
	local status = type(c.task_status) == "string" and string.upper(c.task_status) or "OPEN"
	return status == "DONE" or status == "RESOLVED"
end

-- "- │ ☐ author time (#id) ↳ reply to #parent"
local function format_comment_header(c)
	local depth = math.max(tonumber(c.depth or 0) or 0, 0)
	local bars = depth > 0 and (string.rep("│", depth) .. " ") or ""
	local status = ""
	if c.is_task then
		status = is_task_done(c) and "☑ " or "☐ "
	elseif c.is_resolved then
		status = "~ "
	end
	local header = string.format("- %s%s%s %s", bars, status, c.author or "unknown", c.created_at or "unknown time")
	local comment_id = tonumber(c.id or 0) or 0
	local reply_to = tonumber(c.parent_id or 0) or 0
	if comment_id > 0 then
		header = header .. string.format(" (#%d)", comment_id)
	end
	if reply_to > 0 then
		header = header .. string.format(" ↳ reply to #%d", reply_to)
	end
	return header
end

-- comment bodies and reaction lines are indented by this in both views
local comment_indent = "    "

-- Appends `text` to `lines`; a positive comment_id makes the line act on that comment.
local function push_view_line(lines, view, text, comment_id)
	table.insert(lines, text)
	if comment_id and comment_id > 0 then
		view.ids_by_line[#lines] = comment_id
	end
end

-- Appends comment `c` to `lines`: header, indented body, reactions, blank separator.
-- The header acts on the comment in both views; the PR Info overview (`overview`)
-- also maps the body and reaction lines and shows "(empty)" for an empty body.
local function append_comment_lines(lines, view, c, overview)
	local comment_id = tonumber(c.id or 0) or 0
	local body_id = overview and comment_id or nil
	push_view_line(lines, view, format_comment_header(c), comment_id)
	local body = trim_edge_empty_lines(vim.split(c.text or "", "\n", { plain = true }))
	if #body == 0 and overview then
		body = { "(empty)" }
	end
	for _, body_line in ipairs(body) do
		push_view_line(lines, view, comment_indent .. body_line, body_id)
	end
	local reactions_line, segments = reactions.format_line(c.reactions, c.my_reactions, comment_indent)
	if reactions_line then
		push_view_line(lines, view, "")
		push_view_line(lines, view, reactions_line, body_id)
		view.reaction_segments[#lines] = { comment_id = comment_id, segments = segments }
	end
	push_view_line(lines, view, "")
end

local function open_comment_float(comments, line)
	local source_win = vim.api.nvim_get_current_win()
	local source_buf = vim.api.nvim_get_current_buf()

	local lines = { string.format("PR comments for line %d", line), "" }
	local view = { kind = "float", ids_by_line = {}, reaction_segments = {} }
	for _, c in ipairs(comments) do
		append_comment_lines(lines, view, c, false)
	end

	local buf = create_scratch_buf("markdown")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	state.comment_view_by_buf[buf] = view
	vim.b[buf].bb_pr_float_source_win = source_win
	vim.b[buf].bb_pr_float_source_bufnr = source_buf
	vim.b[buf].bb_pr_float_source_line = line

	local win = open_comment_view_float(buf, "BB PR Comments")
	bind_keymaps(buf, comment_action_specs(false), "File Comment — Keymaps")
	return win
end

-- First entry after `cur` (dir > 0) or before it (dir < 0) in the ascending list
-- `sorted`, wrapping around at either end
local function wrapped_target(sorted, cur, dir)
	if dir > 0 then
		for _, v in ipairs(sorted) do
			if v > cur then
				return v
			end
		end
		return sorted[1]
	end
	for i = #sorted, 1, -1 do
		if sorted[i] < cur then
			return sorted[i]
		end
	end
	return sorted[#sorted]
end

-- render_buffer_comments records every line it marks in state.line_comments_by_buf,
-- so that map alone lists the commented lines
local function jump_file_comment(direction)
	local lines = {}
	for line, comments in pairs(get_buf_line_comments(vim.api.nvim_get_current_buf())) do
		if #comments > 0 then
			table.insert(lines, line)
		end
	end
	if #lines == 0 then
		vim.notify("bb_pr: no file comments in current buffer", vim.log.levels.INFO)
		return
	end
	table.sort(lines)
	vim.api.nvim_win_set_cursor(0, { wrapped_target(lines, vim.api.nvim_win_get_cursor(0)[1], direction), 0 })
end

local function jump_overview_comment(view, direction)
	if #view.thread_lines == 0 then
		vim.notify("bb_pr: no comment threads in current buffer", vim.log.levels.INFO)
		return
	end
	local target = wrapped_target(view.thread_lines, vim.api.nvim_win_get_cursor(0)[1], direction)
	vim.api.nvim_win_set_cursor(0, { target, 0 })
end

local function jump_comment(direction)
	local view = comment_view(vim.api.nvim_get_current_buf())
	if view and view.kind == "overview" then
		jump_overview_comment(view, direction)
		return
	end
	jump_file_comment(direction)
end

-- Places the comment signs / virtual text / underlines of `bufnr` and records the
-- comments per local line in state.line_comments_by_buf.
local function render_buffer_comments(bufnr, comments_payload, cur_path, side, info, finfo)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, state.comment_ns, 0, -1)
	local by_line = {}
	local seen_comment_ids = {}

	for _, c in ipairs(as_array(comments_payload and comments_payload.file_comments)) do
		if not c.is_outdated and path_matches(cur_path, c.path) and comment_matches_side(c, side) then
			local cid = tonumber(c.id or 0) or 0
			if cid > 0 and seen_comment_ids[cid] then
				goto continue
			end
			local line
			if info then
				line = anchor_to_local_line(info, finfo, c) or 0
			else
				line = tonumber(c.line or 0) or 0
			end
			if line > 0 then
				if cid > 0 then
					seen_comment_ids[cid] = true
				end
				by_line[line] = by_line[line] or {}
				table.insert(by_line[line], c)
			end
		end
		::continue::
	end

	for line, line_comments in pairs(by_line) do
		if line > 0 and line <= line_count then
			local preview = split_first_line(line_comments[1].text)
			local root_count = 0
			local fully_resolved = true
			for _, c in ipairs(line_comments) do
				if (tonumber(c.parent_id or 0) or 0) == 0 then
					root_count = root_count + 1
					if not c.is_resolved then
						fully_resolved = false
					end
				end
			end
			local resolved = root_count > 0 and fully_resolved
			local underline_hl = resolved and "BbPrResolvedThread" or "Underlined"
			local virt_text_hl = resolved and "BbPrResolvedVirtText" or "DiagnosticVirtualTextInfo"
			local sign_icon = resolved and "✅" or "💬"
			local sign_hl = resolved and "BbPrResolvedVirtText" or "DiagnosticSignInfo"
			local vt = string.format("%s %d %s", sign_icon, #line_comments, preview)
			vim.api.nvim_buf_set_extmark(bufnr, state.comment_ns, line - 1, 0, {
				sign_text = sign_icon,
				sign_hl_group = sign_hl,
				virt_text = { { vt, virt_text_hl } },
				virt_text_pos = "eol",
			})
			local line_text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
			local first_non_ws = line_text:find("%S")
			local text_start_col = first_non_ws and (first_non_ws - 1) or 0
			vim.api.nvim_buf_set_extmark(bufnr, state.comment_ns, line - 1, text_start_col, {
				end_col = #line_text,
				hl_group = underline_hl,
			})
		end
	end

	state.line_comments_by_buf[bufnr] = by_line
end

apply_comments_to_current_buffer = function(comments_payload)
	local bufnr = vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
		return
	end
	local file = vim.api.nvim_buf_get_name(bufnr)
	local rel = vim.fn.fnamemodify(file, ":.")
	local rel_norm = normalize_repo_path(rel)
	local finfo = window_file_info(vim.api.nvim_get_current_win())
	local cur_path = finfo and finfo.path or rel_norm
	local side = finfo and finfo.side or current_diff_side()
	-- translate Bitbucket line numbers when the PR tab knows its commits
	local info = finfo and tab_diff_base()

	-- The marks are buffer extmarks (eol virtual text needs no window width), so they
	-- depend only on these inputs. CursorMoved / WinScrolled re-run this for every
	-- window of the tab: skip the clear + redraw when nothing changed. The changedtick
	-- covers edits, reloads and the line count.
	local memo = {
		payload = comments_payload,
		path = cur_path,
		from_path = finfo and finfo.from_path or false,
		side = side,
		info = info or false,
		tick = vim.api.nvim_buf_get_changedtick(bufnr),
	}
	local prev = state.rendered_by_buf[bufnr]
	local unchanged = prev ~= nil
	if prev then
		for k, v in pairs(memo) do
			if prev[k] ~= v then
				unchanged = false
				break
			end
		end
	end
	if not unchanged then
		state.rendered_by_buf[bufnr] = memo
		render_buffer_comments(bufnr, comments_payload, cur_path, side, info, finfo)
	end

	-- only file buffers get the comment keymaps: the diffview file panel, commit log
	-- and null buffer share the tab but have no repo file to anchor a comment to.
	-- Outside the memo: buftype is not part of its key, and the call is a b: lookup.
	local buftype = vim.bo[bufnr].buftype
	local is_diffview_file = buftype == "nowrite" and file:match("^diffview://") and file ~= "diffview://null"
	if buftype == "" or is_diffview_file then
		set_diff_buffer_keymaps(bufnr)
	end
end

-- Calls fn(comp) for every file component in a diffview panel component tree.
local function each_diffview_file_comp(node, fn)
	if type(node) ~= "table" then
		return
	end
	if node._name == "file" and type(node.comp) == "table" then
		fn(node.comp)
	end
	for i = 1, #node do
		each_diffview_file_comp(node[i], fn)
	end
end

local function collect_diffview_file_rows(panel_buf)
	local ok, lib = pcall(require, "diffview.lib")
	if not ok then
		return nil
	end
	local view = lib.get_current_view()
	if type(view) ~= "table" or type(view.panel) ~= "table" then
		return nil
	end
	if view.panel.bufid ~= panel_buf then
		return nil
	end
	if type(view.panel.components) ~= "table" then
		return nil
	end
	local rows = {}
	each_diffview_file_comp(view.panel.components, function(comp)
		local ctx = comp.context
		if type(ctx) == "table" and type(ctx.path) == "string" and type(comp.lstart) == "number" then
			rows[ctx.path] = comp.lstart
		end
	end)
	if next(rows) == nil then
		return nil
	end
	return rows
end

local function mark_panel_row(buf, row)
	vim.api.nvim_buf_set_extmark(buf, state.diffview_panel_ns, row, 0, {
		sign_text = "💬",
		sign_hl_group = "DiagnosticSignInfo",
	})
end

local function apply_comment_indicators_to_diffview_panel(tabpage, comments_payload)
	if not (tabpage and vim.api.nvim_tabpage_is_valid(tabpage)) then
		return
	end
	local paths_with_comments = {}
	for _, c in ipairs(as_array(comments_payload and comments_payload.file_comments)) do
		if not c.is_outdated then
			local path = c.path
			if type(path) == "string" and path ~= "" then
				paths_with_comments[normalize_repo_path(path)] = true
			end
		end
	end
	if next(paths_with_comments) == nil then
		return
	end
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
		if vim.api.nvim_win_is_valid(win) then
			local buf = vim.api.nvim_win_get_buf(win)
			local ft = vim.bo[buf].filetype
			if ft == "DiffviewFiles" or ft == "DiffviewFileHistory" then
				local rows = collect_diffview_file_rows(buf)
				-- diffview rewrites the panel lines (changedtick) whenever its rows
				-- move; `rows` is nil while the panel is not the current view's, and
				-- the line-match fallback is replaced once the precise rows exist
				local memo = {
					payload = comments_payload,
					tick = vim.api.nvim_buf_get_changedtick(buf),
					precise = rows ~= nil,
				}
				local prev = state.panel_rendered_by_buf[buf]
				if
					not (
						prev
						and prev.payload == memo.payload
						and prev.tick == memo.tick
						and prev.precise == memo.precise
					)
				then
					state.panel_rendered_by_buf[buf] = memo
					vim.api.nvim_buf_clear_namespace(buf, state.diffview_panel_ns, 0, -1)
					if rows then
						for path, row in pairs(rows) do
							if paths_with_comments[normalize_repo_path(path)] then
								mark_panel_row(buf, row)
							end
						end
					else
						-- Fallback for older diffview versions: full path / basename match.
						local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
						local marked = {}
						for path, _ in pairs(paths_with_comments) do
							local basename = path:match("([^/]+)$") or path
							for idx, line in ipairs(lines) do
								if not marked[idx] and type(line) == "string" then
									if line:find(path, 1, true) or line:find(basename, 1, true) then
										marked[idx] = true
										mark_panel_row(buf, idx - 1)
										break
									end
								end
							end
						end
					end
				end
			end
		end
	end
end

-- Renders the comments into every window of `tabpage` and the diffview file panel.
-- opts.refresh_info also rebuilds a PR Info window open in the tab; the
-- CursorMoved path leaves it alone.
local function apply_comments_to_tab(tabpage, comments_payload, opts)
	if not (tabpage and vim.api.nvim_tabpage_is_valid(tabpage)) then
		return
	end
	local refresh_info = opts and opts.refresh_info
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
		if vim.api.nvim_win_is_valid(win) then
			local ok, err = pcall(vim.api.nvim_win_call, win, function()
				apply_comments_to_current_buffer(comments_payload)
				if refresh_info then
					local bufnr = vim.api.nvim_get_current_buf()
					local info_pr = pr_info_buffer_pr(bufnr)
					if info_pr then
						apply_pr_info_content(bufnr, info_pr)
					end
				end
			end)
			if not ok then
				log("apply_comments_to_tab: window", win, "failed:", err)
			end
		end
	end
	apply_comment_indicators_to_diffview_panel(tabpage, comments_payload)
end

-- Calls fn until it returns true: at most opts.tries calls, opts.delay ms apart.
-- The first call runs after opts.first_delay ms, or right away when that is nil.
local function retry(fn, opts)
	local tries_left = opts.tries
	local function attempt()
		if fn() then
			return
		end
		tries_left = tries_left - 1
		if tries_left > 0 then
			vim.defer_fn(attempt, opts.delay)
		end
	end
	if opts.first_delay then
		vim.defer_fn(attempt, opts.first_delay)
	else
		attempt()
	end
end

-- apply_comments_to_tab once diffview has laid out its two diff windows
-- (gives up after ~2s); `refresh_info` as in apply_comments_to_tab.
local function apply_comments_when_diffview_ready(tabpage, comments_payload, refresh_info)
	retry(function()
		if not vim.api.nvim_tabpage_is_valid(tabpage) then
			return true
		end
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
			local side = diff_side(win)
			if side == "left" or side == "right" then
				apply_comments_to_tab(tabpage, comments_payload, { refresh_info = refresh_info })
				return true
			end
		end
		return false
	end, { tries = 20, delay = 100 })
end

local function build_lines(prs)
	local lines = {
		"ID  STATE    AUTHOR               FROM -> TO           TITLE",
		string.rep("-", 90),
	}

	for _, pr in ipairs(prs) do
		local author = (pr.author and pr.author.user and (pr.author.user.displayName or pr.author.user.name))
			or "unknown"
		local from_ref = (pr.fromRef and pr.fromRef.displayId) or "?"
		local to_ref = (pr.toRef and pr.toRef.displayId) or "?"
		table.insert(
			lines,
			string.format(
				"%s %-3s %-8s %-20s %-18s %s",
				format_build_marker(pr),
				pr.id,
				pr.state or "-",
				author,
				from_ref .. " -> " .. to_ref,
				pr.title or ""
			)
		)
	end

	return lines
end

local function collect_diffview_file_entries(view)
	local entries = {}
	if view and view.panel and type(view.panel.components) == "table" then
		each_diffview_file_comp(view.panel.components, function(comp)
			local ctx = comp.context
			if type(ctx) == "table" and type(ctx.path) == "string" then
				table.insert(entries, ctx)
			end
		end)
	end
	if #entries == 0 and view and type(view.files) == "table" then
		local files_iter = view.files
		if type(files_iter.ipairs) == "function" then
			for _, f in files_iter:ipairs() do
				if type(f) == "table" and type(f.path) == "string" then
					table.insert(entries, f)
				end
			end
		else
			for _, f in ipairs(files_iter) do
				if type(f) == "table" and type(f.path) == "string" then
					table.insert(entries, f)
				end
			end
		end
	end
	return entries
end

local function navigate_to_file_comment_in_diffview(c, opts)
	opts = opts or {}
	local should_open_float = opts.open_float ~= false
	local ok, lib = pcall(require, "diffview.lib")
	local view = ok and lib.get_current_view() or nil
	if type(view) ~= "table" then
		vim.notify(
			string.format("bb_pr: comment on %s:%s", c.path or "?", tostring(c.line or "?")),
			vim.log.levels.INFO
		)
		return
	end

	local target_path = normalize_repo_path(c.path or "")
	local entries = collect_diffview_file_entries(view)
	local target_file = nil
	for _, entry in ipairs(entries) do
		if path_matches(entry.path or "", target_path) then
			target_file = entry
			break
		end
	end
	if not target_file then
		local paths = {}
		for _, e in ipairs(entries) do
			table.insert(paths, tostring(e.path or "?"))
		end
		vim.notify(
			"bb_pr: file not in PR diff: "
				.. (c.path or "?")
				.. (#paths > 0 and ("\navailable: " .. table.concat(paths, ", ")) or ""),
			vim.log.levels.WARN
		)
		return
	end
	if type(view.set_file) == "function" then
		pcall(view.set_file, view, target_file, false, true)
	end

	local line = tonumber(c.line or 0) or 0
	if line <= 0 then
		return
	end
	local file_type = string.upper(tostring(c.file_type or "TO"))
	local bb_line = line

	local function jump_cursor()
		local target_win = nil
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
			if vim.api.nvim_win_is_valid(win) and vim.wo[win].diff then
				local side = diff_side(win)
				if (file_type == "TO" and side == "right") or (file_type == "FROM" and side == "left") then
					target_win = win
					break
				end
				if side == "single" then
					target_win = target_win or win
				end
			end
		end
		if not target_win then
			return nil
		end
		local info = tab_diff_base()
		local finfo = info and window_file_info(target_win)
		if finfo then
			-- unmapped (line no longer shown) → keep the raw number as a best guess
			line = anchor_to_local_line(info, finfo, c) or bb_line
		end
		local buf = vim.api.nvim_win_get_buf(target_win)
		local line_count = vim.api.nvim_buf_line_count(buf)
		if line > line_count then
			line = line_count
		end
		vim.api.nvim_set_current_win(target_win)
		vim.api.nvim_win_set_cursor(target_win, { line, 0 })
		return { win = target_win, buf = buf }
	end

	local target_comment_id = tonumber(c.id or 0) or 0

	local function open_float_for_line(buf)
		local line_comments = get_buf_line_comments(buf)[line]
		if type(line_comments) ~= "table" or #line_comments == 0 then
			return false
		end
		local float_win = open_comment_float(line_comments, line)
		if target_comment_id > 0 and float_win and vim.api.nvim_win_is_valid(float_win) then
			local float_buf = vim.api.nvim_win_get_buf(float_win)
			local target_line = line_of_comment(comment_view(float_buf), target_comment_id)
			if target_line then
				pcall(vim.api.nvim_win_set_cursor, float_win, { target_line, 0 })
			end
		end
		return true
	end

	retry(function()
		local jumped = jump_cursor()
		if not jumped then
			return false
		end
		if should_open_float then
			retry(function()
				return open_float_for_line(jumped.buf)
			end, { tries = 20, delay = 100 })
		end
		return true
	end, { tries = 20, delay = 100, first_delay = 50 })
end

local function navigate_to_overview_comment(pr, comment_id)
	open_pr_info_with_comments(pr)
	retry(function()
		local view = comment_view(vim.api.nvim_get_current_buf())
		local line = view and view.kind == "overview" and line_of_comment(view, tonumber(comment_id))
		if line then
			pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
			return true
		end
		return false
	end, { tries = 20, delay = 100, first_delay = 50 })
end

local function consume_pending_nav(pr_id)
	local key = tonumber(pr_id or 0) or 0
	if key <= 0 then
		return nil
	end
	local nav = state.pending_nav_by_pr_id[key]
	state.pending_nav_by_pr_id[key] = nil
	return nav
end

local function try_navigate_to_pending_comment(pr, payload)
	local pr_id = tonumber(pr and pr.id or 0) or 0
	local nav = consume_pending_nav(pr_id)
	if type(nav) ~= "table" then
		return
	end
	local comment_id = tonumber(nav.comment_id or 0) or 0
	if comment_id <= 0 then
		return
	end

	for _, c in ipairs(as_array(payload and payload.file_comments)) do
		if tonumber(c.id or 0) == comment_id then
			navigate_to_file_comment_in_diffview(c)
			return
		end
	end
	for _, c in ipairs(as_array(payload and payload.overview_comments)) do
		if tonumber(c.id or 0) == comment_id then
			navigate_to_overview_comment(pr, comment_id)
			return
		end
	end
	vim.notify("bb_pr: comment #" .. comment_id .. " not found in PR", vim.log.levels.WARN)
end

local function close_old_pr_tabs()
	local pr_tabs = {}
	local has_safe_tab = false
	for _, t in ipairs(vim.api.nvim_list_tabpages()) do
		if get_tab_pr(t) then
			table.insert(pr_tabs, t)
		else
			has_safe_tab = true
		end
	end
	if #pr_tabs == 0 then
		return
	end

	-- ensure there's at least one non-PR tab so :tabclose on the last PR tab works
	if not has_safe_tab then
		vim.cmd("tabnew")
	end

	for _, t in ipairs(pr_tabs) do
		if vim.api.nvim_tabpage_is_valid(t) then
			pcall(vim.api.nvim_set_current_tabpage, t)
			pcall(vim.cmd, "silent! DiffviewClose")
			pcall(vim.cmd, "tabclose!")
		end
		state.tabs[tab_key(t)] = nil
	end
	state.git_text_cache = {}
	state.hunks_cache = {}
	state.buf_hunks_cache = {}
	state.rendered_by_buf = {}
	state.panel_rendered_by_buf = {}
	log("close_old_pr_tabs: closed", #pr_tabs, "tab(s)")
end

-- Resolve and cache the absolute git toplevel of the working copy the plugin
-- drives. Every git command and DiffviewOpen below is pinned to this path:
-- Neovim's process cwd shifts whenever a window/tab carrying a local directory
-- (`:lcd`/`:tcd`) gains focus, and close_old_pr_tabs() reshuffles tabs between the
-- checkout and DiffviewOpen. Relying on the ambient cwd makes the git commands
-- and diffview intermittently fail to find the repo ("Path not a git repo").
local function resolve_repo_root()
	if state.repo_root and vim.fn.isdirectory(state.repo_root) == 1 then
		return state.repo_root
	end

	local seen, candidates = {}, {}
	local function add(dir)
		if type(dir) == "string" and dir ~= "" and not seen[dir] then
			seen[dir] = true
			candidates[#candidates + 1] = dir
		end
	end

	local bufname = vim.api.nvim_buf_get_name(0)
	if type(bufname) == "string" and bufname:match("^diffview://") then
		-- diffview:// buffers encode the toplevel: diffview://<top>/.git/<rev>/<path>
		local stripped = bufname:gsub("^diffview://", "")
		local git_idx = stripped:find("/%.git/")
		if git_idx then
			add(stripped:sub(1, git_idx - 1))
		end
	elseif type(bufname) == "string" and bufname ~= "" and vim.bo.buftype == "" then
		add(vim.fn.fnamemodify(bufname, ":p:h"))
	end

	add(vim.fn.getcwd(-1, -1)) -- global cwd (what bare `vim.system` git calls use)
	add(vim.fn.getcwd()) -- window-local cwd, if any

	for _, dir in ipairs(candidates) do
		if vim.fn.isdirectory(dir) == 1 then
			local res = vim.system({ "git", "rev-parse", "--show-toplevel" }, { cwd = dir, text = true }):wait(2000)
			if res.code == 0 then
				local root = vim.trim(res.stdout or "")
				if root ~= "" and vim.fn.isdirectory(root) == 1 then
					state.repo_root = root
					return root
				end
			end
		end
	end

	return nil
end

-- Bail out of a merge left over from a conflicted PR checkout so the next PR can be
-- checked out cleanly. Gated on MERGE_HEAD: a plain dirty working tree is still
-- reported to the user instead of being silently reset.
-- cb(ok, aborted): `aborted` says whether there actually was a merge to leave.
local function abort_pending_merge(repo_root, cb)
	local git_opts = { text = true, cwd = repo_root }
	vim.system({ "git", "rev-parse", "--verify", "--quiet", "MERGE_HEAD" }, git_opts, function(head_res)
		if head_res.code ~= 0 then
			cb(true, false)
			return
		end
		vim.system({ "git", "merge", "--abort" }, git_opts, function(abort_res)
			if abort_res.code == 0 then
				log("abort_pending_merge: merge --abort succeeded")
				cb(true, true)
				return
			end
			-- `merge --abort` refuses when the resolution was partially staged or edited;
			-- the merge is ours, so drop it outright.
			vim.system({ "git", "reset", "--hard", "HEAD" }, git_opts, function(reset_res)
				if reset_res.code ~= 0 then
					vim.schedule(function()
						vim.notify(
							"bb_pr: failed to leave the conflicted merge: " .. (reset_res.stderr or ""),
							vim.log.levels.ERROR
						)
					end)
				else
					log("abort_pending_merge: reset --hard after failed merge --abort")
				end
				cb(reset_res.code == 0, true)
			end)
		end)
	end)
end

local function open_diffview(pr)
	local from_ref = pr.fromRef and pr.fromRef.displayId
	local to_ref = pr.toRef and pr.toRef.displayId
	if not from_ref or not to_ref then
		vim.notify("bb_pr: PR does not contain refs", vim.log.levels.WARN)
		return
	end

	local repo_root = resolve_repo_root()
	if not repo_root then
		vim.notify(
			"bb_pr: could not locate the git repository — open a file from the repo first",
			vim.log.levels.ERROR
		)
		return
	end

	-- Pin every git command and DiffviewOpen to repo_root so the flow is immune to
	-- the process cwd drifting as tabs/windows with local directories gain focus.
	local git_opts = { text = true, cwd = repo_root }

	local function open_after_fetch()
		local checkout_cmd = { "git", "checkout", "-B", from_ref, "origin/" .. from_ref }
		vim.system(checkout_cmd, git_opts, function(co_res)
			if co_res.code ~= 0 then
				vim.schedule(function()
					vim.notify(
						"bb_pr: failed to checkout " .. from_ref .. ": " .. (co_res.stderr or ""),
						vim.log.levels.ERROR
					)
				end)
				return
			end
			local merge_cmd = { "git", "merge", "origin/" .. to_ref, "--no-edit" }
			vim.system(merge_cmd, git_opts, function(merge_res)
				vim.schedule(function()
					-- A conflict is not fatal: the PR diff below still renders, with the
					-- unmerged files carrying inline conflict markers. Diffview only builds
					-- its 3-way "Conflicts" section for a revless `:DiffviewOpen`, because
					-- `git diff --name-status <rev>` reports unmerged paths as M, not U —
					-- so keep the rev here and let the user reach the merge tool manually.
					-- The merge is rolled back by abort_pending_merge() on the next open.
					local conflicted = merge_res.code ~= 0
					if conflicted then
						vim.notify(
							"bb_pr: merge conflict with origin/"
								.. to_ref
								.. " — opening the PR anyway; conflicted files carry inline markers,"
								.. " run :DiffviewOpen with no arguments for the 3-way merge tool",
							vim.log.levels.WARN
						)
					end
					close_old_pr_tabs()
					-- "commits" diffs the target tip against the merge commit HEAD, which
					-- holds the same content as the clean working tree; a conflicted merge
					-- has no such commit, so it keeps the working tree
					local rev = "origin/" .. to_ref
					if M.config.diff_mode == "commits" and not conflicted then
						rev = rev .. "..HEAD"
					end
					vim.cmd(
						string.format(
							"%s -C%s %s",
							M.config.diffview_cmd,
							vim.fn.fnameescape(repo_root),
							rev
						)
					)
					set_current_tab_pr(pr)
					set_current_tab_conflict(conflicted and { to_ref = to_ref } or nil)
					set_current_tab_diff_base(repo_root, from_ref, to_ref)
					local pr_tab = vim.api.nvim_get_current_tabpage()
					run_comments_provider(pr.id, function(payload)
						set_tab_comments(pr_tab, payload)
						apply_comments_when_diffview_ready(pr_tab, payload)
						vim.defer_fn(function()
							try_navigate_to_pending_comment(pr, payload)
						end, 300)
					end, { notify_errors = false })
				end)
			end)
		end)
	end

	local fetch_cmd = {
		"git",
		"fetch",
		"origin",
		"+refs/heads/" .. to_ref .. ":refs/remotes/origin/" .. to_ref,
		"+refs/heads/" .. from_ref .. ":refs/remotes/origin/" .. from_ref,
	}

	-- Roll back a merge left behind by a previously opened conflicting PR first,
	-- otherwise the dirty-tree gate below would refuse to check out the new branch.
	abort_pending_merge(repo_root, function(cleanup_ok)
		if not cleanup_ok then
			return -- abort_pending_merge already notified
		end

		vim.system({ "git", "diff", "--quiet", "HEAD" }, git_opts, function(st_res)
			if st_res.code ~= 0 then
				vim.schedule(function()
					vim.notify(
						"bb_pr: working tree has uncommitted changes, cannot checkout " .. from_ref,
						vim.log.levels.WARN
					)
				end)
				return
			end

			vim.system(fetch_cmd, git_opts, function(fetch_res)
				if fetch_res.code ~= 0 then
					vim.schedule(function()
						vim.notify(
							"bb_pr: failed to fetch PR branches: " .. (fetch_res.stderr or ""),
							vim.log.levels.ERROR
						)
					end)
					return
				end

				vim.schedule(open_after_fetch)
			end)
		end)
	end)
end

local function format_opened_date(ms)
	if type(ms) ~= "number" or ms <= 0 then
		return "unknown"
	end

	return os.date("%Y-%m-%d %H:%M:%S %Z", math.floor(ms / 1000))
end

local function build_approval_lines(pr)
	local reviewers = pr.reviewers or {}
	if #reviewers == 0 then
		return { "None" }
	end

	local grouped = {}
	local statuses = {}
	for _, reviewer in ipairs(reviewers) do
		local user = reviewer.user or {}
		local status = reviewer_status(reviewer)
		if not grouped[status] then
			grouped[status] = {}
			table.insert(statuses, status)
		end
		table.insert(grouped[status], user.displayName or user.name or user.slug or "unknown")
	end

	-- statuses are listed alphabetically: the APPROVED, UNAPPROVED, NEEDS_WORK, PENDING
	-- order this once intended never applied (it was matched against "**STATUS**" keys)
	table.sort(statuses)
	local lines = {}
	for _, status in ipairs(statuses) do
		local names = grouped[status]
		table.sort(names)
		table.insert(lines, string.format("**%s**: %s", status, table.concat(names, ", ")))
	end
	return lines
end

-- Appends the body of the PR Info "## Comments" section to `lines` (every comment of the
-- PR, grouped into threads, most recently active thread first) and records in `view`
-- which comment each line acts on, the reaction lines and the thread heading lines.
local function append_overview_comment_lines(lines, view, payload)
	local comments = {}
	vim.list_extend(comments, as_array(payload and payload.overview_comments))
	vim.list_extend(comments, as_array(payload and payload.file_comments))
	if #comments == 0 then
		table.insert(lines, "None")
		return
	end

	local comments_by_id = {}
	for _, c in ipairs(comments) do
		local cid = tonumber(c.id or 0) or 0
		if cid > 0 then
			comments_by_id[cid] = c
		end
	end

	local function thread_root_key(c, fallback_idx)
		local seen = {}
		local current = c
		local current_id = tonumber(current.id or 0) or 0
		local parent_id = tonumber(current.parent_id or 0) or 0

		while parent_id > 0 and not seen[parent_id] do
			seen[parent_id] = true
			local parent = comments_by_id[parent_id]
			if not parent then
				return parent_id
			end
			current = parent
			current_id = tonumber(current.id or 0) or 0
			parent_id = tonumber(current.parent_id or 0) or 0
		end

		if current_id > 0 then
			return current_id
		end
		return string.format("idx:%d", fallback_idx)
	end

	local thread_order = {}
	local comments_by_thread = {}
	local last_created_at = {}
	for idx, c in ipairs(comments) do
		local root = thread_root_key(c, idx)
		if not comments_by_thread[root] then
			comments_by_thread[root] = {}
			last_created_at[root] = ""
			table.insert(thread_order, root)
		end
		table.insert(comments_by_thread[root], c)
		local created_at = tostring(c.created_at or "")
		if created_at > last_created_at[root] then
			last_created_at[root] = created_at
		end
	end
	table.sort(thread_order, function(a, b)
		local a_last = last_created_at[a]
		local b_last = last_created_at[b]
		if a_last == b_last then
			return tostring(a) < tostring(b)
		end
		return a_last > b_last
	end)

	for thread_idx, root in ipairs(thread_order) do
		local thread_comments = comments_by_thread[root]
		local root_comment = thread_comments[1] or {}
		local root_id = tonumber(root_comment.id or 0) or 0
		if thread_idx > 1 then
			push_view_line(lines, view, "")
		end
		push_view_line(lines, view, string.format("### Thread %d", thread_idx), root_id)
		table.insert(view.thread_lines, #lines)
		if root_comment.is_file_comment then
			local path = root_comment.path or "(unknown file)"
			local line = tonumber(root_comment.line or 0) or 0
			local side = root_comment.file_type or ""
			local line_type = root_comment.line_type or ""
			local loc = line > 0 and string.format(":%d", line) or ""
			push_view_line(lines, view, string.format("_Scope: file • `%s%s` %s %s_", path, loc, side, line_type), root_id)
		else
			push_view_line(lines, view, "_Scope: overview_", root_id)
		end
		push_view_line(lines, view, "")

		for _, c in ipairs(thread_comments) do
			append_comment_lines(lines, view, c, true)
		end
	end
end

local function build_status_lines(payload)
	if type(payload) ~= "table" then
		return { "(loading…)" }
	end

	local summary = type(payload.summary) == "string" and string.upper(payload.summary) or "NONE"
	local labels = {
		SUCCESSFUL = "Successful",
		FAILED = "Failed",
		INPROGRESS = "In progress",
		NONE = "No builds",
	}
	local icon = BUILD_ICONS[summary] or "○"
	local label = labels[summary] or summary

	local lines = { string.format("%s %s", icon, label) }

	local builds = as_array(payload.builds)
	for _, b in ipairs(builds) do
		local state_up = type(b.state) == "string" and string.upper(b.state) or ""
		local mark = BUILD_ICONS[state_up] or "•"
		local name = b.name
		if type(name) ~= "string" or name == "" then
			name = b.key or "build"
		end
		local line = string.format("  %s %s", mark, name)
		if type(b.url) == "string" and b.url ~= "" then
			line = line .. "  " .. b.url
		end
		table.insert(lines, line)
	end

	return lines
end

-- The PR Info lines of `pr` and their comment view (see state.comment_view_by_buf)
local function build_pr_info_content(pr)
	local function to_lines(text)
		if type(text) ~= "string" or text == "" then
			return { "(no description)" }
		end

		return vim.split(text, "\n", { plain = true })
	end

	local info_lines = {
		string.format("PR #%s", tostring(pr.id or "?")),
		string.format("Title: %s", pr.title or ""),
		string.format("Opened: %s (%s ago)", format_opened_date(pr.createdDate), format_opened_age(pr.createdDate)),
		"",
		"## Description",
		"",
	}

	local conflict = get_current_tab_conflict()
	if conflict then
		-- right after "Opened:", so the conflict is the first thing visible in the header
		table.insert(info_lines, 4, string.format("Merge: CONFLICT with origin/%s", conflict.to_ref))
	end

	vim.list_extend(info_lines, to_lines(pr.description))
	table.insert(info_lines, "")
	table.insert(info_lines, "## My Review")
	table.insert(info_lines, "")
	table.insert(info_lines, string.format("Status: %s", normalize_my_review_status(pr)))
	table.insert(info_lines, "")
	table.insert(info_lines, "## Approvals")
	table.insert(info_lines, "")

	vim.list_extend(info_lines, build_approval_lines(pr))
	table.insert(info_lines, "")
	table.insert(info_lines, "## Build")
	table.insert(info_lines, "")

	vim.list_extend(info_lines, build_status_lines(get_current_tab_builds()))
	table.insert(info_lines, "")
	table.insert(info_lines, "## Comments")
	table.insert(info_lines, "")

	local view = { kind = "overview", pr = pr, ids_by_line = {}, reaction_segments = {}, thread_lines = {} }
	append_overview_comment_lines(info_lines, view, get_current_tab_comments())
	return info_lines, view
end

apply_pr_info_content = function(buf, pr)
	local info_lines, view = build_pr_info_content(pr)

	local saved_cursors = {}
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		saved_cursors[win] = save_comment_cursor(win, buf)
	end

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, info_lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	-- set once: re-setting it would re-run every FileType autocmd on each refresh
	if vim.bo[buf].filetype ~= "markdown" then
		vim.bo[buf].filetype = "markdown"
		vim.diagnostic.enable(false, { bufnr = buf })
	end
	state.comment_view_by_buf[buf] = view

	for win, saved in pairs(saved_cursors) do
		if vim.api.nvim_win_is_valid(win) then
			restore_comment_cursor(win, buf, saved)
		end
	end
end

-- Title/Body editor: "Title: <title>", a blank line, "Body:", then the body lines
local TITLE_PREFIX = "Title: "

local function title_body_lines(title, body_lines)
	return vim.list_extend({ TITLE_PREFIX .. title, "", "Body:" }, body_lines or {})
end

-- Trimmed title and untrimmed body of the Title/Body editor lines `lines`
local function parse_title_body(lines)
	local title = vim.trim((lines[1] or ""):gsub("^Title:%s*", "", 1))
	return title, table.concat(vim.list_slice(lines, 4), "\n")
end

-- Opens a Title/Body editor float (opts.win_title, opts.width, opts.height) holding
-- opts.title and opts.body_lines. <C-s> (normal and insert) and <CR> submit, q cancels.
-- A submit with an empty title only warns; otherwise on_submit(title, trimmed body)
-- runs and the float closes. Returns buf, win.
local function open_title_body_editor(opts, on_submit)
	local buf = create_scratch_buf("markdown")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, title_body_lines(opts.title, opts.body_lines))
	local win = open_centered_float(buf, { width = opts.width, height = opts.height, title = opts.win_title })

	local function submit()
		local title, body = parse_title_body(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
		if title == "" then
			vim.notify("bb_pr: PR title is required", vim.log.levels.WARN)
			return
		end
		on_submit(title, vim.trim(body))
		pcall(vim.api.nvim_win_close, win, true)
	end

	vim.keymap.set("n", "q", function()
		pcall(vim.api.nvim_win_close, win, true)
	end, { buffer = buf, silent = true })
	vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf, silent = true })
	vim.keymap.set("n", "<CR>", submit, { buffer = buf, silent = true })
	return buf, win
end

-- Runs `bb <args>` changing `pr`, then refetches the PR of the current tab, stores it
-- (keeping the comments), re-renders the PR Info buffer `info_buf` if it still exists
-- and notifies `done_msg`. Failures notify "bb_pr: <fail_msg>: <stderr>".
local function run_pr_info_mutation(args, fail_msg, pr, info_buf, done_msg)
	local source_tab = vim.api.nvim_get_current_tabpage()
	run_bb(args, { fail_msg = fail_msg }, function()
		refresh_current_pr(function(fresh_pr)
			local updated = fresh_pr or pr
			set_tab_pr(source_tab, updated, { preserve_comments = true })
			if info_buf and vim.api.nvim_buf_is_valid(info_buf) then
				apply_pr_info_content(info_buf, updated)
			end
			vim.notify(done_msg, vim.log.levels.INFO)
		end, source_tab)
	end)
end

local function open_edit_pr_description(pr, info_buf)
	local pr_id = tonumber(pr.id or 0) or 0
	if pr_id <= 0 then
		vim.notify("bb_pr: invalid PR id", vim.log.levels.ERROR)
		return
	end

	local description = pr.description or ""
	open_title_body_editor({
		win_title = "Edit PR #" .. tostring(pr_id) .. " (<C-s>/<CR> submit, q cancel)",
		width = math.max(90, math.floor(vim.o.columns * 0.7)),
		height = math.max(14, math.floor(vim.o.lines * 0.4)),
		title = pr.title or "",
		body_lines = description ~= "" and vim.split(description, "\n", { plain = true }) or {},
	}, function(title, body)
		local version = tonumber(pr.version or -1) or -1
		run_pr_info_mutation({
			"-json",
			"-pr-update",
			tostring(pr_id),
			"-pr-update-version",
			tostring(version),
			"-pr-title",
			title,
			"-pr-body",
			body,
		}, "PR update failed", pr, info_buf, "bb_pr: PR #" .. tostring(pr_id) .. " updated")
	end)
end

local function open_pr_info(pr)
	local buf = vim.api.nvim_create_buf(false, true)
	apply_pr_info_content(buf, pr)

	local pr_id = tonumber(pr.id or 0) or 0
	if pr_id > 0 then
		local source_tab = vim.api.nvim_get_current_tabpage()
		run_builds_provider(pr_id, function(builds)
			set_tab_builds(source_tab, builds)
			if vim.api.nvim_buf_is_valid(buf) then
				apply_pr_info_content(buf, pr_info_buffer_pr(buf) or pr)
			end
		end)
	end

	local win = open_comment_view_float(buf, "PR Info")

	local function apply_review_action(action)
		if pr_id <= 0 then
			vim.notify("bb_pr: invalid PR id", vim.log.levels.ERROR)
			return
		end
		run_pr_info_mutation(
			{ "-pr-review", tostring(pr_id), "-review-action", action, "-json" },
			"review action failed",
			pr,
			buf,
			string.format("bb_pr: %s sent for PR #%s", action, tostring(pr_id))
		)
	end

	local function open_file_of_comment()
		local cid = resolve_reply_target_comment_id()
		if not cid then
			vim.notify("bb_pr: move cursor to a file comment line", vim.log.levels.WARN)
			return
		end
		local target = find_comment_by_id(cid)
		if type(target) ~= "table" or not target.is_file_comment or not target.path then
			vim.notify("bb_pr: not a file comment", vim.log.levels.WARN)
			return
		end
		pcall(vim.api.nvim_win_close, win, true)
		navigate_to_file_comment_in_diffview(target, { open_float = false })
	end

	local function open_ticket_under_cursor()
		local ticket = ticket_under_cursor()
		if not ticket then
			vim.notify("bb_pr: no Jira ticket under cursor", vim.log.levels.WARN)
			return
		end
		open_jira_ticket(ticket)
	end

	local ov = M.config.overview
	local specs = {
		{ ov.approve_map, function()
			apply_review_action("approve")
		end, desc = "Approve PR" },
		{ ov.disapprove_map, function()
			apply_review_action("disapprove")
		end, desc = "Disapprove PR" },
		{ ov.needs_work_map, function()
			apply_review_action("needs-work")
		end, desc = "Mark PR needs work", help = "Needs work" },
		{ ov.edit_description_map, function()
			open_edit_pr_description(pr_info_buffer_pr(buf) or pr, buf)
		end, desc = "Edit PR title and description", help = "Edit title & description" },
		{
			ov.open_file_map,
			open_file_of_comment,
			desc = "Open file from overview comment in diff",
			help = "Open file from comment in diff",
		},
		{ M.config.jira.open_map, open_ticket_under_cursor, desc = "Open Jira ticket" },
		{
			ov.open_image_map,
			open_attachment_at_cursor,
			desc = "Download and open attachment under cursor",
			help = "Open attachment",
		},
		{ "─", nil, help = "── Comment actions ──────────────" },
	}
	-- comment actions: same keys as the line comments float
	vim.list_extend(specs, comment_action_specs(true))
	bind_keymaps(buf, specs, "PR Info — Keymaps")
end

open_pr_info_with_comments = function(pr)
	local payload = get_current_tab_comments()
	if payload then
		open_pr_info(pr)
		return
	end

	run_comments_provider(pr.id, function(fetched)
		set_current_tab_comments(fetched)
		open_pr_info(pr)
	end, { notify_errors = true })
end

local function open_telescope_picker(prs)
	local ok_pickers, pickers = pcall(require, "telescope.pickers")
	local ok_finders, finders = pcall(require, "telescope.finders")
	local ok_config, telescope_config = pcall(require, "telescope.config")
	local ok_actions, actions = pcall(require, "telescope.actions")
	local ok_action_state, action_state = pcall(require, "telescope.actions.state")

	if not (ok_pickers and ok_finders and ok_config and ok_actions and ok_action_state) then
		return false
	end

	pickers
		.new({}, {
			prompt_title = "Bitbucket Pull Requests",
			finder = finders.new_table({
				results = prs,
				entry_maker = function(pr)
					return {
						value = pr,
						display = format_pr_entry(pr),
						ordinal = table.concat({ tostring(pr.id or ""), pr.title or "", pr.state or "" }, " "),
					}
				end,
			}),
			sorter = telescope_config.values.generic_sorter({}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if selection and selection.value then
						open_diffview(selection.value)
					end
				end)

				actions.select_horizontal:replace(function()
					local selection = action_state.get_selected_entry()
					if selection and selection.value then
						open_pr_info_with_comments(selection.value)
					end
				end)

				return true
			end,
		})
		:find()

	return true
end

function M.open_pr(pr_id, opts)
	opts = opts or {}
	pr_id = tonumber(pr_id) or 0
	if pr_id <= 0 then
		vim.notify("bb_pr: invalid PR id", vim.log.levels.ERROR)
		return
	end
	local comment_id = tonumber(opts.comment_id or 0) or 0

	fetch_pr_by_id(pr_id, function(found)
		if not found then
			vim.notify("bb_pr: PR #" .. pr_id .. " not found in current repo", vim.log.levels.ERROR)
			return
		end
		if comment_id > 0 then
			state.pending_nav_by_pr_id[pr_id] = { comment_id = comment_id }
		end
		open_diffview(found)
	end)
end

function M.open_list()
	run_provider(function(prs)
		local sorted_prs = prs or {}
		state.prs = sorted_prs

		if open_telescope_picker(sorted_prs) then
			return
		end

		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(buf, "bb_pr://pull_requests")
		vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
		vim.api.nvim_set_option_value("filetype", "bb_pr", { buf = buf })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, build_lines(sorted_prs))

		-- the PR on the cursor line, below the two header lines of build_lines
		local function pr_at_cursor()
			return state.prs[vim.api.nvim_win_get_cursor(0)[1] - 2]
		end

		vim.keymap.set("n", "<CR>", function()
			local pr = pr_at_cursor()
			if pr then
				open_diffview(pr)
			end
		end, { buffer = buf, silent = true })

		vim.keymap.set("n", "i", function()
			local pr = pr_at_cursor()
			if pr then
				open_pr_info_with_comments(pr)
			end
		end, { buffer = buf, silent = true })

		vim.api.nvim_set_current_buf(buf)
	end)
end

local function detect_line_type_for_cursor(side, line)
	local ok, diff_hl = pcall(vim.fn.diff_hlID, line, 1)
	if not ok then
		log("detect_line_type: diff_hlID failed", "side=", side, "line=", line)
		return nil
	end
	local hl_id = tonumber(diff_hl or 0) or 0
	if hl_id == 0 then
		log("detect_line_type: hl_id=0 → CONTEXT", "side=", side, "line=", line)
		return "CONTEXT"
	end
	-- Vim highlights a line that exists only in this window as DiffAdd on either
	-- side, and a modified line as DiffChange/DiffText. Bitbucket's unified diff
	-- has no such distinction: every highlighted line is a removal on the old
	-- (FROM) side and an addition on the new (TO) side.
	local t = side == "left" and "REMOVED" or "ADDED"
	log("detect_line_type:", "side=", side, "line=", line, "hl_name=", vim.fn.synIDattr(hl_id, "name"), "→", t)
	return t
end

-- Resolves the anchor for a new file comment on `line` of the file shown in `win`.
-- Returns ctx or nil plus a reason.
local function resolve_file_comment_context(win, line)
	local finfo, err = window_file_info(win)
	if not finfo then
		return nil, err
	end
	local ctx = { mode = "new_file", bufnr = finfo.bufnr, path = finfo.path }
	local info = tab_diff_base(vim.api.nvim_win_get_tabpage(win))
	if info then
		local anchor, anchor_err = local_line_to_anchor(info, finfo, line)
		if not anchor then
			return nil, anchor_err
		end
		ctx.line, ctx.line_type, ctx.file_type = anchor.line, anchor.line_type, anchor.file_type
	else
		-- PR tab without recorded commits: fall back to the diff highlight of the line
		ctx.line = line
		ctx.line_type = vim.api.nvim_win_call(win, function()
			return detect_line_type_for_cursor(finfo.side, line)
		end) or "CONTEXT"
		ctx.file_type = finfo.side == "left" and "FROM" or "TO"
	end
	log("resolve_file_comment_context:", "local_line=", line, "side=", finfo.side, "mapped=", info ~= nil, "ctx=", ctx)
	return ctx
end

-- Where a new comment created at the cursor goes: { mode = "new_overview" } in PR Info,
-- otherwise the file anchor (see resolve_file_comment_context). Returns nil, reason
-- when the cursor has no such place.
local function resolve_comment_context()
	local bufnr = vim.api.nvim_get_current_buf()
	local line = vim.api.nvim_win_get_cursor(0)[1]

	local view = comment_view(bufnr)
	if vim.bo[bufnr].filetype == "markdown" and view and view.kind == "overview" then
		log("resolve_comment_context: new_overview", "bufnr=", bufnr, "line=", line)
		return { mode = "new_overview" }
	end

	-- line comments float: anchor to the diff line the float was opened from
	local source_win = vim.b[bufnr].bb_pr_float_source_win
	if source_win then
		local source_line = tonumber(vim.b[bufnr].bb_pr_float_source_line or 0) or 0
		if not (vim.api.nvim_win_is_valid(source_win) and source_line > 0) then
			return nil, "the diff window of this float is gone"
		end
		return resolve_file_comment_context(source_win, source_line)
	end

	return resolve_file_comment_context(vim.api.nvim_get_current_win(), line)
end

local function open_multiline_comment_input(opts, on_submit)
	opts = opts or {}
	local title = (opts.title or "Comment") .. (opts.title_suffix or "")
	local prompt = opts.prompt or "Write text. <C-s> submit, q cancel"
	local draft_key = opts.draft_key
	-- the prompt header above the text; get_typed_text skips it
	local header = { "<!-- " .. prompt .. " -->", "" }

	local fresh_text = opts.initial_text
	local draft, conflict = load_draft(draft_key, fresh_text or "")
	local initial_text = (draft and not conflict) and draft.text or fresh_text

	local buf = create_scratch_buf("markdown")
	local initial_lines = { "", "", "", "" }
	if type(initial_text) == "string" and initial_text ~= "" then
		initial_lines = vim.split(initial_text, "\n", { plain = true })
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)

	local win = open_centered_float(buf, {
		width = math.max(80, math.floor(vim.o.columns * 0.7)),
		height = math.max(12, math.floor(vim.o.lines * 0.35)),
		title = title,
	})
	vim.api.nvim_buf_set_lines(buf, 0, 0, false, header)
	vim.api.nvim_win_set_cursor(win, { 3, 0 })
	local sep_ns = vim.api.nvim_create_namespace("bb_pr_merge_sep")
	local function apply_separator()
		if not opts.title_separator then
			return
		end
		local sep_text = string.rep("─", math.max(40, math.floor(vim.o.columns * 0.5)))
		vim.api.nvim_buf_clear_namespace(buf, sep_ns, 0, -1)
		vim.api.nvim_buf_set_extmark(buf, sep_ns, 2, 0, {
			virt_lines = { { { sep_text, "Comment" } } },
			virt_lines_above = false,
		})
	end
	apply_separator()

	local function get_typed_text()
		if not vim.api.nvim_buf_is_valid(buf) then
			return ""
		end
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		if #lines >= 2 and lines[1]:match("^%<%!%-%-") then
			lines = vim.list_slice(lines, 3)
		end
		return vim.trim(table.concat(lines, "\n"))
	end

	announce_draft(buf, draft, conflict, function()
		local draft_lines = vim.split(draft.text, "\n", { plain = true })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.list_extend(vim.list_slice(header), draft_lines))
		apply_separator()
	end)

	local autosave = attach_draft_autosave({
		buf = buf,
		win = win,
		key = draft_key,
		base = fresh_text or "",
		get_text = get_typed_text,
	})

	local function submit_with(variant)
		return function()
			if not vim.api.nvim_buf_is_valid(buf) then
				return
			end
			local text = get_typed_text()
			autosave.cancel()
			delete_draft(draft_key)
			pcall(vim.api.nvim_win_close, win, true)
			if text ~= "" then
				on_submit(text, variant)
			end
		end
	end

	local submit = submit_with(opts.default_submit_variant)

	vim.keymap.set("n", "q", function()
		pcall(vim.api.nvim_win_close, win, true)
	end, { buffer = buf, silent = true })
	vim.keymap.set(
		{ "n", "i" },
		opts.submit_map or "<C-s>",
		submit_with(opts.submit_variant),
		{ buffer = buf, silent = true }
	)
	if opts.alt_submit_map and opts.alt_submit_map ~= "" then
		vim.keymap.set(
			{ "n", "i" },
			opts.alt_submit_map,
			submit_with(opts.alt_submit_variant),
			{ buffer = buf, silent = true }
		)
	end
	vim.keymap.set("n", "<CR>", submit, { buffer = buf, silent = true })
	vim.cmd("startinsert")
end

local function get_current_git_branch()
	local out = vim.fn.system({ "git", "rev-parse", "--abbrev-ref", "HEAD" })
	if vim.v.shell_error ~= 0 then
		return nil
	end
	local branch = vim.trim(out or "")
	if branch == "" then
		return nil
	end
	return branch
end

local function ensure_branch_synced_with_origin(branch)
	local fetch = vim.fn.system({ "git", "fetch", "origin", branch })
	if vim.v.shell_error ~= 0 then
		return false, "bb_pr: failed to fetch origin/" .. branch .. ": " .. vim.trim(fetch or "")
	end

	-- --verify prints the commit the ref points to
	local remote_ref = "refs/remotes/origin/" .. branch
	local remote_sha = vim.trim(vim.fn.system({ "git", "rev-parse", "--verify", remote_ref }) or "")
	if vim.v.shell_error ~= 0 then
		return false, "bb_pr: branch does not exist in origin: " .. branch
	end

	local local_sha = vim.trim(vim.fn.system({ "git", "rev-parse", "HEAD" }) or "")
	if vim.v.shell_error ~= 0 or local_sha == "" then
		return false, "bb_pr: failed to resolve local HEAD"
	end

	if remote_sha == "" then
		return false, "bb_pr: failed to resolve origin branch commit"
	end

	if local_sha ~= remote_sha then
		return false, "bb_pr: branch is not synced with origin/" .. branch .. " (push/pull required)"
	end

	return true
end

local function toggle_draft_in_title_line(line)
	if line:match("^%[DRAFT%]%s+") then
		return (line:gsub("^%[DRAFT%]%s+", "", 1))
	end
	return "[DRAFT] " .. line
end

local function open_create_pr_editor(source_branch, target_branch)
	local function resolve_pr_body_template_lines()
		local template = M.config.pr.create_body_template
		if type(template) == "string" then
			if vim.trim(template) == "" then
				return { "" }
			end
			return vim.split(template, "\n", { plain = true })
		end
		if type(template) == "table" then
			local lines = {}
			for _, item in ipairs(template) do
				table.insert(lines, tostring(item or ""))
			end
			if #lines == 0 then
				return { "" }
			end
			return lines
		end
		return { "" }
	end

	local function normalize_branch_title(branch)
		local name = branch:match("([^/]+)$") or branch
		name = name:gsub("[_%-%./]+", " ")
		name = vim.trim(name)
		return name:sub(1, 1):upper() .. name:sub(2)
	end

	local function do_open(default_title)
		local pr_draft_key = "create_pr:" .. source_branch .. ":" .. target_branch
		local template_lines = resolve_pr_body_template_lines()
		local fresh_base = vim.json.encode({ title = default_title, body = table.concat(template_lines, "\n") })
		local draft, conflict = load_draft(pr_draft_key, fresh_base)
		-- the draft's { title, body }; nil when there is none or it does not decode
		local saved = nil
		if draft then
			local ok, decoded = pcall(vim.json.decode, draft.text)
			saved = (ok and type(decoded) == "table") and decoded or nil
		end
		local saved_body_lines = saved
			and type(saved.body) == "string"
			and vim.split(saved.body, "\n", { plain = true })

		local title, body_lines = default_title, template_lines
		if saved and not conflict then
			if type(saved.title) == "string" and saved.title ~= "" then
				title = saved.title
			end
			body_lines = saved_body_lines or body_lines
		end

		local toggle_map = M.config.pr.create_toggle_draft_map
		local hints = { "<C-s> submit" }
		if toggle_map and toggle_map ~= "" then
			table.insert(hints, toggle_map .. " toggle [DRAFT]")
		end
		table.insert(hints, "q cancel")

		local autosave
		local buf, win = open_title_body_editor({
			win_title = "Create PR (" .. table.concat(hints, ", ") .. ")",
			width = math.floor(vim.o.columns * 0.8),
			height = math.floor(vim.o.lines * 0.8),
			title = title,
			body_lines = body_lines,
		}, function(pr_title, body)
			autosave.cancel()
			delete_draft(pr_draft_key)
			run_bb({
				"-json",
				"-pr-create",
				"-pr-title",
				pr_title,
				"-pr-body",
				body,
				"-pr-source",
				source_branch,
				"-pr-target",
				target_branch,
			}, { fail_msg = "create PR failed" }, function()
				vim.notify("bb_pr: pull request created", vim.log.levels.INFO)
			end)
		end)

		announce_draft(buf, draft, conflict, function()
			if not saved then
				return false
			end
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, title_body_lines(saved.title or "", saved_body_lines))
		end)

		local function get_pr_draft_text()
			if not vim.api.nvim_buf_is_valid(buf) then
				return nil
			end
			local typed_title, body = parse_title_body(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
			-- On exit the buffer can already be emptied; never overwrite a good
			-- draft with a blank one.
			if typed_title == "" and vim.trim(body) == "" then
				return nil
			end
			return vim.json.encode({ title = typed_title, body = body })
		end

		autosave = attach_draft_autosave({
			buf = buf,
			win = win,
			key = pr_draft_key,
			base = fresh_base,
			get_text = get_pr_draft_text,
		})

		local function toggle_draft()
			local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or TITLE_PREFIX
			local raw = line:gsub("^Title:%s*", "", 1)
			vim.api.nvim_buf_set_lines(buf, 0, 1, false, { TITLE_PREFIX .. toggle_draft_in_title_line(raw) })
		end
		bind_keymaps(buf, { { toggle_map, toggle_draft, desc = "Toggle [DRAFT]" } })
		vim.cmd("startinsert")
	end

	vim.system(
		{ "git", "log", "origin/" .. target_branch .. ".." .. source_branch, "--format=%s" },
		{ text = true },
		function(res)
			local commits = {}
			if res.code == 0 and res.stdout and res.stdout ~= "" then
				for line in res.stdout:gmatch("[^\n]+") do
					table.insert(commits, vim.trim(line))
				end
			end
			local default_title
			if #commits == 1 then
				default_title = commits[1]
			else
				default_title = normalize_branch_title(source_branch)
			end
			vim.schedule(function()
				do_open(default_title)
			end)
		end
	)
end

local function create_pr()
	local source_branch = get_current_git_branch()
	if not source_branch then
		vim.notify("bb_pr: failed to detect current git branch", vim.log.levels.ERROR)
		return
	end
	local function detect_origin_default_branch()
		local out = vim.fn.system({ "git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD" })
		if vim.v.shell_error ~= 0 then
			return nil
		end
		local ref = vim.trim(out or "")
		local branch = ref:match("^origin/(.+)$")
		if not branch or branch == "" then
			return nil
		end
		return branch
	end
	local default_branch = detect_origin_default_branch()
	local synced, sync_err = ensure_branch_synced_with_origin(source_branch)
	if not synced then
		vim.notify(sync_err, vim.log.levels.ERROR)
		return
	end
	run_bb({ "-json", "-target-branches" }, {
		json = true,
		fail_msg = "failed to load target branches",
		invalid_msg = "invalid target branches JSON",
	}, function(decoded)
		local options = {}
		for _, b in ipairs(decoded) do
			local name = tostring(b.displayId or "")
			if name ~= "" then
				table.insert(options, name)
			end
		end
		table.sort(options, function(a, b)
			local pa = (default_branch and a == default_branch) and 0 or 1
			local pb = (default_branch and b == default_branch) and 0 or 1
			if pa ~= pb then
				return pa < pb
			end
			return a < b
		end)
		if #options == 0 then
			vim.ui.input({ prompt = "Target branch: " }, function(input)
				local target = vim.trim(input or "")
				if target == "" then
					return
				end
				open_create_pr_editor(source_branch, target)
			end)
			return
		end
		vim.ui.select(options, { prompt = "Select target branch" }, function(choice)
			if not choice then
				return
			end
			open_create_pr_editor(source_branch, choice)
		end)
	end)
end

local function merge_current_pr()
	local pr = get_current_tab_pr()
	if not pr or not pr.id then
		vim.notify("bb_pr: no PR tracked for current tab", vim.log.levels.WARN)
		return
	end
	local template_fn = M.config.pr.merge_body_template_fn

	-- `commits` (the PR commits) is only fetched for template_fn
	local function open_merge_editor(commits)
		local title = string.format("PR #%s: %s", tostring(pr.id or ""), tostring(pr.title or ""))
		local body_lines = { "" }
		if type(template_fn) == "function" then
			local ok_tpl, tpl = pcall(template_fn, commits)
			if ok_tpl then
				if type(tpl) == "string" then
					body_lines = vim.split(tpl, "\n", { plain = true })
				elseif type(tpl) == "table" then
					body_lines = tpl
				end
			end
		else
			local tickets = {}
			for ticket in (pr.title or ""):gmatch("[A-Z][A-Z0-9]+%-%d+") do
				table.insert(tickets, ticket)
			end
			if #tickets > 0 then
				body_lines = { "Fixes " .. table.concat(tickets, " ") }
			end
		end
		local initial_text = title
		if type(body_lines) == "table" and #body_lines > 0 then
			initial_text = table.concat(vim.list_extend({ title, "" }, body_lines), "\n")
		end
		open_multiline_comment_input({
			title = "Merge PR #" .. tostring(pr.id),
			prompt = "Line 1: merge commit title. Next lines: commit body. <C-s> submit, q cancel",
			initial_text = initial_text,
			title_separator = true,
			draft_key = "merge:" .. tostring(pr.id),
		}, function(text)
			local body = ""
			if text:find("\n", 1, true) then
				local lines = vim.split(text, "\n", { plain = true })
				title = vim.trim(lines[1] or "")
				body = vim.trim(table.concat(vim.list_slice(lines, 2), "\n"))
			else
				title = vim.trim(text)
			end
			if title == "" then
				vim.notify("bb_pr: merge commit title is required", vim.log.levels.WARN)
				return
			end
			run_bb(
				{ "-json", "-pr-merge", tostring(pr.id), "-merge-title", title, "-merge-body", body },
				{ fail_msg = "merge failed" },
				function()
					vim.notify("bb_pr: pull request merged", vim.log.levels.INFO)
				end
			)
		end)
	end

	if type(template_fn) ~= "function" then
		open_merge_editor(nil)
		return
	end
	run_bb({ "-json", "-pr-commits", tostring(pr.id) }, {
		json = true,
		fail_msg = "failed to load PR commits",
		invalid_msg = "invalid PR commits JSON",
	}, open_merge_editor)
end

-- Leave the PR: close its tabs and, if the checkout left an unresolved merge behind,
-- roll that merge back so the working tree is usable again.
local function close_current_pr()
	local pr = get_current_tab_pr()
	local repo_root = resolve_repo_root()
	if not pr and not repo_root then
		vim.notify("bb_pr: no PR open", vim.log.levels.WARN)
		return
	end

	close_old_pr_tabs()

	if not repo_root then
		return
	end

	abort_pending_merge(repo_root, function(ok, aborted)
		if ok and aborted then
			vim.schedule(function()
				vim.notify("bb_pr: left the conflicted merge, working tree reset", vim.log.levels.INFO)
			end)
		end
	end)
end

-- Id of the comment the cursor line acts on in a comment view (float or PR Info)
resolve_reply_target_comment_id = function()
	local view = comment_view(vim.api.nvim_get_current_buf())
	return view and view.ids_by_line[vim.api.nvim_win_get_cursor(0)[1]] or nil
end

-- Re-opens the line comments float `win` showing `buf` with the comments now on its
-- source line, keeping the cursor on the same comment.
local function refresh_float_window_if_needed(win, buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local was_current = vim.api.nvim_get_current_win() == win
	local source_win = vim.b[buf].bb_pr_float_source_win
	local source_bufnr = vim.b[buf].bb_pr_float_source_bufnr
	local source_line = vim.b[buf].bb_pr_float_source_line
	if not (source_win and source_bufnr and source_line) then
		return
	end
	if not (vim.api.nvim_win_is_valid(source_win) and vim.api.nvim_buf_is_valid(source_bufnr)) then
		return
	end

	local saved = nil
	if vim.api.nvim_win_is_valid(win) then
		saved = save_comment_cursor(win, buf)
		pcall(vim.api.nvim_win_close, win, true)
	end
	local reopened_win = nil
	vim.api.nvim_win_call(source_win, function()
		local updated_comments = get_buf_line_comments(source_bufnr)[source_line]
		if updated_comments and #updated_comments > 0 then
			reopened_win = open_comment_float(updated_comments, source_line)
		end
	end)
	if reopened_win and vim.api.nvim_win_is_valid(reopened_win) then
		if was_current then
			pcall(vim.api.nvim_set_current_win, reopened_win)
		end
		if saved then
			restore_comment_cursor(reopened_win, vim.api.nvim_win_get_buf(reopened_win), saved)
		end
	end
end

-- Refetches the comments of the PR of `tabpage` and re-renders them: the diff windows,
-- the line comments float in opts.win / opts.buf (default: the current window when the
-- comments arrive) and a PR Info buffer there, or with opts.refresh_info every PR Info
-- window of the tab. opts.notify_errors = false keeps fetch errors silent.
local function reload_tab_comments(tabpage, opts)
	opts = opts or {}
	if not vim.api.nvim_tabpage_is_valid(tabpage) then
		return
	end
	local pr = get_tab_pr(tabpage)
	if not pr or not pr.id then
		vim.notify("bb_pr: no PR tracked for current tab", vim.log.levels.WARN)
		return
	end

	run_comments_provider(pr.id, function(payload)
		set_tab_comments(tabpage, payload)
		apply_comments_when_diffview_ready(tabpage, payload, opts.refresh_info)
		local win = opts.win or vim.api.nvim_get_current_win()
		local buf = opts.buf or vim.api.nvim_get_current_buf()
		vim.defer_fn(function()
			refresh_float_window_if_needed(win, buf)
		end, 150)
		local info_pr = not opts.refresh_info and vim.api.nvim_buf_is_valid(buf) and pr_info_buffer_pr(buf)
		if info_pr and tonumber(info_pr.id or 0) == tonumber(pr.id or 0) then
			apply_pr_info_content(buf, info_pr)
		end
	end, { notify_errors = opts.notify_errors })
end

-- PR of the current tab, or nil after a warning
local function tab_pr_or_warn()
	local pr = get_current_tab_pr()
	if not pr or not pr.id then
		vim.notify("bb_pr: no PR tracked for current tab", vim.log.levels.WARN)
		return nil
	end
	return pr
end

local COMMENT_LINE_HINT = "bb_pr: move cursor to a comment line in BBPROpenLineComments or PR Info"
local COMMENT_NOT_LOADED = "bb_pr: could not find selected comment in loaded payload"

-- The comment the cursor line acts on: cid, comment, version — or nil after a warning.
--   opts.no_target_msg / opts.missing_msg: replace the default warnings
--   opts.allow_missing: return the cid even when the payload lacks the comment
--   opts.version_for = "<verb>": also require a valid version (warns "... for <verb>")
local function cursor_comment_or_warn(opts)
	opts = opts or {}
	local cid = resolve_reply_target_comment_id()
	if not cid then
		vim.notify(opts.no_target_msg or COMMENT_LINE_HINT, vim.log.levels.WARN)
		return nil
	end
	local comment = find_comment_by_id(cid)
	if not comment then
		if opts.allow_missing then
			return cid
		end
		vim.notify(opts.missing_msg or COMMENT_NOT_LOADED, vim.log.levels.WARN)
		return nil
	end
	if not opts.version_for then
		return cid, comment
	end
	local version = tonumber(comment.version or -1) or -1
	if version < 0 then
		vim.notify("bb_pr: selected comment has invalid version for " .. opts.version_for, vim.log.levels.WARN)
		return nil
	end
	return cid, comment, version
end

local function toggle_task_status()
	local pr = tab_pr_or_warn()
	if not pr then
		return
	end
	local not_task = "bb_pr: selected comment is not a task"
	local cid, target = cursor_comment_or_warn({
		no_target_msg = "bb_pr: move cursor to a task line in BBPROpenLineComments or PR Info",
		missing_msg = not_task,
	})
	if not cid then
		return
	end
	if not target.is_task then
		vim.notify(not_task, vim.log.levels.WARN)
		return
	end
	local next_state = is_task_done(target) and "open" or "done"
	local version = tonumber(target.version or 0) or 0
	local source_tab = vim.api.nvim_get_current_tabpage()
	run_bb({
		"-json",
		"-pr-task-status",
		tostring(pr.id),
		"-task-id",
		tostring(cid),
		"-task-state",
		next_state,
		"-task-version",
		tostring(version),
	}, { fail_msg = "toggle task failed" }, function()
		vim.notify("bb_pr: task marked " .. next_state, vim.log.levels.INFO)
		reload_tab_comments(source_tab)
	end)
end

local function resolve_comment()
	local pr = tab_pr_or_warn()
	if not pr then
		return
	end
	local cid, target = cursor_comment_or_warn()
	if not cid then
		return
	end
	local version = tonumber(target.version or 0) or 0
	local action = target.is_resolved and "unresolve" or "resolve"
	local source_tab = vim.api.nvim_get_current_tabpage()
	run_bb({
		"-json",
		"-pr-resolve-comment",
		tostring(pr.id),
		"-resolve-comment-id",
		tostring(cid),
		"-resolve-comment-version",
		tostring(version),
		"-resolve-action",
		action,
	}, { fail_msg = "resolve comment failed" }, function()
		local verb = action == "resolve" and "resolved" or "unresolved"
		vim.notify("bb_pr: comment thread " .. verb, vim.log.levels.INFO)
		reload_tab_comments(source_tab)
	end)
end

find_comment_by_id = function(cid)
	local payload = get_current_tab_comments() or {}
	for _, c in ipairs(as_array(payload.overview_comments)) do
		if tonumber(c.id or 0) == cid then
			return c
		end
	end
	for _, c in ipairs(as_array(payload.file_comments)) do
		if tonumber(c.id or 0) == cid then
			return c
		end
	end
	return nil
end

local function extract_first_suggestion_block(text)
	return type(text) == "string" and text:match("```suggestion%s*\n(.-)\n```") or nil
end

local function accept_suggestion()
	local cid, comment = cursor_comment_or_warn()
	if not cid then
		return
	end
	if not comment.is_file_comment then
		vim.notify(
			"bb_pr: selected comment is overview-only, no file location to apply suggestion",
			vim.log.levels.WARN
		)
		return
	end
	local replacement = extract_first_suggestion_block(comment.text)
	if not replacement then
		vim.notify("bb_pr: selected comment has no ```suggestion``` block", vim.log.levels.WARN)
		return
	end
	local line = tonumber(comment.line or 0) or 0
	if line <= 0 then
		vim.notify("bb_pr: selected comment has invalid line anchor", vim.log.levels.WARN)
		return
	end
	local target_path = normalize_repo_path(comment.path or "")
	local info = tab_diff_base()
	local buf = resolve_apply_target_bufnr(target_path, info and info.root)
	local cur_buf_path = current_buffer_repo_path(buf)
	if target_path == "" or not path_matches(cur_buf_path, target_path) then
		vim.notify(
			string.format(
				"bb_pr: open commented file before accepting suggestion (anchor=%s current=%s buf=%s)",
				target_path,
				cur_buf_path,
				vim.api.nvim_buf_get_name(buf)
			),
			vim.log.levels.WARN
		)
		return
	end
	if info then
		-- the buffer is the working tree with the target merged in: translate the
		-- Bitbucket TO line into it
		local mapped = anchor_to_local_line(
			info,
			{ bufnr = buf, path = target_path, from_path = target_path, side = "right" },
			comment
		)
		if not mapped then
			vim.notify("bb_pr: the commented line is no longer in the working tree", vim.log.levels.WARN)
			return
		end
		line = mapped
	end
	local replacement_lines = vim.split(replacement, "\n", { plain = true })
	local ok_apply, apply_err = apply_suggestion_lines(buf, line, replacement_lines)
	if not ok_apply then
		vim.notify("bb_pr: failed to apply suggestion: " .. tostring(apply_err or ""), vim.log.levels.ERROR)
		return
	end
	-- with diff_mode = "commits" the tab shows no working tree file, so an edit to a
	-- hidden buffer would go unnoticed: write it out
	if #vim.fn.win_findbuf(buf) == 0 then
		local ok_write, write_err = pcall(vim.api.nvim_buf_call, buf, function()
			vim.cmd("silent write")
		end)
		if not ok_write then
			vim.notify("bb_pr: suggestion applied but not saved: " .. tostring(write_err), vim.log.levels.ERROR)
			return
		end
		vim.notify(
			"bb_pr: suggestion applied and saved to " .. target_path .. ". Commit and push manually (git add/commit/push).",
			vim.log.levels.INFO
		)
		return
	end
	vim.notify("bb_pr: suggestion applied. Commit and push manually (git add/commit/push).", vim.log.levels.INFO)
end

local function sort_reactions_by_recent_use(choices)
	table.sort(choices, function(a, b)
		local sa = tonumber(state.reaction_usage_by_key[a] or 0) or 0
		local sb = tonumber(state.reaction_usage_by_key[b] or 0) or 0
		if sa ~= sb then
			return sa > sb
		end
		return a < b
	end)
	return choices
end

-- Upper-cased, trimmed, non-empty reaction choices of the config (the default reaction
-- when none remain); run once by setup.
local function normalize_reaction_choices()
	local normalized = {}
	for _, item in ipairs(as_array(M.config.reactions.choices)) do
		local v = vim.trim(tostring(item or ""))
		if v ~= "" then
			table.insert(normalized, string.upper(v))
		end
	end
	if #normalized == 0 then
		normalized = { string.upper(tostring(M.config.reactions.default or "THUMBS_UP")) }
	end
	M.config.reactions.choices = normalized
end

local function show_reaction_users()
	local view = comment_view(vim.api.nvim_get_current_buf())
	local cursor = vim.api.nvim_win_get_cursor(0)
	local entry = view and view.reaction_segments[cursor[1]]
	if not entry then
		vim.notify("bb_pr: move cursor to a reaction line in BBPROpenLineComments or PR Info", vim.log.levels.WARN)
		return
	end
	local col = cursor[2]

	local cid = tonumber(entry.comment_id or 0) or 0
	local comment = cid > 0 and find_comment_by_id(cid) or nil
	if type(comment) ~= "table" then
		vim.notify(COMMENT_NOT_LOADED, vim.log.levels.WARN)
		return
	end
	if type(comment.reaction_users) ~= "table" then
		vim.notify(
			"bb_pr: this bb binary does not report reaction users; rebuild bb and run BBPRLoadComments",
			vim.log.levels.WARN
		)
		return
	end

	-- cursor inside a specific reaction shows only that one; anywhere else on the line shows all
	local selected = {}
	for _, seg in ipairs(entry.segments) do
		if col >= seg.start_col and col < seg.end_col then
			selected = { seg }
			break
		end
	end
	if #selected == 0 then
		selected = entry.segments
	end

	local lines = {}
	for _, seg in ipairs(selected) do
		local users = as_array(comment.reaction_users[seg.key])
		local label = string.format("%s (%d)", reactions.render_choice(seg.key), #users)
		if #users == 0 then
			table.insert(lines, { label, "(no users reported)" })
		else
			for idx, user in ipairs(users) do
				table.insert(lines, { idx == 1 and label or "", tostring(user) })
			end
		end
	end

	if #lines == 0 then
		vim.notify("bb_pr: no reactions on this comment", vim.log.levels.INFO)
		return
	end

	open_help_float(lines, string.format("Reactions — comment #%d", cid))
end

local function react_to_comment()
	local pr = tab_pr_or_warn()
	if not pr then
		return
	end
	-- a comment missing from the payload gets the reaction added
	local cid = cursor_comment_or_warn({ allow_missing = true })
	if not cid then
		return
	end
	local source_tab = vim.api.nvim_get_current_tabpage()
	local choices = sort_reactions_by_recent_use(vim.list_slice(M.config.reactions.choices))
	vim.ui.select(choices, {
		prompt = "Pick reaction",
		format_item = function(item)
			return reactions.render_choice(item)
		end,
	}, function(choice)
		if not choice or choice == "" then
			return
		end
		local existing = find_comment_by_id(cid)
		local action = "add"
		if existing and type(existing.my_reactions) == "table" and existing.my_reactions[choice] then
			action = "remove"
		end
		run_bb({
			"-json",
			"-pr-reaction",
			tostring(pr.id),
			"-comment-id",
			tostring(cid),
			"-reaction",
			choice,
			"-reaction-action",
			action,
		}, { fail_msg = "add reaction failed" }, function()
			state.reaction_usage_seq = state.reaction_usage_seq + 1
			state.reaction_usage_by_key[choice] = state.reaction_usage_seq
			persist_reaction_recency_state()
			vim.notify("bb_pr: reaction " .. (action == "remove" and "removed" or "added"), vim.log.levels.INFO)
			reload_tab_comments(source_tab)
		end)
	end)
end

local function delete_comment()
	local pr = tab_pr_or_warn()
	if not pr then
		return
	end
	local cid, _, version = cursor_comment_or_warn({ version_for = "delete" })
	if not cid then
		return
	end
	local source_tab = vim.api.nvim_get_current_tabpage()
	run_bb({
		"-json",
		"-pr-delete-comment",
		tostring(pr.id),
		"-delete-comment-id",
		tostring(cid),
		"-delete-comment-version",
		tostring(version),
	}, { fail_msg = "delete comment failed" }, function()
		vim.notify("bb_pr: comment deleted", vim.log.levels.INFO)
		reload_tab_comments(source_tab)
	end)
end

local function edit_comment()
	local pr = tab_pr_or_warn()
	if not pr then
		return
	end
	local cid, target, version = cursor_comment_or_warn({ version_for = "edit" })
	if not cid then
		return
	end
	local source_tab = vim.api.nvim_get_current_tabpage()

	open_multiline_comment_input({
		title = "Edit Comment #" .. tostring(cid),
		prompt = "Edit text. <C-s>/<CR> submit, q cancel",
		initial_text = target.text or "",
	}, function(text)
		run_bb({
			"-json",
			"-pr-update-comment",
			tostring(pr.id),
			"-update-comment-id",
			tostring(cid),
			"-update-comment-version",
			tostring(version),
			"-text",
			text,
		}, { fail_msg = "edit comment failed" }, function()
			vim.notify("bb_pr: comment #" .. tostring(cid) .. " updated", vim.log.levels.INFO)
			reload_tab_comments(source_tab)
		end)
	end)
end

local function convert_comment_task()
	local pr = tab_pr_or_warn()
	if not pr then
		return
	end
	local cid, target, version = cursor_comment_or_warn({ version_for = "convert" })
	if not cid then
		return
	end
	local convert_to = target.is_task and "comment" or "task"
	local source_tab = vim.api.nvim_get_current_tabpage()
	run_bb({
		"-json",
		"-pr-convert-comment",
		tostring(pr.id),
		"-convert-comment-id",
		tostring(cid),
		"-convert-comment-version",
		tostring(version),
		"-convert-to",
		convert_to,
	}, { fail_msg = "convert failed" }, function()
		vim.notify("bb_pr: converted to " .. convert_to, vim.log.levels.INFO)
		reload_tab_comments(source_tab)
	end)
end

-- Opens the comment input and posts the text. force_reply replies to the comment under
-- the cursor, otherwise the comment goes where resolve_comment_context puts it.
-- opts.initial_text prefills the input; opts.ctx / opts.reply_to pass an already
-- resolved context / reply target.
local function post_comment_or_task(is_task, force_reply, opts)
	opts = opts or {}
	local pr = tab_pr_or_warn()
	if not pr then
		return
	end
	local ctx, reply_to = opts.ctx, opts.reply_to
	if force_reply then
		reply_to = reply_to or resolve_reply_target_comment_id()
		if not reply_to then
			vim.notify(COMMENT_LINE_HINT, vim.log.levels.WARN)
			return
		end
	elseif not ctx then
		local ctx_err
		ctx, ctx_err = resolve_comment_context()
		if not ctx then
			vim.notify("bb_pr: cannot create comment here: " .. (ctx_err or "unknown context"), vim.log.levels.WARN)
			return
		end
	end

	local source_tab = vim.api.nvim_get_current_tabpage()
	local comment_win = vim.api.nvim_get_current_win()
	local comment_bufnr = vim.api.nvim_get_current_buf()
	local comment_draft_key
	if reply_to then
		comment_draft_key = "comment:reply:" .. tostring(reply_to)
	elseif ctx.mode == "new_file" then
		comment_draft_key = "comment:file:"
			.. tostring(pr.id)
			.. ":"
			.. tostring(ctx.path or "")
			.. ":"
			.. tostring(ctx.line or 0)
	else
		comment_draft_key = "comment:overview:" .. tostring(pr.id)
	end
	local cmaps = M.config.comments
	local submit_comment_map = cmaps.submit_comment_map or "<C-s>"
	local submit_task_map = cmaps.submit_task_map or "<C-t>"
	open_multiline_comment_input({
		title = is_task and "BB PR Task" or "BB PR Comment",
		prompt = string.format(
			"Write multiline text. %s submit comment, %s submit task, <CR> submit %s, q cancel",
			submit_comment_map,
			submit_task_map,
			is_task and "task" or "comment"
		),
		title_suffix = string.format(" (%s comment, %s task)", submit_comment_map, submit_task_map),
		initial_text = opts.initial_text,
		draft_key = comment_draft_key,
		submit_map = submit_comment_map,
		submit_variant = false,
		alt_submit_map = submit_task_map,
		alt_submit_variant = true,
		default_submit_variant = is_task,
	}, function(text, as_task)
		local cmd = bb_cmd({ "-json", "-pr-comment", tostring(pr.id), "-text", text })
		if as_task then
			table.insert(cmd, "-task")
		end
		if reply_to then
			vim.list_extend(cmd, { "-reply-to", tostring(reply_to) })
		elseif ctx.mode == "new_file" then
			vim.list_extend(cmd, {
				"-path",
				tostring(ctx.path or ""),
				"-line",
				tostring(ctx.line or 0),
				"-line-type",
				tostring(ctx.line_type or "CONTEXT"),
				"-file-type",
				tostring(ctx.file_type or "TO"),
			})
		end
		local kind = as_task and "task" or "comment"
		log("send_comment cmd:", cmd, "ctx=", ctx, "reply_to=", reply_to, "as_task=", as_task)
		-- a failure is logged by run_bb_cmd with the exit code and stderr
		run_bb_cmd(cmd, { fail_msg = "create " .. kind .. " failed" }, function(res)
			log("send_comment OK stdout=", res.stdout or "")
			vim.notify("bb_pr: " .. kind .. " sent", vim.log.levels.INFO)
			reload_tab_comments(source_tab, {
				win = comment_win,
				buf = comment_bufnr,
				refresh_info = true,
				notify_errors = false,
			})
		end)
	end)
end

local function suggestion_prefill_for_context(ctx, suggestion_line)
	if ctx and ctx.mode == "new_file" and suggestion_line ~= "" then
		return string.format("```suggestion\n%s\n```", suggestion_line)
	end
	return "```suggestion\n\n```"
end

local function create_suggestion_comment()
	local ctx, ctx_err = resolve_comment_context()
	if not ctx then
		vim.notify("bb_pr: cannot create comment here: " .. (ctx_err or "unknown context"), vim.log.levels.WARN)
		return
	end

	local suggestion_line = ""
	if ctx.mode == "new_file" and type(ctx.line) == "number" and ctx.line > 0 then
		local line = vim.api.nvim_buf_get_lines(ctx.bufnr, ctx.line - 1, ctx.line, false)[1]
		if type(line) == "string" then
			suggestion_line = line
		end
	end

	-- on a comment line of a float or PR Info the suggestion is a reply to that comment
	local reply_to = resolve_reply_target_comment_id()
	post_comment_or_task(false, reply_to ~= nil, {
		ctx = ctx,
		reply_to = reply_to,
		initial_text = suggestion_prefill_for_context(ctx, suggestion_line),
	})
end

ticket_under_cursor = function()
	local word = vim.fn.expand("<cWORD>")
	return word:match("[A-Z][A-Z0-9]+%-%d+")
end

open_jira_ticket = function(ticket)
	run_bb({ "-jira-ticket", ticket }, {
		json = true,
		fail_msg = "jira fetch failed",
		invalid_msg = "invalid jira response",
	}, function(issue)
		local lines = {}
		local function push(s)
			table.insert(lines, ((s or ""):gsub("\r", "")))
		end
		local function split_field(s)
			return vim.split((s or ""):gsub("\r\n", "\n"):gsub("\r", "\n"), "\n", { plain = true })
		end

		push(string.format("[%s] %s", issue.key or "", issue.summary or ""))
		push(string.rep("─", 60))
		local function meta(label, val)
			if type(val) == "string" and val ~= "" then
				push(string.format("%-14s %s", label .. ":", val))
			end
		end
		meta("Type", issue.type)
		meta("Status", issue.status)
		meta("Priority", issue.priority)
		meta("Assignee", issue.assignee)
		meta("Reporter", issue.reporter)
		meta("Epic", issue.epic_link)
		if type(issue.fix_versions) == "table" and #issue.fix_versions > 0 then
			meta("Fix Versions", table.concat(issue.fix_versions, ", "))
		end
		push(string.rep("─", 60))
		if type(issue.description) == "string" and issue.description ~= "" then
			for _, l in ipairs(split_field(issue.description)) do
				push(l)
			end
		else
			push("(no description)")
		end

		local comments = type(issue.comments) == "table" and issue.comments or {}
		if #comments > 0 then
			push("")
			push(string.rep("─", 60))
			push(string.format("Comments (%d):", #comments))
			for _, c in ipairs(comments) do
				push("")
				push(string.format("  %s  •  %s", c.author or "", (c.created or ""):sub(1, 10)))
				for _, l in ipairs(split_field(c.body or "")) do
					push("  " .. l)
				end
			end
		end

		local buf = create_scratch_buf("markdown")
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false

		local win = open_centered_float(buf, {
			width = math.max(70, math.floor(vim.o.columns * 0.65)),
			height = math.min(#lines + 2, math.floor(vim.o.lines * 0.7)),
			title = " " .. (issue.key or ticket) .. " ",
			footer = " ? help ",
		})
		vim.wo[win].wrap = true
		vim.wo[win].linebreak = true

		local function close()
			pcall(vim.api.nvim_win_close, win, true)
		end
		local url = issue.url or ""
		bind_keymaps(buf, {
			{ "q", close, help = false },
			{ "<Esc>", close, help = false },
			{
				url ~= "" and M.config.jira.open_url_map or nil,
				function()
					vim.fn.jobstart({ "xdg-open", url }, { detach = true })
				end,
				desc = "Open Jira ticket in browser",
				help = "Open in browser",
			},
			{ "q / <Esc>", nil, help = "Close" },
		}, "Jira — Keymaps")
	end)
end

-- Repository slug and project key of `pr`, each from its target ref, else its source ref
local function pr_repo_context(pr)
	local slug = vim.tbl_get(pr, "toRef", "repository", "slug") or vim.tbl_get(pr, "fromRef", "repository", "slug")
	local project = vim.tbl_get(pr, "toRef", "repository", "project", "key")
		or vim.tbl_get(pr, "fromRef", "repository", "project", "key")
	return slug, project
end

open_attachment_at_cursor = function()
	local line = vim.api.nvim_get_current_line()
	local _, attach_y = line:match("!%[.-%]%(attachment:(%d+)/(%d+)%)")
	if not attach_y then
		_, attach_y = line:match("attachment:(%d+)/(%d+)")
	end
	if not attach_y then
		vim.notify("bb_pr: no attachment under cursor", vim.log.levels.WARN)
		return
	end

	local ext = ".png"
	local alt = line:match("!%[(.-)%]%(attachment:")
	if alt and alt:match("%.%a+$") then
		ext = "." .. ((alt:match("%.(%a+)$") or "png"):lower())
	end

	local pr = get_current_tab_pr()
	if not pr then
		vim.notify("bb_pr: no PR loaded for current tab", vim.log.levels.WARN)
		return
	end

	local self_href = vim.tbl_get(pr, "links", "self", 1, "href") or ""
	local base_url = self_href:match("^(https?://[^/]+)") or ""
	local repo, project = pr_repo_context(pr)
	repo, project = repo or "", project or ""
	if base_url == "" or project == "" or repo == "" then
		vim.notify("bb_pr: cannot determine PR context", vim.log.levels.WARN)
		return
	end

	local url = base_url .. "/rest/api/latest/projects/" .. project .. "/repos/" .. repo .. "/attachments/" .. attach_y
	local tmp = vim.fn.tempname() .. ext
	vim.notify("bb_pr: fetching attachment…", vim.log.levels.INFO)

	vim.system(bb_cmd({ "-fetch-url", url }), { text = false }, function(res)
		if res.code ~= 0 then
			vim.schedule(function()
				vim.notify("bb_pr: fetch failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
			end)
			return
		end
		local f = io.open(tmp, "wb")
		if not f then
			vim.schedule(function()
				vim.notify("bb_pr: cannot write temp file " .. tmp, vim.log.levels.ERROR)
			end)
			return
		end
		f:write(res.stdout)
		f:close()
		vim.schedule(function()
			vim.fn.jobstart({ "xdg-open", tmp }, { detach = true })
		end)
	end)
end

local function stats_detect_context()
	-- Try current tab PR first (most reliable — already fetched from Bitbucket).
	local pr = get_current_tab_pr()
	if pr then
		local repo_slug, proj_key = pr_repo_context(pr)
		if repo_slug then
			return repo_slug, proj_key or ""
		end
	end

	-- Fall back: parse git remote in the current working directory.
	local remote = vim.trim(vim.fn.system({ "git", "remote", "get-url", "origin" }))
	if remote == "" then
		remote = vim.trim(vim.fn.system({ "git", "remote", "get-url", "upstream" }))
	end
	if remote ~= "" then
		-- strip trailing .git and extract last two path components: .../PROJECT/REPO
		remote = remote:gsub("%.git$", "")
		local proj, repo = remote:match("/([^/]+)/([^/]+)$")
		-- Bitbucket SSH URLs have /scm/PROJECT/REPO — skip "scm" level
		if proj and proj:lower() == "scm" then
			proj, repo = remote:match("/scm/([^/]+)/([^/]+)$")
		end
		if repo and repo ~= "" then
			return repo, proj and proj:upper() or ""
		end
	end

	return "", ""
end

function M.show_stats(opts)
	opts = opts or {}
	local cfg = M.config.stats
	local repos = opts.repos or cfg.repos
	local project = opts.project or cfg.project
	local since_days = opts.since_days or cfg.since_days
	local concurrency = opts.concurrency or cfg.concurrency
	local top = opts.top or cfg.top
	local ignore_users = opts.ignore_users or cfg.ignore_users

	-- Auto-detect repo/project from current context when not explicitly configured.
	if repos == "" or project == "" then
		local detected_repo, detected_proj = stats_detect_context()
		if repos == "" then
			repos = detected_repo
		end
		if project == "" then
			project = detected_proj
		end
	end

	if repos == "" then
		vim.ui.input({ prompt = "Repos (comma-separated slugs): " }, function(input)
			if input and vim.trim(input) ~= "" then
				opts.repos = vim.trim(input)
				M.show_stats(opts)
			end
		end)
		return
	end

	if not opts._period_selected then
		local default_days = tostring(cfg.since_days)
		local period_choices = { "7", "14", "30", "60", "90", "180", "365", "0" }
		-- Move the configured default to the top so pickers pre-select it.
		for i, choice in ipairs(period_choices) do
			if choice == default_days then
				table.insert(period_choices, 1, table.remove(period_choices, i))
				break
			end
		end
		vim.ui.select(period_choices, {
			prompt = "Period:",
			format_item = function(item)
				local n = tonumber(item)
				local label
				if not n or n == 0 then
					label = "All time"
				else
					label = string.format("Last %d days", n)
				end
				if item == default_days then
					label = label .. " (default)"
				end
				return label
			end,
		}, function(choice)
			if not choice then
				return
			end
			opts.since_days = tonumber(choice) or 0
			opts.repos = repos
			opts.project = project
			opts._period_selected = true
			M.show_stats(opts)
		end)
		return
	end

	local cmd = { "bb", "stats", "-repos", repos }
	if project ~= "" then
		vim.list_extend(cmd, { "-project", project })
	end
	vim.list_extend(cmd, { "-since-days", tostring(since_days) })
	vim.list_extend(cmd, { "-concurrency", tostring(concurrency) })
	vim.list_extend(cmd, { "-top", tostring(top) })
	if ignore_users ~= "" then
		vim.list_extend(cmd, { "-ignore-users", ignore_users })
	end

	local buf = create_scratch_buf()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		"",
		"  Fetching PR stats…",
		"",
		string.format("  repos:   %s", repos),
		string.format("  period:  last %d days", since_days),
		string.format("  cmd:     %s", table.concat(cmd, " ")),
	})

	open_centered_float(buf, {
		width = math.min(vim.o.columns - 4, 120),
		height = math.min(vim.o.lines - 4, 50),
		title = " BB PR Stats ",
	})
	bind_keymaps(buf, { { "q", "<cmd>close<CR>" }, { "<Esc>", "<cmd>close<CR>" } })

	vim.system(cmd, { text = true }, function(res)
		vim.schedule(function()
			if not vim.api.nvim_buf_is_valid(buf) then
				return
			end
			vim.bo[buf].modifiable = true

			if res.code ~= 0 then
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
					"",
					"  Error running bb stats:",
					"",
					"  " .. (res.stderr or "unknown error"),
					"",
					"  Command: " .. table.concat(cmd, " "),
				})
				vim.bo[buf].modifiable = false
				return
			end

			local ok, data = pcall(vim.json.decode, res.stdout)
			if not ok or type(data) ~= "table" then
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
					"",
					"  Failed to parse stats output:",
					"",
					"  " .. tostring(data),
				})
				vim.bo[buf].modifiable = false
				return
			end

			local stats_mod = require("bb_pr.stats")
			local lines, highlights = stats_mod.render(data)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

			local ns = vim.api.nvim_create_namespace("bb_pr_stats")
			for _, h in ipairs(highlights) do
				-- strict = false: a highlight may end past its (multibyte) line
				pcall(vim.api.nvim_buf_set_extmark, buf, ns, h.line, h.col_start, {
					end_col = h.col_end,
					hl_group = h.group,
					strict = false,
				})
			end

			vim.bo[buf].modifiable = false
		end)
	end)
end

open_help_float = function(entries, title)
	-- pad by display width, not byte length: reaction labels contain multibyte emoji
	local key_width = 0
	for _, e in ipairs(entries) do
		key_width = math.max(key_width, vim.fn.strdisplaywidth(e[1]))
	end
	key_width = key_width + 2
	local lines = {}
	local content_width = 0
	for _, e in ipairs(entries) do
		local pad = string.rep(" ", math.max(key_width - vim.fn.strdisplaywidth(e[1]), 0))
		local line = string.format("  %s%s  %s", e[1], pad, e[2])
		content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
		table.insert(lines, line)
	end
	local buf = create_scratch_buf()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	local win = open_centered_float(buf, {
		width = math.max(50, math.min(content_width + 2, math.floor(vim.o.columns * 0.8))),
		height = math.min(#lines + 2, math.floor(vim.o.lines * 0.8)),
		title = " " .. title .. " ",
	})
	local function close()
		pcall(vim.api.nvim_win_close, win, true)
	end
	bind_keymaps(buf, { { "q", close }, { "<Esc>", close }, { "?", close } })
end

set_diff_buffer_keymaps = function(bufnr)
	if vim.b[bufnr].bb_pr_diff_keymaps_set then
		return
	end
	vim.b[bufnr].bb_pr_diff_keymaps_set = true

	local cmaps = M.config.comments
	local buf = bufnr

	-- "g" .. key, nil when the key is unset
	local function g(key)
		return (key and key ~= "") and ("g" .. key) or nil
	end

	bind_keymaps(buf, {
		-- open the comments float, or start a new comment when the line has none
		{
			"gc",
			function()
				local line = vim.api.nvim_win_get_cursor(0)[1]
				local comments = get_buf_line_comments(buf)[line]
				if comments and #comments > 0 then
					open_comment_float(comments, line)
				else
					post_comment_or_task(false, false)
				end
			end,
			desc = "Open PR comments for current line or create one",
			help = "Open line comments / create comment",
		},
		-- diff-only utility keys: used as-is, no g prefix
		{ cmaps.prev_map, function()
			jump_comment(-1)
		end, desc = "Jump to previous PR comment", help = "Previous comment" },
		{ cmaps.next_map, function()
			jump_comment(1)
		end, desc = "Jump to next PR comment", help = "Next comment" },
		-- comment creation keys: the diff buffer prefixes the float key with "g"
		-- (reply/react/delete/edit/resolve/toggle_task/accept_suggestion need the cursor
		-- on a comment line, so they only work in the float / PR Info)
		{ g(cmaps.create_task_map), "<cmd>BBPRCreateTask<CR>", desc = "Create task" },
		{ g(cmaps.create_suggestion_map), "<cmd>BBPRCreateSuggestion<CR>", desc = "Create suggestion" },
		{
			cmaps.refresh_map,
			"<cmd>BBPRRefreshComments<CR>",
			desc = "Force refresh PR comments",
			help = "Refresh comments",
		},
	}, "PR Diff — Keymaps")
end

function M.setup(opts)
	merge_config(opts)
	normalize_reaction_choices()
	load_reaction_recency_state()
	load_drafts()

	vim.api.nvim_set_hl(0, "BbPrResolvedThread", { default = true, underline = true, sp = "Gray" })
	vim.api.nvim_set_hl(0, "BbPrResolvedVirtText", { default = true, link = "Comment" })

	-- commands that just run a function; the wrapper keeps the command opts away from it
	local commands = {
		{ "BBPRList", function()
			M.open_list()
		end, "List active Bitbucket PRs" },
		{ "BBPRLoadComments", function()
			reload_tab_comments(vim.api.nvim_get_current_tabpage())
		end, "Load PR comments and render virtual text in current buffer" },
		{ "BBPRCreateComment", function()
			post_comment_or_task(false, false)
		end, "Create or reply PR comment from cursor context" },
		{ "BBPRCreateTask", function()
			post_comment_or_task(true, false)
		end, "Create or reply PR task from cursor context" },
		{ "BBPRCreateSuggestion", create_suggestion_comment, "Create PR comment with prefilled suggestion block" },
		{ "BBPRAcceptSuggestion", accept_suggestion, "Apply suggestion from comment under cursor to current file" },
		{ "BBPRReplyComment", function()
			post_comment_or_task(false, true)
		end, "Reply to current PR comment" },
		{ "BBPRRefreshComments", function()
			reload_tab_comments(vim.api.nvim_get_current_tabpage())
		end, "Force refresh PR comments from server" },
		{ "BBPRToggleTask", toggle_task_status, "Toggle PR task done/open for comment under cursor" },
		{ "BBPRResolveComment", resolve_comment, "Resolve/unresolve PR comment thread under cursor" },
		{ "BBPRConvertTask", convert_comment_task, "Convert PR comment to task or back under cursor" },
		{ "BBPRReactComment", react_to_comment, "Add reaction to comment under cursor" },
		{ "BBPRReactionUsers", show_reaction_users, "Show who reacted with the reaction under cursor" },
		{ "BBPRDeleteComment", delete_comment, "Delete PR comment under cursor" },
		{ "BBPREditComment", edit_comment, "Edit PR comment under cursor" },
		{ "BBPRCreatePR", create_pr, "Create pull request from current branch" },
		{ "BBPRMerge", merge_current_pr, "Merge pull request opened in current tab" },
		{ "BBPRClose", close_current_pr, "Close open PR tabs and roll back a conflicted merge" },
		{ "BBPRStats", function()
			M.show_stats()
		end, "Show PR statistics in a floating window" },
	}
	for _, command in ipairs(commands) do
		local fn = command[2]
		vim.api.nvim_create_user_command(command[1], function()
			fn()
		end, { desc = command[3] })
	end

	vim.api.nvim_create_user_command("BBPRInfo", function()
		local pr = get_current_tab_pr()
		if not pr then
			vim.notify("bb_pr: no PR tracked for current tab", vim.log.levels.WARN)
			return
		end

		open_pr_info_with_comments(pr)
	end, { desc = "Show info for PR opened in current tab" })

	vim.api.nvim_create_user_command("BBPROpenLineComments", function()
		local bufnr = vim.api.nvim_get_current_buf()
		local line = vim.api.nvim_win_get_cursor(0)[1]
		local comments = get_buf_line_comments(bufnr)[line]
		if not comments or #comments == 0 then
			vim.notify("bb_pr: no comments on current line", vim.log.levels.INFO)
			return
		end
		open_comment_float(comments, line)
	end, { desc = "Open floating window with comments for current line" })

	bind_keymaps(nil, {
		{ M.config.pr.create_map, "<cmd>BBPRCreatePR<CR>", desc = "Create PR" },
		{ M.config.pr.merge_map, "<cmd>BBPRMerge<CR>", desc = "Merge PR" },
		{ M.config.pr.close_map, "<cmd>BBPRClose<CR>", desc = "Close PR" },
		{ M.config.stats.map, "<cmd>BBPRStats<CR>", desc = "BB PR Stats" },
	})

	local aug = vim.api.nvim_create_augroup("bb_pr_comments", { clear = true })
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "CursorMoved", "WinScrolled" }, {
		group = aug,
		callback = function()
			local tabpage = vim.api.nvim_get_current_tabpage()
			local pending_payload = consume_pending_tab_comments()
			if pending_payload then
				apply_comments_when_diffview_ready(tabpage, pending_payload)
				return
			end

			local payload = get_current_tab_comments()
			if payload then
				-- cheap when nothing changed: apply_comments_to_current_buffer and the
				-- panel indicators skip buffers whose render inputs are unchanged
				apply_comments_to_tab(tabpage, payload)
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = aug,
		callback = function(ev)
			state.line_comments_by_buf[ev.buf] = nil
			state.buf_hunks_cache[ev.buf] = nil
			state.rendered_by_buf[ev.buf] = nil
			state.panel_rendered_by_buf[ev.buf] = nil
			state.comment_view_by_buf[ev.buf] = nil
		end,
	})
end

return M
