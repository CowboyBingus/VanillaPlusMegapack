local source = assert(arg[1])
local ffi = require('ffi')
local mission = assert(loadfile(source..'/mission.lua'))()
local resolve = assert(loadfile(source..'/resolve.lua'))()
local fixture = assert(loadfile(source..'/../tests/fixtures/mission.lua'))()
local blocks = fixture.blocks
local reads = 0
local overrides = {}
local api = {}
function api.pointer(bytes,offset)
    local word=ffi.new('uint64_t[1]')
    ffi.copy(word,bytes:sub((offset or 0)+1,(offset or 0)+8),8)
    local value=tonumber(word[0])
    if value<65536 or value>=0x800000000000 then return nil end
    return value
end
local function lookup(address,size)
    for i=#overrides,1,-1 do
        local block=overrides[i]
        if address>=block.address and address+size<=block.address+#block.bytes then
            local at=address-block.address
            return block.bytes:sub(at+1,at+size)
        end
    end
    for _,block in ipairs(blocks) do
        if address>=block.address and address+size<=block.address+#block.bytes then
            local at=address-block.address
            return block.bytes:sub(at+1,at+size)
        end
    end
    error(string.format('Unspecified synthetic read 0x%x + %d',address,size))
end
-- Like the game's reader: a string, or the bytes copied into a caller buffer.
local function deliver(bytes,size,into,offset)
    if not into then return bytes end
    ffi.copy(into.data+(offset or 0),bytes,size)
    return true
end
function api.read(address,size,into,offset)
    reads=reads+1
    return deliver(lookup(address,size),size,into,offset)
