unit COMUnit;

{ First release: 28 Feb 96 }
{ Last changes:  21 May 96 }

{ v006 }

{ COMUnit - Copyright (c) by Christian Muehlhaeuser and Michael Maluck }
{ All rights reserved }
{ If you use this, please be so kind and send an email to muesli AT gmail DOT com }

interface

uses
  Dos,Crt;

const
  BufSize=4096;
  COMSoftFlow=1;
  COMHardFlow=2;
  COMUseFIFO=4;
  COMUseFossil=8;
  COMDetect=$80;

type
  TCharBuf=array[0..BufSize] of Char;

  PCOM=^TCOM;
  TCOM=object
    IOBase: Integer;
    IRQ: Byte;
    DataBits,Parity,StopBits: Byte;
    SaveIOInt: Pointer;
    SaveIER, SaveIMR: Byte;
    Buffer: ^TCharBuf;
    BufHead,BufTail,CharsInBuf: Word;
    BufOverflow,SoftFlow: Boolean;
    COMAttr,IOPort: Byte;
    constructor Init(AIOPort: Byte; ABaud: LongInt; ADataBits, AParity,
                  AStopBits, ACOMAttr: Byte);
    destructor Done;
    procedure COMIRQ;
    procedure EnableInts;
    procedure DisableInts;
    function CarrierDetect: Boolean;
    procedure SendChar(C: Char);
    procedure SendByte(B: Byte);
    procedure SendStr(S: String);
    function ByteAvail: Boolean;
    function ReadChar: Char;
    function ReadByte: Byte;
    function ReadString: String;
    function PeekChar: Char;
    procedure FlushInput;
    procedure SetDTR(DTROn: Boolean);
    procedure SendBreak;
    function HangUp: Boolean;
    procedure GetCOMAttr(var ACOMAttr: Byte);
  end;

var
  COMAcc: array[1..4] of PCOM;

implementation

const
  CSerIOBase: array[1..4] of Word=($3F8,$2F8,$3E8,$2E8);
     CSerIRQ: array[1..4] of Byte=(4,3,4,3);

  { Relative Indizes zum seriellen IO-Port }
  THR=0;      { transmitter holding register }
  DLL=0;      { divisor latch low byte }
  RBR=0;      { receiver buffer register }
  DLH=1;      { divisor latch high byte }
  IER=1;      { interrupt enable register }
  FCR=2;      { fifo control register }
  IIR=2;      { interrupt identification register }
  LCR=3;      { line control register }
  MCR=4;      { modem control register }
  LSR=5;      { line status register }
  MSR=6;      { modem status register }

  { Fuer Bitzugriffe auf die Register }
  CTS=$10;    { clear to send }
  THRE=$20;   { transmitter holding register empty }
  BRKSGN=$40; { break signal }
  DLAB=$80;   { divisor latch access bit }
  DR=1;       { data ready }
  FQE=$40;    { fifo queues enabled }

  { Sonstige Konstanten }
  PIC=$20; { programmable interrupt controller }
  IMR=$21; { master interrupt mask register }

    CR=#13;
  CRLF=#13#10;

var
  Regs: Registers;

{ COM-Port Initialisierung
  ************************
  Uebergabe:
     APort = COM-Port der anzusprechen ist (Bsp: COM2 = 2)
     ABaud = Baud-Rate mit der er initialisiert werden soll (Bsp: 19200)
     ADataBits = 5-8 DataBits (0h,1h,2h,3h)
     AParity = None,Odd,Even (0h,8h,18h)         Standard: 3h,0h,0h = 8N1
     AStopBits = 2,1 (4h,0h)
     Attr = COMSoftFlow,COMHardFlow,COMUseFIFO,COMUseFossil,COMDetect
            und alle Kombinationen
  Rueckgabe: Nichts }

