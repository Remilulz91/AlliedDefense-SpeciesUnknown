@echo off
rem Removes this project's mods from the game. A dev link is simply detached.
setlocal EnableDelayedExpansion
call "%~dp0find-mods.bat"
if not defined MODS (
  echo [ERROR] ue4ss\Mods folder not found. Use SU_MODS_DIR.
  pause
  exit /b 1
)
for /d %%D in ("%~dp0..\mods\*") do call :remove "%%~nxD"
pause
exit /b 0

:remove
set "DST=!MODS!\%~1"
if not exist "!DST!" (
  echo %~1: not installed.
  goto :eof
)
rmdir "!DST!" 2>nul
if exist "!DST!" (
  echo %~1: installed copy found, its logs will be deleted.
  choice /m "Delete %~1"
  if errorlevel 2 goto :eof
  rmdir /s /q "!DST!"
)
echo OK: %~1 removed.
goto :eof
