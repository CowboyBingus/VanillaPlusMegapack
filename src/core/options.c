/* The settings file, the components' switches and options (Mod Options Menu's model), and the bindings registry
 * (Mod Bindings Menu's model).
 *
 * The file is %LOCALAPPDATA%\CowboyBingus\VanillaPlusMegapack\settings.ini as the game sees it: HellForge points the
 * game's LOCALAPPDATA at the installation's own user data (and copies a sandboxed session's back afterwards), so it
 * persists between sessions and never changes the mod's folder. Sections [components], [options], [bindings] and any
 * a component adds, "key = value" lines. Entries the pack does not know (a component switched off, an older version's)
 * are kept as they are. It is read once at start-up and written about a second after a change (on the game thread, at
 * the pack tick), and at a mission's end if a change waits; never on a frame without a change. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "vpm_core.h"

#define MAX_SETTINGS 512
#define SECTION_SIZE 32
#define KEY_SIZE 128
#define VALUE_SIZE 256
#define FILE_LIMIT (256 * 1024)
#define SAVE_DELAY 1.0f

typedef struct Setting { char section[SECTION_SIZE], key[KEY_SIZE], value[VALUE_SIZE]; } Setting;
static Setting g_settings[MAX_SETTINGS];
static int g_settingCount;
static float g_saveIn;          /* seconds until the file is written; 0: nothing waits */
static int g_dirty;
static wchar_t g_path[MAX_PATH];
static const wchar_t* g_pathOverride;

void vpm_settings_path_override(const wchar_t* path) { g_pathOverride = path; }

