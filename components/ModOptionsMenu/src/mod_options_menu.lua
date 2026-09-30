-- HD2-Addon: mods/cowboybingus/mod_options_menu
-- Native MODS tab on the Options screen for Steam build 25480438.
if rawget(_G, 'ModOptionsMenu') then return end
local ffi, bit = require('ffi'), require('bit')
-- Texts and translations: mom_text = {module = src/bingus_text.lua, locales =
-- locales/}, which the build places ahead of this file as a local (tests
-- provide it as a global). This chunk is near Lua's limit of 200 locals, so
-- every translation helper lives in this one table.
local translation = {T = mom_text.module}

ffi.cdef [[
typedef unsigned char MOM_u8;
typedef unsigned short MOM_u16;
typedef unsigned int MOM_u32;
typedef unsigned long long MOM_u64;
]]
-- Widget positions and sizes: two floats passed by value in one register.
if not pcall(ffi.typeof, 'MOM_vec2') then ffi.cdef 'typedef struct { float x, y; } MOM_vec2;' end
-- LuaJIT keeps the first declaration of a C function, so these coexist with
-- the identical declarations of other CowboyBingus addons.
ffi.cdef [[
void *GetModuleHandleA(const char *name);
MOM_u32 GetModuleFileNameW(void *module, MOM_u16 *path, MOM_u32 capacity);
void *GetCurrentProcess(void);
int ReadProcessMemory(void *process, const void *address, void *buffer,
                      size_t size, size_t *received);
void *CreateFileW(const MOM_u16 *path, MOM_u32 access, MOM_u32 share,
                  void *security, MOM_u32 disposition, MOM_u32 flags, void *template_file);
int ReadFile(void *file, void *buffer, MOM_u32 size, MOM_u32 *received, void *overlapped);
int CloseHandle(void *handle);
int BCryptOpenAlgorithmProvider(void **algorithm, const MOM_u16 *name,
                                const MOM_u16 *provider, MOM_u32 flags);
int BCryptCloseAlgorithmProvider(void *algorithm, MOM_u32 flags);
int BCryptCreateHash(void *algorithm, void **hash, void *object, MOM_u32 object_size,
                     const void *secret, MOM_u32 secret_size, MOM_u32 flags);
int BCryptHashData(void *hash, const void *data, MOM_u32 size, MOM_u32 flags);
int BCryptFinishHash(void *hash, void *digest, MOM_u32 size, MOM_u32 flags);
int BCryptDestroyHash(void *hash);
]]

local kernel32, bcrypt = ffi.load('kernel32'), ffi.load('bcrypt')
local process = kernel32.GetCurrentProcess()
local loader = rawget(_G, 'CowboyBingusModLoader')
local log_file
if loader and type(loader.open_log) == 'function' then
    pcall(function() log_file = loader.open_log('ModOptionsMenu.log') end)
end
local function note(message)
    if log_file then pcall(function() log_file:write(message .. '\n'); log_file:flush() end) end
end
-- MOM's own texts, in the game's language when a translation has them.
translation.tr = translation.T.new(mom_text.locales.en, mom_text.locales.bundled,
                                   function(message) note('Text: ' .. message) end)

