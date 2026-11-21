---- MODULE charge ----
(****************************************************************)
(* Charging state machine — Samsung Galaxy S20 FE (r8s)          *)
(* Model of: MAX77705 CNFG_00 MODE + the deployed charge-watch    *)
(* systemd service + the hardware OTG behaviour found in review  *)
(*                                                               *)
(* Branch variants:                                              *)
(*   main                    = deployed system (OTG flaw present)*)
(*   fix/otg-inhibit-respect = OTG respects watchdog inhibit      *)
(****************************************************************)
EXTENDS Integers, TLC, Naturals

\* All "constants" as top-level definitions: the tla2tools SANY on the
\* build host rejects the CONSTANTS = value grammar (2020 SANY2 build).
TempHotStop == 500      \* decigradi: stop charging above this
TempHotResume == 480    \* decigradi: resume below this
TempColdStop == 20      \* decigradi: cold block below this
TempMax == 900          \* decigradi: table max
NULL_TEMP == 99999      \* sensor failure marker (positive sentinel)
OTGFlavor == "fixed"     \* OTG detach respects watchdog inhibit

BattTempMin == -200     \* decigradi, table minimum

VARIABLES
  battTemp,      \* battery temperature (decigradi) or NULL_TEMP
  chgMode,       \* CNFG_00 MODE: 0x4 buck-on-no-charge, 0x5 buck+charge,
                 \* 0xA boost-OTG, 0xF UNO
  wdgState,      \* watchdog intent: "auto" / "inhibit"
  otgOn,         \* OTG VBUS active (a USB accessory drawing power)
  sensorFail     \* temperature reading invalid/stale

vars == <<battTemp, chgMode, wdgState, otgOn, sensorFail>>

ModeNoCharge == 0x4
ModeCharging == 0x5
ModeBoostOTG == 0xA

Init ==
  /\ battTemp = 320        \* ~32C, the measured value
  /\ chgMode = ModeCharging
  /\ wdgState = "auto"
  /\ otgOn = FALSE
  /\ sensorFail = FALSE

TypeOK ==
  /\ battTemp \in {NULL_TEMP} \union BattTempMin..TempMax
  /\ chgMode \in {ModeNoCharge, ModeCharging, ModeBoostOTG, 0xF}
  /\ wdgState \in {"auto", "inhibit"}
  /\ otgOn \in BOOLEAN
  /\ sensorFail \in BOOLEAN

(********************** ENVIRONMENT **********************)

EnvHeat ==
  /\ battTemp < TempMax
  /\ sensorFail' = FALSE
  /\ battTemp' = battTemp + 5
  /\ UNCHANGED <<chgMode, wdgState, otgOn>>

EnvCool ==
  /\ battTemp > BattTempMin
  /\ sensorFail' = FALSE
  /\ battTemp' = battTemp - 5
  /\ UNCHANGED <<chgMode, wdgState, otgOn>>

EnvSensorFail ==
  /\ sensorFail' = TRUE
  /\ battTemp' = NULL_TEMP
  /\ UNCHANGED <<chgMode, wdgState, otgOn>>

EnvOTGAttach ==
  /\ ~otgOn
  /\ otgOn' = TRUE
  \* OTG attach: hardware switches to boost mode 0xA
  /\ chgMode' = ModeBoostOTG
  /\ UNCHANGED <<battTemp, wdgState, sensorFail>>

OTGDetach ==
  /\ otgOn' = FALSE
  /\ IF OTGFlavor = "flawed"
       THEN chgMode' = ModeCharging          \* deployed: unconditional 0x5
       ELSE chgMode' = IF wdgState = "inhibit"
                         THEN ModeNoCharge
                         ELSE ModeCharging   \* fixed: respects inhibit
  /\ UNCHANGED <<battTemp, wdgState, sensorFail>>

(********************** WATCHDOG (systemd charge-watch) **********************)
\* The deployed v2 policy: live NTC temp via ADC, stop >= TempHotStop,
\* resume <= TempHotResume, cold block <= TempColdStop, fail-safe on invalid.

WatchdogTick ==
  /\ sensorFail = FALSE
  /\ CASE
       battTemp = NULL_TEMP ->
         /\ wdgState' = "inhibit"
         /\ chgMode' = ModeNoCharge       \* fail-safe on invalid reading
       /\ battTemp >= TempHotStop ->
         /\ wdgState' = "inhibit"
         /\ chgMode' = IF otgOn THEN ModeBoostOTG ELSE ModeNoCharge
       /\ battTemp <= TempColdStop ->
         /\ wdgState' = "inhibit"
         /\ chgMode' = IF otgOn THEN ModeBoostOTG ELSE ModeNoCharge
       /\ battTemp <= TempHotResume ->
         /\ wdgState' = "auto"
         /\ chgMode' = IF otgOn THEN ModeBoostOTG ELSE ModeCharging
       [] OTHER -> UNCHANGED <<chgMode, wdgState, otgOn>>
     /\ UNCHANGED <<battTemp, sensorFail>>

(********************** NEXT & SPEC **********************)

Next ==
  \/ EnvHeat
  \/ EnvCool
  \/ EnvSensorFail
  \/ EnvOTGAttach
  \/ OTGDetach
  \/ WatchdogTick

Spec == Init /\ [][Next]_vars

(********************** SAFETY PROPERTIES **********************)

NoChargeWhenHot ==
  (battTemp >= TempHotStop /\ battTemp /= NULL_TEMP) => chgMode /= ModeCharging

NoChargeWhenCold ==
  (battTemp <= TempColdStop /\ battTemp /= NULL_TEMP) => chgMode /= ModeCharging

InhibitRespected ==
  (wdgState = "inhibit" /\ ~otgOn) => chgMode /= ModeCharging

FailSafeOnInvalid ==
  (battTemp = NULL_TEMP) => chgMode = ModeNoCharge

SafetyAll == NoChargeWhenHot /\ NoChargeWhenCold /\ InhibitRespected /\ FailSafeOnInvalid

(********************** LIVENESS **********************)

L1 ==
  (battTemp >= TempHotStop /\ ~sensorFail) ~> (chgMode /= ModeCharging)

L2 ==
  ((battTemp <= TempHotResume /\ ~sensorFail /\ wdgState = "auto") ~> chgMode = ModeCharging)

===============
=============================
