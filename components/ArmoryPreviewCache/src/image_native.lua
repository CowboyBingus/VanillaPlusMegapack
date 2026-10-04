-- Build-locked UI presentation and render-texture ownership adapter.
-- Never edits code, card states, avatar work or generation completion flags.
-- Cached UI bindings use the native registration and widget invalidation contract.
local ffi=require('ffi')
local bit=require('bit')
local M={}
local scalar=ffi.new('uint32_t[1]')
local fp=ffi.new('float[4]')
local packed=ffi.new('uint64_t[2]')
local pointer_value=ffi.new('uintptr_t[1]')
local function pointer_key(p)
    -- The host may redact tostring(cdata). Preserve all address bits instead.
    pointer_value[0]=ffi.cast('uintptr_t',p);return ffi.string(pointer_value,8)
end
local function u32(s,o)ffi.copy(scalar,s:sub(o+1,o+4),4);return tonumber(scalar[0])end
local function float(s,o)ffi.copy(fp,s:sub(o+1,o+4),4);return tonumber(fp[0])end
local function raw(s,o,n)return s:sub(o+1,o+n)end
local function finite(n)return n==n and math.abs(n)<1000000 end
-- Grid request identity, not the working camera pose. 0x10F1CE0 changes
-- item+8 (weapon/cape angle) and +84 (cosmetic framing) during generation.
-- Grid kind and record style select the original request's camera preset.
function M.key(layout,item,variant)
    return layout..variant..raw(item,24,16)..raw(item,48,8)
        ..raw(item,64,8)..raw(item,88,16)
end

-- verify_gate: everything a snapshot result feeds into the image tick, per
-- part, as strings to compare between two decodes.
local DIGEST_FIELDS={'context','view','screen','layout','descriptor_id','capture_id','complete',
    'can_freeze','can_freeze_idle','can_freeze_rebind','can_freeze_visible','quiescent','blank_cards',
    'expected_count','width','height','bytes','tile_width','tile_height','controller_kind'}