constructor TCOM.Init;
     var
      i,dummy: byte;
     begin
       IOPort:=AIOPort;
       BufHead:=0;
       BufTail:=0;
       CharsInBuf:=0;
       BufOverflow:=False;
       COMAttr:=ACOMAttr;
       New(Buffer);

       if COMAttr and COMDetect>0 then begin
         COMAttr:=COMAttr and (not COMDetect);
         GetCOMAttr(COMAttr);
       end;

       if COMAttr and COMUseFossil>0 then begin
         Regs.AH:=4;
         Regs.DX:=IOPort-1;
         Intr($14,Regs);
         if Regs.AX<>$1954 then
           COMAttr:=COMAttr and (not COMUseFossil)
         else begin
           case Word(ABaud) of
             300: Regs.AL:=$40;
             600: Regs.AL:=$60;
             1200: Regs.AL:=$80;
             2400: Regs.AL:=$A0;
             4800: Regs.AL:=$C0;
             9600: Regs.AL:=$E0;
             19200: Regs.AL:=0;
             else Regs.AL:=$20;
           end;
           Regs.AL:=Regs.AL or ADataBits or AParity or AStopBits;
           Intr($14,Regs);
           Regs.AH:=3;
           Intr($14,Regs);
         end;
       end;
       if COMAttr and COMUseFossil=0 then begin
         IRQ:=CSerIRQ[IOPort];
         IOBase:=CSerIOBase[IOPort];
         DataBits:=ADataBits;
         Parity:=AParity;
         StopBits:=AStopBits;
         COMAttr:=ACOMAttr;

         if COMAttr and COMUseFIFO>0 then begin
           Port[IOBase+FCR]:=$C7; { activate and clear send&receive buffer,
                                    14 byte trigger level }
           if Port[IOBase+IIR] and FQE=0 then begin
             Port[IOBase+FCR]:=0;
             COMAttr:=COMAttr and (not COMUseFIFO);
           end;
         end;

         GetIntVec(IRQ+8,SaveIOInt);
         SaveIER:=Port[IOBase+IER];
         Port[IOBase+LCR]:=Port[IOBase+LCR] or DLAB;
         Port[IOBase+DLL]:=Lo(115200 div ABaud);
         Port[IOBase+DLH]:=Hi(115200 div ABaud);
         Port[IOBase+LCR]:=ADataBits or AParity or AStopBits;
         Port[IOBase+IER]:=$09;  { enable receive data+modem status ints }
         Port[IOBase+MCR]:=$0B;  { turn on OUT2, RTS, DTR }
         SetIntVec(IRQ+8,ptr(seg(TCOM.COMIRQ),
           Ofs(TCOM.COMIRQ)+(AIOPort-1)*5+11));
         case IOPort of
           1: Port[IMR]:=Port[IMR] and $EF;
           2: Port[IMR]:=Port[IMR] and $F7;
           3: Port[IMR]:=Port[IMR] and $EF;
           4: Port[IMR]:=Port[IMR] and $F7;
         end;
         for I:=0 to 5 do Dummy:=Port[IOBase+I];
         Port[PIC]:=$20;
       end;
     end;

{ Ruecksetzen aller veraenderten Register und Interruptvektoren
  *************************************************************
    Uebergabe: Nichts
    Ausgabe: Nichts }

destructor TCOM.Done;
     begin
       if COMAttr and COMUseFossil>0 then begin
         SetDTR(False);
         Regs.AH:=5;
         Regs.DX:=IOPort-1;
         Intr($14,Regs);
       end else begin
         Port[IOBase+IER]:=SaveIER;
         Port[IOBase+MCR]:=0;
         Port[IOBase+IMR]:=SaveIMR;
         SetIntVec(IRQ+8,SaveIOInt);
         Port[PIC]:=$20;
       end;
       DisPose(Buffer);
     end;

{ Neue Interrupt Service-Routine
  ******************************
    KEIN DIREKTER AUFRUF !!

}

procedure TCOM.COMIRQ; assembler;
     const
       Xon=#17;
       Xoff=#19;
       CIOBase=0;            { Offsets der Variablen relativ zum Objekt }
       CBuffer=12;
       CBufHead=16;
       CCharsInBuf=20;
       CBufOverflow=22;
       CSoftFlow=23;
       CCOMAttr=24;
     asm
@IOPort:
       db 0
       cli                   { Einsprung fuer COM1 }
       mov  byte ptr cs:[@IOPort],0
       jmp  @Start

       cli                   { Einsprung fuer COM2 }
       mov  byte ptr cs:[@IOPort],1
       jmp  @Start

       cli                   { Einsprung fuer COM3 }
       mov  byte ptr cs:[@IOPort],2
       jmp  @Start

       cli                   { Einsprung fuer COM4 }
       mov  byte ptr cs:[@IOPort],3
       jmp  @Start

@Start:push ax
       push bx
       push cx
       push dx
       push si
       push di
       push ds
       push es
       mov  bh,0
       mov  bl,byte ptr cs:[@IOPort]
       mov  dx,seg COMAcc
       mov  ds,dx
       mov  cl,2
       shl  bx,cl
       les  si,dword ptr COMAcc[bx]
@NextChar:
       cmp  word ptr es:[si+CCharsInBuf],BufSize
       jnb  @BufFull
       mov  dx,es:[si+CIOBase]
       mov  bl,es:[si+CCOMAttr]
       test bl,COMUseFIFO
       jz   @NoFIFO1
       push dx
       add  dx,IIR
       in   al,dx
       pop  dx
       test al,4        { received data in fifo queue }
       jz   @NoData
