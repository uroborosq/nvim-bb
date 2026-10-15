# Tasks

## 1. Проверка форм URL

- [ ] 1.1 Вручную (пользователь) открыть в браузере на PR 103 (`https://bitbucket.example.com/projects/PROJ/repos/repo/pull-requests/103`):
  - `/overview?commentId=1001` (комментарий к PR);
  - `/overview?commentId=1002` (задача к `pkg/example/service.go:48`);
  - `/diff#pkg/example/service.go`;
  - тот же адрес с `?t=48` в конце.

  Записать в design.md (D2), какие формы работают. Для неработающих выбрать замену из D2. Проверка: в D2 нет непроверенных форм.

## 2. Модуль `browse.lua`

- [x] 2.1 Создать `lua/bb_pr/browse.lua` с `pr_url(pr)`, `comment_url(pr, id)`, `file_url(pr, path, anchor)` и кодированием пути по D2, используя формы, подтверждённые в 1.1. Проверка: headless-скрипт `nvim --headless -u NONE` с `package.path`, указывающим на `lua/`, покрывает:
  - PR без `links.self` → `nil`;
  - `href` с завершающим `/`;
  - путь с пробелом, `#` и кириллицей;
  - `anchor` с `file_type = "TO"` и `"FROM"`;
  - `anchor = nil`.
- [x] 2.2 Добавить `browse.open(url)` через `vim.ui.open` с сообщением `bb_pr: cannot open <url>: <err>` при ошибке (D5). Проверка: headless-скрипт с подменой `vim.ui.open`, которая возвращает `nil, "no handler"`, получает уведомление с URL; при успешной подмене уведомления нет.
- [x] 2.3 Перевести открытие Jira-тикета и вложений в `init.lua` с `xdg-open` на `browse.open` через `require` внутри функций. Проверка: `grep -n xdg-open lua/bb_pr/init.lua` ничего не находит; `nvim --headless -c 'lua require("bb_pr")' -c q` загружает модуль без ошибки.

## 3. Определение цели и команда

- [x] 3.1 Реализовать `M.browse(kind)` в `init.lua` по D3: comment view, панель Diffview, окно с файлом, иначе PR вкладки; приоритет comment > file > pr; предупреждения для отсутствующего PR и отсутствующего объекта вида `kind`; файл без строки с INFO-сообщением, если строку перевести нельзя. Проверка: headless-скрипт с подменой `browse.open`, подставленными `state.tabs`, `state.comment_view_by_buf` и окном файла получает ожидаемые URL для сценариев спеки «Курсор на комментарии в PR Info», «Курсор в шапке PR Info», «PR Info для PR без вкладки», «PR из diff-буфера», «Комментарий вне комментария», «Вкладка без PR». Модуль загружается (предел top-level `local` не превышен).
- [x] 3.2 Добавить `browse = { map, float_map, picker_map }` в `default_config` и команду `:BBPRBrowse` с `nargs = "?"` и дополнением `pr`/`file`/`comment` в `M.setup`; глобальная клавиша `browse.map` назначается через `bind_keymaps(nil, ...)` (D4). Проверка: в headless nvim после `setup({})` `:BBPRBrowse <Tab>` дополняет три значения, `maparg("<leader>rb", "n")` непустой; после `setup({ browse = { map = "" } })` клавиши нет, а команда есть; `:BBPRBrowse foo` даёт ошибку.
- [x] 3.3 Описать `:BBPRBrowse`, порядок выбора объекта и секцию `browse` в `README.md`; удалить пункт «open bb pr in browser» из Roadmap. Проверка: описание соответствует `specs/pr-open-in-browser/spec.md`, значения по умолчанию совпадают с `default_config`.

## 4. Клавиши в окнах

- [x] 4.1 Добавить запись `browse.float_map` в `comment_action_specs()` (PR Info и float с комментариями к строке) с описанием «Open in browser» (D4). Проверка: headless-тест — в буфере PR Info и float `maparg("gx", "n", false, true).buffer == 1`, а в справке `?` есть строка «Open in browser»; при `float_map = ""` клавиши и строки нет.
- [x] 4.2 Назначить `browse.picker_map` (режим `i`) и `browse.float_map` (режим `n`) в `attach_mappings` Telescope-списка, не закрывая список; в запасном буфере списка назначить `browse.float_map` для `pr_at_cursor()` (D4). Проверка: в headless nvim без Telescope запасной буфер списка имеет буферную клавишу `gx`; с Telescope — проверка в 5.1.

## 5. Ручная проверка

- [ ] 5.1 Вручную открыть в браузере:
  - PR из Telescope-списка (`<C-o>` и `gx` в normal-режиме; список не закрывается);
  - PR из PR Info (шапка) и комментарий из PR Info;
  - комментарий к файлу и ответ в треде из float с комментариями;
  - строку на правой и на левой стороне диффа;
  - строку из target-ветки (файл без строки и сообщение);
  - файл и каталог из панели Diffview;
  - `:BBPRBrowse pr` из diff-буфера;
  - Jira-тикет и вложение (после перехода на `vim.ui.open`).

  Проверить, что в обычной вкладке без PR показывается предупреждение.

## Workflow follow-up

- Не коммитить до проверки пользователем (CLAUDE.md).
- Архивировать изменение после ручной проверки.
