-- Better Lobby Management: English texts, the source of every translation.
-- Translators: see TRANSLATING.md. The comment above an entry says where the
-- text shows. Keys under option. appear in Mod Options Menu, which upper-cases
-- the mod name and choices. ON and OFF are the game's own words and are not here.
return {
    mod = 'better_lobby_management',
    title = 'Better Lobby Management',
    language = 'en',
    strings = {
        -- Escape-menu button (GAME tab, host of a squad on the ship). Upper case like the
        -- game's own buttons. Long labels scroll inside the button.
        ['button.disband'] = 'DISBAND SQUAD',
        -- Escape-menu button. {name} is the chosen player's name, upper-cased.
        ['button.promote'] = 'PROMOTE {name}',
        -- Escape-menu button (host in a mission while their SOS Beacon is on).
        ['button.cancel_sos'] = 'CANCEL SOS',

        -- Title of the game's confirm dialog for DISBAND SQUAD.
        ['dialog.disband.title'] = 'DISBAND SQUAD',
        -- Its text. The dialog holds about three lines.
        ['dialog.disband.body'] = 'Kick every other player. They return to their own ships.',
        -- Title of the confirm dialog for PROMOTE. {name}: the player, upper-cased.
        ['dialog.promote.title'] = 'PROMOTE {name}',
        -- Its text when the host picked the player (by opening their player menu).
        -- {name}: the player's name as written.
        ['dialog.promote.body'] = '{name} hosts from their own ship; you and the squad follow.',
        -- Its text when the mod picked the player.
        ['dialog.promote.body_automatic'] = '{name} hosts from their own ship; you and the squad follow. Picked automatically; select a player\'s card to change.',
        -- Title of the confirm dialog for CANCEL SOS.
        ['dialog.cancel_sos.title'] = 'CANCEL SOS',
        -- Its text for a Public lobby.
        ['dialog.cancel_sos.public'] = 'Stops your SOS, also when a slot opens. Quickplay still finds your Public lobby. You can call in the SOS Beacon again.',
        -- Its text for other lobbies. {privacy} is one of the four texts below.
        ['dialog.cancel_sos.private'] = 'Stops your SOS, also when a slot opens. Your lobby returns to {privacy}. You can call in the SOS Beacon again.',
        -- The game's privacy settings, as the game names them.
        ['privacy.friends'] = 'Friends Only',
        ['privacy.invite'] = 'Invite Only',
        ['privacy.clan'] = 'Friends and Clan',
        -- When the setting is not one of the three above.
        ['privacy.other'] = 'its privacy setting',
        -- A player whose name is unknown. {id} is a number in hexadecimal.
        ['player.unknown'] = 'player {id}',

        -- Chat line sent to the whole squad, as from the host, before DISBAND SQUAD
        -- kicks them. It goes out in the host's language.
        ['chat.disband'] = 'The host disbanded the squad.',

        -- Mod Options Menu: the mod's name (upper-cased by the menu).
        ['option.mod'] = 'Better Lobby Management',
        ['option.region.label'] = 'Lobby Region',
        ['option.region.default'] = 'Game Default',
        ['option.region.continent'] = 'My Continent Only',
        ['option.region.description'] = 'My Continent Only limits the Galactic Map scanner and quickplay to lobbies hosted on your continent (the lowest-latency hosts the game can tell apart). It adds no searches; fewer lobbies may be listed.',
        ['option.messages.label'] = 'Squad Messages',
        ['option.messages.description'] = 'Before kicking, the squad is told why. PROMOTE shows the game\'s own "<name> is the new squad leader" line; DISBAND posts a chat message from you.',
        ['option.scanner.label'] = 'Scanner Recharge (Seconds)',
        ['option.scanner.description'] = 'Seconds the Galactic Map lobby scanner recharges between scans, from 5 to 20. The game currently uses 20; the mod never makes the wait longer than the game\'s own. Every scan is a lobby search, so a shorter wait searches more often.',
    },
    -- Mod Options Menu's limits, in characters.
    limits = {
        ['option.mod'] = 40, ['option.region.label'] = 64, ['option.messages.label'] = 64,
        ['option.scanner.label'] = 64, ['option.region.default'] = 48, ['option.region.continent'] = 48,
        ['option.region.description'] = 400, ['option.messages.description'] = 400,
        ['option.scanner.description'] = 400,
    },
    -- Rough room in ems for dialog titles (the tool warns when a translation looks
    -- wider). Button labels have none: they scroll.
    widths = {['dialog.disband.title'] = 22, ['dialog.cancel_sos.title'] = 22},
}
