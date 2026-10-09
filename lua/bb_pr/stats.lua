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

local MAX_ITEMS = 15

-- Render a single bar chart block. Returns lines, highlights (0-indexed within the block).
-- opts: {
--   bar_hl = "DiagnosticInfo",  -- highlight group for the bars
--   two_col = false,            -- narrow bars and a fixed name width, for merge_two_columns
--   value_suffix = "",          -- unit appended after the count, e.g. "h"
-- }
local function render_bar_chart(title, items, opts)
	opts = opts or {}
	local bar_hl = opts.bar_hl or "DiagnosticInfo"
	local two_col = opts.two_col or false
	local bar_width = two_col and BAR_WIDTH_2COL or BAR_WIDTH
	local value_suffix = opts.value_suffix or ""
	local lines = section_lines(title, two_col and COL_WIDTH or nil)
	local highlights = {}

	if not items or #items == 0 then
		table.insert(lines, "  (no data)")
		return lines, highlights
	end

	local max_count = 0
	local max_name = 10
	for i, item in ipairs(items) do
		if i > MAX_ITEMS then break end
		max_count = math.max(max_count, item.count or 0)
		max_name = math.max(max_name, #(item.user or ""))
	end
	if max_count == 0 then
		table.insert(lines, "  (no data)")
		return lines, highlights
	end

	-- In two-column mode pin to a fixed cap so both columns' bars are column-aligned.
	if two_col then
		max_name = 18
	else
		max_name = math.min(max_name, 26)
	end

	local base = #lines
	for i, item in ipairs(items) do
		if i > MAX_ITEMS then break end
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

	vim.list_extend(highlights, left_hl or {})

	for _, h in ipairs(right_hl or {}) do
		local shift = right_byte_start[h.line + 1]
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

-- Render two bar charts side by side when both have items, otherwise just the
-- one that does. Each spec: { title, title_2col?, items, bar_hl, value_suffix? };
-- title_2col replaces title in the (narrower) two-column layout.
local function render_bar_chart_pair(left, right)
	local has_left = left.items and #left.items > 0
	local has_right = right.items and #right.items > 0

	local function chart(spec, two_col)
		local title = two_col and spec.title_2col or spec.title
		return render_bar_chart(title, spec.items, { bar_hl = spec.bar_hl, two_col = two_col, value_suffix = spec.value_suffix })
	end

	if has_left and has_right then
		local ll, lh = chart(left, true)
		local rl, rh = chart(right, true)
		return merge_two_columns(ll, lh, rl, rh)
	elseif has_left then
		return chart(left, false)
	elseif has_right then
		return chart(right, false)
	end
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
	push(render_bar_chart_pair(
		{ title = "USER COMMENTS  (excluding self-comments)", title_2col = "USER COMMENTS  (excl. self)", items = data.user_comments, bar_hl = "DiagnosticInfo" },
		{ title = "USER APPROVALS", items = data.user_approvals, bar_hl = "DiagnosticOk" }
	))

	if data.user_commits and #data.user_commits > 0 then
		push(render_bar_chart("COMMITS TO BRANCH (by git author)", data.user_commits, { bar_hl = "DiagnosticWarn" }))
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

	push(render_bar_chart_pair(
		{ title = "AUTHOR PRs IN TOP 10%", items = data.top_author_pr_count, bar_hl = "DiagnosticWarn" },
		{ title = "AUTHOR AVG DURATION (hours, MERGED)", items = data.top_author_duration, bar_hl = "DiagnosticHint", value_suffix = "h" }
	))

	if data.top_author_long_ratio and #data.top_author_long_ratio > 0 then
		push(render_bar_chart("AUTHOR LONG-PR RATE  (% of own PRs in top longest)", data.top_author_long_ratio, { bar_hl = "DiagnosticError", value_suffix = "%" }))
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
