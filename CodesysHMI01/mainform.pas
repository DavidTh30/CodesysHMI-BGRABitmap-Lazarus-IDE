unit MainForm;

{ HUD HMI for a Codesys PLC over Modbus TCP.
  Everything is custom drawn with BGRABitmap, including the text fields and
  buttons. Static parts are cached in FBack (rebuilt when layout, selection,
  scroll or the variable list change); values, fields and animations are drawn
  every frame on top. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Types, Math, Forms, Controls, Graphics, Dialogs, ExtCtrls, LCLType,
  BGRABitmap, BGRABitmapTypes, HudPaint, PlcVars, LinkThread;

type
  TBtnId = (bConnect, bWord, bArea, bType, bNew, bAdd, bApply, bDelete, bSave, bReload,
    bWrite, bDec, bInc, bOn, bOff, bToggle, bFilter);

  TBtnStyle = (bsNormal, bsPrimary, bsDanger, bsChip, bsTab);

  TButtonRec = record
    R: TRect;
    Id: TBtnId;
    Arg: Integer;
    Caption: string;
    Style: TBtnStyle;
  end;

  TFieldId = (fHost, fPort, fUnit, fPoll, fName, fAddr, fMin, fMax, fUnitS, fWrite);
  TFieldKind = (fkText, fkInt, fkFloat, fkIdent);

  TFieldRec = record
    R: TRect;
    Caption, Text: string;
    Kind: TFieldKind;
    Visible: Boolean;
  end;

  { TfrmMain }

  TfrmMain = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FLink: TLinkThread;
    FDefs: TVarDefs;
    FRes: TVarResults;
    FStats: TLinkStats;
    FHist: array of array of Double;
    FLastCycle: Int64;
    FSel, FFilter, FScroll, FFocus, FHover: Integer;
    FView: array of Integer;
    FFields: array[TFieldId] of TFieldRec;
    FBtns: array of TButtonRec;
    FRowR, FRowTog: array of TRect;
    FRowIdx: array of Integer;
    FDefArea: TArea;
    FDefType: TDataType;
    FSwap: Boolean;
    FBack, FFrame: TBGRABitmap;
    FBackDirty: Boolean;
    FPhase: Single;
    FTimer: TTimer;
    FLog: string;
    FVarFile, FSnapFile: string;
    FSnapAt: Single;
    FFmt: TFormatSettings;
    FHeaderR, FConnR, FDefR, FTableR, FMonR, FBottomR, FListR, FTrendR: TRect;
    FGaugeCX, FGaugeCY, FGaugeR: Single;
    procedure TimerTick(Sender: TObject);
    procedure Log(const S: string);
    procedure MarkDirty;
    procedure RebuildView;
    procedure DefsChanged;
    procedure SelectVar(I: Integer);
    procedure LoadDefIntoForm(I: Integer);
    function FormToDef(out D: TVarDef): Boolean;
    function SelDef(out D: TVarDef): Boolean;
    function CurValue(I: Integer): Double;
    function FmtVal(const D: TVarDef; V: Double): string;
    function ParseNum(const S: string; out V: Double): Boolean;
    function StepFor(const D: TVarDef): Double;
    function Online: Boolean;
    procedure WriteVar(I: Integer; V: Double);
    procedure DoButton(const Btn: TButtonRec);
    procedure DoConnect;
    procedure DoLayout;
    procedure AddBtn(const ARect: TRect; AId: TBtnId; const ACaption: string;
      AStyle: TBtnStyle = bsNormal; AArg: Integer = 0);
    procedure SetField(F: TFieldId; const R: TRect; AVisible: Boolean = True);
    function VisibleRows: Integer;
    // cached layer
    procedure RenderBack;
    procedure DrawBackdrop(B: TBGRABitmap);
    procedure DrawHeader(B: TBGRABitmap);
    procedure DrawStrip(B: TBGRABitmap; const R: TRect; const ATitle: string);
    procedure DrawConnStatic(B: TBGRABitmap);
    procedure DrawDefStatic(B: TBGRABitmap);
    procedure DrawTableStatic(B: TBGRABitmap);
    procedure DrawMonStatic(B: TBGRABitmap);
    procedure DrawFieldLabels(B: TBGRABitmap);
    // per frame
    procedure RenderDynamic(B: TBGRABitmap);
    procedure DrawClock(B: TBGRABitmap);
    procedure DrawFields(B: TBGRABitmap);
    procedure DrawButtons(B: TBGRABitmap);
    procedure DrawConnDynamic(B: TBGRABitmap);
    procedure DrawTableDynamic(B: TBGRABitmap);
    procedure DrawMonDynamic(B: TBGRABitmap);
    procedure DrawBottom(B: TBGRABitmap);
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure KeyPress(var Key: Char); override;
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.lfm}

const
  RowH = 34;
  HistLen = 300;
  GaugeA0 = 0.75 * Pi;
  GaugeA1 = 2.25 * Pi;
  FilterNames: array[-1..3] of string = ('ALL', 'COIL', 'DI', 'HR', 'IR');

function NiceStep(X: Double): Double;
var
  E, F: Double;
begin
  if X <= 0 then
    Exit(1);
  E := Power(10, Floor(Log10(X)));
  F := X / E;
  if F < 1.5 then Result := E
  else if F < 3.5 then Result := 2 * E
  else if F < 7.5 then Result := 5 * E
  else Result := 10 * E;
end;

{ TfrmMain }

procedure TfrmMain.FormCreate(Sender: TObject);
var
  I: Integer;
  AutoConnect: Boolean;
  SelArg: Integer;
begin
  FFmt := DefaultFormatSettings;
  FFmt.DecimalSeparator := '.';
  FFmt.ThousandSeparator := ',';
  DoubleBuffered := True;
  Constraints.MinWidth := 1400;
  Constraints.MinHeight := 840;
  FSel := -1;
  FFilter := -1;
  FFocus := -1;
  FHover := -1;
  FBackDirty := True;

  FFields[fHost].Caption := 'PLC IP / HOST';   FFields[fHost].Kind := fkText;  FFields[fHost].Text := '127.0.0.1';
  FFields[fPort].Caption := 'TCP PORT';        FFields[fPort].Kind := fkInt;   FFields[fPort].Text := '502';
  FFields[fUnit].Caption := 'UNIT ID';         FFields[fUnit].Kind := fkInt;   FFields[fUnit].Text := '1';
  FFields[fPoll].Caption := 'POLL MS';         FFields[fPoll].Kind := fkInt;   FFields[fPoll].Text := '200';
  FFields[fName].Caption := 'VARIABLE NAME';   FFields[fName].Kind := fkIdent;
  FFields[fAddr].Caption := 'MODBUS ADDR';     FFields[fAddr].Kind := fkInt;
  FFields[fMin].Caption := 'MIN';              FFields[fMin].Kind := fkFloat;
  FFields[fMax].Caption := 'MAX';              FFields[fMax].Kind := fkFloat;
  FFields[fUnitS].Caption := 'UNIT';           FFields[fUnitS].Kind := fkText;
  FFields[fWrite].Caption := 'NEW VALUE';      FFields[fWrite].Kind := fkFloat;

  // command line: [--host H] [--port P] [--connect] [--select N] [--vars file] [--snap out.png]
  FVarFile := ExtractFilePath(Application.ExeName) + 'vars.csv';
  AutoConnect := False;
  SelArg := 0;
  I := 1;
  while I <= ParamCount do
  begin
    if (ParamStr(I) = '--host') and (I < ParamCount) then begin FFields[fHost].Text := ParamStr(I + 1); Inc(I); end
    else if (ParamStr(I) = '--port') and (I < ParamCount) then begin FFields[fPort].Text := ParamStr(I + 1); Inc(I); end
    else if (ParamStr(I) = '--select') and (I < ParamCount) then begin SelArg := StrToIntDef(ParamStr(I + 1), 0); Inc(I); end
    else if (ParamStr(I) = '--vars') and (I < ParamCount) then begin FVarFile := ParamStr(I + 1); Inc(I); end
    else if (ParamStr(I) = '--snap') and (I < ParamCount) then begin FSnapFile := ParamStr(I + 1); Inc(I); end
    else if ParamStr(I) = '--connect' then AutoConnect := True;
    Inc(I);
  end;

  if FileExists(FVarFile) then
    LoadVarDefs(FVarFile, FDefs)
  else
  begin
    DefaultVarDefs(FDefs);
    SaveVarDefs(FVarFile, FDefs);
  end;

  FLink := TLinkThread.Create;
  DefsChanged;
  SelectVar(Min(SelArg, High(FDefs)));
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 50;
  FTimer.OnTimer := @TimerTick;
  Log(Format('LOADED %d VARIABLES FROM %s', [Length(FDefs), UpperCase(ExtractFileName(FVarFile))]));
  if AutoConnect then
    DoConnect;
  if FSnapFile <> '' then
    FSnapAt := 3.0;
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  FTimer.Enabled := False;
  FLink.Free;
  FBack.Free;
  FFrame.Free;
