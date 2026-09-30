local source=assert(arg[1])
local data=assert(loadfile(source..'/roster_data.lua'))()
local roster=assert(loadfile(source..'/roster.lua'))()

-- Authored tag IDs (resolve.from_native keeps the pre-25480438 numbering).
local ACID,ARMORED,PREDATORS,FODDER,CRAWLERS,BALANCED=1,2,3,5,6,7
local PREDATOR_STRAIN,SPORE_BURST,RUPTURE,DRAGON,SHRIEKERS,HIVE_WORLD=8,9,10,11,12,23
local ASSAULT,PHALANX,ARTILLERY,PANZER,BOT_BALANCED=13,14,15,17,18
local JET_BRIGADE,CYBORG_LEGION,GUNSHIPS,INCINERATION=19,20,21,22
local APPROPRIATORS,INVASION,MINDLESS,VOTE_SNATCHERS,HORDE=26,27,28,29,31
local BUGS,BOTS,SQUIDS=2,3,4

-- Data integrity: every index resolves and every displayed name is plain ASCII.
local names={}
for index,entry in ipairs(data.names) do
    assert(type(entry[1])=='string' and not entry[1]:find('[^\32-\126]') and entry[2]>=1 and entry[2]<=4)
    assert(not names[entry[1]],'Duplicate display name '..entry[1])
    names[entry[1]]=index
