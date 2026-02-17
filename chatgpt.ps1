# ==============================
# ChatGPT API PowerShell client
# ==============================
# Requirements:
#   1) Set environment variable OPENAI_API_KEY
#      PowerShell:
#      setx OPENAI_API_KEY "YOUR_API_KEY"
#      (restart terminal after setting)
# ==============================

$apiKey = $env:OPENAI_API_KEY
if (-not $apiKey) {
    Write-Error 'OPENAI_API_KEY not set. use command via Powershell and restart terminal: setx OPENAI_API_KEY "YOUR_API_KEY"'
    exit 1
}

$script:ttsEnabled = $false

Add-Type -AssemblyName System.Speech

$uri = "https://api.openai.com/v1/responses"

$sessionTime = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$logFile = ".\chat_$sessionTime.log"
$memoryFile = ".\memory.txt"
if (!(Test-Path $memoryFile)) {
    New-Item $memoryFile -ItemType File | Out-Null
}
$cacheFile = ".\cache.json"
$memoryMaxLines = 100

# notes support
$notesFile = ".\notes.txt"
if (!(Test-Path $notesFile)) { New-Item $notesFile -ItemType File | Out-Null }
$diagnosticsContextFile = ".\diagnostics_context.txt"
if (!(Test-Path $diagnosticsContextFile)) { New-Item $diagnosticsContextFile -ItemType File | Out-Null }
$commandsHistoryFile = ".\commands_history.log"
if (!(Test-Path $commandsHistoryFile)) { New-Item $commandsHistoryFile -ItemType File | Out-Null }
$script:noteMode = $false

$script:conversation = @()
$script:cache = @{}
$script:contextFingerprint = ""

if (Test-Path $cacheFile) {
    $script:cache = Get-Content $cacheFile | ConvertFrom-Json -AsHashtable
}

function TimeNow { (Get-Date).ToString("HH:mm:ss") }

function Log($text) {
    Add-Content $logFile $text
}

function Speak($text) {
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer

    $voices = $synth.GetInstalledVoices()
    foreach ($v in $voices) {
        if ($v.VoiceInfo.Culture -like "cs-*") {
            $synth.SelectVoice($v.VoiceInfo.Name)
            break
        }
    }

    $synth.SpeakAsync($text) | Out-Null
}

function VoiceInput {
    try {
        Add-Type -AssemblyName System.Speech
        $rec = New-Object System.Speech.Recognition.SpeechRecognitionEngine
        $rec.SetInputToDefaultAudioDevice()
        $rec.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
        Write-Host "Mluv..."
        $r = $rec.Recognize()
        return $r.Text
    } catch {
        Write-Host "Voice failed"
        return ""
    }
}

function LoadMemory {
    if (Test-Path $memoryFile) {
        return Get-Content $memoryFile -Raw
    }
    return ""
}

function LoadDiagnosticsContext([int]$maxChars = 6000) {
    if (!(Test-Path $diagnosticsContextFile)) { return "" }
    $raw = Get-Content $diagnosticsContextFile -Raw
    if (-not $raw) { return "" }
    if ($raw.Length -le $maxChars) { return $raw }
    return $raw.Substring($raw.Length - $maxChars)
}

function LoadCommandsHistory([int]$maxChars = 2500) {
    if (!(Test-Path $commandsHistoryFile)) { return "" }
    $raw = Get-Content $commandsHistoryFile -Raw
    if (-not $raw) { return "" }
    if ($raw.Length -le $maxChars) { return $raw }
    return $raw.Substring($raw.Length - $maxChars)
}

function Get-ContextFingerprint {
    $memStamp = 0
    $diagStamp = 0
    $cmdStamp = 0
    if (Test-Path $memoryFile) { $memStamp = (Get-Item $memoryFile).LastWriteTimeUtc.Ticks }
    if (Test-Path $diagnosticsContextFile) { $diagStamp = (Get-Item $diagnosticsContextFile).LastWriteTimeUtc.Ticks }
    if (Test-Path $commandsHistoryFile) { $cmdStamp = (Get-Item $commandsHistoryFile).LastWriteTimeUtc.Ticks }
    return "$memStamp-$diagStamp-$cmdStamp"
}

function Build-SystemPrompt {
    $memory = LoadMemory
    $diagContext = LoadDiagnosticsContext
    $recentCommands = LoadCommandsHistory
    if (-not $diagContext) { $diagContext = "Zatím bez diagnostického souhrnu." }
    if (-not $recentCommands) { $recentCommands = "Zatím bez historie příkazů." }

    return @"
Jsi CLI admin copilot. Pomáhej stručně, technicky a prakticky.
Paměť uživatele:
$memory

Kontext posledních diagnostik a důležitých kroků:
$diagContext

Nedávno použité příkazy (pro navázání kontextu):
$recentCommands
"@
}