end;

procedure TfrmMain.TimerTick(Sender: TObject);
var
  I, N: Integer;
begin
  FPhase := FPhase + 0.05;
  FRes := FLink.Results;
  if (FLink.Stats.State <> FStats.State) and (FLink.Stats.LastErr <> '') then
    Log('LINK ' + LinkStateNames[FLink.Stats.State] + ' // ' + FLink.Stats.LastErr);
  FStats := FLink.Stats;
  if (FStats.Cycle <> FLastCycle) and (Length(FRes) = Length(FDefs)) then
  begin
    FLastCycle := FStats.Cycle;
    for I := 0 to High(FDefs) do
    begin
      N := Length(FHist[I]);
      if N >= HistLen then
      begin
        Move(FHist[I][1], FHist[I][0], (N - 1) * SizeOf(Double));
        N := N - 1;
      end
      else
        SetLength(FHist[I], N + 1);
      if FRes[I].Good then
        FHist[I][N] := FRes[I].Value
      else
        FHist[I][N] := NaN;
    end;
  end;
  Invalidate;
  if (FSnapFile <> '') and (FPhase >= FSnapAt) and Assigned(FFrame) then
  begin
    FFrame.SaveToFile(FSnapFile);
    FSnapFile := '';
    Close;
  end;
end;

procedure TfrmMain.Log(const S: string);
begin
  FLog := FormatDateTime('hh:nn:ss', Now) + '  ' + S;
end;

procedure TfrmMain.MarkDirty;
begin
  FBackDirty := True;
  Invalidate;
end;

function TfrmMain.Online: Boolean;
begin
  Result := FStats.State = lsOnline;
end;

procedure TfrmMain.RebuildView;
var
  I: Integer;
begin
  FView := nil;
  for I := 0 to High(FDefs) do
    if (FFilter < 0) or (Ord(FDefs[I].Area) = FFilter) then
    begin
      SetLength(FView, Length(FView) + 1);
      FView[High(FView)] := I;
    end;
  FScroll := EnsureRange(FScroll, 0, Max(0, Length(FView) - VisibleRows));
end;

procedure TfrmMain.DefsChanged;
var
  I: Integer;
begin
  FLink.SetDefs(FDefs);
  SetLength(FHist, Length(FDefs));
  for I := 0 to High(FHist) do
    FHist[I] := nil;
  FRes := nil;
  if FSel > High(FDefs) then
    FSel := High(FDefs);
  RebuildView;
  MarkDirty;
end;

function TfrmMain.SelDef(out D: TVarDef): Boolean;
begin
  Result := (FSel >= 0) and (FSel <= High(FDefs));
  if Result then
    D := FDefs[FSel];
end;

function TfrmMain.CurValue(I: Integer): Double;
begin
  if (I >= 0) and (I <= High(FRes)) and FRes[I].Good then
    Result := FRes[I].Value
  else
    Result := NaN;
end;

procedure TfrmMain.SelectVar(I: Integer);
begin
  if (I < 0) or (I > High(FDefs)) then
    Exit;
  FSel := I;
  LoadDefIntoForm(I);
  if not IsNan(CurValue(I)) then
    FFields[fWrite].Text := FloatToStr(CurValue(I), FFmt)
  else
    FFields[fWrite].Text := '';
  if FFocus = Ord(fWrite) then
    FFocus := -1;
  MarkDirty;
end;

procedure TfrmMain.LoadDefIntoForm(I: Integer);
begin
  with FDefs[I] do
  begin
    FFields[fName].Text := Name;
    FFields[fAddr].Text := IntToStr(Addr);
    FFields[fMin].Text := FloatToStr(MinV, FFmt);
    FFields[fMax].Text := FloatToStr(MaxV, FFmt);
    FFields[fUnitS].Text := UnitS;
    FDefArea := Area;
    FDefType := DType;
  end;
end;

function TfrmMain.ParseNum(const S: string; out V: Double): Boolean;
var
  T: string;
begin
  T := UpperCase(Trim(S));
  if (T = 'ON') or (T = 'TRUE') then begin V := 1; Exit(True); end;
  if (T = 'OFF') or (T = 'FALSE') then begin V := 0; Exit(True); end;
  Result := TryStrToFloat(T, V, FFmt);
end;

function TfrmMain.FormToDef(out D: TVarDef): Boolean;
begin
  Result := False;
  D.Name := Trim(FFields[fName].Text);
  if D.Name = '' then
  begin
    Log('DEFINE: NAME IS EMPTY');
    Exit;
  end;
  D.Addr := StrToIntDef(FFields[fAddr].Text, -1);
  if (D.Addr < 0) or (D.Addr > 65535) then
  begin
    Log('DEFINE: ADDRESS MUST BE 0..65535');
    Exit;
  end;
  D.Area := FDefArea;
  D.DType := FDefType;
  if not ParseNum(FFields[fMin].Text, D.MinV) then D.MinV := 0;
  if not ParseNum(FFields[fMax].Text, D.MaxV) then D.MaxV := 100;
  if IsBitArea(D.Area) then
  begin
    D.MinV := 0;
    D.MaxV := 1;
  end;
  D.UnitS := StringReplace(Trim(FFields[fUnitS].Text), ',', ' ', [rfReplaceAll]);
  Result := True;
end;

function TfrmMain.FmtVal(const D: TVarDef; V: Double): string;
begin
  if IsNan(V) then
    Exit('--');
  case D.DType of
    dtBool: if V <> 0 then Result := 'ON' else Result := 'OFF';
    dtReal: Result := FormatFloat('0.00', V, FFmt);
  else
    Result := FormatFloat('0', V, FFmt);
  end;
end;

function TfrmMain.StepFor(const D: TVarDef): Double;
begin
  Result := NiceStep((D.MaxV - D.MinV) / 100);
  if D.DType <> dtReal then
    Result := Max(1, Round(Result));
end;

procedure TfrmMain.WriteVar(I: Integer; V: Double);
var
  D: TVarDef;
begin
  if (I < 0) or (I > High(FDefs)) then
    Exit;
  D := FDefs[I];
  if not IsWritable(D.Area) then
  begin
    Log(UpperCase(D.Name) + ' IS READ ONLY (' + AreaNames[D.Area] + ')');
    Exit;
  end;
  if not Online then
  begin
    Log('NOT CONNECTED // PRESS CONNECT FIRST');
    Exit;
  end;
  if (not IsBitArea(D.Area)) and (D.MaxV > D.MinV) and ((V < D.MinV) or (V > D.MaxV)) then
  begin
    Log(Format('%s: %s OUT OF RANGE %s..%s', [UpperCase(D.Name), FloatToStr(V, FFmt),
      FloatToStr(D.MinV, FFmt), FloatToStr(D.MaxV, FFmt)]));
    Exit;
  end;
  FLink.QueueWrite(D, V);
  Log(Format('WRITE QUEUED  %s := %s', [UpperCase(D.Name), FmtVal(D, V)]));
end;

procedure TfrmMain.DoConnect;
begin
  if FLink.WantConnect then
  begin
    FLink.SetConnect(False);
    Log('DISCONNECT REQUESTED');
  end
  else
  begin
    FLink.Configure(Trim(FFields[fHost].Text), EnsureRange(StrToIntDef(FFields[fPort].Text, 502), 1, 65535),
      EnsureRange(StrToIntDef(FFields[fUnit].Text, 1), 0, 255),
      EnsureRange(StrToIntDef(FFields[fPoll].Text, 200), 20, 10000), FSwap);
    FLink.SetConnect(True);
    Log(Format('CONNECTING TO %s:%s ...', [FFields[fHost].Text, FFields[fPort].Text]));
  end;
end;

procedure TfrmMain.DoButton(const Btn: TButtonRec);
var
  D: TVarDef;
  V: Double;
