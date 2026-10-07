# BORG - Booster Operation, Recovery and Guidance

`Falcon9_lib` is the legacy directory name for BORG's kOS flight scripts. BORG
is a work-in-progress, general-purpose reusable-booster system. It is
hardware-aware after the player assigns engine-role tags, uses FAR data to
build an aerodynamic model, and supports fixed landing sites, waypoints,
moving vessels, and ASDS-style recovery.

The ascent and recovery programs are deliberately independent. The included
ascent program is a small open-loop launch example; the recovery program can
follow a booster launched by MechJeb, PEGAS, another kOS program, or a manual
pilot. The ascent system is responsible for leaving the first stage with a
recoverable state and enough propellant.

## Requirements

- kOS
- Ferram Aerospace Research (FAR)
- Chris GNC Suite (the current project targets v1.0.0 or later)
- the `kOS-LTR` addon from `src/kOS-LTR`
- one kOS CPU on the upper stage and one on the reusable booster
- optional: StarshipExpansionProject, needed only by profiles that enable SEP
  engine-mode control (`engineModeControl`)

LTR and FAR are required by the recovery executive. LTR must appear in the
kOS addon list as `LTR` (`ADDONS:HASADDON("LTR")` / `ADDONS:LTR`).

All distances are metres, speeds are m/s, masses are tonnes as reported by
kOS, times are seconds, and angles are degrees unless noted otherwise.

## Boot files and call chain

Each boot file owns a parameter lexicon and calls an executive. Do not put
vehicle parameters in a shared global parameter file.

| Boot file | CPU | Purpose |
|---|---|---|
| `boot/f9ascent.ks` | upper stage | Generic open-loop ascent example. |
| `boot/f9ascent_rp1.ks` | upper stage | Falcon 9 RP-1 profile. |
| `boot/f9ascent_rp1_asds.ks` | upper stage | Falcon 9 RP-1 ASDS profile. |
| `boot/f9recovery.ks` | booster | Generic recovery profile. |
| `boot/f9recovery_rp1.ks` | booster | Falcon 9 RP-1 recovery profile. |
| `boot/f9recovery_rp1_asds.ks` | booster | Falcon 9 RP-1 ASDS recovery profile. |
| `boot/starshipascent.ks` | upper stage | Starship ascent profile with SEP engine-mode control. |
| `boot/starshiprecovery.ks` | booster | Starship recovery profile with a boostback pitch offset and SEP engine-mode control. |
| `boot/zq3ascent.ks` / `zq3ascent_asds.ks` | upper stage | ZhuQue-3 ascent profiles. |
| `boot/zq3recovery.ks` / `zq3recovery_asds.ks` | booster | ZhuQue-3 recovery profiles. |

The normal execution chain is:

```text
ascent boot -> gof9u.ks -> f9utility.ks + f9launch.ks -> f9_launch
recovery boot -> gof9d.ks -> f9utility.ks
                            -> optional f9boostback.ks
                            -> f9entryburn.ks
                            -> f9landingburn.ks
```

The ascent boot waits for Action Group 10 while the vessel is prelaunch.
Pressing `0` starts `gof9u.ks`. The launch routine starts the tagged liftoff
engines, holds vertical, performs its programmed pitch-over, cuts off at
`mecoMass`, stages the first stage, ignites the upper stage, and waits for a
second Action Group 10 change before releasing its steering and throttle
locks.

The recovery boot can start before launch. `gof9d.ks` validates the recovery
lexicon and LTR, initializes the configured target, waits until the vessel
mass is below `boostBackMass`, then waits `boostBackDelay`. LTR is initialized
only after separation so FAR samples the booster rather than the complete
launch stack.

## Recovery target modes

`landingSiteUse` is explicit; no active waypoint or KSP target is consulted
implicitly.

### Fixed geoposition

```ks
"landingSiteUse", "geo",
"landingSiteGeo", LIST(longitude, latitude),
```

