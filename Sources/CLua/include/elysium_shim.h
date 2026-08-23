/*
** elysium_shim.h — the entire C boundary Swift is allowed to see (design.md
** Decision 4). ElysiumScript's Swift files call only what is declared here (plus the
** raw, non-raising lua.h/lauxlib.h/lualib.h API); every raise/yield/resume/pcall/load
** happens inside CLua's own C, never in Swift (spec "Only C raises, yields, resumes
** or calls Lua; Swift never does").
**
** Naming: every symbol here is prefixed 'elysium_' or 'ELYSIUM_', including the
** static inline wrappers for lua.h function-like macros Swift's importer cannot see
** through 'import CLua' (macros are not exposed to Swift). Swift never spells a raw
** 'lua_'/'luaL_'/'LUA_' identifier (scanner-enforced, spec "Sole-Lua-owner").
*/

#ifndef elysium_shim_h
#define elysium_shim_h

#include <stddef.h>
#include "lua.h"
#include "lauxlib.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------------
** Status codes returned by elysium_pcall / elysium_resume / thread management.
** ---------------------------------------------------------------------- */
#define ELYSIUM_OK                        0  /* completed; results on the stack */
#define ELYSIUM_YIELD                     1  /* yielded; yieldReason/payload valid */
#define ELYSIUM_ERRRUN                    2  /* ordinary Lua error; message on stack */
#define ELYSIUM_FAULT                     3  /* host-recorded trip forced a close */
#define ELYSIUM_ERR_REENTRANT             4  /* C20: target thread already running */
#define ELYSIUM_ERR_NESTING               5  /* C21: entry-stack depth exceeded */
#define ELYSIUM_ERR_BUSY                  6  /* C20: close() while hostDepth != 1 */
#define ELYSIUM_ERR_DEAD                  7  /* resume of a dead/closed coroutine */
#define ELYSIUM_ERR_LOCALE                8  /* newstate: locale probe failed */
#define ELYSIUM_ERR_MATH                  9  /* newstate: math table incomplete */
#define ELYSIUM_ERR_ALLOC                10  /* newstate: allocation failure */
#define ELYSIUM_ERR_OPEN                 11  /* newstate: sandbox construction failed */

/* Yield reason tags (elysium_resume_result.yieldReason, ELYSIUM_YIELD status only). */
#define ELYSIUM_YIELD_NONE                0
#define ELYSIUM_YIELD_PREEMPT             1
#define ELYSIUM_YIELD_WAIT                2
#define ELYSIUM_YIELD_AWAIT               3

/* Fault kinds (elysium_resume_result.faultKind, ELYSIUM_FAULT/ELYSIUM_ERRRUN status). */
#define ELYSIUM_FAULT_NONE                0
#define ELYSIUM_FAULT_RUNTIME             1
#define ELYSIUM_FAULT_INSTRUCTION_BUDGET  2
#define ELYSIUM_FAULT_ALLOCATION_RATE     3
#define ELYSIUM_FAULT_MEMORY_CAP          4
#define ELYSIUM_FAULT_HOST_ABORT          5
#define ELYSIUM_FAULT_INVALID_YIELD       6
#define ELYSIUM_FAULT_COMPILE             7

/* ------------------------------------------------------------------------
** Math and logging seams (design.md Decision 11): Swift supplies these at
** construction so CLua never falls back to libm for script-visible math.
** ---------------------------------------------------------------------- */
typedef double (*elysium_math_unary_fn) (double x);
typedef double (*elysium_math_binary_fn) (double x, double y);

typedef struct elysium_math_table {
  elysium_math_unary_fn sin;
  elysium_math_unary_fn cos;
  elysium_math_unary_fn exp;
  elysium_math_unary_fn log;
  elysium_math_binary_fn atan2;
  elysium_math_binary_fn pow;
} elysium_math_table;

