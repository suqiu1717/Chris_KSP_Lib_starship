RUNONCEPATH("0:/lib/orbit.ks").
RUNONCEPATH("0:/lib/engine_utility.ks").

GLOBAL F9_DISPLAY_TERMINAL_WIDTH IS 50.
GLOBAL F9_DISPLAY_FIELD_WIDTH IS 48.
GLOBAL F9_GUIDANCE_FIRST_ROW IS 11.
GLOBAL F9_GUIDANCE_LAST_ROW IS 18.
GLOBAL F9_RESULT_ROW IS 21.
GLOBAL F9_LTR_INITIALIZED IS FALSE.

// Print into a fixed-width field so a shorter update erases the previous line.
FUNCTION f9_print_at {
    PARAMETER row.
    PARAMETER message.

    LOCAL lineText IS message + "".
    IF lineText:LENGTH > F9_DISPLAY_FIELD_WIDTH {
        SET lineText TO lineText:SUBSTRING(0, F9_DISPLAY_FIELD_WIDTH).
    } ELSE {
        SET lineText TO lineText:PADRIGHT(F9_DISPLAY_FIELD_WIDTH).
    }
    PRINT lineText AT(0, row).
}

FUNCTION f9_clear_display_rows {
    PARAMETER firstRow.
    PARAMETER lastRow.

    FROM {
        LOCAL row IS firstRow.
    } UNTIL row > lastRow STEP {
        SET row TO row + 1.
    } DO {
        f9_print_at(row, "").
    }
}

FUNCTION f9_clear_guidance_display {
    f9_clear_display_rows(
        F9_GUIDANCE_FIRST_ROW,
        F9_GUIDANCE_LAST_ROW
    ).
}

FUNCTION f9_print_result {
    PARAMETER message.
    f9_print_at(F9_RESULT_ROW, message).
}

FUNCTION f9_init_launch_display {
    SET TERMINAL:WIDTH TO F9_DISPLAY_TERMINAL_WIDTH.
    CLEARSCREEN.
    f9_print_at(0, "Falcon 9 Launch Guidance").
    f9_print_at(1, "--------------- VEHICLE ----------------").
    f9_print_at(9, "--------------- SEQUENCE ---------------").
    f9_print_at(20, "---------------- RESULT ----------------").
}

FUNCTION f9_print_target_position {
    PARAMETER targetContext.
    IF (targetContext["source"] = "none"
        AND NOT targetContext["resolved"]) {
        f9_print_at(3, "Lat/Lng: pending natural impact").
        f9_print_at(4, "Alt raw/off/final: pending").
        RETURN.
    }
    LOCAL targetGeo IS targetContext["geo"].

    f9_print_at(
        3,
        "Lat/Lng: " + ROUND(targetGeo:LAT, 4)
            + " / " + ROUND(targetGeo:LNG, 4)
    ).
    f9_print_at(
        4,
        "Alt raw/off/final: "
            + ROUND(targetContext["rawAltitude"], 1)
            + " / " + ROUND(targetContext["altitudeOffset"], 1)
            + " / " + ROUND(targetContext["altitude"], 1) + " m"
    ).
}

FUNCTION f9_init_recovery_display {
    PARAMETER targetContext.

    SET TERMINAL:WIDTH TO F9_DISPLAY_TERMINAL_WIDTH.
    CLEARSCREEN.
    f9_print_at(0, "Falcon 9 Recovery Guidance").
    f9_print_at(1, "---------------- TARGET ----------------").
    IF targetContext["source"] = "none" {
        f9_print_at(2, "Target source: natural impact (automatic)").
    } ELSE IF targetContext["source"] = "vessel" {
        f9_print_at(2, "Target source: vessel (moving)").
    } ELSE IF targetContext["source"] = "waypoint" {
        f9_print_at(2, "Target source: waypoint (fixed)").
    } ELSE {
        f9_print_at(2, "Target source: geoposition (fixed)").
    }
    f9_print_target_position(targetContext).
    f9_print_at(5, "--------------- VEHICLE ----------------").
    f9_print_at(10, "--------------- GUIDANCE ---------------").
    f9_print_at(20, "---------------- RESULT ----------------").
}

FUNCTION f9_print_recovery_vehicle {
    f9_print_at(6, "Altitude: " + ROUND(SHIP:ALTITUDE, 1) + " m").
    f9_print_at(
        7,
        "Speed: " + ROUND(SHIP:VELOCITY:SURFACE:MAG, 1)
            + " m/s  VSpeed: " + ROUND(SHIP:VERTICALSPEED, 1)
    ).
    f9_print_at(8, "Mass: " + ROUND(SHIP:MASS, 2) + " t").
}

// All recovery phases must start from the separated booster so engine lookup
// and FAR sampling do not use the complete launch stack. Boostback delay is
// only part of preparation when boostback will run, or when a natural-impact
// target must be selected after that delay.
FUNCTION f9_wait_for_recovery_start {
    PARAMETER params.

    f9_clear_guidance_display().
    f9_print_at(11, "Phase: recovery - waiting for separation").
    UNTIL SHIP:MASS < params["boostBackMass"] {
        f9_print_recovery_vehicle().
        f9_print_at(
            12,
            "Separation mass: < "
                + ROUND(params["boostBackMass"], 2) + " t"
        ).
        f9_print_at(16, "Engines: waiting").
        WAIT 0.
    }
    // Engine-mode handoff: the booster left the stack in the mode the ascent
    // script selected. The switch belongs here so it also runs when the
    // boostback phase is disabled. The delay is measured from this handoff.
    IF NOT f9_engine_mode_post_separation(params) {
        RETURN FALSE.
    }
    WAIT params["boostBackDelay"].
    RETURN TRUE.
}

