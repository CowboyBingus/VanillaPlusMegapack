/* Mod Bindings Menu's own interface between its files (the component: mod_bindings_menu.c). Nothing outside this
 * folder includes it but the component's test. */
#ifndef MBM_H
#define MBM_H

#include <stddef.h>
#include <stdint.h>
#include "../../core/vpm.h"
#include "mbm_engine.h"

/* ---- game.dll, build 25480438 (the Lua's src/mod_bindings_menu.lua) ------------------------------------------- */

#define MBM_INPUT_OWNER_RVA 0x347CF18u   /* the input owner: action states and both binding maps */
#define MBM_MENU_SYSTEM_RVA 0x347CE38u
#define MBM_UI_STATE_RVA 0x347CE28u
#define MBM_ACTION_LABELS_RVA 0x26438A0u /* u32 label id per action, 97 per group */
#define MBM_BUILD_ROWS_RVA 0x1812940u
#define MBM_SET_TAB_LABELS_RVA 0x17AAC50u
#define MBM_LIST_RESET_RVA 0x1813DD0u
#define MBM_TAB_LABELS_RVA 0x3310210u
#define MBM_INPUT_CONSUME_RVA 0x12FDE90u
#define MBM_MODS_TITLE_RVA 0x3328420u
#define MBM_MODS_TITLE_ID 0x781E104Cu
#define MBM_MISSION_MODE_RVA 0x33266A0u
#define MBM_ACTION_STATE 808u            /* owner + 808 + 32 * (97 * group + action): the action's state, byte 0 set */
#define MBM_ACTION_STRIDE 32u
#define MBM_GROUP_ACTIONS 97u
#define MBM_BINDING_MAP 686800u          /* the live bindings: {records, u32 count = 256} */
#define MBM_DEFAULTS_MAP 686968u         /* the shipped defaults */
#define MBM_MAPPINGS 8u                  /* a 328-byte record: {u32 code, u32 count, 16 x 20-byte mappings} */
#define MBM_MAPPING_SIZE 20u
#define MBM_MAX_MAPPINGS 16u
#define MBM_RECORD_SIZE (MBM_MAPPINGS + MBM_MAX_MAPPINGS * MBM_MAPPING_SIZE)
#define MBM_MAP_RECORDS 256u
#define MBM_SCREEN_STACK 0x429Cu         /* the UI's screen stack: five screen types, then the depth */
#define MBM_BINDING_SCREEN 26u
#define MBM_MENU_SCREEN 208u             /* the menu system's screen object */

/* The binding page's screen object */
#define MBM_SELECTED_TAB 8u
#define MBM_TAB_BAR 1248u
#define MBM_TAB_COUNT 57448u
#define MBM_TAB_CURRENT 57452u
#define MBM_TAB_BUTTON_STATE 11004u
#define MBM_TAB_BUTTON_ACTIVE 11021u
#define MBM_TAB_BUTTON_STRIDE 3400u
#define MBM_ROW_LIST 338344u             /* the listing */
#define MBM_ROW_START 7856u
#define MBM_ROW_STRIDE 24784u
#define MBM_ROW_COUNT 2411916u
#define MBM_ROW_REQUEST 2411928u         /* the row count the builder reads */
#define MBM_CONTROLLER_PAGE 2411904u
#define MBM_NATIVE_TABS 3u
#define MBM_MODS_TAB 3u
#define MBM_MORE_TAB 4u

#define MBM_ACTIONS 36
#define MBM_SLOTS 7
#define MBM_MAX_RECORDS 64
#define MBM_ID_SIZE 128
#define MBM_TEXT_SIZE 512     /* 127 characters of UTF-8 and the terminator */
#define MBM_CATEGORY_SIZE 260 /* 64 characters */
#define MBM_MAX_ALTERNATIVES 16
#define MBM_MAX_INPUTS 5
#define MBM_SWEEP_INTERVAL 2.0f
#define MBM_SECTION "mod_bindings_menu"
#define MBM_EXTENDED_SECTION "mod_bindings_menu.bindings"

