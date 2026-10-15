# Design

## Context

Мотивация описана в proposal.md, требования — в `specs/pr-open-in-browser/spec.md`.

Текущее состояние кода, на которое опирается решение:

- `bb -json` отдаёт у каждого PR `links.self[1].href`, например `https://bitbucket.example.com/projects/PROJ/repos/repo/pull-requests/103` (проверено на сервере). PR Info для вложений уже берёт базовый URL из этого поля (`open_attachment_at_cursor`).
- Комментарий под курсором в обоих видах комментариев (PR Info — `kind = "overview"`, float с комментариями к строке — `kind = "float"`) определяется через `resolve_reply_target_comment_id()`: она читает `state.comment_view_by_buf[buf].ids_by_line`. Ответы в треде имеют свои строки и свои ID. PR в PR Info берётся из `view.pr` (`pr_info_buffer_pr`), в том числе для PR без своей вкладки. Float с комментариями к строке относится к PR текущей вкладки.
- Файл и сторона окна определяются через `window_file_info(win)` → `{ path, from_path, side }`, где `path` — новое имя файла. Строку окна в строку Bitbucket переводит `local_line_to_anchor(info, finfo, line)` → `{ line, line_type, file_type }` или `nil, reason`. `info` — это `tab_diff_base(tabpage)`, он может быть ещё не задан сразу после открытия вкладки.
- Строки панели Diffview дают `seen_view.panel_rows(view.panel.components)` → `{ row, dir, paths }` (0-based `row`). Определять, находится ли курсор в панели, умеет `seen_view.viewed_targets`.
- Клавиши комментариев описаны в `COMMENT_ACTIONS` и назначаются через `comment_action_specs()` в PR Info и во float. `bind_keymaps` пропускает пустые клавиши и добавляет строку в справку `?`.
- Telescope-список переопределяет только `select_default` и `select_horizontal`. Запасной буфер списка назначает `<CR>` и `i` напрямую.
- `xdg-open` вызывается напрямую в двух местах: открытие Jira-тикета и открытие скачанного вложения.
- В `init.lua` около 198 top-level `local` при пределе Lua в 200.

## Goals / Non-Goals

**Goals:**

- Одна функция определения цели, общая для команды и всех клавиш, поэтому любая клавиша открывает то же самое, что `:BBPRBrowse` в этом месте.
- Сборка URL — чистые функции, которые можно проверить в `nvim --headless` без Bitbucket.

**Non-Goals:**

- Копирование URL в буфер обмена (отложено пользователем).
- Открытие файла в репозитории (`/browse/<path>?at=<branch>`) вне диффа PR.
- Открытие комментария к файлу на конкретной строке, если Bitbucket сам не переходит к нему по ссылке на комментарий.
- Изменения в Go CLI.

## Decisions

### D1. Модуль `lua/bb_pr/browse.lua`

Модуль без состояния:

- `pr_url(pr)` → `links.self[1].href` без завершающего `/` или `nil`;
- `comment_url(pr, comment_id)`;
- `file_url(pr, path, anchor?)`, где `anchor = { line, file_type }`;
- `open(url)`.

`init.lua` подключает модуль через `require("bb_pr.browse")` внутри функций, а не top-level `local`, из-за предела в 200 локальных переменных.

Альтернатива — собирать URL из `config.base_url` и project/repo. Её отвергли: ссылка из `links.self` уже указывает на репозиторий PR, а при автоопределении репозитория project/repo в конфиге могут не совпадать с PR.

### D2. Формы URL

От `<pr> = links.self[1].href`:

```
PR                     <pr>
комментарий            <pr>/overview?commentId=<id>
файл                   <pr>/diff#<path>
файл + строка (TO)     <pr>/diff#<path>?t=<line>
файл + строка (FROM)   <pr>/diff#<path>?f=<line>
```

`<path>` кодируется посегментно: `/` остаётся как есть, а пробел, `%`, `#`, `?` и не-ASCII байты заменяются на `%XX`.

`?commentId=` для комментариев к файлам и `?t=`/`?f=` для строки на Bitbucket Server 8.9.7 не проверены, это первая задача в tasks.md. Если форма не работает, правка ограничивается функцией в `browse.lua`. Возможные замены:

- для комментария к файлу — `<pr>/diff?commentId=<id>#<path>` (путь берётся из комментария в загруженном payload);
- для строки — открытие файла без строки.

Поведение из спеки при этом не меняется: открывается комментарий, а строка — «если известна».

### D3. Определение цели — `M.browse(kind)`

