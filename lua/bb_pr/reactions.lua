local M = {}

-- GitHub-style aliases taken from rxaviers emoji cheatsheet:
-- https://gist.github.com/rxaviers/7360908#file-gistfile1-md
local emoji_map = {
	["+1"] = "👍",
	THUMBS_UP = "👍",
	THUMBSUP = "👍",
	["-1"] = "👎",
	THUMBS_DOWN = "👎",
	THUMBSDOWN = "👎",
	LAUGH = "😄",
	SMILE = "😄",
	SMILEY = "😃",
	HOORAY = "🎉",
	TADA = "🎉",
	CONFUSED = "😕",
	HEART = "❤️",
	HEARTS = "♥️",
	ROCKET = "🚀",
	EYES = "👀",
}

local function to_count(v)
	if type(v) == "number" then
		return math.floor(v)
	end
	return 0
end

local function normalize_key(key)
	local raw = tostring(key or "")
	local trimmed = raw:gsub("^:+", ""):gsub(":+$", "")
	trimmed = trimmed:gsub("%s+", "_")
	local upper = trimmed:upper()
	return upper, trimmed:lower()
end

function M.format_line(reactions)
	if type(reactions) ~= "table" then
		return nil
	end

	local items = {}
	for key, value in pairs(reactions) do
		local count = to_count(value)
		if count > 0 then
			table.insert(items, { key = tostring(key), count = count })
		end
	end

	if #items == 0 then
		return nil
	end

	table.sort(items, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return a.key < b.key
	end)

	local chunks = {}
	for _, item in ipairs(items) do
		local upper, fallback = normalize_key(item.key)
		local label = emoji_map[upper] or (":" .. fallback .. ":")
		table.insert(chunks, string.format("%s %d", label, item.count))
	end

	return table.concat(chunks, "  ")
end

return M
