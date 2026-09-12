# Better Aim Assist: development context

Last consolidated: **2026-09-13**. This is the compact development handoff for
maintainers, Codex, and Claude Code. It combines the session's requirements,
debugging history, current source, and reviewed diagnostics. It is not a verbatim
transcript. Development began before Git, so some early revision boundaries and
temporary test artifacts are unavailable; do not invent missing release details.

## Current baseline

- Saved script: **1.5.7**. Last offline-validated version: **1.5.7**.
  Last version positively retested by the user and reviewed through logs: **1.5.7**.
- Tested environment: **Resident Evil 4 Chainsaw Demo, REFramework, TDB 71**,
  Windows, controller input. Accepting the `re4` game identifier in code does not
  establish compatibility with every retail build.
- The user reported that everything worked after the final script reload. The
  previous L2-only/HUD failure and persistent small head-alignment residual were
  reproduced offline and fixed. No further gameplay fix is currently pending.
- Subsequent work established Git, renamed the README, and added the supplied
  gameplay screenshot. Those documentation changes do not change script version.
- Read [README.md](README.md) for player instructions. Current source and new user
  instructions take precedence if they differ from historical notes here.

## Required behavior

1. Holding **LT/L2** continuously follows an accepted enemy target, preferably its
   head, including when the right stick is centered. The user still controls firing.
2. A **strong, deliberate right-stick push** requests a suitable enemy in that
   direction while keeping lock-on. Small/moderate movement and a search with no
   suitable enemy preserve the current valid target. Native invalidation can still
   end a lock; never retain an obstructed or invalid enemy indefinitely.
3. One held gesture requests one switch. Returning toward center or making a
   strong reversal rearms it. A push already present when lock is acquired counts;
   a brief center crossing between selector updates must not be discarded.
4. `HEAD LOCK` must describe L2-only tracking as well as active stick movement.
   Releasing aim disengages. Diagnostics must distinguish held-idle aim from release.
5. Head alignment must account for distance and movement. Use the game's accepted
   aim points and visibility checks; do not select arbitrary world-space heads or
   substitute another enemy's point. Camera lock does not eliminate spread/recoil.
6. Enabling the mod owns all three native controller-assist options at runtime.
   Saved game preferences must remain intact and become effective when disabled.

Defaults: enabled, continuous follow, head preference, head stabilization, HUD,
stick switching, and local recording are on; strength **12**, search area **1.8**,
range **35 m**, stick threshold **0.65**, HUD background opacity **0.18**.

## Development history and why the implementation changed

| Stage | Feedback or finding | Result and lesson |
| --- | --- | --- |
| Baseline through 1.5.0 | Strong controller assistance needed continuous tracking, head preference, option ownership, status feedback, and diagnostics. An early stick implementation allowed a manual turn and recollected a target afterward. | Native selector/camera hooks became the foundation. The manual-release approach did not meet the user's intended target-switch behavior. A local pre-switch backup identifies itself as 1.5.0. |
| 1.5.1 | The user clarified that switching should require sufficient stick movement and a suitable enemy; otherwise attraction should remain. Full left/right pushes still appeared ineffective, even after restarting the game. | Restarting alone did not resolve the behavior. Investigate input, native selection, and camera tracking separately. |
| 1.5.2 | Logs showed target changes, but the user explicitly reported that neither direction visibly switched. They requested more detailed diagnostics. | A selector assignment was insufficient evidence. Native point-list reuse, candidate refresh/visibility, direction mapping, and gesture handling needed attention; diagnostics gained input, candidate, lock, and render evidence. |
| 1.5.3 to 1.5.4 | The corrected switching behavior worked in user retests. The user explicitly requested the 1.5.4 version label. | Preserve the visibility-aware handoff, the new enemy's own points, acquisition-frame pushes, brief center crossings, and strong reversals. The surviving 1.5.3 harness result records 99 checks and four syntax checks. |
| After 1.5.4, through 1.5.6 | At long range the crosshair was visibly off the head even without firing; nearer targets were better. Later tests improved but still missed moving heads and showed small pixel offsets. | Screen-projection calibration addressed alignment across distance/zoom, followed by bounded head-motion compensation in 1.5.6. This was a camera-alignment problem, not merely shots missing despite a centered crosshair. Exact intermediate release boundaries are not fully retained. |
| 1.5.7: held-idle aim | Screenshots showed `READY`; the user explained that `HEAD LOCK` appeared only while holding L2 and moving the right stick, although attraction remained with L2 alone. | RE4 separates `IsAiming` from `IsHoldIdle`. A shared helper accepts either, keeping continuous correction and HUD state active with a resting stick. Both API methods were verified against demo metadata. |
| 1.5.7: remaining alignment residual | Native camera updates could disturb the prior correction every frame, leaving a persistent residual under exponential follow. | Within two degrees per axis of a valid head target, use alpha 1 while retaining the turn-rate limit. Larger acquisitions remain smoothed. Omit follow-smoothing delay from motion lookahead in this mode. The offline disturbance reproducer improved from about 6.144 px to below 1 px. |
| Final retest and repository setup | The user reloaded 1.5.7 and reported everything working. A log review supported the improvement. They chose to maintain the live installation with Git for future sharing. | Retain 1.5.7 as the validated baseline. The repository is named `re4-better-aim-assist`; the README and screenshot now document the mod. |

