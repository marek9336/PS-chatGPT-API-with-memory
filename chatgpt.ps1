# ==============================
# Simple ChatGPT API PowerShell client
# ==============================
# Requirements:
#   1) Set environment variable OPENAI_API_KEY
#      PowerShell:
#      setx OPENAI_API_KEY "YOUR_API_KEY"
#      (restart terminal after setting)
# ==============================

$apiKey = $env:OPENAI_API_KEY
if (-not $apiKey) {
    Write-Error "OPENAI_API_KEY is not set."
    exit 1
}

$uri = "https://api.openai.com/v1/responses"

function Ask-ChatGPT {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Prompt
    )

    $headers = @{
        "Authorization" = "Bearer $apiKey"
        "Content-Type"  = "application/json"
    }

    $body = @{
        model = "gpt-5.2"
        input = $Prompt
    } | ConvertTo-Json -Depth 5

    try {
        $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body

        # Většinou je text v output_text
        if ($response.output_text) {
            return $response.output_text
        }

        # fallback pro případ jiné struktury
        return ($response.output | ConvertTo-Json -Depth 10)
    }
    catch {
        Write-Error $_
    }
}

# ---- jednoduchý interaktivní režim ----
while ($true) {
    $q = Read-Host "`nTy"
    if ($q -in @("exit","quit","q")) { break }

    $answer = Ask-ChatGPT -Prompt $q
    Write-Host "`nChatGPT:`n$answer"
}
