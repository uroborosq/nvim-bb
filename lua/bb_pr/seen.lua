-- Store of "last viewed" records per PR, plus the git refs that keep the seen commits alive.
--
-- File format: { version = 1, prs = { ["<project>/<repo>#<id>"] = record } } where record is
-- { seen_at (ms), source (sha), root, comment_count, comments = { ["<comment id>"] = version },
-- files = { ["<path>"] = "<blob sha>" }, all_viewed } (files: marked as viewed; a record written before this field existed has none, i.e. reads as empty;
-- all_viewed: the source sha at which every PR file was viewed, absent otherwise);
-- comment_count is absent while the record has not seen the PR's comments yet.
-- Callers pass paths and limits; the module holds no state.
local M = {}

local VERSION = 1

function M.key(pr)
	local to = type(pr) == "table" and pr.toRef or nil
	local repo = type(to) == "table" and to.repository or nil
	local project = type(repo) == "table" and type(repo.project) == "table" and repo.project.key or nil
	local slug = type(repo) == "table" and repo.slug or nil
	if not project or not slug or not pr.id or project == "" or slug == "" then
		return nil
	end
	return string.format("%s/%s#%s", project, slug, tostring(pr.id))
end

-- "PROJ/repo#101" -> "refs/bb_pr/seen/PROJ/repo/101"
function M.ref_name(key)
	if not key then
		return nil
	end
	return "refs/bb_pr/seen/" .. tostring(key):gsub("#", "/")
end

-- The prs map of the file at `path`; empty on a missing or corrupt file.
local function read_prs(path)
	path = tostring(path or "")
	if path == "" then
		return {}
	end
	local ok_read, lines = pcall(vim.fn.readfile, path)
	if not ok_read or type(lines) ~= "table" or #lines == 0 then
		return {}
	end
	local ok_json, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
	if not ok_json or type(decoded) ~= "table" or type(decoded.prs) ~= "table" then
		return {}
	end
	local prs = {}
	for key, record in pairs(decoded.prs) do
		if type(record) == "table" then
			prs[key] = record
		end
	end
	return prs
end

-- An empty Lua table encodes as [] and numeric keys as arrays, so the maps are
-- tagged as objects and comment ids are written as strings. Returns whether it wrote.
local function write_prs(path, prs)
	path = tostring(path or "")
	if path == "" then
		return false
	end
	local out = {}
	for key, record in pairs(prs) do
		record = vim.deepcopy(record)
		local comments = vim.empty_dict()
		if type(record.comments) == "table" then
			for id, replies in pairs(record.comments) do
				comments[tostring(id)] = replies
			end
		end
		record.comments = comments
		-- string keys always encode as an object, only an empty table needs the tag
		if type(record.files) ~= "table" or next(record.files) == nil then
			record.files = vim.empty_dict()
		end
		out[key] = record
	end
	if next(out) == nil then
		out = vim.empty_dict()
	end
	pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p")
	-- temp file + rename, so a concurrent reader never sees a half-written store
	local tmp = path .. ".tmp." .. vim.uv.os_getpid()
	local ok = pcall(function()
		vim.fn.writefile({ vim.json.encode({ version = VERSION, prs = out }) }, tmp)
	end) and vim.uv.fs_rename(tmp, path)
	if not ok then
		pcall(vim.fn.delete, tmp)
	end
	return ok and true or false
end

-- All records by key, read once (e.g. for every line of the PR list).
function M.all(path)
	return read_prs(path)
end

function M.get(path, key)
	return key and M.all(path)[key] or nil
end

