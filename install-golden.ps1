$BucketName = 'iwd-aws-clickops-installers-and-executables'
$Profile    = 'appstream_machine_role'
$Dir        = 'C:\Temp\Installers'
$Stage      = 'C:\Temp\Installers\_stage'
$Log        = "C:\Temp\golden-install-$(Get-Date -Format yyyyMMdd-HHmmss).log"
$Results    = @()

# Clear old installer folder (the \\?\ prefix lets Windows delete folders with odd names)
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

function Get-InstallerFromS3($File) {
  # Download into a staging folder (S3 folder names can contain odd characters),
  # then copy the file to a clean path using .NET with the \\?\ prefix.
  if (Test-Path $Stage) { cmd /c "rd /s /q \\?\$Stage" 2>$null | Out-Null }
  New-Item -ItemType Directory -Path $Stage -Force | Out-Null
  $out = aws s3 cp "s3://$BucketName/Golden Image/" $Stage --recursive --exclude "*" --include "*$File" --only-show-errors --profile $Profile 2>&1
  if ($out) { Log "aws: $($out -join ' ')" }
  $dest = Join-Path $Dir $File
  try {
    $src = [System.IO.Directory]::GetFiles("\\?\$Stage", $File, [System.IO.SearchOption]::AllDirectories) | Select-Object -First 1
    if ($src) {
      [System.IO.File]::Copy($src, $dest, $true)
    } else {
      Log "No file named $File found under staging. Folders in staging (name + character codes):"
      foreach ($d in [System.IO.Directory]::GetDirectories("\\?\$Stage")) {
        $n = [System.IO.Path]::GetFileName($d)
        Log ("  '" + $n + "'  codes: " + (($n.ToCharArray() | ForEach-Object { [int]$_ }) -join ','))
      }
    }
  } catch {
    Log "Copy error: $($_.Exception.Message)"
  }
  if (Test-Path $Stage) { cmd /c "rd /s /q \\?\$Stage" 2>$null | Out-Null }
  if (Test-Path $dest) { return $dest } else { return $null }
}

function Install-App($Name, $File, $Switches, $RegName, $OkCodes = @(0,3010)) {
  Log "=== $Name ==="
  $dest = Get-InstallerFromS3 $File
  if (-not $dest) {
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

Install-App 'FSLogix Apps agent' 'FSLogixAppsSetup.exe' '/install /quiet /norestart' 'Microsoft FSLogix Apps*'

# --- next apps get added above this line ---

Log "=== SUMMARY ==="
$Results | Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Log $_ }
Log "Done."
