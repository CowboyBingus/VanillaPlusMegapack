-- Retain complete atlases immediately, before native layout changes destroy them.
-- Native requests continue normally; cached images replace presentation only.
local M={}
function M.new(adapter,options)
    local self={adapter=adapter,entries={},textures={},bytes=0,hits=0,misses=0,
        retained=0,released=0,late_switches=0,early_hits=0,pending_drops=0,
        ready_items=0,missing_ready_items=0,pending_items=0,partial_retained=0,
        idle_retained=0,visible_retained=0,evicted=0,ticks=0,
        grid_hits=0,preselect_hits=0,briefing_hits=0,clear_count=0,
        rendered_items=0,refreshed=0,changed_items=0,reappeared=0,
        status='learning_images',enabled=options.images~=false}
    local pending,context,last_capture,view
    -- A retained crop describes one native render. Cards stop being complete
    -- when the native pipeline re-queues them (screen rebuild, scroll, or an
    -- appearance change such as a weapon pattern), and whatever they render
    -- next supersedes the crop captured before it. Keys stay marked until a
    -- capture adopts their new pixels.
    local rendered={}
    local function count_surface(screen,hits)
        if screen=='grid' then
            self.grid_hits=self.grid_hits+hits
        elseif screen=='weapon_preselect' or screen=='cosmetic_preselect' then
            self.preselect_hits=self.preselect_hits+hits
        elseif screen=='briefing_grid' or screen=='briefing_loadout' then
            self.briefing_hits=self.briefing_hits+hits
        end
    end
    local function reset_request()
        pending=nil;last_capture=nil;self.pending_items=0
        self.ready_items=0;self.missing_ready_items=0;self.blank_ready_items=0
        self.rendered_items=0;self.changed_items=0
        self.last_hits=0;self.last_misses=0;self.last_early_hits=0
    end
    function self:before()
        adapter:prune()
    end
    function self:clear(reason)
        if #self.textures>0 then self.clear_count=self.clear_count+1;self.last_clear_reason=reason or 'cleanup'end
        adapter:restore(true)
        self.entries={};rendered={};reset_request()
        -- Remove each reference only after its release succeeds, for retryable cleanup.
        while #self.textures>0 do
            local t=self.textures[#self.textures]
            adapter:destroy(t)
            self.bytes=self.bytes-t.bytes;self.released=self.released+1
            table.remove(self.textures)
        end
        self.status='learning_images'
    end
    local function release_superseded()
        local used,unused={},false
        for _,entry in pairs(self.entries)do used[entry.texture]=true end
        for _,t in ipairs(self.textures)do if not used[t]then unused=true;break end end
        if not unused then return false end
        -- A more complete atlas can replace earlier partial copies. Unbind
        -- cached UI references before releasing any now-unreferenced texture.
        adapter:restore()
        for i=#self.textures,1,-1 do
            local t=self.textures[i]
            if not used[t]then
                adapter:destroy(t);self.bytes=self.bytes-t.bytes
                self.released=self.released+1;table.remove(self.textures,i)
            end
        end
        return true
    end
    local function retain(s,candidate,idle)
        if candidate.bytes>128*1024*1024 then self.status='image_budget_full';return s,false end
        local protected={}
        for _,item in ipairs(s.items)do
            local entry=self.entries[item.key]
            if entry then protected[entry.texture]=true end
        end
        while #self.textures>=8 or self.bytes+candidate.bytes>128*1024*1024 do
            local victim,index
            for i,t in ipairs(self.textures)do
                if not protected[t] and (not victim or (t.used or 0)<(victim.used or 0))then victim,index=t,i end
            end
            if not victim then self.status='image_budget_full';return s,false end
            adapter:restore()
            for key,entry in pairs(self.entries)do if entry.texture==victim then self.entries[key]=nil end end
            adapter:destroy(victim);table.remove(self.textures,index)
            self.bytes=self.bytes-victim.bytes;self.released=self.released+1;self.evicted=self.evicted+1
            s=adapter:snapshot()
        end
        local texture=adapter:freeze(s,candidate)
        if not texture then return s,false end
        texture.used=self.ticks
        self.textures[#self.textures+1]=texture
        self.bytes=self.bytes+texture.bytes;self.retained=self.retained+1
        if idle then self.idle_retained=self.idle_retained+1 end
        if not candidate.all_complete then self.partial_retained=self.partial_retained+1 end
        for key,value in pairs(candidate.entries)do
            -- Count only crops that replaced an existing crop; a first capture
            -- of a re-rendered item is a miss, not a refresh.
            if self.entries[key] and rendered[key]then self.refreshed=self.refreshed+1 end
            value.texture=texture;self.entries[key]=value;rendered[key]=nil
        end
        s.atlas=texture.replacement
        if release_superseded()then s=adapter:snapshot()end
        return s,true
    end
    -- Choose a same-request handoff. A visible handoff runs only while a
    -- visible tile has no crop at all, so warm visits keep the single
    -- whole-request refresh and never allocate an extra replacement atlas.
    -- A rebind handoff follows it once the offscreen cards finish; tiles over
    -- the regions it left blank must already be served from retained crops.
    local function handoff_mode(s)
        if s.can_freeze_idle then return 'idle' end
        if s.can_freeze_rebind then
            for _,w in ipairs(s.widgets)do
                if not w.pixels_ready and not self.entries[w.key]then return nil end
            end
            return 'idle'
        end
        if s.can_freeze_visible then
            for _,w in ipairs(s.widgets)do
                if not self.entries[w.key]then return 'visible' end
            end
        end
        return nil
    end
    function self:tick(pressure)
        if not self.enabled then self.status='images_disabled';return end
        self.ticks=self.ticks+1
        local s=adapter:snapshot();self.screen=s.screen or 'none'
        self.widget_count=#s.widgets;self.named_material_widgets=0
        for _,w in ipairs(s.widgets)do if w.named_material then self.named_material_widgets=self.named_material_widgets+1 end end
        if context~=s.context or pressure then
            self:clear(pressure and 'memory_pressure' or 'thumbnail_manager_changed');context=s.context
        end
        if view~=s.view then reset_request();view=s.view end
        if adapter.drain then adapter:drain()end
        if pressure or not s.context or not s.atlas then
            reset_request()
            self.status=pressure and 'image_memory_pressure' or
                (s.context and 'waiting_for_thumbnail_screen' or 'waiting_for_image_world');return
        end
        if not s.capture_id then
            reset_request()
            self.status='waiting_for_thumbnail_screen';return
        end
        self.status='learning_images'
        if pending and (pending.atlas~=s.atlas or pending.layout~=s.layout)then
            pending=nil;self.pending_items=0;self.pending_drops=self.pending_drops+1
        end
        if pending and pending.request_id~=s.capture_id then
            local candidate=pending;pending=nil;self.pending_items=0
            if s.can_freeze then
                s=retain(s,candidate,false)
            else self.late_switches=self.late_switches+1 end
        end
        -- A weapon's pattern or attachment change never alters the thumbnail
        -- request identity, so it is detected from the configured slots the
        -- preview queue reports. Retire the superseded crop immediately: the
        -- widget returns to the native pipeline, which presents the re-render as
        -- soon as that item composes, and the v17 pass captures it afterwards.
        local changed=0
        for _,item in ipairs(s.items)do
            local entry=self.entries[item.key]
            if entry and entry.preview and item.preview and entry.preview~=item.preview then
                self.entries[item.key]=nil;changed=changed+1
                if pending then pending.entries[item.key]=nil end
            end
        end
        self.changed_items=changed
        if changed>0 then self.reappeared=self.reappeared+changed end
        local hits,misses,early=adapter:apply(s,self.entries)
        self.last_early_hits=early or 0;self.early_hits=self.early_hits+self.last_early_hits
        self.hits=self.hits+hits;self.misses=self.misses+misses
        self.last_hits=hits;self.last_misses=misses
        count_surface(s.screen,hits)
        for _,item in ipairs(s.items)do
            local entry=self.entries[item.key];if entry then entry.texture.used=self.ticks end
        end
        local ready,missing,superseded={},0,0
        self.blank_ready_items=0
        for _,item in ipairs(s.items)do
            -- A card that is not complete has been re-queued, so the item's
            -- next completion produces pixels that supersede our crop.
            if not item.ready then rendered[item.key]=true end
            if item.ready and item.pixels_ready==false then self.blank_ready_items=self.blank_ready_items+1 end
            if item.ready and item.pixels_ready~=false then
            ready[#ready+1]=item.key
            if not self.entries[item.key]then missing=missing+1
            elseif rendered[item.key]then missing=missing+1;superseded=superseded+1 end
        end end
        self.ready_items=#ready;self.missing_ready_items=missing;self.rendered_items=superseded
        local capture_id=s.capture_id..table.concat(ready)
        if capture_id~=last_capture then
            last_capture=capture_id
            -- Refresh partial metadata as cards finish, or remove it when
            -- native generation restarts. This never detaches the active work.
            pending=missing>0 and adapter:capture(s) or nil
            self.pending_items=0
            if pending then
                pending.request_id=s.capture_id;pending.all_complete=s.complete
                for _ in pairs(pending.entries)do self.pending_items=self.pending_items+1 end
            end
        end
        local mode=pending and pending.request_id==s.capture_id and handoff_mode(s)
        if mode then
            local kept
            s,kept=retain(s,pending,mode=='idle')
            if kept and mode=='visible' then self.visible_retained=self.visible_retained+1 end
            if kept then
                pending=nil;self.pending_items=0
                -- The idle working replacement has no pixels yet. Bind the
                -- completed original before this callback returns to the UI.
                local new_hits,new_misses,new_early=adapter:apply(s,self.entries)
                self.hits=self.hits+new_hits-hits;self.misses=self.misses+new_misses-misses
                self.early_hits=self.early_hits+(new_early or 0)-(early or 0)
                count_surface(s.screen,new_hits-hits)
                hits,misses,early=new_hits,new_misses,new_early
                self.last_hits=hits;self.last_misses=misses;self.last_early_hits=early or 0
                self.missing_ready_items=0
                self.rendered_items=0
            end
        end
        if self.status~='image_budget_full'then
            self.status=hits>0 and 'showing_retained_images' or (pending and 'completed_cards_ready_to_retain' or 'learning_images')
        end
    end
    return self
end
return M
