/* Mod Options Menu: what the MODS tab lists (the Lua's options.lua presentation part, over the core's registry).
 *
 * Categories are the pack's components that registered options (vpm_option_owner), each listing its options in
 * registration order, plus one category of the pack itself, VANILLA PLUS MEGAPACK, with a switch per component
 * (vpm_component_switched_on / vpm_component_switch; a switch applies from the next session). Values are the core's:
 * the applied value is vpm_option_value, and the player's edits stay pending here until APPLY, which hands each to
 * vpm_option_apply (set, the owner's on_change) in registration order, switches after options, and the settings file
 * is written at once. A value set from code (vpm_option_set) replaces the player's pending edit of it, as the Lua's
 * set() did (mom_values_set).
 *
 * The core refuses at registration what the Lua's register_option refused (lengths in characters, 2 to 16 choices, a
 * slider range a float can hold, the kind, the default) and keeps a slider's value rounded to its shown decimals. Here
 * an option is left out only when the tab cannot show one of its texts (not valid UTF-8, a control character after
 * display_text, or blank), and the log says why once. The model is built when the MODS tab opens and again when the
 * registry has grown (its revision is the option count). */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mom.h"

#define LABEL_LIMIT 64 /* a component's name as a switch's label, as an option's label */
#define TITLE_LIMIT 40 /* a component's name as a category title, as the Lua's mod name */
#define MAX_CATEGORIES (MOM_MAX_SWITCHES + 1)
#define DESCRIPTOR_SIZE 216u
#define DESCRIPTOR_STRIDE 224u
#define OFF_TEXT 0xA090BE2Eu
#define ON_TEXT 0x13DC1DA2u
#define WIDGET_INT_SLIDER 0u
#define WIDGET_FLOAT_SLIDER 1u
#define WIDGET_SELECTOR 2u
#define INERT_CATEGORY 10u

/* Choice words the game already translates; other text is shown verbatim. */
typedef struct NativeWord { const char* word; uint32_t label; } NativeWord;
static const NativeWord kNativeWords[] = {
    {"OFF", 0xA090BE2Eu}, {"ON", 0x13DC1DA2u}, {"NO", 0xEF21C0C2u}, {"YES", 0x30DBDB29u},
    {"LOW", 0xE1F9AB36u}, {"MEDIUM", 0x3134D1FEu}, {"HIGH", 0x208F9597u}, {"ULTRA", 0x99FFB498u},
    {"DEFAULT", 0x38E6B4E4u}, {"CUSTOM", 0x2ACF00B1u}, {"NORMAL", 0xF3222616u}, {"INVERTED", 0x05478062u},
    {"WEAK", 0xE7B8332Eu}, {"STRONG", 0xD9709682u}, {"BASIC", 0xAAB9E5DAu}, {"ADVANCED", 0xE0B81607u},
    {"FULL", 0x3BA052B7u}, {"PERFORMANCE", 0x5097DF8Cu}, {"BALANCED", 0xE2135504u}, {"QUALITY", 0x61F69557u},
    {"GLOBAL", 0x1D256A7Bu}, {"ALWAYS", 0xECCB0C50u}, {"DISABLED", 0xE480CC2Bu}, {"HIDDEN", 0xAAE829EDu},
    {"VISIBLE", 0xBCAB6809u}, {"SMALL", 0x818D7022u}, {"LARGE", 0xF8C59D6Au}, {"SHORT", 0xB008F033u},
    {"DYNAMIC", 0xF54D4908u}, {"HOLD", 0x639EE7C1u}, {"PRESS", 0x91B91DD3u}, {"TAP", 0x26603652u},
};

static MomItem g_items[MOM_MAX_KEYS];
static MomCategory g_categories[MAX_CATEGORIES];
static int g_categoryCount;
static int g_revision;
static uint8_t g_logged[MOM_MAX_OPTIONS];       /* an option's refusal was logged */
static MomItem g_control;
static MomCategory g_controlCategory;
/* The options', then one for every switch, then the page control's. */
static _Alignas(16) uint8_t g_descriptors[MOM_MAX_OPTIONS + 2][DESCRIPTOR_STRIDE];