// Acquire the configured landing site. The recovery boot file owns the
// selector and its associated value; no active waypoint or KSP target is
// consulted implicitly.
FUNCTION f9_initialize_target {
    PARAMETER params.

    LOCAL source IS params["landingSiteUse"].
    LOCAL rawAltitude IS 0.
    LOCAL targetGeo IS 0.
    LOCAL targetObject IS 0.
    LOCAL moving IS FALSE.

    IF source = "none" {
        // This placeholder is replaced with the predicted natural impact point
        // after separation and boostBackDelay. Sea level is the first-pass
        // prediction altitude; a second pass uses the terrain at that impact.
        SET targetGeo TO SHIP:GEOPOSITION.
        SET rawAltitude TO 0.
    } ELSE IF source = "geo" {
        LOCAL geoSpec IS params["landingSiteGeo"].
        IF geoSpec:LENGTH < 2 {
            PRINT "F9 target error: landingSiteGeo needs longitude and latitude".
            RETURN LEXICON("ok", FALSE, "source", source).
        }
        LOCAL _longitude IS geoSpec[0].
        LOCAL _latitude IS geoSpec[1].
        IF (_longitude < -180 OR _longitude > 180
            OR _latitude < -90 OR _latitude > 90) {
            PRINT "F9 target error: landingSiteGeo is out of range".
            RETURN LEXICON("ok", FALSE, "source", source).
        }
        SET targetGeo TO LATLNG(_latitude, _longitude).
        SET rawAltitude TO targetGeo:TERRAINHEIGHT.
    } ELSE IF source = "waypoint" {
        LOCAL waypointName IS params["landingSiteWaypoint"].
        LOCAL waypointList IS ALLWAYPOINTS().
        FOR waypoint IN waypointList {
            IF waypoint:NAME = waypointName {
                SET targetObject TO waypoint.
                BREAK.
            }
        }
        IF targetObject = 0 {
            PRINT "F9 target error: waypoint '" + waypointName
                + "' was not found".
            RETURN LEXICON("ok", FALSE, "source", source).
        }
        SET targetGeo TO targetObject:GEOPOSITION.
        SET rawAltitude TO targetObject:ALTITUDE.
    } ELSE IF source = "vessel" {
        LOCAL vesselName IS params["landingSiteVessel"].
        SET targetObject TO VESSEL(vesselName).
        IF targetObject:ISDEAD {
            PRINT "F9 target error: vessel '" + vesselName
                + "' was not found".
            RETURN LEXICON("ok", FALSE, "source", source).
        }
        SET targetGeo TO targetObject:GEOPOSITION.
        SET rawAltitude TO targetObject:ALTITUDE.
        SET moving TO TRUE.
    } ELSE {
        PRINT "F9 target error: landingSiteUse must be none, geo, waypoint, or vessel".
        RETURN LEXICON("ok", FALSE, "source", source).
    }

    RETURN LEXICON(
        "ok", TRUE,
        "source", source,
        "resolved", source <> "none",
        "moving", moving,
        "geo", targetGeo,
        "rawAltitude", rawAltitude,
        "altitudeOffset", params["altitudeOffset"],
        "altitude", rawAltitude + params["altitudeOffset"],
        "object", targetObject
    ).
}

// Resolve landingSiteUse = "none" to the natural LTR impact point. The first
// prediction crosses sea level; the second repeats at the terrain/ocean level
// found under that impact. The final geoposition is written into targetContext
// so all later phases use the same fixed site.
FUNCTION f9_resolve_automatic_target {
    PARAMETER params.
    PARAMETER targetContext.

    IF targetContext["source"] <> "none" OR targetContext["resolved"] {
        RETURN TRUE.
    }
    IF NOT f9_initialize_ltr(params) {
        SET targetContext["ok"] TO FALSE.
        RETURN FALSE.
    }

    LOCAL vecNormal IS f9_get_surface_normal().
    FROM {
        LOCAL pass IS 0.
    } UNTIL pass >= 2 STEP {
        SET pass TO pass + 1.
    } DO {
        LOCAL prediction IS 0.
        IF params["enableEntryBurn"] {
            SET prediction TO f9_ltr_predict(
                params,
                targetContext,
                vecNormal,
                params["entryBurnAlt"],
                params["entryVSpeed"],
                params["landingBurnAltitude"]
            ).
        } ELSE {
            SET prediction TO f9_ltr_predict(
                params,
                targetContext,
                vecNormal,
                9999999999,
                9999999999,
                params["landingBurnAltitude"]
            ).
        }
        IF NOT f9_ltr_prediction_is_valid(prediction) {
            f9_print_result("ERROR: LTR automatic target prediction failed").
            SET targetContext["ok"] TO FALSE.
            RETURN FALSE.
        }

        // LTR positions are body-centred (SOI-RAW). GEOPOSITIONOF expects a
        // SHIP-RAW position, so move the origin back to the current vessel.
        LOCAL impactPosition IS prediction["finalVecR"]
            + SHIP:BODY:POSITION.
        LOCAL targetGeo IS SHIP:BODY:GEOPOSITIONOF(impactPosition).
        LOCAL rawAltitude IS targetGeo:TERRAINHEIGHT.
        IF SHIP:BODY:HASOCEAN AND rawAltitude < 0 {
            SET rawAltitude TO 0.
        }
        SET targetContext["geo"] TO targetGeo.
        SET targetContext["rawAltitude"] TO rawAltitude.
        SET targetContext["altitude"] TO rawAltitude
            + targetContext["altitudeOffset"].
    }

    SET targetContext["moving"] TO FALSE.
    SET targetContext["object"] TO 0.
    SET targetContext["resolved"] TO TRUE.
    SET targetContext["ok"] TO TRUE.
    RETURN TRUE.
}

FUNCTION f9_refresh_target {
    PARAMETER targetContext.
    IF targetContext["moving"] {
        SET targetContext["geo"] TO targetContext["object"]:GEOPOSITION.
        SET targetContext["rawAltitude"]
            TO targetContext["object"]:ALTITUDE.
        SET targetContext["altitude"]
            TO targetContext["rawAltitude"]
                + targetContext["altitudeOffset"].
    }
    RETURN targetContext["geo"].
}

FUNCTION f9_get_target_position {
    PARAMETER targetContext.
    RETURN targetContext["geo"]:ALTITUDEPOSITION(
        targetContext["altitude"]
    ).
}

FUNCTION f9_get_surface_normal {
    LOCAL unitR IS -SHIP:BODY:POSITION:NORMALIZED.
    LOCAL orbitNormal IS VCRS(unitR, SHIP:VELOCITY:SURFACE):NORMALIZED.
    IF orbitNormal:MAG < 1e-4 {
        RETURN NORTH:FOREVECTOR.
    }
    RETURN orbitNormal.
}

