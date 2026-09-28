-- Per-frame call budget for mod tests (canonical copy; each mod repo carries an
-- identical tests/frame_budget.lua). Wrap the api table a mod receives, run one
-- frame, and assert exactly which api calls it made and how many.
--
-- Why counts and not timings: inside Helldivers 2 one VirtualQuery
-- (api.writable_data) costs about 0.29 ms and one ReadProcessMemory (api.read)
-- about 1-2 us, while both take microseconds in a test process. Offline timing
-- hides per-frame system calls; counting them does not.
--
--   local budget=dofile(tests..'/frame_budget.lua')
--   local counts=budget.wrap(api)          -- before the mod first uses api
--   budget.check(budget.frame(counts,step),{read=6},'idle frame')
local M={}

-- Wraps every function field of api in place and returns a live counts table.
-- Fields that share one function (for example view_read = read) keep sharing
-- one wrapper, so identity checks between them still hold; the calls are
-- counted under the alphabetically first name.
function M.wrap(api)
    local counts,wrappers,names={}, {}, {}
    for name,value in pairs(api) do
        if type(value)=='function' then names[#names+1]=name end
    end
    table.sort(names)
    for _,name in ipairs(names) do
        local original=api[name]
        if not wrappers[original] then
            wrappers[original]=function(...)
                counts[name]=(counts[name] or 0)+1
                return original(...)
            end
        end
        api[name]=wrappers[original]
    end
    return counts
end

-- Clears the counts, runs fn(...) as one frame and returns a copy of the
-- frame's counts followed by fn's results.
function M.frame(counts,fn,...)
    for name in pairs(counts) do counts[name]=nil end
    local results={fn(...)}
    local copy={}
    for name,n in pairs(counts) do copy[name]=n end
    return copy,unpack(results)
end

-- Fails when the frame made a call that is not in limits, or more calls than
-- the limit. Adding a new kind of call means adding it here on purpose, which
-- makes every new per-frame cost visible in review.
function M.check(frame,limits,label)
    local names={}
    for name in pairs(frame) do names[#names+1]=name end
    table.sort(names)
    for _,name in ipairs(names) do
        local limit,n=limits[name],frame[name]
        assert(limit,label..': api.'..name..' called '..n..' times but is not in the budget')
        assert(n<=limit,label..': api.'..name..' called '..n..' times, budget '..limit)
    end
end

-- Readable summary for failure messages and test output.
function M.describe(frame)
    local parts={}
    for name,n in pairs(frame) do parts[#parts+1]=name..'='..n end
    table.sort(parts)
    return #parts>0 and table.concat(parts,' ') or 'no api calls'
end

return M
