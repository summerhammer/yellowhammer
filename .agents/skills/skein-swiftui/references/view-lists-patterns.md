# List patterns

Recipes built on `List`, `Table` and the lazy containers. The container choice, the
identity rules and the pitfalls live in **view/lists** — read that first; this file
assumes them.

| Want | Pattern |
|---|---|
| Feed or timeline with custom rows | [Plain feed](#plain-feed) |
| Settings screen | [Grouped settings](#grouped-settings) |
| "Nothing here yet" / no search results | [Empty state](#empty-state) |
| Pull to refresh | [Refreshable](#refreshable) |
| Search over the list's own data | [Searchable list](#searchable-list) |
| Themed background behind rows | [Custom surface](#custom-surface) |
| Multi-select with a batch action | [Selection and batch actions](#selection-and-batch-actions) |
| Drag to reorder, persisted | [Persisted reordering](#persisted-reordering) |
| Swipe to delete with undo | [Destructive swipe with undo](#destructive-swipe-with-undo) |
| Sticky section headers over custom rows | [Pinned sections](#pinned-sections) |
| Collapsible groups | [Expandable sections](#expandable-sections) |
| Tree-shaped data | [Outline list](#outline-list) |
| Photo or icon grid | [Adaptive grid](#adaptive-grid) |
| Endless list that loads as you reach the end | [Infinite list](#infinite-list) |
| Rows that show a skeleton while loading | [Skeleton rows](#skeleton-rows) |
| Sortable columns on Mac and iPad | [Sortable table](#sortable-table) |
| One table that survives compact width | [Adaptive table](#adaptive-table) |

Two ideas recur:

- **The model owns order, filtering and identity; the view only renders.** Every pattern
  below that looks like view state (sort order, filtered results, drag position) is
  reliable only because it is resolved in the model before the `ForEach` sees it.
- **Any gesture-only affordance needs a second route.** Swipe and drag are invisible to
  pointer, keyboard and assistive technology. Pair each with a context menu or toolbar
  action — that is a correctness requirement, not a nicety.

## Plain feed

`.plain` with hidden separators and explicit row insets is the baseline for a timeline.
`defaultMinListRowHeight` stops short rows being padded to the system minimum.

```swift
List {
    ForEach(posts) { post in
        PostRow(post: post)
            .listRowInsets(.init(top: 12, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .contentShape(.rect)
    }
}
.listStyle(.plain)
.environment(\.defaultMinListRowHeight, 1)
```

Keep `PostRow` a single top-level view so the list can template row ids without running
each body — see **view/lists**.

## Grouped settings

```swift
List {
    Section("General") {
        NavigationLink("Display") { DisplaySettings() }
        Toggle("Haptics", isOn: $settings.haptics)
    }
    Section {
        Button("Sign Out", role: .destructive) { session.signOut() }
    } footer: {
        Text("Signed in as \(session.email).")
    }
}
.listStyle(.insetGrouped)
```

Use `Form` instead when the screen is primarily *input* — it adds label alignment and
control styling that a `List` does not. `List` is right when the rows are navigation and
actions.

## Empty state

`ContentUnavailableView` as an overlay, so the list keeps its scroll position, refresh
control and toolbar. The `.search` variant is localized for you.

```swift
List { ForEach(results) { ItemRow(item: $0) } }
    .overlay {
        if results.isEmpty {
            if searchText.isEmpty {
                ContentUnavailableView(
                    "No Articles",
                    systemImage: "doc.richtext",
                    description: Text("Articles you save will appear here.")
                )
            } else {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }
```

Distinguish *empty* from *no match* — they call for different words and different actions.
Neither is the same as *still loading*, which wants [skeleton rows](#skeleton-rows).

## Refreshable

```swift
List { ForEach(items) { ItemRow(item: $0) } }
    .refreshable { await store.reload() }
```

The closure is async and the spinner stays up until it returns — don't fire-and-forget
inside it, or the control snaps back before the data lands. `refreshable` renders as
pull-to-refresh on iOS and as a menu/toolbar refresh affordance on macOS, so the list still
needs an explicit Refresh command if the Mac is a first-class target.

## Searchable list

Resolve the filter outside `body`, so the `ForEach` sees a stable collection.

```swift
@State private var query = ""

private var results: [Item] {
    guard !query.isEmpty else { return store.items }
    return store.items.filter { $0.title.localizedStandardContains(query) }
}

List { ForEach(results) { ItemRow(item: $0) } }
    .searchable(text: $query, prompt: "Search items")
```

A computed property is fine for small in-memory collections. For anything expensive —
network search, a large corpus, a database query — debounce into `@State` (see
**state/streams**) rather than recomputing per keystroke. Use `localizedStandardContains`,
not `contains`: it is case- and diacritic-insensitive the way users expect.

## Custom surface

```swift
List { ForEach(items) { ItemRow(item: $0) } }
    .scrollContentBackground(.hidden)      // without this the next line does nothing
    .background(theme.listBackground)
```

For per-row colouring use `listRowBackground(_:)`, which covers the row's insets and keeps
selection highlighting correct.

## Selection and batch actions

```swift
@State private var selection = Set<Item.ID>()
@Environment(\.editMode) private var editMode

List(items, selection: $selection) { ItemRow(item: $0) }
    .toolbar {
        ToolbarItem(placement: .topBarTrailing) { EditButton() }
        ToolbarItem(placement: .bottomBar) {
            Button("Delete \(selection.count)", role: .destructive) {
                store.delete(ids: selection)
                selection.removeAll()
            }
            .disabled(selection.isEmpty)
        }
    }
```

Clear the selection after acting — stale ids referring to deleted rows are a common source
of a second action doing nothing. On macOS selection is live without an edit mode, so gate
the `EditButton` on the platform rather than shipping a mode Mac users don't need.

## Persisted reordering

The drag must write to the same field the list sorts by, or the row snaps back.

```swift
List {
    ForEach(store.orderedItems) { item in
        ItemRow(item: item)
            .moveDisabled(item.isPinned)
    }
    .onMove { source, destination in
        store.reorder(fromOffsets: source, toOffset: destination)   // rewrites `sortIndex`
    }
}
.toolbar { EditButton() }
```

In the store, apply `move(fromOffsets:toOffset:)` to the ordered array and then rewrite
each element's persisted index. Offsets index the `ForEach`'s collection — if that is a
filtered or sectioned view of the model, translate before mutating.

## Destructive swipe with undo

Full swipe on an irreversible action is a trap; either disable it or make the action
recoverable.

```swift
ItemRow(item: item)
    .swipeActions(edge: .trailing) {
        Button(role: .destructive) { delete(item) } label: {
            Label("Delete", systemImage: "trash")
        }
    }
    .contextMenu {                       // the non-gesture route
        Button("Delete", role: .destructive) { delete(item) }
    }
```

Back it with `UndoManager` from the environment, or a brief "Undo" affordance in the
toolbar, rather than a confirmation dialog per row — a dialog on every swipe defeats the
gesture's purpose. Reserve `confirmationDialog` for deletions that cannot be undone.

## Pinned sections

`.plain` already pins headers:

```swift
List {
    ForEach(groups) { group in
        Section(group.title) { ForEach(group.items) { ItemRow(item: $0) } }
    }
}
.listStyle(.plain)
```

For a custom layout that `List` cannot express, pin in a lazy stack instead —
`LazyVStack(pinnedViews: [.sectionHeaders])`, in **view/scroll-patterns**. Give the header
an opaque background either way; it floats over the rows.

## Expandable sections

`Section(isExpanded:)` gives a collapsible group whose state you own, so it survives
scrolling and can be restored.

```swift
@State private var expanded: Set<Group.ID> = []

List {
    ForEach(groups) { group in
        Section(isExpanded: Binding(
            get: { expanded.contains(group.id) },
            set: { $0 ? expanded.insert(group.id) : expanded.remove(group.id) }
        )) {
            ForEach(group.items) { ItemRow(item: $0) }
        } header: {
            Text(group.title)
        }
    }
}
.listStyle(.sidebar)   // the styles that draw a disclosure control
```

Keying the set by id rather than by index is what keeps the right groups open when the
collection changes.

## Outline list

For genuinely tree-shaped data, `children:` does the recursion — and the disclosure state —
for you.

```swift
struct Node: Identifiable {
    let id: UUID
    let name: String
    var children: [Node]?      // nil, not [], for a leaf
}

List(nodes, children: \.children) { node in
    Label(node.name, systemImage: node.children == nil ? "doc" : "folder")
}
```

An empty array renders a disclosure triangle that opens onto nothing; use `nil` for leaves.
`OutlineGroup` is the same machinery when you need it inside a `List` alongside other
sections.

## Adaptive grid

```swift
ScrollView {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
        ForEach(photos) { photo in
            Thumbnail(photo: photo)
                .aspectRatio(1, contentMode: .fill)
                .clipShape(.rect(cornerRadius: 8))
                .contentShape(.rect)
        }
    }
    .padding(.horizontal, 8)
}
```

`.adaptive` is what makes one grid work on a phone, a split-view iPad and a resized Mac
window. Fix the column count only when it carries meaning. Keep cells cheap: an overlay
badge on every cell is paid per item, and the grid may hold hundreds.

## Infinite list

Visibility is the signal, not offset — it survives varying row heights and a content size
that changes as pages arrive.

```swift
List {
    ForEach(store.items) { ItemRow(item: $0) }

    if store.hasMore {
        ProgressView()
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            .onScrollVisibilityChange(threshold: 0.1) { visible in
                if visible { store.loadMore() }
            }
    }
}
.listStyle(.plain)
```

The callback can fire more than once per approach, so `loadMore()` must be idempotent and
guard its own in-flight state. Never key pagination off `contentOffset > contentSize - k`:
it breaks the moment content shrinks.

## Skeleton rows

Render the real row shape against placeholder data so the layout does not jump when the
content lands.

```swift
List {
    ForEach(store.items.isEmpty ? Item.placeholders : store.items) { item in
        ItemRow(item: item)
            .redacted(reason: store.isLoading ? .placeholder : [])
    }
}
.disabled(store.isLoading)
```

`.redacted` hides text and images but not interaction — hence the `.disabled`. Give the
placeholders stable ids so the swap to real data animates rather than replacing the list.

## Sortable table

`Table` reports the user's sort intent; it never sorts the data.

```swift
@State private var sortOrder = [KeyPathComparator(\Person.familyName)]

Table(people, sortOrder: $sortOrder) {
    TableColumn("Given Name", value: \.givenName)
    TableColumn("Family Name", value: \.familyName)
    TableColumn("E-Mail", value: \.email)
}
.onChange(of: sortOrder) { _, order in people.sort(using: order) }
```

`value:` is what makes a column sortable at all — a column built only from a view builder
gets no header affordance. Sort in the store if the data is owned there, so the order
survives the view's lifetime.

## Adaptive table

Below a regular width, `Table` shows only the first column. Design that column to carry the
combined information, so the transition in and out of Slide Over is seamless.

```swift
@Environment(\.horizontalSizeClass) private var sizeClass
private var isCompact: Bool { sizeClass == .compact }

Table(people, sortOrder: $sortOrder) {
    TableColumn("Name", value: \.familyName) { person in
        VStack(alignment: .leading) {
            Text(person.fullName)
            if isCompact { Text(person.email).foregroundStyle(.secondary) }
        }
    }
    TableColumn("E-Mail", value: \.email)
    TableColumn("Role", value: \.role)
}
.onChange(of: sortOrder) { _, order in people.sort(using: order) }
```

If the compact presentation needs to differ structurally — different affordances, not just
denser content — render a `List` instead of a one-column `Table` and share the row view
between them.
