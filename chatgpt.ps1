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
    Write-Error "OPENAI_API_KEY not set. use command via Powershell and restart terminal: setx OPENAI_API_KEY "YOUR_API_KEY""
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
$script:noteMode = $false

$script:conversation = @()
$script:cache = @{}

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

    if ($script:cache.ContainsKey($prompt)) {
        return $script:cache[$prompt]
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

    $script:cache[$prompt] = $answer
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

# ---- start ----

Write-Host "=== ChatGPT PowerShell Copilot ==="

if (Test-Path $logFile) {
    Get-Content $logFile
}

$memory = $(LoadMemory)

$systemPrompt = @"
Jsi CLI admin copilot. Pomáhej stručně, technicky a prakticky.
Paměť uživatele:
$memory
"@

Write-Host "Prvotní prompt: `n$systemPrompt`n" -ForegroundColor Yellow

$script:conversation += @{ role="system"; content=$systemPrompt }

function Show-Help {
    Write-Host "Dostupné příkazy / Available commands:" -ForegroundColor Cyan
    Write-Host "  exit                - ukončí program / exit the client"
    Write-Host "  reset               - vymaže konverzační historii / clear conversation history"
    Write-Host "  voice / hlas        - zapne hlasový vstup / toggle voice input"
    Write-Host "  analyze / analyzuj <file>    - analyzuj obsah souboru / analyze file contents"
    Write-Host "  !run <ps>           - spusť PS příkaz / execute PowerShell expression"
    Write-Host "  tts                 - přepíná text-to-speech (řeč) / toggle text-to-speech"
    Write-Host "  pamatuj / remember <text>    - přidej text do dlouhodobé paměti / add text to memory"
    Write-Host "  poznámka / note <text>       - přidej shrnutou poznámku / add a summarized note"
    Write-Host "  poznámky / notes on/off      - režim automatického zapisování poznámek / notes mode on/off"
    Write-Host "  help / nápověda      - zobrazí tuto nápovědu / show help"
    Write-Host "  (any other text is sent to GPT)" 
}

Write-Host "exit/ukonči | reset/vymaž | voice/hlas | analyze/analyzuj <file> | !run <ps> | tts | pamatuj/remember <text> | poznámka/note <text> | poznámky/notes on/off | help/nápověda | nebo se prostě na něco zeptej"
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
    if ($inputText -match '^(help|nápověda)$') {
        Show-Help
        continue
    }
    # english/czech aliases
    if ($inputText -match '^(exit|ukonči)$') { break }
    if ($inputText -match '^(reset|vymaž)$') {
        $script:conversation = @()
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
        $memory = $(LoadMemory)
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
        $memory = $(LoadMemory)
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
    $memory = $(LoadMemory)
    $answer = Ask-ChatGPT $inputText
    UpdateMemory $inputText $answer

    Write-Host "[$(TimeNow)] GPT: $answer" -ForegroundColor Cyan
    Log "GPT: $answer"

    if ($script:ttsEnabled) {
        Speak $answer
    }

}
