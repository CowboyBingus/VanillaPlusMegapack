-- The update gate must not change behavior. The ungated adapter and image
-- policy (tests/reference, byte-identical to the sources before the gate) and
-- the current ones run
-- side by side on two copies of the captured Armory and briefing UI, with the
-- same scripted game changes applied to both between prune (before the game
-- update) and tick (after it). After every frame the presentation each
-- widget element shows (texture, UV, size, opacity), every native write, the
-- manager and the whole cache state must be equal, and so must they be after
-- prune (before the game update). Ungated code re-sends presentation every
-- frame; the gated version must end every frame in the same state.
local root=assert(arg[1]);local ffi=require('ffi')
local function p(n)return ffi.cast('uint8_t *',n)end
local function num(x)return type(x)=='number' and x or tonumber(ffi.cast('uintptr_t',x))end
local function u32s(v)return ffi.string(ffi.new('uint32_t[1]',v),4)end
local function ptrs(v)return ffi.string(ffi.new('uint64_t[1]',v),8)end
local function f32s(v)return ffi.string(ffi.new('float[1]',v),4)end
local function u32(s,o)return s:byte(o+1)+s:byte(o+2)*256+s:byte(o+3)*65536+s:byte(o+4)*16777216 end
local function ptr(s,o)return u32(s,o)+u32(s,o+4)*4294967296 end