// aeroTargetOffset is always measured along the booster's downrange axis.
// Keeping this in one helper ensures boostback, entry, and glide all aim at
// the same offset point while powered landing continues to use the raw target.
FUNCTION f9_get_aero_target_position {
    PARAMETER params.
    PARAMETER targetContext.
    PARAMETER vecNormal.

    LOCAL downrangeAxis IS VCRS(vecNormal, UP:FOREVECTOR).
    IF downrangeAxis:MAG < 0.000001 {
        SET downrangeAxis TO VXCL(
            UP:FOREVECTOR,
            SHIP:VELOCITY:SURFACE
        ).
    }
    IF downrangeAxis:MAG < 0.000001 {
        SET downrangeAxis TO NORTH:FOREVECTOR.
    } ELSE {
        SET downrangeAxis TO downrangeAxis:NORMALIZED.
    }
    RETURN f9_get_target_position(targetContext)
        + params["aeroTargetOffset"] * downrangeAxis.
}

FUNCTION f9_initialize_ltr_body {
    PARAMETER ltr.

    // Let the addon build its atmosphere interpolation tables automatically.
    // All other body parameters are assigned explicitly because the values in
    // LTR's C# constructor are only external-test fixtures. BODY:ANGULARVEL is
    // in the same raw reference frame as the body-centred prediction state.
    ltr:InitAtmModel().
    // There is something wrong with CelestialBody.angularVel API, so here we set it with kOS values
    SET ltr:bodySpin TO BODY:ANGULARVEL.
    RETURN TRUE.
}

// Initialize LTR only after stage separation so FAR samples the booster rather
// than the complete launch stack. The coefficient matrices use speed rows and
// altitude/density columns, matching kOS-AFS and kOS-LTR.
FUNCTION f9_initialize_ltr {
    PARAMETER params.
    // IF F9_LTR_INITIALIZED {
    //     RETURN TRUE.
    // }
    IF NOT ADDONS:HASADDON("LTR") {
        f9_print_result("ERROR: kOS-LTR addon is unavailable").
        RETURN FALSE.
    }

    LOCAL ltr IS ADDONS:LTR.
    IF NOT f9_initialize_ltr_body(ltr) {
        RETURN FALSE.
    }
    SET ltr:MASS TO SHIP:MASS.
    SET ltr:AREA TO ltr:REFAREA.
    SET ltr:AOAReversal TO FALSE.
    SET ltr:CtrlSpeedSamples TO params["ltrCtrlSpeedSamples"].
    SET ltr:CtrlAOASamples TO params["ltrCtrlAOASamples"].
    SET ltr:predict_min_step TO params["ltrPredictMinStep"].
    SET ltr:predict_max_step TO params["ltrPredictMaxStep"].
    SET ltr:predict_tmax TO params["ltrPredictTMax"].
    SET ltr:rotation TO R(180, 0, params["targetRoll"]).

    LOCAL cdRows IS LIST().
    LOCAL clRows IS LIST().
    FOR speed IN params["ltrAeroSpeedSamples"] {
        LOCAL cdRow IS LIST().
        LOCAL clRow IS LIST().
        LOCAL aoaCommand IS ltr:GetAOACmd(speed)["AOA"].
        FOR sampleAltitude IN params["ltrAeroAltitudeSamples"] {
            LOCAL coefficients IS ltr:GetFARAeroCoefs(LEXICON(
                "altitude", sampleAltitude,
                "speed", speed,
                "AOA", aoaCommand
            )).
            cdRow:ADD(coefficients["Cd"] * params["ltrCdFactor"]).
            clRow:ADD(coefficients["Cl"] * params["ltrClFactor"]).
        }
        cdRows:ADD(cdRow).
        clRows:ADD(clRow).
    }
    SET ltr:AeroSpeedSamples TO params["ltrAeroSpeedSamples"].
    ltr:SetAeroDsFromAlt(params["ltrAeroAltitudeSamples"]).
    SET ltr:AeroCdSamples TO cdRows.
    SET ltr:AeroClSamples TO clRows.
    SET F9_LTR_INITIALIZED TO TRUE.
    RETURN TRUE.
}

// Run one prediction from the latest state. Async execution yields the kOS CPU
// while the C# RKF45 integrator works, then returns a result and the exact target
// vector used for that prediction.
// When the vessel hits entryAlt, the rocket burn retrograde to reduce speed to entrySpeed
// When the vessel hits burnAltitude, the predictor assumes that the rocket ignite its landing engines
// and fly a parabola trajectory down. So it calculates a simple offset to the predicted
// impact point.
FUNCTION f9_ltr_predict {
    PARAMETER params.
    PARAMETER targetContext.
    PARAMETER vecNormal.
    PARAMETER entryAlt IS 9999999999.
    PARAMETER entrySpeed IS 9999999999.
    PARAMETER burnAltitude IS 0.

    f9_refresh_target(targetContext).
    LOCAL targetPosition IS f9_get_aero_target_position(
        params,
        targetContext,
        vecNormal
    ).
    LOCAL targetBodyPosition IS targetPosition - SHIP:BODY:POSITION.
    LOCAL ltr IS ADDONS:LTR.
    SET ltr:MASS TO SHIP:MASS.
    SET ltr:RTarget TO targetBodyPosition.

    LOCAL initVecR TO -ship:body:position.
    LOCAL initVecV TO ship:velocity:surface.
    LOCAL vecR to initVecR.
    LOCAL vecV to initVecV.
    LOCAL tt TO 0.
    if (ship:altitude > entryAlt) {
        // Propagate to entry interface
        SET ltr:target_altitude TO entryAlt.
        LOCAL handle IS ltr:AsyncSimAtmTraj(LEXICON(
            "t", tt,
            "vecR", vecR,
            "vecV", vecV
        )).
        UNTIL ltr:CheckTask(handle) {
            1.
        }
        LOCAL result IS ltr:GetTaskResult(handle).
        SET tt TO result["t"].
        SET vecR TO result["finalVecR"].
        SET vecV TO result["finalVecV"].
        SET vecV TO vecV:normalized * min(entrySpeed, vecV:mag).
    }

    SET ltr:target_altitude TO targetContext["altitude"].
    // LOCAL state IS ltr:GetState().
    // LOCAL state IS LEXICON("vecR", -ship:body:position, "vecV", ship:velocity:surface).
    LOCAL handle IS ltr:AsyncSimAtmTraj(LEXICON(
        "t", tt,
        "vecR", vecR,
        "vecV", vecV
    )).
    UNTIL ltr:CheckTask(handle) {
        1.
    }
    LOCAL result IS ltr:GetTaskResult(handle).
    local finalVecR to result["finalVecR"].
    local finalVecV to result["finalVecV"].
    local finalFPA to min(-10, 90 - vAng(finalVecR, finalVecV)).
    local downrangeAxis to vxcl(finalVecR, finalVecV):normalized.
    set result["finalVecR"] to finalVecR + 0.33*burnAltitude/tan(finalFPA)*downrangeAxis.
    SET result["initialVecR"] TO initVecR.
    SET result["initialVecV"] TO initVecV.
    // Refresh ship-relative geometry after the asynchronous calculation. The
    // prediction state remains the captured initial state above.
    f9_refresh_target(targetContext).
    SET targetPosition TO f9_get_aero_target_position(
        params,
        targetContext,
        vecNormal
    ).
    SET targetBodyPosition TO targetPosition - SHIP:BODY:POSITION.
    SET result["targetPosition"] TO targetPosition.
    SET result["targetBodyPosition"] TO targetBodyPosition.
    RETURN result.
}

