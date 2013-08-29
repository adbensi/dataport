unit DataPortSerial;
{
  Sergey Bodrov, 2012-2013
}

interface
uses SysUtils, Classes, DataPort, synaser, synautil;

type
  { TSerialClient - serial port reader/writer, based on Ararat Synapse }
  TSerialClient = class(TThread)
  private
    Serial: TBlockSerial;
    s: string;
    sLastError: string;
    FSafeMode: boolean;
    FOnIncomingMsgEvent: TMsgEvent;
    FOnErrorEvent: TMsgEvent;
    FOnConnectEvent: TNotifyEvent;
    procedure SyncProc();
    procedure SyncProcOnConnect();
  protected
    procedure Execute(); override;
  public
    InitStr: string;
    sPort: string;
    iBaudRate: Integer;
    DataBits: Integer;
    Parity: Char;
    StopBits: Integer;
    SoftFlow: Boolean;
    HardFlow: Boolean;
    CalledFromThread: Boolean;
    sToSend: string;
    property SafeMode: boolean read FSafeMode write FSafeMode;
    property OnIncomingMsgEvent: TMsgEvent read FOnIncomingMsgEvent write FOnIncomingMsgEvent;
    property OnErrorEvent: TMsgEvent read FOnErrorEvent write FOnErrorEvent;
    property OnConnectEvent: TNotifyEvent read FOnConnectEvent write FOnConnectEvent;
    function SendString(s: string): Boolean;
    procedure SendStream(st: TStream; Dest: string);
  end;

  { TDataPortSerial - serial DataPort }
  TDataPortSerial = class(TDataPort)
  private
    //slReadData: TStringList; // for storing every incoming data packet separately
    sReadData: AnsiString;
    lock: TMultiReadExclusiveWriteSynchronizer;
    FPort: string;
    FInitStr: string;
    FBaudRate: integer;
    FMinDataBytes: Integer;
    FOnConnect: TNotifyEvent;
    procedure IncomingMsgHandler(Sender: TObject; AMsg: string);
    procedure ErrorEventHandler(Sender: TObject; AMsg: string);
    procedure ConnectHandler(Sender: TObject);
  public
    SerialClient: TSerialClient;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy(); override;
    { Open serial DataPort
         InitStr = 'Port,BaudRate,DataBits,Parity,StopBits,SoftFlow,HardFlow'

         Port - COM port name (COM1, /dev/tty01)
         BaudRate - connection speed (50..4000000 bits per second), default 9600
         DataBits - default 8
         Parity - (N - None, O - Odd, E - Even, M - Mark or S - Space) default N
         StopBits - (1, 1.5, 2)
         SoftFlow - Enable XON/XOFF handshake, default 1
         HardFlow - Enable CTS/RTS handshake, default 0 }
    procedure Open(InitStr: string = ''); override;
    procedure Close(); override;
    function Push(sMsg: AnsiString): Boolean; override;
    function Pull(size: Integer = MaxInt): AnsiString; override;
    function Peek(size: Integer = MaxInt): AnsiString; override;
    function PeekSize(): Cardinal; override;
    function GetSerialPortNames(): string;
  published
    { COM port name }
    property Port: string read FPort write FPort;
    { COM port baud rate }
    property BaudRate: Integer read FBaudRate write FBaudRate;
    { Minimum bytes in incoming buffer to trigger OnDataAppear }
    property MinDataBytes: Integer read FMinDataBytes write FMinDataBytes;
    property Active;
    property OnDataAppear;
    property OnError;
    property OnConnect: TNotifyEvent read FOnConnect write FOnConnect;
  end;


procedure Register;

implementation

procedure Register;
begin
  RegisterComponents('DataPort', [TDataPortSerial]);
end;

// === TSerialClient ===
procedure TSerialClient.SyncProc();
begin
  if CalledFromThread then Exit;
  //if s:='' then Exit;
  CalledFromThread:=True;
  if s<>'' then
  begin
    if Assigned(self.FOnIncomingMsgEvent) then FOnIncomingMsgEvent(self, s);
    s:='';
  end;
  if sLastError<>'' then
  begin
    if Assigned(self.FOnErrorEvent) then FOnErrorEvent(self, sLastError);
    self.Terminate();
  end;
  CalledFromThread:=False;
end;

procedure TSerialClient.SyncProcOnConnect();
begin
  if CalledFromThread then Exit;
  CalledFromThread:=True;
  if Assigned(self.FOnConnectEvent) then self.FOnConnectEvent(self);
  CalledFromThread:=False;
end;