function Refresh-SystemPromptInConversation {
    $prompt = Build-SystemPrompt
    $script:contextFingerprint = Get-ContextFingerprint

    if ($script:conversation.Count -gt 0 -and $script:conversation[0].role -eq "system") {
        $script:conversation[0] = @{ role="system"; content=$prompt }
    } else {
        $script:conversation = @(@{ role="system"; content=$prompt }) + $script:conversation
    }
}

function Log-UserCommand($text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    Add-Content $commandsHistoryFile "[$(Get-Date -Format s)] INPUT: $text"
}

function SaveCache {
    $script:cache | ConvertTo-Json | Set-Content $cacheFile
}

function ExtractText($response) {
    $out = @()
    foreach ($m in $response.output) {
        foreach ($p in $m.content) {
            if ($p.type -eq "output_text") {
                $out += $p.text
            }
        }
    }
    return ($out -join "`n").Trim()
}

function SummarizeIfLong {
    if ($script:conversation.Count -lt 20) { return }

    Write-Host "Shrnuji historii..."
    $summary = Ask-ChatGPT "Shrň dosavadní konverzaci stručně do paměti. Ignoruj dočasné informace jako den, čas nebo náladu. Zachovej veškeré informace o uživateli, dělej mu postupné CV celého jeho života. Zaznamenávej veškerá zařízení, které uživatel kdy použil."
    Add-Content $memoryFile "`n$summary`n"
    $script:conversation = @()
    Refresh-SystemPromptInConversation
}
function OptimizeMemory {

    if (!(Test-Path $memoryFile)) { return }

    $lines = Get-Content $memoryFile |
             Where-Object { $_.Trim() -ne "" } |
             Select-Object -Unique

    if ($lines.Count -lt $memoryMaxLines) { return }

    Write-Host "[Optimalizuji paměť...]" -ForegroundColor DarkYellow

    $joined = $lines -join "`n"

    $prompt = @"
Shrň následující informace do krátké dlouhodobé paměti uživatele.
Odstraň duplicity a zachovej jen důležité informace.
Výstup napiš jako několik stručných vět.

$joined
"@

    $body = @{
        model="gpt-5.2"
        input=$prompt
    } | ConvertTo-Json -Depth 5

    $response = Invoke-RestMethod -Method Post -Uri $uri -Headers @{
        Authorization = "Bearer $apiKey"
        "Content-Type"="application/json"
    } -Body $body

    $text = ""
    foreach ($m in $response.output) {
        foreach ($p in $m.content) {
            if ($p.type -eq "output_text") {
                $text += $p.text
            }
        }
    }

    # 🔥 přepsání celé paměti
    Set-Content $memoryFile $text.Trim()

    Write-Host "[Paměť přepsána optimalizovanou verzí]" -ForegroundColor DarkYellow
}


function StreamRequest($bodyJson) {
    $client = [System.Net.Http.HttpClient]::new()
    $req = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Post,
        $uri
    )

    $req.Headers.Add("Authorization", "Bearer $apiKey")
    $req.Content = [System.Net.Http.StringContent]::new(
        $bodyJson,
        [Text.Encoding]::UTF8,
        "application/json"
    )

    $resp = $client.SendAsync(
        $req,
        [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
    ).Result

    $stream = $resp.Content.ReadAsStreamAsync().Result
    $reader = New-Object System.IO.StreamReader($stream)

    $full = ""
    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if ($line) { $full += $line }
    }

    return $full
}

function Ask-ChatGPT($prompt) {
    Refresh-SystemPromptInConversation
    $cacheKey = "$($script:contextFingerprint)||$prompt"

    if ($script:cache.ContainsKey($cacheKey)) {
        return $script:cache[$cacheKey]
    }

    $script:conversation += @{ role="user"; content=$prompt }

    $body = @{
        model="gpt-5.2"
        input=$script:conversation
    } | ConvertTo-Json -Depth 10

    $raw = StreamRequest $body
    $response = $raw | ConvertFrom-Json

    $answer = ExtractText $response

    $script:conversation += @{ role="assistant"; content=$answer }

    $script:cache[$cacheKey] = $answer
    SaveCache

    SummarizeIfLong

    return $answer
}

