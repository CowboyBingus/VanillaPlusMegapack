-- Read the native panel's solved screen rectangle and opacity. These fields
-- are build locked by install.lua. This module never changes native widgets.
-- Reads land in buffers this reader keeps and fields decode in place, so a
-- sample allocates nothing when the caller passes the table to fill.
local ffi = require('ffi')
local bit = require('bit')
local M = {}

-- Expected transient states, while the game builds or switches screens, are
-- raised as constant tables {pending = reason, status = 'hidden: ' .. reason}:
-- a waiting frame builds no string, and the installer hides and retries on the
-- next frame without counting the frame toward stopping the mod (as v4.0 did
-- for every raised frame). Everything else raises a string and counts.
local function pending(reason) return {pending = reason, status = 'hidden: ' .. reason} end
local DATA_UNAVAILABLE = pending('Presentation data unavailable')
local OWNER_UNAVAILABLE = pending('Presentation owner unavailable')
local FONT_NOT_READY = pending('Native font is not ready')
M.PENDING = {DATA_UNAVAILABLE, OWNER_UNAVAILABLE, FONT_NOT_READY}

local function uint(b, at) return b[at] + b[at + 1] * 256 + b[at + 2] * 65536 + b[at + 3] * 16777216 end
-- The user-mode pointer stored at b[at] (little-endian), or nil.
local function pointer_at(b, at)
    if b[at + 6] ~= 0 or b[at + 7] ~= 0 then return nil end
    local value = uint(b, at) + (b[at + 4] + b[at + 5] * 256) * 4294967296
    if value < 0x10000 or value >= 0x800000000000 then return nil end
    return value
end
local function buffer(size)
    local data = ffi.new('uint8_t[?]', size)
    return {data = data, address = tonumber(ffi.cast('uintptr_t', data)), size = size}
end
local function out_of_range(v) return v ~= v or v < 0 or v > 32768 end

-- A float decoder: the bits go in and the float comes out of one union cell
-- (as in mission.lua: a second view of the cell would read back stale values
-- in compiled code). Declared on first use, under a private name.
local function float_decoder()
    if not pcall(ffi.typeof, 'hd2kyc_float_bits') then
        ffi.cdef('typedef union { uint32_t bits; float value; } hd2kyc_float_bits;')
    end
    local cell = ffi.new('hd2kyc_float_bits')
    return function(b, at)
        cell.bits = uint(b, at)
        return cell.value
    end
end

function M.new(api,game)
    local scratch, widget_bytes, preview_bytes = buffer(64), buffer(164), buffer(88)
    local real = float_decoder()
    local function read(address,size,into)
        into = into or scratch
        assert(address and size <= 1024 and size <= into.size, 'Invalid presentation read')
        if not api.read(address,size,into,0) then error(DATA_UNAVAILABLE) end
        return into.data
    end
    local function pointer(address)
        local result = pointer_at(read(address,8),0)
        if not result then error(OWNER_UNAVAILABLE) end
        return result
    end
    -- A resource hash read each frame, so an unready font table hides the panel
    -- at once; its hex text is formatted again only when the words change, which
    -- they do only when the game loads another font (a language change).
    local function hash_reader()
        local last_high,last_low,text
        return function(address)
            local bytes = read(address,8)
            local high,low = uint(bytes,4),uint(bytes,0)
            if high == 0 and low == 0 then error(FONT_NOT_READY) end
            if high ~= last_high or low ~= last_low then
                last_high,last_low,text = high,low,string.format('%08x%08x',high,low)
            end
            return text
        end
    end
    local font_hash,material_hash,atlas_hash = hash_reader(),hash_reader(),hash_reader()
    -- The widget's solved rectangle into box, when it is fully visible.
    local function rectangle(owner,offset,box)
        local widget = read(owner+offset,164,widget_bytes)
        -- +84 is inherited opacity, including the pod entry animation. +68
        -- alone is local opacity and can remain one while its parent is hidden.
        local opacity = real(widget,84)
        if bit.band(uint(widget,0),0x10) == 0 or not (opacity>=0.995 and opacity<=1.01) then return false end
        local sx,sy = real(widget,100),real(widget,140)
        local x,y,w,h = real(widget,148),real(widget,156),real(widget,36)*sx,real(widget,40)*sy
        if out_of_range(x) or out_of_range(y) or out_of_range(w) or out_of_range(h) or out_of_range(sx) then
            return false
        end
        if sx < 0.3 or sx > 4 or math.abs(sx-sy)>0.01 or w<200 or h<40 then return false end
        box.x,box.y,box.w,box.h,box.scale = x,y,w,h,sx
        return true
    end
    -- The operation or briefing frame; on the map, else the planet frame of a
    -- remote hover. The planet frame stays fixed while joinable cards move and
    -- fade between hovers. Card activity is a fallback for local previews.
    -- Remote hover activity comes from mission selection.
    local function frame(owner,screen,box)
        box.client,box.active = nil,nil
        if rectangle(owner,screen == 'map' and 349072 or 31232,box) then return true end
        if screen ~= 'map' or not rectangle(owner,280528,box) then return false end
        local preview = read(owner+526048,88,preview_bytes)
        local opacity = real(preview,84)
        box.client = true
        box.active = bit.band(uint(preview,0),0x10)~=0 and opacity>0.001 and opacity<=1.01
        return true
    end
    local self = {}
    -- Fills box (a new table when none is given) or returns nil.
    function self:sample(screen,box)
        if screen ~= 'map' and screen ~= 'briefing' then return nil end
        local manager = pointer(game+0x3326e68)
        local registry = screen == 'map' and 25224 or 25272
        local kind = screen == 'map' and 226 or 229
        -- These event registries have one inline subscriber. A zero count can
        -- leave a stale pointer behind, so never inspect it without the count.
        local entry = read(manager+registry,24)
        if uint(entry,0) ~= 1 or uint(entry,16) ~= kind then return nil end
        local owner = pointer_at(entry,8)
        if not owner then return nil end
        if screen == 'briefing' and uint(read(owner+8,4),0) ~= 0 then return nil end
        box = box or {}
        if not frame(owner,screen,box) then return nil end
        -- The active locale's body face and its normal material. The native
        -- font initializer at 0xf553c0 populates these same rendering tables.
        box.font = font_hash(game+0x3772268)
        box.material = material_hash(pointer(game+0x37c5478)+24)
        box.atlas = atlas_hash(game+0x3772ee8)
        box.screen = screen
        -- No guessed coordinates if the native panel is absent or mid-layout.
        return box
    end
    return self
end

return M