Terrain height at the coordinates is used as the raw target altitude.

### Waypoint

```ks
"landingSiteUse", "waypoint",
"landingSiteWaypoint", "ASDS-ZhuQue3-Cape",
```

The waypoint's geoposition and altitude are used. The name must match exactly.

### Vessel

```ks
"landingSiteUse", "vessel",
"landingSiteVessel", "drone",
```

The vessel's position and altitude are refreshed during guidance, so a moving
drone ship can be followed. The vessel name must match exactly.

### Automatic natural-impact target (`none`)

```ks
"landingSiteUse", "none",
```

After separation and `boostBackDelay`, BORG runs an LTR prediction at a
temporary sea-level target, samples the terrain/ocean altitude at that impact,
then repeats the prediction. The resulting geoposition is written into
`targetContext` and is treated as a fixed target for the rest of the flight.
This mode is intended for surveying where to place an ASDS or a downrange
landing pad. For a survey flight, use:

```ks
"landingSiteUse", "none",
"enableBoostBack", FALSE,
```

Read the predicted latitude and longitude from the recovery display, place the
ship or pad there, create a waypoint (or use the vessel name), and update the
recovery boot file for the operational flight.

`altitudeOffset` is added to the selected waypoint, vessel, or geoposition
altitude. It is also applied to an automatically resolved target.

## Engine-role tags

The engine search is substring-based: an engine belongs to a group when its
kOS tag contains the configured string. A combined tag can therefore assign
several roles to one engine. Keep configured strings from unintentionally
containing one another.

The standard Falcon 9 example uses labels like these:

| Role | Example tag |
|---|---|
| All liftoff engines | `liftoff_` |
| Boostback engines | `liftoff_boostback_entry_` |
| Entry engines | `liftoff_boostback_entry_` |
| Final landing engines | `liftoff_boostback_entry_landing2_` |

The recovery lexicon separates the role selectors:

```ks
"boostbackEngineTag", "boostback_",
"entryEngineTag", "entry_",
"landingDecEngineTag", "landing1_",
"landingEngineTag", "landing2_",
```

`landingDecEngineTag` selects the initial landing-deceleration set and
`landingEngineTag` selects the final landing set. If no deceleration engines
match, the final landing set is used as the fallback. When the two sets
overlap, an engine matching the final landing tag is not shut down during the
deceleration-to-landing transition.

When a boot lexicon enables `engineModeControl` (see the next section), the
recovery profile ignores these four selectors: the SEP engine-mode switch
selects the thrust group instead, and `engineModeEngineTag` is used only to
read the thrust axis. The ascent profile still uses `liftoffEngineTag`.

## SEP engine-mode control (Starship)

StarshipExpansionProject puts four engine groups on one booster part and owns
their ignition and shutdown through `ModuleSEPEngineSwitch`: selecting a mode
lights the selected group and shuts the other groups down. When a boot lexicon
contains `"engineModeControl", TRUE` the Starship profiles use this switch
instead of the engine-role tags and instead of `activate_engines` /
`deactivate_engines`. The tag path is unchanged for every other profile.

Mode indices are displayed by the game and are configured in the boot lexicon.
Measured on this install with `sepmodeprobe.ks` (display name from the `Mode`
field, thrust from `SHIP:MAXTHRUST` at throttle 1, part `SEP.26.BOOSTER.CLUSTER`
with its 613 kN engine):

| Index | Mode | Cluster thrust | Engines lit | Notes |
|---:|---|---:|---:|---|
| 0 | Outer Twenty | 20229 kN | 33 | Liftoff state; the switch's default |
| 1 | Middle Eight | 7969 kN | 13 | Post-separation mode; landing deceleration group |
| 2 | Middle Two | 3065 kN | 5 | Pre-separation mode |
| 3 | Center Three | 1839 kN | 3 | Terminal landing mode |

