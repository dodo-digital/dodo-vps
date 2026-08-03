$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'setup.ps1'
$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)

if ($parseErrors.Count -gt 0) {
    $parseErrors | ForEach-Object { Write-Error $_.Message }
    exit 1
}

& $scriptPath -Check

. $scriptPath

if ($InstallTailscale -ne 'false') {
    throw 'PowerShell headless Tailscale default drifted from the Bash launcher.'
}

# Exercise real Windows-native key generation and ssh_config parsing. The path
# contains spaces, which catches native argument and ssh_config quoting drift.
$nativeTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("dodo vps Jose-{0}" -f [Guid]::NewGuid())
$script:SshKeyPath = Join-Path $nativeTestRoot '.ssh\dodo-vps_ed25519'
$script:ExistingServerIp = ''
Initialize-SshKey
$keyExit = Invoke-NativeQuiet { & ssh-keygen -y -f $SshKeyPath }
if ($keyExit -ne 0) {
    throw 'Generated SSH key is passphrase-protected or unreadable.'
}
$script:ExistingServerIp = '203.0.113.19'
$script:UserName = 'ubuntu'
$script:ServerName = 'native-test'
$configDirectory = Join-Path $nativeTestRoot 'config-home'
$shortcut = Set-SshShortcut $configDirectory
$configPath = Join-Path $configDirectory 'config'
$previousPreference = $ErrorActionPreference
try {
    # Windows PowerShell 5.1 promotes harmless native stderr to a terminating
    # NativeCommandError when the global preference is Stop.
    $ErrorActionPreference = 'Continue'
    $configOutput = & ssh -F $configPath -G $shortcut 2>$null | Out-String
    $configExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousPreference
}
if ($configExitCode -ne 0) {
    throw "Generated SSH config failed to parse: $configOutput"
}
if ($configOutput -notmatch [regex]::Escape(($SshKeyPath -replace '\\', '/'))) {
    throw 'Generated SSH config did not preserve the identity path.'
}
$configBytes = [IO.File]::ReadAllBytes($configPath)
if ($configBytes.Length -ge 3 -and $configBytes[0] -eq 0xEF -and $configBytes[1] -eq 0xBB -and $configBytes[2] -eq 0xBF) {
    throw 'Generated SSH config has a UTF-8 BOM.'
}

$script:ExistingServerIp = '203.0.113.20'
$script:UserName = 'ubuntu'
$script:SshKeyPath = 'C:\Users\Test User\.ssh\dodo-vps_ed25519'
$script:RemoteUser = ''
$script:IsResume = $true
$script:SshCalls = New-Object System.Collections.Generic.List[object]

function global:ssh {
    $call = $args -join ' '
    [void]$script:SshCalls.Add(@($args))
    if ($call -match 'root@203\.0\.113\.20') {
        $global:LASTEXITCODE = 255
    }
    else {
        $global:LASTEXITCODE = 0
    }
}

Wait-ForServer
if ($RemoteUser -ne 'ubuntu') {
    throw "Resume selected '$RemoteUser' instead of the hardened service user."
}
$firstSshCall = $SshCalls[0]
$identityIndex = [Array]::IndexOf($firstSshCall, '-i')
if ($identityIndex -lt 0 -or $firstSshCall[$identityIndex + 1] -ne $SshKeyPath) {
    throw 'SSH key path with spaces was split into multiple arguments.'
}

$script:SshCalls.Clear()
Invoke-RemoteSetup
if (-not ($SshCalls | Where-Object { ($_ -join ' ') -match 'ubuntu@203\.0\.113\.20.*sudo env NEW_USER=ubuntu' })) {
    throw 'Resumed setup did not run through the service user with sudo.'
}
if (-not ($SshCalls | Where-Object { ($_ -join ' ') -match '--connect-timeout 10.*--max-time 60.*--retry 2' })) {
    throw 'Remote setup download does not have bounded timeout and retry behavior.'
}

$script:FailRemoteRun = $true
function global:ssh {
    $call = $args -join ' '
    [void]$script:SshCalls.Add(@($args))
    if ($call -match 'bash /tmp/dodo-vps-setup\.sh --on-server') {
        $global:LASTEXITCODE = 1
    }
    else {
        $global:LASTEXITCODE = 0
    }
}
$failureOutput = & {
    try {
        Invoke-RemoteSetup
    }
    catch {
        $_.Exception.Message
    }
} *>&1 | Out-String
if ($failureOutput -notmatch 'Invoke-WebRequest -UseBasicParsing .*main/setup\.ps1') {
    throw 'Failed remote setup did not print the fresh-launcher download command.'
}
if ($failureOutput -notmatch "ExistingServerIp '203\.0\.113\.20'") {
    throw 'Failed remote setup did not print the same-server retry command.'
}

$apiFunction = (Get-Command Invoke-HetznerApi).ScriptBlock.ToString()
if ($apiFunction -notmatch 'TimeoutSec\s*=\s*30') {
    throw 'Hetzner API calls are not bounded by a timeout.'
}

$sshOptions = Get-SshOptions
if ('StrictHostKeyChecking=accept-new' -notin $sshOptions) {
    throw 'SSH does not use accept-new host-key verification.'
}
if (($sshOptions -join ' ') -match 'StrictHostKeyChecking=no|UserKnownHostsFile=NUL') {
    throw 'SSH host-key verification is disabled.'
}
if ('IdentitiesOnly=yes' -notin $sshOptions) {
    throw 'SSH may offer unrelated agent keys and trigger MaxAuthTries/fail2ban.'
}

$script:SshCalls.Clear()
$script:IsResume = $true
function global:ssh {
    [void]$script:SshCalls.Add(@($args))
    $global:LASTEXITCODE = 255
}
function global:Start-Sleep { }
$timeoutOutput = & {
    try {
        Wait-ForServer
    }
    catch {
        $_.Exception.Message
    }
} *>&1 | Out-String
if ($SshCalls.Count -ne 120) {
    throw "Readiness timeout made $($SshCalls.Count) SSH attempts instead of 120."
}
if ($timeoutOutput -notmatch 'did not become reachable after five minutes') {
    throw 'Readiness timeout did not return the bounded five-minute error.'
}

Remove-Item Function:\ssh
Remove-Item Function:\Start-Sleep
Remove-Item -Recurse -Force $nativeTestRoot

Write-Host 'PowerShell compatibility checks passed.'
exit 0