local GAME_SHA256 = '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'
local EXE_SHA256 = 'F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06'
local MENU_SYSTEM_PTR_RVA, UI_STATE_PTR_RVA = 0x347ce38, 0x347ce28
local UI_STACK, UI_STACK_ENTRIES = 0x429c, 5 -- five screen types, then their count
local ESCAPE_MENU_SCREEN, ESCAPE_MENU_TYPE = 200, 1
-- Escape menu: one tab bar over the GAME, SOCIAL and OPTIONS contents. The
-- widget has eight tab buttons; the screen asks for three at initialisation.
local SHOWN_CONTENT = 8
local TAB_BAR, TAB_COUNT, TAB_CURRENT, TAB_LABELS = 1248, 57448, 57452, 57320
local TAB_BUTTON_STATE, TAB_BUTTON_ACTIVE, TAB_TEXT, TAB_STRIDE = 11004, 11021, 8296, 3400
local TAB_LABELS_RVA = 0x33114d0
local NATIVE_TABS, OPTIONS_TAB, MODS_TAB = 3, 2, 3
-- OPTIONS content: a column of nine category buttons and one panel per category.
local OPTIONS_CONTENT = 3010456
local CATEGORY_BUTTON, CATEGORY_STRIDE, CATEGORY_TEXT = 816, 14920, 1928
local CATEGORY_TABLE_RVA, CATEGORY_RECORD = 0x32ec990, 48
local CATEGORIES, MOD_BUTTONS = 9, 8 -- the ninth (ACCOUNT) opens another screen
local CURRENT_CATEGORY, PREVIOUS_CATEGORY = 1318488, 1318492
local ROW_ARRAY, MAX_ROWS = 144000, 32
-- Category panels, in category order. Each family keeps its row count, layout
-- and settings pointer at its own offsets; all panels share the row array.
local PANELS = {
    [0] = {offset = 1150848, family = 'simple', selected = 2872}, -- GAMEPLAY
    [1] = {offset = 1179528, family = 'large', selected = 33296}, -- DISPLAY
    [2] = {offset = 1253248, family = 'large', selected = 33296}, -- GRAPHICS
    [3] = {offset = 1287376, family = 'simple', selected = 2872}, -- AUDIO
    [4] = {offset = 1153728, family = 'simple', selected = 2872}, -- HUD
    [5] = {offset = 1156616, family = 'access', selected = 22392}, -- ACCESSIBILITY
    [6] = {offset = 1290256, family = 'simple', selected = 2880}, -- CONTROLLER
    [7] = {offset = 1293152, family = 'simple', selected = 2872}, -- MOUSE & KEYBOARD
}
local FAMILIES = {
    simple = {count = 2832, x = 2836, gap = 2840, height = 2844, settings = 2856, scrolls = 2830},
    large = {count = 33256, x = 33260, gap = 33264, height = 33268, settings = 33280, scrolls = 33254},
    access = {count = 22352, x = 22356, gap = 22360, settings = 22376, scrolls = 22350},
}
local PANEL_ROWS, PANEL_CONTAINER, PANEL_SCROLL, SCROLL_POSITION = 2816, 544, 816, 1976
local VIEW_HEIGHT, ROW_HEIGHT, GAP_HEIGHT = 806, 64, 32
-- Description box beside the rows: a frame, a title and a body text. The game
-- fills it from the selected row's setting descriptor and caches that setting
-- (requested, shown); 156 means none. Heights are size.y x scale.y.
local DESCRIPTION_BOX, DESCRIPTION_FRAME, DESCRIPTION_TITLE, DESCRIPTION_BODY = 1315800, 272, 936, 1632
local DESCRIBED_SETTING, SHOWN_SETTING, NO_SETTING = 1318500, 1318476, 156
local WIDGET_HEIGHT, WIDGET_SCALE_Y, DESCRIPTION_LIMIT = 16, 32, 400
-- Apply, as on the OPTIONS tab: player edits stay pending until the game's
-- apply action. The unapplied-changes flag makes the game show APPLY (hint 2)
-- and meet tab switches and back with its UNAPPLIED CHANGES dialog (mode 0),
-- whose confirm discards the edits. Native settings never change on MODS, so
-- the game's own apply (which also needs its pending settings to differ) and
-- RESET TO DEFAULT never run there.
local UNAPPLIED = 1319449
local DIALOG, DIALOG_MODE, DIALOG_STATE, DIALOG_CONFIRM, DIALOG_CONFIRM_ACTION = 1296040, 19748, 19752, 4608, 12072
local DIALOG_CANCEL, DIALOG_CANCEL_ACTION = 12160, 19624
local DIALOG_OPEN, UNAPPLIED_MODE, VISIBLE_FLAG = 2, 0, 0x10
-- The game's own confirm of mode 0 reloads the shown panel from the live
-- settings, and the DISPLAY panel's reload then rewrites rows 8 and 11 as its
-- resolution lists. Once open (texts and buttons set), the dialog is switched
-- to a mode the game's confirm ignores, and MOM discards instead.
local NEUTRAL_MODE = 2
-- Input actions evaluated this frame: byte 0 of owner + 808 + 32 * (97 *
-- group + action). Apply is Menu.ExtraOption1 (Tab), group 0.
local INPUT_OWNER_PTR_RVA, ACTION_STATES, ACTION_STRIDE, GROUP_ACTIONS, ACTION_GROUPS = 0x347cf18, 808, 32, 97, 13
local MENU_GROUP, APPLY_ACTION, APPLY_SOUND = 0, 12, 1183616600
-- Option rows (31464 bytes each).
local ROW_STRIDE, ROW_TEXT, ROW_SELECTOR, ROW_VALUE_TEXT = 31464, 3992, 16016, 16832
local ROW_INDEX, ROW_SLIDER, ROW_SLIDER_VALUE, ROW_SETTING = 29068, 29176, 31408, 31428
local ROW_CHOICE_COUNT, ROW_CHOICES = 29072, 29080 -- selector choice count and label IDs
-- Text widgets hold a label ID at +272 and up to 14 format arguments
-- {key, type, value} of 24 bytes from +280, with their count at +616.
local LABEL, ARGUMENTS, ARGUMENT_COUNT = 272, 280, 616
-- '#COUNT' is a pure tag template, so a string COUNT argument shows any text
-- without borrowing a localization slot. The key is MurmurHash64A("COUNT") >> 32.
local TEXT_TEMPLATE, TEXT_KEY, STRING_ARGUMENT = 0xc67c7faf, 0xab2a7b35, 1
-- Rows use setting 139 (a BINDINGS activation type): the settings lookup
-- finds it, its value type is none, and no category handler special-cases it,
-- so changing a MODS row never reads or writes a game setting.
local INERT_SETTING, INERT_DESCRIPTOR_RVA = 139, 0x32ecc60
local DESCRIPTOR_SIZE, MAX_CHOICES = 216, 16
local WIDGET_INT_SLIDER, WIDGET_FLOAT_SLIDER, WIDGET_SELECTOR = 0, 1, 2
local OFF_TEXT, ON_TEXT = 0xa090be2e, 0x13dc1da2
-- Choice words the game already translates; other text is shown verbatim.
local NATIVE_WORDS = {
    OFF = 0xa090be2e, ON = 0x13dc1da2, NO = 0xef21c0c2, YES = 0x30dbdb29,
    LOW = 0xe1f9ab36, MEDIUM = 0x3134d1fe, HIGH = 0x208f9597, ULTRA = 0x99ffb498,
    DEFAULT = 0x38e6b4e4, CUSTOM = 0x2acf00b1, NORMAL = 0xf3222616, INVERTED = 0x05478062,
    WEAK = 0xe7b8332e, STRONG = 0xd9709682, BASIC = 0xaab9e5da, ADVANCED = 0xe0b81607,
    FULL = 0x3ba052b7, PERFORMANCE = 0x5097df8c, BALANCED = 0xe2135504, QUALITY = 0x61f69557,
    GLOBAL = 0x1d256a7b, ALWAYS = 0xeccb0c50, DISABLED = 0xe480cc2b, HIDDEN = 0xaae829ed,
    VISIBLE = 0xbcab6809, SMALL = 0x818d7022, LARGE = 0xf8c59d6a, SHORT = 0xb008f033,
    DYNAMIC = 0xf54d4908, HOLD = 0x639ee7c1, PRESS = 0x91b91dd3, TAP = 0x26603652,
}
local VALUES_FILE, SAVE_DELAY = 'ModOptionsMenu.values', 1
-- {RVA, first bytes, C type}; entry points are verified before first use.
-- Object addresses pass as integers, so a call creates no pointer object.
local NATIVE = {
    set_tab_labels = {0x17aac50, '\x48\x89\x54\x24\x10\x53\x56\x48\x83\xec\x68\x0f\x29\x74\x24\x30',
                      'void (*)(MOM_u64, const MOM_u32 *, int)'},
    select_category = {0x19999c0, '\x40\x53\x48\x83\xec\x20\x48\x8b\xd9\x89\x91\x58\x1e\x14\x00\x39',
                       'void (*)(MOM_u64, int)'},
    set_content_hidden = {0x19984c0, '\x48\x89\x5c\x24\x08\x48\x89\x74\x24\x10\x57\x48\x83\xec\x50\x41',
                          'void (*)(MOM_u64, MOM_u8, MOM_u8)'},
    row_reset = {0x17ff700, '\x48\x89\x5c\x24\x10\x48\x89\x74\x24\x18\x48\x89\x7c\x24\x20\x55',
                 'void (*)(MOM_u64, const float *, const float *)'},
    row_release = {0x17ff4b0, '\x48\x89\x5c\x24\x08\x57\x48\x83\xec\x20\x8b\x81\xc0\x7a\x00\x00',
                   'void (*)(MOM_u64)'},
    row_init = {0x17fe8d0, '\x48\x89\x5c\x24\x08\x57\x48\x83\xec\x70\x48\x8b\xbc\x24\xb0\x00',
                'void (*)(MOM_u64, MOM_vec2, MOM_vec2, MOM_vec2, int, MOM_u64, const void *, MOM_u8)'},
    add_child = {0x144c5c0, '\x40\x53\x48\x83\xec\x20\x4c\x8b\xca\x48\x8b\xd9\x48\x8b\x91\xe0',
                 'void (*)(MOM_u64, MOM_u64)'},
    set_visible = {0x144cfb0, '\x48\x83\xec\x28\x44\x8b\x01\x4c\x8b\xd1\x41\x8b\xc0\x45\x8b\xc8',
                   'void (*)(MOM_u64, MOM_u8)'},
    set_label = {0x143bf90, '\x48\x83\xec\x28\x4c\x8b\xd9\x39\x91\x10\x01\x00\x00\x0f\x84\x80',
                 'void (*)(MOM_u64, MOM_u32)'},
    set_string_arg = {0x143c950, '\x40\x53\x48\x83\xec\x20\x48\x8b\xd9\x48\x81\xc1\x10\x01\x00\x00',
                      'void (*)(MOM_u64, MOM_u32, const char *)'},
    clear_args = {0x143a0f0, '\x80\xb9\x58\x01\x00\x00\x00\xc6\x81\x58\x01\x00\x00\x00\x0f\x97',
                  'MOM_u8 (*)(MOM_u64)'},
    set_choice = {0x17fe7e0, '\x80\xb9\xf8\x32\x00\x00\x00\x74\x28\x83\xfa\x10\x73\x23\x48\x63',
                  'void (*)(MOM_u64, MOM_u32)'},
    set_slider = {0x17fc2c0, '\x40\x53\x48\x83\xec\x20\xf3\x0f\x10\x91\xac\x08\x00\x00\x48\x8b',
                  'void (*)(MOM_u64, float)'},
    finish_simple = {0x1807060, '\x48\x89\x5c\x24\x08\x57\x48\x83\xec\x30\x8b\x81\x10\x0b\x00\x00',
                     'void (*)(MOM_u64)'},
    finish_access = {0x1800fe0, '\x48\x89\x5c\x24\x08\x57\x48\x83\xec\x30\x8b\x81\x50\x57\x00\x00',
                     'void (*)(MOM_u64)'},
    scroll_thumb = {0x1793f60, '\x48\x89\x5c\x24\x10\x57\x48\x83\xec\x40\x48\x8b\xd9\x0f\x29\x74',
                    'void (*)(MOM_u64, float)'},
    scroll_extent = {0x1794600, '\xf3\x0f\x10\xa1\xb0\x07\x00\x00\x0f\x28\xd1\x0f\x2e\xe2\x7a\x02',
                     'void (*)(MOM_u64, float)'},
    set_opacity = {0x1448ad0, '\x40\x57\x48\x83\xec\x20\xf3\x0f\x10\x41\x44\x48\x8b\xf9\x0f\x2e',
                   'void (*)(MOM_u64, float)'},
    scroll_reset = {0x1794570, '\x80\xb9\xb5\x07\x00\x00\x00\x74\x19\xf3\x0f\x10\x89\xbc\x07\x00',
                    'void (*)(MOM_u64)'},
    options_visual = {0x1998590, '\x48\x8b\xc4\x57\x48\x83\xec\x70\x80\xb9\x15\x22\x14\x00\x00\x48',
                      'void (*)(MOM_u64, float)'},
    measure_text = {0x144e1a0, '\x40\x53\x48\x83\xec\x70\x48\x8b\xd9\x8b\x09\x8b\xc1\xc1\xe8\x12',
                    'void (*)(MOM_u64)'},
    -- Position and size share their first 27 bytes; byte 28 picks the field.
    set_position = {0x14476a0, '\x48\x89\x5c\x24\x18\x48\x89\x6c\x24\x20\x48\x89\x54\x24\x10\x56' ..
                               '\x57\x41\x57\x48\x83\xec\x20\xf3\x0f\x10\x41\x04', 'void (*)(MOM_u64, MOM_vec2)'},
    set_size = {0x1447160, '\x48\x89\x5c\x24\x18\x48\x89\x6c\x24\x20\x48\x89\x54\x24\x10\x56' ..
                           '\x57\x41\x57\x48\x83\xec\x20\xf3\x0f\x10\x41\x0c', 'void (*)(MOM_u64, MOM_vec2)'},
    hide_description = {0x17fab90, '\x48\x89\x5c\x24\x10\x57\x48\x83\xec\x70\x0f\xb6\xda\x48\x8b\xf9',
                        'void (*)(MOM_u64, MOM_u8, MOM_u8)'},
    -- Posts a UI sound event; the first argument is unused.
    play_sound = {0x1327f50, '\x48\x89\x5c\x24\x08\x48\x89\x74\x24\x10\x57\x48\x83\xec\x20\x48',
                  'void (*)(MOM_u64, MOM_u32)'},
}
local NATIVE_LABELS = {
    tabs = {0xd876b36e, 0x78934e12, 0x8c02bd80}, -- GAME, SOCIAL, OPTIONS
    categories = {0x396f27d7, 0x196248d0, 0xa522d2d0, 0x15cecac1, 0x9a688238,
                  0x07e3b100, 0x5db3b764, 0xa7c345ef, 0x9bb47b92},
}

