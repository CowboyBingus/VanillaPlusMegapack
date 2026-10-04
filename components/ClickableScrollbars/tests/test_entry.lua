-- The source files and the entry built from them (scripts/entry.py). The main
-- file runs every other src/*.lua file once, in its own order; each file takes
-- from cs only names a file before it set, and sets each name once. Here every
-- file runs from src/ against a cs that refuses a read of a name not set yet and
-- a second set of a name, so a file renamed, reordered or wired to a misspelled
-- name fails offline instead of reading nil in game. The entry must give the
-- same module as the files it was built from.
-- arg[1]: the repository root; arg[2]: the built entry.
local root, entry_path = assert(arg[1]), assert(arg[2])
local MAIN = root .. '/src/clickable_scrollbars.lua'

local passed = 0
local function check(name, condition, detail)
    if not condition then error(name .. (detail and (' (' .. tostring(detail) .. ')') or ''), 0) end
    passed = passed + 1
end

local function read(path)
    local file = assert(io.open(path, 'rb'))
    local text = file:read('*a')
    file:close()
    return text
end

-- cs as one file sees it: reads and sets go to the shared table, checked.
local setters, readers = {}, {}
local function guarded(file, cs)
    for name in pairs(cs) do setters[name] = setters[name] or 'clickable_scrollbars.lua' end
    return setmetatable({}, {
        __index = function(_, name)
            local value = cs[name]
            if value == nil then error(file .. ' reads cs.' .. tostring(name) .. ' before a file sets it', 2) end
            readers[name] = readers[name] or file
            return value
        end,
        __newindex = function(_, name, value)
            if cs[name] ~= nil then
                error(file .. ' sets cs.' .. tostring(name) .. ' again (' .. setters[name] .. ' set it)', 2)
            end
            cs[name], setters[name] = value, file
        end,
    })
end

rawset(_G, '__CLICKABLE_SCROLLBARS_TEST', true)
local ran, order = {}, {}
rawset(_G, 'cs_files', setmetatable({}, {__index = function(_, name)
    local file = name .. '.lua'
    local chunk = assert(loadfile(root .. '/src/' .. file))
    return function(module, cs)
        check(file .. ' runs once', not ran[name])
        ran[name], order[#order + 1] = true, name
        return chunk(module, guarded(file, cs))
    end
end}))
local from_sources = assert(loadfile(MAIN))()
rawset(_G, 'cs_files', nil)

-- The entry embeds exactly the files the main file runs, in that order.
local embedded = {}
for name in read(entry_path):gmatch('\ncs_files%.([%w_]+) = function%(%.%.%.%)\n') do embedded[#embedded + 1] = name end
check('the main file runs source files', #order >= 2, #order)
check('the entry embeds the files the main file runs, in its order',
    table.concat(embedded, ',') == table.concat(order, ','), table.concat(embedded, ',') .. ' / '
    .. table.concat(order, ','))

-- Every name a file hands on is used by a later file.
for name, file in pairs(setters) do
    check('cs.' .. name .. ' (set by ' .. file .. ') is read by a file', readers[name] ~= nil)
end

-- The entry and the files it was built from give the same module.
local from_entry = assert(loadfile(entry_path))()
local function shape(module)
    local names = {}
    for name, value in pairs(module) do names[#names + 1] = name .. ':' .. type(value) end
    table.sort(names)
    return table.concat(names, ' ')
end
check('the entry gives the module its source files give', shape(from_entry) == shape(from_sources),
    shape(from_entry) .. '\n' .. shape(from_sources))
check('the module carries its revision', from_entry.revision == from_sources.revision
    and type(from_entry.revision) == 'string')

print('entry: ' .. passed .. ' checks passed (' .. #order .. ' source files: ' .. table.concat(order, ', ') .. ')')
