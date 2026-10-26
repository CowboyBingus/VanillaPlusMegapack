/* Mod Bindings Menu's extended bindings: bindings without a native action, given when the 36 are all held (the Lua's
 * src/extended.lua and src/extended_store.lua). They read the engine's input (mbm_engine.h) and support:
 *   - press: true on the frame its inputs become held, release: on the frame they stop being held, hold: while held;
 *   - alternatives: any one of a binding's alternatives satisfies it;
 *   - modifiers: an alternative's later inputs must be held with its first one;
 *   - controller buttons on any connected pad, checked each frame one is read (pads plugged in or out are followed).
 * A binding is evaluated when asked, at most once per frame, and each physical input is read at most once per frame.
 * After a change, or a key capture, the first evaluation only records what is held, so a held key fires no press.
 *
 * Saved keys, in the pack's settings file, [mod_bindings_menu.bindings] (the Lua's ModBindingsMenu.bindings):
 *   format = 1
 *   <binding id> = set <alternative>|<alternative>...  |  cleared  |  default
 * An alternative is <input>(+<input>)*@<trigger>, an input <device>:<index> (k keyboard, m mouse, p controller; the
 * engine's button index). Every extended binding has a line, so it stays extended in later sessions. A value this
 * version cannot read is left as it is and its binding stays inactive; a newer format leaves the section untouched and
 * every extended binding inactive. Without the engine's input (no backend yet) an extended binding answers -1: the
 * caller's fixed key. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mbm.h"

#define MBM_FORMAT 1
#define MBM_VALUE_LIMIT 255
#define MBM_SAMPLES 128

typedef struct MbmSample { uint32_t key; uint64_t frame; uint8_t down; } MbmSample;

static struct
{
    int loaded, newer, dirty;
    const MbmDevice* pads[4];      /* the connected ones this frame */
    int pad_count;
    uint64_t pads_frame;
    MbmSample samples[MBM_SAMPLES];
} s_ext;

/* The engine's input and Gui, set by a backend; not part of the component's per-session state. */
static const MbmEngineInput* g_mbmInput;
static const MbmGui* g_mbmGui;

void mbm_engine_set(const MbmEngineInput* input, const MbmGui* gui)
{
    g_mbmInput = input;
    g_mbmGui = gui;
    mbm_refresh_status();
}

void mbm_extended_reset(void)
{
    memset(&s_ext, 0, sizeof s_ext);
    s_ext.pads_frame = MBM_NO_FRAME;
}

static int MbmUsable(const MbmDevice* device) { return device != NULL && device->button != NULL && device->button_id != NULL; }

const MbmEngineInput* mbm_engine_input(void)
{
    return g_mbmInput != NULL && MbmUsable(g_mbmInput->keyboard) ? g_mbmInput : NULL;
}

const MbmGui* mbm_engine_gui(void) { return g_mbmGui; }

/* The device for names and ids: the keyboard, the mouse, or the first usable pad. */
const MbmDevice* mbm_device(int device)
{
    const MbmEngineInput* input = mbm_engine_input();
    if (input == NULL) return NULL;
    if (device == MBM_KEYBOARD) return input->keyboard;
    if (device == MBM_MOUSE) return MbmUsable(input->mouse) ? input->mouse : NULL;
    for (int i = 0; i < 4; i++)
        if (MbmUsable(input->pads[i])) return input->pads[i];
    return NULL;
}

/* The pads connected this frame (a pad without a connected function counts), checked at most once per frame. */
static int MbmConnectedPads(void)
{
    if (s_ext.pads_frame == mbm.frame) return s_ext.pad_count;
    const MbmEngineInput* input = mbm_engine_input();
    s_ext.pad_count = 0;
    for (int i = 0; input != NULL && i < 4; i++)
    {
        const MbmDevice* pad = input->pads[i];
        if (MbmUsable(pad) && (pad->connected == NULL || pad->connected())) s_ext.pads[s_ext.pad_count++] = pad;
    }
    s_ext.pads_frame = mbm.frame;
    return s_ext.pad_count;
}

