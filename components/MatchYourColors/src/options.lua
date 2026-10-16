-- Match Your Colors: the Mod Options Menu registration (moved from src/addon.lua for the Squadmates' Colors choice,
-- 2026-10-16: addon.lua was at the lint's code-line limit). Options.attach(Addon) sets Addon.options: the mode choice,
-- the paint scheme choice (with Schemes, src/schemes.lua), the squad choices and the toggles (complete sets, hoods,
-- materials, cape, weapons), registered once the menu's table exists (the loader's after_startup event, else a few
-- early frames).
local Options = {}

-- The scheme of a Paint Scheme menu value (1 Off, 2-12 the schemes), or nil.
local function scheme_of(value)
    return type(value) == 'number' and value - 1 or nil
end

function Options.attach(Addon)
    -- The choices after the mode and the scheme: {option id, option name, label key, description key, choices (text
    -- keys; 'Off' as it is), default}.
    local CHOICES = {
        {Addon.OPTION_SQUAD, 'squad', 'option.squad.label', 'option.squad.description',
         {'Off', 'option.squad.missing', 'option.squad.everyone'}, Addon.SQUAD_OFF},
        {Addon.OPTION_SQUAD_COLORS, 'squad_colors', 'option.squad_colors.label', 'option.squad_colors.description',
         {'option.squad_colors.own', 'option.squad_colors.yours'}, Addon.SQUAD_OWN},
        {Addon.OPTION_HIDE_CAPE, 'hide_cape', 'option.hide_cape.label', 'option.hide_cape.description',
         {'Off', 'option.hide_cape.yours', 'option.hide_cape.everyone'}, Addon.HIDE_OFF},
    }

    -- tr: the translator.
    function Addon.options(instance, tr, note, Schemes)
        local registered, attempts = false, 0
        local function text(menu, key)
            if key == 'Off' then return key end
            if (tonumber(menu.version) or 1) >= 2 then return function() return tr(key) end end
            return tr(key)
        end
        local function register_scheme(menu, mod)
            local choices = {'Off'}
            for _, scheme in ipairs(Schemes.LIST) do choices[#choices + 1] = text(menu, scheme.text) end
            return menu.register_option(Addon.OPTION_SCHEME, {type = 'choice', mod = mod, mod_id = Addon.MOD_ID,
                label = text(menu, 'option.scheme.label'), description = text(menu, 'option.scheme.description'),
                choices = choices, default = 1})
        end
        local function register_choice(menu, mod, choice)
            local choices = {}
            for i, key in ipairs(choice[5]) do choices[i] = text(menu, key) end
            return menu.register_option(choice[1], {type = 'choice', mod = mod, mod_id = Addon.MOD_ID,
                label = text(menu, choice[3]), description = text(menu, choice[4]), choices = choices,
                default = choice[6]})
        end
        local function register_all(menu, mod)
            local ok, why = menu.register_option(Addon.OPTION_MODE, {type = 'choice', mod = mod, mod_id = Addon.MOD_ID,
                label = text(menu, 'option.mode.label'), description = text(menu, 'option.mode.description'),
                choices = {'Off', text(menu, 'option.mode.helmet'), text(menu, 'option.mode.armor'),
                           text(menu, 'option.mode.cape')}, default = 2})
            if ok and Schemes then ok, why = register_scheme(menu, mod) end
            for _, choice in ipairs(CHOICES) do
                if ok then ok, why = register_choice(menu, mod, choice) end
            end
            for _, toggle in ipairs(Addon.TOGGLES) do
                if ok then
                    ok, why = menu.register_option(toggle[1], {type = 'toggle', mod = mod, mod_id = Addon.MOD_ID,
                        label = text(menu, toggle[3]), description = text(menu, toggle[4]), default = toggle[5]})
                end
            end
            return ok, why
        end
        -- The menu's values applied now and on every change.
        local function follow(menu, id, name, convert)
            convert = convert or function(value) return value end
            instance.set_option(name, convert(menu.get(id)))
            menu.on_change(id, function(value) instance.set_option(name, convert(value)) end)
        end
        local function register(menu)
            local ok, why = register_all(menu, text(menu, 'option.mod'))
            if not ok then return false, why end
            follow(menu, Addon.OPTION_MODE, 'mode')
            if Schemes then follow(menu, Addon.OPTION_SCHEME, 'scheme', scheme_of) end
            for _, choice in ipairs(CHOICES) do follow(menu, choice[1], choice[2]) end
            for _, toggle in ipairs(Addon.TOGGLES) do follow(menu, toggle[1], toggle[2]) end
            note('Options: ' .. instance.options_text() .. '.') -- set_option logs only changes
            return true
        end
        local self = {}
        -- One attempt; true once registered (or when no menu is installed: defaults stay).
        function self.attempt()
            if registered then return true end
            attempts = attempts + 1
            local menu = rawget(_G, 'ModOptionsMenu')
            if type(menu) ~= 'table' or menu.api ~= 1 then return false end
            local called, ok, why = pcall(register, menu)
            registered = called and ok
            if registered then
                note('Mod Options Menu: options registered.')
            else
                note('Mod Options Menu: not registered (' .. tostring(called and why or ok) .. ').')
            end
            return registered
        end
        -- True on the frames of Addon.REGISTER_FRAMES until registered; afterwards one compare per frame.
        local next_index, next_at = 1, Addon.REGISTER_FRAMES[1]
        function self.due(frame)
            if frame < next_at or registered then return false end
            next_index = next_index + 1
            next_at = Addon.REGISTER_FRAMES[next_index] or math.huge
            return true
        end
        function self.registered() return registered end
        return self
    end
    if type(jit) == 'table' and type(jit.off) == 'function' then jit.off(Addon.options, true) end
end

-- Startup and option registration run once: interpreted, sub-functions included.
if type(jit) == 'table' and type(jit.off) == 'function' then
    jit.off(scheme_of, true)
    jit.off(Options.attach, true)
end

return Options
