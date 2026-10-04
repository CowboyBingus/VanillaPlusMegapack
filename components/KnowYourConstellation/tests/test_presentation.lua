local source=assert(arg[1])
local ffi=require('ffi')
local presentation=assert(loadfile(source..'/presentation.lua'))()
local mission=assert(loadfile(source..'/mission.lua'))()
local resolve=assert(loadfile(source..'/resolve.lua'))()
local fixture=assert(loadfile(source..'/../tests/fixtures/presentation_briefing.lua'))()
local transition=assert(loadfile(source..'/../tests/fixtures/presentation_transitions.lua'))()
local overrides={}
local blocks=fixture.blocks
local reads=0
local api={}
function api.pointer(bytes,off)
    if not bytes then return nil end
    local q=ffi.new('uint64_t[1]')
    ffi.copy(q,bytes:sub((off or 0)+1,(off or 0)+8),8)
    local n=tonumber(q[0])
    return n>=65536 and n<0x800000000000 and n or nil
end
-- Like the game's reader: a string, or the bytes copied into a caller buffer.
function api.read(address,size,into,offset)
    assert(size<=1024)
    reads=reads+1
    local result={}
    for _,list in ipairs({blocks,overrides}) do
        for _,b in ipairs(list) do
            for at=math.max(address,b.address),math.min(address+size,b.address+#b.bytes)-1 do
                result[at-address+1]=b.bytes:sub(at-b.address+1,at-b.address+1)
            end
        end
    end
    for i=1,size do assert(result[i],string.format('Unexpected presentation read 0x%x + %d',address,size)) end
    if not into then return table.concat(result) end
    ffi.copy(into.data+(offset or 0),table.concat(result),size)
    return true
end
local function put(address,bytes) overrides[#overrides+1]={address=address,bytes=bytes} end
local function word(n) return ffi.string(ffi.new('uint32_t[1]',n),4) end
local function float(n) return ffi.string(ffi.new('float[1]',n),4) end
local function qword(n) return ffi.string(ffi.new('uint64_t[1]',n),8) end
local game=fixture.game
-- Static body atlas resource identifier from the supported build.
put(game+0x3772ee8,string.char(0x4b,0x93,0x9f,0xc7,0x91,0xb9,0xeb,0xd1))
local reader=presentation.new(api,game)
assert(mission.new(api,game,resolve):screen()=='briefing')
local box=assert(reader:sample('briefing'))
assert(math.abs(box.x-512)<.01 and math.abs(box.y-894.1667)<.02)
assert(math.abs(box.w-710.6667)<.02 and math.abs(box.scale-4/3)<.001)
assert(box.font=='b56d2abac5d17df2' and box.material=='9f85b87d3ff20cbb')
assert(box.atlas=='d1ebb991c79f934b')
put(game+0x3772ee8,string.rep('\0',8))
assert(not pcall(reader.sample,reader,'briefing'),'An unready atlas must not render solid glyph blocks')
put(game+0x3772ee8,string.char(0x4b,0x93,0x9f,0xc7,0x91,0xb9,0xeb,0xd1))
local manager=api.pointer(api.read(game+0x3326e68,8))
local owner=api.pointer(api.read(manager+25280,8))
for _,entry in ipairs(transition.entry) do
    put(owner+8,word(entry.tab))
    put(owner+31232,word(entry.flags))
    put(owner+31232+84,float(entry.alpha))
    local actual=reader:sample('briefing')
    assert((actual~=nil)==(entry.tab==0 and entry.alpha>=.995), 'Pod entry opacity gate regressed')
end
assert(transition.entry[1].tab==2 and transition.entry[1].alpha==0)
put(owner+8,word(1))
assert(not reader:sample('briefing'),'Loadout must be hidden even with fully opaque stale briefing data')
put(owner+8,word(3))
assert(not reader:sample('briefing'),'Unknown tabs must be hidden')
put(owner+8,word(0))
put(owner+31232+84,float(0/0))
assert(not reader:sample('briefing'),'Invalid opacity must hide')
put(owner+31232+84,float(1))
put(manager+25272,word(0))
assert(not reader:sample('briefing'),'Stale subscriber pointer must not be followed')
put(manager+25272,word(1))
put(manager+25288,word(226))
assert(not reader:sample('briefing'),'Reused component allocation must not be followed')
put(manager+25224,word(1)..word(0)..qword(owner)..word(226)..word(0))
put(owner+349072,transition.map)
box=assert(reader:sample('map'))
assert(box.x==512 and math.abs(box.y-768.8333)<.02 and math.abs(box.w-710.6667)<.02)
put(owner+349072+148,float(650))
put(owner+349072+156,float(700))
box=assert(reader:sample('map'))
assert(box.x==650 and box.y==700,'Coordinates must come from the current native panel')
put(owner+349072+84,float(0))
put(owner+280528,string.rep('\0',164))
put(owner+526048,string.rep('\0',164))
assert(not reader:sample('map'))
assert(not reader:sample('ship') and reads<450)
-- Independent synthetic loadout state, without modifying its bytes.
blocks=assert(loadfile(source..'/../tests/fixtures/presentation_loadout.lua'))().blocks
overrides={}
assert(mission.new(api,game,resolve):screen()=='briefing')
assert(not reader:sample('briefing'))
local join=assert(loadfile(source..'/../tests/fixtures/presentation_join_left.lua'))()
blocks,overrides=join.blocks,{}
local join_reader=presentation.new(api,join.game)
local join_manager=api.pointer(api.read(join.game+0x3326e68,8))
local join_owner=api.pointer(api.read(join_manager+25232,8))
local positions=assert(loadfile(source..'/../tests/fixtures/presentation_join_positions.lua'))()
put(join_owner+526048,positions[1])
local join_box=assert(join_reader:sample('map'))
assert(join_box.client and join_box.active and math.abs(join_box.w-710.6667)<.02,
    'The client forecast must use the left planet frame, not the moving card')
assert(join_box.x==512 and math.abs(join_box.y-696.6667)<.02)
for _,widget in ipairs(positions) do
    put(join_owner+526048,widget)
    local current_box=assert(join_reader:sample('map'))
    assert(current_box.client and current_box.active)
    assert(current_box.x==join_box.x and current_box.y==join_box.y and current_box.h==join_box.h,
        'Moving-card position and player-list height must not move the left forecast frame')
end
put(join_owner+526048+84,float(.5))
assert(join_reader:sample('map').active,'A card fade must not hide the fixed frame')
put(join_owner+526048+84,float(0))
assert(join_reader:sample('map').active==false,'Hover dismissal must be distinguished from closing the native frame')
put(join_owner+526048+84,float(1))
put(join_owner+280528+156,float(710))
assert(join_reader:sample('map').y==710,'The left frame must still follow its own native layout')
put(join_owner+280528+84,float(.5))
assert(not join_reader:sample('map'),'The planet frame must be fully visible before opening the strip')
put(join_owner+280528+84,float(1))
put(join_manager+25224,word(0))
assert(not join_reader:sample('map'),'Stale map owner must not show a joinable forecast')
local hidden=assert(loadfile(source..'/../tests/fixtures/presentation_join_hidden.lua'))()
local fonts={}
local material=api.pointer(api.read(join.game+0x37c5478,8))
for _,address in ipairs({join.game+0x3772268,join.game+0x37c5478,join.game+0x3772ee8,material+24}) do
    fonts[#fonts+1]={address=address,bytes=api.read(address,8)}
end
blocks,overrides=hidden.blocks,{}
assert(hidden.game==join.game)
for _,b in ipairs(fonts) do put(b.address,b.bytes) end
local hidden_manager=api.pointer(api.read(hidden.game+0x3326e68,8))
local hidden_owner=api.pointer(api.read(hidden_manager+25232,8))
local left_widget
for _,b in ipairs(join.blocks) do if b.address==join_owner+280528 then left_widget=b.bytes end end
put(hidden_owner+280528,assert(left_widget))
local inactive=assert(presentation.new(api,hidden.game):sample('map'))
assert(inactive.client and not inactive.active,
    'Synthetic hover dismissal must stop report publication despite a cached mission descriptor')
print('PASS: left planet anchoring, independent card movement and fade, hover dismissal, host border, pod fade, loadout and native font mapping')
