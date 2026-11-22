# Release: firma, notarización y publicación

Nota para quien publica Cala. Todo el pipeline está en el repo y no contiene ningún valor personal: identidad, credenciales y DSN se pasan por variables de entorno.

## Por qué hace falta y cuánto cuesta

Sin firma Developer ID y notarización, cualquier Mac que descargue Cala de una web la bloquea al abrirla (Gatekeeper). En macOS 15 o más nuevo no hay forma rápida de saltarlo: el usuario tiene que ir a Ajustes del Sistema → Privacidad y seguridad → **Abrir igualmente** y escribir su contraseña. Casi nadie lo hace solo. Con firma y notarización, solo ve el aviso normal de "descargada de internet, ¿abrir?".

| Qué | Costo |
|---|---|
| Apple Developer Program (necesario para el certificado Developer ID) | **99 USD al año** (o su equivalente en tu moneda) |
| Notarización | Gratis, incluida en la membresía, sin límite práctico |
| Certificado Developer ID | Incluido. Dura 5 años |
| Xcode / herramientas | Gratis. Este pipeline solo usa las Command Line Tools |
| Alojar el DMG (GitHub Releases, tu web) | Gratis en GitHub Releases |

Si dejas de pagar la membresía, las versiones ya publicadas siguen abriendo (la firma lleva sello de tiempo y la notarización queda registrada), pero no puedes firmar versiones nuevas.

Comprobado en la máquina de desarrollo: `spctl` rechaza el build ad-hoc y su DMG ("rejected, no usable signature"), que es exactamente lo que verá otra Mac. En la propia Mac de desarrollo el bloqueo no aparece aunque el archivo esté marcado como descargado, porque macOS recuerda que los archivos se crearon ahí. Por eso **la prueba final se hace siempre en otra Mac u otra cuenta de usuario**, descargando el DMG publicado.

### Mientras no tengas la cuenta: versión de prueba

Puedes repartir el DMG ad-hoc (`./build.sh && ./scripts/make-dmg.sh`) a gente de confianza. El README explica cómo desbloquearlo una vez («Si macOS dice que no puede abrir Cala»). No lo publiques así para el público general.

## Una sola vez

1. **Cuenta de Apple Developer** (99 USD/año): https://developer.apple.com/programs/ — con una cuenta individual basta.
2. **Certificado Developer ID Application.** Hay dos caminos:
   - Con Xcode: Xcode → Settings → Accounts → tu cuenta → Manage Certificates → **+** → *Developer ID Application*.
   - Sin Xcode: developer.apple.com → Certificates → **+** → *Developer ID Application*. Para eso tienes que generar un CSR con *Acceso a Llaveros → Asistente de certificados → Solicitar un certificado de una autoridad*. Luego haces doble clic en el `.cer` descargado.

   Comprueba que quedó instalado:
   ```bash
   security find-identity -v -p codesigning
   ```
   Copia el nombre completo, `Developer ID Application: Tu Nombre (TEAMID)`.
3. **Credenciales de notarización** guardadas en el llavero. Elige un nombre de perfil, por ejemplo `cala-notary`:
   ```bash
   xcrun notarytool store-credentials cala-notary --apple-id TU_APPLE_ID --team-id TEAMID
   ```
   Te pide una **contraseña específica de app**, que se crea en https://account.apple.com → Inicio de sesión y seguridad → Contraseñas de apps. Para CI también puedes usar una API key de App Store Connect (ver `scripts/notarize.sh`).
4. **Decide el bundle id definitivo antes del primer release público**, por ejemplo `com.tudominio.cala`. Cambiarlo después hace que macOS trate la app como otra: cada usuario tendría que volver a dar todos los permisos. El valor por defecto `local.cala` funciona, pero no es un identificador propio.
5. **(Opcional) DSN de Sentry** para *Reportar un problema* y los informes de fallo. Sin él, la ventana de reporte dice que el envío no está activado en esa versión. El DSN no se guarda en el repo.

## Cada release

```bash
# 1. Sube la versión
echo 1.0.0 > VERSION && git commit -am "Version 1.0.0"

# 2. Variables (ponlas en tu shell o en un archivo que NO esté en el repo)
export CALA_SIGN_IDENTITY="Developer ID Application: Tu Nombre (TEAMID)"
export CALA_NOTARY_PROFILE=cala-notary
export CALA_BUNDLE_ID=com.tudominio.cala      # el que decidiste
export CALA_SENTRY_DSN="https://…@….ingest.sentry.io/…"   # opcional

# 3. Build universal + firma + notarización de la app + DMG + notarización del DMG + SHA-256
./scripts/release.sh
```

Resultado: `build/Cala-1.0.0.dmg` y `build/Cala-1.0.0.dmg.sha256`. **El script no sube nada.** Publicar el DMG (GitHub Releases, tu web…) es un paso manual.

Para probar la firma antes de tener las credenciales de notarización:
```bash
CALA_SKIP_NOTARIZE=1 ./scripts/release.sh
```

### Qué comprueba `release.sh`

- Que pasen `scripts/check-rules.sh`.
- Que la firma sea válida y que las entitlements estén puestas (`packaging/Cala.entitlements`: Apple Events para Finder, Calendario y Ubicación; nada más).
- Que notarytool devuelva *Accepted*. Si no, imprime el `id` para pedir el log con `xcrun notarytool log <id> --keychain-profile cala-notary`.
- `spctl` sobre la app y el DMG, es decir, lo mismo que mira Gatekeeper.

### Después de publicar

- Prueba el DMG descargado en otra Mac o en otra cuenta de usuario: doble clic, arrastrar a Aplicaciones y abrir. No debería salir ningún aviso de "desarrollador no identificado".
- Para Intel y macOS 14, el build es universal y apunta a macOS 14. **No se pudo probar en Intel ni en macOS 14 en la máquina de desarrollo**, así que hazlo en una Mac real o en una VM antes de anunciarlo.

## Variables de entorno

| Variable | Uso | Por defecto |
|---|---|---|
| `CALA_SIGN_IDENTITY` | Identidad de `codesign`. `-` es ad-hoc, solo para desarrollo | `-` |
| `CALA_BUNDLE_ID` | Bundle identifier | `local.cala` |
| `CALA_VERSION` | Versión visible | contenido de `VERSION` |
| `CALA_BUILD_NUMBER` | Número de build | número de commits |
| `CALA_ARCHS` | Arquitecturas | `arm64 x86_64` |
| `CALA_SENTRY_DSN` | Destino de *Reportar un problema* | vacío (reportes apagados) |
| `CALA_NOTARY_PROFILE` | Perfil de `notarytool store-credentials` | — |
| `CALA_NOTARY_KEY`, `CALA_NOTARY_KEY_ID`, `CALA_NOTARY_ISSUER` | API key de App Store Connect, para CI | — |
| `CALA_APPLE_ID`, `CALA_TEAM_ID`, `CALA_APP_PASSWORD` | Apple ID + contraseña de app | — |
| `CALA_SKIP_NOTARIZE` | `1` = firma sin notarizar | — |

## Desarrollo local

`./install.sh` compila (ad-hoc), reemplaza `~/Applications/Cala.app` y la abre. El build ad-hoc fija el *designated requirement* al bundle id, así macOS conserva los permisos entre recompilaciones. Un build firmado con Developer ID tiene otro requisito, así que la primera vez que pases de uno a otro macOS vuelve a pedir los permisos.