void mom_model_reset(void)
{
    memset(g_items, 0, sizeof g_items);
    memset(g_categories, 0, sizeof g_categories);
    memset(g_logged, 0, sizeof g_logged);
    memset(&g_control, 0, sizeof g_control);
    memset(&g_controlCategory, 0, sizeof g_controlCategory);
    g_categoryCount = 0;
    g_revision = -1;
}

int mom_model_revision(void) { return vpm_option_count(); }

/* ---- descriptors ------------------------------------------------------------------------------------------------- */

static void PutWord(uint8_t* blob, int index, uint32_t value) { memcpy(blob + index * 4, &value, 4); }
static void PutFloat(uint8_t* blob, int index, float value) { memcpy(blob + index * 4, &value, 4); }

/* The same layout as the game's descriptors (a float slider of 0.01 steps there uses +48 = 6, +52 = 1, format 0x6220),
 * 16-byte aligned like theirs. */
static const uint8_t* Descriptor(uint8_t* blob, const MomItem* item)
{
    memset(blob, 0, DESCRIPTOR_SIZE);
    PutWord(blob, 0, MOM_INERT_SETTING);
    PutWord(blob, 1, INERT_CATEGORY);
    PutWord(blob, 3, 0);
    PutWord(blob, 4, MOM_TEXT_TEMPLATE);
    if (item->kind == VPM_SLIDER)
    {
        PutWord(blob, 2, item->decimals == 0 ? WIDGET_INT_SLIDER : WIDGET_FLOAT_SLIDER);
        PutFloat(blob, 9, (float)item->min);
        PutFloat(blob, 10, (float)item->max);
        PutFloat(blob, 11, (float)item->step);
        PutFloat(blob, 12, item->decimals == 0 ? 20.0f : 6.0f);
        PutFloat(blob, 13, 1.0f);
        /* Float values: two integer digits and the option's decimal places. */
        PutWord(blob, 14, item->decimals == 0 ? 0u : 0x6200u + (uint32_t)item->decimals * 16u);
        return blob;
    }
    PutWord(blob, 2, WIDGET_SELECTOR);
    PutWord(blob, 16, (uint32_t)item->choiceCount);
    for (int i = 0; i < item->choiceCount; i++) PutWord(blob, 17 + i, item->labels[i]);
    return blob;
}

/* ---- items ------------------------------------------------------------------------------------------------------- */

static uint32_t NativeWordLabel(const char* text)
{
    for (size_t i = 0; i < sizeof kNativeWords / sizeof kNativeWords[0]; i++)
        if (strcmp(kNativeWords[i].word, text) == 0) return kNativeWords[i].label;
    return MOM_TEXT_TEMPLATE;
}

static void ToggleFields(MomItem* item)
{
    item->choiceCount = 2;
    item->labels[0] = OFF_TEXT;
    item->labels[1] = ON_TEXT;
}

/* The core registered 2 to 16 choices of at most 48 characters. */
static const char* ChoiceFields(MomItem* item, const VpmOptionDef* def)
{
    int count = 0;
    while (count < MOM_MAX_CHOICES && def->choices[count] != NULL) count++;
    for (int i = 0; i < count; i++)
    {
        const char* text = mom_text_resolve(def->choices[i]);
        if (text == NULL) return "invalid choice name";
        item->choices[i] = mom_text_upper(text);
        /* A word the game translates itself (ON, OFF, LOW...) shows the game's own label. */
        item->labels[i] = NativeWordLabel(item->choices[i]);
    }
    item->choiceCount = count;
    return NULL;
}

/* Decimal places a slider shows: as many as its step needs, at most 3, and at least 1 when min is not whole. */
static int SliderDecimals(double min, double step)
{
    int decimals = 0;
    while (decimals < 3 && fabs(step * pow(10, decimals) - floor(step * pow(10, decimals) + 0.5)) > 1e-6) decimals++;
    if (fmod(min, 1) != 0 && decimals < 1) decimals = 1;
    return decimals;
}

