@echo off
start "" /min powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0scripts\hotkey.ps1"
