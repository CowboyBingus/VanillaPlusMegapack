local ffi,bit=require('ffi'),require('bit')
local M={}
-- A snapshot allocates nothing on idle and flight frames. Every read lands in
-- one reused arena (8-byte aligned) through api.read(address, size, into,
-- offset), addresses are plain numbers, fields decode in place and pointers
-- from two 32-bit halves. The read budget, 160 reads, and the arena size bound
-- every snapshot (the largest read, the avatar registry block, is 228 bytes).
local READS,ARENA=160,160*0x48
local arena=ffi.new('uint8_t[?]',ARENA)
local words=ffi.cast('uint32_t *',arena)
local into={data=arena,address=tonumber(ffi.cast('uintptr_t',arena)),size=ARENA}
-- An 8-byte resource ID as its two 32-bit words.
local function resource(hex)
    local id=ffi.new('uint32_t[2]')
    ffi.copy(id,(hex:gsub('..',function(x)return string.char(tonumber(x,16))end)):reverse(),8)
    return id[0],id[1]
end
local AVATAR_LOW,AVATAR_HIGH=resource('4d1c334d294dfa97')
local HOVER_LOW,HOVER_HIGH=resource('5ec80f4f1cdb66cf')
-- Waiting reasons, raised as the same two objects every time.
local WAIT_READ={hover_wait=true,reason='waiting_for_read'}
local WAIT_POINTER={hover_wait=true,reason='waiting_for_pointer'}
-- Every field a snapshot returns: one table, reused by every snapshot. Its
-- values hold until the next snapshot.
local S={mission_type=0,down=false,active=false,flight=false,key='',identity='',manager=0,pack=0}
-- The kept layout (see "Kept layout" below): where the full resolution found
-- the local avatar, its equipment row, the pack and their identity records.
-- stage is how far it got: 0 none, 1 avatar, 2 equipment row, 3 jump-pack
-- registry (ji nil: the backpack is no jump pack), 4 everything.
local L={stage=0,aw={0,0,0,0,0,0},ew={0,0,0,0,0,0}}
local function forget()L.stage=0 end

-- The running snapshot: adapter, game.dll address, reads and arena bytes used.
local reader,base,reads,used=nil,0,0,0
local game_pointer,game_address
local function address_of(game)
    if type(game)=='number' then return game end
    if game~=game_pointer then game_pointer,game_address=game,tonumber(ffi.cast('uintptr_t',game)) end
    return game_address
end
local function u(o)return words[o/4]end
-- A failed read or pointer also drops the kept layout: an address that no
-- longer reads must not be tried again on every frame.
local function read(address,size)
    reads=reads+1;assert(reads<=READS and used+size<=ARENA,'Hover read budget exceeded')
    local o=used
    if not reader.read(address,size,into,o) then forget();error(WAIT_READ,0) end
    used=o+size+(-size)%8
    return o
end
-- The user-mode pointer stored at arena offset o, as a number.
local function pointer(o)
    local p=words[o/4+1]*4294967296+words[o/4]
    if p<0x10000 or p>=0x800000000000 then forget();error(WAIT_POINTER,0) end
    return p
end
-- True when the 8 bytes at arena offset o hold pointer p (no range check).
local function holds(o,p)return words[o/4+1]*4294967296+words[o/4]==p end
-- The float at arena offset o, decoded from its bits. A NaN loaded through a
-- float cdata can become a non-number value in the game's NaN-tagged LuaJIT;
-- decoded here it is a plain NaN.
local function float(o)
    local w=words[o/4];local e,m=bit.band(bit.rshift(w,23),0xff),bit.band(w,0x7fffff)
    local v
    if e==0xff then v=m==0 and math.huge or 0/0 elseif e==0 then v=m*2^-149 else v=(m+0x800000)*2^(e-150) end
    if w>=0x80000000 then return -v end
    return v