/* Host log sink (print, panic diagnostics). 'envId' identifies the environment that
** produced the line (0 is a reserved sentinel used for state-level diagnostics that
** are not attributable to one environment, e.g. the panic handler). 'utf8' is not
** NUL-terminated; 'len' is exact and never exceeds ScriptBudgets.logLineBytes for a
** print-originated call.
*/
typedef void (*elysium_log_fn) (void *swiftContext, unsigned long long envId,
                                 const char *utf8, size_t len);

/* The dispatcher every host-function/handle-metamethod trampoline call reaches
** (design.md Decision 4, "Trampoline status protocol"). Registered once, by value,
** through elysium_set_dispatch — a non-capturing Swift @convention(c) closure.
** 'fid' identifies the HostFunction/handle method; return value is the status:
**   r >= 0   -> r results already pushed on top of L's stack
**   r == -1  -> exactly one error object pushed on top of L's stack
**   r <= -2  -> yield -(r + 2) values already pushed on top of L's stack
*/
typedef int (*elysium_dispatch_fn) (lua_State *L, int fid, void *swiftContext);

/* The one lua_CFunction every host-function and handle-metamethod closure shares
** (Decision 4, Rule 1). To register a host function under 'fid', push it as
** elysium_push_host_function(L, fid) — equivalent to (and exactly what that helper
** does) pushing 'fid' then lua_pushcclosure(L, elysium_tramp, 1); the raw symbol is
** exposed too because a handle method closure needs a *second* upvalue (the bound
** handle) that the helper does not thread through.
*/
int elysium_tramp (lua_State *L);
static inline void elysium_push_host_function (lua_State *L, int fid) {
  lua_pushinteger(L, fid);
  lua_pushcclosure(L, elysium_tramp, 1);
}

/* ------------------------------------------------------------------------
** State construction.
** ---------------------------------------------------------------------- */
typedef struct elysium_config {
  elysium_math_table math;          /* every field required; see elysium_newstate */
  elysium_log_fn logFn;             /* required */
  void *swiftContext;               /* opaque; handed back to the dispatcher/logFn */
  unsigned long long identity;      /* C30: unique per-state id, host-assigned */
  unsigned long long memoryCapBytes;
  unsigned long long hostOverCapDiagnosticBytes;
  unsigned long long allocationRatePerSliceBytes;
  unsigned long long handlerTotalInstructions;
  int logLineBytes;
  int logLinesPerSlice;
  /* F2 (design.md Decision 7): the idle pooled-thread cap (ScriptBudgets.threadPoolMax);
  ** negative is clamped to 0 (no pooling — every close fully releases its thread).
  */
  int threadPoolMax;
} elysium_config;

/* Allocates and fully constructs a sandboxed state (locale probe, allocator,
** panic handler, count hook, incremental GC parameters, and the sandboxed
** base/string/table/math/utf8 libraries — all under Decision 4 Rule 4 / C27
** protected construction). Returns NULL and sets *errcode on any failure; the
** partial state is fully torn down before returning (no leak on failure).
*/
lua_State *elysium_newstate (const elysium_config *config, int *errcode);

/* Refused (ELYSIUM_ERR_BUSY) while any elysium_pcall/elysium_resume entry is active
** on this state (hostDepth != 1 at the resting frame) — C20.
*/
int elysium_close (lua_State *L);

/* Process-global; call exactly once before the first elysium_newstate (every state
** shares one trampoline dispatcher, matching a process-wide HostFunction registry
** keyed by state identity + fid on the Swift side).
*/
void elysium_set_dispatch (elysium_dispatch_fn dispatch);

/* ------------------------------------------------------------------------
** Loading, calling, resuming.
** ---------------------------------------------------------------------- */

/* Text-only load (mode "t"; a binary-signature chunk is refused before the stub
** loader in lundump.c would even be reached). On success pushes the function; on
** failure pushes a sanitized error message. Returns LUA_OK/LUA_ERRSYNTAX/LUA_ERRMEM
** (elysium_loadtext does not touch hostDepth — loading cannot raise past itself).
*/
int elysium_loadtext (lua_State *L, const char *buf, size_t len, const char *chunkname);

