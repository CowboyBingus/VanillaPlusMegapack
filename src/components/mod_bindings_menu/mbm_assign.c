/* Mod Bindings Menu: registration (the bindings backend's attach; the Lua's register_binding) and the reservations of
 * automatic actions (the Lua's src/assignments.lua).
 *
 * Automatic bindings keep their native action across sessions, because the game saves each action's keys under the
 * action's name. A new id takes a free automatic action, else the action of the binding absent longest once its
 * reservation ended (it missed 30 sessions that count; its keys are then cleared), else it becomes an extended binding.
 * Slot 2, the v1 third-party slot, belongs to one id across sessions (its owner). A session counts from the first time
 * a binding asks for an automatic action or slot 2 in it. Saved in the pack's settings file, [mod_bindings_menu]:
 *   session = <n>                                   the last session that counted
 *   auto.<group>:<action> = <seen> <id>             an automatic action's holder and the last session it registered
 *   action.<group>:<action> = cleared <s> found <h> left <h> | clear    the sweep's mark (mbm_sweep.c)
 *   slot.2 = <seen> <id>                            the shared slot's owner
 * (The Lua's ModBindingsMenu.assignments held the same records as lines; the core reads settings by key, hence one key
 * per action.) Changes are written from the frame after the build check, as the Lua's flush; the core saves the file. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mbm.h"

#define MBM_EXPIRY_SESSIONS 30
#define MBM_SHARED_SLOT 2u
#define MBM_REASON_RESERVED "no free binding action; the others are reserved by mods not loaded this session"
#define MBM_REASON_FULL "all 29 automatic binding actions in use"
#define MBM_EXTENDED_CODE 0u
#define MBM_REFUSED_CODE UINT32_MAX

typedef struct MbmHolder { int present; uint32_t seen; char id[MBM_ID_SIZE]; } MbmHolder;
typedef struct MbmMark { int kind; uint32_t cleared, found, left; } MbmMark; /* kind: 0 none, 1 cleared, 2 clear */

static struct
{
    int loaded, counted, dirty;
    uint32_t saved, session;
    MbmHolder holders[MBM_ACTIONS]; /* automatic actions only (index 7 ..) */
    MbmMark marks[MBM_ACTIONS];
    MbmHolder owner;                /* slot 2 */
} s_book;

void mbm_assign_reset(void) { memset(&s_book, 0, sizeof s_book); }
int mbm_assign_dirty(void) { return s_book.dirty; }

static void MbmActionKey(char* key, size_t size, const char* prefix, int index)
{
    snprintf(key, size, "%s.%u:%u", prefix, mbm_dormant[index].group, mbm_dormant[index].action);
}

/* "<seen> <id>" */
static int MbmParseHolder(const char* text, MbmHolder* out)
{
    char* end = NULL;
    unsigned long seen = text != NULL ? strtoul(text, &end, 10) : 0;
    if (text == NULL || end == text || *end != ' ' || end[1] == 0 || strlen(end + 1) >= MBM_ID_SIZE) return 0;
    out->present = 1;
    out->seen = (uint32_t)seen;
    snprintf(out->id, sizeof out->id, "%s", end + 1);
    return 1;
}

static void MbmParseMark(const char* text, MbmMark* out)
{
    unsigned cleared, found, left;
    char tail;
    if (text == NULL) return;
    if (strcmp(text, "clear") == 0) out->kind = 2;
    else if (sscanf(text, "cleared %u found %x left %x%c", &cleared, &found, &left, &tail) == 3)
        *out = (MbmMark){1, cleared, found, left};
}

/* An id holding two automatic actions (an edited file) keeps the one it registered on last. */
static void MbmDropDuplicates(void)
{
    for (int i = MBM_SLOTS; i < MBM_ACTIONS; i++)
        for (int j = MBM_SLOTS; j < i; j++)
        {
            MbmHolder* a = &s_book.holders[i];
            MbmHolder* b = &s_book.holders[j];
            if (!a->present || !b->present || strcmp(a->id, b->id) != 0) continue;
            if (a->seen >= b->seen) b->present = 0;
            else a->present = 0;
        }
}

