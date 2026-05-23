local M = {}
local reactions = require("bb_pr.reactions")

local default_config = {
	provider_cmd = { "bb", "-reviewers", "-json" },
	comments_cmd = { "bb", "-json", "-pr-comments" },
	force_repo_autodetect = true,
	force_repo_autodetect_flag = "-force-autodetect-repo",
	diffview_cmd = "DiffviewOpen",
	comment_prev_map = "[C",
	comment_next_map = "]C",
	create_comment_map = "<leader>rC",
	create_task_map = "<leader>rT",
	reply_comment_map = "<leader>rR",
	delete_comment_map = "<leader>rx",
	react_comment_map = "<leader>re",
	create_suggestion_map = "<leader>rs",
	accept_suggestion_map = "<leader>rA",
	reaction_default = "THUMBS_UP",
	reaction_choices = vim.deepcopy(reactions.all_reaction_choices),
	refresh_comments_map = "<leader>rr",
	toggle_task_map = "<leader>rt",
	resolve_comment_map = "<leader>rv",
	pr_info_approve_map = "<leader>ra",
	pr_info_disapprove_map = "<leader>rd",
	pr_info_needs_work_map = "<leader>rn",
	create_pr_map = "<leader>rc",
	create_pr_toggle_draft_map = "<leader>rt",
	create_pr_body_template = "",
	merge_pr_map = "<leader>rm",
	merge_pr_body_template_fn = nil,
	reaction_recency_store_path = vim.fn.stdpath("state") .. "/bb_pr_reaction_recency.json",
}
M.config = vim.deepcopy(default_config)

local state = {
	prs = {},
	pr_by_tab = {},
	comment_ns = vim.api.nvim_create_namespace("bb_pr_comments"),
	comments_by_tab = {},
	pending_comments_by_tab = {},
	reaction_usage_by_key = {},
	reaction_usage_seq = 0,
}

local function tab_key(tabpage)
	return tostring(tabpage)
end

local function set_current_tab_pr(pr, opts)
	opts = opts or {}
	local key = tab_key(vim.api.nvim_get_current_tabpage())
	state.pr_by_tab[key] = pr
	if not opts.preserve_comments then
		state.comments_by_tab[key] = nil
	end
end

local function set_tab_pr(tabpage, pr, opts)
	opts = opts or {}
	local key = tab_key(tabpage)
	state.pr_by_tab[key] = pr
	if not opts.preserve_comments then
		state.comments_by_tab[key] = nil
	end
end

local function get_current_tab_pr()
	return state.pr_by_tab[tab_key(vim.api.nvim_get_current_tabpage())]
end

local function get_tab_pr(tabpage)
	return state.pr_by_tab[tab_key(tabpage)]
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

local function format_pr_entry(pr)
	local approvals = 0
	local has_needs_work = false
	for _, reviewer in ipairs(pr.reviewers or {}) do
		if reviewer.approved or reviewer.status == "APPROVED" then
			approvals = approvals + 1
		end
		local reviewer_status = type(reviewer.status) == "string" and string.upper(reviewer.status) or ""
		if reviewer_status == "NEEDS_WORK" then
			has_needs_work = true
		end
	end
	local needs_work_status = has_needs_work and "NW" or "OK"

	return string.format(
		"appr: %d %s %s • open %s, comm %s • %s - %s",
		approvals,
		needs_work_status,
		format_my_review_marker(pr),
		format_opened_age(pr.createdDate),
		format_opened_age(pr.updatedDate),
		pr.author.user.displayName,
		pr.title or ""
	)
end

local function merge_config(user)
	M.config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), user or {})
end

local function load_reaction_recency_state()
	local path = tostring(M.config.reaction_recency_store_path or "")
	if path == "" then
		return
	end
	local ok_read, lines = pcall(vim.fn.readfile, path)
	if not ok_read or type(lines) ~= "table" or #lines == 0 then
		return
	end
	local ok_json, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
	if not ok_json or type(decoded) ~= "table" then
		return
	end
	state.reaction_usage_by_key = type(decoded.by_key) == "table" and decoded.by_key or {}
	state.reaction_usage_seq = tonumber(decoded.seq or 0) or 0
end

local function persist_reaction_recency_state()
	local path = tostring(M.config.reaction_recency_store_path or "")
	if path == "" then
		return
	end
	local dir = vim.fn.fnamemodify(path, ":h")
	pcall(vim.fn.mkdir, dir, "p")
	local payload = vim.json.encode({
		seq = tonumber(state.reaction_usage_seq or 0) or 0,
		by_key = state.reaction_usage_by_key or {},
	})
	pcall(vim.fn.writefile, { payload }, path)
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

