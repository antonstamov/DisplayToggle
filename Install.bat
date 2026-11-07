@echo off
rem DisplayToggle installer: creates Monitor-Toggle.lnk next to the scripts.
rem Double-click this file, then pin the created shortcut to the taskbar
rem (right-click ^> Pin to taskbar) or move it anywhere convenient.
setlocal
set "DIR=%~dp0"
set "DIR=%DIR:~0,-1%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d='%DIR%'; $sh=New-Object -ComObject WScript.Shell; $l=$sh.CreateShortcut($d+'\Monitor-Toggle.lnk'); $l.TargetPath=$env:SystemRoot+'\System32\wscript.exe'; $l.Arguments='\"'+$d+'\Toggle-Primary-Silent.vbs\"'; $l.WorkingDirectory=$d; $l.IconLocation=$d+'\icon.ico,0'; $l.Description='Toggle primary display'; $l.Save(); Write-Output ('created: '+$d+'\Monitor-Toggle.lnk')"
pause