-- values: applied values; pending: the player's unapplied edits, by option id.
-- mods_title, empty_text: MOM's own texts, resolved when the escape menu opens.
local state = {initialized = false, base = nil, native = nil, errors = 0,
               mods = {}, options = {}, option_count = 0, values = {}, pending = {}, pending_count = 0,
               saved = nil, callbacks = {}, texts = {}, text_addresses = {}, revision = 0,
               dirty = false, save_timer = 0, view = nil, mods_tab_logged = false, overflow_logged = false,
               menu_seen = false, language = nil, mods_title = 'MODS', empty_text = 'NO MOD OPTIONS INSTALLED'}

-- Memory ---------------------------------------------------------------------

-- ReadProcessMemory guards the two reads that follow pointers not yet known
-- to be live, the UI stack and the escape menu screen, so a stale pointer
-- fails the read instead of the game. The address passes as an integer and
-- values land in reused buffers, so a read allocates nothing.
local read_memory = ffi.cast('int (*)(void *, MOM_u64, void *, size_t, MOM_u32 *)', kernel32.ReadProcessMemory)
local received, word = ffi.new('MOM_u32[2]'), ffi.new('MOM_u32[2]')
local function fill(target, address, size)
    return read_memory(process, address, target, size, received) ~= 0
        and received[0] == size and received[1] == 0
end
local function valid_pointer(value) return value >= 0x10000 and value < 0x800000000000 end
local function read_pointer(address)
    if not fill(word, address, 8) then return nil end
    local value = word[0] + word[1] * 4294967296
    return valid_pointer(value) and value or nil
end
-- translation.read: up to 16 bytes as a string, for the game's Text Language.
translation.bytes = ffi.new('MOM_u8[16]')
function translation.read(address, size)
    if size > 16 or not fill(translation.bytes, address, size) then return nil end
    return ffi.string(translation.bytes, size)
end
-- Everything else is loaded and stored directly: game.dll's image stays
-- mapped, and the escape menu screen is in use by the game while it is on top
-- of the UI stack, the same frames in which MOM writes to it and hands it to
-- native functions. Typed pointers based at address 0 turn an address into an
-- index, so a load returns a plain number: no system call, no allocation.
-- 32-bit and 64-bit fields are 4-byte aligned.
local BYTES, WORDS, FLOATS = ffi.cast('MOM_u8 *', 0), ffi.cast('MOM_u32 *', 0), ffi.cast('float *', 0)
local function get8(address) return BYTES[address] end
local function get32(address) return WORDS[address / 4] end
local function getf(address) return FLOATS[address / 4] end
local function get64(address) return WORDS[address / 4] + WORDS[address / 4 + 1] * 4294967296 end
-- Writes only touch the escape menu's heap objects, never game.dll sections.
local function put8(address, value) BYTES[address] = value end
local function put32(address, value) WORDS[address / 4] = value end
local function putf(address, value) FLOATS[address / 4] = value end
-- Reused position arguments; a call copies the value.
local PIVOT, position = ffi.new('MOM_vec2', 0.5, 1), ffi.new('MOM_vec2') -- row pivot and anchor
local function vector(x, y)
    position.x, position.y = x, y
    return position
end
-- Memory the game reads with 16-byte SSE loads (movaps faults on anything
-- less) must be 16-byte aligned, but ffi.new only guarantees 8. The aligned
-- part is carved from a larger zeroed block, which the caller keeps alive.
local function aligned(size)
    local block = ffi.new('MOM_u8[?]', size + 15)
    local offset = (16 - tonumber(ffi.cast('MOM_u64', block)) % 16) % 16
    return ffi.cast('MOM_u8 *', block) + offset, block
end

