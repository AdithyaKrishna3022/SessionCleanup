Write-Host "--- Installer-related processes currently running ---"
$names = 'msiexec','Reader_en_install','AdobeARM','Adobe Installer','AcroRd32','Acrobat','AcroCEF','McAfee*','mcsvhost','McUICnt','OneDriveSetup','ZoomInstallerFull','setup'
Get-Process -Name $names -ErrorAction SilentlyContinue | Select-Object Name, Id, StartTime | Format-Table -AutoSize

Write-Host "--- Stopping them ---"
Get-Process -Name $names -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Write-Host "--- Restarting Windows Installer service ---"
Stop-Service msiserver -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
Start-Service msiserver -ErrorAction SilentlyContinue
Get-Service msiserver | Format-Table Name, Status -AutoSize

Write-Host "--- Pending reboot flags ---"
Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue) -ne $null
Write-Host "Done. Now retry the uninstall in Settings > Apps."
