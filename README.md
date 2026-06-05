# CalendarBar

Menu bar-приложение для macOS с синхронизацией Exchange-календаря через **ActiveSync** (протокол мобильной синхронизации Exchange, тот же что у Outlook/iPhone).

Приложение работает в фоне (`LSUIElement`) — иконка в строке меню, без Dock.

## Возможности

- **Menu bar** — количество оставшихся встреч сегодня и время следующей (`3 · 16:00`)
- **Таймлайн дня** — сетка 00:00–24:00 в стиле «Календаря», навигация по дням
- **Детали события** — клик по событию расширяет окно вправо с полной информацией (место, организатор, участники, описание)
- **Текущее время** — красная линия с меткой `HH:mm` на сегодняшнем дне
- **Автоскролл** — при открытии прокрутка к ближайшей предстоящей встрече
- **Уведомления macOS** — напоминание за 5/10/15/30/60 мин до начала (системные, без дублирующей плашки)
- **Автосинхронизация** — каждые 5 минут
- **Повторяющиеся события** — развёртывание recurrence на клиенте
- **Ссылки** — кликабельные URL в месте проведения и описании

## Требования

- macOS 14.0+
- Xcode 15+
- Доступ к Exchange-серверу с включённым ActiveSync (`/Microsoft-Server-ActiveSync`)

## Сборка и запуск (Debug)

```bash
cd CalendarBar
xcodebuild -scheme CalendarBar -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/CalendarBar.app
```

Или откройте `CalendarBar.xcodeproj` в Xcode и нажмите **Run** (⌘R).

## Прод-сборка (Release)

### Через командную строку

```bash
cd CalendarBar
xcodebuild -scheme CalendarBar \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  build
```

Готовое приложение:

```
build/DerivedData/Build/Products/Release/CalendarBar.app
```

Установка в «Программы»:

```bash
cp -R build/DerivedData/Build/Products/Release/CalendarBar.app /Applications/
```

### Через Xcode

1. Откройте `CalendarBar.xcodeproj`
2. Выберите схему **CalendarBar** и конфигурацию **Release** (Product → Scheme → Edit Scheme → Run/Archive → Build Configuration → Release)
3. **Signing & Capabilities** — укажите свою **Team** и при необходимости измените `Bundle Identifier` (`com.organization.CalendarBar`)
4. **Product → Archive** — для архива и экспорта
5. В Organizer: **Distribute App → Copy App** (или Developer ID для распространения вне App Store)

### Заметки по Release

| Параметр | Значение |
|----------|----------|
| Bundle ID | `com.organization.CalendarBar` |
| Версия | `0.0.1` (MARKETING_VERSION) |
| Hardened Runtime | включён |
| App Sandbox | выключен (прямой сетевой доступ к корпоративному Exchange) |
| Подпись | Automatic (нужна Team в Xcode) |

Для распространения .app вне Mac App Store обычно нужны **Developer ID** + **notarization** (Apple). Для личного использования достаточно Release-сборки с вашей подписью и `xattr -cr CalendarBar.app` при первом запуске, если macOS блокирует неподписанное приложение.

## Авторизация

При первом запуске заполните форму:

| Поле | Пример |
|------|--------|
| Email | user@organization.com |
| Сервер | mail.organization.com |
| Домен | ORGANIZATION |
| Имя пользователя | u_username |
| Пароль | •••••••• |

Email, сервер, домен и имя пользователя сохраняются в UserDefaults. Пароль — только в Keychain.

Логин для ActiveSync: `DOMAIN\username` (если домен указан) или email.

## Как это работает

Приложение подключается к Exchange через **ActiveSync** (`/Microsoft-Server-ActiveSync`):

- WBXML-кодек и парсер ответов сервера
- Команды FolderSync / Sync для календаря
- DeviceId в стиле iPhone (`Appl…`) для совместимости с корпоративными политиками
- Развёртывание повторяющихся событий на клиенте (`RecurrenceExpander`)
- TLS с поддержкой корпоративных сертификатов

Это обходит нестабильную синхронизацию встроенного «Календаря» macOS в некоторых корпоративных конфигурациях Exchange.

## Настройки

Меню ⚙️ в нижней панели:

- **Уведомление за** — 5 / 10 / 15 / 30 / 60 мин
- **Разрешить уведомления** — запрос прав + ссылка на настройки macOS
- **Стиль «Предупреждения»** — чтобы уведомление не исчезало само (режим Alerts вместо Banners)
- **О приложении**, **Выйти**, **Закрыть CalendarBar**

Кнопка 🔄 — ручное обновление. Стрелки ◀ ▶ — переключение дней.

Внизу отображается **«Следующая встреча в HH:mm»** — только для ещё не начавшихся встреч (текущая пропускается).

## Структура проекта

```
CalendarBar/
├── CalendarBarApp.swift      # Точка входа
├── StatusBarManager.swift    # NSStatusItem + NSPopover
├── Views/                    # SwiftUI (таймлайн, авторизация, детали)
├── Services/
│   ├── ActiveSync/           # Клиент, WBXML, парсер, recurrence
│   ├── CalendarSyncService.swift
│   ├── NotificationService.swift
│   └── SettingsStore.swift
└── Models/
```
