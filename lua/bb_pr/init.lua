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

local function run_comments_provider(pr_id, cb)
	local cmd = vim.deepcopy(M.config.comments_cmd)
	table.insert(cmd, tostring(pr_id))

	vim.system(cmd, { text = true }, function(res)
		if res.code ~= 0 then
			vim.schedule(function()
				vim.notify("bb_pr: comments provider failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
			end)
			return
		end

		local ok, decoded = pcall(vim.json.decode, res.stdout)
		if not ok or type(decoded) ~= "table" then
			vim.schedule(function()
				vim.notify("bb_pr: invalid PR comments JSON", vim.log.levels.ERROR)
			end)
			return
		end

		cb(decoded)
	end)
end

local function set_current_tab_comments(payload)
	state.comments_by_tab[tab_key(vim.api.nvim_get_current_tabpage())] = payload
end

local function get_current_tab_comments()
	return state.comments_by_tab[tab_key(vim.api.nvim_get_current_tabpage())]
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

local function open_comment_float(comments, line)
	local lines = { string.format("PR comments for line %d", line), "" }
	for _, c in ipairs(comments) do
		table.insert(lines, string.format("- %s @ %s", c.author or "unknown", c.created_at or "unknown time"))
		for _, msg_line in ipairs(vim.split(c.text or "", "\n", { plain = true })) do
			table.insert(lines, "  " .. msg_line)
		end
		table.insert(lines, "")
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"

	local width = math.floor(vim.o.columns * 0.6)
	local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.5))
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
	vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf, silent = true })
end

apply_comments_to_current_buffer = function(comments_payload)
	local bufnr = vim.api.nvim_get_current_buf()
	local file = vim.api.nvim_buf_get_name(bufnr)
	local rel = vim.fn.fnamemodify(file, ":.")

	vim.api.nvim_buf_clear_namespace(bufnr, state.comment_ns, 0, -1)
	local by_line = {}

	for _, c in ipairs(as_array(comments_payload and comments_payload.file_comments)) do
		if c.path == rel or rel:sub(-#(c.path or "")) == c.path then
			local line = tonumber(c.line or 0)
			if line > 0 then
				by_line[line] = by_line[line] or {}
				table.insert(by_line[line], c)
			end
		end
	end

	for line, line_comments in pairs(by_line) do
		local preview = split_first_line(line_comments[1].text)
		local vt = string.format("💬 %d %s", #line_comments, preview)
		vim.api.nvim_buf_set_extmark(bufnr, state.comment_ns, line - 1, 0, {
			virt_text = { { vt, "Comment" } },
			virt_text_pos = "eol",
		})
	end

	vim.b[bufnr].bb_pr_line_comments = by_line
	vim.notify(string.format("bb_pr: loaded %d commented lines for %s", vim.tbl_count(by_line), rel))
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
				apply_comments_to_current_buffer(payload)
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

local function open_pr_info(pr)
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
		"Description:",
	}

	vim.list_extend(info_lines, to_lines(pr.description))
	table.insert(info_lines, "")
	table.insert(info_lines, "Approvals:")

	vim.list_extend(info_lines, build_approval_lines(pr))

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
				apply_comments_to_current_buffer(payload)
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
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
		group = aug,
		callback = function()
			local payload = get_current_tab_comments()
			if payload then
				apply_comments_to_current_buffer(payload)
			end
		end,
	})
end

return M
