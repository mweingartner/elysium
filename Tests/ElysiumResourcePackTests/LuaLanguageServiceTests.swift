import XCTest
@testable import Elysium
@testable import ElysiumCore

final class LuaLanguageServiceTests: XCTestCase {
    private func environment(
        kind: ObjectKind = .player,
        targetCanonicalRef: String? = nil,
        applicableBuiltIns: Set<String>? = nil,
        customAttributes: [LuaCustomAttributeCompletion] = [],
        references: [LuaObjectReferenceCompletion] = [],
        scriptMode: ScriptMode = .module,
        handlerEvent: String? = nil,
        eventCandidates: [ScriptEditorEventCandidate]? = nil,
        isYieldable: Bool = true
    ) -> LuaLanguageEnvironment {
        LuaLanguageEnvironment(
            targetKind: kind,
            targetCanonicalRef: targetCanonicalRef,
            targetApplicableBuiltInAttributes: applicableBuiltIns,
            targetCustomAttributes: customAttributes,
            objectReferences: references,
            scriptMode: scriptMode,
            handlerEvent: handlerEvent,
            eventCandidates: eventCandidates,
            isYieldable: isYieldable
        )
    }

    private func completion(
        _ source: String,
        environment: LuaLanguageEnvironment = LuaLanguageEnvironment(targetKind: .player)
    ) -> LuaCompletionResult {
        LuaLanguageService.completions(
            source: source,
            cursorUTF16: (source as NSString).length,
            environment: environment
        )
    }

    func testSyntaxColorRangesRemainUTF16CorrectAfterEmoji() throws {
        let source = "local label = \"🧪\"; return label"
        let spans = LuaSyntaxColoring.colorSource(source)
        let keywordRange = try XCTUnwrap(spans.first { span in
            span.kind == .keyword && (source as NSString).substring(with: span.range) == "return"
        }?.range)
        XCTAssertEqual(keywordRange, (source as NSString).range(of: "return"))

        let completionSource = "local icon = \"🧪\"\nself.he"
        let result = completion(completionSource)
        XCTAssertEqual((completionSource as NSString).substring(with: result.replacementRange), "he")
        XCTAssertTrue(result.items.contains { $0.label == "health" })
    }

    func testEmptyPrefixAfterDotImmediatelyOffersReceiverSpecificProperties() {
        let result = completion("self.")
        guard case .members(let receiver, let access) = result.context else {
            return XCTFail("expected member completion")
        }
        XCTAssertEqual(receiver, "self")
        XCTAssertEqual(access, .dot)
        XCTAssertTrue(result.prefix.isEmpty)
        XCTAssertTrue(result.items.contains { $0.label == "health" })
        XCTAssertTrue(result.items.contains { $0.label == "ref" })
        XCTAssertFalse(result.items.contains { $0.label == "setBlock" })
    }

    func testColonMethodsRespectResolvedReceiverInsteadOfEditorTarget() {
        let playerResult = completion("self:", environment: environment(kind: .player))
        XCTAssertTrue(playerResult.items.contains { $0.label == "exists" })
        XCTAssertFalse(playerResult.items.contains { $0.label == "setBlock" })
        XCTAssertTrue(playerResult.items.contains { $0.label == "give" })

        let aliasedBlock = "local door = objects.block(\"overworld\", 1, 64, 2)\ndoor:"
        let blockResult = completion(aliasedBlock, environment: environment(kind: .player))
        XCTAssertTrue(blockResult.items.contains { $0.label == "setBlock" })
        XCTAssertTrue(blockResult.items.contains { $0.label == "breakBlock" })
        XCTAssertFalse(blockResult.items.contains { $0.label == "give" })

        let directBlock = completion("objects.block(\"overworld\", 1, 64, 2):")
        XCTAssertTrue(directBlock.items.contains { $0.label == "setBlock" })
        let directPlayer = completion("objects.get(\"player\").")
        XCTAssertTrue(directPlayer.items.contains { $0.label == "health" })
    }

