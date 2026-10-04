-- NaN and the infinities never become a slider's number: register_option's
-- min, max, step and default, set() and the values file refuse them (the MODS
-- tab's rows: tests/test_options_tab.lua). Each check also runs hot, so the
-- JIT compiles it: the game's compiled math.max drops a NaN, where the
-- interpreter keeps it.
-- Usage: <lua> tests/test_slider_numbers.lua [path to src/mod_options_menu.lua]
local source = arg[1] or ((arg[0]:match('^(.*[/\\])') or '') .. '../src/mod_options_menu.lua')
local root = source:match('^(.*)[/\\]src[/\\][^/\\]+$') or '.'
local directory = assert(os.getenv('TEMP') or os.getenv('TMP'))
local PATH = directory .. '/ModOptionsMenu.values'
local Text = dofile(root .. '/src/bingus_text.lua')
_G.mom_text = {module = Text, locales = {en = dofile(root .. '/locales/en.lua'), bundled = {}}}
_G.mom_files = setmetatable({}, {__index = function(files, name)
    local chunk = assert(loadfile(root .. '/src/' .. name .. '.lua'))
    rawset(files, name, chunk)
    return chunk
end})

local function upvalue(fn, wanted)
    for index = 1, 80 do
        local name, value = debug.getupvalue(fn, index)
        if name == wanted then return value end
        if name == nil then break end
    end
    error('missing upvalue ' .. wanted)
end
local function clean()
    for _, suffix in ipairs({'', '.tmp', '.bak'}) do os.remove(PATH .. suffix) end
end
local function write(path, text)
    local file = assert(io.open(path, 'wb'))
    assert(file:write(text))
    assert(file:close())
end
-- A new instance without a menu.
local function fresh()
    _G.ModOptionsMenu, _G.update, _G.BingusTranslations, _G.BingusRuntime = nil, function() end, nil, nil
    Text.registry().steam_language = 'en'
    _G.CowboyBingusModLoader = {log_directory = directory}
    dofile(source)
    local menu = assert(ModOptionsMenu)
    return menu, upvalue(menu.register_option, 'state')
end

local NAN, INF = 0 / 0, math.huge
local NON_FINITE = {NAN, INF, -INF}
local HOT = 300 -- calls: enough for the JIT to compile the path in both VMs
local FINITE_FLOATS = 'slider min, max and step must be finite floats'
local function slider(fields)
    local spec = {type = 'slider', label = 'Number', mod = 'Numbers', min = 0, max = 1, step = 0.05, default = 0.5}
    for key, value in pairs(fields) do spec[key] = value end
    return spec
end

-- register_option: min, max and step must be finite numbers a float can hold
-- (the game keeps them as floats), with a range a float can hold too; the
-- default must be finite (a finite default out of range is clamped, as before).
do
    clean()
    local menu, state = fresh()
    local refused = {
        {{min = NAN}, 'slider needs min < max and 0 < step <= max - min'},
        {{max = NAN}, 'slider needs min < max and 0 < step <= max - min'},
        {{step = NAN}, FINITE_FLOATS},
        {{min = -INF}, FINITE_FLOATS},
        {{max = INF}, FINITE_FLOATS},
        {{min = -INF, max = INF}, FINITE_FLOATS},
        {{step = INF}, 'slider needs min < max and 0 < step <= max - min'},
        {{step = -INF}, 'slider needs min < max and 0 < step <= max - min'},
        {{min = -3.5e38, default = 0}, FINITE_FLOATS},
        {{max = 3.5e38}, FINITE_FLOATS},
        {{min = -2e38, max = 2e38, step = 1, default = 0}, FINITE_FLOATS}, -- the range overflows a float
        {{step = 1e-39}, FINITE_FLOATS}, -- below the smallest normal float
        {{default = NAN}, 'invalid default'},
        {{default = INF}, 'invalid default'},
        {{default = -INF}, 'invalid default'},
    }
    for round = 1, HOT do
        for index, case in ipairs(refused) do
            local ok, reason = menu.register_option('numbers.bad' .. index, slider(case[1]))
            assert(ok == false and reason == case[2], 'refused ' .. index .. ' (round ' .. round .. '): '
                   .. tostring(reason))
        end
    end
    assert(next(state.options) == nil and #state.mods == 0, 'a refused slider leaves no option and no category')
    -- The limits themselves are taken; a finite default out of range is clamped.
    assert(menu.register_option('numbers.wide', slider({min = -1.7e38, max = 1.7e38, step = 1e37, default = 0})))
    assert(menu.register_option('numbers.fine', slider({min = 0, max = 1, step = 1.2e-38, default = 1})))
    assert(menu.register_option('numbers.far', slider({default = 1e300})) and menu.get('numbers.far') == 1)
    assert(menu.register_option('numbers.low', slider({default = -1e300})) and menu.get('numbers.low') == 0)
end
print('PASS: register_option refuses NaN and infinite slider bounds, steps and defaults, and numbers a float cannot '
      .. 'hold, with no option or category left behind, also when compiled')

-- set(): NaN and the infinities are refused with 'invalid value', the value
-- stays and nothing is marked for saving; a finite value out of range is
-- clamped as before. Choices refuse them too.
do
    clean()
    local menu, state = fresh()
    assert(menu.register_option('numbers.slider', slider({})))
    assert(menu.register_option('numbers.choice', {type = 'choice', label = 'Choice', mod = 'Numbers',
                                                   choices = {'One', 'Two', 'Three'}, default = 2}))
    for round = 1, HOT do
        for _, value in ipairs(NON_FINITE) do
            for _, id in ipairs({'numbers.slider', 'numbers.choice'}) do
                local ok, reason = menu.set(id, value)
                assert(ok == false and reason == 'invalid value', id .. ' set(' .. tostring(value) .. ') round ' .. round)
            end
        end
    end
    assert(menu.get('numbers.slider') == 0.5 and menu.get('numbers.choice') == 2 and not state.dirty)
    assert(menu.set('numbers.slider', 1e300) and menu.get('numbers.slider') == 1)
    assert(menu.set('numbers.slider', -1e300) and menu.get('numbers.slider') == 0)
end
print('PASS: set() refuses NaN and infinite values for sliders and choices and keeps the value, also when compiled')

-- The values file: a saved NaN or infinity (however the C library spells it)
-- is ignored and the option takes its default; finite values still load.
do
    clean()
    local spellings = {'nan', '-nan', 'NaN', 'inf', '-inf', 'infinity', '1e999', '-1e999', '-nan(ind)', '1.#QNAN',
                       '1.#INF'}
    local lines = {'numbers.ok\t0.25', 'numbers.choice_nan\tnan', 'numbers.choice_inf\tinf'}
    local ids = {}
    for index = 1, 210 do
        local id = 'numbers.saved' .. index
        ids[index] = id
        lines[#lines + 1] = id .. '\t' .. spellings[(index - 1) % #spellings + 1]
    end
    write(PATH, table.concat(lines, '\n') .. '\n')
    local menu = fresh()
    assert(menu.register_option('numbers.ok', slider({mod = 'Saved 0'})) and menu.get('numbers.ok') == 0.25)
    for _, id in ipairs({'numbers.choice_nan', 'numbers.choice_inf'}) do
        assert(menu.register_option(id, {type = 'choice', label = 'Choice', mod = 'Saved 0', choices = {'A', 'B'},
                                         default = 2}))
        assert(menu.get(id) == 2, id .. ' takes its default')
    end
    -- 210 sliders over 7 mods, so the path is compiled before the last ones load.
    for index, id in ipairs(ids) do
        assert(menu.register_option(id, slider({mod = 'Saved ' .. math.ceil(index / 30), default = 0.75})))
        assert(menu.get(id) == 0.75, id .. ' (' .. lines[index + 3] .. ') takes its default: ' .. tostring(menu.get(id)))
    end
    clean()
end
print('PASS: values saved as NaN or an infinity, in every spelling, load as the option\'s default, also when compiled')
