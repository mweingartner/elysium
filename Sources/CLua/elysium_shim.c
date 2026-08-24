/*
** elysium_shim.c — the C boundary (design.md Decision 4). Implements state
** construction/teardown, the allocator (D5), the instruction-count hook (D6), the
** one trampoline every host closure and handle metamethod shares, and the
** pcall/resume entry points. This file (and elysium_sandbox.c) is the only place in
** the whole package allowed to call a raising/yielding/resuming/loading Lua API
** (spec "Only C raises, yields, resumes or calls Lua; Swift never does").
**
** Every comment tag below ("C19", "D5", ...) names the design.md condition or
** decision the adjacent code satisfies.
*/

#include <stdlib.h>
#include <string.h>
#include <locale.h>
#include <ctype.h>

#include "elysium_internal.h"
#include "lauxlib.h"
#include "lualib.h"

/* ==========================================================================
** Locale probe (C27) — this file never changes the process locale; the probe
** below only *reads* it (CLuaSourceTests pins that no file under Sources/ calls
** the locale-mutating libc entry point).
** ======================================================================= */
/* strcoll and strcmp are only specified to agree in *sign* (both < 0, both == 0, or
** both > 0) — POSIX never promises identical magnitudes, and real libc
** implementations routinely return different ones even under the C locale (glibc
** and Apple's libc both do). A literal '==' here would refuse every state on every
** real machine, so the probe compares sign classes instead: same intent (the
** locale must not reorder byte comparisons), a check that actually passes.
*/
static int elysium_same_sign (int a, int b) {
  return (a > 0 && b > 0) || (a < 0 && b < 0) || (a == 0 && b == 0);
}

static int elysium_locale_ok (void) {
  struct lconv *lc = localeconv();
  if (lc == NULL || lc->decimal_point == NULL || lc->decimal_point[0] != '.')
    return 0;
  if (!elysium_same_sign(strcoll("a", "B"), strcmp("a", "B")))
    return 0;
  /* C27: extended probe — a script-visible ctype table that silently differs from
  ** the plain C locale (e.g. a Latin-1 locale where 0xE9 is a lowercase letter)
  ** would make string.upper/lower/format's %a-%s-%w classes diverge by process. */
  if (isalpha(0xE9) != 0) return 0;
  if (toupper(0xE9) != 0xE9) return 0;
  if (isspace(0xA0) != 0) return 0;
  return 1;
}

/* ==========================================================================
** Thread-context bookkeeping.
** ======================================================================= */
static void elysium_free_thread_list (elysium_state *st) {
  elysium_thread_ctx *cur = st->threadList;
  while (cur != NULL) {
    elysium_thread_ctx *next = cur->next;
    free(cur);
    cur = next;
  }
  st->threadList = NULL;
}

/* F2 (design.md Decision 7, thread pool): unlinks 'ctx' from the state's full
** thread list (elysium_free_thread_list walks that list at elysium_close; a
** fully released ctx must not be double-freed there) and frees it. The
** underlying Lua thread object itself is released separately, by dropping its
** registry anchor (luaL_unref) before this is called — Lua's own GC reclaims
** the lua_State struct; this ctx block is a plain calloc'd block Lua does not
** know about and this shim must free itself.
*/
static void elysium_release_thread_ctx (elysium_state *st, elysium_thread_ctx *ctx) {
  elysium_thread_ctx **link = &st->threadList;
  while (*link != NULL) {
    if (*link == ctx) { *link = ctx->next; break; }
    link = &(*link)->next;
  }
  free(ctx);
}

/* C19: restore hook/allowhook and reset the coroutine's own budget so a pooled
** thread is never reused with a stale count-1 re-arm (D5) or stale totals.
**
** F2 (design.md Decision 7, thread pool): previously this only reset 'co' and
** left it anchored forever — elysium_newthread always created a brand-new
** thread regardless, so the state grew without bound across repeated
** makeCoroutine/close cycles (test.md testZZThreadCycles10000NoGrowth). Now:
** return the reset thread to the idle pool when there is room (elysium_newthread
** checks the pool first); otherwise release it fully so the state does not keep
** growing once the pool is saturated.
*/
static void elysium_reset_thread (lua_State *L, lua_State *co) {
  elysium_state *st = elysium_state_of(L);
  elysium_thread_ctx *ctx = elysium_ctx(co);

  co->allowhook = 1;
  lua_sethook(co, elysium_count_hook, LUA_MASKCOUNT, ELYSIUM_HOOK_GRANULARITY);
  lua_closethread(co, L);
  /* F2 (Builder, thread-pool regression found by testFaultedThreadReuseStillBudgeted
  ** et al.): lua_closethread (lstate.c luaE_resetthread) only resets a thread to a
  ** truly empty stack (lua_gettop(co) == 0) when the status it closed *from* was
  ** LUA_OK/LUA_YIELD — luaD_closeprotected has nothing to close (this sandbox never
  ** has to-be-closed variables, Condition 6) and simply returns whatever status it
  ** was given; luaE_resetthread's "if (status != LUA_OK) luaD_seterrorobj(...)"
  ** branch then *pushes a synthesized error object* instead of leaving the stack
  ** empty when that status was an error code (co's own status after a fault —
  ** ELYSIUM_FAULT/ELYSIUM_ERRRUN). Before pooling, no faulted thread was ever
  ** reused (elysium_newthread always created a fresh one), so this one leftover
  ** value was never observable; a pooled/reused thread now starts every later
  ** resume with a bogus extra value already on its stack, which lua_resume then
  ** reports as one of the *coroutine's own* results (elysium_newthread_with_
  ** function's lua_xmove appends the real function above it, so the call target is
  ** still correct — only the reported result count/values are wrong). Force a
  ** truly empty stack unconditionally, regardless of what closethread left behind.
  */
  lua_settop(co, 0);
  ctx->budget.totalUsed = 0;
  ctx->budget.allocBytes = 0;
  ctx->budget.budgetTripped = 0;

  /* F2 (Builder, thread-pool regression found by
  ** testStackGrowthTripUnderInnerPcallDoesNotBrickCoroutineState): luaE_resetthread
  ** (inside lua_closethread above) also calls luaD_reallocstack, sized off
  ** whatever L->top.p was at the moment of reset — for a thread whose stack grew
  ** deep (e.g. the 190-level pcall-chained recursion that test drives) before
  ** faulting, that shrinks the *physical* array down to a bare handful of slots
  ** (top + LUA_MINSTACK), far below a freshly lua_newthread'd thread's initial
  ** BASIC_STACK_SIZE + EXTRA_STACK. Before pooling this was invisible (a shrunk,
  ** faulted thread was simply never reused). Now: grow it back to at least a
  ** fresh thread's own starting size before it goes idle, in this host section
  ** (hostDepth >= 1 here — see elysium_alloc's D5 comment — so this growth is
  ** never itself rate/cap-limited), so a script that later reuses this pooled
  ** thread sees the *same* headroom a brand-new thread would have and does not
  ** need its own mid-script luaD_growstack (which, unlike this one, *would* be
  ** charged against that script's own tiny per-slice allocation-rate budget).
  */
  luaL_checkstack(co, BASIC_STACK_SIZE, "elysium_reset_thread");

  if (st->poolCount < st->threadPoolMax) {
    ctx->pooled = 1;
    ctx->poolNext = st->pool;
    st->pool = ctx;
    st->poolCount++;
  } else {
    luaL_unref(L, LUA_REGISTRYINDEX, ctx->registryRef);
    elysium_release_thread_ctx(st, ctx);
  }
}

