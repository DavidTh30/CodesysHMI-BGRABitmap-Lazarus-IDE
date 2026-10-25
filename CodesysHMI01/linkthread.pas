unit LinkThread;

{ Background polling thread. The UI only talks to it through thread-safe
  methods: Configure / SetConnect / SetDefs / QueueWrite and the snapshot
  getters. All socket I/O happens here so the HUD never blocks. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Math, ModbusTcp, PlcVars;

type
  TLinkState = (lsOffline, lsConnecting, lsOnline, lsError);

  TVarResult = record
    Value: Double;
    Good: Boolean;
    Err: string;
  end;
  TVarResults = array of TVarResult;

  TLinkStats = record
    State: TLinkState;
    LastErr: string;
    WriteMsg: string;
    Tx, Rx, Errors: Int64;
    CycleMs: Double;
    Cycle: Int64;
  end;

  TWriteReq = record
    Def: TVarDef;
    Value: Double;
  end;

  { TLinkThread }

  TLinkThread = class(TThread)
  private
    FCS: TCriticalSection;
    FClient: TModbusClient;
    // shared, guarded by FCS
    FHost: string;
    FPort: Word;
    FUnitId: Byte;
    FPollMs: Integer;
    FSwap: Boolean;
    FWant: Boolean;
    FDefs: TVarDefs;
    FDefVer: Integer;
    FResults: TVarResults;
    FWrites: array of TWriteReq;
    FStats: TLinkStats;
    procedure SetState(AState: TLinkState; const AErr: string);
    procedure SleepSlices(AMs: Integer);
    procedure DoWrite(const W: TWriteReq; ASwap: Boolean);
    function ReadVar(const D: TVarDef; ASwap: Boolean): Double;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Configure(const AHost: string; APort: Word; AUnitId: Byte; APollMs: Integer; ASwap: Boolean);
    procedure SetConnect(AValue: Boolean);
    procedure SetDefs(const ADefs: TVarDefs);
    procedure QueueWrite(const ADef: TVarDef; AValue: Double);
    function Results: TVarResults;
    function Stats: TLinkStats;
    function WantConnect: Boolean;
  end;

const
  LinkStateNames: array[TLinkState] of string = ('OFFLINE', 'CONNECTING', 'ONLINE', 'ERROR');

implementation

{ TLinkThread }

constructor TLinkThread.Create;
begin
  FCS := TCriticalSection.Create;
  FClient := TModbusClient.Create;
  FHost := '127.0.0.1';
  FPort := 502;
  FUnitId := 1;
  FPollMs := 200;
  inherited Create(False);
end;

destructor TLinkThread.Destroy;
begin
  Terminate;
  WaitFor;
  FClient.Free;
  FCS.Free;
  inherited Destroy;
end;

procedure TLinkThread.Configure(const AHost: string; APort: Word; AUnitId: Byte;
  APollMs: Integer; ASwap: Boolean);
begin
  FCS.Enter;
  try
    FHost := AHost;
    FPort := APort;
    FUnitId := AUnitId;
    FPollMs := Max(20, APollMs);
    FSwap := ASwap;
  finally
    FCS.Leave;
  end;
end;

procedure TLinkThread.SetConnect(AValue: Boolean);
begin
  FCS.Enter;
  try
    FWant := AValue;
  finally
    FCS.Leave;
  end;
end;

function TLinkThread.WantConnect: Boolean;
begin
  FCS.Enter;
  try
    Result := FWant;
  finally
    FCS.Leave;
  end;
end;

procedure TLinkThread.SetDefs(const ADefs: TVarDefs);
var
  I: Integer;
begin
  FCS.Enter;
  try
    FDefs := Copy(ADefs);
    Inc(FDefVer);
    SetLength(FResults, Length(FDefs));
    for I := 0 to High(FResults) do
    begin
      FResults[I].Value := NaN;
      FResults[I].Good := False;
      FResults[I].Err := '';
    end;
  finally
    FCS.Leave;
  end;
end;

procedure TLinkThread.QueueWrite(const ADef: TVarDef; AValue: Double);
begin
  FCS.Enter;
  try
    SetLength(FWrites, Length(FWrites) + 1);
    FWrites[High(FWrites)].Def := ADef;
    FWrites[High(FWrites)].Value := AValue;
  finally
    FCS.Leave;
  end;
end;

function TLinkThread.Results: TVarResults;
begin
  FCS.Enter;
  try
    Result := Copy(FResults);
  finally
    FCS.Leave;
  end;
end;

function TLinkThread.Stats: TLinkStats;
begin
  FCS.Enter;
  try
    Result := FStats;
    Result.Tx := FClient.TxCount;
    Result.Rx := FClient.RxCount;
  finally
    FCS.Leave;
  end;
end;

procedure TLinkThread.SetState(AState: TLinkState; const AErr: string);
begin
  FCS.Enter;
  try
    FStats.State := AState;
    if AErr <> '' then
      FStats.LastErr := AErr;
    if AState = lsError then
      Inc(FStats.Errors);
  finally
    FCS.Leave;
  end;
end;

procedure TLinkThread.SleepSlices(AMs: Integer);
var
  T0: QWord;
  Pending: Boolean;
begin
  T0 := GetTickCount64;
  while (not Terminated) and (GetTickCount64 - T0 < QWord(AMs)) do
  begin
    FCS.Enter;
    Pending := Length(FWrites) > 0;
    FCS.Leave;
    if Pending then
      Exit;
    Sleep(10);
  end;
end;

function TLinkThread.ReadVar(const D: TVarDef; ASwap: Boolean): Double;
var
  B: TBoolArray;
  R: TWordArray;
begin
  case D.Area of
    arCoil, arDI:
      begin
        if D.Area = arCoil then
          B := FClient.ReadBits(fcReadCoils, D.Addr, 1)
        else
          B := FClient.ReadBits(fcReadDiscreteInputs, D.Addr, 1);
        Result := Ord(B[0]);
      end;
  else
    if D.Area = arHR then
      R := FClient.ReadRegs(fcReadHolding, D.Addr, RegCount(D.DType))
    else
      R := FClient.ReadRegs(fcReadInput, D.Addr, RegCount(D.DType));
    Result := DecodeRegs(R, D.DType, ASwap);
  end;
end;

procedure TLinkThread.DoWrite(const W: TWriteReq; ASwap: Boolean);
var
  R: TWordArray;
  Msg: string;
begin
  try
    case W.Def.Area of
      arCoil: FClient.WriteCoil(W.Def.Addr, W.Value <> 0);
      arHR:
        begin
          R := EncodeValue(W.Value, W.Def.DType, ASwap);
          if Length(R) = 1 then
            FClient.WriteReg(W.Def.Addr, R[0])
          else
            FClient.WriteRegs(W.Def.Addr, R);
        end;
    else
      raise EModbusError.Create('AREA IS READ ONLY');
    end;
    Msg := Format('WRITE OK  %s := %s', [UpperCase(W.Def.Name), FloatToStr(W.Value)]);
  except
    on E: EModbusError do
    begin
      Msg := Format('WRITE FAIL  %s : %s', [UpperCase(W.Def.Name), E.Message]);
      FCS.Enter;
      Inc(FStats.Errors);
      FCS.Leave;
    end;
  end;
  FCS.Enter;
  FStats.WriteMsg := Msg;
  FCS.Leave;
end;

procedure TLinkThread.Execute;
var
  Host: string;
  Port: Word;
  UnitId: Byte;
  Poll, Ver, I: Integer;
  Swap, Want: Boolean;
  Defs: TVarDefs;
  Writes: array of TWriteReq;
  Res: TVarResults;
  T0: QWord;
begin
  while not Terminated do
  begin
    FCS.Enter;
    try
      Host := FHost;
      Port := FPort;
      UnitId := FUnitId;
      Poll := FPollMs;
      Swap := FSwap;
      Want := FWant;
      Defs := Copy(FDefs);
      Ver := FDefVer;
      Writes := Copy(FWrites);
      FWrites := nil;
    finally
      FCS.Leave;
    end;

    if Want and not FClient.Connected then
    begin
      SetState(lsConnecting, '');
      try
        FClient.Connect(Host, Port, 2000);
        SetState(lsOnline, Format('CONNECTED TO %s:%d', [Host, Port]));
      except
        on E: Exception do
        begin
          FClient.Disconnect;
          SetState(lsError, UpperCase(E.Message));
          SleepSlices(1500);
          Continue;
        end;
      end;
    end
    else if (not Want) and FClient.Connected then
    begin
      FClient.Disconnect;
      SetState(lsOffline, 'DISCONNECTED BY USER');
    end;

    if FClient.Connected then
    begin
      FClient.UnitId := UnitId;
      T0 := GetTickCount64;
      try
        for I := 0 to High(Writes) do
          DoWrite(Writes[I], Swap);
        Res := nil;   // fresh array: the previous one is now owned by FResults
        SetLength(Res, Length(Defs));
        for I := 0 to High(Defs) do
        begin
          try
            Res[I].Value := ReadVar(Defs[I], Swap);
            Res[I].Good := True;
            Res[I].Err := '';
          except
            on E: EModbusError do
            begin
              Res[I].Value := NaN;
              Res[I].Good := False;
              Res[I].Err := E.Message;
            end;
          end;
        end;
        FCS.Enter;
        try
          if (Ver = FDefVer) and (Length(FResults) = Length(Res)) then
            FResults := Res;
          FStats.CycleMs := GetTickCount64 - T0;
          Inc(FStats.Cycle);
          if FStats.State <> lsOnline then
            FStats.State := lsOnline;
        finally
          FCS.Leave;
        end;
      except
        on E: Exception do
        begin
          FClient.Disconnect;
          SetState(lsError, UpperCase(E.Message));
          FCS.Enter;
          for I := 0 to High(FResults) do
            FResults[I].Good := False;
          FCS.Leave;
        end;
      end;
    end
    else if (not Want) and (Length(Writes) > 0) then
    begin
      FCS.Enter;
      FStats.WriteMsg := 'WRITE IGNORED // NOT CONNECTED';
      FCS.Leave;
    end;

    SleepSlices(Poll);
  end;
  FClient.Disconnect;
end;

end.
