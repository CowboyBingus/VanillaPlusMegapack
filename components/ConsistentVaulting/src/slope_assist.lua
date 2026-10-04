local ffi,bit=require('ffi'),require('bit')
local A={limit=65,radius=3}
local INVALID=0xffffffff
-- Fields decode from the string's bytes with arithmetic: no cdata, cast or copy
-- per field.
local function u(b,o)
    local b0,b1,b2,b3=b:byte((o or 0)+1,(o or 0)+4)
    return ((b3*256+b2)*256+b1)*256+b0 -- lint-ok: R14 vault_data.lua decodes alike; each module loads and is tested alone
end
-- The float with bits w. A NaN loaded through a float cdata can become a
-- non-number value in the game's NaN-tagged LuaJIT; decoded here it is a plain
-- NaN.
local function float_bits(w)
    local e,m=bit.band(bit.rshift(w,23),0xff),bit.band(w,0x7fffff)
    local v
    if e==0xff then v=m==0 and math.huge or 0/0 elseif e==0 then v=m*2^-149 else v=(m+0x800000)*2^(e-150) end
    if w>=0x80000000 then return -v end
    return v
end
local function f(b,o)return float_bits(u(b,o)) end
local function bytes(v)return ffi.string(ffi.new('float[1]',v),4) end
local function finite(v)return v==v and math.abs(v)<100000 end
local function vec(b,o)return {f(b,o),f(b,o+4),f(b,o+8)} end
local COS=math.cos(A.limit*math.pi/180)
-- What an assist writes, built once: steep mode the two slide angles and the
-- slope cosine, ledge mode the ground climb height.
local ASSIST={enter=bytes(65),exit=bytes(60),slope=bytes(COS),height=bytes(2.5)}
local SLOPE_CELLS,LEDGE_CELLS={'enter','exit','slope'},{'height'}
-- Both angles lie in one settings record (+152 and +172): one batch.
local ANGLE_OFFSET,ANGLE_SPAN={enter=0,exit=20},24