/* Loads the reservations once per session, which gives the session its number. */
static void MbmLoad(void)
{
    if (s_book.loaded) return;
    s_book.loaded = 1;
    char key[32];
    const char* session = vpm_setting(MBM_SECTION, "session");
    s_book.saved = session != NULL ? (uint32_t)strtoul(session, NULL, 10) : 0;
    for (int i = 0; i < MBM_ACTIONS; i++)
    {
        MbmActionKey(key, sizeof key, "auto", i);
        if (i >= MBM_SLOTS) (void)MbmParseHolder(vpm_setting(MBM_SECTION, key), &s_book.holders[i]);
        MbmActionKey(key, sizeof key, "action", i);
        MbmParseMark(vpm_setting(MBM_SECTION, key), &s_book.marks[i]);
    }
    (void)MbmParseHolder(vpm_setting(MBM_SECTION, "slot.2"), &s_book.owner);
    MbmDropDuplicates();
    s_book.session = s_book.saved + 1;
}

uint32_t mbm_session(void)
{
    MbmLoad();
    return s_book.session;
}

static void MbmPutHolder(const char* key, const MbmHolder* holder)
{
    char value[MBM_ID_SIZE + 16];
    snprintf(value, sizeof value, "%u %s", holder->seen, holder->id);
    vpm_setting_put(MBM_SECTION, key, holder->present ? value : NULL);
}

static void MbmPutMark(const char* key, const MbmMark* mark)
{
    char value[80];
    if (mark->kind == 1) snprintf(value, sizeof value, "cleared %u found %08x left %08x", mark->cleared, mark->found, mark->left);
    else snprintf(value, sizeof value, "clear");
    vpm_setting_put(MBM_SECTION, key, mark->kind != 0 ? value : NULL);
}

/* Writes the changed reservations into the settings (an unchanged value is no change there); the core saves. */
void mbm_assign_flush(void)
{
    char key[32], session[16];
    s_book.dirty = 0;
    snprintf(session, sizeof session, "%u", s_book.counted ? s_book.session : s_book.saved);
    vpm_setting_put(MBM_SECTION, "session", session);
    for (int i = 0; i < MBM_ACTIONS; i++)
    {
        MbmActionKey(key, sizeof key, "auto", i);
        if (i >= MBM_SLOTS) MbmPutHolder(key, &s_book.holders[i]);
        MbmActionKey(key, sizeof key, "action", i);
        MbmPutMark(key, &s_book.marks[i]);
    }
    MbmPutHolder("slot.2", &s_book.owner);
    vpm_settings_save_soon();
}

int mbm_mark(uint32_t code, uint32_t* found, uint32_t* left)
{
    int index = mbm_code_index(code);
    MbmLoad();
    if (index < 0) return 0;
    *found = s_book.marks[index].found;
    *left = s_book.marks[index].left;
    return s_book.marks[index].kind;
}

/* kind 1: cleared in this session (found and left); 3: the list the sweep left changed. */
void mbm_mark_set(uint32_t code, int kind, uint32_t found, uint32_t left)
{
    int index = mbm_code_index(code);
    if (index < 0) return;
    MbmLoad();
    MbmMark* mark = &s_book.marks[index];
    if (kind == 1) *mark = (MbmMark){1, s_book.session, found, left};
    else if (mark->left == left) return;
    else mark->left = left;
    s_book.dirty = 1;
}

static void MbmCountSession(void)
{
    if (s_book.counted) return;
    s_book.counted = 1;
    s_book.dirty = 1;
}

static int MbmExpired(uint32_t seen) { return (int64_t)s_book.session - (int64_t)seen - 1 >= MBM_EXPIRY_SESSIONS; }

static int MbmHolderOf(const char* id)
{
    for (int i = MBM_SLOTS; i < MBM_ACTIONS; i++)
        if (s_book.holders[i].present && strcmp(s_book.holders[i].id, id) == 0) return i;
    return -1;
}

/* Whether id holds an automatic reservation (kept native, never extended). */
static int MbmReserved(const char* id)
{
    MbmLoad();
    return MbmHolderOf(id) >= 0;
}

static int MbmFreeAction(void)
{
    for (int i = MBM_SLOTS; i < MBM_ACTIONS; i++)
        if (mbm.used[i] == NULL && !s_book.holders[i].present) return i;
    return -1;
}

