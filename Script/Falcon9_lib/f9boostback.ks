RUNONCEPATH("0:/Falcon9_lib/f9utility.ks").

// Apply the optional boostback pitch offset to a guidance error vector.
// The parameter "boostbackPitchOffset" is the pitch attitude change of the
// boostback burn relative to the nominal guidance solution, in degrees:
// negative values pitch the nose down, which raises the engine axis by the
// same amount because the nose and the engines are on opposite ends of the
// vehicle. The rotation is applied to the commanded burn direction itself;
// the vehicle follows it because the steering solution points the engine axis
// along this vector. The error vector is rotated inside its local vertical
// plane, so the burn azimuth still points at the target and only the elevation
// of the burn changes. A missing parameter means no offset.
FUNCTION f9_boostback_steer_vector {
    PARAMETER vecError.
    PARAMETER params.

    IF NOT params:HASKEY("boostbackPitchOffset") {
        RETURN vecError.
    }
    LOCAL pitchOffset IS params["boostbackPitchOffset"].
    // kOS scalar values expose no type suffix, so this parameter cannot be
    // type-checked at run time; configure it as an unquoted number.
    IF ABS(pitchOffset) < 0.0001 {
        RETURN vecError.
    }
    // Keep the rotation inside the vertical plane; beyond +-90 deg the offset
    // would flip the burn past the local horizon.
    SET pitchOffset TO MAX(-90, MIN(90, pitchOffset)).
    LOCAL vecMag IS vecError:MAG.
    IF vecMag < 0.000001 {
        RETURN vecError.
    }
    LOCAL fore IS vecError / vecMag.
    LOCAL upAxis IS -SHIP:BODY:POSITION:NORMALIZED.
    LOCAL upPart IS upAxis - VDOT(upAxis, fore) * fore.
    IF upPart:MAG < 0.000001 {
        RETURN vecError.
    }
    SET upPart TO upPart:NORMALIZED.
    // A positive nose pitch change rotates the engine axis down by the same
    // amount, hence the negated elevation change.
    LOCAL elevationChange IS -pitchOffset.
    RETURN (fore * COS(elevationChange) + upPart * SIN(elevationChange)) * vecMag.
}

FUNCTION f9_boostback_getImpactErr {
    PARAMETER params.
    PARAMETER targetContext.
    PARAMETER vecNormal.

    LOCAL predTime TO time:seconds.
    LOCAL predictedEntryAlt IS 9999999999.
    LOCAL predictedEntrySpeed IS 9999999999.
    IF params["enableEntryBurn"] {
        SET predictedEntryAlt TO params["entryBurnAlt"].
        SET predictedEntrySpeed TO params["entryVSpeed"].
    }
    LOCAL prediction IS f9_ltr_predict(
        params,
        targetContext,
        vecNormal,
        predictedEntryAlt,
        predictedEntrySpeed,
        params["landingBurnAltitude"]
    ).
    IF NOT f9_ltr_prediction_is_valid(prediction) {
        f9_print_result("ERROR: LTR boostback prediction failed").
        RETURN LEXICON("ok", FALSE).
    }
    LOCAL impactError IS f9_get_boostback_error(prediction).
    return LEXICON("err", impactError, "time", predTime, "ok", TRUE).
}

// Give up on the boostback before or during the burn. Under engine-mode control
// the phase is handed a booster burning at full throttle, so every failure exit
// cuts that burn instead of handing the entry phase a booster that is still
// accelerating; other profiles are already at 0. The wait holds the lock across
// one control update so the cut is applied even on the exits that stop the
// program immediately afterwards; the lock is never released, so it keeps the
// throttle down until a later phase replaces it.
FUNCTION f9_boostback_cutoff {
    LOCK THROTTLE TO 0.
    WAIT 0.
    RETURN FALSE.
}

