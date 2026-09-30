-- Host-side squad actions on the ship: disband, and promote a squad member to
-- host.
--
-- Players are only ever removed with the game's own kick: the release drives
-- the escape menu's player-menu KICK, so the game kicks in its own update (see
-- kick below; other ways of kicking are test-build modes). PROMOTE kicks the
-- successor (it returns to its ship and hosts a fresh lobby), finds that lobby
-- through the game's lobby browser, and moves the squad with the game's own
-- squad-Quickplay party join, so no other player needs the mod.
local L = {}

-- The successor's new lobby is searched for as soon as it has left (its ship
-- loads meanwhile; a search before the lobby exists finds nothing), every
-- half second at first, then every 4 s. One PlayFab request each (about
-- 0.2-0.35 s; PlayFab documents no FindLobbies limit, so the fast phase is
-- short). In the v0.4-diag6 test the lobby appeared 2.4-3.6 s after the
-- successor left, and searches a second apart found it at 3.7 s.
L.FIRST_SEARCH = 0.5       -- seconds after the successor left before the first search
L.SEARCH_INTERVAL = 0.5    -- seconds from one search's results to the next search, for L.FAST_SEARCHES seconds
L.FAST_SEARCHES = 15
L.SLOW_SEARCH_INTERVAL = 4 -- seconds between searches after that
L.SEARCH_TIMEOUT = 60      -- give up finding the successor's new lobby
L.RESULT_TIMEOUT = 8       -- one search
L.GONE_TIMEOUT = 10        -- the successor leaves the session after the kick
L.DISBAND_TIMEOUT = 10     -- every kicked player has left the session
L.JOIN_TIMEOUT = 60        -- the party join completes
L.JOIN_GRACE = 2           -- before a returned-to-hosting state counts as a refusal
L.UNLOAD_HOLD = 10        -- package unloads stay paused at least this long after the last kick
L.UNLOAD_HOLD_CAP = 60     -- and are resumed after this long even if the session never settles
L.GAME_KICK_WAIT = 5       -- the player menu's KICK: for the menu to take input, then for the player to go
L.CHAT_LEAD = 0.5          -- seconds between the squad message and the first kick (so it shows first)
L.ARRIVAL_CHECK = 15       -- seconds after a move: how many of the squad reached the new host's session

-- Offsets inside api.scratch (16-byte aligned): a lobby browser result, the search value.
L.INFO, L.SEARCH_VALUE = 0, 256
L.INFO_SIZE, L.INFO_CONNECTION = 256, 72

