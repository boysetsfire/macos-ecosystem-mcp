# Setup Notes – macOS Ecosystem MCP Server

Persönliche Setup-Dokumentation für die Nutzung dieses Servers mit Claude Desktop.
Diese Datei ist eine eigene Ergänzung (kein Teil des Original-Repos von neverprepared)
und wird bei Upstream-Syncs nicht angetastet.

## Was & warum

MCP-Server, der Claude Desktop nativen Zugriff auf macOS Reminders, Calendar und Notes
gibt (via EventKit bzw. AppleScript für Notes). Zweck: Reminders/Notizen/Termine direkt
aus dem Chat heraus verwalten, als Baustein für ein geräteübergreifendes "zweites Gehirn"
(Notizen/ToDos/Kontakte), ergänzend zur nativen iOS-Integration von Claude.

## Installation (Stand: Juli 2026)

Voraussetzungen: macOS 13+, Swift 5.9+ (vorhanden: Swift 6.3.3 / macOS 26).

```bash
cd /Users/christophweitzel/Documents/GitHub
git clone https://github.com/boysetsfire/macos-ecosystem-mcp.git
cd macos-ecosystem-mcp
swift build -c release

# /usr/local/bin existiert auf neueren Macs oft nicht standardmäßig -> anlegen
sudo mkdir -p /usr/local/bin
sudo cp .build/release/macos-mcp /usr/local/bin/macos-mcp
```

## Claude Desktop Config

Datei: `~/Library/Application Support/Claude/claude_desktop_config.json`

Ergänzter Block (bestehende Config, u.a. Cowork-Settings, bleibt unangetastet):

```json
{
  "mcpServers": {
    "macos-ecosystem": {
      "command": "/usr/local/bin/macos-mcp"
    }
  }
}
```

Nach dem Editieren: Claude Desktop **komplett beenden** (⌘Q, nicht nur Fenster schließen)
und neu starten.

## Erteilte Berechtigungen

Bei erstem Tool-Aufruf fragt macOS automatisch ab (System­einstellungen → Datenschutz &
Sicherheit):
- Reminders ✅
- Calendars ✅
- Automation → Notes ✅

## Bekannte Grenzen

- Läuft nur, **solange Claude Desktop offen ist** – kein Hintergrunddienst, kein Autostart
- Nur auf **diesem Mac** nutzbar – kein Zugriff über iPhone-App oder claude.ai im Browser
  (dafür bräuchte es einen öffentlich erreichbaren HTTPS-Endpunkt, den dieser Server nicht
  hat)
- Claude kann **keine neuen Reminder-Listen** erstellen, nur bestehende befüllen
- **Kein Kontaktzugriff**
- Flagged-Status bei Reminders wird von EventKit nicht unterstützt (Parameter wird
  akzeptiert, aber ignoriert)

Für unterwegs (iPhone) bleibt stattdessen die native iOS-Integration von Claude relevant
(Reminders/Calendar/Mail/Messages/Maps/Health) – separates Feature, keine Abhängigkeit
von diesem MCP-Server.

## Remotes

- `origin` → eigener Fork (`github.com/boysetsfire/macos-ecosystem-mcp`)
- `upstream` → Original von neverprepared

## Update-Workflow

```bash
cd /Users/christophweitzel/Documents/GitHub/macos-ecosystem-mcp
git fetch upstream
git merge upstream/main
swift build -c release
sudo cp .build/release/macos-mcp /usr/local/bin/macos-mcp
git push origin main
```

Danach Claude Desktop neu starten.

Alternativ: "Sync fork"-Button auf der GitHub-Fork-Seite nutzen, danach lokal nur noch
`git pull origin main`.

### Merge-Checkliste nach Upstream-Update

Nach jedem `git merge upstream/main` diese Fork-eigenen Änderungen auf Konflikte prüfen:

| Datei | Was wir geändert haben |
|---|---|
| `Sources/macos-mcp/NotesHandler.swift` | `scriptQueue` (serial queue, Z. 7–11), `updateNote()` (neues Tool), `runAppleScript()` (30s-Timeout + Timing-Logs), `getNote()` by noteId (try-Block um `name of container`) |
| `Sources/macos-mcp/App.swift` | `_activityToken` (App-Nap-Prevention), `log()` (Timestamps), Dispatch-Case `notes_update`, Tool-Count |
| `Sources/macos-mcp/ToolDefinitions.swift` | Tool-Definition `notes_update` (nach `notes_append`) |
| `Tests/e2e_notes_test.py` | Neu — kein Upstream-Konflikt möglich |
| `SETUP-NOTES.md` | Neu — kein Upstream-Konflikt möglich |

Bei Konflikten in den Swift-Dateien: Upstream-Änderungen übernehmen, dann unsere
Ergänzungen manuell neu einspielen. Danach `python3 Tests/e2e_notes_test.py` laufen
lassen — alle 16 Tests grün = Merge korrekt.

## Update-Benachrichtigungen

GitHub-Watch auf dem Original-Repo (`neverprepared/macos-ecosystem-mcp`) aktiv:
- Releases (neue Versionen)
- Security alerts (Dependency-Schwachstellen)
