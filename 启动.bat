@echo off
chcp 65001 >nul 2>&1
title Liblocal - 本地 MiniMax H3 生成画布
cd /d "%~dp0"

echo ============================================================
echo   Liblocal  本地 MiniMax H3 生成画布
echo ============================================================
echo.

set "PY=%~dp0runtime\venv\Scripts\python.exe"
if not exist "%PY%" (
  echo [错误] 找不到运行时 Python：
  echo        %PY%
  echo.
  echo 请确认 runtime 目录完整。若是新机器，请先按 docs\部署指南.md 安装。
  echo.
  pause
  exit /b 1
)

if not exist "%~dp0PinCanvas\dist\index.html" (
  echo [提示] 前端尚未构建，正在尝试构建…
  where npm >nul 2>&1
  if errorlevel 1 (
    echo [错误] 未检测到 Node.js/npm，无法构建前端。
    echo        请安装 Node.js 20+ 后重新运行，或使用已构建好的发行包。
    pause
    exit /b 1
  )
  pushd "%~dp0PinCanvas"
  call npm install
  call npm run build
  popd
)

echo 正在启动本地服务…（首次生成需要加载约 28GB 权重，请耐心等待）
echo 关闭此窗口即可停止服务。
echo.

rem 稍后再打开浏览器，给服务留出绑定端口的时间
start "" /b cmd /c "timeout /t 3 >nul & start http://127.0.0.1:8801"

"%PY%" -m orchestrator.server

echo.
echo 服务已退出。
pause