/* ==========================================================================
** D5 — the allocator. 'ptr == NULL' means a new block (osize is a type tag, not a
** size, per the Lua manual); frees always succeed. NULL is returned only when
** hostDepth == 0 (a script frame) and only once the state/rate cap is exceeded;
** while hostDepth > 0 the request is always satisfied (overCapHost is a pure
** diagnostic in that case, never a refusal).
** ======================================================================= */
static void elysium_apply_delta (elysium_state *st, long long delta) {
  if (delta > 0) {
    st->bytesInUse += (unsigned long long)delta;
  } else if (delta < 0) {
    unsigned long long shrink = (unsigned long long)(-delta);
    st->bytesInUse = (st->bytesInUse >= shrink) ? st->bytesInUse - shrink : 0;
  }
}

static void *elysium_alloc (void *ud, void *ptr, size_t osize, size_t nsize) {
  elysium_state *st = (elysium_state *)ud;
  st->allocationCalls++;

  if (nsize == 0) {
    if (ptr != NULL) {
      unsigned long long freed = (unsigned long long)osize;
      st->bytesInUse = (st->bytesInUse >= freed) ? st->bytesInUse - freed : 0;
      free(ptr);
    }
    return NULL;
  }

  {
    long long oldsize = (ptr != NULL) ? (long long)osize : 0;
    long long delta = (long long)nsize - oldsize;
    elysium_entry *e = elysium_current_entry(st);

    if (e->hostDepth > 0) {
      /* D5: host sections never see NULL. */
      void *np = realloc(ptr, nsize);
      if (np == NULL) return NULL;  /* genuine process-wide OOM; nothing else to do */
      elysium_apply_delta(st, delta);
      if ((long long)st->bytesInUse > (long long)(st->cap + st->diagnosticSlackBytes))
        st->overCapHost = 1;
      return np;
    }

    /* Script frame: the memory cap and the per-slice allocation-rate budget apply
    ** before the request is ever attempted (so bytesInUse never overshoots cap by
    ** more than one rejected 'nsize').
    */
    if (delta > 0) {
      if ((long long)st->bytesInUse + delta > (long long)st->cap) {
        if (!st->tripped) { st->tripped = 1; st->emergencyCollections++; }
        e->preemptPending = 1;
        lua_sethook(e->currentThread, elysium_count_hook, LUA_MASKCOUNT, 1);
        return NULL;
      }
      if (e->sliceAllocRequested + (unsigned long long)delta > st->rateCapBytes) {
        st->rateTripped = 1;
        e->preemptPending = 1;
        lua_sethook(e->currentThread, elysium_count_hook, LUA_MASKCOUNT, 1);
        return NULL;
      }
    }

    {
      void *np = realloc(ptr, nsize);
      if (np == NULL) return NULL;  /* genuine process-wide OOM */
      elysium_apply_delta(st, delta);
      if (delta > 0) {
        e->sliceAllocRequested += (unsigned long long)delta;
        if (e->budget != NULL) e->budget->allocBytes += (unsigned long long)delta;
      }
      return np;
    }
  }
}

