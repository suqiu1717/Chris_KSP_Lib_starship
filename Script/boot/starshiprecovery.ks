// Falcon 9 recovery stage boot file.
// Distances are meters, time is seconds, speed is m/s, mass is metric tons,
// and angles are degrees unless noted otherwise.

GLOBAL F9_PARAMS IS LEXICON(
    // Runtime
    "kOSIPU", 2000,

    "landingSiteUse", "waypoint",  // Options: "geo", "waypoint", "vessel", "none". "none" selects the predicted natural impact after separation and boostBackDelay
    "landingSiteGeo", list(0, 0),  // longitude and latitude, use terrain height as altitude
    "landingSiteWaypoint", "sea",  // name of waypoint, use waypoint altitude as altitude
    "landingSiteVessel", "drone",  // name of target vessel, use vessel altitude as altitude, the vessel can move slowly

    "boostbackEngineTag", "boostback_",
    "entryEngineTag", "entry_",
    "landingDecEngineTag", "landing1_",
    "landingEngineTag", "landing2_",

    // SEP engine-mode control: ModuleSEPEngineSwitch owns ignition and shutdown
    // for the booster cluster, and the engine tags above are unused by this
    // profile. Four modes, measured with Falcon9_lib/sepmodeprobe.ks (display
    // name, cluster thrust at throttle 1 with the 613 kN engine of this part):
    //   0 Outer Twenty  20229 kN (33 engines)
    //   1 Middle Eight   7969 kN (13)
    //   2 Middle Two     3065 kN (5)   the state the ascent leaves behind
    //   3 Center Three   1839 kN (3)
    // Mode order is what Next/Previous step through; the switch cycles.
    "engineModeControl", TRUE,
    "engineModeModuleName", "ModuleSEPEngineSwitch",
    "engineModeCount", 4,
    "engineModeInitial", 2,  // Contract: the ascent leaves the booster in Middle Two
    "engineModePostSeparation", 1,  // Middle Eight, selected when the boostback flip reaches burnAlignTolerance (or engineModeSeparationDelay after separation when boostback is off)
    "engineModeSeparationDelay", 4,  // Seconds after separation detection; used only when enableBoostBack is FALSE, and the handoff cuts the throttle before the delay
    "engineModeTerminal", 3,  // Center Three for the final landing phase
    "engineModeTerminalAirspeed", 150,  // Airspeed at which Middle Eight hands over to Center Three, m/s
    "engineModeEngineTag", "liftoff_",  // Any tag on the cluster part; used to read the thrust axis
    // Names shown in the action-group editor; kOS matches those, not the
    // method names (NextEngineModeAction / PreviousEngineModeAction) that KSP
    // stores in the craft file. The probe confirmed this install accepts
    // "Next Engine Mode" / "Previous Engine Mode".
    "engineModeNextAction", "Next Engine Mode",
    "engineModePreviousAction", "Previous Engine Mode",
    // Mode display strings, as measured by the probe. f9_engine_mode_read maps
    // them back to indices, so the script re-reads the real mode before every
    // switch instead of trusting its own step count.
    "engineModeNames", LIST(
        "Outer Twenty", "Middle Eight", "Middle Two", "Center Three"
    ),
    // Group data. kOS aggregates the four engine modules on the cluster part,
    // so the numbers are configured here instead of read from the engines.
    // Thrust values are the probe's SHIP:MAXTHRUST per mode: 7969 kN is 13
    // engines and 1839 kN is 3 engines of this part's 613 kN engine.
    "engineModeDataPostSeparation", LEXICON(
        "thrust", 7969,
        "minthrottle", 0,
        "spooluptime", 0.5
    ),
    "engineModeDataTerminal", LEXICON(
        "thrust", 1839,
        "minthrottle", 0,
        "spooluptime", 0.5
    ),

    // Vehicle-specific values. These must be set before flight.
    "boostBackMass", 300,  // After second stage seperation, the mass of first stage should be less than this, ton
    "targetRoll", 0,  // Roll angle while whole process, deg
    "altitudeOffset", 0,  // Additional height added to the selected waypoint, or target COM, m

    // Powered-burn alignment and timing
    "enableBoostBack", TRUE,  // Set FALSE to skip the boostback phase; the separation handoff then cuts the inherited throttle instead of burning through the flip
    "boostBackDelay", 0,  // Time between 1st stage separation and boostback maneuver, s
    "burnAlignTolerance", 130,  // Alignment angle error tolerance, deg; also selects engineModePostSeparation when the boostback flip reaches it
    // The boostback burn is the continuation of the hot-staging burn: it runs at
    // full throttle and the phase never throttles it down, so the burn is
    // continuous from MECO to the boostback cutoff. Lower this to burn the
    // boostback at a reduced setting (the flip is already done at that point).
    "boostBackThrottle", 1,  // throttle (0~1) during boost back maneuver
    "boostbackPitchOffset", +38,  // Optional: pitch attitude change of the boostback burn relative to the nominal guidance solution, deg. Negative = nose down; missing key means 0

    // Entry burn
    "enableEntryBurn", TRUE,  // Set FALSE to skip only the powered entry burn; aerodynamic gliding remains enabled
    "entryBurnAlt", 200000,  // Altitude to perform entry burn, m
    "entryVSpeed", 1200,  // Target descent rate, m/s
    "entryThrottle", 0.5,  // throttle (0~1) during entry burn

    // kOS-LTR open-loop trajectory predictor. The speed-AOA profile is the
    // attitude assumed by the predictor; aerodynamic coefficients are sampled
    // from FAR once the booster has separated.
    "ltrCtrlSpeedSamples", LIST(300, 600, 1000),
    "ltrCtrlAOASamples", LIST(0, 10, 15),
    "ltrAeroSpeedSamples", LIST(100, 500, 1000, 2000, 3000),
    "ltrAeroAltitudeSamples", LIST(0, 10000, 30000, 50000, 70000),
    "ltrCdFactor", 1,
    "ltrClFactor", 1,
    "ltrPredictMinStep", 0.001,
    "ltrPredictMaxStep", 0.5,
    "ltrPredictTMax", 1200,

    // Aerodynamic guidance. These must be tuned for the vehicle before flight.
    // PID outputs are pitch/yaw correction angles in degrees.
    "aeroPitchKp", 30,
    "aeroPitchKi", 0.05,
    "aeroPitchKd", 0.5,
    "aeroYawKp", 30,
    "aeroYawKi", 0.05,
    "aeroYawKd", 0.5,
    "aeroMaxPitch", 7,
    "aeroMaxYaw", 5,
    "aeroTargetOffset", -120,  // Aerodynamic gliding phase is aiming at target + aeroTargetOffset * downRangeVector, m

    // Landing burn
    "QuadraticAOABase", 30,  // AOA limit base during quadratic guidance phase, increase this value will allow larger AOA, deg
    "QuadraticAOADot", 1,  // AOA limit related to Time-to-go during quadratic guidance phase, increase this value will allow larger AOA when approaching ground, deg/s
    "landingBurnAltitude", 2200,  // Ignite decelerating engines (or landing fallback) below this, m
    "legDeploySpeed", 90,  // Deploy landing legs when speed is below this, m/s
    "touchDownSpeed", 0.1,  // touch down speed, m/s
    "landingPhase2Time", 4,  // time of untargeted landing phase 2, s
    "landingCutoffHeight", 0.2,  // cut off landing engines when height is below this, m
    "boundsUpdatePeriod", 1,  // frequency of updating bounding box, s
    // Keep a continuously ignited RO engine above zero command until cutoff.
    "minLandingThrottleCommand", 0.01
).

