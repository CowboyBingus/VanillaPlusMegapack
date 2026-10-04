-- READ-ONLY live check: runs Flame Damage Fixed's own lookups and checks against the running game from a
-- separate process (PROCESS_QUERY_INFORMATION | PROCESS_VM_READ). Nothing is written: the write guards
-- are refused, so every fix stops right before its first write.
-- Usage: live_check.lua <project root> <pid> <game.dll base> <exe base>
local root, pid, game, exe = assert(arg[1]), tonumber(arg[2]), tonumber(arg[3]), tonumber(arg[4])
local ffi = require('ffi')
_G.FLAME_DAMAGE_FIXED_TEST = true
local Fix = dofile(root .. '/src/flame_damage_fixed.lua')
_G.FLAME_DAMAGE_FIXED_TEST = nil
pcall(ffi.cdef, 'void *OpenProcess(uint32_t access, int inherit, uint32_t pid);')
pcall(ffi.cdef, 'int CloseHandle(void *handle);')
pcall(ffi.cdef, 'int ReadProcessMemory(void *process, const void *address, void *buffer, size_t size, size_t *read);')
local kernel = ffi.load('kernel32')
local process = kernel.OpenProcess(0x410, 0, pid)
assert(process ~= nil, 'OpenProcess (read-only) failed')
local rpm = ffi.cast('int (*)(void *, uintptr_t, void *, size_t, size_t *)', kernel.ReadProcessMemory)
local BLOCK = 65536
local word, count, bulk = ffi.new('uint32_t[1]'), ffi.new('size_t[1]'), ffi.new('uint8_t[4096]')
local block = ffi.new('uint8_t[?]', BLOCK)
local block_words = ffi.cast('uint32_t *', block)
local writes = 0
local api = {
    u32 = function(a) if rpm(process, a, word, 4, count) == 0 or count[0] ~= 4 then return nil end return tonumber(word[0]) end,
    read = function(a, n) if n > 4096 or rpm(process, a, bulk, n, count) == 0 or count[0] ~= n then return nil end return ffi.string(bulk, n) end,
    load = function(a, n)
        if n < 4 or n > BLOCK or rpm(process, a, block, n, count) == 0 or count[0] ~= n then return nil end
        return block_words
    end,
    writable_data = function() return false end, -- guard queries refused: nothing can be written
    writable_region = function() return nil end,
    write_raw = function() writes = writes + 1 return false end,
    write_u32 = function() writes = writes + 1 return false end,
}
local data, why = Fix.resolve_effect(api, exe)
print(string.format('resolve_effect: %s %s', data and string.format('0x%x', data) or 'nil', why or ''))
if data then
    local ok, detail = Fix.check_effect(api, data)
    print('check_effect:', ok and (detail .. ' of ' .. #Fix.PATCHES .. ' words still shipped') or detail)
end
local filter, reason = Fix.check_filter(api, exe)
print('check_filter:', filter and string.format('0x%x (flame row as shipped)', filter) or reason)
local free = {}
for g = Fix.PHYS.GROUP_TOP, Fix.PHYS.GROUP_LOW, -1 do
    if Fix.group_free(api, exe, g) then free[#free + 1] = g end
end
print('private groups free in the allocator:', #free > 0 and table.concat(free, ' ') or 'none')
local slot = Fix.flame_slot(api, game)
print('flame slot:', slot and string.format('0x%x (%d instances)', slot, api.u32(slot) or -1) or 'none (no flame instance)')
-- The driver finds each tracked weapon's family and scans its bodies over the following frames; with the
-- write guards refused, a burst in progress logs its refusal and changes nothing.
local fix = Fix.new(api, game, exe, print)
fix.scan()
for _ = 1, 400 do fix.step(1 / 60) end
for i, address in ipairs(fix.tracked) do
    local weapon = fix.weapons[address]
    local job = weapon and weapon.job
    print(string.format('tracked weapon %d: 0x%x state=%s %s; family %d units; own flame-hittable bodies %s%s',
        i, address, tostring(api.u32(address)), weapon and weapon.name or '?', weapon and #weapon.family or 0,
        weapon and weapon.job_ok and tostring(job.n) or 'not scanned', weapon and weapon.group
        and (' (group ' .. weapon.group .. ')') or ''))
end
if #fix.tracked == 0 then print('tracked weapons: none (no Lumberer or Flame Sentry in the scene)') end
assert(writes == 0, 'live check must never write')
kernel.CloseHandle(process)
