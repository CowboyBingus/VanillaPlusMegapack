-- Real production adapter over the captured Armory grid (Steam 25327279 UI,
-- current-build instruction guards). The manager is a local writable copy
-- whose card states model a visit where the visible cards have composed and
-- offscreen cards are still preparing. Engine calls are recording stand-ins.
local root=assert(arg[1]);local ffi=require('ffi');local source=root..'/src'
local api,game,exe,_,memory=dofile(root..'/tests/captured_ui.lua')(root..'/tests/fixtures/ui_armory_25327279.lua')
local sigs=dofile(source..'/image_signatures.lua')
local guarded={}
for _,s in ipairs(sigs)do
    guarded[tonumber(ffi.cast('uintptr_t',(s.module=='game' and game or exe)+s.rva))]=
        s.hex:gsub('..',function(h)return string.char(tonumber(h,16))end)
end
guarded[tonumber(ffi.cast('uintptr_t',exe+0x1658990))]=ffi.string(ffi.new('uint32_t[1]',32),4)
local captured=api.read
local manager=ffi.new('uint8_t[12176]');local tm=ffi.cast('uint8_t *',manager)
ffi.copy(tm,captured(api.pointer(captured(game+0x347cd80,8)),12176),12176)
local original=ffi.cast('uint8_t *',ffi.cast('void **',tm+11112)[0])
local fresh_blocks,fresh={},{}
for i=1,2 do
    fresh_blocks[i]=ffi.new('uint8_t[104]');fresh[i]=ffi.cast('uint8_t *',fresh_blocks[i])
    ffi.copy(fresh[i],captured(original,104),104)
    fresh[i][0]=i  -- distinct descriptor identity per allocation