function AnalyzeFile($path) {
    if (-not (Test-Path $path)) {
        Write-Host "Soubor nenalezen"
        return
    }

    $content = Get-Content $path -Raw
    Ask-ChatGPT "Analyzuj tento obsah:`n$content"
}

function Add-Note($text) {
    # Use ChatGPT to create a concise summary of the note
    $prompt = "Shrň následující poznámku uživatele stručně tak, aby se hodila do osobních poznámek nebo TODO listu:`n$text"
    $summary = Ask-ChatGPT $prompt
    Add-Content $notesFile $summary
    Write-Host "[Poznámka uložena]: $summary" -ForegroundColor Yellow
}

function Invoke-OpenAIText($prompt, $model = "gpt-5.2") {
    $body = @{
        model = $model
        input = $prompt
    } | ConvertTo-Json -Depth 10

    $response = Invoke-RestMethod -Method Post -Uri $uri -Headers @{
        Authorization = "Bearer $apiKey"
        "Content-Type" = "application/json"
    } -Body $body

    return (ExtractText $response)
}

function Save-CommandOutput($outputPath, [scriptblock]$commandBlock) {
    try {
        & $commandBlock 2>&1 | Out-File -FilePath $outputPath -Encoding UTF8 -Width 4096
    } catch {
        "Command failed: $($_.Exception.Message)" | Out-File -FilePath $outputPath -Encoding UTF8
    }
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NormalizedFixCommand($command) {
    if ([string]::IsNullOrWhiteSpace($command)) { return "" }
    return ($command.Trim() -replace '^(?i)sudo\s+', '')
}

function Test-SudoAvailable {
    return [bool](Get-Command sudo -ErrorAction SilentlyContinue)
}

function Get-DangerousPatternHit($command) {
    if ([string]::IsNullOrWhiteSpace($command)) { return $null }
    $normalizedCommand = Get-NormalizedFixCommand $command
    $blockedPatterns = @(
        '(?im)(?:^|[;|&]\s*)format(?:\.com|\.exe)?(?:\s|$)',
        '(?i)\bdiskpart\b',
        '(?i)\bvssadmin\s+delete\b',
        '(?i)\bcipher\s+/w\b',
        '(?i)\bshutdown\b',
        '(?i)\bstop-computer\b',
        '(?i)\brestart-computer\b',
        '(?i)\brd\s+/s\b',
        '(?i)\bdel\s+/[sq]\b',
        '(?i)\bremove-item\b.*\brecurse\b'
    )

    foreach ($pattern in $blockedPatterns) {
        if ($normalizedCommand -match $pattern) { return $pattern }
    }
    return $null
}

function Collect-WindowsDiagnostics($userIssue = "") {
    $baseDir = Join-Path (Get-Location) "diagnostics"
    if (!(Test-Path $baseDir)) { New-Item -ItemType Directory -Path $baseDir | Out-Null }

    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $diagDir = Join-Path $baseDir "diag_$stamp"
    $reportsDir = Join-Path $diagDir "reports"
    $logsDir = Join-Path $diagDir "logs"
    $registryDir = Join-Path $diagDir "registry"
    $dumpsDir = Join-Path $diagDir "dumps"
    $tempDir = Join-Path $diagDir "temp"

    foreach ($dir in @($diagDir, $reportsDir, $logsDir, $registryDir, $dumpsDir, $tempDir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    "Timestamp: $(Get-Date -Format s)" | Set-Content (Join-Path $diagDir "meta.txt")
    "User issue: $userIssue" | Add-Content (Join-Path $diagDir "meta.txt")
    "IsAdmin: $(Test-IsAdmin)" | Add-Content (Join-Path $diagDir "meta.txt")

    Save-CommandOutput (Join-Path $reportsDir "systeminfo.txt") { systeminfo }
    Save-CommandOutput (Join-Path $reportsDir "computerinfo.txt") { Get-ComputerInfo }
    Save-CommandOutput (Join-Path $reportsDir "driverquery.txt") { driverquery /v }
    Save-CommandOutput (Join-Path $reportsDir "services.txt") { Get-Service | Sort-Object Status,DisplayName | Format-Table -AutoSize }
    Save-CommandOutput (Join-Path $reportsDir "ipconfig_all.txt") { ipconfig /all }
    Save-CommandOutput (Join-Path $reportsDir "hotfixes.txt") { Get-HotFix | Sort-Object InstalledOn -Descending | Format-Table -AutoSize }
    Save-CommandOutput (Join-Path $reportsDir "processes_top_cpu.txt") { Get-Process | Sort-Object CPU -Descending | Select-Object -First 100 Name,Id,CPU,WS,Path }
    Save-CommandOutput (Join-Path $reportsDir "startup_commands.txt") { Get-CimInstance Win32_StartupCommand | Select-Object Name,Command,Location,User | Format-Table -AutoSize }
    Save-CommandOutput (Join-Path $reportsDir "reliability_recent.txt") { Get-WinEvent -LogName "Microsoft-Windows-Reliability-Operational" -MaxEvents 200 | Select-Object TimeCreated,Id,LevelDisplayName,Message }

    Save-CommandOutput (Join-Path $tempDir "temp_listing.txt") {
        Get-ChildItem -Path $env:TEMP -Force -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 500 FullName, Length, LastWriteTime
    }

    $eventLogs = @("System", "Application", "Setup")
    foreach ($logName in $eventLogs) {
        try {
            wevtutil epl $logName (Join-Path $logsDir "$logName.evtx") /ow:true | Out-Null
        } catch {
            "Export failed for ${logName}: $($_.Exception.Message)" | Out-File (Join-Path $logsDir "$logName.error.txt")
        }
    }

    foreach ($file in @("C:\Windows\Logs\CBS\CBS.log", "C:\Windows\Logs\DISM\dism.log")) {
        if (Test-Path $file) {
            Copy-Item $file -Destination $logsDir -Force -ErrorAction SilentlyContinue
        }
    }

    $minidumpPath = "C:\Windows\Minidump"
    if (Test-Path $minidumpPath) {
        Copy-Item (Join-Path $minidumpPath "*.dmp") -Destination $dumpsDir -Force -ErrorAction SilentlyContinue
    }

    $memoryDump = "C:\Windows\MEMORY.DMP"
    if (Test-Path $memoryDump) {
        Save-CommandOutput (Join-Path $dumpsDir "memory_dmp_metadata.txt") {
            Get-Item $memoryDump | Select-Object FullName,Length,CreationTime,LastWriteTime
        }
    }

    try { reg export "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" (Join-Path $registryDir "uninstall_hklm.reg") /y | Out-Null } catch {}
    try { reg export "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" (Join-Path $registryDir "run_hkcu.reg") /y | Out-Null } catch {}
    try { reg export "HKLM\Software\Microsoft\Windows\CurrentVersion\Run" (Join-Path $registryDir "run_hklm.reg") /y | Out-Null } catch {}

    return $diagDir
}

function Build-DiagnosticsContext($diagDir) {
    $reportFiles = @(
        (Join-Path $diagDir "meta.txt"),
        (Join-Path $diagDir "reports\systeminfo.txt"),
        (Join-Path $diagDir "reports\computerinfo.txt"),
        (Join-Path $diagDir "reports\driverquery.txt"),
        (Join-Path $diagDir "reports\services.txt"),
        (Join-Path $diagDir "reports\hotfixes.txt"),
        (Join-Path $diagDir "reports\reliability_recent.txt"),
        (Join-Path $diagDir "temp\temp_listing.txt"),
        (Join-Path $diagDir "logs\CBS.log"),
        (Join-Path $diagDir "logs\dism.log")
    )

    $maxChars = 120000
    $builder = New-Object System.Text.StringBuilder

    foreach ($file in $reportFiles) {
        if (!(Test-Path $file)) { continue }
        if ($builder.Length -ge $maxChars) { break }

        $raw = Get-Content $file -Raw -ErrorAction SilentlyContinue
        if (-not $raw) { continue }

        $remaining = $maxChars - $builder.Length
        if ($raw.Length -gt $remaining) {
            $raw = $raw.Substring(0, [Math]::Max($remaining, 0))
        }

        [void]$builder.AppendLine("===== FILE: $file =====")
        [void]$builder.AppendLine($raw)
        [void]$builder.AppendLine("")
    }

    return $builder.ToString()
}

function Build-DiagnosticsFolderReviewContext($diagDir) {
    $maxChars = 160000
    $builder = New-Object System.Text.StringBuilder
    $extensions = @(".txt", ".log", ".json", ".csv", ".error")

    $files = Get-ChildItem -Path $diagDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            ($extensions -contains $_.Extension.ToLowerInvariant()) -or
            $_.Name -match '\.error\.txt$'
        } |
        Sort-Object Length

    foreach ($file in $files) {
        if ($builder.Length -ge $maxChars) { break }
        if ($file.Length -gt 2MB) { continue }

        $raw = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $raw) { continue }

        $relative = $file.FullName.Replace("$diagDir\", "")
        $remaining = $maxChars - $builder.Length
        if ($remaining -le 0) { break }

        if ($raw.Length -gt $remaining) {
            $raw = $raw.Substring(0, $remaining)
        }

        [void]$builder.AppendLine("===== FILE: $relative =====")
        [void]$builder.AppendLine($raw)
        [void]$builder.AppendLine("")
    }

    return $builder.ToString()
}

function Final-ReviewDiagnosticsFolder($diagDir, $userIssue = "") {
    $context = Build-DiagnosticsFolderReviewContext $diagDir
    $prompt = @"
Jsi senior Windows diagnostik.
Projdi obsah diagnostické složky a napiš česky:
1) Co je nejpravděpodobnější problém.
2) Jaké důkazy v logách to potvrzují (uveď i konkrétní soubory a klíčové události).
3) Co by se mělo udělat dál jako další 3 konkrétní kroky.