## File map and execution flow

| Path | Responsibility |
| --- | --- |
| `reframework/autorun/better_aim_assist.lua` | Entry point, version/defaults, settings, API validation, scoped native parameter changes, head preference, input hooks, shared aim-state helper, HUD, and runtime recording. |
| `reframework/autorun/better_aim_assist/precision.lua` | Accepted-target snapshots, stick gestures, candidate ranking/handoff, continuous camera correction, motion compensation, screen calibration, and switching/alignment diagnostics. |
| `reframework/autorun/better_aim_assist/game_options.lua` | Runtime ownership of native options, disabled menu controls, blocked UI changes, save/load suspension, and restoration. |
| `reframework/autorun/better_aim_assist/diagnostics.lua` | Reflected API/type metadata report. Use this to check the installed build's actual methods and field types. |
| `README.md`, `screenshots/head-lock.png` | Player-facing instructions and the user-supplied gameplay image. |
| `.gitignore`, `.gitattributes` | An explicit file allowlist inside the game installation, plus consistent text line endings. |

The entry point resolves its three modules during script loading, validates the
native API, and installs hooks. Selector updates provide accepted target snapshots
and process switch requests. The player-camera update hook applies continuous
correction. Frame callbacks calibrate screen alignment, draw the HUD, and record
diagnostics. The current ready log reports **16 hooks** on TDB 71.

## Implementation decisions to preserve

### Input, selection, and handoff

- Capture stick input before consuming its normal camera rotation during a valid
  lock. Gyro is a separate argument and does not request target switches.
- Input samples expire after 0.1 s. The gesture center threshold is
  `stick_threshold * 0.55`; keep the input-hook latch as well as selector state.
- Match native axis conventions: normal yaw uses `-raw_x`, reversed yaw uses
  `raw_x`; normal pitch uses `raw_y`, reversed pitch uses `-raw_y`.
- `checkCollectTarget` can return false while a target is valid. Call
  `collectTarget()` to refresh candidates without deliberately releasing it.
  Do not replace this with `requestCollectTarget()`, which clears the target.
- Respect asynchronous visibility checks. Wait for `TargetCastRayList` to clear
  before selecting; the current wait timeout is 0.6 s. Preserve cancellation and
  native-reselection handling while a request is pending.
- Deduplicate candidates by enemy identity, prefer its validated head sample, and
  rank the visibility-tested `CastRayEndPosition`. An enemy's root position can be
  near its feet and produces wrong directional rankings. Ranking uses angular
  separation and directional agreement, not a requirement that enemies differ
  both horizontally and vertically. Forward separation must exceed one degree
  and be at least half the total angular separation.
