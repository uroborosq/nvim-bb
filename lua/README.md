# bbprs.nvim (prototype)

Плагин для Neovim, который использует CLI `bb` как провайдер данных по PR в Bitbucket.

## Возможности

- `:BBPRList` — открыть список активных PR.
- `<CR>` на PR — открыть изменения через `DiffviewOpen`.
- `r` — обновить список.
- `:BBPROpenDiff <id>` — открыть PR по id напрямую.

## Зависимости

- Neovim 0.10+ (для `vim.system`).
- [sindrets/diffview.nvim](https://github.com/sindrets/diffview.nvim).
- Бинарник `bb` в `$PATH`.
- Настроенный `config.json` рядом с рабочей директорией (`cwd`) плагина.

## Быстрый старт

```lua
{
  "local/bbprs.nvim",
  dir = "~/dev/bb/nvim-plugin",
  config = function()
    require("bbprs").setup({
      cli_cmd = "bb",
      cwd = vim.fn.getcwd(),
    })
  end,
}
```

После этого:

1. `:BBPRList`
2. Выбери PR и нажми `<CR>`
3. Откроется `DiffviewOpen target...source`
