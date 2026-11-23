# Web de Cala

Abre [`design/index.html`](design/index.html) con doble clic. Es el prototipo v7 aprobado y funciona sin servidor.

| Referencia | Fuente de verdad |
| --- | --- |
| Apariencia, interacciones y textos de v7 | [`design/index.html`](design/index.html) |
| Reglas de diseño, inventario de componentes y pendientes | [`design/DESIGN.md`](design/DESIGN.md) |
| Valores CSS y condiciones, reutilizables en la implementación | [`design/tokens.css`](design/tokens.css) |
| Intercambio DTCG y metadatos CSS para generar el tema | [`design/tokens.json`](design/tokens.json) |
| Sprite, incluidas definiciones compartidas | [`design/icons.svg`](design/icons.svg) |
| Mensajes completos por idioma | [`design/i18n/es.json`](design/i18n/es.json) · [`design/i18n/en.json`](design/i18n/en.json) |
| Propuestas anteriores | [`design/archive/`](design/archive/) |

Con Playwright y Chromium disponibles, ejecuta `node website/design/verify-tokens.cjs` desde el repo. Si Playwright vive fuera del repo, `CALA_PLAYWRIGHT_MODULE` admite su ruta. Opcionalmente usa `CALA_CHROMIUM_EXECUTABLE` y `CALA_CHROMIUM_ARGS` para elegir el navegador y sus argumentos (array JSON).

El siguiente paso, pendiente de autorización del owner, es implementar la web en Next.js y desplegarla en Vercel desde este repo.
