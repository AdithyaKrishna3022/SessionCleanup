$BucketName = 'iwd-aws-clickops-installers-and-executables'
$Profile    = 'appstream_machine_role'
$Dir        = 'C:\Temp\Installers'
$Log        = "C:\Temp\golden-install-$(Get-Date -Format yyyyMMdd-HHmmss).log"
$Results    = @()
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Clear old installer folder (the \\?\ prefix lets Windows delete folders with trailing spaces)
if (Test-Path $Dir) { cmd /c "rd /s /q \\?\$Dir" 2>$null | Out-Null }
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
  # Find the exact S3 key for this file (folder names may have odd trailing spaces)
  $key = (aws s3api list-objects-v2 --bucket $BucketName --prefix "Golden Image/" --query "Contents[?ends_with(Key,'/$File')].Key | [0]" --output text --profile $Profile 2>&1 | Select-Object -First 1)
  if (-not $key -or $key -eq 'None' -or $key -like '*error*') {
    Log "FAILED: could not find $File in S3 ($key)"
    $script:Results += [pscustomobject]@{App=$Name; Exit='n/a'; Installer='FAIL'; Registry='-'}
    return
  }
  Log "S3 key found for $File"
  $dest = Join-Path $Dir $File
  $out = aws s3 cp "s3://$BucketName/$key" $dest --only-show-errors --profile $Profile 2>&1
  if ($out) { Log "aws: $($out -join ' ')" }
  if (-not (Test-Path $dest)) {
    Log "FAILED: $File not downloaded"
    $script:Results += [pscustomobject]@{App=$Name; Exit='n/a'; Installer='FAIL'; Registry='-'}
    return
  }
  Log "Downloaded: $dest ($([math]::Round((Get-Item $dest).Length/1MB,1)) MB)"
  $p = Start-Process -FilePath $dest -ArgumentList $Switches -Wait -PassThru
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
