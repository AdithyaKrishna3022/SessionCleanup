param(
    [Parameter(Mandatory)][ValidateSet('Logoff', 'Logon', 'Watch', 'Startup', 'Shutdown')][string]$Mode,
    [switch]$DryRun
)

# ===== CONFIG =====
$GraceMinutes = 2
$RootPattern  = '^[A-Za-z]:\\Users\\[^\\]+$'
$Sep       = '\'
$BaseDir   = 'C:\ProgramData\SessionCleanup'
$StateFile = $BaseDir + $Sep + 'disc-state.xml'
$FlagFile  = $BaseDir + $Sep + 'cleaning.flag'
$LogFile   = $BaseDir + $Sep + 'cleanup.log'
$TargetFile = $BaseDir + $Sep + 'target-users.txt'
$TargetUsers = @()
if (Test-Path -LiteralPath $TargetFile) {
    $TargetUsers = @(Get-Content -LiteralPath $TargetFile | ForEach-Object { ($_.Trim() -split '\\')[-1] } | Where-Object { $_ })
}
if ($Mode -in 'Logoff', 'Logon') {
    $LogFile = $BaseDir + $Sep + 'Logs' + $Sep + $Mode.ToLower() + '-' + $env:USERNAME + '.log'
}
$UserFolders = @(
    'Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music', 'Favorites',
    'AppData\Local\Temp',
    'AppData\Local\Microsoft\Windows\INetCache',
    'AppData\Local\Microsoft\Windows\INetCookies',
    'AppData\Local\Microsoft\Windows\History',
    'AppData\Roaming\Microsoft\Windows\Recent',
    'AppData\Roaming\Microsoft\Credentials',
    'AppData\Local\Microsoft\Credentials',
    'AppData\Local\Google\Chrome\User Data',
    'AppData\Local\Microsoft\Edge\User Data',
    'AppData\Local\BraveSoftware\Brave-Browser\User Data',
    'AppData\Roaming\Mozilla\Firefox',
    'AppData\Local\Mozilla\Firefox',
    'AppData\Roaming\Opera Software',
    'AppData\Roaming\Microsoft\Windows\PowerShell',
    'AppData\Local\AWSToolkit',
    '.aws'
)
# ==================

$script:Deleted = 0
$script:Failed = 0
$script:Skipped = 0

function Write-Log([string]$Message) {
    $line = (Get-Date -Format s) + ' [' + $Mode + '] ' + $Message
    try {
        if ((Get-Item -LiteralPath $LogFile -ErrorAction Stop).Length -gt 2MB) {
            Move-Item -LiteralPath $LogFile -Destination ($LogFile + '.old') -Force
        }
    } catch { }
    try { Add-Content -LiteralPath $LogFile -Value $line -ErrorAction SilentlyContinue } catch { }
}

# Reads quser output (English column names). Disconnected sessions have an empty SESSIONNAME.
function Get-Sessions {
    foreach ($line in @(quser 2>$null)) {
        if ($line -match '^\s*>?(\S+)\s+(?:(\S+)\s+)?(\d+)\s+(Active|Disc)\b') {
            [pscustomobject]@{ User = $Matches[1]; Id = [int]$Matches[3]; State = $Matches[4] }
        }
    }
}

function Test-Target([string]$Name) {
    if (-not $Name) { return $false }
    return ($TargetUsers -contains $Name)
}

function Get-AccountName([string]$Sid) {
    try {
        $acct = (New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate([System.Security.Principal.NTAccount]).Value
        return ($acct -split '\\')[-1]
    } catch { return '' }
}

# Deletes a file or folder. Junctions and symlinks are removed as links, never followed.
function Remove-ItemSafe([System.IO.FileSystemInfo]$Item) {
    if ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        if ($Item.PSIsContainer) { [System.IO.Directory]::Delete($Item.FullName) } else { [System.IO.File]::Delete($Item.FullName) }
        return
    }
    if ($Item.PSIsContainer) {
        foreach ($c in @(Get-ChildItem -LiteralPath $Item.FullName -Force -ErrorAction SilentlyContinue)) {
            try { Remove-ItemSafe $c } catch { $script:Failed = $script:Failed + 1 }
        }
        $Item.Attributes = [System.IO.FileAttributes]::Directory
        [System.IO.Directory]::Delete($Item.FullName)
    } else {
        $Item.Attributes = [System.IO.FileAttributes]::Normal
        [System.IO.File]::Delete($Item.FullName)
    }
}

# Deletes everything inside a folder and keeps the folder itself.
function Remove-FolderContents([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        if ($DryRun) { Write-Log ('would delete ' + $item.FullName); $script:Deleted = $script:Deleted + 1; continue }
        try { Remove-ItemSafe $item; $script:Deleted = $script:Deleted + 1 }
        catch { $script:Failed = $script:Failed + 1 }
    }
}

