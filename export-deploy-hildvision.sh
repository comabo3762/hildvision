#!/bin/bash

# Automatisierter WordPress Export & Cloudflare Pages Deploy Script
# Lädt WordPress von Synology herunter und deployt zu GitHub/Cloudflare Pages

set -euo pipefail

# Konfiguration
SYNOLOGY_USER="comabo47"
SYNOLOGY_HOST="192.168.1.183"
SYNOLOGY_PORT="28"
SYNOLOGY_SSH_KEY="$HOME/.ssh/synology"
SYNOLOGY_EXPORT_DIR="/volume1/exported-html-daily"
LOCAL_REPO="$HOME/hildvision"
LOCAL_PUBLIC="$LOCAL_REPO/public"
TEMP_DIR="/tmp/hildvision-export-$$"
LOG_FILE="$HOME/hildvision-deploy.log"

# Logging-Funktion
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== Hildvision Export & Deploy gestartet ==="

# Fehlerbehandlung
trap 'log "❌ FEHLER: Script abgebrochen"; rm -rf "$TEMP_DIR"; exit 1' ERR

# Prüfe SSH-Schlüssel
if [ ! -f "$SYNOLOGY_SSH_KEY" ]; then
    log "❌ SSH-Schlüssel nicht gefunden: $SYNOLOGY_SSH_KEY"
    exit 1
fi

# 1. Temp-Verzeichnis erstellen
log "📁 Erstelle Temp-Verzeichnis..."
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

# 2. Auf Synology den Export durchführen
log "🔄 Starte WordPress Export auf Synology..."
ssh -i "$SYNOLOGY_SSH_KEY" -p "$SYNOLOGY_PORT" -o StrictHostKeyChecking=no "$SYNOLOGY_USER@$SYNOLOGY_HOST" << 'SYNOLOGY_CMD'
    # Altes Export-Verzeichnis löschen
    rm -rf /volume1/exported-html-daily
    mkdir -p /volume1/exported-html-daily
    cd /volume1/exported-html-daily
    
    # WordPress mit wget mirroring exportieren
    wget \
        --mirror \
        --page-requisites \
        --convert-links \
        --wait=0.5 \
        -q \
        --no-parent \
        http://192.168.1.183/wordpress/
    
    echo "✅ Export abgeschlossen"
SYNOLOGY_CMD

log "✅ WordPress Export auf Synology erfolgreich"

# 3. Dateien vom Synology herunterläden
log "📥 Kopiere Dateien vom Synology..."
rsync -av --delete \
    -e "ssh -i $SYNOLOGY_SSH_KEY -p $SYNOLOGY_PORT -o StrictHostKeyChecking=no" \
    "$SYNOLOGY_USER@$SYNOLOGY_HOST:/volume1/exported-html-daily/192.168.1.183/wordpress/" \
    "$TEMP_DIR/" \
    | tee -a "$LOG_FILE"

log "✅ Download erfolgreich"

# 4. Pfade in HTML/CSS/JS Dateien korrigieren
log "🔧 Korrigiere Pfade..."
find "$TEMP_DIR" \( -name "*.html" -o -name "*.css" -o -name "*.js" \) -type f | while read file; do
    # Entferne lokale IP-Referenzen und ersetze durch Cloudflare Pages Domain
    sed -i '' 's|http://192\.168\.1\.183/wordpress/|/|g' "$file"
    sed -i '' 's|http://192\.168\.1\.183|https://hildvision.pages.dev|g' "$file"
    sed -i '' "s|'http://192\.168\.1\.183/wordpress/|'/|g" "$file"
    sed -i '' "s|'http://192\.168\.1\.183|'https://hildvision.pages.dev|g" "$file"
done

log "✅ Pfade korrigiert"

# 5. Alte public/ Dateien sichern
log "🔄 Sichere alte Dateien..."
if [ -d "$LOCAL_PUBLIC" ]; then
    rm -rf "$LOCAL_PUBLIC.backup"
    cp -r "$LOCAL_PUBLIC" "$LOCAL_PUBLIC.backup"
fi

# 6. Neue Dateien ins public/ Verzeichnis kopieren
log "📂 Verschiebe Dateien ins public/ Verzeichnis..."
rm -rf "$LOCAL_PUBLIC"
mkdir -p "$LOCAL_PUBLIC"

# Kopiere alle Dateien
if [ -d "$TEMP_DIR" ]; then
    cp -r "$TEMP_DIR"/* "$LOCAL_PUBLIC/" 2>/dev/null || true
fi

# 7. Synology Systemordner (.#recycle) entfernen
log "🧹 Räume auf..."
find "$LOCAL_PUBLIC" -name "#recycle" -type d -exec rm -rf {} + 2>/dev/null || true

# Prüfe ob Dateien kopiert wurden
FILE_COUNT=$(find "$LOCAL_PUBLIC" -type f 2>/dev/null | wc -l)
log "📊 Dateien im public/ Verzeichnis: $FILE_COUNT"

if [ "$FILE_COUNT" -eq 0 ]; then
    log "⚠️  WARNUNG: Keine Dateien gefunden! Prüfe SSH-Verbindung und Synology-Export."
fi

# 8. Git Operationen
log "💾 Git: add, commit, push..."
cd "$LOCAL_REPO"

# Konfiguriere git
git config user.email "gammas.summer_2v@icloud.com" 2>/dev/null || true
git config user.name "Markus" 2>/dev/null || true

# Entferne alte Lock-Datei
rm -f .git/index.lock 2>/dev/null || true

# Git Status
git add -A

# Prüfe ob es Änderungen gibt
if git diff --cached --quiet; then
    log "ℹ️  Keine Änderungen seit letztem Deploy"
else
    git commit -m "Auto-export WordPress $(date '+%Y-%m-%d %H:%M:%S')" || true
    git push origin main 2>&1 | tee -a "$LOG_FILE"
    log "✅ Erfolgreich zu GitHub gepusht"
fi

# 9. Cleanup
log "🧹 Bereinige Temp-Verzeichnis..."
rm -rf "$TEMP_DIR"

log "=== ✅ Hildvision Export & Deploy erfolgreich abgeschlossen ==="