-- Re-reads the file, sets only `key`, evicts the oldest records beyond max_count.
-- Returns the evicted records, each with its `key`, so the caller can unpin them, and
-- whether the write succeeded (nothing is evicted when it did not).
function M.put(path, key, record, max_count)
	if not key then
		return {}, false
	end
	local prs = read_prs(path)
	prs[key] = record
	local evicted = {}
	local keys = {}
	for k in pairs(prs) do
		if k ~= key then
			table.insert(keys, k)
		end
	end
	table.sort(keys, function(x, y)
		return (tonumber(prs[x].seen_at) or 0) < (tonumber(prs[y].seen_at) or 0)
	end)
	local excess = #keys + 1 - math.max(tonumber(max_count) or 1, 1)
	for i = 1, excess do
		table.insert(evicted, vim.tbl_extend("force", prs[keys[i]], { key = keys[i] }))
		prs[keys[i]] = nil
	end
	if not write_prs(path, prs) then
		return {}, false
	end
	return evicted, true
end

-- Re-reads the file and changes only the given paths of record `key`: changes maps
-- path -> blob sha to mark, or false to unmark. all_viewed (optional): a sha sets the
-- record's all_viewed, false clears it, nil leaves it. Nothing to change writes
-- nothing, and so does a missing record. Returns true, or false plus "missing" (no
-- record) / "write".
function M.set_files(path, key, changes, all_viewed)
	if not key or (next(changes or {}) == nil and all_viewed == nil) then
		return true
	end
	local prs = read_prs(path)
	local record = prs[key]
	if type(record) ~= "table" then
		return false, "missing"
	end
	local files = type(record.files) == "table" and record.files or {}
	for file, sha in pairs(changes or {}) do
		files[file] = sha or nil
	end
	record.files = files
	if all_viewed ~= nil then
		record.all_viewed = all_viewed or nil
	end
	if not write_prs(path, prs) then
		return false, "write"
	end
	return true
end

-- Returns the removed record (with its `key`), or nil when absent or the write failed.
function M.remove(path, key)
	if not key then
		return nil
	end
	local prs = read_prs(path)
	local record = prs[key]
	if type(record) ~= "table" then
		return nil
	end
	prs[key] = nil
	if not write_prs(path, prs) then
		return nil
	end
	return vim.tbl_extend("force", record, { key = key })
end

-- The commit "what changed" is measured from: the later of the source seen here last
-- time and the commit Bitbucket recorded at the user's last review (nil to ignore it).
-- is_ancestor(a, b) is false when either commit is missing locally, so `seen` wins then.
-- Returns baseline (sha or nil), origin ("bitbucket" | "local" | "none").
function M.choose_baseline(seen, reviewed, is_ancestor)
	seen = seen ~= "" and seen or nil
	reviewed = reviewed ~= "" and reviewed or nil
	if seen and reviewed then
		if seen ~= reviewed and is_ancestor(seen, reviewed) then
			return reviewed, "bitbucket"
		end
		return seen, "local"
	end
	if seen then
		return seen, "local"
	end
	if reviewed then
		return reviewed, "bitbucket"
	end
	return nil, "none"
end

-- cb(ok, stderr) runs on the main loop.
local function git_ref(root, args, cb)
	local reason = (not root or root == "") and "missing repo root" or nil
	if not reason then
		for _, arg in ipairs(args) do
			if arg == "" then
				reason = "missing ref or sha"
			end
		end
	end
	if reason then
		if cb then
			vim.schedule(function()
				cb(false, reason)
			end)
		end
		return
	end
	local ok, err = pcall(
		vim.system,
		vim.list_extend({ "git" }, args),
		{ cwd = root, text = true },
		vim.schedule_wrap(function(res)
			if cb then
				cb(res.code == 0, res.stderr)
			end
		end)
	)
	if not ok and cb then
		vim.schedule(function()
			cb(false, tostring(err))
		end)
	end
end

function M.pin(root, key, sha, cb)
	git_ref(root, { "update-ref", M.ref_name(key) or "", sha or "" }, cb)
end

function M.unpin(root, key, cb)
	git_ref(root, { "update-ref", "-d", M.ref_name(key) or "" }, cb)
end

return M