FUNCTION f9_ltr_prediction_is_valid {
    PARAMETER prediction.
    RETURN prediction["ok"]
        AND prediction["status"] = "COMPLETED".
}

// PEGLand-style steering: burnVector is the desired acceleration direction,
// TiS is Engine:facing:inverse * Ship:facing, and targetRoll fixes roll.
// The top vector is built as normal x fore, the same argument order
// f9_lock_roll_zero uses, so the powered phases hold the aerodynamic roll zero.
// The opposite order (fore x normal) is the same reference turned 180 degrees
// about the fore axis, which the entry burn used to hand to the following
// aerodynamic phase as a roll flip. The aerodynamic reference is the
// anti-parallel wind direction, and f9_get_aero_steering turns it into the
// vessel attitude with its own 180 degree pitch, so this order, not the
// mirrored one, is what lands on the aerodynamic roll zero.
FUNCTION f9_get_target_steering {
    PARAMETER burnVector.
    PARAMETER TiS.
    PARAMETER targetRoll.
    PARAMETER vecNormal is 0.

    IF burnVector:MAG < 0.000001 {
        RETURN SHIP:FACING.
    }
    LOCAL topVector IS V(0,0,0).
    if (vecNormal <> 0)  SET topVector TO VCRS(vecNormal, burnVector).
    ELSE SET topVector TO VCRS(f9_get_surface_normal(), burnVector).
    IF topVector:MAG < 0.000001 {
        SET topVector TO NORTH:FOREVECTOR.
    }
    RETURN LOOKDIRUP(burnVector, topVector) * R(0, 0, targetRoll) * TiS.
}

// Lock the roll of a steering direction to the recovery roll-zero reference:
// the ship top vector is built as orbit normal x fore, so the roll about the
// fore axis is deterministic. Swapping the two VCRS arguments flips the roll
// zero by 180 degrees.
FUNCTION f9_lock_roll_zero {
    PARAMETER direction.
    PARAMETER vecNormal is 0.

    IF vecNormal = 0 {
        SET vecNormal TO f9_get_surface_normal().
    }
    LOCAL topVector IS VCRS(direction:FOREVECTOR, vecNormal).
    IF topVector:MAG < 0.000001 {
        SET topVector TO NORTH:FOREVECTOR.
    }
    RETURN LOOKDIRUP(direction:FOREVECTOR, topVector).
}

// UEntry-style steering: Give desired plane-like direction then transform it into vessel direction.
// The roll is explicitly locked (see f9_lock_roll_zero) instead of inheriting
// srfPrograde's implicit roll.
FUNCTION f9_get_aero_steering {
    PARAMETER desiredDirection.
    PARAMETER vecNormal is 0.

    RETURN f9_lock_roll_zero(desiredDirection, vecNormal) * ADDONS:LTR:rotation:INVERSE.
}

FUNCTION f9_get_boostback_error {
    PARAMETER prediction.
    RETURN prediction["targetBodyPosition"]
        - prediction["finalVecR"].
}

FUNCTION f9_step_entry_vgo {
    PARAMETER params.
    PARAMETER targetContext.
    PARAMETER vecVGO.
    PARAMETER vecNormal.

    LOCAL vecR TO -body:position.
    LOCAL vecV TO ship:velocity:surface.
    LOCAL entrySpeed TO params["entryVSpeed"].
    LOCAL g0 TO ship:body:mu / ship:body:radius^2.
    LOCAL burnAltitude TO params["landingBurnAltitude"].

    f9_refresh_target(targetContext).
    LOCAL targetPosition IS f9_get_aero_target_position(
        params,
        targetContext,
        vecNormal
    ).
    LOCAL vecRT IS targetPosition - SHIP:BODY:POSITION.
    LOCAL ltr IS ADDONS:LTR.
    SET ltr:MASS TO SHIP:MASS.
    SET ltr:RTarget TO vecRT.

    // 1. normalize VGO to meet entry speed constraint
    LOCAL unitVGO TO vecVGO:normalized.
    LOCAL xx TO vDot(vecV, unitVGO).
    LOCAL _m TO xx^2 - (vecV:mag^2 - entrySpeed^2).
    IF (_m <= 0) {
        SET vecVGO TO (entrySpeed - vecV:mag) * vecV:normalized.
    }
    ELSE {
        LOCAL vgo IS -xx - sqrt(xx^2 - (vecV:mag^2 - entrySpeed^2)).
        SET vecVGO TO vgo * unitVGO.
    }
    // 2. evaluate reaching time
    LOCAL upAxis TO vecRT:normalized.
    LOCAL vy TO vDot(vecV + vecVGO, upAxis).
    LOCAL ry TO vDot(vecR - vecRT, upAxis).
    LOCAL tt TO (vy + sqrt(vy^2 + 2*g0*ry)) / g0.
    // 3. predict impact point
    SET ltr:target_altitude TO targetContext["altitude"].
    LOCAL handle IS ltr:AsyncSimAtmTraj(LEXICON(
        "t", 0,
        "vecR", vecR,
        "vecV", vecV + vecVGO
    )).
    UNTIL ltr:CheckTask(handle) {
        1.
    }
    LOCAL result IS ltr:GetTaskResult(handle).
    IF (result["status"] <> "COMPLETED") RETURN LEXICON(
        "ok", FALSE,
        "msg", result["msg"],
        "vecVGO", vecVGO
    ).
    LOCAL vecRP TO result["finalVecR"].
    LOCAL vecVP TO result["finalVecV"].
    local finalFPA to min(-10, 90 - vAng(vecRP, vecVP)).
    local downrangeAxis to vxcl(vecRP, vecVP):normalized.
    set vecRP to vecRP + 0.33*burnAltitude/tan(finalFPA)*downrangeAxis.
    // 4. update vecVGO
    SET vecVGO TO vecVGO + (vecRT - vecRP) / tt.
    IF vAng(vecVGO, -vecV) > 30 {
        SET vecVGO TO angleAxis(30, vCrs(-vecV, vecVGO)) * (-vecV):normalized * vecVGO:mag.
    }
    return LEXICON(
        "ok", TRUE,
        "msg", result["msg"],
        "vecVGO", vecVGO
    ).
}

