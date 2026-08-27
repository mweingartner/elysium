import XCTest
@testable import ElysiumCore

final class CustomEventStoreTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllEntities()
    }

    private func makeStores(
        caps: ScriptingStorageCaps = .defaults, isLANClient: Bool = false
    ) -> (FakeObjectGraphHost, CustomEventStore, AttributeStore, ScriptStore) {
        let host = FakeObjectGraphHost()
        host.isLANClient = isLANClient
        let world = World(dim: .overworld, seed: 7)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        host.worldsByDim[.overworld] = world
        let graph = ObjectGraph(host: host)
        return (
            host,
            CustomEventStore(graph: graph, caps: caps),
            AttributeStore(graph: graph, caps: caps),
            ScriptStore(graph: graph, caps: caps)
        )
    }

    func testDeclareListUpdateIdempotenceAndUndeclare() throws {
        let (host, events, _, _) = makeStores()
        host.currentTick = 10
        let fields = [
            CustomEventField(name: "item", type: .string),
            CustomEventField(name: "count", type: .integer),
        ]
        let first = try events.declare(
            .world, name: "furnace.output_ready", fields: fields,
            summary: "Output is ready.", by: .player
        ).get()
        XCTAssertEqual(first.fields.map(\.name), ["count", "item"])
        XCTAssertEqual(first.provenance.createdTick, 10)
        XCTAssertEqual(host.worldRecords["world"]?.revision, 1)

        host.currentTick = 11
        let same = try events.declare(
            .world, name: "furnace.output_ready", fields: Array(fields.reversed()),
            summary: "Output is ready.", by: .ai(model: "ignored")
        ).get()
        XCTAssertEqual(same.provenance, first.provenance)
        XCTAssertEqual(host.worldRecords["world"]?.revision, 1)

        host.currentTick = 12
        let changed = try events.declare(
            .world, name: "furnace.output_ready", fields: fields,
            summary: "A new output stack is ready.", by: .ai(model: "local")
        ).get()
        XCTAssertEqual(changed.provenance.createdBy, .ai(model: "local"))
        XCTAssertEqual(changed.provenance.createdTick, 12)
        XCTAssertEqual(host.worldRecords["world"]?.revision, 2)
        XCTAssertEqual(events.list(.world).map(\.kind.rawValue), ["furnace.output_ready"])

        XCTAssertTrue(try events.undeclare(.world, "furnace.output_ready").get())
        XCTAssertFalse(try events.undeclare(.world, "furnace.output_ready").get())
        XCTAssertNil(host.worldRecords["world"], "the last declaration's removal should remove the empty record")
    }

    func testSeparateNamespaceCoexistsWithAttributeAndSurvivesScriptDetach() throws {
        let (_, events, attributes, scripts) = makeStores()
        _ = try attributes.set(.world, "alarm", .bool(true)).get()
        _ = try events.declare(
            .world, name: "alarm", fields: [], summary: "Alarm signal."
        ).get()
        _ = try scripts.attach(
            .world, name: "brain", source: "", mode: .module, triggers: [],
            by: .player, tick: 0
        ).get()

        XCTAssertEqual(attributes.get(.world, "alarm"), .bool(true))
        XCTAssertNotNil(events.get(.world, "alarm"))
        XCTAssertTrue(try scripts.detach(.world, "brain").get())
        XCTAssertNotNil(events.get(.world, "alarm"))
    }

    func testValidationRefusesBuiltInsReservedFieldsBadSummaryAndFieldCap() {
        XCTAssertEqual(ScriptingStorageCaps.defaults.maxEventDeclarationsPerObject, 16)
        XCTAssertEqual(ScriptingStorageCaps.defaults.maxEventFieldsPerDeclaration, 32)
        XCTAssertEqual(ScriptingStorageCaps.defaults.maxEventSummaryBytes, 256)

        var caps = ScriptingStorageCaps.defaults
        caps.maxEventFieldsPerDeclaration = 1
        caps.maxEventSummaryBytes = 8
        let (_, events, _, _) = makeStores(caps: caps)

        guard case .failure(.builtInEventName) = events.declare(.world, name: "block.broken", fields: []) else {
            return XCTFail("built-in names must not be shadowed")
        }
        guard case .failure(.invalidEventName) = events.declare(.world, name: "Bad.Event", fields: []) else {
            return XCTFail("invalid event name should be refused")
        }
        guard case .failure(.reservedFieldName("source")) = events.declare(
            .world, name: "custom.event", fields: [.init(name: "source", type: .string)]
        ) else { return XCTFail("envelope field should be refused") }
        guard case .failure(.tooManyFields(limit: 1)) = events.declare(
            .world, name: "custom.event",
            fields: [.init(name: "a", type: .string), .init(name: "b", type: .string)]
        ) else { return XCTFail("field cap should be refused") }
        guard case .failure(.summaryTooLarge(limit: 8)) = events.declare(
            .world, name: "custom.event", fields: [], summary: "123456789"
        ) else { return XCTFail("summary cap should be refused") }
        guard case .failure(.summaryTooLarge(limit: 8)) = events.declare(
            .world, name: "custom.event", fields: [], summary: "ééééé"
        ) else { return XCTFail("summary cap must count UTF-8 bytes, not characters") }
    }

    func testDeclarationAndCombinedEntryCapsAreAtomicAcrossStores() throws {
        var declarationCaps = ScriptingStorageCaps.defaults
        declarationCaps.maxEventDeclarationsPerObject = 2
        let (_, events, _, _) = makeStores(caps: declarationCaps)
        _ = try events.declare(.world, name: "a.event", fields: []).get()
        _ = try events.declare(.world, name: "b.event", fields: []).get()
        guard case .failure(.tooManyDeclarations(limit: 2)) = events.declare(
            .world, name: "c.event", fields: []
        ) else { return XCTFail("declaration cap should be refused") }
        XCTAssertEqual(events.list(.world).count, 2)

        var combinedCaps = ScriptingStorageCaps.defaults
        combinedCaps.maxEntriesPerObject = 2
        let (_, combinedEvents, attributes, scripts) = makeStores(caps: combinedCaps)
        _ = try attributes.set(.world, "value", .int(1)).get()
        _ = try combinedEvents.declare(.world, name: "a.event", fields: []).get()
        guard case .failure(.tooManyEntries(limit: 2)) = combinedEvents.declare(
            .world, name: "b.event", fields: []
        ) else { return XCTFail("combined cap should include attributes") }
        guard case .failure(.tooManyEntries(limit: 2)) = scripts.attach(
            .world, name: "script", source: "", mode: .module, triggers: [],
            by: .player, tick: 0
        ) else { return XCTFail("ScriptStore must count event declarations against the shared cap") }
        XCTAssertEqual(
            scriptStoreErrorText(.tooManyEntries(limit: 2)),
            "too many stored attributes, scripts, and event declarations on this object (limit 2)"
        )
        guard case .failure(.tooManyEntries(limit: 2)) = attributes.set(
            .world, "other", .int(2)
        ) else { return XCTFail("AttributeStore must count event declarations against the shared cap") }
        XCTAssertNil(scripts.get(.world, "script"))
        XCTAssertNil(attributes.get(.world, "other"))
        XCTAssertEqual(combinedEvents.list(.world).map(\.kind.rawValue), ["a.event"])
    }

    func testLANClientRefusesMutationsButReadsRemainSideEffectFree() {
        let (_, events, _, _) = makeStores(isLANClient: true)
        guard case .failure(.lanClient) = events.declare(
            .world, name: "custom.event", fields: []
        ) else { return XCTFail("LAN client declaration must fail closed") }
        guard case .failure(.lanClient) = events.undeclare(.world, "custom.event") else {
            return XCTFail("LAN client undeclaration must fail closed")
        }
        XCTAssertTrue(events.list(.world).isEmpty)
    }

    func testDeclarationOnlyBlockIsDiscoverableAndRemovalDropsItsRecord() throws {
        let (host, events, _, _) = makeStores()
        let world = try XCTUnwrap(host.worldsByDim[.overworld])
        _ = world.setBlock(3, 64, 0, Int(cell(B.furnace)))
        let ref = ObjectRef.block(dim: .overworld, x: 3, y: 64, z: 0)
        _ = try events.declare(
            ref, name: "furnace.output_ready",
            fields: [.init(name: "count", type: .integer)]
        ).get()

        let nearby = events.graph.objectsNear(x: 0, y: 64, z: 0, radius: 16, limit: 32)
        XCTAssertTrue(nearby.contains { $0.ref == ref })
        let chunk = try XCTUnwrap(world.getChunk(0, 0))
        XCTAssertNotNil(chunk.objectRecords[chunk.index(3, 64, 0)])

        XCTAssertTrue(try events.undeclare(ref, "furnace.output_ready").get())
        XCTAssertNil(chunk.objectRecords[chunk.index(3, 64, 0)])
    }

    func testContextualDescriptorsDoNotBleedAcrossObjects() throws {
        let (_, events, _, _) = makeStores()
        _ = try events.declare(
            .world, name: "quest.updated", fields: [.init(name: "stage", type: .integer)]
        ).get()
        _ = try events.declare(
            .dimension(.overworld), name: "quest.updated",
            fields: [.init(name: "title", type: .string)]
        ).get()
        let kind = try XCTUnwrap(EventKind.parse("quest.updated"))
        let worldRecord = events.graph.host.worldObjectRecord(for: .world)
        let dimRecord = events.graph.host.worldObjectRecord(for: .dimension(.overworld))

        XCTAssertEqual(
            EventDescriptorRegistry.descriptor(for: kind, declaredOn: .world, in: worldRecord)?.payload.map(\.name),
            ["stage"]
        )
        XCTAssertEqual(
            EventDescriptorRegistry.descriptor(
                for: kind, declaredOn: .dimension(.overworld), in: dimRecord
            )?.payload.map(\.name),
            ["title"]
        )
        XCTAssertNil(EventDescriptorRegistry.descriptor(for: kind), "global built-in registry must stay static")
    }
}