begin
  case Btn.Id of
    bConnect: DoConnect;
    bWord:
      begin
        FSwap := not FSwap;
        FLink.Configure(Trim(FFields[fHost].Text), EnsureRange(StrToIntDef(FFields[fPort].Text, 502), 1, 65535),
          EnsureRange(StrToIntDef(FFields[fUnit].Text, 1), 0, 255),
          EnsureRange(StrToIntDef(FFields[fPoll].Text, 200), 20, 10000), FSwap);
      end;
    bArea:
      begin
        if FDefArea = High(TArea) then FDefArea := Low(TArea) else FDefArea := Succ(FDefArea);
        if IsBitArea(FDefArea) then
          FDefType := dtBool
        else if FDefType = dtBool then
          FDefType := dtInt;
        MarkDirty;
      end;
    bType:
      if not IsBitArea(FDefArea) then
      begin
        if FDefType = dtReal then FDefType := dtInt else FDefType := Succ(FDefType);
        MarkDirty;
      end;
    bNew:
      begin
        FFields[fName].Text := 'New_Var';
        FFields[fAddr].Text := '10';
        FFields[fMin].Text := '0';
        FFields[fMax].Text := '100';
        FFields[fUnitS].Text := '';
        FFocus := Ord(fName);
        Log('DEFINE: FILL THE FORM THEN PRESS ADD');
      end;
    bAdd:
      if FormToDef(D) then
      begin
        SetLength(FDefs, Length(FDefs) + 1);
        FDefs[High(FDefs)] := D;
        DefsChanged;
        SelectVar(High(FDefs));
        Log('ADDED ' + UpperCase(D.Name) + ' // PRESS SAVE CSV TO KEEP IT');
      end;
    bApply:
      if (FSel >= 0) and FormToDef(D) then
      begin
        FDefs[FSel] := D;
        DefsChanged;
        SelectVar(FSel);
        Log('UPDATED ' + UpperCase(D.Name));
      end;
    bDelete:
      if FSel >= 0 then
      begin
        Log('DELETED ' + UpperCase(FDefs[FSel].Name));
        Delete(FDefs, FSel, 1);
        DefsChanged;
        if Length(FDefs) > 0 then
          SelectVar(Min(FSel, High(FDefs)))
        else
          FSel := -1;
      end;
    bSave:
      begin
        SaveVarDefs(FVarFile, FDefs);
        Log('SAVED ' + UpperCase(FVarFile));
      end;
    bReload:
      if FileExists(FVarFile) then
      begin
        LoadVarDefs(FVarFile, FDefs);
        FSel := -1;
        DefsChanged;
        SelectVar(0);
        Log('RELOADED ' + UpperCase(ExtractFileName(FVarFile)));
      end;
    bWrite:
      if ParseNum(FFields[fWrite].Text, V) then
        WriteVar(FSel, V)
      else
        Log('INVALID NUMBER: ' + FFields[fWrite].Text);
    bDec, bInc:
      if SelDef(D) and not IsNan(CurValue(FSel)) then
      begin
        if Btn.Id = bInc then
          V := CurValue(FSel) + StepFor(D)
        else
          V := CurValue(FSel) - StepFor(D);
        if D.MaxV > D.MinV then
          V := EnsureRange(V, D.MinV, D.MaxV);
        WriteVar(FSel, V);
      end;
    bOn: WriteVar(FSel, 1);
    bOff: WriteVar(FSel, 0);
    bToggle:
      if not IsNan(CurValue(FSel)) then
        WriteVar(FSel, Ord(CurValue(FSel) = 0));
    bFilter:
      begin
        FFilter := Btn.Arg;
        FScroll := 0;
        RebuildView;
        MarkDirty;
      end;
  end;
end;

{ ---------------------------------------------------------------- layout }

procedure TfrmMain.AddBtn(const ARect: TRect; AId: TBtnId; const ACaption: string;
  AStyle: TBtnStyle; AArg: Integer);
begin
  SetLength(FBtns, Length(FBtns) + 1);
  with FBtns[High(FBtns)] do
  begin
    R := ARect;
    Id := AId;
    Caption := ACaption;
    Style := AStyle;
    Arg := AArg;
  end;
end;

procedure TfrmMain.SetField(F: TFieldId; const R: TRect; AVisible: Boolean);
begin
  FFields[F].R := R;
  FFields[F].Visible := AVisible;
end;

function TfrmMain.VisibleRows: Integer;
begin
  Result := Max(1, (FListR.Bottom - FListR.Top) div RowH);
end;

procedure TfrmMain.DoLayout;
const
  M = 14;
var
  W, H, Top0, Bot, L, T, R, X, BW, I: Integer;
  D: TVarDef;
  HasSel: Boolean;
begin
  W := ClientWidth;
  H := ClientHeight;
  FBtns := nil;
  FHeaderR := Rect(0, 0, W, 50);
  FBottomR := Rect(M, H - 44, W - M, H - 12);
  Top0 := 64;
  Bot := FBottomR.Top - 12;
  FConnR := Rect(M, Top0, M + 330, Top0 + 318);
  FDefR := Rect(M, FConnR.Bottom + 40, M + 330, Bot);
  FMonR := Rect(W - M - 360, Top0, W - M, Bot);
  FTableR := Rect(FConnR.Right + 14, Top0, FMonR.Left - 14, Bot);

  // connection panel
  L := FConnR.Left; T := FConnR.Top; R := FConnR.Right;
  SetField(fHost, Rect(L + 14, T + 62, L + 206, T + 88));
  SetField(fPort, Rect(L + 216, T + 62, R - 14, T + 88));
  SetField(fUnit, Rect(L + 14, T + 112, L + 100, T + 138));
  SetField(fPoll, Rect(L + 110, T + 112, L + 206, T + 138));
  AddBtn(Rect(L + 216, T + 112, R - 14, T + 138), bWord, '', bsChip);
  AddBtn(Rect(L + 14, T + 152, R - 14, T + 188), bConnect, 'CONNECT', bsPrimary);

  // define panel
  L := FDefR.Left; T := FDefR.Top; R := FDefR.Right;
  SetField(fName, Rect(L + 14, T + 30, R - 14, T + 56));
  AddBtn(Rect(L + 14, T + 80, L + 160, T + 106), bArea, '', bsChip);
  AddBtn(Rect(L + 170, T + 80, R - 14, T + 106), bType, '', bsChip);
  SetField(fAddr, Rect(L + 14, T + 130, L + 104, T + 156));
  SetField(fMin, Rect(L + 114, T + 130, L + 214, T + 156));
  SetField(fMax, Rect(L + 224, T + 130, R - 14, T + 156));
  SetField(fUnitS, Rect(L + 14, T + 180, L + 104, T + 206));
  BW := (R - L - 28 - 18) div 4;
  AddBtn(Rect(L + 14, T + 222, L + 14 + BW, T + 250), bNew, 'NEW');
  AddBtn(Rect(L + 20 + BW, T + 222, L + 20 + 2 * BW, T + 250), bAdd, 'ADD', bsPrimary);
  AddBtn(Rect(L + 26 + 2 * BW, T + 222, L + 26 + 3 * BW, T + 250), bApply, 'APPLY');
  AddBtn(Rect(L + 32 + 3 * BW, T + 222, R - 14, T + 250), bDelete, 'DELETE', bsDanger);
  AddBtn(Rect(L + 14, T + 258, L + 14 + 2 * BW + 6, T + 286), bSave, 'SAVE CSV');
  AddBtn(Rect(L + 26 + 2 * BW, T + 258, R - 14, T + 286), bReload, 'RELOAD');

  // table
  L := FTableR.Left; T := FTableR.Top; R := FTableR.Right;
  X := L + 12;
  for I := -1 to 3 do
  begin
    AddBtn(Rect(X, T + 46, X + 92, T + 72), bFilter, FilterNames[I], bsTab, I);
    Inc(X, 84);
  end;
  FListR := Rect(L + 10, T + 102, R - 10, FTableR.Bottom - 12);

  // monitor
  L := FMonR.Left; T := FMonR.Top; R := FMonR.Right;
  FGaugeCX := (L + R) / 2;
  FGaugeCY := T + 238;
  FGaugeR := 86;
  FTrendR := Rect(L + 14, T + 370, R - 14, T + 482);
  HasSel := SelDef(D);
  SetField(fWrite, Rect(L + 14, T + 532, R - 124, T + 564),
    HasSel and IsWritable(D.Area) and not IsBitArea(D.Area));
  if HasSel and IsWritable(D.Area) then
  begin
    if IsBitArea(D.Area) then
    begin
      AddBtn(Rect(L + 14, T + 528, L + 114, T + 564), bOn, 'ON', bsPrimary);
      AddBtn(Rect(L + 124, T + 528, L + 224, T + 564), bOff, 'OFF');
      AddBtn(Rect(L + 234, T + 528, R - 14, T + 564), bToggle, 'TOGGLE');
    end
    else
    begin
      AddBtn(Rect(R - 114, T + 532, R - 14, T + 564), bWrite, 'WRITE', bsPrimary);
      AddBtn(Rect(L + 14, T + 574, L + 90, T + 602), bDec, '-');
      AddBtn(Rect(L + 100, T + 574, L + 176, T + 602), bInc, '+');
    end;
  end;
