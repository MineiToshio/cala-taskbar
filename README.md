# Cala

Una barra de tareas para tu Mac: tus apps abajo, con miniaturas de cada ventana, y a la derecha Wi‑Fi, sonido, batería, disco, calendario y un panel que te explica por qué tu Mac va lento.

*English version below.*

## Instalar

Necesitas macOS 14 (Sonoma) o más nuevo. Funciona en Macs con Apple silicon y con Intel.

1. Descarga **Cala‑x.y.z.dmg** y ábrelo con doble clic.
2. En la ventana que aparece, **arrastra Cala a la carpeta Aplicaciones**.
3. Abre **Aplicaciones** y haz doble clic en **Cala**. Si macOS pregunta si quieres abrirla, elige **Abrir**.
4. Sigue la bienvenida. Son cuatro pasos y puedes saltar cualquiera.

Si abriste Cala directamente desde la descarga, la bienvenida te ofrece **Mover y reabrir**: la copia a Aplicaciones por ti.

## Los permisos, uno por uno

Cala pide cada permiso con una frase que dice para qué sirve y un botón que abre el panel justo de **Ajustes del Sistema**. Cuando lo activas, Cala lo nota sola: no hace falta reiniciarla.

| Permiso | Para qué | Si no lo das |
|---|---|---|
| Accesibilidad | Ver, enfocar, minimizar y cerrar las ventanas de tus apps; el selector Opción+Tab | La barra igual muestra y abre tus apps, pero sin manejar ventanas |
| Grabación de pantalla | Las miniaturas de las ventanas al pasar el mouse | No hay miniaturas. Cala nunca graba ni envía tu pantalla |
| Calendario | Tus próximos eventos y el botón Unirse a videollamadas | El panel del reloj no muestra eventos |
| Ubicación | macOS solo deja ver los nombres de las redes Wi‑Fi con este permiso | El panel de Wi‑Fi no muestra nombres de redes |
| Bluetooth | Ver y conectar tus dispositivos | El panel de Bluetooth no los lista |
| Controlar Finder | Contar y vaciar la Papelera, reiniciar el Mac cuando lo pides | Esas tres acciones no están disponibles |
| Notificaciones | Avisos de cuota de Claude o Codex (solo si los usas) | No hay avisos |

Para **Accesibilidad** y **Grabación de pantalla**, macOS abre una lista: activa el interruptor de **Cala**. Si después de Grabación de pantalla macOS ofrece **Salir y volver a abrir**, acéptalo.

¿Dijiste que no a algo? Cala sigue funcionando con lo demás. Actívalo cuando quieras en **Configuración → Permisos** (clic derecho en una zona vacía de la barra → Configuración…).

## Abrir al iniciar sesión

Lo eliges en el último paso de la bienvenida, o en **Configuración → General**. Aparece en **Ajustes del Sistema → General → Ítems de inicio**, donde también puedes apagarlo.

## Desinstalar

**Configuración → Avanzado → Desinstalar Cala…** Devuelve el Dock y la barra de menús a como estaban, deja de abrirse al iniciar sesión, borra los ajustes de Cala y mueve la app a la Papelera.

Si Cala no abre, también puedes arrastrar **Cala** desde Aplicaciones a la Papelera. Para quitarla del todo desde Terminal hay un script: `scripts/uninstall.sh` en el código fuente.

Los permisos que diste quedan listados en **Ajustes del Sistema → Privacidad y seguridad**; puedes quitarlos allí.

## Privacidad

Nada sale de tu Mac salvo que tú envíes un informe con **Reportar un problema…**. Antes de enviarlo ves exactamente qué se incluye; tu carpeta personal, nombre de usuario, nombre del Mac y correos se quitan del texto técnico. Si Cala se cierra sola, al volver a abrirla te pregunta si quieres enviar el informe del fallo (puedes cambiarlo en Configuración → Avanzado).

## Si algo no funciona

- **No veo miniaturas**: revisa Grabación de pantalla en Configuración → Permisos.
- **El Dock de macOS desapareció**: Cala lo oculta solo si lo pediste. Apágalo en Configuración → General → Ocultar el Dock de macOS, o sal de Cala: vuelve como estaba.
- **Quiero contar un problema**: clic derecho en la barra → Reportar un problema…

---

## English

A taskbar for your Mac: your apps at the bottom with window thumbnails, and Wi‑Fi, sound, battery, disk, calendar and a "why is my Mac slow" panel on the right. Requires macOS 14 or later, Apple silicon or Intel.

**Install:** open **Cala‑x.y.z.dmg**, drag **Cala** to **Applications**, open it from Applications and follow the four-step welcome. If you open it straight from the download, the welcome offers **Move and reopen**.

**Permissions:** each one comes with a sentence on what it is for and a button to the exact System Settings pane; Cala notices by itself when you allow it. Accessibility (manage windows, Option+Tab) and Screen Recording (thumbnails) are the two the bar is built on; Calendar, Location (Wi‑Fi names), Bluetooth, Finder control (Trash, restart) and Notifications are optional. Anything you skip can be turned on later in **Settings → Permissions**.

**Open at login:** last step of the welcome or **Settings → General**; it shows up in System Settings → General → Login Items.

**Uninstall:** **Settings → Advanced → Uninstall Cala…** puts the Dock and menu bar back, removes the login item and Cala's settings, and moves the app to the Trash.

**Privacy:** nothing leaves your Mac unless you send a report yourself, and you see exactly what is in it first.

Developers: see [docs/README.md](docs/README.md) and [docs/release.md](docs/release.md).
