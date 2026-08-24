/*
** elysium_sandbox.c — library sandboxing and the environment/handle primitives
** (design.md Decisions 8 and 10). Every comment tag names the design.md condition
** or decision the adjacent code satisfies.
**
** General pattern for a "wrapped" library entry: fetch the stock (light) C function
** already installed by the upstream luaopen_*, keep it as the wrapper closure's sole
** upvalue (a plain, 0-upvalue function *value* — retrieved at call time with
** lua_tocfunction so the wrapper never needs its own separate storage for it), run
** the cap checks, then call the stock function directly. This is the only way to
** reach the *static* stock implementations (str_find, str_format, ...) from a
** different translation unit.
*/

#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "elysium_internal.h"
#include "lauxlib.h"
#include "lualib.h"

typedef struct elysium_handle_payload {
  int kindId;
  unsigned long long id;
} elysium_handle_payload;

/* Unique registry keys (their *addresses*, not their contents, are the key —
** the standard "lightuserdata-ish" idiom for private registry slots). C26: every
** table stashed under one of these is reached with lua_rawgetp/lua_rawsetp and is
** never iterated.
*/
static const char ELYSIUM_HOSTOWNED_KEY = 0;
/* F3 (Builder, environment-destroy reclamation fix): manifests[envId] = an array
** of every object elysium_make_environment/elysium_freeze_table marked host-owned
** for that one environment (see elysium_mark_env_owned below). Walked and cleared
** by elysium_destroy_environment so those objects stop being permanently retained
** as keys of ELYSIUM_HOSTOWNED_KEY (an ordinary table, which — unlike a weak table,
** which Condition 6 forbids here anyway — holds a strong reference to every key it
** has ever seen).
*/
static const char ELYSIUM_ENV_MANIFEST_KEY = 0;
static const char ELYSIUM_MASTER_GLOBALS_KEY = 0;
static const char ELYSIUM_MASTER_STRING_KEY = 0;
static const char ELYSIUM_MASTER_TABLE_KEY = 0;
static const char ELYSIUM_MASTER_MATH_KEY = 0;
static const char ELYSIUM_MASTER_UTF8_KEY = 0;
static const char ELYSIUM_HANDLE_META_KEY = 0;
static const char ELYSIUM_HANDLE_INTERN_KEY = 0;

/* ==========================================================================
** Host-owned marker (C23): a registry-keyed set, never iterated, distinguishing
** host-installed metatables (proxies, _ENV, the string metatable, handle-kind
** metatables, read-only views) from script-owned frozen copies installed by
** elysium_setmetatable.
** ======================================================================= */
static void elysium_mark_host_owned (lua_State *L, int idx) {
  idx = lua_absindex(L, idx);
  lua_rawgetp(L, LUA_REGISTRYINDEX, &ELYSIUM_HOSTOWNED_KEY);
  lua_pushvalue(L, idx);
  lua_pushboolean(L, 1);
  lua_rawset(L, -3);
  lua_pop(L, 1);
}

static int elysium_is_host_owned (lua_State *L, int idx) {
  int owned;
  idx = lua_absindex(L, idx);
  lua_rawgetp(L, LUA_REGISTRYINDEX, &ELYSIUM_HOSTOWNED_KEY);
  lua_pushvalue(L, idx);
  lua_rawget(L, -2);
  owned = lua_toboolean(L, -1);
  lua_pop(L, 2);
  if (!owned) {
    /* A3-1 fix: elysium_setmetatable's per-call read-only-view metatable is not
    ** in the state-wide strong set above (that would retain it, and everything
    ** it reaches, for the life of the LuaState -- see the comment at its call
    ** site). Instead it carries a structural sentinel raw-set into its own table
    ** at construction time, keyed by this key's *address* (not its contents).
    ** That key is unforgeable from script text: it is a C pointer, never
    ** obtainable as a Lua value, rawset/rawget are absent from every
    ** environment, and the view metatable that carries it is itself
    ** __metatable-locked (see elysium_setmetatable), so a script can never even
    ** hold a reference to the table this checks. Checking for it here — instead
    ** of only in the strong set — lets the view metatable (and everything it
    ** alone keeps alive) become ordinary garbage once the view itself is
    ** unreachable, while still refusing setmetatable on it while it is alive.
    */
    lua_rawgetp(L, idx, &ELYSIUM_HOSTOWNED_KEY);
    owned = lua_toboolean(L, -1);
    lua_pop(L, 1);
  }
  return owned;
}

/* F3: like elysium_mark_host_owned, but additionally appends the marked object to
** the environment manifest at 'manifestIdx' (an absolute or valid relative stack
** index of the array table elysium_make_environment/elysium_freeze_table built for
** the environment currently under construction), so elysium_destroy_environment can
** find and un-mark it later. Every per-environment host-owned mark goes through
** this instead of elysium_mark_host_owned directly.
*/
static void elysium_mark_env_owned (lua_State *L, int idx, int manifestIdx) {
  elysium_mark_host_owned(L, idx);
  idx = lua_absindex(L, idx);
  lua_pushvalue(L, idx);
  lua_rawseti(L, manifestIdx, (lua_Integer)lua_rawlen(L, manifestIdx) + 1);
}

static int elysium_frozen_newindex_error (lua_State *L) {
  return luaL_error(L, "attempt to modify a read-only table");
}

/* ==========================================================================
** Generic rewrap pass (D8): every light C function directly in 'tidx' becomes a
** 1-upvalue closure over itself (the dummy upvalue is nil — the point is only that
** it stops being a light function, which mainpositionTV/the reachability walk
** would otherwise hash/find by address). Safe to run under lua_next per the Lua
** manual's explicit exception for re-assigning an *existing* field's value.
** ======================================================================= */
static void elysium_rewrap_table (lua_State *L, int tidx) {
  tidx = lua_absindex(L, tidx);
  lua_pushnil(L);
  while (lua_next(L, tidx) != 0) {
    /* stack: key value */
    if (lua_iscfunction(L, -1)) {
      lua_CFunction f = lua_tocfunction(L, -1);
      lua_pop(L, 1);                 /* stack: key */
      if (f != NULL) {
        lua_pushvalue(L, -1);        /* key key */
        lua_pushnil(L);              /* key key nil */
        lua_pushcclosure(L, f, 1);   /* key key closure */
        lua_rawset(L, tidx);         /* t[key] = closure; stack: key */
      }
    } else {
      lua_pop(L, 1);                 /* stack: key */
    }
  }
}

