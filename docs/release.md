# Release: publicar una versión

Cala se reparte **gratis y sin firma de Apple**. Los usuarios la desbloquean una vez al abrirla por primera vez, y el README (inglés, `README.md`, y español, `README.es.md`) explica cómo. Si algún día quieres quitar ese paso, la firma con Developer ID está más abajo (cuesta 99 USD al año).

## Publicar una versión gratuita (el camino normal)

### Preparar la clave de actualizaciones

El dueño genera la clave una vez, en su propia Terminal, desde la raíz del repo.

```bash
swift scripts/update-sign.swift generate --out ~/.config/cala/update-signing-key.json
```

La clave privada Ed25519 se guarda cifrada con una frase de al menos 12 caracteres en `~/.config/cala/`. El directorio tiene permisos 700 y el archivo 600. El comando pide la frase dos veces sin mostrarla y se niega a sobrescribir una clave existente. Guarda una copia del archivo cifrado y la frase en tu gestor de contraseñas. La clave privada nunca entra al repositorio ni al bundle.

Copia únicamente la línea de clave pública que imprime el comando a `packaging/update-public-keys` y súbela en un commit. El archivo admite hasta dos claves, una por línea. Si queda vacío, el build se instala manualmente y no ofrece actualizaciones dentro de Cala.

Para tener una clave de recuperación, ejecuta el mismo comando con `--out ~/Desktop/update-recovery-key.json`, agrega su clave pública en la segunda línea y guarda el archivo cifrado y su frase en el gestor. Elimina la copia del Escritorio. Si pierdes la clave principal, firma la próxima versión con una copia de la clave de recuperación en `~/.config/cala/update-signing-key.json`. Esa versión lleva la clave pública de recuperación y la nueva clave pública principal. Después puedes firmar con la nueva principal y rotar también la de recuperación.

### Configurar otra Mac

Crea el directorio con modo 700 y copia `update-signing-key.json` desde tu gestor de contraseñas a `~/.config/cala/update-signing-key.json`. Desde la raíz del repositorio, deja el archivo con modo 600 y guarda la frase una vez en el Llavero.

```bash
mkdir -p -m 700 ~/.config/cala
# Copia aquí el archivo desde tu gestor de contraseñas.
chmod 600 ~/.config/cala/update-signing-key.json
./scripts/ship.sh --save-passphrase
```

Pega la frase de firma de Cala en los dos avisos de `security`. El comando la guarda en el Llavero de inicio de sesión, que es el predeterminado en macOS, y comprueba que abre el archivo cifrado. Si la comprobación falla, borra el registro. En cada publicación, `/usr/bin/security` lee la frase y la entrega al firmante por una tubería. Si falta el registro o la frase guardada no abre la clave, el firmante pide la frase en la Terminal.

Cualquier proceso que se ejecute con tu usuario puede leer la frase guardada mediante `/usr/bin/security` mientras el Llavero esté desbloqueado. Guardarla es una opción de comodidad. Puedes publicar introduciendo la frase en la Terminal cada vez.

Inicia sesión en GitHub con `gh auth login` si es la primera vez.

Para borrar el registro guardado, por ejemplo al rotar la clave, ejecuta:

```bash
./scripts/ship.sh --forget-passphrase
```

### Publicar e instalar

Escribe las dos [notas de release](releases/README.md) de la próxima versión y haz commit de ambas junto con el cambio en `main`. Por ejemplo, para la versión 1.0.1 escribe `docs/releases/1.0.1.en.md` y `docs/releases/1.0.1.es.md`. Mantén ambas breves, en lenguaje sencillo y centradas en los cambios para el usuario.

```bash
./scripts/ship.sh --dry-run
./scripts/ship.sh
```

El incremento por defecto es `patch`. Puedes indicar `minor`, `major` o una versión explícita como `1.2.0`. La simulación ejecuta los checks en una copia temporal y muestra el plan sin crear el commit, publicar ni instalar. Admite cambios locales para poder probar el flujo antes de hacer commit.

