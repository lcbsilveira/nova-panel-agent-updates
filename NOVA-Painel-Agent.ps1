$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Security

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = Join-Path $root 'data'
$credentialFile = Join-Path $dataDir 'panel-access.dpapi'
$stateFile = Join-Path $dataDir 'panel-state.json'
$logFile = Join-Path $dataDir 'panel-agent.log'
$currentVersion = [version]'0.4.4'
$manifestUrl = 'https://raw.githubusercontent.com/lcbsilveira/nova-panel-agent-updates/main/manifest.json'
$trustedAgentUrl = 'https://raw.githubusercontent.com/lcbsilveira/nova-panel-agent-updates/main/NOVA-Painel-Agent.ps1'
$commandBaseUrl = 'https://raw.githubusercontent.com/lcbsilveira/nova-panel-agent-updates/main/commands'
$executedCommandsFile = Join-Path $dataDir 'executed-commands.json'
$reportedVersionFile = Join-Path $dataDir 'reported-version.txt'
$publicKeyBase64 = 'BgIAAACkAABSU0ExAAwAAAEAAQB93ntDk+N+FYbRSVXOgP0uNpqHJGffnU7qlHjAMIzGC7xlVReA4iCyszeAO94mBmqv5+2VGxTIaM/NINTWO0A1jnns3Uiolh/9pNK5cRFinS+3PILeV6frAJGp4N5QJX1ystyq7GfZylwYY5FP50ndGA8v20aXpwY13mJMQLZaQurEWKbJtZLWELClw1T8BUnsmBJY/wp4QXvg7XLmD9i48dVYRFiPz54cTATBLCONailgHS/t7buyCD54hgjuA8Psh6L6UpK+jL2anTXfcoN3EDF0bEs7VKMxiifd0Y1SNF3WUvgm5alqPklv23f7j9ceMX/gVxloihhe8OdjbOV/sIGYl0kJUH5+SZ5IziZ0z6MyGAvA4Su+fsV+NsGsllJJIgzLO2ZUpdOve3nNVfVPyUvLoQ6yBX632jMYsFupOV/tORhhfOSJpYIUko/Evl24R+1epNH0/hObEn0WkdKX1YRJCrnUQXc1e4QMQHGNHiNuovxmaiJCF0soA7yui8U='
[System.IO.Directory]::CreateDirectory($dataDir) | Out-Null

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\NOVAPanelAgent', [ref]$created)
if (-not $created) { exit 0 }

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class NovaWindow {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
}
'@

function Write-Log([string]$text) {
    $line = ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $text)
    [System.IO.File]::AppendAllText($logFile, $line + [Environment]::NewLine)
}

function Read-Credential {
    if (-not (Test-Path -LiteralPath $credentialFile)) { throw 'Credencial ausente.' }
    $protected = [Convert]::FromBase64String([System.IO.File]::ReadAllText($credentialFile).Trim())
    $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return ([System.Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json)
}

function Send-Telegram([string]$text) {
    try {
        $body = @{ chat_id = $script:config.chat_id; text = $text }
        Invoke-RestMethod -Method Post -Uri ("https://api.telegram.org/bot{0}/sendMessage" -f $script:config.token) -Body $body -TimeoutSec 20 | Out-Null
        Write-Log ('Telegram enviado: ' + $text)
    } catch {
        Write-Log ('Falha Telegram: ' + $_.Exception.Message)
    }
}

function ConvertTo-PanelSlug([string]$value) {
    $normalized = $value.Normalize([Text.NormalizationForm]::FormD)
    $builder = New-Object Text.StringBuilder
    foreach ($character in $normalized.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($character) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($character)
        }
    }
    $slug = $builder.ToString().Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant()
    $slug = [regex]::Replace($slug, '[^a-z0-9]+', '-')
    return $slug.Trim('-')
}

function Test-CommandSignature($command) {
    try {
        $canonical = '{0}|{1}|{2}|{3}|{4}' -f $command.id, $command.target, $command.action, $command.issued_at, $command.expires_at
        $bytes = [Text.Encoding]::UTF8.GetBytes($canonical)
        $signature = [Convert]::FromBase64String([string]$command.signature)
        $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
        $rsa.PersistKeyInCsp = $false
        $rsa.ImportCspBlob([Convert]::FromBase64String($publicKeyBase64))
        return $rsa.VerifyData($bytes, 'SHA256', $signature)
    } catch { return $false }
}

