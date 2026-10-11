@echo off
rem Finds the UE4SS Mods folder of Species: Unknown. Result in %MODS%.
rem To force a path:  set SU_MODS_DIR=C:\...\Binaries\Win64\ue4ss\Mods
set "MODS="
if defined SU_MODS_DIR (
  set "MODS=%SU_MODS_DIR%"
  goto :eof
)
set "STEAM="
for /f "tokens=2,*" %%a in ('reg query "HKCU\Software\Valve\Steam" /v SteamPath 2^>nul ^| findstr /i "SteamPath"') do set "STEAM=%%b"
if not defined STEAM set "STEAM=%ProgramFiles(x86)%\Steam"
set "STEAM=%STEAM:/=\%"
call :trylib "%STEAM%"
if defined MODS goto :eof
if exist "%STEAM%\steamapps\libraryfolders.vdf" (
  for /f "usebackq tokens=1,*" %%a in ("%STEAM%\steamapps\libraryfolders.vdf") do (
    if /i "%%~a"=="path" if not defined MODS call :trylib "%%~b"
  )
)
goto :eof

:trylib
set "LIB=%~1"
set "LIB=%LIB:\\=\%"
for /d %%G in ("%LIB%\steamapps\common\Species*") do (
  for /f "delims=" %%M in ('dir /s /b /ad "%%~G\Mods" 2^>nul ^| findstr /i /e "ue4ss.Mods"') do (
    if not defined MODS set "MODS=%%M"
  )
  if not defined MODS for /f "delims=" %%M in ('dir /s /b /ad "%%~G\Mods" 2^>nul ^| findstr /i /e "Win64.Mods"') do (
    if not defined MODS set "MODS=%%M"
  )
)
goto :eof
