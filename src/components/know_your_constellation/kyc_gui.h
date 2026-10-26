/* The engine Gui calls Know Your Constellation's panel makes, behind one small interface so the route that reaches the
 * engine can be swapped (kyc_gui.c says which routes there are and what each needs). Each member is one engine call
 * the Lua made through stingray.* (panel.lua), with the same arguments; the value constructors it built them from
 * (Vector2, Vector3, Color, IdString64.from_hex) are the route's business. Every call comes from the game thread, on
 * frames the panel is up or changes. */
#ifndef KYC_GUI_H
#define KYC_GUI_H

#include <stddef.h>
#include <stdint.h>

typedef uint64_t KycRef;                            /* an engine object as the route names it; 0 none */
typedef struct KycColour { uint8_t a, r, g, b; } KycColour;   /* Color(a, r, g, b) */
typedef struct KycBox { double x, y, z, w, h; } KycBox;        /* Vector3(x, y, z: the layer), Vector2(w, h) */
typedef struct KycLabel
{
    const char* text;   /* UTF-8, not NUL-terminated: length bytes */
    size_t length;
    uint64_t font;      /* IdString64 of the font and of its material (resource hashes) */
    uint64_t material;
    double size;
    double x, y, z;     /* Vector3(x, y, layer) */
    KycColour colour;
} KycLabel;

/* Gui.text_extents' three results, as the bits of what it gave */
#define KYC_EXTENT_MIN 1
#define KYC_EXTENT_MAX 2
#define KYC_EXTENT_CARET 4

typedef struct KycGui
{
    const char* route;
    /* NULL while the route can draw; else why not (the component's status says it) */
    const char* (*unavailable)(void);
    KycRef (*main_world)(void);                                          /* Application.main_world() */
    int (*worlds)(KycRef* list, int capacity);                           /* Application.worlds(): count, -1 no list */
    KycRef (*create_screen_gui)(KycRef world);                           /* World.create_screen_gui(w, 'scale', 1, 1) */
    void (*destroy_gui)(KycRef world, KycRef gui);                       /* World.destroy_gui(w, gui) */
    KycRef (*material)(KycRef gui, uint64_t material);                   /* Gui.material(gui, IdString64) */
    void (*set_scalar)(KycRef material, uint64_t slot, double value);   /* Material.set_scalar(m, IdString64, v) */
    void (*set_vector2)(KycRef material, uint64_t slot, double x, double y);
    void (*set_vector4)(KycRef material, uint64_t slot, KycColour colour); /* Material.set_vector4(m, slot, Color()) */
    void (*set_texture)(KycRef material, uint64_t slot, uint64_t texture);
    int (*resolution)(double* width, double* height);                    /* Gui.resolution(): 1, or 0 none */
    /* Gui.text_extents(gui, text, IdString64(font), size): out[0] min.x, out[1] max.x, out[2] caret.x */
    int (*text_extents)(KycRef gui, const char* text, size_t length, uint64_t font, double size, double out[3]);
    KycRef (*rect)(KycRef gui, const KycBox* box, KycColour colour);     /* Gui.rect: its id, 0 none */
    void (*update_rect)(KycRef gui, KycRef id, const KycBox* box, KycColour colour);
    KycRef (*text)(KycRef gui, const KycLabel* label);                   /* Gui.text: its id, 0 none */
    void (*update_text)(KycRef gui, KycRef id, const KycLabel* label);
} KycGui;

/* The route the panel draws through: kyc_gui.c's none route, the pack's Lua part (kyc_lua.c), or a test's. */
const KycGui* kyc_gui(void);
void kyc_gui_use(const KycGui* gui); /* NULL: back to kyc_gui.c's none route */
int kyc_gui_is_none(void);           /* 1 while the route is the none route */

#endif
