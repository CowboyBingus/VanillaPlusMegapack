-- CANCEL SOS: stops the SOS Beacon the host called in, keeps it stopped, and
-- gives the SOS Beacon its use back so it can be called in again.
--
-- The game's SOS system (S) lists a mission for SOS joins. While its active
-- byte is set, the host's lobby carries the SOS flag (lobby key 8, PlayFab
-- number_key8, which SOS Quickplay searches for) and is forced Public (key 19,
-- number_key6), whatever the host's privacy setting. The game switches it off
-- only when the squad is full or the beacon is gone (0x67AA20: key 8 = 0), and
-- on again whenever a player leaves or a new host takes over while a beacon
-- stands (0xB5F140, 0x1087010). Its SOS off puts the privacy setting back
-- only when PlayFab already shows the SOS flag off, which it does not until
-- the lobby has posted; so the mod calls that same function, then sets key 19
-- to the privacy setting with the game's key setter, and lets the game post
-- both in this frame's update. It does the same after each re-arm, until the
-- mission ends or the host calls in a new beacon. The SOS Beacon stratagem has
-- one use per mission, which the cancelled beacon spent; the mod puts it back
-- in the host's own stratagem slot. Evidence: docs/TECHNICAL.md.
local B = {}

B.SOS_PTR = 0x3326bf0           -- the SOS system
B.ACTIVE = 8                    -- byte: the SOS is on
B.ENABLED = 24                  -- u32: enabled SOS beacon components (the re-arms need one)
B.PRIVACY = 0xac550             -- game state -> the host's privacy setting
B.PRIVACY_NAMES = {[0] = 'Public', [1] = 'Friends Only', [2] = 'Invite Only', [3] = 'Friends and Clan'}
-- The game's lobby wrapper (network context + G.LOBBY): a cache of the lobby
-- keys as text, the keys the next post sends and the countdown to that post
-- (float seconds; the game posts at <= 0 and restarts it at 30 s).
B.KEYS, B.KEY_SIZE = 56, 257
B.KEY_SOS, B.KEY_PRIVACY = 8, 19
B.PENDING = 0x20
B.COUNTDOWN = 0x1b80
-- The stratagems: per-player records (32 of them, then their count), each
-- with up to 16 stratagem slots {type +0, uses left +4}; and the stratagem
-- settings by type {type +0, uses per mission +0x50 (-1: no limit), shared
-- by the squad +0x94}.
B.PLAYERS_PTR = 0x347ce50
B.PLAYER_SIZE, B.PLAYER_COUNT, B.MAX_PLAYERS = 0x1690, 0x2d200, 32
B.SLOTS, B.SLOT_SIZE, B.SLOT_COUNT, B.MAX_SLOTS = 0x1c0, 0x30, 0x7c0, 16
B.SLOT_USES = 4
B.STRATAGEMS = 0x37cb600
B.STRATAGEM_USES, B.STRATAGEM_SHARED = 0x50, 0x94
B.SOS_STRATAGEM = 0x91
B.NO_LIMIT = 0xffffffff

-- The game's own "SOS off", the function it runs when the squad fills up.
B.DEACTIVATE = {rva = 0x67aa20, type = 'LmSosCall', bytes =
    '\72\137\92\36\8\87\72\131\236\32\72\139\61\191\36\224\2\72\139\217\72\139\135\168\179\0\0\72\133\192\116\31\72'
    .. '\59\135\152\179\0\0\116\22\198\65\8\0\72\199\1\0\0\0\0\72\139\92\36\48\72\131\196\32\95\195\69\51\192\72\141'
    .. '\143\112\212\1\0\65\141\80\8\232\94\123\161\0\72\139\5\199\184\202\2\186\19\0\0\0\72\139\207\68\139\128\80'
    .. '\197\10\0\232\19\82\205\0\198\67\8\0\72\199\3\0\0\0\0\72\139\92\36\48\72\131\196\32\95\195'}