function Read-ExecutedCommands {
    if (-not (Test-Path -LiteralPath $executedCommandsFile)) { return @() }
    try { return @((Get-Content -LiteralPath $executedCommandsFile -Raw | ConvertFrom-Json)) } catch { return @() }
}

function Test-RemoteCommand {
    try {
        $slug = ConvertTo-PanelSlug ([string]$script:config.panel_name)
        if (-not $slug) { return }
        $uri = "$commandBaseUrl/$slug.json?ts=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
        $client = New-Object Net.WebClient
        $client.Headers['User-Agent'] = 'NOVA-Panel-Agent'
        $command = $client.DownloadString($uri) | ConvertFrom-Json
        if (-not $command.id -or [string]$command.target -ne [string]$script:config.panel_name) { return }
        if ([string]$command.action -notin @('restart','cancel_restart')) { return }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ([int64]$command.issued_at -gt ($now + 30) -or [int64]$command.expires_at -lt $now) { return }
        if (-not (Test-CommandSignature $command)) { Write-Log 'Comando remoto com assinatura invalida ignorado.'; return }
        $executed = @(Read-ExecutedCommands)
        if ($executed -contains [string]$command.id) { return }
        $executed = @($executed + [string]$command.id | Select-Object -Last 100)
        $executed | ConvertTo-Json | Set-Content -LiteralPath $executedCommandsFile -Encoding UTF8

        if ([string]$command.action -eq 'restart') {
            Send-Telegram ("REINICIO - {0}`nComando assinado recebido. O computador sera reiniciado em 30 segundos." -f $script:config.panel_name)
            Start-Process "$env:SystemRoot\System32\shutdown.exe" -ArgumentList @('/r','/t','30','/c','Reinicio solicitado pela NOVA Core') -WindowStyle Hidden
        } else {
            Start-Process "$env:SystemRoot\System32\shutdown.exe" -ArgumentList '/a' -WindowStyle Hidden
            Send-Telegram ("CANCELADO - {0}`nA reinicializacao foi cancelada." -f $script:config.panel_name)
        }
    } catch {
        if ($_.Exception.Message -notmatch '404|not found') { Write-Log ('Falha ao consultar comando remoto: ' + $_.Exception.Message) }
    }
}

function Test-AutoUpdate {
    try {
        $client = New-Object System.Net.WebClient
        $client.Headers['User-Agent'] = 'NOVA-Panel-Agent'
        $manifest = $client.DownloadString($manifestUrl) | ConvertFrom-Json
        if ([version]$manifest.version -le $currentVersion) { return $false }
        if ([string]$manifest.url -ne $trustedAgentUrl) { throw 'Endereco de atualizacao nao autorizado.' }
        $newBytes = $client.DownloadData($trustedAgentUrl)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hash = (($sha.ComputeHash($newBytes) | ForEach-Object { $_.ToString('x2') }) -join '')
        if ($hash -ne [string]$manifest.sha256) { throw 'Hash da atualizacao invalido.' }
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
        $rsa.PersistKeyInCsp = $false
        $rsa.ImportCspBlob([Convert]::FromBase64String($publicKeyBase64))
        $signature = [Convert]::FromBase64String([string]$manifest.signature)
        if (-not $rsa.VerifyData($newBytes, 'SHA256', $signature)) { throw 'Assinatura da atualizacao invalida.' }

        $scriptPath = $MyInvocation.ScriptName
        if (-not $scriptPath) { $scriptPath = $PSCommandPath }
        $backupPath = $scriptPath + '.previous'
        Copy-Item -LiteralPath $scriptPath -Destination $backupPath -Force
        [System.IO.File]::WriteAllBytes($scriptPath, $newBytes)
        Send-Telegram ("ATUALIZADO - {0}`nAgente NOVA atualizado para v{1}." -f $script:config.panel_name, $manifest.version)
        # O processo atual ainda possui o mutex do agente. Reiniciar imediatamente
        # faria a nova copia encerrar antes que esse mutex fosse liberado.
        # A tarefa agendada e acionada alguns segundos depois, quando este processo
        # ja tiver terminado.
        $restartTask = "Start-Sleep -Seconds 5; Start-ScheduledTask -TaskName 'NOVA Painel Agent'"
        $restartEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($restartTask))
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-EncodedCommand',$restartEncoded)
        return $true
    } catch {
        Write-Log ('Falha na atualizacao automatica: ' + $_.Exception.Message)
        return $false
    }
}