- Native `updateNoticePointList` can reuse the old list when two enemies share
  point names. For a handoff, fetch the new enemy's enabled aim-point list through
  its `NoticePointController`, then sort and validate it. Verify ownership,
  enabled state, the visibility-validated head/body classification, distance,
  screen position, and that the selector actually accepted the assignment.
- On handoff failure, restore the old target, exact point list, point, and
  `AssistPointCastRay`. Do not call the problematic cache updater during rollback.

### Tracking, precision, and head identity

- The shared `aim_held` result is `get_IsAiming() OR get_IsHoldIdle()`. Keep both
  native flags in diagnostics; do not regress to `IsAiming` alone.
- Head classification matches a `head` token in joint names such as `Head`,
  `Head_00`, and `c_head`; neck/spine are not heads. Head-sample preference must
  not silently jump between different enemies.
- `M.target` rejects missing/stale targets, released aim, inactive native assist,
  and disabled camera control. A target snapshot older than 0.1 s is invalid.
  Camera correction also checks coordinates, range, and whether it is behind the
  camera. In the title menu, reject through cached target state before calling
  gameplay-dependent camera getters.
- Angles are radians. Apply corrections through `setYawPitch` and `applyYawPitch`
  after `onCameraUpdate`. Bound delta time to 0.05 s and retain the angular-speed
  limit `(180 + strength * 45)` degrees/s, including in precise-head mode.
- Normal follow uses `1 - exp(-strength * 12 * dt)`. Near an accepted head,
  including the calibration bias, errors within two degrees on both axes use
  alpha 1. Increasing smoothing strength alone did not solve the disturbance
  reproducer; keep the bounded final correction.
- Screen feedback uses the current projection, including resolution, zoom, and
  camera roll. Keep the per-axis bias bounded to two degrees and discard stale
  feedback or feedback belonging to a different camera, enemy, point, or joint.
  Do not replace this with a hard-coded screen-pixel or world-space offset.
- Head-motion compensation uses successive observations of the same accepted
  point. Its horizon is at most 35 ms and its displacement at most the smaller
  of 10 cm and 0.75 degrees at the target distance. Gaps over 50 ms and position
  jumps reset velocity; stops and reversals replace it on the next observation.
- Refresh a native head position only when its point identity matches the
  selected point. Record mismatches; never follow another enemy's native point.
  Keep motion/calibration functional when diagnostic recording is disabled.

### Native options and restoration

The controlled options are `ControllerAimAssist`, `ControllerAimAssistMaxSpeed`,
and `CameraAimAssistLevel`. Continuous mode requests native High assist; snap
mode requests Low. The two slider baselines come from the game's defaults, not
the user's saved sliders. Override reads and menu editability, and block UI
`requestSetCurrentOptionValue` calls while active. Leave the internal setter
available to native loading. Suspend overrides during save/load with thread-local
nesting. Other parameter patches are scoped to the relevant native call and
restored afterward. Disabling must restore normal access to the saved settings.

## Diagnostics: what the evidence does and does not mean

Local files are deliberately excluded from Git:

| File | Purpose |
| --- | --- |
| `reframework/data/better_aim_assist.json` | User's saved mod settings. |
| `reframework/data/better_aim_assist_diagnostics.json` | Reflected demo API and diagnostic status. |
| `reframework/data/better_aim_assist_runtime.json` | Versioned, timestamped gameplay/status snapshots and bounded histories. |
| `re2_framework_log.txt` | REFramework startup, Lua errors, graphics messages, and reload evidence. |

The runtime JSON root contains `version`, `session_started`, `updated_at`,
`status`, `samples`, `lock_samples`, and `previous_gameplay`. Precision lives at
**`status.precision`**, not at the root. For a retained older gameplay capture,
use its own version, timestamps, and nested status. A later write time does not
mean that gameplay or head tracking continued until that time.

Recording is normally once per second, with up to 45 lock samples, 12 switch
outcomes, 64 input/lock/confirmation events, 32 tracking transitions, 32 alignment
measurements, 16 alignment outliers, and 16 point-refresh comparisons. Switch
requests can also retain 12 screen samples. Ring buffers are partial history;
aggregate counts do not imply that every original event remains inspectable.