-- The game's lobby key setter for numbers (the lobby wrapper, key, value): the
-- value as text in the cache and the key's bits when it changed (0x10924D0).
B.SET_KEY = {rva = 0x10925d0, type = 'LmLobbySetInt', bytes =
    '\76\139\220\73\137\91\32\87\72\129\236\192\0\0\0\72\139\5\42\154\90\1\72\51\196\72\137\132\36\176\0'
    .. '\0\0\15\87\192\139\250\15\17\68\36\48\72\139\217\69\139\200\15\17\68\36\64\76\141\5\35\85\27\1\186'
    .. '\128\0\0\0\15\17\68\36\80\72\141\76\36\48\15\17\68\36\96\15\17\68\36\112\65\15\17\67\184\65\15\17\67'
    .. '\200\65\15\17\67\216\232\230\178\69\255\72\141\76\36\48\72\199\192\255\255\255\255\72\255\192\128\60'
    .. '\1\0\117\247\137\68\36\32\76\141\68\36\32\72\141\68\36\48\139\215\72\137\68\36\40\72\139\203\15\40'
    .. '\68\36\32\102\15\127\68\36\32\232\89\254\255\255'}

-- game.dll code that fixes the layout above.
B.CODE = {
    -- "SOS on": lobby key 8 = 1 and privacy Public when hosting, then S+0 = now, S+8 = 1.
    {rva = 0x67a9a0, name = 'SOS activate', bytes =
        '\72\137\92\36\8\87\72\131\236\32\72\139\29\63\37\224\2\72\139\249\72\139\131\168\179\0\0\72\133\192\116\24'
        .. '\72\59\131\152\179\0\0\116\15\198\65\8\1\72\139\92\36\48\72\131\196\32\95\195\186\8\0\0\0\72\141\139\112'
        .. '\212\1\0\68\141\66\249\232\227\123\161\0\69\51\192\72\139\203\65\141\80\19\232\164\82\205\0\72\139\5\69'
        .. '\185\202\2\72\139\92\36\48\72\139\72\16\72\137\15\198\71\8\1\72\131\196\32\95\195'},
    -- The beacon's activation: the SOS system global, then "SOS on" while the session has fewer than 4 peers.
    {rva = 0x517fd0, name = 'SOS activation event', bytes =
        '\128\58\0\116\34\72\139\13\20\236\224\2\72\139\5\13\79\246\2\72\199\1\0\0\0\0\131\184\144\99\1\0\4\15\130'
        .. '\169\41\22\0\195'},
    -- The re-arms: "SOS on" again when S+24 > 0 and S+8 == 0, after a player left and after a new host.
    {rva = 0xb5f2c3, name = 'SOS re-arm after a leave', bytes =
        '\72\139\9\68\57\121\24\118\11\68\56\121\8\117\5\232\201\182\177\255'},
    {rva = 0x10871f3, name = 'SOS re-arm after a new host', bytes =
        '\72\139\9\68\57\105\24\118\11\68\56\105\8\117\5\232\153\55\95\255'},
    -- The lobby key setter: the text cache (+56, 257 bytes per key) and the per-key bits (+0x20, +0x18).
    {rva = 0x10924e6, name = 'lobby key setter', bytes =
        '\72\141\89\56\72\105\197\1\1\0\0\73\139\240\72\139\249\72\3\216\65\139\0\133\192\117\4\56\3\116\92\72\139'
        .. '\78\8\76\139\192\72\139\211\232\76\56\4\1\133\192\116\73\72\139\71\32\72\139\203\72\15\171\232\72\137'
        .. '\71\32\72\139\71\24\72\15\171\232\72\137\71\24'},
    -- The lobby update: the post countdown at +0x1B80, restarted from the online config's seconds.
    {rva = 0x109411d, name = 'lobby post countdown', bytes =
        '\243\15\16\135\128\27\0\0\72\139\5\28\34\41\2\243\15\92\0\15\47\240\243\15\17\135\128\27\0\0\15\147\195\132'
        .. '\219\116\26\72\139\5\151\141\62\2\102\15\110\128\104\206\3\0\15\91\192\243\15\17\135\128\27\0\0'},
    -- A stratagem's uses left: the slot's type and uses (+0x188/+0x18C from record+0x38), the settings table
    -- 0x37CB600, the shared flag +0x94 and the uses per mission +0x50 (-1: no limit).
    {rva = 0x66d3d0, name = 'stratagem uses', bytes =
        '\72\131\236\40\65\139\192\76\141\21\34\226\21\3\72\141\12\64\72\3\201\139\132\202\140\1\0\0\68\139'
        .. '\132\202\136\1\0\0\72\141\21\117\224\21\3\137\68\36\64\72\139\194\69\133\192\116\4\75\139\4\194\131'
        .. '\184\148\0\0\0\0\116\70\131\120\80\255\116\64'},
    -- The player records: their count at +0x2D200, the peer id at +0, 0x1690 bytes each, slots from +0x38.
    {rva = 0x66f060, name = 'player records', bytes =
        '\69\139\129\0\210\2\0\69\133\192\15\132\7\1\0\0\73\139\209\76\57\34\116\31\255\193\72\129\194\144\22'
        .. '\0\0\65\59\200\114\237\72\139\92\36\104\72\131\196\32\65\93\65\92\95\94\93\195\76\137\124\36\96\77'
        .. '\141\121\56\139\193\72\105\200\144\22\0\0\76\3\249\15\132\192\0\0\0'},
    -- A record's slots: their count at +0x788, 48 bytes each, type +0x188 and uses +0x18C (from record+0x38).
    {rva = 0x66f0f8, name = 'stratagem slots', bytes =
        '\65\139\183\136\7\0\0\73\139\212\72\139\13\239\115\203\2\131\254\16\65\15\67\245\69\51\201\72\141\60'
        .. '\118\72\193\231\4\73\3\255\68\137\135\136\1\0\0\232\38\164\32\0\137\135\140\1\0\0'},
}

