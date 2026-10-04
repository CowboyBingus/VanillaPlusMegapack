local root=assert(arg[1]);local source=arg[2] or root..'/src'
for _,screen in ipairs({'armory','loadout'})do
 local path=arg[3] and arg[3]..'/'..(screen=='armory' and 'ship-armory-fixed-recorded.lua' or 'loadout-replay-input.lua')
  or root..'/tests/fixtures/ui_'..screen..'_25327279.lua'
 local api,game,exe,export,memory=dofile(root..'/tests/captured_ui.lua')(path)
 memory.record=arg[4]~=nil
 -- Preserve the historical UI allocation while replaying the exact native
 -- instruction guards and format constant captured from build 25480438.
 local ffi=require('ffi')
 local original_read=api.read
 local native_signatures=dofile(source..'/signatures.lua')
 local image_signatures=dofile(source..'/image_signatures.lua')
 local native_bytes={}
 for _,s in ipairs(native_signatures)do
  local base=s.module=='game' and game or exe
  native_bytes[tonumber(ffi.cast('uintptr_t',base+s.rva))]=s.hex:gsub('..',function(h)return string.char(tonumber(h,16))end)
 end
 for _,s in ipairs(image_signatures)do
  local base=s.module=='game' and game or exe
  native_bytes[tonumber(ffi.cast('uintptr_t',base+s.rva))]=s.hex:gsub('..',function(h)return string.char(tonumber(h,16))end)
 end
 native_bytes[tonumber(ffi.cast('uintptr_t',exe+0x1658990))]=ffi.string(ffi.new('uint32_t[1]',32),4)
 for address,bytes in pairs(native_bytes)do memory.poke(address,bytes)end
 local native=dofile(source..'/native.lua').new(api,game,exe,native_signatures)
 local s=native:snapshot();local expected=screen=='armory' and 54 or 48
 assert(s.menu and not s.blocked and s.top==(screen=='armory' and 5 or 14) and #s.items==expected)
 local images=dofile(source..'/image_native.lua').new(api,game,exe,image_signatures)
 local i=images:snapshot()
 assert(i.complete and i.expected_count==expected and #i.items==expected and #i.widgets==15)
 assert(i.controller_kind==(screen=='armory' and 224 or 229))
 if arg[4]then export(root..'/tests/fixtures/ui_'..screen..'_25327279.lua')end
end
print('PASS: historical Armory/loadout UI replay with current-build native instruction guards')