Buď konkrétní a technický. Pokud něco chybí, napiš přesně co chybí.

Popis problému od uživatele:
$userIssue

Obsah diagnostické složky:
$context
"@
    return (Invoke-OpenAIText $prompt)
}

function Update-DiagnosticsContextFromRun($diagDir, $userIssue, $analysis, $finalReview) {
    $analysisText = ""
    if ($analysis) {
        $analysisText = $analysis | ConvertTo-Json -Depth 10
    }

    $fixLog = ""
    $fixLogPath = Join-Path $diagDir "fix_actions.log"
    if (Test-Path $fixLogPath) {
        $fixLog = Get-Content $fixLogPath -Raw -ErrorAction SilentlyContinue
    }

    $prompt = @"
Vytvoř stručný trvalý kontext pro další konverzaci admin asistenta.
Napiš česky max 10 řádků:
- hlavní problém
- nejdůležitější důkazy
- jaké kroky byly provedeny / přeskočeny
- co dělat dál

Issue:
$userIssue

Analysis JSON:
$analysisText

Fix log:
$fixLog

Final review:
$finalReview
"@

    $contextSummary = Invoke-OpenAIText $prompt
    $entry = @"
[$(Get-Date -Format s)] Diagnostika: $diagDir
$contextSummary

"@
    Add-Content $diagnosticsContextFile $entry
    Set-Content (Join-Path $diagDir "context_update.txt") $contextSummary
}

