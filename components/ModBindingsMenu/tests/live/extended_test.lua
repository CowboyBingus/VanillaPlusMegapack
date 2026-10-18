-- HD2-Addon: mods/cowboybingus/mod_bindings_extended_test
-- Live test for Mod Bindings Menu version 4 (extended bindings): registers 45
-- bindings in three sections, so the 29 automatic native actions fill and the
-- rest become extended bindings on the MORE MODS tab, plus four that ask for
-- the extended backend with defaults on every device. Logs every activation
-- (is_down turning true) and every change to a binding's keys, so presses,
-- captures, clears and restarts can be checked in ModBindingsExtendedTest.log.
local COUNT = 45
local SECTIONS = {'Extended test A', 'Extended test B', 'Extended test C'}
local DEFAULTS = {
    {id = 'f9', label = 'F9 (press)', default = 'f9'},
    {id = 'ctrl_g', label = 'Ctrl+G (hold)', default = {{button = 'g', modifiers = {'left ctrl'}, trigger = 'hold'}}},
    {id = 'mouse', label = 'Mouse 4 (release)', default = {{button = 'extra_1', device = 'mouse', trigger = 'release'}}},
    {id = 'pad', label = 'LB+Y or F10', default = {{button = 'y', device = 'controller', modifiers = {'left_shoulder'}},
                                                     'f10'}},
}
local loader = rawget(_G, 'CowboyBingusModLoader')
local log
if loader and type(loader.open_log) == 'function' then
    pcall(function() log = loader.open_log('ModBindingsExtendedTest.log') end)
end
local function note(message)
    if log then pcall(function() log:write(os.date('%H:%M:%S '), message, '\n'); log:flush() end) end
end

local ids, registered, down, keys = {}, {}, {}, {}
for index = 1, COUNT do
    ids[#ids + 1] = {id = 'cowboybingus.extended_test.' .. index, label = 'Extended test ' .. index,
                     options = {category = SECTIONS[(index - 1) % #SECTIONS + 1]}}
end
for _, entry in ipairs(DEFAULTS) do
    ids[#ids + 1] = {id = 'cowboybingus.extended_test.' .. entry.id, label = entry.label,
                     options = {category = 'Extended defaults', backend = 'extended', default = entry.default}}
end

local function describe(list)
    if list == nil then return 'nil' end
    local parts = {}
    for _, alternative in ipairs(list) do
        local text = alternative.button
        for _, modifier in ipairs(alternative.modifiers) do text = modifier .. '+' .. text end
        parts[#parts + 1] = alternative.device .. ':' .. text .. '@' .. alternative.trigger
    end
    return #parts > 0 and table.concat(parts, ' | ') or 'no keys'
end

local function register(menu, entry)
    local ok, reason = menu.register_binding(entry.id, entry.label, nil, entry.options)
    registered[entry.id] = ok and true or 'failed'
    local info = ok and menu.binding_info and menu.binding_info(entry.id)
    note((ok and 'Registered ' or 'Failed ') .. entry.id .. (ok and info and (' (' .. info.backend .. ')') or '') ..
         (reason and (': ' .. reason) or ''))
end

local function watch(menu, entry)
    local now = menu.is_down(entry.id)
    if now and not down[entry.id] then note(entry.label .. ' activated') end
    if now ~= nil then down[entry.id] = now end
    if menu.binding then
        local text = describe(menu.binding(entry.id))
        if text ~= keys[entry.id] then
            if keys[entry.id] then note(entry.label .. ' keys: ' .. text) end
            keys[entry.id] = text
        end
    end
end

local function step()
    local menu = rawget(_G, 'ModBindingsMenu')
    if not menu or menu.api ~= 1 or menu.extended == nil then return end
    for _, entry in ipairs(ids) do
        if registered[entry.id] == nil then register(menu, entry) end
        if registered[entry.id] == true then watch(menu, entry) end
    end
end

local previous_update = rawget(_G, 'update')
update = function(dt)
    local ok, err = pcall(step)
    if not ok then note('Error: ' .. tostring(err)) end
    if type(previous_update) == 'function' then return previous_update(dt) end
end
note('Mod Bindings extended test addon loaded.')
