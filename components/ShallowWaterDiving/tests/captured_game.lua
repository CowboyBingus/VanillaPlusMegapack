-- Replays bytes captured from Steam 25327279. Never calls game functions.
local ffi=require('ffi')
return function(filename)
 local fixture=dofile(filename);local blocks,used={},{}
 for _,b in ipairs(fixture.blocks)do
  blocks[#blocks+1]={address=b.address,bytes=b.hex:gsub('..',function(h)return string.char(tonumber(h,16))end)}
 end
 local function address(p)return tonumber(ffi.cast('uintptr_t',p))end
 local game,exe=ffi.cast('uint8_t *',fixture.game),ffi.cast('uint8_t *',fixture.exe)
 local api={module=function(n)return n=='game.dll' and game or exe end,address=address,
  distance=function(a,b)return address(a)-address(b)end}
 function api.read(p,n)
  local a=address(p)
  for _,b in ipairs(blocks)do if a>=b.address and a+n<=b.address+#b.bytes then
   local bytes=b.bytes:sub(a-b.address+1,a-b.address+n)
   used[string.format('%.0f',a)..':'..n]={address=a,bytes=bytes};return bytes
  end end
  error(string.format('Uncaptured current-build game read %x:%d',a,n))
 end
 function api.pointer(b,o)
  o=o or 0;if not b or o+8>#b then return nil end
  local p=ffi.new('uint64_t[1]');ffi.copy(p,b:sub(o+1,o+8),8)
  if p[0]<0x10000 or p[0]>=0x800000000000ULL then return nil end
  return ffi.cast('uint8_t *',p[0])
 end
 api.write=function()error('Capture replay cannot write')end
 local function export(path)
  local rows={};for _,b in pairs(used)do rows[#rows+1]=b end
  table.sort(rows,function(a,b)return a.address<b.address end)
  local out=assert(io.open(path,'wb'))
  out:write('-- Actual game read ranges from Steam 25327279; no game writes or native calls.\nreturn {game=',string.format('%.0f',fixture.game),',exe=',string.format('%.0f',fixture.exe),',blocks={\n')
  for _,b in ipairs(rows)do
   out:write('{address=',string.format('%.0f',b.address),",hex='",(b.bytes:gsub('.',function(c)return string.format('%02x',c:byte())end)),"'},\n")
  end
  out:write('}}\n');out:close()
 end
 return api,game,exe,export
end