static int SettingsPath(int create)
{
    if (g_pathOverride != NULL)
    {
        wcsncpy(g_path, g_pathOverride, MAX_PATH - 1);
        g_path[MAX_PATH - 1] = 0;
        return 1;
    }
    wchar_t base[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH);
    if (n == 0 || n >= MAX_PATH - 64) return 0;
    _snwprintf(g_path, MAX_PATH, L"%ls\\CowboyBingus", base);
    if (create && !CreateDirectoryW(g_path, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) return 0;
    _snwprintf(g_path, MAX_PATH, L"%ls\\CowboyBingus\\VanillaPlusMegapack", base);
    if (create && !CreateDirectoryW(g_path, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) return 0;
    _snwprintf(g_path, MAX_PATH, L"%ls\\CowboyBingus\\VanillaPlusMegapack\\settings.ini", base);
    return 1;
}

static Setting* Find(const char* section, const char* key)
{
    for (int i = 0; i < g_settingCount; i++)
        if (strcmp(g_settings[i].section, section) == 0 && strcmp(g_settings[i].key, key) == 0) return &g_settings[i];
    return NULL;
}

const char* vpm_setting(const char* section, const char* key)
{
    const Setting* s = Find(section, key);
    return s != NULL ? s->value : NULL;
}

void vpm_setting_put(const char* section, const char* key, const char* value)
{
    Setting* s = Find(section, key);
    if (value == NULL)
    {
        if (s == NULL) return;
        *s = g_settings[--g_settingCount];
        g_dirty = 1;
        return;
    }
    if (s == NULL)
    {
        if (g_settingCount >= MAX_SETTINGS || strlen(section) >= SECTION_SIZE || strlen(key) >= KEY_SIZE) return;
        s = &g_settings[g_settingCount++];
        snprintf(s->section, SECTION_SIZE, "%s", section);
        snprintf(s->key, KEY_SIZE, "%s", key);
        s->value[0] = 0;
    }
    if (strcmp(s->value, value) == 0) return;
    snprintf(s->value, VALUE_SIZE, "%s", value);
    g_dirty = 1;
}

static void Trim(char* text)
{
    size_t n = strlen(text);
    while (n > 0 && (text[n - 1] == ' ' || text[n - 1] == '\t' || text[n - 1] == '\r')) text[--n] = 0;
    size_t start = 0;
    while (text[start] == ' ' || text[start] == '\t') start++;
    if (start > 0) memmove(text, text + start, n - start + 1);
}

static void ParseLine(char* line, char* section)
{
    Trim(line);
    if (line[0] == 0 || line[0] == ';' || line[0] == '#') return;
    size_t n = strlen(line);
    if (line[0] == '[' && line[n - 1] == ']')
    {
        line[n - 1] = 0;
        snprintf(section, SECTION_SIZE, "%s", line + 1);
        Trim(section);
        return;
    }
    char* equals = strchr(line, '=');
    if (equals == NULL || section[0] == 0) return;
    *equals = 0;
    char* value = equals + 1;
    Trim(line);
    Trim(value);
    if (line[0] != 0) vpm_setting_put(section, line, value);
}

void vpm_settings_load(void)
{
    g_settingCount = 0;
    g_dirty = 0;
    g_saveIn = 0;
    if (!SettingsPath(0)) return;
    HANDLE file = CreateFileW(g_path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return;
    static char text[FILE_LIMIT + 1];
    DWORD got = 0;
    BOOL ok = ReadFile(file, text, FILE_LIMIT, &got, NULL);
    CloseHandle(file);
    if (!ok) return;
    text[got] = 0;
    char section[SECTION_SIZE] = "";
    char* line = text;
    while (line != NULL && *line != 0)
    {
        char* next = strchr(line, '\n');
        if (next != NULL) *next++ = 0;
        ParseLine(line, section);
        line = next;
    }
    g_dirty = 0;
}

static size_t AppendSection(char* out, size_t at, size_t size, const char* section)
{
    int any = 0;
    for (int i = 0; i < g_settingCount && at < size; i++)
    {
        if (strcmp(g_settings[i].section, section) != 0) continue;
        if (!any) at += (size_t)snprintf(out + at, size - at, "\n[%s]\n", section);
        any = 1;
        if (at < size) at += (size_t)snprintf(out + at, size - at, "%s = %s\n", g_settings[i].key, g_settings[i].value);
    }
    return at;
}

static int Write(void)
{
    static char text[FILE_LIMIT];
    size_t at = (size_t)snprintf(text, sizeof text,
        "; Vanilla Plus Megapack settings. The pack writes this file when you change a setting in game;\n"
        "; edit it only while the game is closed. Components: on or off, from the next session.\n");
    static const char* const known[] = {"components", "options", "bindings"};
    for (int k = 0; k < 3; k++) at = AppendSection(text, at, sizeof text, known[k]);
    for (int i = 0; i < g_settingCount && at < sizeof text; i++)
    {
        int seen = 0;
        for (int k = 0; k < 3; k++) seen |= strcmp(g_settings[i].section, known[k]) == 0;
        for (int j = 0; j < i; j++) seen |= strcmp(g_settings[j].section, g_settings[i].section) == 0;
        if (!seen) at = AppendSection(text, at, sizeof text, g_settings[i].section);
    }
    if (at >= sizeof text || !SettingsPath(1)) return 0;
    wchar_t temporary[MAX_PATH + 8];
    _snwprintf(temporary, MAX_PATH + 8, L"%ls.new", g_path);
    HANDLE file = CreateFileW(temporary, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return 0;
    DWORD wrote = 0;
    BOOL ok = WriteFile(file, text, (DWORD)at, &wrote, NULL) && wrote == at;
    ok = CloseHandle(file) && ok;
    if (ok) ok = MoveFileExW(temporary, g_path, MOVEFILE_REPLACE_EXISTING);
    if (!ok) DeleteFileW(temporary);
    return ok;
}

void vpm_settings_save_soon(void)
{
    if (g_dirty) g_saveIn = SAVE_DELAY;
}

void vpm_settings_flush(void)
{
    if (!g_dirty) return;
    g_saveIn = 0;
    if (Write()) g_dirty = 0;
    else vpm_core_hf()->log(vpm_mod(), "settings: %ls could not be written; kept for the next try", g_path);
}

void vpm_settings_tick(float dt)
{
    if (g_saveIn <= 0) return;
    g_saveIn -= dt;
    if (g_saveIn <= 0) vpm_settings_flush();
}

/* ---- options ----------------------------------------------------------------------------------------------------- */

struct VpmOption
{
    const VpmOptionDef* def;
    VpmComponent* owner;
    double value;
    VpmOptionFn on_change;
    char key[KEY_SIZE];
};
static VpmOption g_options[VPM_MAX_OPTIONS];
static int g_optionCount;

void vpm_options_reset(void)
{
    memset(g_options, 0, sizeof g_options);
    g_optionCount = 0;
    g_settingCount = 0;
    g_dirty = 0;
    g_saveIn = 0;
}

static int ChoiceCount(const VpmOptionDef* def)
{
    int n = 0;
    while (def->choices != NULL && def->choices[n] != NULL) n++;
    return n;
}

static double Snap(const VpmOptionDef* def, double value)
{
    if (def->step <= 0) return value;
    double steps = floor((value - def->min) / def->step + 0.5);
    double snapped = def->min + steps * def->step;
    return snapped > def->max ? def->max : snapped < def->min ? def->min : snapped;
}

static int Valid(const VpmOptionDef* def, double value)
{
    if (value != value) return 0;
    if (def->kind == VPM_TOGGLE) return value == 0 || value == 1;
    if (def->kind == VPM_CHOICE) return value >= 1 && value <= ChoiceCount(def) && value == floor(value);
    if (def->kind == VPM_SLIDER) return value >= def->min && value <= def->max;
    return 0;
}

static int ValidDef(const VpmOptionDef* def)
{
    if (def == NULL || def->id == NULL || def->id[0] == 0 || def->label == NULL) return 0;
    if (def->kind == VPM_CHOICE) return ChoiceCount(def) > 0;
    if (def->kind == VPM_SLIDER) return def->min < def->max && def->step >= 0;
    return def->kind == VPM_TOGGLE;
}

static void Save(VpmOption* option)
{
    char text[64];
    snprintf(text, sizeof text, "%.9g", option->value);
    vpm_setting_put("options", option->key, text);
    vpm_settings_save_soon();
}

VpmOption* vpm_option(VpmComponent* self, const VpmOptionDef* def)
{
    if (!ValidDef(def) || !Valid(def, def->kind == VPM_SLIDER ? Snap(def, def->value) : def->value))
    {
        vpm_log(self, "option %s refused: its definition is not valid", def != NULL && def->id != NULL ? def->id : "?");
        return NULL;
    }
    char key[KEY_SIZE];
    snprintf(key, sizeof key, "%s.%s", vpm_def(self)->id, def->id);
    for (int i = 0; i < g_optionCount; i++)
        if (strcmp(g_options[i].key, key) == 0) return g_options[i].def == def ? &g_options[i] : NULL;
    if (g_optionCount >= VPM_MAX_OPTIONS) { vpm_log(self, "option %s refused: the pack holds %d", key, VPM_MAX_OPTIONS); return NULL; }
    VpmOption* option = &g_options[g_optionCount++];
    memset(option, 0, sizeof *option);
    option->def = def;
    option->owner = self;
    snprintf(option->key, sizeof option->key, "%s", key);
    option->value = def->kind == VPM_SLIDER ? Snap(def, def->value) : def->value;
    const char* saved = vpm_setting("options", key);
    if (saved != NULL)
    {
        char* end = NULL;
        double value = strtod(saved, &end);
        if (end != saved && *end == 0 && def->kind == VPM_SLIDER) value = Snap(def, value);
        if (end != saved && *end == 0 && Valid(def, value)) option->value = value;
        else vpm_log(self, "option %s: the saved value \"%s\" is not valid; the default is used", key, saved);
    }
    return option;
}

double vpm_option_value(const VpmOption* option) { return option->value; }
void vpm_option_on_change(VpmOption* option, VpmOptionFn fn) { option->on_change = fn; }
int vpm_option_count(void) { return g_optionCount; }
VpmOption* vpm_option_at(int index) { return index >= 0 && index < g_optionCount ? &g_options[index] : NULL; }
const VpmOptionDef* vpm_option_def(const VpmOption* option) { return option->def; }
VpmComponent* vpm_option_owner(const VpmOption* option) { return option->owner; }

int vpm_option_set(VpmOption* option, double value)
{
    if (option->def->kind == VPM_SLIDER && value == value) value = Snap(option->def, value);
    if (!Valid(option->def, value)) return 0;
    option->value = value;
    Save(option);
    return 1;
}

typedef struct ChangeCall { VpmOption* option; } ChangeCall;
static void RunChange(void* arg)
{
    VpmOption* option = ((ChangeCall*)arg)->option;
    option->on_change(option->owner, option, option->value);
}

int vpm_option_apply(VpmOption* option, double value)
{
    if (!vpm_option_set(option, value)) return 0;
    if (option->on_change != NULL && vpm_running(option->owner))
    {
        ChangeCall call = {option};
        vpm_core_guarded(option->owner, RunChange, &call);
    }
    return 1;
}

/* ---- bindings ---------------------------------------------------------------------------------------------------- */

struct VpmBinding
{
    const VpmBindingDef* def;
    VpmComponent* owner;
    void* data;
    char key[KEY_SIZE];
};
static VpmBinding g_bindings[VPM_MAX_BINDINGS];
static int g_bindingCount;
static const VpmBindingBackend* g_backend;
static VpmComponent* g_backendOwner;

void vpm_bindings_reset(void)
{
    memset(g_bindings, 0, sizeof g_bindings);
    g_bindingCount = 0;
    g_backend = NULL;
    g_backendOwner = NULL;
}

typedef struct AttachCall { VpmBinding* binding; } AttachCall;
static void RunAttach(void* arg)
{
    VpmBinding* binding = ((AttachCall*)arg)->binding;
    binding->data = g_backend->attach(binding);
}

static void Attach(VpmBinding* binding)
{
    if (g_backend == NULL || g_backend->attach == NULL || !vpm_running(g_backendOwner)) return;
    AttachCall call = {binding};
    vpm_core_guarded(g_backendOwner, RunAttach, &call);
}

VpmBinding* vpm_binding(VpmComponent* self, const VpmBindingDef* def)
{
    if (def == NULL || def->id == NULL || def->id[0] == 0 || def->label == NULL)
    {
        vpm_log(self, "binding refused: its definition is not valid");
        return NULL;
    }
    char key[KEY_SIZE];
    snprintf(key, sizeof key, "%s.%s", vpm_def(self)->id, def->id);
    for (int i = 0; i < g_bindingCount; i++)
        if (strcmp(g_bindings[i].key, key) == 0) return g_bindings[i].def == def ? &g_bindings[i] : NULL;
    if (g_bindingCount >= VPM_MAX_BINDINGS) { vpm_log(self, "binding %s refused: the pack holds %d", key, VPM_MAX_BINDINGS); return NULL; }
    VpmBinding* binding = &g_bindings[g_bindingCount++];
    memset(binding, 0, sizeof *binding);
    binding->def = def;
    binding->owner = self;
    snprintf(binding->key, sizeof binding->key, "%s", key);
    Attach(binding);
    return binding;
}

int vpm_binding_down(const VpmBinding* binding)
{
    if (binding == NULL || g_backend == NULL || g_backend->down == NULL || !vpm_running(g_backendOwner)) return -1;
    return g_backend->down(binding, binding->data);
}

void vpm_bindings_set_backend(VpmComponent* owner, const VpmBindingBackend* backend)
{
    g_backend = backend;
    g_backendOwner = owner;
    for (int i = 0; i < g_bindingCount; i++) Attach(&g_bindings[i]);
}

int vpm_binding_count(void) { return g_bindingCount; }
VpmBinding* vpm_binding_at(int index) { return index >= 0 && index < g_bindingCount ? &g_bindings[index] : NULL; }
const VpmBindingDef* vpm_binding_def(const VpmBinding* binding) { return binding->def; }
VpmComponent* vpm_binding_owner(const VpmBinding* binding) { return binding->owner; }
void* vpm_binding_data(const VpmBinding* binding) { return binding->data; }
