# Proposal

## Why

В PR Info не видно объёма PR: чтобы понять, сколько строк добавлено и удалено, приходится открывать Bitbucket или считать вручную. Bitbucket Server 8.9.7 готовой статистики не отдаёт: эндпоинта `diff-stats-summary` нет (404), `/changes` не содержит числа строк, а `/diff` для большого PR тяжёлый и обрезается сервером. Вкладка PR уже знает merge base и вершину ветки PR, поэтому статистику можно получить локально тем же вызовом git, который строит список файлов PR.

## What Changes

- В шапке PR Info, сразу после строки `Opened:`, появляется строка `Changes: <N> files, +<added> -<deleted>`.
- Числа считаются по diff PR в Bitbucket: от merge base до вершины ветки PR, с распознаванием переименований, без игнорирования пробельных изменений.
- Бинарные файлы входят в число файлов, но не в число строк.
- Строка показывается только в PR Info вкладки самого PR. В PR Info, открытом из списка для PR без своей вкладки, строки нет.
- Пока статистика вычисляется или если git завершился ошибкой, строки нет. Когда статистика получена, открытое окно PR Info перерисовывается.
- Список файлов PR (`with_pr_changed_files`) строится через `git diff --numstat` вместо `--name-status`. Его потребители (prefetch комментируемых файлов, «Files viewed», `:BBPRSinceLastView`) получают тот же список, что и раньше.

## Capabilities

### New Capabilities

- `pr-diff-stats`: сводная статистика diff PR (число файлов, добавленных и удалённых строк) и её отображение в PR Info.

### Modified Capabilities

(нет)

## Impact

- `lua/bb_pr/init.lua`:
  - `with_pr_changed_files` — `--numstat` вместо `--name-status`, сумма строк;
  - `build_pr_info_content` — строка `Changes:`;
  - `open_diffview` — запуск вычисления после `set_current_tab_diff_base`.

  В `init.lua` около 198 локальных переменных верхнего уровня при пределе Lua в 200, поэтому новых top-level `local` не добавляется.
- `README.md`: описание строки `Changes:` в PR Info.
- Запросов к Bitbucket и изменений в Go CLI нет.
