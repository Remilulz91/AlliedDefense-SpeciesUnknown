@echo off
rem Installs every mod of mods\ as a COPY (frozen version) in ue4ss\Mods.
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
for /d %%D in ("%~dp0..\mods\*") do call :copy "%%~fD" "%%~nxD"
pause
exit /b 0

:copy
set "DST=!MODS!\%~2"
rem remove a possible dev link (does not touch the project)
if exist "!DST!" rmdir "!DST!" 2>nul
robocopy "%~1" "!DST!" /E /XF *.log /NFL /NDL /NJH /NJS >nul
if errorlevel 8 (
  echo [ERROR] %~2: copy failed.
) else (
  echo OK: %~2 copied
)
goto :eof
