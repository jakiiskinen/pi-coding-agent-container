@echo off
wt --window 0 new-tab powershell -ExecutionPolicy Bypass -File "%~dp0start-pi.ps1" -Local
