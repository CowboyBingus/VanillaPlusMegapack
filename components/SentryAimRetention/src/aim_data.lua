local ffi,bit=require('ffi'),require('bit')
local M={}
local ZERO=string.rep('\0',4)
-- Four-byte fields decode through reused cells instead of a new cell and a
-- substring per read; out-of-range offsets keep the original path.
local u_cell,f_cell=ffi.new('uint32_t[1]'),ffi.new('float[1]')
local function field(cell,b,o)
    if o>=0 and o+4<=#b then ffi.copy(cell,ffi.cast('const uint8_t *',b)+o,4)
    else ffi.copy(cell,b:sub(o+1,o+4),4) end
    return tonumber(cell[0])
end
local function u(b,o) return field(u_cell,b,o) end
local function f(b,o) return field(f_cell,b,o) end
local function word(n) return ffi.string(ffi.new('uint32_t[1]',n),4) end
local function ticks(b)
    local v=ffi.new('uint64_t[1]');ffi.copy(v,b,8);return tonumber(v[0])
end
local function tickword(n) return ffi.string(ffi.new('uint64_t[1]',n),8) end
local function finite(n) return n==n and math.abs(n)<100000 end
local function vector(b)
    return b and #b==12 and finite(f(b,0)) and finite(f(b,4)) and finite(f(b,8))