Each mode keeps the named ring and everything inside it lit, so only a
full 33-engine cluster gives 20229 kN. `Next` / `Previous` step through the
table in that order and wrap around; the probe verified the cycle is
reversible. Re-run the probe after changing parts or mod versions and copy the
exact `display='...'` strings into `engineModeNames`; when they do not match,
the script still switches modes but falls back to relative tracking from
`engineModeInitial` and cannot re-read a manual change.

kOS invokes actions by the name shown in the **action-group editor**, which for
this mod is the localized text behind `#LOC_SEP_NextEngineMode` /
`#LOC_SEP_PreviousEngineMode` (`"Next Engine Mode"` / `"Previous Engine Mode"`),
not the `NextEngineModeAction` / `PreviousEngineModeAction` method names KSP
stores in the craft file. Both spellings are tried, then the right-click
events; the probe reports which one this install accepts.

Timeline:

| Time | Action |
|---|---|
| Liftoff | The switch starts in `engineModeInitial` (0). |
| Mass reaches `mecoMass + engineModePreSeparationMass` (before MECO) | The ascent loop selects `engineModePreSeparation` (Middle Two) under power. The switch shuts the outer groups down, so the remaining margin burns at the Middle Two rate (3065 kN, ~0.78 t/s) rather than the full cluster rate: 2 t is about 2.6 s of 0.72 TWR flight, and MECO follows. If the threshold is skipped (zero margin, or one mass step past it), the switch instead happens at MECO. |
| MECO | No cutoff: the first stage keeps the pre-separation group burning through staging (hot staging). Every other profile still locks the throttle to 0 and shuts its liftoff engines down here. |
| Separation | The booster leaves the stack in Middle Two, burning at the throttle it inherited from the stack (1). |
| Boostback phase start | The phase takes over the throttle and holds it at 1, so the hot-staging burn continues through the impact predictions, through the flip, and into the boostback burn: one continuous burn from MECO to the boostback cutoff. With `enableBoostBack = FALSE` the separation handoff cuts the burn instead. |
| Boostback flip reaches `burnAlignTolerance` | `f9boostback.ks` selects `engineModePostSeparation` (Middle Eight) at the moment the booster is aligned to the burn. Middle Eight is a superset of Middle Two, so this adds the outer ring to the burn that is already running rather than relighting the stack, and the throttle stays at `boostBackThrottle` (1). When boostback is disabled there is no alignment to wait for, so the switch falls back to `engineModeSeparationDelay` after separation detection. |
| Landing, airspeed below `engineModeTerminalAirspeed` | The landing script selects `engineModeTerminal` (Center Three). |
| Landing cutoff | Throttle locks to 0; the engines stay lit. |

Interactions:

- The pre-separation switch is independent of `stageSeparationDelay`: it fires
  on the mass threshold before MECO, and `stageSeparationDelay` is then spent
  coasting between MECO and staging.
- The ascent and recovery CPUs do not share state. The recovery profile
  assumes the ascent left the booster in `engineModeInitial` (Middle Two);
  when the game exposes the mode display the script re-reads it before every
  switch, so a manual mode change self-corrects. Otherwise do not switch modes
  by hand in flight.
- kOS reports the four engine modules on the cluster part as one aggregated
  engine, so per-group thrust, minimum throttle, and spool time are configured
  in the boot lexicon (`engineModeDataPostSeparation`, `engineModeDataTerminal`)
  instead of being read from the parts.
- With mode control enabled a cutoff zeroes the throttle only; the engines stay
  lit for the rest of the flight. The profile flies one continuous burn from
  MECO to the boostback cutoff: MECO does not throttle down, the booster
  inherits the stack throttle (1) at separation, and `f9boostback.ks` holds that
  throttle through the predictions and the flip (`boostBackThrottle` = 1), so
  the boostback burn is the same burn, only steered at the target. The phase
  cuts it when its guidance ends, when the trajectory already reaches the target
  ("no burn required"), or on failure; with `enableBoostBack = FALSE` the
  separation handoff cuts it, so the survey profile still coasts from separation
  on. The mode switch to Middle Eight happens under thrust, which the SEP switch
  handles by adding the outer ring to the running group; the boostback-disabled
  handoff instead cuts the throttle before its delay, so that switch is never
  made under thrust.
