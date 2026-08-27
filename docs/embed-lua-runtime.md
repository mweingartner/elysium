# Embed the Lua 5.4.8 Script Runtime (`CLua` + `ElysiumScript`)

> **Historical change record:** this document describes the foundational runtime-only change and
> its statement that no gameplay/UI existed was true for that change. The shipped scripting API is
> now documented in `docs/SCRIPTING_GUIDE.md`; the current native authoring surface is documented in
> `docs/LUA_EDITOR.md`.

## Purpose

Elysium's scripting, events and AI object-graph programme
(`docs/scripting-and-eventing-design.md`, v3, §16 row 0 — user-owned and untracked in
this change, per design.md Condition 1) needs a deterministic,
sandboxed, budgeted script runtime before any object, attribute, event or AI work can
start — today nothing in the repository can run untrusted code at all. This change,
`embed-lua-runtime`, is change 0 of that programme: it vendors Lua 5.4.8 as the C target
`CLua` and lands `ElysiumScript`, the Swift target that is the **sole Lua owner**, with
a C boundary that can never unwind a Swift frame, exact machine-independent instruction/
allocation budgets, a per-script frozen API sandbox, and a determinism patch set over
stock Lua. It changes no gameplay, save format, LAN message or UI — pure foundation for
the changes that follow (`object-graph-attributes`, `event-bus`, `script-runtime`,
`ai-object-graph`).

## Value

- **To the scripting programme's later changes.** They inherit a stable, gated
  foundation — the C boundary, sandbox, budgets and determinism work is done once here,
  rather than re-derived by every later change that needs to run a script.
- **To world authors and players, eventually.** Once objects/attributes/events land on
  this runtime, a script fault is always per-script and never engine-fatal: a broken or
  malicious script cannot crash the game, corrupt Swift state, or desync a LAN session,
  because every raise/yield/resume/pcall happens inside `CLua`'s own C and every budget
  trip is recorded host-side before the script is closed.
- **To Michael and future maintainers.** The vendored interpreter's provenance is
  hash-pinned and hermetically re-derivable, and the sole-Lua-owner boundary is
  machine-enforced by the boundary and security scanners, so the isolation guarantees
  here cannot erode silently as the codebase grows.

## Scope

**In scope:** the `CLua` SwiftPM C target (Lua 5.4.8 vendored, patched, provenance-
pinned); `ElysiumScript` (the sole Lua owner: `LuaState`, environments, coroutines,
handles, host functions, marshaling, the validator); the C boundary contract
(`elysium_shim.c`/`elysium_sandbox.c`, public `elysium_shim.h`); the sandbox (stdlib
allowlist, frozen per-environment API copies, `__metatable` locks); the budget system;
the determinism patch set over stock Lua; `detExp`/`detLog`/`detPow` fdlibm ports in
`DetMath` with an independent reference golden; the `elysmoke` script-runtime section
and benchmark, with the pinned check count moving 457 → 469; and the scanner/security-
scan/release-surface gates that keep all of the above true over time.

**Explicitly not in scope** (Conditions 1, 2, 15): no `ObjectGraph`, `EventBus`, Lua API
verbs, scheduler tick integration, commands, editor UI, or script persistence — later
changes (1a–2). No gameplay, save-format, LAN-protocol or UI change. The app never
creates a `lua_State`; `ElysiumCore` gains only one new file
(`Sources/ElysiumCore/Scripting/ScriptHostBindings.swift`, exposing the deterministic
math table and the `RandomX` stream conformance) plus the additive `DetMath.swift`/
`RandomX.swift` edits described below. The runtime has no `io`, `os`, `package`, `debug`
or `coroutine` library (`lcorolib.c` stays vendored for provenance completeness but
`luaopen_coroutine` is never called — `scripts/security-scan.sh` and `CLuaSourceTests`
pin that), no bytecode-loading path (`lundump.c` is a stub that refuses to load), and no
wall-clock or filesystem access — host-only execution, with nothing here scheduling or
pacing a script against gameplay ticks.