/* ==========================================================================
** D6 — the instruction-count hook, installed with LUA_MASKCOUNT/1000 on every
** thread (main + every coroutine; C19 re-installs it on pooled reuse).
** ======================================================================= */
void elysium_count_hook (lua_State *L, lua_Debug *ar) {
  elysium_state *st;
  elysium_entry *e;
  (void)ar;
  st = elysium_state_of(L);
  e = elysium_current_entry(st);

  if (e->budget != NULL)
    e->budget->totalUsed += ELYSIUM_HOOK_GRANULARITY;
  e->sliceRemaining -= ELYSIUM_HOOK_GRANULARITY;

  /* D5: a memory/rate trip already recorded by the allocator is an unconditional,
  ** hard fault — the hook was re-armed to count 1 specifically to reach here next.
  ** The flag is set *before* raising in every branch below (not only the
  ** hostDepth > 0 one): even when hostDepth == 0 lets us raise immediately via
  ** luaL_error, that raise still needs to read back as a trip-caused ELYSIUM_FAULT
  ** to elysium_pcall/elysium_resume, not an ordinary script ELYSIUM_ERRRUN — the
  ** entry 'e' survives the longjmp (elysium_pcall/elysium_resume pop it only after
  ** lua_pcall/lua_resume returns), so setting it first and raising second is safe.
  */
  if (st->tripped || st->rateTripped) {
    e->faultPending = 1;
    e->faultKind = st->tripped ? ELYSIUM_FAULT_MEMORY_CAP : ELYSIUM_FAULT_ALLOCATION_RATE;
    if (e->hostDepth == 0) {
      luaL_error(L, "%s", st->tripped ? "memory cap exceeded" : "allocation rate exceeded");
      return; /* unreachable: luaL_error longjmps */
    }
    return;
  }

  /* D6: the coroutine-lifetime total cap is always hard, regardless of hardSlice. */
  if (e->budget != NULL && e->budget->totalUsed > st->totalCap) {
    e->budget->budgetTripped = 1;
    e->faultPending = 1;
    e->faultKind = ELYSIUM_FAULT_INSTRUCTION_BUDGET;
    if (e->hostDepth == 0) {
      luaL_error(L, "instruction budget exceeded");
      return; /* unreachable */
    }
    return;
  }

  if (e->sliceRemaining <= 0 || e->preemptPending) {
    if (e->hardSlice) {
      /* C35: elysium_pcall with no enclosing coroutine — the slice itself is hard. */
      e->faultPending = 1;
      e->faultKind = ELYSIUM_FAULT_INSTRUCTION_BUDGET;
      if (e->hostDepth == 0) {
        luaL_error(L, "instruction budget exceeded");
        return; /* unreachable */
      }
      return;
    }
    if (e->hostDepth == 0 && lua_isyieldable(L)) {
      e->preemptPending = 0;
      e->yieldReason = ELYSIUM_YIELD_PREEMPT;
      /* D6: called from inside a hook, lua_yield returns normally here; the VM
      ** re-executes the interrupted instruction once this hook function returns,
      ** so accounting stays exact.
      */
      lua_yield(L, 0);
    } else {
      e->preemptPending = 1;
    }
  }
}

/* ==========================================================================
** Rule 4 — the panic handler. Installed immediately after lua_newstate (C27);
** unreachable by construction (every raise happens under a protected entry), kept
** as defence in depth. Logs through the host sink, then returns -> Lua calls abort().
** ======================================================================= */
static int elysium_panic (lua_State *L) {
  elysium_state *st = elysium_state_of(L);
  const char *msg = lua_tostring(L, -1);
  static const char fallback[] = "unprotected error (non-string error object)";
  if (msg == NULL) msg = fallback;
  if (st->logFn != NULL) st->logFn(st->swiftContext, 0, msg, strlen(msg));
  return 0;
}

/* elysium_numpow: '^' and constant folding route through the host ScriptMath table
** (luaconf.h's local section makes this the definition of luai_numpow for b != 2).
*/
lua_Number elysium_numpow (lua_State *L, lua_Number a, lua_Number b) {
  elysium_state *st = elysium_state_of(L);
  return (lua_Number)st->math.pow((double)a, (double)b);
}

/* ==========================================================================
** Rule 1 — the one trampoline every host function and handle metamethod shares.
** Upvalue 1 is always the integer fid (handle method closures add upvalue 2, the
** bound handle — elysium_sandbox.c reads it directly; the dispatcher itself never
** needs to know the difference).
** ======================================================================= */
static elysium_dispatch_fn g_elysium_dispatch = NULL;

void elysium_set_dispatch (elysium_dispatch_fn dispatch) {
  g_elysium_dispatch = dispatch;
}

static const char *elysium_fault_text (int kind) {
  switch (kind) {
    case ELYSIUM_FAULT_INSTRUCTION_BUDGET: return "instruction budget exceeded";
    case ELYSIUM_FAULT_ALLOCATION_RATE:    return "allocation rate exceeded";
    case ELYSIUM_FAULT_MEMORY_CAP:         return "memory cap exceeded";
    case ELYSIUM_FAULT_INVALID_YIELD:      return "invalid yield";
    case ELYSIUM_FAULT_HOST_ABORT:         return "host aborted";
    default:                               return "script fault";
  }
}

