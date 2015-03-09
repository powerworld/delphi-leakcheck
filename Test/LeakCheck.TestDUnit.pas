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

unit LeakCheck.TestDUnit;

interface

uses
  TestFramework;

type
  TTestLeaks = class(TTestCase)
  published
    procedure TestNoLeaks;
    procedure TestWithLeaks;
  end;

  TTestSetup = class(TTestCase)
  protected
    FObj: Pointer;
    procedure SetUp; override;
  published
    procedure TestReleased;
    procedure TestNotReleased;
  end;

  TTestTeardown = class(TTestCase)
  protected
    FObj: Pointer;
    procedure TearDown; override;
  published
    procedure TestReleased;
  end;

  TTestTeardownThatLeaks = class(TTestCase)
  protected
    procedure TearDown; override;
  published
    procedure TestNotReleased;
  end;

implementation

{ TTestLeaks }

procedure TTestLeaks.TestNoLeaks;
begin
  Check(True);
end;

procedure TTestLeaks.TestWithLeaks;
var
  O: Pointer;
begin
{$IFDEF AUTOREFCOUNT}
  O := nil;
{$ENDIF}
  TObject(O) := TObject.Create;
  Check(True);
end;

{ TTestSetup }

procedure TTestSetup.SetUp;
begin
  inherited;
  TObject(FObj) := TObject.Create;
end;

procedure TTestSetup.TestNotReleased;
begin
  Check(True);
end;

procedure TTestSetup.TestReleased;
begin
  TObject(FObj).Free;
  Check(True);
end;

{ TTestTeardown }

procedure TTestTeardown.TearDown;
begin
  inherited;
  TObject(FObj).Free;
end;

procedure TTestTeardown.TestReleased;
begin
  TObject(FObj) := TObject.Create;
  Check(True);
end;

{ TTestTeardownThatLeaks }

procedure TTestTeardownThatLeaks.TearDown;
var
  O: Pointer;
begin
  inherited;
{$IFDEF AUTOREFCOUNT}
  O := nil;
{$ENDIF}
  TObject(O) := TObject.Create;
end;

procedure TTestTeardownThatLeaks.TestNotReleased;
begin
  Check(True);
end;

initialization
  RegisterTests([
    TTestLeaks.Suite,
    TTestSetup.Suite,
    TTestTeardown.Suite,
    TTestTeardownThatLeaks.Suite
  ]);

end.