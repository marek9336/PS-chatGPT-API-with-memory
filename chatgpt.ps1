# ==============================
# ChatGPT PowerShell Client
# ==============================
# Commands:
#   exit  - konec
#   reset - smaže historii
# ==============================

$apiKey = $env:OPENAI_API_KEY
if (-not $apiKey) {
    Write-Error "OPENAI_API_KEY is not set."
    exit 1
}

$uri = "https://api.openai.com/v1/responses"
$logFile = ".\chatgpt_log.txt"

# historie konverzace
$script:conversation = @()

function Get-TimeStamp {
    return (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
}

function Write-Log {
    param($Text)
    Add-Content -Path $logFile -Value $Text
}

function Ask-ChatGPT {
    param([string]$Prompt)

    $headers = @{
        "Authorization" = "Bearer $apiKey"
        "Content-Type"  = "application/json"
    }

    # uložíme do historie
    $script:conversation += @{
        role = "user"
        content = $Prompt
    }

    $body = @{
        model = "gpt-5.2"
        input = $script:conversation
    } | ConvertTo-Json -Depth 10

    try {
        $response = Invoke-RestMethod `
            -Method Post `
            -Uri $uri `
            -Headers $headers `
            -Body $body

        # --- Parsování čistého textu ---
        $textParts = @()

        foreach ($msg in $response.output) {
            foreach ($part in $msg.content) {
                if ($part.type -eq "output_text") {
                    $textParts += $part.text
                }
            }
        }

        $answer = ($textParts -join "`n").Trim()

        # uložit do historie
        $script:conversation += @{
            role = "assistant"
            content = $answer
        }

        return $answer
    }
    catch {
        Write-Error $_
        return ""
    }
}

Write-Host "ChatGPT client ready. Commands: exit, reset"

while ($true) {
    $time = Get-TimeStamp
    $q = Read-Host "`n[$time] Ty"

    if ($q -eq "exit") { break }

    if ($q -eq "reset") {
        $conversation = @()
        Write-Host "Historie smazána."
        continue
    }

    Write-Log "[$time] USER: $q"

    $answer = Ask-ChatGPT -Prompt $q
    $time = Get-TimeStamp

    Write-Host "`n[$time] ChatGPT:`n$answer"
    Write-Log "[$time] GPT: $answer"
}