FUNCTION f9_get_bottom_height {
    PARAMETER TiS.
    LOCAL thrustDown IS -(SHIP:FACING * TiS:INVERSE):FOREVECTOR.
    RETURN get_furtherst_height(SHIP:BOUNDS, thrustDown).
}

FUNCTION f9_get_bottom_altitude {
    PARAMETER targetPosition.
    PARAMETER bottomHeight.
    LOCAL bottomPosition IS SHIP:POSITION - bottomHeight * UP:FOREVECTOR.
    RETURN VDOT(bottomPosition - targetPosition, UP:FOREVECTOR).
}

FUNCTION f9_continuous_throttle {
    PARAMETER requestedFraction.
    PARAMETER minThrottle.
    PARAMETER minCommand.
    RETURN MAX(minCommand, MIN(1, simple_get_throttle(requestedFraction, minThrottle))).
}

// ---------------------------------------------------------------------------
// SEP engine-mode control. Only active when the optional "engineModeControl"
// key is TRUE, so every other vehicle keeps the tag + activate/shutdown path.
//
// The StarshipExpansionProject booster cluster carries one
// ModuleSEPEngineSwitch and four ModuleEnginesFX on a single part, so engine
// tags cannot split it into groups and kOS sees the four modules as one
// aggregated engine. The switch owns ignition and shutdown: selecting a mode
// lights the selected engine group and shuts the other groups down. Values
// kOS cannot read back (mode table, group thrust) live in the boot lexicon;
// use sepmodeprobe.ks to calibrate them.
GLOBAL F9_ENGINE_MODE_INDEX IS -1.

FUNCTION f9_engine_mode_enabled {
    PARAMETER params.

    IF params:HASKEY("engineModeControl") {
        IF params["engineModeControl"] {
            RETURN TRUE.
        }
    }
    RETURN FALSE.
}

FUNCTION f9_engine_mode_module {
    PARAMETER params.

    LOCAL moduleName IS "ModuleSEPEngineSwitch".
    IF params:HASKEY("engineModeModuleName") {
        SET moduleName TO params["engineModeModuleName"].
    }
    LOCAL modules IS SHIP:MODULESNAMED(moduleName).
    IF modules:LENGTH = 0 {
        RETURN 0.
    }
    RETURN modules[0].
}

// Read the live mode index, or -1 when the game does not expose it.
FUNCTION f9_engine_mode_read {
    PARAMETER params.

    LOCAL modeModule IS f9_engine_mode_module(params).
    IF modeModule = 0 {
        RETURN -1.
    }
    IF NOT params:HASKEY("engineModeNames") {
        RETURN -1.
    }
    // kOS addresses fields by the name shown in the GUI, so the method name
    // and the localized label are both worth trying.
    LOCAL display IS "".
    FOR fieldName IN LIST("currentEngineDisplay", "Mode") {
        IF display = "" {
            IF modeModule:HASFIELD(fieldName) {
                SET display TO modeModule:GETFIELD(fieldName) + "".
            }
        }
    }
    IF display = "" {
        RETURN -1.
    }
    LOCAL names IS params["engineModeNames"].
    FROM {
        LOCAL i IS 0.
    } UNTIL i >= names:LENGTH STEP {
        SET i TO i + 1.
    } DO {
        IF names[i] = display {
            RETURN i.
        }
    }
    RETURN -1.
}

FUNCTION f9_engine_mode_begin {
    PARAMETER params.

    IF F9_ENGINE_MODE_INDEX >= 0 {
        RETURN TRUE.
    }
    LOCAL modeModule IS f9_engine_mode_module(params).
    IF modeModule = 0 {
        f9_print_result("ERROR: SEP engine-mode module was not found").
        RETURN FALSE.
    }
    // Verify on the pad, not at MECO: a name that kOS cannot invoke is the
    // usual reason a mode switch never happens.
    IF NOT f9_engine_mode_step_available(params, TRUE)
        OR NOT f9_engine_mode_step_available(params, FALSE) {
        f9_engine_mode_report_unavailable(modeModule).
        RETURN FALSE.
    }
    LOCAL index IS f9_engine_mode_read(params).
    IF index < 0 {
        IF NOT params:HASKEY("engineModeInitial") {
            RETURN FALSE.
        }
        SET index TO ROUND(params["engineModeInitial"]).
    }
    SET F9_ENGINE_MODE_INDEX TO index.
    RETURN TRUE.
}

FUNCTION f9_engine_mode_name {
    PARAMETER params.

    IF F9_ENGINE_MODE_INDEX < 0 {
        RETURN "unknown".
    }
    IF params:HASKEY("engineModeNames") {
        LOCAL names IS params["engineModeNames"].
        IF F9_ENGINE_MODE_INDEX < names:LENGTH {
            RETURN names[F9_ENGINE_MODE_INDEX].
        }
    }
    RETURN "index " + F9_ENGINE_MODE_INDEX.
}

// Names that may step the switch, best first. kOS matches the name shown in
// the action-group editor, which for this mod is the text behind
// "#LOC_SEP_NextEngineMode" / "#LOC_SEP_PreviousEngineMode"; the method names
// KSP stores in the craft file (NextEngineModeAction / PreviousEngineModeAction,
// see the saved craft's ACTIONS block) are listed as well, so an install that
// matches those still works. The boot value is tried first, so a rename only
// needs a boot edit. The localization tag itself is listed last, for a kOS
// build that compares the raw KSPAction string instead of its localized label.
FUNCTION f9_engine_mode_step_names {
    PARAMETER params.
    PARAMETER forward.

    LOCAL names IS LIST().
    IF forward AND params:HASKEY("engineModeNextAction") {
        names:ADD(params["engineModeNextAction"]).
    }
    IF (NOT forward) AND params:HASKEY("engineModePreviousAction") {
        names:ADD(params["engineModePreviousAction"]).
    }
    IF forward {
        names:ADD("Next Engine Mode").
        names:ADD("NextEngineModeAction").
        names:ADD("#LOC_SEP_NextEngineMode").
    } ELSE {
        names:ADD("Previous Engine Mode").
        names:ADD("PreviousEngineModeAction").
        names:ADD("#LOC_SEP_PreviousEngineMode").
    }
    RETURN names.
}

