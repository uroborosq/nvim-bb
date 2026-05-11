local M = {}

M.config = {
	provider_cmd = { "bb", "-reviewers", "-json" },
	comments_cmd = { "bb", "-json", "-pr-comments" },
	diffview_cmd = "DiffviewOpen",
}

local state = {
	prs = {},
	pr_by_tab = {},
	comment_ns = vim.api.nvim_create_namespace("bb_pr_comments"),
	comments_by_tab = {},
	pending_comments_by_tab = {},
}

local function tab_key(tabpage)
	return tostring(tabpage)
end

local function set_current_tab_pr(pr)
	local key = tab_key(vim.api.nvim_get_current_tabpage())
	state.pr_by_tab[key] = pr
	state.comments_by_tab[key] = nil
end

local function get_current_tab_pr()
	return state.pr_by_tab[tab_key(vim.api.nvim_get_current_tabpage())]
end

local function format_pr_entry(pr)
	local author = (pr.author and pr.author.user and (pr.author.user.displayName or pr.author.user.name)) or "unknown"
	local from_ref = (pr.fromRef and pr.fromRef.displayId) or "?"
	local to_ref = (pr.toRef and pr.toRef.displayId) or "?"
	return string.format(
		"#%s [%s] %s (%s → %s) — %s",
		pr.id,
		pr.state or "-",
		author,
		from_ref,
		to_ref,
		pr.title or ""
	)
end

local function merge_config(user)
	M.config = vim.tbl_deep_extend("force", M.config, user or {})
end