// these code will be fired soon after second stage seperation
FUNCTION pre_boostback_hook {
    set steeringManager:torqueepsilonmax to 0.005.
    // set steeringManager:torqueepsilonmin to 0.002.
    // set steeringManager:maxstoppingtime to 1.
    // set steeringManager:pitchts to 16.
    set steeringManager:pitchpid:kd to 0.5.
    // set steeringManager:yawts to 16.
    set steeringManager:yawpid:kd to 0.5.
    // set steeringManager:rollts to 2.
    set steeringManager:rollpid:kd to 0.5.
    // set steeringManager:rollpid:epsilon to 0.1.
}

// these code will be fired soon after boostback maneuver is finished
FUNCTION pre_entryburn_hook {
    // set steeringManager:pitchts to 8.
    // set steeringManager:yawts to 8.
}

// these code will be fired soon after entryburn is finished
FUNCTION pre_landingburn_hook {
    set steeringManager:pitchts to 2.
    set steeringManager:yawts to 2.
    set steeringManager:rollts to 0.5.
    set steeringManager:rollpid:kd to 0.5.
}

if (ship:status = "PRELAUNCH" OR ship:status = "FLYING" OR ship:status = "SUB_ORBITAL") {
    runPath("0:/Falcon9_lib/gof9d.ks").
}