local function run_provider(cb)
	vim.system(with_repo_autodetect_flag(M.config.provider_cmd), { text = true }, function(res)
		if res.code ~= 0 then
			vim.schedule(function()
				vim.notify("bb_pr: provider failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
			end)
			return
		end

		local ok, decoded = pcall(vim.json.decode, res.stdout)
		if not ok or type(decoded) ~= "table" then
			vim.schedule(function()
				vim.notify("bb_pr: invalid JSON provider output", vim.log.levels.ERROR)
			end)
			return
		end

		cb(decoded)
	end)
end

local function refresh_current_pr(cb, tabpage)
	local current = tabpage and get_tab_pr(tabpage) or get_current_tab_pr()
	if type(current) ~= "table" then
		cb(nil)
		return
	end
	local current_id = tonumber(current.id or 0) or 0
	if current_id <= 0 then
		cb(nil)
		return
	end

	run_provider(function(decoded)
		local found = nil
		for _, pr in ipairs(decoded) do
			if tonumber(pr.id or 0) == current_id then
				found = pr
				break
			end
		end
		cb(found)
	end)
end

local apply_comments_to_current_buffer
local apply_comments_to_tab_windows
local apply_pr_info_content
local find_comment_by_id

local function run_comments_provider(pr_id, cb, opts)
	opts = opts or {}
	local cmd = vim.deepcopy(M.config.comments_cmd)
	cmd = with_repo_autodetect_flag(cmd)
	table.insert(cmd, tostring(pr_id))

	vim.system(cmd, { text = true }, function(res)
		if res.code ~= 0 then
			if opts.notify_errors ~= false then
				vim.schedule(function()
					vim.notify("bb_pr: comments provider failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
				end)
			end
			return
		end

		local ok, decoded = pcall(vim.json.decode, res.stdout)
		if not ok or type(decoded) ~= "table" then
			if opts.notify_errors ~= false then
				vim.schedule(function()
					vim.notify("bb_pr: invalid PR comments JSON", vim.log.levels.ERROR)
				end)
			end
			return
		end

		cb(decoded)
	end)
end

local function set_tab_comments(tabpage, payload)
	local key = tab_key(tabpage)
	state.comments_by_tab[key] = payload
	state.pending_comments_by_tab[key] = payload
end

local function set_current_tab_comments(payload)
	set_tab_comments(vim.api.nvim_get_current_tabpage(), payload)
end

local function get_current_tab_comments()
	return state.comments_by_tab[tab_key(vim.api.nvim_get_current_tabpage())]
end

local function consume_pending_tab_comments()
	local key = tab_key(vim.api.nvim_get_current_tabpage())
	local payload = state.pending_comments_by_tab[key]
	state.pending_comments_by_tab[key] = nil
	return payload
end

local function split_first_line(text)
	if type(text) ~= "string" or text == "" then
		return "(empty)"
	end
	return (vim.split(text, "\n", { plain = true })[1] or ""):gsub("%s+", " ")
end

local function task_checkbox_prefix(c)
	if type(c) ~= "table" then
		return nil
	end
	if c.is_task then
		local status = type(c.task_status) == "string" and string.upper(c.task_status) or "OPEN"
		if status == "DONE" or status == "RESOLVED" then
			return "- [x] "
		end
		return "- [ ] "
	end
	if c.is_resolved then
		return "- [~] "
	end
	return nil
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
	local primary = normalize_repo_path(extract_repo_relative_path(name))
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

local function resolve_apply_target_bufnr(target_path)
	local cur = vim.api.nvim_get_current_buf()
	local source = vim.b[cur].bb_pr_float_source_bufnr
	if type(source) == "number" and source > 0 and vim.api.nvim_buf_is_valid(source) then
		local source_name = vim.api.nvim_buf_get_name(source)
		if not tostring(source_name):match("^diffview://") then
			local source_path = current_buffer_repo_path(source)
			if target_path == "" or path_matches(source_path, target_path) then
				return source
			end
		end
	end

	if vim.api.nvim_buf_is_valid(cur) then
		local cur_name = vim.api.nvim_buf_get_name(cur)
		if not tostring(cur_name):match("^diffview://") then
			local cur_path = current_buffer_repo_path(cur)
			if target_path == "" or path_matches(cur_path, target_path) then
				return cur
			end
		end
	end

	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(b) and vim.bo[b].buftype == "" then
			local name = vim.api.nvim_buf_get_name(b)
			if name ~= "" and not tostring(name):match("^diffview://") then
				local p = current_buffer_repo_path(b)
				if target_path ~= "" and path_matches(p, target_path) then
					return b
				end
			end
		end
	end

	if target_path ~= "" then
		local abs = vim.fn.fnamemodify(target_path, ":p")
		local file_buf = vim.fn.bufadd(abs)
		pcall(vim.fn.bufload, file_buf)
		if type(file_buf) == "number" and file_buf > 0 and vim.api.nvim_buf_is_valid(file_buf) then
			return file_buf
		end
	end

	if type(source) == "number" and source > 0 and vim.api.nvim_buf_is_valid(source) then
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
local function current_diff_side()
	local win = vim.api.nvim_get_current_win()
	if not vim.api.nvim_win_is_valid(win) then
		return "single"
	end
	if not vim.wo[win].diff then
		return "single"
	end

	local tab_wins = vim.api.nvim_tabpage_list_wins(0)
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

local function comment_matches_side(c, side)
	if side == "single" then
		return true
	end

	local file_type = tostring(c.file_type or ""):upper()
	local line_type = tostring(c.line_type or ""):upper()

	if side == "left" then
		if file_type == "FROM" then
			return true
		end
		if line_type == "REMOVED" then
			return true
		end
		return false
	end

	if side == "right" then
		if file_type == "TO" or file_type == "" then
			return true
		end
		if line_type == "ADDED" or line_type == "CONTEXT" then
			return true
		end
		return false
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

	if win then
		vim.schedule(function()
			pcall(vim.api.nvim_win_call, win, function()
				local ok_attach = try_attach()
				if not ok_attach then
					vim.cmd("silent! Markview attach")
				end
			end)
		end)
	else
		local ok_attach = try_attach()
		if not ok_attach then
			vim.cmd("silent! Markview attach")
		end
	end
end

local function set_wrapped_window_options(win)
	vim.api.nvim_set_option_value("wrap", true, { win = win })
	vim.api.nvim_set_option_value("linebreak", true, { win = win })
	vim.api.nvim_set_option_value("breakindent", true, { win = win })
	vim.api.nvim_set_option_value("breakindentopt", "shift:2,sbr", { win = win })
end

local function open_comment_float(comments, line)
	local source_win = vim.api.nvim_get_current_win()
	local source_buf = vim.api.nvim_get_current_buf()
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

	local lines = { string.format("PR comments for line %d", line), "" }
	local comment_ids_by_line = {}
	for idx, c in ipairs(comments) do
		local depth = math.max(tonumber(c.depth or 0) or 0, 0)
		local indent = string.rep("\t", depth)
		if idx > 1 then
			table.insert(lines, indent .. "---")
			table.insert(lines, "")
		end
		local comment_id = tonumber(c.id or 0) or 0
		local reply_to = tonumber(c.parent_id or 0) or 0
		local checkbox = task_checkbox_prefix(c) or "- "
		local header =
			string.format("%s%s%s %s", indent, checkbox, c.author or "unknown", c.created_at or "unknown time")
		if comment_id > 0 then
			header = header .. string.format(" (#%d)", comment_id)
		end
		if reply_to > 0 then
			header = header .. string.format(" ↳ reply to #%d", reply_to)
		end
		table.insert(lines, header)
		if comment_id > 0 then
			comment_ids_by_line[#lines] = comment_id
		end
		local msg_lines = trim_edge_empty_lines(vim.split(c.text or "", "\n", { plain = true }))
		for _, msg_line in ipairs(msg_lines) do
			table.insert(lines, indent .. "\t" .. msg_line)
		end
		local reactions_line = reactions.format_line(c.reactions, c.my_reactions)
		if reactions_line then
			table.insert(lines, "")
			table.insert(lines, indent .. "\t" .. reactions_line)
		end
		table.insert(lines, "")
	end

	if lines[#lines] ~= "" then
		table.insert(lines, "")
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"
	vim.b[buf].bb_pr_float_comment_ids_by_line = comment_ids_by_line
	vim.b[buf].bb_pr_float_source_win = source_win
	vim.b[buf].bb_pr_float_source_bufnr = source_buf
	vim.b[buf].bb_pr_float_source_line = line
	vim.diagnostic.enable(false, { bufnr = buf })

	local base_win = vim.api.nvim_get_current_win()
	local base_width = vim.api.nvim_win_get_width(base_win)
	local base_height = vim.api.nvim_win_get_height(base_win)
	local editor_width = vim.o.columns
	local editor_height = vim.o.lines
	local target_width = math.max(math.floor(base_width * 0.9), math.floor(editor_width * 0.7))
	local target_height = math.max(math.floor(base_height * 0.85), math.floor(editor_height * 0.6))
	local width = math.max(100, target_width)
	local height = math.min(#lines + 2, math.max(16, target_height))
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = "BB PR Comments",
		title_pos = "center",
	})

	set_wrapped_window_options(win)
	enable_markview(buf, win)
	vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf, silent = true })
	return win
end

local function jump_file_comment(direction)
	local bufnr = vim.api.nvim_get_current_buf()
	local by_line = vim.b[bufnr].bb_pr_line_comments
	if type(by_line) ~= "table" then
		by_line = {}
	end
	local current_line = vim.api.nvim_win_get_cursor(0)[1]
	local lines = {}
	for line, comments in pairs(by_line) do
		if type(comments) == "table" and #comments > 0 then
			table.insert(lines, line)
		end
	end

	if #lines == 0 then
		local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, state.comment_ns, 0, -1, { details = true })
		local seen = {}
		for _, mark in ipairs(extmarks) do
			local details = mark[4] or {}
			if details.sign_text ~= "💬" then
				goto continue
			end
			local row = tonumber(mark[2] or -1)
			if row >= 0 then
				local line = row + 1
				if not seen[line] then
					seen[line] = true
					table.insert(lines, line)
				end
			end
			::continue::
		end
	end

	if #lines == 0 then
		vim.notify("bb_pr: no file comments in current buffer", vim.log.levels.INFO)
		return
	end

	table.sort(lines)
	local target = nil

	if direction > 0 then
		for _, line in ipairs(lines) do
			if line > current_line then
				target = line
				break
			end
		end
		target = target or lines[1]
	else
		for i = #lines, 1, -1 do
			local line = lines[i]
			if line < current_line then
				target = line
				break
			end
		end
		target = target or lines[#lines]
	end

	vim.api.nvim_win_set_cursor(0, { target, 0 })
end

local function jump_overview_comment(direction)
	local bufnr = vim.api.nvim_get_current_buf()
	local overview_lines = vim.b[bufnr].bb_pr_overview_comment_lines
	if type(overview_lines) ~= "table" or #overview_lines == 0 then
		overview_lines = {}
		local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		for idx, line in ipairs(all_lines) do
			if type(line) == "string" and line:match("^### Thread %d+") then
				table.insert(overview_lines, idx)
			end
		end
		vim.b[bufnr].bb_pr_overview_comment_lines = overview_lines
	end

	if #overview_lines == 0 then
		vim.notify("bb_pr: no comment threads in current buffer", vim.log.levels.INFO)
		return
	end

	local current_line = vim.api.nvim_win_get_cursor(0)[1]
	local target = nil

	if direction > 0 then
		for _, line in ipairs(overview_lines) do
			if line > current_line then
				target = line
				break
			end
		end
		target = target or overview_lines[1]
	else
		for i = #overview_lines, 1, -1 do
			local line = overview_lines[i]
			if line < current_line then
				target = line
				break
			end
		end
		target = target or overview_lines[#overview_lines]
	end

	vim.api.nvim_win_set_cursor(0, { target, 0 })
end

local function jump_comment(direction)
	local bufnr = vim.api.nvim_get_current_buf()
	if type(vim.b[bufnr].bb_pr_overview_comment_lines) == "table" then
		jump_overview_comment(direction)
		return
	end

	jump_file_comment(direction)
end

apply_comments_to_current_buffer = function(comments_payload)
	local bufnr = vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
		return
	end
	local file = vim.api.nvim_buf_get_name(bufnr)
	local rel = vim.fn.fnamemodify(file, ":.")
	local rel_norm = normalize_repo_path(rel)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local side = current_diff_side()

	vim.api.nvim_buf_clear_namespace(bufnr, state.comment_ns, 0, -1)
	local by_line = {}
	local seen_comment_ids = {}

	for _, c in ipairs(as_array(comments_payload and comments_payload.file_comments)) do
		if path_matches(rel_norm, c.path) and comment_matches_side(c, side) then
			local cid = tonumber(c.id or 0) or 0
			if cid > 0 and seen_comment_ids[cid] then
				goto continue
			end
			local line = tonumber(c.line or 0)
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
			local vt = string.format("💬 %d %s", #line_comments, preview)
			vim.api.nvim_buf_set_extmark(bufnr, state.comment_ns, line - 1, 0, {
				sign_text = "💬",
				sign_hl_group = "DiagnosticSignInfo",
				virt_text = { { vt, "DiagnosticVirtualTextInfo" } },
				virt_text_pos = "eol",
			})
			vim.api.nvim_buf_add_highlight(bufnr, state.comment_ns, "Underlined", line - 1, 0, -1)
		end
	end

	vim.b[bufnr].bb_pr_line_comments = by_line
end

apply_comments_to_tab_windows = function(comments_payload)
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_call, win, function()
				apply_comments_to_current_buffer(comments_payload)
			end)
		end
	end
end

local function apply_comments_to_specific_tab(tabpage, comments_payload)
	if not (tabpage and vim.api.nvim_tabpage_is_valid(tabpage)) then
		return
	end

	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_call(win, function()
				apply_comments_to_current_buffer(comments_payload)
				local bufnr = vim.api.nvim_get_current_buf()
				local info_pr = vim.b[bufnr].bb_pr_info_pr
				if type(info_pr) == "table" then
					apply_pr_info_content(bufnr, info_pr)
				end
			end)
		end
	end
end

local function apply_comments_to_specific_tab_when_ready(tabpage, comments_payload, opts)
	opts = opts or {}
	local retries_left = opts.retries or 20
	local delay_ms = opts.delay_ms or 100

	local function attempt()
		if not (tabpage and vim.api.nvim_tabpage_is_valid(tabpage)) then
			return
		end

		local has_stable_diff_side = false
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
			if vim.api.nvim_win_is_valid(win) and vim.wo[win].diff then
				local side = vim.api.nvim_win_call(win, current_diff_side)
				if side == "left" or side == "right" then
					has_stable_diff_side = true
					break
				end
			end
		end

		if has_stable_diff_side then
			apply_comments_to_specific_tab(tabpage, comments_payload)
			return
		end

		retries_left = retries_left - 1
		if retries_left > 0 then
			vim.defer_fn(attempt, delay_ms)
		end
	end

	attempt()
end

local function apply_comments_when_diffview_ready(comments_payload, opts)
	opts = opts or {}
	local retries_left = opts.retries or 20
	local delay_ms = opts.delay_ms or 100

	local function attempt()
		local has_stable_diff_side = false
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
			if vim.api.nvim_win_is_valid(win) and vim.wo[win].diff then
				local side = vim.api.nvim_win_call(win, current_diff_side)
				if side == "left" or side == "right" then
					has_stable_diff_side = true
					break
				end
			end
		end

		if has_stable_diff_side then
			apply_comments_to_tab_windows(comments_payload)
			return
		end

		retries_left = retries_left - 1
		if retries_left > 0 then
			vim.defer_fn(attempt, delay_ms)
		end
	end

	attempt()
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
				"%-3s %-8s %-20s %-18s %s",
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

local function open_diffview(pr)
	local from_ref = pr.fromRef and pr.fromRef.displayId
	local to_ref = pr.toRef and pr.toRef.displayId
	if not from_ref or not to_ref then
		vim.notify("bb_pr: PR does not contain refs", vim.log.levels.WARN)
		return
	end

	local function open_after_fetch()
		local checkout_cmd = { "git", "checkout", "-B", from_ref, "origin/" .. from_ref }
		vim.system(checkout_cmd, { text = true }, function(co_res)
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
			vim.system(merge_cmd, { text = true }, function(merge_res)
				vim.schedule(function()
					if merge_res.code ~= 0 then
						vim.notify(
							"bb_pr: merge conflict with origin/" .. to_ref .. ": " .. (merge_res.stderr or ""),
							vim.log.levels.ERROR
						)
						return
					end
					vim.cmd(string.format("%s origin/%s", M.config.diffview_cmd, to_ref))
					set_current_tab_pr(pr)
					run_comments_provider(pr.id, function(payload)
						vim.schedule(function()
							set_current_tab_comments(payload)
							apply_comments_when_diffview_ready(payload)
						end)
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

	vim.system({ "git", "diff", "--quiet", "HEAD" }, { text = true }, function(st_res)
		if st_res.code ~= 0 then
			vim.schedule(function()
				vim.notify(
					"bb_pr: working tree has uncommitted changes, cannot checkout " .. from_ref,
					vim.log.levels.WARN
				)
			end)
			return
		end

		vim.system(fetch_cmd, { text = true }, function(fetch_res)
			if fetch_res.code ~= 0 then
				vim.schedule(function()
					vim.notify(
						"bb_pr: failed to fetch PR branches: " .. (fetch_res.stderr or ""),
						vim.log.levels.ERROR
					)
				end)
				return
			end

			-- Match Bitbucket's merge check by trying a temporary merge of target into source.
			local merge_check_cmd = {
				"git",
				"merge-tree",
				"origin/" .. to_ref,
				"origin/" .. from_ref,
			}

			vim.system(merge_check_cmd, { text = true }, function(_)
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
	local lines = {}
	local reviewers = pr.reviewers or {}

	if #reviewers == 0 then
		return { "None" }
	end

	local grouped = {}
	local order = { "APPROVED", "UNAPPROVED", "NEEDS_WORK", "PENDING" }

	local function normalize_status(reviewer)
		if reviewer.approved or reviewer.status == "APPROVED" then
			return "APPROVED"
		end

		local raw = type(reviewer.status) == "string" and string.upper(reviewer.status) or ""
		if raw == "NEEDS_WORK" then
			return "NEEDS_WORK"
		end
		if raw == "UNAPPROVED" then
			return "UNAPPROVED"
		end
		if raw == "" then
			return "PENDING"
		end

		return raw
	end

	for _, reviewer in ipairs(reviewers) do
		local user = reviewer.user or {}
		local name = user.displayName or user.name or user.slug or "unknown"
		local status = "**" .. normalize_status(reviewer) .. "**"
		grouped[status] = grouped[status] or {}
		table.insert(grouped[status], name)
	end

	local emitted = {}
	for _, status in ipairs(order) do
		local names = grouped[status]
		if names and #names > 0 then
			table.sort(names)
			table.insert(lines, string.format("%s: %s", status, table.concat(names, ", ")))
			emitted[status] = true
		end
	end

	local remaining_statuses = {}
	for status, _ in pairs(grouped) do
		if not emitted[status] then
			table.insert(remaining_statuses, status)
		end
	end
	table.sort(remaining_statuses)

	for _, status in ipairs(remaining_statuses) do
		local names = grouped[status]
		table.sort(names)
		table.insert(lines, string.format("%s: %s", status, table.concat(names, ", ")))
	end

	return lines
end

local function build_overview_comment_lines(payload)
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

	local overview_comments = as_array(payload and payload.overview_comments)
	local file_comments = as_array(payload and payload.file_comments)
	local comments = {}
	for _, c in ipairs(overview_comments) do
		c.__scope = "overview"
		table.insert(comments, c)
	end
	for _, c in ipairs(file_comments) do
		c.__scope = "file"
		table.insert(comments, c)
	end
	if #comments == 0 then
		return { "None" }
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
	for idx, c in ipairs(comments) do
		local root = thread_root_key(c, idx)
		if not comments_by_thread[root] then
			comments_by_thread[root] = {}
			table.insert(thread_order, root)
		end
		table.insert(comments_by_thread[root], c)
	end
	local function thread_last_created_at(root)
		local thread_comments = comments_by_thread[root] or {}
		local latest = ""
		for _, c in ipairs(thread_comments) do
			local created_at = tostring(c.created_at or "")
			if created_at > latest then
				latest = created_at
			end
		end
		return latest
	end
	table.sort(thread_order, function(a, b)
		local a_last = thread_last_created_at(a)
		local b_last = thread_last_created_at(b)
		if a_last == b_last then
			return tostring(a) < tostring(b)
		end
		return a_last > b_last
	end)

	local lines = {}
	local comment_line_numbers = {}
	local comment_ids_by_line_order = {}
	local comment_ids_by_relative_line = {}
	local thread_line_numbers = {}
	for thread_idx, root in ipairs(thread_order) do
		local thread_comments = comments_by_thread[root]
		local root_comment = thread_comments[1] or {}
		if thread_idx > 1 then
			table.insert(lines, "")
		end
		table.insert(lines, string.format("### Thread %d", thread_idx))
		table.insert(thread_line_numbers, #lines)
		if root_comment.__scope == "file" then
			local path = root_comment.path or "(unknown file)"
			local line = tonumber(root_comment.line or 0) or 0
			local side = root_comment.file_type or ""
			local line_type = root_comment.line_type or ""
			local loc = line > 0 and string.format(":%d", line) or ""
			table.insert(lines, string.format("_Scope: file • `%s%s` %s %s_", path, loc, side, line_type))
			if root_comment.diff_hunk and root_comment.diff_hunk ~= "" then
				table.insert(lines, "```diff")
				for _, hline in ipairs(vim.split(root_comment.diff_hunk, "\n", { plain = true })) do
					table.insert(lines, hline)
				end
				table.insert(lines, "```")
			end
		else
			table.insert(lines, "_Scope: overview_")
		end
		table.insert(lines, "")

		for comment_idx, c in ipairs(thread_comments) do
			local depth = math.max(tonumber(c.depth or 0) or 0, 0)
			local indent = string.rep("\t", depth)

			if #thread_comments > 1 and comment_idx > 1 then
				table.insert(lines, indent .. "---")
				table.insert(lines, "")
			end

			local author = c.author or "unknown"
			local created_at = c.created_at or "unknown time"
			local comment_id = tonumber(c.id or 0) or 0
			local reply_to = tonumber(c.parent_id or 0) or 0
			local checkbox = task_checkbox_prefix(c) or "- "
			local header = string.format("%s%s%s %s", indent, checkbox, author, created_at)
			if comment_id > 0 then
				header = header .. string.format(" (#%d)", comment_id)
			end
			if reply_to > 0 then
				header = header .. string.format(" ↳ reply to #%d", reply_to)
			end
			table.insert(lines, header)
			table.insert(comment_line_numbers, #lines)
			table.insert(comment_ids_by_line_order, comment_id)
			if comment_id > 0 then
				comment_ids_by_relative_line[#lines] = comment_id
			end

			local msg_lines = trim_edge_empty_lines(vim.split(c.text or "", "\n", { plain = true }))
			if #msg_lines == 0 then
				table.insert(lines, indent .. "\t(empty)")
				if comment_id > 0 then
					comment_ids_by_relative_line[#lines] = comment_id
				end
			else
				for _, msg_line in ipairs(msg_lines) do
					table.insert(lines, indent .. "\t" .. msg_line)
					if comment_id > 0 then
						comment_ids_by_relative_line[#lines] = comment_id
					end
				end
			end
			table.insert(lines, "")
		end
	end

	if lines[#lines] ~= "" then
		table.insert(lines, "")
	end

	return lines, comment_line_numbers, comment_ids_by_line_order, comment_ids_by_relative_line, thread_line_numbers
end

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
	table.insert(info_lines, "## Comments")
	table.insert(info_lines, "")

	local comments_payload = get_current_tab_comments()
	local overview_start_line = #info_lines + 1
	local overview_lines, comment_line_numbers, comment_ids_by_line_order, comment_ids_by_relative_line, thread_line_numbers =
		build_overview_comment_lines(comments_payload)
	vim.list_extend(info_lines, overview_lines)

	return info_lines,
		overview_start_line,
		comment_line_numbers,
		comment_ids_by_line_order,
		comment_ids_by_relative_line,
		thread_line_numbers
end

apply_pr_info_content = function(buf, pr)
	local info_lines, overview_start_line, comment_line_numbers, comment_ids_by_line_order, comment_ids_by_relative_line, thread_line_numbers =
		build_pr_info_content(pr)

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, info_lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })

	vim.b[buf].bb_pr_info_pr = pr

	local new_thread_lines = {}
	for _, line in ipairs(thread_line_numbers or {}) do
		table.insert(new_thread_lines, overview_start_line + line - 1)
	end
	vim.b[buf].bb_pr_overview_comment_lines = new_thread_lines

	local ids_by_line = {}
	for idx, line in ipairs(comment_line_numbers or {}) do
		local abs = overview_start_line + line - 1
		local cid = tonumber((comment_ids_by_line_order or {})[idx] or 0) or 0
		if cid > 0 then
			ids_by_line[abs] = cid
		end
	end
	for rel_line, cid in pairs(comment_ids_by_relative_line or {}) do
		local abs = overview_start_line + rel_line - 1
		ids_by_line[abs] = tonumber(cid) or 0
	end
	vim.b[buf].bb_pr_overview_comment_ids_by_line = ids_by_line

	vim.diagnostic.enable(false, { bufnr = buf })
end

local function open_pr_info(pr)
	local buf = vim.api.nvim_create_buf(false, true)
	apply_pr_info_content(buf, pr)

	local width = math.floor(vim.o.columns * 0.7)
	local height = math.min(vim.api.nvim_buf_line_count(buf) + 2, math.floor(vim.o.lines * 0.7))

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = "PR Info",
		title_pos = "center",
	})

	set_wrapped_window_options(win)
	enable_markview(buf, win)

	vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf, silent = true })

	local function apply_review_action(action)
		local pr_id = tonumber(pr.id or 0) or 0
		if pr_id <= 0 then
			vim.notify("bb_pr: invalid PR id", vim.log.levels.ERROR)
			return
		end

		local cmd = bb_cmd({ "-pr-review", tostring(pr_id), "-review-action", action, "-json" })
		local source_tab = vim.api.nvim_get_current_tabpage()
		vim.system(cmd, { text = true }, function(res)
			if res.code ~= 0 then
				vim.schedule(function()
					vim.notify("bb_pr: review action failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
				end)
				return
			end

			refresh_current_pr(function(fresh_pr)
				vim.schedule(function()
					local updated = fresh_pr or pr
					set_tab_pr(source_tab, updated, { preserve_comments = true })
					apply_pr_info_content(buf, updated)
					local msg = string.format("bb_pr: %s sent for PR #%s", action, tostring(pr_id))
					vim.notify(msg, vim.log.levels.INFO)
				end)
			end, source_tab)
		end)
	end

	if M.config.pr_info_approve_map and M.config.pr_info_approve_map ~= "" then
		vim.keymap.set("n", M.config.pr_info_approve_map, function()
			apply_review_action("approve")
		end, { buffer = buf, silent = true, desc = "Approve PR" })
	end
	if M.config.pr_info_disapprove_map and M.config.pr_info_disapprove_map ~= "" then
		vim.keymap.set("n", M.config.pr_info_disapprove_map, function()
			apply_review_action("disapprove")
		end, { buffer = buf, silent = true, desc = "Disapprove PR" })
	end
	if M.config.pr_info_needs_work_map and M.config.pr_info_needs_work_map ~= "" then
		vim.keymap.set("n", M.config.pr_info_needs_work_map, function()
			apply_review_action("needs-work")
		end, { buffer = buf, silent = true, desc = "Mark PR needs work" })
	end
end

local function open_pr_info_with_comments(pr)
	local payload = get_current_tab_comments()
	if payload then
		open_pr_info(pr)
		return
	end

	run_comments_provider(pr.id, function(fetched)
		vim.schedule(function()
			set_current_tab_comments(fetched)
			open_pr_info(pr)
		end)
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

function M.open_list()
	run_provider(function(prs)
		local sorted_prs = prs or {}
		state.prs = sorted_prs

		vim.schedule(function()
			if open_telescope_picker(sorted_prs) then
				return
			end

			local buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_name(buf, "bb_pr://pull_requests")
			vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
			vim.api.nvim_set_option_value("filetype", "bb_pr", { buf = buf })
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, build_lines(sorted_prs))

			vim.keymap.set("n", "<CR>", function()
				local line = vim.api.nvim_win_get_cursor(0)[1]
				local idx = line - 2
				local pr = state.prs[idx]
				if pr then
					open_diffview(pr)
				end
			end, { buffer = buf, silent = true })

			vim.keymap.set("n", "i", function()
				local line = vim.api.nvim_win_get_cursor(0)[1]
				local idx = line - 2
				local pr = state.prs[idx]
				if pr then
					open_pr_info_with_comments(pr)
				end
			end, { buffer = buf, silent = true })

			vim.api.nvim_set_current_buf(buf)
		end)
	end)
end

local function detect_line_type_for_cursor(side, line)
	local ok, diff_hl = pcall(vim.fn.diff_hlID, line, 1)
	if not ok then
		return nil
	end
	local hl_id = tonumber(diff_hl or 0) or 0
	if hl_id == 0 then
		return "CONTEXT"
	end
	local hl_name = vim.fn.synIDattr(hl_id, "name")
	hl_name = type(hl_name) == "string" and hl_name or ""
	if hl_name:find("DiffDelete", 1, true) then
		return "REMOVED"
	end
	if hl_name:find("DiffAdd", 1, true) then
		return "ADDED"
	end
	if hl_name:find("DiffChange", 1, true) or hl_name:find("DiffText", 1, true) then
		return "CONTEXT"
	end

	if side == "left" then
		return "REMOVED"
	end
	if side == "right" then
		return "ADDED"
	end
	return "CONTEXT"
end
local function resolve_comment_context(mode)
	local bufnr = vim.api.nvim_get_current_buf()
	local line = vim.api.nvim_win_get_cursor(0)[1]
	if mode == "reply" then
		return nil
	end

	if vim.bo[bufnr].filetype == "markdown" and type(vim.b[bufnr].bb_pr_overview_comment_lines) == "table" then
		return { mode = "new_overview" }
	end

	local rel = extract_repo_relative_path(vim.api.nvim_buf_get_name(bufnr))
	local side = current_diff_side()
	local file_type = side == "left" and "FROM" or "TO"
	local line_type = detect_line_type_for_cursor(side, line) or "CONTEXT"
	return {
		mode = "new_file",
		path = rel,
		line = line,
		line_type = line_type,
		file_type = file_type,
	}
end

local function open_multiline_comment_input(opts, on_submit)
	opts = opts or {}
	local title = opts.title or "Comment"
	local prompt = opts.prompt or "Write text. <C-s> submit, q cancel"

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "markdown"
	vim.diagnostic.enable(false, { bufnr = buf })
	local initial_lines = { "", "", "", "" }
	if type(opts.initial_text) == "string" and opts.initial_text ~= "" then
		initial_lines = vim.split(opts.initial_text, "\n", { plain = true })
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)

	local width = math.max(80, math.floor(vim.o.columns * 0.7))
	local height = math.max(12, math.floor(vim.o.lines * 0.35))
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = title,
		title_pos = "center",
	})
	vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "<!-- " .. prompt .. " -->", "" })
	vim.api.nvim_win_set_cursor(win, { 3, 0 })

	local function submit()
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		if #lines >= 2 and lines[1]:match("^%<%!%-%-") then
			lines = vim.list_slice(lines, 3)
		end
		local text = table.concat(lines, "\n")
		text = vim.trim(text)
		pcall(vim.api.nvim_win_close, win, true)
		if text ~= "" then
			on_submit(text)
		end
	end

	vim.keymap.set("n", "q", function()
		pcall(vim.api.nvim_win_close, win, true)
	end, { buffer = buf, silent = true })
	vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf, silent = true })
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

	local remote_ref = "refs/remotes/origin/" .. branch
	local remote_check = vim.fn.system({ "git", "rev-parse", "--verify", remote_ref })
	if vim.v.shell_error ~= 0 then
		return false, "bb_pr: branch does not exist in origin: " .. branch
	end

	local local_sha = vim.trim(vim.fn.system({ "git", "rev-parse", "HEAD" }) or "")
	if vim.v.shell_error ~= 0 or local_sha == "" then
		return false, "bb_pr: failed to resolve local HEAD"
	end

	local remote_sha = vim.trim(vim.fn.system({ "git", "rev-parse", remote_ref }) or "")
	if vim.v.shell_error ~= 0 or remote_sha == "" then
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
		local template = M.config.create_pr_body_template
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

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "markdown"
	vim.diagnostic.enable(false, { bufnr = buf })
	local default_title = string.format("%s -> %s", source_branch, target_branch)
	local initial_lines = {
		"Title: " .. default_title,
		"",
		"Body:",
	}
	vim.list_extend(initial_lines, resolve_pr_body_template_lines())
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)

	local width = math.max(90, math.floor(vim.o.columns * 0.7))
	local height = math.max(14, math.floor(vim.o.lines * 0.4))
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = "Create PR (<C-s> submit)",
		title_pos = "center",
	})

	local function submit()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local title = vim.trim((lines[1] or ""):gsub("^Title:%s*", "", 1))
		local body_lines = {}
		for i = 4, #lines do
			table.insert(body_lines, lines[i])
		end
		local body = vim.trim(table.concat(body_lines, "\n"))
		if title == "" then
			vim.notify("bb_pr: PR title is required", vim.log.levels.WARN)
			return
		end
		pcall(vim.api.nvim_win_close, win, true)
		local cmd = bb_cmd({
			"-json",
			"-pr-create",
			"-pr-title",
			title,
			"-pr-body",
			body,
			"-pr-source",
			source_branch,
			"-pr-target",
			target_branch,
		})
		vim.system(cmd, { text = true }, function(res)
			if res.code ~= 0 then
				vim.schedule(function()
					vim.notify("bb_pr: create PR failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
				end)
				return
			end
			vim.schedule(function()
				vim.notify("bb_pr: pull request created", vim.log.levels.INFO)
			end)
		end)
	end

	local function toggle_draft()
		local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "Title: "
		local prefix = "Title: "
		local raw = line:gsub("^Title:%s*", "", 1)
		vim.api.nvim_buf_set_lines(buf, 0, 1, false, { prefix .. toggle_draft_in_title_line(raw) })
	end

	vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf, silent = true })
	vim.keymap.set("n", "<CR>", submit, { buffer = buf, silent = true })
	vim.keymap.set("n", "q", function()
		pcall(vim.api.nvim_win_close, win, true)
	end, { buffer = buf, silent = true })
	if M.config.create_pr_toggle_draft_map and M.config.create_pr_toggle_draft_map ~= "" then
		vim.keymap.set(
			"n",
			M.config.create_pr_toggle_draft_map,
			toggle_draft,
			{ buffer = buf, silent = true, desc = "Toggle [DRAFT]" }
		)
	end
	vim.cmd("startinsert")
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
	vim.system(bb_cmd({ "-json", "-target-branches" }), { text = true }, function(res)
		if res.code ~= 0 then
			vim.schedule(function()
				vim.notify("bb_pr: failed to load target branches: " .. (res.stderr or ""), vim.log.levels.ERROR)
			end)
			return
		end
		local ok, decoded = pcall(vim.json.decode, res.stdout)
		if not ok or type(decoded) ~= "table" then
			vim.schedule(function()
				vim.notify("bb_pr: invalid target branches JSON", vim.log.levels.ERROR)
			end)
			return
		end
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
		vim.schedule(function()
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
	end)
end

local function get_last_commit_title(commits)
	if type(commits) ~= "table" or #commits == 0 then
		return ""
	end
	local msg = tostring((commits[1] or {}).message or "")
	return vim.split(msg, "\n", { plain = true })[1] or ""
end

local function merge_current_pr()
	local pr = get_current_tab_pr()
	if not pr or not pr.id then
		vim.notify("bb_pr: no PR tracked for current tab", vim.log.levels.WARN)
		return
	end
	vim.system(bb_cmd({ "-json", "-pr-commits", tostring(pr.id) }), { text = true }, function(commits_res)
		if commits_res.code ~= 0 then
			vim.schedule(function()
				vim.notify("bb_pr: failed to load PR commits: " .. (commits_res.stderr or ""), vim.log.levels.ERROR)
			end)
			return
		end
		local ok, commits = pcall(vim.json.decode, commits_res.stdout)
		if not ok or type(commits) ~= "table" then
			vim.schedule(function()
				vim.notify("bb_pr: invalid PR commits JSON", vim.log.levels.ERROR)
			end)
			return
		end
		local title = get_last_commit_title(commits)
		if title == "" then
			title = tostring(pr.title or "")
		end
		local body_lines = { "" }
		if type(M.config.merge_pr_body_template_fn) == "function" then
			local ok_tpl, tpl = pcall(M.config.merge_pr_body_template_fn, commits)
			if ok_tpl then
				if type(tpl) == "string" then
					body_lines = vim.split(tpl, "\n", { plain = true })
				elseif type(tpl) == "table" then
					body_lines = tpl
				end
			end
		end
		vim.schedule(function()
			local initial_text = title
			if type(body_lines) == "table" and #body_lines > 0 then
				initial_text = table.concat(vim.list_extend({ title, "" }, body_lines), "\n")
			end
			open_multiline_comment_input({
				title = "Merge PR #" .. tostring(pr.id),
				prompt = "Line 1: merge commit title. Next lines: commit body. <C-s> submit, q cancel",
				initial_text = initial_text,
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
				local cmd = bb_cmd({ "-json", "-pr-merge", tostring(pr.id), "-merge-title", title, "-merge-body", body })
				vim.system(cmd, { text = true }, function(res)
					if res.code ~= 0 then
						vim.schedule(function()
							vim.notify("bb_pr: merge failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
						end)
						return
					end
					vim.schedule(function()
						vim.notify("bb_pr: pull request merged", vim.log.levels.INFO)
					end)
				end)
			end)
		end)
	end)
end

local function resolve_reply_target_comment_id()
	local bufnr = vim.api.nvim_get_current_buf()
	local line = vim.api.nvim_win_get_cursor(0)[1]

	local float_ids = vim.b[bufnr].bb_pr_float_comment_ids_by_line
	if type(float_ids) == "table" then
		local cid = tonumber(float_ids[line] or 0) or 0
		if cid > 0 then
			return cid
		end
	end

	local overview_ids = vim.b[bufnr].bb_pr_overview_comment_ids_by_line
	if type(overview_ids) == "table" then
		local cid = tonumber(overview_ids[line] or 0) or 0
		if cid > 0 then
			return cid
		end
	end

	return nil
end

local function refresh_float_window_if_needed(win, buf)
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

	if vim.api.nvim_win_is_valid(win) then
		pcall(vim.api.nvim_win_close, win, true)
	end
	local reopened_win = nil
	vim.api.nvim_win_call(source_win, function()
		local by_line = vim.b[source_bufnr].bb_pr_line_comments or {}
		local updated_comments = by_line[source_line]
		if updated_comments and #updated_comments > 0 then
			reopened_win = open_comment_float(updated_comments, source_line)
		end
	end)
	if was_current and reopened_win and vim.api.nvim_win_is_valid(reopened_win) then
		pcall(vim.api.nvim_set_current_win, reopened_win)
	end
end

local function toggle_task_status()
	local pr = get_current_tab_pr()
	if not pr or not pr.id then
		vim.notify("bb_pr: no PR tracked for current tab", vim.log.levels.WARN)
		return
	end
	local cid = resolve_reply_target_comment_id()
	if not cid then
		vim.notify("bb_pr: move cursor to a task line in BBPROpenLineComments or PR Info", vim.log.levels.WARN)
		return
	end

	local payload = get_current_tab_comments() or {}
	local all_comments = {}
	for _, c in ipairs(as_array(payload.overview_comments)) do
		all_comments[tonumber(c.id or 0) or 0] = c
	end
	for _, c in ipairs(as_array(payload.file_comments)) do
		all_comments[tonumber(c.id or 0) or 0] = c
	end
	local target = all_comments[cid]
	if type(target) ~= "table" or not target.is_task then
		vim.notify("bb_pr: selected comment is not a task", vim.log.levels.WARN)
		return
	end
	local status = type(target.task_status) == "string" and string.upper(target.task_status) or "OPEN"
	local next_state = (status == "DONE" or status == "RESOLVED") and "open" or "done"
	local version = tonumber(target.version or 0) or 0
	local cmd = bb_cmd({
		"-json",
		"-pr-task-status",
		tostring(pr.id),
		"-task-id",
		tostring(cid),
		"-task-state",
		next_state,
		"-task-version",
		tostring(version),
	})
	vim.system(cmd, { text = true }, function(res)
		if res.code ~= 0 then
			vim.schedule(function()
				vim.notify("bb_pr: toggle task failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
			end)
			return
		end
		vim.schedule(function()
			vim.notify("bb_pr: task marked " .. next_state, vim.log.levels.INFO)
			vim.cmd("BBPRLoadComments")
		end)
	end)
end

local function resolve_comment()
	local pr = get_current_tab_pr()
	if not pr or not pr.id then
		vim.notify("bb_pr: no PR tracked for current tab", vim.log.levels.WARN)
		return
	end
	local cid = resolve_reply_target_comment_id()
	if not cid then
		vim.notify("bb_pr: move cursor to a comment line in BBPROpenLineComments or PR Info", vim.log.levels.WARN)
		return
	end

	local payload = get_current_tab_comments() or {}
	local all_comments = {}
	for _, c in ipairs(as_array(payload.overview_comments)) do
		all_comments[tonumber(c.id or 0) or 0] = c
	end
	for _, c in ipairs(as_array(payload.file_comments)) do
		all_comments[tonumber(c.id or 0) or 0] = c
	end
	local target = all_comments[cid]
	if type(target) ~= "table" then
		vim.notify("bb_pr: could not find selected comment in loaded payload", vim.log.levels.WARN)
		return
	end
	local version = tonumber(target.version or 0) or 0
	local action = target.is_resolved and "unresolve" or "resolve"
	local cmd = bb_cmd({
		"-json",
		"-pr-resolve-comment",
		tostring(pr.id),
		"-resolve-comment-id",
		tostring(cid),
		"-resolve-comment-version",
		tostring(version),
		"-resolve-action",
		action,
	})
	vim.system(cmd, { text = true }, function(res)
		if res.code ~= 0 then
			vim.schedule(function()
				vim.notify("bb_pr: resolve comment failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
			end)
			return
		end
		vim.schedule(function()
			local verb = action == "resolve" and "resolved" or "unresolved"
			vim.notify("bb_pr: comment thread " .. verb, vim.log.levels.INFO)
			vim.cmd("BBPRLoadComments")
		end)
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
	if type(text) ~= "string" or text == "" then
		return nil
	end
	local block = text:match("```suggestion%s*\n(.-)\n```")
	if type(block) ~= "string" then
		return nil
	end
	return block
end

local function accept_suggestion()
	local cid = resolve_reply_target_comment_id()
	if not cid then
		vim.notify("bb_pr: move cursor to a comment line in BBPROpenLineComments or PR Info", vim.log.levels.WARN)
		return
	end
	local comment = find_comment_by_id(cid)
	if type(comment) ~= "table" then
		vim.notify("bb_pr: could not find selected comment in loaded payload", vim.log.levels.WARN)
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
	local buf = resolve_apply_target_bufnr(target_path)
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
	local replacement_lines = vim.split(replacement, "\n", { plain = true })
	local ok_apply, apply_err = apply_suggestion_lines(buf, line, replacement_lines)
	if not ok_apply then
		vim.notify("bb_pr: failed to apply suggestion: " .. tostring(apply_err or ""), vim.log.levels.ERROR)
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

local function react_to_comment()
	local pr = get_current_tab_pr()
	if not pr or not pr.id then
		vim.notify("bb_pr: no PR tracked for current tab", vim.log.levels.WARN)
		return
	end
	local cid = resolve_reply_target_comment_id()
	if not cid then
		vim.notify("bb_pr: move cursor to a comment line in BBPROpenLineComments or PR Info", vim.log.levels.WARN)
		return
	end
	local choices = as_array(M.config.reaction_choices)
	local normalized = {}
	for _, item in ipairs(choices) do
		local v = tostring(item or ""):gsub("^%s+", ""):gsub("%s+$", "")
		if v ~= "" then
			table.insert(normalized, string.upper(v))
		end
	end
	if #normalized == 0 then
		normalized = { string.upper(tostring(M.config.reaction_default or "THUMBS_UP")) }
	end
	sort_reactions_by_recent_use(normalized)
	vim.ui.select(normalized, {
		prompt = "Pick reaction",
		format_item = function(item)
			return reactions.render_choice(item)
		end,
	}, function(choice)
		if not choice or choice == "" then
			return
		end
		local payload = get_current_tab_comments() or {}
		local existing = nil
		for _, c in ipairs(as_array(payload.overview_comments)) do
			if tonumber(c.id or 0) == cid then
				existing = c
				break
			end
		end
		if not existing then
			for _, c in ipairs(as_array(payload.file_comments)) do
				if tonumber(c.id or 0) == cid then
					existing = c
					break
				end
			end
		end
		local action = "add"
		if type(existing) == "table" and type(existing.my_reactions) == "table" and existing.my_reactions[choice] then
			action = "remove"
		end
		local cmd = bb_cmd({
			"-json",
			"-pr-reaction",
			tostring(pr.id),
			"-comment-id",
			tostring(cid),
			"-reaction",
			choice,
			"-reaction-action",
			action,
		})
		vim.system(cmd, { text = true }, function(res)
			if res.code ~= 0 then
				vim.schedule(function()
					vim.notify("bb_pr: add reaction failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
				end)
				return
			end
			vim.schedule(function()
				state.reaction_usage_seq = (tonumber(state.reaction_usage_seq or 0) or 0) + 1
				state.reaction_usage_by_key[choice] = state.reaction_usage_seq
				persist_reaction_recency_state()
				vim.notify("bb_pr: reaction " .. (action == "remove" and "removed" or "added"), vim.log.levels.INFO)
				vim.cmd("BBPRLoadComments")
			end)
		end)
	end)
end

local function delete_comment()
	local pr = get_current_tab_pr()
	if not pr or not pr.id then
		vim.notify("bb_pr: no PR tracked for current tab", vim.log.levels.WARN)
		return
	end
	local cid = resolve_reply_target_comment_id()
	if not cid then
		vim.notify("bb_pr: move cursor to a comment line in BBPROpenLineComments or PR Info", vim.log.levels.WARN)
		return
	end
	local target = find_comment_by_id(cid)
	if type(target) ~= "table" then
		vim.notify("bb_pr: could not find selected comment in loaded payload", vim.log.levels.WARN)
		return
	end
	local version = tonumber(target.version or -1) or -1
	if version < 0 then
		vim.notify("bb_pr: selected comment has invalid version for delete", vim.log.levels.WARN)
		return
	end
	local cmd = bb_cmd({
		"-json",
		"-pr-delete-comment",
		tostring(pr.id),
		"-delete-comment-id",
		tostring(cid),
		"-delete-comment-version",
		tostring(version),
	})
	vim.system(cmd, { text = true }, function(res)
		if res.code ~= 0 then
			vim.schedule(function()
				vim.notify("bb_pr: delete comment failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
			end)
			return
		end
		vim.schedule(function()
			vim.notify("bb_pr: comment deleted", vim.log.levels.INFO)
			vim.cmd("BBPRLoadComments")
		end)
	end)
end

local function post_comment_or_task(is_task, force_reply, opts)
	opts = opts or {}
	local pr = get_current_tab_pr()
	if not pr or not pr.id then
		vim.notify("bb_pr: no PR tracked for current tab", vim.log.levels.WARN)
		return
	end
	local ctx = resolve_comment_context(force_reply and "reply" or "auto")
	if not ctx and not force_reply then
		vim.notify("bb_pr: cannot resolve comment context", vim.log.levels.WARN)
		return
	end

	local function send_comment(reply_to)
		local source_tab = vim.api.nvim_get_current_tabpage()
		local comment_win = vim.api.nvim_get_current_win()
		local comment_bufnr = vim.api.nvim_get_current_buf()
		local suggestion_line = ""
		if ctx and ctx.mode == "new_file" and type(ctx.line) == "number" and ctx.line > 0 then
			local current_line = vim.api.nvim_buf_get_lines(comment_bufnr, ctx.line - 1, ctx.line, false)[1]
			if type(current_line) == "string" then
				suggestion_line = current_line
			end
		end
		open_multiline_comment_input({
			title = is_task and "BB PR Task" or "BB PR Comment",
			prompt = "Write multiline text. <C-s> submit, q cancel",
			initial_text = opts.initial_text,
		}, function(text)
			local cmd = bb_cmd({ "-json", "-pr-comment", tostring(pr.id), "-text", text })
			if is_task then
				table.insert(cmd, "-task")
			end
			if reply_to and reply_to > 0 then
				table.insert(cmd, "-reply-to")
				table.insert(cmd, tostring(reply_to))
			elseif ctx.mode == "new_file" then
				table.insert(cmd, "-path")
				table.insert(cmd, tostring(ctx.path or ""))
				table.insert(cmd, "-line")
				table.insert(cmd, tostring(ctx.line or 0))
				table.insert(cmd, "-line-type")
				table.insert(cmd, tostring(ctx.line_type or "CONTEXT"))
				table.insert(cmd, "-file-type")
				table.insert(cmd, tostring(ctx.file_type or "TO"))
			end
			vim.system(cmd, { text = true }, function(res)
				if res.code ~= 0 then
					vim.schedule(function()
						vim.notify("bb_pr: create comment failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
					end)
					return
				end
				vim.schedule(function()
					vim.notify("bb_pr: comment sent", vim.log.levels.INFO)
					run_comments_provider(pr.id, function(payload)
						vim.schedule(function()
							set_tab_comments(source_tab, payload)
							apply_comments_to_specific_tab_when_ready(source_tab, payload)
							refresh_float_window_if_needed(comment_win, comment_bufnr)
						end)
					end, { notify_errors = false })
				end)
			end)
		end)
	end

	if force_reply then
		local cid = resolve_reply_target_comment_id()
		if not cid then
			vim.notify("bb_pr: move cursor to a comment line in BBPROpenLineComments or PR Info", vim.log.levels.WARN)
			return
		end
		send_comment(cid)
		return
	end

	send_comment(nil)
end

local function suggestion_prefill_for_context(ctx, suggestion_line)
	if ctx and ctx.mode == "new_file" and suggestion_line ~= "" then
		return string.format("```suggestion\n%s\n```", suggestion_line)
	end
	return "```suggestion\n\n```"
end

local function create_suggestion_comment()
	local ctx = resolve_comment_context("auto")
	if not ctx then
		vim.notify("bb_pr: cannot resolve comment context", vim.log.levels.WARN)
		return
	end

	local suggestion_line = ""
	if ctx.mode == "new_file" and type(ctx.line) == "number" and ctx.line > 0 then
		local bufnr = vim.api.nvim_get_current_buf()
		local line = vim.api.nvim_buf_get_lines(bufnr, ctx.line - 1, ctx.line, false)[1]
		if type(line) == "string" then
			suggestion_line = line
		end
	end

	local target_comment_id = resolve_reply_target_comment_id()
	if target_comment_id then
		post_comment_or_task(false, true, {
			initial_text = suggestion_prefill_for_context(ctx, suggestion_line),
		})
		return
	end

	post_comment_or_task(false, false, {
		initial_text = suggestion_prefill_for_context(ctx, suggestion_line),
	})
end

function M.setup(opts)
	merge_config(opts)
	load_reaction_recency_state()

	vim.api.nvim_create_user_command("BBPRList", function()
		M.open_list()
	end, { desc = "List active Bitbucket PRs" })

	vim.api.nvim_create_user_command("BBPRInfo", function()
		local pr = get_current_tab_pr()
		if not pr then
			vim.notify("bb_pr: no PR tracked for current tab", vim.log.levels.WARN)
			return
		end

		open_pr_info_with_comments(pr)
	end, { desc = "Show info for PR opened in current tab" })

	vim.api.nvim_create_user_command("BBPRLoadComments", function()
		local pr = get_current_tab_pr()
		if not pr or not pr.id then
			vim.notify("bb_pr: no PR tracked for current tab", vim.log.levels.WARN)
			return
		end

		run_comments_provider(pr.id, function(payload)
			vim.schedule(function()
				set_current_tab_comments(payload)
				apply_comments_when_diffview_ready(payload)
				local cur_win = vim.api.nvim_get_current_win()
				local cur_buf = vim.api.nvim_get_current_buf()
				vim.defer_fn(function()
					refresh_float_window_if_needed(cur_win, cur_buf)
				end, 150)
				local bufnr = vim.api.nvim_get_current_buf()
				local info_pr = vim.b[bufnr].bb_pr_info_pr
				if type(info_pr) == "table" and tonumber(info_pr.id or 0) == tonumber(pr.id or 0) then
					apply_pr_info_content(bufnr, info_pr)
				end
			end)
		end)
	end, { desc = "Load PR comments and render virtual text in current buffer" })

	vim.api.nvim_create_user_command("BBPROpenLineComments", function()
		local bufnr = vim.api.nvim_get_current_buf()
		local line = vim.api.nvim_win_get_cursor(0)[1]
		local by_line = vim.b[bufnr].bb_pr_line_comments or {}
		local comments = by_line[line]
		if not comments or #comments == 0 then
			vim.notify("bb_pr: no comments on current line", vim.log.levels.INFO)
			return
		end
		open_comment_float(comments, line)
	end, { desc = "Open floating window with comments for current line" })

	vim.keymap.set(
		"n",
		"gc",
		"<cmd>BBPROpenLineComments<CR>",
		{ desc = "Open PR comments for current line", silent = true }
	)
	if M.config.comment_next_map and M.config.comment_next_map ~= "" then
		vim.keymap.set("n", M.config.comment_next_map, function()
			jump_comment(1)
		end, { desc = "Jump to next PR comment", silent = true })
	end
	if M.config.comment_prev_map and M.config.comment_prev_map ~= "" then
		vim.keymap.set("n", M.config.comment_prev_map, function()
			jump_comment(-1)
		end, { desc = "Jump to previous PR comment", silent = true })
	end

	vim.api.nvim_create_user_command("BBPRCreateComment", function()
		post_comment_or_task(false, false)
	end, { desc = "Create or reply PR comment from cursor context" })

	vim.api.nvim_create_user_command("BBPRCreateTask", function()
		post_comment_or_task(true, false)
	end, { desc = "Create or reply PR task from cursor context" })

	vim.api.nvim_create_user_command("BBPRCreateSuggestion", function()
		create_suggestion_comment()
	end, { desc = "Create PR comment with prefilled suggestion block" })

	vim.api.nvim_create_user_command("BBPRAcceptSuggestion", function()
		accept_suggestion()
	end, { desc = "Apply suggestion from comment under cursor to current file" })

	vim.api.nvim_create_user_command("BBPRReplyComment", function()
		post_comment_or_task(false, true)
	end, { desc = "Reply to current PR comment" })

	vim.api.nvim_create_user_command("BBPRRefreshComments", function()
		vim.cmd("BBPRLoadComments")
	end, { desc = "Force refresh PR comments from server" })

	vim.api.nvim_create_user_command("BBPRToggleTask", function()
		toggle_task_status()
	end, { desc = "Toggle PR task done/open for comment under cursor" })

	vim.api.nvim_create_user_command("BBPRResolveComment", function()
		resolve_comment()
	end, { desc = "Resolve/unresolve PR comment thread under cursor" })

	vim.api.nvim_create_user_command("BBPRReactComment", function()
		react_to_comment()
	end, { desc = "Add reaction to comment under cursor" })
	vim.api.nvim_create_user_command("BBPRDeleteComment", function()
		delete_comment()
	end, { desc = "Delete PR comment under cursor" })

	vim.api.nvim_create_user_command("BBPRCreatePR", function()
		create_pr()
	end, { desc = "Create pull request from current branch" })
	vim.api.nvim_create_user_command("BBPRMerge", function()
		merge_current_pr()
	end, { desc = "Merge pull request opened in current tab" })

	if M.config.create_comment_map and M.config.create_comment_map ~= "" then
		vim.keymap.set(
			"n",
			M.config.create_comment_map,
			"<cmd>BBPRCreateComment<CR>",
			{ desc = "Create PR comment", silent = true }
		)
	end
	if M.config.create_task_map and M.config.create_task_map ~= "" then
		vim.keymap.set(
			"n",
			M.config.create_task_map,
			"<cmd>BBPRCreateTask<CR>",
			{ desc = "Create PR task", silent = true }
		)
	end
	if M.config.create_suggestion_map and M.config.create_suggestion_map ~= "" then
		vim.keymap.set(
			"n",
			M.config.create_suggestion_map,
			"<cmd>BBPRCreateSuggestion<CR>",
			{ desc = "Create PR suggestion comment", silent = true }
		)
	end
	if M.config.accept_suggestion_map and M.config.accept_suggestion_map ~= "" then
		vim.keymap.set(
			"n",
			M.config.accept_suggestion_map,
			"<cmd>BBPRAcceptSuggestion<CR>",
			{ desc = "Accept PR suggestion", silent = true }
		)
	end
	if M.config.reply_comment_map and M.config.reply_comment_map ~= "" then
		vim.keymap.set(
			"n",
			M.config.reply_comment_map,
			"<cmd>BBPRReplyComment<CR>",
			{ desc = "Reply PR comment", silent = true }
		)
	end
	if M.config.react_comment_map and M.config.react_comment_map ~= "" then
		vim.keymap.set(
			"n",
			M.config.react_comment_map,
			"<cmd>BBPRReactComment<CR>",
			{ desc = "React to PR comment", silent = true }
		)
	end
	if M.config.delete_comment_map and M.config.delete_comment_map ~= "" then
		vim.keymap.set(
			"n",
			M.config.delete_comment_map,
			"<cmd>BBPRDeleteComment<CR>",
			{ desc = "Delete PR comment", silent = true }
		)
	end
	if M.config.toggle_task_map and M.config.toggle_task_map ~= "" then
		vim.keymap.set(
			"n",
			M.config.toggle_task_map,
			"<cmd>BBPRToggleTask<CR>",
			{ desc = "Toggle PR task done/open", silent = true }
		)
	end
	if M.config.resolve_comment_map and M.config.resolve_comment_map ~= "" then
		vim.keymap.set(
			"n",
			M.config.resolve_comment_map,
			"<cmd>BBPRResolveComment<CR>",
			{ desc = "Resolve/unresolve PR comment thread", silent = true }
		)
	end
	if M.config.refresh_comments_map and M.config.refresh_comments_map ~= "" then
		vim.keymap.set(
			"n",
			M.config.refresh_comments_map,
			"<cmd>BBPRRefreshComments<CR>",
			{ desc = "Force refresh PR comments", silent = true }
		)
	end
	if M.config.create_pr_map and M.config.create_pr_map ~= "" then
		vim.keymap.set("n", M.config.create_pr_map, "<cmd>BBPRCreatePR<CR>", { desc = "Create PR", silent = true })
	end
	if M.config.merge_pr_map and M.config.merge_pr_map ~= "" then
		vim.keymap.set("n", M.config.merge_pr_map, "<cmd>BBPRMerge<CR>", { desc = "Merge PR", silent = true })
	end

	local aug = vim.api.nvim_create_augroup("bb_pr_comments", { clear = true })
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "CursorMoved", "WinScrolled" }, {
		group = aug,
		callback = function()
			local pending_payload = consume_pending_tab_comments()
			if pending_payload then
				apply_comments_when_diffview_ready(pending_payload)
				return
			end

			local payload = get_current_tab_comments()
			if payload then
				apply_comments_to_tab_windows(payload)
			end
		end,
	})
end

return M