local function run_provider(cb)
	vim.system(M.config.provider_cmd, { text = true }, function(res)
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

local apply_comments_to_current_buffer
local apply_comments_to_tab_windows

local function run_comments_provider(pr_id, cb, opts)
	opts = opts or {}
	local cmd = vim.deepcopy(M.config.comments_cmd)
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

local function set_current_tab_comments(payload)
	local key = tab_key(vim.api.nvim_get_current_tabpage())
	state.comments_by_tab[key] = payload
	state.pending_comments_by_tab[key] = payload
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

local function open_comment_float(comments, line)
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
	for idx, c in ipairs(comments) do
		local depth = math.max(tonumber(c.depth or 0) or 0, 0)
		local indent = string.rep("  ", depth)
		if idx > 1 then
			table.insert(lines, indent .. "---")
			table.insert(lines, "")
		end
		local comment_id = tonumber(c.id or 0) or 0
		local reply_to = tonumber(c.parent_id or 0) or 0
		local header = string.format("%s- %s @ %s", indent, c.author or "unknown", c.created_at or "unknown time")
		if comment_id > 0 then
			header = header .. string.format(" (#%d)", comment_id)
		end
		if reply_to > 0 then
			header = header .. string.format(" ↳ reply to #%d", reply_to)
		end
		table.insert(lines, header)
		local msg_lines = trim_edge_empty_lines(vim.split(c.text or "", "\n", { plain = true }))
		for _, msg_line in ipairs(msg_lines) do
			table.insert(lines, indent .. "  " .. msg_line)
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

	vim.api.nvim_set_option_value("wrap", true, { win = win })
	vim.api.nvim_set_option_value("linebreak", true, { win = win })
	enable_markview(buf, win)
	vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf, silent = true })
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
		vim.cmd(string.format("%s origin/%s...origin/%s", M.config.diffview_cmd, to_ref, from_ref))
		set_current_tab_pr(pr)
			run_comments_provider(pr.id, function(payload)
				vim.schedule(function()
					set_current_tab_comments(payload)
						apply_comments_when_diffview_ready(payload)
					end)
				end, { notify_errors = false })
			end

	local fetch_cmd = {
		"git",
		"fetch",
		"origin",
		"+refs/heads/" .. to_ref .. ":refs/remotes/origin/" .. to_ref,
		"+refs/heads/" .. from_ref .. ":refs/remotes/origin/" .. from_ref,
	}

	vim.system(fetch_cmd, { text = true }, function(fetch_res)
		if fetch_res.code ~= 0 then
			vim.schedule(function()
				vim.notify("bb_pr: failed to fetch PR branches: " .. (fetch_res.stderr or ""), vim.log.levels.ERROR)
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
end

local function format_opened_date(ms)
	if type(ms) ~= "number" or ms <= 0 then
		return "unknown"
	end

	return os.date("%Y-%m-%d %H:%M:%S %Z", math.floor(ms / 1000))
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
		local status = normalize_status(reviewer)
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

	local comments = as_array(payload and payload.overview_comments)
	if #comments == 0 then
		return { "None" }
	end

	local lines = {}
	for idx, c in ipairs(comments) do
		if idx > 1 then
			table.insert(lines, "---")
			table.insert(lines, "")
		end

		local depth = math.max(tonumber(c.depth or 0) or 0, 0)
		local indent = string.rep("  ", depth)
		local author = c.author or "unknown"
		local created_at = c.created_at or "unknown time"
		local comment_id = tonumber(c.id or 0) or 0
		local reply_to = tonumber(c.parent_id or 0) or 0
		local header = string.format("%s- %s @ %s", indent, author, created_at)
		if comment_id > 0 then
			header = header .. string.format(" (#%d)", comment_id)
		end
		if reply_to > 0 then
			header = header .. string.format(" ↳ reply to #%d", reply_to)
		end
		table.insert(lines, header)

		local msg_lines = trim_edge_empty_lines(vim.split(c.text or "", "\n", { plain = true }))
		if #msg_lines == 0 then
			table.insert(lines, indent .. "  (empty)")
		else
			for _, msg_line in ipairs(msg_lines) do
				table.insert(lines, indent .. "  " .. msg_line)
			end
		end
		table.insert(lines, "")
	end

	if lines[#lines] ~= "" then
		table.insert(lines, "")
	end

	return lines
end

local function open_pr_info(pr)
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
		"## desc",
	}

	vim.list_extend(info_lines, to_lines(pr.description))
	table.insert(info_lines, "")
	table.insert(info_lines, "## appr-s")

	vim.list_extend(info_lines, build_approval_lines(pr))
	table.insert(info_lines, "")
	table.insert(info_lines, "## comments")

	local comments_payload = get_current_tab_comments()
	vim.list_extend(info_lines, build_overview_comment_lines(comments_payload))

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, info_lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })

	vim.diagnostic.enable(false, { bufnr = buf })

	local width = math.floor(vim.o.columns * 0.7)
	local height = math.min(#info_lines + 2, math.floor(vim.o.lines * 0.7))

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

	vim.api.nvim_set_option_value("wrap", true, { win = win })
	vim.api.nvim_set_option_value("linebreak", true, { win = win })
	enable_markview(buf, win)

	vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf, silent = true })
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
						open_pr_info(selection.value)
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
		state.prs = prs

		vim.schedule(function()
			if open_telescope_picker(prs) then
				return
			end

			local buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_name(buf, "bb_pr://pull_requests")
			vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
			vim.api.nvim_set_option_value("filetype", "bb_pr", { buf = buf })
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, build_lines(prs))

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
					open_pr_info(pr)
				end
			end, { buffer = buf, silent = true })

			vim.api.nvim_set_current_buf(buf)
		end)
	end)
end

function M.setup(opts)
	merge_config(opts)

	vim.api.nvim_create_user_command("BBPRList", function()
		M.open_list()
	end, { desc = "List active Bitbucket PRs" })

	vim.api.nvim_create_user_command("BBPRInfo", function()
		local pr = get_current_tab_pr()
		if not pr then
			vim.notify("bb_pr: no PR tracked for current tab", vim.log.levels.WARN)
			return
		end

		open_pr_info(pr)
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
					apply_comments_to_tab_windows(payload)
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

	vim.keymap.set("n", "gc", "<cmd>BBPROpenLineComments<CR>", { desc = "Open PR comments for current line", silent = true })

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
