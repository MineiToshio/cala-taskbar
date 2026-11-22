#!/bin/zsh
# Uploads build/Cala-<version>.dmg (made by scripts/release.sh) to GitHub Releases as a DRAFT, with notes that tell
# people how to install it. Review the draft on GitHub and press "Publish release" yourself.
# Needs the GitHub CLI (gh) logged in. The repository must be public for people without access to download it.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(tr -d '[:space:]' < VERSION)
DMG=build/Cala-$VERSION.dmg
[[ -f "$DMG" && -f "$DMG.sha256" ]] || { echo "Run ./scripts/release.sh first" >&2; exit 1; }
built=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Cala.app/Contents/Info.plist)
[[ "$built" == "$VERSION" ]] || { echo "build/Cala.app is $built but VERSION is $VERSION; run ./scripts/release.sh" >&2; exit 1; }
SUM=$(cut -d' ' -f1 "$DMG.sha256")
notes=$(mktemp); trap 'rm -f "$notes"' EXIT
cat > "$notes" <<NOTES
## Instalar

1. Descarga **Cala-$VERSION.dmg** (abajo, en *Assets*), ábrelo y arrastra **Cala** a **Aplicaciones**.
2. La primera vez macOS la bloquea porque Cala es gratis y no está firmada por Apple:
   - **macOS 15 o más nuevo:** abre Cala → **Listo** → *Ajustes del Sistema → Privacidad y seguridad* → **Abrir igualmente** → vuelve a abrir Cala → **Abrir igualmente**.
   - **macOS 14:** clic derecho sobre Cala → **Abrir** → **Abrir**.
3. Sigue la bienvenida. Guía completa: [README](https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)#instalar).

Requiere macOS 14 o más nuevo · Apple silicon e Intel · SHA-256: \`$SUM\`

---
*English:* download the DMG, drag Cala to Applications. First launch on macOS 15+: open it, press Done, then System Settings → Privacy & Security → **Open Anyway**. On macOS 14: right-click → Open.
NOTES
gh release create "v$VERSION" "$DMG" "$DMG.sha256" --draft --title "Cala $VERSION" --notes-file "$notes"
echo "Borrador creado. Revísalo y publícalo en GitHub: gh release view v$VERSION --web"
