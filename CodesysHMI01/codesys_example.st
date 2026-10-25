(*
  Codesys V3 side for CodesysHMI (Modbus TCP).

  1) Device tree: Ethernet adapter -> Add Device -> "ModbusTCP Slave Device".
     General tab:  Port 502, Unit ID 1,
                   Holding registers = 16, Input registers = 16,
                   Coils = 16 (Discrete bits = 16) -> enable "Discrete bit areas".
  2) "ModbusTCP Slave Device I/O Mapping" tab: map the channels to the
     variables below (or use the %I/%Q addresses it shows - they are the
     base offsets of each area; the HMI address is relative to that base):
        Coils            -> %IX  (HMI writes)   -> xMotorRun, xPumpEnable, xAlarmReset
        Discrete inputs  -> %QX  (PLC writes)   -> xMotorRunning, xAlarmActive
        Holding register -> %IW  (HMI writes)   -> aHR[0..15]
        Input register   -> %QW  (PLC writes)   -> aIR[0..15]
     Set "Always update variables" = Enabled 2 (always in bus cycle task).
  3) Download, run, then in the HMI type the PLC IP, port 502, CONNECT.
*)
PROGRAM PLC_PRG
VAR
    // coils (from HMI)
    xMotorRun     : BOOL;
    xPumpEnable   : BOOL;
    xAlarmReset   : BOOL;
    // discrete inputs (to HMI)
    xMotorRunning : BOOL;
    xAlarmActive  : BOOL;
    // register images mapped in the I/O mapping tab
    aHR : ARRAY[0..15] OF WORD;   // holding registers (from HMI)
    aIR : ARRAY[0..15] OF WORD;   // input registers   (to HMI)

    iSpeedSP   : INT;
    iTempSP    : INT;
    rFlowSP    : REAL;
    diBatchTgt : DINT;
    rSpeed, rTemp, rFlow, rPressure : REAL;
    diBatchCnt : DINT;
    tPulse : TON;
END_VAR

// ---- decode values written by the HMI (low word first) ----
iSpeedSP := WORD_TO_INT(aHR[0]);
iTempSP  := WORD_TO_INT(aHR[1]);
SysMemCpy(ADR(rFlowSP),    ADR(aHR[2]), 4);
SysMemCpy(ADR(diBatchTgt), ADR(aHR[4]), 4);

// ---- simple process model ----
IF xMotorRun THEN
    rSpeed := rSpeed + (INT_TO_REAL(iSpeedSP) - rSpeed) * 0.08;
    rTemp  := rTemp  + (INT_TO_REAL(iTempSP)  - rTemp)  * 0.02;
ELSE
    rSpeed := rSpeed * 0.92;
    rTemp  := rTemp + (25.0 - rTemp) * 0.02;
END_IF
IF xPumpEnable THEN
    rFlow := rFlow + (rFlowSP - rFlow) * 0.1;
ELSE
    rFlow := rFlow * 0.9;
END_IF
rPressure := 4.0 + rFlow * 0.05;

tPulse(IN := xMotorRun AND NOT tPulse.Q, PT := T#100MS);
IF tPulse.Q AND diBatchCnt < diBatchTgt THEN
    diBatchCnt := diBatchCnt + 1;
END_IF

xMotorRunning := rSpeed > 10.0;
IF rTemp > 100.0 THEN xAlarmActive := TRUE; END_IF
IF xAlarmReset THEN xAlarmActive := FALSE; END_IF

// ---- encode values for the HMI (low word first) ----
aIR[0] := INT_TO_WORD(REAL_TO_INT(rSpeed));
aIR[1] := INT_TO_WORD(REAL_TO_INT(rTemp));
SysMemCpy(ADR(aIR[2]), ADR(rFlow), 4);
SysMemCpy(ADR(aIR[4]), ADR(rPressure), 4);
SysMemCpy(ADR(aIR[6]), ADR(diBatchCnt), 4);
