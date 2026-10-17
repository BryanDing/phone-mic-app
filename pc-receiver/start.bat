@echo off
rem ============================================================
rem  手机麦克风接收程序 - 一键启动
rem  首次运行会自动创建 Python 虚拟环境并安装依赖（需联网一次）
rem ============================================================
setlocal
cd /d "%~dp0"

where python >nul 2>nul
if %errorlevel%==0 (
    set "PY=python"
) else (
    set "PY=C:\Users\Administrator\.workbuddy\binaries\python\versions\3.13.12\python.exe"
)

if not exist ".venv" %PY% -m venv .venv

".venv\Scripts\python.exe" -m pip install -q -r requirements.txt
if errorlevel 1 ".venv\Scripts\python.exe" -m pip install -q -i https://pypi.tuna.tsinghua.edu.cn/simple -r requirements.txt

".venv\Scripts\python.exe" phone_mic_receiver.py %*
pause
