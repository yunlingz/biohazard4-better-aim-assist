# Better Aim Assist

A Lua mod for REFramework, configured for very strong controller tracking in
Resident Evil 4 Chainsaw Demo. No Node.js, additional DLL, or other mod is needed.

Version 1.5.7 keeps continuous tracking, head stabilization, and the HEAD LOCK
display active when you hold LT / L2 with the right stick centered. RE4 has a
separate `HoldIdle` state; the previous script checked only `IsAiming`, so
continuous correction could stop when the stick came to rest.

It also finishes the last two degrees of a head correction without exponential
lag. Larger acquisitions still use the existing smoothing and turn-rate limit.
This removes a residual reproduced when native camera updates disturb the
previous correction each frame. Screen calibration still uses the current
projection, including resolution and zoom, and resets when the target or lock
changes. Head motion compensation from 1.5.6 remains active.

The right-stick fixes from 1.5.3 cover lock acquisition and
quick direction reversals. A brief center movement seen by the input hooks
also rearms switching even if it falls between target-selector updates.
Holding one direction switches once; center the stick or push firmly in the
opposite direction for another switch. Small/moderate movements, or a push
with no suitable enemy, keep tracking the current target.

Switching refreshes candidates while locked, waits for native visibility checks,
and uses the new enemy's own aim-point list. It includes horizontal neighbors
and matches RE4's camera direction, including inverted-axis settings.

The mod prefers enabled head aim points and visible head samples for the
same enemy, and reduces camera sway while a head point is locked. A head target
still has to pass the game's visibility and target checks. This controls camera
aiming; weapon spread and recoil can still affect the shot.

Continuous lock now corrects camera yaw and pitch on each player-camera update,
using a recently accepted native enemy aim point. It remains active after the
native initial snap ends, and releases when aiming stops or the target is
invalid, obstructed, stale, behind the camera, or outside the configured range.
Larger corrections are smoothed using elapsed time, with a bounded turn rate.
Gameplay camera queries are skipped at startup until a fresh native target exists.

Head motion compensation requires consecutive samples of the same accepted
point. Its lookahead is limited to 35 ms, 10 cm, and 0.75 degrees. Position jumps
and samples more than 50 ms apart discard the previous velocity; stops and
direction changes replace it on the next observation. Screen calibration stays
active during small tracking errors caused by movement. Its separate camera
bias remains limited to two degrees per axis. The short motion lookahead omits
follow-smoothing delay when the final head correction is applied directly.
Fresh native positions are used only when their point identity matches the
selected target; a different native target never substitutes for that enemy.

## Use

1. Start the game. If it is already running, press **F10**, open
   **ScriptRunner**, and click **Reset scripts** to load this update without
   restarting your run. REFramework also loads it automatically on the next launch.
2. **Enable Better Aim Assist. No separate game aim-assist setup is needed.**
   While enabled, the mod overrides all three game options: aim-assist type,
   aim-assist maximum speed, and reticle deceleration. It requests that these
   three menu controls appear disabled and blocks requests to edit them.
3. Point roughly toward a visible enemy and hold your normal aim button
   (**LT / L2**). Keep holding it to follow the enemy's movement, and fire normally.
4. Keep holding aim and push the right stick firmly toward another enemy to
   switch. Keep the push through the brief visibility check, then center the
   stick before switching again in the same direction. A firm opposite push
   also starts a new switch. Release aim to disengage.

This mod **uses the built-in targeting engine and owns its assist settings**.
Your saved game aim-assist type and slider positions do not control the mod
while it is enabled. Its continuous-lock checkbox selects tracking or snap;
the two game sliders use fixed, game-defined default baselines underneath the
mod's strength adjustments. Disabling the mod restores access to your saved
game options. Overrides are suspended during game option save/load operations.
Native visibility checks, screen limits, shields, and target rejection still apply.
An enemy leaving the valid targeting area or becoming obstructed can break lock.
There is no automatic firing.

