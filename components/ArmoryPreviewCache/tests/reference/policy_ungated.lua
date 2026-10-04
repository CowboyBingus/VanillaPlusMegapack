-- Bounded resource leases, foreground lookahead and learned startup prewarming.
local M={}
function M.new_memory_guard()
    local g={trips=0,active=false}
    function g:tick(now,free,commit)
        local reason=free<2*1024^3 and 'low_physical_memory' or
                     commit<2*1024^3 and 'low_commit_headroom' or nil
        if reason then
            if not self.active then
                self.trips=self.trips+1;self.last_reason=reason
                self.trigger_free_mib=math.floor(free/1048576)
                self.trigger_commit_mib=math.floor(commit/1048576)
            end
            self.active=true;self.last_low=now;self.healthy_since=nil
            return reason
        end
        if not self.active then return nil end
        if free>=4*1024^3 and commit>=4*1024^3 then
            self.healthy_since=self.healthy_since or now
            if now-self.last_low>=30 and now-self.healthy_since>=5 then
                self.active=false;self.healthy_since=nil;return nil
            end
        else self.healthy_since=nil end
        return 'memory_recovery_cooldown'
    end
    return g
end
function M.new(adapter,options)
    options=options or {}
    local self={adapter=adapter,limit=options.limit or 128,leases={},learned={},learn_order={},
                owner=nil,world=nil,acquires=0,releases=0,hits=0,unresolved=0,retired=0,prewarms=0,
                dependency_acquires=0,startup_acquires=0,foreground_pending=0,
                prewarm=options.prewarm~=false,pressure=false}
    local function key(item)return item.kind..':'..item.id end
    function self:remember(item)
        local k=key(item)
        if not self.learned[k] then
            self.learned[k]={kind=item.kind,id=item.id};self.learn_order[#self.learn_order+1]=k
            if #self.learn_order>192 then self.learned[table.remove(self.learn_order,1)]=nil end
        elseif self.learn_order[#self.learn_order]~=k then
            -- Background/startup traverse this list newest first. A revisit
            -- must refresh priority even when the item was learned long ago.
            for i,known in ipairs(self.learn_order)do
                if known==k then table.remove(self.learn_order,i);break end
            end
            self.learn_order[#self.learn_order+1]=k
        end
        if item.attachments then
            local copy={};for i=1,math.min(10,#item.attachments)do copy[i]=item.attachments[i]end
            self.learned[k].attachments=copy
        end
        return self.learned[k]
    end
    function self:profile()
        local out={};for _,k in ipairs(self.learn_order)do out[#out+1]=self.learned[k]end;return out
    end
    function self:evict(id)
        local lease=self.leases[id];if not lease then return end
        self.adapter:release(id,lease.owner);self.leases[id]=nil;self.releases=self.releases+1
    end
    function self:clear()
        if next(self.leases) and not self.adapter:valid_leases(self.leases,self.owner)then
            self:retire();self.quarantined=true;return
        end
        for id in pairs(self.leases)do self:evict(id)end
    end
    function self:retire()
        -- Native manager replacement owns teardown; never release against its successor.
        for _ in pairs(self.leases)do self.retired=self.retired+1 end
        self.leases={}
    end
    function self:tick(s,now,pressure)
        if self.owner and self.owner~=s.owner then self:retire()end
        self.owner=s.owner
        if next(self.leases) and not self.adapter:valid_leases(self.leases,self.owner)then
            self:retire();self.quarantined=true
        end
        if self.quarantined then self.status='lease_ownership_lost_restart_required';return end
        self.started=self.started or now
        local startup=self.prewarm and not s.menu and not self.seen_menu and now-self.started<60 and s.prefetch
        if self.world and self.world~=s.world and not (not self.seen_menu and s.menu)then self:clear();self.pressure=false end
        self.world=s.world
        if s.menu then self.seen_menu=true end
        if not s.menu and not startup then self:clear();self.pressure=false;self.status='outside_ship_ui';return end
        if pressure then self:clear();self.pressure=true;self.status='memory_pressure';return end
        self.pressure=false
        local wanted,protected={},{}
        local function add(item,background)
            local ids
            if self.adapter.resolve_all then ids=self.adapter:resolve_all(item)
            else local id=self.adapter:resolve(item);ids=id and {id} or {}end
            if #ids==0 then self.unresolved=self.unresolved+1 end
            for index,id in ipairs(ids)do
                if not protected[id]then
                    protected[id]=true;wanted[#wanted+1]={id=id,prewarm=background,dependency=index>1}
                end
            end
        end
        -- Touch the current group in reverse so newest-first prewarming keeps
        -- the same order as foreground requests. Repeated identical snapshots
        -- finish with identical profile bytes, avoiding needless disk writes.
        for i=#s.items,1,-1 do self:remember(s.items[i])end
        for _,item in ipairs(s.items)do
            if not item.finished then add(self.learned[key(item)],false)end
        end
        for _,item in ipairs(s.items)do if item.finished then add(self.learned[key(item)],false)end end
        -- Background learning is useful before opening a menu, but foreground
        -- generation owns priority and never waits for the persistent profile.
        if self.prewarm and not s.active and not s.blocked then
            for i=#self.learn_order,1,-1 do
                add(self.learned[self.learn_order[i]],true)
                if #wanted>=self.limit then break end
            end
        end
        -- Protect only requests that fit. Oversized profiles must not make
        -- every held package unevictable, starving the foreground forever.
        protected={}
        for i=1,math.min(self.limit,#wanted)do protected[wanted[i].id]=true end
        local added=0
        self.foreground_pending=0
        for _,request in ipairs(wanted)do
            local id=request.id
            if self.leases[id]then self.leases[id].used=now;self.hits=self.hits+1
            elseif added<4 and protected[id]then
                local n,victim,oldest=0,nil,math.huge
                for held,l in pairs(self.leases)do
                    n=n+1
                    if not protected[held] and l.used<oldest then victim,oldest=held,l.used end
                end
                if n>=self.limit and victim then self:evict(victim);n=n-1 end
                if n<self.limit and self.adapter:acquire(id,self.owner)then
                    self.leases[id]={owner=self.owner,used=now};added=added+1;self.acquires=self.acquires+1
                    if request.prewarm then self.prewarms=self.prewarms+1 end
                    if request.dependency then self.dependency_acquires=self.dependency_acquires+1 end
                    if startup then self.startup_acquires=self.startup_acquires+1 end
                end
            end
            if not request.prewarm and not self.leases[id]then self.foreground_pending=self.foreground_pending+1 end
        end
        -- A fixed count bound is enforced even for profiles larger than the cache.
        self.status=startup and 'startup_dependency_prewarm' or
            (s.blocked and 'thumbnail_ui_busy' or (s.active and 'foreground_lookahead' or 'resident'))
    end
    return self
end
return M
