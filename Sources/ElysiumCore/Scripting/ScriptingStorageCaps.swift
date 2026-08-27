// ScriptingStorageCaps.swift — object-graph-attributes (change 1a). design.md
// Decision 6: one table for every scripting-storage cap, test-overridable,
// instead of literals scattered at call sites. Consumed by `AttrValueCodec`
// (value shape/size), `ObjectRecordCodec` (map-key length), and
// `AttributeStore`/`Saves.swift` (per-object, per-chunk and per-world-document
// byte budgets).

import ElysiumScript

public struct ScriptingStorageCaps: Sendable, Equatable {
    /// Maximum custom entries in one object's `ObjectRecord`.
    public var maxEntriesPerObject: Int
    /// Maximum canonical record text length, in bytes, for a block or entity/
    /// player object.
    public var maxRecordTextBytes: Int
    /// Maximum canonical record text length, in bytes, for the world or a
    /// dimension bag (smaller — these are meant for small counters/flags, not
    /// large payloads).
    public var maxWorldDimRecordTextBytes: Int
    /// Maximum summed record-text bytes across every block record in one chunk.
    public var maxChunkObjectBytes: Int
    /// Maximum summed bytes across the world document (world bag + the three
    /// dimension bags).
    public var maxWorldDocumentBytes: Int
    /// `ScriptValue`/`AttrValue` shape caps (string bytes, list/map element
    /// counts, nesting depth, total node count) — design.md Decision 4.
    public var value: ScriptValueLimits
    /// Maximum UTF-8 byte length of one map key inside an `AttrValue.map`.
    public var maxMapKeyBytes: Int
    /// Maximum length (bytes == chars, names are `[a-z][a-z0-9_]{0,31}`) of a
    /// custom attribute name.
    public var maxNameBytes: Int
    /// Maximum persistent custom-event declarations on one object.
    public var maxEventDeclarationsPerObject: Int
    /// Maximum declared payload fields on one custom event.
    public var maxEventFieldsPerDeclaration: Int
    /// Maximum UTF-8 bytes in an optional custom-event summary.
    public var maxEventSummaryBytes: Int

    public init(
        maxEntriesPerObject: Int,
        maxRecordTextBytes: Int,
        maxWorldDimRecordTextBytes: Int,
        maxChunkObjectBytes: Int,
        maxWorldDocumentBytes: Int,
        value: ScriptValueLimits,
        maxMapKeyBytes: Int,
        maxNameBytes: Int,
        maxEventDeclarationsPerObject: Int = 16,
        maxEventFieldsPerDeclaration: Int = 32,
        maxEventSummaryBytes: Int = 256
    ) {
        self.maxEntriesPerObject = maxEntriesPerObject
        self.maxRecordTextBytes = maxRecordTextBytes
        self.maxWorldDimRecordTextBytes = maxWorldDimRecordTextBytes
        self.maxChunkObjectBytes = maxChunkObjectBytes
        self.maxWorldDocumentBytes = maxWorldDocumentBytes
        self.value = value
        self.maxMapKeyBytes = maxMapKeyBytes
        self.maxNameBytes = maxNameBytes
        self.maxEventDeclarationsPerObject = maxEventDeclarationsPerObject
        self.maxEventFieldsPerDeclaration = maxEventFieldsPerDeclaration
        self.maxEventSummaryBytes = maxEventSummaryBytes
    }

    /// design.md Decision 6's defaults: 64 entries/object, 65,536 B record text
    /// (16,384 B for world/dimension bags), 1,048,576 B/chunk, 524,288 B world
    /// document, `ScriptValueLimits.defaults`, 256 B map keys, 32-char names,
    /// 16 event declarations/object, 32 fields/declaration, and 256 B summaries.
    public static let defaults = ScriptingStorageCaps(
        maxEntriesPerObject: 64,
        maxRecordTextBytes: 65_536,
        maxWorldDimRecordTextBytes: 16_384,
        maxChunkObjectBytes: 1_048_576,
        maxWorldDocumentBytes: 524_288,
        value: .defaults,
        maxMapKeyBytes: 256,
        maxNameBytes: 32,
        maxEventDeclarationsPerObject: 16,
        maxEventFieldsPerDeclaration: 32,
        maxEventSummaryBytes: 256
    )
}