- `burnAlignTolerance` now has two jobs on this profile: it ends the boostback
  alignment loop and, through the switch above, selects the Middle Eight group
  for the burn.

## Recovery phases

### 1. Separation and target preparation

The recovery executive always waits for the booster mass to fall below
`boostBackMass`, then waits `boostBackDelay`. It initializes the target and LTR
after this handoff. The LTR body model calls `InitAtmModel` and sets body spin
from `BODY:ANGULARVEL`; aerodynamic coefficients are sampled from FAR using
the configured speed and altitude grids.

With `engineModeControl` enabled the handoff is preceded by `f9_engine_mode_begin`,
which reads the mode the ascent left behind (`engineModeInitial`, Middle Two) and
verifies the switch is usable. `boostBackDelay` counts from this point. With
`enableBoostBack = FALSE` the handoff also locks the throttle to 0, so a
hot-staged booster stops burning before the delay instead of carrying the
inherited throttle into the entry phase.

### 2. Boostback

If `enableBoostBack` is `TRUE`, BORG predicts the impact error, aligns the
boostback engine thrust axis, and fires the tagged engines at
`boostBackThrottle`. The prediction is refreshed asynchronously while the
burn runs. The steering and cutoff logic accounts for prediction latency and
cuts off when the predicted error is no longer improving. If the switch is
`FALSE`, no boostback hook, engine lookup, alignment, or burn is performed.

Under engine-mode control the boostback burn is the continuation of the
hot-staging burn. The phase takes the throttle over at 1 and holds it there, so
the booster keeps burning through the impact predictions and the flip; the
alignment is then where the mode changes, not where the burn starts: the moment
the alignment error reaches `burnAlignTolerance` the script selects
`engineModePostSeparation` (Middle Eight), which adds the outer ring to the
running group, and the burn - already at `boostBackThrottle`, which is 1 on
this profile - continues as the boostback burn. With boostback disabled that
selection falls back to `engineModeSeparationDelay` after separation detection;
the "no burn required" exit also selects it, so the entry and landing phases
still see Middle Eight.

Because the phase holds a live burn, every path that gives up goes through
`f9_boostback_cutoff`, which cuts the throttle before returning: the target
check, the engine lookup, the LTR setup, and a failed prediction, including one
that fails during the alignment loop (it gives up before the engine-mode switch,
so the post-separation group is never selected on an unaligned booster). The
"no burn required" exit cuts the burn as well, since continuing it would push the
booster off a target it already reaches. No exit path hands the entry phase a
booster that is still burning, and the cutoff holds its throttle lock across one
control update, so the cut is applied even when the executive stops right after.

### 3. Entry phase

`f9_entry_burn` is always called so the phase boundary remains consistent. It
calls the entry hook and then:

- when `enableEntryBurn` is `TRUE`, holds the booster retrograde while
  descending to `entryBurnAlt`, iteratively computes a target-correcting VGO,
  aligns the entry engines, and burns at `entryThrottle` until the configured
  `entryVSpeed` is reached;
- when `enableEntryBurn` is `FALSE`, skips only the engine lookup, alignment,
  ignition, and powered burn. The following aerodynamic gliding phase is still
  executed by `f9_landing_burn`.

Either way the phase locks the throttle to 0 on entry, so a booster handed over
still burning from a hot-staging separation (or from another ascent program)
coasts from the phase boundary on, and the disabled path cannot leave the
throttle at its inherited value.

