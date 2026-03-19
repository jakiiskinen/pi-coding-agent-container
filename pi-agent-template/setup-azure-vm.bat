@echo off
wt --window 0 new-tab powershell -ExecutionPolicy Bypass -File "%~dp0setup-azure-vm.ps1"
