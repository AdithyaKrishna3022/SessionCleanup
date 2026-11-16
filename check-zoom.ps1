$pat = '*Zoom*'

Write-Host "--- Uninstall registry (machine-wide) ---"
$k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $pat } |
  Select-Object DisplayName, DisplayVersion, InstallLocation | Format-List | Out-String | Write-Host

Write-Host "--- Uninstall registry (current user only) ---"
Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
  Where-Object { $_.DisplayName -like $pat } |
  Select-Object DisplayName, DisplayVersion, InstallLocation | Format-List | Out-String | Write-Host

Write-Host "--- Folder check ---"
$paths = @('C:\Program Files\Zoom\bin\Zoom.exe', 'C:\Program Files (x86)\Zoom\bin\Zoom.exe')
Get-ChildItem C:\Users -Directory -ErrorAction SilentlyContinue | ForEach-Object { $paths += "$($_.FullName)\AppData\Roaming\Zoom\bin\Zoom.exe" }
foreach ($p in $paths) { "{0,-70} {1}" -f $p, (Test-Path $p) }

Write-Host "--- Zoom processes running ---"
Get-Process -Name Zoom* -ErrorAction SilentlyContinue | Select-Object Name, Id | Format-Table -AutoSize | Out-String | Write-Host
