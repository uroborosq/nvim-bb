-- Pure helpers for the per-file "viewed" state: a file is viewed when the blob sha of
-- its PR-branch content equals the sha recorded when it was marked. No state, no git calls.
local M = {}

-- Parses `git ls-tree -r -z` output ("<mode> <type> <sha>\t<path>\0" per entry)
-- into { [path] = blob_sha }. Only blobs are kept; paths may contain spaces.
function M.parse_ls_tree(out)
	local blobs = {}
	for entry in tostring(out or ""):gmatch("[^%z]+") do
		local kind, sha, path = entry:match("^%d+ (%a+) (%x+)\t(.+)$")
		if kind == "blob" then
			blobs[path] = sha
		end
	end
	return blobs
end

-- files: marked { [path] = sha }; blobs: current { [path] = sha}.
-- A path absent from blobs (e.g. deleted) is never viewed.
function M.is_viewed(files, blobs, path)
	local sha = files and files[path]
	return sha ~= nil and sha == (blobs and blobs[path])
end

-- Returns viewed, total for a list of plain path strings (callers map changed-file
-- entries to their path).
function M.count(files, blobs, paths)
	local viewed = 0
	for _, path in ipairs(paths or {}) do
		if M.is_viewed(files, blobs, path) then
			viewed = viewed + 1
		end
	end
	return viewed, #(paths or {})
end

-- "mark" when any path is not viewed yet, otherwise "unmark" (empty set: "unmark").
function M.action(files, blobs, paths)
	for _, path in ipairs(paths or {}) do
		if not M.is_viewed(files, blobs, path) then
			return "mark"
		end
	end
	return "unmark"
end

return M