The alignment and the burn steer with `f9_get_target_steering`, which builds its
top vector as orbit normal x fore: the same roll zero as the aerodynamic
phases. The powered attitude therefore stays roll-continuous with the
aerodynamic coast before it and the aerodynamic glide after it, instead of
rolling 180 degrees when the burn ends.

### 4. Aerodynamic descent and landing ignition

`f9_landing_burn` begins with an unpowered aerodynamic-guidance loop. LTR
predicts the impact point using the configured AOA profile and FAR-derived
coefficients. Independent pitch and yaw PID loops correct downrange and
crossrange impact error, with `aeroMaxPitch`, `aeroMaxYaw`, dynamic-pressure
attenuation, and `aeroTargetOffset` limiting the correction. The aerodynamic
steering explicitly locks the roll angle to a deterministic reference built
from the orbit normal, so the unpowered descent and glide do not inherit an
implicit roll from the prograde direction.

Landing ignition is spool-compensated. BORG predicts future bottom height over
the selected deceleration engines' spool-up time and ignites when the future
height reaches `landingBurnAltitude`. This prevents a late ignition without
starting the burn solely from current altitude. With `engineModeControl`
enabled the deceleration group is already lit, so the phase starts the moment
the predicted height reaches `landingBurnAltitude` instead of igniting and
waiting for a spool-up.

### 5. Unified landing-burn guidance

The landing burn uses one continuous loop containing two guidance regimes:

1. **Quadratic phase:** fixed-time quadratic guidance commands a three-
   dimensional acceleration toward the target. The starting reference
   acceleration is based on the deceleration-engine thrust and current
   descent state; the ending reference acceleration is based on the final
   landing-engine set. The dynamic AOA limit is reduced by dynamic pressure
   and tightens with time-to-go.
2. **Terminal phase:** when `landingPhase2Time` is reached, the AOA allowance
   is removed and the command is biased toward the local vertical descent
   direction to prevent terminal divergence.

The steering holds the roll at the same zero reference as the aerodynamic
phase, so the attitude stays continuous when the engines ignite. The requested
acceleration is converted through a minimum-throttle-aware
throttle mapper. During every update, BORG samples several points of the
remaining quadratic trajectory. Deceleration engines are shut down only when
all sampled thrust demands are below the final landing-engine cutoff
capability. Engines that are also final landing engines remain active.

With `engineModeControl` enabled the transition is instead driven by airspeed:
when airspeed falls below `engineModeTerminalAirspeed`, the switch selects
`engineModeTerminal` (Center Three) and the guidance target acceleration and
thrust data change with it. The deceleration group is never shut down from the
trajectory samples.

Landing legs deploy below `legDeploySpeed`. Engines are cut off when vertical
speed becomes non-negative or the bottom of the vehicle reaches
`landingCutoffHeight`. The script then holds the vehicle upright for five
seconds before releasing steering and throttle locks. With `engineModeControl`
enabled a cutoff only holds the throttle at zero; the engines stay lit.

## Script responsibilities

| Script | Responsibility |
|---|---|
| `f9utility.ks` | Parameter validation, display helpers, target acquisition/refresh, automatic target resolution, LTR/FAR setup and prediction, steering transforms, bottom-height calculation, throttle mapping, and SEP engine-mode switching. |
| `f9launch.ks` | Included open-loop ascent: liftoff, vertical hold, programmed turn, MECO, pre-separation engine-mode switch, staging, upper-stage ignition, and Action Group 10 handoff. |
| `f9boostback.ks` | Optional post-separation boostback alignment, latency-aware impact-error guidance, throttle control, and cutoff. |
| `f9entryburn.ks` | Optional powered entry burn and VGO iteration. It keeps the entry phase callable when the powered burn is disabled. |
| `f9landingburn.ks` | Aerodynamic impact correction, spool-compensated ignition, unified quadratic/terminal landing guidance, engine transition, gear deployment, and cutoff. With `engineModeControl` the engine transition follows airspeed instead of trajectory samples. |
| `sepmodeprobe.ks` | One-off ground calibration for the SEP engine-mode boot values. Not part of any flight profile. |
| `gof9u.ks` | Upper-stage executive; loads launch modules and runs `f9_launch`. |
| `gof9d.ks` | Booster executive; validates, waits for separation, resolves targets, and runs the recovery phases. |