FUNCTION f9_boostback {
    PARAMETER params.
    PARAMETER targetContext.

    // The boostback phase owns the throttle from its first statement. Under
    // engine-mode control the burn is continuous: MECO does not throttle the
    // stack down, the separation handoff does not cut it, and this phase keeps
    // it at 1, so the hot-staging burn runs straight through the impact
    // predictions and the flip into the boostback burn itself (see
    // boostBackThrottle in the recovery boot lexicon). Every give-up path below
    // goes through f9_boostback_cutoff, so a failed phase never leaves an
    // unguided booster at full throttle. Other profiles arrive here already
    // throttled down from MECO and hold 0 until the burn.
    IF f9_engine_mode_enabled(params) {
        LOCK THROTTLE TO 1.
    } ELSE {
        LOCK THROTTLE TO 0.
    }

    IF NOT targetContext["ok"] {
        f9_print_result("ERROR: no valid landing target").
        RETURN f9_boostback_cutoff().
    }

    f9_clear_guidance_display().
    pre_boostback_hook().
    // Under engine-mode control the SEP switch owns the engine groups and the
    // tag search cannot split the single cluster part; thrust data comes from
    // the boot lexicon instead (see sepmodeprobe.ks).
    LOCAL boostbackEngines IS LIST().
    LOCAL engineInfo IS 0.
    IF f9_engine_mode_enabled(params) {
        SET engineInfo TO f9_engine_mode_engine_data(params, "engineModeDataPostSeparation").
    } ELSE {
        SET boostbackEngines TO search_engine(params["boostbackEngineTag"]).
        IF boostbackEngines:LENGTH = 0 {
            f9_print_result("ERROR: no boostback engines found").
            RETURN f9_boostback_cutoff().
        }
        SET engineInfo TO get_engines_info(boostbackEngines).
        IF engineInfo["thrust"] <= 0 {
            f9_print_result("ERROR: boostback engines have no thrust").
            RETURN f9_boostback_cutoff().
        }
    }
    IF NOT f9_initialize_ltr(params) {
        RETURN f9_boostback_cutoff().
    }

    // Initialize 2 predictions
    LOCAL vecNormal IS f9_get_surface_normal().
    LOCAL _predres IS f9_boostback_getImpactErr(params, targetContext, vecNormal).
    if (not _predres["ok"]) { return f9_boostback_cutoff(). }
    LOCAL lastPredTime TO _predres["time"].
    LOCAL lastPredErr TO _predres["err"].
    WAIT 0.
    SET _predres TO f9_boostback_getImpactErr(params, targetContext, vecNormal).
    if (not _predres["ok"]) { return f9_boostback_cutoff(). }
    LOCAL predTime TO _predres["time"].
    LOCAL predErr TO _predres["err"].
    LOCAL errDot TO (predErr - lastPredErr) / (predTime - lastPredTime).
    WAIT 0.
    function update_predictions {
        parameter _predErr.
        parameter _predTime.

        set lastPredTime to predTime.
        set lastPredErr to predErr.
        set predErr to _predErr.
        set predTime to _predTime.
        set errDot TO (predErr - lastPredErr) / max(0.001, predTime - lastPredTime).
    }

    f9_print_target_position(targetContext).
    f9_print_recovery_vehicle().
    IF predErr:MAG < 0.001 {
        f9_print_at(11, "Phase: boostback - no burn required").
        f9_print_at(12, "Predicted impact error: 0.0 m").
        // The trajectory already reaches the target, so unlike the normal path
        // the phase cuts the inherited burn here. Cut before the switch so the
        // engine-mode change never happens under thrust, then hand the later
        // phases the boostback engine group. The wait applies the cut before
        // the switch runs, not just before the phase returns.
        LOCK THROTTLE TO 0.
        WAIT 0.
        IF NOT f9_engine_mode_select_post_separation(params) {
            RETURN FALSE.
        }
        RETURN TRUE.
    }

    f9_print_at(11, "Phase: boostback - aligning").
    SAS OFF.
    // Steering routine: lock steering to predErr
    LOCAL done to False.
    LOCAL steeringTarget TO "kill".
    LOCAL vecSteer IS f9_boostback_steer_vector(predErr, params).
    when (not done) then {
        SET steeringTarget TO f9_get_target_steering(
            vecSteer,
            engineInfo["TiS"],
            params["targetRoll"],
            vecNormal
        ).
        return true.
    }
    LOCK STEERING TO steeringTarget.
    RCS ON.

    LOCAL alignmentError IS VANG(
        (SHIP:FACING * engineInfo["TiS"]:INVERSE):FOREVECTOR,
        vecSteer
    ).
    f9_print_at(
        12,
        "Predicted impact error: "
            + ROUND(predErr:MAG, 2) + " m"
    ).
    f9_print_at(13, "Alignment error: " + ROUND(alignmentError, 2) + " deg").
    f9_print_at(
        16,
        "Engines: burning  Throttle: "
            + ROUND(SHIP:CONTROL:MAINTHROTTLE, 2)
    ).
    UNTIL alignmentError <= params["burnAlignTolerance"] {
        SET _predres TO f9_boostback_getImpactErr(params, targetContext, vecNormal).
        if not _predres["ok"] { BREAK. }
        update_predictions(_predres["err"], _predres["time"]).

        // Compute the offset vector once per pass so the steering lock and the
        // alignment error are always derived from the same prediction.
        SET vecSteer TO f9_boostback_steer_vector(predErr, params).
        SET alignmentError TO VANG(
            (SHIP:FACING * engineInfo["TiS"]:INVERSE):FOREVECTOR,
            vecSteer
        ).
        f9_print_target_position(targetContext).
        f9_print_recovery_vehicle().
        f9_print_at(
            12,
            "Predicted impact error: "
                + ROUND(predErr:MAG, 2) + " m"
        ).
        f9_print_at(
            13,
            "Alignment error: " + ROUND(alignmentError, 2) + " deg"
        ).
        f9_print_at(
            16,
            "Engines: burning  Throttle: "
                + ROUND(SHIP:CONTROL:MAINTHROTTLE, 2)
        ).
        WAIT 0.
    }

    // A prediction that failed inside the loop breaks out with a stale steering
    // vector, so the burn would fly on an outdated direction: give up before the
    // engine-mode switch and before the throttle leaves 0. done disarms the
    // steering and cutoff triggers of the aborted phase.
    IF NOT _predres["ok"] {
        SET done TO TRUE.
        f9_print_result("ERROR: LTR boostback prediction failed").
        RETURN f9_boostback_cutoff().
    }

    f9_print_at(11, "Phase: boostback - powered guidance").
    // Engine-mode control: the flip has reached burnAlignTolerance, so bring the
    // boostback group (Middle Eight) online. Middle Eight is a superset of
    // Middle Two, so this adds the outer ring to a burn that is already running
    // rather than relighting the stack; the throttle is already at
    // boostBackThrottle (1) and does not change.
    IF NOT f9_engine_mode_select_post_separation(params) {
        SET done TO TRUE.
        RETURN f9_boostback_cutoff().
    }
    f9_engine_activate(params, boostbackEngines).
    LOCK throttle TO params["boostBackThrottle"].
    LOCAL predictionFailed IS FALSE.
    f9_print_at(16, "Engines: active").
    WAIT 0.

    // Guidance with prediction latency
    // throttle and steering routine
    when (not done) then {
        // given last prediction, last time, current prediction, current time
        LOCAL currentErr TO predErr + errDot * (time:seconds - predTime).
        LOCAL errMagDot TO vDot(currentErr, errDot).
        IF (currentErr:mag <= 1000 AND errMagDot >= 0) {
            SET done TO true.
            LOCK THROTTLE TO 0.
        }
        return true.
    }
    UNTIL done {
        SET _predres TO f9_boostback_getImpactErr(params, targetContext, vecNormal).
        if not _predres["ok"] {
            SET predictionFailed TO TRUE.
            BREAK.
        }
        update_predictions(_predres["err"], _predres["time"]).
        // Refresh the steering vector every pass: the burn direction must keep
        // following the evolving impact error, not the alignment snapshot.
        SET vecSteer TO f9_boostback_steer_vector(predErr, params).

        LOCAL currentMagnitude IS predErr:MAG.
        f9_print_target_position(targetContext).
        f9_print_recovery_vehicle().
        f9_print_at(
            12,
            "Predicted impact error: "
                + ROUND(currentMagnitude, 2) + " m"
        ).
        f9_print_at(
            14,
            "errDot: "
                + ROUND(2*vDot(predErr, errDot)/max(0.01, predErr:mag), 2) + " m"
        ).
        f9_print_at(
            16,
            "Engines: active  Throttle: "
                + ROUND(SHIP:CONTROL:MAINTHROTTLE, 2)
        ).
        WAIT 0.
    }

    f9_print_at(11, "Phase: boostback - cutoff").
    f9_print_at(16, "Engines: cutoff  Throttle: 0.00").
    LOCK THROTTLE TO 0.
    // Hold the lock across one control update before releasing it: UNLOCK
    // leaves the last applied value, and an unapplied zero would leave the
    // boostback burn running after the phase.
    WAIT 0.
    f9_engine_deactivate(params, boostbackEngines).
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    IF predictionFailed {
        SET done TO TRUE.
        f9_print_result("ERROR: LTR boostback prediction failed").
        RETURN FALSE.
    }
    RETURN TRUE.
}