/* Whether an input is held now: a controller button on any connected pad. */
int mbm_engine_down(int device, uint32_t index)
{
    if (device == MBM_PAD)
    {
        int count = MbmConnectedPads();
        for (int i = 0; i < count; i++)
            if (s_ext.pads[i]->button(index)) return 1;
        return 0;
    }
    const MbmDevice* d = mbm_device(device);
    return d != NULL && d->button(index);
}

/* The button first pressed this frame on a device (any connected pad for MBM_PAD). */
int mbm_engine_any_pressed(int device, uint32_t* index)
{
    if (device != MBM_PAD)
    {
        const MbmDevice* d = mbm_device(device);
        return d != NULL && d->any_pressed != NULL && d->any_pressed(index);
    }
    int count = MbmConnectedPads();
    for (int i = 0; i < count; i++)
        if (s_ext.pads[i]->any_pressed != NULL && s_ext.pads[i]->any_pressed(index)) return 1;
    return 0;
}

int mbm_window_focused(void)
{
    const MbmEngineInput* input = mbm_engine_input();
    return input != NULL && input->has_focus != NULL ? input->has_focus() : -1;
}

/* One physical input's state, read from the engine at most once per frame. */
static int MbmInputDown(const MbmInput* input)
{
    uint32_t key = (uint32_t)input->device * 65536u + input->index;
    MbmSample* sample = &s_ext.samples[(key * 2654435761u) % MBM_SAMPLES];
    if (sample->key == key && sample->frame == mbm.frame) return sample->down;
    int down = mbm_engine_down(input->device, input->index);
    *sample = (MbmSample){key, mbm.frame, (uint8_t)down};
    return down;
}

/* ---- the store ---------------------------------------------------------------------------------------------- */

static void MbmStoreLoad(void)
{
    if (s_ext.loaded) return;
    s_ext.loaded = 1;
    const char* format = vpm_setting(MBM_EXTENDED_SECTION, "format");
    if (format == NULL || strcmp(format, "1") == 0) return;
    s_ext.newer = 1;
    vpm_log(mbm.self, "The extended bindings file was written by a newer Mod Bindings Menu; it is left as it is, and "
        "extended bindings stay inactive.");
}

static int MbmDeviceCode(char c) { return c == 'k' ? MBM_KEYBOARD : c == 'm' ? MBM_MOUSE : c == 'p' ? MBM_PAD : 0; }
static char MbmDeviceChar(int device) { return device == MBM_KEYBOARD ? 'k' : device == MBM_MOUSE ? 'm' : 'p'; }
static const char* const kMbmTriggers[] = {"press", "release", "hold"};

static int MbmTrigger(const char* text, size_t length)
{
    for (int t = 0; t < 3; t++)
        if (length == strlen(kMbmTriggers[t]) && memcmp(text, kMbmTriggers[t], length) == 0) return t;
    return -1;
}

/* One input "<device>:<index>" at p, ending at '+' or at the '@' at end; the character after it, or NULL. */
static const char* MbmParseInput(const char* p, const char* end, MbmInput* out)
{
    int device = MbmDeviceCode(*p);
    if (device == 0 || p[1] != ':' || p[2] < '0' || p[2] > '9') return NULL;
    char* stop = NULL;
    unsigned long index = strtoul(p + 2, &stop, 10);
    if (stop > end || index > 65535 || (stop != end && *stop != '+')) return NULL;
    *out = (MbmInput){(uint8_t)device, (uint16_t)index};
    return stop;
}

/* "<input>(+<input>)*@<trigger>" from text to its end (not included); 1 parsed. */
static int MbmParseAlternative(const char* text, const char* end, MbmAlternative* out)
{
    const char* at = memchr(text, '@', (size_t)(end - text));
    int trigger = at != NULL ? MbmTrigger(at + 1, (size_t)(end - at - 1)) : -1;
    memset(out, 0, sizeof *out);
    for (const char* p = text; trigger >= 0; p++)
    {
        if (out->count >= MBM_MAX_INPUTS) return 0;
        p = MbmParseInput(p, at, &out->inputs[out->count++]);
        if (p == NULL) return 0;
        if (p == at) break;
    }
    out->trigger = (uint8_t)trigger;
    return trigger >= 0;
}