int elysium_tramp (lua_State *L) {
  int fid = (int)lua_tointeger(L, lua_upvalueindex(1));
  elysium_state *st = elysium_state_of(L);
  elysium_entry *e = elysium_current_entry(st);
  int r;

  e->hostDepth++;                              /* Rule 3: trampoline ++/-- */
  r = g_elysium_dispatch(L, fid, st->swiftContext);
  e->hostDepth--;

  if (e->faultPending) {
    /* Rule 3: a trip recorded *during* the dispatcher call (hostDepth was > 0 when
    ** the hook fired) is raised here, after the dispatcher has returned, discarding
    ** whatever it produced — no results are lost because a fault discards them.
    ** faultPending/faultKind stay set (never cleared here): the longjmp this raise
    ** triggers unwinds straight to the elysium_pcall/elysium_resume that owns this
    ** same entry 'e', and that call reads faultPending after lua_pcall/lua_resume
    ** returns to report ELYSIUM_FAULT instead of an ordinary ELYSIUM_ERRRUN. The
    ** entry is freshly memset by the next elysium_pcall/elysium_resume that reuses
    ** this stack slot, so nothing needs to reset it in the meantime.
    */
    return luaL_error(L, "%s", elysium_fault_text(e->faultKind));
  }

  if (r >= 0) {
    if (lua_gettop(L) < r)
      return luaL_error(L, "internal error: host function declared %d results with %d on the stack",
                         r, lua_gettop(L));
    return r;
  } else if (r == -1) {
    return lua_error(L);
  } else {
    int nres = -(r + 2);
    if (!lua_isyieldable(L)) {
      /* C29: cannot honor the yield attempt; fault by host-side flag, never by
      ** matching Lua error text. Builder fix (found by
      ** testInvalidYieldFromSynchronousCall/testInvalidYieldFlaggedNotParsed): the
      ** flag itself was never actually set here -- e->faultPending/faultKind were
      ** left untouched, so elysium_pcall/elysium_resume's status computation fell
      ** through to the generic ELYSIUM_FAULT_RUNTIME case and this always reported
      ** as an ordinary runtime error, exactly the "matching Lua error text" outcome
      ** the comment above (and Condition 29) says must not happen.
      */
      e->yieldReason = ELYSIUM_YIELD_NONE;
      e->faultPending = 1;
      e->faultKind = ELYSIUM_FAULT_INVALID_YIELD;
      return luaL_error(L, "%s", elysium_fault_text(ELYSIUM_FAULT_INVALID_YIELD));
    }
    return lua_yield(L, nres);
  }
}

void elysium_set_yield_reason (lua_State *L, int tag, long long payloadInt,
                                unsigned long long payloadToken) {
  elysium_state *st = elysium_state_of(L);
  elysium_entry *e = elysium_current_entry(st);
  e->yieldReason = tag;
  e->yieldPayloadInt = payloadInt;
  e->yieldPayloadToken = payloadToken;
}

/* ==========================================================================
** State construction / teardown.
** ======================================================================= */
lua_State *elysium_newstate (const elysium_config *config, int *errcode) {
  elysium_state *st;
  lua_State *L;
  elysium_thread_ctx *mainCtx;

  if (errcode) *errcode = ELYSIUM_OK;

  if (config == NULL || config->math.sin == NULL || config->math.cos == NULL ||
      config->math.exp == NULL || config->math.log == NULL ||
      config->math.atan2 == NULL || config->math.pow == NULL ||
      config->math.tan == NULL || config->math.asin == NULL || config->math.acos == NULL ||
      config->math.log2 == NULL || config->math.log10 == NULL || config->logFn == NULL) {
    if (errcode) *errcode = ELYSIUM_ERR_MATH;
    return NULL;
  }
  if (!elysium_locale_ok()) {
    if (errcode) *errcode = ELYSIUM_ERR_LOCALE;
    return NULL;
  }

  st = (elysium_state *)calloc(1, sizeof(elysium_state));
  if (st == NULL) {
    if (errcode) *errcode = ELYSIUM_ERR_ALLOC;
    return NULL;
  }

  st->math = config->math;
  st->logFn = config->logFn;
  st->swiftContext = config->swiftContext;
  st->identity = config->identity;
  st->cap = config->memoryCapBytes;
  st->diagnosticSlackBytes = config->hostOverCapDiagnosticBytes;
  st->rateCapBytes = config->allocationRatePerSliceBytes;
  st->totalCap = config->handlerTotalInstructions;
  st->logLineBytes = config->logLineBytes;
  st->logLinesPerSlice = config->logLinesPerSlice;
  st->threadPoolMax = (config->threadPoolMax > 0) ? config->threadPoolMax : 0;  /* F2 */

  /* D4 Rule 3 baseline: entries[0] is the permanent resting frame, hostDepth == 1
  ** ("Swift owns the state"), before lua_newstate makes its first allocation.
  */
  st->entryTop = 1;
  st->entries[0].hostDepth = 1;
  st->entries[0].currentThread = NULL;  /* filled in once lua_newstate returns */

  L = lua_newstate(elysium_alloc, st);
  if (L == NULL) {
    free(st);
    if (errcode) *errcode = ELYSIUM_ERR_ALLOC;
    return NULL;
  }
  st->mainL = L;
  st->entries[0].currentThread = L;

  mainCtx = (elysium_thread_ctx *)calloc(1, sizeof(elysium_thread_ctx));
  if (mainCtx == NULL) {
    lua_close(L);
    free(st);
    if (errcode) *errcode = ELYSIUM_ERR_ALLOC;
    return NULL;
  }
  mainCtx->state = st;
  st->threadList = mainCtx;
  *(elysium_thread_ctx **)lua_getextraspace(L) = mainCtx;

  lua_atpanic(L, elysium_panic);  /* C27: right after lua_newstate */
  lua_sethook(L, elysium_count_hook, LUA_MASKCOUNT, ELYSIUM_HOOK_GRANULARITY);
  lua_gc(L, LUA_GCINC, 200, 100, 13);  /* D5: pinned incremental parameters */

  /* C27: open + sandbox the libraries as a protected C builder; failure tears the
  ** whole state down and reports ELYSIUM_ERR_OPEN rather than leaving a partial state.
  */
  lua_pushcfunction(L, elysium_openlibs);
  if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
    lua_close(L);
    elysium_free_thread_list(st);
    free(st);
    if (errcode) *errcode = ELYSIUM_ERR_OPEN;
    return NULL;
  }

  return L;
}

int elysium_close (lua_State *L) {
  elysium_state *st = elysium_state_of(L);
  if (st->dead) return ELYSIUM_OK;  /* idempotent */
  /* C20: refused while any entry is active (hostDepth != 1 at the resting frame). */
  if (st->entryTop != 1 || st->entries[0].hostDepth != 1)
    return ELYSIUM_ERR_BUSY;
  st->dead = 1;
  lua_close(st->mainL);
  elysium_free_thread_list(st);
  free(st);
  return ELYSIUM_OK;
}