static void elysium_remove_field (lua_State *L, int tidx, const char *name) {
  lua_pushnil(L);
  lua_setfield(L, tidx, name);
}

/* Installs a wrapper closure at t[name], capturing the CURRENT t[name] value (a
** plain, possibly-already-rewrapped function value) as the wrapper's sole upvalue,
** so the wrapper can retrieve and call it with lua_tocfunction(lua_upvalueindex(1)).
*/
static void elysium_wrap_field (lua_State *L, int tidx, const char *name, lua_CFunction wrapper) {
  tidx = lua_absindex(L, tidx);
  lua_getfield(L, tidx, name);
  if (lua_isnil(L, -1)) { lua_pop(L, 1); return; }
  lua_pushcclosure(L, wrapper, 1);
  lua_setfield(L, tidx, name);
}

static lua_CFunction elysium_stock (lua_State *L) {
  return lua_tocfunction(L, lua_upvalueindex(1));
}

static void elysium_check_result_len (lua_State *L, int idx, size_t cap, const char *what) {
  if (lua_type(L, idx) == LUA_TSTRING) {
    size_t len;
    lua_tolstring(L, idx, &len);
    if (len > cap) luaL_error(L, "%s result exceeds %d bytes", what, (int)cap);
  }
}

/* ==========================================================================
** base library wrappers.
** ======================================================================= */

/* print (task 2.3, C33): C-enforced caps (512 B/line, 256 lines/slice); calls
** through elysium_host_log directly rather than the dispatcher, since it never
** needs a script-supplied result and always succeeds or raises. Upvalue 1 is the
** owning environment's id (installed per-environment, not in the shared master).
**
** Builds the line in a plain malloc'd C buffer rather than a luaL_Buffer: several
** luaL_tolstring calls in a row, each potentially recursing into lua_pushfstring
** (itself luaL_Buffer-based) to format a number, is exactly the nested-buffer
** pattern the Lua 5.4 manual warns can invalidate an outer buffer's box position;
** a plain C buffer sidesteps that entirely and is what capping a byte length
** wants anyway. Truncation is a raw byte cut (like elysium_traceback); the
** decode-with-repair discipline that makes this safe for a script-controlled
** value lives on the Swift side (C26), same as every other capped text read.
*/
static int elysium_print (lua_State *L) {
  elysium_state *st = elysium_state_of(L);
  elysium_entry *e = elysium_current_entry(st);
  unsigned long long envId = (unsigned long long)lua_tointeger(L, lua_upvalueindex(1));
  int n = lua_gettop(L);
  int i;
  size_t cap = (size_t)st->logLineBytes;
  size_t used = 0;
  char *buf;

  if (e->logLinesThisSlice >= st->logLinesPerSlice)
    return luaL_error(L, "print budget exceeded");
  e->logLinesThisSlice++;

  buf = (char *)malloc(cap > 0 ? cap : 1);
  if (buf == NULL) return luaL_error(L, "out of memory building a print line");

  for (i = 1; i <= n; i++) {
    size_t len;
    const char *s;
    if (i > 1 && used < cap) buf[used++] = '\t';
    s = luaL_tolstring(L, i, &len);  /* address-free per the lauxlib.c patch */
    if (used < cap) {
      size_t take = (used + len > cap) ? (cap - used) : len;
      memcpy(buf + used, s, take);
      used += take;
    }
    lua_pop(L, 1);
  }

  elysium_host_log(L, envId, buf, used);
  free(buf);
  return 0;
}

/* setmetatable (D8, C23). */
static int elysium_setmetatable (lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  if (lua_getmetatable(L, 1)) {
    if (elysium_is_host_owned(L, -1))
      return luaL_error(L, "cannot change a protected metatable");
    lua_pop(L, 1);
  }
  if (lua_isnoneornil(L, 2)) {
    lua_pushnil(L);
    lua_setmetatable(L, 1);
    lua_settop(L, 1);
    return 1;
  }
  luaL_checktype(L, 2, LUA_TTABLE);

  lua_newtable(L);
  {
    int C = lua_gettop(L);
    lua_pushnil(L);
    while (lua_next(L, 2) != 0) {
      int skip = 0;
      if (lua_type(L, -2) == LUA_TSTRING) {
        const char *k = lua_tostring(L, -2);
        if (strcmp(k, "__gc") == 0 || strcmp(k, "__mode") == 0 || strcmp(k, "__close") == 0)
          skip = 1;
      }
      if (skip) {
        lua_pop(L, 1);
      } else {
        lua_pushvalue(L, -2);
        lua_insert(L, -2);
        lua_rawset(L, C);
      }
    }

    lua_getfield(L, C, "__metatable");
    if (lua_isnil(L, -1)) {
      lua_pop(L, 1);
      lua_newtable(L);           /* read-only view */
      {
        int view = lua_gettop(L);
        lua_newtable(L);         /* view's metatable */
        lua_pushvalue(L, C);
        lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, elysium_frozen_newindex_error);
        lua_setfield(L, -2, "__newindex");
        lua_pushliteral(L, "locked");
        lua_setfield(L, -2, "__metatable");
        /* A3-1 fix: mark this per-call view metatable as host-owned
        ** *structurally* (a raw field of its own, keyed by an address a script
        ** can never produce) rather than as a key in the state-wide strong
        ** ELYSIUM_HOSTOWNED_KEY set. Every setmetatable(t, mt) without a
        ** script-supplied __metatable builds a fresh one of these, so putting
        ** it in that shared table retained it (and everything __index/the
        ** frozen copy it reaches) for the life of the LuaState — unreclaimable
        ** by collectFull, not covered by any environment manifest, and not
        ** undone by destroy(). This sentinel is checked by
        ** elysium_is_host_owned; ownership still refuses setmetatable while
        ** the view is reachable, but once nothing references view/viewMeta
        ** any more they are ordinary garbage like any other table.
        */
        lua_pushboolean(L, 1);
        lua_rawsetp(L, -2, &ELYSIUM_HOSTOWNED_KEY);
        lua_setmetatable(L, view);
      }
      lua_setfield(L, C, "__metatable");
    } else {
      lua_pop(L, 1);  /* keep the script-supplied __metatable */
    }

    lua_setmetatable(L, 1);
  }
  lua_settop(L, 1);
  return 1;
}

