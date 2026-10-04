local ffi,bit=require('ffi'),require('bit')
local M={}
local function u(b,o)local v=ffi.new('uint32_t[1]');ffi.copy(v,b:sub(o+1,o+4),4);return tonumber(v[0])end
local function word(n)return ffi.string(ffi.new('uint32_t[1]',n),4)end
local CUTOFF=ffi.string(ffi.new('float[1]',1/1024),4)
local function current(api,s)
    for _,g in ipairs(s.guards)do if api.read(g.address,#g.bytes)~=g.bytes then return false end end
    return true
end
-- Follow both native maps afresh: the engine can compact/reallocate this array.
function M.inspect(api,game,target)
    local s={guards={}}
    local function read(a,n)
        local b=assert(api.read(a,n),'Hover settings unreadable')
        s.guards[#s.guards+1]={address=a,bytes=b};return b
    end
    local function ptr(b,o)return assert(api.pointer(b,o),'Hover settings pointer unavailable')end
    if api.pointer(read(game+0x3326bb8,8))~=target.manager then return nil end
    local jm=target.manager
    local function slot(offset,key)
        local h=read(jm+offset,20);local cap,empty,mult=u(h,8),u(h,12),u(h,16)
        assert(cap>0 and cap<=256 and bit.band(cap,cap-1)==0,'Unsupported settings map')
        assert(key~=empty,'Invalid settings key')
        local product=tonumber(ffi.cast('uint32_t',ffi.new('uint64_t',key)*ffi.new('uint64_t',mult)))
        local data=ptr(h)
        for probe=0,cap-1 do
            local address=data+8*bit.band(product+probe,cap-1);local row=read(address,8)
            if u(row,0)==key or u(row,0)==empty then
                return {address=address,bytes=row,index=u(row,0)==key and u(row,4) or nil}
            end
        end
        error('Hover settings map full')
    end
    local entity_slot=slot(32,target.pack)
    if not entity_slot.index or entity_slot.index==0xffffffff then return nil end
    local count=u(read(jm+12,4),0)
    assert(count<=64 and entity_slot.index<count,'Invalid pack registry index')
    local entity=ptr(read(ptr(read(jm+56,8))+8*entity_slot.index,8))
    if read(entity,20)~=target.identity then return nil end
    local cap=u(read(jm+4,4),0);local n=u(read(jm+152,4),0)
    assert(cap>0 and cap<=256 and n<=cap,'Invalid settings count')
    s.forward=slot(96,target.pack);s.index=s.forward.index
    local data=ptr(read(jm+160,8))
    if s.index and s.index~=0xffffffff then
        assert(s.index<n,'Invalid settings index')
        local reverse=slot(128,s.index)
        assert(reverse.index==target.pack,'Settings owner mismatch')
        s.address=data+280*s.index;s.bytes=read(s.address,280)
    else
        assert(n<cap,'No free hover settings slot')
        s.index=n;s.address=data+280*n;s.previous=read(s.address,280)
        s.reverse=slot(128,n)
        assert(not s.reverse.index or s.reverse.index==0xffffffff,'Settings slot already owned')
        s.count_address=jm+152;s.count_bytes=word(n)
        -- Same six-entry resource table as game.dll+508c60. Copy the current
        -- resource, including other archive mods; never write shared settings.
        local owner=ptr(read(game+0x346bf98,8))
        local resources=ptr(read(owner+0xf12cb8,8));local headers=read(resources,96)
        for i=0,5 do
            if headers:sub(i*16+1,i*16+8)==target.identity:sub(1,8) then
                local index=u(headers,i*16+8);assert(index<3,'Invalid hover resource index')
                s.bytes=read(resources+96+280*index,280);break
            end
        end
        assert(s.bytes,'Hover resource unavailable');s.create=true
    end
    return s
end
-- Undo creation writes i..1 after write i failed (failure path only: each
-- undo write is checked again).
local function undo(api,writes,i)
    for j=i,1,-1 do assert(api.write(writes[j][1],writes[j][2]),'Settings rollback failed')end
end
-- Publish a normal engine-owned override in existing free storage. No
-- allocations or native function calls. Native pack destruction removes and
-- compacts these records through both maps. Returns the override, inspected again.
local function create(api,game,target,s,original)
    local writes={{s.address,s.previous,s.bytes},{s.reverse.address,s.reverse.bytes,word(s.index)..word(target.pack)},
        {s.count_address,s.count_bytes,word(s.index+1)},
        {s.forward.address,s.forward.bytes,word(target.pack)..word(s.index)}}
    -- All or nothing: every destination is checked (one protection query each)
    -- before anything is written, so a refused one leaves memory untouched.
    -- The writes follow in this same call and are not checked a second time.
    -- No frame/native callback occurs between them; a failed write undoes the
    -- earlier ones.
    for _,w in ipairs(writes)do assert(api.writable_data(w[1],#w[3]),'Settings storage is not writable data')end
    for i,w in ipairs(writes)do
        if not api.write(w[1],w[3],true) then undo(api,writes,i);error('Could not create per-pack hover settings')end
    end
    s=assert(M.inspect(api,game,target),'New hover override unavailable')
    assert(not s.create and s.bytes:sub(157,160)==original,'New hover override mismatch')
    return s
end
function M.cancel(api,game,target,state)
    -- A mission transition can invalidate data after the input snapshot.
    -- Retry read-only preflight; errors after mutation still reach cleanup.
    local ok,s=pcall(M.inspect,api,game,target)
    if not ok or not s then
        state.settings_waits=(state.settings_waits or 0)+1
        state.last_settings_error=ok and 'Hover pack changed' or tostring(s)
        return false
    end
    local original=s.bytes:sub(157,160);local duration=ffi.new('float[1]');ffi.copy(duration,original,4)
    assert(duration[0]>1/1024 and duration[0]<86400 and s.bytes:byte(154)==1,'Unsupported hover duration mode')
    if not current(api,s) then return false end
    if s.create then s=create(api,game,target,s,original) end
    if not current(api,s) then return false end
    local lease={manager=target.manager,pack=target.pack,identity=target.identity,key=target.key,original=original}
    state.lease=lease -- keep cleanup information even if a write reports failure
    if not api.write(s.address+156,CUTOFF) then
        assert(api.write(s.address+156,original),'Hover duration rollback failed')
        state.lease=nil;error('Could not shorten hover duration')
    end
    assert(api.read(s.address+156,4)==CUTOFF,'Hover duration write not retained')
    return true
end
-- true once the lease is settled (restored, or its pack proven gone); false
-- and why while it waits (settings unreadable or changing), keeping the lease.
function M.restore(api,game,state)
    local lease=state.lease;if not lease then return true end
    -- Retain the identity lease until we can resolve it or prove it is gone.
    -- Never turn a temporarily unavailable read into a permanent hook stop.
    local ok,s=pcall(M.inspect,api,game,lease)
    if not ok then
        state.restore_waits=(state.restore_waits or 0)+1
        state.last_restore_error=tostring(s);return false,state.last_restore_error
    end
    if not s or s.create then state.lease=nil;return true end
    if not current(api,s) then return false,'Hover settings changed' end
    -- Do not overwrite a later native/other-mod edit, or use a stale address.
    if s.bytes:sub(157,160)==CUTOFF then
        assert(api.write(s.address+156,lease.original),'Could not restore hover duration')
        assert(api.read(s.address+156,4)==lease.original,'Hover restoration not retained')
        state.restorations=(state.restorations or 0)+1
    end
    state.lease=nil;return true
end
-- The settings writer runs on about two frames per flight: the cancellation
-- and the restoration. Compiled, it took about 6 KB of the LuaJIT code cache
-- that the game and every mod share (the whole mod 14,294 -> 8,241 bytes and
-- 20 -> 14 traces, measured in the game's lua51.dll), and those frames were
-- not faster for it in a test process. true selects this chunk, the second
-- true every function in it: nothing else is affected and nothing is flushed.
if jit and jit.off then jit.off(true,true) end
return M
