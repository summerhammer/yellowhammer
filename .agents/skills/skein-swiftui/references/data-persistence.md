# Persistence

Storing data on device: SwiftData models, queries, migrations, and the small-value
stores. Companion to **state/primitives** (`@ObservationIgnored` on `@AppStorage`),
**state/injection** (reaching a context) and `FileManager`.

## Pick a store

| Data | Store |
|---|---|
| Entities, relationships, anything queried or listed | **SwiftData** |
| User preferences, small scalars | `@AppStorage` / `UserDefaults` |
| Per-window UI restoration state | `@SceneStorage` |
| Tokens, passwords, keys | Keychain — never `UserDefaults` |
| Blobs, documents, generated media | `FileManager` in the app container |

Core Data is not used in new code. SwiftData covers the model layer; drop to a custom
`DataStore` only for a backing store SwiftData does not provide.

## Models

```swift
@Model
final class Trip {
    #Unique<Trip>([\.slug])
    #Index<Trip>([\.startDate], [\.startDate, \.slug])

    var slug: String
    var title: String
    var startDate: Date

    @Relationship(deleteRule: .cascade, inverse: \Stop.trip)
    var stops: [Stop] = []

    init(slug: String, title: String, startDate: Date) { … }
}
```

- **Always state the delete rule and the inverse.** The default `.nullify` orphans
  children, and crashes when the child's back-reference is non-optional. SwiftData
  infers inverses badly — write `inverse:` explicitly.
- **`@Relationship` on one side only.** Both sides is a circular reference.
- **One `#Unique` per model**, with several key-path arrays if you need several
  constraints: `#Unique<Trip>([\.slug], [\.email])`.
- **`#Index` the properties you filter and sort on**, and index together the ones used
  together. Indexes cost on write — skip them for write-heavy, rarely-read models.
- **Stored enums must be `Codable`.** Associated values are fine.
- **`description` is a forbidden property name**, and property observers on `@Model`
  properties are silently ignored.
- **`@Transient` properties are not persisted**, need a default, and reset on fetch.
  Prefer a computed property unless the value is expensive.
- **`@Attribute(.externalStorage)` is a hint**, and only for `Data`.
- Model identifiers are temporary until the first save — save before relying on one.

## Container and context

```swift
@main
struct TripsApp: App {
    var body: some Scene {
        WindowGroup { TripList() }
            .modelContainer(for: Trip.self)
    }
}
```

- One container per app, installed on the `Scene`; views take `@Environment(\.modelContext)`.
- **Call `save()` explicitly where correctness matters.** Autosave timing is not
  predictable. No need to check `hasChanges` first.
- Use an in-memory container (`ModelConfiguration(isStoredInMemoryOnly: true)`) for
  previews and tests, seeded in one helper.

## Queries

```swift
struct TripList: View {
    @Query(filter: #Predicate<Trip> { !$0.stops.isEmpty },
           sort: \Trip.startDate, order: .reverse)
    private var trips: [Trip]
}
```

- **`@Query` only works inside a `View`.** Anywhere else, fetch through the context with
  a `FetchDescriptor`.
- Parameterise a query by passing the filter into the view's `init` and assigning
  `_trips = Query(...)`; a `@Query` cannot read another property of the same view.
- For counts use `modelContext.fetchCount(_:)` — cheap, but it does not live-update.
- On a `FetchDescriptor`, set `fetchLimit`, `propertiesToFetch`, and
  `relationshipKeyPathsForPrefetching` when you know what the screen reads. All
  properties are fetched by default.

### Predicates

`#Predicate` supports a subset of Swift. Some unsupported things compile and then crash.

- **Match strings with `localizedStandardContains(_:)`**, and prefixes with
  `starts(with:)`. `lowercased()`, `hasPrefix`, `hasSuffix` and regex literals are out —
  regex compiles, then fails at runtime.
- **`!collection.isEmpty` — never `collection.isEmpty == false`**, which crashes.
- No `map`, `reduce`, `count(where:)`, `first`, or custom operators.
- **Predicate only over stored properties.** Computed properties, `@Transient`
  properties and fields inside `Codable` structs compile and crash.

## Migrations

Define a versioned schema from the first release — even for lightweight changes, it is
the only thing that makes a later heavyweight change possible.

```swift
enum TripSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [Trip.self, Stop.self] }
}

enum TripMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [TripSchemaV1.self, TripSchemaV2.self] }
    static var stages: [MigrationStage] { [migrateV1toV2] }

    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: TripSchemaV1.self, toVersion: TripSchemaV2.self,
        willMigrate: { context in /* dedupe before a new #Unique */ try context.save() },
        didMigrate: nil
    )
}

.modelContainer(for: Trip.self, migrationPlan: TripMigrationPlan.self)
```

- **Lightweight** (`.lightweight`) covers added/removed properties and renames declared
  with `@Attribute(originalName:)`. Everything else — a new uniqueness constraint, a type
  change, backfilling a non-optional — needs a `.custom` stage.
- Each version is a full snapshot of every model, so keep the model types themselves
  inside the versioned enums and typealias the current version.
- Test migration by opening a store file seeded by the previous version; a failed
  migration is a launch crash for everyone who updates.

## Concurrency

`ModelContext` and model instances are **not** `Sendable` and must not cross actors.
`ModelContainer` and `PersistentIdentifier` are.

```swift
@ModelActor
actor ImportActor {
    func importTrips(_ payloads: [TripPayload]) throws -> [PersistentIdentifier] {
        let trips = payloads.map(Trip.init)
        trips.forEach(modelContext.insert)
        try modelContext.save()
        return trips.map(\.persistentModelID)
    }
}
```

Do background writes in a `@ModelActor` built from the container, return identifiers, and
re-fetch on the main context. `@Query` picks the changes up on its own.

## CloudKit

Only when the container is CloudKit-backed:

- **No `@Attribute(.unique)` / `#Unique`** — unsupported, and it breaks the local store too.
- **Every property needs a default or must be optional; every relationship optional.**
- Sync is eventually consistent — the UI must render correctly before data arrives.

## Small values

```swift
@AppStorage("preferredSort") private var sort: SortOrder = .recent
```

- `@AppStorage` is for preferences the user sets: scalars, `String`, `Data`, `URL`, and
  `RawRepresentable` enums. Not for model data, and not for anything large.
- Reading in a view subscribes it; writing redraws every reader. Keep keys in one
  `enum` of constants, not string literals at each site.
- Inside an `@Observable` class it needs `@ObservationIgnored` — see **state/primitives**.
- `@SceneStorage` holds per-scene UI restoration state (selected tab, scroll target) and
  is discarded when the scene is; never treat it as durable.
- Use a shared `UserDefaults(suiteName:)` in an App Group to reach widgets and extensions.

## Pitfalls

- **No delete rule** — orphaned children, or a crash on delete.
- **`isEmpty == false` in a predicate**, or a predicate over a computed/`@Transient`
  property — compiles, crashes at runtime.
- **`@Query` in a model or store type** — silently never updates.
- **No migration plan shipped in v1** — the first non-trivial schema change has nothing
  to migrate from.
- **Passing a model instance to a background task** — pass `persistentModelID` and
  re-fetch.
- **Relying on an identifier before the first save** — it changes.
- **Tokens in `UserDefaults`** — plain-text, backed up, synced. Keychain.