/* ==========================================================================
** Loading.
** ======================================================================= */
int elysium_loadtext (lua_State *L, const char *buf, size_t len, const char *chunkname) {
  /* Text-only: mode "t" refuses a chunk starting with the binary signature before
  ** the lundump.c stub would ever be reached. hostDepth is untouched: lua_load is
  ** internally protected (luaD_protectedparser) and cannot raise past itself.
  */
  return luaL_loadbufferx(L, buf, len, chunkname, "t");
}

/* ==========================================================================
** The synchronous message handler shared by every elysium_pcall (D9 / spec
** "Error values and tracebacks are sanitized and address-free": any error object
** that is not a string or number becomes "<non-string error>" without invoking
** __tostring).
** ======================================================================= */
static int elysium_msgh (lua_State *L) {
  int t = lua_type(L, 1);
  if (t != LUA_TSTRING && t != LUA_TNUMBER) {
    lua_pushliteral(L, "<non-string error>");
    lua_replace(L, 1);
  }
  /* Builder fix (found by testErrorWithEmbeddedNulAndInvalidUTF8): luaL_traceback's
  ** own 'msg' parameter is a NUL-terminated C string -- its internal luaL_addstring
  ** call runs strlen(msg), which would silently truncate a script-controlled error
  ** value at its first embedded NUL byte (Lua strings are length-prefixed and may
  ** legally contain NUL; C26/F11 both require reading them by length, never by
  ** NUL-termination). Build the traceback with msg = NULL (skipping its internal
  ** message handling), then concatenate the *full-length* message ourselves with
  ** lua_concat, which works from the stack's real string lengths, not strlen.
  */
  luaL_traceback(L, L, NULL, 1);   /* stack: msg, traceback */
  lua_pushliteral(L, "\n");        /* stack: msg, traceback, "\n" */
  lua_insert(L, -2);               /* stack: msg, "\n", traceback */
  lua_concat(L, 3);                /* stack: msg .. "\n" .. traceback */
  return 1;
}

int elysium_pcall (lua_State *L, int nargs, int nresults, long long slice,
                    elysium_resume_result *out) {
  elysium_state *st = elysium_state_of(L);
  elysium_entry *outer;
  elysium_entry *e;
  int base;
  int rc;

  memset(out, 0, sizeof(*out));

  if (st->entryTop >= ELYSIUM_MAX_ENTRY_DEPTH) {
    lua_pop(L, nargs + 1);  /* keep the caller's stack balanced: function + args */
    return ELYSIUM_ERR_NESTING;
  }

  /* F4 (test.md testZZCallHardSliceDependsOnMainThreadHookPhase): unconditional,
  ** every entry — not only when a trip left basehookcount wrong. lua_sethook's own
  ** resethookcount() only runs when lua_sethook is actually *called*; the previous
  ** "if (L->basehookcount != ELYSIUM_HOOK_GRANULARITY)" guard mirrored C19's
  ** stale-re-arm fix, but on the ordinary path (no trip; basehookcount already
  ** 1000) it skipped the call entirely, so L->hookcount kept whatever phase the
  ** *previous* elysium_pcall on this same, permanently-reused main thread left it
  ** at — up to 999 instructions of carried-over jitter, making a top-level call()'s
  ** hard slice depend on process history instead of being a pure function of the
  ** call. Coroutines never had this problem: elysium_newthread/elysium_reset_thread
  ** already call lua_sethook unconditionally, but those only run once per fresh or
  ** pooled thread, never per resume — the main thread has no equivalent "fresh
  ** per call" moment, so elysium_pcall must reset it itself, every time.
  */
  lua_sethook(L, elysium_count_hook, LUA_MASKCOUNT, ELYSIUM_HOOK_GRANULARITY);

  outer = &st->entries[st->entryTop - 1];
  e = &st->entries[st->entryTop];
  memset(e, 0, sizeof(*e));
  e->currentThread = L;
  e->budget = outer->budget;                     /* C21: inherit the enclosing coroutine */
  e->hardSlice = (e->budget == NULL) ? 1 : 0;     /* C35 */
  e->sliceRemaining = slice;
  e->hostDepth = 0;
  st->entryTop++;

  base = lua_gettop(L) - nargs;   /* stack index of the function being called */
  lua_pushcfunction(L, elysium_msgh);
  lua_insert(L, base);
  rc = lua_pcall(L, nargs, nresults, base);
  lua_remove(L, base);

  st->entryTop--;

  {
    int tripKind = ELYSIUM_FAULT_NONE;
    if (e->faultPending)
      tripKind = (e->faultKind != ELYSIUM_FAULT_NONE) ? e->faultKind : ELYSIUM_FAULT_RUNTIME;
    else if (st->tripped)
      tripKind = ELYSIUM_FAULT_MEMORY_CAP;
    else if (st->rateTripped)
      tripKind = ELYSIUM_FAULT_ALLOCATION_RATE;

    /* HIGH fix (security-code.md Refutation, downgraded Condition 5): D5 says any
    ** state-wide trip flag forces .faulted regardless of Lua's status — "pcall
    ** cannot revive it" — so this must be decided *before* trusting rc == LUA_OK,
    ** not only in the rc != LUA_OK tail where the check used to live exclusively.
    ** st->tripped/st->rateTripped (and e->faultPending, deferred from a host
    ** section by the trampoline) can all survive a LUA_OK return two ways: the
    ** script's own local `pcall` caught the raised fault before this entry's own
    ** lua_pcall ever saw an error, or luaM_saferealloc_/luaM_malloc_ (lmem.c) can
    ** raise LUA_ERRMEM SYNCHRONOUSLY the instant the allocator returns NULL twice
    ** — before the hook's count-1 re-arm ever gets to run — so e->faultPending is
    ** not always set for a genuine cap/rate trip either. Both state-wide flags are
    ** unconditionally cleared below on every exit through this block so neither can
    ** leak into the next elysium_pcall/elysium_resume, regardless of which of the
    ** three sources (faultPending, tripped, rateTripped) triggered it.
    */
    if (tripKind != ELYSIUM_FAULT_NONE) {
      if (rc == LUA_OK) {
        /* The trip's own error text (if it was ever actually raised) is gone —
        ** consumed by the script's own pcall. The stack instead holds the
        ** script's own return values; discard them and synthesize the fault text
        ** ourselves (elysium_fault_text mirrors what the hook itself would have
        ** raised) so the trip is still surfaced with a sane message rather than
        ** whatever non-string value the script happened to return.
        */
        lua_settop(L, base - 1);
        lua_pushstring(L, elysium_fault_text(tripKind));
      }
      out->nres = 1;
      out->faultKind = tripKind;
      st->tripped = 0;
      st->rateTripped = 0;
      return ELYSIUM_FAULT;
    }
    st->tripped = 0;
    st->rateTripped = 0;
  }

  if (rc == LUA_OK) {
    out->nres = lua_gettop(L) - base + 1;
    return ELYSIUM_OK;
  }
  out->nres = 1;  /* one sanitized error object left on top */
  out->faultKind = ELYSIUM_FAULT_RUNTIME;
  return ELYSIUM_ERRRUN;
}

