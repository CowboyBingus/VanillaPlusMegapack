-- Per-frame API budget and garbage: the real installer, mission reader, native
-- panel reader, roster and model over synthetic memory (tests/session.lua);
-- only the GUI is stubbed. Reads are counted per frame with
-- tests/frame_budget.lua. Garbage is measured with the collector stopped,
-- interpreted and compiled (compiled frames in a window where the JIT compiled
-- nothing, since compiling allocates). The fake reader allocates nothing itself.
-- Pass "measure" as the second argument to print the counts instead.
local source=assert(arg[1])
local measure=arg[2]=='measure'
local H=assert(loadfile(source..'/../tests/session.lua'))()(source)
local budget,text,word,session=H.budget,H.text,H.word,H.session

-- Exact counts: the same reads as v4.0 in every scenario. A refresh frame is
-- the 0.5 s re-sample of a highlighted mission. A mission's own screens are
-- neither the war table nor the briefing, the same two reads as the ship.
-- Campaign spawn weights and war effects come from rows the plain refresh
-- reads already.
local limits={
    ship={read=2},
    mission={read=2},
    map_steady={read=16},
    map_refresh={read=64},
    briefing_steady={read=18},
    briefing_refresh={read=68},
    loadout={read=5},
    client_steady={read=30},
    client_refresh={read=99},
    weighted_refresh={read=64},
}
local function frame(s,label,dt)
    local used=budget.frame(s.counts,s.env.update,dt)
    if measure then print(label,budget.describe(used)) else budget.check(used,limits[label],label) end
    assert(not used.writable_data,'The forecast never queries memory protection')
    return used
end

-- Exact garbage in bytes per frame, {interpreted, compiled}: none, refreshes
-- included (the refresh runs interpreted either way). A refresh used to make
-- 232 bytes (the constellation draw's lists and 64-bit random state, and the
-- filtered tag list), and 824 with spawn weights or war effects (their tables
-- and the roster's cache key). The same in the workspace LuaJIT and the game's
-- lua51.dll.
local garbage_limits={
    ship={0,0}, mission={0,0}, map_steady={0,0}, briefing_steady={0,0}, loadout={0,0}, client_steady={0,0},
    map_refresh={0,0}, briefing_refresh={0,0}, client_refresh={0,0}, weighted_refresh={0,0},
}
local function check_garbage(s,label,dt)
    local slow,fast=H.interpreted(s,dt),H.compiled(s,dt)
    if measure then print(label,string.format('garbage %.1f B/frame interpreted, %.1f compiled',slow,fast)) return end
    local limit=garbage_limits[label]
    assert(slow==limit[1] and fast==limit[2],string.format('%s: %.1f B/frame interpreted, %.1f compiled, budget %d and %d',
        label,slow,fast,limit[1],limit[2]))
end
-- string.format calls in one frame. A steady frame makes none: the font,
-- material and atlas hashes keep their hex text while their words stay the
-- same (v4.0 formatted all three every frame).
local function formats(s,dt)
    local format,n=string.format,0
    string.format=function(...) n=n+1 return format(...) end -- counted, restored below
    s.env.update(dt)
    string.format=format
    return n
end
local function steady_formats(s,label)
    local n=formats(s,.01)
    if measure then print(label,'string.format '..n) else assert(n==0,label..': '..n..' string.format calls') end
end
-- The anchor read in compiled frames is the native panel's (no stale fields).
local function anchored(s,x,y,w,h,client)
    local a=s.anchor
    assert(a and a.x==x and math.abs(a.y-y)<.01 and math.abs(a.w-w*4/3)<.01 and math.abs(a.h-h*4/3)<.01
        and math.abs(a.scale-4/3)<1e-6 and a.client==client,'The panel anchor must be the native frame')
    assert(a.font=='b56d2abac5d17df2' and a.material=='9f85b87d3ff20cbb' and a.atlas=='d1ebb991c79f934b')
end

local host=session('host')
-- Ship: no war table or briefing open; a mission's own screens read the same.
host.show_screen(0)
host.env.update(.01)
frame(host,'ship',.01)
check_garbage(host,'ship',.01)
assert(not host.shown)
host.show_screen(2)
frame(host,'mission',.01)
check_garbage(host,'mission',.01)
-- War table: a hosted mission resolves and is published.
host.show_screen(15)
for _=1,3 do host.env.update(.11) end
assert(host.shown and host.shown.headline and host.published>=1,'The hosted mission must publish')
assert(host.shown.key==host.fixture.key,'The published report is the hosted mission')
-- The first visible frame read the game's Text Language (5 reads, not repeated
-- while the native font stays the same: the steady limits below pin that).
assert(text.registry().game_language=='zh-Hans' and text.registry().game_code=='zh-CN')
frame(host,'map_steady',.01)
frame(host,'map_refresh',.5)
frame(host,'map_steady',.01)
local report=host.shown
check_garbage(host,'map_steady',0)
check_garbage(host,'map_refresh',.5)
assert(host.shown==report,'An unchanged refresh keeps its report')
anchored(host,512,768.8333,533,489,nil)
steady_formats(host,'map_steady')
-- Briefing: the same mission through the briefing owner.
host.show_screen(14)
for _=1,3 do host.env.update(.11) end
assert(host.shown and host.shown.screen=='briefing','The briefing must publish')
frame(host,'briefing_steady',.01)
frame(host,'briefing_refresh',.5)
check_garbage(host,'briefing_steady',0)
check_garbage(host,'briefing_refresh',.5)
anchored(host,512,894.1667,533,360,nil)
steady_formats(host,'briefing_steady')
-- Loadout: the briefing panel is hidden; nothing else is read.
host.space.put(host.owner+8,word(1))
frame(host,'loadout',.01)
check_garbage(host,'loadout',.01)
assert(not host.shown,'Loadout hides the forecast')
assert(host.env.EnemyIntelligence.failures==0)

