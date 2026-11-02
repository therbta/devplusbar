# Dev+ Bar Reverse-Engineering Map

## Top-Level Layout

- `Sources/`: main macOS app code (Swift, AppKit + SwiftUI)
- `Tests/`: unit tests for query building, parsing, filtering, auth flow, storage, and update logic
- `site`: static marketing/privacy site and assets
- `assets`: screenshots/icons used by docs/site
- `Tools`: build-time generators (`makeicon.swift`, `makeog.swift`)
- `Packaging`: release packaging metadata (MAS entitlements, Homebrew cask template)
- `docs/release-notes`: release notes used in publish flow
- `Makefile`: build, test, package, notarize, and release orchestration

## Runtime Entry Points

- `main.swift` under `Sources/`
  - Default: launches the menu bar app through `NSApplication` + `AppDelegate`
  - Hidden mode: `--render-panel <path>` renders a panel image and exits
  - Hidden mode: `--render-screens <dir>` renders App Store screenshots and exits

## Core Runtime Modules

- App lifecycle and UI shell
  - `AppDelegate.swift`: startup wiring, refresh loops, panel/toast actions, settings/welcome wiring
  - `StatusPanel.swift`: custom arrow panel attached to menu bar item
  - `PanelView.swift`: main interactive panel (tabs, rows, keyboard handling)
  - `PanelInput.swift`: panel data/state input model
  - `BarToast.swift`: compact notifications in app UI

- Auth and token handling
  - `Auth.swift`: selects auth source and sign-in state resolution
  - `DeviceFlowAuth.swift`: GitHub device-flow auth sequence
  - `TokenProvider.swift`: token lookup strategy (including CLI token path)
  - `Keychain.swift`: secure token persistence in macOS keychain

- Data fetch and transformation
  - `GitHubClient.swift`: GraphQL transport and response handling
  - `Query.swift`: query string construction for sections/tabs
  - `ResponseParser.swift`: GraphQL JSON -> app domain models
  - `Filtering.swift`: applies visibility/filter rules and section shaping
  - `Models.swift`: app domain model types

- Persistence and state
  - `Settings.swift`: user-configurable behavior flags/types
  - `SettingsStore.swift`: defaults-backed settings persistence
  - `SeenStore.swift`: tracks read/unread items
  - `RefreshGate.swift`: serializes refreshes and preserves queued intent

- UX support and system integration
  - `WelcomeWindow.swift`: sign-in/welcome surface
  - `SettingsWindow.swift`: preferences surface
  - `Notifier.swift`: local notifications integration
  - `LaunchAtLogin.swift`: startup registration on macOS
  - `UpdateChecker.swift`: release checks
  - `AuthorAvatars.swift`, `Avatar.swift`: avatar loading/cache
  - `Formatting.swift`: display-time text/date formatting helpers
  - `PanelPreview.swift`, `ScreenshotRenderer.swift`: deterministic visual render paths

## Test Coverage Map

- Auth flow: `DeviceFlowAuthTests.swift`, `TokenProviderTests.swift`, `KeychainTests.swift`
- Query + parser: `QueryTests.swift`, `ResponseParserTests.swift`, fixtures under `Tests/.../Fixtures`
- Filtering + formatting: `FilteringTests.swift`, `FormattingTests.swift`
- State + storage: `SeenStoreTests.swift`, `SettingsStoreTests.swift`, `RefreshGateTests.swift`
- Networking/update behavior: `GitHubClientTests.swift`, `UpdateCheckerTests.swift`

## Reverse-Engineering Order (Suggested)

1. Start with `main.swift` and `AppDelegate.swift` to map startup and event flow.
2. Follow refresh path: `RefreshGate.swift` -> `GitHubClient.swift` -> `Query.swift` -> `ResponseParser.swift` -> `Filtering.swift`.
3. Inspect UI state rendering in `PanelInput.swift` + `PanelView.swift` + `StatusPanel.swift`.
4. Review auth branch in `Auth.swift` + `DeviceFlowAuth.swift` + `TokenProvider.swift` + `Keychain.swift`.
5. Confirm behavior with tests and renderer modes (`--render-panel`, `--render-screens`).

## Sequence Diagram: Auth Flow

```mermaid
sequenceDiagram
  participant User
  participant Welcome as WelcomeWindow
  participant Auth as Auth
  participant Device as DeviceFlowAuth
  participant GitHub as GitHub OAuth
  participant Keychain as Keychain
  participant App as AppDelegate

  User->>Welcome: Click Sign In
  Welcome->>Auth: start sign-in
  Auth->>Device: request device code
  Device->>GitHub: POST device/code
  GitHub-->>Device: device_code + user_code + verification_uri
  Device-->>Welcome: show verification URI and code
  User->>GitHub: Approve device login
  Device->>GitHub: poll token endpoint
  GitHub-->>Device: access_token
  Device-->>Auth: token
  Auth->>Keychain: save token
  Auth-->>App: signed-in state changed
  App->>App: trigger refresh + open panel
```

## Sequence Diagram: Refresh/Data Flow

```mermaid
sequenceDiagram
  participant Timer as Refresh Timer
  participant Gate as RefreshGate
  participant App as AppDelegate
  participant Query as Query
  participant Client as GitHubClient
  participant API as GitHub GraphQL API
  participant Parser as ResponseParser
  participant Filter as Filtering
  participant Seen as SeenStore
  participant Panel as PanelView/StatusPanel

  Timer->>Gate: request refresh
  Gate->>App: allow single active refresh
  App->>Query: build section queries
  Query-->>App: GraphQL search/query payload
  App->>Client: fetch(payload, token)
  Client->>API: POST /graphql
  API-->>Client: JSON response
  Client-->>App: raw response data
  App->>Parser: parse JSON -> Snapshot
  Parser-->>App: snapshot
  App->>Filter: apply visibility/grouping rules
  Filter-->>App: menu sections
  App->>Seen: merge read/unread state
  Seen-->>App: seen flags
  App->>Panel: publish PanelInput
  Panel-->>User: updated tabs, rows, counters
```