# Privacy & Security

## How Your Data is Protected

### API Credentials
Tama connects to AI providers (Claude, OpenAI, etc.) using **your own API keys**. These credentials are:

- **Encrypted** using AES-256-GCM (via Apple's CryptoKit)
- **Stored in the macOS Keychain** — the same secure storage used for your passwords
- **Never transmitted anywhere** except directly to the AI provider's API
- **Never logged or stored in plain text**

### Keychain Permission Prompt
When you first add an API key, macOS will show a system dialog:

> "Tama wants to use your confidential information stored in 'Tama' in your keychain."

**This is normal and expected.** This prompt appears because Tama is creating a secure encryption key to protect your credentials. Click "Always Allow" to prevent this prompt from appearing again.

### What We DON'T Do
- ❌ We don't have access to your credentials
- ❌ We don't store credentials on any server
- ❌ We don't track which AI providers you use
- ❌ We don't sell or share any data

### Local Storage Only
All your data (chat history, settings, schedules) is stored **locally on your Mac** in:
- `~/Library/Application Support/Tama/` — encrypted data files
- macOS Keychain — encryption keys

Nothing leaves your machine except API calls directly to the AI providers you choose to use.

### Open Source
This app is open source. You can audit exactly how credentials are handled:
- `tama/Sources/AI/ClaudeCredentials.swift` — Keychain encryption key management
- `tama/Sources/AI/ProviderStore.swift` — Encrypted credential storage