-- A client hovering another squad's joinable mission on the war table.
local client=session('client')
client.show_screen(15)
for _=1,3 do client.env.update(.11) end
assert(client.shown and client.shown.key==client.fixture.key,'The joinable mission must publish')
frame(client,'client_steady',.01)
frame(client,'client_refresh',.5)
check_garbage(client,'client_steady',0)
check_garbage(client,'client_refresh',.5)
anchored(client,512,696.6667,533,425.5,true)
steady_formats(client,'client_steady')
assert(client.env.EnemyIntelligence.failures==0)

-- A hosted mission with campaign spawn weights and a war effect: an unchanged
-- refresh keeps its report without calling the roster again.
local weighted=session('host')
weighted.add_weights()
weighted.show_screen(15)
for _=1,3 do weighted.env.update(.11) end
assert(weighted.shown and weighted.zone and weighted.war,'The weighted mission must publish with its weights')
assert(weighted.zone[0xbfb1567b]==5 and weighted.zone[0x72c5564a]==0.5 and weighted.war[0x72c5564a]==0.25)
local calls,shown=weighted.roster_calls,weighted.shown
frame(weighted,'weighted_refresh',.5)
check_garbage(weighted,'weighted_refresh',.5)
assert(weighted.shown==shown and weighted.roster_calls==calls,'An unchanged weighted refresh keeps its report')
-- Changed weights reach the roster on the next refresh, and the refresh after
-- an unchanged one does not: a war effect's factor; one of the planet's two
-- spawn weights gone, then both; the war effect gone.
local globals=weighted.space.pointer(weighted.game+0x346d518)
local listed=weighted.board+1053752+304*76+286952+128
local function refreshed(n,message)
    weighted.env.update(.5)
    assert(weighted.roster_calls==calls+n,message)
    weighted.env.update(.5)
    assert(weighted.roster_calls==calls+n,message..', then unchanged: the roster is not called')
end
weighted.space.put(globals+8,H.word(0x3f000000))
refreshed(1,'A changed war effect computes the roster again')
assert(weighted.war[0x72c5564a]==0.5 and weighted.shown~=shown)
weighted.space.put(listed,word(1))
refreshed(2,'A spawn weight that stops applying computes again')
assert(weighted.zone[0xbfb1567b]==5 and weighted.zone[0x72c5564a]==nil)
weighted.space.put(listed,word(0))
refreshed(3,'Spawn weights that stop applying compute again')
assert(weighted.zone==nil and weighted.war)
weighted.space.put(globals+80,word(0))
refreshed(4,'A war effect that stops applying computes again')
assert(weighted.zone==nil and weighted.war==nil)
assert(weighted.env.EnemyIntelligence.failures==0)

-- The refresh path stays interpreted: over 2000 refreshes, with and without
-- spawn weights, no trace starts in the resolver, the roster or the
-- installer's refresh helpers (compiled, the resolver's loops and the tag
-- comparison did).
do
    local util=require('jit.util')
    local helpers={}
    local line=0
    for code in io.lines(source..'/install.lua') do
        line=line+1
        local name=code:match('^%s*local function ([%w_]+)%(')
        if name=='same_tags' or name=='copy_tags' or name=='same_weights' or name=='keep_weights'
            or name=='roster_report' or name=='forecast' or name=='publishable' or name=='refresh' then
            helpers[line]=name
        end
    end
    local started={}
    local function watch(what,_,func)
        if what=='start' then
            local info=util.funcinfo(func)
            local file=info.source or ''
            local helper=file:find('install.lua',1,true) and helpers[info.linedefined]
            started[#started+1]=helper and 'install.lua '..helper or file
        end
    end
    jit.attach(watch,'trace') -- lint-ok: R5 test only: records where traces start
    local plain=session('host')
    plain.show_screen(15)
    for _=1,1000 do plain.env.update(.5) end
    for _=1,1000 do weighted.env.update(.5) end
    jit.attach(watch) -- lint-ok: R5 test only: detaches the recorder
    local found=0
    for _ in pairs(helpers) do found=found+1 end
    assert(found==8 and #started>0,'The refresh helpers are found and the JIT ran')
    for _,file in ipairs(started) do
        assert(not file:find('resolve.lua',1,true) and not file:find('roster.lua',1,true)
            and not file:find('^install.lua '),'A trace started in '..file)
    end
end

if not measure then
    print('PASS: per-frame API budget on the ship, in a mission, on the war table (host, client, spawn weights), briefing and loadout; no protection queries')
    print('PASS: garbage per frame, interpreted and compiled: none, refreshes included (with and without spawn weights); '
        ..'refreshes start no trace in the resolver, the roster or the refresh helpers of the installer')
end