    func testEngineAndLuaModulesHaveDistinctMembers() {
        XCTAssertEqual(Set(completion("objects.").items.map(\.label)), ["get", "find", "block"])
        XCTAssertEqual(Set(completion("ai.").items.map(\.label)), ["ask", "await"])
        XCTAssertTrue(completion("math.sq").items.contains { $0.label == "sqrt" })
        XCTAssertFalse(completion("math.").items.contains { $0.label == "get" })
    }

    func testLocalTableLiteralFieldsAreInferred() {
        let source = "local config = { open = false, speed = 2 }\nconfig."
        let items = completion(source).items
        XCTAssertEqual(Set(items.map(\.label)), ["open", "speed"])
        XCTAssertEqual(items.first(where: { $0.label == "open" })?.detail, "boolean")
        XCTAssertEqual(items.first(where: { $0.label == "speed" })?.detail, "integer")
    }

    func testLiveCustomAttributesAppearOnlyOnCurrentSelfAttrsProxy() {
        let env = environment(customAttributes: [
            LuaCustomAttributeCompletion(
                name: "quest_state", typeName: "string", isReadOnly: true,
                summary: "Current quest state"
            ),
        ])
        let selfItems = completion("self.attrs.", environment: env).items
        XCTAssertEqual(selfItems.map(\.label), ["quest_state"])
        XCTAssertEqual(selfItems.first?.isReadOnly, true)

        let otherItems = completion("player.attrs.", environment: env).items
        XCTAssertTrue(otherItems.isEmpty, "target custom attributes must not leak onto another receiver")

        let handleAlias = completion("local me = self\nme.attrs.", environment: env)
        XCTAssertEqual(handleAlias.items.map(\.label), ["quest_state"])
        let proxyAlias = completion("local attrs = self.attrs\nattrs.", environment: env)
        XCTAssertEqual(proxyAlias.items.map(\.label), ["quest_state"])
    }

    func testKeywordCustomAttributeRequiresGetInsteadOfInvalidDotSyntax() {
        let env = environment(customAttributes: [
            LuaCustomAttributeCompletion(name: "end", typeName: "string"),
            LuaCustomAttributeCompletion(name: "quest_state", typeName: "string"),
        ])
        XCTAssertEqual(completion("self.attrs.", environment: env).items.map(\.label), ["quest_state"])
    }

    func testDottedAndCollidingAttributesAreNotInsertedAsDirectMembers() {
        let items = completion("self.").items
        let names = Set(items.map(\.label))
        XCTAssertFalse(names.contains("rpg.path"))
        XCTAssertEqual(items.filter { $0.label == "name" }.count, 1)
        XCTAssertEqual(items.first(where: { $0.label == "name" })?.kind, .property,
                       "handle name wins; the colliding block attribute must use get(name)")
    }

    func testEventNameCompletionReplacesOnlyContentInsideQuote() {
        let source = "on(\"entity.da"
        let result = completion(source)
        XCTAssertEqual(result.context, .eventName)
        XCTAssertEqual(result.prefix, "entity.da")
        XCTAssertEqual((source as NSString).substring(with: result.replacementRange), "entity.da")
        XCTAssertTrue(result.items.contains { $0.label == "entity.damaged" && $0.insertionText == "entity.damaged" })
        XCTAssertFalse(result.items.contains { $0.label == "block.used" }, "player targets must not offer block-only events")
        XCTAssertFalse(result.items.contains { $0.label == "block.replaced" }, "reserved events are documented but not offered")

        let explicitOtherTarget = completion(
            "subscribe(objects.block(\"overworld\", 1, 64, 2), \"block.u"
        )
        XCTAssertTrue(
            explicitOtherTarget.items.contains { $0.label == "block.used" },
            "an explicit subscription target may differ from the editor target"
        )
        let explicitAnalysis = LuaLanguageService.analyze(
            source: "subscribe(objects.block(\"overworld\", 1, 64, 2), \"block.used\", function(ev) end)",
            environment: environment(kind: .player)
        )
        XCTAssertFalse(explicitAnalysis.diagnostics.contains { $0.id.hasPrefix("target-event:") })
    }

