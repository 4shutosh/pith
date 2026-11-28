# Design standards

Rules for the native apps' interface, written down so new screens don't drift. Values live in code as tokens; this file says what they mean and how to use them. `DesignRulesTests` enforces the mechanical rules on every `swift test`.

## Sources of truth

| What | Where |
| :--- | :--- |
| Colours, both themes | `Theme` in `PithMacCore/Theme.swift` |
| Text sizes | `TypeScale` in `PithMacCore/Theme.swift` |
| Fonts | `Typography` (Inter for interface and blocks, JetBrains Mono for code, bundled) |
| Window and column layout | `EditorLayout` in `PithMacCore/EditorLayout.swift` |
| Sidebar geometry | `SidebarMetrics` in `PithMacApp/Sidebar.swift` |
| Block row geometry | `OutlineRow` constants in `PithMacApp/OutlinerView.swift` |
| Icons | drawn shapes in `PithMacApp/Icons.swift` |

A new value goes into one of these first, then gets used. Never write a raw number or colour that duplicates or nearly duplicates a token.

## Layout

- **Three zones.** A 38 pt title-bar band, a 216 pt sidebar with a 1 pt divider, and the editor pane.
- **One column.** Content is at most 680 pt wide, centred in the pane beside the sidebar (not in the window). Side margins are 64 pt and shrink to 24 pt as the pane narrows; the column shrinks with them. The window can be as small as 360 × 400 pt so it fits laptop grids. The sidebar docks only while the pane keeps a 320 pt column with 24 pt margins (windows ≥ 585 pt); narrower, the sidebar never docks: hovering the sidebar toggle slides it over the content (with a shadow) until the pointer leaves, and clicking the toggle or ⌘\\ pins it open until a click outside or opening a page. The docked open/closed choice is kept for when the window is wide again.
- **Window chrome row.** The traffic lights and window-level controls (sidebar toggle, theme) share one row whose height is twice the traffic lights' measured centre, so they line up. Content never moves vertically when the sidebar opens or closes: every screen starts `EditorLayout.contentTop` below the window top. With the sidebar docked the sidebar paints its own column under the row and the row is clear over the editor. With the sidebar hidden or the window narrow the row fills with the surface colour (cross-fading with the drawer), so scrolled content passes under it instead of behind the controls. The row sits above the content in z-order and is native window chrome across its full width: drag moves the window, double-click follows the system's title-bar setting (zoom by default). Future tabs go in this row.
- **Content starts 58 pt below the window top.**
- **Bullets inside the column.** A block row is a 14 pt disclosure, an 18 pt bullet column, an 8 pt gap and the text. Only the hover-only disclosure arrow sits in the margin; the bullet column starts on the column edge, so bullets line up under the first letter of the title and nesting steps inward 24 pt.
- **Window controls.** Title-bar buttons sit 78 pt from the left and are centred on the traffic lights at y = 16. Anything always available (sidebar toggle, theme) lives there, not inside the sidebar.

## Alignment

- **One left edge per column.** In the pane: page title, subtitle, top-level bullets, dividers, day headings, reference cards and list-row content all start on the column edge. In the sidebar: every row's first element starts at x 20 (outer inset 10, row inset 10). For Journals and All pages that is the icon, with the label at x 44; for section headers and page names it is the text. Section-header icons sit at the right end of their row. Never leave an empty icon gutter in front of text.
- **Backgrounds bleed; content doesn't move.** Hover, selection and list-row fills extend past the edge (6 pt for blocks, 12 pt for list rows) so the text inside stays on the shared edge.
- **Right edges match too.** Header actions, counts and the end of dividers line up with the column's right edge.
- **Vertical centres.** Icons, bullets and controls are centred on the line they belong to. Check them against text, not against frames.

## Spacing

- Layout spacing uses the 4 pt grid: 4, 8, 12, 16, 24, 28, 40, 44, 58, 64. The old 6 pt steps (subtitle gap, label bottom) are allowed but don't add new ones.
- Optical sizes inside a component (icon 15, disclosure 14, bullet column 18, icon gap 9, row spacing 1) are fine as long as the edges they produce line up with neighbours.
- Use a stack's `spacing` rather than one-off padding on siblings.
- Repeated rows of one kind share one height: sidebar rows 28, list rows 38, block lines 24 with 4 above and below.

## Type

| Step | Size | Use |
| :--- | :--- | :--- |
| `pageTitle` | 28 semibold, −0.4 tracking | Page and screen titles |
| `sectionTitle` | 22 semibold | Day headings in the stream |
| `searchInput` | 17 | The search field |
| `block` | 15 on a 24 pt line | Block text |
| `listRow` | 14 | List rows, search results, reference cards |
| `ui` | 13 | Sidebar rows, subtitles, menus |
| `meta` | 12 | Meta text, chips, hints |
| `label` | 11 medium | Section labels, shortcut hints |
| `code` | 13.5 mono | Code next to block text |