// Whether a name this install accepts can be invoked at all, using the same
// resolution order as f9_engine_mode_step. The listed-name scans require the
// matching HASACTION/HASEVENT flag, so this predicate stays exactly as strict
// as what f9_engine_mode_step will actually do.
FUNCTION f9_engine_mode_step_available {
    PARAMETER params.
    PARAMETER forward.

    LOCAL modeModule IS f9_engine_mode_module(params).
    IF modeModule = 0 {
        RETURN FALSE.
    }
    LOCAL direction IS "Previous".
    IF forward {
        SET direction TO "Next".
    }
    FOR name IN f9_engine_mode_step_names(params, forward) {
        IF modeModule:HASACTION(name) OR modeModule:HASEVENT(name) {
            RETURN TRUE.
        }
    }
    FOR entry IN modeModule:ALLACTIONNAMES {
        IF entry:CONTAINS(direction) AND modeModule:HASACTION(entry) {
            RETURN TRUE.
        }
    }
    FOR entry IN modeModule:ALLEVENTNAMES {
        IF entry:CONTAINS(direction) AND modeModule:HASEVENT(entry) {
            RETURN TRUE.
        }
    }
    RETURN FALSE.
}

FUNCTION f9_engine_mode_step {
    PARAMETER params.
    PARAMETER forward.

    LOCAL modeModule IS f9_engine_mode_module(params).
    IF modeModule = 0 {
        RETURN FALSE.
    }
    LOCAL names IS f9_engine_mode_step_names(params, forward).
    FOR actionName IN names {
        IF modeModule:HASACTION(actionName) {
            modeModule:DOACTION(actionName, TRUE).
            WAIT 0.
            RETURN TRUE.
        }
    }
    // A career save can withhold actions until the action groups are unlocked;
    // the right-click event runs the same code and stays available.
    FOR eventName IN names {
        IF modeModule:HASEVENT(eventName) {
            modeModule:DOEVENT(eventName).
            WAIT 0.
            RETURN TRUE.
        }
    }
    // Renamed entries: fall back to whatever listed name carries the direction.
    // Only entries the matcher accepts are invoked, so a listed name that
    // HASACTION/HASEVENT rejects cannot turn into a DOACTION/DOEVENT exception
    // that kills the flight script.
    LOCAL direction IS "Previous".
    IF forward {
        SET direction TO "Next".
    }
    FOR entry IN modeModule:ALLACTIONNAMES {
        IF entry:CONTAINS(direction) AND modeModule:HASACTION(entry) {
            modeModule:DOACTION(entry, TRUE).
            WAIT 0.
            RETURN TRUE.
        }
    }
    FOR entry IN modeModule:ALLEVENTNAMES {
        IF entry:CONTAINS(direction) AND modeModule:HASEVENT(entry) {
            modeModule:DOEVENT(entry).
            WAIT 0.
            RETURN TRUE.
        }
    }
    f9_engine_mode_report_unavailable(modeModule).
    RETURN FALSE.
}

// Failure diagnostics: the names this install does offer, together with the
// flag the matcher returns for each one. A name flagged True can be pasted
// into engineModeNextAction / engineModePreviousAction; a name that is listed
// but flagged False means the listed names and the matcher disagree, which is
// the case the boot override exists for. Printed as scrolling text rather than
// into the 48-character result row, which would truncate the list away.
FUNCTION f9_engine_mode_report_unavailable {
    PARAMETER modeModule.

    f9_print_result("ERROR: no usable engine-mode step name").
    PRINT "Engine mode names on " + modeModule:NAME + ":".
    FOR actionName IN modeModule:ALLACTIONNAMES {
        PRINT "  action [" + actionName + "] accepted="
            + modeModule:HASACTION(actionName).
    }
    FOR eventName IN modeModule:ALLEVENTNAMES {
        PRINT "  event [" + eventName + "] accepted="
            + modeModule:HASEVENT(eventName).
    }
}

// Step the switch to the target index, taking the shorter way around the
// cyclic mode list. When the game exposes the current mode the tracker is
// re-synchronized first, so a manual mode change does not desync the script.
FUNCTION f9_engine_mode_goto {
    PARAMETER params.
    PARAMETER target.

    IF NOT f9_engine_mode_enabled(params) {
        RETURN TRUE.
    }
    IF NOT f9_engine_mode_begin(params) {
        RETURN FALSE.
    }
    LOCAL count IS 4.
    IF params:HASKEY("engineModeCount") {
        SET count TO ROUND(params["engineModeCount"]).
    }
    // A cyclic table with fewer than one entry would make the step counts
    // meaningless, and an index outside the table cannot be reached.
    IF count < 1 {
        f9_print_result("ERROR: engineModeCount must be at least 1").
        RETURN FALSE.
    }
    LOCAL targetIndex IS ROUND(target).
    IF targetIndex < 0 OR targetIndex >= count {
        f9_print_result(
            "ERROR: engine mode index " + targetIndex + " is out of range"
        ).
        RETURN FALSE.
    }
    LOCAL current IS f9_engine_mode_read(params).
    IF current < 0 OR current >= count {
        SET current TO F9_ENGINE_MODE_INDEX.
    }
    // Fail rather than step blindly: the caller keeps the thrust data of the
    // group that is actually lit and retries on the next pass.
    IF current < 0 OR current >= count {
        f9_print_result("ERROR: current engine mode index is unknown").
        RETURN FALSE.
    }
    IF current = targetIndex {
        SET F9_ENGINE_MODE_INDEX TO current.
        RETURN TRUE.
    }

    LOCAL forwardSteps IS targetIndex - current.
    IF forwardSteps < 0 {
        SET forwardSteps TO forwardSteps + count.
    }
    LOCAL backwardSteps IS count - forwardSteps.
    IF forwardSteps <= backwardSteps {
        FROM {
            LOCAL i IS 0.
        } UNTIL i >= forwardSteps STEP {
            SET i TO i + 1.
        } DO {
            IF NOT f9_engine_mode_step(params, TRUE) {
                RETURN FALSE.
            }
        }
    } ELSE {
        FROM {
            LOCAL i IS 0.
        } UNTIL i >= backwardSteps STEP {
            SET i TO i + 1.
        } DO {
            IF NOT f9_engine_mode_step(params, FALSE) {
                RETURN FALSE.
            }
        }
    }
    SET F9_ENGINE_MODE_INDEX TO targetIndex.
    RETURN TRUE.
}