**Trust boundaries.** Script source text, chunk names, and every Lua value crossing the
C boundary are untrusted; a script fault is always per-script and never engine-fatal.
The C shim (`elysium_pcall`/`elysium_resume`) is the only code that may
raise/yield/resume/pcall Lua — Swift never calls a raising or metamethod-invoking API.
`ElysiumScript` is the sole Lua owner: no other target may `import CLua` or spell a
`lua_`/`luaL_`/`LUA_`-prefixed identifier, enforced mechanically by `scripts/sqlite-
boundary-scan.swift` (whose `--self-test` proves the rules against the positive/negative
fixtures under `Tests/SecurityScanFixtures/`), not just by convention.

**Guardrails.** A fixed per-environment stdlib allowlist with everything else absent;
frozen, `__metatable`-locked API proxies so nothing reachable from a fresh environment
is writable except a script's own `_ENV`; exact budgets whose trips are recorded
host-side so `pcall` cannot revive a faulted script; a determinism patch set (fixed hash
seed, ordinal-keyed iteration, `strcmp` not `strcoll`, `FP_CONTRACT OFF`) so iteration
order, math, RNG and error text are identical across processes; and hash-pin/provenance
gates (`scripts/clua/rederive.sh`, `CLuaSourceTests`, `scripts/verify-elysium-storage-
release-surface.sh`) that fail closed on drift.

