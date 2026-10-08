-- Match Your Colors: the mods' patch files (src/patches.lua) on synthetic patches written into build/test-patches/:
-- the game's priority (the boot archive's patches first, the highest number first, then the searched archive's,
-- then the archive), the indexed types, parts read from the patch's files, an unreadable patch skipped, and the
-- signature the analysis cache keys on (it changes with a resource's bytes, not with a Lua addon's patch).
-- Usage: luajit tests/test_patches.lua <repository root>
local root = assert(arg and arg[1], 'usage: test_patches.lua <repository root>')
package.path = root .. '/src/?.lua;' .. package.path
local ffi = require('ffi')
local Files, Slim, Patches = require('files'), require('slim'), require('patches')
local passed = 0
local function check(name, fn)
    fn()
    passed = passed + 1
end

local TEXTURE, MATERIAL, UNIT = 'cd4238c6a0c69e32', 'eac0b497876adedf', 'e0a48d0be9a7453f'
local LUA = 'a14e8dfa2cd117e2'
local BOOT, KIT, OTHER = '9ba626afa44a3aa3', '1111111111111111', '2222222222222222'
local X, Y, Z = '31c26f8e129cb8b1', '5c481fc00966b6f9', '0123456789abcdef'
local FOLDER = root .. '/build/test-patches/'

local function folder_ready()
    local probe = io.open(FOLDER .. 'probe', 'wb')
    if not probe then
        os.execute('mkdir "' .. FOLDER:gsub('/', '\\') .. '"') -- lint-ok: R5 test process only
        probe = assert(io.open(FOLDER .. 'probe', 'wb'), 'cannot write ' .. FOLDER)
    end
    probe:close()
    os.remove(FOLDER .. 'probe')
end

-- Little-endian bytes of a 32-bit number and of a 16-hex-digit name.
local function le32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256,
                                          math.floor(v / 16777216) % 256) end
local function le64(hex) return le32(tonumber(hex:sub(9, 16), 16)) .. le32(tonumber(hex:sub(1, 8), 16)) end
local function at64(v) return le32(v % 4294967296) .. le32(math.floor(v / 4294967296)) end