## Status display

A transparent overlay appears at the **top-right**:

| Status | Meaning |
| --- | --- |
| STANDBY | Waiting for playable gameplay. |
| READY | Enabled; hold aim near an enemy. |
| SEARCHING | Aiming, but no valid target is locked yet. |
| LOCKED | A native aim-assist target is acquired; strong tracking is applied while aiming. |
| HEAD LOCK | Following an acquired head point, including while LT / L2 is held with the right stick centered. |
| WAITING | Native controller activation is inactive; use your controller and check the mod's diagnostics if it persists. |
| DISABLED | The mod is turned off. |
| ERROR | Open the mod settings for the error and diagnostics. |

## Adjust

Press **F10**, then open **Script Generated UI > Better Aim Assist**.

- **Reset to defaults** restores every mod setting and saves immediately:
  Enabled, continuous lock, head preference, head stabilization, HUD, and local
  diagnostic recording are on; strength is 12x, search cone is 1.8x, distance is
  35 m, and HUD background opacity is 0.18. Right-stick switching is on with a
  switching threshold of 0.65.
- **Near lock-on preset** is the default: strength 12, 1.8x search cone, and
  35 m acquisition distance. Strength controls continuous response and turn rate.
- Leave **Continuous lock while holding aim** enabled for moving-target tracking.
- **Right-stick target switching** consumes stick camera movement during a valid
  lock. **Stick switching threshold** controls how firmly you must push before
  a target search starts. Separate gyro input does not request a target switch.
- **Prefer the head** and **Reduce camera sway during head lock** are enabled
  by default. The HUD distinguishes **HEAD LOCK** from a general **LOCKED** target.
- Raise **Tracking strength** toward 20 for a stronger pull. Choose **Softer
  preset** if it feels abrupt.
- Toggle **Show status at top-right**, or set **Status background opacity** to
  **0** for text with no background panel. The overlay never captures input.
- Settings save automatically to `reframework/data/better_aim_assist.json`.

Search area and distance remain subject to the game's other targeting limits.
The strength multiplier describes the mod's response adjustment, not a measured
percentage of accuracy or a guarantee that every enemy will be locked.

## Disable or remove

Uncheck **Enabled** in the mod settings to return to normal aiming. Parameter
changes are scoped to the relevant game calls and restored immediately afterward.

To uninstall, close the game and remove:

- `reframework/autorun/better_aim_assist.lua`
- `reframework/autorun/better_aim_assist/`
- Optionally, `reframework/data/better_aim_assist.json` and
  `reframework/data/better_aim_assist_diagnostics.json` and
  `reframework/data/better_aim_assist_runtime.json`.

## Compatibility and diagnostics

The script checks method signatures and field types before installing its hooks.
The installed demo's TDB 71 API was inspected directly. Other RE4 builds may
need adaptation. The mod stops applying changes if it detects an incompatible
API or a runtime error.

For troubleshooting, use **Diagnostics > Write diagnostics** in the mod menu.
The report is `reframework/data/better_aim_assist_diagnostics.json`; the main
REFramework log is `re2_framework_log.txt` beside the game executable.

For the requested test run, **Record local diagnostics** is enabled. Launch the
game manually, enter gameplay, and hold aim near two visible enemies for about
10-15 seconds. Center the stick, push firmly toward the other enemy, center it,
and try the opposite direction. Then pause without resetting scripts. The mod writes
`reframework/data/better_aim_assist_runtime.json` automatically, once per second,
with bounded recent samples. It retains up to 45 lock samples after you pause,
including the selected joint, target position, and distance from screen center.
API metadata is refreshed automatically once per script load. No uploads or
external services are involved. Recording can be disabled in the mod menu.
The runtime report's `precision` section includes raw/corrected stick values,
input gates, thresholds, lock-session IDs, refresh/wait counts, candidate
positions and direction scores, and per-request rejection reasons. It retains
the last 12 switch outcomes and 64 input/lock/confirmation events. Each request
can retain up to 12 rendered samples plus projected candidate positions, so
the direction chosen can be compared with where enemies appeared on screen.