@NoFIFO1:
       in   al,dx
       test bl,COMSoftFlow
       jz   @NoSoftFlow
       cmp  al,XOn
       jnz  @NoXOn
       mov  byte ptr es:[si+CSoftFlow],True
       jmp  @Ok
@NoXOn:cmp  al,XOff
       jnz  @NoXOff
       mov  byte ptr es:[si+CSoftFlow],False
       jmp  @Ok
@NoXOff:
       mov  byte ptr es:[si+CSoftFlow],False
@NoSoftFlow:
       mov  di,es:[si+CBuffer]
       mov  bx,es:[si+CBuffer+2]
       mov  cx,es:[si+CBufHead]
       add  di,cx
       adc  bx,0
       push es
       mov  es,bx
       stosb
       pop  es
       cmp  cx,BufSize
       jb   @NotEnd
       xor  cx,cx
       jmp  @StoreHead
@NotEnd:
       inc  cx
@StoreHead:
       mov  word ptr es:[si+CBufHead],cx
       inc  word ptr es:[si+CCharsInBuf]
       jmp  @Ok
@BufFull:
       mov  byte ptr es:[si+CBufOverflow],True
       jmp  @NoData
@Ok:   test bl,COMUseFIFO
       jz   @NoFIFO2
       push dx
       add  dx,LSR
       in   al,dx
       pop  dx
       test al,1
       jnz  @NextChar
@NoFIFO2:
@NoData:
       mov  al,$20
       out  PIC,al
       pop  es
       pop  ds
       pop  di
       pop  si
       pop  dx
       pop  cx
       pop  bx
       pop  ax
       sti
       iret
     end;

procedure TCOM.EnableInts; assembler; asm sti end;
procedure TCOM.DisableInts; assembler; asm cli end;

{ Ueberpruefe ob ein stabiles Traegersignal anliegt
  *************************************************
  Uebergabe: Nichts
  Ausgbabe: True falls, wenn stabiles Traegersignal anliegt, sonst False }

function TCOM.CarrierDetect;
     var
       w: word;
       b: boolean;
     begin
       if COMAttr and COMUseFossil>0 then begin
         Regs.AH:=3;
         Regs.DX:=IOPort-1;
         Intr($14,Regs);
         CarrierDetect:=Regs.AL and $80>0;
       end else begin
         w:=0;
         b:=true;
         while (w<500) and b do begin
           Inc(w);
           b:=(Port[IOBase+MSR] and 128)=0; { true=no carrier ! }
         end;
         CarrierDetect:=not b;
       end;
     end;

{ Char an den initialisierten COM-Port schicken
  *********************************************
  Uebergabe:
     C = zu sendender Buchstabe
  Ausgabe: Nichts }

procedure TCOM.SendChar(C: Char);
     begin
       if COMAttr and COMUseFossil>0 then begin
         Regs.AH:=1;
         Regs.AL:=Ord(C);
         Regs.DX:=IOPort-1;
         Intr($14,Regs);
       end else begin
         while (Port[IOBase+LSR] and $20)=0 do ; {wait for Tx Hold Req Empty}
         if COMAttr and COMHardFlow>0 then
           while (Port[IOBase+MSR] and $10)=0 do ; { wait for CTS }
         if COMAttr and COMSoftFlow>0 then
           while SoftFLow and CarrierDetect do ;
         Port[IOBase+MCR]:=$0B; { turn on OUT2, DTR, RTS }
         DisableInts;
         Port[IOBase+THR]:=Ord(C);
         EnableInts;
       end;
     end;

{ Ein Byte an den initialisierten COM-Port schicken
  *************************************************
  Uebergabe:
     B = zu sendendes Byte
  Ausgbabe: Nichts }

procedure TCOM.SendByte(B: Byte);
     begin
       SendChar(Chr(B));
     end;

{ Einen String an den initialisierten COM-Port schicken
  *****************************************************
  Uebergabe:
     S = zu sendender String
  Ausgbabe: Nichts }

procedure TCOM.SendStr(S: String);
     var
       I: Byte;
     begin
       for I:=1 to Length(S) do SendChar(S[I]);
     end;

{ Ueberpruefen ob Bytes angekommen sind
  *************************************
  Uebergabe: Nichts
  Ausgabe: True falls Daten warten, False wenn nichts eingetroffen ist }

function TCOM.ByteAvail;
     begin
       if COMAttr and COMUseFossil>0 then begin
         Regs.AH:=3;
         Regs.DX:=IOPort-1;
         Intr($14,Regs);
         ByteAvail:=Regs.AH and 1>0;
       end else
         ByteAvail:=CharsInBuf>0;
     end;

