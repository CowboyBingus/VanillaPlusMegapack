/* The route Know Your Constellation's panel reaches the engine's Gui through (kyc_gui.h). The decision (user,
 * 2026-10-22): keep the game's look, no ImGui; draw with the same engine Gui calls the Lua made through stingray.Gui
 * (World.create_screen_gui, Gui.rect, text, update_rect, update_text, text_extents, material and resolution, the
 * Material setters, Application.worlds and main_world). Two routes reach those calls from C (KB
 * hellforge-megapack-native-port, section 5). Neither
 * can be finished from what is known offline on build 25480438, so the route here is none: the panel stays off, and
 * the component reads missions and computes forecasts as before, logging each new one.
 *
 * Route 1, the engine's script C API tables. game.dll keeps the master struct's pointer at game.dll + 0x3326308 (exe
 * 0x27C8D80, live: Match Your Colors calls its World +0x08, Unit +0x18, Material +0x28 and Mesh +0xE8 tables). The 2017
 * SDK's ScriptApi has Application at +0x10 and Gui at +0x80 (index 16), but HD2's struct has seven more entries before
 * Mesh (+0xE8, not +0xB0), so Gui's index is unknown, and so are the slots and C signatures inside the Gui, World,
 * Application and Material tables (the exe is packed: its data is filled at run time). What the probe must find: the
 * master struct's entries (its first 40 qwords) and each candidate table's function pointers; then, from the game's
 * Lua state, the C function behind each binding the panel uses (stingray.Gui.rect, .update_rect, .text, .update_text,
 * .text_extents, .material, .resolution; World.create_screen_gui, .destroy_gui; Application.worlds, .main_world;
 * Material.set_scalar, .set_vector2, .set_vector4, .set_texture: lua_tocfunction gives each wrapper's address) and,
 * in each wrapper's code, the table and slot it calls (`call [reg + slot]`) and how it passes vectors, colours and
 * IdString64 values. With those, this file gets a KycGui whose members call the slots.
 *
 * Route 2, the same stingray.* Lua functions called from C through the game's lua_State, which draws as the Lua did by
 * construction. lua51.dll (LuaJIT 2.1, loaded in the game; HellForge's copy exports the whole Lua C API) gives the
 * calls by name: lua_getfield, lua_pushnumber, lua_pushlstring, lua_pushvalue, lua_pcall, lua_gettop, lua_settop,
 * lua_type, lua_tonumber, luaL_ref, lua_rawgeti, luaL_unref. What is not known is the lua_State and when calling into
 * it is safe: LuaApi (get_engine_api id 1) has getscriptenvironmentstate, but the getter and the LuaApi table (exe
 * 0xa4fe0 and 0x27cc0a0 in a capture of an older build) and LuaApi's layout are unverified on 25480438; and HellForge's
 * game-thread tick (game.dll 0x13270B0, before the game's update) may run inside one of the engine's script calls, where
 * the running Lua thread may not be the main one. What the probe must find: the main lua_State* (from
 * getscriptenvironmentstate, or the L of the engine's lua_pcall of the script's update), whether HellForge's tick runs
 * inside a script call and on which lua_State, and that one stingray.Gui.rect call made from the tick draws on the war
 * table. With those, this file gets a KycGui whose members push the arguments and lua_pcall the bindings, keeping
 * worlds, GUIs and materials in the registry (luaL_ref) as their KycRef.
 *
 * Until then: kyc_gui() is the none route, and kyc_gui_use lets the tests (and a route under test) take its place. */
#include <stddef.h>
#include "kyc_gui.h"

static const char* NoRoute(void)
{
    return "no engine Gui route on HellForge yet (the in-game probe must find the ScriptApi Gui table or the game's "
           "lua_State)";
}

static const KycGui kNone = {"none", NoRoute};
static const KycGui* g_gui = &kNone;

const KycGui* kyc_gui(void) { return g_gui; }
void kyc_gui_use(const KycGui* gui) { g_gui = gui != NULL ? gui : &kNone; }