typedef struct elysium_resume_result {
  int nres;                              /* result/yielded value count (OK/YIELD) */
  int yieldReason;                       /* ELYSIUM_YIELD_*, valid when status==ELYSIUM_YIELD */
  long long yieldPayloadInt;             /* .wait(ticks) */
  unsigned long long yieldPayloadToken;  /* .await(token) */
  int faultKind;                         /* ELYSIUM_FAULT_*, valid on FAULT/ERRRUN */
  /* C20 (Builder fix, found by testCloseCoroutineFromInsideItsHostFunctionIsDeferred):
  ** non-zero when close(coroutine) was requested from inside 'co's own host function
  ** during this resume. elysium_resume itself does NOT reset/pool 'co' in this case —
  ** doing so before the caller reads nres/faultKind results or a fault's traceback off
  ** 'co's own stack (lua_closethread wipes that stack) would read a just-reset thread,
  ** which is exactly the crash this field exists to avoid. The caller MUST finish
  ** reading everything it needs from 'co' first, then call elysium_closethread(L, co)
  ** itself (which by then finds 'co' no longer on the entry stack and performs the
  ** real reset) whenever this flag is set.
  */
  int closeDeferred;
} elysium_resume_result;

/* Synchronous host->Lua call of the function already on top of L's stack, above its
** 'nargs' arguments (design.md Decision 4: "the only synchronous host->Lua call
** form"; never yieldable — an attempted yield inside becomes ELYSIUM_FAULT_INVALID_YIELD).
** A hard slice applies when no enclosing coroutine enclosed this entry (C35).
*/
int elysium_pcall (lua_State *L, int nargs, int nresults, long long slice,
                    elysium_resume_result *out);

/* Resumes coroutine 'co' (created by elysium_newthread) with 'nargs' values already
** pushed on co's stack. Refuses re-entrancy (ELYSIUM_ERR_REENTRANT) without calling
** lua_resume (C20). Any trip flag recorded during the resume forces ELYSIUM_FAULT and
** closes+pools the thread regardless of the underlying Lua status (D5).
*/
int elysium_resume (lua_State *L, lua_State *co, int nargs, long long slice,
                     elysium_resume_result *out);

/* A pooled (or fresh) coroutine thread, anchored in the registry so it survives GC
** while the host holds it. Its extraspace and count hook are freshly installed.
*/
lua_State *elysium_newthread (lua_State *L);

/* Additive (Builder, Lane C): equivalent to elysium_newthread(L) followed by pushing
** the value anchored at registry ref 'functionRef' onto the new thread's own stack —
** the "push the main function" step Lua's coroutine-start convention requires before
** the first elysium_resume. Swift cannot do this itself with two separate calls:
** moving a value from one lua_State* to another (lua_xmove) is not on the Rule 2
** allowed Swift surface, and only C may touch it. Returns NULL (matching
** elysium_newthread) on host-side allocation failure; 'functionRef' must name a
** function value already anchored in L's registry (ScriptEnvironment.compile's
** result).
*/
lua_State *elysium_newthread_with_function (lua_State *L, int functionRef);

/* Resets 'co' (lua_closethread), restores its hook/allowhook (C19), and either
** returns it to the idle thread pool (design.md Decision 7) or, once the pool
** already holds threadPoolMax idle threads, releases the registry anchor obtained
** from elysium_newthread and frees its bookkeeping — never both. If 'co' is
** currently running, the close is deferred to the outermost elysium_resume of
** 'co' (C20) and this call returns immediately.
*/
void elysium_closethread (lua_State *L, lua_State *co);