Each public phase returns a Boolean. The executive stops when configuration,
target acquisition, addon availability, engine discovery, thrust data, or a
prediction prerequisite fails.

## Configuration reference

The tables below show the defaults in `boot/f9recovery.ks`. RP-1, ASDS, and
ZhuQue-3 boot files intentionally override vehicle-specific values; always
edit the boot file that is installed on the actual craft.

### Ascent parameters

The included generic ascent defaults are:

| Key | Default | Meaning |
|---|---:|---|
| `kOSIPU` | `2000` | kOS instructions per update. |
| `liftoffEngineTag` | `"liftoff_"` | Engines started for liftoff and MECO. |
| `payloadMass` | `16.651` | Payload mass in tonnes. |
| `mecoMass` | `190 + payloadMass` | Mass threshold for first-stage MECO. |
| `targetHeading` | `80` | Programmed ascent heading. |
| `targetRoll` | `0` | Programmed roll angle. |
| `turnSpeed` | `50` | Surface speed at which pitch-over starts. |
| `pitchOmega` | `0.42` | Programmed pitch decrease in degrees per second. |
| `stageSeparationDelay` | `1` | Delay between MECO and staging. |
| `upperStageIgnitionDelay` | `2` | Delay between staging and upper-stage ignition. |

This ascent is not an orbit optimizer. Reserve first-stage propellant and use
another ascent system if the mission needs a different trajectory.

### Recovery target, tags, and switches

| Key | Default | Meaning |
|---|---:|---|
| `kOSIPU` | `2000` | kOS instructions per update. |
| `landingSiteUse` | `"waypoint"` | `geo`, `waypoint`, `vessel`, or `none`. |
| `landingSiteGeo` | `LIST(0, 0)` | Longitude/latitude for `geo`. |
| `landingSiteWaypoint` | `"VAB"` | Waypoint name for `waypoint`. |
| `landingSiteVessel` | `"drone"` | Vessel name for `vessel`. |
| `boostbackEngineTag` | `"boostback_"` | Boostback engine selector. |
| `entryEngineTag` | `"entry_"` | Entry engine selector. |
| `landingDecEngineTag` | `"landing1_"` | Initial landing-deceleration selector. |
| `landingEngineTag` | `"landing2_"` | Final landing selector. |
| `boostBackMass` | `150` | Mass below which separation is recognized. |
| `targetRoll` | `0` | Powered recovery roll command. |
| `altitudeOffset` | `0` | Altitude added to the selected target. |
| `enableBoostBack` | `TRUE` | Run the boostback phase. |
| `boostBackDelay` | `4` | Delay after separation detection. |
| `burnAlignTolerance` | `130` | Alignment error accepted before powered burn. Under `engineModeControl` it also selects the post-separation engine group at that moment. |
| `boostBackThrottle` | `1` | Boostback throttle command. |
| `boostbackPitchOffset` | `0` (optional) | Boostback attitude pitch offset relative to the guidance solution, deg, clamped to ±90. Negative values pitch the nose down; missing key means `0`. `boot/starshiprecovery.ks` sets `+38`. |
| `enableEntryBurn` | `TRUE` | Run the powered entry burn; gliding still runs when `FALSE`. |
| `entryBurnAlt` | `60000` | Absolute ASL descending entry-burn altitude. |
| `entryVSpeed` | `650` | Positive target downward speed after entry burn. |
| `entryThrottle` | `1` | Entry throttle command. |

### SEP engine-mode control (Starship boot files)

