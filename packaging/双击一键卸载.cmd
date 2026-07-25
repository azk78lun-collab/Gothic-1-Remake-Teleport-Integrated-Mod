@echo off
chcp 65001 >nul
echo =======================================================
echo   Gothic 1 Remake Mod V4 一键卸载清除
echo   作者：猴子香蕉你大爷
echo   B站主页：https://space.bilibili.com/258597412
echo =======================================================
echo.
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0uninstall.ps1"
