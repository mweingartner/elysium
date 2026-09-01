import XCTest
@testable import ElysiumCore

@MainActor
final class ScriptLanguageSchemaTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        if entityTypes().isEmpty { registerAllEntities() }
    }

    func testSchemaIdentifiersAndMemberOrderingAreDeterministic() {
        let symbols = ScriptLanguageSchema.allSymbols
        XCTAssertEqual(Set(symbols.map(\.id)).count, symbols.count, "schema symbol ids must be unique")
        XCTAssertEqual(ScriptLanguageSchema.moduleMembers(named: "objects").map(\.name), ["get", "find", "block"])
        XCTAssertEqual(ScriptLanguageSchema.moduleMembers(named: "ai").map(\.name), ["ask", "await"])
        XCTAssertEqual(
            ScriptLanguageSchema.handleMethods.filter { $0.receiverKinds == [.block] }.map(\.name),
            ["setFurnaceOutput", "setBlock", "breakBlock"]
        )
        XCTAssertEqual(
            ScriptLanguageSchema.handleMethods.filter { $0.receiverKinds == [.player] }.map(\.name),
            ["give"]
        )
        XCTAssertEqual(ScriptLanguageSchema.unsupportedSymbols.map(\.name), ["log"])
        XCTAssertFalse(ScriptLanguageSchema.unsupportedSymbols[0].availability.isCompletable)
    }

    func testRuntimeHostBindingTreeExactlyMatchesEngineSchema() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "language-schema-bindings")
        game.createWorld(name: "Schema", seedText: "17", mode: GameMode.creative, difficulty: 2)
        let runtime = try XCTUnwrap(game.scriptingCommandContext().scriptRuntime)

        var globals: [String] = []
        var modules: [String: [String]] = [:]
        for binding in runtime.buildHostBindings() {
            switch binding {
            case .function(let name, _):
                globals.append(name)
            case .table(let name, let children):
                modules[name] = children.compactMap { child in
                    guard case .function(let childName, _) = child else { return nil }
                    return childName
                }
            }
        }

        XCTAssertEqual(globals, ScriptLanguageSchema.engineGlobals.map(\.name))
        XCTAssertEqual(Set(modules.keys), Set(["objects", "ai"]))
        for module in modules.keys.sorted() {
            XCTAssertEqual(
                modules[module],
                ScriptLanguageSchema.engineModuleMembers.filter { $0.parent == module }.map(\.name),
                "\(module) runtime bindings and authoring schema drifted"
            )
        }

        let runtimeHandleMethods = Set(ScriptRuntime.makeObjectDispatch(runtime).methods.keys)
        XCTAssertEqual(runtimeHandleMethods, Set(ScriptLanguageSchema.handleMethods.map(\.name)))
    }

    func testCompletableSchemaSymbolsArePresentInTheShippedSandbox() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "language-schema-sandbox")
        game.createWorld(name: "Schema Sandbox", seedText: "23", mode: GameMode.creative, difficulty: 2)
        let runtime = try XCTUnwrap(game.scriptingCommandContext().scriptRuntime)

        var probes: [String] = []
        let globalKinds: Set<ScriptLanguageSymbolKind> = [.globalFunction, .globalValue, .module]
        for symbol in ScriptLanguageSchema.allSymbols where
            symbol.parent == nil && globalKinds.contains(symbol.kind) && symbol.availability.isCompletable {
            probes.append("assert(\(symbol.name) ~= nil, \"missing \(symbol.name)\")")
        }
        for symbol in ScriptLanguageSchema.engineModuleMembers + ScriptLanguageSchema.luaModuleMembers
            where symbol.availability.isCompletable {
            let parent = try XCTUnwrap(symbol.parent)
            probes.append("assert(\(parent).\(symbol.name) ~= nil, \"missing \(parent).\(symbol.name)\")")
        }
        for symbol in ScriptLanguageSchema.handleProperties + ScriptLanguageSchema.handleMethods {
            probes.append("assert(world.\(symbol.name) ~= nil, \"missing handle \(symbol.name)\")")
        }
        probes += [
            "assert(log == nil, \"log must stay unavailable\")",
            "assert(load == nil and loadfile == nil and dofile == nil, \"dynamic loading must stay unavailable\")",
            "assert(os == nil and io == nil and debug == nil and package == nil, \"unsafe libraries must stay unavailable\")",
        ]

        XCTAssertNil(
            runtime.dryRun(source: probes.joined(separator: "\n"), owner: .world, mode: .module),
            "the pure schema probe should run against exactly the shipped sandbox surface"
        )
    }

    func testAttributesProjectRegistryTruthAndRuntimeCamelCaseSugar() {
        for kind in ObjectKind.allCases {
            let source = AttributeRegistry.descriptors(for: kind)
            let projected = ScriptLanguageSchema.attributes(for: kind)
            XCTAssertEqual(projected.map(\.name), source.map(\.canonical))
            for (attribute, descriptor) in zip(projected, source) {
                XCTAssertTrue(
                    Set(descriptor.aliases).isSubset(of: Set(attribute.aliases)),
                    "registry aliases must remain present"
                )
            }
            XCTAssertEqual(projected.map(\.applicability), source.map(\.applicability))
            XCTAssertEqual(projected.map(\.mutability), source.map(\.mutability))
            XCTAssertEqual(projected.map(\.aiExposed), source.map(\.aiExposed))
            XCTAssertEqual(projected.map(\.summary), source.map(\.summary))
            XCTAssertEqual(
                projected.map(\.type),
                source.map { ScriptLanguageValueType(attributeKind: $0.valueKind) }
            )
        }
        XCTAssertFalse(
            ScriptLanguageSchema.attributes(for: .block).first(where: { $0.name == "name" })?.supportsDotAccess ?? true,
            "h.name is the handle display name; the block registry name must use h:get(\"name\")"
        )
        XCTAssertFalse(
            ScriptLanguageSchema.attributes(for: .block).first(where: { $0.name == "be.type" })?.supportsDotAccess ?? true
        )
        XCTAssertTrue(
            ScriptLanguageSchema.attributes(for: .entity).first(where: { $0.name == "health" })?.supportsDotAccess ?? false
        )
        let maxHealth = ScriptLanguageSchema.attributes(for: .entity).first { $0.name == "max_health" }
        XCTAssertEqual(maxHealth?.dotAccessNames, ["max_health", "maxHealth"])
    }

    func testEventRegistryCoversThePublishedBuiltInCatalogExactlyOnce() {
        let expected: [EventKind] = [
            .attributeChanged,
            .blockPlaced, .blockToolStrike, .blockBroken, .blockReplaced, .blockChanged, .blockUsed,
            .blockNeighborChanged, .blockScheduledTick,
            .furnaceSmeltCompleted,
            .entitySpawned, .entityRemoved, .entityDamaged, .entityDied, .entityHealed,
            .entityInteracted, .entityTargetChanged,
            .playerJoined, .playerLeft, .playerRespawned, .playerDimensionChanged,
            .playerPickedUp, .playerDropped, .playerAttacked, .playerSlept, .playerLeveled,
            .playerAdvancement,
            .dimDayPhaseChanged, .dimWeatherChanged,
            .worldGameruleChanged, .worldDifficultyChanged,
            .explosion, .load, .unload, .timerFired, .aiReplied,
            .scriptFaulted, .scriptAttached, .scriptOverBudget,
        ]
        XCTAssertEqual(EventKind.builtInKinds, expected)
        for kind in expected {
            XCTAssertEqual(
                EventKind.parse(kind.rawValue), kind,
                "every offered/persisted built-in event must round-trip through the public parser"
            )
        }
        XCTAssertEqual(Set(EventDescriptorRegistry.names).count, expected.count)
        XCTAssertEqual(
            EventDescriptorRegistry.all.compactMap { descriptor in
                if case .reserved = descriptor.availability { return descriptor.kind.rawValue }
                return nil
            },
            ["block.replaced", "block.scheduledTick", "unload"]
        )
        for descriptor in EventDescriptorRegistry.all {
            XCTAssertNotNil(EventDescriptorRegistry.descriptor(named: descriptor.kind.rawValue))
            XCTAssertEqual(Set(descriptor.payload.map(\.name)).count, descriptor.payload.count)
            XCTAssertFalse(descriptor.summary.isEmpty)
        }
        XCTAssertEqual(EventKind.parse("furnace.smeltCompleted"), .furnaceSmeltCompleted)
        XCTAssertEqual(EventKind.parse("furnace.output")?.rawValue, "furnace.output")
        XCTAssertNil(
            EventDescriptorRegistry.descriptor(named: "furnace.output"),
            "the pre-existing custom-event spelling must not be claimed as a built-in"
        )
    }

    func testLuaCATSOutputIsStableToolingOnlyAndCoversEngineAPI() {
        let first = ScriptLanguageSchema.luaCATSDefinitions
        let second = ScriptLanguageSchema.luaCATSDefinitions
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("---@meta\n"))
        XCTAssertTrue(first.contains("---@class ElysiumObject"))
        XCTAssertTrue(first.contains("function ElysiumObject:setBlock(name, opts) end"))
        XCTAssertTrue(first.contains("function ElysiumObject:setFurnaceOutput(item) end"))
        XCTAssertTrue(first.contains("function objects.find(options) end"))
        XCTAssertTrue(first.contains("function ai.await(prompt, opts) end"))
        let aiPrefix = String(first.prefix(ScriptLanguageSchema.editorAIPrefixCharacterLimit))
        XCTAssertTrue(aiPrefix.contains("function on("), "bounded AI schema must include event registration")
        XCTAssertTrue(aiPrefix.contains("function objects.get("), "bounded AI schema must include object lookup")
        XCTAssertTrue(
            aiPrefix.contains("function ElysiumObject:setFurnaceOutput(item)"),
            "bounded AI schema must include the furnace output contract"
        )
        XCTAssertFalse(first.contains("function log("))
        XCTAssertFalse(first.contains("function load("))
        XCTAssertEqual(
            ScriptLanguageSchema.symbol(named: "ult", parent: "math")?.signatures.first?.returns.map(\.type),
            [.boolean]
        )
        XCTAssertEqual(
            ScriptLanguageSchema.symbol(named: "modf", parent: "math")?.signatures.first?.returns.map(\.type),
            [.number, .number]
        )
        XCTAssertEqual(
            ScriptLanguageSchema.symbol(named: "randomseed", parent: "math")?.signatures.first?.returns,
            []
        )
        XCTAssertEqual(
            ScriptLanguageSchema.symbol(named: "sub", parent: "string")?.signatures.first?.parameters.count,
            3
        )
        let tableInsert = ScriptLanguageSchema.symbol(named: "insert", parent: "table")
        XCTAssertEqual(tableInsert?.signatures.map(\.label), [
            "table.insert(list, value)",
            "table.insert(list, pos, value)",
        ])
        XCTAssertEqual(tableInsert?.signatures.map { $0.parameters.map(\.isOptional) }, [
            [false, false],
            [false, false, false],
        ], "table.insert's required value must not be misread as optional")
    }

    func testEveryPaletteSnippetPassesTheShippedValidator() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "language-schema-snippets")
        game.createWorld(name: "Snippets", seedText: "19", mode: GameMode.creative, difficulty: 2)
        let runtime = try XCTUnwrap(game.scriptingCommandContext().scriptRuntime)

        for kind in ObjectKind.allCases {
            let items = ScriptLanguageSchema.snippetSections(for: kind).flatMap(\.items)
            XCTAssertFalse(items.isEmpty)
            XCTAssertEqual(Set(items.map(\.id)).count, items.count, "\(kind) snippet ids must be unique")
            for item in items {
                switch runtime.validateSourceForEditor(item.code, chunkName: item.id).outcome {
                case .accepted:
                    break
                case .refused(let stage, let message, let hint, let line):
                    XCTFail("\(item.id) refused at stage \(stage), line \(line): \(message) — \(hint)")
                }
            }
        }
    }

    func testPaletteSnippetsDoNotRegressToHistoricalWrongSignatures() {
        let source = ScriptLanguageSchema.snippets.map(\.code).joined(separator: "\n")
        XCTAssertFalse(source.contains("function(self, world, player, ev)"))
        XCTAssertFalse(source.contains("emit(self,"))
        XCTAssertFalse(source.contains("self:attach(\"name\", \"module\""))
        XCTAssertFalse(source.contains("self:setBlock(x"))
        XCTAssertFalse(source.contains("self:breakBlock(x"))
        XCTAssertFalse(source.contains("objects.find(\"entity\")"))
        XCTAssertFalse(source.contains("objects.block(x"))
        XCTAssertFalse(source.contains("log("))

        guard let repeating = ScriptLanguageSchema.snippets.first(where: { $0.id == "timing.every" }) else {
            return XCTFail("missing durable every snippet")
        }
        XCTAssertTrue(repeating.code.contains("every(20, \"on_interval\")"))
        XCTAssertFalse(repeating.code.contains("every(20, function"))

        guard let unload = ScriptLanguageSchema.snippets.first(where: { $0.id == "lifecycle.unload" }) else {
            return XCTFail("missing unload finalizer snippet")
        }
        XCTAssertTrue(unload.code.contains("register(\"unload\", function()"))
        XCTAssertFalse(unload.code.contains("function(ev)"), "the unload finalizer receives no event")
    }
}
