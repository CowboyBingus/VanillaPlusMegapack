-- Better Lobby Management: Simplified Chinese (zh-Hans). Made from en.lua by translations.py template.
-- Translate the text on the right of each '='. Keep the keys, {placeholders} and quotes.
-- A line starting with '-- [' is not translated yet: remove the '-- ' and translate it.
-- 'English:' lines are the source text; check reports when it changes.
return {
    mod = 'better_lobby_management',
    language = 'zh-Hans',
    strings = {
        -- Escape-menu button (GAME tab, host of a squad on the ship). Upper case like the
        -- game's own buttons. Long labels scroll inside the button.
        -- English: DISBAND SQUAD
        ['button.disband'] = '解散小队',
        -- Escape-menu button. {name} is the chosen player's name, upper-cased.
        -- English: PROMOTE {name}
        ['button.promote'] = '提升 {name} 为小队长',
        -- Escape-menu button (host in a mission while their SOS Beacon is on).
        -- English: CANCEL SOS
        ['button.cancel_sos'] = '取消SOS信号',
        -- Title of the game's confirm dialog for DISBAND SQUAD.
        -- English: DISBAND SQUAD
        ['dialog.disband.title'] = '解散小队',
        -- Its text. The dialog holds about three lines.
        -- English: Kick every other player. They return to their own ships.
        ['dialog.disband.body'] = '将其他所有玩家移出小队，他们会返回各自的舰船。',
        -- Title of the confirm dialog for PROMOTE. {name}: the player, upper-cased.
        -- English: PROMOTE {name}
        ['dialog.promote.title'] = '提升 {name} 为小队长',
        -- Its text when the host picked the player (by opening their player menu).
        -- {name}: the player's name as written.
        -- English: {name} hosts from their own ship; you and the squad follow.
        ['dialog.promote.body'] = '{name} 将在自己的舰船上担任主办者，你和小队随后跟上。',
        -- Its text when the mod picked the player.
        -- English: {name} hosts from their own ship; you and the squad follow. Picked automatically; select a player's card to change.
        ['dialog.promote.body_automatic'] = '{name} 将在自己的舰船上担任主办者，你和小队随后跟上。已自动选择该玩家；选中其他玩家的名片即可更换。',
        -- Title of the confirm dialog for CANCEL SOS.
        -- English: CANCEL SOS
        ['dialog.cancel_sos.title'] = '取消SOS信号',
        -- Its text for a Public lobby.
        -- English: Stops your SOS, also when a slot opens. Quickplay still finds your Public lobby. You can call in the SOS Beacon again.
        ['dialog.cancel_sos.public'] = '停止发出SOS信号，有空位时也不会重新发出。快速匹配仍能找到你的公开大厅。你可以再次呼叫SOS信标。',
        -- Its text for other lobbies. {privacy} is one of the four texts below.
        -- English: Stops your SOS, also when a slot opens. Your lobby returns to {privacy}. You can call in the SOS Beacon again.
        ['dialog.cancel_sos.private'] = '停止发出SOS信号，有空位时也不会重新发出。你的大厅将恢复为{privacy}。你可以再次呼叫SOS信标。',
        -- The game's privacy settings, as the game names them.
        -- English: Friends Only
        ['privacy.friends'] = '仅限好友',
        -- English: Invite Only
        ['privacy.invite'] = '仅限邀请',
        -- English: Friends and Clan
        ['privacy.clan'] = '好友和战队',
        -- When the setting is not one of the three above.
        -- English: its privacy setting
        ['privacy.other'] = '原本的隐私设置',
        -- A player whose name is unknown. {id} is a number in hexadecimal.
        -- English: player {id}
        ['player.unknown'] = '玩家 {id}',
        -- Chat line sent to the whole squad, as from the host, before DISBAND SQUAD
        -- kicks them. It goes out in the host's language.
        -- English: The host disbanded the squad.
        ['chat.disband'] = '主办者已解散小队。',
        -- Mod Options Menu: the mod's name (upper-cased by the menu).
        -- English: Better Lobby Management
        ['option.mod'] = '更好的大厅管理',
        -- English: Lobby Region
        ['option.region.label'] = '大厅地区',
        -- English: Game Default
        ['option.region.default'] = '游戏默认',
        -- English: My Continent Only
        ['option.region.continent'] = '仅限本大洲',
        -- English: My Continent Only limits the Galactic Map scanner and quickplay to lobbies hosted on your continent (the lowest-latency hosts the game can tell apart). It adds no searches; fewer lobbies may be listed.
        ['option.region.description'] = '“仅限本大洲”让星系地图扫描仪和快速匹配只寻找主办者与你位于同一大洲的大厅（这是游戏能分辨的最低延迟范围）。不会增加搜索次数，但列出的大厅可能变少。',
        -- English: Squad Messages
        ['option.messages.label'] = '小队消息',
        -- English: Before kicking, the squad is told why. PROMOTE shows the game's own "<name> is the new squad leader" line; DISBAND posts a chat message from you.
        ['option.messages.description'] = '移除玩家前，先告知小队原因。提升小队长时显示游戏自带的“某某成为新的小队长”提示；解散小队时以你的名义发送一条聊天消息。',
        -- English: Scanner Recharge (Seconds)
        ['option.scanner.label'] = '扫描仪充能时间（秒）',
        -- English: Seconds the Galactic Map lobby scanner recharges between scans, from 5 to 20. The game currently uses 20; the mod never makes the wait longer than the game's own. Every scan is a lobby search, so a shorter wait searches more often.
        ['option.scanner.description'] = '星系地图大厅扫描仪在两次扫描之间的充能秒数，范围为 5 到 20。游戏目前使用 20 秒；本模组绝不会让等待时间比游戏自身的更长。每次扫描都是一次大厅搜索，因此等待越短，搜索越频繁。',
    },
}