end;

{ ---------------------------------------------------------------- painting }

procedure TfrmMain.Paint;
begin
  if (FFrame = nil) or (FFrame.Width <> ClientWidth) or (FFrame.Height <> ClientHeight) then
  begin
    FreeAndNil(FFrame);
    FreeAndNil(FBack);
    FFrame := TBGRABitmap.Create(ClientWidth, ClientHeight, hcBg);
    FBack := TBGRABitmap.Create(ClientWidth, ClientHeight, hcBg);
    FBackDirty := True;
  end;
  if FBackDirty then
    RenderBack;
  FFrame.PutImage(0, 0, FBack, dmSet);
  RenderDynamic(FFrame);
  FFrame.Draw(Canvas, 0, 0, True);
end;

procedure TfrmMain.Resize;
begin
  inherited Resize;
  FBackDirty := True;
  Invalidate;
end;

procedure TfrmMain.RenderBack;
begin
  DoLayout;
  RebuildView;
  FBack.Fill(hcBg);
  DrawBackdrop(FBack);
  DrawHeader(FBack);
  DrawConnStatic(FBack);
  DrawDefStatic(FBack);
  DrawTableStatic(FBack);
  DrawMonStatic(FBack);
  DrawFieldLabels(FBack);
  ChamferPanel(FBack, RectFOf(FBottomR), 0, 0, 14, 14, WithAlpha(hcPanel, 160), WithAlpha(hcLineHi, 110));
  FBackDirty := False;
end;

procedure TfrmMain.DrawBackdrop(B: TBGRABitmap);
var
  X, Y: Integer;
begin
  X := 0;
  while X < B.Width do
  begin
    B.DrawLineAntialias(X, 50, X, B.Height, hcGrid, 1);
    Inc(X, 40);
  end;
  Y := 50;
  while Y < B.Height do
  begin
    B.DrawLineAntialias(0, Y, B.Width, Y, hcGrid, 1);
    Inc(Y, 40);
  end;
  X := 200;
  while X < B.Width do
  begin
    B.DrawLineAntialias(X, 50, X, B.Height, hcGridRed, 1);
    Inc(X, 320);
  end;
end;

procedure TfrmMain.DrawHeader(B: TBGRABitmap);
var
  W: Integer;
begin
  W := B.Width;
  B.GradientFill(0, 0, W, 50, BGRA(40, 42, 46), BGRA(24, 25, 28), gtLinear,
    PointF(0, 0), PointF(0, 50), dmSet);
  B.DrawLineAntialias(0, 49, W, 49, hcLine, 1);
  B.FillRectAntialias(0, 0, 8, 49, hcOrange);
  SetFont(B, FontHud, 22, True);
  TextSpaced(B, 22, 6, 'CODESYS LINK', hcText, 1.5);
  SetFont(B, FontMono, 11);
  TextSpaced(B, 24, 32, 'MODBUS TCP MASTER // BGRABITMAP HMI  v1.0', hcTextDim, 0.5);
  HatchStripes(B, RF(240, 12, 340, 38), WithAlpha(hcLine, 150), 3, 5);
  Chevrons(B, 350, 13, 24, 3, hcOrange);
end;

procedure TfrmMain.DrawStrip(B: TBGRABitmap; const R: TRect; const ATitle: string);
var
  W: Single;
begin
  W := Min(300, (R.Right - R.Left) * 0.62);
  B.FillPolyAntialias([PointF(R.Left + 12, R.Top + 10), PointF(R.Left + 12 + W, R.Top + 10),
    PointF(R.Left + 26 + W, R.Top + 36), PointF(R.Left + 12, R.Top + 36)], hcOlive);
  SetFont(B, FontHud, 16, True);
  TextSpaced(B, R.Left + 24, R.Top + 13, ATitle, hcInk, 1.2);
end;

procedure TfrmMain.DrawFieldLabels(B: TBGRABitmap);
var
  F: TFieldId;
  I: Integer;
  S: string;
begin
  SetFont(B, FontMono, 9);
  for F := Low(TFieldId) to High(TFieldId) do
    if FFields[F].Visible then
      TextAt(B, FFields[F].R.Left, FFields[F].R.Top - 14, FFields[F].Caption, hcTextDim);
  for I := 0 to High(FBtns) do
    if FBtns[I].Style = bsChip then
    begin
      case FBtns[I].Id of
        bWord: S := 'WORD ORDER (32 BIT)';
        bArea: S := 'MODBUS AREA';
        bType: S := 'DATA TYPE';
      else
        S := '';
      end;
      TextAt(B, FBtns[I].R.Left, FBtns[I].R.Top - 14, S, hcTextDim);
    end;
end;

procedure TfrmMain.DrawConnStatic(B: TBGRABitmap);
var
  R: TRectF;
  X, Y: Single;
  I: Integer;
const
  Names: array[0..4] of string = ('STATE', 'CYCLE', 'TX', 'RX', 'ERRORS');
begin
  R := RectFOf(FConnR);
  ChamferPanel(B, R, 0, 22, 0, 22, WithAlpha(hcPanelDark, 170), WithAlpha(hcLine, 160));
  DrawStrip(B, FConnR, 'LINK // MODBUS TCP');
  B.DrawLineAntialias(R.Left + 14, R.Top + 196, R.Right - 14, R.Top + 196, WithAlpha(hcLine, 120), 1);
  SetFont(B, FontMono, 10);
  X := R.Left + 128;
  for I := 0 to 4 do
  begin
    Y := R.Top + 206 + I * 16;
    TextAt(B, X, Y, Names[I], hcTextDim);
  end;
  HatchStripes(B, RF(R.Right - 70, R.Top + 16, R.Right - 30, R.Top + 30), WithAlpha(hcLine, 150), 3, 4);
end;

procedure TfrmMain.DrawDefStatic(B: TBGRABitmap);
var
  R: TRectF;
  A: TArea;
  Y: Single;
begin
  R := RectFOf(FDefR);
  TagLabel(B, R.Left, R.Top - 30, 'DEFINE VAR', hcOrange, hcInk, 24);
  ChamferPanel(B, R, 0, 22, 22, 8, WithAlpha(hcPanel, 120), WithAlpha(hcLineHi, 110));
  SetFont(B, FontMono, 9);
  TextAt(B, R.Left + 114, R.Top + 166, 'CODESYS I/O MAP (RELATIVE)', hcTextDim);
  Y := R.Top + 300;
  if Y + 64 < R.Bottom then
  begin
    B.DrawLineAntialias(R.Left + 12, Y - 6, R.Right - 24, Y - 6, WithAlpha(hcLine, 120), 1);
    for A := Low(TArea) to High(TArea) do
    begin
      TextAt(B, R.Left + 14, Y, AreaHint[A], hcTextDim);
      Y := Y + 14;
    end;
  end;
end;

procedure TfrmMain.DrawTableStatic(B: TBGRABitmap);
var
  R: TRectF;
  L, RR, CArea, CAddr, CType, CMap, CVal, Y: Single;
  K, I, N, Rows: Integer;
  D: TVarDef;
  S: string;
