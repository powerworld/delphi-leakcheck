{***************************************************************************}
{                                                                           }
{           LeakCheck for Delphi                                            }
{                                                                           }
{           Copyright (c) 2015 Honza Rames                                  }
{                                                                           }
{           https://bitbucket.org/shadow_cs/delphi-leakcheck                }
{                                                                           }
{***************************************************************************}
{                                                                           }
{  Licensed under the Apache License, Version 2.0 (the "License");          }
{  you may not use this file except in compliance with the License.         }
{  You may obtain a copy of the License at                                  }
{                                                                           }
{      http://www.apache.org/licenses/LICENSE-2.0                           }
{                                                                           }
{  Unless required by applicable law or agreed to in writing, software      }
{  distributed under the License is distributed on an "AS IS" BASIS,        }
{  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. }
{  See the License for the specific language governing permissions and      }
{  limitations under the License.                                           }
{                                                                           }
{***************************************************************************}

unit LeakCheck.Cycle;

interface

uses
  SysUtils,
  TypInfo,
  Generics.Collections,
  Rtti;

{$SCOPEDENUMS ON}

type

  /// <summary>
  ///   Specifies the output format of <c>TCycle.ToString</c>.
  /// </summary>
  TCycleFormat = (
    /// <summary>
    ///   Generate Graphviz compatible format
    /// </summary>
    Graphviz,
    /// <summary>
    ///   Append addresses of to the output (useful to distinguish different
    ///   instances with the same type name, recommended if Graphviz is
    ///   enabled).
    /// </summary>
    WithAddress);
  TCycle = record
  public type
    TItem = record
      TypeInfo: PTypeInfo;
      Address: Pointer;
    end;

    /// <seealso cref="">
    ///   <see cref="LeakCheck.Cycle|TCycleFormat" />
    /// </seealso>
    TCycleFormats = set of TCycleFormat;
  private
    FData: TArray<TItem>;
    function GetLength: Integer; inline;
    function GetItem(Index: Integer): TItem; inline;
  public
    /// <summary>
    ///   Converts cycle to textual representation. See <see cref="LeakCheck.Cycle|TCycleFormat" />
    ///   .
    /// </summary>
    function ToString(Format: TCycleFormats = []): string;

    property Items[Index: Integer]: TItem read GetItem; default;
    property Length: Integer read GetLength;
  end;
  TCycles = TArray<TCycle>;

  TScanner = class
  strict protected type
    TSeenInstancesSet = TDictionary<Pointer, Boolean>;
    TCurrentPathStack = TStack<TCycle.TItem>;
    {$INCLUDE LeakCheck.Types.inc}
  strict protected
    FCurrentPath: TCurrentPathStack;
    FInstance: Pointer;
    FResult: TCycles;
    FSeenInstances: TSeenInstancesSet;

    procedure CycleFound;
    procedure ScanArray(P: Pointer; TypeInfo: PTypeInfo; ElemCount: NativeUInt);
    procedure ScanClass(const Instance: TObject);
    procedure ScanClassInternal(const Instance: TObject);
    procedure ScanDynArray(var A: Pointer; TypeInfo: Pointer);
    procedure ScanInterface(const Instance: IInterface);
    procedure ScanRecord(P: Pointer; TypeInfo: PTypeInfo);
    procedure ScanTValue(const Value: PValue);
    procedure TypeEnd; inline;
    procedure TypeStart(Address: Pointer; TypeInfo: PTypeInfo); inline;
  protected
    constructor Create(AInstance: Pointer);
    function Scan: TCycles;
  public
    destructor Destroy; override;
  end;

/// <summary>
///   Scans for reference cycles in managed fields. It can ONLY scan inside
///   managed fields so it can scan for interface cycles on any platform but
///   can only find object cycles on NextGen generated code. On non-NextGen it
///   cannot find cycles produced by referencing interface from owned object.
///   Main goal of this function is to detect cycles on NextGen in places where
///   you might have forgot to put <c>Weak</c> attribute.
/// </summary>
function ScanForCycles(const Instance: TObject): TCycles;

implementation

{$IF CompilerVersion >= 25} // >= XE4
  {$LEGACYIFEND ON}
{$IFEND}
{$IF CompilerVersion >= 24} // >= XE3
  {$DEFINE XE3_UP}
{$IFEND}

function ScanForCycles(const Instance: TObject): TCycles;
var
  Scanner: TScanner;
begin
  Scanner := TScanner.Create(Instance);
  try
    Result := Scanner.Scan;
  finally
    Scanner.Free;
  end;
end;

{$REGION 'TScanner'}

constructor TScanner.Create(AInstance: Pointer);
begin
  inherited Create;
  FInstance := AInstance;
  FCurrentPath := TCurrentPathStack.Create;
  FSeenInstances := TSeenInstancesSet.Create;
end;

procedure TScanner.CycleFound;
var
  Len: Integer;
begin
  Len := Length(FResult);
  SetLength(FResult, Len + 1);
  FResult[Len].FData := FCurrentPath.ToArray;
end;

destructor TScanner.Destroy;
begin
  FSeenInstances.Free;
  FCurrentPath.Free;
  inherited;
end;

function TScanner.Scan: TCycles;
begin
  try
    ScanClassInternal(FInstance);
    Result := FResult;
  finally
    FResult := Default(TCycles);
    FSeenInstances.Clear;
  end;
end;

procedure TScanner.ScanArray(P: Pointer; TypeInfo: PTypeInfo;
  ElemCount: NativeUInt);
var
  FT: PFieldTable;
begin
  TypeStart(P, TypeInfo);
  if ElemCount > 0 then
  begin
    case TypeInfo^.Kind of
      // TODO: Variants
      tkClass:
        while ElemCount > 0 do
        begin
          ScanClass(TObject(P^));
          Inc(PByte(P), SizeOf(Pointer));
          Dec(ElemCount);
        end;
      tkInterface:
        while ElemCount > 0 do
        begin
          ScanInterface(IInterface(P^));
          Inc(PByte(P), SizeOf(Pointer));
          Dec(ElemCount);
        end;
      tkDynArray:
        while ElemCount > 0 do
        begin
          // See System._FinalizeArray for why we call it like that
          ScanDynArray(PPointer(P)^, typeInfo);
          Inc(PByte(P), SizeOf(Pointer));
          Dec(ElemCount);
        end;
      tkArray:
        begin
          FT := PFieldTable(PByte(typeInfo) + Byte(PTypeInfo(typeInfo).Name{$IFNDEF NEXTGEN}[0]{$ENDIF}));
          while ElemCount > 0 do
          begin
            ScanArray(P, FT.Fields[0].TypeInfo^, FT.Count);
            Inc(PByte(P), FT.Size);
            Dec(ElemCount);
          end;
        end;
      tkRecord:
        begin
          FT := PFieldTable(PByte(TypeInfo) + Byte(PTypeInfo(TypeInfo).Name{$IFNDEF NEXTGEN}[0]{$ENDIF}));
          while ElemCount > 0 do
          begin
            if TypeInfo = System.TypeInfo(TValue) then
              ScanTValue(PValue(P))
            else
              ScanRecord(P, TypeInfo);
            Inc(PByte(P), FT.Size);
            Dec(ElemCount);
          end;
        end;
    end;
  end;
  TypeEnd;
end;

procedure TScanner.ScanClass(const Instance: TObject);
begin
  if not Assigned(Instance) then
    // NOP
  else if Instance = FInstance then
    CycleFound
  else if not FSeenInstances.ContainsKey(Instance) then
  begin
    FSeenInstances.Add(Instance, True);
    ScanClassInternal(Instance);
  end;
end;

procedure TScanner.ScanClassInternal(const Instance: TObject);
var
  InitTable: PTypeInfo;
  LClassType: TClass;
begin
  TypeStart(Instance, Instance.ClassInfo);
  LClassType := Instance.ClassType;
  repeat
    InitTable := PPointer(PByte(LClassType) + vmtInitTable)^;
    if Assigned(InitTable) then
      ScanRecord(Instance, InitTable);
    LClassType := LClassType.ClassParent;
  until LClassType = nil;
  TypeEnd;
end;

procedure TScanner.ScanDynArray(var A: Pointer; TypeInfo: Pointer);
var
  P: Pointer;
  Rec: PDynArrayRec;
begin
  // Do not push another type, we already did in previous call

  P := A;
  if P <> nil then
  begin
    Rec := PDynArrayRec(PByte(P) - SizeOf(TDynArrayRec));

    // If refcount is negative the array is released
    if (Rec^.RefCnt > 0) and (Rec^.Length <> 0) then
    begin
      // Fetch the type descriptor of the elements
      Inc(PByte(TypeInfo), Byte(PDynArrayTypeInfo(TypeInfo)^.name));
      if PDynArrayTypeInfo(TypeInfo)^.elType <> nil then
      begin
        TypeInfo := PDynArrayTypeInfo(TypeInfo)^.elType^;
        ScanArray(P, TypeInfo, Rec^.Length);
      end;
    end;
  end;
end;

procedure TScanner.ScanInterface(const Instance: IInterface);
var
  inst: Pointer;
begin
  // Do not push another type, we cannot be sure of the type information
  // Cast should return nil not raise an exception if interface is not class
  try
    inst := TObject(Instance);
  except
    // If there are dangling references that were previsouly released they may
    // not be accessible
    // TODO: We could ask the memory manager whether the Instance address is readable (ie. is allocated/leaks)
    on EAccessViolation do
      Exit;
    else raise;
  end;
  ScanClass(inst);
end;

procedure TScanner.ScanRecord(P: Pointer; TypeInfo: PTypeInfo);
var
  I: Cardinal;
  FT: PFieldTable;
begin
  // Do not push another type, ScanArray will do it later
  FT := PFieldTable(PByte(TypeInfo) + Byte(PTypeInfo(TypeInfo).Name{$IFNDEF NEXTGEN}[0]{$ENDIF}));
  if FT.Count > 0 then
  begin
    for I := 0 to FT.Count - 1 do
    begin
{$IFDEF WEAKREF}
      if FT.Fields[I].TypeInfo = nil then
        Exit; // Weakref separator
        // TODO: Wekrefs???
{$ENDIF}
      ScanArray(Pointer(PByte(P) + NativeInt(FT.Fields[I].Offset)),
        FT.Fields[I].TypeInfo^, 1);
    end;
  end;
end;

procedure TScanner.ScanTValue(const Value: PValue);
var
  ValueData: PValueData absolute Value;
begin
  // Do not push another type, ScanArray already did
  if (not Value^.IsEmpty) and Assigned(ValueData^.FValueData) then
  begin
    // Performance optimization, keep only supported types here to avoid adding
    // strings
    case Value^.Kind of
      // TODO: Variants
      tkClass,
      tkInterface,
      tkDynArray,
      tkArray,
      tkRecord:
        // If TValue contains the instance directly it will duplicate it
        // but it is totally OK, otherwise some other type holding the instance
        // might get hidden. The type is the actual type TValue holds.
        ScanArray(Value^.GetReferenceToRawData, Value.TypeInfo, 1);
    end;
  end;
end;

procedure TScanner.TypeEnd;
begin
  FCurrentPath.Pop;
end;

procedure TScanner.TypeStart(Address: Pointer; TypeInfo: PTypeInfo);
var
  Item: TCycle.TItem;
begin
  Item.Address := Address;
  Item.TypeInfo := TypeInfo;
  FCurrentPath.Push(Item);
end;

{$ENDREGION}

{$REGION 'TCycle'}

function TCycle.GetItem(Index: Integer): TCycle.TItem;
begin
  Result := FData[Index];
end;

function TCycle.GetLength: Integer;
begin
  Result := System.Length(FData);
end;

function TCycle.ToString(Format: TCycleFormats = []): string;

  function ItemToStr(const Item: TCycle.TItem; Format: TCycleFormats): string; inline;
  begin
{$IFDEF XE3_UP}
    Result := Item.TypeInfo^.NameFld.ToString;
{$ELSE}
    Result := string(Item.TypeInfo^.Name);
{$ENDIF}
    if TCycleFormat.WithAddress in Format then
      Result := Result + SysUtils.Format(' (%p)', [Item.Address]);

    if TCycleFormat.Graphviz in Format then
      Result := '"' + Result + '"';
  end;

const
  Separator = ' -> ';
var
  Item: TCycle.TItem;
begin
  Result := '';
  if Length = 0 then
    Exit;

  for Item in FData do
  begin
    if Byte(Item.TypeInfo^.Name{$IFNDEF NEXTGEN}[0]{$ENDIF}) > 0 then
    begin
      if Result <> '' then
        Result := Result + Separator;
      Result := Result + ItemToStr(Item, Format);
    end;
  end;
  // Complete the circle
  Result := Result + Separator + ItemToStr(FData[0], Format);
  if TCycleFormat.Graphviz in Format then
    Result := Result + ';';
end;

{$ENDREGION}

end.