-- status: the addon's shared status table. note(message): the log.
function L.new(api, game, G, natives, status, note)
    local self = {}
    local cache, s = {ctx = 0}, G.new_snapshot()
    local job = nil
    local scratch = api.scratch
    status.actions = 0

    local function set_status(text)
        status.lobby = text
        status.revision = (status.revision or 0) + 1
    end
    set_status('idle')

    local function snapshot()
        local ctx = G.context(api, game, cache)
        if ctx == 0 then return nil end
        return G.read_session(api, game, ctx, s)
    end
    self.snapshot = snapshot

    local function name_of(names, lo, hi)
        return names[G.peer_key(lo, hi)] or ('player ' .. api.u64_hex(lo, hi))
    end

    -- Remote session peers (not the local player), as a fresh list.
    local function remote_peers(snap)
        local list = {}
        for i = 1, snap.peer_count do
            local peer = snap.peers[i]
            if not (peer.lo == snap.local_lo and peer.hi == snap.local_hi) and (peer.lo ~= 0 or peer.hi ~= 0) then
                list[#list + 1] = {lo = peer.lo, hi = peer.hi, index = peer.index}
            end
        end
        return list
    end

    local function lower(a, b) return a.hi < b.hi or (a.hi == b.hi and a.lo < b.lo) end

    -- target: {lo, hi} of the squad member the host picked in the menu, or nil
    -- for the automatic choice (a friend of the host first, then the lowest
    -- peer id, which is also the rule the game's lobby uses when an owner
    -- disappears).
    function self.choose_successor(snap, target)
        local peers = remote_peers(snap)
        if #peers == 0 then return nil, 'no other players' end
        if target then
            for _, peer in ipairs(peers) do
                if peer.lo == target.lo and peer.hi == target.hi then return peer end
            end
            return nil, 'that player is no longer in the squad'
        end
        local best, best_friend
        for _, peer in ipairs(peers) do
            if not best or lower(peer, best) then best = peer end
            if natives.is_friend(0, api.u64(peer.lo, peer.hi)) ~= 0 then
                peer.friend = true
                if not best_friend or lower(peer, best_friend) then best_friend = peer end
            end
        end
        return best_friend or best
    end

    local function refuse(action, why)
        note(action .. ' refused: ' .. why)
        set_status(action .. ' refused: ' .. why)
        return false, why
    end

    -- Squad messages: announcer(text) posts a chat line to the squad (set by
    -- the addon; nil while the option is off). Returns when the first kick may
    -- start: L.CHAT_LEAD later once a line went out, so it arrives first.
    -- text(key) gives the line in the host's language (the addon's translator).
    self.announcer = nil
    self.text = function(key) return key end
    local function announce(text, now)
        if not self.announcer then return now end
        local sent, detail = self.announcer(text)
        if sent then
            note('squad message sent to ' .. tostring(detail) .. ' player(s): ' .. text)
            return now + L.CHAT_LEAD
        end
        note('squad message not sent: ' .. tostring(detail))
        return now
    end

    -- PROMOTE's message. notice_mode 'leader': the game's own new squad
    -- leader notice, leader_notice(lo, hi) (set by the addon; nil while squad
    -- messages are off), shown without a colon; 'chat' (a test-build choice):
    -- a chat line. Returns when the kick may start, as announce.
    self.notice_mode, self.leader_notice = 'leader', nil
    local function tell_new_host(now)
        if self.notice_mode ~= 'leader' then
            return announce(job.name .. ' is the new host. The squad is moving to their ship.', now)
        end
        if not self.leader_notice then return now end
        local sent, detail = self.leader_notice(job.lo, job.hi)
        if sent then
            note('squad leader notice sent to ' .. tostring(detail) .. ' player(s): ' .. job.name)
            return now + L.CHAT_LEAD
        end
        note('squad leader notice not sent: ' .. tostring(detail))
        return now
    end

    -- menu_closer() closes the escape menu as Esc does (set by the addon).
    -- PROMOTE calls it once the menu is no longer needed: the squad moving
    -- while it was open left the old host's Helldiver in the menu pose until
    -- Esc was pressed twice (v0.4-diag7).
    self.menu_closer = nil
    local function close_menu()
        if not self.menu_closer then return end
        local closed, why = self.menu_closer()
        note(job.kind .. ': ' .. (closed and 'escape menu closed' or 'escape menu not closed: ' .. tostring(why)))
    end

    -- Every kick goes through here; see docs/TECHNICAL.md.
    -- kick_peer releases the kicked player's loadout at once, and the engine
    -- unloads one queued package per frame, while their Helldiver can still
    -- hold units from those packages (the v0.1 and v0.3 crashes; in the
    -- v0.4-diag1 test the client never left, so its Helldiver stayed). kick_mode
    -- (diagnostic builds choose it):
    --   'hold'    kick_peer in the update, the engine's unload pause (which the
    --             game itself sets while it tears a world down) held until the
    --             kicked clients have left the PlayFab lobby (tick)
    --   'message' only the kick message; the client leaves by itself and the
    --             game removes it through its own leave handling
    --   'render'  kick_peer from the render callback (render_step), with the hold
    --   'plain'   kick_peer in the update without the hold (v0.3)
    --   'game'    the player menu's own KICK, driven through the escape menu
    --             (game_kicker, set by the addon; ui_step): the game kicks in
    --             its own update, as when the host holds KICK
    -- observer: the diagnostic recorder.
    local hold = nil
    local pending = {}
    local ui = {}
    self.kick_mode = 'hold'
    self.observer = nil
    self.game_kicker = nil

    local function hold_unloads(now)
        if hold then
            hold.last = now
            return
        end
        local paused = natives.unload_paused() ~= 0
        if not paused then natives.pause_unloads(1) end
        hold = {owned = not paused, started = now, last = now}
        note(paused and 'kick: package unloads already paused by the game' or 'kick: package unloads paused')
    end

    local function perform(ctx, lo, hi, now, how)
        local observer = self.observer
        if observer then observer.before_kick(lo, hi, now, how) end
        if how == 'message' then
            natives.send_kick(api.u64(lo, hi))
        else
            natives.kick_peer(ctx + G.HOST_SYNC, api.u64(lo, hi))
        end
        if observer then observer.after_kick(lo, hi, now, how) end
    end

    local function kick(snap, lo, hi, now)
        local mode = self.kick_mode
        if mode == 'game' then
            ui[#ui + 1] = {lo = lo, hi = hi, since = now}
        elseif mode == 'render' then
            pending[#pending + 1] = {ctx = snap.ctx, lo = lo, hi = hi}
        elseif mode == 'message' then
            perform(snap.ctx, lo, hi, now, 'message')
        else
            if mode == 'hold' then hold_unloads(now) end
            perform(snap.ctx, lo, hi, now, 'kick')
        end
    end

    -- The render callback (diagnostic builds): the kicks 'render' mode queued
    -- in this frame's update.
    function self.render_step(now)
        for i = 1, #pending do
            local k = pending[i]
            pending[i] = nil
            hold_unloads(now)
            perform(k.ctx, k.lo, k.hi, now, 'render')
        end
    end

    -- 'game' mode, once per frame while kicks are queued: one at a time, the
    -- game_kicker sets up the player menu's KICK (the game kicks later in
    -- this frame); the next kick waits until that player has left.
    function self.ui_pending() return #ui > 0 end
    function self.ui_step(now)
        local target = ui[1]
        if not target then return end
        local who = api.u64_hex(target.lo, target.hi)
        if target.started then
            local snap = snapshot()
            if not snap or not G.has_peer(snap, target.lo, target.hi) then
                note(string.format('game kick: %s left the session %.2f s after its KICK', who, now - target.started))
                table.remove(ui, 1)
            elseif now - target.started >= L.GAME_KICK_WAIT then
                note('game kick: ' .. who .. ' is still in the session; the player menu\'s KICK did not run')
                table.remove(ui, 1)
            end
            return
        end
        local status, card = 'no escape menu', nil
        if self.game_kicker then status, card = self.game_kicker(target.lo, target.hi) end
        if status == 'started' then
            target.started = now
            note('game kick: KICK set on ' .. who .. '\'s player menu (card ' .. tostring(card) .. ')')
            local observer = self.observer
            if observer then observer.before_kick(target.lo, target.hi, now, 'game') end
        elseif now - target.since >= L.GAME_KICK_WAIT then
            note('game kick: gave up on ' .. who .. ' (' .. status .. ')')
            table.remove(ui, 1)
        elseif status ~= target.status then
            target.status = status
            note('game kick: waiting for the escape menu (' .. status .. ')')
        end
    end

    function self.holding() return hold ~= nil end

    local function lobby_members(snap)
        local lobby = G.playfab_lobby(api, snap.ctx)
        return lobby and api.read32(lobby + G.PL_MEMBERS) or 0
    end

    -- Once per frame while holding: resumes unloads L.UNLOAD_HOLD after the
    -- last kick once the session is stable and no kicked client is still in
    -- the PlayFab lobby (its Helldiver would still be on this ship). During a
    -- transition the game's own world teardown sets and clears the flag
    -- itself; the cap ends a hold that never settles.
    function self.tick(now)
        if not hold or now - hold.last < L.UNLOAD_HOLD then return end
        if not hold.owned then hold = nil; return end
        if natives.unload_paused() == 0 then
            note(string.format('package unloads resumed by the game after %.1f s', now - hold.started))
            hold = nil
            return
        end
        local snap = snapshot()
        local stable = snap ~= nil and snap.transition == 0
            and (snap.mode == G.MODE_SHIP or snap.mode == G.MODE_MISSION)
        local settled = stable and lobby_members(snap) <= snap.peer_count
        if not settled and now - hold.started < L.UNLOAD_HOLD_CAP then return end
        natives.pause_unloads(0)
        note(string.format('package unloads resumed after %.1f s%s', now - hold.started, settled and '' or ' (cap)'))
        hold = nil
    end

    -- Error or shutdown: resumes unloads if the mod paused them.
    function self.release_hold(reason)
        if hold and hold.owned and natives.unload_paused() ~= 0 then
            natives.pause_unloads(0)
            note('package unloads resumed: ' .. reason)
        end
        hold = nil
    end

    -- Shared checks: hosting a squad, nothing else in progress. Returns the
    -- snapshot, or nil and the reason (already logged).
    local function ready(action)
        local why
        local snap = not job and snapshot() or nil
        if job then
            why = 'another action is running (' .. job.kind .. ')'
        elseif not snap then
            why = 'no network session'
        elseif not snap.is_host or snap.hosting ~= 1 then
            why = 'not hosting'
        elseif snap.peer_count < 2 then
            why = 'no other players'
        elseif snap.transition ~= 0 then
            why = 'a transition is running'
        elseif snap.join_state ~= 0 or snap.party_join ~= 0 then
            why = 'a join is running'
        else
            return snap
        end
        refuse(action, why)
        return nil, why
    end

    -- Kicks every other player with the game's own kick, one per frame (the
    -- first in this frame); the job ends when they have all left the session.
    function self.disband(now)
        local snap, why = ready('disband')
        if not snap then return false, why end
        if snap.mode ~= G.MODE_SHIP then return refuse('disband', 'only on the ship') end
        if self.kick_mode == 'game' and not self.game_kicker then
            return refuse('disband', 'the escape menu integration is unavailable')
        end
        local names, peers = G.names(api, game), remote_peers(snap)
        for _, peer in ipairs(peers) do peer.name = name_of(names, peer.lo, peer.hi) end
        job = {kind = 'disband', path = 'disband', queue = peers, kicked = 0, total = #peers, ctx = snap.ctx,
               step = 'kick', since = now, started = now}
        note('disband: kicking ' .. #peers .. ' player(s)')
        set_status('disband: kicking ' .. #peers .. ' player(s)')
        job.kick_at = announce(self.text('chat.disband'), now)
        return self.step(now)
    end

    local function fail(why)
        note(job.kind .. ' failed at ' .. job.step .. ': ' .. why)
        set_status(job.kind .. ' failed: ' .. why)
        job = nil
        return false
    end

    local function finish(text)
        note(job.kind .. ': ' .. text)
        set_status(text)
        status.actions = status.actions + 1
        job = nil
        return true
    end

    local function goto_step(step, now, timeout)
        job.step, job.since = step, now
        job.deadline = timeout and now + timeout or nil
    end

    -- Promotes a squad member: tells the squad, kicks the successor home, finds
    -- their new lobby and moves the squad there. Ship only. target: see
    -- choose_successor.
    function self.promote(target_choice, now)
        local snap, why = ready('promote')
        if not snap then return false, why end
        if snap.mode ~= G.MODE_SHIP then return refuse('promote', 'only on the ship') end
        if self.kick_mode == 'game' and not self.game_kicker then
            return refuse('promote', 'the escape menu integration is unavailable')
        end
        local target, reason = self.choose_successor(snap, target_choice)
        if not target then return refuse('promote', reason) end
        local names = G.names(api, game)
        job = {kind = 'promote', lo = target.lo, hi = target.hi, name = name_of(names, target.lo, target.hi),
               started = now, ctx = snap.ctx, step = 'start', since = now, squad = snap.peer_count}
        note(string.format('promote: successor %s (%s, player %d%s)', job.name, api.u64_hex(target.lo, target.hi),
            target.index + 1, target.friend and ', friend' or ''))
        job.kick_at = tell_new_host(now)
        if job.kick_at > now then
            goto_step('announce', now)
            set_status('promote: telling the squad')
        else
            kick(snap, target.lo, target.hi, now)
            goto_step('gone', now, L.GONE_TIMEOUT)
            set_status('promote: ' .. job.name .. ' returns to their ship')
        end
        return true
    end

    -- Diagnostic builds: verbose logs every search, why one waits and what it
    -- returned; control_search first searches for the host's own lobby, which
    -- must be found if lobbies publish their host's id as the mod expects.
    self.verbose, self.control_search = false, false

    local function start_search(snap, now)
        local field = snap.ctx + G.BROWSER
        local handle = api.load64(field)
        if handle == 0 then return fail('no lobby browser') end
        local searching = G.game_searching(api, game)
        if searching or natives.browser_busy(field) ~= 0 then
            local why = searching and 'a game search is running' or 'the lobby browser is busy'
            if self.verbose and job.waiting ~= why then note(job.kind .. ': search waits (' .. why .. ')') end
            job.waiting = why
            job.next_search = now + 0.5
            return true
        end
        job.waiting = nil
        local control = self.control_search and not job.controlled
        local lo, hi = job.lo, job.hi
        if control then lo, hi, job.controlled = snap.local_lo, snap.local_hi, true end
        natives.clear_filters(handle)
        local value = api.u64_decimal(lo, hi)
        api.put_string(scratch + L.SEARCH_VALUE, value, 32)
        natives.filter_string(field, G.KEY_HOST_PEER, scratch + L.SEARCH_VALUE, G.OP_EQUAL)
        natives.browser_start(field)
        job.control = control
        if not control then job.searches = (job.searches or 0) + 1 end
        if self.verbose then
            note(string.format('%s: search %s (string_key2 eq %s)', job.kind, control and 'for your own lobby (control)'
                or (job.searches .. ' for ' .. job.name .. '\'s lobby'), value))
        end
        goto_step('results', now, L.RESULT_TIMEOUT)
        return true
    end

    local function read_results(snap, now)
        local field = snap.ctx + G.BROWSER
        if natives.browser_busy(field) ~= 0 then
            if now >= job.deadline then
                if self.verbose then note(job.kind .. ': search timed out') end
                goto_step('search', now)
                job.next_search = now
            end
            return true
        end
        local count = natives.browser_count(field)
        local joinable = false
        if count > 0 then
            api.zero(scratch + L.INFO, L.INFO_SIZE)
            natives.browser_result(field, scratch + L.INFO, 0)
            joinable = api.load8(scratch + L.INFO + L.INFO_CONNECTION) ~= 0
        end
        if self.verbose then
            note(string.format('%s: %s search: %d result(s)%s', job.kind, job.control and 'control' or 'successor',
                count, count > 0 and string.format(', first lobby %s%s', api.cstring(scratch + L.INFO, 64) or '?',
                    joinable and ' (has a connection string)' or ' (no connection string)') or ''))
        end
        if job.control then
            goto_step('search', now)
            job.next_search = now
            return true
        end
        if count > 0 then
            if joinable then
                job.found_at = now
                note(string.format('%s: found %s\'s lobby after %d search(es), %.1f s after they left', job.kind,
                    job.name, job.searches, now - job.gone_at))
                local started = natives.start_join(snap.ctx + G.JOIN, scratch + L.INFO, G.JOIN_PARTY, 0,
                                                   G.JOIN_REASON_QUICKPLAY)
                if started == 0 then return fail('the game refused to start the party join') end
                goto_step('joining', now, L.JOIN_TIMEOUT)
                set_status(job.kind .. ': moving the squad to ' .. job.name)
                return true
            end
        end
        goto_step('search', now)
        job.next_search = now + (now - job.gone_at < L.FAST_SEARCHES and L.SEARCH_INTERVAL or L.SLOW_SEARCH_INTERVAL)
        return true
    end

    -- Where a promote's time went: the kick, finding the lobby, the join.
    local function timing()
        if not (job.gone_at and job.found_at and job.moved_at) then return '' end
        return string.format(' (kicked in %.1f s, lobby found %.1f s later, joined in %.1f s)',
            job.gone_at - job.started, job.found_at - job.gone_at, job.moved_at - job.found_at)
    end

    -- One step per frame while an action runs. now: seconds (the addon's clock).
    function self.step(now)
        if not job then return false end
        local snap = snapshot()
        if not snap then return fail('network session lost') end
        local step = job.step
        if job.path == 'disband' then
            if job.kick_at and now < job.kick_at then return true end -- the squad message goes first
            -- Kick the next player still in the session; finish once none is left.
            while #job.queue > 0 do
                local peer = table.remove(job.queue, 1)
                if G.has_peer(snap, peer.lo, peer.hi) then
                    kick(snap, peer.lo, peer.hi, now)
                    job.kicked = job.kicked + 1
                    note('disband: kicked ' .. peer.name)
                    return true
                end
            end
            if snap.peer_count <= 1 then return finish('disbanded (' .. job.kicked .. ' players)') end
            if now - job.started >= L.DISBAND_TIMEOUT then
                return finish('disbanded (' .. job.kicked .. ' players; ' .. (snap.peer_count - 1) .. ' still leaving)')
            end
            return true
        end
        if step == 'announce' then
            -- The squad message went out; kick once it has had time to arrive.
            if now >= job.kick_at then
                if not G.has_peer(snap, job.lo, job.hi) then return fail(job.name .. ' left the squad meanwhile') end
                kick(snap, job.lo, job.hi, now)
                goto_step('gone', now, L.GONE_TIMEOUT)
                set_status(job.kind .. ': ' .. job.name .. ' returns to their ship')
            end
        elseif step == 'gone' then
            if not G.has_peer(snap, job.lo, job.hi) then
                goto_step('search', now)
                job.gone_at = now
                close_menu()
                job.search_until, job.next_search = now + L.SEARCH_TIMEOUT, now + L.FIRST_SEARCH
                set_status(job.kind .. ': waiting for ' .. job.name .. '\'s lobby')
                local observer = self.observer
                if observer and observer.lobby_report then observer.lobby_report(snap.ctx) end
            elseif now >= job.deadline then
                return fail(job.name .. ' is still in the session')
            end
        elseif step == 'search' then
            if now >= job.search_until then return fail(job.name .. '\'s lobby was not found') end
            if now >= job.next_search then return start_search(snap, now) end
        elseif step == 'results' then
            return read_results(snap, now)
        elseif step == 'joining' then
            if snap.host_lo == job.lo and snap.host_hi == job.hi then
                job.moved_at = now
                self.arrival = {due = now + L.ARRIVAL_CHECK, squad = job.squad, name = job.name, lo = job.lo,
                                hi = job.hi}
                return finish('squad moved to ' .. job.name .. '\'s ship' .. timing())
            elseif snap.is_host and snap.join_state == 0 and now - job.since >= L.JOIN_GRACE then
                return fail(job.name .. '\'s game refused the squad (privacy or room)')
            elseif now >= job.deadline then
                return fail('the party join did not complete')
            end
        end
        return true
    end

    -- After a move the other members follow the party join on their own; the
    -- log says how many of the squad reached the new host's session, once,
    -- L.ARRIVAL_CHECK s later. arrival is set only then: the addon calls
    -- check_arrival while it is set, and nothing is read before it is due.
    self.arrival = nil
    function self.check_arrival(now)
        local arrival = self.arrival
        if not arrival or now < arrival.due then return end
        self.arrival = nil
        local snap = snapshot()
        if not snap or snap.host_lo ~= arrival.lo or snap.host_hi ~= arrival.hi then
            note(string.format('promote: no longer in %s\'s session %d s after the move', arrival.name,
                L.ARRIVAL_CHECK))
            return
        end
        note(string.format('promote: %d of %d players in %s\'s session %d s after the move', snap.peer_count,
            arrival.squad, arrival.name, L.ARRIVAL_CHECK))
    end

    function self.busy() return job ~= nil end
    function self.job() return job end

    -- True when an action was running and is now cancelled.
    function self.cancel(reason)
        if not job then return false end
        fail('cancelled: ' .. tostring(reason))
        return true
    end

    return self
end

return L