- `target_switches` counts selector handoffs. `confirmed_switches` additionally
  requires the new target to remain active, at least three camera frames, and
  errors within one degree for at least 0.1 s. A counter increase alone does not
  prove that the user saw the intended enemy selected.
- An unconfirmed handoff is not automatically a failed handoff. In the reviewed
  retained example, a brief selector gap interrupted confirmation after 95 ms,
  but screen samples showed the requested enemy centered. Reasons for older
  entries that have rolled out cannot be reconstructed from totals alone.
- `error_px` projects the last observed head snapshot. `aim_error_px` projects
  the temporary camera aim point. `estimated_render_error_px` extrapolates the
  head using velocity and age. None independently measures the actual animated
  head at render time. Combine these with the user's visual test/screenshot.
- Separate steady tracking from acquisition, switches, brief native target gaps,
  aim release, and stale snapshots. A retained released-aim sample is not proof
  of a tracking failure. `READY` after releasing aim is expected.
- Inspect nested motion/refresh rejection reasons and selected/native enemy,
  point, and joint identities. A rejected refresh is not itself a Lua exception.
- `steady_calls` remained zero in the captures below. Offline coverage exists,
  but these gameplay logs do not independently validate sway suppression.
- A `Present failed: 87a0001` at local 01:46:57 was followed by successful renderer
  reinitialization. That recovered graphics event was distinct from Lua failures;
  no aim-assist exception was found in that reviewed session.

## Validation record

### Offline checks already performed

The prior 1.5.7 validation passed **117 behavioral checks**: 99 existing checks
plus 18 aim-state/alignment regressions, and syntax checks for all four Lua files.
Mocks used the captured demo API. Coverage included option ownership/save-load
restoration, reset and capture retention, native point-cache reuse, visibility
completion/cancellation, one-switch-per-gesture behavior, held-idle transitions,
moving targets, release/invalid-target gates, yaw wrap, bounded diagnostics,
30/72/144 fps, short/medium/long ranges, zoom/roll, head bob, stops/reversals,
stale samples, point mismatch, position jumps, and disabled recording.

Two useful before/after reproducers: 1.5.6 stopped correction/HUD tracking during
`HoldIdle`; 1.5.7 keeps both active and still releases correctly. Repeated native
camera disturbance left about **6.144 px** residual in 1.5.6 and settled below
one pixel in 1.5.7. Switching code paths were compared and retained while fixing
aim state and final correction. These checks were not rerun for this doc update.

**Reproducibility limit:** there is no checked-in test harness. On the original
machine, `%TEMP%/re4-stick-switch-IrJvNW/` still contains the older `validate.mjs`,
`test.lua`, `switch-tests.lua`, and a 99-check result labeled 1.5.3. It depends on
the Lua/WASM package in `%TEMP%/re4-aim-assist-b2536b91c5614a5492a5e88a179300a8/`.
The runner contains old version strings and machine-specific paths; inspect and
adapt it before use. Its presence is not a reproducible 1.5.7 test command for a
fresh clone. The temporary 18-regression project was cleaned up after validation.
Do not run old game-click/reload helpers in the other temporary directory.

### Gameplay evidence

