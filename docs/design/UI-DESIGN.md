# UI Design

> The visual architecture of MachStruct — how the user interacts with structured documents.

## 1. Design Philosophy

- **Feels like a native Mac app.** Uses standard macOS chrome, keyboard shortcuts, and interaction patterns. Should feel like it belongs next to Xcode and Finder.
- **Speed is a feature.** No loading spinners for files under 50MB. Tree expansion is instant. Search results appear as you type.
- **Progressive disclosure.** The default view is clean and simple. Power features (JQ queries, raw editing, format conversion) are one click away but never in the way.

## 2. Window Layout

```
┌───────────────────────────────────────────────────────────────┐
│ ● ● ●   MachStruct — data.json (120 MB)        [search 🔍]  │
├─────────┬─────────────────────────────────────────────────────┤
│ SIDEBAR │                   MAIN AREA                        │
│         │                                                     │
│ ▼ root  │  ┌─────────────────────────────────────────────┐   │
│   ▶ name│  │              TREE VIEW                      │   │
│   ▼ items│  │  (or)       RAW TEXT VIEW                   │   │
│     ▶ [0]│  │  (or)       TABLE VIEW (for arrays)         │   │
│     ▶ [1]│  │                                             │   │
│     ▶ [2]│  └─────────────────────────────────────────────┘   │
│     ...  │                                                     │
│         │  ┌─────────────────────────────────────────────┐   │
│         │  │           DETAIL / EDITOR PANEL              │   │
│ ────────│  │  (collapsible, shows selected node)          │   │
│ STATS   │  └─────────────────────────────────────────────┘   │
│ 500K    │                                                     │
│ nodes   │  ┌─────────────────────────────────────────────┐   │
│ 120MB   │  │           STATUS BAR                         │   │
│ JSON    │  │  path: root.items[42].name  │  Ln 1,204     │   │
│         │  └─────────────────────────────────────────────┘   │
└─────────┴─────────────────────────────────────────────────────┘
```

## 3. Core Views

### 3.1 Tree View (Primary)

The heart of the app. A hierarchical outline of the document with lazy expansion.

**Implementation:** SwiftUI `List` with `OutlineGroup` providing:
- Automatic view recycling (only visible rows are in memory)
- On-demand child expansion (collapsed subtrees cost zero)
- Native selection, keyboard navigation, and accessibility

**Row Design:**
```
 ▶ "name"    :    "John Doe"                    str
   [expand]  [key]  [value, truncated if long]  [type badge]
```

- **Expand arrow:** Only shown for containers (objects/arrays). Clicking triggers lazy child loading.
- **Key:** Displayed in a muted color. For arrays, shows index: `[0]`, `[1]`, etc.
- **Value:** Truncated to fit the available width. Full value shown on hover tooltip or in the detail panel.
- **Type badge:** Small colored pill — `str` (green), `int` (blue), `num` (purple), `bool` (orange), `null` (gray), `obj` (teal), `arr` (indigo). Provides at-a-glance type information.
- **Child count:** For collapsed containers, show count: `{12 keys}` or `[3,401 items]`.

**Keyboard shortcuts:**
- Arrow keys: navigate up/down
- Right arrow: expand node
- Left arrow: collapse node (or jump to parent)
- Enter: start editing the selected value
- Cmd+F: focus search
- Space: toggle preview in detail panel

### 3.2 Raw Text View

A syntax-highlighted text representation of the current document (or selected subtree). Uses a custom text view with:
- Line numbers
- Syntax coloring per format (JSON, XML, YAML, CSV)
- Synchronized scrolling — selecting a tree node scrolls raw text to that location and vice versa
- Read-only by default; "Edit Raw" mode for power users

### 3.3 Table View (for Arrays)

When an array of uniform objects is selected, offer an automatic table view:

```
| name       | age | email              |
|------------|-----|--------------------|
| John Doe   | 32  | john@example.com   |
| Jane Smith | 28  | jane@example.com   |
```