function Parse-JsonResponse($text) {
    $clean = $text.Trim()
    if ($clean.StartsWith('```')) {
        $clean = $clean -replace '^```(?:json)?\s*', ''
        $clean = $clean -replace '\s*```$', ''
    }
    return ($clean | ConvertFrom-Json -ErrorAction Stop)
}

function Analyze-WindowsDiagnostics($diagDir, $userIssue = "") {
    $context = Build-DiagnosticsContext $diagDir

    $prompt = @"
Jsi senior Windows diagnostik.
Analyzuj data z diagnostiky a vrať POUZE validní JSON podle tohoto schématu:
{
  "problem_summary": "stručné shrnutí problému",
  "root_causes": ["pravděpodobná příčina 1", "pravděpodobná příčina 2"],
  "actions": [
    {
      "id": "A1",
      "title": "krátký název kroku",
      "description": "co se stane a proč",
      "type": "powershell",
      "command": "konkrétní příkaz",
      "requires_admin": true,
      "risk": "nízké/střední/vysoké + stručně",
      "rollback": "jak vrátit změnu zpět"
    }
  ]
}
Podmínky:
- Navrhuj jen konkrétní bezpečné kroky.
- Pokud si nejsi jistý, přidej to do description.
- Pokud nejsou potřeba žádné kroky, vrať prázdné actions.
- Nevracej nic mimo JSON.

Popis problému od uživatele:
$userIssue

Diagnostická data:
$context
"@

    $raw = Invoke-OpenAIText $prompt
    try {
        $parsed = Parse-JsonResponse $raw
        $parsed | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $diagDir "analysis.json")
        return $parsed
    } catch {
        Set-Content (Join-Path $diagDir "analysis_raw.txt") $raw
        Write-Host "Nepodařilo se parse JSON odpověď, uloženo do analysis_raw.txt" -ForegroundColor Yellow
        return $null
    }
}