/* The core registered a range and step a float holds (min < max, 0 < step <= max - min); its step 0 is the Lua's
 * default step, 1. */
static void SliderFields(MomItem* item, const VpmOptionDef* def)
{
    item->min = def->min;
    item->max = def->max;
    item->step = def->step == 0 ? 1 : def->step;
    item->decimals = SliderDecimals(item->min, item->step);
}

/* The item for an option's definition (the core registered it: a toggle, a choice or a slider), or the reason the tab
 * cannot show it. */
static const char* OptionFields(MomItem* item, const VpmOptionDef* def)
{
    item->kind = def->kind;
    item->gap = def->gap != 0;
    item->label = mom_text_resolve(def->label);
    if (item->label == NULL) return "invalid option registration";
    if (def->description != NULL)
    {
        item->description = mom_text_resolve(def->description);
        if (item->description == NULL) return "invalid description";
    }
    if (def->kind == VPM_TOGGLE) { ToggleFields(item); return NULL; }
    if (def->kind == VPM_CHOICE) return ChoiceFields(item, def);
    SliderFields(item, def);
    return NULL;
}

/* ---- categories -------------------------------------------------------------------------------------------------- */

static MomCategory* NewCategory(const char* title, VpmComponent* owner)
{
    if (g_categoryCount >= MAX_CATEGORIES) return NULL;
    MomCategory* c = &g_categories[g_categoryCount];
    memset(c, 0, sizeof *c);
    c->title = title;
    c->owner = owner;
    c->sequence = ++g_categoryCount;
    return c;
}

/* The category named after an option's component (the Lua's mod name, upper case), new at its first option. */
static MomCategory* OwnerCategory(VpmComponent* owner)
{
    for (int i = 0; i < g_categoryCount; i++)
        if (g_categories[i].owner == owner) return &g_categories[i];
    const char* name = mom_text_named(vpm_def(owner)->name, TITLE_LIMIT);
    return NewCategory(mom_text_upper(name != NULL ? name : vpm_def(owner)->id), owner);
}

static void Refused(int index, const VpmOption* option, const char* reason)
{
    if (g_logged[index]) return;
    g_logged[index] = 1;
    vpm_log(mom.self, "Option %s.%s is not shown: %s.", vpm_def(vpm_option_owner(option))->id, vpm_option_def(option)->id,
        reason);
}

static void AddOption(int index)
{
    VpmOption* option = vpm_option_at(index);
    MomItem* item = &g_items[index];
    memset(item, 0, sizeof *item);
    item->option = option;
    item->key = index;
    const char* reason = OptionFields(item, vpm_option_def(option));
    if (reason != NULL) { Refused(index, option, reason); return; }
    MomCategory* category = OwnerCategory(vpm_option_owner(option));
    if (category == NULL) { Refused(index, option, "all mod categories are in use"); return; }
    if (category->count >= MOM_MAX_ROWS) { Refused(index, option, "its component already has 32 options"); return; }
    item->descriptor = Descriptor(g_descriptors[index], item);
    category->items[category->count++] = item;
}

/* The pack's own category: a switch per component, which applies from the next session. */
static void AddSwitches(void)
{
    MomCategory* category = NewCategory(mom_text_upper(VPM_PACK_NAME), NULL);
    const uint8_t* descriptor = NULL;
    for (int i = 0; category != NULL && i < vpm_component_count() && i < MOM_MAX_SWITCHES; i++)
    {
        VpmComponent* component = vpm_component_at(i);
        MomItem* item = &g_items[MOM_MAX_OPTIONS + i];
        char text[160];
        memset(item, 0, sizeof *item);
        item->component = component;
        item->key = MOM_MAX_OPTIONS + i;
        item->kind = VPM_TOGGLE;
        item->label = mom_text_named(vpm_def(component)->name, LABEL_LIMIT);
        if (item->label == NULL) item->label = mom_intern(vpm_def(component)->id);
        snprintf(text, sizeof text, "Switches %s on or off. Applies from the next session.", vpm_def(component)->name);
        item->description = mom_text_resolve(text);
        ToggleFields(item);
        if (descriptor == NULL) descriptor = Descriptor(g_descriptors[MOM_MAX_OPTIONS], item);
        item->descriptor = descriptor;
        category->items[category->count++] = item;
    }
}