/* Pushes a capped, address-free traceback string for 'co' onto co's own stack and
** returns its byte length (the caller reads it with elysium_tolstring(co, -1, &len)
** and then elysium_pop(co, 1)).
*/
size_t elysium_traceback (lua_State *co, size_t maxBytes);

/* Called by the dispatcher, before returning a yield status (r <= -2), to record
** *why* the coroutine is yielding. 'invalidYield' non-zero means the trampoline
** could not honor a yield attempt (non-yieldable point) and will fault instead
** (C29) — 'tag'/payload are ignored in that case.
*/
void elysium_set_yield_reason (lua_State *L, int tag, long long payloadInt,
                                unsigned long long payloadToken);

typedef struct elysium_memory_status {
  unsigned long long bytesInUse;
  unsigned long long cap;
  int tripped;
  int rateTripped;
  int overCapHost;
  unsigned long long allocationCalls;
  unsigned long long emergencyCollections;
} elysium_memory_status;

void elysium_memory_status_get (lua_State *L, elysium_memory_status *out);

/* Additive (Builder, object-graph-attributes change 1a carry-forward N4-2 /
** design.md Decision 12): the sandbox's numeric library caps
** (elysium_sandbox.c's string/table/utf8 wrappers) are compile-time literals
** with no Swift-visible name of their own; ScriptBudgets used to duplicate
** them as ten mutable fields nothing ever read. This getter is their one
** source of truth on the Swift side (ScriptLibraryCaps.current mirrors it
** read-only) — the values themselves are unchanged, only how Swift observes
** them.
*/
typedef struct elysium_library_caps_t {
  int patternSubjectBytes;   /* string.find/match/gmatch/gsub subject cap */
  int patternBytes;          /* string.find/match/gmatch/gsub pattern cap */
  int matchSteps;            /* ELYSIUM_MATCH_STEPS, luaconf.h */
  int resultBytes;           /* gsub/format/pack/rep/concat result cap */
  int byteRangeBytes;        /* string.byte requested range cap */
  int sortElements;          /* table.sort element-count cap */
  int unpackResults;         /* table.unpack result-count cap */
  int moveElements;          /* table.move element-count cap */
  int utf8SubjectBytes;      /* utf8.codepoint/len/offset/codes subject cap */
  int formatConversions;     /* string.format conversion-count cap */
  int maxStringBytes;        /* ELYSIUM_MAX_STRING, luaconf.h */
} elysium_library_caps_t;

elysium_library_caps_t elysium_library_caps (void);

/* Clears the state-wide diagnostic trip flags (tripped/rateTripped/overCapHost);
** does not affect any coroutine's totalUsed/budgetTripped.
*/
void elysium_reset_trips (lua_State *L);

/* Additive (Builder, Lane C): the coroutine-lifetime instruction total
** (elysium_coroutine_budget.totalUsed, elysium_internal.h) backing the public
** ScriptCoroutine.instructionsUsed counter (design.md Decision 17); there is no other
** way for Swift to read it (it lives in a private struct alongside every thread's
** extraspace, not in elysium_resume_result — which only ever reports the *outcome* of
** one resume, not the coroutine's running total).
*/
unsigned long long elysium_thread_instructions_used (lua_State *co);

/* F2 (Builder, thread-pool regression coverage): the state's current idle
** pooled-thread count (elysium_state.poolCount) — never exceeds threadPoolMax
** (design.md Decision 7). Non-raising, non-allocating.
*/
int elysium_pool_count (lua_State *L);

/* GC is host-stepped only (D5); no other lua_gc mode is reachable (C26). */
void elysium_gc_step (lua_State *L, int kilobytes);
void elysium_gc_full (lua_State *L);

/* Routes a host log line (already capped/hygiene-filtered) to the configured sink. */
void elysium_host_log (lua_State *L, unsigned long long envId, const char *utf8, size_t len);

/* ------------------------------------------------------------------------
** Sandbox construction seams used by ScriptEnvironment/Handles (design.md
** Decisions 8 and 10). Implemented in elysium_sandbox.c.
** ---------------------------------------------------------------------- */

