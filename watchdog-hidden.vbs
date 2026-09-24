' watchdog-hidden.vbs - run watchdog.ps1 with NO console window at all.
'
' Why this wrapper exists: on Windows 11 the default terminal is Windows Terminal.
' "powershell.exe -WindowStyle Hidden" only suppresses the legacy conhost window;
' as soon as the console starts it is handed off to Windows Terminal
' (OpenConsole.exe + WindowsTerminal.exe) and that window IS visible.
' That is the window that flashed on screen every minute.
'
' WScript.Shell.Run(cmd, 0, False) starts the child with SW_HIDE, which produced
' no visible window in testing.
'
' Path is derived from this script's own location, so the repo works on any machine.
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptDir & "\watchdog.ps1""", 0, False
