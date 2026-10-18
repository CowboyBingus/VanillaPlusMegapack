-- The idle gate (install.lua `idle`, mission.lua `quiet`) and the panel's
-- skipped re-clear, against the published v4.1 code.
-- 1. Equivalence: the v4.1 installer, mission reader and panel (copied under
--    tests/reference/) and the new ones run side by side, each with the real
--    panel over an engine fake, through the same scripted frames: ship and
--    mission idle, the war table and briefing (host and client), loadout,
--    screen changes every few frames, transient pending states, genuine
--    errors, a failing game update below (pause and resume), spawn weights,
--    a scrolling headline and, last, a stop after 8 errors. After every frame
--    everything the mod shows or reports must be equal: the update's results,
--    the status and counters, the guard's status, every engine call, printed
--    lines, log writes and the drawn model. Only the read count may differ.
-- 2. The gate's reads, pinned exactly: 1 per quiet frame, the full 2-read
--    check every 30th frame.
-- 3. The one intended difference: a UI manager replaced while its old screen
--    stack still reads as neither screen is seen at the next full check, so
--    the panel can appear up to 30 frames late.
local source=assert(arg[1])
local tests=source..'/../tests/'
local harness=assert(loadfile(tests..'session.lua'))()
local H=harness(source)
local R=harness(source,{install=tests..'reference/install.lua',mission=tests..'reference/mission.lua',
    panel=tests..'reference/panel.lua'})
local word,qword=H.word,H.qword

