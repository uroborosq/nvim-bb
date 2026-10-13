# Spec Delta

## MODIFIED Requirements

### Requirement: Строка статистики в PR Info
Окно PR Info для PR открытой вкладки этого PR SHALL показывать в шапке, сразу после строки `Opened:`, строку `Changes: <N> files, +<added> -<deleted>`. Строка SHALL показываться и для своих, и для чужих PR.

#### Scenario: PR с изменениями в нескольких файлах
- **WHEN** PR изменяет 14 файлов, в которых добавлено 345 и удалено 67 строк, и пользователь открывает PR Info во вкладке этого PR
- **THEN** в шапке PR Info после строки `Opened:` выводится `Changes: 14 files, +345 -67`

#### Scenario: Конфликт слияния
- **WHEN** у PR конфликт с target-веткой, и пользователь открывает PR Info во вкладке PR
- **THEN** строка `Changes:` стоит после `Opened:`, а строка `Merge: CONFLICT ...` — после неё

#### Scenario: Свой PR
- **WHEN** пользователь открывает PR Info во вкладке PR, автором которого является он сам
- **THEN** строка `Changes:` выводится так же, как для чужого PR
