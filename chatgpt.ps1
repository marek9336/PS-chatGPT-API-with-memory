# ==============================
# ChatGPT PowerShell Client
# ==============================
# Commands:
#   exit  - konec
#   reset - smaže historii
# ==============================

$apiKey = $env:OPENAI_API_KEY
if (-not $apiKey) {
    Write-Error "OPENAI_API_KEY not set"
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
    $summary = Ask-ChatGPT "Shrň dosavadní konverzaci stručně do paměti."
    Add-Content $memoryFile "`n$summary`n"
    $script:conversation = @()
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

Write-Host "exit | reset | voice | analyze <file> | !run <ps> | tts | pamatuj <text> | nebo se prostě na něco zeptej"

while ($true) {

    $inputText = Read-Host

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
        Write-Host "Uloženo do paměti."
        continue
    }


    Write-Host "[$(TimeNow)] Ty: $inputText" -ForegroundColor Green
    Log "USER: $inputText"
    $memory = $(LoadMemory)
    $answer = Ask-ChatGPT $inputText

    Write-Host "[$(TimeNow)] GPT: $answer" -ForegroundColor Cyan
    Log "GPT: $answer"

    if ($script:ttsEnabled) {
        Speak $answer
    }

}