/* The dormant actions: {group, action, the action's own label id}, the seven fixed v1 slots first. */
typedef struct MbmDormant { uint8_t group, action; uint32_t label; } MbmDormant;
extern const MbmDormant mbm_dormant[MBM_ACTIONS];

/* ---- records ------------------------------------------------------------------------------------------------- */

#define MBM_PRESS 0
#define MBM_RELEASE 1
#define MBM_HOLD 2
#define MBM_NO_FRAME UINT64_MAX

typedef struct MbmInput { uint8_t device; uint16_t index; } MbmInput; /* MBM_KEYBOARD, MBM_MOUSE, MBM_PAD */
typedef struct MbmAlternative
{
    MbmInput inputs[MBM_MAX_INPUTS]; /* the first triggers; the others are held with it */
    uint8_t count, trigger, was;     /* was: held at the last evaluation */
} MbmAlternative;

/* An extended binding's saved keys (the Lua's bindings file record). */
#define MBM_KIND_NONE 0
#define MBM_KIND_DEFAULT 1
#define MBM_KIND_SET 2
#define MBM_KIND_CLEARED 3
#define MBM_KIND_UNKNOWN 4

typedef struct MbmRecord
{
    VpmBinding* binding;
    char id[MBM_ID_SIZE];             /* "<component>.<binding id>" */
    char text[MBM_TEXT_SIZE];         /* the row's label, upper case */
    char category[MBM_CATEGORY_SIZE]; /* its section, upper case */
    uint32_t requested;               /* the slot asked for, 0 automatic */
    uint32_t slot;                    /* the fixed slot it got, 0 automatic */
    uint32_t code;                    /* group * 65536 + action */
    uint8_t group, action;
    uint8_t extended, defaults_ready, plan;
    uint32_t swept_count;             /* the mapping count the sweep left, UINT32_MAX none */
    /* extended bindings */
    int position;
    uint8_t kind, resolved, inactive, down, dirty;
    int alternative_count;
    int64_t epoch;                    /* -1: never evaluated */
    uint64_t frame;
    MbmAlternative alternatives[MBM_MAX_ALTERNATIVES];
} MbmRecord;

/* ---- the shared state (mod_bindings_menu.c) ----------------------------------------------------------------- */

typedef struct MbmState
{
    VpmComponent* self;
    uintptr_t base;          /* game.dll once the build check passed */
    int initialized, ready;  /* ready: native input found, the list functions known */
    int labels_writable;     /* the action label table's pages (checked once) */
    int slots_writable;      /* the text slots' and the MODS title's pages (checked once) */
    uint32_t revision;       /* grows when the rows to show change */
    MbmRecord records[MBM_MAX_RECORDS];
    int record_count;
    MbmRecord* order[MBM_MAX_RECORDS]; /* native bindings in dormant order */
    int order_count;
    MbmRecord* extended_order[MBM_MAX_RECORDS]; /* by category, then registration */
    int extended_count;
    MbmRecord* used[MBM_ACTIONS];
    int defaults_pending, keyboard_pending;
    int page_open, page_visited, release_pending, title_active;
    int suppressed, in_mission, mission_check;
    float sweep_timer;
    uint64_t frame;
    uint32_t input_epoch, bindings_version;
    char more_text[64], more_header_text[64], empty_text[64], unnamed_text[64];
} MbmState;
extern MbmState mbm;

/* mod_bindings_menu.c */
int mbm_code_index(uint32_t code);       /* the dormant action's index, -1 none */
uint32_t mbm_code_at(int index);
int mbm_pointer(uint64_t value);         /* a user-mode pointer, as the Lua's word_pointer */
uintptr_t mbm_active_screen(void);
uintptr_t mbm_input_owner(void);
void mbm_refresh_status(void);

