@echo off
setlocal
cd /d "%~dp0"
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"

:: Single silent entry point: whatever *.vbs sits next to this file.
:: No console windows remain after start (server runs under pythonw).
for %%F in ("%~dp0*.vbs") do (
    start "" "%%F"
    exit /b 0
)

:: Fallback: direct server start if no VBS helper found.
if exist "C:\Python314\pythonw.exe" (
    start "" "C:\Python314\pythonw.exe" "%~dp0app\backend\server.py" --host 127.0.0.1 --port 8780
    exit /b 0
)
where pythonw >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    start "" pythonw "%~dp0app\backend\server.py" --host 127.0.0.1 --port 8780
    exit /b 0
)
echo Backend python not found. Install Python 3.14+ or place runtime\python next to this file.
endlocal
