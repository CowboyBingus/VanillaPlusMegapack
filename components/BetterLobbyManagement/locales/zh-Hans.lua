return {
    mod = 'better_lobby_management',
    language = 'zh-Hans',
    strings = {
        -- English: DISBAND SQUAD
        ['button.disband'] = '解散小队',
        -- English: PROMOTE {name}
        ['button.promote'] = '移交队长给 {name}',
        -- English: CANCEL SOS
        ['button.cancel_sos'] = '取消求救信标',
        -- English: DISBAND SQUAD
        ['dialog.disband.title'] = '解散小队',
        -- English: Kick every other player. They return to their own ships.
        ['dialog.disband.body'] = '移除其他所有玩家。他们将返回各自的舰船。',
        -- English: PROMOTE {name}
        ['dialog.promote.title'] = '移交队长给 {name}',
        -- English: {name} hosts from their own ship; you and the squad follow.
        ['dialog.promote.body'] = '{name} 将在自己的舰船上担任房主，你和小队成员将随之转移。',
        -- English: {name} hosts from their own ship; you and the squad follow. Picked automatically; select a player's card to change.
        ['dialog.promote.body_automatic'] = '{name} 将在自己的舰船上担任房主，你和小队成员将随之转移。该玩家由系统自动选定；选择其他玩家的名片即可更换。',
        -- English: CANCEL SOS
        ['dialog.cancel_sos.title'] = '取消求救信标',
        -- English: Stops your SOS, also when a slot opens. Quickplay still finds your Public lobby. You can call in the SOS Beacon again.
        ['dialog.cancel_sos.public'] = '停止求救，之后出现空位也不会恢复。快速加入仍可找到你的公开大厅。你可以再次呼叫求救信标。',
        -- English: Stops your SOS, also when a slot opens. Your lobby returns to {privacy}. You can call in the SOS Beacon again.
        ['dialog.cancel_sos.private'] = '停止求救，之后出现空位也不会恢复。大厅恢复为{privacy}。你可以再次呼叫求救信标。',
        -- English: Friends Only
        ['privacy.friends'] = '仅限好友',
        -- English: Invite Only
        ['privacy.invite'] = '仅限邀请',
        -- English: Friends and Clan
        ['privacy.clan'] = '好友与战团',
        -- English: its privacy setting
        ['privacy.other'] = '原来的隐私设置',
        -- English: player {id}
        ['player.unknown'] = '玩家 {id}',
        -- English: The host disbanded the squad.
        ['chat.disband'] = '房主已解散小队。',
        -- English: Better Lobby Management
        ['option.mod'] = '大厅管理增强',
        -- English: Lobby Region
        ['option.region.label'] = '大厅地区',
        -- English: Game Default
        ['option.region.default'] = '游戏默认',
        -- English: My Continent Only
        ['option.region.continent'] = '仅限本洲',
        -- English: My Continent Only limits the Galactic Map scanner and quickplay to lobbies hosted on your continent (the lowest-latency hosts the game can tell apart). It adds no searches; fewer lobbies may be listed.
        ['option.region.description'] = '“仅限本洲”将银河战争地图扫描与快速加入限制为你所在大洲的大厅（游戏能够区分的低延迟房主）。不会增加搜索次数，但可能减少显示的大厅数量。',
        -- English: Squad Messages
        ['option.messages.label'] = '小队通知',
        -- English: Before kicking, the squad is told why. PROMOTE shows the game's own "<name> is the new squad leader" line; DISBAND posts a chat message from you.
        ['option.messages.description'] = '移除玩家前，通知小队原因。移交队长时显示游戏原有的新队长通知；解散小队时以你的名义发送聊天消息。',
        -- English: Scanner Recharge (Seconds)
        ['option.scanner.label'] = '扫描冷却时间（秒）',
        -- English: Seconds the Galactic Map lobby scanner recharges between scans, from 5 to 20. The game currently uses 20; the mod never makes the wait longer than the game's own. Every scan is a lobby search, so a shorter wait searches more often.
        ['option.scanner.description'] = '银河战争地图大厅扫描的间隔，范围为 5 至 20 秒。游戏当前使用 20 秒；模组不会让等待时间超过游戏原值。每次扫描都会搜索大厅，因此间隔越短，搜索越频繁。',
    },
}
