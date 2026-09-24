local ffi = require('ffi')
local bit = require('bit')
local M = {}
local word = ffi.new('uint32_t[1]')
local half = ffi.new('uint16_t[1]')
local float = ffi.new('float[1]')

local function u32(bytes, offset)
    assert(bytes and offset >= 0 and offset + 4 <= #bytes, 'Short mission field')
    ffi.copy(word, bytes:sub(offset + 1, offset + 4), 4)
    return tonumber(word[0])
end

local function f32(bytes, offset)
    ffi.copy(float, bytes:sub(offset + 1, offset + 4), 4)
    return tonumber(float[0])
end

local function u16(bytes, offset)
    ffi.copy(half, bytes:sub(offset + 1, offset + 2), 2)
    return tonumber(half[0])
end

function M.new(api, game, resolve)
    local self = {api=api, game=game, resolve=resolve}
    local function read(address, size)
        assert(size > 0 and size <= 65536, 'Mission read bound exceeded')
        local bytes = assert(api.read(address, size), 'Mission data unavailable')
        return bytes
    end
    local function ptr(address)
        local address_value = assert(api.pointer(read(address, 8)), 'Mission pointer unavailable')
        return address_value
    end
    local function count(address, maximum)
        local value = u32(read(address, 4), 0)
        assert(value <= maximum, 'Mission array bound exceeded')
        return value
    end

    function self:screen()
        local manager = ptr(game + 0x347ce28)
        local state = read(manager + 0x429c, 24)
        local n = u32(state, 20)
        if n < 1 or n > 5 then return nil end
        local top = u32(state, 4 * (n - 1))
        if top == 15 then return 'map' end
        if top == 14 then return 'briefing' end
        return nil
    end

    local function identity(bytes)
        assert(#bytes == 200, 'Invalid mission descriptor')
        local faction, difficulty = bytes:byte(9, 10)
        assert(faction >= 2 and faction <= 4 and difficulty >= 1 and difficulty <= 10,
            'Mission descriptor not ready')
        local mission = u16(bytes, 26)
        assert(mission < 256, 'Unknown mission type')
        local seed, secondary, planet = u32(bytes, 0), u32(bytes, 4), u32(bytes, 12)
        local key = table.concat({seed, secondary, faction, difficulty, planet, mission}, ':')
        return {key=key, seed=seed, faction=faction, difficulty=difficulty, planet=planet, mission=mission}
    end

    local function joinable_preview(board,root)
        -- Mirror the native map lookup (0x1036670 / 0x1036710). A missing
        -- operation selection alone does not authorize cached preview data.
        -- The second result distinguishes an ended hover from a selected
        -- mission whose advertised packet or preview is still loading.
        local planet = u32(read(board+1548956,4),0)
        if planet>=0x80000000 or read(board+2064401,1):byte()==0 then return nil,false end
        local selection = read(board+1548964,8)
        local id,group = u32(selection,0),u32(selection,4)
        if id>=0x80000000 or group==0 then
            local session = ptr(game+0x3326aa0)
            local fallback = read(session+5633600,12)
            if id>=0x80000000 then id=u32(fallback,0) end
            if group==0 then group=u32(fallback,8) end
        end
        if id>=0x80000000 or group==0 then return nil,false end
        local total = count(board+2053224,440)
        if total==0 then return nil,true end
        local rows = read(board+2044424,total*20)
        local kind,index
        for i=0,total-1 do
            local at=i*20
            if u32(rows,at+8)==group and u32(rows,at+12)==id then
                assert(not kind, 'Ambiguous joinable mission')
                kind,index=u32(rows,at),u32(rows,at+4)
            end
        end
        local layout = ({[1]={1097440,1253440,100},[2]={1253448,1409448,100},
            [3]={1409456,1487456,50}})[kind]
        if not layout then return nil,true end
        local manager = ptr(game+0x347ce80)
        if index>=count(manager+layout[2],layout[3]) then return nil,true end
        local record = manager+layout[1]+index*1560
        if read(record+1456,1):byte()==0 then return nil,true end
        local advertised = read(record+944,512):match('^([^%z]+)%z')
        -- The native preview builder decodes this advertisement into the board
        -- descriptor and loads its canonical packet into the single preview slot.
        if u32(read(board+4286668,4),0)~=0 then return nil,true end
        local loaded = read(root+713400,512):match('^([^%z]+)%z')
        if not advertised or advertised~=loaded then return nil,true end
        return planet,true
    end

    function self:descriptor(screen)
        local root = ptr(game + 0x3326340)
        local controller = ptr(root + 0xae288)
        local board = ptr(game + 0x347cee8)
        local address = board + 0x4168d0
        local preview_planet,hovered,operation_planet,operation_index
        if screen == 'briefing' then
            local manager = ptr(game + 0x3326e68)
            local n = count(manager + 26184, 1024)
            assert(n > 0, 'Briefing descriptor unavailable')
            local rows = read(manager + 26192, n * 16)
            local selected
            for i = 0, n - 1 do
                if u32(rows, 16 * i + 8) == 235 then
                    assert(not selected, 'Ambiguous briefing owner')
                    selected = assert(api.pointer(rows, 16 * i))
                end
            end
            assert(selected, 'Briefing owner unavailable')
            address = selected + 1072
        else
            local index = u32(read(board + 1548960, 4),0)
            if index==0xffffffff then
                preview_planet,hovered = joinable_preview(board,root)
                if not preview_planet then return nil,hovered end
            else
                assert(index < 110, 'No highlighted mission')
                local selected = read(board + 1012352 + index * 92, 92)
                assert(selected:byte(53) ~= 0, 'No highlighted mission')
                operation_planet,operation_index = u16(selected,16),index
            end
        end
        local bytes = read(address, 200)
        local result = identity(bytes)
        -- The native modifier/stamp path consumes the loaded controller.
        -- A stale controller cannot authorize a full composition forecast.
        local loaded = read(controller + 8, 200)
        local ok, current = pcall(identity, loaded)
        result.controller_matches = ok and current.key == result.key
        result.address, result.bytes = address, bytes
        result.controller, result.board, result.root = controller, board, root
        result.preview_planet = preview_planet
        result.operation_planet,result.operation_index = operation_planet,operation_index
        result.screen = screen
        return result,hovered
    end

    local function settings(snapshot)
        local b = read(game + 0x328d2a0 + (snapshot.difficulty - 1) * 816, 816)
        local start = ({[2]=276,[3]=372,[4]=468})[snapshot.faction]
        local fallback = ({[2]=564,[3]=600,[4]=636})[snapshot.faction]
        local result = {draws=u32(b,272), candidates={}, blockers={}, fallback=resolve.from_native(u32(b,fallback+32))}
        for i = 0, 7 do
            local at = start + i * 12
            result.candidates[#result.candidates + 1] = {id=resolve.from_native(u32(b,at)),weight=f32(b,at+4),
                only_when_empty=b:byte(at+9) ~= 0}
            result.blockers[#result.blockers + 1] = resolve.from_native(u32(b,fallback+i*4))
        end
        return result
    end

    local function campaign(snapshot, hashes, initial)
        local board, root = snapshot.board, snapshot.root
        local data = board + 1053752
        local planet = snapshot.preview_planet or snapshot.operation_planet or count(board + 1548952, 511)
        local n = count(board + 1197132, 512)
        assert(planet < n, 'Planet data changed')
        if not snapshot.preview_planet and not snapshot.operation_planet then
            assert(u32(read(data + 495200,4),0) == planet, 'Planet data changed')
        end
        -- Map previews can be on a different planet from the active operation.
        -- Use the advertised planet for remote hovers or the highlighted local
        -- operation's planet. Check its hash before applying campaign inputs.
        local static = read(data + 280 * planet, 280)
        assert(u32(static,24) == snapshot.planet, 'Selected planet does not match this mission')
        local dynamic = read(data + 304 * planet + 286752, 304)
        local session = ptr(game + 0x347cef0)
        local complete = true
        local gated = read(session+92102,1):byte() ~= 0 or read(root+4205,1):byte() ~= 0
            or read(root+4217,1):byte() ~= 0
        local defs = ptr(game + 0x347cd98)
        local dn = count(defs+53248,1024)
        local rows = dn > 0 and read(defs,dn*52) or ''
        local by_id, by_hash = {}, {}
        for i = 0, dn - 1 do
            local at = i * 52
            if u32(rows,at+4) == 40 and u32(rows,at+24) == 13 then
                local tag = hashes[u32(rows,at+28)]
                assert(tag, 'Unknown campaign enemy tag')
                by_id[u32(rows,at)] = tag
            end
            if by_hash[u32(rows,at+8)] == nil then by_hash[u32(rows,at+8)] = u32(rows,at) end
        end
        local function add_ids(bytes, at, length, maximum)
            assert(length <= maximum, 'Too many campaign modifiers')
            for i = 0, length - 1 do resolve.add(initial, by_id[u32(bytes,at+i*4)]) end
        end
        if not gated then
            local selected = read(data+304*planet+286952,132)
            add_ids(selected,0,u32(selected,128),32)
            add_ids(static,184,u32(static,200),4)
            for i = 0, count(data+494868,4) - 1 do
                local env = read(data+494696+i*44,44)
                if u32(env,0) == planet then add_ids(env,4,u32(env,36),8) end
            end
            for i = 0, count(data+490072,8) - 1 do
                local event = read(data+470104+2496*i,2496)
                local pn = u32(event,2480)
                assert(pn <= 32, 'Too many event planets')
                local applies = pn == 0
                for j = 0, pn - 1 do if u32(event,2352+4*j) == planet then applies = true end end
                if applies then add_ids(event,2336,u32(event,2348),3) end
            end
            local selected_index = u32(read(board+1548960,4),0)
            assert(selected_index<=110 or selected_index==0xffffffff, 'Invalid operation selection')
            assert(not snapshot.operation_index or selected_index==snapshot.operation_index,
                'Operation changed during read')
            if not snapshot.preview_planet and selected_index < 110 then
                local selected = read(board+1012352+92*selected_index,92)
                assert(u16(selected,16)==planet, 'Operation planet does not match this mission')
                local category = u32(selected,28)
                if selected:byte(53) ~= 0 and category < 14
                    and read(game+0x32e98e0+168*category+9,1):byte() ~= 0 then
                    local operation_id, template_id
                    for i = 0, count(data+155672,512)-1 do
                        local operation = read(data+143384+24*i,24)
                        if u32(operation,0) == u16(selected,16)
                            and u32(operation,4) == selected:byte(25) then
                            operation_id = u32(operation,4)
                            break
                        end
                    end
                    if operation_id then
                        for i = 0, count(data+155672,512)-1 do
                            local operation = read(data+143384+24*i,24)
                            if u32(operation,0) == planet and u32(operation,4) == operation_id then
                                template_id = u32(operation,8)
                                break
                            end
                        end
                    end
                    if template_id then
                        local header = read(board+0x1f8908,24)
                        local values = api.pointer(header)
                        local total = u32(header,16)
                        assert(total <= 4096, 'Too many operation templates')
                        if values and total > 0 then
                            local keys = read(assert(api.pointer(header,8)),total*4)
                            for i = 0, total-1 do
                                if u32(keys,4*i) == template_id then
                                    local template = ptr(values+8*i)
                                    local total_mods = count(template+96,256)
                                    if total_mods > 0 then
                                        local list = read(ptr(template+88),total_mods*4)
                                        for j = 0, total_mods-1 do
                                            resolve.add(initial,by_id[by_hash[u32(list,4*j)]])
                                        end
                                    end
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
        local faction, region = u32(dynamic,36), u32(dynamic,64)
        local globals = read(ptr(game+0x346d518),32*356)
        for i = 0, 31 do
            local at = i*356
            local scope, value, filter = globals:byte(at+85), u32(globals,at+88), u32(globals,at+92)
            local applies = scope == 3 or scope == 0 and value == planet
                or scope == 1 and value == region or scope == 2 and value == faction
            if applies and (filter == 0 or filter == faction) then
                local total = u32(globals,at+80)
                assert(total <= 5, 'Too many global modifier entries')
                for j = 0, total - 1 do
                    if globals:byte(at+16*j+1) == 17 then resolve.add(initial,resolve.from_native(u32(globals,at+16*j+4))) end
                end
            end
        end
        return complete
    end

    local function stamp(snapshot, initial)
        local controller = snapshot.controller
        local level = ptr(controller+648)
        local explicit = read(level+9160276,16)
        local n = u32(explicit,12)
        assert(n <= 3, 'Too many explicit tags')
        for i = 0, n - 1 do resolve.add(initial,resolve.from_native(u32(explicit,4*i))) end
        if api.pointer(read(controller,8)) and count(level+18510124,100000) ~= 0 then
            local selection = read(level+9017008,168)
            local index, variant = selection:byte(163), selection:byte(162)
            if index ~= 255 then
                local address
                local owner = assert(api.pointer(selection))
                if u32(selection,8) == 2915250090 then
                    if variant ~= 255 then address = ptr(ptr(owner+40)+24*variant+8)+456*index end
                else
                    address = ptr(owner)
                end
                if address then resolve.add(initial,resolve.from_native(u32(read(address+208,4),0))) end
            end
        end
    end

    local function excluded_by_config(tag_hash)
        local manager = ptr(game+0x347cdf8)
        local key = resolve.exclusion_key(tag_hash)
        for _, offset in ipairs({73848,49232}) do
            local header = read(manager+offset,24)
            local capacity, empty, multiplier = u32(header,8), u32(header,12), u32(header,16)
            assert(capacity <= 65536 and (capacity == 0 or bit.band(capacity,capacity-1) == 0),
                'Unexpected configuration map')
            if capacity > 0 then
                local data = assert(api.pointer(header))
                local product = tonumber(ffi.cast('uint32_t',ffi.new('uint64_t',key)*multiplier))
                local finished = false
                for probe = 0, math.min(capacity,128)-1 do
                    local slot = bit.band(product+probe,capacity-1)
                    local found = u32(read(data+48*slot,4),0)
                    if found == key then return true end
                    if found == empty then finished = true break end
                end
                assert(finished or capacity <= 128, 'Configuration lookup bound exceeded')
            end
        end
        return false
    end

    function self:sample(screen)
        local snapshot = self:descriptor(screen)
        if not snapshot then return nil end
        local hash_bytes = read(game+0x21e1920,32*4)
        local hashes, hash_by_id = {}, {}
        for i = 0, 31 do
            local hash = u32(hash_bytes,i*4)
            local tag = resolve.from_native(i)
            hashes[hash], hash_by_id[tag] = tag, hash
        end
        local initial = {}
        snapshot.unresolved = {}
        local ok, result = pcall(campaign,snapshot,hashes,initial)
        if not ok then initial = {} end
        if not ok then snapshot.unresolved[#snapshot.unresolved+1] = tostring(result) end
        local complete = ok and result and snapshot.controller_matches
        if snapshot.controller_matches then
            local good, reason = pcall(stamp,snapshot,initial)
            if not good then snapshot.unresolved[#snapshot.unresolved+1] = tostring(reason) end
            complete = complete and good
        else
            snapshot.unresolved[#snapshot.unresolved+1] = 'Hovered mission differs from the loaded mission'
        end
        local tags = resolve.base(snapshot.seed,settings(snapshot),initial)
        -- Native build 25480438 uses 896-byte mission records, a conditional
        -- additional tag, and eight exclusions (formerly one).
        local mission_config = read(game+0x3773420+896*snapshot.mission,896)
        if mission_config:byte(0x34+1)==2 and
            mission_config:sub(0x360+1,0x360+8)=='\073\120\130\127\209\044\124\133' then
            resolve.add(tags,31)
        end
        local disabled = {}
        for _, tag in ipairs(tags) do
            local ok, value = pcall(excluded_by_config,hash_by_id[tag])
            if ok then disabled[tag] = value else
                complete = false
                snapshot.unresolved[#snapshot.unresolved+1] = tostring(value)
            end
        end
        local exclusion = {}
        for i=0,7 do
            local native=u32(mission_config,0x14+4*i)
            if native~=0 then exclusion[resolve.from_native(native)]=true end
        end
        snapshot.tags = resolve.filter(tags,exclusion,disabled)
        snapshot.complete = complete
        if read(snapshot.address,200) ~= snapshot.bytes or self:screen() ~= screen then return nil end
        if snapshot.preview_planet and
            u32(read(snapshot.board+1548956,4),0)~=snapshot.preview_planet then return nil end
        if snapshot.operation_index and (u32(read(snapshot.board+1548960,4),0)~=snapshot.operation_index
            or u16(read(snapshot.board+1012352+92*snapshot.operation_index+16,2),0)~=snapshot.operation_planet)
            then return nil end
        return snapshot
    end
    return self
end

return M
