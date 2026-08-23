/*
** elysium_internal.h — private structures shared by elysium_shim.c and
** elysium_sandbox.c (never installed under include/, so ElysiumScript cannot see it;
** the public contract is entirely in include/elysium_shim.h).
**
** This file may include Lua's private headers (lstate.h) per Condition 19/2.5 —
** elysium_shim.c and elysium_sandbox.c are the sole-Lua-owner's own C, not the Swift
** boundary the scanner polices.
*/

#ifndef elysium_internal_h
#define elysium_internal_h

#include "lua.h"
#include "lstate.h"
#include "elysium_shim.h"

/* Elysium: the count-hook granularity and the pattern-matcher step budget are
** compile-time constants (design.md Decision 6); they are not part of
** elysium_config because no test needs to change them independently of the
** slice/total values, which *are* runtime-configurable.
*/
#define ELYSIUM_HOOK_GRANULARITY 1000

/* C21: fixed-size nested-entry stack. Index 0 is the permanent resting frame
** (hostDepth == 1, Swift owns the state, no Lua call active); elysium_pcall and
** elysium_resume push frames above it. Exceeding the cap is ELYSIUM_ERR_NESTING.
*/
#define ELYSIUM_MAX_ENTRY_DEPTH 16

/* Per-coroutine budget record (task 1.3 reconciled with 2.7): lives for the whole
** lifetime of one lua_State thread object (persists across pool reuse until the
** owning LuaState is closed), never reset by a nested entry. Reset to zero only
** when a thread is (re)issued to script code as a fresh coroutine (elysium_newthread,
** and again whenever elysium_closethread pools it for reuse — see C19).
*/
typedef struct elysium_coroutine_budget {
  unsigned long long totalUsed;   /* instructions charged over this coroutine's life */
  unsigned long long allocBytes;  /* bytes allocated while this coroutine was current */
  int budgetTripped;              /* 1 once totalUsed exceeded the state's total cap */
} elysium_coroutine_budget;

/* Every lua_State this shim ever hands to Lua (the main thread and every pooled
** coroutine) stores a pointer to one of these in its extraspace slot (C's own
** convention layered on top of stock Lua, which merely copies the main thread's
** extraspace *value* into new threads — elysium_newthread overwrites it with a
** fresh per-thread block right after lua_newthread returns).
*/
typedef struct elysium_thread_ctx {
  struct elysium_state *state;         /* shared state; same for every thread */
  elysium_coroutine_budget budget;     /* this thread's own coroutine totals */
  lua_State *L;                        /* F2 (thread pool): this thread's own lua_State*,
                                        ** set once at creation, so a pooled ctx can be
                                        ** reissued without a fresh lua_newthread */
  int registryRef;                     /* F2: the LUA_REGISTRYINDEX ref anchoring this
                                        ** thread; needed to luaL_unref it on full release */
  int pooled;                          /* F2: 1 while sitting in the idle pool */
  struct elysium_thread_ctx *next;     /* full list of every thread ever created, freed
                                        ** at elysium_close (F2: unlinked early on full
                                        ** release — see elysium_release_thread_ctx) */
  struct elysium_thread_ctx *poolNext; /* F2: idle-pool intrusive list */
} elysium_thread_ctx;

/* C21: one pushed/popped activation record per elysium_pcall/elysium_resume entry.
** entries[entryTop - 1] is always "the current entry" that the count hook and the
** allocator consult.
*/
typedef struct elysium_entry {
  int hostDepth;                        /* D4 Rule 3: 0 while Lua runs under this entry */
  lua_State *currentThread;             /* the thread (main or coroutine) this entry runs */
  elysium_coroutine_budget *budget;     /* owning coroutine's record, or NULL (C35) */
  int hardSlice;                        /* C35: elysium_pcall with no enclosing coroutine */
  long long sliceRemaining;
  unsigned long long sliceAllocRequested;
  int preemptPending;
  int faultPending;
  int faultKind;                        /* ELYSIUM_FAULT_* set when faultPending is raised */
  int yieldReason;                      /* ELYSIUM_YIELD_* */
  long long yieldPayloadInt;            /* .wait(ticks) */
  unsigned long long yieldPayloadToken; /* .await(token) */
  int logLinesThisSlice;
  int closeDeferred;                    /* C20: close(coroutine) requested while running */
} elysium_entry;

/* The shared, per-LuaState struct. The main thread's extraspace slot holds a
** pointer to *its* elysium_thread_ctx, whose 'state' field is this struct.
*/
typedef struct elysium_state {
  lua_State *mainL;
  void *swiftContext;              /* opaque Unmanaged<LuaState> pointer for the dispatcher */
  unsigned long long identity;     /* C30: unique id, set by Swift at construction */
  elysium_math_table math;
  elysium_log_fn logFn;

  unsigned long long bytesInUse;
  unsigned long long cap;                       /* memoryCapBytes */
  unsigned long long diagnosticSlackBytes;       /* hostOverCapDiagnosticBytes */
  unsigned long long rateCapBytes;               /* allocationRatePerSliceBytes */
  unsigned long long totalCap;                   /* handlerTotalInstructions */
  int logLineBytes;
  int logLinesPerSlice;

  int tripped;        /* memory cap trip (state-wide diagnostic flag; see per-entry too) */
  int rateTripped;
  int overCapHost;
  int dead;            /* elysium_close has run; every entry point refuses */

  unsigned long long allocationCalls;
  unsigned long long emergencyCollections;

  elysium_entry entries[ELYSIUM_MAX_ENTRY_DEPTH];
  int entryTop;        /* always >= 1; entries[0] is the permanent resting frame */

  elysium_thread_ctx *threadList;  /* every thread ctx ever allocated, for elysium_close */

  /* F2 (design.md Decision 7, thread pool): idle pooled threads, intrusive-listed via
  ** elysium_thread_ctx.poolNext. elysium_newthread pops from here before ever calling
  ** lua_newthread; elysium_reset_thread pushes here (or fully releases) on close.
  */
  elysium_thread_ctx *pool;
  int poolCount;
  int threadPoolMax;

  int handleKindCount;
} elysium_state;

/* Recover this thread's context / shared state. Every lua_State this shim ever
** hands to Lua has a non-NULL extraspace slot (elysium_newstate/elysium_newthread
** guarantee it), so this is infallible for any L reachable from a host function.
*/
static inline elysium_thread_ctx *elysium_ctx (lua_State *L) {
  return *(elysium_thread_ctx **)lua_getextraspace(L);
}

static inline elysium_state *elysium_state_of (lua_State *L) {
  return elysium_ctx(L)->state;
}

static inline elysium_entry *elysium_current_entry (elysium_state *st) {
  return &st->entries[st->entryTop - 1];
}

/* elysium_sandbox.c entry points used only by elysium_shim.c (state construction). */
int elysium_openlibs (lua_State *L);  /* runs under lua_pcall as a C builder (C27) */

/* elysium_shim.c entry points used by elysium_sandbox.c to build wrapper closures
** and to fire the count hook on freshly created threads. elysium_tramp itself is
** declared in the public elysium_shim.h (Swift needs to register host functions
** with it too); only the count hook is internal-only.
*/
void elysium_count_hook (lua_State *L, lua_Debug *ar);

#endif