/* pairs/ipairs (D8): return wrapped iterator closures; pairs honours __pairs. */
static int elysium_pairs (lua_State *L) {
  luaL_checkany(L, 1);
  if (luaL_getmetafield(L, 1, "__pairs") != LUA_TNIL) {
    int floor;
    lua_insert(L, 1);
    floor = lua_gettop(L) - 2;
    lua_call(L, 1, LUA_MULTRET);
    return lua_gettop(L) - floor;
  }
  lua_pushvalue(L, lua_upvalueindex(1));  /* the wrapped 'next' */
  lua_pushvalue(L, 1);
  lua_pushnil(L);
  return 3;
}

static int elysium_ipairs_aux (lua_State *L) {
  lua_Integer i = luaL_checkinteger(L, 2) + 1;
  lua_pushinteger(L, i);
  lua_geti(L, 1, i);
  if (lua_isnil(L, -1)) return 1;
  return 2;
}

static int elysium_ipairs (lua_State *L) {
  luaL_checkany(L, 1);
  lua_pushvalue(L, lua_upvalueindex(1));  /* the elysium_ipairs_aux closure */
  lua_pushvalue(L, 1);
  lua_pushinteger(L, 0);
  return 3;
}

/* ==========================================================================
** string library wrappers (D8; caps from specs/script-sandbox-and-budgets).
** ======================================================================= */
static void elysium_check_pattern_caps (lua_State *L, int subjIdx, int patIdx) {
  size_t sl, pl;
  luaL_checklstring(L, subjIdx, &sl);
  luaL_checklstring(L, patIdx, &pl);
  if (sl > 8192) luaL_error(L, "subject exceeds 8192 bytes");
  if (pl > 256) luaL_error(L, "pattern exceeds 256 bytes");
}

static int elysium_str_find (lua_State *L) {
  elysium_check_pattern_caps(L, 1, 2);
  return elysium_stock(L)(L);
}
static int elysium_str_match (lua_State *L) {
  elysium_check_pattern_caps(L, 1, 2);
  return elysium_stock(L)(L);
}
static int elysium_str_gmatch (lua_State *L) {
  elysium_check_pattern_caps(L, 1, 2);
  return elysium_stock(L)(L);
}
static int elysium_str_gsub (lua_State *L) {
  lua_CFunction stock;
  int n;
  elysium_check_pattern_caps(L, 1, 2);
  stock = elysium_stock(L);
  n = stock(L);
  elysium_check_result_len(L, -n, 65536, "gsub");  /* C36 */
  return n;
}

/* string.format (C28: Lua's own conversion grammar, %p rejected regardless of
** flags/width; %% is not a conversion; <= 32 conversions) then C36 result cap.
*/
static void elysium_format_check (lua_State *L, const char *fmt, size_t len) {
  size_t i = 0;
  int conversions = 0;
  while (i < len) {
    if (fmt[i] != '%') { i++; continue; }
    i++;
    if (i >= len) luaL_error(L, "invalid conversion to 'format'");
    if (fmt[i] == '%') { i++; continue; }
    while (i < len && strchr("-+ #0", fmt[i]) != NULL) i++;
    { int wd = 0; while (i < len && wd < 2 && isdigit((unsigned char)fmt[i])) { i++; wd++; } }
    if (i < len && fmt[i] == '.') {
      i++;
      { int pd = 0; while (i < len && pd < 2 && isdigit((unsigned char)fmt[i])) { i++; pd++; } }
    }
    if (i >= len) luaL_error(L, "invalid conversion to 'format'");
    if (fmt[i] == 'p') luaL_error(L, "'%%p' is not a permitted format conversion");
    conversions++;
    i++;
  }
  if (conversions > 32) luaL_error(L, "too many conversions to 'format' (limit 32)");
}
static int elysium_str_format (lua_State *L) {
  size_t len;
  const char *fmt = luaL_checklstring(L, 1, &len);
  lua_CFunction stock;
  int n;
  elysium_format_check(L, fmt, len);
  stock = elysium_stock(L);
  n = stock(L);
  elysium_check_result_len(L, -n, 65536, "format");
  return n;
}

static int elysium_str_rep (lua_State *L) {
  size_t sl, sepl = 0;
  lua_Integer n;
  luaL_checklstring(L, 1, &sl);
  n = luaL_checkinteger(L, 2);
  if (lua_gettop(L) >= 3) luaL_checklstring(L, 3, &sepl);
  if (n > 0) {
    /* mirror stock str_rep's own length formula, without building the string, so a
    ** huge 'n' cannot force a huge allocation before we refuse it. */
    double total = (double)sl * (double)n + (double)sepl * (double)(n - 1);
    if (total > 65536.0) luaL_error(L, "'rep' result exceeds 65536 bytes");
  }
  return elysium_stock(L)(L);
}

static lua_Integer elysium_str_relat (lua_Integer pos, size_t len) {
  if (pos >= 0) return pos;
  else if ((size_t)(-pos) > len) return 0;
  else return (lua_Integer)len + pos + 1;
}
static int elysium_str_byte (lua_State *L) {
  size_t l;
  const char *s = luaL_checklstring(L, 1, &l);
  lua_Integer pi = luaL_optinteger(L, 2, 1);
  lua_Integer pj = luaL_optinteger(L, 3, pi);
  lua_Integer posi = elysium_str_relat(pi, l);
  lua_Integer posj = elysium_str_relat(pj, l);
  (void)s;
  if (posi < 1) posi = 1;
  if (posj > (lua_Integer)l) posj = (lua_Integer)l;
  if (posi <= posj && (posj - posi + 1) > 4096)
    luaL_error(L, "'byte' range exceeds 4096 bytes");
  return elysium_stock(L)(L);
}

static int elysium_str_pack (lua_State *L) {
  lua_CFunction stock = elysium_stock(L);
  int n = stock(L);
  elysium_check_result_len(L, -n, 65536, "pack");  /* C36 */
  return n;
}

