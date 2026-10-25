unit ModbusTcp;

{ Minimal blocking Modbus TCP master (client) on top of FPC ssockets.
  Supports FC1/2 (read bits), FC3/4 (read registers), FC5 (write coil),
  FC6 (write register) and FC16 (write multiple registers). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ssockets;

const
  fcReadCoils          = $01;
  fcReadDiscreteInputs = $02;
  fcReadHolding        = $03;
  fcReadInput          = $04;
  fcWriteCoil          = $05;
  fcWriteRegister      = $06;
  fcWriteRegisters     = $10;

type
  TWordArray = array of Word;
  TBoolArray = array of Boolean;

  { Modbus exception returned by the slave: the connection is still fine }
  EModbusError = class(Exception);

  { TModbusClient }

  TModbusClient = class
  private
    FSock: TInetSocket;
    FTid: Word;
    FUnitId: Byte;
    FTimeout: Integer;
    FTxCount, FRxCount: Int64;
    procedure ReadExact(var Buf; Count: Integer);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Connect(const AHost: string; APort: Word; ATimeoutMs: Integer = 2000);
    procedure Disconnect;
    function Connected: Boolean;
    function Transact(const PDU: TBytes): TBytes;
    function ReadBits(AFunc: Byte; AAddr, ACount: Word): TBoolArray;
    function ReadRegs(AFunc: Byte; AAddr, ACount: Word): TWordArray;
    procedure WriteCoil(AAddr: Word; AValue: Boolean);
    procedure WriteReg(AAddr, AValue: Word);
    procedure WriteRegs(AAddr: Word; const AValues: array of Word);
    property UnitId: Byte read FUnitId write FUnitId;
    property TxCount: Int64 read FTxCount;
    property RxCount: Int64 read FRxCount;
  end;

function ModbusExceptionText(ACode: Byte): string;

implementation

function ModbusExceptionText(ACode: Byte): string;
begin
  case ACode of
    1: Result := 'ILLEGAL FUNCTION';
    2: Result := 'ILLEGAL DATA ADDRESS';
    3: Result := 'ILLEGAL DATA VALUE';
    4: Result := 'SLAVE DEVICE FAILURE';
    5: Result := 'ACKNOWLEDGE';
    6: Result := 'SLAVE DEVICE BUSY';
    10: Result := 'GATEWAY PATH UNAVAILABLE';
    11: Result := 'GATEWAY TARGET NO RESPONSE';
  else
    Result := 'EXCEPTION ' + IntToStr(ACode);
  end;
end;

{ TModbusClient }

constructor TModbusClient.Create;
begin
  inherited Create;
  FUnitId := 1;
  FTimeout := 2000;
end;

destructor TModbusClient.Destroy;
begin
  Disconnect;
  inherited Destroy;
end;

procedure TModbusClient.Connect(const AHost: string; APort: Word; ATimeoutMs: Integer);
begin
  Disconnect;
  FTimeout := ATimeoutMs;
  FSock := TInetSocket.Create(AHost, APort, ATimeoutMs);
  FSock.IOTimeout := ATimeoutMs;
end;

procedure TModbusClient.Disconnect;
begin
  FreeAndNil(FSock);
end;

function TModbusClient.Connected: Boolean;
begin
  Result := FSock <> nil;
end;

procedure TModbusClient.ReadExact(var Buf; Count: Integer);
var
  P: PByte;
  N, Got: Integer;
begin
  P := @Buf;
  Got := 0;
  while Got < Count do
  begin
    N := FSock.Read(P[Got], Count - Got);
    if N <= 0 then
      raise Exception.Create('RECEIVE TIMEOUT / CONNECTION CLOSED');
    Inc(Got, N);
  end;
end;

function TModbusClient.Transact(const PDU: TBytes): TBytes;
var
  Frame: TBytes;
  Hdr: array[0..6] of Byte;
  Len, Tid: Integer;
begin
  if FSock = nil then
    raise Exception.Create('NOT CONNECTED');
  Inc(FTid);
  SetLength(Frame, 7 + Length(PDU));
  Frame[0] := Hi(FTid);
  Frame[1] := Lo(FTid);
  Frame[2] := 0;
  Frame[3] := 0;
  Frame[4] := Hi(Word(Length(PDU) + 1));
  Frame[5] := Lo(Word(Length(PDU) + 1));
  Frame[6] := FUnitId;
  Move(PDU[0], Frame[7], Length(PDU));
  if FSock.Write(Frame[0], Length(Frame)) <> Length(Frame) then
    raise Exception.Create('SEND FAILED');
  Inc(FTxCount);

  // skip stale replies (e.g. late answers to a timed-out request)
  repeat
    ReadExact(Hdr, 7);
    Tid := (Hdr[0] shl 8) or Hdr[1];
    Len := (Hdr[4] shl 8) or Hdr[5];
    if (Len < 2) or (Len > 260) then
      raise Exception.Create('BAD MBAP LENGTH');
    SetLength(Result, Len - 1);
    ReadExact(Result[0], Len - 1);
  until Tid = FTid;
  Inc(FRxCount);

  if (Result[0] and $80) <> 0 then
  begin
    if Length(Result) > 1 then
      raise EModbusError.Create(ModbusExceptionText(Result[1]))
    else
      raise EModbusError.Create('MODBUS EXCEPTION');
  end;
  if Result[0] <> PDU[0] then
    raise Exception.Create('FUNCTION CODE MISMATCH');
end;

function TModbusClient.ReadBits(AFunc: Byte; AAddr, ACount: Word): TBoolArray;
var
  R: TBytes;
  I: Integer;
begin
  R := Transact(TBytes.Create(AFunc, Hi(AAddr), Lo(AAddr), Hi(ACount), Lo(ACount)));
  if Length(R) < 2 + (ACount + 7) div 8 then
    raise Exception.Create('SHORT BIT RESPONSE');
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
    Result[I] := (R[2 + I div 8] and (1 shl (I mod 8))) <> 0;
end;

function TModbusClient.ReadRegs(AFunc: Byte; AAddr, ACount: Word): TWordArray;
var
  R: TBytes;
  I: Integer;
begin
  R := Transact(TBytes.Create(AFunc, Hi(AAddr), Lo(AAddr), Hi(ACount), Lo(ACount)));
  if Length(R) < 2 + ACount * 2 then
    raise Exception.Create('SHORT REGISTER RESPONSE');
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
    Result[I] := (R[2 + I * 2] shl 8) or R[3 + I * 2];
end;

procedure TModbusClient.WriteCoil(AAddr: Word; AValue: Boolean);
var
  V: Byte;
begin
  if AValue then V := $FF else V := 0;
  Transact(TBytes.Create(fcWriteCoil, Hi(AAddr), Lo(AAddr), V, 0));
end;

procedure TModbusClient.WriteReg(AAddr, AValue: Word);
begin
  Transact(TBytes.Create(fcWriteRegister, Hi(AAddr), Lo(AAddr), Hi(AValue), Lo(AValue)));
end;

procedure TModbusClient.WriteRegs(AAddr: Word; const AValues: array of Word);
var
  P: TBytes;
  I, N: Integer;
begin
  N := Length(AValues);
  SetLength(P, 6 + N * 2);
  P[0] := fcWriteRegisters;
  P[1] := Hi(AAddr);
  P[2] := Lo(AAddr);
  P[3] := Hi(Word(N));
  P[4] := Lo(Word(N));
  P[5] := N * 2;
  for I := 0 to N - 1 do
  begin
    P[6 + I * 2] := Hi(AValues[I]);
    P[7 + I * 2] := Lo(AValues[I]);
  end;
  Transact(P);
end;

end.