This is detected heuristically: if >80% of array elements are objects sharing the same keys, display as a table. The user can switch between tree and table view for any array.

### 3.4 Detail / Editor Panel

A collapsible bottom or side panel showing the selected node in detail:
- **Full value** (not truncated)
- **Path** breadcrumb: `root > items > [42] > name`
- **Type** with format-specific info
- **Edit controls:** Text field for scalars, type picker dropdown, delete button
- **Raw bytes** toggle for debugging

### 3.5 Search

Two modes, accessible via the toolbar search field:

**Text search:** Searches keys and values across the entire document. Results shown as a filtered list with context. Matching nodes highlighted in the tree.

**Path query (power user):** JQ-style expressions for targeted access:
- `.items[0].name` — navigate to a specific node
- `.items[] | select(.age > 30)` — filter arrays
- `..name` — recursive descent, find all "name" keys

Results appear in a results panel below the search bar with keyboard navigation (Up/Down to select, Enter to jump to node in tree).

## 4. Editing Model

MachStruct supports **simple editing** — not a full text editor, but enough for common tasks:

### What You Can Edit
- **Scalar values:** Click a value in the tree or detail panel, type a new value, press Enter. Type is auto-detected or can be forced via a dropdown.
- **Keys:** Double-click a key to rename it.
- **Add child:** Right-click a container → "Add Item" (for arrays) or "Add Key-Value" (for objects). A new node appears with placeholder values.
- **Delete node:** Select → Delete key, or right-click → "Delete".
- **Reorder:** Drag-and-drop within arrays to reorder items.
- **Copy/paste:** Copy a node as JSON text; paste JSON text as a new child node.

### What Requires Raw Edit Mode
- Multi-node structural changes (moving nodes between parents)
- Bulk find-and-replace across values
- Adding comments or format-specific annotations

### Undo/Redo
Every edit action registers with NSDocument's UndoManager:
- Cmd+Z: undo last edit
- Cmd+Shift+Z: redo
- Unlimited undo within the session
- Undo descriptions appear in the Edit menu: "Undo Change Value of 'name'"

## 5. Toolbar

```
[Format: JSON ▼]  [◀ ▶ collapse/expand all]  [🌳 Tree | 📝 Raw | 📊 Table]  [⚙ Settings]
```

- **Format selector:** Shows current format. For new files, lets you pick the format.
- **Collapse/Expand:** Collapse all to depth 1, or expand all (with a warning for large files).
- **View mode toggle:** Switch between Tree, Raw Text, and Table views.
- **Settings gear:** Opens preferences (indent style, theme, font size, auto-detect encoding).

## 6. Appearance and Theming

- **Follows system appearance:** Light and dark mode via SwiftUI's native support.
- **Syntax color scheme:** Customizable (ships with defaults for Xcode Light, Xcode Dark, Monokai, Solarized).
- **Font:** System monospace font (SF Mono) by default, configurable.
- **Density:** Compact and comfortable row heights, togglable.

## 7. macOS Integration Points

- **Drag & drop:** Drop a file onto the app icon or window to open it.
- **Quick Look:** Quick Look plugin generates a mini tree view for JSON/XML/YAML/CSV files in Finder.
- **Spotlight:** Spotlight importer indexes document keys and values for system-wide search.
- **Services menu:** "Format JSON" and "Minify JSON" available in any app's Services menu for selected text.
- **Share menu:** Share the document or selected subtree via the standard macOS share sheet.
- **Touch Bar (legacy):** Navigation arrows, expand/collapse, and search on Touch Bar Macs.
- **Menu bar extras:** File stats and validation status in the menu bar.

## 8. Accessibility

- Full VoiceOver support with semantic descriptions ("Object with 12 keys, expanded" / "String value: John Doe")
- Keyboard-only navigation for all features
- High-contrast type badges
- Respects system font size preferences (Dynamic Type)
- Reduce Motion support (skip tree expansion animations)
