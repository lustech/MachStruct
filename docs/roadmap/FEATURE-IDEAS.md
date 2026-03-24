# Feature Ideas & Differentiators

> Creative features that could make MachStruct stand out from every other JSON viewer.

## Tier 1: High-Impact, Unique Differentiators

### 1. "X-Ray Mode" — Schema Inference
Automatically infer the implicit schema of any JSON/YAML document and display it as a collapsible type overlay. For an array of 10K user objects, show: `{ name: string, age: int, email: string?, tags: string[] }` — even though there's no formal schema. Highlight type inconsistencies (e.g., "age" is a string in 3 out of 10K records). This is enormously useful for exploring unfamiliar API responses.

### 2. "Time Machine" — Visual Diff Over Time
Track file changes across saves (or across git commits if the file is in a repo). Show a timeline slider that lets you scrub through the document's history and see what changed — added nodes glow green, removed nodes glow red, changed values show before/after. Integrates with macOS Versions API and git.

### 3. Natural Language Queries
"Show me all users older than 30" or "Find items where the price is missing" — powered by a local LLM or heuristic query translator that converts natural language to JQ/XPath expressions. No cloud dependency. Even a simple keyword-to-path mapper would be valuable.

### 4. Live Tail / File Watcher
Watch a JSON file for changes (e.g., a log file, config file, or API response dump). When the file changes on disk, incrementally re-index only the changed regions and animate the diff. Useful for developers watching config hot-reloads or streaming data.

### 5. "Lens" — Custom Node Renderers
Let power users define custom renderers for specific node patterns. Examples:
- A node with keys `lat` and `lng` → render as a mini map preview
- A node with a `url` key ending in `.png` → render as an image thumbnail
- A node with an ISO 8601 date string → render as a human-readable date with relative time
- A node with a hex color string → render with a color swatch

Ship with built-in lenses for common patterns; let users create custom lenses via a simple DSL or Swift plugin.

### 6. Split-Pane Document Comparison
Open two documents side by side with structural diff. Not just text diff — tree-aware diff that understands "this object was moved from index 3 to index 7" vs. "this object was deleted and a similar one was added." Essential for comparing API responses, config versions, or data exports.

## Tier 2: Power User Features

### 7. Transformation Pipeline
Define a chain of transformations: Filter → Map → Sort → Rename keys → Output. Visual pipeline editor where each step shows intermediate results. Save pipelines as reusable presets. Example: "From this 100MB API dump, extract all users with >100 followers, sort by join date, and export as CSV."

### 8. Multi-File Workspace
Open an entire directory of JSON files as a workspace. Cross-file search, batch operations (format all, validate all, convert all to YAML). Project-level bookmarks.

### 9. Regex-Powered Find & Replace
Find and replace across all values (or all keys) using regex patterns. Preview all matches before applying. Supports capture groups for advanced transformations (e.g., rename all keys from `camelCase` to `snake_case`).

### 10. Node Statistics Panel
For any selected container, show rich statistics:
- Type distribution of children (pie chart)
- Key frequency (which keys appear in what % of objects)
- Value distribution for repeated keys (histogram of ages, word cloud of names)
- Null/missing value heatmap
- Array length distribution

### 11. Shareable Bookmarks / Deep Links
Generate a `machstruct://path/to/file#root.items[42].name` URL that opens MachStruct, opens the file, and navigates to the exact node. Useful for sharing specific nodes in Slack/email.

### 12. Export Fragments
Select any subtree and export it as a standalone file in any supported format. Right-click an array of objects → "Export as CSV." Copy a subtree as a formatted code snippet with syntax highlighting (for pasting into docs/Slack).

## Tier 3: Quality-of-Life & Polish

### 13. Smart Clipboard
When you copy text that looks like JSON/XML/YAML, MachStruct can grab it from the clipboard and open it in a new scratch document. Menu bar icon shows "JSON detected on clipboard — click to view."

### 14. Minimap
A minimap sidebar (like VS Code) showing the document structure at a glance. Color-coded by node depth or type. Click to jump. Useful for very large files where scrolling is tedious.

### 15. "Flatten" and "Unflatten"
Convert between nested JSON and dot-path flat key-value pairs:
- Flatten: `{"user": {"name": "John"}}` → `{"user.name": "John"}`
- Unflatten: reverse

Useful for config file migration and debugging.

### 16. Syntax-Aware Copy
Copy a node and MachStruct puts multiple representations on the clipboard:
- JSON text (for pasting into editors)
- Rich text with syntax highlighting (for pasting into docs/presentations)
- Tab-separated (for pasting into spreadsheets)
- Swift/Python/JS code literal (for pasting into code)

### 17. Format Auto-Fixer
Detect and fix common issues: trailing commas, unquoted keys, single quotes (JS-style), comments in JSON. Show what was fixed and let the user accept or reject each fix.

### 18. Hex/Binary Value Inspector
For base64-encoded strings, offer inline decode preview. For numbers, show hex/binary/octal representations. For UUIDs, highlight and validate format. For Unix timestamps, show human-readable date.

### 19. Drag-Out Export
Drag a node directly from the tree view into Finder to create a file, into a text editor to paste formatted text, or into a terminal to paste the JQ path.

### 20. Command Palette
Cmd+Shift+P opens a command palette (VS Code-style) with fuzzy search across all commands, recently opened files, and bookmarked nodes. The fastest way to do anything.

## Tier 4: Long-Term Vision

### 21. Plugin System
Swift-based plugins that can:
- Register new format parsers
- Add custom node renderers (Lenses)
- Define transformation pipelines
- Add toolbar buttons and menu items
- Publish to a plugin directory

### 22. Collaborative Viewing
Share a read-only view of a document via a local web server. Colleagues can view the document in their browser with the full tree UI. Useful for pair debugging without sharing the file.

### 23. AI-Powered Features
- "Explain this structure" — describe what a JSON document appears to represent
- "Generate sample data" — create realistic test data matching the document's schema
- "Suggest a schema" — generate a JSON Schema from the document
- "Translate query" — convert natural language to JQ/XPath and back

### 24. Binary Format Support
Extend the parser system to handle binary serialization formats:
- MessagePack — compact JSON alternative
- BSON — MongoDB's binary JSON
- Protobuf — Google's schema-based binary format (requires .proto files)
- CBOR — IoT-focused binary format
- Parquet — columnar data format for analytics

Each would implement the `StructParser` protocol and map to the same DocumentNode model.

## Prioritization Framework

When deciding what to build next, score features on:

| Criterion | Weight | Question |
|---|---|---|
| **User impact** | 40% | How many users benefit, and how much? |
| **Uniqueness** | 25% | Does any other Mac app do this well? |
| **Implementation cost** | 20% | How many weeks of effort? |
| **Architecture alignment** | 15% | Does it fit cleanly into the existing module system? |

Features that score high on uniqueness (X-Ray Mode, Lenses, Time Machine) should be prioritized even if they're harder to build — they're what make MachStruct worth choosing over free alternatives.
