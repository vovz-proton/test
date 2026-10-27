@echo off
rem Debug run: console stays open and shows what the program is doing.
cd /d "%~dp0"
python tray_prank.py --debug
pause
