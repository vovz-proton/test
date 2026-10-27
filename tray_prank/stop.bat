@echo off
rem Ask the already running copy to quit (it will show its good-bye dialog).
cd /d "%~dp0"
python tray_prank.py --quit
pause
