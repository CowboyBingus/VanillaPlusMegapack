-- The API other mods use; src/mod_options_menu.lua publishes it as the global
-- ModOptionsMenu.
local mom = ...
local state, note, translation = mom.state, mom.note, mom.translation
local display_text, saved_values, encode, decode = mom.display_text, mom.saved_values, mom.encode, mom.decode
local snap, valid_value, set_pending = mom.snap, mom.valid_value, mom.set_pending
local new_option, same_option, descriptor = mom.new_option, mom.same_option, mom.descriptor
local MAX_MODS, MAX_ROWS, SAVE_DELAY = mom.MAX_MODS, mom.MAX_ROWS, mom.SAVE_DELAY

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

-- Categories ------------------------------------------------------------------

-- A mod is known by the mod_id it gives, else by the addon that registers (the
-- chunk of its code) and the mod name resolved at its first registration. A
-- later registration of that addon finds the category by that name, by the
-- name shown now, or by the first registration's text function returning that
-- name now, so a mod whose name follows the game's language keeps one
-- category. Shown names follow the language (translation.refresh); identity
-- never does.
local OWN_SOURCE = debug.getinfo(1, 'S').source
local function caller_source()
    for level = 2, 40 do
        local info = debug.getinfo(level, 'S')
        if not info then break end
        if info.what ~= 'C' and info.source ~= OWN_SOURCE then return info.source end
    end
    return '?'
end

-- A namespaced id such as 'author.mod_name': letters, digits and _ . - / :
local function valid_mod_id(mod_id)
    return type(mod_id) == 'string' and #mod_id <= 64 and mod_id:find('^[%w_%.%-/:]+$') ~= nil
end

local function same_mod(mod, mod_id, origin, title)
    if mod_id or mod.id then return mod.id == mod_id end
    if mod.origin ~= origin then return false end
    if mod.name == title or mod.title == title then return true end
    local current = type(mod.source) == 'function' and translation.resolve(mod.source, 40)
    return current and translation.T.upper(current) == title or false
end

local function describe_mod(mod)
    return mod.id and ("mod_id '" .. mod.id .. "'") or ('addon ' .. mod.origin:gsub('^[@=]', ''))
end

-- Two mods may show the same name: they keep their own categories, and the
-- log says so once, when the second registers.
local function warn_same_title(mod)
    for _, other in ipairs(state.mods) do
        if other.title == mod.title then
            note('Two mod categories are named ' .. mod.title .. ': ' .. describe_mod(mod) .. ' is kept apart from '
                 .. describe_mod(other) .. '.')
            return
        end
    end
end

-- The MODS tab shows the first MAX_MODS mods to register (src/view.lua: past
-- 8, in pages). Another mod is refused, so its author learns it is not shown;
-- each refused mod is logged once, the first LOGGED_REFUSALS of them.
local LOGGED_REFUSALS = 8
local FULL = 'all ' .. MAX_MODS .. ' mod categories are in use'
local function refuse_mod(key, title)
    local count = state.refused_count
    if count < LOGGED_REFUSALS and not state.refused[key] then
        state.refused[key], state.refused_count = true, count + 1
        note('Refused the options of ' .. title .. ': ' .. FULL
             .. (count + 1 == LOGGED_REFUSALS and '; further refused mods are not logged.' or '.'))
    end
    return false, FULL
end

-- The category of the mod a registration names, new while a button is free.
local function category(mod_id, title, source)
    local origin = not mod_id and caller_source() or nil
    for _, mod in ipairs(state.mods) do
        if same_mod(mod, mod_id, origin, title) then return mod end
    end
    if #state.mods >= MAX_MODS then return refuse_mod(mod_id or (origin .. '\0' .. title), title) end
    local mod = {id = mod_id, origin = origin, name = title, title = title, source = source, order = {},
                 sequence = #state.mods + 1}
    warn_same_title(mod)
    state.mods[mod.sequence] = mod
    return mod
end

-- API -------------------------------------------------------------------------

-- The option a registration describes and the mod name it gives (false when
-- none), or nil and the reason it is refused.
local function checked(id, spec)
    if type(id) ~= 'string' or id == '' or #id > 96 or id:find('[%c]') or type(spec) ~= 'table'
       or not translation.resolve(spec.label, 64) then
        return nil, 'invalid option registration'
    end
    local mod_name = spec.mod ~= nil and translation.resolve(spec.mod, 40)
    if spec.mod ~= nil and not mod_name then return nil, 'invalid mod name' end
    if spec.mod_id ~= nil and not valid_mod_id(spec.mod_id) then return nil, 'invalid mod_id' end
    local option, reason = new_option(id, spec)
    if not option then return nil, reason end
    return option, mod_name
end

-- Version 2 (v1.1): texts may be functions; limits count characters.
-- Version 3: register_option refuses a mod past max_mods (112: past 8 mods
-- the category buttons show them in pages); spec.mod_id.
local api = {api = 1, version = 3, max_mods = MAX_MODS, max_options = MAX_ROWS}
-- id: stable unique string that keys the saved value. spec: {type = 'toggle'
-- | 'choice' | 'slider', label = 'Row text', mod = 'Mod name', mod_id =
-- 'author.mod', default = ..., choices = {...} (choice), min/max/step
-- (slider), gap = true (space above), description = 'Shown beside the rows
-- while the option is selected'}. mod_id (preferred) keeps a mod's options in
-- one category whatever its shown name. label, mod, description and each
-- choice may be a function returning the text in the current language (see
-- translation.refresh). Limits in characters: label 64, mod 40, choice 48,
-- description 400; mod_id 64.
function api.register_option(id, spec)
    local option, detail = checked(id, spec)
    if not option then return false, detail end
    local existing = state.options[id]
    if existing then
        if same_option(existing, option) then return true end
        return false, 'option already registered differently'
    end
    -- The category is named after the mod's name as first registered.
    local mod, refusal = category(spec.mod_id, translation.T.upper(detail or caller_mod()), spec.mod)
    if not mod then return false, refusal end
    if #mod.order >= MAX_ROWS then return false, 'mod already has ' .. MAX_ROWS .. ' options' end
    local title = mod.title
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
-- on_change callbacks are not called. The value counts at once. set() writes
-- no row itself: another mod's update may call it after the escape menu has
-- closed (its screen freed) and before MOM's next step notices, so a row of
-- the MODS view shows the value from the next step that has checked the view.
function api.set(id, value)
    local option = state.options[id]
    if not option then return false, 'unknown option' end
    if option.kind == 'slider' and type(value) == 'number' then value = snap(option, value) end
    if not valid_value(option, value) then return false, 'invalid value' end
    state.values[id] = value
    set_pending(id, nil)
    -- An unchanged value leaves the values file alone.
    local text, saved = encode(option, value), saved_values()
    if saved[id] ~= text then saved[id], state.dirty, state.save_timer = text, true, SAVE_DELAY end
    if state.view then state.queued[id], state.queued_any = true, true end
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

mom.api = api
