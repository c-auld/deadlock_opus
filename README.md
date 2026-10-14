# Zombie Escape (Godot 4.7 prototype)

Small PS1-style first-person survival horror in the classic Resident Evil mould:
explore three dim rooms, scrounge scarce ammo, decide which zombies are worth a
bullet, find the Exit Keycard and get out.

Run: open the folder in Godot 4.7 and press F5, or
`/Applications/Godot.app/Contents/MacOS/Godot --path .`

## Controls
| Key | Action |
|---|---|
| WASD / arrows, mouse | move, look |
| Shift | run (limited stamina) |
| Left mouse | fire handgun |
| R | reload (also restart after win/death) |
| Tab or I | items (pauses the game) — Up/Down select, Enter use, Tab/Esc close |
| E | pick up / use door / read terminal |
| F | flashlight |

## Design
- **Handgun**: 8-round magazine, starts with 6 loaded and none spare. 1.4s reload, 0.3s between shots.
  Body shot = 1 damage, headshot = 2. Muzzle flash, recoil, blood/dust puffs, gunshot noise.
- **Zombie model**: built in code from faceted 6-sided limbs (no imported assets): hunched spine,
  separate upper/lower arms and legs with elbows and knees, clawed hands, elongated skull with dark
  sockets and pin-prick glowing eyes, hanging jaw with teeth, torn shirt, exposed belly, wounds.
  Each zombie randomises which arm reaches and which leg drags, plus slight size variation.
  Animated limp, chattering jaw, forward lunge on attack, fall-back on death.
- **Zombies** (`scripts/zombie.gd`, 5 HP): idle until they see you (9m, in front of them) or you get
  within 3m. Gunshots within 14m draw them to where you fired. They shamble at ~1.3 m/s (you walk
  2.6, run 4.4), wind up and hit for 25 at arm's length, stagger when shot, search where they last
  saw you for ~6s and then give up. No speed ramp, no endless chase.
- **Health**: 100. FINE / CAUTION / DANGER in the HUD and item screen, red flash + camera shake on
  hits, heartbeat louder when hurt or when a hostile zombie is near. 0 = death.
- **Items**: one First Aid Spray (+60), two 5-round ammo boxes, the Exit Keycard. Using ammo from the
  item screen loads the gun; the spray is refused at full health so it can't be wasted.
- **Scarcity**: 16 rounds total vs. 3 zombies × 5 HP. Killing everything needs headshots; avoiding
  the optional closet zombie is the safe play.

## Level walkthrough (spoilers)
1. Corridor A — ammo box tucked behind the crates. A side closet holds a sleeping zombie and,
   behind it, the First Aid Spray (optional risk/reward).
2. Corridor B → STORAGE room — a zombie guards the Exit Keycard on a crate.
3. Taking the keycard makes the "corpse" lying in corridor B get up.
4. Door room — second ammo box in the corner, terminal log hints at the keycard, red keycard reader
   by the EXIT door. E at the door with the keycard opens it; walk out to win.

## Validation
`tests/playtest.gd` drives the real game in a window with injected keyboard and mouse events
(`Input.parse_input_event`), not direct function calls, except where noted:
```
/Applications/Godot.app/Contents/MacOS/Godot --path . --script tests/playtest.gd [-- /dir/for/screenshots/]
```
Result: **56/56 checks pass, 4 consecutive runs.** Waits and key-holds use simulated physics ticks
and re-send held keys each tick, so the test is stable even when its window is in the background.

**Tested (automated, windowed):**
- Movement: W forward, D strafe, Shift sprint faster, walls block.
- Shooting: left click fires and spends a round, muzzle flash, fire-rate limit, empty gun dry-clicks.
- Reloading: R refills from reserve, blocked with no spare ammo, can't fire mid-reload, HUD count.
- Zombie damage: body shot −1, headshot −2, shot alerts zombie, dies at 0 HP, corpse stops blocking.
- Zombie AI: no detection from behind, detection in front at 8m, pursuit ~1.4 m/s, gives up after
  losing the player, attacks at close range for 25.
- Health: red flash, FINE/CAUTION/DANGER, First Aid Spray heals +60 via item screen (keyboard).
- Inventory: Tab and I open, world is paused while open, lists weapon/ammo/heal/key, using ammo loads
  the gun, heal refused at full health, Tab and Esc close.
- Collection: E picks up ammo (+5), First Aid Spray, Exit Keycard; prompt shown; keycard wakes the corpse.
- Locked door: locked prompt, E without key refuses, door physically blocks, keycard opens it.
- Victory: walking out shows YOU ESCAPED. Defeat: health 0 shows YOU DIED. R restarts.

**Shortcuts the test takes:** it teleports the player/zombies into position and sets some values
directly (e.g. health 30, `has_key = true` for the door test, zombie facing) instead of walking the
whole level. A full start-to-finish run through all rooms was not automated.

**Not verified:**
- A human playthrough: real mouse-look feel, aim difficulty at 320×180, whether the ammo budget
  and zombie damage feel fair, and whether the level is readable without the walkthrough.
- Audio: sounds are generated and play without errors, but nobody has listened to the mix.
- Mouse clicks on inventory rows (only keyboard navigation was tested).
- Performance on other machines / other renderers; only this Mac (Godot 4.7.2, Forward+) was run.
