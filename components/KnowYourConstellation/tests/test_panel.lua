local source=assert(arg[1])
local T=assert(loadfile(source..'/bingus_text.lua'))()
local panel=assert(loadfile(source..'/panel.lua'))(T)
local model=assert(loadfile(source..'/model.lua'))()
local english=assert(loadfile(source..'/../locales/en.lua'))()
T.registry().game_language='en'
local tr=T.new(english)
local roster=assert(loadfile(source..'/roster.lua'))()
local data=assert(loadfile(source..'/roster_data.lua'))()
local width,height=3440,1440
local main,overlay={},{}
local worlds={main,overlay}
local created,destroyed,measured,calls=0,0,0,0
local rects,texts={},{}
local engine={Application={},World={},Gui={},Material={},Vector2={},IdString64={}}
setmetatable(engine.Vector2,{__call=function(_,x,y) return {x=x,y=y} end})
engine.Vector2.x=function(v) return v.x end
engine.Vector3=function(x,y,z) return {x=x,y=y,z=z} end
engine.Color=function(a,r,g,b) return {a=a,r=r,g=g,b=b} end
engine.IdString64.from_hex=function(hash) return {hash=hash} end
engine.Application.main_world=function() return main end
engine.Application.worlds=function() return worlds end
engine.Gui.resolution=function() return width,height end
engine.World.create_screen_gui=function(w)
    assert(w==overlay)
    created=created+1
    rects,texts={},{}
    return {}
end
engine.World.destroy_gui=function(w,g) assert(w==overlay and g) destroyed=destroyed+1 end
engine.Gui.material=function(g,m)
    assert(m.hash=='9f85b87d3ff20cbb')
    g.ink={scalars={}}
    return g.ink
end
engine.Material.set_scalar=function(m,key,value) m.scalars[key.hash]=value end
engine.Material.set_vector2=function(m,key,value)
    assert(key.hash=='e13777ce00000000' and value.x==1 and value.y==-1)
    m.range=true
end
engine.Material.set_vector4=function(m,key,value)
    assert(key.hash=='7701209e00000000' and value.a==0)
    m.shadow=true
end
engine.Material.set_texture=function(m,key,value)
    assert(key.hash=='88bac99b00000000' and value.hash=='d1ebb991c79f934b')
    m.atlas=true
end
-- Proportional test font: CJK characters are a full em, Latin letters narrower.
local function span(text,size)
    local n,i=0,1
    while i<=#text do
        local v,after=T.decode(text,i)
        assert(v,'Measured text is not valid UTF-8')
        local c=v<128 and string.char(v) or ''
        n=n+size*(v>=0x2E80 and 1 or c=='W' and .9 or c=='I' and .25 or c==' ' and .3 or .55)
        i=after
    end
    return n
end
engine.Gui.text_extents=function(g,text,font,size)
    measured=measured+1
    assert(font.hash=='b56d2abac5d17df2')
    return {x=-.08*size},{x=span(text,size)+.04*size},{x=span(text,size)}
end
local function rectangle(pos,size,colour)
    calls=calls+1
    assert(pos.x>=0 and pos.y>=0 and pos.x+size.x<=width+1 and pos.y+size.y<=height+1,'Rectangle outside the screen')
    return {p=pos,s=size,c=colour}