function Get-ForegroundIssue {
    $handle = [NovaWindow]::GetForegroundWindow()
    if ($handle -eq [IntPtr]::Zero) { return $null }
    $builder = New-Object System.Text.StringBuilder 512
    [void][NovaWindow]::GetWindowText($handle, $builder, $builder.Capacity)
    [uint32]$pidValue = 0
    [void][NovaWindow]::GetWindowThreadProcessId($handle, [ref]$pidValue)
    $title = $builder.ToString().Trim()
    $process = (Get-Process -Id $pidValue -ErrorAction SilentlyContinue).ProcessName
    $combined = ($process + ' ' + $title).ToLowerInvariant()
    $patterns = @(
        'windows update', 'reiniciar para atualizar', 'restart required',
        'terminar de configurar', 'finish setting up', 'vamos concluir',
        'windows backup', 'backup do windows', 'file history', 'historico de arquivos',
        'microsoft account problem', 'problema com a conta microsoft',
        'onedrive.*backup', 'fazer backup das pastas'
    )
    foreach ($pattern in $patterns) {
        if ($combined -match $pattern) {
            return @{ key = 'window:' + $process + ':' + $title; message = "Aviso visivel na tela: $title" }
        }
    }
    return $null
}

function Get-DisruptiveWindowIssues {
    $issues = @{}
    $processPatterns = @(
        '^taskmgr$', '^widgets$', '^widgetservice$', '^searchhost$',
        '^startmenuexperiencehost$', '^systemsettings$', '^applicationframehost$'
    )
    $titlePatterns = @(
        'gerenciador de tarefas', 'task manager', 'widgets',
        'configuracoes', 'settings', 'windows update',
        'terminar de configurar', 'finish setting up',
        '^erro$', '^error$', 'warning', 'aviso', 'atencao', 'attention'
    )
    # EBClient usa o EdgeBrowser/CEF internamente para renderizar as midias.
    $allowedProcessPatterns = @('^ebclient$', '^edgebrowser', '^cef', '^teamviewer', '^tv_')
    foreach ($process in Get-Process -ErrorAction SilentlyContinue) {
        $handle = $process.MainWindowHandle
        if ($handle -eq [IntPtr]::Zero) { continue }
        if (-not [NovaWindow]::IsWindowVisible($handle) -or [NovaWindow]::IsIconic($handle)) { continue }
        $name = [string]$process.ProcessName
        $title = [string]$process.MainWindowTitle
        $combined = ($name + ' ' + $title).ToLowerInvariant()
        $isDisruptive = $false
        foreach ($pattern in $processPatterns) { if ($name -match $pattern) { $isDisruptive = $true; break } }
        if (-not $isDisruptive) {
            foreach ($pattern in $titlePatterns) {
                if ($combined -match $pattern -or $title.ToLowerInvariant() -match $pattern) { $isDisruptive = $true; break }
            }
        }
        # O EBClient e o exibidor esperado. O TeamViewer e ignorado para que o
        # acesso de manutencao nao gere falso alerta. Qualquer outra janela com
        # titulo visivel e tratada como interferencia sobre a midia.
        if (-not $isDisruptive -and $title.Trim()) {
            $isAllowed = $false
            foreach ($pattern in $allowedProcessPatterns) { if ($name -match $pattern) { $isAllowed = $true; break } }
            if (-not $isAllowed) { $isDisruptive = $true }
        }
        if ($isDisruptive) {
            $label = if ($title.Trim()) { $title.Trim() } else { $name }
            $key = 'disruptive:' + $name.ToLowerInvariant()
            $issues[$key] = "Uma janela do Windows esta cobrindo a exibicao: $label."
        }
    }
    return $issues
}

function Test-PendingReboot {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    )
    foreach ($path in $paths) { if (Test-Path $path) { return $true } }
    $session = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $value = (Get-ItemProperty -Path $session -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    return $null -ne $value
}

