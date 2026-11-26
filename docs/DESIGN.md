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
- **One column.** Content is at most 680 pt wide, centred in the pane beside the sidebar (not in the window), with at least 64 pt either side. Every screen in the pane uses `EditorLayout`. Table-like screens (All pages) may widen to `directoryWidth` (820 pt) through the same function; nothing computes its own layout.
- **Content starts 58 pt below the window top.**
- **Bullets inside the column.** A block row is a 14 pt disclosure, an 18 pt bullet column, an 8 pt gap and the text. Only the hover-only disclosure arrow sits in the margin; the bullet column starts on the column edge, so bullets line up under the first letter of the title and nesting steps inward 24 pt.
- **Window controls.** Title-bar buttons sit 78 pt from the left and are centred on the traffic lights at y = 16. Anything always available (sidebar toggle, theme) lives there, not inside the sidebar.

## Alignment

- **One left edge per column.** In the pane: page title, subtitle, top-level bullets, dividers, day headings, reference cards and list-row content all start on the column edge. In the sidebar: every label starts at x 44 (row inset 10, icon 15, gap 9), and section labels start on the icon column.
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

- **Radii:** 6 for rows and small controls, 7 for fields and list rows, 8 for cards.
- **Icons:** drawn with SwiftUI shapes in `Icons.swift`, 14–15 pt frames, strokes of 1.1–1.25 pt, coloured by the foreground. No SF Symbols, so icons match Inter and both themes.
- **Hit targets:** at least 24 pt; rows and toolbar buttons 28 pt.
- **Markers in text:** formatting markers (`**`, `*`, `~~`, `==`, backticks) are hidden outside editing and shown dimmed while editing. Page-link brackets currently stay visible.

## Interaction

- **One selection.** The sidebar highlights at most one item for the current view (`sidebarDestination`). A page never appears in two sidebar lists.
- **Favorites are pinned.** They never scroll with Recent.
- **Shortcut hints appear on hover**, not permanently.
- **Destructive actions confirm** wherever they appear and stay undoable with ⌘Z. The same action behaves the same everywhere.
- **Editing behaviour lives in `pith-core`**; views only display it (see AGENTS.md).

## Checking a change

1. `swift test`. `DesignRulesTests` fails on off-scale text sizes, colours outside `Theme`, and system symbols or system fonts.
2. Render the key screens in both themes and look at the edges:

   ```sh
   cd apps/macos && PITH_DB=/tmp/pith-play.db PITH_SNAPSHOT=/tmp/pith-shots swift run PithMacApp
   ```

   At 1280 × 820 pt the captures are 2 px per pt. Check that the new element shares the column's left and right edges, sits on the 4 pt grid, and looks right in light and dark.
3. If a rule had to bend, change this file and the token in the same change.