function Apply-DiagnosticActions($analysis, $diagDir) {
    if (-not $analysis) { return }
    if (-not $analysis.actions -or $analysis.actions.Count -eq 0) {
        Write-Host "GPT nenavrhl žádné automatické kroky." -ForegroundColor Yellow
        return
    }

    $isAdmin = Test-IsAdmin
    $fixLog = Join-Path $diagDir "fix_actions.log"
    "Fix execution started: $(Get-Date -Format s)" | Set-Content $fixLog

    foreach ($action in $analysis.actions) {
        Write-Host ""
        Write-Host "[$($action.id)] $($action.title)" -ForegroundColor Cyan
        Write-Host "Proč: $($action.description)"
        Write-Host "Riziko: $($action.risk)"
        Write-Host "Rollback: $($action.rollback)"
        Write-Host "Příkaz: $($action.command)" -ForegroundColor DarkGray

        $approve = Read-Host "Provést tento krok? (ano/ne)"
        if ($approve -notmatch '^(a|ano|y|yes)$') {
            Add-Content $fixLog "[$($action.id)] SKIPPED by user"
            Add-Content $commandsHistoryFile "[$(Get-Date -Format s)] DIAG-SKIP [$($action.id)]: $($action.command)"
            continue
        }

        $normalizedCommand = Get-NormalizedFixCommand $action.command
        $dangerHit = Get-DangerousPatternHit $normalizedCommand
        if ($dangerHit) {
            Write-Host "Varování: příkaz obsahuje rizikový vzor ($dangerHit)." -ForegroundColor Red
            $dangerApprove = Read-Host "I přesto chceš příkaz spustit? (ano/ne)"
            if ($dangerApprove -notmatch '^(a|ano|y|yes)$') {
                Add-Content $fixLog "[$($action.id)] SKIPPED: dangerous pattern rejected"
                Add-Content $commandsHistoryFile "[$(Get-Date -Format s)] DIAG-SKIP-DANGER [$($action.id)]: $($action.command)"
                continue
            }
        }

        $needsAdmin = $false
        try { $needsAdmin = [bool]$action.requires_admin } catch {}
        $execCommand = $normalizedCommand
        if ($needsAdmin -and -not $isAdmin) {
            if (Test-SudoAvailable) {
                $sudoApprove = Read-Host "Krok vyžaduje admin práva. Spustit přes sudo? (ano/ne)"
                if ($sudoApprove -match '^(a|ano|y|yes)$') {
                    $execCommand = "sudo $normalizedCommand"
                } else {
                    Add-Content $fixLog "[$($action.id)] SKIPPED: sudo declined"
                    Add-Content $commandsHistoryFile "[$(Get-Date -Format s)] DIAG-SKIP-SUDO [$($action.id)]: $($action.command)"
                    continue
                }
            } else {
                Write-Host "Tento krok vyžaduje administrátora a 'sudo' není dostupné. Přeskakuji." -ForegroundColor Yellow
                Add-Content $fixLog "[$($action.id)] SKIPPED: admin required and sudo unavailable"
                Add-Content $commandsHistoryFile "[$(Get-Date -Format s)] DIAG-SKIP-ADMIN [$($action.id)]: $($action.command)"
                continue
            }
        }

        try {
            Add-Content $fixLog "[$($action.id)] EXECUTING: $execCommand"
            Add-Content $commandsHistoryFile "[$(Get-Date -Format s)] DIAG-EXEC [$($action.id)]: $execCommand"
            $result = Invoke-Expression $execCommand 2>&1 | Out-String
            Add-Content $fixLog $result
            Write-Host "Krok proveden." -ForegroundColor Green
        } catch {
            $err = $_ | Out-String
            Add-Content $fixLog "[$($action.id)] ERROR: $err"
            Add-Content $commandsHistoryFile "[$(Get-Date -Format s)] DIAG-ERROR [$($action.id)]: $execCommand"
            Write-Host "Krok selhal, detail ve fix_actions.log" -ForegroundColor Red
        }
    }
}