function Get-HealthIssues {
    $issues = @{}
    if (Test-PendingReboot) {
        $issues.pending_reboot = 'O Windows esta aguardando uma reinicializacao.'
    }
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    if ($disk -and $disk.Size -gt 0) {
        $freeGb = [math]::Round($disk.FreeSpace / 1GB, 1)
        $freePercent = [math]::Round(($disk.FreeSpace / $disk.Size) * 100)
        if ($freeGb -lt 5 -or $freePercent -lt 10) {
            $issues.disk = "Pouco espaco no disco C: $freeGb GB livres ($freePercent%)."
        }
    }
    $defender = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($defender -and (-not $defender.AntivirusEnabled -or -not $defender.RealTimeProtectionEnabled)) {
        $issues.defender = 'A protecao em tempo real do Windows esta desativada.'
    }
    try {
        $updateSession = New-Object -ComObject Microsoft.Update.Session
        $updateSearcher = $updateSession.CreateUpdateSearcher()
        $updateResult = $updateSearcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
        $updateCount = [int]$updateResult.Updates.Count
        if ($updateCount -gt 0) {
            $issues.windows_updates = "O Windows Update encontrou $updateCount atualizacao(oes) pendente(s)."
        }
    } catch {
        Write-Log ('Falha ao consultar Windows Update: ' + $_.Exception.Message)
    }
    return $issues
}

try { $script:config = Read-Credential } catch { Write-Log $_.Exception.Message; exit 2 }
$reportedVersion = ''
if (Test-Path -LiteralPath $reportedVersionFile) {
    $reportedVersion = ([IO.File]::ReadAllText($reportedVersionFile)).Trim()
}
if ($reportedVersion -ne $currentVersion.ToString()) {
    Send-Telegram ("AGENTE ATIVO - {0}`nVersao {1}. Monitoramento e comandos remotos ativos." -f $script:config.panel_name, $currentVersion)
    [IO.File]::WriteAllText($reportedVersionFile, $currentVersion.ToString())
}
$active = @{}
if (Test-Path -LiteralPath $stateFile) {
    try {
        $saved = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        foreach ($property in $saved.PSObject.Properties) { $active[$property.Name] = [string]$property.Value }
    } catch { $active = @{} }
}

$lastHealthCheck = [datetime]::MinValue
$lastUpdateCheck = [datetime]::MinValue
$lastCommandCheck = [datetime]::MinValue
while ($true) {
    if (((Get-Date) - $lastUpdateCheck).TotalHours -ge 6) {
        $lastUpdateCheck = Get-Date
        if (Test-AutoUpdate) { exit 0 }
    }
    if (((Get-Date) - $lastCommandCheck).TotalSeconds -ge 30) {
        $lastCommandCheck = Get-Date
        Test-RemoteCommand
    }
    $current = @{}
    $windowIssue = Get-ForegroundIssue
    if ($windowIssue) { $current[$windowIssue.key] = $windowIssue.message }
    $disruptiveWindows = Get-DisruptiveWindowIssues
    foreach ($key in $disruptiveWindows.Keys) { $current[$key] = $disruptiveWindows[$key] }
    if (((Get-Date) - $lastHealthCheck).TotalMinutes -ge 10) {
        $health = Get-HealthIssues
        foreach ($key in $health.Keys) { $current[$key] = $health[$key] }
        $lastHealthCheck = Get-Date
    } else {
        foreach ($key in $active.Keys) {
            if ($key -notlike 'window:*') { $current[$key] = $active[$key] }
        }
    }
    foreach ($key in $current.Keys) {
        if (-not $active.ContainsKey($key)) {
            Send-Telegram ("ALERTA - {0}`n{1}" -f $script:config.panel_name, $current[$key])
        }
    }
    foreach ($key in @($active.Keys)) {
        if (-not $current.ContainsKey($key) -and $key -notlike 'window:*') {
            Send-Telegram ("RESOLVIDO - {0}`n{1}" -f $script:config.panel_name, $active[$key])
        }
    }
    $active = $current
    ($active | ConvertTo-Json) | Set-Content -LiteralPath $stateFile -Encoding UTF8
    Start-Sleep -Seconds 15
}