No other sizes. Weight carries emphasis (regular, medium, semibold); size carries hierarchy.

## Colour

- Use `Theme` tokens only. Every token has a dark and a light value and must look right in both; check both before shipping.
- One accent (amber) for links, the caret and in-progress state. Tags use their own green so they read apart from links. Done uses the done green. Don't use the accent for decoration.
- Text has four strengths: strong (titles, selected), primary (blocks), secondary (sidebar labels), tertiary (meta, hints). Pick by role, not by look.

## Components

Screens are built from `PithMacApp/Components.swift` and `FilterChips.swift`; a screen never re-implements one of these. `DesignRulesTests` fails if a screen declares its own grid, keycap or screen title.

| Need | Component | Narrow behaviour |
| :--- | :--- | :--- |
| Screen title, subtitle, trailing action | `ScreenHeader` (`ScreenTitle` alone for custom headers) | Title never wraps; the trailing action drops below the title |
| Filter / search input | `SearchField` | Fills the width it is given |
| Filter tabs | `ChipRow` + `FilterChip` | Labels never truncate; the row scrolls with an edge fade |
| Keys | `Keycap`, `KeycapRow`, `KeyHint` | Fixed size |
| Section heading | `SectionLabel` | — |
| Grouped panel | `Card` (title, count, content padding) | — |
| Card grids | `AdaptiveGrid` (`AdaptiveColumns` decides the count) | Two columns only when each gets its minimum width |
| Setting with a control | `SettingRow` + `SegmentedGroup` | Control moves under its label below 520 pt; controls never truncate |
| Secondary action | `SecondaryButton` | Fixed size |

Width-driven decisions (`EditorLayout`, `AdaptiveColumns`, `PageDirectoryLayout`, `JournalCalendarLayout`) are pure functions in `PithMacCore` with tests; views only read them. Check every screen at 1280, 520 and 380 pt wide with snapshot mode before calling UI work done.