/* ==========================================================================
** Coroutines.
** ======================================================================= */
lua_State *elysium_newthread (lua_State *L) {
  elysium_state *st = elysium_state_of(L);
  lua_State *co;
  elysium_thread_ctx *ctx;

  /* F2 (design.md Decision 7, thread pool): reuse an idle pooled thread when one
  ** is available instead of always creating a fresh one. A pooled thread was
  ** already reset (lua_closethread, hook restored to granularity, allowhook = 1,
  ** budget zeroed — elysium_reset_thread) before it was added to the pool, and
  ** it keeps its own registry anchor from when it was first created, so nothing
  ** further needs to happen here: no lua_newthread, no new registry ref, no new
  ** ctx allocation. Nothing needs pushing onto L's stack either — elysium_newthread
  ** never left the fresh-path's thread on L's stack (luaL_ref below consumes it),
  ** so callers (elysium_newthread_with_function) never depended on that either.
  */
  if (st->pool != NULL) {
    ctx = st->pool;
    st->pool = ctx->poolNext;
    ctx->poolNext = NULL;
    ctx->pooled = 0;
    st->poolCount--;
    return ctx->L;
  }

  co = lua_newthread(L);           /* pushes co onto L's stack */
  ctx = (elysium_thread_ctx *)calloc(1, sizeof(elysium_thread_ctx));
  if (ctx == NULL) {
    lua_pop(L, 1);
    return NULL;  /* genuine host-side OOM (this bookkeeping block is not Lua's) */
  }
  ctx->state = st;
  ctx->L = co;
  ctx->next = st->threadList;
  st->threadList = ctx;
  *(elysium_thread_ctx **)lua_getextraspace(co) = ctx;  /* overwrite the copied pointer */

  co->allowhook = 1;
  lua_sethook(co, elysium_count_hook, LUA_MASKCOUNT, ELYSIUM_HOOK_GRANULARITY);

  /* Registry-anchored so it survives GC while pooled; the ref itself lives for
  ** the lifetime of the state unless the pool is saturated when the thread is
  ** later closed, in which case elysium_reset_thread releases it early (F2).
  */
  ctx->registryRef = luaL_ref(L, LUA_REGISTRYINDEX);
  return co;
}

lua_State *elysium_newthread_with_function (lua_State *L, int functionRef) {
  lua_State *co = elysium_newthread(L);
  if (co == NULL) return NULL;
  lua_rawgeti(L, LUA_REGISTRYINDEX, functionRef);
  lua_xmove(L, co, 1);
  return co;
}

void elysium_closethread (lua_State *L, lua_State *co) {
  elysium_state *st = elysium_state_of(L);
  int i;
  /* C20: 'co' is currently running somewhere on the entry stack (a host function
  ** nested inside co's own resume asked to close it) — defer to the outermost
  ** elysium_resume of 'co', which reports its natural outcome first, then closes.
  */
  for (i = 0; i < st->entryTop; i++) {
    if (st->entries[i].currentThread == co) {
      st->entries[i].closeDeferred = 1;
      return;
    }
  }
  elysium_reset_thread(L, co);
}