    func testManualEmitCompletionOffersOnlyDeclaredCustomEventsOnCurrentTarget() throws {
        let declaration = CustomEventDeclaration(
            kind: try XCTUnwrap(EventKind.parse("machine.ready")),
            fields: [CustomEventField(name: "count", type: .integer)],
            summary: "A machine is ready.",
            provenance: Provenance(createdBy: .player, createdTick: 1)
        )
        let env = environment(
            kind: .player,
            eventCandidates: ScriptEditorEventCatalog.candidates(
                targetKind: .player,
                declarations: [declaration]
            )
        )

        for source in ["emit(\"", "self:emit(\""] {
            let names = completion(source, environment: env).items.map(\.label)
            XCTAssertEqual(names, ["machine.ready"])
            XCTAssertFalse(names.contains("load"))
            XCTAssertFalse(names.contains("entity.damaged"))
        }
        XCTAssertTrue(
            completion("player:emit(\"", environment: env).items.isEmpty,
            "declarations from the editor target must not leak onto another explicit receiver"
        )
        XCTAssertTrue(
            completion("on(\"", environment: env).items.contains { $0.label == "load" },
            "subscription completion must continue to offer compatible engine events"
        )

        let analysis = LuaLanguageService.analyze(
            source: "emit(\"load\", {})\nself:emit(\"entity.damaged\", {})",
            environment: env
        )
        XCTAssertEqual(
            analysis.diagnostics.filter { $0.id.hasPrefix("manual-built-in-event:") }.count,
            2
        )
        XCTAssertTrue(analysis.diagnostics.filter {
            $0.id.hasPrefix("manual-built-in-event:")
        }.allSatisfy { $0.severity == .error })
    }

    func testOrdinaryStringsCommentsAndCompletedArgumentsDoNotOpenCompletion() {
        XCTAssertTrue(completion("local text = \"self.").items.isEmpty)
        XCTAssertTrue(completion("-- self.").items.isEmpty)
        let completedArgument = completion("on(\"load\"")
        XCTAssertEqual(completedArgument.context, .keywordsAndGlobals)
        XCTAssertTrue(completedArgument.prefix.isEmpty,
                      "the editor suppresses ordinary empty-prefix global completion unless Control-Space is used")
    }

    func testEventPayloadFieldsFollowInferredCallbackEvent() {
        let source = "on(\"entity.damaged\", function(ev)\n  ev."
        let names = Set(completion(source).items.map(\.label))
        XCTAssertTrue(names.isSuperset(of: ["kind", "subject", "tick", "source", "amount", "attacker"]))
        XCTAssertFalse(names.contains("requestId"))

        let withOptions = "on(\"entity.damaged\", { name = \"handler_name\" }, function(ev)\n  ev."
        XCTAssertTrue(completion(withOptions).items.contains { $0.label == "amount" },
                      "an option string must not replace the call's event type")

        let handleMethod = "self:on(\"entity.damaged\", function(ev)\n  ev."
        XCTAssertTrue(completion(handleMethod).items.contains { $0.label == "amount" })
    }

    func testNearbyObjectReferencesAreOfferedOnlyInReferenceArguments() {
        let ref = LuaObjectReferenceCompletion(
            canonicalRef: "block:overworld:4,65,-2", displayName: "Oak Door", kind: .block
        )
        let stale = LuaObjectReferenceCompletion(
            canonicalRef: "entity:999", displayName: "Gone", kind: .entity, isLive: false
        )
        let env = environment(references: [ref, stale])
        let result = completion("objects.get(\"block:o", environment: env)
        XCTAssertEqual(result.context, .objectReference)
        XCTAssertEqual(result.items.first?.label, ref.canonicalRef)
        XCTAssertEqual(result.items.first?.insertionText, ref.canonicalRef)
        XCTAssertFalse(result.items.contains { $0.label == stale.canonicalRef })
        XCTAssertFalse(completion("local block", environment: env).items.contains { $0.label == ref.canonicalRef })

        let subscribe = completion("subscribe(\"block:o", environment: env)
        XCTAssertEqual(subscribe.items.first?.insertionText, "objects.get(\"\(ref.canonicalRef)\")")
        XCTAssertEqual(("subscribe(\"block:o" as NSString).substring(with: subscribe.replacementRange), "\"block:o")
    }

