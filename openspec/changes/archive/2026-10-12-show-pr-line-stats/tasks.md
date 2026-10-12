# Tasks

## 1. Разбор `numstat`

- [x] 1.1 Создать модуль `lua/bb_pr/diffstat.lua` с чистой функцией `parse_numstat(out)` → `files, totals` (D1, D2):
  - `files` — `{ from_path, path, added, deleted }[]`, у бинарного файла `added`/`deleted` равны nil;
  - `totals` — `{ files, added, deleted }`, бинарные файлы входят только в `files`.

  Проверка: headless-скрипт `nvim --headless -u NONE` покрывает пустой вывод, обычный файл, переименование (пустое поле пути и два пути), путь с пробелом, бинарный файл и удалённый файл (`from_path == path`).

## 2. Список файлов PR со статистикой

- [x] 2.1 Перевести `with_pr_changed_files` на `git diff --numstat -z -M <base> <source>` с разбором через `parse_numstat`. Сохранять `info.changed_files` и `info.line_stats`. Подключить модуль без новой top-level `local` (D2). Проверка:
  - headless-тест на временном репозитории с изменённым, добавленным, удалённым, переименованным и бинарным файлом;
  - `changed_files` совпадает по `from_path`/`path` с результатом прежнего разбора `--name-status`;
  - `line_stats` совпадает с `git diff --shortstat -M <base> <source>`.
- [x] 2.2 Добавить очередь ожидающих в `with_pr_changed_files` (D3). Проверка: headless-тест с двумя вызовами подряд до завершения git — запускается один процесс (например, через подмену `vim.system` со счётчиком), оба `cb` получают один и тот же список.

## 3. Строка в PR Info

- [x] 3.1 В `build_pr_info_content` выводить `Changes: <N> files, +<added> -<deleted>` сразу после `Opened:` и перед `Merge: CONFLICT`, только если PR Info относится к PR вкладки и `ts.diff_base.line_stats` задан (D5). Проверка: в `nvim --headless` с подставленным `tab_state` строка выводится для PR вкладки, отсутствует для другого PR и при `line_stats == nil`, а при конфликте стоит перед строкой `Merge:`.
- [x] 3.2 В `open_diffview` после `set_current_tab_diff_base` запускать `with_pr_changed_files` и по результату вызывать `seen_view.refresh_info(tabpage)`, если вкладка жива и `diff_base` тот же объект (D4, D6). Проверка: `luajit -bl lua/bb_pr/init.lua > /dev/null` или `nvim --headless -c 'lua require("bb_pr")' -c q` загружает модуль без ошибки (предел локальных переменных не превышен).
- [x] 3.3 Описать строку `Changes:` в разделе PR Info файла `README.md`: что считается (merge base..вершина ветки PR, как в Bitbucket), что строка есть только во вкладке самого PR и что `+/-` в панели Diffview считаются иначе. Проверка: описание соответствует `specs/pr-diff-stats/spec.md`.

## 4. Ручная проверка

- [ ] 4.1 Открыть чужой и свой PR, сравнить строку `Changes:` с diff PR в Bitbucket и с `git diff --shortstat -M $(git merge-base origin/<from> origin/<to>) origin/<from>`. Убедиться, что строка появляется в уже открытом PR Info без смены позиции курсора, что её нет в PR Info другого PR, открытом из списка, и что «Files viewed» и prefetch комментируемых файлов работают как раньше. Для PR с сотнями файлов сравнить время появления «Files viewed» с прежним (`--name-status`).

## Workflow follow-up

- Не коммитить до проверки пользователем (CLAUDE.md).
- Архивировать изменение после ручной проверки.
