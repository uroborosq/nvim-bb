local M = {}

local state = {
  prs = {},
  buf = nil,
  win = nil,
  config = {
    cli_cmd = "go run .",
    cwd = vim.fn.getcwd(),
    reviewers = true,
  },
}

local function notify(msg, level)
  vim.notify("bbprs: " .. msg, level or vim.log.levels.INFO)
end

function M.setup(opts)
  state.config = vim.tbl_deep_extend("force", state.config, opts or {})

  vim.api.nvim_create_user_command("BBPRList", function()
    M.open_list()
  end, { desc = "Open Bitbucket PR list" })

  vim.api.nvim_create_user_command("BBPROpenDiff", function(args)
    local pr_id = tonumber(args.args)
    if not pr_id then
      notify("usage: BBPROpenDiff <pr_id>", vim.log.levels.ERROR)
      return
    end
    M.open_diff_for_pr(pr_id)
  end, { nargs = 1, desc = "Open PR in diffview" })
end

local function parse_json_lines(lines)
  local text = table.concat(lines, "\n")
  if text == "" then
    return nil, "empty output"
  end

  local ok, decoded = pcall(vim.json.decode, text)
  if not ok then
    return nil, decoded
  end

  return decoded, nil
end

function M.fetch_prs(cb)
  local argv = { "bash", "-lc", state.config.cli_cmd .. " --reviewers" }

  vim.system(argv, {
    cwd = state.config.cwd,
    text = true,
    env = vim.tbl_extend("force", vim.fn.environ(), {
      BB_JSON_OUTPUT = "1",
    }),
  }, function(res)
    if res.code ~= 0 then
      vim.schedule(function()
        notify("CLI failed: " .. (res.stderr or "unknown error"), vim.log.levels.ERROR)
      end)
      return
    end

    local parsed, err = parse_json_lines(vim.split(res.stdout or "", "\n", { trimempty = true }))
    if err then
      vim.schedule(function()
        notify("failed to parse JSON: " .. tostring(err), vim.log.levels.ERROR)
      end)
      return
    end

    vim.schedule(function()
      cb(parsed)
    end)
  end)
end

local function ensure_list_buffer()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].filetype = "bbprs"

  vim.keymap.set("n", "<CR>", function()
    local line = vim.api.nvim_get_current_line()
    local pr_id = tonumber(line:match("^#(%d+)"))
    if pr_id then
      M.open_diff_for_pr(pr_id)
    end
  end, { buffer = state.buf, silent = true })

  vim.keymap.set("n", "r", function()
    M.open_list(true)
  end, { buffer = state.buf, silent = true, desc = "Refresh PR list" })

  return state.buf
end

local function render_pr_lines(prs)
  local lines = {
    "Bitbucket Pull Requests",
    "",
  }

  for _, pr in ipairs(prs) do
    local author = (((pr.author or {}).user or {}).displayName) or "unknown"
    local from_ref = ((pr.fromRef or {}).displayId) or "?"
    local to_ref = ((pr.toRef or {}).displayId) or "?"
    table.insert(lines, string.format("#%d [%s] %s (%s -> %s) by %s", pr.id, pr.state or "?", pr.title or "", from_ref, to_ref, author))
  end

  if #prs == 0 then
    table.insert(lines, "No PRs found")
  end

  return lines
end

function M.open_list(refresh)
  local buf = ensure_list_buffer()

  local open_window = function()
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_set_current_win(state.win)
      return
    end

    vim.cmd("botright vnew")
    state.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.win, buf)
    vim.api.nvim_win_set_width(state.win, 70)
  end

  open_window()

  if refresh ~= false and #state.prs == 0 then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading PRs..." })
  end

  M.fetch_prs(function(prs)
    state.prs = prs or {}
    local lines = render_pr_lines(state.prs)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end)
end

function M.open_diff_for_pr(pr_id)
  local pr = nil
  for _, item in ipairs(state.prs) do
    if item.id == pr_id then
      pr = item
      break
    end
  end

  if not pr then
    notify("PR #" .. pr_id .. " not found in cache; run :BBPRList", vim.log.levels.WARN)
    return
  end

  local from_ref = ((pr.fromRef or {}).displayId)
  local to_ref = ((pr.toRef or {}).displayId)

  if not from_ref or not to_ref then
    notify("PR refs are missing for #" .. pr_id, vim.log.levels.ERROR)
    return
  end

  vim.cmd(string.format("DiffviewOpen %s...%s", to_ref, from_ref))
end

return M