The user explicitly reported that 1.5.7 worked after reloading. The detailed log
review covered a session starting **2026-09-12T17:45:45Z** (September 13 in the
user's Asia/Taipei timezone). Later gameplay extended the same session; the
second column below is a read-only snapshot taken while preparing this handoff.

| Evidence | Original reviewed segment, last alignment 17:46:48Z | Later snapshot, last alignment 18:06:42Z |
| --- | ---: | ---: |
| Accepted targets / camera corrections | 3,946 / 3,946 | 4,526 / 4,526 |
| Switch requests / handoffs | 47 / 42 | 48 / 43 |
| Camera-confirmed / unconfirmed handoffs | 32 / 10 | 33 / 10 |
| Handoff failures / searches without a directional target | 0 / 5 | 0 / 5 |
| Fresh retained L2-only head-lock samples | 32 | 34 |
| Measured alignment frames / estimated outliers above 3 px | 3,919 / 90 | 4,498 / 92 |
| Final distance / projected observed-head offset | 32.095 m / 0.408 px | 32.465 m / 0.500 px |

The original review found all 16 retained outliers within 50 ms of a switch or
target reacquisition; its last 14 settled history samples were below one pixel
(maximum about 0.61 px). This does not classify every outlier in the aggregate.
The later snapshot had no recorded aim-assist error fields, and its last switch
was camera-confirmed. Its file `updated_at` was 18:11:43Z, after tracking ended.
These results support the user's improvement report, not perfect alignment in
every frame or independent confirmation of all unconfirmed switches.

## Working on this repository

- The repository root is the **live game installation**, beside `re4demo.exe`.
  This preserves the installable `reframework/autorun/` layout and the root README.
  Keep `.gitignore` as an explicit allowlist: source, documentation, and intended
  screenshots only. Add rules for new project files; do not force-add game data,
  binaries, personal settings, API dumps, runtime logs, or temporary dependencies.
- Git began after the gameplay fixes. Existing early commits include `f6ee063`
  (`init`) and `93d6b4b` (`rename md`). The initially suggested external project
  folder was rejected. The latest inspected branch was `master` with an existing
  `origin/master`; inspect current state rather than recreating Git, changing
  branches, or assuming the original `main` initialization is still current.
- This PowerShell session did not resolve `git` through PATH. The installed Git
  executable was `C:\Program Files\Git\cmd\git.exe`; use `git` normally if the
  environment resolves it, or invoke that executable with PowerShell's `&`.
- Inspect `git status` and existing changes before editing. The screenshot was
  added as a separate user request; preserve it and other pending user work.
  Use explicit paths when staging. Local editing is not a request to publish.
- Keep conversation and project documentation in **English**. Work with one
  agent unless the user explicitly requests delegation. During extended work,
  provide brief progress updates about every 20-30 seconds and use resumable
  commands with short yields rather than hiding long waits.
- The user operates gameplay and reloads manually. Do not automatically launch,
  stop, restart, reload, or control the game. A script update can be loaded through
  **F10 > ScriptRunner > Reset scripts**; verify the loaded version before testing.
- Use PowerShell/native tools when sufficient. Temporary helpers should use
  **Node.js, not Python**, in a unique OS temporary directory, with local
  dependencies and cleanup of only the artifacts created for the current task.
  Node is a development tool, not a dependency of the installed Lua mod.

### Practical change-and-test loop

1. Read this context, inspect the relevant source and current Git changes, and
   check the loaded/captured version and timestamps before diagnosing a report.
2. Reproduce the specific failure where possible. Confirm native method signatures
   against the installed build's reflected metadata; do not guess API names.
3. Make a focused change. For behavior changes, update the script version and
   relevant documentation together; keep the saved and gameplay-validated
   versions distinct until a new retest actually passes.
4. Check all changed Lua syntax and run the relevant available behavioral checks.
   Do not claim the historic 117-check run validates a new revision. Documentation
   edits need link/file checks, Git inclusion checks, and `git diff --check`.
5. For an input/alignment change, have the user reload and test: hold L2 with a
   centered stick; try weak/strong pushes, both directions, holding one direction,
   centering/reversing, and a direction without a suitable enemy; release aim;
   check close/far and moving heads. Then pause without resetting scripts so the
   capture remains available. Test option restoration when that code changes.
6. Review gates, candidate/point identities, handoffs, camera confirmation, fresh
   screen samples, and errors together. Ask targeted questions only when needed
   to distinguish what logs measure from what the user actually sees.
7. Update this handoff with the new version, reason for the change, evidence,
   limitations, and any pending work. Keep it compact and preserve lessons that
   prevent regressions. No further gameplay change is authorized merely by a
   historical limitation or an old failed test recorded here.

Reference: [REFramework scripting documentation](https://cursey.github.io/reframework-book/)
and the installed game's reflected type metadata. Read metadata reports locally;
the repository does not bundle the game's reflected data or executable files.
