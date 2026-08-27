// ScriptAIAuthoringGuide.swift — compact, deterministic scripting contract shared with the
// in-game Ollama tool lane. Its built-in event section is deliberately generated from the same
// descriptors the runtime/editor expose, so that palette cannot become a stale hand-maintained copy;
// the compact Lua API rules above it remain explicit prose and are covered by focused contract tests.

import Foundation

public enum ScriptAIAuthoringGuide {
    public static var text: String {
        var lines = [
            "Elysium Lua authoring contract:",
            "- Module mode executes once whenever the script is loaded. Register callbacks with on(event, fn), subscribe(target, event, fn), target:on(event, fn), or target:onAttribute(attribute, fn). A module has no top-level ev.",
            "- Handler mode is already the complete callback body for its selected trigger. ev is implicitly bound. Never wrap handler-mode source in on(), subscribe(), or another function.",
            "- Every world, dimension, block, entity, and player is an object handle. Read h.ref, h.kind, h.name; use h:get(name), h:set(name, value), h:define(name, value[, {readonly=boolean, force=boolean}]), and h.attrs.name. h:define accepts no other option fields. Check validates attribute writes against the same live types, readonly rules, collisions, and storage caps without mutating.",
            "- A script may change attributes on self or any live handle it was given or resolved. Lua camelCase custom names persist as snake_case, for example doorRef becomes door_ref. Existing pre-upgrade collapsed keys remain readable through unchanged camelCase source, but generate new code with canonical snake_case. Built-ins are registry-first and accept canonical or camelCase spelling, so h:get(\"maxHealth\"), h:set(\"gameMode\", value), and h.maxHealth refer to max_health/game_mode, never custom keys. target:onAttribute(\"state\", function(ev) ... end) receives ev.key, ev.old, ev.new, ev.subject, ev.tick, and ev.source.",
            "- Custom attributes and attached scripts share one name namespace on each object. An attribute API refuses a script name until that script is detached; h:attach refuses an attribute name until that attribute is removed. h.attrs exposes custom attribute values only, so inspect attached script records with h:scripts() before conditionally attaching one. Custom event declarations are separate.",
            "- Custom event names use one to four lowercase dot-separated segments, for example machine.ready. Existing frozen built-ins shown below keep their exact spelling.",
            "- Declare a discoverable typed event with h:declareEvent(name, fields[, summary]). fields maps field names to any|boolean|integer|number|string|object|list|map; append ? for nullable, for example {item=\"string\", count=\"integer\", actor=\"object?\"}.",
            "- Inspect declarations with h:events(), remove one with h:undeclareEvent(name), emit a custom event on that object with h:emit(name[, payload]), or use emit(name[, payload][, target]). h:emit takes only name/payload; global emit's optional target must be a real object handle and never silently falls back when malformed. A matching declaration validates payload fields. Undeclared custom events remain legal for compatibility, but declare reusable events so people and AI can discover their contract. Built-in events are engine-produced facts and cannot be emitted manually.",
            "- h:on(event[, opts], fn) observes only h. Its optional table accepts only attr and name; target is invalid because the receiver fixes it. Malformed/unknown options and incompatible target/event/filter shapes fail identically in Check and live execution. subscribe() additionally accepts exact handles, kind filters, or any. An attr filter is valid only for attribute.changed; built-in filters may include registry punctuation such as inventory[0] or be.name. High-frequency block.changed and attribute.changed kind subscriptions retain their documented filters and bounds. A custom attribute named pos is ordinary state; synthetic movement also uses key pos but requires an explicit pos filter and is omitted from recent events.",
            "- Use objects.get(exactRef), objects.find{kind=..., type=..., near=..., radius=..., limit=...}, and objects.block(dim, x, y, z). Never invent an object reference.",
            "- Use h:attach(name, source[, {on=event, attr=attribute, target=handle}]) only when deliberately creating another attached script. Omit options for module mode; supplying a valid on event creates handler mode. There is no mode option, and target must be an object handle. Attach/detach lifecycle churn is capped at 2 operations per originating script and 32 operations across the world per tick. Run Once cannot persist handlers, timers, declarations, or child scripts.",
            "- The only block-specific handle methods are block:setBlock(name[, opts]) and block:breakBlock(). Do not invent use, scheduleTick, neighbors, entity verbs, player verbs, or world.spawn methods.",
            "- Keep callbacks short and event-driven; never busy-loop or poll. Attached work shares a deterministic instruction bucket, a callback is preempted and fairly resumed when its slice expires, repeated spinning faults, and suspended callbacks are capped at 64 per script and 1,024 per world. Use wait or named after/every handlers for delayed work.",
            "- ai.ask(prompt) replies later through ai.replied; ai.await(prompt) suspends only the calling coroutine. Replies preserve request order and remain paired with the waiter until scheduler credit permits resume. AI is optional, so never require it for deterministic event or attribute behavior.",
            "- unload is not an EventBus event and must not be used with on(), subscribe(), or handler mode. A module may install register(\"unload\", fn) as a synchronous finalizer for edit, disable, detach, object unload, or session shutdown. It receives no ev; its only persistent side effects may be final custom-attribute writes. It cannot wait, schedule, call AI, emit, subscribe, register, change declarations/scripts/world state/built-ins, use RNG, or call say/sound/particles.",
            "- EventBus callbacks receive exactly one parameter, ev. ev.source is provenance (engine, player, ai, lan, or script:<owner-ref>), not a damage cause. Event-specific payload is listed below; the separate unload finalizer receives no arguments.",
            "Built-in events (exact names; reserved/non-produced names omitted):",
        ]
        for descriptor in EventDescriptorRegistry.available {
            let kinds = descriptor.subjectKinds.map(\.rawValue).sorted(by: utf8Less).joined(separator: "|")
            let fields = descriptor.payload.map { field in
                "\(field.name):\(field.type.displayName)\(field.isNullable ? "?" : "")"
            }.joined(separator: ",")
            let suffix = fields.isEmpty ? "" : " payload={\(fields)}"
            lines.append("- \(descriptor.kind.rawValue) [\(kinds)]\(suffix): \(descriptor.summary)")
        }
        return lines.joined(separator: "\n")
    }
}
