/* Mod Bindings Menu's key capture for extended bindings on the MORE MODS tab (the Lua's src/capture.lua): choosing a
 * binding's key the way a native row's capture widget does.
 *
 * A capture belongs to a page: the keyboard page captures keyboard keys and mouse buttons, the controller page
 * controller buttons. It replaces the binding's alternatives of that page's devices and keeps the others.
 * Phases: idle -> arming -> capturing -> releasing -> idle.
 *   - arming: wait until the click, key or button that activated the row is released, so it is never captured.
 *   - capturing: the first newly pressed input decides: Back (Escape; B, from either page) cancels; Delete or Backspace
 *     (X on the controller page) clears the page's keys; a modifier (Ctrl, Shift, Alt; a shoulder button or trigger)
 *     waits: another input pressed while it is held makes a chord, releasing it alone binds it; anything else becomes
 *     the binding, with the modifiers held then. The keyboard's entries for mouse buttons (names ending in **) and
 *     mouse double clicks are ignored.
 *   - releasing: wait until every input of the capture is released, so the binding does not fire from that press.
 * From arming to the end every mod binding reads false and the page's Back guard is held, so Back cancels the capture
 * instead of closing the page. Focus loss (after the window was seen focused), a page change or 10 seconds without a
 * choice cancel. Every exit releases the guard and starts a new input epoch. */
#include <stdlib.h>
#include <string.h>
#include "mbm.h"

#define MBM_TIMEOUT 10.0f
#define MBM_SET_SIZE 8

typedef struct MbmSet { uint32_t index[MBM_SET_SIZE]; int count; } MbmSet; /* per device: MBM_KEYBOARD .. MBM_PAD */
typedef struct MbmNames { MbmSet activators[4], back[4], clear[4], modifiers[4]; } MbmNames;

static const char* const kMbmActivators[4][4] = {{0}, {"enter", "numpad enter", "space"}, {"left"}, {"a"}};
static const char* const kMbmBack[4][4] = {{0}, {"esc", "escape"}, {0}, {"b"}};
static const char* const kMbmClear[4][4] = {{0}, {"delete", "backspace"}, {0}, {"x"}};
static const char* const kMbmModifiers[4][8] = {{0},
    {"left ctrl", "right ctrl", "left shift", "right shift", "left alt", "right alt"}, {0},
    {"left_shoulder", "right_shoulder", "left_trigger", "right_trigger"}};

static struct
{
    int phase, controller, focused_seen, names_ready;
    MbmRecord* record;
    int (*hold_back)(void);
    void (*release_back)(void);
    float timer;
    uint8_t trigger;
    MbmInput held[MBM_MAX_INPUTS + 1];
    int held_count;
    MbmInput pending;
    int has_pending;
    MbmNames names;
} s_cap;

void mbm_capture_reset(void) { memset(&s_cap, 0, sizeof s_cap); }

int mbm_capture_phase(MbmRecord** record, int* controller)
{
    if (record != NULL) *record = s_cap.record;
    if (controller != NULL) *controller = s_cap.controller;
    return s_cap.phase;
}

static int MbmPageHas(int device) { return s_cap.controller ? device == MBM_PAD : device != MBM_PAD; }
static int MbmModifierDevice(int device) { return device == MBM_PAD ? MBM_PAD : MBM_KEYBOARD; }

static void MbmFill(MbmSet* sets, const char* const* names, int width)
{
    for (int device = MBM_KEYBOARD; device <= MBM_PAD; device++)
    {
        const MbmDevice* d = mbm_device(device);
        sets[device].count = 0;
        for (int i = 0; d != NULL && i < width && names[device * width + i] != NULL; i++)
        {
            uint32_t index;
            if (d->button_id(names[device * width + i], &index) && sets[device].count < MBM_SET_SIZE)
                sets[device].index[sets[device].count++] = index;
        }
    }
}

/* The engine's ids of the names above, once per session (a name the engine does not know is left out). */
static void MbmLookup(void)
{
    if (s_cap.names_ready) return;
    s_cap.names_ready = 1;
    MbmFill(s_cap.names.activators, &kMbmActivators[0][0], 4);
    MbmFill(s_cap.names.back, &kMbmBack[0][0], 4);
    MbmFill(s_cap.names.clear, &kMbmClear[0][0], 4);
    MbmFill(s_cap.names.modifiers, &kMbmModifiers[0][0], 8);
}

static int MbmMember(const MbmSet* sets, int device, uint32_t index)
{
    for (int i = 0; i < sets[device].count; i++)
        if (sets[device].index[i] == index) return 1;
    return 0;
}