/* ==========================================================================
** table library wrappers.
** ======================================================================= */
static int elysium_table_sort (lua_State *L) {
  lua_Integer n = (lua_Integer)lua_rawlen(L, 1);
  lua_Integer k;
  if (n > 4096) luaL_error(L, "table.sort exceeds 4096 elements");
  for (k = 1; k <= n; k++) {
    lua_rawgeti(L, 1, k);
    if (lua_type(L, -1) == LUA_TSTRING) {
      size_t len;
      lua_tolstring(L, -1, &len);
      if (len > 8192) { lua_pop(L, 1); luaL_error(L, "table.sort element exceeds 8192 bytes"); }
    }
    lua_pop(L, 1);
  }
  return elysium_stock(L)(L);
}

static int elysium_table_concat (lua_State *L) {
  lua_Integer i = luaL_optinteger(L, 3, 1);
  lua_Integer j = luaL_optinteger(L, 4, (lua_Integer)lua_rawlen(L, 1));
  lua_CFunction stock;
  int n;
  if (j >= i && (j - i + 1) > 65536)
    luaL_error(L, "table.concat element count exceeds 65536");
  stock = elysium_stock(L);
  n = stock(L);
  elysium_check_result_len(L, -n, 65536, "table.concat");
  return n;
}

static int elysium_table_unpack (lua_State *L) {
  lua_Integer i = luaL_optinteger(L, 2, 1);
  lua_Integer j = luaL_optinteger(L, 3, (lua_Integer)lua_rawlen(L, 1));
  if (j >= i && (j - i + 1) > 256)
    luaL_error(L, "table.unpack exceeds 256 results");
  return elysium_stock(L)(L);
}

static int elysium_table_move (lua_State *L) {
  lua_Integer f = luaL_checkinteger(L, 2);
  lua_Integer e = luaL_checkinteger(L, 3);
  if (e >= f && (e - f + 1) > 65536)
    luaL_error(L, "table.move exceeds 65536 elements");
  return elysium_stock(L)(L);
}

static int elysium_table_insert (lua_State *L) {
  if (lua_gettop(L) > 2) {  /* positional form: insert(t, pos, v) */
    lua_Integer n = (lua_Integer)lua_rawlen(L, 1);
    if (n > 65536) luaL_error(L, "table.insert (positional) exceeds 65536 elements");
  }
  return elysium_stock(L)(L);
}

static int elysium_table_remove (lua_State *L) {
  if (lua_gettop(L) > 1) {  /* positional form: remove(t, pos) */
    lua_Integer n = (lua_Integer)lua_rawlen(L, 1);
    if (n > 65536) luaL_error(L, "table.remove (positional) exceeds 65536 elements");
  }
  return elysium_stock(L)(L);
}

/* ==========================================================================
** utf8 library wrappers.
** ======================================================================= */
static int elysium_utf8_checked (lua_State *L) {
  size_t l;
  luaL_checklstring(L, 1, &l);
  if (l > 65536) luaL_error(L, "utf8 subject exceeds 65536 bytes");
  return elysium_stock(L)(L);
}

static int elysium_utf8_iter_tramp (lua_State *L) {
  return elysium_stock(L)(L);
}

static int elysium_utf8_codes (lua_State *L) {
  size_t l;
  lua_CFunction stock;
  int n, top0;
  luaL_checklstring(L, 1, &l);
  if (l > 65536) luaL_error(L, "utf8 subject exceeds 65536 bytes");
  top0 = lua_gettop(L);
  stock = elysium_stock(L);
  n = stock(L);  /* pushes iterFn, s, 0 */
  {
    lua_CFunction iterFn = lua_tocfunction(L, top0 + 1);
    lua_pushcfunction(L, iterFn);
    lua_pushcclosure(L, elysium_utf8_iter_tramp, 1);
    lua_replace(L, top0 + 1);
  }
  return n;
}

/* ==========================================================================
** math library: sin/cos/atan/exp/log route through the state's ScriptMath table
** (D11); random/randomseed are installed per-environment (elysium_make_environment)
** since they need the environment's own ScriptRandomStream, dispatched via the
** reserved fids 1 and 2.
** ======================================================================= */
static int elysium_math_sin (lua_State *L) {
  elysium_state *st = elysium_state_of(L);
  lua_pushnumber(L, (lua_Number)st->math.sin((double)luaL_checknumber(L, 1)));
  return 1;
}
static int elysium_math_cos (lua_State *L) {
  elysium_state *st = elysium_state_of(L);
  lua_pushnumber(L, (lua_Number)st->math.cos((double)luaL_checknumber(L, 1)));
  return 1;
}
static int elysium_math_exp (lua_State *L) {
  elysium_state *st = elysium_state_of(L);
  lua_pushnumber(L, (lua_Number)st->math.exp((double)luaL_checknumber(L, 1)));
  return 1;
}
static int elysium_math_atan (lua_State *L) {
  elysium_state *st = elysium_state_of(L);
  lua_Number y = luaL_checknumber(L, 1);
  lua_Number x = luaL_optnumber(L, 2, 1.0);
  lua_pushnumber(L, (lua_Number)st->math.atan2((double)y, (double)x));
  return 1;
}
static int elysium_math_log (lua_State *L) {
  elysium_state *st = elysium_state_of(L);
  lua_Number x = luaL_checknumber(L, 1);
  if (lua_isnoneornil(L, 2)) {
    lua_pushnumber(L, (lua_Number)st->math.log((double)x));
  } else {
    double lb = st->math.log((double)luaL_checknumber(L, 2));
    double lx = st->math.log((double)x);
    lua_pushnumber(L, (lua_Number)(lx / lb));
  }
  return 1;
}

/* scripting-ui-and-replication (change 3): tan/asin/acos restore the three math
** functions change 0 removed (design.md §8.3 "Removed: tan asin acos (v1)"),
** wrapped exactly like sin/cos/exp/log above so they route through the state's
** ScriptMath table (DetMath's fdlibm ports) instead of libm. log2/log10 are new,
** additive entries — math.log(x, b) above is untouched (design.md Appendix E
** point 4: "log(x, b) = log(x)/log(b) for every base", pinned by
** MathTests.testLogBaseRatio).
*/
static int elysium_math_tan (lua_State *L) {
  elysium_state *st = elysium_state_of(L);
  lua_pushnumber(L, (lua_Number)st->math.tan((double)luaL_checknumber(L, 1)));
  return 1;
}
static int elysium_math_asin (lua_State *L) {
  elysium_state *st = elysium_state_of(L);
  lua_pushnumber(L, (lua_Number)st->math.asin((double)luaL_checknumber(L, 1)));
  return 1;
}
static int elysium_math_acos (lua_State *L) {
  elysium_state *st = elysium_state_of(L);
  lua_pushnumber(L, (lua_Number)st->math.acos((double)luaL_checknumber(L, 1)));
  return 1;
}
static int elysium_math_log2 (lua_State *L) {
  elysium_state *st = elysium_state_of(L);
  lua_pushnumber(L, (lua_Number)st->math.log2((double)luaL_checknumber(L, 1)));
  return 1;
}
static int elysium_math_log10 (lua_State *L) {
  elysium_state *st = elysium_state_of(L);
  lua_pushnumber(L, (lua_Number)st->math.log10((double)luaL_checknumber(L, 1)));
  return 1;
}

