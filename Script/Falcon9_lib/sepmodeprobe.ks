// SEP engine-mode probe: one-off calibration tool for the Starship booster
// cluster (ModuleSEPEngineSwitch, StarshipExpansionProject).
//
// Run it once on the launch pad with the booster clamped, from a kOS CPU on
// the vessel (it locks the throttle to 1 while cycling modes). Then open
// 0:/sep_probe.log and feed the measured values back into the boot lexicon:
//
//   engineModeCount           number of modes the switch cycles through
//   engineModeInitial         mode index at liftoff (ascent) / after separation (recovery contract)
//   engineModePreSeparation   Middle Two index
//   engineModePostSeparation  Middle Eight index
//   engineModeTerminal        Center Three index
//   engineModeDataPostSeparation / engineModeDataTerminal
//                             thrust (kN at throttle 1), minthrottle, spooluptime
//   engineModeNextAction / engineModePreviousAction
//                             action names, if they differ from the defaults
//
// The log appends, so every run starts with a "run @ T+..." header. To clear
// it first, type this in the terminal:
//     DELETE "sep_probe.log" FROM 0.
// Every line is written to the file as it is produced, so a probe interrupted
// by a runtime error still leaves everything it found up to that point.

GLOBAL SEP_PROBE_LOG_PATH IS "0:/sep_probe.log".

FUNCTION sep_probe_say {
    PARAMETER message.

    PRINT message.
    LOG message TO SEP_PROBE_LOG_PATH.
}

// The names kOS may accept for the mode-step action. kOS matches the name
// shown in the action-group editor (the mod's is the text behind
// "#LOC_SEP_NextEngineMode"), while the craft file stores the method name
// (NextEngineModeAction) and the mod's KSPAction attribute carries the tag.
FUNCTION sep_probe_candidate_names {
    PARAMETER forward.

    IF forward {
        RETURN LIST(
            "Next Engine Mode", "NextEngineModeAction",
            "#LOC_SEP_NextEngineMode"
        ).
    } ELSE {
        RETURN LIST(
            "Previous Engine Mode", "PreviousEngineModeAction",
            "#LOC_SEP_PreviousEngineMode"
        ).
    }
}

// Step one mode, reporting which name on this install actually works. Mirrors
// the resolution order of f9_engine_mode_step, and like it only invokes names
// the HASACTION/HASEVENT matcher accepts, so a listed name that the matcher
// rejects cannot abort the probe with a DOACTION exception.
FUNCTION sep_probe_step {
    PARAMETER modeModule.
    PARAMETER forward.

    LOCAL direction IS "Previous".
    IF forward {
        SET direction TO "Next".
    }
    FOR actionName IN sep_probe_candidate_names(forward) {
        IF modeModule:HASACTION(actionName) {
            sep_probe_say("  step via action '" + actionName + "'").
            modeModule:DOACTION(actionName, TRUE).
            RETURN TRUE.
        }
    }
    FOR eventName IN sep_probe_candidate_names(forward) {
        IF modeModule:HASEVENT(eventName) {
            sep_probe_say("  step via event '" + eventName + "'").
            modeModule:DOEVENT(eventName).
            RETURN TRUE.
        }
    }
    // Last resort: a listed action or event whose name carries the direction
    // word, again only when the matcher accepts it.
    FOR entry IN modeModule:ALLACTIONNAMES {
        IF entry:CONTAINS(direction) AND modeModule:HASACTION(entry) {
            sep_probe_say("  step via listed action '" + entry + "'").
            modeModule:DOACTION(entry, TRUE).
            RETURN TRUE.
        }
    }
    FOR entry IN modeModule:ALLEVENTNAMES {
        IF entry:CONTAINS(direction) AND modeModule:HASEVENT(entry) {
            sep_probe_say("  step via listed event '" + entry + "'").
            modeModule:DOEVENT(entry).
            RETURN TRUE.
        }
    }
    sep_probe_say("  ERROR: no usable " + direction + " action or event").
    RETURN FALSE.
}

// The switch state as one string, shared by the snapshot and the cycle check
// so both read the same fields. Missing fields are reported as n/a.
FUNCTION sep_probe_mode_state {
    PARAMETER modeModule.

    LOCAL display IS "n/a".
    IF modeModule:HASFIELD("currentEngineDisplay") {
        SET display TO modeModule:GETFIELD("currentEngineDisplay") + "".
    } ELSE IF modeModule:HASFIELD("Mode") {
        SET display TO modeModule:GETFIELD("Mode") + "".
    }
    LOCAL index IS "n/a".
    IF modeModule:HASFIELD("selectedIndex") {
        SET index TO modeModule:GETFIELD("selectedIndex") + "".
    }
    RETURN "display='" + display + "' index=" + index.
}

FUNCTION sep_probe_mode_snapshot {
    PARAMETER modeModule.
    PARAMETER label.

    LOCAL engines IS LIST().
    LIST ENGINES IN engines.
    LOCAL engineText IS "".
    FOR e IN engines {
        SET engineText TO engineText + "[" + e:TAG
            + " thrust=" + ROUND(e:thrust, 1)
            + " possible=" + ROUND(e:possiblethrust, 1)
            + " minthrottle=" + ROUND(e:minthrottle, 3)
            + " ign=" + e:IGNITION
            + " flameout=" + e:FLAMEOUT + "] ".
    }
    sep_probe_say(
        label + ": " + sep_probe_mode_state(modeModule)
            + " maxthrust=" + ROUND(SHIP:MAXTHRUST, 1) + " " + engineText
    ).
}

