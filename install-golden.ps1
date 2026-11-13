$Bucket  = 's3://iwd-aws-clickops-installers-and-executables/Golden Image/'
$Profile = 'appstream_machine_role'
$Dir     = 'C:\Temp\Installers'
$Log     = "C:\Temp\golden-install-$(Get-Date -Format yyyyMMdd-HHmmss).log"
$Results = @()
New-Item -ItemType Directory -Path $Dir -Force | Out-Null

function Log($m) {
  $l = "$(Get-Date -Format 'HH:mm:ss')  $m"
  Write-Host $l
  Add-Content -Path $Log -Value $l
}

function Test-Installed($Like) {
  $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
       'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
  Get-ItemProperty $k -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like $Like } | Select-Object -First 1
}

function Install-App($Name, $File, $Switches, $RegName, $OkCodes = @(0,3010)) {
  Log "=== $Name ==="
  $out = aws s3 cp $Bucket $Dir --recursive --exclude "*" --include "*$File" --only-show-errors --profile $Profile 2>&1
  if ($out) { Log "aws: $($out -join ' ')" }
  $f = Get-ChildItem $Dir -Recurse -Filter $File -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $f) {
    Log "FAILED: $File not downloaded"
    $script:Results += [pscustomobject]@{App=$Name; Exit='n/a'; Installer='FAIL'; Registry='-'}
    return
  }
  Log "Downloaded: $($f.FullName)"
  $p = Start-Process -FilePath $f.FullName -ArgumentList $Switches -Wait -PassThru
  $code = $p.ExitCode
  $ok = $OkCodes -contains $code
  Log "Exit code: $code  ->  $(if ($ok) {'OK'} else {'FAIL'})"
  $script:Results += [pscustomobject]@{
    App=$Name; Exit=$code
    Installer=$(if ($ok) {'OK'} else {'FAIL'})
    Registry=$(if (Test-Installed $RegName) {'FOUND'} else {'MISSING'})
  }
}

Log "Start. Log file: $Log"
aws --version 2>&1 | ForEach-Object { Log $_ }

Install-App 'VC++ Redistributable x64' 'VC_redist.x64.exe' '/install /quiet /norestart' 'Microsoft Visual C++ 2015*Redistributable (x64)*' @(0,3010,1638)

# --- next apps get added above this line ---

Log "=== SUMMARY ==="
$Results | Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Log $_ }
Log "Done."