/* ==========================================================================
** Deep copy / frozen proxy machinery for per-environment tables (D8).
** ======================================================================= */
static int elysium_deepcopy_master (lua_State *L, const void *key) {
  int master, copy;
  /* F1 (design.md Condition 3 / test.md F1): a stale main-thread stack (from an
  ** unrelated earlier failed push, before that Swift-side leak was fixed) used to
  ** be the only way this ever got close to overrunning ci->top; kept as
  ** defence-in-depth exactly like elysium_traceback's existing luaL_checkstack use.
  ** This call is made directly by Swift (LuaState.makeEnvironment), never under a
  ** protected elysium_pcall/elysium_resume frame — a raise here is unreachable by
  ** construction (see Rule 4's panic handler) rather than a normal control-flow
  ** path, exactly like the accepted process-OOM residual (design.md Decision 5).
  */
  luaL_checkstack(L, LUA_MINSTACK, "elysium_deepcopy_master");
  lua_rawgetp(L, LUA_REGISTRYINDEX, key);
  master = lua_gettop(L);
  lua_newtable(L);
  copy = lua_gettop(L);
  lua_pushnil(L);
  while (lua_next(L, master) != 0) {
    lua_pushvalue(L, -2);
    lua_insert(L, -2);
    lua_rawset(L, copy);
  }
  lua_replace(L, master);  /* overwrite master's slot with the copy, dropping master */
  return lua_gettop(L);
}

static int elysium_proxy_len (lua_State *L) {
  lua_pushinteger(L, (lua_Integer)lua_rawlen(L, lua_upvalueindex(1)));
  return 1;
}
static int elysium_proxy_iter (lua_State *L) {
  /* Called as iterFn(state, key) per the 'next' protocol; state (the proxy) is
  ** ignored — upvalue1 is the hidden table actually being walked. */
  lua_settop(L, 2);
  lua_pushvalue(L, lua_upvalueindex(1));  /* hidden, at index 3 */
  lua_pushvalue(L, 2);                    /* key, at index 4 */
  if (lua_next(L, 3) == 0) {
    lua_pushnil(L);
    return 1;
  }
  return 2;
}
static int elysium_proxy_pairs (lua_State *L) {
  lua_pushvalue(L, lua_upvalueindex(1));  /* the elysium_proxy_iter closure */
  lua_pushvalue(L, 1);                    /* state = the proxy itself */
  lua_pushnil(L);
  return 3;
}

/* Builds a frozen read-only proxy for 'hiddenIdx' (D8: "empty table + metatable
** {__index = hidden, __newindex = raise, __len, __pairs = C-closure iterator
** holding hidden as upvalue, __metatable = locked}") and returns its stack index.
** F3: the metatable is registered into the environment manifest at 'manifestIdx'
** (see elysium_mark_env_owned) rather than only the state-wide host-owned set, so
** elysium_destroy_environment can reclaim it.
*/
static int elysium_make_proxy (lua_State *L, int hiddenIdx, int manifestIdx) {
  hiddenIdx = lua_absindex(L, hiddenIdx);
  lua_newtable(L);                        /* proxy */
  lua_newtable(L);                        /* metatable */
  lua_pushvalue(L, hiddenIdx);
  lua_setfield(L, -2, "__index");
  lua_pushcfunction(L, elysium_frozen_newindex_error);
  lua_setfield(L, -2, "__newindex");
  lua_pushvalue(L, hiddenIdx);
  lua_pushcclosure(L, elysium_proxy_len, 1);
  lua_setfield(L, -2, "__len");
  lua_pushvalue(L, hiddenIdx);
  lua_pushcclosure(L, elysium_proxy_iter, 1);
  lua_pushcclosure(L, elysium_proxy_pairs, 1);
  lua_setfield(L, -2, "__pairs");
  lua_pushliteral(L, "locked");
  lua_setfield(L, -2, "__metatable");
  elysium_mark_env_owned(L, -1, manifestIdx);
  lua_setmetatable(L, -2);
  return lua_gettop(L);
}