end
local function nonzero(b) return f(b,0)~=0 or f(b,4)~=0 or f(b,8)~=0 end
local function fromhex(h) return (h:gsub('..',function(p)return string.char(tonumber(p,16))end)) end
-- Resource identity and BehaviorComponent defaults from this build's data.
local profiles={
    [fromhex('701de358cfd685ef')]={name='Gatling',behavior=213,fire_gate={pause=16,resume=4}},
    [fromhex('bb26ba7638e4cd37')]={name='Machine gun',behavior=312,fire_gate={pause=14,resume=3}},
    [fromhex('a8a8ffcf360f0756')]={name='Laser cannon',behavior=308},
    [fromhex('c6e986dc68950737')]={name='Rocket',behavior=611},
    [fromhex('582896febac30c82')]={name='Flamethrower',behavior=207},
    [fromhex('742dce3b2e81a051')]={name='Mortar',behavior=319},
    [fromhex('8b2f0938183a05b2')]={name='EMS mortar',behavior=323},
}
-- EMS mortar uses the same mechanism, with its own resource/profile identity.
M.profiles=profiles
local signatures={
    {0x6bf390,'405741574883ec283b158248dc02450fb6f94c8b158779c6'},
    {0x11cb930,'4883ec288b41083b05e3822b020f84d00000004c8b1526b4'},
    {0x11cba20,'4883ec288b41083b05f3812b020f84d00000004c8b1536b3'},
    {0x755f90,'48894c24085355565741574883ec20'},
}
M.signatures=signatures
local function matches(api,guards)
    for _,g in ipairs(guards) do
        if api.read(g.address,#g.bytes)~=g.bytes then return false end
    end
    return true
end

function M.snapshot(api,game)
    local function read(a,n)
        local b=api.read(a,n);assert(b and #b==n,'Runtime read unavailable');return b
    end
    local function pointer(b)
        return assert(api.pointer(b),'Runtime pointer unavailable')
    end
    local roots={}
    local function root(rva)
        local b=read(game+rva,8)
        if b==string.rep('\0',8) then return nil end
        local p=pointer(b);roots[#roots+1]={address=game+rva,bytes=b};return p
    end
    local tm,bm,rm=root(0x3326d30),root(0x3326740),root(0x3326d70)
    if not tm or not bm or not rm then return {},'waiting_for_sentries' end
    local th=read(tm+308,84)
    local cap,total,active=u(th,0),u(th,12),u(th,16)
    assert(active<=total and total<=cap and cap<=8192,'Unsupported targeting registry')
    if active==0 then return {},'waiting_for_sentries' end
    local rh=read(rm+8,88);local bh=read(bm+32,80)
    assert(u(rh,16)<=u(rh,12) and u(rh,12)<=u(rh,0) and u(rh,0)<=4096,'Unsupported turret registry')
    assert(u(bh,0)<=16384,'Unsupported behavior registry')
    local ep=pointer(th:sub(53,60));local rt=pointer(th:sub(69,76));local nt=pointer(th:sub(77,84))
    local result={}
    local function lookup(manager,off,id,limit,guards)
        local h=read(manager+off,20);local c=u(h,8)
        if c==0 then return nil end
        assert(c<=limit and bit.band(c,c-1)==0,'Unsupported entity map')
        local data=pointer(h:sub(1,8));local empty,mul=u(h,12),u(h,16)
        local product=ffi.new('uint64_t',id)*ffi.new('uint64_t',mul)
        for probe=0,math.min(c,128)-1 do
            local slot=bit.band(tonumber(ffi.cast('uint32_t',product))+probe,c-1)
            local address=data+slot*8;local row=read(address,8)
            if u(row,0)==id then
                guards[#guards+1]={address=manager+off,bytes=h}
                guards[#guards+1]={address=address,bytes=row}
                return u(row,4)
            end
            if u(row,0)==empty then return nil end
        end
        error('Entity map probe bound exceeded')
    end
    -- Bound each contiguous registry read; entity identity/authority stays fresh.
    local pointers
    for i=0,active-1 do
        if i%256==0 then pointers=read(ep+8*i,math.min(256,active-i)*8) end
        local at=(i%256)*8
        local entity_pointer=pointers:sub(at+1,at+8);local entity_address=pointer(entity_pointer)
        local entity=read(entity_address,24);local profile=profiles[entity:sub(1,8)]
        if profile and bit.band(entity:byte(21),3)==1 then
            local guards={}
            for _,g in ipairs(roots) do guards[#guards+1]=g end
            for _,g in ipairs({{tm+360,th:sub(53,60)},{tm+376,th:sub(69,76)},
                {tm+384,th:sub(77,84)},{ep+8*i,entity_pointer},{entity_address,entity:sub(1,20)}}) do
                guards[#guards+1]={address=g[1],bytes=g[2]}
            end
            local id=u(entity,8)
            local ti=lookup(tm,336,id,16384,guards)
            local bi=lookup(bm,64,id,32768,guards)
            local ri=lookup(rm,40,id,8192,guards)
            if ti==i and bi and ri and bi~=0xffffffff and ri~=0xffffffff then
                assert(bi<u(bh,0) and ri<u(rh,12),'Component index out of range')
                local function array(manager,off,index,stride,size)
                    local b=read(manager+off,8);local p=pointer(b)
                    guards[#guards+1]={address=manager+off,bytes=b}
                    return p+index*stride,read(p+index*stride,size)
                end
                local be=select(2,array(bm,88,bi,8,8))
                local re=select(2,array(rm,64,ri,8,8))
                assert(be==entity_pointer and re==entity_pointer,'Component identity mismatch')
                local ba,behavior=array(bm,96,bi,504,160)
                local ca,control=array(rm,88,ri,16,16)
                local runtime=read(rt+208*i,32);local network=read(nt+24*i,24)
                assert(u(behavior,0)==profile.behavior,'Unsupported sentry behavior')
                assert(behavior:byte(121)<=1 and control:byte(1)<=1,'Unsupported component flags')
                assert(vector(runtime:sub(9,20)) and vector(runtime:sub(21,32))
                    and vector(behavior:sub(29,40)),'Invalid aim vector')
                assert(finite(f(control,8)) and f(control,8)>=0 and f(control,8)<=1000
                    and finite(f(control,12)) and f(control,12)>=0 and f(control,12)<=1000,'Invalid turret speeds')
                local flags=u(network,16)
                local row={id=id,key=entity:sub(1,20),entity=entity_address,guards=guards,
                    transition_guards={{address=ba+8,bytes=behavior:sub(9,12)},
                        {address=ba+24,bytes=behavior:sub(25,28)},
                        {address=ba+96,bytes=behavior:sub(97,100)},
                        {address=ba+120,bytes=behavior:sub(121,121)}},
                    profile=profile.name,behavior_address=ba,node=u(behavior,8),target=u(behavior,24),
                    authority_address=entity_address+20,
                    has=behavior:byte(121)==1,source_flags=u(behavior,96),point=behavior:sub(29,40),
                    runtime_target=u(runtime,0),raw=runtime:sub(9,20),computed=runtime:sub(21,32),
                    raw_address=rt+208*i+8,computed_address=rt+208*i+20,
                    flags_address=nt+24*i+16,flags=flags,control_address=ca,
                    horizontal=control:sub(9,12),vertical=control:sub(13,16),enabled=control:byte(1)==1}
                if profile.fire_gate then
                    -- The MG/Gatling firing handlers use this microsecond deadline
                    -- for native candidate selection, independently of spin-up.
                    local clock_root=read(game+0x3326348,8)
                    row.selection={address=ba+152,deadline=behavior:sub(153,160),
                        now=ticks(read(pointer(clock_root)+24,8)),
                        guards={{address=game+0x3326348,bytes=clock_root}}}
                    local wm=pointer(read(game+0x3326ce0,8))
                    local fire_guards={}
                    local wi=lookup(wm,48,id,32768,fire_guards)
                    assert(wi and wi~=0xffffffff and wi<16384,'Weapon data unavailable')
                    local function weapon_array(off,stride,size)
                        local b=read(wm+off,8);local p=pointer(b)
                        fire_guards[#fire_guards+1]={address=wm+off,bytes=b}
                        return p+stride*wi,read(p+stride*wi,size)
                    end
                    local _,we=weapon_array(72,8,8)
                    assert(we==entity_pointer,'Weapon identity mismatch')
                    local _,wr=weapon_array(88,1008,228)
                    local mode_address,network=weapon_array(96,12,12)
                    local count,index=u(wr,216),u(wr,220)
                    assert(count>0 and count<=24 and index<count,'Invalid sentry fire nodes')
                    local node=u(wr,120+4*index)
                    assert(node<1024 and u(network,0)<=8,'Invalid sentry weapon state')
                    fire_guards[#fire_guards+1]={address=game+0x3326ce0,bytes=read(game+0x3326ce0,8)}
                    local cm=pointer(read(game+0x3326660,8))
                    local ci=lookup(cm,40,id,32768,fire_guards)
                    assert(ci and ci~=0xffffffff and ci<16384,'Weapon trigger unavailable')
                    local triggers=read(cm+88,8)
                    local trigger=read(pointer(triggers)+ci,1):byte(1)
                    assert(trigger<=1,'Invalid sentry trigger')
                    row.fire={manager=wm,mode_address=mode_address,mode=u(network,0),
                        guards=fire_guards,unit=u(entity,12),node=node,trigger=trigger==1,
                        pause=profile.fire_gate.pause,resume=profile.fire_gate.resume}
                    if row.target~=0 and row.runtime_target==row.target then
                        -- The collision surface normally lies in front of the
                        -- target node. Resolve its unit so that surface is not
                        -- mistaken for terrain. Keep target guards separate:
                        -- target removal must never prevent restoring a sentry.
                        local fg={};local fb=read(game+0x3326cb8,8)
                        local fm=pointer(fb)
                        fg[#fg+1]={address=game+0x3326cb8,bytes=fb}
                        local fi=lookup(fm,73808,row.target,131072,fg)
                        if fi and fi~=0xffffffff then
                            assert(fi<16384,'Target faction index out of range')
                            local array=read(fm+73832,8);local slot=pointer(array)+8*fi
                            local eb=read(slot,8);local address=pointer(eb);local target=read(address,20)
                            assert(u(target,8)==row.target,'Target identity changed')
                            fg[#fg+1]={address=fm+73832,bytes=array}
                            fg[#fg+1]={address=slot,bytes=eb}
                            fg[#fg+1]={address=address,bytes=target}
                            row.fire.target_unit=u(target,12);row.fire.target_guards=fg
                        end
                    end
                end
                result[#result+1]=row
            end
        end
    end
    return result,#result==0 and 'waiting_for_sentries' or 'observing'
end

local function writable(api,s)
    return api.writable_data(s.flags_address,4) and api.writable_data(s.raw_address,24)
        and api.writable_data(s.control_address+8,8)
end
local function same(a,b)
    return a.key==b.key and a.flags_address==b.flags_address
        and a.control_address==b.control_address and a.raw_address==b.raw_address
end

function M.release(api,native,lease)
    local s=lease.snapshot
    -- A removed/moved entity owns no writable lease here. Never follow an old slot.
    if not matches(api,s.guards) then return true,'retired' end
    if s.authority_address then
        local flags=api.read(s.authority_address,1)
        if not flags or bit.band(flags:byte(1),1)==0 then return true,'authority_changed' end
    end
    if not writable(api,s) then return false,'restore_memory_unavailable' end
    local restored=true
    if not lease.completed then
        for _,w in ipairs(lease.aim_writes or {}) do
            local current=api.read(w.address,12)
            local ours=false
            if current then
                for cut=0,12 do
                    if current==w.after:sub(1,cut)..w.before:sub(cut+1) then ours=true;break end
                end
            end
            -- A derived aim changed by the engine is no longer ours to restore.
            -- Still release every owned control even if one rollback fails.
            if not current then restored=false
            elseif ours and current~=w.before then
                local called,written=pcall(api.write,w.address,w.before)
                if not called or not written or api.read(w.address,12)~=w.before then restored=false end
            end
        end
    end
    -- Do not overwrite speed changes made by native behavior or another mod.
    for _,axis in ipairs({{'horizontal',8},{'vertical',12}}) do
        if lease[axis[1]] then
            local address=s.control_address+axis[2];local current=api.read(address,4)
            if current==ZERO then
                local called=pcall(native[axis[1]],s.entity,f(s[axis[1]],0))
                if not called or api.read(address,4)~=s[axis[1]] then restored=false
                else lease[axis[1]]=nil end
            elseif not current then restored=false
            else lease[axis[1]]=nil end
        end
    end
    if lease.flag then
        local current=api.read(s.flags_address,4)
        if not current then restored=false
        elseif bit.band(u(current,0),2)~=0 then
            local called=pcall(native.retention,s.id,false)
            if not called or api.read(s.flags_address,4)~=word(bit.band(u(current,0),bit.bnot(2))) then restored=false
            else lease.flag=nil end
        else lease.flag=nil end
    end
    return restored,restored and 'restored' or 'restore_incomplete'
end

local function acquire(api,native,s,record,state)
    if s.flags~=0 or not matches(api,s.guards) or not matches(api,s.transition_guards or {}) then return true,'busy' end
    if s.authority_address then
        local flags=api.read(s.authority_address,1)
        if not flags or bit.band(flags:byte(1),3)~=1 then return true,'busy' end
    end
    if not writable(api,s) then return false,'hold_memory_unavailable' end
    local lease={snapshot=s,flag=true};record.lease=lease
    -- Set the native retention bit first: the engine skips its target-source
    -- prepass and fallback path while this bit is owned. AI itself keeps running.
    native.retention(s.id,true)
    if api.read(s.flags_address,4)~=word(2) then return false,'hold_flag_failed' end
    for _,axis in ipairs({{'horizontal',8},{'vertical',12}}) do
        lease[axis[1]]=true
        native[axis[1]](s.entity,0)
        if api.read(s.control_address+axis[2],4)~=ZERO then return false,'hold_speed_failed' end
    end
    if s.raw~=record.raw then state.late_aim=state.late_aim+1 end
    lease.aim_writes={}
    for _,w in ipairs({{address=s.raw_address,before=s.raw,after=record.raw},
        {address=s.computed_address,before=s.computed,after=record.computed}}) do
        lease.aim_writes[#lease.aim_writes+1]=w
        if not api.write(w.address,w.after) then return false,'hold_aim_failed' end
    end
    if api.read(s.raw_address,12)~=record.raw or api.read(s.computed_address,12)~=record.computed then
        return false,'hold_aim_verify_failed'
    end
    state.holds=state.holds+1
    lease.completed=true
    return true,'holding'
end

function M.step(api,native,rows,state)
    state.records=state.records or {}
    state.holds=state.holds or 0;state.releases=state.releases or 0;state.late_aim=state.late_aim or 0
    state.observed=#rows;local seen={};local holding=0
    for _,s in ipairs(rows) do
        seen[s.id]=true
        local record=state.records[s.id]
        if record and record.snapshot.key==s.key then
            -- Refresh map guards even when component addresses did not move.
            -- A hash-table replacement alone invalidates the old guards and
            -- must not retire a live hold without restoring its controls.
            if record.lease then
                local old=record.lease.snapshot;local relocated={}
                for k,v in pairs(s) do relocated[k]=v end
                relocated.horizontal=old.horizontal;relocated.vertical=old.vertical
                record.lease.snapshot=relocated
            end
            record.snapshot=s
        elseif record and not same(record.snapshot,s) then
            if record.lease then
                local ok,why=M.release(api,native,record.lease);if not ok then return false,why end
            end
            record=nil;state.records[s.id]=nil
        end
        local tracking=s.enabled and s.has and s.target~=0 and bit.band(s.source_flags,1)~=0
        local scan=record and s.has and s.target==0 and bit.band(s.source_flags,32)~=0
            and s.node~=record.node and nonzero(s.point) and s.point~=record.source_point
        if record and record.lease then
            -- A non-target point on the firing node is the dead-target fallback,
            -- not scanning. A zero point is the observed transition placeholder.
            if tracking or scan or not s.enabled or s.horizontal~=ZERO or s.vertical~=ZERO
                or bit.band(s.flags,bit.bnot(2))~=0 then
                local ok,why=M.release(api,native,record.lease);if not ok then return false,why end
                record.lease=nil;record.raw=nil;state.releases=state.releases+1
            elseif bit.band(s.flags,2)==0 then
                -- The engine explicitly reclaimed targeting; restore our speed
                -- overrides and wait for a fresh target rather than fighting it.
                local ok,why=M.release(api,native,record.lease);if not ok then return false,why end
                record.lease=nil;record.raw=nil;state.releases=state.releases+1
            end
        end
        if tracking and not (record and record.lease) and s.flags==0 and s.runtime_target==s.target then
            record={snapshot=s,node=s.node,source_point=s.point,raw=s.raw,computed=s.computed}
            state.records[s.id]=record
        elseif record and record.raw and not record.lease and not tracking and s.enabled then
            if scan then record.raw=nil
            else
                local ok,why=acquire(api,native,s,record,state)
                if not ok then return false,why end
            end
        end
        if record then record.latest=s end
        if record and record.lease then holding=holding+1 end
    end
    for id,record in pairs(state.records) do
        if not seen[id] then
            if record.lease then
                local ok,why=M.release(api,native,record.lease);if not ok then return false,why end
            end
            state.records[id]=nil
        end
    end
    state.holding=holding
    return true,holding>0 and 'holding' or (#rows>0 and 'observing' or 'waiting_for_sentries'),holding>0
end

-- A short adjustment may keep firing. A broad or prolonged sweep cannot.
-- Separate enter/exit angles and a settle interval avoid rapid mode toggling.
M.fire_policy={settle_seconds=0.06,sweep_seconds=0.20,reselection_seconds=0.10}
local function direction(x,y,z)
    local length=math.sqrt(x*x+y*y+z*z)
    assert(finite(length) and length>0.00001,'Invalid firing direction')
    return {x/length,y/length,z/length}
end
local function angle(a,b)
    return math.deg(math.acos(math.max(-1,math.min(1,a[1]*b[1]+a[2]*b[2]+a[3]*b[3]))))
end
function M.fire_geometry(s)
    local pose=s.fire.pose
    assert(pose and #pose==64 and vector(pose:sub(17,28)) and vector(pose:sub(49,60)),
        'Invalid muzzle pose')
    local forward=direction(f(pose,16),f(pose,20),f(pose,24))
    local aim=direction(f(s.computed,0)-f(pose,48),f(s.computed,4)-f(pose,52),f(s.computed,8)-f(pose,56))
    return forward,angle(forward,aim)
end
local function fire_identity(api,s)
    local authority=s.authority_address and api.read(s.authority_address,1)
    return matches(api,s.guards) and matches(api,s.fire.guards)
        and (not s.authority_address or (authority and bit.band(authority:byte(1),3)==1))
end
function M.release_selection(api,lease)
    local s=lease.snapshot
    if not fire_identity(api,s) or not matches(api,s.selection.guards)
        or api.read(s.behavior_address+8,4)~=word(12) then return true end
    local current=api.read(s.selection.address,8)
    if not current then return false end
    local ours=current==lease.after
    if not lease.completed then
        for cut=0,8 do
            if current==lease.after:sub(1,cut)..lease.before:sub(cut+1) then ours=true;break end
        end
    end
    -- The native handler consumes the request by setting its own new deadline.
    if not ours or current==lease.before then return true end
    if not api.writable_data(s.selection.address,8) then return false end
    local ok,written=pcall(api.write,s.selection.address,lease.before)
    return ok and written and api.read(s.selection.address,8)==lease.before
end

function M.selection_step(api,rows,state)
    state.reselections=state.reselections or 0
    for _,s in ipairs(rows) do
        if s.selection then
            local r=state.fire_records[s.id]
            local tracking=s.enabled and s.node==12 and s.has and s.target~=0
                and bit.band(s.source_flags,1)~=0
            if r.selection then
                r.selection.snapshot=s
                if tracking or not s.enabled or s.node~=12 then
                    if not M.release_selection(api,r.selection) then return false,'selection_restore_failed' end
                    r.selection=nil
                else
                    local current=api.read(s.selection.address,8)
                    if not current then return false,'selection_read_failed' end
                    if current~=r.selection.after then r.selection=nil end
                end
            end
            if tracking then r.selection_armed=true
            elseif r.selection_armed and s.target==0 then
                r.selection_armed=false -- one request per observed target loss
                local q=s.selection;local deadline=ticks(q.deadline)
                local remaining=deadline-q.now
                -- Bound retries if native perception repeatedly offers a target
                -- that is immediately invalidated again.
                local due=math.max(q.now,(r.last_selection or 0)+M.fire_policy.reselection_seconds*1000000)
                if s.enabled and s.node==12 and not r.selection and q.now>0
                    and q.now<9007199254740991 and remaining>0 and remaining<=1000000 and due<deadline then
                    if not fire_identity(api,s) or not matches(api,q.guards)
                        or not matches(api,s.transition_guards or {})
                        or api.read(q.address,8)~=q.deadline then return false,'selection_identity_changed' end
                    if not api.writable_data(q.address,8) then return false,'selection_memory_unavailable' end
                    r.selection={snapshot=s,before=q.deadline,after=tickword(due)}
                    -- Only expire the pending query. Native perception, scoring,
                    -- range checks and target assignment still choose the enemy.
                    if not api.write(q.address,r.selection.after)
                        or api.read(q.address,8)~=r.selection.after then return false,'selection_request_failed' end
                    r.selection.completed=true;r.last_selection=due;state.reselections=state.reselections+1
                end
            elseif not s.enabled or s.node~=12 then r.selection_armed=false end
        end
    end
    return true
end
function M.release_fire(api,native,lease)
    local s=lease.snapshot
    if not fire_identity(api,s) then return true end
    local current=api.read(s.fire.mode_address,4)
    if not current then return false end
    -- Restore only the no-fire mode owned by this module.
    if current~=ZERO then return true end
    if not api.writable_data(s.fire.mode_address,4) then return false end
    local ok=pcall(native.fire_mode,s.fire.manager,s.id,lease.mode)
    return ok and api.read(s.fire.mode_address,4)==word(lease.mode)
end
function M.fire_step(api,native,rows,state,now)
    state.fire_records=state.fire_records or {}
    state.fire_pauses=state.fire_pauses or 0;state.fire_resumes=state.fire_resumes or 0
    local seen,paused={},0
    for _,s in ipairs(rows) do
        if s.fire then
            seen[s.id]=true
            local r=state.fire_records[s.id]
            if r and r.snapshot.key~=s.key then
                if r.selection and not M.release_selection(api,r.selection) then return false,'selection_restore_failed' end
                if r.lease and not M.release_fire(api,native,r.lease) then return false,'fire_restore_failed' end
                r=nil
            end
            r=r or {};state.fire_records[s.id]=r;r.snapshot=s
            if r.lease then r.lease.snapshot=s end -- refresh maps after native compaction
            if r.selection then r.selection.snapshot=s end
            local forward,error_angle=M.fire_geometry(s)
            r.error=error_angle;r.anchor=r.anchor or forward
            local tracking=s.enabled and s.has and s.target~=0 and bit.band(s.source_flags,1)~=0
            local synced=tracking and s.runtime_target==s.target
            -- A retained direction does not imply that there is still a target
            -- to shoot. Never reopen a paused burst merely because it is held.
            if r.terrain_target~=s.target then r.terrain_blocked=nil;r.terrain_checked_at=nil;r.query=nil end
            r.terrain_target=s.target
            if synced and s.fire.terrain_blocked~=nil then
                r.terrain_blocked=s.fire.terrain_blocked;r.query=s.fire.query;r.terrain_checked_at=now
            end
            r.terrain_age=r.terrain_checked_at and now-r.terrain_checked_at or nil
            local unavailable=not synced and s.fire.trigger
            local obstructed=tracking and r.terrain_blocked==true
            r.reason=unavailable and (tracking and 'aim_pending' or 'target_lost')
                or (obstructed and 'terrain_blocked' or nil)
            r.synced=synced;r.travel=angle(r.anchor,forward)
            local aligned=synced and not obstructed and error_angle<=s.fire.resume
            if aligned then
                r.settled_since=r.settled_since or now
                if now-r.settled_since>=M.fire_policy.settle_seconds then
                    r.anchor=forward;r.sweep_since=nil
                end
            else r.settled_since=nil end
            local travel=angle(r.anchor,forward)
            -- Time with shot permission closed is not a continuing firing sweep.
            if r.lease then r.sweep_since=nil end
            if not s.fire.trigger then
                r.anchor=forward;r.sweep_since=nil
            elseif not aligned and (travel>0.5 or (synced and error_angle>s.fire.resume)) then
                r.sweep_since=r.sweep_since or now
            end
            local broad=(synced and error_angle>s.fire.pause)
                or (s.fire.trigger and travel>s.fire.pause)
                or (s.fire.trigger and r.sweep_since and now-r.sweep_since>=M.fire_policy.sweep_seconds)
            if not r.reason and broad then r.reason='sweep' end
            local settled=aligned and now-r.settled_since>=M.fire_policy.settle_seconds
            if r.lease and s.fire.mode~=0 then r.lease=nil end -- engine/another mod changed the mode
            -- Losing a target is not itself a broad turn. A close replacement
            -- with a fresh clear ray can use the ordinary short-turn allowance.
            -- A broad turn or obstruction observed during the pause cancels
            -- this shortcut; those pauses still require settled alignment.
            if r.lease and (broad or obstructed) then r.lease.handoff=false end
            local handoff=r.lease and r.lease.handoff and synced
                and s.fire.terrain_blocked==false and error_angle<=s.fire.pause and not broad
            if r.lease and (settled or handoff or (not tracking and not s.fire.trigger) or not s.enabled) then
                if not M.release_fire(api,native,r.lease) then return false,'fire_restore_failed' end
                r.lease=nil;r.anchor=forward;r.sweep_since=nil
                state.fire_resumes=state.fire_resumes+1
            elseif not r.lease and (broad or unavailable or obstructed) and s.enabled and s.fire.mode~=0 then
                if not fire_identity(api,s) or not matches(api,s.transition_guards or {}) then return false,'fire_identity_changed' end
                if not api.writable_data(s.fire.mode_address,4) then return false,'fire_memory_unavailable' end
                r.lease={snapshot=s,mode=s.fire.mode,handoff=unavailable and not broad and not obstructed}
                -- Journal before invoking the native setter.
                native.fire_mode(s.fire.manager,s.id,0)
                if api.read(s.fire.mode_address,4)~=ZERO then return false,'fire_pause_failed' end
                state.fire_pauses=state.fire_pauses+1
            end
            if r.lease then paused=paused+1 end
        end
    end
    for id,r in pairs(state.fire_records) do
        if not seen[id] then
            if r.selection and not M.release_selection(api,r.selection) then return false,'selection_restore_failed' end
            if r.lease and not M.release_fire(api,native,r.lease) then return false,'fire_restore_failed' end
            state.fire_records[id]=nil
        end
    end
    state.fire_paused=paused
    return true
end

function M.apply(api,game,exe,state)
    local ok,rows,reason=pcall(M.snapshot,api,game)
    if not ok then return false,tostring(rows),false end
    if #rows==0 and not state.native then return true,reason,false end
    if not state.native then
        for _,s in ipairs(signatures) do
            local expected=fromhex(s[2])
            assert(api.read(game+s[1],#expected)==expected,'Unsupported native sentry setter')
        end
        local pose_signature=fromhex('40534883ec204863dae89206eaff488bc84c8b0041ff90e8')
        assert(exe and api.read(exe+0x1fd220,#pose_signature)==pose_signature,'Unsupported engine pose getter')
        for _,s in ipairs({
            {0x79f860,'33c04c8d05c7b201020f1f800000000049390cc0740cffc083f80475f3'},
            {0x7f4590,'488bc4f30f11582089480855535657415441554156415748'},
        }) do
            local expected=fromhex(s[2])
            assert(api.read(exe+s[1],#expected)==expected,'Unsupported terrain query')
        end
        state.native=api.bind(game,exe)
    end
    for _,s in ipairs(rows) do
        if s.fire then
            assert(fire_identity(api,s),'Fire pose identity changed')
            s.fire.pose=state.native.pose(s.fire.unit,s.fire.node)
            if s.enabled and s.has and s.target~=0 and s.runtime_target==s.target
                and bit.band(s.source_flags,1)~=0 then
                -- Test the current target point before ballistic/lead correction.
                -- A low target remains legal when the terrain does not occlude it.
                if s.fire.target_unit and matches(api,s.fire.target_guards) then
                    s.fire.terrain_blocked,s.fire.query=state.native.terrain_path(
                        s.fire.unit,s.fire.pose:sub(49,60),s.raw,s.fire.target_unit)
                    if not matches(api,s.fire.target_guards) then s.fire.terrain_blocked=nil;s.fire.query=nil end
                end
                assert(matches(api,s.transition_guards or {}),'Terrain target changed')
            end
        end
    end
    local accepted,why=M.fire_step(api,state.native,rows,state,api.time())
    if not accepted then return false,why,false end
    accepted,why=M.selection_step(api,rows,state)
    if not accepted then return false,why,false end
    local accepted,why,active=M.step(api,state.native,rows,state)
    if accepted and state.fire_paused>0 then return true,'firing_paused',true end
    return accepted,why,active
end

function M.stop(api,game,exe,state)
    local ok=true
    for id,r in pairs(state.fire_records or {}) do
        local selection_ok=not r.selection or M.release_selection(api,r.selection)
        local fire_ok=not r.lease or M.release_fire(api,state.native,r.lease)
        if selection_ok and fire_ok then state.fire_records[id]=nil else ok=false end
    end
    for id,record in pairs(state.records or {}) do
        if record.lease then
            local restored=M.release(api,state.native,record.lease)
            if restored then state.records[id]=nil else ok=false end
        else state.records[id]=nil end
    end
    return ok
end
return M
