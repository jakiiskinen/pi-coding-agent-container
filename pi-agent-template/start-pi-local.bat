@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0start-pi.ps1" -Local
if %errorlevel% neq 0 pause