These keys are only read when `engineModeControl` is `TRUE`. The values below
are those of `boot/starshiprecovery.ks`; the ascent profile shares
`engineModeControl`, `engineModeModuleName`, `engineModeCount`,
`engineModeInitial`, `engineModeNextAction`, `engineModePreviousAction`, and
`engineModeNames`, and adds the pre-separation pair.

| Key | Default | Meaning |
|---|---:|---|
| `engineModeControl` | `TRUE` | Select engine groups with the SEP switch instead of tags and `activate_engines` / `deactivate_engines`. |
| `engineModeModuleName` | `"ModuleSEPEngineSwitch"` | PartModule that owns the switch. |
| `engineModeCount` | `4` | Number of modes the switch cycles through. |
| `engineModeInitial` | recovery `2`, ascent `0` | Mode at the start of the profile. The recovery value is the contract for the mode the ascent leaves behind. |
| `engineModePreSeparation` | ascent `2` | Mode selected before staging (Middle Two). |
| `engineModePreSeparationMass` | ascent `2` | Tonnes above `mecoMass` at which `engineModePreSeparation` is selected, so the switch happens under power before MECO. The switch shuts the liftoff group down, so the remaining margin burns at the pre-separation group's rate (Middle Two, 3065 kN, ~0.78 t/s) instead of the full-cluster rate (~5-6 t/s): `2` is about 2.6 s of 0.72 TWR flight to MECO, not 0.3 s. Keep it above one physics step at full thrust (~0.15 t) so the ascent loop still catches the threshold; `0` effectively switches at MECO. |
| `engineModePostSeparation` | `1` | Mode selected after separation (Middle Eight), at boostback alignment or after `engineModeSeparationDelay`. |
| `engineModeSeparationDelay` | `4` | Seconds after separation detection before selecting `engineModePostSeparation`; used only when `enableBoostBack` is `FALSE` (with boostback, the alignment switch above owns the timing). That handoff first locks the throttle to 0, so the mode switch is not made under thrust. |
| `engineModeTerminal` | `3` | Terminal landing mode (Center Three). |
| `engineModeTerminalAirspeed` | `50` | Airspeed in m/s below which the terminal mode is selected. |
| `engineModeEngineTag` | `"liftoff_"` | Tag on the cluster part, read only for the thrust axis. |
| `engineModeNextAction` / `engineModePreviousAction` | `"Next Engine Mode"` / `"Previous Engine Mode"` | Names of the mode-step actions. kOS matches the name shown in the action-group editor, not the method name KSP stores in the craft file; both forms are tried, so change these only if the probe reports something else. |
| `engineModeNames` | `LIST("Outer Twenty", "Middle Eight", "Middle Two", "Center Three")` | Display names in index order, as measured by the probe, used for the readout and to re-read the mode. |
| `engineModeDataPostSeparation` | `LEXICON("thrust", 7969, "minthrottle", 0, "spooluptime", 0.5)` | Middle Eight group data: thrust in kN, minimum throttle, spool-up time in seconds. |
| `engineModeDataTerminal` | `LEXICON("thrust", 1839, "minthrottle", 0, "spooluptime", 0.5)` | Center Three group data. |

### LTR prediction

| Key | Default | Meaning |
|---|---:|---|
| `ltrCtrlSpeedSamples` | `LIST(300, 600, 1000)` | Speed axis for the open-loop AOA profile. |
| `ltrCtrlAOASamples` | `LIST(0, 8, 10)` | AOA values corresponding to the speed axis. |
| `ltrAeroSpeedSamples` | `LIST(100, 500, 1000, 2000, 3000)` | FAR coefficient speed samples. |
| `ltrAeroAltitudeSamples` | `LIST(0, 10000, 30000, 50000, 70000)` | FAR coefficient altitude samples. |
| `ltrCdFactor` | `1` | Drag-coefficient calibration multiplier. |
| `ltrClFactor` | `1` | Lift-coefficient calibration multiplier. |
| `ltrPredictMinStep` | `0.001` | Minimum RKF45 step in seconds. |
| `ltrPredictMaxStep` | `0.5` | Maximum RKF45 step in seconds. |
| `ltrPredictTMax` | `1200` | Maximum prediction duration. |