// Thrust data of one engine-mode group. kOS aggregates the four modules on the
// cluster part, so the numbers come from the boot lexicon; only the thrust axis
// is measured live from the tagged engines.
FUNCTION f9_engine_mode_engine_data {
    PARAMETER params.
    PARAMETER dataKey.

    LOCAL data IS params[dataKey].
    LOCAL result IS LEXICON(
        "thrust", data["thrust"],
        "minthrottle", data["minthrottle"],
        "spooluptime", data["spooluptime"],
        "TiS", R(180, 0, 0)
    ).
    LOCAL engines IS LIST().
    IF params:HASKEY("engineModeEngineTag") {
        SET engines TO search_engine(params["engineModeEngineTag"]).
    }
    IF engines:LENGTH = 0 {
        LIST ENGINES IN engines.
    }
    IF engines:LENGTH > 0 {
        LOCAL info IS get_engines_info(engines).
        IF info["thrust"] > 0 {
            SET result["TiS"] TO info["TiS"].
        }
    }
    RETURN result.
}

// Select the post-separation engine group (Middle Eight). The boostback phase
// calls this at the moment its flip reaches burnAlignTolerance, so the burn
// lights up on the full boostback group.
FUNCTION f9_engine_mode_select_post_separation {
    PARAMETER params.

    IF NOT f9_engine_mode_enabled(params) {
        RETURN TRUE.
    }
    IF NOT f9_engine_mode_goto(params, params["engineModePostSeparation"]) {
        f9_print_result("ERROR: engine-mode post-separation switch failed").
        RETURN FALSE.
    }
    f9_print_at(16, "Engine mode: " + f9_engine_mode_name(params)).
    RETURN TRUE.
}

// Separation handoff. With boostback enabled the switch belongs to the
// boostback phase, which knows when the booster is aligned; that phase holds the
// inherited hot-staging throttle through the predictions and the flip and cuts
// the burn when its guidance ends. Without boostback there is no alignment to
// wait for, so cut the burn here and fall back to a fixed delay after
// separation.
FUNCTION f9_engine_mode_post_separation {
    PARAMETER params.

    IF NOT f9_engine_mode_enabled(params) {
        RETURN TRUE.
    }
    IF NOT f9_engine_mode_begin(params) {
        // begin() already reported the specific reason.
        RETURN FALSE.
    }
    IF params:HASKEY("enableBoostBack") AND params["enableBoostBack"] {
        RETURN TRUE.
    }
    // Nothing takes the inherited throttle over on this path, and the mode
    // switch below must not light the post-separation group under thrust, so
    // cut the burn at the handoff: the boostback-disabled profile (the ASDS
    // survey configuration) then coasts from separation on with the engines
    // lit at throttle 0.
    LOCK THROTTLE TO 0.
    WAIT params["engineModeSeparationDelay"].
    RETURN f9_engine_mode_select_post_separation(params).
}

// Gated wrappers: under engine-mode control the SEP switch owns ignition and
// shutdown, so the legacy calls become no-ops for this vehicle only.
FUNCTION f9_engine_activate {
    PARAMETER params.
    PARAMETER engines.

    IF f9_engine_mode_enabled(params) {
        RETURN TRUE.
    }
    activate_engines(engines).
    RETURN TRUE.
}

FUNCTION f9_engine_deactivate {
    PARAMETER params.
    PARAMETER engines.

    IF f9_engine_mode_enabled(params) {
        RETURN TRUE.
    }
    deactivate_engines(engines).
    RETURN TRUE.
}

// Mode indices address the configured cyclic table; an index outside it would
// make the shortest-path step count in f9_engine_mode_goto meaningless. Only
// call this for a key that f9_validate_required_keys already found.
FUNCTION f9_engine_mode_index_valid {
    PARAMETER params.
    PARAMETER indexKey.

    LOCAL count IS ROUND(params["engineModeCount"]).
    LOCAL index IS ROUND(params[indexKey]).
    IF index < 0 OR index >= count {
        PRINT "F9 config error: " + indexKey + " must be inside 0.."
            + (count - 1) + " (engineModeCount)".
        RETURN FALSE.
    }
    RETURN TRUE.
}

FUNCTION f9_validate_required_keys {
    PARAMETER params.
    PARAMETER requiredKeys.
    PARAMETER context IS "configuration".

    IF NOT params:HASSUFFIX("HASKEY") {
        PRINT "F9 " + context + " config error: params must be a lexicon".
        RETURN FALSE.
    }

    LOCAL ok IS TRUE.
    FOR key IN requiredKeys {
        IF NOT params:HASKEY(key) {
            PRINT "F9 " + context + " config error: missing required key '"
                + key + "'".
            SET ok TO FALSE.
        }
    }
    RETURN ok.
}

FUNCTION f9_validate_launch_params {
    PARAMETER params.

    LOCAL requiredKeys IS LIST(
        "kOSIPU", "liftoffEngineTag", "mecoMass", "targetHeading",
        "turnSpeed", "pitchOmega", "stageSeparationDelay",
        "upperStageIgnitionDelay"
    ).
    IF NOT f9_validate_required_keys(params, requiredKeys, "launch") {
        RETURN FALSE.
    }

    LOCAL ok IS TRUE.
    IF params["mecoMass"] <= 0 {
        PRINT "F9 config error: mecoMass must be positive".
        SET ok TO FALSE.
    }
    IF (params["turnSpeed"] <= 0 OR params["pitchOmega"] <= 0) {
        PRINT "F9 config error: turnSpeed and pitchOmega must be positive".
        SET ok TO FALSE.
    }
    IF f9_engine_mode_enabled(params) {
        IF NOT f9_validate_required_keys(
            params,
            LIST(
                "engineModeInitial", "engineModePreSeparation",
                "engineModePreSeparationMass", "engineModeCount"
            ),
            "launch engine mode"
        ) {
            SET ok TO FALSE.
        } ELSE {
            IF params["engineModePreSeparationMass"] < 0 {
                PRINT "F9 config error: engineModePreSeparationMass must not be negative".
                SET ok TO FALSE.
            }
            FOR modeIndexKey IN LIST(
                "engineModeInitial", "engineModePreSeparation"
            ) {
                IF NOT f9_engine_mode_index_valid(params, modeIndexKey) {
                    SET ok TO FALSE.
                }
            }
        }
    }
    RETURN ok.
}

