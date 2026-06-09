# CalendarBar

Menu bar-приложение для macOS с Exchange-календарём и почтой через **ActiveSync**. Приложение работает в фоне (`LSUIElement`): без Dock, с отдельными иконками календаря и почты в строке меню.

## Возможности

### Календарь

- **Menu bar summary** — количество оставшихся встреч сегодня и время следующей (`3 · 16:00`)
- **Таймлайн дня** — сетка 00:00–24:00, навигация по дням и кнопка «Сегодня»
- **Детали события** — боковая панель с местом, организатором, участниками и описанием
- **Пересекающиеся встречи** — компактная раскладка колонками; при 4+ пересечениях показывается агрегированный блок
- **Текущее время** — красная линия с меткой `HH:mm`
- **Автоскролл** — при открытии прокрутка к ближайшей встрече
- **Повторяющиеся события** — развёртывание recurrence на клиенте
- **Действия со встречей** — принять, отклонить, «под вопросом», удалить из календаря
- **Ссылки** — кликабельные URL в месте проведения и описании
- **Уведомления macOS** — напоминания за 5/10/15/30/60 минут до начала

### Почта

- **Отдельная иконка в menu bar** — конверт со счётчиком непрочитанных
- **Входящие / Отправленные / Черновики / Корзина** — переключатели папок в почтовом popover
- **Треды писем** — группировка по `ConversationId`/теме
- **Чтение письма** — список тредов слева, текст письма справа
- **Ручное прочтение** — кнопка `Прочитано` / `Непрочитано` синхронизирует состояние с Exchange/Outlook
- **Ответы** — `Ответить`, `Ответить всем`, `Переслать`, новое письмо
- **Вложения** — отображение и скачивание вложений
- **Уведомления о новой почте** — только для свежих писем после запуска; старые непрочитанные при старте не пушатся
- **Отключение почты** — toggle `Почта` в календарных настройках полностью убирает конверт и останавливает почтовую синхронизацию

## Требования

- macOS 14.0+
- Xcode 15+
- Доступ к Exchange-серверу с включённым ActiveSync (`/Microsoft-Server-ActiveSync`)

## Сборка и запуск

Debug:

```bash
cd CalendarBar
xcodebuild -scheme CalendarBar -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/CalendarBar.app
```

Release:

```bash
cd CalendarBar
xcodebuild -scheme CalendarBar -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/CalendarBar.app
```

Или откройте `CalendarBar.xcodeproj` в Xcode и нажмите **Run** (⌘R).

Готовое Release-приложение:

```text
CalendarBar/build/DerivedData/Build/Products/Release/CalendarBar.app
```

Установка в «Программы»:

```bash
cp -R CalendarBar/build/DerivedData/Build/Products/Release/CalendarBar.app /Applications/
```

## Release и подпись

| Параметр | Значение |
|----------|----------|
| Bundle ID | `com.organization.CalendarBar` |
| Версия | `0.0.1` |
| Hardened Runtime | включён |
| App Sandbox | выключен |
| Подпись | Automatic, нужна Team в Xcode |

Для распространения вне Mac App Store обычно нужны **Developer ID** и **notarization**. Для личного использования достаточно локальной Release-сборки; если macOS блокирует приложение, можно снять quarantine:

```bash
xattr -cr /Applications/CalendarBar.app
```

## Авторизация

При первом запуске заполните форму:

| Поле | Пример |
|------|--------|
| Email | `user@organization.com` |
| Сервер | `mail.organization.com` |
| Домен | `ORGANIZATION` |
| Имя пользователя | `u_username` |
| Пароль | `••••••••` |

Email, сервер, домен и имя пользователя сохраняются в `UserDefaults`. Пароль хранится только в Keychain.

Логин для ActiveSync: `DOMAIN\username`, если домен указан, иначе email.

## Как это работает

Приложение подключается к Exchange через **ActiveSync**:

- `OPTIONS` / endpoint discovery
- `Provision` для policy key
- `FolderSync` для поиска Calendar, Inbox, Sent, Drafts, Trash
- `Sync` для календаря, почтовых папок и read/unread state
- `ItemOperations Fetch` для полного тела письма и вложений
- `SendMail`, `SmartReply`, `SmartForward` для отправки и ответов
- `MeetingResponse` для принятия/отклонения встреч
- собственный WBXML encode/decode слой
- `DeviceId` и `User-Agent` в стиле iPhone для совместимости с корпоративными политиками

Синхронизация работает периодически, по умолчанию раз в 5 минут. Почтовые уведомления появляются только после baseline-синхронизации входящих, поэтому старые непрочитанные письма при запуске не создают пачку уведомлений.

## Настройки

Меню ⚙️ в календарном popover:

- **Уведомление за** — 5 / 10 / 15 / 30 / 60 минут
- **Разрешить уведомления…** — запрос прав macOS
- **Стиль «Предупреждения» в macOS…** — переход в настройки уведомлений
- **Запускать при входе** — login item через `SMAppService`
- **Почта** — включает/выключает почтовый виджет и почтовую синхронизацию
- **О приложении**
- **Выйти из аккаунта**
- **Закрыть CalendarBar**

Кнопка 🔄 в календаре и почте запускает ручную синхронизацию.

## Локальные данные

- Настройки аккаунта: `~/Library/Preferences/com.organization.CalendarBar.plist`
- Пароль: Keychain item `exchange-password` / service `com.organization.CalendarBar`
- ActiveSync sync keys: `UserDefaults`

## Структура проекта

```text
CalendarBar/
├── CalendarBarApp.swift
├── StatusBarManager.swift
├── MailStatusBarManager.swift
├── PopoverMetrics.swift
├── Models/
│   ├── AccountSettings.swift
│   ├── CalendarEvent.swift
│   └── MailMessage.swift
├── Services/
│   ├── ActiveSync/
│   │   ├── ActiveSyncClient.swift
│   │   ├── ActiveSyncParser.swift
│   │   ├── ActiveSyncSyncKeyStore.swift
│   │   ├── RecurrenceExpander.swift
│   │   └── WBXMLCodec.swift
│   ├── CalendarSyncService.swift
│   ├── MailSyncService.swift
│   ├── NotificationService.swift
│   ├── SettingsStore.swift
│   └── LaunchAtLoginService.swift
└── Views/
    ├── EventsListView.swift
    ├── DayTimelineView.swift
    ├── EventDetailView.swift
    ├── MailListView.swift
    ├── MailDetailView.swift
    ├── MailComposeView.swift
    └── AuthView.swift
```