end
engine.Gui.rect=function(g,p,s,c) rects[#rects+1]=rectangle(p,s,c) return #rects end
engine.Gui.update_rect=function(g,id,p,s,c) rects[id]=rectangle(p,s,c) end
local function text(g,value,font,size,material,pos,colour)
    calls=calls+1
    T.display(value)
    assert(g.ink.atlas and g.ink.range and g.ink.shadow)
    for _,hash in ipairs({'8035c266','5e8455fe','309e7783','82b803a8'}) do assert(g.ink.scalars[hash..'00000000']==0) end
    assert(font.hash=='b56d2abac5d17df2' and material.hash=='9f85b87d3ff20cbb')
    assert(pos.x>=0 and pos.y>=0 and pos.y+size<=height and pos.x+span(value,size)<=width+1,'Text outside the screen')
    return {value=value,size=size,p=pos,c=colour}
end
engine.Gui.text=function(...) texts[#texts+1]=text(...) return #texts end
engine.Gui.update_text=function(g,id,...) texts[id]=text(g,...) end

local function anchor(frame_height,screen)
    local s=math.min(width/1920,height/1080)
    local h=(frame_height or 489)*s
    return {x=(width-math.min(width,height*16/9))/2+54*s,y=height-139*s-h,w=533*s,h=h,
        scale=s,font='b56d2abac5d17df2',material='9f85b87d3ff20cbb',atlas='d1ebb991c79f934b',screen=screen or 'map'}
end
local function report(faction,tags,difficulty,screen)
    local snapshot={key=table.concat(tags,',')..'@'..difficulty,screen=screen or 'map',faction=faction,
        tags=tags,difficulty=difficulty}
    return model.make(snapshot,roster.compute(data,snapshot),data,tr)
end
local function visible(surface)
    local parts={}
    for _,id in ipairs(surface.text_ids) do
        if texts[id].value~='' then parts[#parts+1]=texts[id].value end
    end
    return table.concat(parts,' '):gsub('%s+',' ')
end
local function enemies(m)
    local names={}
    for _,entry in ipairs(m.large) do names[#names+1]=entry.text end
    for _,name in ipairs(m.small) do names[#names+1]=name end
    return names
end
-- Exact enemy names drawn by the current plan, plus the "and N more" count.
-- List lines are rejoined first because a name can wrap across two lines.
local function listed(surface)
    local names,more,section,list={},0,nil,{}
    for _,item in ipairs(surface.geometry.plan.items) do
        if item.kind=='text' then
            local count=item.text:match('^and (%d+) more$')
            if item.text==tr('panel.large') then section='large'
            elseif item.text==tr('panel.small') then section='small'
            elseif item.role=='body' and section=='large' and not count then names[item.text]=true
            elseif item.role=='body' and section then list[#list+1]=item.text end
        end
    end
    for part in (table.concat(list,' ')..', '):gmatch('(.-), ') do
        local count=part:match('^and (%d+) more$')
        if count then more=tonumber(count) elseif part~='' then names[part]=true end
    end
    return names,more
end
local function below_region(a)
    -- Everything hangs below the native panel, above the prompt row, on a high layer.
    local s=a.scale
    for _,id in ipairs(surfaceref.rect_ids) do
        local r=rects[id]
        if r.s.x>0 then
            -- Above the squad nameplates (above 1000); only 0-1023 sort correctly.
            assert(r.p.z>1000 and r.p.z<=1023,'Forecast drawn outside the layers above the squad list')
            assert(r.p.x>=a.x-.001 and r.p.x+r.s.x<=a.x+a.w+.001,'Panel escaped the native width')
            assert(r.p.y>=panel.BOTTOM*s-.001 and r.p.y+r.s.y<=a.y+panel.BORDER*s+.001,
                'Panel covered the native panel or the prompt row')
        end
    end
    local scrolling=surfaceref.scroll and surfaceref.scroll.id
    for _,id in ipairs(surfaceref.text_ids) do
        local t=texts[id]
        if t.value~='' then
            assert(t.p.z>1000 and t.p.z<=1023,'Text drawn outside the layers above the squad list')
            -- A scrolling headline may enter the side padding, under the masks.
            local left,right=a.x,a.x+a.w-panel.PAD*s+1
            if id==scrolling then left,right=a.x+panel.INSET*s-.001,a.x+a.w-panel.INSET*s+.001 end
            assert(t.p.x>=left and t.p.x+span(t.value,t.size)<=right,'Text escaped the panel')
            assert(t.p.y>=panel.BOTTOM*s and t.p.y+t.size<=a.y,'Text left the panel')
        end
    end
end
local function clear_of_meters(plan,s)
    -- Every large-enemy name ends before its meter.
    for i,item in ipairs(plan.items) do
        if item.kind=='meter' then
            local name=plan.items[i-1]
            assert(name.kind=='text' and span(name.text,name.size)<=item.x-2*panel.GAP*s+.001,'Name runs into its meter')
        end
    end
end
local function even_ticks(a)
    -- Ticks sit on whole pixels with identical widths and gaps (fractional
    -- sizes round to uneven gaps); each meter ends at the column's right edge.
    local s,row=a.scale,{}
    local tick,gap=panel.tick_pixels(s)
    local right=a.x+a.w-panel.PAD*s
    for _,id in ipairs(surfaceref.rect_ids) do
        local r=rects[id]
        if r.s.x>0 and r.p.z==panel.LAYER.content then
            row[#row+1]=r
            if #row==panel.TICKS then
                for k,t in ipairs(row) do
                    assert(t.p.x==math.floor(t.p.x) and t.p.y==math.floor(t.p.y) and t.s.y==math.floor(t.s.y),
                        'Ticks sit on whole pixels')
                    assert(t.s.x==tick and t.s.y==row[1].s.y and t.p.y==row[1].p.y,'Ticks in a row are identical')
                    if k>1 then assert(t.p.x-row[k-1].p.x==tick+gap,'Every gap is the same width') end
                end
                assert(math.abs(row[#row].p.x+tick-right)<=.5,'Meters end at the column edge')
                row={}
            end
        end
    end
    assert(#row==0,'Meters have ten ticks')
end
local function meters()
    -- Count the filled ticks of each meter row, in drawing order.
    local rows,current={},nil
    for _,id in ipairs(surfaceref.rect_ids) do
        local r=rects[id]
        if r.s.x>0 and r.p.z==panel.LAYER.content then
            if not current or #current.ticks==panel.TICKS then current={ticks={}} rows[#rows+1]=current end
            current.ticks[#current.ticks+1]=r.c.r==240
        end
    end
    local filled={}
    for i,row in ipairs(rows) do
        local n=0
        for _,on in ipairs(row.ticks) do if on then n=n+1 end end
        filled[i]=n
    end
    return filled
end

local cases={
    {3,{15,22},8},{3,{18},8},{3,{15,19},10},{3,{17,20},10},{3,{14},3},
    {2,{1},10},{2,{6,11,23},9},{2,{5,9,11},8},{2,{3,8},8},{2,{2,10},10},{2,{},1},
    {4,{27},8},{4,{26},8},{4,{29},8},{4,{28},8},
}
surfaceref=panel.new(engine)
local surface=surfaceref
for _,res in ipairs({{1280,720},{1920,1080},{2560,1440},{3440,1440},{5120,1440},{1280,1024}}) do
    width,height=unpack(res)
    for _,frame in ipairs({489,371}) do
        local a=anchor(frame)
        surface:clear()
        for _,case in ipairs(cases) do
            local m=report(unpack(case))
            assert(surface:show(m,0,a),'Forecast not drawn')
            assert(not surface.geometry.place.side,'War-table forecasts hang below the native panel')
            below_region(a)
            local shown=visible(surface)
            assert(shown:find(tr('panel.label'),1,true) and shown:find(tr('panel.footer'),1,true))
            local names,more=listed(surface)
            local missing=0
            for _,name in ipairs(enemies(m)) do
                if not names[name] then missing=missing+1 end
            end
            assert(missing==more,'Every enemy must be named or counted in "and N more"')
            assert(more==0,'Below the native panel every enemy fits')
            local filled=meters()
            for i=1,#filled do assert(filled[i]==m.large[i].ticks,'Meter ticks differ from the report') end
            clear_of_meters(surface.geometry.plan,a.scale)
            even_ticks(a)
        end
        -- Static forecasts make no GUI calls at all.
        local m=report(3,{15,22},8)
        surface:show(m,0,a)
        local before_created,before_measured,before_calls=created,measured,calls
        for _=1,120 do surface:show(m,1/60,a) end
        assert(created==before_created and measured==before_measured and calls==before_calls,
            'Unchanged forecasts must not redraw or remeasure')
        -- A new report with identical content does not redraw either.
        local same=report(3,{22,15},8)
        surface:show(same,0,a)
        assert(calls==before_calls,'Identical content must not redraw')
        -- Pending keeps the panel but drops enemy text; the GUI is reused.
        local saved=surface.gui
        surface:suspend(a)
        local pending=visible(surface)
        assert(surface.gui==saved and pending:find(tr('panel.label'),1,true) and not pending:find('War Striders',1,true))
        surface:show(m,0,a)
        assert(visible(surface):find('War Striders',1,true) and surface.gui==saved)
        -- Native movement redraws without remeasuring.
        local measured_before=measured
        a.x=a.x+3
        surface:show(m,0,a)
        below_region(a)
        assert(measured==measured_before,'Native movement must reuse the cached plan')
        surface:clear()
        assert(not surface.gui and not surface:suspend(a),'Closed panels cannot retain or recreate chrome')
    end
end

-- Briefing: attached below the native panel, or beside it when too tall.
width,height=1920,1080
local b=anchor(360,'briefing')
local m=report(3,{15,22},8,'briefing')
assert(surface:show(m,0,b) and not surface.geometry.place.side)
local place=surface.geometry.place
assert(math.abs(place.y+place.h-(b.y+panel.BORDER*b.scale))<.001,'The box shares the native bottom border')
-- The native frame's dark gap: the opaque body starts 7 units in, 4 units
-- inside the 3-unit gold outline, on every side.
do
    local s,body,outline=b.scale,nil,0
    for _,id in ipairs(surface.rect_ids) do
        local r=rects[id]
        if r.s.x>0 and r.p.z==panel.LAYER.body then body=r end
        -- Rules share the outline's layer; the outline is the gold strokes.
        if r.s.x>0 and r.p.z==panel.LAYER.border and r.c.r==255 and r.c.g==185 then
            outline=outline+1
            assert(math.min(r.s.x,r.s.y)==3*s,'The outline is 3 units of gold')
        end
    end
    assert(outline==4 and body)
    assert(math.abs(body.p.x-(place.x+7*s))<.001 and math.abs(body.p.y-(place.y+7*s))<.001
        and math.abs(body.s.x-(place.w-14*s))<.001 and math.abs(body.s.y-(place.h-14*s))<.001,
        'The body sits 4 units inside the outline')
    assert(body.c.r==panel.BODY[1] and body.c.g==panel.BODY[2] and body.c.b==panel.BODY[3] and body.c.a==255)
end
local shown=visible(surface)
for _,name in ipairs(enemies(m)) do assert(shown:find(name,1,true),'Briefing must list '..name) end
b.y=40*b.scale
assert(surface:show(m,0,b) and surface.geometry.place.side,'No room below: the panel moves beside the native frame')

-- A native panel ending near the prompt row leaves no room below: beside it.
local low=anchor()
low.y=90*low.scale
assert(surface:show(report(2,{1},10),0,low) and surface.geometry.place.side)

-- Headlines with several modifiers stay inside the frame.
width,height=1280,720
local a=anchor(371)
m=report(2,{6,11,12,23,31},9)
assert(m.headline=='DRAGONROACH ACTIVITY // ROVING SHRIEKERS // HIVE WORLD // HORDE // BUG NURSERY')
surface:show(m,0,a)
below_region(a)

-- Plans: very small areas cut the lists and count what was left out.
local measure=function(value,size) return span(value,size) end
local big=report(3,{15,22},8)
assert(not panel.fit(big,measure,480,150,1),'Below the panel nothing is cut')
local plan=panel.fit(big,measure,480,150,1,true)
assert(plan and plan.size==12)
local cut_lines=0
for _,item in ipairs(plan.items) do
    if item.kind=='text' and item.text:find('and %d+ more') then cut_lines=cut_lines+1 end
end
assert(cut_lines==1,'Cut lists end with one "and N more" line')
assert(panel.fit(big,measure,480,2000,1).size==panel.SIZES[1],'Roomy frames use the full text size')
-- Balanced padding: the plan ends as far below the footer's baseline as the
-- label's capitals start below the top.
do
    local roomy=panel.fit(big,measure,480,2000,1)
    local footer=roomy.items[#roomy.items]
    assert(footer.kind=='text' and footer.text==big.footer)
    assert(math.abs(roomy.height-(footer.d+panel.TITLE*(1-panel.CAP)))<1e-9,'Bottom padding mirrors the top')
end
assert(not pcall(panel.wrap,'x',0,function() return 1 end))
local wrapped=panel.wrap(string.rep('W',80),40,function(value) return #value*10 end)
assert(table.concat(wrapped)==string.rep('W',80),'Long tokens must wrap without losing characters')

-- The UI world can change or disappear.
a=anchor()
surface:show(report(2,{1},10),0,a)
overlay={}
worlds={main,overlay}
surface:show(report(2,{3},10),0,a)
assert(visible(surface):find('Pouncers',1,true))
worlds={main}
assert(not surface:show(report(2,{3},10),0,a) and not surface.gui)
assert(destroyed>0)
print('PASS: forecast box below the native panel at six resolutions, every enemy named, high draw layer, meter ticks, no redraw when static, pending, briefing and side placement, font fallback and world changes')

-- The real installer, roster and renderer together through menu transitions.
worlds={main,overlay}
width,height=2560,1440
local screen,key,ready,complete,hovered='map','hosted',true,true,true
local native=anchor()
local sample_tags={15,22}
local reader={}
function reader:screen() return screen end
function reader:descriptor() return {key=key,screen=screen,controller_matches=true},hovered end
function reader:sample()
    return {key=key,screen=screen,faction=3,tags=sample_tags,difficulty=8,complete=complete,controller_matches=true}
end
local expected=report(3,{15,22},8)
local function complete_forecast()
    local names,more=listed(surface)
    if more~=0 then return false end
    for _,name in ipairs(enemies(expected)) do if not names[name] then return false end end
    return true
end
local env=setmetatable({stingray=engine,print=function() end,os={}}, {__index=_G})
env._G=env
env.update=function() end
local install=assert(loadfile(source..'/install.lua'))()
surface:clear()
setfenv(install,env)({create_api=function() return {module=function() return 1 end} end,
    mission={new=function() return reader end},resolve={},roster=roster,roster_data=data,model=model,
    panel={new=function() return surface end},
    presentation={new=function() return {sample=function() native.screen=screen return ready and native or nil end} end},
    text=T,locales={en=english,bundled={}},runtime=assert(loadfile(source..'/bingus_runtime.lua'))(),
    runtime_memory={new=function() return {verify_build=function() return true end} end},
    build={revision='panel-test',game_sha256='supported',exe_sha256='supported'}})
env.update(.01)
assert(surface.gui and not surface.geometry.place.side and complete_forecast())
local saved_gui=surface.gui
key,complete='new-hosted',false
env.update(.01)
assert(surface.gui==saved_gui and not visible(surface):find('War Striders',1,true),
    'Pending missions must blank the enemies without recreating the panel')
complete=true
env.update(.101)
assert(surface.gui==saved_gui and complete_forecast())
screen,ready='briefing',false
env.update(0)
assert(not surface.gui,'Pod entry must hide the forecast')
ready=true
env.update(.01)
assert(surface.gui and not surface.geometry.place.side and complete_forecast(),
    'Ready briefing must show the attached forecast immediately')
ready=false
env.update(0)
assert(not surface.gui,'Loadout must hide the forecast')
screen,key,ready='map','joinable',true
native.client,native.active=true,true
env.update(.01)
assert(surface.gui)
hovered=false
env.update(0)
assert(not surface.gui,'Client unhover must remove the forecast on the same frame')
env.update(.5)
assert(not surface.gui,'A dismissed forecast cannot reappear from a refresh')
hovered=true
env.update(.01)
assert(surface.gui and complete_forecast())

-- The panel's own waits, each held for 10,000 frames: engine resources that
-- are not there yet and a window or native panel the box cannot fit yet.
-- Hidden with the reason, never counted toward a stop, back once it clears.
-- `fresh` waits need a new GUI or new plans, as after a screen change.
local state=env.EnemyIntelligence
local long_headline=model.headline({19,20,21,22,15},tr)
local function swap(owner,name,value)
    local saved=owner[name]
    owner[name]=value
    return function() owner[name]=saved end
end
local waits={
    {'UI worlds unavailable',true,function() return swap(engine.Application,'worlds',function() return nil end) end},
    {'Could not create forecast panel',true,function()
        return swap(engine.World,'create_screen_gui',function() return nil end) end},
    {'Font material unavailable',true,function() return swap(engine.Gui,'material',function() return nil end) end},
    {'Font metrics unavailable',true,function() return swap(engine.Gui,'text_extents',function() return nil end) end},
    {'Font caret unavailable',false,function()
        -- A headline that scrolls needs a caret per character; prefixes get none.
        local measure=engine.Gui.text_extents
        local restore=swap(engine.Gui,'text_extents',function(g,value,font,size)
            local lo,hi,caret=measure(g,value,font,size)
            if #value<#long_headline and long_headline:sub(1,#value)==value then caret=nil end
            return lo,hi,caret
        end)
        sample_tags,key={19,20,21,22,15},'long-headline'
        return function() restore() sample_tags,key={15,22},'joinable' end
    end},
    {'Retained rectangle unavailable',true,function() return swap(engine.Gui,'rect',function() return nil end) end},
    {'Retained text unavailable',true,function() return swap(engine.Gui,'text',function() return nil end) end},
    {'Native panel unavailable',false,function()
        return swap(engine.Gui,'resolution',function() return 320,200 end) end},
    {'Forecast exceeds viewport',false,function()
        local y,h=native.y,native.h
        native.y,native.h=20,30
        return function() native.y,native.h=y,h end
    end},
}
-- Waiting frames re-plan the box every frame, so the font fake's measurements
-- are remembered for the holds (the test's own speed; results unchanged).
local unmemoized=swap(engine.Gui,'text_extents',(function(measure)
    local memo={}
    return function(g,value,font,size)
        local key=size..'|'..value
        local hit=memo[key]
        if not hit then hit={measure(g,value,font,size)} memo[key]=hit end
        return hit[1],hit[2],hit[3]
    end
end)(engine.Gui.text_extents))
for _,wait in ipairs(waits) do
    local reason,fresh,cause=wait[1],wait[2],wait[3]
    if fresh then surface:clear() end
    local clear=cause()
    local pending=state.pending
    for _=1,10000 do env.update(.01) end
    assert(state.status=='hidden: '..reason,reason..': status '..state.status)
    assert(state.pending==pending+10000 and state.guard.errors==0 and state.failures==0
        and not state.guard.first_failure,reason..': a waiting frame never counts toward a stop')
    clear()
    for _=1,3 do env.update(.11) end
    assert(surface.gui and complete_forecast(),reason..': the forecast is back once it clears')
end
unmemoized()
env.shutdown()
assert(not surface.gui and env.EnemyIntelligence.failures==0)
print('PASS: installer, roster and renderer through pending, pod entry, briefing, loadout and client unhover')
print('PASS: the panel\'s '..#waits..' waits (engine resources, window size) each held for 10000 frames: '
    ..'hidden with their reason, never counted, back once cleared')

-- Scroll timing: hold at the start, move at the set speed (scaled with the
-- UI), hold at the end, then restart from the beginning.
local hold,speed=panel.SCROLL.hold,panel.SCROLL.speed
local period=hold+100/speed+panel.SCROLL.end_hold
assert(select(2,panel.scroll_offset(0,100,1))==period)
assert(panel.scroll_offset(0,100,1)==0 and panel.scroll_offset(hold-.01,100,1)==0)
assert(math.abs(panel.scroll_offset(hold+1,100,1)-speed)<1e-9)
assert(math.abs(panel.scroll_offset(hold+1,100,2)-2*speed)<1e-9)
assert(panel.scroll_offset(hold+100/speed+.01,100,1)==100)
assert(panel.scroll_offset(period+.5,100,1)==0,'The cycle restarts at the beginning')
-- Window: whole glyphs inside the visible span widened by the mask margin,
-- continuing from the previous position gives the same answer as a fresh scan.
local edges={0,10,20,30,40,50,60,70,80,90,100}
local first,last=panel.window(edges,10,0,35,5)
assert(first==1 and last==5)
first,last=panel.window(edges,10,12,35,5,first,last)
assert(first==2 and last==6 and select(2,panel.window(edges,10,12,35,5))==6)
first,last=panel.window(edges,10,65,35,5,first,last)
assert(first==7 and last==11)

-- Long headlines stay on one line at the title size and scroll like native
-- strings, with panel-coloured masks over the side padding.
width,height=2560,1440
a=anchor()
surface:clear()
m=report(2,{6,11,12,23,31},9)
assert(surface:show(m,0,a))
local heads=0
for _,item in ipairs(surface.geometry.plan.items) do
    if item.text==m.headline then
        heads=heads+1
        assert(item.kind=='scroll' and item.size==panel.TITLE*a.scale and item.travel>0)
    end
end
assert(heads==1,'The headline is one line')
local masks=0
for _,id in ipairs(surface.rect_ids) do
    local r=rects[id]
    if r.p.z==panel.LAYER.mask and r.s.x>0 then
        masks=masks+1
        assert(r.c.r==panel.BODY[1] and r.c.g==panel.BODY[2] and r.c.b==panel.BODY[3] and r.c.a==255,
            'Masks use the panel colour')
    end
end
assert(masks==2,'One mask on each side')
local sc=surface.scroll
local function drawn() return texts[sc.id] end
-- Where the headline's first glyph would be: moves left as it scrolls.
local function origin() return drawn().p.x-sc.edges[sc.first] end
assert(drawn().value:find('^DRAGONROACH') and math.abs(origin()-(a.x+panel.PAD*a.scale))<.001)
below_region(a)
local before_calls,before_measured=calls,measured
for _=1,100 do surface:show(m,1/60,a) end
assert(calls==before_calls,'A headline holding at the start makes no GUI calls')
for _=1,5 do surface:show(m,.1,a) end
before_calls=calls
local o=origin()
for _=1,60 do surface:show(m,1/60,a) below_region(a) end
assert(calls==before_calls+60,'A moving headline updates one text per frame')
assert(measured==before_measured,'Scrolling never measures text')
assert(origin()<o,'The headline moves left')
local guard=0
while sc.offset<sc.travel do
    surface:show(m,.1,a)
    below_region(a)
    guard=guard+1
    assert(guard<1000)
end
assert(drawn().value:find('BUG NURSERY$'),'The end of the headline is shown')
before_calls=calls
surface:show(m,.1,a)
assert(calls==before_calls,'A headline holding at the end makes no GUI calls')
guard=0
while sc.offset~=0 do surface:show(m,.1,a) guard=guard+1 assert(guard<100) end
assert(drawn().value:find('^DRAGONROACH'),'Headlines reset to the start')
-- Later cycles reuse the window strings: at most two per glyph ever.
for _=1,3*math.ceil(select(2,panel.scroll_offset(0,sc.travel,a.scale))*60) do surface:show(m,1/60,a) end
local strings=0
for _ in pairs(sc.windows) do strings=strings+1 end
assert(strings<=2*(T.length(m.headline)+1),'Window strings are bounded')
-- Moving the native panel redraws without remeasuring and keeps the cycle.
local t=sc.time
a.x=a.x+3
surface:show(m,0,a)
below_region(a)
assert(surface.scroll~=sc and surface.scroll.time==t and measured==before_measured)
-- Short headlines do not scroll or mask.
surface:show(report(3,{15,22},8),0,a)
assert(not surface.scroll)
for _,id in ipairs(surface.rect_ids) do assert(rects[id].p.z~=panel.LAYER.mask or rects[id].s.x==0) end
surface:clear()

-- Only the first non-main world draws on the war table: the one GUI goes
-- there, and clear destroys it.
do
    local first_main,first_ui={},{}
    local guis={}
    local e=setmetatable({Application={},World={}},{__index=engine})
    e.Application={main_world=function() return first_main end,worlds=function() return {first_main,first_ui,{}} end}
    e.World={create_screen_gui=function(w) local g={world=w} guis[#guis+1]=g return g end,
        destroy_gui=function(w,g) assert(g.world==w) g.destroyed=true end}
    local first=panel.new(e)
    assert(first:show(report(2,{1},10),0,anchor()))
    assert(#guis==1 and guis[1].world==first_ui,'The forecast lives in the first non-main world')
    first:clear()
    assert(guis[1].destroyed)
end
print('PASS: long headlines scroll on one line with masks and no idle GUI calls; one GUI in the first non-main world')

-- Chinese: every text translated into CJK characters (a full em each, no
-- spaces) with an ideographic comma between names. Every drawn string is
-- valid UTF-8 and inside the panel, every enemy is named or counted, and a
-- long headline scrolls by whole characters. v3.16 hid this panel with
-- "Invalid caret advance" because a CJK advance exceeded the side padding.
do
    local zh,n={language='zh-Hans',strings={}},0
    local function word(length)
        local parts={}
        for k=1,length do n=n+1 parts[k]=T.encode(0x4E00+(n*37)%20000) end
        return table.concat(parts)
    end
    for key,value in pairs(english.strings) do
        if key:find('^unit%.') then zh.strings[key]=word(2+#value%5)
        elseif key:find('^title%.') then zh.strings[key]=word(3+#value%4) end
    end
    zh.strings['panel.label']=word(4)..' // '..word(4)
    zh.strings['panel.footer']=word(16)
    zh.strings['panel.large'],zh.strings['panel.rate']=word(4),word(4)
    zh.strings['panel.small'],zh.strings['panel.order']=word(6),word(6)
    zh.strings['panel.more']=word(2)..' {count} '..word(1)
    zh.strings['panel.list_separator']=T.encode(0x3001)
    zh.strings['headline.separator']=' // '
    zh.strings['headline.standard']=word(4)
    local logs={}
    T.registry().game_language='zh-Hans'
    local zh_tr=T.new(english,{['zh-Hans']=zh},function(line) logs[#logs+1]=line end)
    assert(zh_tr('panel.label')==zh.strings['panel.label'] and #logs==1 and logs[1]:find('121 of 121',1,true),
        table.concat(logs,'\n'))
    local function zh_report(faction,tags,difficulty)
        local snapshot={key=table.concat(tags,',')..'@'..difficulty,screen='map',faction=faction,tags=tags,
            difficulty=difficulty}
        return model.make(snapshot,roster.compute(data,snapshot),data,zh_tr)
    end
    local function zh_listed(s)
        local names,more,section,lines={},0,nil,{}
        for _,item in ipairs(s.geometry.plan.items) do
            if item.kind=='text' then
                if item.text==zh.strings['panel.large'] then section='large'
                elseif item.text==zh.strings['panel.small'] then section='small'
                elseif item.role=='body' and section=='large' then names[item.text]=true
                elseif item.role=='body' and section=='small' then lines[#lines+1]=item.text end
            end
        end
        local more_pattern='^'..zh.strings['panel.more']:gsub('{count}','(%%d+)')..'$'
        for part in (table.concat(lines)..T.encode(0x3001)):gmatch('(.-)'..T.encode(0x3001)) do
            local count=part:match(more_pattern)
            if count then more=tonumber(count) elseif part~='' then names[part]=true end
        end
        return names,more
    end
    for _,res in ipairs({{1280,720},{1920,1080},{3440,1440}}) do
        width,height=unpack(res)
        local a=anchor(489)
        surface:clear()
        for _,case in ipairs(cases) do
            local m=zh_report(unpack(case))
            assert(surface:show(m,0,a),'Chinese forecast not drawn')
            if not surface.geometry.place.side then below_region(a) end
            local names,more=zh_listed(surface)
            local missing=0
            for _,name in ipairs(enemies(m)) do if not names[name] then missing=missing+1 end end
            assert(missing==more,'Every enemy must be named or counted in the Chinese list')
            for _,item in ipairs(surface.geometry.plan.items) do
                if item.kind=='text' then assert(T.check(item.text),'Line cut inside a character') end
            end
        end
    end
    -- A long Chinese headline scrolls: carets measured once per character,
    -- windows cut only between characters.
    width,height=1920,1080
    local a=anchor()
    surface:clear()
    local m=zh_report(2,{6,11,12,23,31},9)
    local before=measured
    assert(surface:show(m,0,a) and surface.scroll,'The Chinese headline scrolls')
    local sc=surface.scroll
    assert(#sc.edges==T.length(m.headline)+1 and #sc.bounds==#sc.edges,'One caret per character')
    assert(measured-before>=T.length(m.headline) and measured-before<#m.headline,
        'Carets are measured per character, not per byte')
    local seen,guard={},0
    repeat
        surface:show(m,.05,a)
        below_region(a)
        local value=texts[sc.id].value
        assert(T.check(value),'Scroll window cut inside a character')
        seen[value]=true
        guard=guard+1
    until (sc.offset==sc.travel and guard>10) or guard>2000
    assert(sc.offset==sc.travel,'The Chinese headline reaches its end')
    surface:clear()
    T.registry().game_language='en'
end
print('PASS: Chinese forecasts: whole characters in every line and scroll window, CJK wrapping, every enemy named or counted')