end
-- The game sees the local manager copy and the two replacement descriptors;
-- one-byte native writes land in replay memory.
for a,bytes in pairs(guarded)do memory.poke(a,bytes)end
memory.poke(game+0x347cd80,ffi.string(ffi.new('void *[1]',tm),8))
memory.map(tm,tm,12176);memory.map(fresh[1],fresh[1],104);memory.map(fresh[2],fresh[2],104)
local created,bound,destroyed=0,{},{}
local calls={create=function()created=created+1;return fresh[created]end,
    register=function(name)assert(name==3400165836)end,
    destroy=function(t)destroyed[#destroyed+1]=t end,
    texture=function(e,name,t)assert(name==984135806);bound[tostring(e)]=t end,
    uv=function()end,size=function()end,alpha=function()end,material=function()end,
    register_image=function()end,
    byte=function(p,v)memory.poke(p,string.char(v))end}
local adapter=dofile(source..'/image_native.lua').new(api,game,exe,sigs,calls)
local u32=ffi.cast('uint32_t *',tm)
local function state(card,v)if v then u32[(card*1816+1832)/4]=v end;return u32[(card*1816+1832)/4]end
local function set_active(card,phase)u32[11064/4]=card;u32[11096/4]=phase end

local s=adapter:snapshot()
assert(s.screen=='grid' and s.complete and s.can_freeze_idle and not s.can_freeze_visible)
local card_of,visible,offscreen={},{},{}
for _,item in ipairs(s.items)do card_of[item.key]=item.card end
for _,w in ipairs(s.widgets)do visible[card_of[w.key]]=true end
for c=0,5 do if state(c)~=0 and not visible[c]then offscreen[#offscreen+1]=c end end
assert(#offscreen>0,'Fixture must have offscreen cards')
-- Offscreen cards queued/preparing, one of them active in preparation.
for _,c in ipairs(offscreen)do state(c,3)end
state(offscreen[1],4);set_active(offscreen[1],4)
s=adapter:snapshot()
assert(not s.complete and not s.can_freeze and s.quiescent)
assert(s.can_freeze_visible and not s.can_freeze_idle and not s.can_freeze_rebind,'Visible cards composed: early handoff offered')
assert(#s.registry==15)
-- Composition, a non-preparing phase or an unfinished visible card each close it.
state(offscreen[1],6);s=adapter:snapshot()
assert(not s.quiescent and not s.can_freeze_visible,'Never detach while a card composes into the atlas')
assert(#s.registry==0,'Registry reads are skipped when no handoff can be accepted')
state(offscreen[1],4);set_active(offscreen[1],6)
assert(not adapter:snapshot().can_freeze_visible,'Active card must be in preparation phase 4/5')
set_active(offscreen[1],4)
local some_visible=next(visible);state(some_visible,5)
assert(not adapter:snapshot().can_freeze_visible,'Every visible tile must be composed')
state(some_visible,8)
set_active(0xffffffff,0)
assert(adapter:snapshot().can_freeze_visible,'Queued cards between activations do not compose')
state(offscreen[#offscreen],7)
assert(not adapter:snapshot().can_freeze_visible,'A finalizing card blocks detach even when not active')
state(offscreen[#offscreen],3)
state(offscreen[1],4);set_active(offscreen[1],4)

-- Early handoff: only composed cards are captured; every consumer moves off
-- the detached atlas and the visible tiles are rebound in the same callback.
s=adapter:snapshot()
local native_state=ffi.string(tm,11112)
local p=adapter:capture(s);p.request_id=s.capture_id
local expected=0
for _,item in ipairs(s.items)do
    if visible[item.card]then expected=expected+1;assert(p.entries[item.key])
    else assert(not p.entries[item.key],'Unfinished card pixels never enter the cache')end
end
local count=0;for _ in pairs(p.entries)do count=count+1 end;assert(count==expected)
local first=adapter:freeze(s,p)
assert(ffi.cast('void **',tm+11112)[0]==fresh[1] and first.handle==original)
for _,e in ipairs(s.registry)do assert(bound[tostring(e)]==fresh[1])end
for _,entry in pairs(p.entries)do entry.texture=first end
local entries=p.entries
assert(adapter:apply(s,entries)==#s.widgets)
for _,w in ipairs(s.widgets)do assert(bound[tostring(w.element)]==original)end
assert(ffi.string(tm,11112)==native_state,'Never forge native card or generation state')

-- The replacement holds the composed cards as blank space: no second early
-- handoff, and those regions are never captured from it.
s=adapter:snapshot()
assert(s.blank_cards>0 and not s.can_freeze_visible and not s.can_freeze_rebind)
for _,w in ipairs(s.widgets)do assert(not w.pixels_ready)end
-- Offscreen cards finish into the replacement.
for _,c in ipairs(offscreen)do state(c,8)end;set_active(0xffffffff,0)
s=adapter:snapshot()
assert(s.complete and not s.can_freeze_idle and s.can_freeze_rebind,'Rebind boundary after the visible handoff')
p=adapter:capture(s);p.request_id=s.capture_id
for _,item in ipairs(s.items)do assert((p.entries[item.key]~=nil)==not visible[item.card])end
local second=adapter:freeze(s,p)
assert(ffi.cast('void **',tm+11112)[0]==fresh[2] and second.handle==fresh[1])
for key,entry in pairs(p.entries)do entry.texture=second;entries[key]=entry end
assert(adapter:apply(s,entries)==#s.widgets)
-- Neither handoff left a restorable backup with blank regions in it.
adapter:restore(true)
assert(ffi.cast('void **',tm+11112)[0]==fresh[2] and #destroyed==0,'Blank-region atlases are never returned to native ownership')
-- Native re-queues and recomposes the visible cards while one offscreen card
-- is still blank and another restarts: at most one early handoff per atlas,
-- the rest waits for the rebind boundary.
assert(#offscreen>=2,'Fixture must have two offscreen cards')
for c in pairs(visible)do state(c,3)end
state(offscreen[2],3);adapter:snapshot()
for c in pairs(visible)do state(c,8)end
s=adapter:snapshot()
assert(s.quiescent and not s.complete and s.blank_cards==#offscreen-1)
for _,w in ipairs(s.widgets)do assert(w.pixels_ready)end
assert(not s.can_freeze_visible,'No early handoff while another card is blank')
print('PASS: grid visible handoff on captured UI; composition/phase/unfinished-visible gates; registry reads skipped while blocked; only composed pixels captured; offscreen cards retained through the rebind boundary; no native state writes or blank restores')
