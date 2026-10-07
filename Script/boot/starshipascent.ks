// Falcon 9 second stage boot file.
// Provides very simple open-loop ascent guidance
// If you want more capable rocket ascent guidance, please use PEGAS
// Distances are meters, time is seconds, speed is m/s, mass is metric tons,
// and angles are degrees unless noted otherwise.

local payloadMass to 8.5.
GLOBAL F9_ASCENT_PARAMS IS LEXICON(
    // Runtime
    "kOSIPU", 2000,
    "liftoffEngineTag", "liftoff_",

    // Vehicle-specific values. These must be set before flight.
    "payloadMass", payloadMass,  // Mass of the payload, ton
    "mecoMass", 440 + payloadMass,  // When the mass is below MECO mass, trigger MECO, ton
    "targetHeading", 80,  // First stage ascent azimuth, deg
    "targetRoll", 0,  // Roll angle while whole process, deg

    // Launch
    "turnSpeed", 50,  // Gravity turn start speed, m/s
    "pitchOmega", 0.5,  // Programmed turn pitching speed, deg/s
    "stageSeparationDelay", 0,  // Time between MECO and 1st Stage Separation, s
    "upperStageIgnitionDelay", 0,  // Time between 1st Stage Separation and second stage ignition, s

    // SEP engine-mode control: ModuleSEPEngineSwitch owns ignition and
    // shutdown for the booster cluster. Four modes, measured with
    // Falcon9_lib/sepmodeprobe.ks (display name, cluster thrust at throttle 1
    // with the 613 kN engine of this part):
    //   0 Outer Twenty  20229 kN (33 engines)  liftoff
    //   1 Middle Eight   7969 kN (13)
    //   2 Middle Two     3065 kN (5)           pre-separation
    //   3 Center Three   1839 kN (3)
    // Mode order is what Next/Previous step through; the switch cycles.
    // The pre-separation switch is mass-triggered: the ascent loop selects
    // engineModePreSeparation when mass reaches mecoMass +
    // engineModePreSeparationMass, falling back to switching at MECO if the
    // threshold was skipped. The switch also shuts the outer groups down, so
    // the remaining margin burns at the Middle Two rate (3065 kN, Isp 400 s,
    // ~0.78 t/s) instead of the full cluster rate: 2 t is about 2.6 s of
    // 0.72 TWR flight to MECO, not the ~0.3 s the full-thrust rate suggests.
    // Keep the margin above one physics step of full-thrust burn (~0.15 t) so
    // the ascent loop still catches the threshold.
    // MECO does not throttle the cluster down for this profile: the booster
    // burns through staging (hot staging), and the recovery profile continues
    // that same burn - throttle 1 through the boostback flip - until the
    // boostback guidance cuts it (see boot/starshiprecovery.ks).
    "engineModeControl", TRUE,
    "engineModeModuleName", "ModuleSEPEngineSwitch",
    "engineModeCount", 4,
    "engineModeInitial", 0,  // Outer Twenty, the default state of the switch
    "engineModePreSeparation", 2,  // Middle Two, selected before staging
    "engineModePreSeparationMass", 3,  // Tonnes above mecoMass at which the switch fires; see the note above
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
    )
).

if (ship:status = "PRELAUNCH") {
    print "Activate AG10 to enable launch.".
    wait until ag10.
    runPath("0:/Falcon9_lib/gof9u.ks").
}