Handoff counts report selector assignments. Camera confirmation separately
requires the new target to stay active while aim remains held, with camera
angle errors within one degree for at least 0.1 seconds. Render samples show
the tracked point's actual projection relative to screen center; camera
confirmation alone does not establish the user's visible controller result.
The in-game Diagnostics panel shows both counts, the input gate, and the last
outcome. Check that the menu/report says **1.5.7** after loading the update.
The last gameplay capture is retained across menu-only launches in the
`previous_gameplay` field, with its original timestamps. Diagnostic failures now
include their actual error in the runtime report and REFramework log.

Runtime status and lock samples retain both native aim flags (`native_aiming`
and `hold_idle`) alongside the combined `aiming` state. Status also records the
HUD text. `precision.tracking` records the current gate, rejection counts, and
up to 32 transitions, distinguishing released aim, lost targets, stale samples,
inactive native assistance, and disabled camera control.

The `precision.head_alignment` section records target distance, applied and
requested angular correction, and up to 32 recent measurements. `error_px` is
the projection of the last observed head position; `aim_error_px` projects the
camera's temporary aim point. `estimated_render_error_px` estimates the head
position at render time using its velocity and sample age. It is an estimate,
not an independent measurement of the animated head at rendering time.
`centered_frames` and `estimated_centered_frames` count the respective positions
within one pixel of screen center. Up to 16 `outliers` retain estimated offsets
above three pixels so brief misses remain available after the lock settles.
`precise_frames`, `precise_head`, `follow_alpha`, and the input/output angular
errors show when the final head correction is active and any remaining lag.

The nested `motion` data records head speed, sample source, selector/render
delays, refreshed position displacement, lead distance, limits, and rejected
samples. Its latest observation remains available even when screen calibration
is waiting for the camera to settle. Stale samples, large discrepancies, and
unavailable projections are rejected and counted; normal tracking continues.
Up to 16 `motion.refresh_history` entries record selected/native point and
enemy identities, joint names, and refresh rejection reasons. These distinguish
an old native enemy from another point on the same enemy without changing the
selected target. Diagnostic read failures cannot interrupt tracking.
Alignment and motion compensation also work with diagnostic recording disabled.
Target samples include the notice-point offset and camera-object position.

Validation includes offline checks for the three overrides, grayed menu
queries, blocked UI requests, original-value visibility during save/load,
restoration when disabled, complete reset, and capture retention. The native
continuous correction also has checks for moving targets, snap completion,
release conditions, yaw wrap, invalid coordinates, and different frame rates.
Version 1.5.7 passes 117 offline behavioral checks (99 existing checks and 18
aim-state/alignment regressions), plus syntax checks for all four Lua files.
Existing checks cover native cache reuse, visibility completion/cancellation,
lock preservation, strong stick pushes, one switch per gesture, and bounded
diagnostics. A repeated native-camera-update reproducer leaves a 6.1-pixel
offset in 1.5.6 and settles below one pixel in 1.5.7. A separate regression
reproduces correction and HEAD LOCK stopping during `HoldIdle` in 1.5.6; both
remain active in 1.5.7, and releasing aim still disengages. Tests also cover
switch gestures across active/idle aim transitions, head stabilization, native
point mismatch, 30/72/144 fps, short/medium/long distances, zoom and roll, head
bob, stops/reversals, stale samples, position jumps, correction limits, and
disabled recording.
These checks use the captured demo API and mocked gameplay objects. Gameplay
feedback confirms improved alignment through 1.5.6, with remaining visible
offsets and HEAD LOCK disappearing when the right stick rests. Version 1.5.7
addresses those reproduced failure modes and still needs an in-game retest.

API references: [REFramework scripting documentation](https://cursey.github.io/reframework-book/)
and the local game's reflected type metadata.