    func testExactNearbyBindingOffersOnlyThatObjectsCustomAttributesAndMethods() {
        let canonical = "block:overworld:4,65,-2"
        let reference = LuaObjectReferenceCompletion(
            canonicalRef: canonical,
            displayName: "Oak Door",
            kind: .block,
            customAttributes: [
                LuaCustomAttributeCompletion(
                    name: "lock_code", typeName: "string", isReadOnly: true,
                    summary: "Live lock code on this exact door."
                ),
            ]
        )
        let env = environment(
            kind: .world,
            targetCanonicalRef: ObjectRef.world.canonical,
            customAttributes: [LuaCustomAttributeCompletion(name: "world_state")],
            references: [reference]
        )

        let source = "local door = objects.get(\"\(canonical)\")\ndoor.attrs."
        let attributes = completion(source, environment: env).items
        XCTAssertEqual(attributes.map(\.label), ["lock_code"])
        XCTAssertEqual(attributes.first?.isReadOnly, true)

        let methods = completion(
            "local door = objects.get(\"\(canonical)\")\ndoor:", environment: env
        ).items
        XCTAssertTrue(methods.contains { $0.label == "setBlock" })
        XCTAssertFalse(methods.contains { $0.label == "health" })
    }

    func testLocalsShadowGlobalsAndEvIsOnlyImplicitInHandlerMode() {
        let shadowed = completion("local say = 1\nsa")
        XCTAssertEqual(shadowed.items.first(where: { $0.label == "say" })?.source, .local)
        XCTAssertFalse(completion("e").items.contains { $0.label == "ev" })
        XCTAssertTrue(completion(
            "e",
            environment: environment(scriptMode: .handler, handlerEvent: "load")
        ).items.contains { $0.label == "ev" })
    }

    func testDeclaredCustomEventsAreDiscoverableWithPayloadCompletion() throws {
        let kind = try XCTUnwrap(EventKind.parse("machine.ready"))
        let declaration = CustomEventDeclaration(
            kind: kind,
            fields: [
                CustomEventField(name: "count", type: .integer),
                CustomEventField(name: "item", type: .string, isNullable: true),
            ],
            summary: "Machine output is ready.",
            provenance: Provenance(createdBy: .player, createdTick: 9)
        )
        let events = ScriptEditorEventCatalog.candidates(
            targetKind: .block,
            declarations: [declaration]
        )
        let env = environment(kind: .block, eventCandidates: events)

        let eventNames = completion("on(\"machine.", environment: env).items
        XCTAssertTrue(eventNames.contains {
            $0.label == "machine.ready" && $0.source == .liveObject
        })

        let payloadSource = "on(\"machine.ready\", function(ev)\n  ev."
        let payload = completion(payloadSource, environment: env).items
        XCTAssertTrue(payload.contains { $0.label == "count" && $0.detail == "integer" })
        XCTAssertTrue(payload.contains { $0.label == "item" && $0.detail == "string?" })
        XCTAssertTrue(payload.contains { $0.label == "subject" })

        let analysis = LuaLanguageService.analyze(
            source: "on(\"machine.ready\", function(ev) say(ev.count) end)",
            environment: env
        )
        XCTAssertFalse(analysis.diagnostics.contains { $0.id.hasPrefix("undeclared-event:") })
    }

