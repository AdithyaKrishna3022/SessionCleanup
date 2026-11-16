param([string]$Only = '')   # e.g. -Only Zoom,OneDrive  (leave empty to run everything)

$BucketName = 'iwd-aws-clickops-installers-and-executables'
$Profile    = 'appstream_machine_role'
$Dir        = 'C:\Temp\Installers'
$Stage      = 'C:\Temp\Installers\_stage'
$Log        = "C:\Temp\golden-install-$(Get-Date -Format yyyyMMdd-HHmmss).log"
$Results    = @()

# Clear old installer folder (the \\?\ prefix lets Windows delete folders with odd names)
if (Test-Path $Dir) { cmd /c "rd /s /q \\?\$Dir" 2>$null | Out-Null }
New-Item -ItemType Directory -Path $Dir -Force | Out-Null

# Helper code for finding / closing windows (used by the main script and by the popup-closer job)
$PopupCs = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class PopupUtil {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, StringBuilder l);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public static System.Collections.Generic.List<string> TopWindows() {
    var list = new System.Collections.Generic.List<string>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (IsWindowVisible(h)) {
        StringBuilder sb = new StringBuilder(256);
        GetWindowText(h, sb, 256);
        if (sb.Length > 0) { uint pid; GetWindowThreadProcessId(h, out pid); list.Add(h.ToInt64() + "|" + pid + "|" + sb.ToString()); }
      }
      return true;
    }, IntPtr.Zero);
    return list;
  }
  public static bool ClickButton(IntPtr dlg, string caption) {
    IntPtr found = IntPtr.Zero;
    EnumChildWindows(dlg, delegate(IntPtr h, IntPtr l) {
      StringBuilder sb = new StringBuilder(256);
      SendMessage(h, 0x000D, (IntPtr)256, sb);   // WM_GETTEXT
      if (sb.ToString().Replace("&","").Trim() == caption) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    if (found == IntPtr.Zero) return false;
    SendMessage(found, 0x00F5, IntPtr.Zero, IntPtr.Zero);  // BM_CLICK
    return true;
  }
}
'@
Add-Type -TypeDefinition $PopupCs

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

# Returns the handle of the first visible window whose title is exactly $Title (or zero)
function Find-Win($Title) {
  foreach ($w in [PopupUtil]::TopWindows()) {
    $parts = $w -split '\|', 3
    if ($parts[2] -eq $Title) { return [IntPtr][int64]$parts[0] }
  }
  return [IntPtr]::Zero
}

# Background job that finds popup windows by title and clicks their "Close" button.
# Writes what it does to C:\Temp\popup-closer.log
function Start-PopupCloser($Titles) {
  Start-Job -ArgumentList $PopupCs, ($Titles -join '|') -ScriptBlock {
    param($cs, $tj)
    $t  = $tj -split '\|'
    $lf = 'C:\Temp\popup-closer.log'
    try { Add-Type -TypeDefinition $cs } catch { Add-Content $lf "Add-Type failed: $($_.Exception.Message)"; return }
    Add-Content $lf "$(Get-Date -Format HH:mm:ss) closer started, watching for: $($t -join ', ')"
    while ($true) {
      foreach ($w in [PopupUtil]::TopWindows()) {
        $parts = $w -split '\|', 3
        $hwnd  = [IntPtr][int64]$parts[0]
        $title = $parts[2]
        foreach ($x in $t) {
          if ($title -like "*$x*") {
            $clicked = [PopupUtil]::ClickButton($hwnd, 'Close')
            if (-not $clicked) { [PopupUtil]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null }
            Add-Content $lf "$(Get-Date -Format HH:mm:ss) MATCH '$title'; clicked Close button: $clicked"
          }
        }
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

function Install-App($Name, $File, $Switches, $RegName, $OkCodes = @(0,3010), $ClosePopups = @(), $KillAfter = @(), $FinishWindow = '') {
  if ($Only) {
    $match = $false
    foreach ($o in ($Only -split ',')) { if ($Name -like "*$($o.Trim())*") { $match = $true } }
    if (-not $match) { return }
  }
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

  # Wait only for the installer process itself (not for apps it launches), max 20 minutes.
  # If the installer leaves a "completion" window open, close it once the install really looks done.
  $p = Start-Process -FilePath $dest -ArgumentList $Switches -PassThru
  $null = $p.Handle
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $quiet = 0; $closedFinish = $false
  while (-not $p.HasExited -and $sw.Elapsed.TotalMinutes -lt 20) {
    Start-Sleep -Seconds 3
    if ($FinishWindow -and -not $closedFinish -and -not $p.HasExited) {
      $hw = Find-Win $FinishWindow
      if ($hw -ne [IntPtr]::Zero -and $sw.Elapsed.TotalSeconds -gt 45 -and -not (Get-Process msiexec -ErrorAction SilentlyContinue) -and (Test-Installed $RegName)) { $quiet++ } else { $quiet = 0 }
      if ($quiet -ge 5) {
        Log "Install looks complete; closing the '$FinishWindow' window"
        [PopupUtil]::PostMessage($hw, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        $closedFinish = $true
      }
    }
  }
  $finished = $p.HasExited
  if ($job) { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue }
  if (-not $finished) {
    Log "WARNING: installer still running after 20 minutes"
    $script:Results += [pscustomobject]@{App=$Name; Exit='timeout'; Installer='FAIL'; Registry='-'}
    return
  }
  $code = $p.ExitCode
  $ok = $OkCodes -contains $code
  Log "Exit code: $code  ->  $(if ($ok) {'OK'} else {'FAIL'})"

  # Close apps the installer launched on its own, then give the registry a moment to settle
  Start-Sleep -Seconds 8
  if ($KillAfter.Count -gt 0) {
    $running = Get-Process -Name $KillAfter -ErrorAction SilentlyContinue
    if ($running) { Log "Closing launched apps: $((($running | Select-Object -ExpandProperty Name -Unique)) -join ', ')"; $running | Stop-Process -Force -ErrorAction SilentlyContinue }
  }
  $script:Results += [pscustomobject]@{
    App=$Name; Exit=$code
    Installer=$(if ($ok) {'OK'} else {'FAIL'})
    Registry=$(if (Test-Installed $RegName) {'FOUND'} else {'MISSING'})
  }
}

Log "Start. Log file: $Log  Only='$Only'"
aws --version 2>&1 | ForEach-Object { Log $_ }

Install-App 'VC++ Redistributable x64' 'VC_redist.x64.exe' '/install /quiet /norestart' @('Microsoft Visual C++ v14*Redistributable (x64)*','Microsoft Visual C++ 2015*Redistributable (x64)*') @(0,3010,1638)
Install-App 'FSLogix Apps agent' 'FSLogixAppsSetup.exe' '/install /quiet /norestart' 'Microsoft FSLogix Apps*'
Install-App 'Google Chrome' 'ChromeSetup.exe' '/silent /install' 'Google Chrome*' @(0,3010) @() @('chrome')
Install-App 'Adobe Acrobat Reader' 'Reader_en_install.exe' '/sAll /rs /msi EULA_ACCEPT=YES' 'Adobe Acrobat*' @(0,3010) @('Internet Explorer') @('Acrobat','AcroCEF','AcroRd32') 'Adobe Acrobat Reader Installer'
Install-App 'Microsoft OneDrive' 'OneDriveSetup.exe' '/allusers /silent' 'Microsoft OneDrive*' @(0,3010) @() @('OneDrive')
Install-App 'Zoom' 'ZoomInstallerFull.exe' '/silent' 'Zoom*' @(0,3010) @() @('Zoom')

# --- next apps get added above this line ---

Log "=== SUMMARY ==="
$Results | Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Log $_ }
Log "Done."
