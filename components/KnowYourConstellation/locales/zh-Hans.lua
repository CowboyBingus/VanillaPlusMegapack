-- Know Your Constellation: Simplified Chinese (zh-Hans). Made from en.lua by translations.py template.
-- Translate the text on the right of each '='. Keep the keys, {placeholders} and quotes.
-- A line starting with '-- [' is not translated yet: remove the '-- ' and translate it.
-- 'English:' lines are the source text; check reports when it changes.
return {
    mod = 'know_your_constellation',
    language = 'zh-Hans',
    strings = {
        -- Panel title above the forecast, in the game's gold. Upper case in English, like the
        -- game's own panel titles.
        -- English: FORECAST // INTEL AND RECON
        ['panel.label'] = '敌情预测 // 情报与侦察',
        -- Last line of the panel.
        -- English: Possible encounters. Spawns are not guaranteed.
        ['panel.footer'] = '可能遭遇的敌人，不保证实际出现。',
        -- Caption above the large enemies, which get a SPAWN RATE meter.
        -- English: LARGE ENEMIES
        ['panel.large'] = '大型敌人',
        -- Caption on the right, above the meters.
        -- English: SPAWN RATE
        ['panel.rate'] = '生成率',
        -- Caption above the list of small and medium enemies.
        -- English: SMALL AND MEDIUM ENEMIES
        ['panel.small'] = '小型和中型敌人',
        -- Caption on the right, above that list.
        -- English: MOST COMMON FIRST
        ['panel.order'] = '越靠前越常见',
        -- Ends a list that had to be cut to fit the screen. {count} is the number of
        -- enemies left out (1 or more).
        -- English: and {count} more
        ['panel.more'] = '另有 {count} 种',
        -- Between two enemy names in the list. Chinese and Japanese usually use an
        -- ideographic comma without spaces.
        -- English: ,
        ['panel.list_separator'] = '、',
        -- Between two constellation names in the headline (one line under the title).
        -- English:  //
        ['headline.separator'] = ' // ',
        -- Headline when the mission has no special constellation.
        -- English: STANDARD FORCES
        ['headline.standard'] = '常规部队',
        -- Constellation names in the headline, upper case in English. Subfactions, strains
        -- and operation modifiers (JET BRIGADE, PREDATOR STRAIN, INCINERATION CORPS...)
        -- use the game's own names: use the ones your game shows. The others are this
        -- mod's names for the game's base constellations.
        -- English: BILE BUGS
        ['title.bile_bugs'] = '胆液虫群',
        -- English: ARMORED BUGS
        ['title.armored_bugs'] = '重甲虫群',
        -- English: HUNTER SWARMS
        ['title.hunter_swarms'] = '追猎虫群',
        -- English: FLYER COMPOSITION
        ['title.flyer_composition'] = '飞空虫群',
        -- English: LIGHT BUGS
        ['title.light_bugs'] = '轻型虫群',
        -- English: BUG NURSERY
        ['title.bug_nursery'] = '虫族繁育窝',
        -- English: BALANCED TERMINIDS
        ['title.balanced_terminids'] = '均衡虫群',
        -- English: PREDATOR STRAIN
        ['title.predator_strain'] = '掠食变种',
        -- English: SPORE BURST STRAIN
        ['title.spore_burst_strain'] = '孢裂变种',
        -- English: RUPTURE STRAIN
        ['title.rupture_strain'] = '爆裂虫族变种',
        -- English: DRAGONROACH ACTIVITY
        ['title.dragonroach_activity'] = '蟑龙活动',
        -- English: ROVING SHRIEKERS
        ['title.roving_shriekers'] = '漫游尖啸虫',
        -- English: ASSAULT FORCES
        ['title.assault_forces'] = '特攻部队',
        -- English: PHALANX FORCES
        ['title.phalanx_forces'] = '方阵部队',
        -- English: ARTILLERY FORCES
        ['title.artillery_forces'] = '炮兵部队',
        -- English: AIR COMPOSITION
        ['title.air_composition'] = '空中部队',
        -- English: ARMORED COLUMN
        ['title.armored_column'] = '装甲纵队',
        -- English: BALANCED AUTOMATONS
        ['title.balanced_automatons'] = '均衡部队',
        -- English: JET BRIGADE
        ['title.jet_brigade'] = '喷气旅',
        -- English: CYBORG LEGION
        ['title.cyborg_legion'] = '生化人军团',
        -- English: GUNSHIP PATROLS
        ['title.gunship_patrols'] = '炮舰巡逻队',
        -- English: INCINERATION CORPS
        ['title.incineration_corps'] = '炽灼部队',
        -- English: HIVE WORLD
        ['title.hive_world'] = '虫窝世界',
        -- English: ILLUMINATE STRAGGLERS
        ['title.illuminate_stragglers'] = '光能者残部',
        -- English: LEVIATHAN BLOCKADE
        ['title.leviathan_blockade'] = '利维坦封锁屏障',
        -- English: APPROPRIATORS
        ['title.appropriators'] = '占领者',
        -- English: INVASION FLEET
        ['title.invasion_fleet'] = '入侵舰队',
        -- English: MINDLESS MASSES
        ['title.mindless_masses'] = '无脑群氓',
        -- English: VOTE SNATCHERS
        ['title.vote_snatchers'] = '窃票者',
        -- English: SEAF SUPPORT
        ['title.seaf_support'] = '超级地球武装部队支援',
        -- English: HORDE
        ['title.horde'] = '群袭',
        -- Enemy names, plural, as on the Helldivers wiki. Use the names players of your
        -- language know (the game's own where it shows one).
        -- English: Scavengers
        ['unit.scavengers'] = '食腐虫',
        -- English: Bile Spitters
        ['unit.bile_spitters'] = '胆液吐沫虫',
        -- English: Pouncers
        ['unit.pouncers'] = '猛扑虫',
        -- English: Warriors
        ['unit.warriors'] = '武斗虫',
        -- English: Hive Guards
        ['unit.hive_guards'] = '虫窝护卫',
        -- English: Bile Warriors
        ['unit.bile_warriors'] = '吐酸武斗虫',
        -- English: Hunters
        ['unit.hunters'] = '追猎虫',
        -- English: Brood Commanders
        ['unit.brood_commanders'] = '虫族指挥官',
        -- English: Chargers
        ['unit.chargers'] = '强袭虫',
        -- English: Charger Behemoths
        ['unit.charger_behemoths'] = '巨兽级强袭虫',
        -- English: Bile Spewers
        ['unit.bile_spewers'] = '胆液喷涌虫',
        -- English: Bile Titans
        ['unit.bile_titans'] = '吐酸泰坦',
        -- English: Stalkers
        ['unit.stalkers'] = '追踪虫',
        -- English: Nursing Spewers
        ['unit.nursing_spewers'] = '抚育喷涌虫',
        -- English: Shriekers
        ['unit.shriekers'] = '尖啸虫',
        -- English: Impalers
        ['unit.impalers'] = '穿刺虫',
        -- English: Alpha Commanders
        ['unit.alpha_commanders'] = '阿尔法指挥官',
        -- English: Alpha Warriors
        ['unit.alpha_warriors'] = '阿尔法武斗虫',
        -- English: Spore Chargers
        ['unit.spore_chargers'] = '孢子强袭虫',
        -- English: Predator Stalkers
        ['unit.predator_stalkers'] = '掠食追踪虫',
        -- English: Hive Lords
        ['unit.hive_lords'] = '霸王虫',
        -- English: Dragonroaches
        ['unit.dragonroaches'] = '蟑龙',
        -- English: Rupture Spewers
        ['unit.rupture_spewers'] = '爆裂喷涌虫',
        -- English: Rupture Warriors
        ['unit.rupture_warriors'] = '爆裂武斗虫',
        -- English: Rupture Chargers
        ['unit.rupture_chargers'] = '爆裂强袭虫',
        -- English: Spore Burst Bile Titans
        ['unit.spore_burst_bile_titans'] = '孢裂吐酸泰坦',
        -- English: Spore Burst Warriors
        ['unit.spore_burst_warriors'] = '孢裂武斗虫',
        -- English: Spore Burst Hunters
        ['unit.spore_burst_hunters'] = '孢裂追猎虫',
        -- English: Spore Burst Scavengers
        ['unit.spore_burst_scavengers'] = '孢裂食腐虫',
        -- English: Predator Hunters
        ['unit.predator_hunters'] = '掠食追猎虫',
        -- English: Troopers
        ['unit.troopers'] = '装甲兵',
        -- English: Marauders
        ['unit.marauders'] = '劫掠者',
        -- English: Brawlers
        ['unit.brawlers'] = '乱斗者',
        -- English: Assault Raiders
        ['unit.assault_raiders'] = '特攻奇袭者',
        -- English: MG Raiders
        ['unit.mg_raiders'] = '机枪奇袭者',
        -- English: Rocket Raiders
        ['unit.rocket_raiders'] = '火箭奇袭者',
        -- English: Commissars
        ['unit.commissars'] = '机械统帅',
        -- English: Berserkers
        ['unit.berserkers'] = '狂暴者',
        -- English: Devastators
        ['unit.devastators'] = '蹂躏者',
        -- English: Heavy Devastators
        ['unit.heavy_devastators'] = '重型蹂躏者',
        -- English: Rocket Devastators
        ['unit.rocket_devastators'] = '火箭蹂躏者',
        -- English: Scout Striders
        ['unit.scout_striders'] = '侦察纵步者',
        -- English: Hulk Scorchers
        ['unit.hulk_scorchers'] = '巨型炙炎者',
        -- English: Hulk Bruisers
        ['unit.hulk_bruisers'] = '巨型碾压者',
        -- English: Annihilator Tanks
        ['unit.annihilator_tanks'] = '湮灭坦克',
        -- English: Shredder Tanks
        ['unit.shredder_tanks'] = '碎裂坦克',
        -- English: Barrager Tanks
        ['unit.barrager_tanks'] = '铁幕坦克',
        -- English: Factory Striders
        ['unit.factory_striders'] = '移动工厂',
        -- English: Hulk Obliterators
        ['unit.hulk_obliterators'] = '巨型抹煞者',
        -- English: Gunships
        ['unit.gunships'] = '炮舰',
        -- English: Reinforced Scout Striders
        ['unit.reinforced_scout_striders'] = '强化侦察纵步者',
        -- English: Conflagration Devastators
        ['unit.conflagration_devastators'] = '烈火蹂躏者',
        -- English: Pyro Troopers
        ['unit.pyro_troopers'] = '炙焰装甲兵',
        -- English: Jet Brigade Devastators
        ['unit.jet_brigade_devastators'] = '喷气旅蹂躏者',
        -- English: War Striders
        ['unit.war_striders'] = '战争纵步者',
        -- English: Vox Engines
        ['unit.vox_engines'] = '噪轰引擎',
        -- English: Agitators
        ['unit.agitators'] = '惑乱者',
        -- English: Radicals
        ['unit.radicals'] = '激进先锋',
        -- English: Jet Brigade Troopers
        ['unit.jet_brigade_troopers'] = '喷气旅装甲兵',
        -- English: Jet Brigade MG Raiders
        ['unit.jet_brigade_mg_raiders'] = '喷气旅机枪装甲兵',
        -- English: Jet Brigade Commissars
        ['unit.jet_brigade_commissars'] = '喷气旅机械统帅',
        -- English: Incendiary Rocket Raiders
        ['unit.incendiary_rocket_raiders'] = '燃烧火箭奇袭者',
        -- English: Hulk Firebombers
        ['unit.hulk_firebombers'] = '巨型烈焰轰炸者',
        -- English: Incendiary MG Devastators
        ['unit.incendiary_mg_devastators'] = '燃烧机枪蹂躏者',
        -- English: Jet Brigade Hulk Scorchers
        ['unit.jet_brigade_hulk_scorchers'] = '喷气旅巨型炙炎者',
        -- English: Jet Brigade Hulk Bruisers
        ['unit.jet_brigade_hulk_bruisers'] = '喷气旅巨型碾压者',
        -- English: Elevated Overseers
        ['unit.elevated_overseers'] = '崇高监视者',
        -- English: Harvesters
        ['unit.harvesters'] = '猎杀器',
        -- English: Watchers
        ['unit.watchers'] = '守望者',
        -- English: Overseers
        ['unit.overseers'] = '监视者',
        -- English: Voteless
        ['unit.voteless'] = '无票者',
        -- English: Stingrays
        ['unit.stingrays'] = '刺魟',
        -- English: Fleshmobs
        ['unit.fleshmobs'] = '肉瘤体',
        -- English: Leviathans
        ['unit.leviathans'] = '利维坦',
        -- English: Crescent Overseers
        ['unit.crescent_overseers'] = '新月监视者',
        -- English: Veracitors
        ['unit.veracitors'] = '证真者',
        -- English: Gatekeepers
        ['unit.gatekeepers'] = '御门者',
        -- English: Obtruders
        ['unit.obtruders'] = '突入者',
        -- English: Crushers
        ['unit.crushers'] = '粉碎者',
        -- English: Wretches
        ['unit.wretches'] = '悲怜体',
    },
}
