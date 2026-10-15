-- Bitbucket web URLs of a PR, its comments and its files, built from the PR's
-- links.self href (the PR page), and opening a URL with the system handler.
local M = {}

-- PR page URL without a trailing "/", nil when the PR has no self link
function M.pr_url(pr)
	local href = vim.tbl_get(pr or {}, "links", "self", 1, "href")
	if type(href) ~= "string" or href == "" then
		return nil
	end
	return (href:gsub("/+$", ""))
end

function M.comment_url(pr, comment_id)
	local base = M.pr_url(pr)
	return base and string.format("%s/overview?commentId=%s", base, comment_id)
end

-- Percent-encodes a repo path for the URL fragment: "/" and the other fragment
-- characters stay, everything else (space, "%", "#", "?", non-ASCII bytes) becomes %XX.
local function encode_path(path)
	return (path:gsub("[^%w%-%._~/!$&'()*+,;=:@]", function(ch)
		return string.format("%%%02X", ch:byte())
	end))
end

-- URL of `path` in the PR diff; anchor = { line, file_type } adds the line on the
-- TO (?t=) or FROM (?f=) side.
function M.file_url(pr, path, anchor)
	local base = M.pr_url(pr)
	if not base then
		return nil
	end
	local url = base .. "/diff#" .. encode_path(path)
	local line = anchor and tonumber(anchor.line)
	if line and line > 0 then
		local side = tostring(anchor.file_type or ""):upper() == "FROM" and "f" or "t"
		url = string.format("%s?%s=%d", url, side, line)
	end
	return url
end

function M.open(url)
	local _, err = vim.ui.open(url)
	if err then
		vim.notify(string.format("bb_pr: cannot open %s: %s", url, err), vim.log.levels.ERROR)
	end
end

return M
