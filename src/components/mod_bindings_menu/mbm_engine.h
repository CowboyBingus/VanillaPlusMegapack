/* Mod Bindings Menu's extended bindings and MORE MODS page read the engine's input and draw with the engine's Gui. The
 * Lua reached both through stingray's Lua tables (Keyboard, Mouse, Pad1-4, Window.has_focus; World.create_screen_gui,
 * Gui.rect/text/text_extents, Material). A C mod has no route to them yet (KB hellforge-megapack-native-port §5: the
 * ScriptApi Gui and Input C tables, or the Lua bindings called from C), so they sit behind these two interfaces.
 * Until a backend sets them (mbm_engine_set), extended bindings answer "unknown" (the caller's fixed key) and the
 * MORE MODS tab is not offered; everything else of the component works without them. */
#ifndef MBM_ENGINE_H
#define MBM_ENGINE_H

#include <stdint.h>

#define MBM_KEYBOARD 1
#define MBM_MOUSE 2
#define MBM_PAD 3

/* One engine input device, answering as stingray's Keyboard, Mouse and PadN tables do. */
typedef struct MbmDevice
{
    int (*button)(uint32_t index);                       /* 1 held (a value above 0.5) */
    int (*any_pressed)(uint32_t* index);                 /* 1 with the first button pressed this frame */
    int (*pressed)(uint32_t index);                      /* 1 pressed this frame (Mouse.pressed: buttons, wheel); NULL none */
    int (*button_id)(const char* name, uint32_t* index); /* 1 with the engine's index for a button name */
    const char* (*button_name)(uint32_t index);          /* the engine's name ("left ctrl"), NULL none */
    const char* (*locale_name)(uint32_t index);          /* the localized name, NULL none */
    int (*connected)(void);                              /* pads: 1 connected; NULL: counts as connected */
} MbmDevice;

typedef struct MbmEngineInput
{
    const MbmDevice* keyboard; /* required: without it the input is not ready */
    const MbmDevice* mouse;
    const MbmDevice* pads[4];
    int (*has_focus)(void);    /* 1 focused, 0 not, -1 the engine does not say; NULL: -1 */
} MbmEngineInput;

/* The panel's screen Gui (the Lua's panel.lua drawing). Colours are {alpha, red, green, blue}; y grows upward. */
typedef struct MbmGui
{
    /* Creates the Gui in the UI world with the body font (the hashes the game keeps for its font, the font's material
     * and atlas) and inks the material as the native font setup does. 1 created. */
    int (*open)(uint64_t font, uint64_t material, uint64_t atlas);
    void (*close)(void);
    int (*alive)(void); /* its world still exists */
    /* Retained primitives: handle 0 creates one and returns its handle (never 0); a handle updates it. A zero size hides
     * a rectangle. */
    uint32_t (*rect)(uint32_t handle, float x, float y, float layer, float w, float h, const uint8_t colour[4]);
    uint32_t (*text)(uint32_t handle, const char* text, float x, float y, float layer, float size, const uint8_t colour[4]);
    int (*text_width)(const char* text, float size, float* width); /* 1 measured */
} MbmGui;

/* Sets (or clears, with NULL) the engine's input and Gui. Both are needed for the MORE MODS page; the input alone makes
 * extended bindings answer. */
void mbm_engine_set(const MbmEngineInput* input, const MbmGui* gui);

#endif