/* ==========================================================================
** elysium_openlibs (C27): runs once, under lua_pcall, as the protected state
** builder called from elysium_newstate.
** ======================================================================= */
int elysium_openlibs (lua_State *L) {
  int gidx, sidx, tidx, midx, uidx;

  lua_newtable(L);
  lua_rawsetp(L, LUA_REGISTRYINDEX, &ELYSIUM_HOSTOWNED_KEY);
  lua_newtable(L);
  lua_rawsetp(L, LUA_REGISTRYINDEX, &ELYSIUM_HANDLE_META_KEY);
  lua_newtable(L);
  lua_rawsetp(L, LUA_REGISTRYINDEX, &ELYSIUM_HANDLE_INTERN_KEY);

  /* D8: base/string/table/math/utf8 only — never coroutine/os/io/package/debug. */
  luaL_requiref(L, LUA_GNAME, luaopen_base, 1);
  gidx = lua_gettop(L);
  luaL_requiref(L, LUA_STRLIBNAME, luaopen_string, 1);
  sidx = lua_gettop(L);
  luaL_requiref(L, LUA_TABLIBNAME, luaopen_table, 1);
  tidx = lua_gettop(L);
  luaL_requiref(L, LUA_MATHLIBNAME, luaopen_math, 1);
  midx = lua_gettop(L);
  luaL_requiref(L, LUA_UTF8LIBNAME, luaopen_utf8, 1);
  uidx = lua_gettop(L);

  /* Generic rewrap (D8): every remaining light C function becomes a 1-upvalue
  ** closure before any wrapper/removal touches these tables. */
  elysium_rewrap_table(L, gidx);
  elysium_rewrap_table(L, sidx);
  elysium_rewrap_table(L, tidx);
  elysium_rewrap_table(L, midx);
  elysium_rewrap_table(L, uidx);

  /* String metatable (process-wide; C24: rewrap the arithmetic metamethods). */
  lua_pushliteral(L, "");
  lua_getmetatable(L, -1);
  {
    int smeta = lua_gettop(L);
    elysium_rewrap_table(L, smeta);  /* __add.. __unm; __index (a table) untouched */
    lua_pushliteral(L, "locked");
    lua_setfield(L, smeta, "__metatable");
    elysium_mark_host_owned(L, smeta);
  }
  lua_pop(L, 2);  /* metatable, dummy string */

  /* Removals (D8 allowlist). */
  elysium_remove_field(L, gidx, "load");
  elysium_remove_field(L, gidx, "loadfile");
  elysium_remove_field(L, gidx, "dofile");
  elysium_remove_field(L, gidx, "collectgarbage");
  elysium_remove_field(L, gidx, "rawset");
  elysium_remove_field(L, gidx, "rawget");
  elysium_remove_field(L, gidx, "warn");
  elysium_remove_field(L, gidx, "_G");
  elysium_remove_field(L, gidx, "print");       /* installed per-environment */
  elysium_remove_field(L, sidx, "dump");
  elysium_remove_field(L, midx, "random");      /* installed per-environment */
  elysium_remove_field(L, midx, "randomseed");  /* installed per-environment */

  /* Wrappers. */
  elysium_wrap_field(L, gidx, "setmetatable", elysium_setmetatable);
  {
    /* pairs' default branch needs the (already-rewrapped) 'next' closure. */
    lua_getfield(L, gidx, "next");
    lua_pushcclosure(L, elysium_pairs, 1);
    lua_setfield(L, gidx, "pairs");
  }
  {
    lua_pushnil(L);
    lua_pushcclosure(L, elysium_ipairs_aux, 1);
    lua_pushcclosure(L, elysium_ipairs, 1);
    lua_setfield(L, gidx, "ipairs");
  }

  elysium_wrap_field(L, sidx, "find", elysium_str_find);
  elysium_wrap_field(L, sidx, "match", elysium_str_match);
  elysium_wrap_field(L, sidx, "gmatch", elysium_str_gmatch);
  elysium_wrap_field(L, sidx, "gsub", elysium_str_gsub);
  elysium_wrap_field(L, sidx, "format", elysium_str_format);
  elysium_wrap_field(L, sidx, "rep", elysium_str_rep);
  elysium_wrap_field(L, sidx, "byte", elysium_str_byte);
  elysium_wrap_field(L, sidx, "pack", elysium_str_pack);  /* C36: pack moves to wrapped */

  elysium_wrap_field(L, tidx, "sort", elysium_table_sort);
  elysium_wrap_field(L, tidx, "concat", elysium_table_concat);
  elysium_wrap_field(L, tidx, "unpack", elysium_table_unpack);
  elysium_wrap_field(L, tidx, "move", elysium_table_move);
  elysium_wrap_field(L, tidx, "insert", elysium_table_insert);
  elysium_wrap_field(L, tidx, "remove", elysium_table_remove);

  elysium_wrap_field(L, midx, "sin", elysium_math_sin);
  elysium_wrap_field(L, midx, "cos", elysium_math_cos);
  elysium_wrap_field(L, midx, "atan", elysium_math_atan);
  elysium_wrap_field(L, midx, "exp", elysium_math_exp);
  elysium_wrap_field(L, midx, "log", elysium_math_log);
  elysium_wrap_field(L, midx, "tan", elysium_math_tan);
  elysium_wrap_field(L, midx, "asin", elysium_math_asin);
  elysium_wrap_field(L, midx, "acos", elysium_math_acos);
  /* log2/log10 have no native lmathlib entry to wrap (D8's allowlist table never
  ** listed them) — added directly, matching the "add a brand-new field" idiom
  ** elysium_make_environment already uses for random/randomseed/print below.
  */
  lua_pushcfunction(L, elysium_math_log2);
  lua_setfield(L, midx, "log2");
  lua_pushcfunction(L, elysium_math_log10);
  lua_setfield(L, midx, "log10");

  elysium_wrap_field(L, uidx, "codepoint", elysium_utf8_checked);
  elysium_wrap_field(L, uidx, "len", elysium_utf8_checked);
  elysium_wrap_field(L, uidx, "offset", elysium_utf8_checked);
  elysium_wrap_field(L, uidx, "codes", elysium_utf8_codes);

  /* Stash the five sanitized masters in the registry; elysium_make_environment
  ** deep-copies from here (never shares a writable table between environments).
  */
  lua_pushvalue(L, gidx); lua_rawsetp(L, LUA_REGISTRYINDEX, &ELYSIUM_MASTER_GLOBALS_KEY);
  lua_pushvalue(L, sidx); lua_rawsetp(L, LUA_REGISTRYINDEX, &ELYSIUM_MASTER_STRING_KEY);
  lua_pushvalue(L, tidx); lua_rawsetp(L, LUA_REGISTRYINDEX, &ELYSIUM_MASTER_TABLE_KEY);
  lua_pushvalue(L, midx); lua_rawsetp(L, LUA_REGISTRYINDEX, &ELYSIUM_MASTER_MATH_KEY);
  lua_pushvalue(L, uidx); lua_rawsetp(L, LUA_REGISTRYINDEX, &ELYSIUM_MASTER_UTF8_KEY);

  lua_settop(L, 0);
  return 0;
}

