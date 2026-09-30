-- Per-frame API budget: the real installer, mission reader, native panel
-- reader, roster and model over synthetic memory; only the GUI is stubbed.
-- Pass "measure" as the second argument to print the counts instead.
local source=assert(arg[1])
local measure=arg[2]=='measure'
local ffi=require('ffi')
local budget=assert(loadfile(source..'/../tests/frame_budget.lua'))()
local memory=assert(loadfile(source..'/../tests/fixtures/memory.lua'))()
local function load(name) return assert(loadfile(source..'/'..name..'.lua'))() end
local resolve,mission,presentation=load('resolve'),load('mission'),load('presentation')
local roster,roster_data,model=load('roster'),load('roster_data'),load('model')
local text=load('bingus_text')
local english=assert(loadfile(source..'/../locales/en.lua'))()

-- One address space: the hosted mission and the native map panel fixtures.
local mission_fixture=memory.mission('host')
local panel_fixture=memory.presentation('map')
assert(mission_fixture.game==panel_fixture.game)
local game=mission_fixture.game
local blocks,overrides={},{}
for _,list in ipairs({mission_fixture.blocks,panel_fixture.blocks}) do
    for _,block in ipairs(list) do blocks[#blocks+1]=block end
end
local api={}
function api.pointer(bytes,offset)
    if not bytes then return nil end
    local q=ffi.new('uint64_t[1]')
    ffi.copy(q,bytes:sub((offset or 0)+1,(offset or 0)+8),8)
    local n=tonumber(q[0])
    return n>=65536 and n<0x800000000000 and n or nil
end
function api.read(address,size)
    -- The installer's language read passes pointers, like the game's reader.
    if type(address)=='cdata' then address=tonumber(ffi.cast('uintptr_t',address)) end
    local result={}
    for _,list in ipairs({blocks,overrides}) do
        for _,b in ipairs(list) do
            for at=math.max(address,b.address),math.min(address+size,b.address+#b.bytes)-1 do
                result[at-address+1]=b.bytes:sub(at-b.address+1,at-b.address+1)
            end
        end
    end
    for i=1,size do assert(result[i],string.format('Unexpected read 0x%x + %d',address,size)) end
    return table.concat(result)
end
function api.module() return game end
function api.module_hash() return 'supported' end
local counts=budget.wrap(api)
local function put(address,bytes) overrides[#overrides+1]={address=address,bytes=bytes} end
local function word(n) return ffi.string(ffi.new('uint32_t[1]',n),4) end
local function qword(n) return ffi.string(ffi.new('uint64_t[1]',n),8) end
local function u32(bytes,at)
    local v=ffi.new('uint32_t[1]')
    ffi.copy(v,bytes:sub(at+1,at+4),4)
    return tonumber(v[0])
end

-- The hosted operation frame is visible on the map; the briefing reuses the
-- loaded mission descriptor through the briefing owner record.
local screen_state=api.pointer(api.read(game+0x347ce28,8))+0x429c
local manager=api.pointer(api.read(game+0x3326e68,8))
local owner=api.pointer(api.read(manager+25224+8,8))
put(owner+349072,memory.widget(512,768.8333,533,489))
local controller=api.pointer(api.read(api.pointer(api.read(game+0x3326340,8))+0xae288,8))
put(manager+26184,word(1))
put(manager+26192,qword(0x5a000000)..word(235)..word(0))
put(0x5a000000+1072,api.read(controller+8,200))
local function show_screen(top) put(screen_state,word(top)..string.rep('\0',16)..word(1)) end
-- The game's Text Language: settings +212 indexes the language records; record 11 is zh-CN.
local settings=api.pointer(api.read(game+text.GAME.settings,8))
put(settings+text.GAME.index,word(11))
put(game+text.GAME.table+8*11,qword(0x5b000000))
put(0x5b000000+8,qword(0x5b000100))
put(0x5b000100,'zh-CN'..string.rep('\0',11))

local published,shown=0,nil
local surface={}
function surface:show(m) shown=m published=published+1 return true end
function surface:suspend() end
function surface:clear() shown=nil end
local env=setmetatable({stingray={Gui={},World={}},print=function() end,os={},io=io},{__index=_G})
env._G=env
local install=load('install')
setfenv(install,env)(function() return api end,mission,resolve,roster,roster_data,model,
    {new=function() return surface end},{revision='budget',game_sha256='supported',exe_sha256='supported'},
    presentation,text,{en=english,bundled={}})

-- Exact counts. v3.16.1 makes the same calls in every scenario with this
-- harness: the v4 roster and panel add no per-frame reads. A refresh frame
-- is the 0.5 s re-sample of a highlighted mission.
local limits={
    ship={pointer=1,read=2},
    map_steady={pointer=7,read=16},
    map_refresh={pointer=21,read=64},
    briefing_steady={pointer=9,read=18},
    briefing_refresh={pointer=27,read=68},
    loadout={pointer=3,read=5},
}
local function frame(label,dt)
    local used=budget.frame(counts,env.update,dt)
    if measure then print(label,budget.describe(used)) else budget.check(used,limits[label],label) end
    assert(not used.writable_data,'The forecast never queries memory protection')
    return used
end

-- Ship: no war table or briefing open.
show_screen(0)
env.update(.01)
frame('ship',.01)
assert(not shown)
-- War table: a hosted mission resolves and is published once.
show_screen(15)
for _=1,3 do env.update(.11) end
assert(shown and shown.headline and published>=1,'The hosted mission must publish')
-- The first visible frame read the game's Text Language (5 reads, not repeated
-- while the native font stays the same: the steady limits below pin that).
assert(text.registry().game_language=='zh-Hans' and text.registry().game_code=='zh-CN')
frame('map_steady',.01)
frame('map_refresh',.5)
frame('map_steady',.01)
-- Briefing: the same mission through the briefing owner.
show_screen(14)
for _=1,3 do env.update(.11) end
assert(shown and shown.screen=='briefing','The briefing must publish')
frame('briefing_steady',.01)
frame('briefing_refresh',.5)
-- Loadout: the briefing panel is hidden; nothing else is read.
put(owner+8,word(1))
frame('loadout',.01)
assert(not shown,'Loadout hides the forecast')
if not measure then
    print('PASS: per-frame API budget on the ship, war table, briefing and loadout; no protection queries')
end