    func testModeContractDiagnosticsRejectWrongSourceShapes() {
        let handler = environment(
            scriptMode: .handler,
            handlerEvent: "entity.damaged"
        )
        for source in [
            "subscribe(self, \"entity.damaged\", function(ev) say(ev.amount) end)",
            "self:on(\"entity.damaged\", function(ev) say(ev.amount) end)",
        ] {
            let analysis = LuaLanguageService.analyze(source: source, environment: handler)
            XCTAssertTrue(analysis.diagnostics.contains {
                $0.id.hasPrefix("handler-subscription-wrapper:") && $0.severity == .error
            }, source)
        }
        let directHandler = LuaLanguageService.analyze(
            source: "say(ev.amount)",
            environment: handler
        )
        XCTAssertFalse(directHandler.diagnostics.contains {
            $0.id.hasPrefix("handler-subscription-wrapper:")
        })

        let module = environment(scriptMode: .module)
        let invalidModule = LuaLanguageService.analyze(
            source: "say(ev.amount)",
            environment: module
        )
        XCTAssertTrue(invalidModule.diagnostics.contains {
            $0.id.hasPrefix("module-top-level-ev:") && $0.severity == .error
        })
        let callbackModule = LuaLanguageService.analyze(
            source: "on(\"entity.damaged\", function(ev) say(ev.amount) end)",
            environment: module
        )
        XCTAssertFalse(callbackModule.diagnostics.contains {
            $0.id.hasPrefix("module-top-level-ev:")
        })
        let tableFieldModule = LuaLanguageService.analyze(
            source: "local values = {\n  ev\n  = 1; ev = 2\n}",
            environment: module
        )
        XCTAssertFalse(tableFieldModule.diagnostics.contains {
            $0.id.hasPrefix("module-top-level-ev:")
        })
    }

    func testUnloadFinalizerGuidanceIsSeparateFromEventHandlers() {
        let candidates = ScriptEditorEventCatalog.candidates(targetKind: .player)
        XCTAssertFalse(candidates.contains { $0.name == "unload" })

        let moduleHelp = ScriptEditorAuthoringContract.modeHelp(.module)
        XCTAssertTrue(moduleHelp.contains("register(\"unload\", fn)"))
        XCTAssertTrue(moduleHelp.contains("no-ev"))

        let unloadHelp = ScriptEditorAuthoringContract.handlerEventHelp(
            eventName: "unload", candidates: candidates, targetKind: .player
        )
        XCTAssertTrue(unloadHelp.contains("not an EventBus handler event"))
        XCTAssertTrue(unloadHelp.contains("register(\"unload\""))
    }

    func testUndeclaredAndTargetIncompatibleEventsProduceGuidance() {
        let analysis = LuaLanguageService.analyze(
            source: "on(\"machine.unknown\", function(ev) end)\non(\"block.used\", function(ev) end)",
            environment: environment(kind: .player)
        )
        XCTAssertTrue(analysis.diagnostics.contains { $0.id.hasPrefix("undeclared-event:") })
        XCTAssertTrue(analysis.diagnostics.contains { $0.id.hasPrefix("target-event:") })
    }

    func testCamelCaseAndSubsequenceFilteringAreDeterministic() {
        let result = completion("self:sB", environment: environment(kind: .block))
        XCTAssertEqual(result.items.first?.label, "setBlock")
        XCTAssertEqual(result.replacementRange.length, 2)
    }

    func testLiveTargetApplicabilityAndCamelCaseSugarStayFactual() {
        let livePlayer = environment(
            kind: .player,
            applicableBuiltIns: ["health", "max_health", "dimension"]
        )
        let result = completion("self.", environment: livePlayer)
        XCTAssertTrue(result.items.contains { $0.label == "max_health" })
        XCTAssertTrue(result.items.contains { $0.label == "maxHealth" })
        XCTAssertFalse(result.items.contains { $0.label == "target" }, "non-mob target must not offer mob-only attributes")

        let analysis = LuaLanguageService.analyze(
            source: "local me = self\nsay(me.maxHealth)", environment: livePlayer
        )
        XCTAssertFalse(analysis.diagnostics.contains { $0.id.hasPrefix("unknown-member:") })
    }

    func testDiagnosticsCoverUnavailableAndUnsafeConstructsWithQuickFixes() {
        let source = "log(\"x\")\nh:set(\"state\", true)\nself.exists()\npairs(self.attrs)\nwait(20)"
        let analysis = LuaLanguageService.analyze(source: source, environment: environment(isYieldable: false))
        XCTAssertTrue(analysis.diagnostics.contains { $0.id.hasPrefix("unavailable:") && $0.quickFixes.first?.replacementText == "say" })
        XCTAssertTrue(analysis.diagnostics.contains {
            $0.id.hasPrefix("unavailable:") && $0.quickFixes.first?.replacementText == "self"
        })
        XCTAssertTrue(analysis.diagnostics.contains { $0.id.hasPrefix("member-access:") })
        XCTAssertTrue(analysis.diagnostics.contains { $0.id.hasPrefix("pairs-attrs:") })
        XCTAssertTrue(analysis.diagnostics.contains { $0.id.hasPrefix("wait-mode:") })
    }

