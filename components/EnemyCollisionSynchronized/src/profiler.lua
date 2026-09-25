-- Bounded, observational telemetry. Never changes game state or GC policy.
local P = {}
local stages={'discovery','snapshot','validation','planning','motion','native','maintenance','logging'}
local sections={'metadata','skeleton','actors','bodies'}
local counters={'scan_entities','deep_inspections','budget_yields','realignments','claws_disabled','fling_stops','completion_requests','history_expirations','guard_passes_skipped'}
local lifecycles={ragdoll_settled=true,ragdoll_dynamic=true,ragdoll_stopped=true,
    corpse_aligned=true,corpse_repair=true,corpse_other=true,unclassified=true,rejected=true}
local buckets={.1,.25,.5,1,2,4,8,16,33,100,1000,math.huge}
local function stats()return {count=0,total=0,maximum=0,histogram={},over2=0,over8=0,over16=0,over33=0}end
local function record(row,ms)
    row.count=row.count+1;row.total=row.total+ms;row.maximum=math.max(row.maximum,ms)
    if ms>2 then row.over2=row.over2+1 end
    if ms>8 then row.over8=row.over8+1 end
    if ms>16 then row.over16=row.over16+1 end
    if ms>33 then row.over33=row.over33+1 end
    for i,upper in ipairs(buckets)do if ms<=upper then row.histogram[i]=(row.histogram[i] or 0)+1;break end end
end
local function percentile(row)
    if row.count==0 then return 0 end
    local seen=0
    for i,upper in ipairs(buckets)do seen=seen+(row.histogram[i] or 0);if seen>=row.count*.95 then return upper end end
end
local function probe(fn,...)
    if type(fn)~='function' then return nil end
    local ok,value=pcall(fn,...)
    if ok and type(value)=='number' and value==value and math.abs(value)<math.huge then return value end