void mom_model_update(void)
{
    int revision = mom_model_revision();
    if (revision == g_revision) return;
    g_revision = revision;
    g_categoryCount = 0;
    for (int i = 0; i < revision && i < MOM_MAX_OPTIONS; i++) AddOption(i);
    AddSwitches();
}

/* Button order: alphabetical, categories with the same title in the order they were registered. */
static int Before(const MomCategory* a, const MomCategory* b)
{
    int order = strcmp(a->title, b->title);
    return order != 0 ? order < 0 : a->sequence < b->sequence;
}

int mom_model_categories(const MomCategory** out, int capacity)
{
    int n = 0;
    for (int i = 0; i < g_categoryCount && n < capacity; i++)
    {
        if (g_categories[i].count == 0) continue;
        int at = n++;
        while (at > 0 && Before(&g_categories[i], out[at - 1])) { out[at] = out[at - 1]; at--; }
        out[at] = &g_categories[i];
    }
    return n;
}

/* ---- the page control -------------------------------------------------------------------------------------------- */

/* A category of one choice row naming the pages. The row is never an edit; turning it turns the pages (view.c). */
const MomCategory* mom_page_control(int count)
{
    int pages = (count + MOM_PAGE_MODS - 1) / MOM_PAGE_MODS;
    if (pages > MOM_MAX_CHOICES) pages = MOM_MAX_CHOICES;
    if (mom.modsPage > pages - 1) mom.modsPage = pages - 1;
    MomItem* item = &g_control;
    memset(item, 0, sizeof *item);
    item->key = MOM_NO_KEY;
    item->turn = 1;
    item->kind = VPM_CHOICE;
    item->label = mom_intern(vpm_text(mom.self, "page.label", "Mods Page"));
    item->description = mom_intern(vpm_text(mom.self, "page.description",
        "The category buttons show 7 mods at a time. Change the page to see the others."));
    item->value = mom.modsPage + 1;
    item->choiceCount = pages;
    for (int i = 0; i < pages; i++)
    {
        item->choices[i] = mom_text_page(vpm_text(mom.self, "page.value", "{page} / {pages}"), i + 1, pages);
        item->labels[i] = MOM_TEXT_TEMPLATE;
    }
    item->descriptor = Descriptor(g_descriptors[MOM_MAX_OPTIONS + 1], item);
    MomCategory* c = &g_controlCategory;
    memset(c, 0, sizeof *c);
    c->title = mom_text_page(vpm_text(mom.self, "category.page", "PAGE {page} OF {pages}"), mom.modsPage + 1, pages);
    c->pages = pages;
    c->count = 1;
    c->items[0] = item;
    return c;
}

void mom_page_turned(int page)
{
    mom.modsPage = page - 1;
    g_control.value = page;
    g_controlCategory.title = mom_text_page(vpm_text(mom.self, "category.page", "PAGE {page} OF {pages}"), page,
        g_controlCategory.pages);
}

/* ---- values ------------------------------------------------------------------------------------------------------ */

double mom_applied(const MomItem* item)
{
    if (item->option != NULL) return vpm_option_value(item->option);
    if (item->component != NULL) return vpm_component_switched_on(item->component) ? 1 : 0;
    return item->value;
}

double mom_shown(const MomItem* item)
{
    if (item->key == MOM_NO_KEY) return item->value;
    return mom.pendingSet[item->key] ? mom.pending[item->key] : mom_applied(item);
}