    func testNonYieldableDiagnosticsRespectShadowedWaitAndAI() {
        let source = """
        local wait = function() return 1 end
        local ai = { await = function() return 2 end }
        wait()
        ai.await()
        """
        let analysis = LuaLanguageService.analyze(
            source: source, environment: environment(isYieldable: false)
        )

        XCTAssertFalse(analysis.diagnostics.contains { $0.id.hasPrefix("wait-mode:") })
        XCTAssertFalse(analysis.diagnostics.contains { $0.id.hasPrefix("await-mode:") })
    }

    func testSandboxGlobalNamesMayBeShadowedByDocumentLocals() {
        let source = "local log = function(value) return value end\nlocal h = self\nh:exists()\nreturn log(\"ok\")"
        let analysis = LuaLanguageService.analyze(source: source, environment: environment())
        XCTAssertFalse(analysis.diagnostics.contains { $0.id.hasPrefix("unavailable:") })
        XCTAssertFalse(analysis.semanticTokens.contains { token in
            token.role == .unavailable && (source as NSString).substring(with: token.range) == "log"
        })
        XCTAssertFalse(analysis.semanticTokens.contains { token in
            token.role == .unavailable && (source as NSString).substring(with: token.range) == "h"
        })
    }

    func testDiagnosticsRespectDynamicPayloadsAndReportReadOnlyAndInvalidEvents() {
        let dynamic = "on(\"custom.event\", function(ev)\n  ev.any_payload\n  self.attrs.unknown\nend)"
        let dynamicAnalysis = LuaLanguageService.analyze(source: dynamic, environment: environment())
        XCTAssertFalse(dynamicAnalysis.diagnostics.contains { $0.id.hasPrefix("unknown-member:") })

        let invalid = "on(\"not valid!\", function(ev) end)\nself.dimension = \"nether\""
        let invalidAnalysis = LuaLanguageService.analyze(source: invalid, environment: environment())
        XCTAssertTrue(invalidAnalysis.diagnostics.contains { $0.id.hasPrefix("invalid-event:") })
        XCTAssertTrue(invalidAnalysis.diagnostics.contains { $0.id.hasPrefix("readonly-member:") })
    }

    func testSignatureHelpTracksActiveParameter() throws {
        let source = "on(\"load\", "
        let help = try XCTUnwrap(LuaLanguageService.signatureHelp(
            source: source,
            cursorUTF16: (source as NSString).length,
            environment: environment()
        ))
        XCTAssertEqual(help.label, "on(event, fn)")
        XCTAssertEqual(help.activeParameter, 1)

        let overloadSource = "on(\"load\", {}, "
        let overload = try XCTUnwrap(LuaLanguageService.signatureHelp(
            source: overloadSource,
            cursorUTF16: (overloadSource as NSString).length,
            environment: environment()
        ))
        XCTAssertEqual(overload.label, "on(event, opts, fn)")
        XCTAssertEqual(overload.activeParameter, 2)
    }

    func testSemanticAnalysisClassifiesLocalsEngineGlobalsAndProperties() {
        let source = "local target = self\nsay(target.health)"
        let analysis = LuaLanguageService.analyze(source: source, environment: environment())
        func text(for token: LuaSemanticToken) -> String {
            (source as NSString).substring(with: token.range)
        }
        XCTAssertTrue(analysis.semanticTokens.contains { $0.role == .declaration && text(for: $0) == "target" })
        XCTAssertTrue(analysis.semanticTokens.contains { $0.role == .engineGlobal && text(for: $0) == "say" })
        XCTAssertTrue(analysis.semanticTokens.contains { $0.role == .attribute(readOnly: false) && text(for: $0) == "health" })
    }
}