-- The confirm dialog's body for a privacy setting, from the translator t
-- (bingus_text; the box holds about three lines, 120 bytes of English).
local PRIVACY_TEXTS = {[1] = 'privacy.friends', [2] = 'privacy.invite', [3] = 'privacy.clan'}
function B.body(privacy, t)
    if privacy == 0 then return t('dialog.cancel_sos.public') end
    return t('dialog.cancel_sos.private', {privacy = t(PRIVACY_TEXTS[privacy] or 'privacy.other')})
end

-- G: src/game.lua. status: the addon's status table (counts kept there).
-- note(message): the mod's log.
function B.new(api, game, G, status, note)
    local self = {}
    local deactivate, set_key
    local cache, snapshot = {ctx = 0}, G.new_snapshot()
    local confirmed = 0             -- the SOS object a guarded read confirmed
    local cancelled = nil           -- {ctx, sos, enabled} while a cancel is kept
    status.sos_cancels, status.sos_rearms, status.sos_leaks = 0, 0, 0

    -- Once: the natives and the code that fixes the layout.
    function self.verify()
        if api.bytes(game + B.DEACTIVATE.rva, #B.DEACTIVATE.bytes) ~= B.DEACTIVATE.bytes then
            return false, 'SOS deactivate changed'
        end
        if api.bytes(game + B.SET_KEY.rva, #B.SET_KEY.bytes) ~= B.SET_KEY.bytes then
            return false, 'lobby number setter changed'
        end
        for _, code in ipairs(B.CODE) do
            if api.bytes(game + code.rva, #code.bytes) ~= code.bytes then return false, code.name .. ' changed' end
        end
        deactivate = api.native(B.DEACTIVATE.type, game + B.DEACTIVATE.rva)
        set_key = api.native(B.SET_KEY.type, game + B.SET_KEY.rva)
        return true
    end

    -- The SOS system, or 0. A new object is confirmed once with a guarded
    -- read; later frames use direct loads.
    local function object()
        local sos = api.load64(game + B.SOS_PTR)
        if sos == 0 then return 0 end
        if sos ~= confirmed then
            if sos % 8 ~= 0 or not api.read32(sos + B.ENABLED) then return 0 end
            confirmed = sos
        end
        return sos
    end

    -- True while an SOS is on (two direct loads).
    function self.active()
        local sos = object()
        return sos ~= 0 and api.load8(sos + B.ACTIVE) ~= 0
    end

    local function privacy()
        local state = api.load64(game + G.GAME_STATE_PTR)
        if state == 0 then return nil end
        return api.load32(state + B.PRIVACY)
    end

    -- For the escape menu: the host's privacy setting when CANCEL SOS can be
    -- offered, else false. snap: a session snapshot (src/game.lua); the mode
    -- test needs no load, so the ship costs nothing here.
    function self.offer(snap)
        if snap.mode ~= G.MODE_MISSION or not snap.is_host or snap.hosting ~= 1 or snap.transition ~= 0 then
            return false
        end
        if not self.active() then return false end
        return privacy() or false
    end

    -- A lobby key from the game's cache (action frames only).
    local function key(ctx, index)
        return api.cstring(ctx + G.LOBBY + B.KEYS + index * B.KEY_SIZE, 16) or ''
    end
    local function keys(ctx)
        return string.format('SOS flag %s, privacy %s', key(ctx, B.KEY_SOS), key(ctx, B.KEY_PRIVACY))
    end

    -- The game's SOS off, then the privacy setting on key 19: the game's own
    -- SOS off keeps key 19 Public while PlayFab still shows the SOS flag on,
    -- and it does until the lobby has posted. Returns the setting.
    local function switch_off(ctx, sos)
        deactivate(sos)
        local setting = privacy()
        if setting then set_key(ctx + G.LOBBY, B.KEY_PRIVACY, setting) end
        return setting
    end

    -- The game posts the lobby in this frame's update (its countdown at 0),
    -- instead of up to 30 s later. One checked write.
    local function publish(ctx)
        return api.write_f32(ctx + G.LOBBY + B.COUNTDOWN, 0)
    end

    -- Gives the host's SOS Beacon back the use its beacon spent, up to the
    -- stratagem's uses per mission, so it can be called in again (action
    -- frames only; one checked write). Returns the log text.
    local function restore_use(snap)
        local settings = api.load64(game + B.STRATAGEMS + 8 * B.SOS_STRATAGEM)
        if settings == 0 or api.read32(settings) ~= B.SOS_STRATAGEM then return 'SOS Beacon settings unreadable' end
        local limit, shared = api.read32(settings + B.STRATAGEM_USES), api.read32(settings + B.STRATAGEM_SHARED)
        if not limit or limit == B.NO_LIMIT then return 'the SOS Beacon has no use limit' end
        if shared ~= 0 then return 'the SOS Beacon\'s uses are shared; not restored' end
        local players = api.load64(game + B.PLAYERS_PTR)
        local count = players ~= 0 and api.read32(players) and api.read32(players + B.PLAYER_COUNT)
        if not count then return 'player records unreadable' end
        for r = 0, math.min(count, B.MAX_PLAYERS) - 1 do
            local record = players + r * B.PLAYER_SIZE
            if api.load32(record) == snap.local_lo and api.load32(record + 4) == snap.local_hi then
                for i = 0, math.min(api.load32(record + B.SLOT_COUNT), B.MAX_SLOTS) - 1 do
                    local slot = record + B.SLOTS + i * B.SLOT_SIZE
                    if api.load32(slot) == B.SOS_STRATAGEM then
                        local uses = api.load32(slot + B.SLOT_USES)
                        if uses >= limit then return string.format('SOS Beacon uses already %d', uses) end
                        if not api.write32(slot + B.SLOT_USES, uses + 1) then
                            return 'SOS Beacon use: the write was refused'
                        end
                        return string.format('SOS Beacon uses %d -> %d', uses, uses + 1)
                    end
                end
                return 'no SOS Beacon slot'
            end
        end
        return 'no player record of yours'
    end

    local function refuse(why)
        note('cancel SOS refused: ' .. why)
        return false, why
    end

    -- Stops the SOS. Returns true, or false and why. now: seconds (the addon's clock).
    function self.cancel(now)
        if not deactivate then return refuse('not verified') end
        local ctx = G.context(api, game, cache)
        if ctx == 0 then return refuse('no network session') end
        local snap = G.read_session(api, game, ctx, snapshot)
        if not snap.is_host or snap.hosting ~= 1 then return refuse('not hosting') end
        if snap.mode ~= G.MODE_MISSION then return refuse('not in a mission') end
        if snap.transition ~= 0 then return refuse('a transition is running') end
        local sos = object()
        if sos == 0 or api.load8(sos + B.ACTIVE) == 0 then return refuse('no SOS is on') end
        local before = keys(ctx)
        local setting = switch_off(ctx, sos)
        local published = publish(ctx)
        cancelled = {ctx = ctx, sos = sos, enabled = api.load32(sos + B.ENABLED), since = now}
        status.sos_cancels = status.sos_cancels + 1
        note(string.format('SOS cancelled: lobby %s -> %s (privacy setting %s); %s; %s', before, keys(ctx),
            B.PRIVACY_NAMES[setting] or tostring(setting),
            published and 'posted in this frame' or 'the write was refused; posted at the next lobby update',
            restore_use(snap)))
        return true
    end

    function self.cancelled() return cancelled ~= nil end

    local function finish(why, now)
        note(string.format('SOS: no longer kept off after %.0f s (%s)', now - cancelled.since, why))
        cancelled = nil
    end

    -- Once per frame while a cancel is kept (6 direct loads while nothing
    -- changes). The game re-arms in its own update, after the mod's, so a
    -- re-arm is caught in the next frame. The lobby posts every 30 s: unless
    -- a post went out in between (key 8 no longer pending), the pending post
    -- already carries the cancel again.
    function self.keep(now)
        local kept = cancelled
        if not kept then return end
        local ctx = G.context(api, game, cache)
        if ctx ~= kept.ctx or api.load64(game + B.SOS_PTR) ~= kept.sos then
            return finish('new session or mission', now)
        end
        local state = api.load64(game + G.GAME_STATE_PTR)
        if state == 0 or api.load32(state + G.MODE) ~= G.MODE_MISSION then return finish('the mission ended', now) end
        local sos = kept.sos
        local enabled = api.load32(sos + B.ENABLED)
        if enabled == 0 then return finish('no SOS beacon left', now) end
        if enabled > kept.enabled then return finish('a new SOS beacon was called in', now) end
        kept.enabled = enabled
        if api.load8(sos + B.ACTIVE) == 0 then return end
        if api.load32(ctx + G.HOST) ~= api.load32(ctx + G.LOCAL)
            or api.load32(ctx + G.HOST + 4) ~= api.load32(ctx + G.LOCAL + 4) then
            return finish('no longer the host', now)
        end
        local posted = math.floor(api.load32(ctx + G.LOBBY + B.PENDING) / 2 ^ B.KEY_SOS) % 2 == 0
        switch_off(ctx, sos)
        status.sos_rearms = status.sos_rearms + 1
        local text = 'SOS: the game listed it again (a player left or a new host); cancelled again'
        if posted then
            status.sos_leaks = status.sos_leaks + 1
            text = text .. '; the lobby had already posted it, ' .. (publish(ctx) and 'posted again in this frame'
                or 'the write was refused; posted at the next lobby update')
        end
        note(text)
    end

    return self
end

return B