function Clear-Profile([string]$Root, [string]$Name, [string]$Sid) {
    if ($Root -notmatch $RootPattern) { Write-Log ('Refusing unexpected profile path: ' + $Root); return }
    $script:Deleted = 0
    $script:Failed = 0
    foreach ($rel in $UserFolders) { Remove-FolderContents ($Root + $Sep + $rel) }
    if ($Sid) { Remove-FolderContents ($Root.Substring(0, 2) + $Sep + '$Recycle.Bin' + $Sep + $Sid) }
    if (($script:Deleted + $script:Failed) -gt 0) {
        Write-Log ('Cleaned ' + $Name + ': ' + $script:Deleted + ' removed, ' + $script:Failed + ' failed')
    }
}

# Cleans the profile of every target user who has no session at all.
function Invoke-Sweep {
    $script:Skipped = 0
    foreach ($p in @(Get-CimInstance -ClassName Win32_UserProfile)) {
        if ($p.Special -or -not $p.LocalPath) { continue }
        $name = Get-AccountName $p.SID
        if (-not $name) { $name = Split-Path $p.LocalPath -Leaf }
        if (-not (Test-Target $name)) { continue }
        $users = @(Get-Sessions | ForEach-Object { $_.User })
        if ($users -contains $name) { continue }
        if ($p.Loaded) {
            Write-Log ('Skipped ' + $name + ': profile still loaded')
            $script:Skipped = $script:Skipped + 1
            continue
        }
        if (-not $DryRun) { Set-Content -LiteralPath $FlagFile -Value (Get-Date -Format s) }
        try { Clear-Profile $p.LocalPath $name $p.SID }
        finally { Remove-Item -LiteralPath $FlagFile -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-SweepRetry {
    for ($i = 1; $i -le 4; $i = $i + 1) {
        Invoke-Sweep
        if ($script:Skipped -eq 0) { return }
        if ($DryRun) { return }
        Start-Sleep -Seconds 15
    }
}

function Stop-UserSession($Session) {
    Write-Log ('Ending disconnected session ' + $Session.Id + ' of ' + $Session.User)
    if ($DryRun) { return }
    & logoff.exe $Session.Id 2>&1 | Out-Null
    for ($i = 0; $i -lt 20; $i = $i + 1) {
        Start-Sleep -Seconds 3
        $left = @(Get-Sessions | Where-Object { $_.Id -eq $Session.Id })
        if ($left.Count -eq 0) { return }
    }
    Write-Log 'Logoff did not finish, resetting the session'
    & reset.exe session $Session.Id 2>&1 | Out-Null
}

# Runs every minute: ends target sessions that stayed disconnected longer than the grace period.
function Invoke-Watch {
    $old = @{}
    if (Test-Path -LiteralPath $StateFile) {
        try { $old = Import-Clixml -LiteralPath $StateFile } catch { $old = @{} }
    }
    $new = @{}
    $now = Get-Date
    foreach ($sess in @(Get-Sessions)) {
        if ($sess.State -ne 'Disc') { continue }
        if (-not (Test-Target $sess.User)) { continue }
        $key = [string]$sess.Id
        $first = $now
        if ($old.ContainsKey($key)) { $first = [datetime]$old[$key] }
        if (($now - $first).TotalMinutes -ge $GraceMinutes) { Stop-UserSession $sess }
        else { $new[$key] = $first }
    }
    if (-not $DryRun) { Export-Clixml -InputObject $new -LiteralPath $StateFile }
    Invoke-SweepRetry
}

function Invoke-Startup {
    Remove-Item -LiteralPath $FlagFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    Write-Log 'Boot or shutdown cleanup'
    Invoke-SweepRetry
}

# Group Policy logoff script, runs as the user who signs out.
function Invoke-LogoffMode {
    if (-not (Test-Target $env:USERNAME)) { return }
    Clear-Profile $env:USERPROFILE $env:USERNAME ''
    if (-not $DryRun) { Clear-RecycleBin -Force -ErrorAction SilentlyContinue }
}

# Group Policy logon script: waits while a cleanup is still running, so a new session never starts mid-delete.
function Invoke-LogonGuard {
    for ($i = 0; $i -lt 30; $i = $i + 1) {
        if (-not (Test-Path -LiteralPath $FlagFile)) { return }
        Start-Sleep -Seconds 3
    }
    Write-Log 'Cleanup flag still present after 90 seconds, continuing'
}

# ----- main -----
if ($TargetUsers.Count -eq 0) {
    if ($Mode -ne 'Watch') { Write-Log 'No account listed in target-users.txt, nothing to do' }
    return
}
if ($Mode -eq 'Logoff') { Invoke-LogoffMode; return }
if ($Mode -eq 'Logon') { Invoke-LogonGuard; return }

$wait = 120000
if ($Mode -eq 'Watch') { $wait = 0 }
$mutex = New-Object System.Threading.Mutex($false, 'Global\SessionCleanupMutex')
$have = $false
try {
    try { $have = $mutex.WaitOne($wait) }
    catch [System.Threading.AbandonedMutexException] { $have = $true }
    if ($have) {
        if ($Mode -eq 'Watch') { Invoke-Watch } else { Invoke-Startup }
    }
}
catch { Write-Log ('UNEXPECTED ERROR: ' + $_.Exception.Message) }
finally {
    if ($have) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
