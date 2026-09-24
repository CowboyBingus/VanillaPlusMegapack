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
function M.new(api,game,exe,signatures,test_calls)
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
    local image_material_bytes=ffi.string(ffi.new('uint64_t[1]',image_material),8)
    local function supported_material(bytes)
        local resource=raw(bytes,608,8)
        return (resource==string.rep('\0',8) and api.pointer(bytes,600)~=nil)
            or resource==image_material_bytes
    end
    local bindings={}
    local self={}
    local retired={}
    local working_backup,restore_working
    -- Configured weapon slots observed in the native preview queue, keyed by the
    -- request identity. A weapon's applied pattern and attachments live here, not
    -- in the thumbnail request record, so this is the only appearance signal the
    -- cache can key on. The queue only holds work while a preview is generating,
    -- so the last observation per identity is remembered for the session.
    local preview_observed={}
    local function observe_previews()
        local preview=ptr(game+0x347ce60)
        if not preview then return end
        local header=read(preview+50448,8)
        local head,tail=u32(header,0),u32(header,4)
        assert(head<128 and tail<128,'Preview queue bounds changed')
        local index,jobs=head,0
        while index~=tail and jobs<16 do
            local row=read(preview+50456+index*200,200)
            local count=u32(row,80)
            assert(count<=10,'Preview queue dependency bound changed')
            preview_observed[raw(row,64,8)]=raw(row,88,count*8)
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
    local function reconcile(clear)
        if not next(bindings)then return end
        local owner,kind=controller()
        local ui=ptr(game+0x347cd90)
        local world=ui and ptr(ui+15432)
        local tm=ptr(game+0x347cd80)
        local atlas=tm and ptr(tm+11112)
        local keep={}
        for _,b in pairs(bindings)do
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
                    if not clear and owned then keep[pointer_key(b.widget)]=b
                    else
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
        end
        bindings=keep
    end
    function self:restore(return_working)
        if return_working and restore_working then restore_working()end
        reconcile(true)
    end
    function self:prune()reconcile(false)end
    local function descriptor(atlas)
        local d=read(atlas,104)
        assert(u32(d,8)==0 and u32(d,12)==0 and u32(d,28)==1 and u32(d,32)==1
            and d:byte(100)==1,'Unsupported thumbnail texture descriptor')
        local w,h=u32(d,20),u32(d,24)
        assert(w>=64 and h>=64 and w<=4096 and h<=16384,'Thumbnail dimensions exceed bounds')
        return d,w,h
    end
    local function widget(result,address,rec,item)
        local a=read(address,704);local tail=read(address+1984,24)
        if bit.band(u32(a,272),0x3c0000)~=0xc0000 or not supported_material(a)then return end
        result.widgets[#result.widgets+1]={key=item.key,owner=result.owner,world=result.world,controller_kind=result.controller_kind,
            widget=address,element=address+272,record_pointer=raw(tail,0,8),
            visual=raw(rec,0,8),bound=tail:byte(22)~=0,invalidated=rec:byte(69)~=0,
            named_material=raw(a,608,8)==image_material_bytes,
            native_ready=item.ready,indices=raw(rec,60,8),uv=raw(a,548,16),size=raw(a,284,8),
            alpha=float(a,340),spinner_alpha=float(a,684),
            box_width=float(a,12)*float(a,28),box_height=float(a,16)*float(a,32),fit=u32(tail,16)}
    end
    local function idle_gate(result,mb,by_index,owned)
        result.can_freeze_idle=result.complete and result.blank_cards==0
            and #result.widgets>0 and #result.items==result.expected_count
        for c=0,5 do if u32(mb,c*1816+1832)~=0 and not owned[c]then
            result.can_freeze=false;result.can_freeze_idle=false
        end end
        for _,item in pairs(by_index)do if not item.key then result.can_freeze_idle=false end end
        -- The registry includes hidden widgets from the screen we just left.
        -- An idle detach is allowed only when every visible consumer can be
        -- rebound in this callback. Hidden consumers are moved to fresh too.
        result.registry={};local mapped={}
        for _,w in ipairs(result.widgets)do
            mapped[pointer_key(w.element)]=true
            if w.fit<1 or w.fit>3 or not finite(w.box_width) or not finite(w.box_height)
                or w.box_width<=0 or w.box_height<=0 then result.can_freeze_idle=false end
        end
        local n=u32(mb,11136);assert(n<=128,'Image registry bounds')
        for i=0,n-1 do
            local element=assert(api.pointer(mb,11144+i*8))
            result.registry[#result.registry+1]=element
            if not mapped[pointer_key(element)]then
                local bytes=read(element,88)
                if bit.band(u32(bytes,0),0x3c0000)~=0xc0000 or float(bytes,84)~=0 then
                    result.can_freeze_idle=false
                end
            end
        end
    end
    function self:snapshot()
        local result={items={},widgets={},expected_count=0}
        local sm=ptr(game+0x347ce28);local ui=ptr(game+0x347cd90)
        local tm=ptr(game+0x347cd80)
        if not tm then return result end
        -- The detached render texture is globally allocated through the engine
        -- application API, not owned by the transient Armory UI world. Preserve
        -- it while the thumbnail manager survives, even with no active menu.
        result.context=pointer_key(tm);result.manager=tm
        if not sm or not ui then return result end
        local st=read(sm+0x429c,24);local depth=u32(st,20)
        local top=depth>=1 and depth<=5 and u32(st,(depth-1)*4)
        local kind=top==5 and 224 or (top==14 and 229 or nil)
        if not kind then return result end
        local world=ptr(ui+15432);if not world then return result end
        result.world=world;result.controller_kind=kind;result.owner=controller(kind)
        result.view=pointer_key(world)..string.char(kind)..(result.owner and pointer_key(result.owner) or '')
        local mb=read(tm,12176);local atlas=api.pointer(mb,11112)
        if not atlas then return result end
        local desc,w,h=descriptor(atlas)
        result.atlas=atlas;result.width=w;result.height=h;result.bytes=w*h*4
        result.descriptor_id=raw(desc,0,8)
        result.layout=raw(mb,16,16)..raw(mb,11100,8)..raw(desc,8,28)
        -- Appearance observation is an optimization; a transient queue read must
        -- never invalidate the sample.
        pcall(observe_previews)
        local by_index,ids={},{}
        result.source_cards={};result.blank_cards=0
        if blank_working and (blank_working.atlas~=atlas or blank_working.id~=result.descriptor_id
            or blank_working.context~=result.context or blank_working.manager~=tm)then blank_working=nil end
        local active,all_complete,safe,nonempty=u32(mb,11064),true,true,0
        local phase=u32(mb,11096)
        for c=0,5 do
            local at=c*1816;local state,n=u32(mb,at+1832),u32(mb,at+1836)
            assert(state<=8 and n<=15,'Image card bounds')
            if state~=0 then
                local stamp={string.char(n)}
                result.expected_count=result.expected_count+n
                nonempty=nonempty+1
                if state~=8 then all_complete=false end
                if state~=3 and state~=4 and state~=5 then safe=false end
                for i=0,n-1 do
                    local o=at+32+i*120;local kind=u32(mb,o+100)
                    local input=raw(mb,o,104)
                    stamp[#stamp+1]=M.key('',input,'')..raw(mb,o+56,16)
                    if kind<=4 then
                        local item={input=input,card=c,index=i,ready=state==8,rectangle=raw(mb,o+56,16),
                            preview=preview_observed[raw(input,24,8)]}
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
        result.tile_width=float(mb,24);result.tile_height=float(mb,28)
        if not result.owner then result.can_freeze=false;return result end
        if kind==229 then
            local records=read(result.owner+454728,480)
            local expected={2,3,4,0,0,1};local slots={};local valid=true
            for index=0,5 do
                local rec=raw(records,index*80,80)
                local card,slot=u32(rec,60),u32(rec,64)
                local item=card<6 and slot<15 and by_index[card*15+slot]
                local address=result.owner+422768+index*5464
                if not item or u32(rec,8)~=3 or u32(item.input,100)~=expected[index+1]
                    or ptr(address+1984)~=result.owner+454728+index*80 then valid=false;break end
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
                idle_gate(result,mb,by_index,owned)
                return result
            end
        end
        local control=result.owner+280216
        local pre=kind==224 and read(control+37968,16)
        if pre and pre:byte(5)==0 and u32(pre,0)<6 then
            local mode=u32(pre,12);assert(mode<=2,'Pre-select mode bounds')
            result.screen=mode==0 and 'weapon_preselect' or 'cosmetic_preselect'
            local records=read(control+37728,240);local owned={[u32(pre,0)]=true}
            for index=0,2 do
                local rec=raw(records,index*80,80)
                local card,slot=u32(rec,60),u32(rec,64)
                local item=card<6 and slot<15 and by_index[card*15+slot]
                if item and owned[card] and u32(rec,8)==3 then
                    item.key=M.key(result.layout,item.input,'preselect'..raw(pre,12,4)..raw(rec,0,8)..raw(rec,72,4))
                    result.items[#result.items+1]=item
                    ids[#ids+1]=string.char(card,slot)..item.key
                    local address=control+5256+index*12304
                    if ptr(address+1984)==control+37728+index*80 then widget(result,address,rec,item)end
                end
            end
            if #result.items>0 then result.capture_id=pointer_key(atlas)..table.concat(ids)end
            idle_gate(result,mb,by_index,owned)
            return result
        end
        result.screen=kind==229 and 'briefing_grid' or 'grid'
        local grid=result.owner+(kind==229 and 864032 or 523752)
        local meta=read(grid+597772,24892)
        local count=u32(meta,0);assert(count<=12,'Image grid row bounds')
        -- Every nonempty card must belong to this grid. Empty cards do not
        -- render, so small categories can hand over the completed old atlas too.
        local owned={}
        for i=0,5 do
            local card=u32(meta,622592-597772+i*12)
            if card<6 then owned[card]=true end
        end
        for c=0,5 do if u32(mb,c*1816+1832)~=0 and not owned[c]then result.can_freeze=false end end
        local grid_kind=raw(meta,602052-597772,4)
        -- Resolve every requested item through its grid record, including
        -- offscreen cards. Record style distinguishes alternate camera presets.
        for index=0,255 do
            local rec=raw(meta,602104-597772+index*80,80)
            local card,slot=u32(rec,60),u32(rec,64)
            local item=card<6 and slot<15 and by_index[card*15+slot]
            if item and u32(rec,8)==3 then
                local key=M.key(result.layout,item.input,grid_kind..raw(rec,0,8)..raw(rec,72,4))
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
            local columns=u32(read(rb+44724,4),0);assert(columns<=4,'Image grid column bounds')
            for col=0,columns-1 do
                local widget=rb+9192+col*11112
                local a=read(widget,704);local tail=read(widget+1984,24)
                local record=api.pointer(tail)
                local record_offset=record and tonumber(record-(grid+602104)) or -1
                if record_offset>=0 and record_offset<256*80 and record_offset%80==0 then
                    local rec=raw(meta,602104-597772+record_offset,80)
                    local card,index=u32(rec,60),u32(rec,64)
                    local item=card<6 and index<15 and by_index[card*15+index]
                    if item and item.key and u32(rec,8)==3 and bit.band(u32(a,272),0x3c0000)==0xc0000
                        and supported_material(a) then
                        result.widgets[#result.widgets+1]={key=item.key,owner=result.owner,world=result.world,controller_kind=result.controller_kind,
                            widget=widget,element=widget+272,record_pointer=raw(tail,0,8),
                            visual=raw(rec,0,8),bound=tail:byte(22)~=0,invalidated=rec:byte(69)~=0,
                            named_material=raw(a,608,8)==image_material_bytes,
                            native_ready=item.ready,
                            indices=raw(rec,60,8),uv=raw(a,272+276,16),size=raw(a,272+12,8),
                            alpha=float(a,272+68),spinner_alpha=float(a,616+68),
                            box_width=float(a,12)*float(a,28),box_height=float(a,16)*float(a,32),
                            fit=u32(tail,16)}
                    end
                end
            end
        end
        idle_gate(result,mb,by_index,owned)
        return result
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
        assert((s.can_freeze or (s.can_freeze_idle and p.request_id==s.capture_id))
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
    function self:apply(s,entries)
        local hits,misses,early=0,0,0
        local checked={}
        for _,w in ipairs(s.widgets)do
            local entry=entries[w.key]
            if entry and w.box_width>0 and w.box_height>0 and w.fit>=1 and w.fit<=3 then
                local ratio=w.fit==1 and math.max(entry.width/w.box_width,entry.height/w.box_height)
                    or (w.fit==2 and entry.height/w.box_height or entry.width/w.box_width)
                if finite(ratio) and ratio>0 then
                    if not checked[entry.texture]then
                        assert(not entry.texture.destroyed and not entry.texture.returned
                            and read(entry.texture.handle,8)==entry.texture.id,'Cached texture ownership changed')
                        checked[entry.texture]=true
                    end
                    if not w.bound or w.invalidated or w.named_material then
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
                    else misses=misses+1 end
                end
            else misses=misses+1 end
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
        return hits,misses,early
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
