local M = {}

local BAR_WIDTH = 32
local BAR_WIDTH_2COL = 16
local COL_WIDTH = 56    -- padded width of each column in two-column layout
local BLOCK = "█"

local function bar(value, max_value, width)
	if max_value == 0 then return string.rep(" ", width) end
	local filled = math.floor(value / max_value * width + 0.5)
	filled = math.min(math.max(filled, 0), width)
	return string.rep(BLOCK, filled) .. string.rep(" ", width - filled)
end

local function section_lines(title, width)
	local w = width or math.max(44, #title + 4)
	local sep = string.rep("─", w)
	return { "", title, sep }
end

-- Render a single bar chart block. Returns lines, highlights (0-indexed within the block).
-- opts: { value_suffix = "h" } to append a unit after the count.
local function render_bar_chart(title, items, max_items, bar_hl, bar_width, sep_width, opts)
	max_items = max_items or 15
	bar_hl = bar_hl or "DiagnosticInfo"
	bar_width = bar_width or BAR_WIDTH
	local value_suffix = (opts and opts.value_suffix) or ""
	local lines = section_lines(title, sep_width)
	local highlights = {}

	if not items or #items == 0 then
		table.insert(lines, "  (no data)")
		return lines, highlights
	end

	local max_count = 0
	for i, item in ipairs(items) do
		if i > max_items then break end
		max_count = math.max(max_count, item.count or 0)
	end
	if max_count == 0 then
		table.insert(lines, "  (no data)")
		return lines, highlights
	end

	local max_name = 10
	for i, item in ipairs(items) do
		if i > max_items then break end
		max_name = math.max(max_name, #(item.user or ""))
	end
	-- In two-column mode pin to a fixed cap so both columns' bars are column-aligned.
	local name_cap = (bar_width == BAR_WIDTH_2COL) and 18 or 26
	max_name = (bar_width == BAR_WIDTH_2COL) and name_cap or math.min(max_name, name_cap)

	local base = #lines
	for i, item in ipairs(items) do
		if i > max_items then break end
		local name = item.user or "?"
		if #name > max_name then name = name:sub(1, max_name - 1) .. "…" end
		local pad = max_name - #name
		local b = bar(item.count, max_count, bar_width)
		local line = string.format("  %s%s  %s  %d%s", name, string.rep(" ", pad), b, item.count, value_suffix)
		table.insert(lines, line)
		local col_start = 2 + max_name + pad + 2
		table.insert(highlights, { line = base + i - 1, col_start = col_start, col_end = col_start + bar_width, group = bar_hl })
	end

	return lines, highlights
end

-- Merge two column blocks side by side.
-- Uses vim.api.nvim_strwidth for display-cell width (not bytes) so multi-byte
-- chars like ─ / █ (3 bytes each in UTF-8) don't corrupt the padding.
local function merge_two_columns(left_lines, left_hl, right_lines, right_hl)
	local n = math.max(#left_lines, #right_lines)
	local lines = {}
	local highlights = {}
	local SEP = "  "

	-- Pad/truncate s to exactly COL_WIDTH display cells.
	-- Returns (padded_string, byte_length_of_padded_string).
	local function pad_left(s)
		local dw = vim.api.nvim_strwidth(s)
		if dw > COL_WIDTH then
			-- Truncate at correct character boundary (single-width chars only here).
			s = vim.fn.strcharpart(s, 0, COL_WIDTH)
			dw = COL_WIDTH
		end
		local spaces = string.rep(" ", COL_WIDTH - dw)
		local padded = s .. spaces
		return padded, #padded  -- byte length used to compute right-col byte offset
	end

	-- Per-line byte offset where the right column starts.
	local right_byte_start = {}
	for i = 1, n do
		local l = left_lines[i] or ""
		local r = right_lines[i] or ""
		local padded_l, byte_len = pad_left(l)
		table.insert(lines, padded_l .. SEP .. r)
		right_byte_start[i] = byte_len + #SEP
	end

	for _, h in ipairs(left_hl or {}) do
		table.insert(highlights, { line = h.line, col_start = h.col_start, col_end = h.col_end, group = h.group })
	end

	for _, h in ipairs(right_hl or {}) do
		local shift = right_byte_start[h.line + 1] or (COL_WIDTH + #SEP)
		table.insert(highlights, { line = h.line, col_start = h.col_start + shift, col_end = h.col_end + shift, group = h.group })
	end

	return lines, highlights
end

local function render_distribution(title, dist, bar_hl)
	bar_hl = bar_hl or "DiagnosticHint"
	local lines = section_lines(title)
	local highlights = {}

	if not dist or (dist.count or 0) == 0 then
		table.insert(lines, "  (no data)")
		return lines, highlights
	end

	table.insert(lines, string.format(
		"  n=%-4d  mean=%-8.1f  median=%-8.1f  min=%-8.1f  max=%-8.1f  std=%.1f",
		dist.count, dist.mean, dist.median, dist.min, dist.max, dist.std
	))
	table.insert(lines, string.format(
		"  p25=%-8.1f  p75=%-8.1f  p90=%-8.1f  p95=%.1f",
		dist.p25, dist.p75, dist.p90, dist.p95
	))
	table.insert(lines, "")

	local hist = dist.histogram or {}
	local max_count = 0
	for _, b in ipairs(hist) do
		max_count = math.max(max_count, b.count or 0)
	end
	if max_count == 0 then return lines, highlights end

	local max_label = 6
	for _, b in ipairs(hist) do
		max_label = math.max(max_label, #(b.label or ""))
	end

	local base = #lines
	for i, bucket in ipairs(hist) do
		local label = bucket.label or ""
		local pad = max_label - #label
		local b = bar(bucket.count, max_count, BAR_WIDTH)
		local line = string.format("  %s%s  %s  %d", label, string.rep(" ", pad), b, bucket.count)
		table.insert(lines, line)
		local col_start = 2 + max_label + pad + 2
		table.insert(highlights, { line = base + i - 1, col_start = col_start, col_end = col_start + BAR_WIDTH, group = bar_hl })
	end

	return lines, highlights
end

local function render_top_prs(title, prs)
	local lines = section_lines(title)

	if not prs or #prs == 0 then
		table.insert(lines, "  (no data)")
		return lines
	end

	for i, pr in ipairs(prs) do
		local days = (pr.duration_hours or 0) / 24
		local title_trunc = (pr.title or ""):sub(1, 56)
		table.insert(lines, string.format("  %2d. [%s] %s", i, pr.repo or "?", title_trunc))
		table.insert(lines, string.format("      %.0fh (%.1fd)  ·  %s", pr.duration_hours or 0, days, pr.author or "?"))
	end

	return lines
end

function M.render(data)
	local all_lines = {}
	local all_highlights = {}

	local function push(lines, highlights)
		local off = #all_lines
		for _, l in ipairs(lines or {}) do
			table.insert(all_lines, l)
		end
		for _, h in ipairs(highlights or {}) do
			table.insert(all_highlights, { line = h.line + off, col_start = h.col_start, col_end = h.col_end, group = h.group })
		end
	end

	local s = data.summary or {}
	local repos_str = table.concat(s.repos or {}, ", ")
	local since_str = "all time"
	if s.since_date and s.since_date ~= "" then
		since_str = string.format("last %d days (since %s)", s.since_days or 0, (s.since_date or ""):sub(1, 10))
	end

	push({
		"",
		string.format("  BB PR Statistics  ·  %s  ·  [%s]", s.project or "?", repos_str),
		string.format("  Period: %s", since_str),
		string.format("  Total PRs: %d   Analyzed: %s", s.total_prs or 0, (s.analyzed_at or ""):sub(1, 19)),
		string.rep("═", 60),
	})

	-- COMMENTS and APPROVALS side by side.
	local has_comments = data.user_comments and #data.user_comments > 0
	local has_approvals = data.user_approvals and #data.user_approvals > 0

	if has_comments and has_approvals then
		local ll, lh = render_bar_chart("USER COMMENTS  (excl. self)", data.user_comments, 15, "DiagnosticInfo", BAR_WIDTH_2COL, COL_WIDTH)
		local rl, rh = render_bar_chart("USER APPROVALS", data.user_approvals, 15, "DiagnosticOk", BAR_WIDTH_2COL, COL_WIDTH)
		push(merge_two_columns(ll, lh, rl, rh))
	elseif has_comments then
		push(render_bar_chart("USER COMMENTS  (excluding self-comments)", data.user_comments, 15, "DiagnosticInfo"))
	elseif has_approvals then
		push(render_bar_chart("USER APPROVALS", data.user_approvals, 15, "DiagnosticOk"))
	end

	if data.user_commits and #data.user_commits > 0 then
		push(render_bar_chart("COMMITS TO BRANCH (by git author)", data.user_commits, 15, "DiagnosticWarn"))
	end

	if data.pr_open_duration then
		push(render_distribution("PR OPEN DURATION (hours, MERGED only)", data.pr_open_duration, "DiagnosticWarn"))
	end

	if data.open_to_first_comment then
		push(render_distribution("TIME: OPEN → FIRST COMMENT (hours)", data.open_to_first_comment, "DiagnosticHint"))
	end

	if data.first_comment_to_merge then
		push(render_distribution("TIME: FIRST COMMENT → MERGE (hours)", data.first_comment_to_merge, "DiagnosticHint"))
	end

	if data.comment_distribution then
		push(render_distribution("COMMENTS PER PR  (excluding self-comments)", data.comment_distribution, "DiagnosticInfo"))
	end

	if data.top_longest_prs and #data.top_longest_prs > 0 then
		push(render_top_prs("TOP LONGEST PRs  (by open duration, MERGED)", data.top_longest_prs))
	end

	local has_pr_count = data.top_author_pr_count and #data.top_author_pr_count > 0
	local has_dur      = data.top_author_duration and #data.top_author_duration > 0
	local has_ratio    = data.top_author_long_ratio and #data.top_author_long_ratio > 0

	if has_pr_count and has_dur then
		local ll, lh = render_bar_chart("AUTHOR PRs IN TOP 10%", data.top_author_pr_count, 15, "DiagnosticWarn", BAR_WIDTH_2COL, COL_WIDTH)
		local rl, rh = render_bar_chart("AUTHOR AVG DURATION (hours, MERGED)", data.top_author_duration, 15, "DiagnosticHint", BAR_WIDTH_2COL, COL_WIDTH, { value_suffix = "h" })
		push(merge_two_columns(ll, lh, rl, rh))
	elseif has_pr_count then
		push(render_bar_chart("AUTHOR PRs IN TOP 10%", data.top_author_pr_count, 15, "DiagnosticWarn"))
	elseif has_dur then
		push(render_bar_chart("AUTHOR AVG DURATION (hours, MERGED)", data.top_author_duration, 15, "DiagnosticHint", nil, nil, { value_suffix = "h" }))
	end

	if has_ratio then
		push(render_bar_chart("AUTHOR LONG-PR RATE  (% of own PRs in top longest)", data.top_author_long_ratio, 15, "DiagnosticError", nil, nil, { value_suffix = "%" }))
	end

	if data.warnings and #data.warnings > 0 then
		local warn_lines = section_lines("WARNINGS")
		for _, w in ipairs(data.warnings) do
			table.insert(warn_lines, "  ! " .. w)
		end
		push(warn_lines)
	end

	table.insert(all_lines, "")
	return all_lines, all_highlights
end

return M