/* mbm_maps.c: binding maps, the native answer */
void mbm_maps_reset(void);
uintptr_t mbm_map_bucket(uint32_t map, uint32_t code); /* the cached record, else the map indexed again */
uintptr_t mbm_map_cached(uint32_t map, uint32_t code);
void mbm_map_forget(uint32_t map, uint32_t code);
uintptr_t mbm_live_header(MbmRecord* record, uint32_t* count);
int mbm_native_down(MbmRecord* record);
int mbm_maps_writable(uintptr_t bucket); /* the map holding bucket was found writable */
int mbm_in_mission(void);

/* mbm_sweep.c */
void mbm_sweep_reset(void);
void mbm_add_keyboard_defaults(void);
int mbm_sanitize_defaults(void);
void mbm_sweep(void);
uint32_t mbm_fingerprint(const uint32_t* words);

/* mbm_assign.c: reservations (the Lua's assignments file) and registration */
void mbm_assign_reset(void);
void* mbm_attach(VpmBinding* binding);
int mbm_assign_dirty(void);
void mbm_assign_flush(void);
/* The sweep's per-action marks: 0 none, 1 cleared (with fingerprints), 2 to be cleared entirely. mbm_mark_set kind 1:
 * cleared in this session; 3: only the list left changed. */
int mbm_mark(uint32_t code, uint32_t* found, uint32_t* left);
void mbm_mark_set(uint32_t code, int kind, uint32_t found, uint32_t left);
uint32_t mbm_session(void);

/* mbm_text.c */
int mbm_display_text(const char* text, int limit, char* out, size_t size); /* 1 usable */

/* mbm_tab.c: the native MODS tab */
void mbm_tab_reset(void);
void mbm_page_frame(uintptr_t screen, float seconds);
void mbm_tab_away(void);
int mbm_release_labels(void);
void mbm_mods_title(int active);
uint32_t mbm_claim_label(const char* text);
void mbm_set_functions(uintptr_t base);
void mbm_consume(uintptr_t owner, uint32_t action);

/* mbm_extended.c */
void mbm_extended_reset(void);
void mbm_register_extended(MbmRecord* record, const char* reason);
int mbm_extended_known(const char* id);
int mbm_extended_down(MbmRecord* record);
int mbm_extended_dirty(void);
void mbm_extended_flush(void);
const MbmEngineInput* mbm_engine_input(void); /* NULL while no input source is set */
const MbmGui* mbm_engine_gui(void);
int mbm_engine_down(int device, uint32_t index);
int mbm_engine_any_pressed(int device, uint32_t* index);
int mbm_window_focused(void);            /* 1, 0, -1 unknown */
const MbmDevice* mbm_device(int device);
int mbm_current(MbmRecord* record);      /* resolves record->alternatives: 1, 0 before engine input */
int mbm_store_alternatives(MbmRecord* record, const MbmAlternative* list, int count);
int mbm_extended_inactive(const MbmRecord* record); /* saved by a newer version: never changed, never firing */
const char* mbm_input_label(const MbmInput* input, char* out, size_t size);
MbmRecord* mbm_record(const char* id);

/* mbm_capture.c */
void mbm_capture_reset(void);
int mbm_begin_capture(MbmRecord* record, int controller, int (*hold_back)(void), void (*release_back)(void),
    const char** why);
void mbm_update_capture(float seconds);
void mbm_cancel_capture(const char* reason);
int mbm_capture_phase(MbmRecord** record, int* controller); /* MBM_IDLE ... */
#define MBM_IDLE 0
#define MBM_ARMING 1
#define MBM_CAPTURING 2
#define MBM_RELEASING 3

/* mbm_panel.c, mbm_draw.c: the MORE MODS tab's panel */
void mbm_panel_reset(void);
int mbm_panel_available(void);
void mbm_panel_frame(uintptr_t listing, float seconds);
void mbm_panel_hide(const char* reason);

#endif