-- A patch file `file` (with .stream and .gpu_resources beside it) holding entries {{name, type, main, gpu}}; a
-- `magic` other than the archive's makes it unreadable.
local function write_patch(file, entries, magic)
    local types = 1
    local base = 72 + 32 * types
    local main_at = base + 80 * #entries
    local toc, mains, gpus = {}, {}, {}
    local gpu_at = 0
    for _, e in ipairs(entries) do
        toc[#toc + 1] = le64(e[1]) .. le64(e[2]) .. at64(main_at) .. at64(0) .. at64(gpu_at) .. string.rep('\0', 16)
            .. le32(#e[3]) .. le32(0) .. le32(#e[4]) .. string.rep('\0', 12)
        mains[#mains + 1], gpus[#gpus + 1] = e[3], e[4]
        main_at, gpu_at = main_at + #e[3], gpu_at + #e[4]
    end
    local head = le32(magic or 0xF0000011) .. le32(types) .. le32(#entries) .. string.rep('\0', 60)
    local out = assert(io.open(FOLDER .. file, 'wb'))
    out:write(head, string.rep('\0', 32 * types), table.concat(toc), table.concat(mains))
    out:close()
    out = assert(io.open(FOLDER .. file .. '.gpu_resources', 'wb'))
    out:write(table.concat(gpus))
    out:close()
    out = assert(io.open(FOLDER .. file .. '.stream', 'wb'))
    out:close()
end

local function clear()
    folder_ready()
    for _, name in ipairs(Files.new(FOLDER).list('*')) do os.remove(FOLDER .. name) end
end

-- The archived resources under the patches: {[archive .. name .. type] = {main, gpu}} as a slim reader.
local function base_reader(resources)
    local self = {closed = 0}
    function self.locate(archive, name, kind)
        local r = resources[archive .. name .. kind]
        return r and {0, #r[1], 0, 0, 0, #r[2], base = r} or nil
    end
    function self.part_size(record, part) return record[({main = 2, stream = 4, gpu = 6})[part]] end
    function self.part(_, record, part, at, size, out, out_offset)
        local bytes = part == 'main' and record.base[1] or record.base[2]
        ffi.copy(out + (out_offset or 0), bytes:sub(at + 1, at + size), size)
    end
    function self.close() self.closed = self.closed + 1 end
    return self
end

local function index()
    return Patches.index(Files.new(FOLDER), {TEXTURE, MATERIAL, UNIT}, Slim.grower(64), function() end)
end
local function read_part(reader, archive, record, part)
    local size = reader.part_size(record, part)
    local out = ffi.new('uint8_t[?]', size)
    reader.part(archive, record, part, 0, size, out, 0)
    return ffi.string(out, size)
end

check('order: the boot archive first, the highest number first; other files are no patches', function()
    local order = Patches.order({'9ba626afa44a3aa3.patch_1', '9ba626afa44a3aa3.patch_10', '9ba626afa44a3aa3.patch_2',
                                 '1111111111111111.patch_0', '9ba626afa44a3aa3.patch_0.stream',
                                 '9ba626afa44a3aa3.patch_0.gpu_resources', '0000000000000001.patch_3', 'bundles.nxa',
                                 '9ba626afa44a3aa3.patch_x', 'readme.patch_0'})
    local names = {}
    for i, p in ipairs(order) do names[i] = p.file end
    assert(table.concat(names, ' ') == '9ba626afa44a3aa3.patch_10 9ba626afa44a3aa3.patch_2 9ba626afa44a3aa3.patch_1 '
           .. '0000000000000001.patch_3 1111111111111111.patch_0', table.concat(names, ' '))
    assert(order[1].archive == BOOT and order[1].number == 10, 'archive and number')
end)

check('the boot patches win over every archive, the higher patch first; an archive\'s own patches over it', function()
    clear()
    write_patch(BOOT .. '.patch_0', {{X, TEXTURE, 'old main', 'old pixels'}, {Z, LUA, 'print(1)', ''}})
    write_patch(BOOT .. '.patch_1', {{X, TEXTURE, 'new main', 'new pixels'}})
    write_patch(KIT .. '.patch_0', {{Y, TEXTURE, 'kit main', 'kit pixels'}})
    write_patch(BOOT .. '.patch_2', {{Y, TEXTURE, 'bad', 'bad'}}, 0x12345678) -- unreadable: left out
    local idx = index()
    assert(#idx.patches == 3 and idx.entries == 3 and idx.skipped == 1, string.format('%d patches, %d entries, %d '
           .. 'skipped', #idx.patches, idx.entries, idx.skipped))
    local base = base_reader({[KIT .. X .. TEXTURE] = {'vanilla main', 'vanilla pixels'},
                              [OTHER .. Y .. TEXTURE] = {'other main', 'other pixels'},
                              [KIT .. Z .. LUA] = {'archived lua', ''}})
    local reader = Patches.over(base, idx, Files.new(FOLDER))
    local record = assert(reader.locate(KIT, X, TEXTURE))
    assert(record.file == BOOT .. '.patch_1', 'the higher boot patch: ' .. tostring(record.file))
    assert(read_part(reader, KIT, record, 'main') == 'new main' and read_part(reader, KIT, record, 'gpu')
           == 'new pixels', 'its parts from its files')
    assert(reader.locate(OTHER, X, TEXTURE).file == BOOT .. '.patch_1', 'a boot patch counts for every archive')
    assert(reader.locate(KIT, Y, TEXTURE).file == KIT .. '.patch_0', 'the searched archive\'s own patch')
    local other = assert(reader.locate(OTHER, Y, TEXTURE))
    assert(not other.file and read_part(reader, OTHER, other, 'gpu') == 'other pixels', 'another archive: archived')
    assert(not reader.locate(KIT, Z, LUA).file, 'types the mod does not read are not indexed')
    assert(reader.locate(KIT, Y, MATERIAL) == nil, 'name and type both match')
    reader.close()
    assert(base.closed == 1, 'closing closes the archive reader too')
end)

check('the signature changes with a resource\'s bytes, not with a Lua addon\'s patch or the order of listing', function()
    clear()
    write_patch(BOOT .. '.patch_0', {{X, TEXTURE, 'main', 'black visor'}})
    local first = index().signature
    assert(index().signature == first, 'stable')
    write_patch(BOOT .. '.patch_0', {{X, TEXTURE, 'main', 'blue visor!'}}) -- same sizes, other pixels
    local second = index().signature
    assert(second ~= first, 'another variant of the same LUT mod')
    write_patch(BOOT .. '.patch_1', {{Z, LUA, 'print(1)', ''}})
    assert(index().signature == second, 'a Lua addon\'s patch changes nothing')
    clear()
    assert(index().signature == '0:0:0:00000001', 'no patch: ' .. index().signature)
end)

clear()
print('PASS test_patches (' .. passed .. ' checks)')