function Start-WindowsDiagnostics($userIssue = "") {
    Write-Host "Sbírám diagnostická data systému Windows..." -ForegroundColor DarkYellow
    $diagDir = Collect-WindowsDiagnostics $userIssue
    Write-Host "Diagnostika uložena do: $diagDir" -ForegroundColor Green

    Write-Host "Analyzuji data přes GPT..." -ForegroundColor DarkYellow
    $analysis = Analyze-WindowsDiagnostics -diagDir $diagDir -userIssue $userIssue

    if (-not $analysis) {
        Write-Host "Analýza selhala. Zkontroluj soubor analysis_raw.txt." -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "Shrnutí problému:" -ForegroundColor Cyan
    Write-Host $analysis.problem_summary

    if ($analysis.root_causes -and $analysis.root_causes.Count -gt 0) {
        Write-Host ""
        Write-Host "Pravděpodobné příčiny:" -ForegroundColor Cyan
        foreach ($cause in $analysis.root_causes) {
            Write-Host " - $cause"
        }
    }

    if ($analysis.actions -and $analysis.actions.Count -gt 0) {
        Write-Host ""
        Write-Host "Navržené kroky:" -ForegroundColor Cyan
        foreach ($action in $analysis.actions) {
            Write-Host "[$($action.id)] $($action.title) :: $($action.description)"
        }

        $runFixes = Read-Host "Chceš navržené kroky projít a případně spustit? (ano/ne)"
        if ($runFixes -match '^(a|ano|y|yes)$') {
            Apply-DiagnosticActions -analysis $analysis -diagDir $diagDir
        }
    } else {
        Write-Host "GPT nenašel automaticky řešitelný krok." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Finální revize celé diagnostické složky..." -ForegroundColor DarkYellow
    $finalReview = Final-ReviewDiagnosticsFolder -diagDir $diagDir -userIssue $userIssue
    Set-Content (Join-Path $diagDir "final_review.txt") $finalReview
    Write-Host ""
    Write-Host "Závěrečné zhodnocení:" -ForegroundColor Cyan
    Write-Host $finalReview

    Update-DiagnosticsContextFromRun -diagDir $diagDir -userIssue $userIssue -analysis $analysis -finalReview $finalReview
    Refresh-SystemPromptInConversation
    Write-Host "[Diagnostický kontext byl uložen pro další konverzaci]" -ForegroundColor DarkYellow

    Write-Host "Hotovo. Kompletní podklady: $diagDir" -ForegroundColor Green
}

# ---- start ----

Write-Host "=== ChatGPT PowerShell Copilot ==="

if (Test-Path $logFile) {
    Get-Content $logFile
}

Refresh-SystemPromptInConversation
Write-Host "Prvotní prompt: `n$($script:conversation[0].content)`n" -ForegroundColor Yellow

function Show-Help {
    Write-Host "Dostupné příkazy / Available commands:" -ForegroundColor Cyan
    Write-Host "  exit                - ukončí program / exit the client"
    Write-Host "  reset               - vymaže konverzační historii / clear conversation history"
    Write-Host "  voice / hlas        - zapne hlasový vstup / toggle voice input"
    Write-Host "  analyze / analyzuj <file>    - analyzuj obsah souboru / analyze file contents"
    Write-Host "  diagnose / diagnostika [problém] - sesbírá Windows diagnostiku + GPT návrh oprav"
    Write-Host "  !run <ps>           - spusť PS příkaz / execute PowerShell expression"
    Write-Host "  tts                 - přepíná text-to-speech (řeč) / toggle text-to-speech"
    Write-Host "  pamatuj / remember <text>    - přidej text do dlouhodobé paměti / add text to memory"
    Write-Host "  poznámka / note <text>       - přidej shrnutou poznámku / add a summarized note"
    Write-Host "  poznámky / notes on/off      - režim automatického zapisování poznámek / notes mode on/off"
    Write-Host "  help / nápověda      - zobrazí tuto nápovědu / show help"
    Write-Host "  (any other text is sent to GPT)" 
}

Write-Host "exit/ukonči | reset/vymaž | voice/hlas | analyze/analyzuj <file> | diagnose/diagnostika [problém] | !run <ps> | tts | pamatuj/remember <text> | poznámka/note <text> | poznámky/notes on/off | help/nápověda | nebo se prostě na něco zeptej"
function UpdateMemory($userText, $assistantText) {

    $existingMemory = ""
    if (Test-Path $memoryFile) {
        $existingMemory = Get-Content $memoryFile -Raw
    }

    $memoryCheckPrompt = @"
Máš existující dlouhodobou paměť uživatele:

$existingMemory

Nová konverzace:
Uživatel: $userText
Asistent: $assistantText

Úkol:
1. Aktualizuj paměť podle nových informací.
2. Pokud se informace změnila, starou nahraď.
3. Odstraň duplicity.
4. Ignoruj dočasné informace (den, čas, náladu).
5. Vrať kompletní novou paměť.

Vrať pouze výslednou paměť.
"@

    $body = @{
        model="gpt-5.2"
        input=$memoryCheckPrompt
    } | ConvertTo-Json -Depth 5

    $response = Invoke-RestMethod -Method Post -Uri $uri -Headers @{
        Authorization = "Bearer $apiKey"
        "Content-Type"="application/json"
    } -Body $body

    $text = ""
    foreach ($m in $response.output) {
        foreach ($p in $m.content) {
            if ($p.type -eq "output_text") {
                $text += $p.text
            }
        }
    }

    if ($text.Trim().Length -gt 0) {
        Set-Content $memoryFile $text.Trim()
        Write-Host "[Paměť aktualizována]" -ForegroundColor DarkYellow
    }
}


while ($true) {

    $inputText = Read-Host
    Log-UserCommand $inputText
    if ($inputText -match '^(help|nápověda)$') {
        Show-Help
        continue
    }
    # english/czech aliases
    if ($inputText -match '^(exit|ukonči)$') { break }
    if ($inputText -match '^(reset|vymaž)$') {
        $script:conversation = @()
        Refresh-SystemPromptInConversation
        continue
    }
    if ($inputText -match '^(voice|hlas)$') {
        $inputText = VoiceInput
        Write-Host "Rozpoznáno: $inputText"
    }
    if ($inputText -match '^(analyze|analyzuj)\s+') {
        $arg = $inputText -replace '^(analyze|analyzuj)\s+',''
        AnalyzeFile $arg
        continue
    }
    if ($inputText -match '^(diagnose|diagnostika)(\s+.*)?$') {
        $issue = ($inputText -replace '^(diagnose|diagnostika)\s*','').Trim()
        Start-WindowsDiagnostics $issue
        continue
    }
    if ($inputText -match '^!run\s+') {
        Invoke-Expression ($inputText.Substring(5))
        continue
    }
    if ($inputText -eq 'tts') {
        $script:ttsEnabled = -not $script:ttsEnabled
        Write-Host "TTS:" ($script:ttsEnabled ? "ON" : "OFF")
        continue
    }
    if ($inputText -match '^(pamatuj|remember)\s+') {
        $arg = $inputText -replace '^(pamatuj|remember)\s+',''
        Add-Content $memoryFile $arg
        Refresh-SystemPromptInConversation
        Write-Host "Uloženo do paměti."
        continue
    }

    # notes commands
    if ($inputText -match '^(poznámky|notes)\s+on$') {
        $script:noteMode = $true
        Write-Host "Režim poznámek zapnut" -ForegroundColor DarkYellow
        continue
    }
    if ($inputText -match '^(poznámky|notes)\s+off$') {
        $script:noteMode = $false
        Write-Host "Režim poznámek vypnut" -ForegroundColor DarkYellow
        continue
    }
    if ($inputText -match '^(poznámka|note)\s+' ) {
        $noteText = $inputText -replace '^(poznámka|note)\s+',''
        Add-Note $noteText
        continue
    }

    if ($script:noteMode) {
        # every line becomes a summarized note
        Add-Note $inputText
        continue
    }

    if ($inputText -eq "exit") { break }

    if ($inputText -eq "voice") {
        $inputText = VoiceInput
        Write-Host "Rozpoznáno: $inputText"
    }

    if ($inputText -eq "reset") {
        $script:conversation = @()
        Refresh-SystemPromptInConversation
        continue
    }

    if ($inputText.StartsWith("analyze ")) {
        AnalyzeFile $inputText.Substring(8)
        continue
    }

    if ($inputText.StartsWith("!run ")) {
        Invoke-Expression $inputText.Substring(5)
        continue
    }
    if ($inputText -eq "tts") {
        $script:ttsEnabled = -not $script:ttsEnabled
        Write-Host "TTS:" ($script:ttsEnabled ? "ON" : "OFF")
        continue
    }
    if ($inputText.StartsWith("pamatuj")) {
        Add-Content $memoryFile ($inputText.Substring(7))
        Refresh-SystemPromptInConversation
        Write-Host "Uloženo do paměti."
        continue
    }

    # notes commands
    if ($inputText -match '^(poznámky|notes)\s+on$') {
        $script:noteMode = $true
        Write-Host "Režim poznámek zapnut" -ForegroundColor DarkYellow
        continue
    }
    if ($inputText -match '^(poznámky|notes)\s+off$') {
        $script:noteMode = $false
        Write-Host "Režim poznámek vypnut" -ForegroundColor DarkYellow
        continue
    }
    if ($inputText -match '^(poznámka|note)\s+' ) {
        $noteText = $inputText -replace '^(poznámka|note)\s+',''
        Add-Note $noteText
        continue
    }

    if ($script:noteMode) {
        # every line becomes a summarized note
        Add-Note $inputText
        continue
    }


    Write-Host "[$(TimeNow)] Ty: $inputText" -ForegroundColor Green
    Log "USER: $inputText"
    $answer = Ask-ChatGPT $inputText
    UpdateMemory $inputText $answer

    Write-Host "[$(TimeNow)] GPT: $answer" -ForegroundColor Cyan
    Log "GPT: $answer"

    if ($script:ttsEnabled) {
        Speak $answer
    }

}