**One reconciliation note.** `design.md`'s prose Manifest lists `scripts/elysium-
storage-api-v1.json` under "must not change," while `manifest.json` (authoritative)
lists it as touchable — and it did change: making `verifySymbolGraph` path-independent
moved that file's `symbolGraphSHA256` field and, in turn, `EXPECTED_STORAGE_API_SHA256`.
Security (code) confirmed this is a sound consequence of an in-manifest scanner
improvement, not an unreviewed edit; every other storage source/API/capability pin
stayed byte-identical to HEAD.

## Functional details

**The C boundary contract.** `elysium_newstate(const elysium_config *, int *errcode) ->
lua_State *` builds one `LuaState` per world session: it asserts the process locale is
pinned, requires a complete `elysium_math_table` (no libm fallback anywhere), installs
`lua_atpanic(elysium_panic)`, the count hook, the pinned incremental-GC parameters
(`pause 200, stepmul 100, stepsize 13`) and the sandbox (built under its own `lua_pcall`),
then returns `NULL` with an `elysium_errcode` (`ELYSIUM_ERR_LOCALE`, `ELYSIUM_ERR_MATH`,
`ELYSIUM_ERR_OPEN`, …) on refusal rather than aborting. `hostDepth` lives on a per-entry
frame: the permanent resting frame starts at 1 ("Swift owns the state"); every
`elysium_pcall`/`elysium_resume` pushes a fresh frame at 0 onto a 16-deep entry stack
(`ELYSIUM_MAX_ENTRY_DEPTH`; a deeper nesting is refused as a `.hostAbort` "nesting too
deep" fault) and pops it on return, and the trampoline (`elysium_tramp`, the one
`lua_CFunction` behind every host function and handle metamethod) increments it around
the Swift dispatcher. The count
hook and the allocator may only raise, yield, or return `NULL` when `hostDepth == 0`;
above that the allocator always satisfies the request (`overCapHost` past the cap plus a
1 MiB diagnostic slack). A raise can therefore only unwind C frames between the raise
site and the nearest protected entry — never a Swift frame. The dispatcher's return
status maps to Lua results (`r >= 0`), an error (`r == -1`), or a yield (`r <= -2`).

**Budgets** (`ScriptBudgets.defaults`; the instruction, allocation, memory, log and
thread-pool fields reach the shim through `elysium_config` and the value, source,
chunk-name and fault-text caps are enforced Swift-side — all of those test-overridable):
instruction slice `handlerSliceInstructions` 5,000, coroutine-lifetime total
`handlerTotalInstructions` 100,000, scheduler-enforced `perTickInstructions` 50,000 /
`perTickBucket` 250,000 and `maxConsecutivePreemptions` 20. The Core scheduler charges at least one
1,000-instruction hook quantum per resume, retains overrun debt, backpressures the event recipient
cursor when empty, reserves one quantum for each downstream phase lane, and caps suspended
coroutines at 64 per script and 1,024 per world; allocation-rate `allocationRatePerSliceBytes`
2 MiB per slice; hard `memoryCapBytes` 16 MiB with `hostOverCapDiagnosticBytes` 1 MiB
slack; `threadPoolMax` 256 pooled threads; `logLineBytes` 512 / `logLinesPerSlice` 256
for `print`. Every standard-library verb that can do unbounded work is capped: pattern
matching costs at most `ELYSIUM_MATCH_STEPS` (100,000) steps per call, string/table
results (`rep`, `format`, `pack`, `gsub`, `concat`, positional `insert`/`remove`) top
out at 65,536 elements or bytes, and the vendored `lvm.c luaV_concat` enforces
`ELYSIUM_MAX_STRING` (262,144 bytes) so no script-visible string, however produced,
exceeds 256 KiB (the full per-verb table is in `specs/script-sandbox-and-budgets/spec.md`).
Those per-verb caps are compile-time constants in `elysium_sandbox.c`; the matching
`ScriptBudgets` fields (`patternSubjectBytes` … `utf8SubjectBytes`) mirror them for
reference and are not read by the runtime. `ScriptValueLimits.defaults` (derived from the
same budgets): string 4 KiB, list 256 elements, map 64 keys (each key also ≤ 4 KiB in both
marshal directions), depth 4, nodes 1,024; and on
`ScriptBudgets` itself, source 16 KiB, chunk name 64 B, fault message 512 B, traceback
2 KiB. A slice is soft inside a non-yieldable region (a `table.sort` comparator, a `gsub`
callback, a nested `call` body inside a coroutine's host function); the coroutine total
is hard, and a top-level `call()` with no
enclosing coroutine treats its own slice as hard too, since the main thread cannot
yield.

**Sandbox.** Each `LuaState` opens exactly `base`, `string`, `table`, `math`, `utf8` via
`luaL_requiref` (never `coroutine`/`os`/`io`/`package`; `linit.c` is not linked). Every
light C function in `_G`, `string`, `table`, `math`, `utf8` and the string metatable is
rewrapped as a one-upvalue C closure so no light C function or light userdata is ever
reachable from script code (either would otherwise be hashed by address, breaking
determinism). `load loadfile dofile collectgarbage rawset rawget warn _G string.dump` and the stock
`math.random`/`randomseed` are removed outright; `print`, `setmetatable`, `pairs`/
`ipairs`, the capped `string`/`table`/`utf8` verbs, and
`math.sin/cos/tan/asin/acos/atan/exp/log/log2/log10`/`random`/`randomseed` are shim
wrappers that cap inputs and route transcendentals/RNG through the host.
`math.tan`/`asin`/`acos` were removed outright through change 0-2 (design.md §8.3
"Removed: tan asin acos (v1)") and restored as shim wrappers in
`scripting-ui-and-replication` (change 3) once the fdlibm ports existed to back them;
`math.log2`/`log10` are new in change 3, additive entries alongside the unchanged
`math.log(x[, b])`. `setmetatable` silently drops
`__gc`/`__mode`/`__close` from the copy it installs (the call succeeds without them, so no
finalizer, weak table or to-be-closed variable can ever exist) and installs that frozen
copy; a target whose current metatable the host owns (a frozen proxy's, `_ENV`'s, the
string metatable, a handle-kind metatable, or a prior read-only view's own metatable) is
refused, recognized by an unforgeable marker rather than by the presence of
`__metatable`. Each per-call read-only view carries its own marker (a light-userdata-
keyed raw slot on the view's own locked metatable) instead of an entry in a state-wide
strong-keyed table — closing an audited retention leak (Finding A3-1) where
`setmetatable(obj, Class)` without `__metatable` retained ~336 bytes per call for the
`LuaState`'s life; per-view marking reclaims that memory under `collectFull`. Every
library/API table reachable from an environment is a per-environment frozen proxy
(`__index` → hidden copy, `__newindex` raises, `__len`/`__pairs` read without exposing
the hidden table); `_ENV` alone is writable.

**Determinism.** The eleven-file patch set (`scripts/clua/elysium.patch`) fixes the hash
seed (`luai_makeseed` → `0x454C5953u`), disables random pivot selection
(`l_randomizePivot() = 0`), hashes every collectable table key by a monotonic per-object
`ordinal` instead of its address (`mainpositionTV`), makes `luaL_tolstring`'s default
case address-free, removes `luaL_testudata`/`luaL_checkudata` (their `_test` substring
is on the release-surface denylist), pins the locale decimal point and `strcmp` (not
`strcoll`), turns off FP contraction, adds the matcher step budget, and stubs
`lundump.c` against bytecode.
`math.sin/cos/tan/asin/acos/atan/exp/log/log2/log10` and `^` route through `ScriptMath`
(never libm; change 3 added tan/asin/acos/log2/log10 to the table);
`math.random`/`randomseed` draw from the environment's `ScriptRandomStream`; a state
refuses construction unless the process locale is pinned. The `elysmoke` `script runtime
(vs script-runtime goldens)` section runs a fixed corpus through ten checks — state
creation, a sandbox-surface hash, four corpus hashes, an address-free scan of
script-visible text and two budget-trip ordinals, against
`goldens/script-runtime-goldens.json` — then perturbs the heap and reproduces every value
in a second state — cross-heap, cross-process evidence that order, math, RNG and error
text are pure functions of operation history, never of memory addresses.

**`ScriptValue`, marshaling and handles.** `ScriptValue` is `null | bool | int(Int64) |
number(Double)` (finite, `-0` → `0`) `| string | list | map | ref(String)`, capped as
above; a table with exactly keys `1...n` marshals as `list`, string-only keys as `map`,
anything else is a deterministic error. `HostCall.arguments` gives host functions
`ScriptArgument.value/.function/.handle/.unsupported` so a handler can ask for a raw Lua
function or handle explicitly. `registerHandleKind(name:dispatch:interned:) ->
HandleKind` builds one metatable per kind whose `__index` resolves method names to
cached bound C closures (`h:m()` and `h.m()` both work), `__eq` compares `(kind, ref)`,
`__tostring` returns the ref; `makeHandle(kind:ref:id:)` registers a ref with the state's
resolver (returned as `ScriptValue.ref`, materialized as userdata when pushed) and
`invalidateHandle(ref:)` retires it.

**DetMath ports.** `detExp`/`detLog`/`detPow` (plus private `detScalbn`) are fdlibm 5.3c
`e_exp.c`/`e_log.c`/`e_pow.c` ports in `Sources/ElysiumCore/Core/DetMath.swift`, in the
same word-access style as the existing `detSin`/`detCos`/`detAtan2`; none traps for any
input, and each is pinned against `goldens/fmath-explog-goldens.json`, produced once by
an independently rebuilt netlib fdlibm reference (`scripts/fdlibm-reference/`) and never
hand-edited or regenerated. `RandomX` gains `init(stateWords:)`/`stateWords`
additively; `nextGaussian` and `gameRng` are byte-identical to before.

**Fault handling.** `ScriptFault` carries a `ScriptFaultKind` (`.compile`, `.runtime`,
`.instructionBudget`, `.allocationRate`, `.memoryCap`, `.hostAbort`, `.invalidYield`), a
sanitized `message` (≤ 512 B) and an address-free `traceback` (≤ 2 KiB); `resume`
returns `ScriptResumeOutcome.completed/.yielded/.faulted` and `call` returns
`ScriptCallOutcome.success/.failure`. Any budget or memory trip is recorded host-side
before the call returns, so the coroutine reports `.faulted` and closes regardless of
Lua's own status — `pcall` cannot revive its own exhaustion.

**Public API (stable for later changes).** `LuaState` (`init(budgets:math:log:) throws`,
`isDead`, `memoryStatus`, `collectStep(kilobytes:)`/`collectFull()`, `close()`,
`checkSyntax`, `makeEnvironment`, `registerHandleKind`, `makeHandle`/
`invalidateHandle`, `makeCoroutine`/`resume`/`close(_:)`, `call`), `ScriptEnvironment`
(`compile`, `destroy`, `name`), `ScriptFunction`, `ScriptCoroutine`, `HandleKind`/
`HandleRef`/`HandleDispatch`, `ScriptValue`/`ScriptValueLimits`/`ScriptValueError`,
`ScriptBudgets`, `ScriptMath`, `ScriptRandomStream`, `ScriptTextHygiene`,
`ScriptValidator`/`ScriptValidation`, `ScriptFault`/`ScriptFaultKind`,
`ScriptResumeOutcome`/`ScriptCallOutcome`, `ScriptYieldReason`, `ScriptLogSink` (the
`log:` sink; provisional shape), `ScriptMemoryStatus` (`memoryStatus`'s field set;
provisional), `HostBinding`/`HostFunction`/`HostCall`/`ScriptArgument`/`HostResult`, and
`LuaRuntimeError`'s lifecycle/identity cases (`.localeNotPinned` through
`.handleRefConflict`; the four construction refusals, `.stateBusy`, `.stateMismatch` and
`.handleRefConflict` are thrown today, while re-entrant-resume, dead-coroutine and
nesting refusals surface as `.hostAbort` faults rather than thrown errors).
`ElysiumScript` never imports `ElysiumCore`; `ScriptHostMath.deterministic` (in
`ScriptHostBindings.swift`) supplies the shipped app's `ScriptMath`, and `RandomX`
conforms to `ScriptRandomStream` additively.

**Gates.** `swift run -c release elysmoke` reports 469 checks across 17 suites (up from
457 pre-change): two new fdlibm exp/log/pow probe checks plus the ten-check
script-runtime section; `--bench-scripts` reports µs-per-operation rows (per 1k
instructions, per host call, per handle call, per environment, per thread cycle,
emergency-GC latency, plus three C-step cost rows: flooded-hash lookup, sparse `next`
scan, 256 KiB string compare) against the programme's Luau-fallback rule (flag if µs/1k
instructions exceeds 40 — measured at 1.6–1.7 µs across the Build and Test runs,
comfortably inside the 50,000-instruction, 2 ms per-tick budget). `scripts/clua/rederive.sh` and
`CLuaSourceTests` re-derive/hermetically verify `Sources/CLua`'s provenance; the
scanner/security-scan/release-surface gates named in Scope enforce the rest.

## Usage

Construct one `LuaState` per world session, build a sandboxed environment, compile a
chunk against its own private `_ENV`, and call it — two environments never see each
other's globals (spec "Globals are private per environment"):

```swift
import ElysiumScript
import ElysiumCore // ScriptHostMath, RandomX

