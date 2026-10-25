/* The pack's components, in the order they start and are listed (README.md's table). Each is a VpmComponentDef in
 * src/components/<id>/; the settings file names them by id. */
#include "core/vpm_core.h"

extern const VpmComponentDef vpm_component_better_stratagem_bounce;
extern const VpmComponentDef vpm_component_hellpod_steering_unlocked;
extern const VpmComponentDef vpm_component_reinforcement_beacons_fixed;
extern const VpmComponentDef vpm_component_consistent_vaulting;
extern const VpmComponentDef vpm_component_shallow_water_diving;
extern const VpmComponentDef vpm_component_sentry_aim_retention;
extern const VpmComponentDef vpm_component_enemy_collision_synchronized;
extern const VpmComponentDef vpm_component_controllable_hover_pack;
extern const VpmComponentDef vpm_component_know_your_constellation;
extern const VpmComponentDef vpm_component_armory_preview_cache;
extern const VpmComponentDef vpm_component_arc_thrower_revamped;
extern const VpmComponentDef vpm_component_clickable_scrollbars;
extern const VpmComponentDef vpm_component_ship_station_hotkeys;
extern const VpmComponentDef vpm_component_flame_damage_fixed;
extern const VpmComponentDef vpm_component_mod_options_menu;
extern const VpmComponentDef vpm_component_mod_bindings_menu;
extern const VpmComponentDef vpm_component_better_lobby_management;
extern const VpmComponentDef vpm_component_hellpod_drop_hold;
extern const VpmComponentDef vpm_component_laser_sentry_cooldown;
extern const VpmComponentDef vpm_component_match_your_colors;
extern const VpmComponentDef vpm_component_sticky_grenade_handles;
extern const VpmComponentDef vpm_component_stratagem_hero_expanded;
extern const VpmComponentDef vpm_component_sound_systems_rebalanced;
extern const VpmComponentDef vpm_component_foliage_pass_through;
extern const VpmComponentDef vpm_component_holster_your_shield;

const VpmComponentDef* const vpm_components[] = {
    &vpm_component_better_stratagem_bounce,
    &vpm_component_hellpod_steering_unlocked,
    &vpm_component_reinforcement_beacons_fixed,
    &vpm_component_consistent_vaulting,
    &vpm_component_shallow_water_diving,
    &vpm_component_sentry_aim_retention,
    &vpm_component_enemy_collision_synchronized,
    &vpm_component_controllable_hover_pack,
    &vpm_component_know_your_constellation,
    &vpm_component_armory_preview_cache,
    &vpm_component_arc_thrower_revamped,
    &vpm_component_clickable_scrollbars,
    &vpm_component_ship_station_hotkeys,
    &vpm_component_flame_damage_fixed,
    &vpm_component_mod_options_menu,
    &vpm_component_mod_bindings_menu,
    &vpm_component_better_lobby_management,
    &vpm_component_hellpod_drop_hold,
    &vpm_component_laser_sentry_cooldown,
    &vpm_component_match_your_colors,
    &vpm_component_sticky_grenade_handles,
    &vpm_component_stratagem_hero_expanded,
    &vpm_component_sound_systems_rebalanced,
    &vpm_component_foliage_pass_through,
    &vpm_component_holster_your_shield,
};
const int vpm_component_total = (int)(sizeof vpm_components / sizeof vpm_components[0]);
