# BrewWatcher

Menyradsapp för macOS som håller koll på Homebrew-paket och påminner dig om uppdateringar.

## Filer

- **`BrewWatcherApp.swift`** — hela appens källkod (SwiftUI, en fil)
- **`BrewWatcherIcon.svg`** — ikonens källfil (vektorgrafik)
- **`AppIcon.appiconset/`** — färdig icon set för Xcode (alla storlekar)
- **`release.sh`** — build-skript för att signera, notarisera och paketera

## Setup i Xcode

1. **Skapa nytt projekt**: File → New → Project → macOS → App
   - Product Name: `BrewWatcher`
   - Interface: SwiftUI
   - Language: Swift
   - Minimum Deployment: macOS 14.0

2. **Ersätt den autogenererade `BrewWatcherApp.swift`** med filen i denna mapp

3. **Lägg in ikonen**:
   - Öppna `Assets.xcassets`
   - Ta bort den befintliga `AppIcon`
   - Dra in hela `AppIcon.appiconset`-mappen

4. **Inställningar**:
   - I projektets Info-flik, lägg till `Application is agent (UIElement)` = `YES`
     (då försvinner Dock-ikonen — appen lever bara i menyraden)
   - I Signing & Capabilities: **ta bort App Sandbox** om den finns
     (appen måste kunna köra `brew` som subprocess)

5. **Bygg och kör** (⌘R). Appen dyker upp i menyraden.

## Releasing (signera + notarisera)

Se `release.sh`. Innan du kör skriptet:

1. Skaffa Apple Developer Program (99 USD/år)
2. Skapa Developer ID Application-certifikat i Xcode → Settings → Accounts
3. Skapa app-specifikt lösenord på appleid.apple.com
4. Spara notariseringscredentials i keychain:
   ```bash
   xcrun notarytool store-credentials "brewwatcher-notary" \
     --apple-id "din@email.com" \
     --team-id "DITT_TEAM_ID" \
     --password "app-specifikt-lösenord"
   ```
5. Aktivera Hardened Runtime i Signing & Capabilities
6. Fyll i `DEV_ID` i `release.sh`
7. Kör: `chmod +x release.sh && ./release.sh`

## Distribution via Homebrew Cask

När appen är notariserad och uppladdad till GitHub Releases:

1. Forka `homebrew/homebrew-cask`
2. Skapa en cask-fil med `brew create --cask <URL till DMG>`
3. Testa lokalt: `brew install --cask ./Casks/brewwatcher.rb` och `brew audit --new --cask brewwatcher`
4. Öppna PR till `homebrew/homebrew-cask`

Efter merge får användarna uppdateringar via `brew upgrade` automatiskt.

## Funktioner

- Visar antal uppdateringsbara paket i menyradsikonen
- Klickbar menyradsmeny med lista över utdaterade paket
- "Uppdatera alla"-knapp med progress per paket (X/Y, %, status)
- Auto-kontroll var 6:e timme
- Native notiser när uppdateringar finns
- Välkomstvy som hjälper användaren att installera Homebrew om det saknas