/* ==========================================================================
** Environment construction (D8).
** ======================================================================= */
int elysium_make_environment (lua_State *L, unsigned long long envId) {
  int base = lua_gettop(L);
  int manifest;
  int globalsHidden, stringHidden, tableHidden, mathHidden, utf8Hidden;
  int stringProxy, tableProxy, mathProxy, utf8Proxy, globalsProxy;
  int envTable;

  /* F1 (test.md: "elysium_make_environment/elysium_deepcopy_master... push ~= 16
  ** slots with no lua_checkstack"): this call runs unprotected (Swift calls it
  ** directly, never under elysium_pcall/elysium_resume — see elysium_deepcopy_
  ** master's comment on why luaL_checkstack, which raises, is still the right
  ** choice here). Reserve generous headroom for everything this function plus
  ** elysium_deepcopy_master/elysium_make_proxy push (observed peak well under 20
  ** slots) plus a full LUA_MINSTACK of margin.
  */
  luaL_checkstack(L, 40, "elysium_make_environment");

  /* F3 (design.md Condition 30 / test.md F3): this environment's manifest of
  ** host-owned objects (elysium_mark_env_owned), registered under its envId
  ** immediately so elysium_freeze_table -- called later, from Swift, for any
  ** host-binding table tree -- can find and append to the same manifest.
  ** Deliberately occupies stack slot base+1 for the rest of this function: the
  ** existing 'lua_copy(L, envTable, base + 1)' at the end overwrites this stack
  ** slot's *value* with envTable, which is exactly what already happened here
  ** before this change (an unused reserved slot) -- the manifest table itself
  ** stays alive independently via the registry anchor set below, not via this
  ** stack slot.
  */
  lua_newtable(L);
  manifest = lua_gettop(L);
  lua_rawgetp(L, LUA_REGISTRYINDEX, &ELYSIUM_ENV_MANIFEST_KEY);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushvalue(L, -1);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &ELYSIUM_ENV_MANIFEST_KEY);
  }
  lua_pushvalue(L, manifest);
  lua_rawseti(L, -2, (lua_Integer)envId);   /* manifestsTable[envId] = manifest */
  lua_pop(L, 1);                            /* drop manifestsTable */

  globalsHidden = elysium_deepcopy_master(L, &ELYSIUM_MASTER_GLOBALS_KEY);
  stringHidden  = elysium_deepcopy_master(L, &ELYSIUM_MASTER_STRING_KEY);
  tableHidden   = elysium_deepcopy_master(L, &ELYSIUM_MASTER_TABLE_KEY);
  mathHidden    = elysium_deepcopy_master(L, &ELYSIUM_MASTER_MATH_KEY);
  utf8Hidden    = elysium_deepcopy_master(L, &ELYSIUM_MASTER_UTF8_KEY);

  /* print (reserved fid 0) and math.random/randomseed (reserved fids 1, 2) are
  ** genuinely per-environment: they need this environment's id / RNG stream. */
  lua_pushinteger(L, (lua_Integer)envId);
  lua_pushcclosure(L, elysium_print, 1);
  lua_setfield(L, globalsHidden, "print");

  lua_pushinteger(L, 1);
  lua_pushinteger(L, (lua_Integer)envId);
  lua_pushcclosure(L, elysium_tramp, 2);
  lua_setfield(L, mathHidden, "random");

  lua_pushinteger(L, 2);
  lua_pushinteger(L, (lua_Integer)envId);
  lua_pushcclosure(L, elysium_tramp, 2);
  lua_setfield(L, mathHidden, "randomseed");

  stringProxy = elysium_make_proxy(L, stringHidden, manifest);
  tableProxy  = elysium_make_proxy(L, tableHidden, manifest);
  mathProxy   = elysium_make_proxy(L, mathHidden, manifest);
  utf8Proxy   = elysium_make_proxy(L, utf8Hidden, manifest);

  lua_pushvalue(L, stringProxy); lua_setfield(L, globalsHidden, "string");
  lua_pushvalue(L, tableProxy);  lua_setfield(L, globalsHidden, "table");
  lua_pushvalue(L, mathProxy);   lua_setfield(L, globalsHidden, "math");
  lua_pushvalue(L, utf8Proxy);   lua_setfield(L, globalsHidden, "utf8");

  globalsProxy = elysium_make_proxy(L, globalsHidden, manifest);

  lua_newtable(L);
  envTable = lua_gettop(L);
  lua_newtable(L);
  lua_pushvalue(L, globalsProxy);
  lua_setfield(L, -2, "__index");
  lua_pushliteral(L, "locked");
  lua_setfield(L, -2, "__metatable");
  elysium_mark_env_owned(L, -1, manifest);
  lua_setmetatable(L, envTable);

  lua_copy(L, envTable, base + 1);
  lua_settop(L, base + 1);

  {
    int ref = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
    return ref;
  }
}

void elysium_destroy_environment (lua_State *L, int envRef, unsigned long long envId) {
  /* F3: un-mark every object this environment ever registered as host-owned
  ** (elysium_mark_env_owned) before dropping envRef -- otherwise
  ** ELYSIUM_HOSTOWNED_KEY's own strong reference to each metatable (as a table
  ** key) keeps the whole per-environment object graph reachable forever,
  ** regardless of _ENV's own ref being released.
  */
  lua_rawgetp(L, LUA_REGISTRYINDEX, &ELYSIUM_ENV_MANIFEST_KEY);
  {
    int manifestsTable = lua_gettop(L);
    lua_rawgeti(L, manifestsTable, (lua_Integer)envId);
    if (lua_istable(L, -1)) {
      int manifest = lua_gettop(L);
      lua_rawgetp(L, LUA_REGISTRYINDEX, &ELYSIUM_HOSTOWNED_KEY);
      {
        int hostOwned = lua_gettop(L);
        lua_Integer n = (lua_Integer)lua_rawlen(L, manifest);
        lua_Integer i;
        for (i = 1; i <= n; i++) {
          lua_rawgeti(L, manifest, i);   /* the marked object */
          lua_pushnil(L);
          lua_rawset(L, hostOwned);      /* hostOwned[object] = nil -- un-mark */
        }
      }
      lua_pop(L, 1);   /* hostOwned */
    }
    lua_pop(L, 1);     /* manifest (or nil) */
    lua_pushnil(L);
    lua_rawseti(L, manifestsTable, (lua_Integer)envId);  /* manifests[envId] = nil */
  }
  lua_pop(L, 1);       /* manifestsTable */

  luaL_unref(L, LUA_REGISTRYINDEX, envRef);
}