-- A session with the real panel, its printed lines and log writes recorded.
local function session(h,kind)
    local engine,counts=h.engine()
    local s=h.session(kind,engine)
    s.engine,s.engine_counts,s.printed,s.logged=engine,counts,{},{}
    s.env.print=function(line) s.printed[#s.printed+1]=line end
    local log={}
    function log:write(line) s.logged[#s.logged+1]=line end
    function log:close() s.logged[#s.logged+1]='<close>' end
    s.env.CowboyBingusModLoader={open_log=function() return log end}
    s.resolution=engine.Gui.resolution
    return s
end
local function reads(s) return s.counts.read or 0 end

-- Error texts name the raising file and line, which differ between the copies.
local function plain(v)
    if type(v)~='string' then return v end
    return (v:gsub('[^%s]*%.lua:%d+: ',''))
end
local FIELDS={'status','frames','reads','failures','pending','key','screen','complete'}
local GUARD={'state','errors','lower_errors','pauses','first_error','burst_error','first_failure','stop_error'}
local function same_list(a,b,what,where)
    assert(#a==#b,where..': '..what..' count '..#a..' vs '..#b)
    for i=1,#a do assert(plain(a[i])==plain(b[i]),where..': '..what..' '..i..': '..tostring(a[i])..' vs '..tostring(b[i])) end
end
local function compare(new,old,where)
    local a,b=new.env.EnemyIntelligence,old.env.EnemyIntelligence
    for _,field in ipairs(FIELDS) do
        assert(plain(a[field])==plain(b[field]),where..': '..field..' '..tostring(a[field])..' vs '..tostring(b[field]))
    end
    for _,field in ipairs(GUARD) do
        assert(plain(a.guard[field])==plain(b.guard[field]),where..': guard '..field..' '..tostring(a.guard[field])..' vs '
            ..tostring(b.guard[field]))
    end
    for name,n in pairs(old.engine_counts) do
        assert(new.engine_counts[name]==n,where..': engine '..name..' '..tostring(new.engine_counts[name])..' vs '..n)
    end
    for name in pairs(new.engine_counts) do assert(old.engine_counts[name],where..': engine '..name..' only new') end
    same_list(new.printed,old.printed,'printed',where)
    same_list(new.logged,old.logged,'log',where)
    local p,q=new.surface,old.surface
    assert((p.gui~=nil)==(q.gui~=nil) and (p.model and p.model.signature)==(q.model and q.model.signature)
        and (p.geometry~=nil)==(q.geometry~=nil) and (p.scroll and p.scroll.offset)==(q.scroll and q.scroll.offset),
        where..': drawn panel differs')
end

-- One frame on both; the update's results (or its error) must match.
local frames_run=0
local function step(pair,dt,where)
    local ok1,a1,a2=pcall(pair.new.env.update,dt)
    local ok2,b1,b2=pcall(pair.old.env.update,dt)
    assert(ok1==ok2 and a1==b1 and a2==b2,where..': update results differ')
    compare(pair.new,pair.old,where)
    frames_run=frames_run+1
end
local DTS={.016,.0167,.033,.016,.1,.016,.5,.0083}
local function run(pair,n,label)
    for i=1,n do step(pair,DTS[(frames_run+i)%#DTS+1],label..' frame '..i) end
end
local function both(pair,fn) fn(pair.new) fn(pair.old) end

-- Host -----------------------------------------------------------------------------
local host={new=session(H,'host'),old=session(R,'host')}
both(host,function(s) s.show_screen(0) end)
run(host,300,'ship')
both(host,function(s) s.show_screen(15) end)
run(host,150,'war table')
both(host,function(s) s.show_screen(0) end)
run(host,90,'ship again')
both(host,function(s) s.show_screen(2) end)
run(host,240,'mission')
both(host,function(s) s.show_screen(14) end)
run(host,150,'briefing')
both(host,function(s) s.space.put(s.owner+8,word(1)) end)
run(host,30,'loadout')
both(host,function(s) s.space.put(s.owner+8,word(0)) end)
run(host,60,'briefing again')
both(host,function(s) s.show_screen(0) end)
run(host,45,'ship before unreadable stack')
both(host,function(s) s.space.readable(s.screen_state,24,false) end)
run(host,20,'unreadable screen stack')
both(host,function(s) s.space.readable(s.screen_state,24,true) end)
run(host,60,'readable screen stack')
-- Screens changing every few frames, in and out of the gate's window.
for i,n in ipairs({7,31,3,29,30,1,45,2,60,13}) do
    both(host,function(s) s.show_screen(i%2==1 and 15 or 0) end)
    run(host,n,'switching '..i)
end
both(host,function(s) s.show_screen(15) s.long_headline() end)
run(host,240,'scrolling headline')
both(host,function(s) s.long_headline(false) end)
run(host,60,'headline back')
-- Pending states with the panel up, then on the ship.
local loaded=host.new.space.pointer(host.new.controller+8)
both(host,function(s) s.space.put(s.controller+8,word(loaded%4294967296+1)) end)
run(host,40,'waiting for mission data')
both(host,function(s) s.space.put(s.controller+8,word(loaded%4294967296)) end)
run(host,40,'mission data back')
both(host,function(s) s.space.put(s.game+0x3326e68,qword(0)) end)
run(host,25,'no menu manager')
both(host,function(s) s.space.put(s.game+0x3326e68,qword(s.manager)) end)
run(host,25,'menu manager back')
both(host,function(s) s.space.put(s.game+0x3772268,qword(0)) end)
run(host,25,'font not ready')
both(host,function(s) s.space.put(s.game+0x3772268,word(0xc5d17df2)..word(0xb56d2aba)) end)
run(host,25,'font back')
-- A failing game update below: on the war table, then while quiet on the ship.
both(host,function(s) s.lower_raises=true end)
run(host,3,'update below fails on the war table')
both(host,function(s) s.lower_raises=false end)
run(host,90,'update below clean again')
both(host,function(s) s.show_screen(0) end)
run(host,40,'ship before the update below fails')
both(host,function(s) s.lower_raises=true end)
run(host,2,'update below fails on the ship')
both(host,function(s) s.lower_raises=false end)
run(host,100,'resumed on the ship')
-- Genuine errors: three in a burst, then clean.
both(host,function(s) s.show_screen(15) end)
run(host,30,'war table before errors')
both(host,function(s) s.engine.Gui.resolution=function() error('window size unavailable',0) end end)
run(host,3,'genuine errors')
both(host,function(s) s.engine.Gui.resolution=s.resolution end)
run(host,60,'errors cleared')
-- Spawn weights change the report.
both(host,function(s) s.add_weights() end)
run(host,120,'spawn weights')
both(host,function(s) s.show_screen(2) end)
run(host,600,'long mission')

-- Client: a joinable mission on the war table.
local client={new=session(H,'client'),old=session(R,'client')}
for _,phase in ipairs({{0,200},{15,200},{0,120},{2,300},{15,100},{0,61}}) do
    both(client,function(s) s.show_screen(phase[1]) end)
    run(client,phase[2],'client screen '..phase[1])
end

-- Last: 8 genuine errors in a burst stop both; the stopped mods do nothing.
both(host,function(s) s.show_screen(15) end)
run(host,10,'war table before the stop')
both(host,function(s) s.space.put(s.board+0x4168d0+26,word(300):sub(1,2)) end)
run(host,8,'errors until the stop')
assert(host.new.env.EnemyIntelligence.status:find('^stopped after: 8 errors: '),'8 errors stop the mod')
both(host,function(s) s.show_screen(0) end)
run(host,60,'stopped')
assert(frames_run>=3000,'at least 3000 compared frames: '..frames_run)
local saved,v41=reads(host.new)+reads(client.new),reads(host.old)+reads(client.old)

-- Reads per frame through the gate ---------------------------------------------
local s=session(H,'host')
local budget=H.budget
s.show_screen(0)
s.env.update(.016)
local per={}
for i=1,90 do per[i]=budget.frame(s.counts,s.env.update,.016).read or 0 end
-- The first gated frame after the full frame is 1; the 30th of a window is the
-- full check (2 reads), so frames 30, 60 and 90 read 2 and all others 1.
for i=1,90 do assert(per[i]==(i%30==0 and 2 or 1),'ship frame '..i..': '..per[i]..' reads') end
s.show_screen(2)
for i=1,60 do
    local n=budget.frame(s.counts,s.env.update,.016).read or 0
    assert(n==1 or n==2,'mission frame '..i..': '..n..' reads')
end
-- The frame the war table opens: the gate's read sees it, then the full frame
-- runs with v4.1's reads (69: screen, panel, language, first sample).
local function opening(h)
    local o=session(h,'host')
    o.show_screen(0)
    for _=1,10 do o.env.update(.016) end
    o.show_screen(15)
    return budget.frame(o.counts,o.env.update,.11).read
end
local opened,opened_v41=opening(H),opening(R)
assert(opened_v41==69 and opened==1+opened_v41,'opening frame: '..opened..' reads, v4.1 '..opened_v41)

-- No trace start in the mod's own files (src/, or the v4.1 copies) aborts on
-- idle frames: on the ship, in a mission, and on the ship again after the war
-- table (traces started on its active frames, or in the first 5 frames after
-- a screen change, are not counted). v4.1 aborted there every time a
-- start got hot: the hidden frame's pairs loops and the returns into the
-- guard's pcall. Starts in the test's fake reader are not the mod's.
local function idle_aborts(h)
    local util=require('jit.util')
    local i=session(h,'host')
    local starts,aborts,counting={},0,true
    local function watch(what,trace,func)
        if what=='start' then
            local file=util.funcinfo(func).source or ''
            starts[trace]=counting and (file:match('/src/[%w_]+%.lua$')~=nil or file:match('/reference/[%w_]+%.lua$')~=nil)
        elseif what=='abort' and starts[trace] and counting then
            aborts=aborts+1
        end
    end
    jit.flush() -- lint-ok: R5 test only: starts the count from an empty cache
    jit.attach(watch,'trace') -- lint-ok: R5 test only: counts aborted trace starts
    for _,phase in ipairs({{0,3000},{2,3000},{15,300},{0,1000}}) do
        i.show_screen(phase[1])
        for k=1,phase[2] do
            counting=phase[1]~=15 and k>5
            i.env.update(.016)
        end
    end
    jit.attach(watch) -- lint-ok: R5 test only: detaches the recorder
    return aborts
end
local aborts,aborts_v41=idle_aborts(H),idle_aborts(R)
assert(aborts==0 and aborts_v41>0,'aborted trace starts in the mod on idle frames: '..aborts..', v4.1 '..aborts_v41)

-- The intended difference: a replaced UI manager ------------------------------------
local function replaced(h)
    local r=session(h,'host')
    r.show_screen(0)
    for _=1,40 do r.env.update(.016) end
    local other=0x7c000000
    r.space.put(other+0x429c,word(15)..string.rep('\0',16)..word(1))
    r.space.put(r.game+0x347ce28,qword(other))
    local n=0
    while not r.env.EnemyIntelligence.status:find('^visible') do
        r.env.update(.11)
        n=n+1
        assert(n<=40,'the panel never appeared')
    end
    return n
end
local late,now=replaced(H),replaced(R)
assert(now==1 and late>=1 and late<=30,'panel after a replaced manager: '..late..' frames, v4.1 '..now)

print(string.format('PASS: %d frames side by side with v4.1 (host and client; idle, war table, briefing, '
    ..'loadout, screen changes, pending states, errors, a failing update below, a stop): every output equal, '
    ..'reads %d -> %d; gate: 1 read per quiet frame, 2 every 30th; a replaced UI manager is seen within 30 frames '
    ..'(here %d); idle aborted trace starts %d -> 0',frames_run,v41,saved,late,aborts_v41))