procedure TSerialClient.Execute();
begin
  sLastError:='';

  try
    Serial:=TBlockSerial.Create();
    Serial.DeadlockTimeout:=10000;
    Serial.Connect(sPort);
    Sleep(1);
    if Serial.LastError=0 then
    begin
      Serial.Config(iBaudRate, DataBits, Parity, StopBits, SoftFlow, HardFlow);
      Sleep(1);
    end;

    if Serial.LastError<>0 then
    begin
      sLastError:=Serial.LastErrorDesc;
      Synchronize(SyncProc);
    end
    else
    begin
      Synchronize(SyncProcOnConnect);
    end;

    while not Terminated do
    begin
      s:=Serial.RecvPacket(100);
      sLastError:='';
      if (Serial.LastError<>0) and (Serial.LastError<>ErrTimeout) then sLastError:=IntToStr(Serial.LastError)+'='+Serial.LastErrorDesc;
      if (Length(s)>0) or (Length(sLastError)>0) then Synchronize(SyncProc);

      Sleep(1);

      if sToSend<>'' then
      begin
        if Serial.CanWrite(10) then
        begin
          Serial.SendString(sToSend);
          if (Serial.LastError<>0) and (Serial.LastError<>ErrTimeout) then
          begin
            sLastError:=Serial.LastErrorDesc;
            Synchronize(SyncProc);
          end
          else sToSend:='';
        end;
      end;


    end;
  finally
    FreeAndNil(Serial);
  end;
end;

function TSerialClient.SendString(s: string): Boolean;
begin
  Result:=False;
  if not Assigned(Self.Serial) then Exit;
  if SafeMode then self.sToSend:=s
  else
  begin
    if Serial.CanWrite(1000) then Serial.SendString(s);
    if (Serial.LastError<>0) and (Serial.LastError<>ErrTimeout) then
    begin
      sLastError:=Serial.LastErrorDesc;
      Synchronize(SyncProc);
      Exit;
    end;
  end;
  Result:=True;
end;

procedure TSerialClient.SendStream(st: TStream; Dest: string);
begin
  if not Assigned(Self.Serial) then Exit;
  Serial.SendStreamRaw(st);
  if Serial.LastError<>0 then
  begin
    sLastError:=Serial.LastErrorDesc;
    Synchronize(SyncProc);
  end;
end;


{ TDataPortSerial }

constructor TDataPortSerial.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  self.lock:=TMultiReadExclusiveWriteSynchronizer.Create();
  FPort:='COM1';
  FBaudRate:=9600;
  FMinDataBytes:=1;
  FActive:=False;
  //Self.slReadData:=TStringList.Create();
  Self.sReadData:='';
  Self.SerialClient:=nil;
end;

function GetFirstWord(var s: string; delimiter: string = ' '): string;
var
  i: integer;
begin
  Result:='';
  i:=Pos(delimiter, s);
  if i>0 then
  begin
    Result:=Copy(s, 1, i-1);
    s:=Copy(s, i+1, maxint);
  end
  else
  begin
    Result:=s;
    s:='';
  end;
end;

procedure TDataPortSerial.Open(InitStr: string = '');
var
  s, ss: string;
begin
  ss:=InitStr;
  if ss='' then ss:=FInitStr else FInitStr:=ss;
  if Assigned(self.SerialClient) then
  begin
    self.SerialClient.FreeOnTerminate:=True;
    self.SerialClient.Terminate;
    //FreeAndNil(self.SerialClient);
  end;
  Self.SerialClient:=TSerialClient.Create(true);
  Self.SerialClient.OnIncomingMsgEvent:=self.IncomingMsgHandler;
  Self.SerialClient.OnErrorEvent:=self.ErrorEventHandler;
  Self.SerialClient.OnConnectEvent:=self.ConnectHandler;
  Self.SerialClient.SafeMode:=True;

  // Port
  s:=GetFirstWord(ss, ',');
  if s<>'' then Port:=s;
  Self.SerialClient.sPort:=Port;

  // BaudRate
  s:=GetFirstWord(ss, ',');
  Self.SerialClient.iBaudRate:=StrToIntDef(s, FBaudRate);

  // DataBits
  s:=GetFirstWord(ss, ',');
  Self.SerialClient.DataBits:=StrToIntDef(s, 8);

  // Parity
  s:=GetFirstWord(ss, ',');
  if s='' then s:='N';
  Self.SerialClient.Parity:=s[1];

  // StopBits
  s:=GetFirstWord(ss, ',');
  if s='1' then
    Self.SerialClient.StopBits:=SB1
  else if s='1.5' then
    Self.SerialClient.StopBits:=SB1andHalf
  else if s='2' then
    Self.SerialClient.StopBits:=SB2
  else
    Self.SerialClient.StopBits:=SB1;

  // SoftFlow
  s:=GetFirstWord(ss, ',');
  if s='1' then
    Self.SerialClient.SoftFlow:=True
  else
   Self.SerialClient.SoftFlow:=False;

  // HardFlow
  s:=GetFirstWord(ss, ',');
  if s='1' then
    Self.SerialClient.HardFlow:=True
  else
    Self.SerialClient.HardFlow:=False;

  // Check serial port
  //if Pos(Port, synaser.GetSerialPortNames())=0 then Exit;
  {$IFDEF UNIX}
  // detect lock file name
  if Pos('tty', Port)>0 then
  begin
    s:='/var/lock/LCK..'+Copy(Port, Pos('tty', Port), maxint);
    if FileExists(s) then
    begin
      // try to remove lock file (if any)
      DeleteFile(s);
    end;
  end;
  {$ENDIF}

  Self.SerialClient.Start();

  // don't inherits Open() - OnOpen event will be after successfull connection
