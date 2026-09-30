-- Display model for one mission forecast. Every text comes from
-- locales/en.lua or its translation through `t` (a bingus_text translator:
-- t(key, values)); enemy names are keyed by roster_data.lua's English names.
local M = {}

-- Authored tag IDs (resolve.from_native) to their title keys. Subfactions,
-- strains and operation modifiers use their in-game names; base
-- constellations keep the mod's names.
M.TITLES = {
    [1]='title.bile_bugs', [2]='title.armored_bugs', [3]='title.hunter_swarms', [4]='title.flyer_composition',
    [5]='title.light_bugs', [6]='title.bug_nursery', [7]='title.balanced_terminids',
    [8]='title.predator_strain', [9]='title.spore_burst_strain', [10]='title.rupture_strain',
    [11]='title.dragonroach_activity', [12]='title.roving_shriekers',
    [13]='title.assault_forces', [14]='title.phalanx_forces', [15]='title.artillery_forces',
    [16]='title.air_composition', [17]='title.armored_column', [18]='title.balanced_automatons',
    [19]='title.jet_brigade', [20]='title.cyborg_legion', [21]='title.gunship_patrols',
    [22]='title.incineration_corps', [23]='title.hive_world', [24]='title.illuminate_stragglers',
    [25]='title.leviathan_blockade', [26]='title.appropriators', [27]='title.invasion_fleet',
    [28]='title.mindless_masses', [29]='title.vote_snatchers', [30]='title.seaf_support', [31]='title.horde',
}
local BASE = {[1]=true,[2]=true,[3]=true,[4]=true,[5]=true,[6]=true,[7]=true,
    [13]=true,[14]=true,[15]=true,[16]=true,[17]=true,[18]=true,[24]=true}

-- Text key of an English enemy name: 'MG Raiders' -> 'unit.mg_raiders'.
function M.unit_key(name)
    local key = name:lower():gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', '')
    return 'unit.' .. key
end

function M.headline(tags, t)
    local modifiers, bases = {}, {}
    for _, tag in ipairs(tags) do
        local key = M.TITLES[tag]
        if key then
            local list = BASE[tag] and bases or modifiers
            list[#list + 1] = t(key)
        end
    end
    for _, title in ipairs(bases) do modifiers[#modifiers + 1] = title end
    return #modifiers > 0 and table.concat(modifiers, t('headline.separator')) or t('headline.standard')
end

-- report = roster report {large={{name, ticks}}, small={name}} with names indexes.
function M.make(snapshot, report, data, t)
    local large, small, parts = {}, {}, {}
    for _, entry in ipairs(report.large) do
        local text = t(M.unit_key(data.names[entry[1]][1]))
        large[#large + 1] = {text=text, ticks=entry[2]}
        parts[#parts + 1] = text .. '=' .. entry[2]
    end
    for _, name in ipairs(report.small) do
        small[#small + 1] = t(M.unit_key(data.names[name][1]))
        parts[#parts + 1] = small[#small]
    end
    local result = {key=snapshot.key, screen=snapshot.screen, complete=true, headline=M.headline(snapshot.tags, t),
        large=large, small=small, label=t('panel.label'), footer=t('panel.footer'), more=t('panel.more'),
        separator=t('panel.list_separator'), large_caption=t('panel.large'), rate_caption=t('panel.rate'),
        small_caption=t('panel.small'), order_caption=t('panel.order')}
    -- Every drawn text is in the signature, so a language change redraws.
    result.signature = table.concat({result.headline, result.label, result.footer, result.more, result.separator,
        result.large_caption, result.rate_caption, result.small_caption, result.order_caption,
        table.concat(parts, '\1')}, '\2')
    return result
end

return M
