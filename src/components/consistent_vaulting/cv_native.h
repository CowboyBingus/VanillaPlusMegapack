/* Consistent Vaulting: the game functions it calls (windows_api.lua api.native), by their addresses on build 25480438.
 * cv_native.c checks the bindings and the code bytes once per session, as the Lua did, before any call. */
#ifndef CV_NATIVE_H
#define CV_NATIVE_H

#include <stdint.h>

typedef struct CvNativeFns
{
    uint64_t (*valid)(uint32_t actor);                            /* exe 0x7972F0: actor validity */
    uint32_t (*flags)(uint32_t actor);                            /* exe 0x7993D0: actor flags */
    void (*motion)(uint32_t actor, float* first, float* second);  /* exe 0x799540: actor motion */
    uint32_t (*mover)(uint32_t unit, uint32_t name);              /* exe 0x7CE220: mover lookup */
    void* (*dimensions)(uint32_t mover);                          /* exe 0x7CFE10: mover dimensions */
    void (*position)(uint32_t mover, float* out);                 /* exe 0x7CF050: mover position */
    void* (*basis)(void* matrix, const float* forward, const float* up); /* game.dll 0x173F150: direction/up basis */
    void (*rotation)(float* quaternion, const void* matrix);       /* game.dll 0x173A750: basis to quaternion */
    int32_t (*classify)(void* unused, const void* entity, const float* point, const float* quaternion); /* game.dll 0xA9D560: exit */
    uint32_t (*world_id)(const void* world);                      /* exe 0x79F860 */
    uint32_t (*query)(uint32_t world, uint32_t a, uint32_t b, uint32_t c, uint32_t filter, const void* descriptor,
        void* out, uint32_t capacity);                            /* exe 0x7F9070: synchronous shape query */
    void (*drive)(void* controller, float dt);                    /* game.dll 0xA9A0C0: the original local driver */
    uint32_t (*detect)(void* controller, float dt);               /* game.dll 0xA9C3E0: the approach detector */
    uint8_t (*approach)(void* unused, const void* args, float* first, float* last, float* span, float* width); /* game.dll 0xA9DD90 */
    void (*override)(void* manager, const void* entity, const void* modifier); /* game.dll 0x83C420: settings override */
} CvNativeFns;

#ifdef VPM_TEST
/* Tests: the functions the binding takes instead of the game's (after the same checks), until NULL. */
void cv_native_test(const CvNativeFns* fns);
#endif

#endif