LTR samples FAR after separation, initializes the body's atmosphere and spin,
and asynchronously propagates the trajectory. A failed or timed-out
prediction is reported to the active phase; aerodynamic guidance falls back to
surface retrograde for an individual invalid glide prediction.

### Aerodynamic guidance

| Key | Default | Meaning |
|---|---:|---|
| `aeroPitchKp` / `aeroPitchKi` / `aeroPitchKd` | `10 / 0 / 0.5` | Downrange PID gains. |
| `aeroYawKp` / `aeroYawKi` / `aeroYawKd` | `10 / 0 / 0.5` | Crossrange PID gains. |
| `aeroMaxPitch` | `6` | Maximum pitch correction in degrees. |
| `aeroMaxYaw` | `10` | Maximum yaw correction in degrees. |
| `aeroTargetOffset` | `0` | Downrange offset applied to boostback, entry, and glide targets. |

### Landing guidance

| Key | Default | Meaning |
|---|---:|---|
| `QuadraticAOABase` | `30` | Low-q upper bound for quadratic-phase AOA. |
| `QuadraticAOADot` | `1` | AOA allowance in degrees per second of time-to-go. |
| `landingBurnAltitude` | `2300` | Spool-predicted ignition-height threshold. |
| `legDeploySpeed` | `90` | Airspeed below which landing gear deploys. |
| `touchDownSpeed` | `0.1` | Positive terminal downward-speed magnitude. |
| `landingPhase2Time` | `4` | Time-to-go at which terminal guidance begins. |
| `landingCutoffHeight` | `0.2` | Bottom height at which engines are cut off. |
| `boundsUpdatePeriod` | `1` | Vessel-bounds refresh interval. |
| `minLandingThrottleCommand` | `0.01` | Minimum positive landing throttle command. |

## Hooks and tuning order

Recovery boot files define three hooks:

- `pre_boostback_hook`: runs after the separation delay and before boostback
  engine lookup;
- `pre_entryburn_hook`: runs at the entry phase boundary, including when the
  powered entry burn is disabled;
- `pre_landingburn_hook`: runs before aerodynamic descent and landing.

Use these hooks for vehicle-specific steering-manager settings. Tune the
attitude controller first, then engine tags and thrust data, then LTR/AOA
profiles, aerodynamic PID limits, entry parameters, and finally landing
guidance. A poor steering-manager response can make a correct impact prediction
look like a guidance failure.

## Testing workflow

0. For a Starship profile, run `Falcon9_lib/sepmodeprobe.ks` on the pad once
   and feed the values from `0:/sep_probe.log` back into the boot lexicon:
   mode count, indices, display names, action names, and the two group-data
   lexicons. The probe holds the throttle at 1 for about 12 seconds while it
   cycles the modes, so run it clamped on the pad; it steps back to the mode
   it started in.
1. Confirm that all engine tags are discoverable after staging and that the
   configured `boostBackMass` is below the attached launch-vehicle mass but
   above the separated-booster mass.
2. Run an ASDS survey with `landingSiteUse = "none"` and
   `enableBoostBack = FALSE`; record the displayed natural impact coordinates.
3. Place the recovery ship or pad, configure a waypoint or vessel target, and
   rerun the flight with the intended burn switches.
4. Verify the first-stage fuel reserve, engine restart count, minimum throttle,
   spool time, and touchdown clearance before a full mission.

The included ascent guidance is only a convenience. A player-controlled,
MechJeb, PEGAS, or other ascent can be used as long as the booster reaches
separation in a state the recovery profile can physically recover.