/* Builds a fresh environment: per-environment hidden copies of the sanitized
** library masters, a frozen API proxy, and a private writable _ENV table whose
** __index is that proxy. 'envId' is opaque host bookkeeping threaded through the
** reserved-fid dispatch (print/random/randomseed). Pushes the new _ENV table onto
** the top of L's stack and returns a registry reference to it (Swift anchors it with
** the ordinary raw API — luaL_ref(L, LUA_REGISTRYINDEX) is on the allowed surface —
** so this entry point pushes rather than refs, leaving the choice to the caller;
** the returned int is the ref this function itself took, kept alive until
** elysium_destroy_environment so the shim's own bookkeeping — the host-owned-marker
** set used by the setmetatable ownership rule (C23) — can find _ENV by ref).
*/
int elysium_make_environment (lua_State *L, unsigned long long envId);

/* Destroys the registry-anchored _ENV table (its ref becomes invalid); does not
** affect any other environment. Reserved-fid dispatch for this envId must be made
** to fail on the Swift side afterward (C30).
**
** F3 (Builder, environment-destroy reclamation fix): 'envId' identifies this
** environment's manifest of host-owned objects (elysium_make_environment /
** elysium_freeze_table register into it) so this call can un-mark every one of
** them from the state-wide host-owned set (elysium_sandbox.c's
** ELYSIUM_HOSTOWNED_KEY table) before dropping the manifest itself — otherwise
** that table's own strong key references keep the whole per-environment object
** graph (hidden tables, proxies, _ENV's metatable) reachable forever, regardless
** of envRef being unref'd. The caller (ScriptEnvironment.destroy()) is also
** responsible for releasing the environment's compiled-chunk ScriptFunction refs
** and Swift-side fidTable entries — this call only owns the C-side object graph.
*/
void elysium_destroy_environment (lua_State *L, int envRef, unsigned long long envId);

/* Registers one handle kind's metatable (once per kind, per state) and returns its
** small non-negative kind id, used by elysium_make_handle and encoded in the fids
** the trampoline dispatches __index/__newindex/__eq/__tostring to (base fid + 0..3,
** passed back out via *baseFid so Swift can register the four HandleDispatch
** entries under known ids).
*/
int elysium_register_handle_kind (lua_State *L, const char *name, size_t nameLen,
                                   int interned, int *baseFid);

/* Pushes a handle userdata for (kindId, id, ref) onto L's stack. For an interned
** kind, returns the existing userdata if 'ref' was already seen (and not since
** invalidated); for a non-interned kind, always creates a fresh userdata (distinct
** identity, equal by ref via __eq).
*/
void elysium_make_handle (lua_State *L, int kindId, unsigned long long id,
                           const char *ref, size_t refLen, int interned);

/* Removes an interned handle's ref -> userdata registration so a later
** elysium_make_handle for the same ref creates a fresh (unequal) userdata.
** No-op for a ref that was never interned or already invalidated.
*/
void elysium_invalidate_handle (lua_State *L, int kindId, const char *ref, size_t refLen);

/* Additive (Builder, Lane C): the handle userdata payload {kindId, id} is a private
** C struct (elysium_handle_payload in elysium_sandbox.c) so Swift's __index/__newindex/
** __eq/__tostring dispatch — which only receives a raw stack index for the handle
** argument, never the payload layout — cannot read it by any means on the Rule 2
** allowed surface. These two accessors are the minimal seam that avoids mirroring the
** C struct's layout in Swift (fragile) or exposing the struct itself in the public
** header (a raw-pointer leak). Both are non-raising: an idx that is not a handle
** userdata of the expected size yields the documented sentinel rather than an error.
*/
int elysium_handle_kind (lua_State *L, int idx);              /* -1 if not a handle */
unsigned long long elysium_handle_id (lua_State *L, int idx); /* 0 if not a handle */