/* A saved value: its kind, and the alternatives of a "set" one. */
static int MbmParseValue(const char* value, MbmAlternative* list, int* count)
{
    *count = 0;
    if (strcmp(value, "default") == 0) return MBM_KIND_DEFAULT;
    if (strcmp(value, "cleared") == 0) return MBM_KIND_CLEARED;
    if (strncmp(value, "set ", 4) != 0) return MBM_KIND_UNKNOWN;
    for (const char* p = value + 4;;)
    {
        const char* end = strchr(p, '|');
        if (end == NULL) end = p + strlen(p);
        if (*count >= MBM_MAX_ALTERNATIVES || !MbmParseAlternative(p, end, &list[*count])) return MBM_KIND_UNKNOWN;
        (*count)++;
        if (*end == 0) return MBM_KIND_SET;
        p = end + 1;
    }
}

static size_t MbmAlternativeText(const MbmAlternative* alt, char* out, size_t size, int last)
{
    size_t at = 0;
    for (int i = 0; i < alt->count && at < size; i++)
        at += (size_t)snprintf(out + at, size - at, "%s%c:%u", i > 0 ? "+" : "", MbmDeviceChar(alt->inputs[i].device),
            alt->inputs[i].index);
    if (at < size) at += (size_t)snprintf(out + at, size - at, "@%s%s", kMbmTriggers[alt->trigger], last ? "" : "|");
    return at;
}

/* A record's value as saved; 0 when it does not fit a settings value. */
static int MbmValueText(const MbmRecord* r, char* out, size_t size)
{
    if (r->kind != MBM_KIND_SET) return snprintf(out, size, "%s", r->kind == MBM_KIND_CLEARED ? "cleared" : "default") > 0;
    size_t at = (size_t)snprintf(out, size, "set ");
    for (int a = 0; a < r->alternative_count && at < size; a++)
        at += MbmAlternativeText(&r->alternatives[a], out + at, size - at, a + 1 == r->alternative_count);
    return at < size && at <= MBM_VALUE_LIMIT;
}

int mbm_extended_dirty(void) { return s_ext.dirty; }

/* Writes the changed extended keys into the settings (from the frame, after the build check); the core saves. */
void mbm_extended_flush(void)
{
    s_ext.dirty = 0;
    if (s_ext.newer) return;
    char value[MBM_VALUE_LIMIT + 1];
    vpm_setting_put(MBM_EXTENDED_SECTION, "format", "1");
    for (int i = 0; i < mbm.extended_count; i++)
    {
        MbmRecord* r = mbm.extended_order[i];
        if (!r->dirty) continue;
        r->dirty = 0;
        if (r->kind != MBM_KIND_UNKNOWN && MbmValueText(r, value, sizeof value)) vpm_setting_put(MBM_EXTENDED_SECTION, r->id, value);
    }
    vpm_settings_save_soon();
}

int mbm_extended_known(const char* id)
{
    MbmStoreLoad();
    return vpm_setting(MBM_EXTENDED_SECTION, id) != NULL;
}

MbmRecord* mbm_record(const char* id)
{
    for (int i = 0; i < mbm.record_count; i++)
        if (strcmp(mbm.records[i].id, id) == 0) return &mbm.records[i];
    return NULL;
}

void mbm_register_extended(MbmRecord* r, const char* reason)
{
    MbmStoreLoad();
    const char* saved = vpm_setting(MBM_EXTENDED_SECTION, r->id);
    if (saved != NULL) r->kind = (uint8_t)MbmParseValue(saved, r->alternatives, &r->alternative_count);
    else if (!s_ext.newer)
    {
        r->kind = MBM_KIND_DEFAULT;
        r->dirty = 1;
        s_ext.dirty = 1;
    }
    r->extended = 1;
    r->position = ++mbm.extended_count;
    int at = mbm.extended_count - 1;
    while (at > 0 && strcmp(mbm.extended_order[at - 1]->category, r->category) > 0)
    {
        mbm.extended_order[at] = mbm.extended_order[at - 1];
        at--;
    }
    mbm.extended_order[at] = r;
    vpm_log(mbm.self, "Registered %s as an extended binding (%s) under %s.", r->id, reason, r->category);
}