end;

procedure TDataPortSerial.Close();
begin
  if Assigned(self.SerialClient) then
  begin
    if self.SerialClient.CalledFromThread then self.SerialClient.Terminate()
    else FreeAndNil(self.SerialClient);
  end;
  inherited Close();
end;

destructor TDataPortSerial.Destroy();
begin
  if Assigned(self.SerialClient) then
  begin
    self.SerialClient.OnIncomingMsgEvent:=nil;
    self.SerialClient.OnErrorEvent:=nil;
    self.SerialClient.OnConnectEvent:=nil;
    FreeAndNil(self.SerialClient);
  end;
  //FreeAndNil(self.slReadData);
  FreeAndNil(self.lock);
  inherited Destroy();
end;

procedure TDataPortSerial.IncomingMsgHandler(Sender: TObject; AMsg: string);
begin
  if AMsg<>'' then
  begin
    if lock.BeginWrite then
    begin
      //slReadData.Add(AMsg);
      sReadData:=sReadData+AMsg;
      lock.EndWrite;

      if Assigned(FOnDataAppear) then FOnDataAppear(self);
    end;

  end;
end;

procedure TDataPortSerial.ErrorEventHandler(Sender: TObject; AMsg: string);
begin
  if Assigned(Self.FOnError) then Self.FOnError(Self, AMsg);
  self.FActive:=False;
end;

{
function TDataPortIP.Peek(size: Integer = MaxInt): AnsiString;
var
  i, num, remain: Integer;
begin
  Result:='';
  remain:=size;
  lock.BeginRead();
  for i:=0 to slReadData.Count do
  begin
    num:=Length(slReadData[i]);
    if num>remain then num:=remain;
    Result:=Result+Copy(slReadData[i], 1, num);
    remain:=remain-num;
    if remain<=0 then Break;
  end;
  lock.EndRead();
end;
}

function TDataPortSerial.Peek(size: Integer = MaxInt): AnsiString;
begin
  lock.BeginRead();
  Result:=Copy(sReadData, 1, size);
  lock.EndRead();
end;

function TDataPortSerial.PeekSize(): Cardinal;
//var i: Integer;
begin
  //Result:=0;
  lock.BeginRead();
  //// Length of all strings
  //for i:=0 to slReadData.Count-1 do Result:=Result+Cardinal(Length(slReadData[i]));
  Result:=Cardinal(Length(sReadData));
  lock.EndRead();
end;

function TDataPortSerial.GetSerialPortNames: string;
begin
  Result:=synaser.GetSerialPortNames();
end;

{
function TDataPortIP.Pull(size: Integer = MaxInt): AnsiString;
var
  num, len, remain: Integer;
begin
  Result:='';
  remain:=size;
  if not lock.BeginWrite() then Exit;
  while slReadData.Count>0 do
  begin
    // we read every string to exclude line delimiters
    len:=Length(slReadData[0]);
    num:=len;
    if num>remain then num:=remain;
    Result:=Result+Copy(slReadData[0], 1, num);
    remain:=remain-num;
    if num>=len then slReadData.Delete(0)
    else
    begin
      Delete(slReadData[0], 1, num);
      Break;
    end;
    if remain<=0 then Break;
  end;
  lock.EndWrite();
end;
}

function TDataPortSerial.Pull(size: Integer = MaxInt): AnsiString;
begin
  Result:='';
  if not lock.BeginWrite() then Exit;
  Result:=Copy(sReadData, 1, size);
  Delete(sReadData, 1, size);
  //sReadData:='';
  lock.EndWrite();
end;

function TDataPortSerial.Push(sMsg: AnsiString): Boolean;
begin
  Result:=False;
  if not Assigned(self.SerialClient) then Exit;
  if lock.BeginWrite() then
  begin
    self.SerialClient.SendString(sMsg);
    lock.EndWrite();
  end;
end;

procedure TDataPortSerial.ConnectHandler(Sender: TObject);
begin
  self.FActive:=True;
  if Assigned(FOnConnect) then FOnConnect(Self);
  if Assigned(OnOpen) then OnOpen(Self);
end;

end.