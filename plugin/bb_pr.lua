if vim.g.loaded_bb_pr == 1 then
	return
end
vim.g.loaded_bb_pr = 1

require("bb_pr").setup({
	provider_cmd = { "bb", "-reviewers", "-json" },
})