function M.digest(s)
    local out={}
    for _,k in ipairs(DIGEST_FIELDS)do out[#out+1]=tostring(s[k])end
    for _,k in ipairs({'manager','world','owner','atlas'})do out[#out+1]=s[k] and pointer_key(s[k]) or '-' end
    local parts={screen=table.concat(out,'\1')}
    out={}
    for _,item in ipairs(s.items)do
        out[#out+1]=table.concat({item.key or '-',tostring(item.ready),tostring(item.pixels_ready),
            item.card,item.index,item.rectangle,item.preview or '-'},'\2')
    end
    parts.items=table.concat(out,'\1')
    out={};local shown={}
    for _,w in ipairs(s.widgets)do
        out[#out+1]=table.concat({w.key,pointer_key(w.widget),w.record_pointer,w.visual,tostring(w.bound),
            tostring(w.invalidated),tostring(w.named_material),tostring(w.native_ready),tostring(w.pixels_ready),
            w.indices,tostring(w.box_width),tostring(w.box_height),w.fit},'\2')
        shown[#shown+1]=table.concat({w.uv,w.size,tostring(w.alpha),tostring(w.spinner_alpha)},'\2')
    end
    parts.widgets=table.concat(out,'\1');parts.presentation=table.concat(shown,'\1')
    out={}
    for _,e in ipairs(s.registry or {})do out[#out+1]=pointer_key(e)end
    parts.registry=table.concat(out)
    out={}
    for c=0,5 do
        local source=s.source_cards and s.source_cards[c]
        out[#out+1]=source and (source.state..':'..source.stamp) or '-'
    end
    parts.cards=table.concat(out,'\1')
    return parts
end

-- One reused read buffer: 8-byte aligned, with byte, 32-bit and float views.
-- Only ReadProcessMemory writes it, so views never alias Lua stores.
local function buffer(size)
    local keep=ffi.new('uint64_t[?]',math.ceil(size/8))
    local bytes=ffi.cast('uint8_t *',keep)
    return {keep=keep,data=bytes,bytes=bytes,address=tonumber(ffi.cast('uintptr_t',keep)),size=size,
        u32=ffi.cast('uint32_t *',keep),f32=ffi.cast('float *',keep)}
end
-- A pointer field as a number (two 32-bit halves), nil when it is not a
-- plausible user-mode address; word is the field's 32-bit index.
local function pointer(b,word)
    local v=b.u32[word]+b.u32[word+1]*4294967296
    if v<0x10000 or v>=0x800000000000 then return nil end
    return v
end

-- The state check (docs/UPDATE_GATE.md). Each refresh reads what the image
-- snapshot and the asset policy consume into reused buffers and copies the
-- words they use into a signature with one fixed region per component. A
-- component whose words differ from the previous refresh gets a new version.
-- Nothing is allocated. Cost per refresh: 3 reads outside a thumbnail screen;
-- on one, 2 controller reads, the manager, the atlas descriptor, the preview
-- queue header (+1-2 reads while previews are queued) and the screen block
-- (grid: 1; pre-select: 1 + 3 widget record pointers; briefing: 1 + 6).
-- POLICY holds what only the asset policy reads (UI blocked flag, lease table
-- pointer, item status), so its changes never cost an image tick.
local UI,CONTROLLER,MANAGER,DESCRIPTOR,QUEUE,SCREEN,POLICY=0,1,2,3,4,5,6
local REGION={[0]=0,32,48,1648,1680,4624,7632}
local WORDS=7760
-- Item words the snapshot and the policy read: request identity (+24..+40,
-- +48..+56, +64..+72, +88..+104), crop rectangle (+56..+72) and kind (+100);
-- status (+104) goes to POLICY. The generator rewrites the camera fields +8
-- and +84.
local ITEM_WORDS={6,7,8,9,12,13,14,15,16,17,22,23,24,25}
-- Record words: visual (+0), type (+8), card/slot (+60), invalidation (+68)
-- and style (+72).
local RECORD_WORDS={0,1,2,15,16,17,18}
local BRIEFING_KINDS={[0]=2,3,4,0,0,1}
function M.state(api,game)
    local read=api.read
    local base=tonumber(ffi.cast('uintptr_t',game))
    local G,STACK,UIB,DPTR,DROWS=buffer(0x138),buffer(24),buffer(464),buffer(8),buffer(4+64*16)
    local MB,DESC,QH,QROWS=buffer(12176),buffer(104),buffer(8),buffer(127*200)
    local SMALL,META,TAILS,LEASE=buffer(480),buffer(24892),buffer(6*8),buffer(40)
    local cur,prev=ffi.new('uint32_t[?]',WORDS),ffi.new('uint32_t[?]',WORDS)
    local clen,plen=ffi.new('int32_t[7]'),ffi.new('int32_t[7]')
    local tails_ok=ffi.new('bool[6]')
    local lease_words,lease_prev=ffi.new('uint32_t[12]'),ffi.new('uint32_t[12]')
    -- No previous signature yet: the first refresh reports every component.
    for k=0,6 do clen[k]=-1;plen[k]=-1 end
    local self={G=G,STACK=STACK,UI=UIB,DPTR=DPTR,DROWS=DROWS,MB=MB,DESC=DESC,QH=QH,QROWS=QROWS,
        SMALL=SMALL,META=META,TAILS=TAILS,tails_ok=tails_ok,base=base,
        refreshes=0,image_version=0,policy_version=0,lease_version=0,lease_checked=false}
    local function words(b,first,count,w)
        local src=b.u32
        for i=0,count-1 do cur[w+i]=src[first+i] end
        return w+count
    end
    local function records(b,first,count,w)
        local src=b.u32
        for r=0,count-1 do
            local at=first+r*20
            for j=1,7 do cur[w]=src[at+RECORD_WORDS[j]];w=w+1 end
        end
        return w
    end
    local function tail(i,address,w)
        local ok=read(address,8,TAILS,i*8)
        tails_ok[i]=ok==true
        cur[w]=ok and 1 or 2
        if ok then cur[w+1]=TAILS.u32[i*2];cur[w+2]=TAILS.u32[i*2+1];return w+3 end
        return w+1
    end
    local function grid(address,w)
        local ok=read(address+597772,24892,META,0)
        self.meta_ok,self.meta_address=ok==true,address
        cur[w]=ok and 1 or 2;w=w+1
        if not ok then return w end
        -- Rows, row heights/index table, scroll position, item count, grid kind,
        -- columns and anchor (+597772..+602104), every record's identity, type,
        -- card/slot, invalidation and style, then row ranges, owned cards and the
        -- visible window (+622584..+622664). Scrolling remaps widgets to other
        -- records without any manager change; these fields move with it.
        w=words(META,0,1083,w)
        w=records(META,1083,256,w)
        return words(META,6203,20,w)
    end
    -- A briefing loadout is shown when all six records hold their slot's
    -- request (the manager item exists, has the expected kind) and each widget
    -- still points at its record: as in snapshot().
    local function loadout(owner)
        local m,r=MB.u32,SMALL.u32
        for index=0,5 do
            local card,slot=r[index*20+15],r[index*20+16]
            if card>=6 or slot>=15 then return false end
            local st,n=m[card*454+458],m[card*454+459]
            if st==0 or slot>=n then return false end
            local kind=m[card*454+8+slot*30+25]
            if kind>4 or r[index*20+2]~=3 or kind~=BRIEFING_KINDS[index]
                or not tails_ok[index] or pointer(TAILS,index*2)~=owner+454728+index*80 then return false end
        end
        return true
    end
    -- Globals block: the thumbnail manager, UI, state machine, preview queue
    -- and lease table pointers. Returns the UI and POLICY write positions.
    local function read_globals()
        local w,p=REGION[UI],REGION[POLICY]
        local ok=read(base+0x347cd80,0x138,G,0)
        self.g_ok=ok==true;cur[w]=ok and 1 or 2;w=w+1
        local tm,ui,sm,preview,lease
        if ok then
            w=words(G,0,2,w);w=words(G,4,2,w);w=words(G,42,2,w);w=words(G,56,2,w)
            p=words(G,76,2,p)
            tm,ui,sm,preview,lease=pointer(G,0),pointer(G,4),pointer(G,42),pointer(G,56),pointer(G,76)
        end
        self.tm,self.ui,self.sm,self.preview,self.lease=tm,ui,sm,preview,lease
        return w,p
    end
    -- State stack: depth and top. Returns the controller kind of a thumbnail
    -- screen (Armory 224, briefing 229).
    local function read_stack(w)
        self.stack_ok,self.depth,self.top=false,nil,nil
        if not self.sm then return w end
        local ok=read(self.sm+0x429c,24,STACK,0)
        self.stack_ok=ok==true;cur[w]=ok and 1 or 2;w=w+1
        if not ok then return w end
        local depth=STACK.u32[5]
        local top=depth>=1 and depth<=5 and STACK.u32[depth-1] or nil
        cur[w]=depth;cur[w+1]=top or 0xffffffff;w=w+2
        self.depth,self.top=depth,top
        return w,top==5 and 224 or (top==14 and 229 or nil)
    end
    -- UI block: the UI world, and the blocked flag for the policy.
    local function read_ui(w,p)
        self.ui_ok=false
        if not self.ui then return w,p end
        local ok=read(self.ui+15432,464,UIB,0)
        self.ui_ok=ok==true;cur[w]=ok and 1 or 2;w=w+1
        if not ok then return w,p end
        w=words(UIB,0,2,w);p=words(UIB,115,1,p)
        return w,p,pointer(UIB,0)
    end
    local function reset_screen()
        self.dptr_ok,self.rows_ok,self.mb_ok,self.desc_ok,self.qh_ok,self.qrows_ok=false,false,false,false,false,false
        self.small_ok,self.meta_ok,self.jobs,self.screen=false,false,0,nil
        for i=0,5 do tails_ok[i]=false end
    end
    -- The dispatch rows are a fixed 64-row array after their count: one read,
    -- or the count and the rows when the array cannot be read whole.
    local function read_rows(d)
        if read(d+5740,4+64*16,DROWS,0)then return true end
        local ok=read(d+5740,4,DROWS,0)
        local n=ok and DROWS.u32[0]
        if n and n>0 and n<=64 then ok=read(d+5744,n*16,DROWS,4)end
        return ok==true
    end
    -- The controller registered for kind (and whether several are), and how
    -- many briefing controllers are registered.
    local function find_owner(kind,n)
        local found,ambiguous,briefing=nil,0,0
        for i=0,n-1 do
            local row=1+i*4
            local k=DROWS.u32[row+2]
            if k==kind then
                if found then ambiguous=1 end
                found=pointer(DROWS,row)
            end
            if k==229 and pointer(DROWS,row)then briefing=briefing+1 end
        end
        return found,ambiguous,briefing
    end
    -- The rows' count and the owner found in them (with ambiguity and the
    -- briefing controller count).
    local function row_words(d,kind,w)
        local rok=read_rows(d)
        self.rows_ok=rok;cur[w]=rok and 1 or 2;w=w+1
        local n=rok and DROWS.u32[0]
        if n then cur[w]=n;w=w+1 end
        if not (n and n<=64) then return w end
        local found,ambiguous,briefing=find_owner(kind,n)
        cur[w]=found and found%4294967296 or 0;cur[w+1]=found and math.floor(found/4294967296) or 0
        cur[w+2]=ambiguous;cur[w+3]=briefing
        return w+4,found
    end
    -- CONTROLLER: dispatch pointer and rows. Returns the screen's owner.
    local function read_controller(kind)
        local w=REGION[CONTROLLER]
        local ok=read(base+0x3326e68,8,DPTR,0)
        self.dptr_ok=ok==true;cur[w]=ok and 1 or 2;w=w+1
        local d=ok and pointer(DPTR,0)
        if ok then w=words(DPTR,0,2,w)end
        local owner
        if d then w,owner=row_words(d,kind,w)end
        clen[CONTROLLER]=w-REGION[CONTROLLER]
        self.owner=owner
        return owner
    end
    -- One card's state and count and, while it is busy, per item the words the
    -- snapshot reads (identity, crop rectangle, kind) and its status (POLICY).
    local function card_words(m,c,w,p)
        local at=c*454
        local st,n=m[at+458],m[at+459]  -- +1832, +1836
        cur[w]=st;cur[w+1]=n;w=w+2
        if st==0 or n>15 then return w,p end
        for i=0,n-1 do
            local item=at+8+i*30    -- +32+i*120
            for j=1,14 do cur[w]=m[item+ITEM_WORDS[j]];w=w+1 end
            cur[p]=m[item+26];p=p+1 -- +104 status
        end
        return w,p
    end
    -- MANAGER: one read of the thumbnail manager. Returns the working atlas.
    local function read_manager(p)
        local w=REGION[MANAGER]
        local ok=read(self.tm,12176,MB,0)
        self.mb_ok=ok==true;cur[w]=ok and 1 or 2;w=w+1
        local atlas
        if ok then
            local m=MB.u32
            cur[w]=m[2763];w=w+1                -- +11052
            w=words(MB,4,4,w)                   -- +16..+32: layout, tile size
            for c=0,5 do w,p=card_words(m,c,w,p)end
            cur[w]=m[2766];cur[w+1]=m[2774];w=w+2  -- active +11064, phase +11096
            w=words(MB,2775,2,w)                -- +11100 layout
            w=words(MB,2778,2,w)                -- atlas +11112
            local count=m[2784]                 -- registry +11136
            cur[w]=count;w=w+1
            if count<=128 then w=words(MB,2786,count*2,w)end
            atlas=pointer(MB,2778)
        end
        clen[MANAGER]=w-REGION[MANAGER]
        self.atlas=atlas
        return atlas,p
    end
    local function read_descriptor(atlas)
        local w=REGION[DESCRIPTOR]
        if atlas then
            local ok=read(atlas,104,DESC,0)
            self.desc_ok=ok==true;cur[w]=ok and 1 or 2;w=w+1
            if ok then w=words(DESC,0,26,w)end
        end
        clen[DESCRIPTOR]=w-REGION[DESCRIPTOR]
    end
    -- The occupied preview rows, oldest first, in at most two reads.
    local function read_jobs(preview,head,tail_index)
        local jobs=(tail_index-head)%128
        local first=math.min(jobs,128-head)
        local ok=jobs==0 or read(preview+50456+head*200,first*200,QROWS,0)
        if ok and jobs>first then ok=read(preview+50456,(jobs-first)*200,QROWS,first*200)end
        return jobs,ok==true
    end
    -- Per queued job: identity, slot count and slots.
    local function job_words(jobs,w)
        for r=0,jobs-1 do
            local row=r*50
            local n=QROWS.u32[row+20]  -- +80 slot count
            w=words(QROWS,row+16,2,w)  -- +64 identity
            cur[w]=n;w=w+1
            if n>10 then break end
            w=words(QROWS,row+22,n*2,w) -- +88 slots
        end
        return w
    end
    local function queue_words(preview,w)
        local ok=read(preview+50448,8,QH,0)
        self.qh_ok=ok==true;cur[w]=ok and 1 or 2;w=w+1
        if not ok then return w end
        local head,tail_index=QH.u32[0],QH.u32[1]
        cur[w]=head;cur[w+1]=tail_index;w=w+2
        if head>=128 or tail_index>=128 then return w end
        local jobs,rok=read_jobs(preview,head,tail_index)
        self.qrows_ok=rok;cur[w]=rok and 1 or 2;w=w+1
        if not rok then return w end
        self.jobs=jobs
        return job_words(jobs,w)
    end
    -- QUEUE: the preview queue header and its occupied rows.
    local function read_queue()
        local w=REGION[QUEUE]
        if self.preview then w=queue_words(self.preview,w)end
        clen[QUEUE]=w-REGION[QUEUE]
    end
    -- Briefing: the six loadout records and their widgets' record pointers;
    -- the picker grid when they do not form a loadout.
    local function briefing_words(owner,w)
        local ok=read(owner+454728,480,SMALL,0)
        self.small_ok=ok==true;cur[w]=ok and 1 or 2;w=w+1
        if ok then
            w=records(SMALL,0,6,w)
            for index=0,5 do w=tail(index,owner+422768+index*5464+1984,w)end
        end
        if ok and self.mb_ok and loadout(owner)then self.screen='briefing_loadout';return w end
        self.screen='briefing_grid'
        return grid(owner+864032,w)
    end
    -- Armory: the pre-select records and mode block (one read) and its three
    -- widgets' record pointers; the grid when no pre-select is shown.
    local function armory_words(owner,w)
        local control=owner+280216
        local ok=read(control+37728,256,SMALL,0)
        self.small_ok=ok==true;cur[w]=ok and 1 or 2;w=w+1
        if ok then
            w=words(SMALL,60,4,w)       -- mode block (+37968)
            w=records(SMALL,0,3,w)
        end
        if ok and SMALL.bytes[244]==0 and SMALL.u32[60]<6 then
            self.screen='preselect'
            for index=0,2 do w=tail(index,control+5256+index*12304+1984,w)end
            return w
        end
        self.screen='grid'
        return grid(owner+523752,w)
    end
    -- SCREEN: the block of the screen shown.
    local function read_screen(kind,owner,atlas)
        local w=REGION[SCREEN]
        if atlas and owner then
            cur[w]=kind;w=w+1
            if kind==229 then w=briefing_words(owner,w)else w=armory_words(owner,w)end
        end
        clen[SCREEN]=w-REGION[SCREEN]
    end
    local function component_changed(k)
        if clen[k]~=plen[k] then return true end
        local r=REGION[k]
        for i=r,r+clen[k]-1 do if cur[i]~=prev[i]then return true end end
        return false
    end
    -- Versions: the image tick reads every component but POLICY; the asset
    -- policy reads neither the atlas descriptor nor the screen block.
    local function count_versions()
        local image,policy=false,false
        for k=0,6 do
            if component_changed(k)then
                if k~=POLICY then image=true end
                if k~=DESCRIPTOR and k~=SCREEN then policy=true end
            end
        end
        if image then self.image_version=self.image_version+1 end
        if policy then self.policy_version=self.policy_version+1 end
        return image
    end
    function self:refresh()
        self.refreshes=self.refreshes+1
        cur,prev=prev,cur;clen,plen=plen,clen
        for k=0,6 do clen[k]=0 end
        local w,p=read_globals()
        local kind,world
        w,kind=read_stack(w)
        w,p,world=read_ui(w,p)
        clen[UI]=w-REGION[UI]
        self.kind,self.world=kind,world
        reset_screen()
        -- The rest only while a thumbnail screen can be shown, in the order
        -- snapshot() needs it.
        if self.tm and self.sm and self.ui and kind and world then
            local owner=read_controller(kind)
            local atlas
            atlas,p=read_manager(p)
            read_descriptor(atlas)
            read_queue()
            read_screen(kind,owner,atlas)
        end
        clen[POLICY]=p-REGION[POLICY]
        return count_versions()
    end
    -- The lease table owner (header and allocator), read by the policy step
    -- only: 2 reads, own version.
    function self:refresh_lease()
        local lease=self.lease
        for i=0,11 do lease_words[i]=0 end
        if lease then
            lease_words[0]=1;lease_words[1]=lease%4294967296;lease_words[2]=math.floor(lease/4294967296)
            if read(lease,32,LEASE,0)then
                lease_words[0]=lease_words[0]+2
                local h=LEASE.u32
                lease_words[3],lease_words[4],lease_words[5]=h[0],h[1],h[2]
                lease_words[6],lease_words[7],lease_words[8]=h[4],h[5],h[6]
            end
            if read(lease+16416,8,LEASE,32)then
                lease_words[0]=lease_words[0]+4
                lease_words[9],lease_words[10]=LEASE.u32[8],LEASE.u32[9]
            end
        end
        local same=self.lease_checked
        for i=0,11 do if lease_words[i]~=lease_prev[i]then same=false end;lease_prev[i]=lease_words[i]end
        self.lease_checked=true
        if not same then self.lease_version=self.lease_version+1 end
        return not same
    end
    return self
end

function M.new(api,game,exe,signatures,test_calls,state) -- lint-ok: R10 ported from v23 unchanged; split into named steps is a follow-up (differential harness ready)
    local function read(p,n)
        local bytes=assert(api.read(p,n),'Image memory unavailable');return bytes
    end
    local function ptr(p)return api.pointer(read(p,8))end
    for _,s in ipairs(signatures)do
        local bytes=s.hex:gsub('..',function(v)return string.char(tonumber(v,16))end)
        assert(read((s.module=='game' and game or exe)+s.rva,#bytes)==bytes,'Image instruction mismatch')
    end
    local root=assert(ptr(game+0x3326308));assert(root==exe+0x27c8d80,'Image API root mismatch')
    local app=assert(ptr(root+16))
    for off,rva in pairs({[368]=0x31af50,[400]=0x31b360,[528]=0x31e030})do
        assert(ptr(app+off)==exe+rva,'Image application API mismatch')
    end
    assert(u32(read(exe+0x1658990,4),0)==32,'Unexpected texture format size')
    local calls=test_calls or {}
    local create=calls.create or ffi.cast('void *(*)(int,int,int,int,uint32_t,uint8_t)',exe+0x31af50)
    local destroy=calls.destroy or ffi.cast('void (*)(void *)',exe+0x31b360)
    local register=calls.register or ffi.cast('void (*)(uint32_t,void *)',exe+0x31e030)
    local set_texture=calls.texture or ffi.cast('void (*)(void *,uint32_t,void *)',game+0x14499e0)
    local set_uv=calls.uv or ffi.cast('void (*)(void *,uint64_t,uint64_t)',game+0x143eef0)
    local set_size=calls.size or ffi.cast('void (*)(void *,uint64_t)',game+0x1447160)
    local set_alpha=calls.alpha or ffi.cast('void (*)(void *,float)',game+0x1448ad0)
    local material=calls.material or ffi.cast('void (*)(void *,uint64_t,uint8_t)',game+0x144f800)
    local register_image=calls.register_image or ffi.cast('void (*)(void *,void *)',game+0x1392680)
    local byte=calls.byte or function(p,v)ffi.cast('uint8_t *',p)[0]=v end
    local image_material=ffi.new('uint64_t',0x27ef0643)*0x100000000+0x5506e446
    local bindings={}
    local self={prune_checks=0,prune_changes=0,prune_reconciles=0,prune_misses=0,digest=M.digest}
    local retired={}
    local working_backup,restore_working
    state=state or M.state(api,game)
    local WIDGET,ELEMENT,COLUMNS,IDENTITY=buffer(2008),buffer(88),buffer(4),buffer(8)
    local function need(ok)return assert(ok,'Image memory unavailable')end
    local function text(b,offset,n)return ffi.string(b.bytes+offset,n)end
    local function cast(v)return v and ffi.cast('uint8_t *',v)end
    -- Widget fields at +0..+704 and +1984..+2008 in one read; the two reads the
    -- ungated snapshot made, and their failure, if that read fails.
    local function load_widget(address)
        if not api.read(address,2008,WIDGET,0)then
            need(api.read(address,704,WIDGET,0));need(api.read(address+1984,24,WIDGET,1984))
        end
    end
    -- An initialized private material, or the named thumbnail template.
    local function supported(a)
        local lo,hi=a.u32[152],a.u32[153]
        return (lo==0 and hi==0 and pointer(a,150)~=nil) or (lo==0x5506e446 and hi==0x27ef0643)
    end
    -- Configured weapon slots observed in the native preview queue, keyed by the
    -- request identity. A weapon's applied pattern and attachments live here, not
    -- in the thumbnail request record, so this is the only appearance signal the
    -- cache can key on. The queue only holds work while a preview is generating,
    -- so the last observation per identity is remembered for the session.
    local preview_observed={}
    local function observe_previews(st)
        local preview=pointer(st.G,56)
        if not preview then return end
        if not st.qh_ok then need(api.read(preview+50448,8,st.QH,0))end
        local head,tail=st.QH.u32[0],st.QH.u32[1]
        assert(head<128 and tail<128,'Preview queue bounds changed')
        local rows=st.QROWS
        local index,jobs=head,0
        while index~=tail and jobs<16 do
            if not st.qrows_ok then need(api.read(preview+50456+index*200,200,rows,jobs*200))end
            local count=rows.u32[jobs*50+20]
            assert(count<=10,'Preview queue dependency bound changed')
            preview_observed[text(rows,jobs*200+64,8)]=text(rows,jobs*200+88,count*8)
            index=(index+1)%128;jobs=jobs+1
        end
    end
    -- Native state 8 describes a request, not pixels in a newly allocated
    -- replacement. Track completed card regions that the swap left blank.
    local blank_working
    local function controller(kind)
        if not kind then
            local sm=ptr(game+0x347ce28);if not sm then return end
            local st=read(sm+0x429c,24);local depth=u32(st,20)
            local top=depth>=1 and depth<=5 and u32(st,(depth-1)*4)
            kind=top==5 and 224 or (top==14 and 229 or nil)
            if not kind then return end
        end
        local d=ptr(game+0x3326e68);if not d then return end
        local n=u32(read(d+5740,4),0);assert(n<=64,'Image dispatch bounds')
        local rows=n>0 and read(d+5744,n*16) or ''
        local found
        for i=0,n-1 do if u32(rows,i*16+8)==kind then
            assert(not found,'Ambiguous image controller');found=api.pointer(rows,i*16)
        end end
        return found,kind
    end
    local function uv(element,bytes)
        ffi.copy(packed,bytes,16);set_uv(element,packed[0],packed[1])
    end
    local function size(element,bytes)
        ffi.copy(packed,bytes,8);set_size(element,packed[0])
    end
    -- Returns how many bindings were released. A dry pass (verify_gate) only
    -- counts the bindings a real pass would release.
    local function reconcile(clear,dry) -- lint-ok: R10 ported from v23 unchanged; split into named steps is a follow-up (differential harness ready)
        if not next(bindings)then return 0 end
        local owner,kind=controller()
        local ui=ptr(game+0x347cd90)
        local world=ui and ptr(ui+15432)
        local tm=ptr(game+0x347cd80)
        local atlas=tm and ptr(tm+11112)
        local keep,released={},0
        for _,b in pairs(bindings)do
            local kept=false
            -- Fixed embedded widget offsets are valid only while this exact
            -- controller remains registered. Never dereference a departed UI.
            if owner==b.owner and kind==b.controller_kind and world==b.world and atlas then
                local current=read(b.widget+1984,8)
                local flags=u32(read(b.element,4),0)
                -- Briefing keeps its controller/widgets while retiring their
                -- materials on picker entry. The texture setter clones this
                -- material unconditionally: a cleared pointer crashes natively.
                -- A replacement material also ends our binding's ownership.
                local material_pointer=read(b.element+328,8)
                if bit.band(flags,0x3c0000)==0xc0000 and api.pointer(material_pointer)
                    and material_pointer==b.material_pointer then
                    local record=api.pointer(current)
                    local same=current==b.record_pointer and record
                        and read(record,8)==b.visual and read(record+60,8)==b.indices
                    local owned=same and read(record+68,1)=='\0'
                        and read(b.widget+2005,1)~='\0'
                    if not clear and owned then keep[pointer_key(b.widget)]=b;kept=true
                    elseif not dry then
                        -- Remove our texture before any detached atlas is freed.
                        -- Never restore an old transparent snapshot every frame.
                        set_texture(b.element,984135806,atlas)
                        if clear and owned then
                            byte(record+68,1)
                            set_alpha(b.element,0);set_alpha(b.widget+616,1)
                        end
                    end
                end
            end
            if not kept then released=released+1 end
        end
        if not dry then bindings=keep end
        return released
    end
    function self:restore(return_working)
        if return_working and restore_working then restore_working()end
        reconcile(true)
    end
    -- The gate: reference is the state version the last full snapshot decoded;
    -- verified says the bindings were checked against that state; dropped says
    -- a prune released a binding since, which the next tick must follow up.
    local reference,verified,dropped
    -- Before the game update. The bindings depend only on state the refresh
    -- covers, so they are checked on the first prune after a full snapshot (a
    -- remap there can leave a binding whose new item has no crop; this prune
    -- releases it, as every prune did) and whenever the refresh sees a change
    -- since that snapshot. Otherwise the per-binding reads are skipped. This is
    -- the frame's second state check (the first follows the game update, in
    -- tick); it runs only while images are bound.
    function self:prune()
        if not next(bindings)then return end
        if verified and reference then
            self.prune_checks=self.prune_checks+1
            state:refresh()
            if state.image_version==reference then
                if not self.verify or reconcile(false,true)==0 then return end
                self.prune_misses=self.prune_misses+1
            else self.prune_changes=self.prune_changes+1 end
        end
        self.prune_reconciles=self.prune_reconciles+1
        if reconcile(false)>0 then dropped=true end
        verified=true
    end
    -- After the game update: one refresh, true when nothing the last full
    -- snapshot decoded has changed and no binding was released since.
    function self:unchanged()
        state:refresh()
        return reference~=nil and state.image_version==reference and not dropped
    end
    local function descriptor(atlas)
        local d=read(atlas,104)
        assert(u32(d,8)==0 and u32(d,12)==0 and u32(d,28)==1 and u32(d,32)==1
            and d:byte(100)==1,'Unsupported thumbnail texture descriptor')
        local w,h=u32(d,20),u32(d,24)
        assert(w>=64 and h>=64 and w<=4096 and h<=16384,'Thumbnail dimensions exceed bounds')
        return d,w,h
    end
    -- A widget's fields: a is the widget read (+0..+704, +1984..+2008), rec
    -- the 80-byte record string.
    local function widget_row(result,address,a,rec,item)
        local p=cast(address)
        return {key=item.key,owner=result.owner,world=result.world,controller_kind=result.controller_kind,
            widget=p,element=p+272,record_pointer=text(a,1984,8),
            visual=raw(rec,0,8),bound=a.bytes[2005]~=0,invalidated=rec:byte(69)~=0,
            named_material=a.u32[152]==0x5506e446 and a.u32[153]==0x27ef0643,
            native_ready=item.ready,pixels_ready=item.pixels_ready,
            indices=raw(rec,60,8),uv=text(a,548,16),size=text(a,284,8),
            alpha=a.f32[85],spinner_alpha=a.f32[171],
            box_width=a.f32[3]*a.f32[7],box_height=a.f32[4]*a.f32[8],fit=a.u32[500]}
    end
    local function widget(result,address,rec,item)
        load_widget(address)
        if bit.band(WIDGET.u32[68],0x3c0000)~=0xc0000 or not supported(WIDGET)then return end
        result.widgets[#result.widgets+1]=widget_row(result,address,WIDGET,rec,item)
    end
    -- Handoff boundaries that keep the current request (the switch boundary,
    -- can_freeze, is set by snapshot):
    --   idle:    every card complete, so the whole request is retained.
    --   rebind:  every card complete, but an earlier visible handoff left some
    --            completed regions blank in the working atlas. images.lua
    --            detaches only when those regions' visible tiles hold crops.
    --   visible: every card backing a visible tile is complete and no card is
    --            composing, so a short visit keeps what the player saw.
    local function idle_gate(result,mb,by_index,owned) -- lint-ok: R10 ported from v23 unchanged; split into named steps is a follow-up (differential harness ready)
        local m=mb.u32
        local ok=#result.widgets>0 and #result.items==result.expected_count
        for c=0,5 do if m[c*454+458]~=0 and not owned[c]then
            result.can_freeze=false;ok=false
        end end
        for _,item in pairs(by_index)do if not item.key then ok=false end end
        -- The registry includes hidden widgets from the screen we just left.
        -- An idle detach is allowed only when every visible consumer can be
        -- rebound in this callback. Hidden consumers are moved to fresh too.
        result.registry={};local mapped={};local visible_ready=true
        for _,w in ipairs(result.widgets)do
            mapped[pointer_key(w.element)]=true
            if w.fit<1 or w.fit>3 or not finite(w.box_width) or not finite(w.box_height)
                or w.box_width<=0 or w.box_height<=0 then ok=false end
            if not w.pixels_ready then visible_ready=false end
        end
        local visible=ok and not result.complete and result.quiescent
            and result.blank_cards==0 and visible_ready
        -- Registry reads cost one native read per consumer. Skip them only on
        -- generation ticks where no handoff could be accepted; a complete
        -- request always lists them because restore_working rebinds them.
        if result.can_freeze or result.complete or visible then
            local n=m[2784];assert(n<=128,'Image registry bounds')
            for i=0,n-1 do
                local element=assert(pointer(mb,2786+i*2))
                result.registry[#result.registry+1]=cast(element)
                if ok and not mapped[pointer_key(element)]then
                    need(api.read(element,88,ELEMENT,0))
                    if bit.band(ELEMENT.u32[0],0x3c0000)~=0xc0000 or ELEMENT.f32[21]~=0 then
                        ok=false
                    end
                end
            end
        end
        result.can_freeze_idle=ok and result.complete and result.blank_cards==0
        result.can_freeze_rebind=ok and result.complete and result.blank_cards>0
        result.can_freeze_visible=ok and visible
    end
    -- The ungated snapshot, decoded from the state's buffers instead of a read
    -- per field. It asserts at the same fields; a buffer whose refresh read
    -- failed is read again at the ungated size first, so a failure raises the
    -- same error at the same point.
    local function owner_of(st,kind)
        need(st.dptr_ok or api.read(st.base+0x3326e68,8,st.DPTR,0))
        local d=pointer(st.DPTR,0);if not d then return nil end
        local rows=st.DROWS
        if not st.rows_ok then
            need(api.read(d+5740,4,rows,0))
            local n=rows.u32[0];assert(n<=64,'Image dispatch bounds')
            if n>0 then need(api.read(d+5744,n*16,rows,4))end
        end
        local n=rows.u32[0];assert(n<=64,'Image dispatch bounds')
        local found
        for i=0,n-1 do if rows.u32[i*4+3]==kind then
            assert(not found,'Ambiguous image controller');found=pointer(rows,1+i*4)
        end end
        return found
    end
    local function widget_pointer(st,index,address)
        if not st.tails_ok[index]then need(api.read(address,8,st.TAILS,index*8))end
        return pointer(st.TAILS,index*2)
    end
    local function decode(st) -- lint-ok: R10,R11 ported from v23 unchanged; split into named steps is a follow-up (differential harness ready)
        local result={items={},widgets={},expected_count=0}
        local G,MB,DESC=st.G,st.MB,st.DESC
        need(st.g_ok or api.read(st.base+0x347cd80,0x138,G,0))
        local sm,ui,tm=pointer(G,42),pointer(G,4),pointer(G,0)
        if not tm then return result end
        -- The detached render texture is globally allocated through the engine
        -- application API, not owned by the transient Armory UI world. Preserve
        -- it while the thumbnail manager survives, even with no active menu.
        result.context=pointer_key(tm);result.manager=cast(tm)
        if not sm or not ui then return result end
        need(st.stack_ok or api.read(sm+0x429c,24,st.STACK,0))
        local depth=st.STACK.u32[5]
        local top=depth>=1 and depth<=5 and st.STACK.u32[depth-1]
        local kind=top==5 and 224 or (top==14 and 229 or nil)
        if not kind then return result end
        need(st.ui_ok or api.read(ui+15432,8,st.UI,0))
        local world=pointer(st.UI,0);if not world then return result end
        local owner=owner_of(st,kind)
        result.world=cast(world);result.controller_kind=kind;result.owner=cast(owner)
        result.view=pointer_key(world)..string.char(kind)..(owner and pointer_key(owner) or '')
        need(st.mb_ok or api.read(tm,12176,MB,0))
        local m=MB.u32
        local atlas=pointer(MB,2778)
        if not atlas then return result end
        need(st.desc_ok or api.read(atlas,104,DESC,0))
        local d=DESC.u32
        assert(d[2]==0 and d[3]==0 and d[7]==1 and d[8]==1
            and DESC.bytes[99]==1,'Unsupported thumbnail texture descriptor')
        local w,h=d[5],d[6]
        assert(w>=64 and h>=64 and w<=4096 and h<=16384,'Thumbnail dimensions exceed bounds')
        local atlas_pointer=cast(atlas)
        result.atlas=atlas_pointer;result.width=w;result.height=h;result.bytes=w*h*4
        result.descriptor_id=text(DESC,0,8)
        result.layout=text(MB,16,16)..text(MB,11100,8)..text(DESC,8,28)
        -- Appearance observation is an optimization; a transient queue read must
        -- never invalidate the sample.
        pcall(observe_previews,st)
        local by_index,ids={},{}
        result.source_cards={};result.blank_cards=0
        if blank_working and (blank_working.atlas~=atlas_pointer or blank_working.id~=result.descriptor_id
            or blank_working.context~=result.context or blank_working.manager~=result.manager)then blank_working=nil end
        local active,all_complete,safe,nonempty=m[2766],true,true,0
        local phase=m[2774]
        for c=0,5 do
            local at=c*1816;local state,n=m[c*454+458],m[c*454+459]
            assert(state<=8 and n<=15,'Image card bounds')
            if state~=0 then
                local stamp={string.char(n)}
                result.expected_count=result.expected_count+n
                nonempty=nonempty+1
                if state~=8 then all_complete=false end
                if state~=3 and state~=4 and state~=5 then safe=false end
                for i=0,n-1 do
                    local o=at+32+i*120;local item_kind=m[o/4+25]
                    local input=text(MB,o,104)
                    stamp[#stamp+1]=M.key('',input,'')..text(MB,o+56,16)
                    if item_kind<=4 then
                        local item={input=input,card=c,index=i,ready=state==8,rectangle=text(MB,o+56,16),
                            preview=preview_observed[text(MB,o+24,8)]}
                        by_index[c*15+i]=item
                    end
                end
                result.source_cards[c]={state=state,stamp=table.concat(stamp)}
            end
            local source=result.source_cards[c]
            if blank_working and blank_working.cards[c]then
                if not source or state~=8 or source.stamp~=blank_working.cards[c]then
                    blank_working.cards[c]=nil
                else result.blank_cards=result.blank_cards+1 end
            end
        end
        for _,item in pairs(by_index)do
            item.pixels_ready=item.ready and not (blank_working and blank_working.cards[item.card])
        end
        result.complete=nonempty>0 and all_complete and active==0xffffffff
        result.can_freeze=nonempty>0 and safe and active<6 and (phase==4 or phase==5)
        -- Nothing is composing into the working atlas: every nonempty card is
        -- queued/preparing (3/4/5) or complete (8), and the single active card,
        -- if any, is still preparing. States 6/7 finalize into the atlas.
        local quiet=nonempty>0
        for c=0,5 do
            local source=result.source_cards[c]
            if source and source.state~=3 and source.state~=4 and source.state~=5
                and source.state~=8 then quiet=false end
        end
        if active~=0xffffffff then
            local source=active<6 and result.source_cards[active]
            if not source or source.state<3 or source.state>5 or (phase~=4 and phase~=5)then quiet=false end
        end
        result.quiescent=quiet
        result.tile_width=MB.f32[6];result.tile_height=MB.f32[7]
        if not owner then result.can_freeze=false;return result end
        local small=st.SMALL
        if kind==229 then
            if not st.small_ok then need(api.read(owner+454728,480,small,0))end
            local expected={2,3,4,0,0,1};local slots={};local valid=true
            for index=0,5 do
                local rec=text(small,index*80,80)
                local card,slot=u32(rec,60),u32(rec,64)
                local item=card<6 and slot<15 and by_index[card*15+slot]
                local address=owner+422768+index*5464
                if not item or u32(rec,8)~=3 or u32(item.input,100)~=expected[index+1]
                    or widget_pointer(st,index,address+1984)~=owner+454728+index*80 then valid=false;break end
                slots[#slots+1]={rec=rec,item=item,address=address}
            end
            if valid then
                result.screen='briefing_loadout';local owned={}
                for index,slot in ipairs(slots)do
                    local item,rec=slot.item,slot.rec
                    item.key=M.key(result.layout,item.input,'briefing_loadout'..string.char(index-1)..raw(rec,0,8)..raw(rec,72,4))
                    result.items[#result.items+1]=item;owned[item.card]=true
                    ids[#ids+1]=string.char(item.card,item.index)..item.key
                    widget(result,slot.address,rec,item)
                end
                result.capture_id=pointer_key(atlas)..table.concat(ids)
                idle_gate(result,MB,by_index,owned)
                return result
            end
        end
        local control=owner+280216
        -- The pre-select records (+37728) and mode block (+37968) are one read.
        local pre=false
        if kind==224 then
            if not st.small_ok then need(api.read(control+37968,16,small,240))end
            pre=small.bytes[244]==0 and small.u32[60]<6
        end
        if pre then
            local mode=small.u32[63];assert(mode<=2,'Pre-select mode bounds')
            result.screen=mode==0 and 'weapon_preselect' or 'cosmetic_preselect'
            if not st.small_ok then need(api.read(control+37728,240,small,0))end
            local owned={[small.u32[60]]=true}
            local variant='preselect'..text(small,252,4)
            for index=0,2 do
                local rec=text(small,index*80,80)
                local card,slot=u32(rec,60),u32(rec,64)
                local item=card<6 and slot<15 and by_index[card*15+slot]
                if item and owned[card] and u32(rec,8)==3 then
                    item.key=M.key(result.layout,item.input,variant..raw(rec,0,8)..raw(rec,72,4))
                    result.items[#result.items+1]=item
                    ids[#ids+1]=string.char(card,slot)..item.key
                    local address=control+5256+index*12304
                    if widget_pointer(st,index,address+1984)==control+37728+index*80 then widget(result,address,rec,item)end
                end
            end
            if #result.items>0 then result.capture_id=pointer_key(atlas)..table.concat(ids)end
            idle_gate(result,MB,by_index,owned)
            return result
        end
        result.screen=kind==229 and 'briefing_grid' or 'grid'
        local grid=owner+(kind==229 and 864032 or 523752)
        local meta=st.META
        if not (st.meta_ok and st.meta_address==grid)then need(api.read(grid+597772,24892,meta,0))end
        local g=meta.u32
        local count=g[0];assert(count<=12,'Image grid row bounds')
        -- Every nonempty card must belong to this grid. Empty cards do not
        -- render, so small categories can hand over the completed old atlas too.
        local owned={}
        for i=0,5 do
            local card=g[6205+i*3]              -- +622592
            if card<6 then owned[card]=true end
        end
        for c=0,5 do if m[c*454+458]~=0 and not owned[c]then result.can_freeze=false end end
        local grid_kind=text(meta,4280,4)       -- +602052
        -- Resolve every requested item through its grid record, including
        -- offscreen cards. Record style distinguishes alternate camera presets.
        for index=0,255 do
            local r=1083+index*20               -- record at +602104
            local card,slot=g[r+15],g[r+16]
            local item=card<6 and slot<15 and by_index[card*15+slot]
            if item and g[r+2]==3 then
                local key=M.key(result.layout,item.input,grid_kind..text(meta,r*4,8)..text(meta,r*4+72,4))
                assert(not item.key or item.key==key,'Ambiguous grid request identity')
                if not item.key then
                    item.key=key;result.items[#result.items+1]=item
                    -- Slot moves are new atlas work even if the semantic key
                    -- remains the same (for example when the grid scrolls).
                    ids[#ids+1]=string.char(item.card,item.index)..key
                end
            end
        end
        result.capture_id=pointer_key(atlas)..table.concat(ids)
        for row=0,count-1 do
            local rb=grid+2816+row*44752
            need(api.read(rb+44724,4,COLUMNS,0))
            local columns=COLUMNS.u32[0];assert(columns<=4,'Image grid column bounds')
            for col=0,columns-1 do
                local address=rb+9192+col*11112
                load_widget(address)
                local record=pointer(WIDGET,496)
                local record_offset=record and record-(grid+602104) or -1
                if record_offset>=0 and record_offset<256*80 and record_offset%80==0 then
                    local r=1083+record_offset/4
                    local card,index=g[r+15],g[r+16]
                    local item=card<6 and index<15 and by_index[card*15+index]
                    if item and item.key and g[r+2]==3 and bit.band(WIDGET.u32[68],0x3c0000)==0xc0000
                        and supported(WIDGET) then
                        result.widgets[#result.widgets+1]=widget_row(result,address,WIDGET,text(meta,r*4,80),item)
                    end
                end
            end
        end
        idle_gate(result,MB,by_index,owned)
        return result
    end
    -- fresh: decode what unchanged() just read (nothing ran in between).
    -- Otherwise the state is read again, which also records the mod's own
    -- writes since.
    function self:snapshot(fresh)
        if not fresh then state:refresh()end
        local result=decode(state)
        reference,verified,dropped=state.image_version,false,false
        return result
    end
    -- verify_gate only: an independent read and decode that leaves the gate's
    -- state and reference untouched.
    local peek_state
    function self:peek()
        peek_state=peek_state or M.state(api,game)
        peek_state:refresh()
        return decode(peek_state)
    end
    function self:capture(s)
        if #s.widgets==0 or #s.items==0 then return end
        local p={atlas=s.atlas,layout=s.layout,bytes=s.bytes,descriptor_id=s.descriptor_id,entries={}}
        for _,item in ipairs(s.items)do
            -- State 8 is the native per-card completion contract. Other cards
            -- can still be generating; their pixels must never enter this map.
            if item.ready and item.pixels_ready~=false then
            -- Recovered 0x10F0CB0 crop formula; fixture tests compare this with
            -- the actual native-bound UVs, rather than duplicating expectations.
            local r=item.rectangle
            local x=float(r,0)+1/s.tile_width
            local y=(1-float(r,4)-float(r,12))/6+item.card/6+1/s.tile_height
            local w=float(r,8)-2/s.tile_width
            local h=float(r,12)/6-2/s.tile_height
            assert(finite(x) and finite(y) and w>0 and h>0 and x>=0 and y>=0
                and x+w<=1.001 and y+h<=1.001,'Invalid completed image rectangle')
            local pixels_w,pixels_h=w*s.tile_width,h*s.tile_height*6
            fp[0],fp[1],fp[2],fp[3]=x,y,x+w,y+h
            p.entries[item.key]={uv=ffi.string(fp,16),width=pixels_w,height=pixels_h,
                preview=item.preview}
            end
        end
        if not next(p.entries)then return end
        return p
    end
    function self:freeze(s,p)
        local same_request=(s.can_freeze_idle or s.can_freeze_rebind or s.can_freeze_visible)
            and p.request_id==s.capture_id
        assert((s.can_freeze or same_request)
            and s.atlas==p.atlas and s.layout==p.layout,'Unsafe atlas handoff')
        assert(ptr(game+0x347cd80)==s.manager and ptr(s.manager+11112)==p.atlas,'Atlas owner changed')
        local d,w,h=descriptor(p.atlas);assert(raw(d,0,8)==p.descriptor_id,'Atlas generation changed')
        -- Same API and six arguments as the native atlas creator. Command 14
        -- creates the replacement before command 31 registers it for later draws.
        local fresh=create(w,h,1,0,3400165836,1)
        if fresh==nil then return end
        fresh=ffi.cast('uint8_t *',fresh)
        register(3400165836,fresh)
        ffi.cast('void **',s.manager+11112)[0]=fresh
        -- Rebind every native registered consumer, including hidden leftovers,
        -- before the old atlas can become independently releasable. apply()
        -- restores retained crops for the active screen in this same callback.
        for _,element in ipairs(s.registry or {})do set_texture(element,984135806,fresh)end
        -- The game owns fresh and will destroy it normally. Only the detached
        -- original belongs to us; never return it to the working atlas slot.
        local texture={handle=p.atlas,replacement=fresh,bytes=p.bytes,id=p.descriptor_id,width=w,height=h}
        blank_working={atlas=fresh,id=read(fresh,8),context=s.context,manager=s.manager,cards={}}
        for c,source in pairs(s.source_cards)do
            if source.state==8 then blank_working.cards[c]=source.stamp end
        end
        if s.can_freeze_idle and p.request_id==s.capture_id then
            working_backup={texture=texture,context=s.context,manager=s.manager,
                request=pointer_key(fresh)..s.capture_id:sub(9),layout=s.layout}
        else working_backup=nil end
        return texture
    end
    -- Textures whose ownership the last apply checked. A tick the gate skips
    -- checks them again (one 8-byte read each), as apply did every frame.
    local shown,shown_count={},0
    function self:check_textures()
        for i=1,shown_count do
            local t=shown[i]
            local ok=not t.destroyed and not t.returned
            if ok then
                need(api.read(t.address,8,IDENTITY,0))
                ok=IDENTITY.u32[0]==t.id_low and IDENTITY.u32[1]==t.id_high
            end
            assert(ok,'Cached texture ownership changed')
        end
    end
    -- The fourth result counts widgets with a crop that stayed unbound (fit,
    -- ratio or material not usable yet); the ungated tick retried those every
    -- frame. The fifth counts widgets whose material and registration this
    -- apply initialized: those writes change what the next snapshot decodes.
    function self:apply(s,entries) -- lint-ok: R10 ported from v23 unchanged; split into named steps is a follow-up (differential harness ready)
        local hits,misses,early,unresolved,initialized=0,0,0,0,0
        local checked={}
        shown_count=0
        for _,w in ipairs(s.widgets)do
            local entry=entries[w.key]
            if entry and w.box_width>0 and w.box_height>0 and w.fit>=1 and w.fit<=3 then
                local ratio=w.fit==1 and math.max(entry.width/w.box_width,entry.height/w.box_height)
                    or (w.fit==2 and entry.height/w.box_height or entry.width/w.box_width)
                if not (finite(ratio) and ratio>0)then unresolved=unresolved+1
                else
                    local t=entry.texture
                    if not checked[t]then
                        assert(not t.destroyed and not t.returned
                            and read(t.handle,8)==t.id,'Cached texture ownership changed')
                        checked[t]=true
                        if not t.address then
                            local b1,b2,b3,b4,b5,b6,b7,b8=t.id:byte(1,8)
                            t.address=tonumber(ffi.cast('uintptr_t',t.handle))
                            t.id_low=b1+b2*256+b3*65536+b4*16777216
                            t.id_high=b5+b6*256+b7*65536+b8*16777216
                        end
                        shown_count=shown_count+1;shown[shown_count]=t
                    end
                    if not w.bound or w.invalidated or w.named_material then
                        initialized=initialized+1
                        local tm=assert(ptr(game+0x347cd80))
                        assert(u32(read(tm+11136,4),0)<128,'Image registration full')
                        -- Freshly recreated widgets still reference the named
                        -- thumbnail template. Clone the private material using
                        -- the normal native contract before binding our texture.
                        material(w.element,image_material,1)
                        -- A missing template may leave initialization without
                        -- a material. Do not enter the native texture setter.
                        if ptr(w.element+328)then
                            register_image(tm,w.element)
                            -- This byte means the UI has an image, not that the
                            -- native card finished. Native destruction unregisters
                            -- it; new requests invalidate it through record+68.
                            byte(w.widget+2005,1)
                            byte(assert(api.pointer(w.record_pointer))+68,0)
                        end
                    end
                    local material_pointer=read(w.element+328,8)
                    if api.pointer(material_pointer)then
                        set_texture(w.element,984135806,entry.texture.handle)
                        -- The setter can privatize a shared material. Track the
                        -- final instance, not the pointer from before that call.
                        w.material_pointer=read(w.element+328,8)
                        bindings[pointer_key(w.widget)]=w
                        uv(w.element,entry.uv)
                        fp[0],fp[1]=entry.width/ratio,entry.height/ratio
                        size(w.element,ffi.string(fp,8))
                        set_alpha(w.widget+616,0);set_alpha(w.element,1)
                        hits=hits+1
                        if not w.native_ready then early=early+1 end
                    else misses=misses+1;unresolved=unresolved+1 end
                end
            else
                misses=misses+1
                if entry then unresolved=unresolved+1 end
            end
        end
        -- Presentation follows the cache. A crop whose key the cache no longer
        -- holds (the weapon was re-configured, or the entry was evicted) must
        -- stop being drawn, so the widget is handed back to the native pipeline
        -- and its own render becomes visible as soon as it is composed.
        local tm=ptr(game+0x347cd80)
        local atlas=tm and ptr(tm+11112)
        if atlas then
            for key,b in pairs(bindings)do
                if not entries[b.key]and b.world==s.world and b.owner==s.owner then
                    local record=api.pointer(read(b.widget+1984,8))
                    local material_pointer=read(b.element+328,8)
                    if material_pointer==b.material_pointer then
                        set_texture(b.element,984135806,atlas)
                        if record and read(b.widget+1984,8)==b.record_pointer
                            and read(record,8)==b.visual and read(record+60,8)==b.indices
                            and read(b.widget+2005,1)~='\0' then
                            byte(record+68,1)
                            set_alpha(b.element,0);set_alpha(b.widget+616,1)
                        end
                    end
                    bindings[key]=nil
                end
            end
        end
        return hits,misses,early,unresolved,initialized
    end
    local function destroy_owned(t)
        if t.destroyed or t.returned then return end
        local tm=ptr(game+0x347cd80)
        assert(not tm or ptr(tm+11112)~=t.handle,'Refusing to release the game working atlas')
        local d=read(t.handle,8)
        assert(raw(d,0,8)==t.id,'Retained texture identity changed')
        destroy(t.handle)
        t.destroyed=true
    end
    restore_working=function()
        local backup=working_backup
        if not backup or backup.texture.destroyed or backup.texture.returned then return end
        local s=self:snapshot();local t=backup.texture
        -- Idle retention leaves a blank replacement behind native state-8
        -- cards. If those exact requests are still current during disable or
        -- pressure cleanup, return the real pixels to native ownership first.
        -- A different request/manager/layout already owns its own generation.
        if s.context~=backup.context or s.manager~=backup.manager or s.capture_id~=backup.request
            or s.layout~=backup.layout or not s.complete or s.atlas~=t.replacement then working_backup=nil;return end
        assert(read(t.handle,8)==t.id,'Idle backup texture identity changed')
        register(3400165836,t.handle)
        ffi.cast('void **',s.manager+11112)[0]=t.handle
        for _,element in ipairs(s.registry or {})do set_texture(element,984135806,t.handle)end
        t.returned=true
        destroy(t.replacement)
        blank_working=nil
        working_backup=nil
    end
    function self:destroy(t)
        if t.retired or t.destroyed then return end
        if (t.pins or 0)>0 then retired[#retired+1]=t else destroy_owned(t)end
        t.retired=true
    end
    function self:drain()
        for i=#retired,1,-1 do
            if (retired[i].pins or 0)==0 then destroy_owned(retired[i]);table.remove(retired,i)end
        end
    end
    return self
end
return M
