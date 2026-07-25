@echo off
REM TeleportMod UI Launcher - runs via Task Scheduler to escape game's window station
setlocal

set "PS1_PATH=%~dp0TeleportModUI.ps1"
set "TASK_NAME=G1R_TeleportMod_UI"

REM Clean up any previous task
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1

REM Create and immediately run a scheduled task
REM Task Scheduler runs in user's interactive session (visible desktop)
REM WinForms needs STA; keep the UI process visible so it does not look like a black-window flash.
schtasks /Create /TN "%TASK_NAME%" /TR "powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File \"%PS1_PATH%\"" /SC ONCE /ST 00:00 /F >nul 2>&1
schtasks /Run /TN "%TASK_NAME%" >nul 2>&1
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1
