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
    Where-Object { $n = $_.DisplayName; $n -and (@($Like) | Where-Object { $n -like $_ }) } |
    Select-Object -First 1
}

# Background job that closes popup windows with the given titles (same as clicking Close)
function Start-PopupCloser($Titles) {
  Start-Job -ArgumentList (,$Titles) -ScriptBlock {
    param($t)
    Add-Type -Namespace W -Name U -MemberDefinition '[DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern IntPtr FindWindow(string c, string n); [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);'
    while ($true) {
      foreach ($x in $t) {
        $h = [W.U]::FindWindow($null, $x)
        if ($h -ne [IntPtr]::Zero) { [W.U]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null }
      }
      Start-Sleep -Seconds 2
    }
  }
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

function Install-App($Name, $File, $Switches, $RegName, $OkCodes = @(0,3010), $ClosePopups = @()) {
  Log "=== $Name ==="
  $dest = Get-InstallerFromS3 $File
  if (-not $dest) {
    Log "FAILED: $File not downloaded"
    $script:Results += [pscustomobject]@{App=$Name; Exit='n/a'; Installer='FAIL'; Registry='-'}
    return
  }
  Log "Downloaded: $dest ($([math]::Round((Get-Item $dest).Length/1MB,1)) MB)"
  $job = $null
  if ($ClosePopups.Count -gt 0) { $job = Start-PopupCloser $ClosePopups; Log "Popup closer running for: $($ClosePopups -join ', ')" }
  $p = Start-Process -FilePath $dest -ArgumentList $Switches -Wait -PassThru
  if ($job) { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue }
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

Install-App 'VC++ Redistributable x64' 'VC_redist.x64.exe' '/install /quiet /norestart' @('Microsoft Visual C++ v14*Redistributable (x64)*','Microsoft Visual C++ 2015*Redistributable (x64)*') @(0,3010,1638)
Install-App 'FSLogix Apps agent' 'FSLogixAppsSetup.exe' '/install /quiet /norestart' 'Microsoft FSLogix Apps*'
Install-App 'Google Chrome' 'ChromeSetup.exe' '/silent /install' 'Google Chrome*'
Install-App 'Adobe Acrobat Reader' 'Reader_en_install.exe' '/sAll /rs /msi EULA_ACCEPT=YES' 'Adobe Acrobat*' @(0,3010) @('Internet Explorer')

# --- next apps get added above this line ---

Log "=== SUMMARY ==="
$Results | Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Log $_ }
Log "Done."
