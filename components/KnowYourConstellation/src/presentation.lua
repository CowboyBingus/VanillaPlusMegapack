-- Read the native panel's solved screen rectangle and opacity. These fields
-- are build locked by install.lua. This module never changes native widgets.
local ffi = require('ffi')
local bit = require('bit')
local M = {}

function M.new(api,game)
    local function read(address,size)
        assert(address and size <= 1024, 'Invalid presentation read')
        local bytes = api.read(address,size)
        assert(bytes and #bytes == size, 'Presentation data unavailable')
        return bytes
    end
    local function number(bytes,offset,ctype)
        local value = ffi.new(ctype..'[1]')
        ffi.copy(value,bytes:sub(offset+1,offset+4),4)
        return tonumber(value[0])
    end
    local function uint(bytes,offset) return number(bytes,offset,'uint32_t') end
    local function float(bytes,offset) return number(bytes,offset,'float') end
    local function pointer(address)
        local result = api.pointer(read(address,8))
        assert(result, 'Presentation owner unavailable')
        return result
    end
    local function hash(address)
        local bytes = read(address,8)
        local value = string.format('%08x%08x',uint(bytes,4),uint(bytes,0))
        assert(value~='0000000000000000', 'Native font is not ready')
        return value
    end
    local self = {}
    function self:sample(screen)
        if screen ~= 'map' and screen ~= 'briefing' then return nil end
        local manager = pointer(game+0x3326e68)
        local registry = screen == 'map' and 25224 or 25272
        local kind = screen == 'map' and 226 or 229
        -- These event registries have one inline subscriber. A zero count can
        -- leave a stale pointer behind, so never inspect it without the count.
        local entry = read(manager+registry,24)
        if uint(entry,0) ~= 1 or uint(entry,16) ~= kind then return nil end
        local owner = api.pointer(entry,8)
        if not owner then return nil end
        if screen == 'briefing' and uint(read(owner+8,4),0) ~= 0 then return nil end
        local function rectangle(offset)
            local widget = read(owner+offset,164)
            -- +84 is inherited opacity, including the pod entry animation. +68
            -- alone is local opacity and can remain one while its parent is hidden.
            local opacity = float(widget,84)
            if bit.band(uint(widget,0),0x10) == 0 or not (opacity>=0.995 and opacity<=1.01) then return nil end
            local sx,sy = float(widget,100),float(widget,140)
            local box = {x=float(widget,148),y=float(widget,156),
                w=float(widget,36)*sx,h=float(widget,40)*sy,scale=sx}
            for _,v in pairs(box) do
                if v ~= v or v < 0 or v > 32768 then return nil end
            end
            if sx < 0.3 or sx > 4 or math.abs(sx-sy)>0.01 or box.w<200 or box.h<40 then return nil end
            return box
        end
        local box = rectangle(screen == 'map' and 349072 or 31232)
        if not box and screen=='map' then
            box = rectangle(280528)
            if box then
                -- The planet frame stays fixed while joinable cards move and
                -- fade between hovers. Card activity is a fallback for local
                -- previews. Remote hover activity comes from mission selection.
                local preview = read(owner+526048,88)
                local opacity = float(preview,84)
                box.client = true
                box.active = bit.band(uint(preview,0),0x10)~=0
                    and opacity>0.001 and opacity<=1.01
            end
        end
        if not box then return nil end
        -- The active locale's body face and its normal material. The native
        -- font initializer at 0xf553c0 populates these same rendering tables.
        box.font = hash(game+0x3772268)
        box.material = hash(pointer(game+0x37c5478)+24)
        box.atlas = hash(game+0x3772ee8)
        box.screen = screen
        -- No guessed coordinates if the native panel is absent or mid-layout.
        return box
    end
    return self
end

return M
