@echo off
if not exist "%~dp0TeleportModUI.ps1" (
    echo ERROR: TeleportModUI.ps1 not found.
    pause
    exit /b 1
)
wscript.exe //B "%~dp0LaunchTeleportUI.vbs"