begin
  R := RectFOf(FTableR);
  ChamferPanel(B, R, 0, 26, 0, 26, WithAlpha(hcPanelDark, 170), WithAlpha(hcLine, 160));
  DrawStrip(B, FTableR, 'CODESYS VARIABLES');
  SetFont(B, FontMono, 12, True);
  TextAt(B, R.Left + 340, R.Top + 16, Format('%.3d DEF', [Length(FDefs)]), hcText);
  Chevrons(B, R.Left + 420, R.Top + 11, 24, 3, hcOrange);
  B.DrawLineAntialias(R.Left + 12, R.Top + 72, R.Right - 30, R.Top + 72, WithAlpha(hcLineHi, 150), 1);

  L := R.Left;
  RR := R.Right;
  CArea := L + Round((RR - L) * 0.36);
  CAddr := CArea + 62;
  CType := CAddr + 58;
  CMap := CType + 58;
  CVal := RR - 128;
  SetFont(B, FontMono, 9);
  Y := R.Top + 84;
  TextAt(B, L + 18, Y, '#', hcTextDim);
  TextAt(B, L + 58, Y, 'NAME', hcTextDim);
  TextAt(B, CArea, Y, 'AREA', hcTextDim);
  TextAt(B, CAddr, Y, 'ADDR', hcTextDim);
  TextAt(B, CType, Y, 'TYPE', hcTextDim);
  TextAt(B, CMap, Y, 'MAP', hcTextDim);
  TextAt(B, CVal, Y, 'VALUE', hcTextDim, taRightJustify);
  TextAt(B, RR - 70, Y, 'CTRL', hcTextDim, taCenter);

  Rows := VisibleRows;
  N := Min(Rows, Length(FView) - FScroll);
  SetLength(FRowR, Max(0, N));
  SetLength(FRowTog, Max(0, N));
  SetLength(FRowIdx, Max(0, N));
  for K := 0 to N - 1 do
  begin
    I := FView[FScroll + K];
    D := FDefs[I];
    Y := FListR.Top + K * RowH;
    FRowIdx[K] := I;
    FRowR[K] := Rect(FListR.Left, Round(Y), FListR.Right - 8, Round(Y) + RowH - 4);
    FRowTog[K] := Rect(0, 0, 0, 0);
    if I = FSel then
    begin
      B.FillRectAntialias(FListR.Left, Y, FListR.Right - 8, Y + RowH - 4, WithAlpha(hcLime, 36));
      B.FillRectAntialias(FListR.Left, Y, FListR.Left + 4, Y + RowH - 4, hcLime);
    end
    else
      B.FillRectAntialias(FListR.Left, Y, FListR.Right - 8, Y + RowH - 4, WithAlpha(hcPanel, 60));
    SetFont(B, FontMono, 10);
    TextAt(B, L + 18, Y + 9, Format('%.2d', [I + 1]), hcTextDim);
    SetFont(B, FontHud, 14, I = FSel);
    S := FitText(B, UpperCase(D.Name), Round(CArea - L - 70));
    if I = FSel then
      TextAt(B, L + 58, Y + 7, S, hcLime)
    else
      TextAt(B, L + 58, Y + 7, S, hcOrange);
    // area chip
    if IsWritable(D.Area) then
      B.RectangleAntialias(CArea, Y + 7, CArea + 46, Y + 23, hcOrange, 1)
    else
      B.RectangleAntialias(CArea, Y + 7, CArea + 46, Y + 23, hcLine, 1);
    SetFont(B, FontMono, 10, True);
    TextAt(B, CArea + 23, Y + 8, AreaNames[D.Area], hcText, taCenter);
    SetFont(B, FontMono, 11);
    TextAt(B, CAddr, Y + 8, Format('%.5d', [D.Addr]), hcText);
    TextAt(B, CType, Y + 8, TypeNames[D.DType], hcTextDim);
    SetFont(B, FontMono, 10);
    TextAt(B, CMap, Y + 9, FitText(B, CodesysAddress(D), Round(CVal - CMap - 70)), hcTextDim);
    // control column
    if IsWritable(D.Area) and IsBitArea(D.Area) then
      FRowTog[K] := Rect(Round(RR) - 92, Round(Y) + 6, Round(RR) - 48, Round(Y) + 24)
    else if IsWritable(D.Area) then
    begin
      ChamferPanel(B, RF(RR - 96, Y + 6, RR - 44, Y + 24), 0, 6, 0, 6, WithAlpha(hcOrange, 30), hcOrange, 1);
      SetFont(B, FontHud, 11, True);
      TextAt(B, RR - 70, Y + 7, 'SET', hcOrange, taCenter);
    end
    else
    begin
      SetFont(B, FontMono, 10);
      TextAt(B, RR - 70, Y + 9, 'RO', hcTextDim, taCenter);
    end;
  end;
  // scrollbar
  if Length(FView) > Rows then
  begin
    B.FillRectAntialias(FListR.Right - 4, FListR.Top, FListR.Right, FListR.Bottom, WithAlpha(hcLine, 60));
    Y := (FListR.Bottom - FListR.Top) * Rows / Length(FView);
    L := FListR.Top + (FListR.Bottom - FListR.Top - Y) * FScroll / Max(1, Length(FView) - Rows);
    B.FillRectAntialias(FListR.Right - 4, L, FListR.Right, L + Y, hcLineHi);
  end;
  if Length(FView) = 0 then
  begin
    SetFont(B, FontHud, 18, True);
    TextSpaced(B, (R.Left + R.Right) / 2, FListR.Top + 40, 'NO VARIABLES IN THIS AREA', hcTextDim, 2, taCenter);
  end;
end;

procedure TfrmMain.DrawMonStatic(B: TBGRABitmap);
var
  R: TRectF;
  D: TVarDef;
  I: Integer;
  A: Single;
  S: string;
begin
  R := RectFOf(FMonR);
  ChamferPanel(B, R, 22, 0, 22, 0, WithAlpha(hcPanelDark, 170), WithAlpha(hcLine, 160));
  DrawStrip(B, FMonR, 'LIVE MONITOR');
  if not SelDef(D) then
  begin
    SetFont(B, FontHud, 18, True);
    TextAt(B, (R.Left + R.Right) / 2, R.Top + 200, 'SELECT A VARIABLE', hcTextDim, taCenter);
    Exit;
  end;
  SetFont(B, FontHud, 26, True);
  TextAt(B, R.Left + 16, R.Top + 46, FitText(B, UpperCase(D.Name), Round(R.Right - R.Left) - 32), hcText);
  SetFont(B, FontMono, 11);
  S := Format('%s %.5d  //  %s', [AreaNames[D.Area], D.Addr, TypeNames[D.DType]]);
  if D.UnitS <> '' then
    S := S + '  //  ' + UpperCase(D.UnitS);
  TextAt(B, R.Left + 16, R.Top + 80, S, hcOrange);
  TextAt(B, R.Left + 16, R.Top + 96, 'CODESYS ' + CodesysAddress(D), hcTextDim);

  // gauge ticks
  if not IsBitArea(D.Area) then
  begin
    B.EllipseAntialias(FGaugeCX, FGaugeCY, FGaugeR, FGaugeR, WithAlpha(hcLine, 170), 1);
    ArcTicks(B, FGaugeCX, FGaugeCY, FGaugeR - 9, FGaugeR - 3, GaugeA0, GaugeA1, 40, WithAlpha(hcLine, 200), 1);
    ArcTicks(B, FGaugeCX, FGaugeCY, FGaugeR - 12, FGaugeR - 3, GaugeA0, GaugeA1, 4, hcLineHi, 1.5);
    SetFont(B, FontMono, 9);
    for I := 0 to 4 do
    begin
      A := GaugeA0 + (GaugeA1 - GaugeA0) * I / 4;
      S := FormatFloat('0.#', D.MinV + (D.MaxV - D.MinV) * I / 4, FFmt);
      TextAt(B, FGaugeCX + (FGaugeR + 18) * Cos(A), FGaugeCY + (FGaugeR + 18) * Sin(A) - 6, S, hcTextDim, taCenter);
    end;
  end
  else
  begin
    B.EllipseAntialias(FGaugeCX, FGaugeCY, FGaugeR, FGaugeR, WithAlpha(hcLine, 170), 1);
    ArcTicks(B, FGaugeCX, FGaugeCY, FGaugeR + 6, FGaugeR + 11, 0, 2 * Pi, 60, WithAlpha(hcLine, 160), 1);
  end;

  // trend frame
  B.FillRectAntialias(FTrendR.Left, FTrendR.Top, FTrendR.Right, FTrendR.Bottom, BGRA(10, 11, 13, 160));
  for I := 1 to 3 do
    DashedLine(B, FTrendR.Left, FTrendR.Top + (FTrendR.Bottom - FTrendR.Top) * I / 4, FTrendR.Right,
      FTrendR.Top + (FTrendR.Bottom - FTrendR.Top) * I / 4, WithAlpha(hcLine, 60), 1, 2, 4);
  CornerBrackets(B, RF(FTrendR.Left - 3, FTrendR.Top - 3, FTrendR.Right + 3, FTrendR.Bottom + 3), 10, hcLineHi, 1.2);
  SetFont(B, FontMono, 9);
  TextAt(B, FTrendR.Left, FTrendR.Top - 14, Format('TREND // LAST %d SAMPLES', [HistLen]), hcTextDim);

  SetFont(B, FontHud, 13, True);
  if IsWritable(D.Area) then
    TextSpaced(B, R.Left + 16, R.Top + 494, 'WRITE TO PLC', hcText, 1)
  else
  begin
    TextSpaced(B, R.Left + 16, R.Top + 494, 'READ ONLY', hcTextDim, 1);
    SetFont(B, FontMono, 10);
    TextAt(B, R.Left + 16, R.Top + 520, 'THIS AREA IS WRITTEN BY THE CODESYS PROGRAM', hcTextDim);
    TextAt(B, R.Left + 16, R.Top + 534, 'USE COIL / HR TO SEND VALUES TO THE PLC', hcTextDim);
  end;
  if IsWritable(D.Area) and not IsBitArea(D.Area) then
  begin
    SetFont(B, FontMono, 10);
    TextAt(B, R.Left + 190, R.Top + 582, Format('STEP %s  RANGE %s..%s', [FloatToStr(StepFor(D), FFmt),
      FloatToStr(D.MinV, FFmt), FloatToStr(D.MaxV, FFmt)]), hcTextDim);
  end;
