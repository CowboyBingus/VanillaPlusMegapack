-- game.dll's native functions MOM calls and the native labels and setting
-- descriptor it relies on, verified once per session against Steam build
-- 25480438 before MOM touches the menu (initialize).
local mom = ...
local ffi = require('ffi')
local memory, note, state, get32 = mom.memory, mom.note, mom.state, mom.get32

local GAME_SHA256 = '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'
local EXE_SHA256 = 'F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06'
-- The native labels of the escape menu's three tabs (4 bytes each) and of the
-- OPTIONS content's nine categories (one record each, the label at +8).
local TAB_LABELS_RVA = 0x33114d0
local CATEGORY_TABLE_RVA, CATEGORY_RECORD = 0x32ec990, 48
-- Rows use setting 139 (a BINDINGS activation type): the settings lookup
-- finds it, its value type is none, and no category handler special-cases it,
-- so changing a MODS row never reads or writes a game setting.
local INERT_SETTING, INERT_DESCRIPTOR_RVA = 139, 0x32ecc60
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

local function initialize()
    if state.initialized then return end
    state.initialized = true
    local ok, err = pcall(function()
        -- The runtime hashes each module file once per session for every mod
        -- (BingusRuntime.hashes): 'game modules unavailable' or 'unsupported
        -- game build' when it refuses.
        local verified, why = memory.verify_build({exe_sha256 = EXE_SHA256, game_sha256 = GAME_SHA256})
        assert(verified, why)
        local base = memory.address(memory.module('game.dll'))
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

-- For the other files and the update.
mom.initialize, mom.NATIVE_LABELS, mom.INERT_SETTING = initialize, NATIVE_LABELS, INERT_SETTING