local function module_sha256(module)
    local path = ffi.new('MOM_u16[32768]')
    local length = kernel32.GetModuleFileNameW(module, path, 32768)
    assert(length > 0 and length < 32768, 'cannot resolve module path')
    local file = kernel32.CreateFileW(path, 0x80000000, 7, nil, 3, 0x08000000, nil)
    assert(file ~= ffi.NULL and file ~= ffi.cast('void *', -1), 'cannot read module file')
    local algorithm, hash = ffi.new('void *[1]'), ffi.new('void *[1]')
    local ok, result = pcall(function()
        local name = ffi.new('MOM_u16[7]', {83, 72, 65, 50, 53, 54, 0})
        assert(bcrypt.BCryptOpenAlgorithmProvider(algorithm, name, nil, 0) == 0)
        assert(bcrypt.BCryptCreateHash(algorithm[0], hash, nil, 0, nil, 0, 0) == 0)
        local buffer, received = ffi.new('MOM_u8[1048576]'), ffi.new('MOM_u32[1]')
        while true do
            assert(kernel32.ReadFile(file, buffer, 1048576, received, nil) ~= 0)
            if received[0] == 0 then break end
            assert(bcrypt.BCryptHashData(hash[0], buffer, received[0], 0) == 0)
        end
        local digest, parts = ffi.new('MOM_u8[32]'), {}
        assert(bcrypt.BCryptFinishHash(hash[0], digest, 32, 0) == 0)
        for i = 0, 31 do parts[#parts + 1] = string.format('%02X', digest[i]) end
        return table.concat(parts)
    end)
    if hash[0] ~= nil then bcrypt.BCryptDestroyHash(hash[0]) end
    if algorithm[0] ~= nil then bcrypt.BCryptCloseAlgorithmProvider(algorithm[0], 0) end
    kernel32.CloseHandle(file)
    if not ok then error(result) end
    return result
end

local function initialize()
    if state.initialized then return end
    state.initialized = true
    local ok, err = pcall(function()
        local game, exe = kernel32.GetModuleHandleA('game.dll'), kernel32.GetModuleHandleA(nil)
        assert(game ~= nil and game ~= ffi.NULL and exe ~= nil and exe ~= ffi.NULL)
        assert(module_sha256(game) == GAME_SHA256, 'unsupported game.dll build')
        assert(module_sha256(exe) == EXE_SHA256, 'unsupported helldivers2.exe build')
        local base = tonumber(ffi.cast('MOM_u64', game))
        local native = {}
        for name, entry in pairs(NATIVE) do
            assert(ffi.string(ffi.cast('const char *', base + entry[1]), #entry[2]) == entry[2], name .. ' changed')
            native[name] = ffi.cast(entry[3], base + entry[1])
        end
        for index, label in ipairs(NATIVE_LABELS.tabs) do
            assert(get32(base + TAB_LABELS_RVA + (index - 1) * 4) == label, 'tab labels changed')
        end
        for index, label in ipairs(NATIVE_LABELS.categories) do
            assert(get32(base + CATEGORY_TABLE_RVA + (index - 1) * CATEGORY_RECORD + 8) == label,
                   'category labels changed')
        end
        assert(get32(base + INERT_DESCRIPTOR_RVA) == INERT_SETTING and
               get32(base + INERT_DESCRIPTOR_RVA + 4) == 10 and
               get32(base + INERT_DESCRIPTOR_RVA + 12) == 0, 'setting descriptors changed')
        state.base, state.native = base, native
    end)
    if ok then note('Native options layout verified for current game build.')
    else note('Mod options integration unavailable: ' .. tostring(err)) end
end

-- Text -----------------------------------------------------------------------

local function display_text(text)
    return (text:gsub('[%c]', ' '):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- A registered text: a string, or (API version 2) a function returning one,
-- which is called now and again whenever the escape menu opens, so the text
-- can follow the game's language. Limits count characters, so a Chinese or
-- Cyrillic text gets the same room as an English one. Returns the text to
-- show, or nil when the value is not a usable text.
function translation.resolve(value, limit)
    if type(value) == 'function' then
        local ok, result = pcall(value)
        if not ok then return nil end
        value = result
    end
    if type(value) ~= 'string' or translation.T.length(value) > limit then return nil end
    local text = display_text(value)
    if text == '' or not translation.T.check(text) then return nil end
    return text
end

-- Text buffers live as long as the addon: a hidden widget may still point at
-- one after the MODS view closes, until the game re-initialises that widget.
-- Their addresses are kept as numbers, so a check compares without allocating.
local function text_buffer(text)
    local buffer = state.texts[text]
    if not buffer then
        buffer = ffi.new('char[?]', #text + 1, text)
        state.texts[text] = buffer
        state.text_addresses[text] = tonumber(ffi.cast('MOM_u64', buffer))
    end
    return buffer
end

local function text_argument(widget)
    for index = 0, math.min(get8(widget + ARGUMENT_COUNT), 14) - 1 do
        local record = widget + ARGUMENTS + 24 * index
        if get32(record) == TEXT_KEY then return record end
    end
    return nil
end

local function shows_text(widget, text)
    if get32(widget + LABEL) ~= TEXT_TEMPLATE then return false end
    local record = text_argument(widget)
    if not record or get32(record + 4) ~= STRING_ARGUMENT then return false end
    text_buffer(text)
    return get64(record + 8) == state.text_addresses[text]
end

local function show_text(widget, text)
    state.native.set_label(widget, TEXT_TEMPLATE)
    state.native.set_string_arg(widget, TEXT_KEY, text_buffer(text))
end

local function show_label(widget, label)
    state.native.clear_args(widget + LABEL)
    state.native.set_label(widget, label)
end

-- Registered texts given as functions follow the game's language: they are
-- called again whenever the escape menu opens (never per frame). A result
-- that is no longer a usable text keeps the text shown before. Mods keep the
-- category they registered under; only its shown name changes.
function translation.refresh()
    local changed = false
    local function refreshed(value, source, limit, upper)
        if type(source) ~= 'function' then return value end
        local text = translation.resolve(source, limit)
        if not text then return value end
        if upper then text = translation.T.upper(text) end
        changed = changed or text ~= value
        return text
    end
    for _, mod in pairs(state.mods) do mod.title = refreshed(mod.title, mod.source, 40, true) end
    for _, option in pairs(state.options) do
        local sources = option.sources
        option.label = refreshed(option.label, sources.label, 64)
        if option.description then
            option.description = refreshed(option.description, sources.description, DESCRIPTION_LIMIT)
        end
        for index, source in ipairs(sources.choices) do
            -- The game's own words keep the game's label.
            if option.labels[index] == TEXT_TEMPLATE then
                option.choices[index] = refreshed(option.choices[index], source, 48, true)
            end
        end
    end
    local title, empty = translation.tr('tab.mods'), translation.tr('category.none')
    changed = changed or title ~= state.mods_title or empty ~= state.empty_text
    state.mods_title, state.empty_text = title, empty
    if changed then state.revision = state.revision + 1 end
end

-- The game's Text Language (5 guarded reads), logged when it changes.
function translation.observe()
    local tag, code = translation.T.observe(translation.read, state.base)
    local seen = tag and (tag .. ' (game setting ' .. code .. ')') or (translation.T.language() .. ' (Steam)')
    if seen ~= state.language then
        state.language = seen
        note('Text language: ' .. seen .. '.')
    end
end

-- Values ---------------------------------------------------------------------

local function values_path()
    local directory = type(loader) == 'table' and loader.log_directory
    if type(directory) ~= 'string' or directory == '' then
        local local_app_data = os.getenv('LOCALAPPDATA')
        if not local_app_data then return nil end
        directory = local_app_data .. '/CowboyBingus/Helldivers2/Logs'
    end
    return directory .. '/' .. VALUES_FILE
end

local function saved_values()
    if state.saved then return state.saved end
    state.saved = {}
    local path = values_path()
    local file = path and io.open(path, 'rb')
    if not file then return state.saved end
    for id, value in (file:read('*a') or ''):gmatch('([^\t\r\n]+)\t([^\r\n]*)') do
        state.saved[id] = value
    end
    file:close()
    return state.saved
end

local function encode(option, value)
    if option.kind == 'toggle' then return value and 'true' or 'false' end
    if option.kind == 'choice' then return tostring(value) end
    return string.format('%.6g', value)
end

local function valid_value(option, value)
    if option.kind == 'toggle' then return type(value) == 'boolean' end
    if type(value) ~= 'number' or value ~= value then return false end
    if option.kind == 'choice' then
        return value % 1 == 0 and value >= 1 and value <= #option.choices
    end
    return value >= option.min and value <= option.max
end

-- Slider values snap to the option's step; decimals avoid float noise.
local function snap(option, value)
    local steps = math.floor((value - option.min) / option.step + 0.5)
    local snapped = math.min(option.max, math.max(option.min, option.min + steps * option.step))
    return tonumber(string.format('%.' .. option.decimals .. 'f', snapped))
end

local function decode(option, text)
    if option.kind == 'toggle' then
        if text == 'true' then return true elseif text == 'false' then return false end
        return nil
    end
    local value = tonumber(text)
    if value == nil then return nil end
    if option.kind == 'slider' then value = snap(option, value) end
    return valid_value(option, value) and value or nil
end

local function save_values()
    local path = values_path()
    if not path then return end
    local merged = {}
    for id, text in pairs(saved_values()) do merged[id] = text end
    for id, option in pairs(state.options) do merged[id] = encode(option, state.values[id]) end
    local lines = {}
    for id, text in pairs(merged) do lines[#lines + 1] = id .. '\t' .. text end
    table.sort(lines)
    local file, reason = io.open(path, 'wb')
    if not file then note('Cannot save option values: ' .. tostring(reason)); return end
    file:write(table.concat(lines, '\n'), '\n')
    file:close()
    state.dirty = false
end

local function changed(option, value)
    if state.values[option.id] == value then return end
    state.values[option.id] = value
    state.saved[option.id] = encode(option, value)
    state.dirty, state.save_timer = true, SAVE_DELAY
    for _, callback in ipairs(state.callbacks[option.id] or {}) do
        local ok, err = pcall(callback, value, option.id)
        if not ok then note('Option callback for ' .. option.id .. ' failed: ' .. tostring(err)) end
    end
end

-- Player edits wait for the apply action; editing back to the applied value
-- withdraws the edit.
local function set_pending(id, value)
    local had = state.pending[id] ~= nil
    if value == state.values[id] then value = nil end
    state.pending[id] = value
    if had ~= (value ~= nil) then state.pending_count = state.pending_count + (had and -1 or 1) end
end

-- What a row shows: the pending edit, else the applied value.
local function shown_value(option)
    local value = state.pending[option.id]
    if value == nil then value = state.values[option.id] end
    return value
end

-- Applies every pending edit in registration order, then saves at once, as
-- the game saves its settings on apply.
local function apply_pending()
    local options = {}
    for id in pairs(state.pending) do options[#options + 1] = state.options[id] end
    table.sort(options, function(a, b) return a.sequence < b.sequence end)
    local pending = state.pending
    state.pending, state.pending_count = {}, 0
    for _, option in ipairs(options) do changed(option, pending[option.id]) end
    save_values()
    return #options
end

local function drop_pending()
    state.pending, state.pending_count = {}, 0
end

-- Native rows ----------------------------------------------------------------

-- The same layout as the game's descriptors (a float slider of 0.01 steps
-- there uses +48 = 6, +52 = 1, format 0x6220), 16-byte aligned like theirs.
-- Returns the descriptor and the block that keeps it alive.
local function descriptor(option)
    local blob, block = aligned(DESCRIPTOR_SIZE)
    local words, floats = ffi.cast('MOM_u32 *', blob), ffi.cast('float *', blob)
    words[0], words[1], words[3], words[4] = INERT_SETTING, 10, 0, TEXT_TEMPLATE
    if option.kind == 'slider' then
        words[2] = option.decimals == 0 and WIDGET_INT_SLIDER or WIDGET_FLOAT_SLIDER
        floats[9], floats[10], floats[11] = option.min, option.max, option.step
        floats[12], floats[13] = option.decimals == 0 and 20 or 6, 1
        -- Float values: two integer digits and the option's decimal places.
        words[14] = option.decimals == 0 and 0 or 0x6200 + option.decimals * 16
    else
        words[2], words[16] = WIDGET_SELECTOR, #option.labels
        for index, label in ipairs(option.labels) do words[16 + index] = label end
    end
    return blob, block
end

local function row_value(entry)
    if entry.option.kind == 'slider' then return getf(entry.row + ROW_SLIDER_VALUE) end
    return get32(entry.row + ROW_INDEX)
end

local function decode_row(option, raw)
    if option.kind == 'toggle' then return raw == 1 end
    if option.kind == 'choice' then return raw + 1 end
    return snap(option, raw)
end

-- Custom choice words share the '#COUNT' template, so the shown word is the
-- value widget's argument.
local function show_choice(entry)
    local option = entry.option
    if option.kind ~= 'choice' then return end
    local index = get32(entry.row + ROW_INDEX)
    local text = option.choices[index + 1]
    if text and option.labels[index + 1] == TEXT_TEMPLATE then
        show_text(entry.row + ROW_VALUE_TEXT, text)
    end
end

local function apply_value(entry, value)
    local option, native = entry.option, state.native
    if option.kind == 'slider' then
        native.set_slider(entry.row + ROW_SLIDER, value)
    else
        local index = option.kind == 'toggle' and (value and 1 or 0) or value - 1
        native.set_choice(entry.row + ROW_SELECTOR, index)
        show_choice(entry)
    end
    entry.raw = row_value(entry)
end

local function finish_panel(panel, family, name)
    local native = state.native
    local count = get32(panel + family.count)
    local height = count * ROW_HEIGHT - getf(panel + family.gap)
    if family.height then putf(panel + family.height, height) end
    if name == 'simple' then native.finish_simple(panel); return end
    if name == 'access' then native.finish_access(panel); return end
    -- The large panels finish inline in their builders; this is the same sequence.
    local scroll = panel + PANEL_SCROLL
    if count == 0 then
        native.set_opacity(scroll, 0)
        put8(panel + family.scrolls, 0)
        return
    end
    native.scroll_thumb(scroll, math.min(1, VIEW_HEIGHT / height))
    native.scroll_extent(scroll, height - VIEW_HEIGHT)
    if height > VIEW_HEIGHT then
        native.set_opacity(scroll, 1)
        put8(panel + family.scrolls, 1)
    else
        native.set_opacity(scroll, 0)
        if getf(scroll + SCROLL_POSITION) ~= 0 then
            putf(scroll + SCROLL_POSITION, 0)
            native.scroll_reset(scroll)
        end
        put8(panel + family.scrolls, 0)
    end
end

-- Mods and the MODS view -----------------------------------------------------

-- Mods in button order (alphabetical), at most one per category button.
local function mod_list()
    local list = {}
    for _, mod in pairs(state.mods) do list[#list + 1] = mod end
    table.sort(list, function(a, b) return a.title < b.title end)
    if #list > MOD_BUTTONS and not state.overflow_logged then
        state.overflow_logged = true
        note(#list .. ' mods registered options; only the first ' .. MOD_BUTTONS .. ' are shown.')
    end
    while #list > MOD_BUTTONS do table.remove(list) end
    return list
end

-- The idle gate, run every frame: one read of the UI stack (its entries and
-- their count) answers whether the escape menu is open; only then is its
-- screen pointer read.
local ui_stack = ffi.new('MOM_u32[?]', UI_STACK_ENTRIES + 1)
local function escape_menu()
    local base = state.base
    local ui = get64(base + UI_STATE_PTR_RVA)
    if not valid_pointer(ui) or not fill(ui_stack, ui + UI_STACK, 4 * (UI_STACK_ENTRIES + 1)) then
        return nil, 'closed'
    end
    local depth = ui_stack[UI_STACK_ENTRIES]
    if depth > UI_STACK_ENTRIES then return nil, 'closed' end
    local open = false
    for index = 0, depth - 1 do
        if ui_stack[index] == ESCAPE_MENU_TYPE then open = true end
    end
    if not open then return nil, 'closed' end
    if ui_stack[depth - 1] ~= ESCAPE_MENU_TYPE then return nil, 'covered' end
    local menu = get64(base + MENU_SYSTEM_PTR_RVA)
    local screen = valid_pointer(menu) and read_pointer(menu + ESCAPE_MENU_SCREEN)
    if not screen or screen % 8 ~= 0 then return nil, 'closed' end
    return screen, 'open'
end

-- Adds MODS as the fourth native tab. The game draws it, its index and Q/E
-- (LB/RB) cycling; relabelling resets every button's state, so the current
-- tab's selected state is restored as the screen's opener does.
local tab_labels = ffi.new('MOM_u32[?]', NATIVE_TABS + 1)
local function ensure_mods_tab(screen)
    local bar = screen + TAB_BAR
    local count = get32(bar + TAB_COUNT)
    local title = bar + TAB_TEXT + TAB_STRIDE * MODS_TAB
    if count == NATIVE_TABS + 1 then
        if get32(bar + TAB_LABELS + 4 * MODS_TAB) ~= TEXT_TEMPLATE then return false end
        if not shows_text(title, state.mods_title) then show_text(title, state.mods_title) end
        return true
    end
    if count ~= NATIVE_TABS then return false end
    local current = get32(bar + TAB_CURRENT)
    if current >= NATIVE_TABS then return false end
    for index = 0, NATIVE_TABS - 1 do
        tab_labels[index] = get32(bar + TAB_LABELS + 4 * index)
        if tab_labels[index] ~= NATIVE_LABELS.tabs[index + 1] then return false end
    end
    tab_labels[MODS_TAB] = TEXT_TEMPLATE
    state.native.set_tab_labels(bar, tab_labels, NATIVE_TABS + 1)
    local button = bar + TAB_STRIDE * current
    put32(button + TAB_BUTTON_STATE, 3)
    put8(button + TAB_BUTTON_ACTIVE, 1)
    show_text(title, state.mods_title)
    if not state.mods_tab_logged then
        state.mods_tab_logged = true
        note('Added native MODS tab (current tab ' .. current .. ').')
    end
    return true
end

local function category_button(content, index)
    return content + CATEGORY_BUTTON + CATEGORY_STRIDE * index
end

local function label_categories(view)
    local native = state.native
    for index = 0, CATEGORIES - 1 do
        local button = category_button(view.content, index)
        local mod = index < MOD_BUTTONS and view.mods[index + 1]
        if mod or (index == 0 and #view.mods == 0) then
            show_text(button + CATEGORY_TEXT, mod and mod.title or state.empty_text)
            native.set_visible(button, 1)
        else
            native.set_visible(button, 0)
        end
    end
end

local function restore_categories(content)
    for index = 0, CATEGORIES - 1 do
        local button = category_button(content, index)
        show_label(button + CATEGORY_TEXT, NATIVE_LABELS.categories[index + 1])
        state.native.set_visible(button, 1)
    end
end

-- Switches the shown panel through the game's own category selection, which
-- deactivates the previous panel and builds the next one. The selection keeps
-- no previous index itself, so it is written first; reselecting the shown
-- category goes through another panel to force a fresh build.
local function select_category(content, shown, target)
    local native = state.native
    if shown == target then
        local other = target == 0 and 3 or 0
        put32(content + PREVIOUS_CATEGORY, shown)
        native.select_category(content, other)
        shown = other
    end
    put32(content + PREVIOUS_CATEGORY, shown)
    native.select_category(content, target)
end

-- Every panel build first releases all rows, last to first, which detaches
-- them from whichever panel listed them. The reset loads both rectangles with
-- movaps, so they must be 16-byte aligned.
local ZERO_RECT
ZERO_RECT, state.zero_rect_block = aligned(16) -- the block stays referenced, so it is never collected
ZERO_RECT = ffi.cast('const float *', ZERO_RECT)
local function release_rows(rows)
    for index = MAX_ROWS - 1, 0, -1 do
        local row = rows + ROW_STRIDE * index
        state.native.row_reset(row, ZERO_RECT, ZERO_RECT)
        state.native.row_release(row)
    end
end

-- Replaces the rows the game built for category `index` with the options of
-- the mod on that button, following the panel builders: released rows, native
-- row initialisation from a descriptor, the same positions and gaps, then the
-- panel's own finishing layout.
local function build_page(view, index)
    local native = state.native
    local spec = PANELS[index]
    local family = FAMILIES[spec.family]
    local panel = view.content + spec.offset
    local rows = get64(panel + PANEL_ROWS)
    if rows ~= view.content + ROW_ARRAY then return false end
    local settings = get64(panel + family.settings)
    if not valid_pointer(settings) then settings = 0 end
    local mod = view.mods[index + 1]
    local options = mod and mod.order or {}
    local count = math.min(#options, MAX_ROWS)
    local page = {index = index, entries = {}}
    release_rows(rows)
    local gap = 0
    for position = 1, count do
        local option = options[position]
        if option.gap and position > 1 then gap = gap - GAP_HEIGHT end
        local row = rows + ROW_STRIDE * (position - 1)
        native.row_init(row, vector(0, (position - 1) * -ROW_HEIGHT + gap), PIVOT, PIVOT, 10,
                        settings, option.descriptor, 1)
        native.add_child(panel + PANEL_CONTAINER, row)
        show_text(row + ROW_TEXT, option.label)
        local entry = {row = row, option = option}
        apply_value(entry, shown_value(option))
        page.entries[position] = entry
    end
    put32(panel + family.count, count)
    putf(panel + family.x, 0)
    putf(panel + family.gap, gap)
    if get32(panel + spec.selected) >= count then put32(panel + spec.selected, 0) end
    finish_panel(panel, family, spec.family)
    view.page = page
    return true
end

-- The page is intact while the panel lists exactly its rows and each still
-- shows its option; a revert or device change rebuilds the panel natively,
-- and the DISPLAY panel's settings reload rewrites rows 8 and 11 in place
-- (their choice lists), so selectors check their choices too.
local function page_intact(view)
    local page = view.page
    local family = FAMILIES[PANELS[page.index].family]
    local panel = view.content + PANELS[page.index].offset
    if get32(panel + family.count) ~= #page.entries then return false end
    for _, entry in ipairs(page.entries) do
        local row, option = entry.row, entry.option
        if get32(row + ROW_SETTING) ~= INERT_SETTING or not shows_text(row + ROW_TEXT, option.label) then
            return false
        end
        if option.kind ~= 'slider' and (get32(row + ROW_CHOICE_COUNT) ~= #option.labels
                                        or get32(row + ROW_CHOICES) ~= option.labels[1]) then
            return false
        end
    end
    return true
end

local function poll_page(view)
    for _, entry in ipairs(view.page.entries) do
        local raw = row_value(entry)
        if raw ~= entry.raw then
            entry.raw = raw
            show_choice(entry)
            set_pending(entry.option.id, decode_row(entry.option, raw))
        end
    end
end

-- The page entry on the row the panel has selected (hovered with the mouse),
-- the same row the game's own description follows.
local function selected_entry(view)
    local page = view.page
    if not page then return nil end
    local spec = PANELS[page.index]
    return page.entries[get32(view.content + spec.offset + spec.selected) + 1]
end

local function text_height(widget)
    return getf(widget + WIDGET_HEIGHT) * getf(widget + WIDGET_SCALE_Y)
end

-- Shows the entry's description the way the game's set_description lays out a
-- setting's: title over body, the frame fitted to both. MOM rows share one
-- setting without a description, so the game itself only ever hides the box.
local function describe(view, entry)
    local native, box = state.native, view.content + DESCRIPTION_BOX
    view.described = entry
    local text = entry and entry.option.description
    if not text then native.hide_description(box, 1, 1); return end
    local title, body = box + DESCRIPTION_TITLE, box + DESCRIPTION_BODY
    show_text(title, entry.option.label)
    show_text(body, text)
    native.measure_text(body)
    native.measure_text(title)
    local title_height, body_height = text_height(title), text_height(body)
    native.set_position(body, vector(14, -title_height - 24))
    native.set_opacity(body, 1)
    native.set_size(box + DESCRIPTION_FRAME, vector(450, body_height + title_height + 7 + 72))
    native.hide_description(box, 0, 1)
end

-- Hands the box back to the game: hidden at once, MOM's text arguments gone,
-- and both setting caches cleared so OPTIONS fills it again.
local function release_description(content)
    local native, box = state.native, content + DESCRIPTION_BOX
    native.hide_description(box, 1, 0)
    native.clear_args(box + DESCRIPTION_TITLE + LABEL)
    native.clear_args(box + DESCRIPTION_BODY + LABEL)
    put32(content + DESCRIBED_SETTING, NO_SETTING)
    put32(content + SHOWN_SETTING, NO_SETTING)
end

-- The screen runs the OPTIONS content's visual pass (layout, category button
-- states, row animation, description box) only while OPTIONS is the current
-- tab, so the MODS tab runs it once per frame itself: without it a menu opened
-- on another tab is never laid out. The description then follows the selection.
local function update_visuals(view, dt)
    state.native.options_visual(view.content, dt)
    local entry = selected_entry(view)
    if entry ~= view.described then describe(view, entry) end
end

-- Whether an input action triggered this frame, on any device or binding.
-- The input owner is live whenever the menu is: the visual pass reads it.
local function action_triggered(group, action)
    local owner = get64(state.base + INPUT_OWNER_PTR_RVA)
    if not valid_pointer(owner) or group >= ACTION_GROUPS or action >= GROUP_ACTIONS then return false end
    return get8(owner + ACTION_STATES + ACTION_STRIDE * (GROUP_ACTIONS * group + action)) ~= 0
end

-- Whether a dialog button's action (u32 group, u32 action at key) triggered.
local function key_triggered(dialog, key)
    return action_triggered(get32(dialog + key), get32(dialog + key + 4))
end

local function button_triggered(dialog, button, key)
    return bit.band(get32(dialog + button), VISIBLE_FLAG) ~= 0 and key_triggered(dialog, key)
end

-- The UNAPPLIED CHANGES dialog, decided as the game decides it (0x199ce60):
-- confirmed when its shown confirm button's action triggers, cancelled when
-- its cancel button's does. When the game's input update runs before this one
-- it has already closed the dialog and cleared the confirm action (Menu.Select)
-- but not the cancel action (Menu.Back), so a dialog seen open and closed
-- since was confirmed unless its cancel action triggered. view.dialog: 'open'
-- once seen open, 'decided' once decided while still open (its closing then
-- decides nothing again). Nil when no dialog is involved.
local function unapplied_dialog(view)
    local dialog = view.content + DIALOG
    local mode = get32(dialog + DIALOG_MODE)
    local open = get32(dialog + DIALOG_STATE) == DIALOG_OPEN and (mode == UNAPPLIED_MODE or mode == NEUTRAL_MODE)
    local seen = view.dialog
    if not open then
        view.dialog = nil
        if seen ~= 'open' then return nil end
        return key_triggered(dialog, DIALOG_CANCEL_ACTION) and 'cancelled' or 'confirmed'
    end
    if seen == 'decided' then return 'open' end
    view.dialog = 'decided'
    if button_triggered(dialog, DIALOG_CONFIRM, DIALOG_CONFIRM_ACTION) then return 'confirmed' end
    if button_triggered(dialog, DIALOG_CANCEL, DIALOG_CANCEL_ACTION) then return 'cancelled' end
    view.dialog = 'open'
    return 'open'
end

-- Applies the pending edits on the apply action, discards them when the
-- UNAPPLIED CHANGES dialog is confirmed, and keeps the game's unapplied flag
-- in step with them. Nothing runs while no edit is pending.
local NO_ENTRIES = {}
local function update_apply(view)
    if state.pending_count > 0 then
        local dialog = unapplied_dialog(view)
        if dialog == 'confirmed' then
            drop_pending()
            for _, entry in ipairs(view.page and view.page.entries or NO_ENTRIES) do
                apply_value(entry, state.values[entry.option.id])
            end
            note('Discarded unapplied option changes.')
        elseif not dialog and action_triggered(MENU_GROUP, APPLY_ACTION) then
            note('Applied ' .. apply_pending() .. ' option changes.')
            state.native.play_sound(0, APPLY_SOUND)
        end
    else
        view.dialog = nil
    end
    local unapplied = state.pending_count > 0 and 1 or 0
    if unapplied ~= view.unapplied then
        put8(view.content + UNAPPLIED, unapplied)
        view.unapplied = unapplied
    end
end

-- Neutralises the UNAPPLIED CHANGES dialog once it is open. It finishes
-- opening inside the visual pass, which runs after update_apply, so this runs
-- after that pass: no frame leaves the game's own confirm armed. A dialog that
-- opened in that pass is watched from here, so a confirm on the game's next
-- input update counts even though update_apply never saw the dialog open.
local function neutralize_dialog(view)
    if state.pending_count == 0 then return end
    local dialog = view.content + DIALOG
    if get32(dialog + DIALOG_STATE) ~= DIALOG_OPEN then return end
    local mode = get32(dialog + DIALOG_MODE)
    if mode == UNAPPLIED_MODE then
        put32(dialog + DIALOG_MODE, NEUTRAL_MODE)
        mode = NEUTRAL_MODE
    end
    if mode == NEUTRAL_MODE and not view.dialog then view.dialog = 'open' end
end

local function enter_view(screen)
    local native = state.native
    local content = screen + OPTIONS_CONTENT
    local shown = get32(content + CURRENT_CATEGORY)
    -- described: the entry the description box shows; false until first set.
    -- unapplied: the game's unapplied-changes flag as last written.
    -- dialog: the UNAPPLIED CHANGES dialog as watched (unapplied_dialog).
    local view = {screen = screen, content = content, mods = mod_list(), revision = state.revision,
                  saved = shown < MOD_BUTTONS and shown or 0, described = false,
                  unapplied = 0, dialog = nil}
    -- The game's tab switch hid every content; MODS shows the OPTIONS content,
    -- which the screen feeds input while its shown content is OPTIONS (its
    -- visual pass follows the tab instead: update_visuals).
    put32(screen + SHOWN_CONTENT, OPTIONS_TAB)
    native.set_content_hidden(content, 0, 1)
    label_categories(view)
    if shown ~= 0 then select_category(content, shown, 0) end
    state.view = view
    build_page(view, 0)
    note('Opened MODS tab: ' .. #view.mods .. ' mods.')
end

local function leave_view(view)
    local content = view.content
    local shown = view.page and view.page.index or get32(content + CURRENT_CATEGORY)
    view.page = nil
    -- The game lets the view go only once the edits are applied or discarded.
    drop_pending()
    put8(content + UNAPPLIED, 0)
    release_description(content)
    restore_categories(content)
    if shown >= MOD_BUTTONS then shown = CATEGORIES end -- no panel to deactivate
    select_category(content, shown, view.saved)
    state.view = nil
    if state.dirty then save_values() end
    note('Closed MODS tab.')
end

local function refresh_view(view)
    view.mods, view.revision = mod_list(), state.revision
    label_categories(view)
    local current = view.page and view.page.index or 0
    view.page = nil
    if current >= math.max(#view.mods, 1) then
        select_category(view.content, current, 0)
        current = 0
    end
    build_page(view, current)
end

local function maintain_view(view)
    local current = get32(view.content + CURRENT_CATEGORY)
    local page = view.page
    if view.revision ~= state.revision then
        refresh_view(view)
    elseif current ~= (page and page.index) then
        view.page = nil
        if current < math.max(#view.mods, 1) then
            -- The game already switched panels; replace its rows.
            build_page(view, current)
        else
            select_category(view.content, current, 0)
            build_page(view, 0)
        end
    elseif page and not page_intact(view) then
        build_page(view, current)
    end
    if view.page then poll_page(view) end
end

local function step(dt)
    if not state.initialized then initialize() end
    if not state.native then return end
    if state.dirty then
        state.save_timer = state.save_timer - (type(dt) == 'number' and dt or 0)
        if state.save_timer <= 0 then save_values() end
    end
    local screen, status = escape_menu()
    local view = state.view
    -- A view dropped with the menu (closed or rebuilt) never applies its edits;
    -- reopening the escape menu re-initialises every widget we touched.
    if status == 'closed' then
        state.menu_seen = false
        if view then state.view = nil; drop_pending(); note('Escape menu closed on the MODS tab.') end
        if state.dirty then save_values() end
        return
    end
    if status ~= 'open' then return end
    if not state.menu_seen then
        -- The menu just opened. Its OPTIONS tab is where the game's Text
        -- Language changes, so the language is read and the texts refreshed
        -- here, once per opening.
        state.menu_seen = true
        translation.observe()
        translation.tr:refresh()
        translation.refresh()
    end
    if view and view.screen ~= screen then state.view, view = nil, nil; drop_pending() end
    if not ensure_mods_tab(screen) then
        if view then state.view = nil; drop_pending() end
        return
    end
    local tab = get32(screen + TAB_BAR + TAB_CURRENT)
    if view then
        if tab ~= MODS_TAB then leave_view(view) else maintain_view(view) end
    elseif tab == MODS_TAB then
        enter_view(screen)
    end
    view = state.view
    if view then
        update_apply(view)
        update_visuals(view, type(dt) == 'number' and dt or 0)
        neutralize_dialog(view)
    end
end

-- API ------------------------------------------------------------------------

-- Names a caller's mod after its addon entry, e.g.
-- 'mods/example/better_hud' -> 'BETTER HUD', for authors who pass no mod name.
local function caller_mod()
    for level = 3, 8 do
        local info = debug.getinfo(level, 'S')
        if not info then break end
        local entry = info.source and info.source:match('mods/[%w_]+/([%w_/]+)')
        if entry then
            local name = display_text((entry:match('([%w_]+)$') or entry):gsub('_', ' '))
            if name ~= '' then return name end
        end
    end
    return translation.tr('mod.unnamed')
end

-- sources: the registered values (strings or functions), for translation.refresh.
local function new_option(id, spec)
    local kind = spec.type
    local option = {id = id, kind = kind, label = translation.resolve(spec.label, 64), gap = spec.gap == true,
                    sources = {label = spec.label, description = spec.description, choices = {}}}
    if spec.description ~= nil then
        option.description = translation.resolve(spec.description, DESCRIPTION_LIMIT)
        if not option.description then return nil, 'invalid description' end
    end
    if kind == 'toggle' then
        option.labels, option.default = {OFF_TEXT, ON_TEXT}, spec.default == true
        if spec.default ~= nil and type(spec.default) ~= 'boolean' then return nil, 'invalid default' end
    elseif kind == 'choice' then
        local choices = spec.choices
        if type(choices) ~= 'table' or #choices < 2 or #choices > MAX_CHOICES then
            return nil, 'choices must list 2 to ' .. MAX_CHOICES .. ' names'
        end
        option.choices, option.labels = {}, {}
        for index, choice in ipairs(choices) do
            local text = translation.resolve(choice, 48)
            if not text then return nil, 'invalid choice name' end
            option.choices[index] = translation.T.upper(text)
            -- A word the game translates itself (ON, OFF, LOW...) shows the game's own label.
            option.labels[index] = NATIVE_WORDS[option.choices[index]] or TEXT_TEMPLATE
            option.sources.choices[index] = choice
        end
        option.default = spec.default == nil and 1 or spec.default
    elseif kind == 'slider' then
        local min, max, step = spec.min, spec.max, spec.step or 1
        if type(min) ~= 'number' or type(max) ~= 'number' or type(step) ~= 'number'
           or not (min < max) or step <= 0 or step > max - min then
            return nil, 'slider needs min < max and 0 < step <= max - min'
        end
        local decimals = 0
        while decimals < 3 and math.abs(step * 10 ^ decimals - math.floor(step * 10 ^ decimals + 0.5)) > 1e-6 do
            decimals = decimals + 1
        end
        if min % 1 ~= 0 then decimals = math.max(decimals, 1) end
        option.min, option.max, option.step, option.decimals = min, max, step, decimals
        option.default = spec.default == nil and min or spec.default
        if type(option.default) == 'number' then option.default = snap(option, option.default) end
    else
        return nil, 'type must be toggle, choice or slider'
    end
    if not valid_value(option, option.default) then return nil, 'invalid default' end
    return option
end

-- Texts given as functions may differ between registrations (another
-- language): only texts given as strings are compared.
local function same_option(a, b)
    local function same_text(x, y, source_x, source_y)
        return type(source_x) == 'function' or type(source_y) == 'function' or x == y
    end
    local sa, sb = a.sources, b.sources
    if a.kind ~= b.kind or a.default ~= b.default or not same_text(a.label, b.label, sa.label, sb.label)
       or not same_text(a.description, b.description, sa.description, sb.description) then
        return false
    end
    if a.kind == 'choice' then
        if #a.choices ~= #b.choices then return false end
        for index = 1, #a.choices do
            if not same_text(a.choices[index], b.choices[index], sa.choices[index], sb.choices[index]) then
                return false
            end
        end
        return true
    end
    if a.kind == 'slider' then return a.min == b.min and a.max == b.max and a.step == b.step end
    return true
end

-- Version 2 (v1.1): texts may be functions; limits count characters.
local api = {api = 1, version = 2, max_mods = MOD_BUTTONS, max_options = MAX_ROWS}
-- id: stable unique string that keys the saved value. spec: {type = 'toggle'
-- | 'choice' | 'slider', label = 'Row text', mod = 'Mod name', default = ...,
-- choices = {...} (choice), min/max/step (slider), gap = true (space above),
-- description = 'Shown beside the rows while the option is selected'}.
-- label, mod, description and each choice may be a function returning the
-- text in the current language (see translation.refresh). Limits in characters:
-- label 64, mod 40, choice 48, description 400.
function api.register_option(id, spec)
    if type(id) ~= 'string' or id == '' or #id > 96 or id:find('[%c]') or type(spec) ~= 'table'
       or not translation.resolve(spec.label, 64) then
        return false, 'invalid option registration'
    end
    local mod_name = spec.mod ~= nil and translation.resolve(spec.mod, 40)
    if spec.mod ~= nil and not mod_name then return false, 'invalid mod name' end
    local option, reason = new_option(id, spec)
    if not option then return false, reason end
    local existing = state.options[id]
    if existing then
        if same_option(existing, option) then return true end
        return false, 'option already registered differently'
    end
    -- Options group under the mod's name as first registered.
    local title = translation.T.upper(mod_name or caller_mod())
    local mod = state.mods[title]
    if not mod then
        mod = {title = title, source = spec.mod, order = {}}
        state.mods[title] = mod
    end
    if #mod.order >= MAX_ROWS then return false, 'mod already has ' .. MAX_ROWS .. ' options' end
    state.option_count = state.option_count + 1
    option.mod, option.sequence = title, state.option_count
    option.descriptor, option.descriptor_block = descriptor(option)
    mod.order[#mod.order + 1] = option
    state.options[id] = option
    local saved = saved_values()[id]
    local value = saved and decode(option, saved)
    if value == nil then value = option.default end
    state.values[id] = value
    state.revision = state.revision + 1
    note('Registered option ' .. id .. ' (' .. option.kind .. ') under ' .. title .. '.')
    return true
end

-- Applied value: boolean (toggle), 1-based choice index (choice) or number
-- (slider). A player's edit counts once applied.
function api.get(id)
    return state.values[id]
end

-- Sets a value from code, replacing any unapplied player edit of it;
-- on_change callbacks are not called.
function api.set(id, value)
    local option = state.options[id]
    if not option then return false, 'unknown option' end
    if option.kind == 'slider' and type(value) == 'number' then value = snap(option, value) end
    if not valid_value(option, value) then return false, 'invalid value' end
    state.values[id] = value
    set_pending(id, nil)
    saved_values()[id] = encode(option, value)
    state.dirty, state.save_timer = true, SAVE_DELAY
    local page = state.view and state.view.page
    for _, entry in ipairs(page and page.entries or NO_ENTRIES) do
        if entry.option == option then apply_value(entry, value) end
    end
    return true
end

-- callback(value, id) runs when the player applies a change to the option.
function api.on_change(id, callback)
    if type(id) ~= 'string' or type(callback) ~= 'function' then return false, 'invalid callback' end
    local list = state.callbacks[id] or {}
    list[#list + 1] = callback
    state.callbacks[id] = list
    return true
end

function api.ready() return state.native ~= nil end
_G.ModOptionsMenu = api

local previous_update = rawget(_G, 'update')
local traceback = debug.traceback
update = function(dt)
    -- xpcall passes dt on (LuaJIT extension), so no closure is built per frame.
    local ok, err = xpcall(step, traceback, dt)
    if not ok then
        state.errors = state.errors + 1
        if state.errors <= 8 then note('Options update error: ' .. tostring(err)) end
    end
    if type(previous_update) == 'function' then return previous_update(dt) end
end
note('Mod Options Menu initialized.')
