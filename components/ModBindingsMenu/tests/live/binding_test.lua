-- HD2-Addon: mods/cowboybingus/mod_bindings_test
-- Live test for Mod Bindings Menu v2: registers automatic bindings and logs
-- each activation, so trigger types and controller buttons can be checked.
local COUNT = 12
local loader = rawget(_G, 'CowboyBingusModLoader')
local log
if loader and type(loader.open_log) == 'function' then
    pcall(function() log = loader.open_log('ModBindingsTest.log') end)
end
local function note(message)
    if log then pcall(function() log:write(os.date('%H:%M:%S '), message, '\n'); log:flush() end) end
end

local registered, down, activations = {}, {}, {}
local function step()
    local menu = rawget(_G, 'ModBindingsMenu')
    if not menu or menu.api ~= 1 or (menu.version or 1) < 2 then return end
    for index = 1, COUNT do
        local id = 'cowboybingus.binding_test.' .. index
        if not registered[index] then
            local ok, reason = menu.register_binding(id, 'Test binding ' .. index, nil,
                                                     {category = 'Binding test'})
            if ok then registered[index] = true; note('Registered ' .. id)
            elseif reason then registered[index] = 'failed'; note('Failed ' .. id .. ': ' .. reason) end
        end
        if registered[index] == true then
            local now = menu.is_down(id)
            if now and not down[index] then
                activations[index] = (activations[index] or 0) + 1
                note('Test binding ' .. index .. ' activated (' .. activations[index] .. ')')
            end
            if now ~= nil then down[index] = now end
        end
    end
end

local previous_update = rawget(_G, 'update')
update = function(dt)
    local ok, err = pcall(step)
    if not ok then note('Error: ' .. tostring(err)) end
    if type(previous_update) == 'function' then return previous_update(dt) end
end
note('Mod Bindings test addon loaded.')