end
local reader=mission.new(api,fixture.game,resolve)
assert(reader:screen()==fixture.screen)
local sample=reader:sample(fixture.screen)
assert(sample.key==fixture.key)
assert(table.concat(sample.tags,',')==table.concat(fixture.tags,','))
assert(sample.complete==fixture.complete)
assert(reads<1500, 'Unexpected polling cost')
local function put(address,bytes) overrides[#overrides+1]={address=address,bytes=bytes} end
local function word(n) return ffi.string(ffi.new('uint32_t[1]',n),4) end
local function qword(n) return ffi.string(ffi.new('uint64_t[1]',n),8) end
local function u32(b,at)
    local v=ffi.new('uint32_t[1]')
    ffi.copy(v,b:sub(at+1,at+4),4)
    return tonumber(v[0])
end
local board=sample.board
local campaign=board+1053752
local planet=u32(api.read(board+1548952,4),0)
local index=u32(api.read(board+1548960,4),0)
local selected=api.read(board+1012352+92*index,92)
local op_id=selected:byte(25)
local category=u32(selected,28)
assert(category<14)
put(fixture.game+0x32e98e0+168*category+9,string.char(1))
put(campaign+155672,word(1))
put(campaign+143384,word(planet)..word(op_id)..word(1234567)..string.rep('\0',12))
put(board+0x1f8908,qword(0x700000)..qword(0x700100)..word(1)..word(0))
put(0x700000,qword(0x700200))
put(0x700100,word(1234567))
put(0x700200+88,qword(0x700300)..word(1))
local defs=api.pointer(api.read(fixture.game+0x347cd98,8))
local count=u32(api.read(defs+53248,4),0)
local rows=api.read(defs,count*52)
local dragon_hash
for i=0,count-1 do
    local at=i*52
    if u32(rows,at+4)==40 and u32(rows,at+24)==13 and u32(rows,at+28)==0x9fd5943a then
        dragon_hash=u32(rows,at+8)
        break
    end
end
assert(dragon_hash,'Synthetic modifier definition missing')
put(0x700300,word(dragon_hash))
local config=api.pointer(api.read(fixture.game+0x347cdf8,8))
put(config+73848,string.rep('\0',24))
put(config+49232,string.rep('\0',24))
local modified=reader:sample(fixture.screen)
assert(modified.complete,table.concat(modified.unresolved,','))
local dragon=false
for _,tag in ipairs(modified.tags) do if tag==11 then dragon=true end end
assert(dragon,'Operation modifier was not applied')
-- Browsing a local operation does not update the ship's active planet. Use
-- the hovered operation's planet while keeping its operation modifiers.
local saved_overrides=#overrides
local active_planet=planet==76 and 268 or 76
put(board+1548952,word(active_planet))
put(campaign+495200,word(active_planet))
put(campaign+280*active_planet,string.rep('\0',24)..word(123456789)..string.rep('\0',252))
local cross_planet=reader:sample(fixture.screen)
assert(cross_planet and cross_planet.complete, 'Hosted hover must resolve independently of the ship active planet')
assert(cross_planet.operation_planet==planet and cross_planet.operation_index==index)
assert(table.concat(cross_planet.tags,',')==table.concat(modified.tags,','),
    'Hosted preview must preserve the hovered operation modifiers on another active planet')
for i=#overrides,saved_overrides+1,-1 do overrides[i]=nil end
put(config+73848,qword(0x700400)..word(1)..word(0xffffffff)..word(1)..word(0))
put(0x700400,word(resolve.exclusion_key(0x9fd5943a))..string.rep('\0',44))
local excluded=reader:sample(fixture.screen)
assert(excluded.complete)
for _,tag in ipairs(excluded.tags) do assert(tag~=11,'Backend exclusion ignored') end

-- Synthetic pre-join hover, with no selected local operation. The advertisement,
-- cached preview and loaded controller must all belong to the same mission.
local join=assert(loadfile(source..'/../tests/fixtures/mission_join.lua'))()
blocks,overrides,reads=join.blocks,{},0
local join_reader=mission.new(api,join.game,resolve)
local joined=join_reader:sample('map')
assert(joined.key==join.key and joined.complete and join.complete)
assert(joined.faction==4 and table.concat(joined.tags,',')==table.concat(join.tags,','))
assert(reads<150,'Joinable forecast exceeded its bounded read budget')
assert(u32(api.read(joined.board+1548960,4),0)==0xffffffff)
local descriptor,hovered=join_reader:descriptor('map')
assert(descriptor and hovered==true,'A selected remote mission must report an active hover')
put(joined.root+713400,'different mission packet\0'..string.rep('\0',487))
descriptor,hovered=join_reader:descriptor('map')
assert(descriptor==nil and hovered==true,
    'A loading preview must retain hover activity without using the previous mission')
overrides={}
put(joined.board+2064401,string.char(0))
descriptor,hovered=join_reader:descriptor('map')
assert(descriptor==nil and hovered==false,'An inactive preview gate must end the hover without a reader failure')
overrides={}
local selection=api.read(joined.board+1548964,8)
local id,group=u32(selection,0),u32(selection,4)
if id>=0x80000000 or group==0 then
    local fallback=api.read(api.pointer(api.read(join.game+0x3326aa0,8))+5633600,12)
    if id>=0x80000000 then id=u32(fallback,0) end
    if group==0 then group=u32(fallback,8) end
end
-- Native controller navigation may provide a fallback selection. Respect it,
-- but never reuse the cached mission once both selection sources are empty.
put(join.game+0x3326aa0,qword(0x710000))
put(joined.board+1548964,word(0xffffffff)..word(0))
put(0x710000+5633600,word(id)..word(0)..word(group))
descriptor,hovered=join_reader:descriptor('map')
assert(descriptor and descriptor.key==join.key and hovered==true)
put(0x710000+5633600,word(0xffffffff)..word(0)..word(group))
descriptor,hovered=join_reader:descriptor('map')
assert(descriptor==nil and hovered==false,'No native hover must be distinct from a loading packet')
assert(join_reader:sample('map')==nil)
overrides={}
put(joined.board+2053224,word(441))
assert(not pcall(join_reader.descriptor,join_reader,'map'),'Joinable lookup must reject an oversized table')
overrides={}
put(joined.board+4286668,word(0xffffffff))
descriptor,hovered=join_reader:descriptor('map')
assert(descriptor==nil and hovered==true,'A missing preview slot must keep hover activity without reading stale data')
overrides={}
put(joined.board+1548960,word(110))
assert(not pcall(join_reader.descriptor,join_reader,'map'),
    'Invalid local indices must not be treated as joinable mission selection')
overrides={}
local remote=api.pointer(api.read(join.game+0x347ce80,8))
-- The synthetic sample is from the native third advertisement list.
local valid_address
for _,block in ipairs(blocks) do
    if #block.bytes==1 and block.address>=remote+1409456 and block.address<remote+1487456
        and (block.address-remote-1409456-1456)%1560==0 then valid_address=block.address end
end
assert(valid_address,'Synthetic advertised mission validity flag missing')
put(valid_address,string.char(0))
assert(join_reader:descriptor('map')==nil,'Expired advertisements must wait without a reader failure')
assert(join_reader:sample('map')==nil,'Sampling an expired advertisement must remain a normal pending state')
overrides={}
local loaded=api.read(joined.controller+8,200)
put(joined.controller+8,word(u32(loaded,0)+1)..loaded:sub(5))
local pending=join_reader:sample('map')
assert(not pending.complete and not pending.controller_matches,
    'An advertised mission must still wait for the matching loaded controller')

-- Synthetic stalled hover on planet 268 while the ship's local operation is on
-- planet 76. The preview's identity, campaign rows and controller agree.
local other=assert(loadfile(source..'/../tests/fixtures/mission_join_other_planet.lua'))()
blocks,overrides,reads=other.blocks,{},0
local other_reader=mission.new(api,other.game,resolve)
local remote_sample=other_reader:sample('map')
assert(remote_sample and remote_sample.complete,table.concat(remote_sample.unresolved,','))
assert(remote_sample.key==other.key and remote_sample.preview_planet==268)
assert(table.concat(remote_sample.tags,',')==table.concat(other.tags,','))
assert(reads<150,'Cross-planet hover must stay within the read budget')
local remote_data=remote_sample.board+1053752
local remote_static=api.read(remote_data+280*268,280)
put(remote_data+280*268,remote_static:sub(1,24)..word(910588397)..remote_static:sub(29))
assert(not other_reader:sample('map').complete,'A displayed planet hash mismatch must still withhold the report')
overrides={}
-- Planet-scoped enemy modifiers must follow the hovered planet, not the ship.
local globals=api.pointer(api.read(other.game+0x346d518,8))
local function scoped_modifier(planet,tag)
    return string.char(17)..string.rep('\0',3)..word(tag+1)..string.rep('\0',72)
        ..word(1)..word(0)..word(planet)..word(0)..string.rep('\0',260)
end
put(globals,scoped_modifier(76,11)..scoped_modifier(268,1)..string.rep('\0',30*356))
local remote_config=api.pointer(api.read(other.game+0x347cdf8,8))
put(remote_config+73848,string.rep('\0',24))
put(remote_config+49232,string.rep('\0',24))
local scoped=other_reader:sample('map')
assert(scoped.complete)
local bile=false
for _,tag in ipairs(scoped.tags) do
    assert(tag~=11,'The local planet modifier leaked into the remote mission')
    if tag==1 then bile=true end
end
assert(bile,'The hovered planet modifier was not applied')
overrides={}
local original_read=api.read
local descriptor_reads=0
function api.read(address,size,into,offset)
    local bytes=original_read(address,size)
    if address==remote_sample.address and size==200 then
        descriptor_reads=descriptor_reads+1
        if descriptor_reads==2 then bytes=word(u32(bytes,0)+1)..bytes:sub(5) end
    end
    return deliver(bytes,size,into,offset)
end
assert(other_reader:sample('map')==nil,'A mission changed during sampling must return pending, not fail the renderer')
api.read=original_read
print('PASS: host and joinable forecasts, cross-planet identity and scoped modifiers, pending previews, expiry, bounds and controller readiness')

-- New build: multiple mission exclusions remove each matching canonical tag.
overrides={}
put(other.game+0x3773420+896*84,string.rep('\0',20)..word(8)..word(12)..string.rep('\0',868))
local filtered=other_reader:sample('map')
for _,tag in ipairs(filtered.tags)do assert(tag~=7 and tag~=11,'One of the native exclusions was ignored')end
assert(resolve.from_native(1)==31 and resolve.from_native(2)==1 and resolve.from_native(31)==30)
overrides={}
put(other.game+0x3773420+896*84,string.rep('\0',52)..string.char(2)..string.rep('\0',811)
    ..'\073\120\130\127\209\044\124\133'..string.rep('\0',24))
local horde=other_reader:sample('map')
assert(horde and horde.complete)
local found=false
for _,tag in ipairs(horde.tags)do if tag==31 then found=true end end
assert(found,'HordeOnly mission mode must add its native tag')
print('PASS: inserted native tag preserves catalogue IDs; all eight mission exclusions supported')

-- Spawn-weight multipliers: category-72 campaign modifiers on the hovered
-- planet (deduplicated by modifier ID) and type-15 war effects in scope.
overrides={}
local function float(n) return ffi.string(ffi.new('float[1]',n),4) end
local war_strider,tank=0xbfb1567b,0x72c5564a
local other_campaign=remote_sample.board+1053752
local other_defs=api.pointer(api.read(other.game+0x347cd98,8))
local function weight_row(id,family,factor)
    return word(id)..word(72)..word(9000+id)..string.rep('\0',12)..word(13)..word(family)
        ..word(0)..word(2)..word(math.floor(factor*100))..float(factor)..word(1)
end
local base_row=api.read(other_defs,52)
put(other_defs+53248,word(3))
put(other_defs,base_row..weight_row(501,war_strider,5)..weight_row(502,tank,0.5))
-- The hovered planet carries 501 twice and 502 once; planet 76 is not hovered.
put(other_campaign+304*268+286952,word(501)..word(501)..word(502)..string.rep('\0',116)..word(3))
put(other_campaign+304*76+286952,word(502)..string.rep('\0',124)..word(1))
local function war_effect(scope,value,family,factor)
    return string.char(15)..string.rep('\0',3)..word(family)..float(factor)..string.rep('\0',68)
        ..word(1)..string.char(scope,0,0,0)..word(value)..word(0)..string.rep('\0',260)
end
put(globals,war_effect(3,0,tank,0.25)..war_effect(0,76,war_strider,9)..string.rep('\0',30*356))
local weighted=other_reader:sample('map')
assert(weighted and weighted.complete,table.concat(weighted and weighted.unresolved or {},','))
assert(weighted.zone and weighted.zone[war_strider]==5 and weighted.zone[tank]==0.5,
    'Category-72 weights must apply once per modifier ID on the hovered planet only')
assert(weighted.war and weighted.war[tank]==0.25 and not weighted.war[war_strider],
    'War effects must follow their scope: global applies, another planet does not')
-- A sample's lists and weight tables are its own: passed again, it is refilled
-- in place; a sample into another table leaves them alone.
local kept_zone,kept_war,kept_tags=weighted.zone,weighted.war,weighted.tags
local tag_list=table.concat(kept_tags,',')
assert(other_reader:sample('map',weighted)==weighted and weighted.zone==kept_zone and weighted.war==kept_war
    and weighted.tags==kept_tags and table.concat(kept_tags,',')==tag_list and kept_zone[war_strider]==5
    and kept_zone[tank]==0.5 and kept_war[tank]==0.25,'A sample passed again is refilled in place')
overrides={}
local plain=other_reader:sample('map')
assert(plain.zone==nil and plain.war==nil,'No multipliers without applicable rows')
assert(plain.tags~=kept_tags and kept_zone[war_strider]==5 and kept_war[tank]==0.25
    and table.concat(kept_tags,',')==tag_list,'A sample into another table leaves the earlier one alone')
assert(other_reader:sample('map',weighted)==weighted and weighted.zone==nil and weighted.war==nil
    and next(kept_zone)==nil and next(kept_war)==nil and weighted.tags==kept_tags,
    'Refilled without applicable rows, the kept weight tables are emptied and not named')
print('PASS: category-72 spawn weights on the hovered planet, deduplicated IDs, scoped type-15 war effects; '
    ..'samples refilled in place')

-- No UI state yet (while the game starts) is no forecast screen, not an error:
-- the same single read, and errors count toward stopping the mod.
overrides={}
local starting=mission.new(api,other.game,resolve)
put(other.game+0x347ce28,qword(0))
reads=0
assert(starting:screen()==nil and reads==1,'An absent UI state must read as no forecast screen')
put(other.game+0x347ce28,qword(0x8000))
assert(starting:screen()==nil,'A UI state pointer outside user memory must read as no forecast screen')
print('PASS: no forecast screen before the UI state exists')