/* The action of the binding absent longest, once its reservation has ended. */
static int MbmExpiredAction(void)
{
    int oldest = -1;
    for (int i = MBM_SLOTS; i < MBM_ACTIONS; i++)
    {
        const MbmHolder* h = &s_book.holders[i];
        if (!h->present || mbm.used[i] != NULL || !MbmExpired(h->seen)) continue;
        if (oldest < 0 || h->seen < s_book.holders[oldest].seen) oldest = i;
    }
    return oldest;
}

/* Gives action index to id; an expired binding that held it loses it, and its keys are cleared. */
static uint32_t MbmHandOver(const char* id, int index)
{
    MbmHolder* previous = &s_book.holders[index];
    if (previous->present)
    {
        vpm_log(mbm.self, "Native action %u:%u goes to %s: %s has not registered for %d sessions; its keys are cleared.",
            mbm_dormant[index].group, mbm_dormant[index].action, id, previous->id,
            (int)((int64_t)s_book.session - previous->seen - 1));
        s_book.marks[index] = (MbmMark){2, 0, 0, 0};
    }
    int own = MbmHolderOf(id);
    if (own >= 0) s_book.holders[own].present = 0;
    previous->present = 1;
    previous->seen = s_book.session;
    snprintf(previous->id, sizeof previous->id, "%s", id);
    s_book.dirty = 1;
    return mbm_code_at(index);
}

/* The automatic action for id, or 0 with *reason: reservations of mods not loaded, or every action in use. */
static uint32_t MbmAssignAction(const char* id, const char** reason)
{
    MbmLoad();
    MbmCountSession();
    int own = MbmHolderOf(id);
    if (own >= 0 && mbm.used[own] == NULL)
    {
        if (s_book.holders[own].seen != s_book.session)
        {
            s_book.holders[own].seen = s_book.session;
            s_book.dirty = 1;
        }
        return mbm_code_at(own);
    }
    int index = MbmFreeAction();
    if (index < 0) index = MbmExpiredAction();
    if (index >= 0) return MbmHandOver(id, index);
    *reason = MBM_REASON_FULL;
    for (int i = MBM_SLOTS; i < MBM_ACTIONS; i++)
        if (mbm.used[i] == NULL && s_book.holders[i].present) *reason = MBM_REASON_RESERVED;
    return 0;
}

/* Slot 2: its owner gets the slot's action; an id with an automatic reservation keeps it; any other id, while the
 * owner's reservation lasts, gets an automatic action; with no owner, or an expired one, the caller becomes the owner
 * (the expired owner's keys cleared). */
static uint32_t MbmAssignShared(const char* id, const char** reason)
{
    MbmLoad();
    MbmCountSession();
    MbmHolder* owner = &s_book.owner;
    int mine = owner->present && strcmp(owner->id, id) == 0;
    if (mine && mbm.used[1] == NULL)
    {
        if (owner->seen != s_book.session)
        {
            owner->seen = s_book.session;
            s_book.dirty = 1;
        }
        return mbm_code_at(1);
    }
    if (MbmHolderOf(id) >= 0 || mbm.used[1] != NULL || (owner->present && !mine && !MbmExpired(owner->seen)))
        return MbmAssignAction(id, reason);
    if (owner->present && !mine)
    {
        vpm_log(mbm.self, "Slot %u goes to %s: %s has not registered for %d sessions; its keys are cleared.",
            MBM_SHARED_SLOT, id, owner->id, (int)((int64_t)s_book.session - owner->seen - 1));
        s_book.marks[1] = (MbmMark){2, 0, 0, 0};
    }
    owner->present = 1;
    owner->seen = s_book.session;
    snprintf(owner->id, sizeof owner->id, "%s", id);
    s_book.dirty = 1;
    return mbm_code_at(1);
}

/* The native action for a registration, MBM_EXTENDED_CODE to make it extended, or MBM_REFUSED_CODE with *reason. A
 * binding never changes backend: an id the extended store knows stays extended, one with a reservation stays native.
 * Every registration may fall back to an extended binding (VpmBindingDef asks for no backend). */
