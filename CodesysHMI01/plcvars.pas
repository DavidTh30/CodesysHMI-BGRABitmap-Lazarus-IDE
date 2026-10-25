unit PlcVars;

{ Variable definitions for the Codesys Modbus TCP slave mapping,
  register <-> value conversion and vars.csv persistence. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, ModbusTcp;

type
  TArea = (arCoil, arDI, arHR, arIR);
  TDataType = (dtBool, dtInt, dtUInt, dtDInt, dtReal);

  TVarDef = record
    Name: string;
    Area: TArea;
    Addr: Integer;
    DType: TDataType;
    MinV, MaxV: Double;
    UnitS: string;
  end;
  TVarDefs = array of TVarDef;

const
  AreaNames: array[TArea] of string = ('COIL', 'DI', 'HR', 'IR');
  TypeNames: array[TDataType] of string = ('BOOL', 'INT', 'UINT', 'DINT', 'REAL');
  // how the Codesys "ModbusTCP Slave Device" maps each area into the PLC
  AreaCodesys: array[TArea] of string = ('%IX', '%QX', '%IW', '%QW');
  AreaHint: array[TArea] of string = (
    'COIL -> CODESYS %IX (HMI WRITES, PLC READS)',
    'DI   -> CODESYS %QX (PLC WRITES, HMI READS)',
    'HR   -> CODESYS %IW (HMI WRITES, PLC READS)',
    'IR   -> CODESYS %QW (PLC WRITES, HMI READS)');

function IsBitArea(A: TArea): Boolean;
function IsWritable(A: TArea): Boolean;
function RegCount(DT: TDataType): Integer;
function ParseArea(const S: string; out A: TArea): Boolean;
function ParseType(const S: string; out DT: TDataType): Boolean;
function CodesysAddress(const D: TVarDef): string;
function DecodeRegs(const R: array of Word; DT: TDataType; ASwap: Boolean): Double;
function EncodeValue(V: Double; DT: TDataType; ASwap: Boolean): TWordArray;
procedure LoadVarDefs(const AFileName: string; out Defs: TVarDefs);
procedure SaveVarDefs(const AFileName: string; const Defs: TVarDefs);
procedure DefaultVarDefs(out Defs: TVarDefs);

implementation

function IsBitArea(A: TArea): Boolean;
begin
  Result := A in [arCoil, arDI];
end;

function IsWritable(A: TArea): Boolean;
begin
  Result := A in [arCoil, arHR];
end;

function RegCount(DT: TDataType): Integer;
begin
  if DT in [dtDInt, dtReal] then
    Result := 2
  else
    Result := 1;
end;

function ParseArea(const S: string; out A: TArea): Boolean;
var
  X: TArea;
begin
  for X := Low(TArea) to High(TArea) do
    if SameText(Trim(S), AreaNames[X]) then
    begin
      A := X;
      Exit(True);
    end;
  A := arHR;
  Result := False;
end;

function ParseType(const S: string; out DT: TDataType): Boolean;
var
  X: TDataType;
begin
  for X := Low(TDataType) to High(TDataType) do
    if SameText(Trim(S), TypeNames[X]) then
    begin
      DT := X;
      Exit(True);
    end;
  if SameText(Trim(S), 'WORD') then
  begin
    DT := dtUInt;
    Exit(True);
  end;
  DT := dtInt;
  Result := False;
end;

function CodesysAddress(const D: TVarDef): string;
begin
  if IsBitArea(D.Area) then
    Result := Format('%s%d.%d', [AreaCodesys[D.Area], D.Addr div 8, D.Addr mod 8])
  else if RegCount(D.DType) = 2 then
    Result := Format('%s%d (%sD%d)', [AreaCodesys[D.Area], D.Addr,
      Copy(AreaCodesys[D.Area], 1, 2), D.Addr div 2])
  else
    Result := AreaCodesys[D.Area] + IntToStr(D.Addr);
end;

function Pack32(const R: array of Word; ASwap: Boolean): LongWord;
begin
  // Codesys (little endian) puts the low word at the lower register
  if ASwap then
    Result := (LongWord(R[0]) shl 16) or R[1]
  else
    Result := (LongWord(R[1]) shl 16) or R[0];
end;

function DecodeRegs(const R: array of Word; DT: TDataType; ASwap: Boolean): Double;
var
  L: LongWord;
  S: Single;
begin
  case DT of
    dtInt: Result := SmallInt(R[0]);
    dtUInt: Result := R[0];
    dtDInt:
      Result := LongInt(Pack32(R, ASwap));
    dtReal:
      begin
        L := Pack32(R, ASwap);
        Move(L, S, 4);
        Result := S;
      end;
  else
    Result := Ord(R[0] <> 0);
  end;
end;

function EncodeValue(V: Double; DT: TDataType; ASwap: Boolean): TWordArray;
var
  L: LongWord;
  S: Single;
begin
  SetLength(Result, RegCount(DT));
  case DT of
    dtInt: Result[0] := Word(SmallInt(EnsureRange(Round(V), -32768, 32767)));
    dtUInt: Result[0] := Word(EnsureRange(Round(V), 0, 65535));
    dtDInt, dtReal:
      begin
        if DT = dtDInt then
          L := LongWord(LongInt(EnsureRange(Round(V), Low(LongInt), High(LongInt))))
        else
        begin
          S := V;
          Move(S, L, 4);
        end;
        if ASwap then
        begin
          Result[0] := Word(L shr 16);
          Result[1] := Word(L and $FFFF);
        end
        else
        begin
          Result[0] := Word(L and $FFFF);
          Result[1] := Word(L shr 16);
        end;
      end;
  else
    Result[0] := Ord(V <> 0);
  end;
end;

procedure AddDef(var Defs: TVarDefs; const AName: string; A: TArea; AAddr: Integer;
  DT: TDataType; AMin, AMax: Double; const AUnit: string);
begin
  SetLength(Defs, Length(Defs) + 1);
  with Defs[High(Defs)] do
  begin
    Name := AName;
    Area := A;
    Addr := AAddr;
    DType := DT;
    MinV := AMin;
    MaxV := AMax;
    UnitS := AUnit;
  end;
end;

procedure DefaultVarDefs(out Defs: TVarDefs);
begin
  Defs := nil;
  AddDef(Defs, 'Motor_Run',     arCoil, 0, dtBool, 0, 1, '');
  AddDef(Defs, 'Pump_Enable',   arCoil, 1, dtBool, 0, 1, '');
  AddDef(Defs, 'Alarm_Reset',   arCoil, 2, dtBool, 0, 1, '');
  AddDef(Defs, 'Motor_Running', arDI,   0, dtBool, 0, 1, '');
  AddDef(Defs, 'Alarm_Active',  arDI,   1, dtBool, 0, 1, '');
  AddDef(Defs, 'Speed_SP',      arHR,   0, dtInt,  0, 1500, 'rpm');
  AddDef(Defs, 'Temp_SP',       arHR,   1, dtInt,  0, 120, 'C');
  AddDef(Defs, 'Flow_SP',       arHR,   2, dtReal, 0, 50, 'm3/h');
  AddDef(Defs, 'Batch_Target',  arHR,   4, dtDInt, 0, 100000, 'pcs');
  AddDef(Defs, 'Speed_PV',      arIR,   0, dtInt,  0, 1500, 'rpm');
  AddDef(Defs, 'Temp_PV',       arIR,   1, dtInt,  0, 120, 'C');
  AddDef(Defs, 'Flow_PV',       arIR,   2, dtReal, 0, 50, 'm3/h');
  AddDef(Defs, 'Pressure_PV',   arIR,   4, dtReal, 0, 10, 'bar');
  AddDef(Defs, 'Batch_Count',   arIR,   6, dtDInt, 0, 100000, 'pcs');
end;

procedure LoadVarDefs(const AFileName: string; out Defs: TVarDefs);
var
  Lines, F: TStringList;
  I: Integer;
  D: TVarDef;
  FS: TFormatSettings;
begin
  Defs := nil;
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Lines := TStringList.Create;
  F := TStringList.Create;
  try
    F.StrictDelimiter := True;
    F.Delimiter := ',';
    Lines.LoadFromFile(AFileName);
    for I := 1 to Lines.Count - 1 do   // line 0 = header
    begin
      if Trim(Lines[I]) = '' then
        Continue;
      F.DelimitedText := Lines[I];
      while F.Count < 7 do
        F.Add('');
      D.Name := Trim(F[0]);
      if D.Name = '' then
        Continue;
      ParseArea(F[1], D.Area);
      D.Addr := StrToIntDef(Trim(F[2]), 0);
      ParseType(F[3], D.DType);
      if IsBitArea(D.Area) then
        D.DType := dtBool
      else if D.DType = dtBool then
        D.DType := dtInt;
      D.MinV := StrToFloatDef(Trim(F[4]), 0, FS);
      D.MaxV := StrToFloatDef(Trim(F[5]), 100, FS);
      D.UnitS := Trim(F[6]);
      SetLength(Defs, Length(Defs) + 1);
      Defs[High(Defs)] := D;
    end;
  finally
    F.Free;
    Lines.Free;
  end;
end;

procedure SaveVarDefs(const AFileName: string; const Defs: TVarDefs);
var
  L: TStringList;
  I: Integer;
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  L := TStringList.Create;
  try
    L.Add('Name,Area,Address,Type,Min,Max,Unit');
    for I := 0 to High(Defs) do
      with Defs[I] do
        L.Add(Format('%s,%s,%d,%s,%s,%s,%s', [Name, AreaNames[Area], Addr, TypeNames[DType],
          FloatToStr(MinV, FS), FloatToStr(MaxV, FS), UnitS]));
    L.SaveToFile(AFileName);
  finally
    L.Free;
  end;
end;

end.
