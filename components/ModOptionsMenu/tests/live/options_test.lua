-- HD2-Addon: mods/cowboybingus/mod_options_test
-- Registers sample options for twelve test mods and logs every change. More
-- than 8 mods, so the MODS tab shows them in pages: ALPHA to GOLF and the page
-- control on page 1, HOTEL to LIMA and two hidden buttons on page 2. ALPHA to
-- FOXTROT land on the GAMEPLAY, DISPLAY, GRAPHICS, AUDIO, HUD and
-- ACCESSIBILITY panels, covering each panel family; ECHO fills all 32 rows to
-- scroll. Descriptions: short, long (several lines) and missing.
local loader = rawget(_G, 'CowboyBingusModLoader')
local log_file
if loader and type(loader.open_log) == 'function' then
    pcall(function() log_file = loader.open_log('ModOptionsTest.log') end)
end
local function note(message)
    if log_file then pcall(function() log_file:write(message .. '\n'); log_file:flush() end) end
end

local LONG = 'A long description to check wrapping and the box height: it runs over several lines, '
    .. 'the way a mod author might explain a setting that needs more words, with the frame growing '
    .. 'to fit every line of it.'
local OPTIONS = {
    {'test.alpha.hints', {type = 'toggle', label = 'Show Hints', mod = 'Test Alpha', default = true,
                          description = 'Shows button hints.'}},
    {'test.alpha.mode', {type = 'choice', label = 'Fire Mode', mod = 'Test Alpha',
                         choices = {'Single', 'Burst', 'Auto'}, default = 2, description = LONG}},
    {'test.alpha.quality', {type = 'choice', label = 'Quality', mod = 'Test Alpha',
                            choices = {'Low', 'Medium', 'High'}}},
    {'test.alpha.volume', {type = 'slider', label = 'Volume', mod = 'Test Alpha',
                           min = 0, max = 1, step = 0.05, default = 0.5, gap = true,
                           description = 'Slider description after a gap.'}},
    {'test.alpha.count', {type = 'slider', label = 'Count', mod = 'Test Alpha', min = 1, max = 10, default = 3}},
    {'test.bravo.enabled', {type = 'toggle', label = 'Enabled', mod = 'Test Bravo',
                            description = 'Second test mod, first row.'}},
    {'test.bravo.size', {type = 'choice', label = 'Marker Size', mod = 'Test Bravo',
                         choices = {'Small', 'Large', 'Huge'}}},
    {'test.charlie.fov', {type = 'slider', label = 'Extra Zoom', mod = 'Test Charlie', min = 10, max = 90, step = 5, default = 45,
                          description = 'Third test mod, integer slider.'}},
    {'test.charlie.speed', {type = 'slider', label = 'Speed Multiplier', mod = 'Test Charlie',
                            min = 0.1, max = 3, step = 0.1, default = 1, description = LONG}},
    {'test.delta.only', {type = 'toggle', label = 'Only Option', mod = 'Test Delta', default = true,
                         description = 'The only option of its mod.'}},
    {'test.foxtrot.words', {type = 'choice', label = 'Native Words', mod = 'Test Foxtrot',
                            choices = {'Off', 'On', 'Always'}, description = 'Choice with native words.'}},
}
for index = 1, 10 do
    OPTIONS[#OPTIONS + 1] = {'test.alpha.extra' .. index,
                             {type = 'toggle', label = 'Extra Toggle ' .. index, mod = 'Test Alpha'}}
end
for index = 1, 32 do
    OPTIONS[#OPTIONS + 1] = {'test.echo.' .. index,
                             {type = 'toggle', label = 'Echo Row ' .. index, mod = 'Test Echo',
                              gap = index % 8 == 1,
                              description = index % 2 == 1 and ('Echo row ' .. index .. ', odd rows only.') or nil}}
end
for index, name in ipairs({'Golf', 'Hotel', 'India', 'Juliett', 'Kilo', 'Lima'}) do
    OPTIONS[#OPTIONS + 1] = {'test.' .. name:lower() .. '.enabled',
                             {type = 'toggle', label = 'Enabled', mod = 'Test ' .. name, default = index % 2 == 0,
                              description = 'Test mod ' .. (6 + index) .. ' of 12, for the pages past 8 mods.'}}
end

local registered = false
local function step()
    local menu = rawget(_G, 'ModOptionsMenu')
    if registered or not menu or menu.api ~= 1 then return end
    registered = true
    for _, entry in ipairs(OPTIONS) do
        local id = entry[1]
        local ok, reason = menu.register_option(id, entry[2])
        if not ok then note('Registration failed for ' .. id .. ': ' .. tostring(reason)) end
        menu.on_change(id, function(value)
            note(string.format('Changed %s = %s', id, tostring(value)))
        end)
        note(string.format('Loaded %s = %s', id, tostring(menu.get(id))))
    end
    note('Registered ' .. #OPTIONS .. ' test options; menu ready: ' .. tostring(menu.ready()))
end

local previous_update = rawget(_G, 'update')
update = function(dt)
    local ok, err = pcall(step)
    if not ok then note('Test addon error: ' .. tostring(err)) end
    if type(previous_update) == 'function' then return previous_update(dt) end
end
note('Mod Options test addon initialized.')
