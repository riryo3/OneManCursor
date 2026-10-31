@echo off
rem Build with the C# compiler that ships with Windows (no extra install needed)
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
if not exist "%CSC%" (
  echo csc.exe not found. .NET Framework is required.
  pause
  exit /b 1
)
"%CSC%" /nologo /platform:x64 /target:winexe /out:OneManCursor.exe /reference:System.Windows.Forms.dll /reference:System.Drawing.dll OneManCursor.cs
if errorlevel 1 (
  echo Build failed.
  pause
  exit /b 1
)
echo Build OK: OneManCursor.exe
echo It runs in the task tray (no window). On first run, Windows Firewall will ask. Allow on Private network.
pause