end
local function global(rva)return pointer(read(base+rva,8))end
-- Low 32 bits of key*mult from 16-bit halves: exact in doubles, no 64-bit cdata.
local function hash(key,mult)
    local kl,kh,ml,mh=bit.band(key,0xffff),bit.rshift(key,16),bit.band(mult,0xffff),bit.rshift(mult,16)
    return kl*ml+bit.band(kh*ml+kl*mh,0xffff)*65536
end
local function lookup(h,key,limit)
    local cap,empty,mult=u(h+8),u(h+12),u(h+16)
    if cap==0 then return nil end
    assert(cap<=limit and bit.band(cap,cap-1)==0,'Unsupported hover map')
    local product=hash(key,mult)
    local data=pointer(h)
    for probe=0,math.min(cap,64)-1 do
        local row=read(data+8*bit.band(product+probe,cap-1),8)
        if u(row)==key then local i=u(row+4);if i~=0xffffffff then return i end;return nil end
        if u(row)==empty then return nil end
    end
end
-- The 24-byte records at arena offsets a and b hold the same bytes.
local function same_record(a,b)
    for i=0,5 do if words[a/4+i]~=words[b/4+i] then return false end end
    return true
end
-- Keep the 24-byte record at arena offset o in t, or compare it with t.
local function keep(t,o)for i=0,5 do t[i+1]=words[o/4+i] end end
local function kept(t,o)
    for i=0,5 do if t[i+1]~=words[o/4+i] then return false end end
    return true
end

-- Full resolution -------------------------------------------------------------
-- True, or nil and why.
local function mission()
    local mode=read(global(0x33266a0),0x44)
    -- +0x40 is a mission type, not a boolean. Native player logic at 602d20
    -- accepts 1..7; Evacuate High-Value Assets uses 2 on the supported build.
    S.mission_type=u(mode+0x40)
    if u(mode+8)==0 or S.mission_type<1 or S.mission_type>7 then return nil,'waiting_for_mission'end
    return true
end
-- The local player's unit, or nil and why.
local function local_unit()
    local pm=global(0x3326468);local counts=read(pm+0x84,8)
    assert(u(counts)<=4 and u(counts+4)<=4,'Unsupported player count')
    if u(counts)==0 or u(counts+4)==0 then return nil,'waiting_for_player'end
    local player=read(pointer(read(pm+0xe8,8)),24)
    if bit.band(arena[player+20],1)==0 then return nil,'waiting_for_player'end
    local unit=u(read(pm+0x3a8,4))
    if unit==0x7fff then return nil,'waiting_for_avatar'end
    L.pm,L.unit=pm,unit
    return unit
end
-- The local avatar's entity record (arena offset), or nil and why.
local function avatar_record(unit)
    local owner=global(0x346bf98)
    local ei=lookup(read(owner+0xf22ec8,20),unit,1048576)
    if not ei then return nil,'waiting_for_avatar'end
    assert(ei<262144,'Unsupported entity index')
    L.avatar=owner+0xf32f18+ei*24
    local avatar=read(L.avatar,24)
    if u(avatar)~=AVATAR_LOW or u(avatar+4)~=AVATAR_HIGH or bit.band(arena[avatar+20],1)==0 then
        return nil,'waiting_for_avatar'
    end
    return avatar
end
-- The avatar manager and the avatar's index in it, or nil and why.
local function avatar_slot(avatar)
    local am=global(0x3326d20)
    local ai=lookup(read(am+0xf8,20),u(avatar+8),64)
    if not ai then return nil,'waiting_for_avatar'end
    local count=u(read(am+0x6c,4))
    assert(count<=8 and ai<count,'Unsupported avatar index')
    local slot=pointer(read(am+0x110+ai*8,8))
    assert(same_record(read(slot,24),avatar),'Avatar identity mismatch')
    L.am,L.ai,L.am_slot=am,ai,slot;keep(L.aw,avatar);L.stage=1
    return am,ai
