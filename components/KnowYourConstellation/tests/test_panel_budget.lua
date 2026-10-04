-- Per-frame engine calls and garbage of the real panel, with the real
-- installer, readers, roster and model over synthetic memory
-- (tests/session.lua) and an engine fake that allocates nothing
-- (H.engine). Engine calls are pinned per frame by name with
-- tests/frame_budget.lua; garbage is measured with the collector stopped,
-- interpreted and compiled. The engine's own cost and garbage are not here:
-- they are unmeasured in game. Pass "measure" as the second argument to print
-- the counts instead.
local source=assert(arg[1])
local measure=arg[2]=='measure'
local H=assert(loadfile(source..'/../tests/session.lua'))()(source)
local budget,word=H.budget,H.word

-- Exact engine calls per frame. While the panel is up, every frame checks the
-- world list and the window size (a replaced or removed world moves or hides
-- the panel on that frame; a new size lays it out again). A moving headline
-- adds one text update with its temporary IDs, position and colour. Hidden
-- frames make none; the frame that hides the panel destroys its GUI.
local UP={['Application.main_world']=1,['Application.worlds']=1,['Gui.resolution']=1}
local limits={
    ship={}, mission={}, loadout={},
    map_steady=UP, map_refresh=UP, waiting=UP, briefing_steady=UP, briefing_refresh=UP, client_steady=UP,
    client_refresh=UP, scroll_holding=UP,
    scroll_moving={['Application.main_world']=1,['Application.worlds']=1,['Gui.resolution']=1,['Gui.update_text']=1,
        ['IdString64.from_hex']=2,['Vector3']=1,['Color']=1},
    hiding={['Application.worlds']=1,['World.destroy_gui']=1},
}
local function frame(s,label,dt)
    local _,used=budget.frame(s.counts,budget.frame,s.engine_counts,s.env.update,dt)
    if measure then print(label,budget.describe(used)) return used end
    budget.check(used,limits[label],label)
    for name,n in pairs(limits[label]) do
        assert(used[name]==n,label..': '..name..' '..tostring(used[name])..' times, pinned at '..n)
    end
    return used
end
-- Garbage in bytes per frame, {interpreted, compiled}: none anywhere. Every
-- hidden frame (the ship and missions) used to empty the panel into four new
-- tables (128 bytes), and every waiting frame made a new pending model.
local function check_garbage(s,label,dt)
    local slow,fast=H.interpreted(s,dt),H.compiled(s,dt)
    if measure then print(label,string.format('garbage %.1f B/frame interpreted, %.1f compiled',slow,fast)) return end
    assert(slow==0 and fast==0,string.format('%s: %.1f B/frame interpreted, %.1f compiled',label,slow,fast))
end
local function session(kind)
    local engine,counts=H.engine()
    local s=H.session(kind,engine)
    s.engine,s.engine_counts=engine,counts
    return s
end
local function up(s) return s.surface and s.surface.gui~=nil end
local function status(s) return s.env.EnemyIntelligence.status end

local host=session('host')
host.show_screen(0)
host.env.update(.01)
assert(host.surface and not up(host),'The panel exists and is down on the ship')
frame(host,'ship',.01)
check_garbage(host,'ship',.01)
host.show_screen(2)
frame(host,'mission',.01)
check_garbage(host,'mission',.01)

-- War table: the hosted mission's forecast is up; steady and refresh frames.
host.show_screen(15)
for _=1,3 do host.env.update(.11) end
assert(up(host) and status(host):find('^visible map'),status(host))
local model=host.surface.model
frame(host,'map_steady',.01)
frame(host,'map_refresh',.5)
check_garbage(host,'map_steady',0)
check_garbage(host,'map_refresh',.5)
assert(host.surface.model==model,'An unchanged refresh keeps the drawn report')

-- Waiting for mission data with the panel up (the loaded mission differs from
-- the highlighted one): the panel keeps its frame and captions.
local loaded=host.space.pointer(host.controller+8)
host.space.put(host.controller+8,word(loaded%4294967296+1))
host.env.update(.01)
local pending=host.surface.model
assert(up(host) and pending.signature=='pending' and status(host):find('^waiting for mission data'),status(host))
frame(host,'waiting',.01)
check_garbage(host,'waiting',.01)
assert(host.surface.model==pending,'Waiting frames reuse the pending model')
host.space.put(host.controller+8,word(loaded%4294967296))
host.env.update(.01)
assert(up(host) and host.surface.model.signature~='pending' and status(host):find('^visible map'),status(host))

-- A headline wider than the box scrolls: hold, move, hold, reset. Measured
-- after two whole cycles, once every window of it has been cut.
host.long_headline()
host.env.update(.5)
local scrolling=host.surface.scroll
assert(scrolling and scrolling.travel>0,'The long headline scrolls')
for _=1,1500 do host.env.update(.016) end
while not (host.surface.scroll.offset==0 and host.surface.scroll.time<1) do host.env.update(.016) end
frame(host,'scroll_holding',.016)
while host.surface.scroll.offset==0 do host.env.update(.016) end
frame(host,'scroll_moving',.016)
check_garbage(host,'scroll_moving',.016)
host.long_headline(false)

-- Briefing: the same mission through the briefing owner.
host.show_screen(14)
for _=1,3 do host.env.update(.11) end
assert(up(host) and status(host):find('^visible briefing'),status(host))
frame(host,'briefing_steady',.01)
frame(host,'briefing_refresh',.5)
check_garbage(host,'briefing_steady',0)
check_garbage(host,'briefing_refresh',.5)
-- Loadout: the briefing panel hides; the first frame destroys the GUI.
host.space.put(host.owner+8,word(1))
frame(host,'hiding',.01)
assert(not up(host),'Loadout hides the forecast')
frame(host,'loadout',.01)
check_garbage(host,'loadout',.01)
assert(host.env.EnemyIntelligence.failures==0)

-- A client hovering another squad's joinable mission on the war table.
local client=session('client')
client.show_screen(15)
for _=1,3 do client.env.update(.11) end
assert(up(client) and status(client):find('^visible map'),status(client))
frame(client,'client_steady',.01)
frame(client,'client_refresh',.5)
check_garbage(client,'client_steady',0)
check_garbage(client,'client_refresh',.5)
assert(client.env.EnemyIntelligence.failures==0)

if not measure then
    print('PASS: real panel per frame: 3 engine calls while up (world list, main world, window size), 5 more on a '
        ..'moving headline, none while hidden; no garbage, interpreted or compiled, on the ship, in missions, '
        ..'on the war table (host and client), waiting, scrolling, briefing and loadout')
end