end;

{ ---------------------------------------------------------------- per frame }

procedure TfrmMain.RenderDynamic(B: TBGRABitmap);
begin
  DrawClock(B);
  DrawConnDynamic(B);
  DrawTableDynamic(B);
  DrawMonDynamic(B);
  DrawFields(B);
  DrawButtons(B);
  DrawBottom(B);
end;

procedure TfrmMain.DrawClock(B: TBGRABitmap);
var
  X: Single;
  C: TBGRAPixel;
  S: string;
begin
  X := B.Width - 16;
  SetFont(B, FontHud, 20, True);
  TextSpaced(B, X, 6, FormatDateTime('hh:nn:ss', Now), hcText, 1, taRightJustify);
  SetFont(B, FontMono, 10);
  TextAt(B, X, 31, FormatDateTime('yyyy-mm-dd', Now), hcTextDim, taRightJustify);
  // link badge
  case FStats.State of
    lsOnline: C := hcLime;
    lsConnecting: C := hcOrange;
    lsError: C := BGRA(226, 82, 64);
  else
    C := hcTextDim;
  end;
  S := LinkStateNames[FStats.State];
  SetFont(B, FontHud, 14, True);
  ChamferPanel(B, RF(X - 290, 12, X - 140, 38), 0, 8, 0, 8, WithAlpha(C, 40), C, 1.2);
  TextSpaced(B, X - 215, 16, S, C, 1.5, taCenter);
  if (FStats.State = lsOnline) and (Frac(FPhase * 0.6) < 0.5) then
    B.FillEllipseAntialias(X - 278, 25, 4, 4, C);
end;

procedure TfrmMain.DrawFields(B: TBGRABitmap);
var
  F: TFieldId;
  R: TRect;
  Foc: Boolean;
  S: string;
  TX, TY: Single;
begin
  SetFont(B, FontMono, 13);
  for F := Low(TFieldId) to High(TFieldId) do
  begin
    if not FFields[F].Visible then
      Continue;
    R := FFields[F].R;
    Foc := FFocus = Ord(F);
    B.FillRectAntialias(R.Left, R.Top, R.Right, R.Bottom, BGRA(8, 9, 10, 235));
    if Foc then
    begin
      B.RectangleAntialias(R.Left, R.Top, R.Right, R.Bottom, hcOrange, 1.5);
      B.FillRectAntialias(R.Left, R.Bottom - 2, R.Right, R.Bottom, hcOrange);
    end
    else
      B.RectangleAntialias(R.Left, R.Top, R.Right, R.Bottom, WithAlpha(hcLine, 220), 1);
    S := FFields[F].Text;
    // show the tail when the text is wider than the box
    while (Length(S) > 1) and (TextW(B, S) > R.Right - R.Left - 18) do
      Delete(S, 1, 1);
    TX := R.Left + 8;
    TY := (R.Top + R.Bottom - TextH(B)) / 2;
    if Foc then
      TextAt(B, TX, TY, S, hcText)
    else
      TextAt(B, TX, TY, S, hcLime);
    if Foc and (Frac(FPhase * 1.5) < 0.5) then
      B.FillRectAntialias(TX + TextW(B, S) + 1, R.Top + 6, TX + TextW(B, S) + 3, R.Bottom - 6, hcOrange);
  end;
end;

procedure TfrmMain.DrawButtons(B: TBGRABitmap);
var
  I: Integer;
  R: TRectF;
  Hot, Act: Boolean;
  Cap: string;
  C, Ink: TBGRAPixel;
begin
  for I := 0 to High(FBtns) do
  begin
    R := RectFOf(FBtns[I].R);
    Hot := I = FHover;
    Cap := FBtns[I].Caption;
    case FBtns[I].Id of
      bConnect:
        if FLink.WantConnect then Cap := 'DISCONNECT' else Cap := 'CONNECT';
      bWord:
        if FSwap then Cap := 'HI-LO' else Cap := 'LO-HI';
      bArea: Cap := AreaNames[FDefArea];
      bType: Cap := TypeNames[FDefType];
    end;
    case FBtns[I].Style of
      bsTab:
        begin
          Act := FFilter = FBtns[I].Arg;
          TabShape(B, R, Cap, Act);
          Continue;
        end;
      bsChip:
        begin
          B.FillRectAntialias(R.Left, R.Top, R.Right, R.Bottom, BGRA(8, 9, 10, 235));
          if Hot then C := hcOrange else C := WithAlpha(hcLine, 220);
          B.RectangleAntialias(R.Left, R.Top, R.Right, R.Bottom, C, 1);
          SetFont(B, FontMono, 12, True);
          TextAt(B, R.Left + 8, (R.Top + R.Bottom - TextH(B)) / 2, Cap, hcLime);
          Chevrons(B, R.Right - 18, R.Top + 8, 10, 1, hcOrange);
          Continue;
        end;
      bsPrimary:
        begin
          C := hcOrange;
          if (FBtns[I].Id = bConnect) and FLink.WantConnect then
            C := hcLime;
        end;
      bsDanger: C := BGRA(226, 82, 64);
    else
      C := hcLineHi;
    end;
    if Hot then
    begin
      ChamferPanel(B, R, 0, 8, 0, 8, C, C, 1.2);
      Ink := hcInk;
    end
    else
    begin
      ChamferPanel(B, R, 0, 8, 0, 8, WithAlpha(C, 36), C, 1.2);
      Ink := C;
    end;
    if R.Bottom - R.Top > 32 then
      SetFont(B, FontHud, 16, True)
    else
      SetFont(B, FontHud, 13, True);
    TextSpaced(B, (R.Left + R.Right) / 2, (R.Top + R.Bottom - TextH(B)) / 2, Cap, Ink, 1.2, taCenter);
  end;
end;

procedure TfrmMain.DrawConnDynamic(B: TBGRABitmap);
var
  R: TRectF;
  CX, CY, A, X, Y: Single;
  I: Integer;
  C: TBGRAPixel;
  Vals: array[0..4] of string;
begin
  R := RectFOf(FConnR);
  CX := R.Left + 64;
  CY := R.Top + 250;
  case FStats.State of
    lsOnline: C := hcLime;
    lsConnecting: C := hcOrange;
    lsError: C := BGRA(226, 82, 64);
  else
    C := hcLine;
  end;
  B.EllipseAntialias(CX, CY, 38, 38, WithAlpha(hcLine, 140), 1);
  ArcTicks(B, CX, CY, 42, 46, 0, 2 * Pi, 36, WithAlpha(hcLine, 140), 1);
  if FStats.State in [lsOnline, lsConnecting] then
    for I := 0 to 2 do
    begin
      A := FPhase * 1.4 + I * 2 * Pi / 3;
      ArcLine(B, CX, CY, 32, A, A + 1.1, C, 3);
    end
  else
    ArcLine(B, CX, CY, 32, 0, 2 * Pi, WithAlpha(C, 120), 3);
  DiskIcon(B, CX, CY, 12, C);

  Vals[0] := LinkStateNames[FStats.State];
  Vals[1] := FormatFloat('0', FStats.CycleMs, FFmt) + ' MS';
  Vals[2] := IntToStr(FStats.Tx);
  Vals[3] := IntToStr(FStats.Rx);
  Vals[4] := IntToStr(FStats.Errors);
  SetFont(B, FontMono, 11, True);
  X := R.Right - 18;
  for I := 0 to 4 do
  begin
    Y := R.Top + 205 + I * 16;
    if I = 0 then
      TextAt(B, X, Y, Vals[I], C, taRightJustify)
    else
      TextAt(B, X, Y, Vals[I], hcText, taRightJustify);
  end;
  SetFont(B, FontMono, 9);
  TextAt(B, R.Left + 14, R.Top + 298, FitText(B, FStats.LastErr, Round(R.Right - R.Left) - 28), hcTextDim);
