-- Screens the captures do not show, built on a captured Armory or briefing
-- controller: the weapon/cosmetic pre-select and the briefing loadout. poke
-- writes replay memory; m32 is the writable manager's 32-bit view.
local ffi=require('ffi')
local M={}
local function u32s(v)return ffi.string(ffi.new('uint32_t[1]',v),4)end
-- An initialized image widget showing the record at the given address.
function M.widget_bytes(record)
    local b=ffi.new('uint8_t[2008]')
    local f,u=ffi.cast('float *',b),ffi.cast('uint32_t *',b)
    f[3],f[4],f[7],f[8],f[85]=172,172,1,1,1
    u[68]=0xc0000                                   -- image element
    ffi.cast('uint64_t *',b+600)[0]=0x500000000000  -- private material
    ffi.cast('uint64_t *',b+1984)[0]=record         -- displayed record
    u[500]=1;b[2005]=1                              -- fit, bound
    return ffi.string(b,2008)
end
function M.record_bytes(visual,card,slot)
    local b=ffi.new('uint8_t[80]')
    local u=ffi.cast('uint32_t *',b)
    ffi.copy(b,visual,8);u[2]=3;u[15]=card;u[16]=slot;u[18]=1
    return ffi.string(b,80)
end
-- The Armory pre-select (mode 0 weapon, 1 cosmetic): three slots of card 0.
function M.preselect(poke,owner,mode)
    local control=owner+280216
    local records=''
    for i=0,2 do records=records..M.record_bytes('preview'..i,0,i)end
    poke(control+37728,records)
    poke(control+37968,u32s(0)..string.char(0,0,0,0)..u32s(0)..u32s(mode))
    for i=0,2 do poke(control+5256+i*12304,M.widget_bytes(control+37728+i*80))end
end
function M.preselect_closed(poke,owner)
    poke(owner+280216+37968,u32s(0)..string.char(1,0,0,0)..u32s(0)..u32s(0))
end
-- The briefing loadout: six slots of card 0 whose items get the loadout's kinds.
function M.loadout(poke,owner,m32)
    local kinds={2,3,4,0,0,1}
    local records=''
    for i=0,5 do
        m32[(32+i*120+100)/4]=kinds[i+1]
        records=records..M.record_bytes('loadout'..i,0,i)
    end
    poke(owner+454728,records)
    for i=0,5 do poke(owner+422768+i*5464,M.widget_bytes(owner+454728+i*80))end
end
return M
