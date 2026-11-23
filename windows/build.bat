@echo off
chcp 65001 >nul
echo 正在安装打包工具...
python -m pip install pyinstaller
echo 正在打包...
python -m PyInstaller --onefile --noconsole --name USBTransfer usb_pull_gui.py
echo.
echo 完成！可执行文件在 dist\USBTransfer.exe
pause
