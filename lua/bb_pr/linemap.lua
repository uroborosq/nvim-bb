-- Line-number translation between two versions of a file.
--
-- Hunks come from vim.diff(result_type = "indices"): { start_a, count_a, start_b, count_b }.
-- A side with count 0 has start = the line after which the other side's lines sit
-- (0 = before the first line).
local M = {}

-- Normalizes text so both versions end with exactly one newline; otherwise a
-- missing final newline shows up as a change of the last line.
local function normalize(text)
	text = text or ""
	if text ~= "" and text:sub(-1) ~= "\n" then
		text = text .. "\n"
	end
	return text
end

function M.lines_to_text(lines)
	if #lines == 0 or (#lines == 1 and lines[1] == "") then
		return ""
	end
	return table.concat(lines, "\n") .. "\n"
end

function M.hunks(a_text, b_text)
	return vim.diff(normalize(a_text), normalize(b_text), { result_type = "indices", indent_heuristic = true })
end

-- Maps line n across hunks; `from` and `to` are the hunk field offsets (1 = a, 3 = b).
local function map_line(hunks, n, from, to)
	local offset = 0
	for _, h in ipairs(hunks) do
		local s, c = h[from], h[from + 1]
		local other_c = h[to + 1]
		if c > 0 and n >= s and n < s + c then
			return nil
		end
		local last = c > 0 and (s + c - 1) or s
		if last < n then
			offset = offset + other_c - c
		else
			break
		end
	end
	return n + offset
end

-- Line n of version b → line of version a; nil when the line exists only in b.
function M.b_to_a(hunks, n)
	return map_line(hunks, n, 3, 1)
end

-- Line n of version a → line of version b; nil when the line exists only in a.
function M.a_to_b(hunks, n)
	return map_line(hunks, n, 1, 3)
end

-- True when line n of version a is removed/changed (absent from b).
function M.in_a(hunks, n)
	return M.a_to_b(hunks, n) == nil
end

-- True when line n of version b is added/changed (absent from a).
function M.in_b(hunks, n)
	return M.b_to_a(hunks, n) == nil
end

return M