local function world(fixture,version,options)
    local api,game,exe,_,memory=dofile(root..'/tests/captured_ui.lua')(root..'/tests/fixtures/ui_'..fixture..'_25327279.lua')
    local sigs=dofile(root..'/src/image_signatures.lua')
    for _,s in ipairs(sigs)do
        memory.poke((s.module=='game' and game or exe)+s.rva,s.hex:gsub('..',function(h)return string.char(tonumber(h,16))end))
    end
    memory.poke(exe+0x1658990,u32s(32))
    local w={api=api,game=num(game),memory=memory,version=version,writes={},log={},created={},names={},destroyed={},
        texture={},uv={},size={},alpha={},no_material={},texture_calls=0}
    -- A writable manager at a real address; the game global points at it.
    local captured_tm=ptr(api.read(game+0x347cd80,8),0)
    w.manager=ffi.new('uint8_t[12176]');ffi.copy(w.manager,api.read(p(captured_tm),12176),12176)
    w.m32=ffi.cast('uint32_t *',w.manager);w.tm=num(w.manager)
    memory.poke(game+0x347cd80,ptrs(w.tm));memory.map(w.tm,w.manager,12176)
    w.original=w.m32[2778]+w.m32[2779]*4294967296
    w.names[w.original]='original'
    local descriptor=api.read(p(w.original),104)
    local function canon(t)
        if t==nil then return 'nil' end
        local a=num(t);return w.names[a] or string.format('unknown:%x',a)
    end
    w.canon=canon
    local function write(address,bytes)
        w.writes[#w.writes+1]=string.format('%x',num(address))..'='..bytes:gsub('.',function(c)return string.format('%02x',c:byte())end)
        memory.poke(num(address),bytes)
    end
    w.poke=function(address,bytes)memory.poke(num(address),bytes)end
    local calls={}
    calls.create=function()
        local d=ffi.new('uint8_t[104]');ffi.copy(d,descriptor,104)
        w.created[#w.created+1]=d;d[0]=0x40+#w.created
        memory.map(num(d),d,104);w.names[num(d)]='fresh'..#w.created
        return d
    end
    calls.register=function()end
    calls.destroy=function(t)w.destroyed[#w.destroyed+1]=canon(t)end
    calls.texture=function(e,_,t)w.texture[num(e)]=canon(t);w.texture_calls=w.texture_calls+1 end
    calls.uv=function(e,a,b)w.uv[num(e)]=tostring(a)..','..tostring(b)end
    calls.size=function(e,v)w.size[num(e)]=tostring(v)end
    calls.alpha=function(e,v)w.alpha[num(e)]=v end
    -- Native material setup: a private instance, template resource cleared.
    -- With the template missing, initialization leaves no material.
    calls.material=function(e)
        if w.no_material[num(e)]then write(num(e)+328,ptrs(0));return end
        write(num(e)+328,ptrs(0x600000000000+num(e)%0x10000000))
        write(num(e)+336,ptrs(0))
    end
    calls.register_image=function(_,e)
        local n=w.m32[2784]
        for i=0,n-1 do if w.m32[2786+i*2]+w.m32[2787+i*2]*4294967296==num(e)then return end end
        w.m32[2786+n*2]=num(e)%4294967296;w.m32[2787+n*2]=math.floor(num(e)/4294967296);w.m32[2784]=n+1
        w.writes[#w.writes+1]='register '..string.format('%x',num(e))
    end
    calls.byte=function(a,v)write(a,string.char(v))end
    if version=='ungated' then
        w.adapter=dofile(root..'/tests/reference/image_native_ungated.lua').new(api,game,exe,sigs,calls)
        w.cache=dofile(root..'/tests/reference/images_ungated.lua').new(w.adapter,{})
    else
        w.adapter=dofile(root..'/src/image_native.lua').new(api,game,exe,sigs,calls)
        w.cache=dofile(root..'/src/images.lua').new(w.adapter,options or {})
    end
    -- Layout of the captured screen, for scripted changes.
    local sm=ptr(api.read(game+0x347ce28,8),0);w.stack=sm+0x429c
    local d=ptr(api.read(game+0x3326e68,8),0);local n=u32(api.read(p(d+5740),4),0)
    local rows=api.read(p(d+5744),n*16)
    for i=0,n-1 do
        local kind=u32(rows,i*16+8)
        if kind==224 or kind==229 then w.owner,w.kind=ptr(rows,i*16),kind end
    end
    w.grid=w.owner+(w.kind==229 and 864032 or 523752)
    w.meta=w.grid+597772
    w.widgets={}
    local count=u32(api.read(p(w.meta),4),0)
    for row=0,count-1 do
        local rb=w.grid+2816+row*44752
        for col=0,u32(api.read(p(rb+44724),4),0)-1 do w.widgets[#w.widgets+1]=rb+9192+col*11112 end
    end
    w.preview=ptr(api.read(game+0x347ce60,8),0)
    return w
end

local COUNTERS={'bytes','hits','misses','last_hits','last_misses','early_hits','last_early_hits','retained',
    'released','late_switches','pending_drops','ready_items','missing_ready_items','blank_ready_items',
    'rendered_items','refreshed','changed_items','reappeared','pending_items','partial_retained','idle_retained',
    'visible_retained','evicted','grid_hits','preselect_hits','briefing_hits','clear_count','widget_count',
    'named_material_widgets','ticks','status','screen','last_clear_reason'}
local function state(w)
    local out={}
    for _,k in ipairs(COUNTERS)do out[#out+1]=k..'='..tostring(w.cache[k])end
    local keys={}
    for key in pairs(w.cache.entries)do keys[#keys+1]=key end
    table.sort(keys)
    for _,key in ipairs(keys)do
        local e=w.cache.entries[key]
        out[#out+1]='entry '..key:gsub('.',function(c)return string.format('%02x',c:byte())end)..' '
            ..e.uv:gsub('.',function(c)return string.format('%02x',c:byte())end)..' '..e.width..'x'..e.height
            ..' '..w.canon(e.texture.handle)..' '..tostring(e.preview and #e.preview)
    end
    for i,t in ipairs(w.cache.textures)do
        out[#out+1]=string.format('texture %d %s %s %s used=%s %s %s',i,w.canon(t.handle),w.canon(t.replacement),
            tostring(t.bytes),tostring(t.used),tostring(t.destroyed),tostring(t.returned))
    end
    for _,section in ipairs({'texture','uv','size','alpha'})do
        local rows={}
        for e,v in pairs(w[section])do rows[#rows+1]=string.format('%s %x=%s',section,e,tostring(v))end
        table.sort(rows);for _,r in ipairs(rows)do out[#out+1]=r end
    end
    out[#out+1]='writes '..table.concat(w.log,' | ')
    out[#out+1]='destroyed '..table.concat(w.destroyed,' ')
    out[#out+1]='created '..#w.created
    -- The manager, with the working atlas pointer by name.
    local bytes=ffi.string(w.manager,12176)
    out[#out+1]='manager '..bytes:sub(1,11112):gsub('.',function(c)return string.format('%02x',c:byte())end)
        ..' atlas='..w.canon(w.m32[2778]+w.m32[2779]*4294967296)
        ..' '..bytes:sub(11121):gsub('.',function(c)return string.format('%02x',c:byte())end)
    return out
end
local function compare(a,b,label)
    local x,y=state(a),state(b)
    for i=1,math.max(#x,#y)do
        if x[i]~=y[i]then
            local a,b=tostring(x[i]),tostring(y[i])
            local at=1;while a:sub(at,at)==b:sub(at,at)do at=at+1 end
            local from=math.max(1,at-160)
            error(string.format('%s: ungated and gated differ at line %d, character %d:\n  ungated: %s\n  gated:   %s',
                label,i,at,a:sub(from,at+240),b:sub(from,at+240)))
        end
    end
end

-- Scripted game changes (identical in both worlds).
local function card(w,c,st)w.m32[(c*1816+1832)/4]=st end
local function active(w,c,phase)w.m32[11064/4]=c;w.m32[11096/4]=phase end
local function meta_u32(w,offset,v)w.poke(w.meta+offset,u32s(v))end
local function record_byte(w,k,offset,v)w.poke(w.meta+4332+k*80+offset,string.char(v))end
-- Scroll: every widget shows the record `rows` rows further, as the native
-- layout does when the grid scrolls (tails and the visible window move).
local function scroll(w,rows,first,px)
    for i,widget in ipairs(w.widgets)do
        local tail=w.api.read(p(widget+1984),8)
        w.poke(widget+1984,ptrs(ptr(tail,0)+rows*3*80))
    end
    meta_u32(w,24884,first);meta_u32(w,24888,first+14);w.poke(w.meta+2644,f32s(px))
end
-- A preview job for the item in card c, slot i, with the given slots.
local function queue(w,c,i,slots)
    local row=44
    local id=ffi.string(w.manager+c*1816+32+i*120+24,8)
    local bytes=string.rep('\0',64)..id..string.rep('\0',8)..u32s(#slots)..string.rep('\0',4)
    for _,s in ipairs(slots)do bytes=bytes..ptrs(s)end
    w.poke(w.preview+50456+row*200,bytes..string.rep('\0',200-#bytes))
    w.poke(w.preview+50448,u32s(44)..u32s(45))
end
local function empty_queue(w)w.poke(w.preview+50448,u32s(45)..u32s(45))end
local function top(w,value)w.poke(w.stack,u32s(value))end

-- Every item's identity in a new category: request keys change, as when the
-- player switches category (the completed cards then hold the new items).
local function category(w,n)
    for c=0,5 do
        for i=0,14 do w.manager[c*1816+32+i*120+31]=n end
    end
end
-- Screens the captures do not show (tests/synthetic_screens.lua).
local screens=dofile(root..'/tests/synthetic_screens.lua')
local function preselect(w,mode)screens.preselect(w.poke,w.owner,mode)end
local function preselect_closed(w)screens.preselect_closed(w.poke,w.owner)end
local function loadout(w)screens.loadout(w.poke,w.owner,w.m32)end

-- A hidden image consumer left in the registry by the previous screen
-- (handoff eligibility reads its type and opacity), at a fixed address.
local HIDDEN=0x7ffe00001000
local function hidden_consumer(w,opacity)
    local bytes=ffi.new('uint8_t[88]')
    ffi.cast('uint32_t *',bytes)[0]=0xc0000;ffi.cast('float *',bytes)[21]=opacity
    w.poke(HIDDEN,ffi.string(bytes,88))
    local n=w.m32[2784]
    w.m32[2786+n*2]=HIDDEN%4294967296;w.m32[2787+n*2]=math.floor(HIDDEN/4294967296);w.m32[2784]=n+1
end
-- A bound tile's material instance replaced natively (as briefing does when
-- it retires materials on picker entry).
local function retire_material(w,index)
    w.poke(w.widgets[index]+272+328,ptrs(0x610000000000+index))
end

local frames=0
-- One part of a frame's native writes as a set: bindings are a hash table, so
-- cleanup visits widgets in table order. Prune makes the same texture calls in
-- both (it releases the same bindings); the update does not (the gated one does
-- not re-send unchanged presentation), so only prune's are counted.
local function settle(w,part)
    table.sort(w.writes)
    local textures=part=='prune' and ' textures='..w.texture_calls or ''
    w.log[#w.log+1]=part..textures..' '..table.concat(w.writes,' ');w.writes={};w.texture_calls=0
end
local function run(fixture,script,worlds)
    worlds=worlds or {world(fixture,'ungated'),world(fixture,'gated')}
    for _,step in ipairs(script)do
        for _=1,step.repeats or 1 do
            frames=frames+1
            for _,w in ipairs(worlds)do w.cache:before();settle(w,'prune')end
            compare(worlds[1],worlds[2],fixture..': '..step.name..' (before the game update)')
            for _,w in ipairs(worlds)do
                if step.change then step.change(w)end
                w.cache:tick(step.pressure==true)
                -- A change after the tick: the native UI moving outside the
                -- update, first seen by the next frame's prune.
                if step.after then step.after(w)end
                settle(w,'tick')
            end
            compare(worlds[1],worlds[2],fixture..': '..step.name)
            if os.getenv('APC_TRACE')then
                local c=worlds[1].cache
                print(step.name,c.screen,c.status,'retained',c.retained,'pending',c.pending_items,'late',c.late_switches,
                    'hits',c.last_hits,'misses',c.last_misses,'widgets',c.widget_count,'ready',c.ready_items,'gated',worlds[2].cache.gated_ticks)
            end
        end
    end
    return worlds
end

local STATIC={name='unchanged',repeats=6}
local gated_frames=0
local function gated(worlds)gated_frames=gated_frames+worlds[2].cache.gated_ticks;return worlds end
-- Armory: a visit with a queued appearance job, idle handoff, scrolling,
-- card regeneration with invalidation, an appearance change, pressure,
-- leaving and returning, cards restarting, pre-select screens.
local first_visit={
    {name='first visit with a preview job',change=function(w)queue(w,1,3,{0x1111,0x2222})end},
    STATIC,
    {name='scroll one row',change=function(w)scroll(w,1,6,17.5)end},
    {name='scroll settles',change=function(w)w.poke(w.meta+2644,f32s(18))end},
    STATIC,
    {name='card 1 re-queued',change=function(w)
        card(w,1,3);active(w,1,4)
        for k=0,255 do
            local rec=w.api.read(p(w.meta+4332+k*80),80)
            if u32(rec,8)==3 and u32(rec,60)==1 then record_byte(w,k,68,1)end
        end
    end},
    STATIC,
    {name='card 1 preparing',change=function(w)card(w,1,5);active(w,1,5)end},
    STATIC,
    {name='card 1 composing',change=function(w)card(w,1,6);active(w,1,6)end},
    {name='card 1 finalizing',change=function(w)card(w,1,7)end},
    {name='card 1 complete before the manager moves on',change=function(w)card(w,1,8)end},
    STATIC,
    {name='card 1 complete',change=function(w)active(w,0xffffffff,0)end},
    STATIC,
    {name='appearance change queued',change=function(w)queue(w,1,3,{0x1111,0x3333})end},
    STATIC,
    {name='queue drained',change=empty_queue},
    STATIC,
    {name='memory pressure',pressure=true,repeats=3},
    {name='pressure cleared',repeats=3},
    {name='left the Armory',change=function(w)top(w,3)end},
    STATIC,
    {name='back in the Armory',change=function(w)top(w,5)end},
    STATIC,
    {name='card 2 restarts',change=function(w)card(w,2,3);active(w,2,4)end},
    {name='card 2 restarts again before completing',change=function(w)card(w,2,4)end},
    STATIC,
    {name='card 2 complete',change=function(w)card(w,2,8);active(w,0xffffffff,0)end},
    STATIC,
    {name='scroll back',change=function(w)scroll(w,-1,3,0)end},
    STATIC,
    {name='scroll outside the update',after=function(w)scroll(w,1,6,18)end},
    STATIC,
    {name='weapon pre-select opens',change=function(w)preselect(w,0);card(w,0,3);active(w,0,4)end},
    STATIC,
    {name='pre-select rendered',change=function(w)card(w,0,8);active(w,0xffffffff,0)end},
    STATIC,
    {name='pre-select closes as the grid re-queues',change=function(w)
        preselect_closed(w);for c=0,5 do card(w,c,3)end;card(w,0,4);active(w,0,4)
    end},
    STATIC,
    {name='grid complete',change=function(w)for c=0,5 do card(w,c,8)end;active(w,0xffffffff,0)end},
    STATIC,
    {name='weapon pre-select opens again',change=function(w)preselect(w,0);card(w,0,3);active(w,0,4)end},
    STATIC,
    {name='pre-select rendered again',change=function(w)card(w,0,8);active(w,0xffffffff,0)end},
    STATIC,
    {name='cosmetic pre-select',change=function(w)preselect(w,1);card(w,0,3);active(w,0,4)end},
    STATIC,
    {name='pre-select closes',change=preselect_closed},
    STATIC,
}
local armory=gated(run('armory',first_visit))
assert(armory[1].cache.retained>0 and armory[1].cache.hits>0 and armory[1].cache.preselect_hits>0,
    'The script must retain crops and show them on the grid and pre-select')
-- A first visit while generating: visible cards finish first (visible
-- handoff), the rest later (rebind handoff), then the player scrolls onto
-- them; a later visit leaves before its category finishes (late switch).
gated(run('armory',{
    {name='visible cards done, the rest queued',change=function(w)
        for c=2,5 do card(w,c,3)end;card(w,2,4);active(w,2,4)
    end},
    STATIC,
    {name='card 2 preparing',change=function(w)card(w,2,5);active(w,2,5)end},
    STATIC,
    {name='card 2 composing',change=function(w)card(w,2,6);active(w,2,6)end},
    {name='card 2 done, card 3 preparing',change=function(w)card(w,2,8);card(w,3,4);active(w,3,4)end},
    STATIC,
    {name='category complete',change=function(w)for c=3,5 do card(w,c,8)end;active(w,0xffffffff,0)end},
    STATIC,
    {name='scroll two rows',change=function(w)scroll(w,2,9,36)end},
    STATIC,
    {name='next category starts',change=function(w)category(w,7);for c=0,5 do card(w,c,3)end;active(w,0,4)end},
    {name='its first card done',change=function(w)card(w,0,8);active(w,1,4)end},
    STATIC,
    {name='left before it finished',change=function(w)top(w,3)end},
    STATIC,
}))
-- Nine categories through the eight-atlas budget: least-recently-used
-- eviction depends on the recency the gated frames record.
local categories={}
for n=1,9 do
    categories[#categories+1]={name='category '..n,change=function(w)category(w,n)end}
    categories[#categories+1]=STATIC
    if n==5 then
        categories[#categories+1]={name='revisit category 2',change=function(w)category(w,2)end}
        categories[#categories+1]=STATIC
    end
end
local lru=gated(run('armory',categories))
assert(lru[1].cache.evicted>0,'The script must evict')
-- A capture held back by a hidden consumer that is still visible: only its
-- opacity changes (the state does not cover it), so pending frames run in full.
local held=gated(run('armory',{
    {name='a hidden consumer still visible',change=function(w)hidden_consumer(w,1)end},
    STATIC,
    {name='the hidden consumer faded',change=function(w)w.poke(HIDDEN+84,f32s(0))end},
    STATIC,
}))
assert(held[1].cache.idle_retained==1 and held[1].cache.pending_drops==0,'The fade must release the held capture')
-- A tile whose template is missing stays unbound with a crop: such frames
-- retry in full until the material can be made. The tile shows the named
-- thumbnail template with no material instance yet. The frame after the
-- material is made runs in full too: the mod's own write changed what the
-- snapshot decodes (the tile no longer shows the named template).
local function template_missing(w)
    local element=w.widgets[1]+272
    w.no_material[element]=true
    w.poke(element+328,ptrs(0));w.poke(element+336,u32s(0x5506e446)..u32s(0x27ef0643))
end
local missing=gated(run('armory',{
    {name='a tile template missing',change=template_missing},
    STATIC,
    {name='the template is back',change=function(w)w.no_material={}end},
    STATIC,
}))
assert(missing[1].cache.full_retry==nil and missing[2].cache.full_retry>0,'The gated cache must retry the unbound tile')
-- A bound tile's material replaced right after a full update: the first prune
-- after it releases the binding and the next update binds the tile again, so
-- a later cleanup restores it. Then the grid scrolls outside the update while
-- tiles are bound: the next prune must release the remapped bindings.
gated(run('armory',{
    STATIC,
    {name='scroll position moves, a material is replaced after the update',
        change=function(w)w.poke(w.meta+2644,f32s(3))end,after=function(w)retire_material(w,2)end},
    STATIC,
    {name='scroll outside the update with tiles bound',after=function(w)scroll(w,1,6,18)end},
    STATIC,
    {name='memory pressure',pressure=true},
    {name='pressure cleared',repeats=3},
}))
-- Texture ownership lost while frames are skipped: both raise the same error.
do
    local worlds=run('armory',{STATIC})
    for _,w in ipairs(worlds)do
        w.poke(w.original,string.rep('\238',8))
        w.cache:before()
        local ok,why=pcall(w.cache.tick,w.cache,false)
        assert(not ok and tostring(why):find('Cached texture ownership changed',1,true),
            w.version..': lost texture ownership must raise, got '..tostring(why))
    end
    assert(worlds[2].cache.gated_ticks>0,'The ownership check must run on a skipped frame')
end
-- verify_gate=1 checks the assumptions in real play: what the state does not
-- cover (widget fields) never changes on its own. With correct gating and no
-- such change it reports no miss. A tile's fit changing outside the update
-- (not covered) is caught on the next skipped frame and the full update runs,
-- so the result still matches the ungated one; prune's dry reconcile catches a
-- binding released by a material replaced outside the update.
local verify_frames
do
    local function verified(script)
        local worlds={world('armory','ungated'),world('armory','gated',{verify_gate=true})}
        local before=frames
        run('armory',script,worlds)
        verify_frames=(verify_frames or 0)+frames-before
        return worlds[2]
    end
    local clean=verified(first_visit)
    assert(clean.cache.gate_misses==0 and clean.adapter.prune_misses==0 and clean.cache.gated_ticks>0,
        'Correct gating reports no miss')
    local fit=verified({STATIC,
        {name='a tile changes its fit after a skipped update',after=function(w)w.poke(w.widgets[4]+2000,u32s(2))end},
        STATIC})
    assert(fit.cache.gate_misses==1 and fit.cache.gate_misses_widgets==1,'An uncovered widget change must be caught')
    local material=verified({STATIC,
        {name='a material replaced after a skipped update',after=function(w)retire_material(w,3)end},
        STATIC,
        {name='a tile unbound natively after a skipped update',after=function(w)w.poke(w.widgets[5]+2005,'\0')end},
        STATIC})
    assert(material.adapter.prune_misses==2,'Releases the state does not cover must be caught')
end
-- Briefing: the captured picker grid, then a synthetic loadout.
local briefing=gated(run('loadout',{
    {name='briefing grid'},
    STATIC,
    {name='card 0 re-queued',change=function(w)card(w,0,3);active(w,0,4)end},
    STATIC,
    {name='card 0 complete',change=function(w)card(w,0,8);active(w,0xffffffff,0)end},
    STATIC,
    {name='memory pressure',pressure=true},
    {name='pressure cleared',repeats=3},
    {name='loadout shown',change=loadout},
    STATIC,
    {name='loadout card re-queued',change=function(w)card(w,0,3);active(w,0,4)end},
    STATIC,
    {name='loadout card complete',change=function(w)card(w,0,8);active(w,0xffffffff,0)end},
    STATIC,
}))
assert(briefing[1].cache.briefing_hits>0)
print(string.format('PASS: ungated and gated update give identical presentation, native writes, manager and cache state before and after the game update in each of %d frames (%d gated): first visit, idle/visible/rebind handoffs, scrolling in and outside the update, invalidation and regeneration, a card completing alone, appearance change, pressure, leave and return, late switch, weapon/cosmetic pre-select, nine categories through LRU eviction, a capture held by a hidden consumer, a tile retried until its material exists, a material replaced after the update, briefing grid and loadout; lost texture ownership raises in both; verify_gate reports no miss for correct gating and catches an uncovered widget change and two uncovered releases (%d of the frames)',
    frames,gated_frames,verify_frames))