/* Sets the record's alternatives from its saved keys (an inactive or cleared binding has none; the default is none,
 * since VpmBindingDef gives no default keys). 0 while the engine has no input. */
int mbm_current(MbmRecord* r)
{
    if (r->resolved) return 1;
    if (mbm_engine_input() == NULL) return 0;
    r->inactive = (uint8_t)mbm_extended_inactive(r);
    if (r->inactive || r->kind != MBM_KIND_SET) r->alternative_count = 0;
    for (int a = 0; a < r->alternative_count; a++) r->alternatives[a].was = 0;
    r->resolved = 1;
    return 1;
}

/* Stores keys chosen on the page: an empty list clears the binding (its default no longer applies). */
int mbm_store_alternatives(MbmRecord* r, const MbmAlternative* list, int count)
{
    MbmStoreLoad();
    if (!r->extended || s_ext.newer || count > MBM_MAX_ALTERNATIVES) return 0;
    MbmRecord candidate = *r;
    memcpy(candidate.alternatives, list, sizeof *list * (size_t)count);
    candidate.alternative_count = count;
    candidate.kind = count == 0 ? MBM_KIND_CLEARED : MBM_KIND_SET;
    char value[MBM_VALUE_LIMIT + 1];
    if (!MbmValueText(&candidate, value, sizeof value))
    {
        vpm_log(mbm.self, "The keys chosen for %s do not fit the settings file; the binding keeps its keys.", r->id);
        return 0;
    }
    *r = candidate;
    for (int a = 0; a < count; a++) r->alternatives[a].was = 0;
    r->dirty = 1;
    r->resolved = 1;
    r->inactive = 0;
    r->frame = MBM_NO_FRAME;
    r->epoch = -1;
    s_ext.dirty = 1;
    mbm.bindings_version++;
    return 1;
}

int mbm_extended_inactive(const MbmRecord* r) { return s_ext.newer || r->kind == MBM_KIND_UNKNOWN; }

/* Whether one alternative fires this frame, its held state recorded for the next; after a change press and release
 * only record it. lint: per-frame */
static int MbmFires(MbmAlternative* alt, int resync)
{
    int held = 1;
    for (int i = 0; i < alt->count && held; i++) held = MbmInputDown(&alt->inputs[i]);
    int was = alt->was;
    alt->was = (uint8_t)held;
    if (alt->trigger == MBM_HOLD) return held;
    if (resync) return 0;
    if (alt->trigger == MBM_PRESS) return held && !was;
    return was && !held;
}

/* An extended binding's answer: at most one evaluation per frame; false while a key capture suppresses mod bindings
 * (inputs still read). -1 while the engine has no input. lint: per-frame */
int mbm_extended_down(MbmRecord* r)
{
    if (mbm_engine_input() == NULL) return -1;
    if (r->frame == mbm.frame) return r->down;
    r->frame = mbm.frame;
    if (!mbm_current(r))
    {
        r->down = 0;
        return 0;
    }
    int resync = r->epoch != (int64_t)mbm.input_epoch;
    r->epoch = mbm.input_epoch;
    int down = 0;
    for (int a = 0; a < r->alternative_count; a++)
        if (MbmFires(&r->alternatives[a], resync)) down = 1;
    r->down = (uint8_t)(down && !mbm.suppressed);
    return r->down;
}

/* The name the player reads: the engine's localized name, else its name, else "<device> <index>". */
const char* mbm_input_label(const MbmInput* input, char* out, size_t size)
{
    const MbmDevice* d = mbm_device(input->device);
    const char* name = d != NULL && d->locale_name != NULL ? d->locale_name(input->index) : NULL;
    if ((name == NULL || name[0] == 0) && d != NULL && d->button_name != NULL) name = d->button_name(input->index);
    if (name != NULL && name[0] != 0) snprintf(out, size, "%s", name);
    else snprintf(out, size, "%s %u", input->device == MBM_KEYBOARD ? "keyboard" : input->device == MBM_MOUSE ? "mouse" : "controller",
        input->index);
    return out;
}
