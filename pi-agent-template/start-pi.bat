@echo off
set POS=
for /f "tokens=*" %%i in ('powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms;$c=[Windows.Forms.Cursor]::Position;$s=[Windows.Forms.Screen]::FromPoint($c);if($env:WT_SESSION){Write-Output('--pos '+($c.X+80).ToString()+','+($c.Y+80).ToString())}else{Write-Output('--pos '+$s.Bounds.X.ToString()+','+$s.Bounds.Y.ToString())}"') do set POS=%%i
wt --window new %POS% new-tab powershell -ExecutionPolicy Bypass -File "%~dp0start-pi.ps1"
if %errorlevel% neq 0 pause