static uint32_t MbmChooseAction(const char* id, uint32_t slot, const char** reason)
{
    uint32_t code;
    if (slot == MBM_SHARED_SLOT) code = MbmAssignShared(id, reason);
    else if (slot != 0)
    {
        if (mbm.used[slot - 1] != NULL) { *reason = "slot already in use"; return MBM_REFUSED_CODE; }
        return mbm_code_at((int)slot - 1);
    }
    else if (mbm_extended_known(id) && !MbmReserved(id)) return MBM_EXTENDED_CODE;
    else code = MbmAssignAction(id, reason);
    return code != 0 ? code : MBM_EXTENDED_CODE;
}

static int MbmValidId(const char* id)
{
    return id[0] != 0 && strpbrk(id, "\t\r\n=") == NULL && id[0] != ' ' && id[strlen(id) - 1] != ' ';
}

/* The record's id, texts and slot from the definition; 0 with *reason when not usable. */
static int MbmDescribe(MbmRecord* r, VpmBinding* binding, const char** reason)
{
    const VpmBindingDef* def = vpm_binding_def(binding);
    VpmComponent* owner = vpm_binding_owner(binding);
    *reason = "invalid binding registration";
    if (snprintf(r->id, sizeof r->id, "%s.%s", vpm_def(owner)->id, def->id) >= (int)sizeof r->id || !MbmValidId(r->id)) return 0;
    if (def->slot > MBM_SLOTS || !mbm_display_text(def->label, 127, r->text, sizeof r->text)) return 0;
    *reason = "invalid binding category";
    if (def->category != NULL) return mbm_display_text(def->category, 64, r->category, sizeof r->category);
    if (!mbm_display_text(vpm_def(owner)->name, 64, r->category, sizeof r->category))
        snprintf(r->category, sizeof r->category, "%s", mbm.unnamed_text);
    return 1;
}

static void MbmAddNative(MbmRecord* r, uint32_t code)
{
    int index = mbm_code_index(code);
    r->slot = index < MBM_SLOTS ? r->requested : 0;
    r->code = code;
    r->group = (uint8_t)(code >> 16);
    r->action = (uint8_t)(code & 0xFFFFu);
    mbm.used[index] = r;
    int at = mbm.order_count++;
    while (at > 0 && mbm_code_index(mbm.order[at - 1]->code) > index)
    {
        mbm.order[at] = mbm.order[at - 1];
        at--;
    }
    mbm.order[at] = r;
    mbm.defaults_pending = 1;
    char slot[24] = "";
    if (r->slot != 0) snprintf(slot, sizeof slot, " (slot %u)", r->slot);
    vpm_log(mbm.self, "Registered %s on native action %u:%u%s under %s.", r->id, r->group, r->action, slot, r->category);
}

/* The bindings backend's attach: the binding's record (its data for down), or NULL when refused (it then answers -1:
 * the caller's fixed key). */
void* mbm_attach(VpmBinding* binding)
{
    if (mbm.record_count >= MBM_MAX_RECORDS)
    {
        vpm_log(mbm.self, "Cannot register %s: the menu holds %d bindings.", vpm_binding_def(binding)->id, MBM_MAX_RECORDS);
        return NULL;
    }
    MbmRecord* r = &mbm.records[mbm.record_count];
    memset(r, 0, sizeof *r);
    const char* reason = NULL;
    r->requested = vpm_binding_def(binding)->slot;
    uint32_t code = MbmDescribe(r, binding, &reason) ? MbmChooseAction(r->id, r->requested, &reason) : MBM_REFUSED_CODE;
    if (code == MBM_REFUSED_CODE)
    {
        vpm_log(mbm.self, "Cannot register %s: %s.", r->id[0] != 0 ? r->id : vpm_binding_def(binding)->id, reason);
        return NULL;
    }
    mbm.record_count++;
    r->binding = binding;
    r->swept_count = UINT32_MAX;
    r->epoch = -1;
    r->frame = MBM_NO_FRAME;
    if (code == MBM_EXTENDED_CODE) mbm_register_extended(r, "every native action is held");
    else MbmAddNative(r, code);
    mbm.revision++;
    return r;
}
