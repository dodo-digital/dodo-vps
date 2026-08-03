#requires -Version 5.1
<#
.SYNOPSIS
  Native Windows launcher for dodo-vps.

.DESCRIPTION
  Provisions a Hetzner Ubuntu VPS from Windows PowerShell 5.1 or PowerShell 7,
  then runs the shared Linux setup script on the server. No WSL or Git Bash is
  required.
#>

[CmdletBinding()]
param(
    [string]$HetznerToken = $env:HETZNER_TOKEN,
    [ValidateSet('cpx11', 'cpx21', 'cpx31', 'cpx41')]
    [string]$ServerType = 'cpx21',
    [ValidateSet('ash', 'hil', 'nbg1', 'hel1')]
    [string]$ServerLocation = 'ash',
    [ValidatePattern('^[a-z_][a-z0-9_-]{0,31}$')]
    [string]$UserName = 'ubuntu',
    [string]$ServerName = '',
    [string]$ExistingServerIp = '',
    [string]$SshKeyPath = '',
    [ValidateSet('true', 'false')]
    [string]$InstallDocker = 'true',
    [ValidateSet('true', 'false')]
    [string]$InstallClaudeCode = 'true',
    [ValidateSet('true', 'false')]
    [string]$InstallCodex = 'true',
    [ValidateSet('true', 'false')]
    [string]$InstallGeminiCli = 'true',
    [ValidateSet('true', 'false')]
    [string]$InstallOpenCode = 'true',
    [ValidateSet('true', 'false')]
    [string]$InstallBun = 'true',
    [ValidateSet('true', 'false')]
    [string]$InstallTailscale = 'false',
    [ValidatePattern('^(?!/)(?!.*(?:\.\.|//))(?!.*\/$)[A-Za-z0-9._/-]+$')]
    [string]$Channel = 'main',
    [switch]$NoWizard,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:RawBase = "https://raw.githubusercontent.com/dodo-digital/dodo-vps/$Channel"
$script:RemoteUser = 'root'
$script:IsResume = -not [string]::IsNullOrWhiteSpace($ExistingServerIp)

function Write-Step([string]$Message) {
    Write-Host "`n== $Message ==`n" -ForegroundColor Cyan
}

function Write-Info([string]$Message) {
    Write-Host '[dodo-vps] ' -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-Warn([string]$Message) {
    Write-Host '[warn] ' -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Stop-Setup([string]$Message) {
    throw $Message
}

function Test-RequiredCommands {
    $missing = @()
    foreach ($command in @('ssh', 'ssh-keygen')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            $missing += $command
        }
    }
    if ($missing.Count -gt 0) {
        Stop-Setup ("Missing Windows OpenSSH tools: {0}. Install 'OpenSSH Client' from Settings > Optional Features, then rerun." -f ($missing -join ', '))
    }
}

function Test-WindowsSupport {
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Stop-Setup 'PowerShell 5.1 or newer is required.'
    }
    Test-RequiredCommands
    Write-Info ("Compatibility check passed: Windows {0}, PowerShell {1}" -f [Environment]::OSVersion.Version, $PSVersionTable.PSVersion)
}

function Invoke-NativeQuiet([scriptblock]$Action) {
    $previousPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 can promote redirected native stderr into a
        # terminating NativeCommandError when the global preference is Stop.
        $ErrorActionPreference = 'Continue'
        & $Action 2>&1 | Out-Null
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Invoke-BackgroundJobWithTimeout(
    [scriptblock]$ScriptBlock,
    [object[]]$ArgumentList,
    [int]$TimeoutSeconds
) {
    $job = Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    try {
        $completedJob = Wait-Job -Job $job -Timeout $TimeoutSeconds
        if ($null -eq $completedJob) {
            Stop-Job -Job $job
            return [pscustomobject]@{
                ExitCode = 124
                TimedOut = $true
                StandardError = "SSH probe exceeded the $TimeoutSeconds-second timeout."
            }
        }

        $result = @(Receive-Job -Job $job)
        if ($result.Count -eq 0) {
            return [pscustomobject]@{
                ExitCode = 1
                TimedOut = $false
                StandardError = 'SSH probe ended without returning a result.'
            }
        }
        return $result[-1]
    }
    finally {
        if ($job.State -eq 'Running') { Stop-Job -Job $job }
        Remove-Job -Job $job -Force
    }
}

function Read-Secret([string]$Prompt) {
    $secure = Read-Host $Prompt -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Read-YesNo([string]$Prompt, [bool]$Default = $true) {
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = Read-Host "$Prompt $hint"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        if ($answer -match '^[Yy]') { return $true }
        if ($answer -match '^[Nn]') { return $false }
        Write-Host 'Please answer y or n.'
    }
}

function Invoke-HetznerApi([string]$Method, [string]$Endpoint, $Body = $null) {
    $headers = @{ Authorization = "Bearer $HetznerToken" }
    $parameters = @{
        Uri = "https://api.hetzner.cloud/v1$Endpoint"
        Method = $Method
        Headers = $headers
        ContentType = 'application/json'
        TimeoutSec = 30
    }
    if ($null -ne $Body) {
        $parameters.Body = ($Body | ConvertTo-Json -Depth 8 -Compress)
    }
    Invoke-RestMethod @parameters
}

function Test-HetznerToken {
    try {
        $null = Invoke-HetznerApi 'GET' '/servers'
        return $true
    }
    catch {
        Write-Warn ("Hetzner rejected the token or could not be reached: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Invoke-Wizard {
    Write-Host ''
    Write-Host 'Coding Agent VPS Setup for Windows' -ForegroundColor Green
    Write-Host 'This creates and secures an Ubuntu VPS, then installs your coding agents.'

    while ([string]::IsNullOrWhiteSpace($script:HetznerToken) -or -not (Test-HetznerToken)) {
        Write-Host ''
        Write-Host 'Create a Read & Write token at:'
        Write-Host 'https://console.hetzner.cloud/ > Project > Security > API Tokens' -ForegroundColor Blue
        $script:HetznerToken = Read-Secret 'Paste your Hetzner API token'
        if ([string]::IsNullOrWhiteSpace($script:HetznerToken)) {
            Write-Warn 'The token cannot be empty.'
        }
    }
    Write-Info 'Hetzner token accepted. It will not be saved to disk.'

    Write-Step 'Server size'
    Write-Host '1) Small       2 GB / 2 CPU'
    Write-Host '2) Medium      4 GB / 3 CPU (recommended)'
    Write-Host '3) Large       8 GB / 4 CPU'
    Write-Host '4) Extra Large 16 GB / 8 CPU'
    switch ((Read-Host 'Choice [2]')) {
        '1' { $script:ServerType = 'cpx11' }
        '3' { $script:ServerType = 'cpx31' }
        '4' { $script:ServerType = 'cpx41' }
        default { $script:ServerType = 'cpx21' }
    }

    Write-Step 'Server location'
    Write-Host '1) Ashburn, US   2) Hillsboro, US   3) Nuremberg, DE   4) Helsinki, FI'
    switch ((Read-Host 'Choice [1]')) {
        '2' { $script:ServerLocation = 'hil' }
        '3' { $script:ServerLocation = 'nbg1' }
        '4' { $script:ServerLocation = 'hel1' }
        default { $script:ServerLocation = 'ash' }
    }

    Write-Step 'Tools'
    $script:InstallClaudeCode = (Read-YesNo 'Install Claude Code?' $true).ToString().ToLowerInvariant()
    $script:InstallCodex = (Read-YesNo 'Install Codex?' $true).ToString().ToLowerInvariant()
    $script:InstallGeminiCli = (Read-YesNo 'Install Gemini CLI?' $true).ToString().ToLowerInvariant()
    $script:InstallOpenCode = (Read-YesNo 'Install OpenCode?' $true).ToString().ToLowerInvariant()
    $script:InstallDocker = (Read-YesNo 'Install Docker?' $true).ToString().ToLowerInvariant()
    $script:InstallTailscale = (Read-YesNo 'Install Tailscale?' $true).ToString().ToLowerInvariant()

    Write-Step 'Ready'
    Write-Host "Server: $ServerType in $ServerLocation"
    Write-Host "User: $UserName"
    if (-not (Read-YesNo 'Create the server and begin setup?' $true)) {
        Write-Host 'Cancelled.'
        exit 0
    }
}

function Initialize-SshKey {
    Write-Step 'SSH key'
    if ([string]::IsNullOrWhiteSpace($script:SshKeyPath)) {
        $script:SshKeyPath = Join-Path $HOME '.ssh\dodo-vps_ed25519'
    }
    if (-not [IO.Path]::IsPathRooted($SshKeyPath)) {
        $script:SshKeyPath = [IO.Path]::GetFullPath((Join-Path (Get-Location) $SshKeyPath))
    }
    if ($SshKeyPath.Contains('"')) {
        Stop-Setup 'SSH key paths cannot contain a double quote.'
    }
    $keyDirectory = Split-Path -Parent $SshKeyPath
    if (-not (Test-Path $keyDirectory)) {
        $null = New-Item -ItemType Directory -Path $keyDirectory -Force
    }

    if (Test-Path $SshKeyPath) {
        if (-not (Test-Path "$SshKeyPath.pub")) {
            $publicKey = & ssh-keygen -y -f $SshKeyPath
            if ($LASTEXITCODE -ne 0) { Stop-Setup 'Could not derive the public SSH key.' }
            Set-Content -Path "$SshKeyPath.pub" -Value $publicKey -Encoding ascii
        }
        Write-Info "Using existing SSH key: $SshKeyPath"
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($ExistingServerIp)) {
        Stop-Setup 'Resuming requires -SshKeyPath or the default dodo-vps key.'
    }

    # ProcessStartInfo preserves the empty -N argument under both legacy
    # Windows PowerShell 5.1 and PowerShell 7 native argument modes.
    $sshKeygen = (Get-Command ssh-keygen).Source
    $comment = "dodo-vps-{0}" -f (Get-Date -Format yyyyMMdd)
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $sshKeygen
    $processInfo.Arguments = "-t ed25519 -f `"$SshKeyPath`" -N `"`" -C `"$comment`""
    $processInfo.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($processInfo)
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { Stop-Setup 'SSH key generation failed.' }
    Write-Info "Created SSH key: $SshKeyPath"
}

function New-HetznerServer {
    Write-Step 'Create server'
    $publicKey = (Get-Content "$SshKeyPath.pub" -Raw).Trim()
    $keyName = 'dodo-vps-{0}' -f [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $sshKeyId = $null

    try {
        $keyResponse = Invoke-HetznerApi 'POST' '/ssh_keys' @{ name = $keyName; public_key = $publicKey }
        $sshKeyId = $keyResponse.ssh_key.id
    }
    catch {
        $statusCode = $null
        try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
        if ($statusCode -eq 401 -or $statusCode -eq 403) {
            Stop-Setup 'This Hetzner token cannot create resources. Generate a Read & Write project token and retry.'
        }
        $keys = Invoke-HetznerApi 'GET' '/ssh_keys'
        $existing = $keys.ssh_keys | Where-Object { $_.public_key.Trim() -eq $publicKey } | Select-Object -First 1
        if ($null -eq $existing) { throw }
        $sshKeyId = $existing.id
        Write-Info "Reusing Hetzner SSH key $sshKeyId"
    }

    if ([string]::IsNullOrWhiteSpace($script:ServerName)) {
        $script:ServerName = 'agent-vps-{0:x6}' -f (Get-Random -Minimum 0 -Maximum 16777215)
    }
    $response = Invoke-HetznerApi 'POST' '/servers' @{
        name = $ServerName
        server_type = $ServerType
        image = 'ubuntu-24.04'
        location = $ServerLocation
        ssh_keys = @([int]$sshKeyId)
        start_after_create = $true
    }
    $script:ExistingServerIp = $response.server.public_net.ipv4.ip
    if ([string]::IsNullOrWhiteSpace($ExistingServerIp)) { Stop-Setup 'Hetzner did not return a server IP.' }
    # Hetzner may reassign an IP from a deleted server. Clear a stale key only
    # when we just created the replacement; resume paths must reject changes.
    $null = Invoke-NativeQuiet { & ssh-keygen -R $ExistingServerIp }
    Write-Info "Server created: $ServerName ($ExistingServerIp)"
}

function Get-SshOptions {
    @(
        '-i', $SshKeyPath,
        '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'LogLevel=ERROR',
        '-o', 'ConnectTimeout=5',
        '-o', 'BatchMode=yes'
    )
}

function Invoke-SshProbe([string[]]$Options, [string]$Target) {
    $sshExecutable = (Get-Command ssh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $connection = [pscustomobject]@{
        Executable = $sshExecutable
        Options = @($Options)
        Target = $Target
    }
    $probeScript = {
        param($Connection)
        $ErrorActionPreference = 'Continue'
        $sshOptions = @($Connection.Options)
        $nativeOutput = @(& $Connection.Executable @sshOptions $Connection.Target 'echo ok' 2>&1)
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            TimedOut = $false
            StandardError = (($nativeOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
        }
    }
    Invoke-BackgroundJobWithTimeout $probeScript @(,$connection) 10
}

function Wait-ForServer {
    Write-Step 'Waiting for server'
    $options = Get-SshOptions
    $candidates = if ($IsResume) { @($UserName, 'root') } else { @('root') }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $lastSshError = ''
    for ($attempt = 1; $attempt -le 60 -and $stopwatch.Elapsed.TotalMinutes -lt 5; $attempt++) {
        foreach ($candidate in $candidates) {
            $probe = Invoke-SshProbe $options "$candidate@$ExistingServerIp"
            if ($probe.ExitCode -eq 0) {
                $script:RemoteUser = $candidate
                Write-Info "Server is ready (connecting as $RemoteUser)."
                return
            }
            $lastSshError = $probe.StandardError
        }
        Write-Host ("`rWaiting... {0}/60" -f $attempt) -NoNewline
        Start-Sleep -Seconds 5
    }
    $message = 'Server did not become reachable after five minutes. Check the Hetzner console.'
    if (-not [string]::IsNullOrWhiteSpace($lastSshError)) {
        $message += " Last SSH error: $lastSshError"
    }
    Stop-Setup $message
}

function Invoke-RemoteSetup {
    Write-Step 'Running setup on server'
    $options = Get-SshOptions
    $target = "$RemoteUser@$ExistingServerIp"
    $sudo = if ($RemoteUser -eq 'root') { '' } else { 'sudo ' }
    $scriptUrl = "$RawBase/setup.sh"

    if ($RemoteUser -ne 'root') {
        & ssh @options $target 'sudo -n true'
        if ($LASTEXITCODE -ne 0) {
            Stop-Setup 'The service user cannot run passwordless sudo. Use the Hetzner console to restore sudo access, then retry this same server.'
        }
    }

    $downloadCommand = "${sudo}curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 2 '$scriptUrl' -o /tmp/dodo-vps-setup.sh && ${sudo}chmod +x /tmp/dodo-vps-setup.sh"
    & ssh @options $target $downloadCommand
    if ($LASTEXITCODE -ne 0) {
        Write-RetryInstructions
        Stop-Setup 'Could not download the server setup script. No new VPS is needed.'
    }

    $environment = @(
        "NEW_USER=$UserName",
        "INSTALL_DOCKER=$InstallDocker",
        "INSTALL_CLAUDE_CODE=$InstallClaudeCode",
        "INSTALL_CODEX=$InstallCodex",
        "INSTALL_GEMINI_CLI=$InstallGeminiCli",
        "INSTALL_OPENCODE=$InstallOpenCode",
        "INSTALL_BUN=$InstallBun",
        "INSTALL_TAILSCALE=$InstallTailscale"
    ) -join ' '
    $runCommand = "${sudo}env $environment bash /tmp/dodo-vps-setup.sh --on-server"

    & ssh -t @options $target $runCommand
    if ($LASTEXITCODE -eq 0) { return }

    Write-Warn 'Server setup failed. Fetching the last 120 log lines.'
    & ssh @options $target "${sudo}tail -120 /var/log/dodo-vps-setup.log 2>/dev/null || true"
    Write-RetryInstructions
    Stop-Setup "Server setup failed. The VPS is still reachable at $target."
}

function Write-RetryInstructions {
    Write-Host ''
    Write-Host 'Retry this same server after a fix is pushed:' -ForegroundColor Yellow
    Write-Host '  Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/dodo-digital/dodo-vps/main/setup.ps1 -OutFile dodo-vps-setup.ps1'
    Write-Host ("  powershell -ExecutionPolicy Bypass -File .\dodo-vps-setup.ps1 -ExistingServerIp '{0}' -SshKeyPath '{1}' -UserName '{2}' -InstallDocker '{3}' -InstallClaudeCode '{4}' -InstallCodex '{5}' -InstallGeminiCli '{6}' -InstallOpenCode '{7}' -InstallBun '{8}' -InstallTailscale '{9}'" -f $ExistingServerIp, $SshKeyPath, $UserName, $InstallDocker, $InstallClaudeCode, $InstallCodex, $InstallGeminiCli, $InstallOpenCode, $InstallBun, $InstallTailscale)
}

function Set-SshShortcut([string]$SshDirectory = '') {
    if ([string]::IsNullOrWhiteSpace($SshDirectory)) {
        $SshDirectory = Join-Path $HOME '.ssh'
    }
    $configPath = Join-Path $sshDirectory 'config'
    if (-not (Test-Path $sshDirectory)) { $null = New-Item -ItemType Directory -Path $sshDirectory -Force }
    $existing = if (Test-Path $configPath) { Get-Content $configPath -Raw } else { '' }
    $aliasName = 'dodo-vps'
    if ($existing -match '(?im)^Host\s+dodo-vps\s*$') {
        $suffix = if ([string]::IsNullOrWhiteSpace($ServerName)) { $ExistingServerIp } else { $ServerName }
        $suffix = $suffix -replace '[^A-Za-z0-9_-]', '-'
        $aliasName = "dodo-vps-$suffix"
        Write-Warn "SSH shortcut 'dodo-vps' already exists; creating '$aliasName' for this server."
    }
    $identityPath = $SshKeyPath -replace '\\', '/'
    $block = @"

Host $aliasName
    HostName $ExistingServerIp
    User $UserName
    IdentityFile "$identityPath"
"@
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::AppendAllText($configPath, $block, $utf8NoBom)
    Write-Info "Added SSH shortcut. Connect with: ssh $aliasName"
    return $aliasName
}

function Start-DodoVps {
    try {
        Test-WindowsSupport
        if ($Check) { return }

        if ([string]::IsNullOrWhiteSpace($ExistingServerIp)) {
            if (-not $NoWizard) {
                Invoke-Wizard
            }
            else {
                if ([string]::IsNullOrWhiteSpace($HetznerToken)) { Stop-Setup '-HetznerToken or HETZNER_TOKEN is required with -NoWizard.' }
                if (-not (Test-HetznerToken)) { Stop-Setup 'Hetzner token validation failed.' }
            }
        }
        else {
            Write-Info "Resuming existing server $ExistingServerIp. No new VPS will be created."
        }

        Initialize-SshKey
        if ([string]::IsNullOrWhiteSpace($ExistingServerIp)) { New-HetznerServer }
        Wait-ForServer
        Invoke-RemoteSetup
        $shortcutName = Set-SshShortcut

        Write-Host ''
        Write-Host 'Setup complete.' -ForegroundColor Green
        Write-Host "Server: $ExistingServerIp"
        Write-Host "Connect: ssh $shortcutName"
        if ($InstallTailscale -eq 'true') {
            Write-Host 'Install the Windows Tailscale app with the same account: https://tailscale.com/download/windows'
        }
    }
    catch {
        Write-Host ''
        Write-Host '[error] ' -ForegroundColor Red -NoNewline
        Write-Host $_.Exception.Message
        exit 1
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Start-DodoVps
}
