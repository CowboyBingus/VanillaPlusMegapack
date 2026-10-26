/* Know Your Constellation's Lua part: the bridge between the pack's DLL and lua/forecast_panel.lua, the pack's one Lua
 * file, which Bingus Shared Loader starts from the pack's data patch (kyc_lua.c says how they work together).
 *
 * The Lua part attaches once (vpm_kyc_lua_attach) with one dispatcher, a LuaJIT ffi callback that makes one engine
 * Gui call per KycLuaCall. While the bridge's `work` is 0, the Lua part's update does nothing else; when it is not,
 * the update calls vpm_kyc_lua_apply once, and the panel (kyc_panel.c) draws through the dispatcher in that call.
 *
 * The structs below are the Lua part's ffi.cdef, field for field (lua/forecast_panel.lua). Change both together and
 * raise KYC_LUA_VERSION: attach refuses a Lua part of another version, or whose KycLuaCall has another size. */
#ifndef KYC_LUA_H
#define KYC_LUA_H

#include <stdint.h>
#include "kyc.h"

#define KYC_LUA_VERSION 1
#define KYC_LUA_WORLDS 64

/* One engine call (op) with its arguments and results. References (worlds, GUIs, materials, rectangles, texts) are the
 * Lua part's own numbers for the engine's objects, as doubles so LuaJIT reads them as plain numbers; resource hashes
 * travel as 16 lower-case hex digits (IdString64.from_hex), as the Lua mod kept them. */
typedef struct KycLuaCall
{
    int32_t op, capacity;          /* capacity: of refs, for KYC_LUA_WORLDS_OP */
    double world, gui, item;       /* the objects the call names, or the one it made */
    double x, y, z, w, h;          /* a position (z: the layer) and a size; resolution's results in w, h */
    double size, value;            /* a text size; a scalar */
    uint8_t a, r, g, b;            /* Color(a, r, g, b) */
    uint32_t length;               /* text's bytes */
    const char* text;              /* UTF-8, not NUL-terminated */
    char id[2][24];                /* IdString64 hex texts: the font or slot, then the material or texture */
    double out[3];                 /* text_extents: min.x, max.x, caret.x */
    double refs[KYC_LUA_WORLDS];   /* worlds' results */
    char error[192];               /* the engine's error, when the call raised */
} KycLuaCall;

/* The dispatcher's results: 1 done (its outputs set), 0 the engine gave nothing, -1 no world list, -2 the call raised
 * (error set). */
#define KYC_LUA_RAISED (-2)
typedef int (*KycLuaDispatch)(KycLuaCall* call);

/* The ops, in kyc_gui.h's order. */
enum
{
    KYC_LUA_MAIN_WORLD = 1, KYC_LUA_WORLDS_OP, KYC_LUA_CREATE_GUI, KYC_LUA_DESTROY_GUI, KYC_LUA_MATERIAL,
    KYC_LUA_SET_SCALAR, KYC_LUA_SET_VECTOR2, KYC_LUA_SET_VECTOR4, KYC_LUA_SET_TEXTURE, KYC_LUA_RESOLUTION,
    KYC_LUA_TEXT_EXTENTS, KYC_LUA_RECT, KYC_LUA_UPDATE_RECT, KYC_LUA_TEXT, KYC_LUA_UPDATE_TEXT
};

typedef struct KycLuaBridge
{
    uint32_t version;       /* KYC_LUA_VERSION */
    volatile int32_t work;  /* not 0: the Lua part's next update calls vpm_kyc_lua_apply */
} KycLuaBridge;

/* The DLL's exports for the Lua part (LuaJIT ffi). attach: the bridge, or NULL when version or call_size differ from
 * this DLL's (the refusal is logged on the component's next frame). apply: the panel's pending change, drawn now
 * through the dispatcher; from the Lua part's update only (the game thread). */
HF_MOD_EXPORT KycLuaBridge* vpm_kyc_lua_attach(uint32_t version, uint32_t call_size, KycLuaDispatch dispatch);
HF_MOD_EXPORT void vpm_kyc_lua_apply(void);

/* ---- for the component ---------------------------------------------------------------------------------------- */

/* From start(): the component the Lua part's work runs guarded for; the request starts empty. */
void kyc_lua_bind(VpmComponent* self);
/* At the start of a frame that may act: takes an attached Lua part as the panel's route (in place of kyc_gui.c's none
 * route only). 1 on the frame it does, -1 on the frame a refused one is first seen, else 0. */
int kyc_lua_adopt(void);
/* 1 while the Lua part is the panel's route. */
int kyc_lua_route(void);
/* Why the Lua part is not the route (kyc_gui.c's none route says it). */
const char* kyc_lua_absent(void);
/* The panel as the component's frame drives it (kyc_panel.h's show, suspend and clear, the same results). With the Lua
 * route they record the change for the Lua part's next update, which draws it; the results are then the last draw's
 * (a draw's error comes back once, on the next show or suspend). With any other route they draw at once. */
int kyc_surface_show(const KycModel* model, double dt, const KycAnchor* anchor);
int kyc_surface_suspend(const KycAnchor* anchor);
int kyc_surface_clear(void);
/* The frame drops the forecast after an error (the Lua mod's frame cleared the panel then). After a draw's error that
 * this frame was given, the draw has already cleared it and is retried on the Lua part's next update (as the Lua mod
 * drew again on the next frame); otherwise it is kyc_surface_clear. */
int kyc_surface_drop(void);
/* For the tests: the bridge, and forgetting the Lua part. */
const KycLuaBridge* kyc_lua_bridge(void);
void kyc_lua_reset(void);

#endif
