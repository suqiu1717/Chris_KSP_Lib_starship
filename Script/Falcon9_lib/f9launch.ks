RUNONCEPATH("0:/Falcon9_lib/f9utility.ks").

FUNCTION f9_launch {
    PARAMETER params.

    IF NOT f9_validate_launch_params(params) {
        RETURN FALSE.
    }
    SET CONFIG:IPU TO params["kOSIPU"].
    f9_init_launch_display().

    LOCAL liftoffEngines IS search_engine(params["liftoffEngineTag"]).
    IF liftoffEngines:LENGTH = 0 {
        f9_print_result("ERROR: no liftoff engines found").
        RETURN FALSE.
    }
    LOCAL engineInfo IS get_engines_info(liftoffEngines).
    IF engineInfo["thrust"] <= 0 {
        f9_print_result("ERROR: liftoff engines have no thrust").
        RETURN FALSE.
    }
    IF f9_engine_mode_enabled(params) {
        // f9_engine_mode_begin reports the reason itself, including the action
        // names this install does expose.
        IF NOT f9_engine_mode_begin(params) {
            RETURN FALSE.
        }
    }

    f9_print_at(2, "State: starting main engines").
    f9_print_at(
        3,
        "Mass: " + ROUND(SHIP:MASS, 2)
            + " t  MECO: " + ROUND(params["mecoMass"], 2) + " t"
    ).
    f9_print_at(
        4,
        "Speed: " + ROUND(SHIP:VELOCITY:SURFACE:MAG, 1)
            + " m/s  Turn: " + ROUND(params["turnSpeed"], 1)
    ).
    f9_print_at(
        5,
        "Heading: " + ROUND(params["targetHeading"], 1)
            + " deg  Pitch: 90 deg"
    ).
    f9_print_at(
        6,
        "Thrust: " + ROUND(engineInfo["thrust"], 1)
            + " kN  Spool: " + ROUND(engineInfo["spooluptime"], 2) + " s"
    ).
    f9_print_at(7, "Throttle command: 1.00").
    f9_print_at(10, "Event: main engine start").
    LOCAL steeringTarget IS HEADING(params["targetHeading"], 90) * engineInfo["TiS"].
    SAS OFF.
    LOCK STEERING TO steeringTarget.
    LOCK THROTTLE TO 1.
    STAGE.
    // activate_engines(liftoffEngines).
    WAIT engineInfo["spooluptime"].

    f9_print_at(2, "State: vertical ascent").
    f9_print_at(10, "Event: liftoff").
    STAGE.
    RCS ON.
    UNTIL SHIP:VELOCITY:SURFACE:MAG >= params["turnSpeed"] {
        f9_print_at(
            3,
            "Mass: " + ROUND(SHIP:MASS, 2)
                + " t  MECO: " + ROUND(params["mecoMass"], 2) + " t"
        ).
        f9_print_at(
            4,
            "Speed: " + ROUND(SHIP:VELOCITY:SURFACE:MAG, 1)
                + " m/s  Turn: " + ROUND(params["turnSpeed"], 1)
        ).
        f9_print_at(
            5,
            "Heading: " + ROUND(params["targetHeading"], 1)
                + " deg  Pitch: 90 deg"
        ).
        f9_print_at(
            7,
            "Throttle: " + ROUND(SHIP:CONTROL:MAINTHROTTLE, 2)
        ).
        WAIT 0.
    }

    f9_print_at(2, "State: programmed turn").
    f9_print_at(10, "Event: turn started").
    LOCAL turnStart IS TIME:SECONDS.
    LOCAL modePreset IS FALSE.
    UNTIL SHIP:MASS <= params["mecoMass"] {
        LOCAL pitchCommand IS MAX(
            0,
            90 - params["pitchOmega"] * (TIME:SECONDS - turnStart)
        ).
        SET steeringTarget TO HEADING(params["targetHeading"], pitchCommand)
            * engineInfo["TiS"].
        f9_print_at(
            3,
            "Mass: " + ROUND(SHIP:MASS, 2)
                + " t  MECO: " + ROUND(params["mecoMass"], 2) + " t"
        ).
        f9_print_at(
            4,
            "Speed: " + ROUND(SHIP:VELOCITY:SURFACE:MAG, 1) + " m/s"
        ).
        f9_print_at(
            5,
            "Heading: " + ROUND(params["targetHeading"], 1)
                + " deg  Pitch: " + ROUND(pitchCommand, 1) + " deg"
        ).
        f9_print_at(
            7,
            "Throttle: " + ROUND(SHIP:CONTROL:MAINTHROTTLE, 2)
        ).
        // Engine-mode control: select the pre-separation group (Middle Two)
        // once the stack is engineModePreSeparationMass tonnes above the MECO
        // mass, so the switch happens under power instead of during the
        // MECO-to-staging coast. The switch itself shuts the outer groups
        // down, so the remaining margin burns at the Middle Two rate and MECO
        // arrives a couple of seconds after the switch, not immediately (see
        // the engineModePreSeparationMass note in the boot lexicon).
        IF f9_engine_mode_enabled(params) AND NOT modePreset {
            IF SHIP:MASS <= params["mecoMass"]
                + params["engineModePreSeparationMass"] {
                IF NOT f9_engine_mode_goto(
                    params, params["engineModePreSeparation"]
                ) {
                    f9_print_result(
                        "ERROR: engine-mode pre-separation switch failed"
                    ).
                    RETURN FALSE.
                }
                SET modePreset TO TRUE.
                f9_print_at(
                    8, "Engine mode: " + f9_engine_mode_name(params)
                ).
            }
        }
        WAIT 0.
    }

    f9_print_at(2, "State: MECO").
    f9_print_at(10, "Event: main engine cutoff").
    // With engine-mode control (Starship) the first stage is not throttled down
    // at MECO: the mode switch already shut the outer groups down, and the
    // remaining group keeps burning through staging (hot staging). Every other
    // profile keeps the original cutoff.
    IF f9_engine_mode_enabled(params) {
        f9_print_at(7, "Throttle command: 1.00").
    } ELSE {
        LOCK THROTTLE TO 0.
        f9_engine_deactivate(params, liftoffEngines).
        f9_print_at(7, "Throttle command: 0.00").
    }

    // Fallback: the ascent loop normally switched mode already. This covers a
    // zero margin and a mass step large enough to skip the threshold.
    IF f9_engine_mode_enabled(params) AND NOT modePreset {
        IF NOT f9_engine_mode_goto(params, params["engineModePreSeparation"]) {
            f9_print_result("ERROR: engine-mode pre-separation switch failed").
            RETURN FALSE.
        }
        SET modePreset TO TRUE.
        f9_print_at(8, "Engine mode: " + f9_engine_mode_name(params)).
    }
    WAIT params["stageSeparationDelay"].

    f9_print_at(2, "State: stage separation").
    f9_print_at(10, "Event: first-stage separation").
    // Steering and throttle are locked to temporary value. In future this will be changed to PEG guidance
    SET _steering_gap TO ship:facing.
    LOCK STEERING TO _steering_gap.
    STAGE.
    SET SHIP:CONTROL:FORE TO 1.
    WAIT params["upperStageIgnitionDelay"].

    f9_print_at(2, "State: upper-stage ignition").
    f9_print_at(10, "Event: upper-stage ignition").
    LOCK THROTTLE TO 1.
    f9_print_at(7, "Throttle command: 1.00").
    WAIT 5.
    SET SHIP:CONTROL:FORE TO 0.
    f9_print_at(23, "First stage guidance ended, Action Group 10 to deactivate program").
    LOCAL AG10State to AG10.
    WAIT UNTIL AG10 <> AG10State.
    UNLOCK STEERING.
    UNLOCK THROTTLE.
    WAIT 0.
    RETURN TRUE.
}
