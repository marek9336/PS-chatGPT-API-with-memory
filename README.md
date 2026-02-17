# PS-chatGPT-API-with-memory

## English

### Overview
This project is a PowerShell CLI assistant (`chatgpt.ps1`) using the OpenAI Responses API.

It supports:
- chat with persistent conversation context
- long-term memory storage (`memory.txt`)
- prompt/answer cache (`cache.json`)
- summarized notes (`notes.txt`)
- voice input + text-to-speech
- file analysis
- Windows diagnostics collection + GPT analysis + optional guided fix execution

### Requirements
- Windows
- PowerShell 7+ (`pwsh`) recommended
- OpenAI API key in environment variable `OPENAI_API_KEY`

Set API key:
```powershell
setx OPENAI_API_KEY "YOUR_API_KEY"
```
Then restart terminal.

### Run
```powershell
pwsh -File .\chatgpt.ps1
```

### Main Commands
- `help` / `nápověda` - show command list
- `exit` / `ukonči` - exit
- `reset` / `vymaž` - clear in-session conversation
- `voice` / `hlas` - use microphone input
- `tts` - toggle text-to-speech
- `analyze <file>` / `analyzuj <file>` - analyze local file content with GPT
- `diagnose [issue]` / `diagnostika [problém]` - run Windows diagnostics workflow
- `pamatuj <text>` / `remember <text>` - append manual memory
- `poznámka <text>` / `note <text>` - add summarized note
- `poznámky on|off` / `notes on|off` - toggle note mode
- `!run <powershell>` - run PowerShell command directly

### Windows Diagnostics Workflow
When you run `diagnostika` / `diagnose`, the script:
1. Creates a new folder under `diagnostics/diag_YYYYMMDD_HHMMSS`.
2. Collects reports/logs/registry exports/dump metadata.
3. Sends selected diagnostic context to GPT for structured analysis (`analysis.json`).
4. Shows probable causes and proposed actions.
5. Executes actions only with explicit user confirmation (`ano/ne`).
6. Uses `sudo` for admin-required steps when available and approved.
7. Performs a final full-folder GPT review and saves it to `final_review.txt`.

Common output files:
- `meta.txt`
- `analysis.json` (or `analysis_raw.txt` if JSON parse fails)
- `fix_actions.log`
- `final_review.txt`
- exported logs in `reports/`, `logs/`, `registry/`, `dumps/`, `temp/`

### Safety Model for Fix Commands
- Every proposed action requires explicit confirmation.
- For known dangerous command patterns (for example destructive disk/file operations), script shows an extra warning and asks for second confirmation.
- Admin-required steps can be elevated through `sudo` (if installed/available).

### Repository Notes
- `diagnostics/` is gitignored and should not be committed.
- Session logs are stored as `chat_YYYY-MM-DD_HH-mm-ss.log`.

---

## Cesky

### Přehled
Tento projekt je PowerShell CLI asistent (`chatgpt.ps1`) nad OpenAI Responses API.

Umí:
- chat s kontextem konverzace
- dlouhodobou paměť (`memory.txt`)
- cache dotazů/odpovědí (`cache.json`)
- shrnuté poznámky (`notes.txt`)
- hlasový vstup + text-to-speech
- analýzu souborů
- Windows diagnostiku + GPT vyhodnocení + volitelné řízené opravy

### Požadavky
- Windows
- PowerShell 7+ (`pwsh`) doporučeno
- OpenAI API klíč v proměnné `OPENAI_API_KEY`

Nastavení API klíče:
```powershell
setx OPENAI_API_KEY "YOUR_API_KEY"
```
Potom restartuj terminál.

### Spuštění
```powershell
pwsh -File .\chatgpt.ps1
```

### Hlavní příkazy
- `help` / `nápověda` - přehled příkazů
- `exit` / `ukonči` - ukončení
- `reset` / `vymaž` - vymazání konverzace v aktuální relaci
- `voice` / `hlas` - vstup z mikrofonu
- `tts` - zap/vyp čtení odpovědí
- `analyze <file>` / `analyzuj <file>` - analýza lokálního souboru přes GPT
- `diagnose [issue]` / `diagnostika [problém]` - diagnostický workflow Windows
- `pamatuj <text>` / `remember <text>` - ruční přidání do paměti
- `poznámka <text>` / `note <text>` - shrnutá poznámka
- `poznámky on|off` / `notes on|off` - režim poznámek
- `!run <powershell>` - přímé spuštění PowerShell příkazu

### Diagnostický workflow Windows
Po spuštění `diagnostika` / `diagnose` skript:
1. Vytvoří novou složku `diagnostics/diag_YYYYMMDD_HHMMSS`.
2. Sesbírá reporty/logy/exporty registrů/metadata dumpů.
3. Pošle vybraný kontext GPT pro strukturovanou analýzu (`analysis.json`).
4. Vypíše pravděpodobné příčiny a navržené kroky.
5. Každý krok spustí jen po potvrzení uživatelem (`ano/ne`).
6. Krokům vyžadujícím admin práva může dát elevaci přes `sudo` (pokud je dostupné a odsouhlasené).
7. Na konci udělá finální GPT revizi celé složky a uloží ji do `final_review.txt`.

Typické výstupy:
- `meta.txt`
- `analysis.json` (nebo `analysis_raw.txt`, pokud JSON neprojde parse)
- `fix_actions.log`
- `final_review.txt`
- exporty v `reports/`, `logs/`, `registry/`, `dumps/`, `temp/`

### Bezpečnost při opravách
- Každý navržený krok vyžaduje potvrzení.
- U známých rizikových vzorů příkazů skript zobrazí extra varování a chce druhé potvrzení.
- Kroky s admin právy lze spouštět přes `sudo` (pokud je nainstalované/dostupné).

### Poznámky k repozitáři
- `diagnostics/` je v `.gitignore` a nemá se commitovat.
- Log relace se ukládá jako `chat_YYYY-MM-DD_HH-mm-ss.log`.
