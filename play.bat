@echo off
rem ---------------------------------------------------------------------------
rem  Play DOOM on the CPU in this repository. Double-click this file.
rem  The first run builds everything (a few minutes); after that it starts fast.
rem ---------------------------------------------------------------------------
cd /d "%~dp0"
title DOOM on rv32im

echo.
echo  Building DOOM for the CPU in rtl\ and starting it...
echo  (first run takes a few minutes, later runs are quick)
echo.

python scripts\fetch_doom.py
if errorlevel 1 goto failed

python scripts\build_doom.py --play
if errorlevel 1 goto failed

echo.
echo  Done. Run this file again to play again.
pause
exit /b 0

:failed
echo.
echo  Something went wrong above.
echo  Check that Python and the tools in CLEANUP.md are installed.
echo.
pause
exit /b 1