end;

procedure TfrmMain.DrawTableDynamic(B: TBGRABitmap);
var
  K, I: Integer;
  D: TVarDef;
  V: Double;
  Y, CVal: Single;
  C: TBGRAPixel;
  T: TRect;
  IsOn: Boolean;
begin
  CVal := FTableR.Right - 128;
  for K := 0 to High(FRowIdx) do
  begin
    I := FRowIdx[K];
    if I > High(FDefs) then
      Continue;
    D := FDefs[I];
    Y := FRowR[K].Top;
    V := CurValue(I);
    // quality dot
    if (I <= High(FRes)) and FRes[I].Good then
      C := hcLime
    else if (I <= High(FRes)) and (FRes[I].Err <> '') then
      C := BGRA(226, 82, 64)
    else
      C := hcLine;
    B.FillEllipseAntialias(FTableR.Left + 46, Y + 15, 3.5, 3.5, C);
    // value
    SetFont(B, FontHud, 16, True);
    if (I <= High(FRes)) and (FRes[I].Err <> '') and not FRes[I].Good then
      TextAt(B, CVal, Y + 5, 'ERR', BGRA(226, 82, 64), taRightJustify)
    else if D.DType = dtBool then
    begin
      if IsNan(V) then
        TextAt(B, CVal, Y + 5, '--', hcTextDim, taRightJustify)
      else if V <> 0 then
        TextAt(B, CVal, Y + 5, 'ON', hcLime, taRightJustify)
      else
        TextAt(B, CVal, Y + 5, 'OFF', hcTextDim, taRightJustify);
    end
    else
      TextAt(B, CVal, Y + 5, FmtVal(D, V), BGRA(244, 246, 248), taRightJustify);
    // toggle switch
    T := FRowTog[K];
    if T.Right > T.Left then
    begin
      IsOn := (not IsNan(V)) and (V <> 0);
      if IsOn then
      begin
        B.RoundRectAntialias(T.Left, T.Top, T.Right, T.Bottom, 9, 9, hcLime, 1, WithAlpha(hcLime, 90));
        B.FillEllipseAntialias(T.Right - 9, (T.Top + T.Bottom) / 2, 6, 6, hcLime);
      end
      else
      begin
        B.RoundRectAntialias(T.Left, T.Top, T.Right, T.Bottom, 9, 9, hcLine, 1, BGRA(8, 9, 10, 200));
        B.FillEllipseAntialias(T.Left + 9, (T.Top + T.Bottom) / 2, 6, 6, hcTextDim);
      end;
    end;
  end;
end;

procedure TfrmMain.DrawMonDynamic(B: TBGRABitmap);
var
  D: TVarDef;
  V, Lo, Hi, H: Double;
  Pct, A, KX, KY, X, Y, PX: Single;
  I, N: Integer;
  Pts: ArrayOfTPointF;
  C: TBGRAPixel;
  S: string;
  Good: Boolean;
begin
  if not SelDef(D) then
    Exit;
  V := CurValue(FSel);
  Good := not IsNan(V);

  // rotating outer ring
  for I := 0 to 2 do
  begin
    A := FPhase * 0.6 + I * 2 * Pi / 3;
    ArcLine(B, FGaugeCX, FGaugeCY, FGaugeR + 30, A, A + 0.8, WithAlpha(hcLineHi, 120), 1.5);
  end;

  if IsBitArea(D.Area) then
  begin
    if Good and (V <> 0) then
    begin
      B.FillEllipseAntialias(FGaugeCX, FGaugeCY, FGaugeR - 14, FGaugeR - 14, WithAlpha(hcLime, 40));
      B.EllipseAntialias(FGaugeCX, FGaugeCY, FGaugeR - 14, FGaugeR - 14, hcLime, 4);
      B.EllipseAntialias(FGaugeCX, FGaugeCY, FGaugeR - 6, FGaugeR - 6, WithAlpha(hcLime, 60 + Round(60 * Sin(FPhase * 4))), 6);
      C := hcLime;
      S := 'ON';
    end
    else
    begin
      B.EllipseAntialias(FGaugeCX, FGaugeCY, FGaugeR - 14, FGaugeR - 14, WithAlpha(hcLine, 200), 4);
      C := hcTextDim;
      if Good then S := 'OFF' else S := '--';
    end;
    SetFont(B, FontHud, 56, True);
    TextAt(B, FGaugeCX, FGaugeCY - 36, S, C, taCenter);
  end
  else
  begin
    if Good and (D.MaxV > D.MinV) then
      Pct := EnsureRange((V - D.MinV) / (D.MaxV - D.MinV), 0, 1)
    else
      Pct := 0;
    ArcLine(B, FGaugeCX, FGaugeCY, FGaugeR - 20, GaugeA0, GaugeA1, WithAlpha(hcLine, 90), 6);
    if Pct > 0.001 then
    begin
      ArcLine(B, FGaugeCX, FGaugeCY, FGaugeR - 20, GaugeA0, GaugeA0 + (GaugeA1 - GaugeA0) * Pct, WithAlpha(hcOrange, 90), 12);
      ArcLine(B, FGaugeCX, FGaugeCY, FGaugeR - 20, GaugeA0, GaugeA0 + (GaugeA1 - GaugeA0) * Pct, hcOrange, 6);
    end;
    A := GaugeA0 + (GaugeA1 - GaugeA0) * Pct;
    KX := FGaugeCX + (FGaugeR - 20) * Cos(A);
    KY := FGaugeCY + (FGaugeR - 20) * Sin(A);
    B.FillEllipseAntialias(KX, KY, 7, 7, hcBg);
    B.EllipseAntialias(KX, KY, 7, 7, hcOrange, 2);
    SetFont(B, FontHud, 38, True);
    TextAt(B, FGaugeCX, FGaugeCY - 30, FmtVal(D, V), BGRA(244, 246, 248), taCenter);
    SetFont(B, FontMono, 11);
    if Good then
      S := IntToStr(Round(Pct * 100)) + '%  ' + UpperCase(D.UnitS)
    else
      S := UpperCase(D.UnitS);
    TextAt(B, FGaugeCX, FGaugeCY + 14, S, hcOrange, taCenter);
  end;
  if (FSel <= High(FRes)) and (FRes[FSel].Err <> '') and not FRes[FSel].Good then
  begin
    SetFont(B, FontMono, 10, True);
    TextAt(B, FGaugeCX, FGaugeCY + 34, FRes[FSel].Err, BGRA(226, 82, 64), taCenter);
  end;

  // trend
  if FSel <= High(FHist) then
  begin
    N := Length(FHist[FSel]);
    if D.MaxV > D.MinV then
    begin
      Lo := D.MinV;
      Hi := D.MaxV;
    end
    else
    begin
      Lo := 0;
      Hi := 1;
    end;
    Pts := nil;
    for I := 0 to N - 1 do
    begin
      H := FHist[FSel][I];
      PX := FTrendR.Right - (N - 1 - I) * (FTrendR.Right - FTrendR.Left) / (HistLen - 1);
      if IsNan(H) then
      begin
        if Length(Pts) > 1 then
          B.DrawPolyLineAntialias(Pts, hcOrange, 1.6);
        Pts := nil;
        Continue;
      end;
      Y := FTrendR.Bottom - 4 - EnsureRange((H - Lo) / (Hi - Lo), 0, 1) * (FTrendR.Bottom - FTrendR.Top - 8);
      if (D.DType = dtBool) and (Length(Pts) > 0) then
      begin
        SetLength(Pts, Length(Pts) + 1);
        Pts[High(Pts)] := PointF(PX, Pts[High(Pts) - 1].Y);
      end;
      SetLength(Pts, Length(Pts) + 1);
      Pts[High(Pts)] := PointF(PX, Y);
    end;
    if Length(Pts) > 1 then
    begin
      B.DrawPolyLineAntialias(Pts, WithAlpha(hcOrange, 50), 6);
      B.DrawPolyLineAntialias(Pts, hcOrange, 1.6);
      B.FillEllipseAntialias(Pts[High(Pts)].X, Pts[High(Pts)].Y, 3.5, 3.5, hcText);
    end;
    SetFont(B, FontMono, 9);
    TextAt(B, FTrendR.Right - 4, FTrendR.Top + 3, FloatToStr(Hi, FFmt), hcTextDim, taRightJustify);
    TextAt(B, FTrendR.Right - 4, FTrendR.Bottom - 15, FloatToStr(Lo, FFmt), hcTextDim, taRightJustify);
  end;

  // last write result from the PLC link
  SetFont(B, FontMono, 10);
  X := FMonR.Left + 16;
  Y := FMonR.Top + 618;
  if FStats.WriteMsg <> '' then
  begin
    if Pos('FAIL', FStats.WriteMsg) > 0 then C := BGRA(226, 82, 64) else C := hcLime;
    TextAt(B, X, Y, FitText(B, FStats.WriteMsg, FMonR.Right - FMonR.Left - 32), C);
  end;