-- Snapshot reads: each is complete or raises; a guard read is verified again
-- before and after writes (guarded).
local function read(api,s,a,n,guard)
    local b=assert(api.read(a,n),'Slope data unavailable');assert(#b==n,'Short slope read')
    if guard then s.guards[#s.guards+1]={address=a,bytes=b} end
    return b
end
local function ptr(api,b,o) return assert(api.pointer(b,o),'Slope pointer unavailable') end
local function global(api,s,game,rva) return ptr(api,read(api,s,game+rva,8,true)) end
-- The low 32 bits of a*b for 32-bit a and b, exact in doubles: no 64-bit cdata.
local function low_product(a,b)
    local a_low,b_low=a%65536,b%65536
    return (a_low*b_low+(((a-a_low)/65536*b_low+a_low*(b-b_low)/65536)%65536)*65536)%4294967296
end
-- The value stored for id in the game hash map at a (header and rows are guards).
local function lookup(api,s,a,id,limit)
    local h=read(api,s,a,20,true)
    local cap,empty,mult=u(h,8),u(h,12),u(h,16)
    assert(cap>0 and cap<=limit and bit.band(cap,cap-1)==0,'Unsupported slope map')
    local data=ptr(api,h)
    local low=low_product(id,mult)
    for i=0,math.min(cap,128)-1 do
        local slot=bit.band(low+i,cap-1)
        local row=read(api,s,data+slot*8,8,true)
        if u(row)==id then return u(row,4) end
        if u(row)==empty then return nil end
    end
end

-- Light reads: the identity chain and the input, read on every check, land in
-- one reused arena through api.read_into (the same ReadProcessMemory as
-- api.read) and decode in place, so an idle check creates no string, table or
-- pointer. Addresses are plain numbers here and reach the api as its own
-- address values: numbers when the game base is a number (the test fixtures),
-- else uint8_t pointers like api.pointer's, made once per address. Each read
-- is recorded (address, size, kind); a snapshot that goes on past the light
-- gate turns its records into guards, in read order: SLOPE ones into its own,
-- VAULT ones (EPOCH: also epoch guards) into the identity the vault snapshot of
-- the same check takes over instead of reading that chain again. The kinds
-- match the guards the vault snapshot gives these reads itself.
local SLOPE,VAULT,EPOCH=1,2,4
local CHAIN,OWNED=SLOPE+VAULT,SLOPE+VAULT+EPOCH
-- A slot holds the largest light read (0x44 bytes). 208 slots cover the most
-- reads one snapshot can make: 7 for the player, 2 globals, two maps of up to
-- 1 + 128 and 1 + 64 rows, the entity, the avatar count, the registry pair
-- and the input.
local SLOT,SLOTS=72,208
local arena=ffi.new('uint8_t[?]',SLOT*SLOTS)
local words=ffi.cast('uint32_t *',arena)
local slots={}
for i=0,SLOTS-1 do slots[i]=arena+i*SLOT end
local recorded_address,recorded_size=ffi.new('double[?]',SLOTS),ffi.new('int32_t[?]',SLOTS)
local recorded_kind=ffi.new('uint8_t[?]',SLOTS)
local reads=0
local POINTER=ffi.typeof('uint8_t *')
local numeric,pointers,cached=false,{},0
local function api_address(n)
    if numeric then return n end
    local p=pointers[n]
    if p then return p end
    if cached>=1024 then pointers,cached={},0 end
    p=ffi.cast(POINTER,n);pointers[n]=p;cached=cached+1
    return p
end
local game_object,game_number
local function base_of(game)
    numeric=type(game)=='number'
    if numeric then return game end
    if game~=game_object then game_object,game_number=game,tonumber(ffi.cast('uintptr_t',game)) end
    return game_number
end
-- Reads size bytes at address into the next slot; its index, or raises.
local function light_read(api,address,size,kind)
    local slot=reads
    assert(slot<SLOTS,'Slope read budget exceeded')
    assert(api.read_into(api_address(address),size,slots[slot]),'Slope data unavailable')
    recorded_address[slot],recorded_size[slot],recorded_kind[slot]=address,size,kind
    reads=slot+1
    return slot
end
local function word(slot,offset) return words[slot*18+offset/4] end
local function byte_at(slot,offset) return arena[slot*SLOT+offset] end
-- The user-mode pointer at offset of a slot as a number (api.pointer's rule:
-- at least 0x10000 and below 2^47), else raises.
local function light_pointer(slot,offset)
    local high=word(slot,offset+4)
    local value=high<0x8000 and high*4294967296+word(slot,offset)
    return assert(value and value>=0x10000 and value,'Slope pointer unavailable')
end
local function light_global(api,base,rva,kind) return light_pointer(light_read(api,base+rva,8,kind),0) end
-- True when the 8 bytes at offset of a slot hold pointer p (no range check).
local function holds(slot,offset,p) return word(slot,offset+4)*4294967296+word(slot,offset)==p end
-- The value stored for id in the game hash map at address (header and rows are guards).
local function light_lookup(api,address,id,limit)
    local h=light_read(api,address,20,CHAIN)
    local cap,empty=word(h,8),word(h,12)
    assert(cap>0 and cap<=limit and bit.band(cap,cap-1)==0,'Unsupported slope map')
    local data=light_pointer(h,0)
    local low=low_product(id,word(h,16))
    for i=0,math.min(cap,128)-1 do
        local row=light_read(api,data+bit.band(low+i,cap-1)*8,8,CHAIN)
        local key=word(row,0)
        if key==id then return word(row,4) end
        if key==empty then return nil end
    end
end

-- True while a mission runs (the mode pointer and record).
local function in_mission(api,base)
    local mode=light_read(api,light_global(api,base,0x33266a0,CHAIN),0x44,CHAIN)
    return word(mode,8)~=0 and word(mode,0x40)>=1 and word(mode,0x40)<=7
end
-- The local player's unit reference while a mission runs, else nil and why.
local found_pm
local function local_ref(api,base)
    if not in_mission(api,base) then return nil,'outside_mission' end
    local pm=light_global(api,base,0x3326468,OWNED)
    local counts=light_read(api,pm+0x84,8,VAULT)
    assert(word(counts,0)<=4 and word(counts,4)<=4,'Unsupported player count')
    if word(counts,0)==0 or word(counts,4)==0 then return nil,'no_local_avatar' end
    if bit.band(byte_at(light_read(api,light_pointer(light_read(api,pm+0xe8,8,OWNED),0),24,OWNED),20),1)==0 then
        return nil,'no_local_avatar'
    end
    found_pm=pm
    return word(light_read(api,pm+0x3a8,4,OWNED),0)
end

-- Resource 0x4d1c334d294dfa97 as two 32-bit words.
local AVATAR_LOW,AVATAR_HIGH=0x294dfa97,0x4d1c334d
-- The identity found by the light reads: the avatar's unit reference, ID and
-- unit, owner and manager, its avatar index, the slot and address of its
-- entity record, and the registry's pointer to that record.
local found_ref,found_id,found_unit,found_owner,found_manager,found_ai,found_entity,found_address,found_registry
-- The avatar entity of ref: its slot, else nil and why.
local function avatar_entity(api,key,owner,ref)
    local ei=light_lookup(api,owner+0xf22ec8,ref,1048576)
    if not ei or ei==INVALID then return nil,'gone' end
    assert(ei<262144,'Unsupported entity index')
    local address=owner+0xf32f18+ei*24
    local entity=light_read(api,address,24,OWNED)
    if word(entity,0)~=AVATAR_LOW or word(entity,4)~=AVATAR_HIGH then return nil,'gone' end
    if key and (key.id~=word(entity,8) or key.unit~=word(entity,12)) then return nil,'gone' end
    if not key and bit.band(byte_at(entity,20),1)==0 then return nil,'no_local_avatar' end
    found_entity,found_address=entity,address
    return entity
end

-- The 24-byte records in slots a and b hold the same bytes.
local function same_record(a,b)
    for offset=0,20,4 do
        if word(a,offset)~=word(b,offset) then return false end
    end
    return true
end
-- The avatar index of id, checked against the avatar count and the registry.
local function avatar_index(api,manager,id,entity)
    local ai=light_lookup(api,manager+0xf8,id,64)
    if not ai or ai==INVALID then return nil end
    assert(ai<word(light_read(api,manager+0x6c,4,VAULT),0) and ai<8,'Unsupported avatar index')
    found_registry=light_pointer(light_read(api,manager+0x110+ai*8,8,OWNED),0)
    assert(same_record(light_read(api,found_registry,24,OWNED),entity),'Avatar registry mismatch')
    return ai
end

-- Resolves the local avatar, or with a saved key that same avatar, through
-- light reads: true, else nil and why. A saved identity is used only for
-- cleanup. It can locate the original avatar after registry compaction or a
-- local-player switch, never grant a new lease.
local function identify(api,base,key)
    local ref,why
    if key then ref=key.ref else ref,why=local_ref(api,base) end
    if not ref then return nil,why end
    if ref==0x7fff then return nil,'gone' end
    local owner,manager=light_global(api,base,0x346bf98,OWNED),light_global(api,base,0x3326d20,OWNED)
    if key and (api.distance(api_address(owner),key.owner)~=0 or api.distance(api_address(manager),key.manager)~=0) then
        return nil,'gone'
    end
    local entity
    entity,why=avatar_entity(api,key,owner,ref)
    if not entity then return nil,why end
    local id=word(entity,8)
    local ai=avatar_index(api,manager,id,entity)
    if not ai then return nil,'gone' end
    found_ref,found_id,found_unit,found_owner,found_manager,found_ai=ref,id,word(entity,12),owner,manager,ai
    return true
end

-- The kept identity: identify() without a saved key keeps where it found the
-- local avatar (player manager, unit reference, entity record and its bytes,
-- avatar index and the registry's pointer). While the input stays released a
-- check only verifies it: the input at the kept index, the mission, the unit
-- reference, the entity record at the kept address (resource, ID, unit and
-- alive flag) and the registry slot at the kept index, 6 reads instead of 18.
-- A difference, a press or a failed check resolves everything again
-- (identify) before anything is armed or written.
local kept=false
local kept_pm,kept_ref,kept_owner,kept_manager,kept_ai,kept_address,kept_registry
local kept_entity={0,0,0,0,0,0}
local function keep_identity()
    kept_pm,kept_ref,kept_owner,kept_manager,kept_ai=found_pm,found_ref,found_owner,found_manager,found_ai
    kept_address,kept_registry=found_address,found_registry
    for i=0,5 do kept_entity[i+1]=word(found_entity,i*4) end
    kept=true
end
-- true when the kept identity holds, nil and why outside a mission, else false.
local function verify_identity(api,base)
    if not in_mission(api,base) then kept=false;return nil,'outside_mission' end
    if word(light_read(api,kept_pm+0x3a8,4,OWNED),0)~=kept_ref then return false end
    local entity=light_read(api,kept_address,24,OWNED)
    for i=0,5 do if word(entity,i*4)~=kept_entity[i+1] then return false end end
    if not holds(light_read(api,kept_manager+0x110+kept_ai*8,8,OWNED),0,kept_registry) then return false end
    found_ref,found_id,found_unit,found_owner,found_manager,found_ai=kept_ref,kept_entity[3],kept_entity[4],
        kept_owner,kept_manager,kept_ai
    found_entity,found_address=entity,kept_address
    return true
end

-- The light snapshot of an idle check: the input released. One table, reused
-- by every idle check; vault_phase is the address of the avatar's vault
-- controller phase word, which the vault check reads next.
local IDLE={manual=false}
-- True when the input is released (a light read, a guard).
local function released(api)
    local input=light_read(api,found_manager+0x150+found_ai*0xa7aec+0x1b68+14*32,1,SLOPE)
    return byte_at(input,0)==0
end
-- The snapshot goes on past the light gate: its light reads become guards, in
-- read order (SLOPE: its own; VAULT: s.identity, the identity chain's guards
-- for the vault snapshot of this check), and the identity takes the api's
-- address values. Returns the snapshot and the entity record's bytes.
local function adopt(vault_phase)
    local s={guards={},identity={}}
    for slot=0,reads-1 do
        local kind=recorded_kind[slot]
        if kind~=0 then
            local g={address=api_address(recorded_address[slot]),bytes=ffi.string(slots[slot],recorded_size[slot])}
            if bit.band(kind,SLOPE)~=0 then s.guards[#s.guards+1]=g end
            if bit.band(kind,VAULT)~=0 then s.identity[#s.identity+1]=g;g.epoch=bit.band(kind,EPOCH)~=0 end
        end
    end
    s.entity=api_address(found_address);s.ai=found_ai;s.vault_phase=vault_phase
    s.key={ref=found_ref,id=found_id,unit=found_unit,owner=api_address(found_owner),manager=api_address(found_manager)}
    s.entity_bytes=ffi.string(slots[found_entity],24)
    return s,s.entity_bytes
end

-- The local movement and mover records.
local function mover_records(api,s,game,id)
    local mm=global(api,s,game,0x3326558)
    local mi=lookup(api,s,mm+0x48a0,id,1048576)
    assert(mi and mi~=INVALID and mi<8192,'Movement unavailable')
    local move=read(api,s,ptr(api,read(api,s,mm+0x48c8,8,true))+mi*132,132)
    local mover_address=ptr(api,read(api,s,mm+0x48d0,8,true))+mi*164
    local mover=read(api,s,mover_address,164)
    read(api,s,mover_address+76,16,true)
    return move,mover
end

-- The mover's handle and character controller object, verified through the
-- handle pool, the mover record and the shared mover definition.
local function controller_object(api,s,exe,mover)
    local handle=u(mover,88)
    local pool=ptr(api,read(api,s,exe+0x27c3298+bit.rshift(handle,30)*0x810,8,true))
    local h=read(api,s,pool,56,true)
    local index=bit.band(handle,u(h,40))
    assert(index>=0 and index<u(h,36) and bit.band(handle,u(h,52))~=0,'Invalid mover handle')
    local layout=u(h,28)
    local start=ptr(api,h)+index*bit.band(layout,65535)
    assert(u(read(api,s,start+bit.band(bit.rshift(layout,16),255),4,true))==handle,'Reused mover handle')
    local record=read(api,s,start+bit.rshift(layout,24),32,true)
    assert(u(record,8)==s.key.unit,'Mover belongs to another unit')
    local definition,object=ptr(api,record,16),ptr(api,record,24)
    local def=read(api,s,definition,28,true)
    assert(u(def)==u(mover,76),'Mover name mismatch')
    assert(api.distance(ptr(api,read(api,s,object,8,true)),exe+0x16a16d8)==0,'Unsupported character controller')
    local up=vec(read(api,s,object+80,12,true),0)
    assert(math.abs(up[1])+math.abs(up[2])+math.abs(up[3]-1)<0.001,'Unsupported up vector')
    -- Preserve the separate 70-degree support/drop limit and shared definition.
    assert(math.abs(f(def,20)-50*math.pi/180)<0.001 and math.abs(f(def,24)-70*math.pi/180)<0.001,
        'Unsupported mover definition')
    assert(math.abs(f(read(api,s,object+100,4,true))-math.cos(70*math.pi/180))<0.001,'Unsupported support filter')
    return handle,object
end

-- The effective settings record: the avatar's own override, whose angle and
-- height cells an assist may write, or the shared component record. Only the
-- span an assist uses is read: walking speed (+12) through ground climb height
-- (+260), 252 of the record's 852 bytes; SETTINGS maps record offsets into it.
local SETTINGS_FROM,SETTINGS_SIZE=12,252
local SETTINGS={walk=0,enter=152-12,exit=172-12,height=260-12}
local function settings_record(api,s,entity)
    local manager=s.key.manager
    local oi=lookup(api,s,manager+0x547c70,s.key.id,64)
    if oi and oi~=INVALID then
        assert(oi<8,'Unsupported avatar override')
        local base=manager+0x547d24+oi*852
        local settings=read(api,s,base+SETTINGS_FROM,SETTINGS_SIZE)
        s.cells.enter=base+152;s.cells.exit=base+172;s.cells.height=base+260
        return settings
    end
    local component=ptr(api,read(api,s,s.key.owner+0xf12bb8,8,true))
    local map=read(api,s,component,32,true);local found=false
    for i=0,1 do
        if map:sub(i*16+1,i*16+8)==entity:sub(1,8) and u(map,i*16+8)==0 then found=true end
    end
    assert(found,'Unsupported avatar resource map')
    return read(api,s,component+32+SETTINGS_FROM,SETTINGS_SIZE)
end

-- The settings an assist checks and the current bytes of every cell it may write.
local function settings_values(api,s,settings)
    -- Native allocation has a fixed eight-record capacity in this build.
    s.override_count=u(read(api,s,s.key.manager+0x547d20,4,true))
    assert(s.override_count<=8,'Unsupported override count')
    local at=SETTINGS
    s.walk=f(settings,at.walk);s.enter=f(settings,at.enter);s.exit=f(settings,at.exit);s.ground_max=f(settings,at.height)
    assert(finite(s.walk) and s.walk>0 and s.walk<=10,'Unsupported walking speed')
    s.values={cap=read(api,s,s.cells.cap,4),slope=read(api,s,s.cells.slope,4)}
    -- The override's cells are in the settings just read (arm reads each cell
    -- again right before writing it).
    if s.cells.enter then
        s.values.enter=settings:sub(at.enter+1,at.enter+4);s.values.exit=settings:sub(at.exit+1,at.exit+4)
        s.values.height=settings:sub(at.height+1,at.height+4)
    end
end

-- Input, movement flags, ground contact and the native mover position.
local function motion(api,s,game,exe,move)
    local manager,ai=s.key.manager,s.ai
    s.manual=read(api,s,manager+0x150+ai*0xa7aec+0x1b68+14*32,1,true):byte()~=0
    local flags=read(api,s,manager+0x53e880+ai*0x1238,24,true)
    s.climbing=bit.band(u(flags,12),0x200)~=0
    s.eligible=bit.band(u(flags),2)~=0 and bit.band(u(flags),0x404000)==0
        and bit.band(u(flags,4),0x8000000)==0 and bit.band(u(flags,8),0x20084000)==0
        and bit.band(u(flags,12),0x5181c)==0 and bit.band(u(flags,16),9)==0
    s.ground=bit.band(u(flags,8),4)==0 and bit.band(u(flags,12),0x26)==0
        and move:byte(16)==0 and move:byte(13)==0
    local n=vec(move,20);local length=math.sqrt(n[1]^2+n[2]^2+n[3]^2)
    s.normal_z=finite(length) and length>0.99 and length<1.01 and n[3]/length or -1
    s.native=assert(api.native(game,exe),'Native slope support unavailable')
    s.root=s.native.mover_position(s.key.unit,s.mover_name)
    assert(s.root and finite(s.root[1]) and finite(s.root[2]) and finite(s.root[3]),'Invalid mover position')
end

-- An idle check through the kept identity: IDLE, nil and why outside a
-- mission, or false when the chain must be resolved (a press or a difference).
-- The input comes first, at the kept avatar index: a press resolves the full
-- chain anyway, so a press check makes one read more than before, not six. A
-- released input counts only once the identity holds.
local function kept_idle(api,base)
    found_manager,found_ai=kept_manager,kept_ai
    if not released(api) then return false end
    local found,why=verify_identity(api,base)
    if not found then return found,why end
    IDLE.vault_phase=api_address(found_manager+0x53e1b8+found_ai*0x1238+4)
    return IDLE
end

-- light: no lease, so a released input ends the check after the identity.
-- verify: the previous check also ended there, so the kept identity may stand
-- in for the full chain while the input stays released.
function A.snapshot(api,game,exe,key,light,verify)
    reads=0
    local base=base_of(game)
    if verify and not key and kept then
        local idle,outside=kept_idle(api,base)
        if idle~=false then return idle,outside end
        reads=0
    end
    local found,why=identify(api,base,key)
    if not key then if found then keep_identity() else kept=false end end
    if not found then return nil,why end
    local vault_phase=api_address(found_manager+0x53e1b8+found_ai*0x1238+4)
    -- With no lease and the manual input released, A.step uses only the
    -- input state. The mover, controller, settings and flags are read and
    -- validated in full as soon as the input is pressed, and on every
    -- lease check.
    if light and not key and released(api) then
        IDLE.vault_phase=vault_phase
        return IDLE
    end
    local s,entity=adopt(vault_phase)
    local manager,ai,id=s.key.manager,s.ai,s.key.id
    assert(u(read(api,s,manager+0x53e1b8+ai*0x1238+0x2ac,4,true))==id,'Vault identity mismatch')
    local direction=manager+0x53e134+ai*0x1238
    assert(u(read(api,s,direction+40,4,true))==id,'Movement direction identity mismatch')
    local move,mover=mover_records(api,s,game,id)
    local handle,object=controller_object(api,s,exe,mover)
    s.manager=manager;s.handle=handle;s.object=object;s.mover_name=u(mover,76)
    s.cells={cap=direction+8,slope=object+96}
    settings_values(api,s,settings_record(api,s,entity))
    if key then return s end
    motion(api,s,game,exe,move)
    return s
end

local function guarded(api,s)
    for _,g in ipairs(s.guards) do if api.read(g.address,#g.bytes)~=g.bytes then return false end end
    return true
end
local function same(api,a,b)
    return a.id==b.id and a.unit==b.unit and a.ref==b.ref
        and api.distance(a.manager,b.manager)==0 and api.distance(a.owner,b.owner)==0
end

-- Restores the owned angles with one protection query; after a failure the
-- remaining ones are still tried one by one, as every restore is.
local function restore_angles(api,s,angles)
    local changes={}
    for i,w in ipairs(angles) do changes[i]={ANGLE_OFFSET[w.name],w.before} end
    local restored,landed=api.write_batch(s.cells.enter,ANGLE_SPAN,changes)
    if not restored then
        for i=landed+2,#angles do api.write(s.cells[angles[i].name],angles[i].before) end
    end
    for _,w in ipairs(angles) do
        if api.read(s.cells[w.name],4)~=w.before then restored=false end
    end
    return restored
end

-- A refused protection check before any write of a region (nil) is reported as
-- data that changed before the commit, as the separate check did; any other
-- failure is a failed write (false).
local function refused(api,address,size,landed)
    if landed==0 and not api.writable_data(address,size) then return nil end
    return false
end

-- Writes an assist with one protection query per region: the angles share the
-- settings record, the slope cosine is in the controller object and the ledge
-- height is alone. Each write is read back. True, nil (refused) or false.
local function write_cells(api,s,writes)
    if writes[1].name=='enter' then
        local written,landed=api.write_batch(s.cells.enter,ANGLE_SPAN,
            {{ANGLE_OFFSET.enter,writes[1].after},{ANGLE_OFFSET.exit,writes[2].after}})
        if not written then return refused(api,s.cells.enter,ANGLE_SPAN,landed) end
        if not api.write(s.cells.slope,writes[3].after) then return refused(api,s.cells.slope,4,0) end
    elseif not api.write(s.cells.height,writes[1].after) then
        return refused(api,s.cells.height,4,0)
    end
    for _,w in ipairs(writes) do
        if api.read(s.cells[w.name],4)~=w.after then return false end
    end
    return true
end

-- True when the cell holds this write's bytes, or a byte mix of a partial
-- write (every byte from before or after).
local function owned(w,current)
    if current==w.after then return true end
    if not (w.partial and current and current~=w.before) then return false end
    for j=1,4 do
        local c=current:byte(j)
        if c~=w.before:byte(j) and c~=w.after:byte(j) then return false end
    end
    return true
end

-- Restores one lease write on release; owned angles are collected for one
-- batch. False when the cell cannot be read or restored.
local function release_cell(api,s,lease,w,angles)
    local address=s.cells[w.name]
    -- A replacement mover has its own defaults; never restore into it.
    if w.name=='slope' and (lease.handle~=s.handle or api.distance(lease.object,s.object)~=0) then address=nil end
    if not address then return true end
    local current=api.read(address,4)
    if current==nil then return false end
    if not owned(w,current) then return true end
    if ANGLE_OFFSET[w.name] then angles[#angles+1]=w;return true end
    return api.write(address,w.before) and api.read(address,4)==w.before
end

function A.stop(api,game,exe,state)
    local lease=state.slope_lease
    if not lease then return true end
    local ok,s,why=pcall(A.snapshot,api,game,exe,lease.key)
    if not ok then return false end
    if not s then
        if why=='gone' then state.slope_lease=nil;return true end
        return false
    end
    -- Verified once before the writes: between here and them only these cells
    -- are read and written.
    if not guarded(api,s) then return false end
    local restored,angles=true,{}
    for i=#lease.writes,1,-1 do
        if not release_cell(api,s,lease,lease.writes[i],angles) then restored=false end
    end
    if #angles>0 and not restore_angles(api,s,angles) then restored=false end
    if restored then state.slope_lease=nil end
    return restored
end

-- Decisions use actual native climbing and ground contact, not query readiness.
-- Stable steep support has no timer that would unexpectedly drop a stationary
-- player. It remains walking-only inside the original three-metre area.
function A.keep(lease,s,now)
    if not s.eligible then return false,'ineligible' end
    local dx,dy,dz=s.root[1]-lease.anchor[1],s.root[2]-lease.anchor[2],s.root[3]-lease.anchor[3]
    if dx*dx+dy*dy>A.radius^2 or math.abs(dz)>3 then return false,'left_area' end
    if s.climbing then
        if now>lease.started+8 then return false,'climb_timeout' end
        lease.phase='climb';lease.last_climb=now;return true
    end
    if lease.phase=='attempt' then return now<=lease.started+1.25,'attempt_timeout' end
    if lease.kind=='ledge' then return false,'ledge_climb_finished' end
    if s.ground and s.normal_z>=COS then
        lease.air_since=nil
        if s.normal_z<math.cos(44*math.pi/180) then
            lease.phase='support';lease.flat_since=nil;return true
        end
        lease.flat_since=lease.flat_since or now
        return now-lease.flat_since<0.35,'flat_ground'
    end
    lease.air_since=lease.air_since or now
    return now-lease.air_since<0.25,'unsupported'
end

-- Ends the assist with this status, restoring every cell it still owns.
local function finish(api,game,exe,state,reason)
    state.slope_status=reason
    state.assist_intent=nil
    if state.slope_lease then state.slope_last_release=reason end
    if state.slope_lease and state.slope_lease.kind=='ledge' and reason=='attempt_timeout' then
        state.ledge_attempt_expiries=(state.ledge_attempt_expiries or 0)+1
    end
    if not A.stop(api,game,exe,state) then return false,'slope_restore_failed' end
    return true
end

-- The snapshot still shows the lease's avatar and mover, and the bytes it wrote.
local function lease_holds(api,lease,s)
    if not same(api,lease.key,s.key) or lease.handle~=s.handle or api.distance(lease.object,s.object)~=0 then
        return false,'identity_changed'
    end
    for _,w in ipairs(lease.writes) do
        if s.values[w.name]~=w.after then return false,'settings_changed' end
    end
    return true
end

-- No movement cap during detection or a rejected attempt: it is applied only
-- after this assisted attempt actually enters native climbing. Returns nothing
-- once capped, else the step's result.
local function cap_speed(api,game,exe,state,s,lease)
    local cap=f(s.values.cap)
    if not finite(cap) or not guarded(api,s) then return finish(api,game,exe,state,'speed_cap_unavailable') end
    local w={name='cap',before=s.values.cap,after=bytes(cap>=0 and math.min(cap,s.walk) or s.walk),partial=true}
    lease.writes[#lease.writes+1]=w
    if not api.write(s.cells.cap,w.after) or api.read(s.cells.cap,4)~=w.after then
        local restored=A.stop(api,game,exe,state)
        return false,restored and 'speed_cap_write_failed' or 'slope_restore_failed'
    end
    w.partial=false;lease.speed_capped=true
end

-- Counts the phases the lease enters.
local function count_phase(state,lease,previous)
    if lease.phase=='climb' and previous~='climb' then
        state.slope_climbs=(state.slope_climbs or 0)+1
        if lease.kind=='ledge' then state.ledge_climbs=(state.ledge_climbs or 0)+1 end
    end
    if lease.phase=='support' and previous~='support' then state.slope_landings=(state.slope_landings or 0)+1 end
end

-- One poll of an armed lease: keep it, cap the speed once it climbs, or end it.
local function hold(api,game,exe,state,s,now)
    local lease=state.slope_lease
    local holds,why=lease_holds(api,lease,s)
    if not holds then return finish(api,game,exe,state,why) end
    local previous=lease.phase
    local keep
    keep,why=A.keep(lease,s,now)
    if not keep then return finish(api,game,exe,state,why) end
    if lease.kind=='slope' and lease.phase~='attempt' and not lease.speed_capped then
        local result,reason=cap_speed(api,game,exe,state,s,lease)
        if result~=nil then return result,reason end
    end
    count_phase(state,lease,previous)
    state.slope_status=lease.phase;return true
end

-- The default slide settings: 45 and 40 degrees, slope cosine of 50 degrees.
local function default_slide(s)
    return not (s.enter~=45 or s.exit~=40 or math.abs(f(s.values.slope)-math.cos(50*math.pi/180))>0.001)
end
-- A ledge assist needs ground contact and the default ground climb height.
local function ledge_unfit(kind,s)
    return kind=='ledge' and (not s.ground or math.abs(s.ground_max-1.95)>0.001)
end

-- True when this poll checks for a candidate: a fresh press opened a 1.25 s
-- window for this avatar, eligible and not climbing yet; at most every 0.1 s,
-- with default slide settings and unchanged guards.
local function candidate_due(api,state,s,now,rising)
    state.slope_status='waiting_for_manual_climb'
    if rising then state.assist_intent={key=s.key,deadline=now+1.25} end
    if not s.manual or not s.eligible or s.climbing then state.assist_intent=nil;return false end
    local intent=state.assist_intent
    if not intent or now>intent.deadline or not same(api,intent.key,s.key) then state.assist_intent=nil;return false end
    if intent.checked and now-intent.checked<0.1 then return false end
    intent.checked=now
    if not default_slide(s) then state.slope_status='custom_slope_settings_retained';return false end
    return guarded(api,s)
end

-- The assist a fresh native candidate check allows here: 'slope', 'ledge' or nil.
local function validated_kind(api,game,exe,state,s)
    state.candidate_checks=(state.candidate_checks or 0)+1
    local kind,reason
    if A.candidate then kind,reason=A.candidate(api,game,exe,state,s) end
    state.candidate_reason=reason or 'candidate_validator_unavailable'
    if kind~='slope' and kind~='ledge' or ledge_unfit(kind,s) or not guarded(api,s) then return nil end
    return kind
end

-- Without its own settings record the avatar gets one from the original
-- AvatarComponent modifier routine: a zero-count modifier descriptor copies the
-- base record into an engine-owned local override. Returns the new snapshot
-- while it still allows this assist.
local function with_override(api,game,exe,state,s,kind)
    if s.override_count>=8 then state.slope_status='override_capacity_reached';return nil end
    s.native.ensure_override(s.manager,s.entity)
    state.slope_overrides=(state.slope_overrides or 0)+1
    local fresh=A.snapshot(api,game,exe)
    if not fresh or not same(api,s.key,fresh.key) or not fresh.cells.enter or not fresh.manual or not fresh.eligible
        or not default_slide(fresh) or ledge_unfit(kind,fresh) or not guarded(api,fresh) then return nil end
    return fresh
end

-- Arms the lease: every cell must still hold what the snapshot read; the guards
-- were verified after the last native call (the candidate check or the override
-- creation) and are verified again after the writes.
local function arm(api,game,exe,state,s,kind,now)
    local lease={key=s.key,handle=s.handle,object=s.object,anchor=s.root,started=now,kind=kind,phase='attempt',writes={}}
    state.slope_lease=lease
    state.assist_intent=nil
    local names=kind=='ledge' and LEDGE_CELLS or SLOPE_CELLS
    for _,name in ipairs(names) do
        if api.read(s.cells[name],4)~=s.values[name] then return finish(api,game,exe,state,'slope_changed_before_commit') end
    end
    -- Every write is in the lease before the attempt: a failed one may land in
    -- part, and the restore decides per cell what is ours.
    for _,name in ipairs(names) do
        lease.writes[#lease.writes+1]={name=name,before=s.values[name],after=ASSIST[name],partial=true}
    end
    local written=write_cells(api,s,lease.writes)
    if written==nil then return finish(api,game,exe,state,'slope_changed_before_commit') end
    if not written then
        local restored=A.stop(api,game,exe,state)
        return false,restored and 'slope_write_failed' or 'slope_restore_failed'
    end
    for _,w in ipairs(lease.writes) do w.partial=false end
    if not guarded(api,s) then return finish(api,game,exe,state,'slope_changed_after_commit') end
    state.slope_arms=(state.slope_arms or 0)+1
    if kind=='ledge' then state.ledge_arms=(state.ledge_arms or 0)+1 end
    state.slope_status='attempt'
    return true
end

function A.step(api,game,exe,state)
    -- state.avatar: this poll's verified local avatar, for the vault check
    -- that follows in the same poll (vault_data.lua), else nil.
    state.avatar=nil
    local light=not state.slope_lease
    local ok,s,why=pcall(A.snapshot,api,game,exe,nil,light,light and state.slope_down==false)
    if not ok or not s then
        -- Require a fresh input release after transitions or unavailable data.
        state.slope_down=true
        -- false: outside a mission, which the vault check need not read again.
        if ok and why=='outside_mission' then state.avatar=false end
        return finish(api,game,exe,state,ok and 'waiting_for_avatar' or 'waiting_for_slope_data')
    end
    state.avatar=s
    local rising=s.manual and state.slope_down==false
    state.slope_down=s.manual
    -- No lease and the input released: nothing below runs, nor needs the time.
    if not state.slope_lease and not s.manual then
        state.slope_status='waiting_for_manual_climb';state.assist_intent=nil;return true
    end
    local now=api.time()
    if state.slope_lease then return hold(api,game,exe,state,s,now) end
    if not candidate_due(api,state,s,now,rising) then return true end
    local kind=validated_kind(api,game,exe,state,s)
    if not kind then return true end
    if not s.cells.enter then
        s=with_override(api,game,exe,state,s,kind)
        if not s then return true end
    end
    return arm(api,game,exe,state,s,kind,now)
end

-- Machine code: the helpers of every check compile: the light reads, their
-- decoding, map probes and record compare, and the full snapshot's string read
-- helpers. The straight-line stages that call them (the identity chain, the
-- snapshot and the step) run once per check and stay interpreted, like the
-- rest, which runs while the input is held or an assist is armed: there system
-- calls dominate. Compiled, the whole idle check became one long trace per
-- check state, about 100 KB more of the LuaJIT code cache that the game and
-- every mod share in a session, for about 1 us less per idle frame in the game's
-- lua51.dll (offline). true selects this chunk, the second true every function
-- in it; the helpers are compiled again by name. Nothing is flushed.
if jit and jit.off then
    jit.off(true,true)
    for _,fn in ipairs({u,float_bits,f,read,ptr,global,lookup,api_address,light_read,word,byte_at,light_pointer,
        holds,low_product,light_lookup,same_record}) do jit.on(fn) end
end
return A