`ship.sh` exige `main` limpio para publicar. Comprueba los correos de autor y committer del historial, ejecuta los checks, exige las notas en ambos idiomas y crea el commit local `Release <versión>`.

`release.sh [commit]` compila en un checkout temporal del commit elegido (HEAD por defecto) y genera el DMG, su `.sha256` y `build/latest.json` firmado con el SHA completo del commit. Una vez terminado el build, `ship.sh` prepara el tag local y sube `main` y el tag juntos con un push atómico por HTTPS usando la sesión de `gh`.

`publish-github.sh` monta y verifica una copia privada del DMG, comprueba el manifiesto y el tag, y sube los archivos y las notas a un borrador. Antes de publicarlo, `ship.sh` descarga el manifiesto del borrador, verifica la firma y lo compara con `build/latest.json`. Tras publicar, repite la comprobación desde la URL pública sin autenticación durante un máximo aproximado de tres minutos. Si falla, intenta devolver la publicación a borrador. Si pasa, ejecuta `./install.sh`.

Si falla el build, la subida o la verificación, vuelve a ejecutar `./scripts/ship.sh` con el commit `Release <versión>` en HEAD. El script conserva la versión y reutiliza el tag y el borrador si ya existen. Si se interrumpió durante la comprobación pública, retoma esa comprobación. Cuando el release ya se publicó y solo falla la instalación, vuelve a ejecutar `./install.sh`.

Cala 1.0.0 se actualiza a mano una vez para instalar la primera versión que incluye el actualizador.

**Antes de la primera versión pública:**
- El repositorio tiene que ser **público**; si no, nadie fuera de él puede descargar el DMG. Se cambia en *Settings → General → Danger Zone → Change visibility* en GitHub.
- La licencia es PolyForm Noncommercial 1.0.0 (`LICENSE`): uso y modificación gratis sin fines comerciales; vender o usar el código comercialmente requiere tu permiso. Como autor puedes vender Cala o cambiar la licencia de versiones futuras.
- Opcional: `CALA_SENTRY_DSN` para que *Reportar un problema* envíe informes. Sin él, los usuarios usan *Copiar informe* y lo pegan en un issue.

**Instalador de una línea:** `scripts/get-cala.sh` toma siempre la última release publicada (API de GitHub), verifica el `.sha256` que sube `publish-github.sh`, instala en `/Applications` si es escribible o en `~/Applications` si no lo es, y abre Cala sin el bloqueo de Gatekeeper (curl no marca la descarga). Necesita que el repo sea público y que la release tenga el `.dmg` y el `.dmg.sha256`. Para probarlo con un build local: `CALA_DMG_URL=file://$PWD/build/Cala-X.dmg CALA_SHA_URL=file://$PWD/build/Cala-X.dmg.sha256 bash scripts/get-cala.sh`.

**Cómo probar una versión antes de publicarla:** en otra Mac u otra cuenta de usuario, descarga el DMG del borrador y sigue el README tal cual. En la Mac donde se compiló no aparece el bloqueo de macOS (macOS recuerda que los archivos se crearon ahí), así que ahí no sirve como prueba.

### Sobre la firma ad-hoc

Las versiones gratuitas se firman "ad-hoc" con un requisito fijo al bundle id. Así macOS **conserva los permisos al actualizar**: el usuario no tiene que volver a dar Accesibilidad ni Grabación de pantalla con cada versión. A cambio, otra app firmada ad-hoc con el mismo bundle id podría heredar esos permisos. Para eso tendría que estar ya ejecutándose en la Mac del usuario, así que es un riesgo bajo; la firma Developer ID lo elimina. Los builds ad-hoc también llevan el hardened runtime con `packaging/Cala.entitlements`, igual que los firmados.

### Ayudante del Llavero (`cala-keychain`)

