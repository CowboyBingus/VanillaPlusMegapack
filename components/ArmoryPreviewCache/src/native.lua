-- The only game mutations are balanced calls to the game's package lease API.
-- All thumbnail cards, render targets, queues and executable bytes remain owned
-- and updated by the game. Layouts are specific to the fingerprinted build.
local ffi=require('ffi')
local bit=require('bit')
local M={}
local word=ffi.new('uint32_t[1]')
local pointer_value=ffi.new('uintptr_t[1]')
local function pointer_key(p)
    pointer_value[0]=ffi.cast('uintptr_t',p);return ffi.string(pointer_value,8)
end
local zero=string.rep('\0',8)
local function u32(s,o) assert(s and o+4<=#s,'Short field');ffi.copy(word,s:sub(o+1,o+4),4);return tonumber(word[0])end
local function raw64(s,o) assert(s and o+8<=#s,'Short identifier');return s:sub(o+1,o+8)end
local function hex(s) return (s:reverse():gsub('.',function(c)return string.format('%02x',c:byte())end))end
local function unhex(s)
    assert(type(s)=='string' and #s==16 and not s:find('[^0-9a-f]'),'Invalid identifier')
    return (s:gsub('..',function(c)return string.char(tonumber(c,16))end)):reverse()
end
M.hex,M.unhex=hex,unhex

-- The lease table's 1024 rows (16 bytes each: identifier, 64-bit count), read
-- into one reused buffer and decoded in place.
local LEASE_ROWS=ffi.new('uint32_t[4096]')
local LEASE_BUFFER={address=tonumber(ffi.cast('uintptr_t',LEASE_ROWS)),size=16384}
-- test_calls: {acquire=fn,release=fn} stand-ins for the two native lease
-- functions (tests only).
function M.new(api,game,exe,signatures,dependencies,test_calls)
    local function read(p,n)
        assert(n>0 and n<=32768,'Read exceeds bound')
        local bytes=api.read(p,n);assert(bytes,'Native data unavailable');return bytes
    end
    local function ptr(p)
        local value=api.pointer(read(p,8));assert(value,'Native pointer unavailable');return value
    end
    for _,s in ipairs(signatures)do
        local bytes=(s.hex:gsub('..',function(v)return string.char(tonumber(v,16))end))
        assert(read((s.module=='game' and game or exe)+s.rva,#bytes)==bytes,'Native instruction mismatch')
    end
    local root_api=ptr(game+0x3326308)
    assert(root_api==exe+0x27c8d80,'Unexpected script API')
    local app=ptr(root_api+16)
    assert(ptr(app+752)==exe+0x320dd0 and ptr(app+768)==exe+0x321030,'Unexpected package API')
    local calls=test_calls or {}
    local acquire=calls.acquire or ffi.cast('void (*)(void *,const uint64_t *,uint32_t)',game+0x12fe350)  -- lint-ok: R2 once per session in native.new (v23 cast; only the test stand-in is new)
    local release=calls.release or ffi.cast('void (*)(void *,const uint64_t *,uint32_t)',game+0x12fe4e0)  -- lint-ok: R2 once per session in native.new (v23 cast; only the test stand-in is new)
    local argument=ffi.new('uint64_t[1]')
    local self={api=api}
    local dependency=dependencies and dependencies.new(api,game)
    local catalog_owner
    local kits,presets,weapons={},{},{}

    function self:owner()
        local p=ptr(game+0x347ceb0)
        local h=read(p,32)
        assert(u32(h,8)==1024 and u32(h,24)==2 and raw64(h,16)==zero,'Unexpected lease table')
        assert(api.pointer(h)==p+32,'Unexpected lease storage')
        local allocator=ptr(p+16416)
        return pointer_key(p)..pointer_key(allocator),p
    end
    -- Package identifiers as hex text, made once per identifier and session
    -- (bounded: the cache restarts past 8192 identifiers).
    local hex_ids,hex_count={},0
    local function hex_of(low,high)
        local row=hex_ids[high]
        local text=row and row[low]
        if text then return text end
        if hex_count>=8192 then hex_ids,hex_count={},0 end
        row=hex_ids[high];if not row then row={};hex_ids[high]=row end
        text=bit.tohex(high,8)..bit.tohex(low,8)
        row[low]=text;hex_count=hex_count+1
        return text
    end
    -- One reused table of the table's rows (identifier -> count) and the
    -- identifiers it holds: the next decode replaces it, so callers read the
    -- counts they need before decoding again.
    local rows,listed,row_ids={},0,{}
    function self:references()
        local owner,p=self:owner()
        for i=1,listed do rows[row_ids[i]]=nil end
        listed=0
        assert(api.read(tonumber(ffi.cast('uintptr_t',p))+32,16384,LEASE_BUFFER,0),'Native data unavailable')
        local w=LEASE_ROWS
        for i=0,4092,4 do
            local low,high=w[i],w[i+1]
            if low~=0 or high~=0 then
                -- Counts are 64-bit natively; reject high-word or implausible values.
                assert(w[i+3]==0,'Invalid package reference count')
                local count=w[i+2];assert(count>0 and count<1000000,'Invalid package references')
                local id=hex_of(low,high)
                rows[id]=count;listed=listed+1;row_ids[listed]=id
            end
        end
        return rows,listed,owner,p
    end
    function self:valid_leases(leases,owner)
        local current_rows,_,current=self:references()
        if current~=owner then return false end
        for id in pairs(leases)do if not current_rows[id]then return false end end
        return true
    end
    function self:acquire(id,owner)
        local before,n,current,p=self:references()
        if current~=owner or (not before[id] and n>=1008)then return false end
        local count=before[id] or 0
        ffi.copy(argument,unhex(id),8);acquire(p,argument,1)
        local after,_,check=self:references()
        assert(check==owner and after[id]==count+1,'Package acquire did not balance')
        return true
    end
    function self:release(id,owner)
        local before,_,current,p=self:references()
        -- A reset manager has already retired its own package references.
        if current~=owner or not before[id]then return false end
        local count=before[id]
        ffi.copy(argument,unhex(id),8);release(p,argument,1)
        local after,_,check=self:references()
        assert(check==owner and (after[id] or 0)==count-1,'Package release did not balance')
        return true
    end
    local function catalog()
        local ko,po,wo=ptr(game+0x33264f8),ptr(game+0x347cef8),ptr(game+0x346bf98)
        local wt=ptr(wo+0xf12558)
        local kp=ptr(ko);local kc=u32(read(ko+8,4),0)
        local pc=u32(read(po+7392,4),0)
        assert(kc>0 and kc<=1024 and pc>0 and pc<=4096,'Catalogue bounds changed')
        local key=table.concat({pointer_key(ko),pointer_key(kp),kc,pointer_key(po),pc,pointer_key(wt)},':')
        if key==catalog_owner then return end
        kits,presets,weapons={},{},{}
        local pointers=read(kp,kc*8)
        for i=0,kc-1 do
            local row=read(assert(api.pointer(pointers,i*8)),48)
            local id=raw64(row,32)
            if id~=zero then kits[u32(row,0)]=hex(id)end
        end
        for first=0,pc-1,1024 do
            local n=math.min(1024,pc-first);local rows=read(po+761060+first*24,n*24)
            for i=0,n-1 do presets[u32(rows,i*24+4)]=u32(rows,i*24+8)end
        end
        local buckets=read(wt,1080*16);local records=read(wt+17280,540*32)
        for i=0,1079 do
            local id=raw64(buckets,i*16)
            if id~=zero then
                local index=u32(buckets,i*16+8);assert(index<540,'Weapon record bound changed')
                local package_id=raw64(records,index*32+8)
                if package_id~=zero then weapons[hex(id)]=hex(package_id)end
            end
        end
        catalog_owner=key
    end
    function self:resolve(item)
        if not catalog_owner then catalog()end
        if item.kind==0 or item.kind==1 then return weapons[item.id] end
        if item.kind>=2 and item.kind<=4 then
            local raw=unhex(item.id)
            if u32(raw,4)~=0 then return nil end
            return kits[presets[u32(raw,0)]]
        end
    end
    function self:resolve_all(item)
        local base=self:resolve(item);local result=base and {base} or {}
        if not base then return result end
        if dependency and item.kind<=1 then
            for _,id in ipairs(dependency:resolve(item))do
                if id~=base then result[#result+1]=id end
            end
        end
        return result
    end
    function self:snapshot()
        local owner=self:owner()
        local sm=ptr(game+0x347ce28);local stack=read(sm+0x429c,24);local depth=u32(stack,20)
        local top=depth>=1 and depth<=5 and u32(stack,(depth-1)*4) or -1
        local ui=ptr(game+0x347cd90);local world=api.pointer(read(ui+15432,8))
        local blocked=u32(read(ui+15892,4),0)~=0
        -- Gameplay states cannot display thumbnails or run startup prewarming.
        -- Keep owner/world information so the policy can release old leases.
        if top~=5 and top~=14 and depth~=0 then
            return {owner=owner,world=world and pointer_key(world),menu=false,prefetch=false,
                    blocked=blocked,top=top,items={},active=false,states={}}
        end
        local tm=ptr(game+0x347cd80);local h=read(tm,12176)
        assert(ptr(game+0x347cd80)==tm and u32(h,11052)==7,'Thumbnail manager changed')
        local active=u32(h,11064);assert(active==0xffffffff or active<6,'Invalid thumbnail active card')
        local items,states={},{}
        for card=0,5 do
            local off=1816*card;local state=u32(h,off+1832);local count=u32(h,off+1836)
            assert(state<=8 and count<=15,'Invalid thumbnail card')
            states[#states+1]=state
            for i=0,count-1 do
                local at=off+32+i*120;local kind=u32(h,at+100)
                if state~=0 and kind<=4 then
                    local id=raw64(h,at+24)
                    if id~=zero then items[#items+1]={kind=kind,id=hex(id),finished=state==8 or u32(h,at+104)==4}end
                end
            end
        end
        -- The transient UI flag toggles during normal thumbnail work. It is
        -- not a world-lifetime signal and must never invalidate held leases.
        local menu=top==5 and world~=nil
        if top==14 and world~=nil then
            -- Briefing has its own controller. State 11 alone must not enable
            -- asset work during a controller teardown or unrelated transition.
            local dispatch=api.pointer(read(game+0x3326e68,8))
            if dispatch then
                local count=u32(read(dispatch+5740,4),0)
                assert(count<=64,'UI dispatch bound changed')
                local matches=0
                if count>0 then
                    local rows=read(dispatch+5744,count*16)
                    for i=0,count-1 do
                        if u32(rows,i*16+8)==229 and api.pointer(rows,i*16)then matches=matches+1 end
                    end
                end
                menu=matches==1
            end
        end
        -- Global package leases do not require a thumbnail world. During the
        -- bounded startup window, an initialized UI world with an empty state
        -- stack and idle preview manager can warm dependencies before Armory.
        local prefetch=world~=nil and depth==0 and active==0xffffffff
        if menu or prefetch then
            catalog()
            if dependency then
                dependency:refresh()
                local queued=dependency:queued()
                for _,item in ipairs(items)do item.attachments=queued[item.id]end
            end
        end
        return {owner=owner,world=world and pointer_key(world),menu=menu,
                prefetch=prefetch,blocked=blocked,top=top,items=items,active=active~=0xffffffff,states=states}
    end
    return self
end
return M