int elysium_resume (lua_State *L, lua_State *co, int nargs, long long slice,
                     elysium_resume_result *out) {
  elysium_state *st = elysium_state_of(L);
  elysium_thread_ctx *coCtx;
  elysium_entry *outer;
  elysium_entry *e;
  lua_State *fromThread;
  int nres = 0;
  int rc;
  int status;
  int i;

  memset(out, 0, sizeof(*out));

  /* C20: refuse re-entrancy without ever calling lua_resume. */
  for (i = 0; i < st->entryTop; i++) {
    if (st->entries[i].currentThread == co) {
      lua_pop(L, nargs);
      return ELYSIUM_ERR_REENTRANT;
    }
  }
  {
    int s = lua_status(co);
    if (s != LUA_OK && s != LUA_YIELD) {
      lua_pop(L, nargs);
      return ELYSIUM_ERR_DEAD;
    }
  }
  if (st->entryTop >= ELYSIUM_MAX_ENTRY_DEPTH) {
    lua_pop(L, nargs);
    return ELYSIUM_ERR_NESTING;
  }

  coCtx = elysium_ctx(co);

  /* C19: a thread that faulted from the hook was left with its count re-armed to
  ** fire after 1 instruction; undo that before it is reused.
  */
  if (co->basehookcount != ELYSIUM_HOOK_GRANULARITY)
    lua_sethook(co, elysium_count_hook, LUA_MASKCOUNT, ELYSIUM_HOOK_GRANULARITY);

  outer = &st->entries[st->entryTop - 1];
  fromThread = outer->currentThread;   /* C21: never NULL */
  e = &st->entries[st->entryTop];
  memset(e, 0, sizeof(*e));
  e->currentThread = co;
  e->budget = &coCtx->budget;
  e->sliceRemaining = slice;
  e->hostDepth = 0;
  st->entryTop++;

  /* N4-1 (design.md Decision 12 / Condition 14, amended by Security (plan)
  ** C25 and C28): the caller already validated and pushed 'nargs' values onto
  ** L's own stack (the Swift side's lua_checkstack(pointer, ...) before this
  ** call), but that says nothing about 'co' — the *target* thread lua_xmove
  ** is about to move them onto. A near-full or memory-capped 'co' can fail to
  ** grow for the move; check non-raising here rather than let lua_xmove's
  ** internal growth trap. On failure: unwind exactly the frame just pushed
  ** (entryTop--) and pop the caller's still-unmoved 'nargs' values from L
  ** (mirroring the ELYSIUM_ERR_REENTRANT/DEAD/NESTING early returns above),
  ** so lua_gettop(L) is unchanged by this failure branch, in every case.
  */
  if (nargs > 0 && !lua_checkstack(co, nargs)) {
    st->entryTop--;
    lua_pop(L, nargs);
    /* C28: only report the message on 'co' when 'co' provably has room for
    ** it — checked separately from the 'nargs' growth that just failed,
    ** since a coroutine that cannot grow by 'nargs' may still have a single
    ** slot free. If even that fails ('co' is exhausted at LUAI_MAXSTACK or
    ** the allocator's cap admits not one more slot), leave 'co' completely
    ** untouched rather than risk lua_pushstring's own internal growth
    ** raising past this unprotected frame — report the outcome with nothing
    ** on 'co's stack (nres = 0) and let the Swift side (Coroutines.swift,
    ** recognizing faultKind == ELYSIUM_FAULT_HOST_ABORT with nres == 0)
    ** synthesize the message itself instead of reading a stack that was
    ** never written.
    */
    if (lua_checkstack(co, 1)) {
      lua_pushstring(co, "stack overflow");
      out->faultKind = ELYSIUM_FAULT_HOST_ABORT;
      out->nres = 1;
      return ELYSIUM_ERRRUN;
    }
    out->faultKind = ELYSIUM_FAULT_HOST_ABORT;
    out->nres = 0;
    return ELYSIUM_FAULT;
  }

  if (nargs > 0)
    lua_xmove(L, co, nargs);

  rc = lua_resume(co, fromThread, nargs, &nres);

  st->entryTop--;

  {
    int tripKind = ELYSIUM_FAULT_NONE;
    if (e->faultPending)
      tripKind = (e->faultKind != ELYSIUM_FAULT_NONE) ? e->faultKind : ELYSIUM_FAULT_RUNTIME;
    else if (coCtx->budget.budgetTripped)
      /* D6: the total cap can trip without the hook itself observing hostDepth > 0
      ** (e.g. it raised directly at hostDepth == 0); either way any trip flag
      ** forces .faulted regardless of the Lua status (D5, "pcall cannot revive it").
      */
      tripKind = ELYSIUM_FAULT_INSTRUCTION_BUDGET;
    else if (st->tripped)
      tripKind = ELYSIUM_FAULT_MEMORY_CAP;
    else if (st->rateTripped)
      tripKind = ELYSIUM_FAULT_ALLOCATION_RATE;

    /* HIGH fix (security-code.md Refutation, downgraded Condition 5): evaluated
    ** *before* rc == LUA_YIELD/LUA_OK, not only in the rc-is-an-error tail where
    ** the st->tripped/st->rateTripped half of this check used to live exclusively.
    ** A trip caught by the coroutine's own local `pcall` can let it keep running
    ** all the way to a normal return (rc == LUA_OK) or a legitimate-looking
    ** `coroutine.yield` (rc == LUA_YIELD); a synchronous LUA_ERRMEM raised straight
    ** out of luaM_saferealloc_/luaM_malloc_ (lmem.c) can similarly beat the hook's
    ** count-1 re-arm to the punch, leaving e->faultPending unset even though
    ** st->tripped/st->rateTripped are. Any of the three sources must still force
    ** .faulted ("pcall cannot revive it" — design.md 93, 279), and both state-wide
    ** flags are unconditionally cleared below on every exit through this block so
    ** neither can leak into the next elysium_pcall/elysium_resume (coCtx's own
    ** budgetTripped is per-coroutine and is already reset when the faulted thread
    ** is pooled — elysium_reset_thread/C19 — so it needs no clearing here).
    */
    if (tripKind != ELYSIUM_FAULT_NONE) {
      if (rc == LUA_OK || rc == LUA_YIELD) {
        /* The trip's own error text (if it was ever actually raised) is gone —
        ** consumed by the coroutine's own pcall, or the coroutine ran past the
        ** trip all the way to a yield. 'co's own stack holds its actual
        ** results/yielded values instead of a fault message; discard them and
        ** synthesize the fault text ourselves so the trip is still surfaced with
        ** a sane message.
        */
        lua_settop(co, 0);
        lua_pushstring(co, elysium_fault_text(tripKind));
      }
      out->faultKind = tripKind;
      status = ELYSIUM_FAULT;
    } else if (rc == LUA_YIELD) {
      out->nres = nres;
      out->yieldReason = e->yieldReason;
      out->yieldPayloadInt = e->yieldPayloadInt;
      out->yieldPayloadToken = e->yieldPayloadToken;
      status = ELYSIUM_YIELD;
    } else if (rc == LUA_OK) {
      out->nres = nres;
      status = ELYSIUM_OK;
    } else {
      out->nres = 1;
      out->faultKind = ELYSIUM_FAULT_RUNTIME;
      status = ELYSIUM_ERRRUN;
    }

    st->tripped = 0;
    st->rateTripped = 0;
  }

  /* C20 (Builder fix, found by testCloseCoroutineFromInsideItsHostFunctionIsDeferred):
  ** do NOT reset 'co' here. 'out' above may still owe the caller a read of 'co's own
  ** stack (nres result values on OK/YIELD, or the fault/traceback text the caller
  ** builds via elysium_traceback on FAULT/ERRRUN) — lua_closethread (inside
  ** elysium_reset_thread) wipes exactly that stack, so resetting before the caller
  ** has read it corrupts the very outcome this resume just reported. Report the
  ** request instead; the caller finishes reading, then calls elysium_closethread
  ** itself (which by then no longer finds 'co' on the entry stack, so it performs
  ** the real reset immediately rather than deferring again).
  */
  out->closeDeferred = e->closeDeferred;

  return status;
}

