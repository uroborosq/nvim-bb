-- Pure helpers for per-file line stats of a PR diff. No state, no git calls.
local M = {}

-- Returns files, totals for `git diff --numstat -z -M` output: "<added>\t<deleted>\t<path>\0",
-- or "<added>\t<deleted>\t\0<from_path>\0<path>\0" for a rename; binary files report "-".
-- files: { { from_path, path, added, deleted } } (added/deleted nil for binary);
-- totals: { files, added, deleted } (binary files count only in `files`).
function M.parse_numstat(out)
	local files = {}
	local totals = { files = 0, added = 0, deleted = 0 }
	local fields = {}
	for field in tostring(out or ""):gmatch("([^%z]*)%z") do
		fields[#fields + 1] = field
	end
	local i = 1
	while i <= #fields do
		local add, del, path = fields[i]:match("^([%d-]+)\t([%d-]+)\t(.*)$")
		i = i + 1
		if add then
			local from_path = path
			if path == "" then
				from_path, path = fields[i], fields[i + 1]
				i = i + 2
			end
			if path then
				local added, deleted = tonumber(add), tonumber(del)
				files[#files + 1] = { from_path = from_path, path = path, added = added, deleted = deleted }
				totals.files = totals.files + 1
				totals.added = totals.added + (added or 0)
				totals.deleted = totals.deleted + (deleted or 0)
			end
		end
	end
	return files, totals
end

return M