end
-- The equipped backpack's entity ID, or nil and why. Equipped backpack, then
-- reverse ownership: never choose the first pack.
local function backpack(avatar)
    local equipment=global(0x3326738)
    local qi=lookup(read(equipment+40,20),u(avatar+8),8192)
    if not qi then return nil,'no_backpack'end
    assert(qi<4096,'Unsupported equipment index')
    local ids=pointer(read(equipment+64,8));local slot=pointer(read(ids+qi*8,8))
    assert(same_record(read(slot,24),avatar),'Equipment identity mismatch')
    local rows=pointer(read(equipment+80,8))
    L.eq,L.qi,L.eq_ids,L.eq_slot,L.eq_rows,L.pack_at=equipment,qi,ids,slot,rows,rows+qi*48+12;L.stage=2
    local pack_id=u(read(L.pack_at,4))
    if pack_id==0 or pack_id==0xffffffff then return nil,'no_backpack'end
    return pack_id
end
-- The jump-pack manager, the pack's registry index and its entity record, or
-- nil and why.
local function jump_pack(pack_id)
    local jm=global(0x3326bb8)
    L.jm,L.pack_id=jm,pack_id
    local ji=lookup(read(jm+32,20),pack_id,128)
    if not ji then L.ji=nil;L.stage=3;return nil,'no_jump_pack'end
    local counts=read(jm+16,8);local total,owned=u(counts),u(counts+4)
    assert(owned<=total and total<=64,'Unsupported jump-pack registry')
    if ji>=owned then return nil,'pack_not_owned'end
    local entries=pointer(read(jm+56,8));local address=pointer(read(entries+ji*8,8))
    local entity=read(address,24)
    assert(u(entity+8)==pack_id,'Pack identity mismatch')
    local hover=u(entity)==HOVER_LOW and u(entity+4)==HOVER_HIGH
    if hover and bit.band(arena[entity+20],1)==0 then return nil,'pack_not_owned'end
    L.ji,L.jm_entries,L.entity,L.hover=ji,entries,address,hover;keep(L.ew,entity);L.stage=3
    if not hover then return nil,'not_hover_pack'end
    return jm,ji,entity
end
-- The pack's row in the attachment registry (arena offset of its owner), or nil
-- and why.
local function attached(pack_id,avatar)
    local attach=global(0x3326dc0)
    local bi=lookup(read(attach+32,20),pack_id,8192)
    if not bi then return nil,'pack_not_attached'end
    assert(bi<4096,'Unsupported attachment index')
    local rows=pointer(read(attach+64,8))
    if u(read(rows+bi*48+4,4))~=u(avatar+8) then return nil,'pack_not_attached'end
    L.attach,L.attach_rows,L.owner_at=attach,rows,rows+bi*48+4
    return true
