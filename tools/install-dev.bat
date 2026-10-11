@echo off
rem Installs every mod of mods\ as a LINK (junction) in ue4ss\Mods.
rem The game reads the project directly: live edits, logs land in the project.
setlocal EnableDelayedExpansion
call "%~dp0find-mods.bat"
if not defined MODS (
  echo [ERROR] Species Unknown ue4ss\Mods folder not found.
  echo Set it manually and run again, for example:
  echo   set SU_MODS_DIR=C:\...\Binaries\Win64\ue4ss\Mods
  pause
  exit /b 1
)
echo Mods UE4SS : !MODS!
for /d %%D in ("%~dp0..\mods\*") do call :link "%%~fD" "%%~nxD"
pause
exit /b 0

:link
set "SRC=%~1"
set "DST=!MODS!\%~2"
if exist "!DST!" (
  rmdir "!DST!" 2>nul
  if exist "!DST!" (
    echo [ERROR] %~2: a copy already exists in the game. Run tools\uninstall.bat first.
    goto :eof
  )
)
mklink /J "!DST!" "!SRC!" >nul
if errorlevel 1 (
  echo [ERROR] %~2: could not create the link.
) else (
  echo OK: %~2  -^>  linked to the project
)
goto :eof
