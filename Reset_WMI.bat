# Reset the Windows Management Instrumentation Command-line (WMIC)
sc stop iphlpsvc
sc stop wscsvc
sc stop Winmgmt

net stop winmgmt /y
net stop bits /y
net stop wuauserv /y
net stop ccmexec /y

cd %systemroot%\system32\wbem
rd /S /Q repository
regsvr32 /s %systemroot%\system32\scecli.dll
regsvr32 /s %systemroot%\system32\userenv.dll
mofcomp cimwin32.mof
mofcomp cimwin32.mfl
mofcomp rsop.mof
mofcomp rsop.mfl
for /f %%s in ('dir /b /s *.dll') do regsvr32 /s %%s
for /f %%s in ('dir /b *.mof') do mofcomp %%s
for /f %%s in ('dir /b *.mfl') do mofcomp %%s
mofcomp exwmi.mof
mofcomp -n:root\cimv2\applications\exchange wbemcons.mof
mofcomp -n:root\cimv2\applications\exchange smtpcons.mof
mofcomp exmgmt.mof

net start winmgmt
net start bits
net start wuauserv
net start ccmexec

sc start iphlpsvc
sc start wscsvc
sc start Winmgmt