let state = try LuaState(budgets: .defaults, math: ScriptHostMath.deterministic, log: mySink) // mySink: any ScriptLogSink
let env = state.makeEnvironment(name: "npc-42", random: RandomX(7))
switch env.compile(source: "counter = (counter or 0) + 1; return counter", chunkName: "npc-42") {
case .success(let fn):
    let outcome = try state.call(fn, args: [], slice: 5_000) // .success([.int(1)]) or .failure(fault)
case .failure(let fault):
    break // compile refused: fault.kind == .compile, fault.message names the reason
}
```

A host function returning `.error` surfaces as an ordinary, `pcall`-catchable Lua error
without unwinding any Swift frame (spec "Host function error"); a monkey-patch attempt
such as `math.floor = 1` or `getmetatable(_ENV).__index.print = 1` always raises instead
of mutating shared state (spec "Monkey-patch attempts fail").

Coroutines preempt exactly: `try state.resume(co, args: [], slice: 5_000)` on a coroutine
`co` from `try state.makeCoroutine(function: fn)` running a long loop returns
`.yielded(.preempted)` after exactly 5,000 counted instructions, and
resuming again with no arguments continues at the interrupted instruction — never
skipping or repeating one (spec "Preemption resumes at the same instruction").

A script running `while true do pcall(function() while true do end end) end` cannot
outrun its own budget: it faults `.instructionBudget` once `handlerTotalInstructions` is
reached and its thread closes regardless of the `pcall` (spec "pcall cannot revive a
budget fault"). A 257-element list, a 65-key map, or a 4,097-byte string passed to a
host function is refused naming the exceeded cap (spec "Caps enforced"), and
`("a"):rep(8000):find((".-"):rep(8) .. "b")` raises `"pattern too complex"` within the
same slice instead of hanging the process (spec "Pattern bomb terminates").
`state.registerHandleKind(name:dispatch:interned:)` lets scripts call back into host
objects through both `h:m()` and `h.m()`, with deterministic, address-free equality and
iteration (spec "Method call forms", "Transient handle equality").

Before a script ever reaches `compile`, `ScriptValidator.validate(source:chunkName:using:
state)` runs stages 0–3 and returns `.accepted(sourceSHA256:)` or
`.refused(stage:message:hint:line:)`: a source containing U+202E or a C1 control is
refused at stage 0 with its line number and no compilation is attempted, `local debug =
1 … debug + 1` and `self.os.x` pass stage 2, and a bare top-level `require("x")` is
refused with the hint that `require` is not part of the sandboxed API (spec "Hygiene
refusal", "Lint never refuses declared locals"). A memory-cap trip is per-script too:
`while true do pcall(function() t[#t+1] = ("x"):rep(1000) end) end` under a
`ScriptBudgets` whose `memoryCapBytes` is shrunk to 1 MiB returns `.faulted` with kind
`.memoryCap` after a deterministic number of accepted allocations, the thread closes, at
most two allocator refusals follow the trip, and `memoryStatus.tripped` reads `false`
again for the next script on the same state (spec "Memory cap trips even under pcall").

Run the gates locally before trusting a change to this runtime: `scripts/clua/
rederive.sh` (exit 0 on no drift; `--tarball PATH` runs it offline against a local copy
of the pinned tarball), `bash scripts/security-scan.sh`, `scripts/verify-
elysium-storage-release-surface.sh`, and `swift run -c release elysmoke` (expect `469
passed, 0 failed`, run twice to confirm the script-runtime section is byte-identical
across processes). Verification for this Candidate runs those gates plus the full
`swift test` suite — `ElysiumScriptTests`, `Tests/ElysiumCoreTests/
DetMathExpLogPowTests`, and the pre-existing suites (`ElysiumTextInputTests`,
`ElysiumResourcePackTests`, `ElysiumDebugProtocolTests`, `ElysiumCoreTests`,
`ElysiumAppSupportTests`) unchanged in shape — with an independent Test pass layering
seeded fuzz/property/metamorphic coverage (program generation, marshaling round trips,
pattern and handle fuzzing, load/stress/resilience) on the same suite names, and the
elysmoke check count moved from 457 to 469 everywhere it is pinned
(`scripts/pipeline.sh`, `README.md`, `CONTRIBUTING.md`, `ARCHITECTURE.md`, `AGENTS.md`).