end
local function sorted_keys(rows)local keys={};for key in pairs(rows)do keys[#keys+1]=key end;table.sort(keys);return keys end

function P.new(api,revision)
    local clock=api.clock or api.time
    local p={rows={},details={},units={},workloads={},worst={},revisits={},before={},
        stats=stats(),window=stats(),chain=stats(),chain_window=stats(),intervals=stats(),
        scopes={mission=stats(),outside_mission=stats()},polls=0,updates=0,reads=0,bytes=0,
        total=0,maximum=0,output_max=0,finish_max=0,finish_total=0,started=clock(),
        unit_count=0,workload_count=0,late_revisits=0,max_late_revisit=0,revisit_evictions=0,
        cycles_total=0,cycles_samples=0,revision=revision}
    p.window_at=p.started
    for _,name in ipairs(stages)do p.rows[name]={ms=0,reads=0,bytes=0,read_ms=0,sampled_reads=0,poll_ms=0,max_poll_ms=0,window_ms=0}end
    for _,name in ipairs(sections)do p.details[name]={sampled_ms=0,reads=0,bytes=0}end
    local function close_detail(now)
        if p.sample and p.current=='snapshot' and p.detail_current and p.detail_at then
            local row=p.details[p.detail_current];row.sampled_ms=row.sampled_ms+(now-p.detail_at)*1000
        end
        p.detail_at=nil
    end
    local function close_phase(now)
        close_detail(now)
        if p.current then
            local row=p.rows[p.current];local ms=(now-p.phase_at)*1000
            row.ms=row.ms+ms;row.poll_ms=row.poll_ms+ms;row.window_ms=row.window_ms+ms
        end
        p.phase_at=now
    end
    function p.detail(name)
        if not p.running or not p.sample or not p.details[name] then return end
        local now=clock();close_detail(now)
        p.detail_current=name
        if now and p.current=='snapshot' then p.detail_at=now end
    end
    function p.phase(name)
        local old=p.current
        if p.running and p.rows[name] then
            local now=clock();close_phase(now);p.current=name
            if p.sample and name=='snapshot' and p.detail_current then p.detail_at=now end
        end
        return old
    end
    function p.begin(state)
        p.running=true;p.current='maintenance';p.start=clock();p.phase_at=p.start
        p.read_start=p.reads;p.byte_start=p.bytes;p.sample=p.polls%30==0
        p.detail_current=nil;p.detail_at=nil
        p.cycle_start=probe(api.thread_cycles);p.heap_start=probe(collectgarbage,'count')
        for _,row in pairs(p.rows)do row.poll_ms=0 end
        for _,key in ipairs(counters)do p.before[key]=state and state[key] or 0 end
        p.poll_worst_unit=nil;p.poll_worst_unit_ms=0;p.poll_worst_unit_kind=nil
    end
    function p.update_started()
        local now=clock();p.updates=p.updates+1
        if p.last_update and now>=p.last_update then record(p.intervals,(now-p.last_update)*1000)end
        p.last_update=now;return now
    end
    function p.update_finished(start,ok)
        if not start then return end
        local elapsed=(clock()-start)*1000
        record(p.chain,elapsed);record(p.chain_window,elapsed)
        if not ok then p.update_errors=(p.update_errors or 0)+1 end
    end
    local function add_unit(rows,key,elapsed,reads)
        local row=rows[key]
        if not row then row={count=0,ms=0,max=0,reads=0};rows[key]=row end
        row.count=row.count+1;row.ms=row.ms+elapsed;row.max=math.max(row.max,elapsed);row.reads=row.reads+reads
    end
    function p.unit(name,start,reads,unit)
        if not p.running then return end
        local now=clock();local elapsed=(now-start)*1000
        if not p.units[name] then
            if p.unit_count>=64 then name='Other' else p.unit_count=p.unit_count+1 end
        end
        add_unit(p.units,name,elapsed,p.reads-reads)
        local kind=type(unit)=='table' and unit.profile_lifecycle or 'rejected'
        if not lifecycles[kind] then kind='unclassified' end
        local owner=type(unit)=='table' and (unit.owner==true and 'owned' or unit.owner==false and 'remote') or 'unknown'
        owner=owner or 'unknown'
        local key=name..' lifecycle='..kind..' ownership='..owner
        if not p.workloads[key] then
            if p.workload_count>=128 then key='Other lifecycle=unclassified ownership=unknown'
            else p.workload_count=p.workload_count+1 end
        end
        add_unit(p.workloads,key,elapsed,p.reads-reads)
        if elapsed>p.poll_worst_unit_ms then p.poll_worst_unit=name;p.poll_worst_unit_kind=kind;p.poll_worst_unit_ms=elapsed end
        -- Numeric identities live only in this fixed-size observation cache.
        -- It has no role in repair decisions and is never written to the log.
        if type(unit)=='table' and type(unit.unit)=='number' then
            local slot=unit.unit%256+1;local old=p.revisits[slot]
            if kind=='ragdoll_settled' and unit.owner==false and unit.active==true and unit.update_enabled==true then
                if old and old.unit==unit.unit and old.id==unit.id and old.resource==unit.resource then
                    local gap=now-old.at
                    if gap>1 then p.late_revisits=p.late_revisits+1;p.max_late_revisit=math.max(p.max_late_revisit,gap)end
                    old.at=now
                else
                    if old then p.revisit_evictions=p.revisit_evictions+1 end
                    p.revisits[slot]={unit=unit.unit,id=unit.id,resource=unit.resource,at=now}
                end
            elseif old and old.unit==unit.unit then p.revisits[slot]=nil end
        end
    end
    function p.finish(state)
        local now=clock();close_phase(now)
        local cycle_end=probe(api.thread_cycles);local heap_end=probe(collectgarbage,'count')
        p.running=false
        local elapsed=(now-p.start)*1000
        p.polls=p.polls+1;p.total=p.total+elapsed;p.maximum=math.max(p.maximum,elapsed)
        record(p.stats,elapsed);record(p.window,elapsed)
        local scope=state.mission_flag==1 and 'mission' or 'outside_mission'
        record(p.scopes[scope],elapsed)
        if scope=='outside_mission' then for slot in pairs(p.revisits)do p.revisits[slot]=nil end end
        local cycles=p.cycle_start and cycle_end and cycle_end>=p.cycle_start and cycle_end-p.cycle_start or nil
        if cycles then p.cycles_samples=p.cycles_samples+1;p.cycles_total=p.cycles_total+cycles end
        for _,row in pairs(p.rows)do row.max_poll_ms=math.max(row.max_poll_ms,row.poll_ms)end
        state.read_calls=p.reads-p.read_start;state.read_bytes=p.bytes-p.byte_start
        state.performance_last_ms=elapsed;state.performance_max_ms=p.maximum
        if #p.worst<8 or elapsed>p.worst[#p.worst].wall_ms then
            local event={poll=p.polls,at_s=now-p.started,wall_ms=elapsed,cycles=cycles,
                heap_delta_kb=p.heap_start and heap_end and heap_end-p.heap_start or nil,
                scope=scope,reads=state.read_calls,bytes=state.read_bytes,phases={},actions={},
                ragdolls=state.ragdoll_count or 0,corpses=state.corpse_count or 0,
                enemy=p.poll_worst_unit or 'none',lifecycle=p.poll_worst_unit_kind or 'none',enemy_ms=p.poll_worst_unit_ms}
            for _,name in ipairs(stages)do event.phases[name]=p.rows[name].poll_ms end
            for _,key in ipairs(counters)do event.actions[key]=(state[key] or 0)-p.before[key]end
            p.worst[#p.worst+1]=event;table.sort(p.worst,function(a,b)return a.wall_ms>b.wall_ms end)
            if #p.worst>8 then p.worst[9]=nil end
        end
        local overhead=(clock()-now)*1000;p.finish_total=p.finish_total+overhead;p.finish_max=math.max(p.finish_max,overhead)
    end
    local function stat_line(prefix,row)
        return string.format('%s_count=%d mean_ms=%.4f p95_upper_ms=%.4f max_ms=%.4f over2=%d over8=%d over16=%d over33=%d',
            prefix,row.count,row.total/math.max(1,row.count),percentile(row),row.maximum,row.over2,row.over8,row.over16,row.over33)
    end
    function p.text(state)
        local now=clock();local seconds=math.max(.001,now-p.started)
        local dominant,dominant_ms='none',0
        for _,name in ipairs(stages)do if p.rows[name].ms>dominant_ms then dominant,dominant_ms=name,p.rows[name].ms end end
        local flags={}
        if p.maximum>2 then flags[#flags+1]='slow_mod_poll' end
        if p.output_max>2 then flags[#flags+1]='slow_diagnostic_output' end
        if (state.budget_yields or 0)>0 then flags[#flags+1]='work_deferred' end
        if p.late_revisits>0 then flags[#flags+1]='late_ragdoll_revisit' end
        local lines={'Enemy Collision Synchronized performance '..revision..' schema=2',
            'scope=mod_callback; wall times include possible descheduling; phases exclusive; reads timed one poll in 30',
            'wrapped_update includes vanilla and earlier hooks only, excludes this mod and later hooks; not GPU FPS or network latency',
            'native=dispatch only; thread cycles are raw, not milliseconds; Lua heap deltas cover the shared VM and do not prove GC pauses',
            string.format('seconds=%.2f polls=%d update_calls=%d update_calls_per_second=%.2f',seconds,p.polls,p.updates,p.updates/seconds),
            string.format('mod_ms_mean=%.4f mod_ms_p95_upper=%.4f mod_ms_max=%.4f mod_ms_per_second=%.4f',p.total/math.max(1,p.polls),percentile(p.stats),p.maximum,p.total/seconds),
            string.format('profiler_output_ms_max=%.4f profiler_finish_ms_max=%.4f profiler_finish_ms_total=%.4f dominant_phase=%s flags=%s',p.output_max,p.finish_max,p.finish_total,dominant,table.concat(flags,',')),
            stat_line('poll',p.stats),stat_line('mission_poll',p.scopes.mission),stat_line('outside_mission_poll',p.scopes.outside_mission),
            string.format('window_polls=%d seconds=%.2f mod_ms_per_second=%.4f ',p.window.count,now-p.window_at,p.window.total/math.max(.001,now-p.window_at))..stat_line('window',p.window),
            stat_line('wrapped_update',p.chain),stat_line('window_wrapped_update',p.chain_window),stat_line('update_interval',p.intervals),
            'wrapped_update_errors='..tostring(p.update_errors or 0),
            string.format('thread_cycle_samples=%d thread_cycles_total=%.0f late_ragdoll_revisits=%d max_late_revisit_seconds=%.4f revisit_cache_slots=256 revisit_cache_evictions=%d',p.cycles_samples,p.cycles_total,p.late_revisits,p.max_late_revisit,p.revisit_evictions)}
        for _,name in ipairs(stages)do
            local row=p.rows[name]
            lines[#lines+1]=string.format('phase=%s ms=%.4f max_poll_ms=%.4f window_ms=%.4f reads=%d bytes=%d sampled_read_ms=%.4f sampled_reads=%d',name,row.ms,row.max_poll_ms,row.window_ms,row.reads,row.bytes,row.read_ms,row.sampled_reads)
        end
        for _,name in ipairs(sections)do
            local row=p.details[name]
            lines[#lines+1]=string.format('snapshot_section=%s sampled_ms=%.4f sampled_reads=%d sampled_bytes=%d',name,row.sampled_ms,row.reads,row.bytes)
        end
        for _,name in ipairs(sorted_keys(p.units))do
            local row=p.units[name];lines[#lines+1]=string.format('enemy=%s inspections=%d mean_ms=%.4f max_ms=%.4f reads=%d',name,row.count,row.ms/row.count,row.max,row.reads)
        end
        for _,key in ipairs(sorted_keys(p.workloads))do
            local row=p.workloads[key];lines[#lines+1]=string.format('workload=%s inspections=%d mean_ms=%.4f max_ms=%.4f reads=%d',key,row.count,row.ms/row.count,row.max,row.reads)
        end
        for i,event in ipairs(p.worst)do
            local parts={string.format('slow_poll_rank=%d poll=%d at_s=%.4f wall_ms=%.4f thread_cycles=%s heap_delta_kb=%s scope=%s reads=%d bytes=%d ragdolls=%d corpses=%d enemy=%s lifecycle=%s enemy_ms=%.4f',
                i,event.poll,event.at_s,event.wall_ms,tostring(event.cycles or 'unavailable'),tostring(event.heap_delta_kb or 'unavailable'),event.scope,event.reads,event.bytes,event.ragdolls,event.corpses,event.enemy,event.lifecycle,event.enemy_ms)}
            for _,name in ipairs(stages)do parts[#parts+1]=string.format('%s_ms=%.4f',name,event.phases[name])end
            for _,key in ipairs(counters)do parts[#parts+1]=key..'='..event.actions[key]end
            lines[#lines+1]=table.concat(parts,' ')
        end
        for _,key in ipairs(counters)do lines[#lines+1]=key..'='..tostring(state[key] or 0)end
        for _,key in ipairs({'world_metadata_decodes','pool_metadata_decodes'})do
            lines[#lines+1]=key..'='..tostring(state[key] or 0)
        end
        for _,key in ipairs({'ragdoll_count','corpse_count','skipped','retries'})do lines[#lines+1]=key..'='..tostring(state[key] or 0)end
        lines[#lines+1]='history_expiry_age_max_seconds='..tostring(state.max_revisit_seconds or 0)
        return table.concat(lines,'\n')..'\n'
    end
    function p.flush(state,force)
        local now=clock()
        if not force and now-(p.last_output or p.started)<10 then return end
        p.last_output=now
        local ok,written=pcall(function()
            local logger=rawget(_G,'CowboyBingusModLoader')
            local file=logger and logger.open_log and logger.open_log('EnemyCollisionSynchronized-Performance.log');if not file then return false end
            local success,result=pcall(function()return file:write(p.text(state))end)
            local closed=file:close();return success and result~=nil and closed~=nil
        end)
        p.output_max=math.max(p.output_max,(clock()-now)*1000)
        if ok and written then
            p.window=stats();p.chain_window=stats();p.window_at=clock()
            for _,row in pairs(p.rows)do row.window_ms=0 end
        end
    end
    -- Install the read wrapper last so failed setup leaves the original API intact.
    local read=api.read
    api.read=function(address,size)
        if not p.running then return read(address,size)end
        local row=p.rows[p.current]
        p.reads=p.reads+1;p.bytes=p.bytes+size;row.reads=row.reads+1;row.bytes=row.bytes+size
        if p.sample then
            local detail=p.current=='snapshot' and p.detail_current and p.details[p.detail_current]
            if detail then detail.reads=detail.reads+1;detail.bytes=detail.bytes+size end
            local start=clock();local bytes=read(address,size)
            row.read_ms=row.read_ms+(clock()-start)*1000;row.sampled_reads=row.sampled_reads+1;return bytes
        end
        return read(address,size)
    end
    local view=api.view
    -- Wrap the view only while it is paired with the read wrapped above, and
    -- keep the wrapped pair paired.
    if view and api.view_read==read then
        api.view_read=api.read
        api.view=function(address,size)
            if not p.running then return view(address,size) end
            local row=p.rows[p.current]
            p.reads=p.reads+1;p.bytes=p.bytes+size;row.reads=row.reads+1;row.bytes=row.bytes+size
            if p.sample then
                local start=clock();local result=view(address,size)
                row.read_ms=row.read_ms+(clock()-start)*1000;row.sampled_reads=row.sampled_reads+1;return result
            end
            return view(address,size)
        end
    end
    return p
end
return P