FUNCTION f9_validate_recovery_params {
    PARAMETER params.

    LOCAL requiredKeys IS LIST(
        "kOSIPU", "boostbackEngineTag", "entryEngineTag",
        "landingDecEngineTag", "landingEngineTag", "boostBackMass",
        "landingSiteUse", "enableBoostBack", "enableEntryBurn",
        "targetRoll", "altitudeOffset", "boostBackDelay", "boostBackThrottle",
        "entryBurnAlt", "entryVSpeed", "entryThrottle",
        "burnAlignTolerance", "ltrCtrlSpeedSamples",
        "ltrCtrlAOASamples",
        "ltrAeroSpeedSamples", "ltrAeroAltitudeSamples", "ltrCdFactor",
        "ltrClFactor", "ltrPredictMinStep", "ltrPredictMaxStep",
        "ltrPredictTMax", "aeroPitchKp", "aeroPitchKi", "aeroPitchKd",
        "aeroYawKp", "aeroYawKi", "aeroYawKd", "aeroMaxPitch",
        "aeroMaxYaw", "aeroTargetOffset", "QuadraticAOABase",
        "QuadraticAOADot", "landingBurnAltitude",
        "legDeploySpeed", "touchDownSpeed", "landingPhase2Time",
        "landingCutoffHeight", "boundsUpdatePeriod",
        "minLandingThrottleCommand"
    ).
    IF NOT f9_validate_required_keys(params, requiredKeys, "recovery") {
        RETURN FALSE.
    }

    LOCAL ok IS TRUE.
    IF (params["landingSiteUse"] <> "geo"
        AND params["landingSiteUse"] <> "waypoint"
        AND params["landingSiteUse"] <> "vessel"
        AND params["landingSiteUse"] <> "none") {
        PRINT "F9 recovery config error: landingSiteUse must be none, geo, waypoint, or vessel".
        SET ok TO FALSE.
    } ELSE IF params["landingSiteUse"] = "geo" {
        IF NOT f9_validate_required_keys(
            params,
            LIST("landingSiteGeo"),
            "recovery"
        ) {
            SET ok TO FALSE.
        }
    } ELSE IF params["landingSiteUse"] = "waypoint" {
        IF NOT f9_validate_required_keys(
            params,
            LIST("landingSiteWaypoint"),
            "recovery"
        ) {
            SET ok TO FALSE.
        }
    } ELSE IF params["landingSiteUse"] = "vessel" {
        IF NOT f9_validate_required_keys(
            params,
            LIST("landingSiteVessel"),
            "recovery"
        ) {
            SET ok TO FALSE.
        }
    }
    IF params["boostBackMass"] <= 0 {
        PRINT "F9 config error: boostBackMass must be positive".
        SET ok TO FALSE.
    }

    IF params["aeroMaxPitch"] <= 0 {
        PRINT "F9 config error: aeroMaxPitch must be positive".
        SET ok TO FALSE.
    }
    IF params["aeroMaxYaw"] <= 0 {
        PRINT "F9 config error: aeroMaxYaw must be positive".
        SET ok TO FALSE.
    }
    IF (params["entryBurnAlt"] <= 0 OR params["entryVSpeed"] <= 0) {
        PRINT "F9 config error: entry burn altitude and speed must be positive".
        SET ok TO FALSE.
    }
    IF (params["ltrCtrlSpeedSamples"]:LENGTH = 0
        OR params["ltrCtrlSpeedSamples"]:LENGTH
            <> params["ltrCtrlAOASamples"]:LENGTH) {
        PRINT "F9 config error: LTR speed/AOA profiles must be nonempty and equal-length".
        SET ok TO FALSE.
    }
    IF (params["ltrAeroSpeedSamples"]:LENGTH = 0
        OR params["ltrAeroAltitudeSamples"]:LENGTH = 0) {
        PRINT "F9 config error: LTR aerodynamic sample axes must be nonempty".
        SET ok TO FALSE.
    }
    IF (params["ltrPredictMinStep"] < 0
        OR params["ltrPredictMaxStep"] <= 0
        OR params["ltrPredictMinStep"] > params["ltrPredictMaxStep"]
        OR params["ltrPredictTMax"] <= 0) {
        PRINT "F9 config error: invalid LTR predictor step/time limits".
        SET ok TO FALSE.
    }
    IF (params["touchDownSpeed"] < 0) {
        PRINT "F9 config error: invalid landing speed".
        SET ok TO FALSE.
    }
    IF f9_engine_mode_enabled(params) {
        IF NOT f9_validate_required_keys(
            params,
            LIST(
                "engineModeInitial", "engineModePostSeparation",
                "engineModeSeparationDelay", "engineModeTerminal",
                "engineModeTerminalAirspeed", "engineModeCount",
                "engineModeDataPostSeparation", "engineModeDataTerminal"
            ),
            "recovery engine mode"
        ) {
            SET ok TO FALSE.
        } ELSE {
            IF params["engineModeSeparationDelay"] < 0 {
                PRINT "F9 config error: engineModeSeparationDelay must not be negative".
                SET ok TO FALSE.
            }
            IF params["engineModeTerminalAirspeed"] <= 0 {
                PRINT "F9 config error: engineModeTerminalAirspeed must be positive".
                SET ok TO FALSE.
            }
            FOR modeIndexKey IN LIST(
                "engineModeInitial", "engineModePostSeparation",
                "engineModeTerminal"
            ) {
                IF NOT f9_engine_mode_index_valid(params, modeIndexKey) {
                    SET ok TO FALSE.
                }
            }
            FOR dataKey IN LIST("engineModeDataPostSeparation", "engineModeDataTerminal") {
                LOCAL data IS params[dataKey].
                IF NOT (data:HASKEY("thrust") AND data:HASKEY("minthrottle")
                    AND data:HASKEY("spooluptime")) {
                    PRINT "F9 config error: " + dataKey + " needs thrust, minthrottle and spooluptime".
                    SET ok TO FALSE.
                } ELSE IF data["thrust"] <= 0 {
                    PRINT "F9 config error: " + dataKey + " thrust must be positive".
                    SET ok TO FALSE.
                }
            }
        }
    }
    RETURN ok.
}