static int MbmAnyDown(const MbmSet* sets)
{
    for (int device = MBM_KEYBOARD; device <= MBM_PAD; device++)
        for (int i = 0; i < sets[device].count; i++)
            if (mbm_engine_down(device, sets[device].index[i])) return 1;
    return 0;
}

/* Ends the capture whatever its phase: the guard goes back, mod bindings read again from a new input epoch. */
static void MbmFinish(const char* reason)
{
    void (*release)(void) = s_cap.release_back;
    s_cap.phase = MBM_IDLE;
    s_cap.record = NULL;
    s_cap.hold_back = NULL;
    s_cap.release_back = NULL;
    s_cap.has_pending = 0;
    s_cap.focused_seen = 0;
    s_cap.held_count = 0;
    mbm.suppressed = 0;
    mbm.input_epoch++;
    if (release != NULL) release();
    if (reason != NULL) vpm_log(mbm.self, "Key capture ended: %s.", reason);
}

/* The trigger a captured key keeps: the first of the page's alternatives', else the first alternative's, else press. */
static uint8_t MbmCurrentTrigger(const MbmRecord* r)
{
    for (int a = 0; a < r->alternative_count; a++)
        if (MbmPageHas(r->alternatives[a].inputs[0].device)) return r->alternatives[a].trigger;
    return r->alternative_count > 0 ? r->alternatives[0].trigger : MBM_PRESS;
}

int mbm_begin_capture(MbmRecord* r, int controller, int (*hold_back)(void), void (*release_back)(void), const char** why)
{
    if (s_cap.phase != MBM_IDLE) { *why = "a capture is running"; return 0; }
    if (r == NULL || !r->extended) { *why = "not an extended binding"; return 0; }
    if (mbm_extended_inactive(r)) { *why = "the binding was saved by a newer version"; return 0; }
    if (mbm_engine_input() == NULL || !mbm_current(r)) { *why = "input not ready"; return 0; }
    MbmLookup();
    s_cap.phase = MBM_ARMING;
    s_cap.record = r;
    s_cap.controller = controller;
    s_cap.hold_back = hold_back;
    s_cap.release_back = release_back;
    s_cap.timer = 0;
    s_cap.trigger = MbmCurrentTrigger(r);
    s_cap.focused_seen = 0;
    mbm.suppressed = 1;
    if (hold_back != NULL && !hold_back())
    {
        MbmFinish("the page's Back guard could not be held");
        *why = "back guard unavailable";
        return 0;
    }
    return 1;
}

static void MbmHold(const MbmInput* inputs, int count)
{
    for (int i = 0; i < count && s_cap.held_count < MBM_MAX_INPUTS + 1; i++) s_cap.held[s_cap.held_count++] = inputs[i];
}

/* Records the choice: inputs (main first) replace the page's alternatives, none removes them; the other page's stay.
 * Then waits for release. */
static void MbmChoose(const MbmInput* inputs, int count)
{
    MbmRecord* r = s_cap.record;
    MbmAlternative kept[MBM_MAX_ALTERNATIVES];
    int kept_count = 0, at = -1;
    for (int a = 0; a < r->alternative_count; a++)
    {
        if (MbmPageHas(r->alternatives[a].inputs[0].device)) { if (at < 0) at = kept_count; }
        else if (kept_count < MBM_MAX_ALTERNATIVES - 1) kept[kept_count++] = r->alternatives[a];
    }
    if (count > 0)
    {
        if (at < 0) at = kept_count;
        memmove(&kept[at + 1], &kept[at], sizeof kept[0] * (size_t)(kept_count - at));
        memset(&kept[at], 0, sizeof kept[at]);
        memcpy(kept[at].inputs, inputs, sizeof *inputs * (size_t)count);
        kept[at].count = (uint8_t)count;
        kept[at].trigger = s_cap.trigger;
        kept_count++;
    }
    (void)mbm_store_alternatives(r, kept, kept_count); /* refused (does not fit): the binding keeps its keys */
    MbmHold(inputs, count);
    s_cap.phase = MBM_RELEASING;
}

static int MbmByIndex(const void* a, const void* b)
{
    uint16_t x = ((const MbmInput*)a)->index, y = ((const MbmInput*)b)->index;
    return x < y ? -1 : x > y;
}