- **Radii:** 6 for rows and small controls, 7 for fields and list rows, 8 for cards.
- **Icons mark landmarks and state, never repeating content.** Fixed navigation items and section headers get an icon (Journals, All pages, Favorites, Recent), as do state (task marks, the favorite star in All pages), function (the collapse arrow, the window-control toggles) and a field's identity (the search magnifier). Repeating rows such as page lists have none, except where one list mixes kinds: each ⌘K result marks its kind (page, journal, block bullet, command, more, create) in one 16 pt icon column aligned to the row's first line. Icons are drawn with SwiftUI shapes in `Icons.swift`, 14–15 pt frames, strokes of 1.1–1.25 pt, coloured by the foreground; no SF Symbols.
- **Hit targets:** at least 24 pt; rows and toolbar buttons 28 pt.
- **Markers in text:** formatting markers (`**`, `*`, `~~`, `==`, backticks) are hidden outside editing and shown dimmed while editing. Page-link brackets currently stay visible.
- **Journal calendar.** All pages → Journals is the journal history: every month from the first written day to today in one scroll, newest first, Monday-start weeks with blanks (never neighbouring months' days). A written day's cell is tinted with `Theme.journalInk` by how much was written (1–2, 3–6, 7–15, 16+ blocks); unwritten days are bare numerals, future days dimmer. Today carries a short accent underline; the selected day a 1.5 pt `textStrong` ring. Keyboard and hover share one selection, and the selected day is previewed beside the months when both fit (`JournalCalendarLayout`), above them when narrower. Click or ↵ opens the day; an unwritten day opens as a pending journal, created only when text is written. Arrows move by day and week, ⇞/⇟ by month, ⌥←/⌥→ jump between written days, T returns to today.

## Motion

- Use the `Motion` tokens (`hover`, `fast`, `morph`, `drawer`, `pop`); never write a duration or spring inline.
- Motion is short and quiet: state feedback under about 0.2 s, no decorative loops.
- Every token returns no animation when the system's Reduce Motion setting is on, so animations respect it automatically.

## Keyboard first

- **Every action has a keyboard path.** It has a shortcut, or at least an entry in the ⌘K palette and the menu bar. On-screen controls are a second path, never the only one.
- **One action catalog.** Every user action is an `AppAction` (`PithMacCore/Shortcuts.swift`) with its title, keywords, category, scope and optional default shortcut. Add the case, its availability in `isAvailable`, and its effect in `perform` (or in `ActionPerformer` for window-level actions). The palette, the menus and the Keyboard shortcuts page all read the catalog, so they never need a separate list.
- **One dispatcher.** `ActionPerformer.perform(_:)` is the only path from an action to its effect, whether it came from a key, a menu or the palette.
- **Shortcuts are customisable and validated.** Bindings live in `ShortcutStore`; nothing hard-codes a shortcut. A binding needs ⌘, ⌃ or ⌥, can't take a system shortcut (Copy, Paste, Undo, Quit…), and conflicts are reported by scope. Keys are matched by their unshifted base character for the current layout, so ⇧⌘. means the full-stop key.
- **⌘K is one ranked list.** Pages, blocks and commands are ranked together by the core; a page contributes at most two blocks before a "N more in …" row (↵ expands it), commands show at most three unless filtered, and "Create page" is always last (⌘↵ from anywhere when no command is selected). An empty search shows recent pages, then commands. ⇥ / ⇧⇥ cycle the All, Pages, Blocks and Commands filters; a leading `>` searches commands only. The selected result is previewed beside the list when the palette is at least 760 pt wide (`PaletteLayout`), and folds under the selected row when narrower; key hints that don't fit are dropped, never wrapped. Rows are keyed by result id, never by position, and only the keyboard selection is highlighted.
- **⌘K is the one place to find and change any key.** The palette shows every command's current shortcut, and ⌘↵ rebinds the selected command in place. ⌘/ opens the palette scoped to shortcuts (a Shortcuts chip; ⌫ on an empty search leaves the scope), listing every action by category plus the built-in keys; ↵ rebinds there. Recording always goes through `ShortcutStore.record`, so the palette and the Keyboard shortcuts screen (⌥⌘/, for bulk customisation) accept and reject exactly the same keys.
- **Fixed keys are documented, not hidden.** Writing, selection, list and palette keys that can't be rebound are listed in `BuiltInKey.all`, which the Keyboard shortcuts page shows; update it when a fixed key changes.
- **No permanent toolbars on content.** Page headers show the title and subtitle only. Page actions live in the palette, the Page menu and right-click menus.
- **Destructive commands have no single-key shortcut** and always confirm.
- **One keyboard router.** Screens never install their own `NSEvent` monitors. A view that handles keys attaches `.keyScope(layer, whileEditingText:) { stroke in … }` and matches on named keys (`stroke.key`, `stroke.modifiers`), never raw key codes. Layers are `global` < `screen` < `overlay`; within a layer the newest scope goes first, a declined key falls through, and an open overlay is modal. Scopes skip keys while text is being edited unless they declare `whileEditingText: true`. Text-editing keys inside a block belong to the block's text view. App-wide shortcuts are dispatched by the router's global scope with live availability; the menus list the same actions for discovery, always enabled with catalog titles, because SwiftUI menus don't reliably refresh their enabled state.

## Interaction

- **One selection.** The sidebar highlights at most one item for the current view (`sidebarDestination`). A page never appears in two sidebar lists.
- **Unified scrollable sidebar sections.** Favorites, custom user sections, and Recent live inside one vertical scroll area with collapsible headers so no section can starve or clip another.
- **Shortcut hints appear on hover**, not permanently.
- **Destructive actions confirm** wherever they appear and stay undoable with ⌘Z. The same action behaves the same everywhere.
- **Pointers match affordance.** Clickable controls, rows, links, bullets, chevrons, and menus use `.cursor(.pointingHand)` (`CursorModifier.swift`, pure SwiftUI `onContinuousHover`; never an embedded AppKit view, which breaks SwiftUI hover on the row, and never `NSCursor.push`/`pop`); text inputs and block prose use `.iBeam`; non-interactive chrome and empty canvas keep `.arrow`.
- **Editing behaviour lives in `pith-core`**; views only display it (see AGENTS.md).

## Checking a change

1. `swift test`. `DesignRulesTests` fails on off-scale text sizes, colours outside `Theme`, and system symbols or system fonts.
2. Render the key screens in both themes and look at the edges:

   ```sh
   cd apps/macos && PITH_DB=/tmp/pith-play.db PITH_SNAPSHOT=/tmp/pith-shots swift run PithMacApp
   ```

   At 1280 × 820 pt the captures are 2 px per pt. Check that the new element shares the column's left and right edges, sits on the 4 pt grid, and looks right in light and dark.
3. If a rule had to bend, change this file and the token in the same change.

## State and performance

- **Views observe the narrowest model.** High-frequency state that only one surface shows lives in its own `ObservableObject` on the controller: palette search (`PaletteSearch`), find (`FindState`), All-pages counts (`PageDirectoryModel`). Typing in one of them never re-renders the outline or sidebar.
- **Publish only real changes.** Assign published values through `update(_:to:)`, which skips equal values.
- **Rows are `Equatable` over everything they display** (`.equatable()`), and read nothing else from the controller in `body`; computed inputs (find matches) are passed in.
- **Writes refresh through the change feed.** After any write, local or external, call `applyChanges()`; it patches stale rows and reloads only pages whose tree changed. Navigation calls `loadView()`. Never reload the page list on navigation.
- **Slow reads leave the main thread.** Search and block-ref completion run on the interactive `worker`, counts and bulk work on `background`, each through a `SingleFlight` so only the newest request runs. Never queue interactive work behind background work.
- **Measure at scale.** `PITH_PERF=1 swift test -c release --filter PerformanceTests` includes a 10k-page run; `PITH_SEED_PATH=<file>` writes a large graph for Instruments.