int mom_snap(const MomItem* item, double value, double* out)
{
    if (!(value > -HUGE_VAL && value < HUGE_VAL)) return 0;
    double steps = floor((value - item->min) / item->step + 0.5);
    double snapped = fmin(item->max, fmax(item->min, item->min + steps * item->step));
    char text[64]; /* decimals avoid float noise, as the Lua's string.format('%.<n>f') */
    snprintf(text, sizeof text, "%.*f", item->decimals, snapped);
    *out = strtod(text, NULL);
    return 1;
}

/* Player edits wait for the apply action; editing back to the applied value withdraws the edit (the core keeps a
 * slider's value rounded to its shown decimals, as a row's value is). */
void mom_set_pending(const MomItem* item, double value)
{
    if (item->key == MOM_NO_KEY) return;
    int had = mom.pendingSet[item->key], has = value != mom_applied(item);
    mom.pendingSet[item->key] = (uint8_t)has;
    mom.pending[item->key] = has ? value : 0;
    if (had != has) mom.pendingCount += has ? 1 : -1;
}

void mom_drop_pending(void)
{
    if (mom.pendingCount == 0) return;
    memset(mom.pendingSet, 0, sizeof mom.pendingSet);
    mom.pendingCount = 0;
}

/* ---- values set from code ------------------------------------------------------------------------------------------
 * The Lua's set() replaced the player's pending edit of the option and queued its row for the next step. The core's
 * vpm_option_set only moves its revision, so an open view compares each option's applied value with the one it last
 * showed, on the frames the revision moved (view.c). */

static double g_seen[MOM_MAX_OPTIONS]; /* each option's applied value as the open view shows it */
static int g_seenCount;

static int Options(void)
{
    int count = vpm_option_count();
    return count < MOM_MAX_OPTIONS ? count : MOM_MAX_OPTIONS;
}

void mom_values_seen(void)
{
    g_seenCount = Options();
    for (int i = 0; i < g_seenCount; i++) g_seen[i] = vpm_option_value(vpm_option_at(i));
}

static void DropPending(int key)
{
    if (!mom.pendingSet[key]) return;
    mom.pendingSet[key] = 0;
    mom.pendingCount--;
}

/* Options registered since the view last looked are taken as seen: the view's next build shows them. */
int mom_values_set(uint8_t* changed)
{
    int count = Options(), n = 0;
    for (int i = 0; i < count; i++)
    {
        double value = vpm_option_value(vpm_option_at(i));
        changed[i] = (uint8_t)(i < g_seenCount && value != g_seen[i]);
        g_seen[i] = value;
        if (!changed[i]) continue;
        DropPending(i);
        n++;
    }
    g_seenCount = count;
    return n;
}

/* ---- apply ------------------------------------------------------------------------------------------------------- */

/* An option's applied value is the one its row shows; a value its on_change sets from code is not, so the view shows
 * that one from its next step. */
static void ApplyOne(int key, double value)
{
    if (key >= MOM_MAX_OPTIONS)
    {
        VpmComponent* component = vpm_component_at(key - MOM_MAX_OPTIONS);
        if (component != NULL) vpm_component_switch(component, value != 0);
        return;
    }
    VpmOption* option = vpm_option_at(key);
    if (option != NULL && vpm_option_apply(option, value)) g_seen[key] = value;
    else vpm_log(mom.self, "An option change was refused: %g.", value);
}

/* Every pending edit applied in registration order (options, then switches), then saved at once, as the Lua saved its
 * values file on apply (and the game its settings). */
int mom_apply_pending(void)
{
    int applied = 0;
    for (int key = 0; key < MOM_MAX_KEYS && mom.pendingCount > 0; key++)
    {
        if (!mom.pendingSet[key]) continue;
        mom.pendingSet[key] = 0;
        mom.pendingCount--;
        applied++;
        ApplyOne(key, mom.pending[key]);
    }
    vpm_settings_save_now();
    return applied;
}