size_t elysium_traceback (lua_State *co, size_t maxBytes) {
  const char *s;
  size_t len = 0;

  /* A coroutine that just faulted left its ci chain intact for exactly this kind
  ** of post-mortem inspection (that is what makes a traceback possible at all),
  ** but co->ci->top.p is wherever the VM/hook happened to be when the error fired
  ** — frequently right at its existing limit, with no headroom for the values
  ** luaL_traceback itself needs to push while walking the stack and building the
  ** message. Grow it explicitly first; unlike the alloc-cap path this call is not
  ** hostDepth-gated (elysium_traceback always runs at hostDepth == 0, after the
  ** entry that faulted has already been popped), so it can safely ask for room.
  */
  luaL_checkstack(co, LUA_MINSTACK, "elysium_traceback");
  luaL_traceback(co, co, NULL, 0);
  s = lua_tolstring(co, -1, &len);
  if (s == NULL) {
    lua_pop(co, 1);
    lua_pushliteral(co, "");
    return 0;
  }
  if (len <= maxBytes)
    return len;

  {
    /* Copy the capped prefix into a C buffer *before* popping the untruncated
    ** string (popping first and reading 's' afterward would race the collector —
    ** the same discipline C26 requires of every Swift-facing text read).
    */
    char *copy = (char *)malloc(maxBytes);
    if (copy == NULL) {
      lua_pop(co, 1);
      lua_pushliteral(co, "");
      return 0;
    }
    memcpy(copy, s, maxBytes);
    lua_pop(co, 1);
    lua_pushlstring(co, copy, maxBytes);
    free(copy);
    return maxBytes;
  }
}

/* ==========================================================================
** Memory status, trip reset, host-stepped GC, logging (C26: the only reachable
** lua_gc modes).
** ======================================================================= */
void elysium_memory_status_get (lua_State *L, elysium_memory_status *out) {
  elysium_state *st = elysium_state_of(L);
  out->bytesInUse = st->bytesInUse;
  out->cap = st->cap;
  out->tripped = st->tripped;
  out->rateTripped = st->rateTripped;
  out->overCapHost = st->overCapHost;
  out->allocationCalls = st->allocationCalls;
  out->emergencyCollections = st->emergencyCollections;
}

void elysium_reset_trips (lua_State *L) {
  elysium_state *st = elysium_state_of(L);
  st->tripped = 0;
  st->rateTripped = 0;
  st->overCapHost = 0;
}

/* object-graph-attributes change 1a carry-forward N4-2: single source of truth
** for the sandbox's numeric library caps (elysium_sandbox.c's literals,
** mirrored here rather than duplicated as mutable ScriptBudgets fields).
** These numbers are the ones elysium_sandbox.c's string/table/utf8 wrappers
** already enforce; this getter takes no lua_State because the caps are
** compile-time constants, not per-state configuration.
*/
elysium_library_caps_t elysium_library_caps (void) {
  elysium_library_caps_t caps;
  caps.patternSubjectBytes = 8192;
  caps.patternBytes = 256;
  caps.matchSteps = ELYSIUM_MATCH_STEPS;
  caps.resultBytes = 65536;
  caps.byteRangeBytes = 4096;
  caps.sortElements = 4096;
  caps.unpackResults = 256;
  caps.moveElements = 65536;
  caps.utf8SubjectBytes = 65536;
  caps.formatConversions = 32;
  caps.maxStringBytes = ELYSIUM_MAX_STRING;
  return caps;
}

unsigned long long elysium_thread_instructions_used (lua_State *co) {
  return elysium_ctx(co)->budget.totalUsed;
}

/* F2 (Builder, thread-pool regression coverage). */
int elysium_pool_count (lua_State *L) {
  return elysium_state_of(L)->poolCount;
}

void elysium_gc_step (lua_State *L, int kilobytes) {
  lua_gc(L, LUA_GCSTEP, kilobytes);
}

void elysium_gc_full (lua_State *L) {
  lua_gc(L, LUA_GCCOLLECT);
}

void elysium_host_log (lua_State *L, unsigned long long envId, const char *utf8, size_t len) {
  elysium_state *st = elysium_state_of(L);
  if (st->logFn != NULL) st->logFn(st->swiftContext, envId, utf8, len);
}