end
for faction,table_ in pairs(data.factions) do
    for _,resource in ipairs(table_.resources) do assert(resource==0 or data.names[resource]) end
    for _,unit in ipairs(table_.units) do
        assert(table_.families[unit[1]] and table_.resources[unit[2]] and #unit[3]==10)
        for _,tag in ipairs(unit[4]) do assert(tag>=1 and tag<=31) end
        for _,tag in ipairs(unit[5]) do assert(tag>=1 and tag<=31) end
    end
    for _,rule in ipairs(table_.swaps) do
        assert(rule[1]>=1 and rule[1]<=31 and table_.resources[rule[2]] and table_.resources[rule[3]])
    end
    for _,group in ipairs(table_.groups) do
        assert(({[2]=true,[4]=true,[5]=true,[6]=true,[9]=true})[group[1]],'Unexpected pool '..group[1])
        assert((group[1]==2)==(group[2]>=1 and group[2]<=4),'Only patrols carry a category')
        for _,member in ipairs(group[10]) do assert(table_.families[member[1]] and member[2]>=1) end
    end
    assert(#table_.travel>=1,faction)
end

local function forecast(faction,tags,difficulty,zone,war)
    local report=roster.compute(data,{faction=faction,tags=tags,difficulty=difficulty},zone,war)
    local set,large,order={},{},{}
    for _,entry in ipairs(report.large) do
        local name=data.names[entry[1]][1]
        set[name],large[name]=true,entry[2]
        order[#order+1]=name
        assert(entry[2]>=1 and entry[2]<=10,'Ticks out of range')
        assert(data.names[entry[1]][2]>=3,'Only large or massive enemies get meters')
    end
    for _,name in ipairs(report.small) do
        set[data.names[name][1]]=true
        order[#order+1]=data.names[name][1]
        assert(data.names[name][2]<=2,'Small and medium enemies are listed without meters')
    end
    return set,large,order
end

local function only(set,expected,label)
    local seen={}
    for name in pairs(set) do
        assert(expected[name],label..': unexpected '..name)
        seen[name]=true
    end
    for name in pairs(expected) do assert(seen[name],label..': missing '..name) end
end

-- Vote Snatchers replace every Overseer, Harvester, Watcher and Stingray.
for d=4,10 do
    only((forecast(SQUIDS,{VOTE_SNATCHERS},d)),
        {Wretches=true,Crushers=true,Voteless=true,Fleshmobs=true},'Vote Snatchers D'..d)
end
-- Appropriators: pure Illuminate, no Voteless, Fleshmobs, Crescent Overseers or Stingrays.
local set=forecast(SQUIDS,{APPROPRIATORS},8)
assert(set.Obtruders and set.Veracitors and set.Gatekeepers and set.Overseers)
assert(not set.Voteless and not set.Fleshmobs and not set['Crescent Overseers'] and not set.Stingrays)
-- Stingrays are air support for the Invasion Fleet only; Watchers patrol on their own timer.
set=forecast(SQUIDS,{INVASION},8)
assert(set.Stingrays and set.Watchers and set['Crescent Overseers'])
assert(not forecast(SQUIDS,{MINDLESS},8).Stingrays)

-- Incineration Corps: Berserkers and Brawlers are absent.
for _,base in ipairs({ASSAULT,PHALANX,ARTILLERY,PANZER,BOT_BALANCED}) do
    for d=2,10 do
        set=forecast(BOTS,{base,INCINERATION},d)
        assert(not set.Berserkers and not set.Brawlers,'Incineration Corps kept a Berserker or Brawler')
        assert(set['Pyro Troopers'] and set['Conflagration Devastators'])
    end
end

-- War Striders: D6+, only Artillery, Assault or Jet Brigade, and never beside tanks.
local TANKS={'Annihilator Tanks','Shredder Tanks','Barrager Tanks'}
for _,base in ipairs({ASSAULT,PHALANX,ARTILLERY,PANZER,BOT_BALANCED}) do
    for _,jet in ipairs({false,true}) do
        for d=1,10 do
            local tags={base}
            if jet then tags[2]=JET_BRIGADE end
            set=forecast(BOTS,tags,d)
            local expected=d>=6 and (jet or base==ARTILLERY or base==ASSAULT)
            assert((set['War Striders'] or false)==expected,'War Strider eligibility at D'..d)
            if set['War Striders'] then
                for _,tank in ipairs(TANKS) do assert(not set[tank],'Tanks and War Striders coexist') end
            end
        end
    end
end
local _,heavy=forecast(BOTS,{ARTILLERY},8)
local _,zoned=forecast(BOTS,{ARTILLERY},8,{[0xbfb1567b]=5})
assert(zoned['War Striders']>heavy['War Striders'],'A War Strider zone multiplier must raise its meter')
-- A negative or zero multiplier removes only groups containing that family:
-- tank slots still become War Striders through the Artillery replacement rule.
local _,reduced=forecast(BOTS,{ARTILLERY},8,{[0xbfb1567b]=-1})
assert(reduced['War Striders'] and reduced['War Striders']<heavy['War Striders'])
set=forecast(BOTS,{ARTILLERY},8,{[0xbfb1567b]=-1,[0x72c5564a]=-1})
assert(not set['War Striders'],'Removing both families removes every War Strider source')
set=forecast(BOTS,{ARTILLERY},8,nil,{[0xbfb1567b]=0,[0x72c5564a]=0})
assert(not set['War Striders'],'A zero war-effect multiplier removes the family groups')

-- Tank variants and Factory Striders follow the wiki's difficulty floors.
assert(not forecast(BOTS,{BOT_BALANCED},6)['Barrager Tanks'] and forecast(BOTS,{BOT_BALANCED},7)['Barrager Tanks'])
assert(not forecast(BOTS,{BOT_BALANCED},6)['Factory Striders'] and forecast(BOTS,{BOT_BALANCED},7)['Factory Striders'])
-- Cyborg Legion: Vox Engines replace Factory Striders from D7; Agitators and Radicals throughout.
set=forecast(BOTS,{PANZER,CYBORG_LEGION},7)
assert(set['Vox Engines'] and not set['Factory Striders'] and set.Radicals and set.Agitators)
-- Jet Brigade Hulks replace the ordinary ones; Gunships only with Gunship Patrols.
set=forecast(BOTS,{BOT_BALANCED,JET_BRIGADE},8)
assert(set['Jet Brigade Hulk Bruisers'] and not set['Hulk Bruisers'])
assert(not forecast(BOTS,{BOT_BALANCED},8).Gunships and forecast(BOTS,{BOT_BALANCED,GUNSHIPS},8).Gunships)
-- Objective-only and captive units are never listed.
for _,base in ipairs({ASSAULT,PHALANX,ARTILLERY,PANZER,BOT_BALANCED}) do
    for d=1,10 do assert(not forecast(BOTS,{base},d)['Hulk Obliterators']) end
end

-- Terminids: Alpha Commanders replace Brood Commanders from D8 and summon Alpha Warriors.
set=forecast(BUGS,{FODDER},7)
assert(set['Brood Commanders'] and not set['Alpha Commanders'] and not set['Alpha Warriors'])
set=forecast(BUGS,{FODDER},8)
assert(set['Alpha Commanders'] and set['Alpha Warriors'] and not set['Brood Commanders'])
-- Dragonroaches exclude Bile Titans (a Charger spawns instead), except under Spore Burst.
set=forecast(BUGS,{CRAWLERS,DRAGON},9)
assert(set.Dragonroaches and set.Chargers and not set['Bile Titans'] and set.Shriekers)
set=forecast(BUGS,{FODDER,SPORE_BURST,DRAGON},8)
assert(set.Dragonroaches and set['Spore Burst Bile Titans'] and not set['Bile Titans'])
assert(not forecast(BUGS,{CRAWLERS},9).Dragonroaches and not forecast(BUGS,{CRAWLERS},9).Shriekers)
-- Spore Burst replaces Warriors (including summoned ones), Scavengers and Hunters.
set=forecast(BUGS,{FODDER,SPORE_BURST},8)
assert(set['Spore Burst Warriors'] and not set.Warriors and not set.Scavengers and not set.Hunters)
-- Predator Strain replaces Hunters and brings Predator Stalkers; BugPredators brings Pouncers.
set=forecast(BUGS,{PREDATORS,PREDATOR_STRAIN},8)
assert(set['Predator Hunters'] and set['Predator Stalkers'] and set.Pouncers and not set.Hunters)
-- Rupture Strain from D6 (wiki: Extreme); Bile Bugs bring Spitters, Spewers and Bile Warriors.
assert(not forecast(BUGS,{ARMORED,RUPTURE},5)['Rupture Warriors'] and forecast(BUGS,{ARMORED,RUPTURE},6)['Rupture Warriors'])
set=forecast(BUGS,{ACID},10)
assert(set['Bile Spitters'] and set['Bile Spewers'] and set['Bile Warriors'] and set['Bile Titans'] and set['Spore Chargers'])
-- Hive Lords only on Hive Worlds from D7; Stalkers need lairs and are never listed.
assert(not forecast(BUGS,{CRAWLERS,HIVE_WORLD},6)['Hive Lords'] and forecast(BUGS,{CRAWLERS,HIVE_WORLD},7)['Hive Lords'])
for _,base in ipairs({ACID,ARMORED,PREDATORS,FODDER,CRAWLERS,BALANCED}) do
    for d=1,10 do
        set=forecast(BUGS,{base},d)
        assert(not set.Stalkers and not set['Hive Lords'])
        if d<4 then assert(not set.Chargers,'Chargers below Challenging') end
    end
end
-- The Horde tag only adds groups; it never removes the base constellation's units.
local base_set=forecast(BUGS,{ACID},9)
local horde_set=forecast(BUGS,{ACID,HORDE},9)
for name in pairs(base_set) do assert(horde_set[name],'Horde removed '..name) end

-- Sorting: most common first within each section, meters never increase down the list.
local _,large,order=forecast(BOTS,{ARTILLERY,INCINERATION},8)
assert(order[1]=='War Striders','War Striders lead the Artillery large enemies')
local previous=11
for _,name in ipairs(order) do
    if large[name] then assert(large[name]<=previous) previous=large[name] end
end
assert(roster.ticks(0.16)==10 and roster.ticks(0.08)==9 and roster.ticks(0.001)==1 and roster.ticks(0)==0)

-- One computation per mission input; tags in another order reuse it.
local cache=roster.new(data)
local snapshot={faction=BOTS,tags={ARTILLERY,INCINERATION},difficulty=8}
local first=cache:report(snapshot)
assert(cache:report(snapshot)==first and cache:report({faction=BOTS,tags={INCINERATION,ARTILLERY},difficulty=8})==first)
assert(cache.computed==1)
assert(cache:report(snapshot,{[0xbfb1567b]=5})~=first and cache.computed==2,'Zone multipliers are part of the key')
assert(cache:report({faction=BOTS,tags={ARTILLERY},difficulty=8})~=first and cache.computed==3)
assert(not pcall(roster.compute,data,{faction=9,tags={},difficulty=8}))
print('PASS: data integrity, wiki cross-checks for all three factions, War Strider rules, zone multipliers, sorting and one computation per mission')