Функция `M.browse(kind)` объявляется в `init.lua` после `tab_pr_or_warn` и не добавляет top-level `local`, так как это поле `M`. Она по месту вызова находит набор кандидатов, выбирает самый конкретный (или кандидата вида `kind`) и вызывает `browse.open`.

```
текущий буфер
  |
  +-- comment view (state.comment_view_by_buf)?
  |     pr      = view.pr (overview) или PR вкладки (float)
  |     comment = resolve_reply_target_comment_id()
  |
  +-- панель Diffview вкладки PR?
  |     pr   = PR вкладки
  |     file = путь строки курсора (строка каталога -> нет file)
  |
  +-- окно с файлом (window_file_info ok)?
  |     pr   = PR вкладки
  |     file = finfo.path, anchor = local_line_to_anchor(...) или nil + причина
  |
  +-- иначе: pr = PR вкладки

kind == nil  -> comment, иначе file, иначе pr
kind задан   -> кандидат этого вида или предупреждение "no <kind> under cursor"
pr == nil    -> предупреждение "no PR tracked for current tab"
```

Если `local_line_to_anchor` вернул `nil, reason` или `diff_base` ещё не задан, открывается файл без строки, а `reason` показывается как INFO. Для `side == "single"` (файл без диффа) берётся сторона TO, как и при создании комментария.

Для левой стороны используется `finfo.path`, то есть новое имя. Bitbucket показывает переименованный файл в диффе под новым именем, а `?f=` выбирает сторону.

Альтернатива — отдельные функции для каждого контекста, назначенные своими клавишами. Её отвергли (вариант B в explore): клавиш больше, а выбранный объект почти всегда тот же.

### D4. Команда и клавиши

Конфигурация по умолчанию:

```lua
browse = {
	map = "<leader>rb",   -- глобальная клавиша
	float_map = "gx",     -- PR Info, float с комментариями, запасной буфер списка, normal-режим Telescope
	picker_map = "<C-o>", -- insert-режим Telescope-списка
},
```

- `:BBPRBrowse` создаётся в `M.setup` с `nargs = "?"` и дополнением `pr`, `file`, `comment`. Неизвестный аргумент даёт ошибку.
- Глобальная клавиша назначается через `bind_keymaps(nil, ...)` рядом с `pr.create_map`.
- В PR Info и во float клавиша добавляется в `comment_action_specs()` отдельной записью, а не в `COMMENT_ACTIONS`: её значение лежит в `M.config.browse`, а не в `M.config.comments`. Справка `?` показывает её автоматически.
- В diff-буфере `gx` не переопределяется. Правая сторона — настоящий файл рабочего дерева, где `gx` нужен для ссылок в коде. Там работает глобальная `<leader>rb`.
- В Telescope `attach_mappings` назначает `picker_map` в режиме `i` и `float_map` в режиме `n`. Обработчик берёт PR выбранной записи и не закрывает список, как и `<C-x>`.
- В запасном буфере списка `float_map` назначается рядом с `<CR>` и `i` для `pr_at_cursor()`.

### D5. Открытие через `vim.ui.open`

`browse.open(url)` вызывает `vim.ui.open(url)` (Neovim ≥ 0.10). Если функция вернула ошибку, показывается `bb_pr: cannot open <url>: <err>`. Открытие Jira-тикета и вложений переводится на `browse.open`, после чего прямых вызовов `xdg-open` в плагине не остаётся.

Альтернатива — оставить `xdg-open`. Её отвергли: `vim.ui.open` учитывает macOS, WSL и `$BROWSER`, а ошибку сейчас некуда вернуть, потому что `jobstart` с `detach` её не сообщает.

## Risks / Trade-offs

- [Формы `?commentId=` для комментариев к файлам и `?t=`/`?f=` не проверены на 8.9.7] → задача 1.1 проверяет их вручную до реализации; замены описаны в D2.
- [`<C-o>` в insert-режиме Telescope перекрывает стандартное действие Vim «одна команда normal-режима»] → в prompt-буфере Telescope оно почти не используется; клавиша настраивается.
- [Сразу после открытия вкладки `diff_base` ещё не задан] → открывается файл без строки с сообщением; повторный вызов через секунду даёт строку.
- [`links.self` отсутствует у PR (например, ответ старого формата)] → `pr_url` возвращает `nil`, и показывается предупреждение «PR has no Bitbucket link».
- [Предел top-level `local` в `init.lua`] → новый код живёт в модуле и в поле `M.browse`; проверка загрузки модуля входит в задачи.
