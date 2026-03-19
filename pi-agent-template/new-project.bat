@echo off
wt --window 0 new-tab powershell -NoExit -ExecutionPolicy Bypass -File "%~dp0new-project.ps1"