Las contraseñas de Correo solo las toca `Cala.app/Contents/Helpers/cala-keychain` (fuente: `Helpers/cala-keychain/main.c`). Es un binario precompilado y firmado ad-hoc **una sola vez**, guardado en el repo como `packaging/Helpers/cala-keychain` junto a `packaging/Helpers/cala-keychain.cdhash` (SHA-256 y cdhash por arquitectura). `build.sh` lo copia byte a byte y, en ad-hoc, sin volver a firmarlo; falla si `scripts/verify-keychain-helper.sh` no cuadra o si el bundle id, el identificador de firma (`local.cala.keychain`) o el Team ID no coinciden. Detalles en [architecture.md](architecture.md#code-signing-and-permissions).

- **No lo recompiles a la ligera.** El Llavero confía en el ayudante por su cdhash: un binario nuevo significa que **cada usuario** verá otra vez el aviso «cala-keychain quiere acceder…» una vez por cuenta. Solo por un bug del ayudante o un cambio de macOS mínimo (`MIN_MACOS` en el script, igual que en `build.sh` y `Package.swift`).
- **Cómo:** primero `scripts/build-keychain-helper.sh --test DIR` (variantes de prueba que nunca se publican), luego `scripts/build-keychain-helper.sh --yes` (sin `--yes` se niega). Regenera el binario y el `.cdhash`; compruébalo con `scripts/verify-keychain-helper.sh packaging/Helpers/cala-keychain --cdhash`.
- **Commit:** `Helpers/` y `packaging/Helpers/` van juntos en el mismo commit, y el binario con permiso de ejecución (`git ls-files -s packaging/Helpers/cala-keychain` debe mostrar `100755`). El binario publicado tiene que salir de ese `main.c`.
- **`CALA_BUNDLE_ID`:** solo letras, dígitos, puntos y guiones. El ayudante sirve a la app cuyo `CFBundleIdentifier` declara el bundle que lo contiene, así que cambiar el id no exige recompilarlo; `build.sh` exige que el Info.plist y la firma de la app usen ese mismo id.
- **Developer ID:** `build.sh` vuelve a firmar la copia del ayudante con la identidad (hardened runtime, timestamp, identificador `local.cala.keychain`; la notarización lo exige) y exige el mismo Team ID que la app. El Llavero pasa a confiar en la firma del equipo, estable entre versiones; pasar de ad-hoc a Developer ID (o al revés) pide el aviso una vez más por cuenta. En este modo, si el sistema no da una comprobación anti-carrera, el ayudante falla cerrado (código 78, «Reinicia tu Mac…»); en ad-hoc la omite. Lo que protege: en ad-hoc solo frena llamadas accidentales u ocasionales (un atacante local puede firmar cualquier programa con cualquier identificador); con Developer ID solo atiende código firmado por ese equipo con el bundle id de Cala.

## Opcional: firma Developer ID y notarización (de pago)

### Por qué y cuánto cuesta

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

### Una sola vez

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
4. **Decide el bundle id definitivo antes del primer release público**, por ejemplo `com.tudominio.cala`. Cambiarlo después hace que macOS trate la app como otra: cada usuario tendría que volver a dar todos los permisos. El valor por defecto `local.cala` funciona, pero no es un identificador propio. El ayudante del Llavero (`Contents/Helpers/cala-keychain`) lee el bundle id de la app que lo contiene, así que no hay que recompilarlo al cambiarlo; `build.sh` falla si el id, la firma o el Team ID no cuadran.
5. **(Opcional) DSN de Sentry** para *Reportar un problema* y los informes de fallo. Sin él, la ventana de reporte dice que el envío no está activado en esa versión. El DSN no se guarda en el repo.

### Cada release firmado

```bash
# Variables (ponlas en tu shell o en un archivo fuera del repo)
export CALA_SIGN_IDENTITY="Developer ID Application: Tu Nombre (TEAMID)"
export CALA_NOTARY_PROFILE=cala-notary
export CALA_BUNDLE_ID=com.tudominio.cala      # el que decidiste
export CALA_SENTRY_DSN="https://…@….ingest.sentry.io/…"   # opcional

# Publica e instala desde main, con las notas ya comprometidas
./scripts/ship.sh minor
```

La publicación incluye el DMG notarizado, su `.sha256` y `latest.json`.

Para probar la firma antes de tener las credenciales de notarización:
```bash
CALA_SKIP_NOTARIZE=1 ./scripts/release.sh
```

#### Qué comprueba `release.sh`

- Ejecuta todos los `scripts/check-*.sh` antes del build y se detiene si falla alguno. Con `ship.sh`, los mismos checks se ejecutan antes del commit de versión y el build comprueba que el commit solo modificó `VERSION`. El checkout temporal contiene solo los archivos del commit, incluidos el código, la versión, las claves y las notas. [Inventario de checks](architecture.md#automated-checks)
- Vía `build.sh`: que el ayudante del Llavero sea el del repo (SHA-256 y, en ad-hoc, cdhash) y que bundle id, identificadores de firma y Team ID cuadren.
- Que la firma sea válida y que las entitlements estén puestas (`packaging/Cala.entitlements`: Apple Events para Finder, Calendario y Ubicación; nada más).
- Que notarytool devuelva *Accepted*. Si no, imprime el `id` para pedir el log con `xcrun notarytool log <id> --keychain-profile cala-notary`.
- `spctl` sobre la app y el DMG cuando se ejecuta la notarización.
- Que la versión supere el último tag numérico, que existan ambas notas y que el entorno no tenga ninguna variable `CALA_UPDATE_*`.
- Que la firma de `latest.json` corresponda a una clave pública comprometida y que el tamaño y el SHA-256 correspondan al DMG. En el volumen montado verifica claves, URL, identidad, versión, build, hash del ayudante del Llavero y ausencia de ajustes de prueba.

#### Después de publicar

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
| `CALA_BUILD_DIR` | Directorio del bundle y los artefactos de distribución | `build` |
| `CALA_SENTRY_DSN` | Destino de *Reportar un problema* | vacío (reportes apagados) |
| `CALA_NOTARY_PROFILE` | Perfil de `notarytool store-credentials` | — |
| `CALA_NOTARY_KEY`, `CALA_NOTARY_KEY_ID`, `CALA_NOTARY_ISSUER` | API key de App Store Connect, para CI | — |
| `CALA_APPLE_ID`, `CALA_TEAM_ID`, `CALA_APP_PASSWORD` | Apple ID + contraseña de app | — |
| `CALA_SKIP_NOTARIZE` | `1` = firma sin notarizar | — |

## Desarrollo local

`./install.sh` compila y usa un directorio privado del mismo volumen que `/Applications` para intercambiar el bundle de forma atómica. Instala sin sudo cuando el usuario tiene acceso suficiente a `/Applications` y al bundle anterior. Si encuentra una copia antigua sin permisos de escritura, pide sudo. La copia nueva queda a nombre del usuario, con grupo `admin` y escritura para el grupo, y Cala se abre en la sesión que ejecutó el instalador. Las otras sesiones detectan el build nuevo y se reinician cuando pueden hacerlo. [Configuración de otras cuentas](setup.md#other-user-profiles)

El build ad-hoc fija el *designated requirement* al bundle id, así macOS conserva los permisos entre recompilaciones. Un build firmado con Developer ID tiene otro requisito, así que la primera vez que pases de uno a otro macOS vuelve a pedir los permisos (y el aviso del Llavero de Correo, una vez por cuenta).

Para la [prueba integral del actualizador](updates.md#11-end-to-end-plan-the-fixture-ladder), `swift scripts/update-sign.swift testkey "$T/keys"` genera un par desechable y `scripts/make-update-fixture.sh --out "$T/f2" --version 0.0.2 --build 2 --keys "$T/keys"` prepara el DMG y el feed para el servidor local. Usa un `$T` temporal fuera del repositorio y bórralo al terminar. El firmante de producción solo acepta claves cifradas.