/* Additive (Builder, Lane C): wraps the table already at 'idx' in the same frozen,
** host-owned read-only proxy machinery elysium_make_environment uses for string/
** table/math/utf8 (D8's "empty table + metatable {__index = hidden, ...}" shape),
** replacing it in place. Used by ScriptEnvironment when a HostBinding tree (Decision
** 17's stable makeEnvironment(hostBindings:) parameter — empty in this change, since
** no host API table exists before 1a) contributes a nested table: it must be
** sandboxed exactly like every other library table (Condition 7), not left as a
** plain writable table reachable from _ENV. F3: 'envId' registers the fresh
** proxy's metatable into that environment's manifest (see
** elysium_destroy_environment) exactly like elysium_make_environment's own
** library proxies, so a host-binding table tree is reclaimed on destroy too.
*/
void elysium_freeze_table (lua_State *L, int idx, unsigned long long envId);

/* ------------------------------------------------------------------------
** static inline wrappers for lua.h function-like macros (Swift's Clang importer
** cannot see through #define; every one of these is a thin, non-raising, exact
** pass-through — Decision 4's "elysium_-prefixed wrappers" list).
** ---------------------------------------------------------------------- */
/* Additive (Builder, Lane C): LUA_REGISTRYINDEX expands to '(-LUAI_MAXSTACK - 1000)',
** an arithmetic macro Swift's ClangImporter refuses to import ("structure not
** supported") — unlike the simple-literal ELYSIUM_* macros and status codes above it,
** there is no way for Swift to spell it at all without this wrapper. Every one of
** ElysiumScript's raw registry table operations (luaL_ref/unref, lua_rawgeti/rawseti,
** the compiled-chunk `_ENV` upvalue swap) needs this index.
*/
static inline int elysium_registryindex (void) { return LUA_REGISTRYINDEX; }

static inline void elysium_pop (lua_State *L, int n) { lua_pop(L, n); }
/* F1 (Builder, stack-leak fix): lua_settop to an index the caller itself recorded
** (always <= the current top on every call site in this package) only ever
** shrinks or leaves the stack unchanged, so it can never need to grow it — safe
** to call outside a protected frame, unlike luaL_checkstack/luaD_growstack.
*/
static inline void elysium_settop (lua_State *L, int idx) { lua_settop(L, idx); }
static inline const char *elysium_tostring (lua_State *L, int idx) { return lua_tostring(L, idx); }
static inline lua_Number elysium_tonumber (lua_State *L, int idx) { return lua_tonumber(L, idx); }
static inline lua_Integer elysium_tointeger (lua_State *L, int idx) { return lua_tointeger(L, idx); }
static inline void elysium_newtable (lua_State *L) { lua_newtable(L); }
static inline void elysium_pushcfunction (lua_State *L, lua_CFunction f) { lua_pushcfunction(L, f); }
static inline void elysium_insert (lua_State *L, int idx) { lua_insert(L, idx); }
static inline void elysium_remove (lua_State *L, int idx) { lua_remove(L, idx); }
static inline void elysium_replace (lua_State *L, int idx) { lua_replace(L, idx); }
static inline void *elysium_getextraspace (lua_State *L) { return lua_getextraspace(L); }
static inline int elysium_upvalueindex (int i) { return lua_upvalueindex(i); }
static inline int elysium_isnil (lua_State *L, int idx) { return lua_isnil(L, idx); }
static inline int elysium_istable (lua_State *L, int idx) { return lua_istable(L, idx); }
static inline int elysium_isfunction (lua_State *L, int idx) { return lua_isfunction(L, idx); }
static inline void *elysium_newuserdata (lua_State *L, size_t sz) { return lua_newuserdata(L, sz); }
static inline void elysium_pushglobaltable (lua_State *L) { lua_pushglobaltable(L); }

#ifdef __cplusplus
}
#endif

#endif
