/*
** $Id: lundump.c $
** load precompiled Lua chunks
** See Copyright Notice in lua.h
*/

/*
** Elysium: this file is replaced in full by scripts/clua/elysium.patch. The stock
** bytecode loader is an unverified binary format (crafted bytecode can corrupt the
** VM) and every interpreter input in this build is untrusted script text, so binary
** loading is removed outright rather than hardened. 'elysium_loadtext' already
** refuses a chunk starting with the LUAC_DATA/binary signature before reaching here
** (mode "t"); this stub is defence in depth for any other path that could reach
** 'luaU_undump' (e.g. 'load' with a binary reader — 'load' itself is removed from
** the sandbox, but the C entry point must still fail closed on its own).
*/

#define lundump_c
#define LUA_CORE

#include "lprefix.h"

#include "lua.h"

#include "ldo.h"
#include "lobject.h"
#include "lundump.h"
#include "lzio.h"

LClosure *luaU_undump (lua_State *L, ZIO *Z, const char *name) {
  (void)Z;
  luaO_pushfstring(L, "%s: binary chunks are disabled", name);
  luaD_throw(L, LUA_ERRSYNTAX);
  return NULL;  /* unreachable: luaD_throw never returns */
}