/* The main input, then the modifiers of its device held now (by index), at most MBM_MAX_INPUTS in all. */
static int MbmChord(int device, uint32_t index, MbmInput* inputs)
{
    int count = 0, modifiers = MbmModifierDevice(device);
    inputs[count++] = (MbmInput){(uint8_t)device, (uint16_t)index};
    MbmInput held[MBM_SET_SIZE];
    int held_count = 0;
    const MbmSet* set = &s_cap.names.modifiers[modifiers];
    for (int i = 0; i < set->count; i++)
        if (mbm_engine_down(modifiers, set->index[i])) held[held_count++] = (MbmInput){(uint8_t)modifiers, (uint16_t)set->index[i]};
    qsort(held, (size_t)held_count, sizeof held[0], MbmByIndex);
    for (int i = 0; i < held_count && count < MBM_MAX_INPUTS; i++) inputs[count++] = held[i];
    return count;
}

/* The keyboard's entries for mouse buttons (the mouse reports those) and mouse double clicks are not inputs. */
static int MbmIgnored(int device, uint32_t index)
{
    const MbmDevice* d = mbm_device(device);
    const char* name = device != MBM_PAD && d != NULL && d->button_name != NULL ? d->button_name(index) : NULL;
    if (name == NULL) return 0;
    size_t n = strlen(name);
    return (device == MBM_KEYBOARD && n >= 2 && strcmp(name + n - 2, "**") == 0) || (device == MBM_MOUSE && strstr(name, "double") != NULL);
}

/* One newly pressed input on a device of the capture's page. */
static void MbmDecide(int device, uint32_t index)
{
    if (MbmIgnored(device, index)) return;
    MbmInput input = {(uint8_t)device, (uint16_t)index};
    if (MbmMember(s_cap.names.clear, device, index))
    {
        MbmChoose(NULL, 0);
        MbmHold(&input, 1);
        return;
    }
    if (MbmMember(s_cap.names.modifiers, device, index))
    {
        if (!s_cap.has_pending) s_cap.pending = input;
        s_cap.has_pending = 1;
        return;
    }
    MbmInput chord[MBM_MAX_INPUTS];
    int count = MbmChord(device, index, chord);
    MbmChoose(chord, count);
}

/* The input first pressed this frame on device: Back cancels from either page; on the page's devices it is decided.
 * Returns whether the capture left the capturing phase. */
static int MbmPressedOn(int device)
{
    uint32_t index;
    if (!mbm_engine_any_pressed(device, &index)) return 0;
    if (MbmMember(s_cap.names.back, device, index))
    {
        MbmFinish("cancelled");
        return 1;
    }
    if (MbmPageHas(device)) MbmDecide(device, index);
    return s_cap.phase != MBM_CAPTURING;
}

static void MbmCapturing(void)
{
    for (int device = MBM_KEYBOARD; device <= MBM_PAD; device++)
        if (MbmPressedOn(device)) return;
    /* A modifier pressed alone and released alone becomes the binding. */
    if (s_cap.has_pending && !mbm_engine_down(s_cap.pending.device, s_cap.pending.index))
    {
        MbmInput pending = s_cap.pending;
        s_cap.has_pending = 0;
        MbmChoose(&pending, 1);
        s_cap.held_count = 0;
    }
}

/* Focus is lost only after the window was seen focused (an engine that never reports focus cannot cancel). */
static int MbmFocusKept(void)
{
    int focused = mbm_window_focused();
    if (focused == 1) s_cap.focused_seen = 1;
    return focused != 0 || !s_cap.focused_seen;
}

static void MbmReleasing(void)
{
    for (int i = 0; i < s_cap.held_count; i++)
        if (mbm_engine_down(s_cap.held[i].device, s_cap.held[i].index)) return;
    MbmFinish(NULL);
}

/* One frame of the capture, from the panel's frame. lint: per-frame */
void mbm_update_capture(float seconds)
{
    if (s_cap.phase == MBM_IDLE) return;
    if (mbm_engine_input() == NULL) { MbmFinish("input unavailable"); return; }
    if (!MbmFocusKept()) { MbmFinish("the game lost focus"); return; }
    s_cap.timer += seconds;
    if (s_cap.phase == MBM_ARMING)
    {
        if (!MbmAnyDown(s_cap.names.activators)) s_cap.phase = MBM_CAPTURING;
    }
    else if (s_cap.phase == MBM_CAPTURING)
    {
        if (s_cap.timer > MBM_TIMEOUT) { MbmFinish("no key chosen in 10 seconds"); return; }
        MbmCapturing();
    }
    if (s_cap.phase == MBM_RELEASING) MbmReleasing();
}

void mbm_cancel_capture(const char* reason)
{
    if (s_cap.phase != MBM_IDLE) MbmFinish(reason != NULL ? reason : "cancelled");
}
