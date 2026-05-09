local M = {}

M.config = {
  provider_cmd = { "go", "run", "./main.go", "-reviewers", "-json" },
  diffview_cmd = "DiffviewOpen",
}

local state = {
  prs = {},
}

local function format_pr_entry(pr)
  local author = (pr.author and pr.author.user and (pr.author.user.displayName or pr.author.user.name)) or "unknown"
  local from_ref = (pr.fromRef and pr.fromRef.displayId) or "?"
  local to_ref = (pr.toRef and pr.toRef.displayId) or "?"
  return string.format("#%s [%s] %s (%s → %s) — %s", pr.id, pr.state or "-", author, from_ref, to_ref, pr.title or "")
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

local function build_lines(prs)
  local lines = {
    "ID  STATE    AUTHOR               FROM -> TO           TITLE",
    string.rep("-", 90),
  }

  for _, pr in ipairs(prs) do
    local author = (pr.author and pr.author.user and (pr.author.user.displayName or pr.author.user.name)) or "unknown"
    local from_ref = (pr.fromRef and pr.fromRef.displayId) or "?"
    local to_ref = (pr.toRef and pr.toRef.displayId) or "?"
    table.insert(lines, string.format("%-3s %-8s %-20s %-18s %s", pr.id, pr.state or "-", author, from_ref .. " -> " .. to_ref, pr.title or ""))
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

  vim.cmd(string.format("%s %s...%s", M.config.diffview_cmd, to_ref, from_ref))
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

  pickers.new({}, {
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
      return true
    end,
  }):find()

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

      vim.api.nvim_set_current_buf(buf)
    end)
  end)
end

function M.setup(opts)
  merge_config(opts)

  vim.api.nvim_create_user_command("BBPRList", function()
    M.open_list()
  end, { desc = "List active Bitbucket PRs" })
end

return M