end
-- S.down, S.active and S.flight from the avatar's movement flags, the pack's
-- five state bytes (states: the registry's state array) and the jump input.
local function pack_state(am,ai,states,ji)
    local flags=read(am+0x53d900+ai*0x1238+0xf80,24)
    local ps=read(states+ji*5,5)
    for i=0,4 do assert(arena[ps+i]<=1,'Unsupported pack flags')end
    -- The native input helper maps pair (2,15) to slot 15. +8 is its held time.
    local held=float(read(am+0x150+ai*0xa7aec+0x1b68+15*32,32)+8)
    assert(held==held and held>=0 and held<86400,'Invalid jump input')
    S.down=held>0
    S.active=arena[ps]==1
    S.flight=S.active and arena[ps+1]==0 and arena[ps+4]==1 and bit.band(u(flags+12),4)~=0
        and bit.band(u(flags+12),0x30)==0 and bit.band(u(flags+8),0x80000000)==0
end
-- S.key (avatar record, pack record and manager) and S.identity (the pack
-- record's first 20 bytes), built again only when those bytes change.
local key_words,key_manager={0,0,0,0,0,0,0,0,0,0,0,0},nil
local function same_key(avatar,entity,jm)
    if jm~=key_manager then return false end
    for i=0,5 do
        if key_words[i+1]~=words[avatar/4+i] or key_words[i+7]~=words[entity/4+i] then return false end
    end
    return true
end
local function identify(avatar,entity,jm)
    if same_key(avatar,entity,jm) then return end
    S.key=ffi.string(arena+avatar,24)..ffi.string(arena+entity,24)..tostring(jm)
    S.identity=ffi.string(arena+entity,20)
    for i=0,5 do key_words[i+1],key_words[i+7]=words[avatar/4+i],words[entity/4+i] end
    key_manager=jm
end
-- Everything from the registry roots down (39 reads with a hover pack, after
-- the mission check), keeping the layout as it goes.
local function resolve()
    forget()
    local unit,reason=local_unit();if not unit then return nil,reason end
    local avatar;avatar,reason=avatar_record(unit);if not avatar then return nil,reason end
    local am,ai=avatar_slot(avatar);if not am then return nil,ai end
    local pack_id;pack_id,reason=backpack(avatar);if not pack_id then return nil,reason end
    local jm,ji,entity=jump_pack(pack_id);if not jm then return nil,ji end
    local ok;ok,reason=attached(pack_id,avatar);if not ok then return nil,reason end
    L.states=pointer(read(jm+80,8))
    pack_state(am,ai,L.states,ji)
    L.stage=4
    identify(avatar,entity,jm)
    S.manager,S.pack=jm,pack_id
    return S
end

-- Kept layout -----------------------------------------------------------------
-- Between resolutions only the mode, the unit, the pack's state bytes, flags
-- and input change. Each frame reads the identity records at their kept
-- addresses and the registry slots and array pointers that lead to them (one
-- read per registry: its counts and array pointers sit together), at most 14
-- reads after the mission check instead of 39. false when any of it differs
-- (or a stage was never kept): resolve() then runs in the same frame. A
-- cancellation always resolves afresh before it writes (see fly).
local function check_avatar()
    if u(read(L.pm+0x3a8,4))~=L.unit then return nil end
    local avatar=read(L.avatar,24);if not kept(L.aw,avatar) then return nil end
    -- Count (+0x6c) through the avatar's slot (+0x110 + 8 ai) in one read.
    local ai=L.ai;local block=read(L.am+0x6c,0xac+ai*8);local count=u(block)
    if count>8 or ai>=count or not holds(block+0xa4+ai*8,L.am_slot) then return nil end
    return avatar
end
-- The kept equipment row's pack ID, or nil when the row moved.
local function check_equipment()
    local block=read(L.eq+64,24) -- the identity (+64) and row (+80) arrays
    if not holds(block,L.eq_ids) or not holds(block+16,L.eq_rows) then return nil end
    if not holds(read(L.eq_ids+L.qi*8,8),L.eq_slot) then return nil end
    return u(read(L.pack_at,4))
end
-- The pack's entity record (arena offset) and the registry block, false when
-- the registry or the record moved, or nil and why.
local function check_pack(pack_id)
    local block=read(L.jm+16,72) -- counts (+16), map (+32), entries (+56), states (+80)
    if not L.ji then
        if lookup(block+16,pack_id,128) then return false end
        return nil,'no_jump_pack'
    end
    local total,owned=u(block),u(block+4)
    if owned>total or total>64 or L.ji>=owned or not holds(block+40,L.jm_entries) then return false end
    if not holds(read(L.jm_entries+L.ji*8,8),L.entity) then return false end
    local entity=read(L.entity,24);if not kept(L.ew,entity) then return false end
    if not L.hover then return nil,'not_hover_pack' end
    if L.stage<4 or not holds(block+64,L.states) then return false end
    return entity
end
local function warm()
    local avatar=check_avatar();if not avatar or L.stage<2 then return false end
    local pack_id=check_equipment();if not pack_id then return false end
    if pack_id==0 or pack_id==0xffffffff then return nil,'no_backpack'end
    if L.stage<3 or pack_id~=L.pack_id then return false end
    local entity,reason=check_pack(pack_id);if not entity then return entity,reason end
    if not holds(read(L.attach+64,8),L.attach_rows) or u(read(L.owner_at,4))~=u(avatar+8) then return false end
    pack_state(L.am,L.ai,L.states,L.ji)
    identify(avatar,entity,L.jm)
    S.manager,S.pack=L.jm,pack_id
    return S
end

-- The local player's hover pack: S, or nil and why. Reads only; a read or
-- pointer that is not available yet raises WAIT_READ or WAIT_POINTER. fresh
-- skips the kept layout and resolves everything again.
function M.snapshot(api,game,fresh)
    reader,base,reads,used=api,address_of(game),0,0
    local ok,reason=mission();if not ok then forget();return nil,reason end
    if L.stage>0 and not fresh then
        local s;s,reason=warm();if s~=false then return s,reason end
        reads,used=0,0
    end
    return resolve()
end
-- The snapshot, or nil and why. Registries can disagree briefly while a
-- mission/player is removed; this phase only reads, so a failed snapshot is
-- rejected (with its kept layout) and the next update retries.
local function read_snapshot(api,game,state,fresh)
    local ok,s,reason=pcall(M.snapshot,api,game,fresh)
    if not ok then
        forget()
        if type(s)=='table' and s.hover_wait then reason=s.reason else
            state.snapshot_waits=(state.snapshot_waits or 0)+1
            state.last_snapshot_error=tostring(s);reason='waiting_for_game_data'
        end
        s=nil
    end
    state.snapshot_status=s and 'valid' or reason
    state.mission_type=s and s.mission_type or nil
    return s,reason
end
-- Before a cancellation the pack is located afresh from the registry roots: it
-- must be the same pack (same key) in the same flight with the jump held.
local function confirmed(api,game,s,state)
    local key=s.key
    local again=read_snapshot(api,game,state,true)
    return again~=nil and again.key==key and again.flight and again.down
end
-- A flight frame: focus check and the policy; when it asks for a cancellation,
-- the focus check runs again and the pack is located afresh right before the
-- settings write (which checks its own guards again).
local function fly(api,game,s,state)
    if not api.focused() then M.policy.step(state,nil);return 'waiting_for_game_focus'end
    if not M.policy.step(state,s) then return 'watching_hover'end
    if not api.focused() or not confirmed(api,game,s,state) then
        M.policy.step(state,nil);return 'snapshot_changed'
    end
    if not M.settings.cancel(api,game,s,state) then
        M.policy.step(state,nil);return 'snapshot_changed'
    end
    state.cancellations=(state.cancellations or 0)+1
    return 'cancel_requested'
end
function M.apply(api,game,exe,state)
    local s,reason=read_snapshot(api,game,state)
    if state.lease then
        if s and s.key==state.lease.key and s.active then return 'native_descent' end
        if not M.settings.restore(api,game,state) then return 'restore_pending' end
        M.policy.step(state,nil)
    end
    -- Without a hover-pack snapshot there is nothing to focus-gate: skip the
    -- window/process system calls on every such frame.
    if not s then M.policy.step(state,nil);return reason end
    -- Without a flight the policy only resets and no cancellation can start,
    -- so the focus check could not change the outcome.
    if not s.flight then M.policy.step(state,s);return 'waiting_for_hover'end
    return fly(api,game,s,state)
end
-- Undo this mod's change to the game and start afresh (the loader calls it
-- when the mod pauses, stops or shuts down): the restore's result (true, or
-- false and why while it waits), and the policy forgets the flight, so a
-- flight in progress needs a release and a new press before it can be
-- cancelled.
function M.cleanup(api,game,state)M.policy.step(state,nil);return M.settings.restore(api,game,state)end
-- The snapshot's stages are straight-line code that runs once per frame.
-- Compiled, they took about 34 KB of the LuaJIT code cache that the game and
-- every mod share (the whole mod 44,464 bytes in the game's lua51.dll) to
-- save about 2 us per frame in a test process. Interpreted, the helpers they
-- call (reads, pointers, map probes, record compares, the float decoder) still
-- compile and the mod's machine code stays near 10 KB. This marks only these
-- functions; it flushes nothing.
if jit and jit.off then
    for _,stage in ipairs({mission,local_unit,avatar_record,avatar_slot,backpack,jump_pack,attached,pack_state,
        resolve,check_avatar,check_equipment,check_pack,warm,M.snapshot})do
        jit.off(stage)
    end
end
return M
