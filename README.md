# PS-chatGPT-API-with-memory

This repository contains a PowerShell script (`chatgpt.ps1`) that serves as a CLI client for the OpenAI ChatGPT API. It supports conversational interaction, long-term memory storage, caching, and a notes/todo system. Users can type queries, save memory, analyze files, and record summarized notes. The script is designed for Windows PowerShell and leverages text-to-speech and voice input for additional interactivity.

Below are some of the main features:

- **Chat-based interface** using OpenAI's GPT models.
- **Persistent memory** stored in `memory.txt` with automatic summarization and optimization.
- **Caching** of prompts to reduce API calls (`cache.json`).
- **Note-taking mode** with automatic summarization to `notes.txt`.
- **Voice input** and **text-to-speech** support.
- Simple commands like `pamatuj`, `poznámka`, `analyze <file>`, and more.

Usage instructions and configuration details are included in the script comments.