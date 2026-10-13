# Tasks

## 1. Удаление режима из плагина

- [x] 1.1 В конфигурации по умолчанию `lua/bb_pr/init.lua` удалить поле `diff_mode` и комментарий к нему про режимы `"worktree"` и `"commits"`. Проверка: `grep -n diff_mode lua/bb_pr/init.lua` не находит конфигурационного поля.
- [x] 1.2 В `open_diffview` убрать ветвление по `M.config.diff_mode` и комментарий о режиме `"commits"`: всегда выполнять `<diffview_cmd> -C<repo_root> origin/<to_ref>`. Комментарий о конфликте и 3-way merge оставить. Проверка: `grep -n 'diff_mode\|\.\.HEAD' lua/bb_pr/init.lua` ничего не находит; `nvim --headless -c 'lua require("bb_pr").setup({ diff_mode = "commits" })' -c q` завершается без ошибки.
- [x] 1.3 В принятии suggestion переписать комментарий у записи буфера, не показанного ни в одном окне. Обоснование: suggestion можно принять из PR Info, когда файл не открыт, и правка скрытого буфера иначе останется незаметной. Сама логика записи не меняется. Проверка: комментарий не упоминает `diff_mode`.
- [x] 1.4 Обновить документацию: в `README.md` удалить абзац «PR tab diff mode», а из описания строки `Changes:` убрать «in either `diff_mode`» и «(or with the merge commit in `diff_mode = "commits"`, unless the merge conflicts)». В `CLAUDE.md` удалить последнее предложение раздела «Line numbers» про `diff_mode = "commits"`. Проверка: `grep -rn diff_mode README.md CLAUDE.md lua/` ничего не находит.

## 2. Ручная проверка

- [ ] 2.1 Удалить `diff_mode = "commits"` из `~/.config/nvim/lua/plugins/bb.lua` (выполняет пользователь или агент с его разрешения, файл вне репозитория). Открыть PR с Go-файлами и убедиться, что правая сторона diff — файл `<repo>/<path>`, а не `diffview://`, к нему подключён gopls (`:checkhealth vim.lsp` или `:LspInfo`), работают переход к определению и диагностика. Проверить, что комментарии, переход к комментарию и принятие suggestion работают, и что при конфликте слияния правая сторона показывает файл с маркерами конфликта.

## Workflow follow-up

- Не коммитить до проверки пользователем (CLAUDE.md).
- Архивировать изменение после ручной проверки.