/* ==========================================================================
** Handle kinds (D10).
** ======================================================================= */
int elysium_register_handle_kind (lua_State *L, const char *name, size_t nameLen,
                                   int interned, int *baseFid) {
  elysium_state *st = elysium_state_of(L);
  int kindId = st->handleKindCount++;
  int fidBase = 3 + kindId * 4;  /* 0/1/2 reserved for print/random/randomseed */
  static const char *names[4] = {"__index", "__newindex", "__eq", "__tostring"};
  int i;

  /* F1: like elysium_deepcopy_master -- called directly by Swift
  ** (LuaState.registerHandleKind), never under a protected frame. */
  luaL_checkstack(L, LUA_MINSTACK, "elysium_register_handle_kind");

  if (baseFid) *baseFid = fidBase;

  lua_newtable(L);
  {
    int meta = lua_gettop(L);
    for (i = 0; i < 4; i++) {
      lua_pushinteger(L, fidBase + i);
      lua_pushcclosure(L, elysium_tramp, 1);
      lua_setfield(L, meta, names[i]);
    }
    lua_pushlstring(L, name, nameLen);
    lua_setfield(L, meta, "__name");
    lua_pushliteral(L, "locked");
    lua_setfield(L, meta, "__metatable");
    elysium_mark_host_owned(L, meta);

    lua_rawgetp(L, LUA_REGISTRYINDEX, &ELYSIUM_HANDLE_META_KEY);
    lua_pushvalue(L, meta);
    lua_rawseti(L, -2, kindId);
    lua_pop(L, 1);

    if (interned) {
      lua_newtable(L);
      lua_rawgetp(L, LUA_REGISTRYINDEX, &ELYSIUM_HANDLE_INTERN_KEY);
      lua_pushvalue(L, -2);
      lua_rawseti(L, -2, kindId);
      lua_pop(L, 2);
    }
  }
  lua_pop(L, 1);
  return kindId;
}

void elysium_make_handle (lua_State *L, int kindId, unsigned long long id,
                           const char *ref, size_t refLen, int interned) {
  int internTable = 0, kindTable = 0;

  /* F1: called from pushScriptValue's .ref case, sometimes unprotected (a call()/
  ** resume() argument push, before elysium_pcall/elysium_resume) and sometimes
  ** protected (a host function's own result push, inside the trampoline) -- see
  ** elysium_deepcopy_master's comment for why luaL_checkstack is still correct
  ** in the unprotected case too. */
  luaL_checkstack(L, LUA_MINSTACK, "elysium_make_handle");

  if (interned) {
    lua_rawgetp(L, LUA_REGISTRYINDEX, &ELYSIUM_HANDLE_INTERN_KEY);
    internTable = lua_gettop(L);
    lua_rawgeti(L, internTable, kindId);
    kindTable = lua_gettop(L);
    lua_pushlstring(L, ref, refLen);
    lua_gettable(L, kindTable);
    if (!lua_isnil(L, -1)) {
      lua_replace(L, internTable);
      lua_settop(L, internTable);
      return;
    }
    lua_pop(L, 1);
  }

  {
    elysium_handle_payload *payload =
        (elysium_handle_payload *)lua_newuserdatauv(L, sizeof(elysium_handle_payload), 2);
    int handle = lua_gettop(L);
    payload->kindId = kindId;
    payload->id = id;

    lua_newtable(L);
    lua_setiuservalue(L, handle, 1);        /* method cache */
    lua_pushlstring(L, ref, refLen);
    lua_setiuservalue(L, handle, 2);        /* ref string */

    lua_rawgetp(L, LUA_REGISTRYINDEX, &ELYSIUM_HANDLE_META_KEY);
    lua_rawgeti(L, -1, kindId);
    lua_setmetatable(L, handle);
    lua_pop(L, 1);

    if (interned) {
      lua_pushlstring(L, ref, refLen);
      lua_pushvalue(L, handle);
      lua_settable(L, kindTable);
      lua_replace(L, internTable);
      lua_settop(L, internTable);
    }
  }
}

void elysium_invalidate_handle (lua_State *L, int kindId, const char *ref, size_t refLen) {
  lua_rawgetp(L, LUA_REGISTRYINDEX, &ELYSIUM_HANDLE_INTERN_KEY);
  lua_rawgeti(L, -1, kindId);
  if (!lua_isnil(L, -1)) {
    lua_pushlstring(L, ref, refLen);
    lua_pushnil(L);
    lua_settable(L, -3);
  }
  lua_pop(L, 2);
}

/* Additive (Builder, Lane C; see elysium_shim.h). 'lua_rawlen' of a full userdata is
** its byte size (the Lua manual), so a size mismatch alone is enough to refuse a
** value that only happens to be *some* full userdata but not one of ours.
*/
static elysium_handle_payload *elysium_handle_payload_at (lua_State *L, int idx) {
  idx = lua_absindex(L, idx);
  if (lua_type(L, idx) != LUA_TUSERDATA) return NULL;
  if (lua_rawlen(L, idx) != sizeof(elysium_handle_payload)) return NULL;
  return (elysium_handle_payload *)lua_touserdata(L, idx);
}

int elysium_handle_kind (lua_State *L, int idx) {
  elysium_handle_payload *payload = elysium_handle_payload_at(L, idx);
  return (payload != NULL) ? payload->kindId : -1;
}

unsigned long long elysium_handle_id (lua_State *L, int idx) {
  elysium_handle_payload *payload = elysium_handle_payload_at(L, idx);
  return (payload != NULL) ? payload->id : 0;
}

void elysium_freeze_table (lua_State *L, int idx, unsigned long long envId) {
  int hiddenIdx = lua_absindex(L, idx);
  int manifest;

  /* F1: called from Swift (Environment.swift's installHostBindings), never under
  ** a protected frame -- see elysium_deepcopy_master's comment. */
  luaL_checkstack(L, LUA_MINSTACK, "elysium_freeze_table");

  /* F3: this environment's manifest was registered by elysium_make_environment
  ** (which always runs before any host-binding installation) under the same
  ** envId; elysium_make_proxy below appends the fresh proxy's metatable to it so
  ** elysium_destroy_environment reclaims a host-binding table tree too. */
  lua_rawgetp(L, LUA_REGISTRYINDEX, &ELYSIUM_ENV_MANIFEST_KEY);
  lua_rawgeti(L, -1, (lua_Integer)envId);
  manifest = lua_gettop(L);

  elysium_make_proxy(L, hiddenIdx, manifest);  /* pushes a fresh proxy over 'hiddenIdx' */
  lua_replace(L, hiddenIdx);                   /* ... and moves it into the original slot */
  lua_pop(L, 2);   /* this env's manifest, the manifests table */
}