end;

procedure TfrmMain.DrawBottom(B: TBGRABitmap);
var
  R: TRectF;
begin
  R := RectFOf(FBottomR);
  FolderIcon(B, R.Left + 22, R.Top + 9, hcText);
  SetFont(B, FontMono, 12, True);
  TextSpaced(B, R.Left + 46, R.Top + 9, 'EVENT LOG', hcText, 1);
  B.DrawLineAntialias(R.Left + 150, R.Top + 6, R.Left + 150, R.Bottom - 6, hcLine, 1);
  SetFont(B, FontMono, 12);
  TextAt(B, R.Left + 164, R.Top + 9, FitText(B, FLog, Round(R.Right - R.Left) - 520), hcLime);
  SetFont(B, FontMono, 10);
  TextAt(B, R.Right - 90, R.Top + 10, '[TAB] NEXT FIELD  [ENTER] WRITE  [ESC] CANCEL  [WHEEL] SCROLL',
    hcTextDim, taRightJustify);
  Chevrons(B, R.Right - 74, R.Top + 9, 14, 2, hcOrange);
  HatchStripes(B, RF(R.Right - 52, R.Top + 8, R.Right - 16, R.Bottom - 8), WithAlpha(hcLine, 160), 3, 4);
end;

{ ---------------------------------------------------------------- input }

procedure TfrmMain.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  I, H: Integer;
  P: TPoint;
  F: TFieldId;
  Hand, Beam: Boolean;
begin
  inherited MouseMove(Shift, X, Y);
  P := Point(X, Y);
  H := -1;
  for I := 0 to High(FBtns) do
    if PtInRect(FBtns[I].R, P) then
      H := I;
  FHover := H;
  Hand := H >= 0;
  for I := 0 to High(FRowR) do
    Hand := Hand or PtInRect(FRowR[I], P);
  Beam := False;
  for F := Low(TFieldId) to High(TFieldId) do
    if FFields[F].Visible and PtInRect(FFields[F].R, P) then
      Beam := True;
  if Beam then
    Cursor := crIBeam
  else if Hand then
    Cursor := crHandPoint
  else
    Cursor := crDefault;
end;

procedure TfrmMain.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
  P: TPoint;
  F: TFieldId;
  D: TVarDef;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then
    Exit;
  P := Point(X, Y);
  for F := Low(TFieldId) to High(TFieldId) do
    if FFields[F].Visible and PtInRect(FFields[F].R, P) then
    begin
      FFocus := Ord(F);
      Invalidate;
      Exit;
    end;
  FFocus := -1;
  for I := 0 to High(FBtns) do
    if PtInRect(FBtns[I].R, P) then
    begin
      DoButton(FBtns[I]);
      Invalidate;
      Exit;
    end;
  for I := 0 to High(FRowR) do
  begin
    if (FRowTog[I].Right > FRowTog[I].Left) and PtInRect(FRowTog[I], P) then
    begin
      if not IsNan(CurValue(FRowIdx[I])) then
        WriteVar(FRowIdx[I], Ord(CurValue(FRowIdx[I]) = 0))
      else
        WriteVar(FRowIdx[I], 1);
      Exit;
    end;
    if PtInRect(FRowR[I], P) then
    begin
      SelectVar(FRowIdx[I]);
      D := FDefs[FRowIdx[I]];
      // the SET chip jumps straight into the write field
      if IsWritable(D.Area) and not IsBitArea(D.Area) and (X > FTableR.Right - 100) then
        FFocus := Ord(fWrite);
      Exit;
    end;
  end;
  Invalidate;
end;

function TfrmMain.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
var
  Old: Integer;
begin
  Result := True;
  Old := FScroll;
  if WheelDelta > 0 then Dec(FScroll) else Inc(FScroll);
  FScroll := EnsureRange(FScroll, 0, Max(0, Length(FView) - VisibleRows));
  if FScroll <> Old then
    MarkDirty;
end;

procedure TfrmMain.KeyDown(var Key: Word; Shift: TShiftState);
var
  N: Integer;
  Btn: TButtonRec;
  K: Integer;
begin
  inherited KeyDown(Key, Shift);
  if FFocus >= 0 then
  begin
    case Key of
      VK_TAB:
        begin
          // next visible field
          N := FFocus;
          repeat
            N := (N + 1) mod (Ord(High(TFieldId)) + 1);
          until FFields[TFieldId(N)].Visible or (N = FFocus);
          FFocus := N;
        end;
      VK_ESCAPE: FFocus := -1;
      VK_RETURN:
        begin
          if FFocus = Ord(fWrite) then
          begin
            Btn.Id := bWrite;
            DoButton(Btn);
          end
          else if FFocus in [Ord(fHost), Ord(fPort), Ord(fUnit), Ord(fPoll)] then
          begin
            if FLink.WantConnect then
              FLink.Configure(Trim(FFields[fHost].Text), EnsureRange(StrToIntDef(FFields[fPort].Text, 502), 1, 65535),
                EnsureRange(StrToIntDef(FFields[fUnit].Text, 1), 0, 255),
                EnsureRange(StrToIntDef(FFields[fPoll].Text, 200), 20, 10000), FSwap)
            else
              DoConnect;
          end;
          FFocus := -1;
        end;
      VK_DELETE: FFields[TFieldId(FFocus)].Text := '';
    else
      Exit;
    end;
    Key := 0;
    Invalidate;
    Exit;
  end;

  // no field focused: navigate the table
  K := -1;
  for N := 0 to High(FView) do
    if FView[N] = FSel then
      K := N;
  case Key of
    VK_UP: if K > 0 then SelectVar(FView[K - 1]);
    VK_DOWN: if (K >= 0) and (K < High(FView)) then SelectVar(FView[K + 1])
      else if (K < 0) and (Length(FView) > 0) then SelectVar(FView[0]);
    VK_SPACE:
      if (FSel >= 0) and IsWritable(FDefs[FSel].Area) and IsBitArea(FDefs[FSel].Area) then
      begin
        Btn.Id := bToggle;
        DoButton(Btn);
      end;
    VK_RETURN:
      if FFields[fWrite].Visible then
        FFocus := Ord(fWrite);
  else
    Exit;
  end;
  // keep the selection on screen
  for N := 0 to High(FView) do
    if FView[N] = FSel then
    begin
      if N < FScroll then FScroll := N;
      if N >= FScroll + VisibleRows then FScroll := N - VisibleRows + 1;
    end;
  MarkDirty;
  Key := 0;
end;

procedure TfrmMain.KeyPress(var Key: Char);
var
  F: TFieldId;
  Ok: Boolean;
begin
  inherited KeyPress(Key);
  if FFocus < 0 then
    Exit;
  F := TFieldId(FFocus);
  if Key = #8 then
  begin
    if FFields[F].Text <> '' then
      SetLength(FFields[F].Text, Length(FFields[F].Text) - 1);
  end
  else if (Key >= ' ') and (Key <= '~') and (Length(FFields[F].Text) < 40) then
  begin
    case FFields[F].Kind of
      fkInt: Ok := Key in ['0'..'9'];
      fkFloat: Ok := Key in ['0'..'9', '.', '-', 'e', 'E', 'o', 'O', 'n', 'N', 'f', 'F'];
      fkIdent: Ok := Key in ['A'..'Z', 'a'..'z', '0'..'9', '_'];
    else
      Ok := Key <> ',';
    end;
    if Ok then
      FFields[F].Text := FFields[F].Text + Key;
  end;
  Key := #0;
  Invalidate;
end;

end.