{ Char aus dem Puffer lesen
  *************************
  Uebergabe: Nichts
  Ausgabe: Empfangener Buchstabe }

function TCOM.ReadChar;
     begin
       if COMAttr and COMUseFossil>0 then begin
         Regs.AH:=2;
         Regs.DX:=IOPort-1;
         Intr($14,Regs);
         ReadChar:=Chr(Regs.AL);
       end else begin
         repeat until ByteAvail;
         ReadChar:=Buffer^[BufTail];
         Inc(BufTail);
         if BufTail>BufSize then BufTail:=0;
         Dec(CharsInBuf);
       end;
     end;

{ Byte aus dem Puffer lesen
  *************************
  Uebergabe: Nichts
  Ausgbabe: Empfangenes Byte }

function TCOM.ReadByte;
     begin
       ReadByte:=Ord(ReadChar);
     end;

{ String vom initialisierten COM-Port lesen
  *****************************************
  Uebergabe: Nichts
  Ausgbabe: Empfangener String }

function TCOM.ReadString;
     var
       C: Char;
       S: String;
     begin
       S:='';
       repeat
         C:=ReadChar;
         S:=S+C;
       until C=CR;
       Dec(S[0]);
       ReadString:=S;
     end;

{ Char aus dem Puffer (Zeichen bleibt im Puffer!)
  ***********************************************
  Uebergabe: Nichts
  Ausgabe: Empfangener Buchstabe }

function TCOM.PeekChar;
     begin
       repeat until ByteAvail;
       PeekChar:=Buffer^[BufTail];
     end;

{ Lesepuffer loeschen
  *******************
  Uebergabe: Nichts
  Ausgabe: Nichts }

procedure TCOM.FlushInput;
     begin
       if COMAttr and COMUseFossil>0 then begin
         Regs.AH:=$0A;
         Regs.DX:=IOPort-1;
         Intr($14,Regs);
       end else begin
         DisableInts;
         BufTail:=BufHead;
         CharsInBuf:=0;
         EnableInts;
       end;
     end;

{ DTR-Bereitschaft setzen/loeschen
  ********************************
  Uebergabe: True  - Setze DTR
             False - Loesche DTR
  Ausgabe: Nichts }

procedure TCOM.SetDTR;
     begin
       if COMAttr and COMUseFossil>0 then begin
         Regs.AH:=6;
         Regs.DX:=IOPort-1;
         Regs.AL:=Ord(DTROn);
         Intr($14,Regs);
       end else
         Port[IOBase+MCR]:=(Port[IOBase+MCR] and $FE) or Ord(DTROn);
     end;

{ Auflegen
  ********
  Uebergabe: Nichts
  Ausgabe: True - Auflegen war erfolgreich, sonst False }

function TCOM.HangUp;
     var
       W: Word;
     begin
       if CarrierDetect then begin
         W:=0;
         SetDTR(False);
         repeat
           Delay(1);
           Inc(W);
         until (W=1000) or not CarrierDetect;
         SetDTR(True);
         if CarrierDetect then SendStr('+++ATH0'#13);
       end;
       HangUp:=NOT CarrierDetect;
     end;

{ Break-Signal ans Modem schicken
  *******************************
  Uebergabe: Nichts
  Ausgabe: Nichts }

procedure TCOM.SendBreak;
     var
       CurTicks: LongInt;
     begin
       if COMAttr and COMUseFossil>0 then begin
         Regs.AX:=$1A01;
         Regs.DX:=IOPort-1;
         Intr($14,Regs);
       end else
         Port[IOBase+LCR]:=Port[IOBase+LCR] or BRKSGN;
       CurTicks:=MemL[$40:$6C];
       repeat until CurTicks<>MemL[$40:$6C];
       if COMAttr and COMUseFossil>0 then begin
         Regs.AX:=$1A00;
         Regs.DX:=IOPort-1;
         Intr($14,Regs);
       end else
         Port[IOBase+LCR]:=Port[IOBase+LCR] or BRKSGN;
     end;

procedure TCOM.GetCOMAttr;
     var
       IIR1,IIR2: Byte;
     begin
       IIR1:=Port[IOBase+IIR];
       Port[IOBase+FCR]:=1;
       IIR2:=Port[IOBase+IIR];
       if IIR1 and $80=0 then Port[IOBase+IIR]:=0;
       if IIR2 and $C0>0 then ACOMAttr:=ACOMAttr or COMUseFIFO;
       Regs.AH:=4;
       Regs.DX:=IOPort-1;
       Intr($14,Regs);
       if Regs.AX<>$1954 then ACOMAttr:=ACOMAttr and not COMUseFossil;
     end;

begin
end.
