# Install-CASAS-SEB.ps1
# Silently installs CASAS eTests SEB and Safe Exam Browser (SEB) on the image builder.
# Run in an elevated (Administrator) PowerShell. Log files are written to C:\Temp.
#
# How it works (from the installer log and CreateSEBShortcut.bat):
#  - The CASAS installer (Inno Setup) copies its files, then launches the SEB setup
#    with no silent option and waits for it, then runs CreateSEBShortcut.bat
#    (which only makes a Desktop shortcut and waits up to ~2 minutes for SEB to appear).
#  - So this script starts CASAS silently, closes the SEB window CASAS opens,
#    and installs SEB silently itself right away. CASAS then finishes on its own.

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path C:\Temp -Force | Out-Null

$casas     = "$env:USERPROFILE\Downloads\eTestsSEBsetup (1).exe"
$sebDir    = 'C:\Program Files (x86)\CASAS eTests SEB'
$sebExe    = 'C:\Program Files (x86)\SafeExamBrowser\Application\SafeExamBrowser.exe'
$sebBundle = 'SEB_3.7.0.682_SetupBundle'

if (-not (Test-Path $casas)) { throw "Installer not found: $casas" }

Write-Host '1/4 Starting the CASAS installer silently...'
$c = Start-Process -FilePath $casas -PassThru -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/LOG=C:\Temp\casas-install.log'
$null = $c.Handle   # keeps the exit code available after the process ends

Write-Host '2/4 Waiting for the SEB setup window to start, then closing it...'
$deadline = (Get-Date).AddMinutes(5)
while ((Get-Date) -lt $deadline -and -not (Get-Process -Name $sebBundle -ErrorAction SilentlyContinue)) {
    Start-Sleep -Seconds 2
}
Start-Sleep -Seconds 3
Get-Process -Name $sebBundle -ErrorAction SilentlyContinue | Stop-Process -Force

Write-Host '3/4 Installing Safe Exam Browser silently...'
$s = Start-Process -FilePath "$sebDir\$sebBundle.exe" -Wait -PassThru -ArgumentList '/quiet', '/norestart', '/log', 'C:\Temp\seb-install.log'

Write-Host '4/4 Waiting for the CASAS installer to finish and checking the result...'
if (-not $c.WaitForExit(240000)) { Write-Warning 'CASAS installer still running after 4 minutes.' }

$apps = Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*, HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* |
    Where-Object { $_.DisplayName -match 'CASAS|Safe Exam' } |
    Select-Object DisplayName

''
"CASAS exit code: $($c.ExitCode)"
"SEB exit code:   $($s.ExitCode)   (0 or 3010 = success)"
$apps | Format-Table -AutoSize
"SafeExamBrowser.exe found: $(Test-Path $sebExe)"
