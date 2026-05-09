# bbprs.nvim (prototype)

Плагин для Neovim, который использует текущую Go CLI (`/workspace/bb`) как провайдер данных по PR в Bitbucket.

## Возможности

- `:BBPRList` — открыть список активных PR.
- `<CR>` на PR — открыть изменения через `DiffviewOpen`.
- `r` — обновить список.
- `:BBPROpenDiff <id>` — открыть PR по id напрямую.

## Зависимости

- Neovim 0.10+ (для `vim.system`).
- [sindrets/diffview.nvim](https://github.com/sindrets/diffview.nvim).
- Настроенный `config.json` в корне этого репозитория для CLI.

## Быстрый старт

```lua
{
  "local/bbprs.nvim",
  dev = true,
  dir = "/workspace/bb/nvim-plugin",
  config = function()
    require("bbprs").setup({
      -- команда, которая возвращает PR в JSON
      cli_cmd = "cd /workspace/bb && go run . --json",
      -- cwd, где лежит config.json
      cwd = "/workspace/bb",
    })
  end,
}
```

После этого:

1. `:BBPRList`
2. Выбери PR и нажми `<CR>`
3. Откроется `DiffviewOpen target...source`

## Что дальше

Для комментариев/аппрувов лучше добавить в Go CLI отдельные команды:

- `--pr <id> --comments`
- `--pr <id> --activities`
- `--pr <id> --approve|--unapprove`

и затем расширить Lua UI (детальная карточка PR + список тредов).