FUNCTION sep_probe_run {
    sep_probe_say(
        "run @ T+" + ROUND(TIME:SECONDS, 1) + " s, vessel mass "
            + ROUND(SHIP:MASS, 2) + " t"
    ).

    // 1. Switch module: visible fields, actions and events.
    LOCAL modules IS SHIP:MODULESNAMED("ModuleSEPEngineSwitch").
    sep_probe_say("ModuleSEPEngineSwitch count = " + modules:LENGTH).
    IF modules:LENGTH = 0 {
        sep_probe_say("ERROR: no ModuleSEPEngineSwitch found on this vessel").
    } ELSE {
        LOCAL modeModule IS modules[0].
        sep_probe_say("module part = " + modeModule:PART:NAME).
        FOR f IN modeModule:ALLFIELDNAMES {
            sep_probe_say("  field: " + f).
        }
        // Each listed name with the flag the matcher returns for it. A name
        // that is listed but flagged False is exactly the list-versus-matcher
        // mismatch that broke the HASACTION lookup, and the name that is
        // flagged True is the one to paste into the boot lexicon.
        FOR a IN modeModule:ALLACTIONNAMES {
            sep_probe_say(
                "  action: " + a
                    + "  HASACTION=" + modeModule:HASACTION(a)
            ).
        }
        FOR v IN modeModule:ALLEVENTNAMES {
            sep_probe_say(
                "  event: " + v
                    + "  HASEVENT=" + modeModule:HASEVENT(v)
            ).
        }
        FOR fieldName IN LIST("currentEngineDisplay", "Mode", "selectedIndex") {
            sep_probe_say(
                "HASFIELD '" + fieldName + "' = "
                    + modeModule:HASFIELD(fieldName)
            ).
        }
        FOR probeName IN LIST(
            "Next Engine Mode", "NextEngineModeAction",
            "#LOC_SEP_NextEngineMode",
            "Previous Engine Mode", "PreviousEngineModeAction",
            "#LOC_SEP_PreviousEngineMode",
            "NextEngineModeEvent", "PreviousEngineModeEvent"
        ) {
            sep_probe_say(
                "HASACTION '" + probeName + "' = "
                    + modeModule:HASACTION(probeName)
                    + "   HASEVENT = " + modeModule:HASEVENT(probeName)
            ).
        }

        // 2. Engines as kOS sees them (one aggregated entry per part).
        sep_probe_mode_snapshot(modeModule, "initial").

        // 3. Cycle every mode forward, then step back the same number of times
        //    to confirm that the switch is cyclic and reversible. Stepping back
        //    exactly as far as the forward pass got leaves the switch in the
        //    mode it started in, so the calibration run does not leave the
        //    vehicle in an unexpected mode for the next flight.
        LOCAL startState IS sep_probe_mode_state(modeModule).
        LOCAL cycleSteps IS 6.
        sep_probe_say("cycling Next x" + cycleSteps + " ...").
        LOCK THROTTLE TO 1.
        WAIT 1.
        LOCAL forwardDone IS 0.
        LOCAL stopped IS FALSE.
        FROM {
            LOCAL i IS 0.
        } UNTIL i >= cycleSteps OR stopped STEP {
            SET i TO i + 1.
        } DO {
            IF sep_probe_step(modeModule, TRUE) {
                SET forwardDone TO forwardDone + 1.
                WAIT 1.
                sep_probe_mode_snapshot(modeModule, "next " + i).
            } ELSE {
                SET stopped TO TRUE.
            }
        }
        sep_probe_say("forward steps completed: " + forwardDone).
        sep_probe_say("cycling Previous x" + forwardDone + " ...").
        SET stopped TO FALSE.
        FROM {
            LOCAL i IS 0.
        } UNTIL i >= forwardDone OR stopped STEP {
            SET i TO i + 1.
        } DO {
            IF sep_probe_step(modeModule, FALSE) {
                WAIT 1.
                sep_probe_mode_snapshot(modeModule, "prev " + i).
            } ELSE {
                SET stopped TO TRUE.
            }
        }
        // UNLOCK alone leaves KSP's last throttle value, which is full
        // throttle for this probe; close it before releasing the lock.
        LOCK THROTTLE TO 0.
        WAIT 1.
        UNLOCK THROTTLE.
        IF forwardDone = 0 {
            sep_probe_say(
                "switch did not move; no calibration values were measured"
            ).
        } ELSE IF sep_probe_mode_state(modeModule) = startState {
            sep_probe_say("cycle returned to the starting mode: " + startState).
        } ELSE {
            sep_probe_say(
                "WARNING: mode moved from " + startState + " to "
                    + sep_probe_mode_state(modeModule)
            ).
        }
    }
    sep_probe_say("probe done").
}

CLEARSCREEN.
PRINT "SEP engine-mode probe".
sep_probe_run().
PRINT "Probe log appended to " + SEP_PROBE_LOG_PATH + " (line by line)".
