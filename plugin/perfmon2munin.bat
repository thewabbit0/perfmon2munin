@echo off
rem a batch wrapper to call the perfmon2munin.ps1 as munin-node is unable to pass parameters 
rem to called executables

set OUTFILE=%TEMP%\perfmon2munin-%RANDOM%.output

rem munin-node for windows has very short timeouts for getting the name of a plugin,
rem occasionally the powershell call will take too long and the plugin will be discarded upon
rem service startup. Work around this by returning the name immediately
if "%1" == "name" (echo perfmon>%OUTFILE%&&type %OUTFILE%&&goto end)

cmd /C "echo . "%~dp0\perfmon2munin.ps1" "%1" | %SystemRoot%\syswow64\WindowsPowerShell\v1.0\powershell.exe -command -" >%OUTFILE%
type %OUTFILE%

:end
del /Q %OUTFILE%