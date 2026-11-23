# Cala para Mac · Sistema de diseño web v7

La referencia aprobada es [`index.html`](index.html). Ábrela directamente en un navegador. El HTML funciona por sí solo. [`tokens.css`](tokens.css) conserva las declaraciones reutilizables y su cascada. [`tokens.json`](tokens.json) ofrece el mismo inventario con tipos DTCG y metadatos de procedencia. Las ventanas, citas y lecturas de la demo son datos de ejemplo.

## 1. Dirección visual

- La marca usa el navy y la menta del logo. El escritorio combina un horizonte frío y textura fina. Los nueve temas de Cala aportan color a la barra y sus escenas.
- La barra se puede usar. Los paneles, el foco, las miniaturas y Opción+Tab son parte de la experiencia de producto. El titular y las dos ventanas iniciales dejan espacio para la barra y «Mira cómo funciona».
- Evitar beige, blobs morados, glassmorphism decorativo, píldoras como recurso visual general, numeración 01/02/03 de relleno, emoji, fotos de stock y testimonios inventados. Reservar las formas redondas para controles o estados que las necesiten, como los puntos de tema.
- Los textos explican una acción o una consecuencia concreta. Las simulaciones representan acciones reales de Cala con datos de ejemplo.

## 2. Color y contraste

| Token | Oscuro | Claro | Uso |
| --- | --- | --- | --- |
| `--navy` / `--navy-deep` / `--mint` | `#1c2944` / `#10192b` / `#8de4cd` | Los mismos | Marca, logo, horizonte y CTA del recorrido |
| `--bg` | `#0d1421` | `#f4f7fb` | Lienzo de página |
| `--surface` / `--card` / `--raised` | `#131e2f` / `#19263a` / `#223148` | `#eaf0f7` / `#fff` / `#e1eaf4` | Secciones, tarjetas y controles elevados |
| `--text` / `--muted` | `#f2f7ff` / `#b6c5d9` | `#142238` / `#425570` | Texto primario y secundario efectivos |
| `--window-muted` / `--bar-subtle` | `#b2c3da` / `#e9f1ff` | `#455a73` / `#3c4e66` en Sistema claro | Texto de apoyo en ventanas y bandeja. La página no define un tercer tono global |
| `--accent` / `--accent-ink` / `--accent-surface` | Menta / `#102a25` / `#1e3e3c` | `#146753` / `#fff` / `#d7efe7` | Enlaces, botones y foco general |
| `--line` / `--control-line` | `#324157` / `#647997` | `#bdccdf` / `#7186a0` | Separadores y límites de controles |
| `--warm` / `--warm-surface` | `#ffca8b` / `#392f28` | `#783e08` / `#faecda` | Texto y fondo de aviso general |
| `--quota-ok` / `--quota-warn` / `--quota-low` | `#65d5aa` / `#ffb340` / `#ff6961` | `#147d59` / `#c77700` / `#d70015` | Pintura de la cuota **restante**. Verde ≥25 %, ámbar <25 %, rojo <10 % |
| `--quota-warn-ink` / `--quota-low-ink` | `#ffb340` / `#ff8580` | `#824800` / `#b01322` | Textos de cuota en paneles sobre sus superficies |
| `--disk-purgeable` / `--disk-free` | Mezcla de 48 % de acento con tarjeta / `#728197` | Misma mezcla / `#9aa8bb` | Partes purgable y libre. La parte usada lleva el acento |

- **Foco:** contorno de 2 px en acento con separación de 4 px. La barra usa su tinta temática y separación de −2 px. Los controles de las ventanas usan `--window-ink`.
- **Confirmación y fallo:** copiar usa icono de check y texto en caso de éxito. Si falla, el estado indica cómo copiar manualmente. Comparten la superficie del aviso. El semáforo verde deshabilitado usa `#a0afc0`.
- **Disco:** la app usa naranja bajo 20 % libre y rojo bajo 10 %. La demo conserva los umbrales y sus tintas de bandeja con contraste. Para disco, Swift usa colores semánticos de macOS. La paleta hexadecimal de cuota viene de `Theme.swift`. [Cuota](../../Sources/Cala/Theme.swift#L45) · [Disco](../../Sources/Cala/Disk.swift#L32)
- **AA:** ≥4,5:1 para texto normal, ≥3:1 para texto grande e iconos informativos y límites que identifican controles. No comunicar estados solo con color. En la aceptación v7 se midieron 4,89:1 en hero y 6,79:1 en ventanas abiertas. La bandeja dio 4,72:1 en texto y 3,52:1 en iconos en su matriz de nueve temas. La última revisión de la sección inferior dio 4,98:1. Son mínimos de las muestras, no garantías para variantes futuras.

## 3. Temas de la barra

| ID | ES / EN | Gradiente base | Acento | Texto |
| --- | --- | --- | --- | --- |
| `system` | Sistema / System | `#344257 → #182438` oscuro · `#f4f8ff → #d4e0ee` claro | `#0a84ff` / `#007aff` | `#fcfdff` / `#142238` |
| `graphite` | Grafito / Graphite | `#2b2d31 → #1e1f22` | `#5b9dff` | `#fcfdff` |
| `midnight` | Medianoche / Midnight | `#141b3a → #0b1026` | `#7c9cff` | `#fcfdff` |
| `ocean` | Océano / Ocean | `#0e7490 → #1d4ed8` | `#7df9ff` | `#fcfdff` |
| `sunset` | Atardecer / Sunset | `#f97316 → #db2777` | `#fff1b8` | `#fcfdff` |
| `forest` | Bosque / Forest | `#14532d → #365314` | `#a3e635` | `#fcfdff` |
| `lavender` | Lavanda / Lavender | `#7c3aed → #c026d3` | `#f5d0fe` | `#fcfdff` |
| `candy` | Chicle / Candy | `#fbcfe8 → #bae6fd` | `#db2777` | `#17233a` |
| `snow` | Nieve / Snow | `#f8fafc → #e2e8f0` | `#2563eb` | `#17233a` |

Aplicar `data-theme` al escritorio o escena. La barra usa `--bar-paint` si existe y, en los demás temas, los dos extremos a 90°. Sistema web simula el material nativo con pintura translúcida. Océano, Atardecer y Lavanda añaden capas para mantener contraste. Atardecer cambia su máscara desde 1350 px. Mantener el tema de origen en los paneles y miniaturas aunque en Next.js se monten en un portal. Fondo del panel = 92 % de `--panel-base` + extremo inicial. Superficies y bordes derivan de mezclas con el texto, tal como se declaran en los tokens. Las ventanas del escritorio usan su propia paleta según el esquema del navegador. El rango de transparencia 0–80 % corresponde a la app. [HTML](index.html#features) · [Temas nativos](../../Sources/Cala/Theme.swift#L11)

## 4. Tipografía

Usar la pila `-apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif`. Mono para comando, prompt y lecturas de bandeja con `ui-monospace, "SF Mono", Menlo, monospace`. Los valores de abajo son CSS, con el peso efectivo de la regla de origen cuando está declarado.

| Nivel | Tamaño y tratamiento |
| --- | --- |
| H1 escritorio EN | `clamp(43px, min(6.4vw, calc(14vh - 32px)), 94px)` · 735 · interlínea 0,97 · tracking −0,052 em |
| H1 escritorio ES | `clamp(41px, min(5.7vw, calc(13.8vh - 42.2px)), 82px)`. Misma composición base |
| H1 móvil | `clamp(43px, 9.2vw, 58px)`. Primer tramo en español a 0,9 em |
| H2 / H3 | H2 `clamp(32px, 4.1vw, 54px)`, 720, tracking −0,05 em. H3 base 22 px, tracking −0,025 em. Interlínea de encabezados 1,1 |
| Cuerpo / entradilla | 16 px / 1,55. Entradilla escritorio 15–21 px según ancho y alto. Móvil 14 px / 1,4 |
| Copia de funciones / permisos | 15 px / 14 px. Mantener límites de línea de cada tarjeta |
| Rótulos, leyendas y comandos | Según componente, normalmente 10–13 px. Lecturas 11 px mono, 9 px en móvil. Comando de instalación inferior 13 px / 1,55 |

## 5. Espaciado y rejilla

| Área | Regla |
| --- | --- |
| Escala / contenedor | 4, 8, 12, 16, 24, 32, 48, 64, 96 px. `--wrap: 1232px`. Gutter `clamp(16px, 4vw, 48px)`. Sección `clamp(64px, 8vw, 120px)` |
| Escritorio | Dos columnas entre titular y ventanas, relación 1:1,04. El ancho adapta el texto y el alto ajusta el espacio del hero sin desplazar la barra del primer pantallazo entre 700 y 1100 px de alto |
| Barra | 66 px escritorio y 99 px móvil desde el corte 767/768. Mosaico de app 34×34 px escritorio y 29×29 px móvil. Separar paneles 6 px. En móvil elegir espacio visible, abrir debajo si hace falta y cerrar cuando el ancla sale de pantalla |
| Selector | Nueve puntos de 12 px en objetivos de 26×26 px según regla efectiva. Cerca de la barra, bajo ella en móvil. Mantiene nombres accesibles y tooltip |
| Funciones | Dos columnas con gap `clamp(14px, 2vw, 26px)` y Temas a todo el ancho. Una columna hasta 700 px. Ajustes en 520 px para elementos de escena. FAQ a una columna hasta 670 px |
| Instalación / permisos / privacidad | Instalación y permisos cambian distribución hasta 710 px. Privacidad ajusta su rejilla hasta 850 y 520 px. No tratar los umbrales de componentes como un único breakpoint de página |
| Móvil y rangos de QA | Titular, controles de demo, barra, temas, CTA de instalación y una ventana visible. Barrer ancho 360–1920 px en ambos idiomas. Medir alto en escritorio con navegación incluida |

Las media queries completas se enumeran en los tokens. Los umbrales se replican como constantes de consulta, ya que `var()` no se evalúa dentro de una media query nativa.

## 6. Radios, bordes y materiales

| Elemento | Regla |
| --- | --- |
| Radios base | `--r-control: 8px`, `--r-card: 12px`, `--r-window: 20px`. Las ventanas de hero usan 13 px en escritorio y 9 px en móvil. Las tarjetas de funciones usan 15 px |
| Hairlines | Bordes de 1 px en `--line` o `--control-line`. Ventanas usan `--window-border` con alfa. Semáforos y toggles indican estado también por forma o texto |
| Elevación | `--shadow: 0 14px 38px #080e1990` en oscuro y `0 14px 38px #425e8533` en claro. `--desktop-shadow` guarda tres capas para la ventana activa |
| Material | `--material` alfa 0,91 oscuro / 0,93 claro. Barra con `blur(18px)`. Panel de la demo efectivo sin blur y con fondo derivado del tema |
| Capas | Escritorio aislado. Wallpaper −1, hero 1, `demo-dock` 2. En el dock, barra 4, puntos 5, panel 6 y ayuda 7. Fantasma de ventana 5 y cursor 9 dentro del escritorio. Los z-index son locales al contexto |

## 7. Movimiento

| Acción | Tiempo y curva |
| --- | --- |
| Entrada hero | Copia 540 ms con retraso 40 ms y ventanas 650 ms con 140 ms, `cubic-bezier(.22,.72,.29,1)`. Barra con `taskbar-in` 400 ms `ease-out`. Caption 480 ms con 210 ms |
| «Mira cómo funciona» | Halo de opacidad y escala, 4 s, retraso 1 s, `ease-in-out`. El control permanece operable |
| Ventana al dock | 400 ms, `cubic-bezier(.55,.02,.41,1)`. El fantasma se encoge hacia el icono y desaparece. El estado cambia al minimizar |
| Cambio de tema | Crossfade de pared 420 ms y barra 360 ms, `ease`. Conservar la legibilidad al cambiar de polaridad |
| Paneles y copia | Panel en vivo 190 ms `ease-out` con retraso de 220 ms en recorrido. Check animado 240 ms de `ease-out`, confirmación vía texto y `aria-live` |
| Recorrido | 14 pasos y unos 40 s. Aproximación 530 ms, cursor `transform` 550 ms con `cubic-bezier(.25,.8,.32,1)`, pulsación 230 ms. Lectura 2300 ms. En IA móvil, 1000 ms en Claude y el resto en Codex. Pausa, Cerrar, Esc y salida por Tab. Restaurar ventanas y tema inicial |
| Revelado inferior | `IntersectionObserver` al 45 %, una vez. Panel 420 ms tras 240 ms, medidores 650 ms tras 480 ms con `cubic-bezier(.2,.7,.25,1)`. Puntero 600 ms `ease-out`. Resaltados por escena y apertura de disclosure en el CSS |

Priorizar `transform` y `opacity`; el halo y las capas se componen por separado. Con `prefers-reduced-motion` no hay entradas, crossfades ni minimización animada. El recorrido avanza con Siguiente, sin cursor simulado, y muestra Claude y Codex juntos. El salto desde Archivos es inmediato con movimiento reducido.

## 8. Iconografía

El [sprite SVG](icons.svg) es una copia exacta de las definiciones aprobadas, con sus IDs, logo, degradados y paisaje. Insertarlo una vez en el layout de Next.js, antes de sus usos, con su contenedor de 0×0 y `aria-hidden="true"`. Mantener los IDs y las referencias internas. Para cada icono decorativo, usar `<svg className="icon" aria-hidden="true"><use href="#i-wifi" /></svg>` dentro de un control con texto o nombre accesible. La clase `.icon` usa `fill: none`, `stroke: currentColor`, ancho y alto de 1,15 em, trazo de 1,65 y remates y uniones redondos. Los rellenos puntuales y las excepciones quedan definidos en el sprite. El paisaje debe quedar inline para heredar los tokens de cada escena.

| Pieza | Referencia nativa | Web |
| --- | --- | --- |
| Inicio | [`square.grid.2x2.fill`](../../Sources/Cala/BarView.swift#L162) | `i-grid`, cuatro cuadrados llenos |
| Más | [`chevron.up`](../../Sources/Cala/Overflow.swift#L77) | `i-more`, chevrón |
| Wi‑Fi | [`wifi` y variantes](../../Sources/Cala/Overflow.swift#L24) | `i-wifi`, arcos y punto |
| Claude / Codex | [`ProviderMark`, dibujos propios, sin SF Symbol](../../Sources/Cala/BarView.swift#L351) | `i-provider-spark` y `i-provider-prompt`. Estrella y símbolo de terminal en nube, idénticos en las dos escenas |
| CPU / Disco | [`cpu` / `internaldrive`](../../Sources/Cala/Overflow.swift#L63) | `i-cpu` / `i-disk`, chip y unidad. Porcentajes de ejemplo |
| Batería / ahorro | [Familia `battery.*`](../../Sources/Cala/Overflow.swift#L29) · [`leaf.fill`](../../Sources/Cala/Flyout.swift#L371) | `i-battery`, `i-battery.100`, `i-leaf` |
| Reloj / Calendario / Unirse | [Reloj textual](../../Sources/Cala/BarView.swift#L218-L219) · [`video.fill`](../../Sources/Cala/BarView.swift#L196) · [Controles del mes](../../Sources/Cala/Flyout.swift#L433) | Fecha y hora locales. `i-calendar` para escenas, `i-video` para la cita y chevrones para cambiar de mes |
| Mostrar escritorio | [Franja al extremo](../../Sources/Cala/BarView.swift#L67) | Línea CSS y botón con nombre accesible, sin pictograma |
| Teclado / Bluetooth | [`keyboard` y `BluetoothShape`](../../Sources/Cala/Overflow.swift#L43) | `i-keyboard`, `i-bluetooth` |
| Brillo / Sonido | [`sun.max.fill` y altavoz](../../Sources/Cala/Overflow.swift#L54) · [`speaker.fill` / ondas](../../Sources/Cala/Flyout.swift#L177) | `i-sun`, `i-sun.min`, familia `i-speaker.*` y `i-sound` |
| Perfiles / Descargas / Papelera | [`person.crop.circle`, `arrow.down.circle`, `trash`](../../Sources/Cala/TrayLayout.swift#L37) | `i-person`, `i-download-circle`, `i-trash` |
| Buscar / Pantalla / Cerrar | [`magnifyingglass`](../../Sources/Cala/Overflow.swift#L224) · [`display`](../../Sources/Cala/SettingsWindow.swift#L565) · [`xmark`](../../Sources/Cala/Preview.swift#L67) | `i-search`, `i-display`, `i-close`. Los iconos de Archivos, Notas, Navegador y Terminal son mosaicos genéricos del prototipo |

Orden visible de la demo: Más, Wi‑Fi, IA, CPU, Disco, Batería, Reloj y Mostrar escritorio. Más contiene Teclado, Bluetooth, Brillo, Sonido, Perfiles, Descargas y Papelera. Sonido viene visible por defecto en la app y puede moverse. El hover de la bandeja muestra tooltip y el clic abre el panel. [Configuración real](../../Sources/Cala/TrayLayout.swift#L25) · [Hover y clic nativos](../../Sources/Cala/main.swift#L353)

## 9. Componentes y mapeo a Next.js

Propuesta de estructura para la implementación futura. **S** = Server Component, **C** = Client Component o isla interactiva.

```text
app/[locale]/page.tsx                 S · compone la página y carga mensajes
components/layout/
  SiteHeader.tsx, SiteFooter.tsx      S · navegación, marca y enlaces
  LanguagePicker.tsx                 C · elección y persistencia
components/hero/
  Hero.tsx                           S · titular, instalación y fondo
  DesktopDemo.tsx, DemoWindow.tsx    C · foco, estado de ventanas y puntero
  Taskbar.tsx, Flyout.tsx             C · apps, bandeja, reloj y paneles
  WindowSwitcher.tsx, ThemePicker.tsx C · Opción+Tab, radios y tema activo
  GuidedTour.tsx                     C · cursor, pasos, pausa y restauración
components/sections/
  Features.tsx, Installation.tsx     S · siete tarjetas y pasos terminal/DMG
  FeatureScene.tsx                   C · reproducción al entrar en pantalla
  InstallTerminal.tsx                C · semáforos, copiar y reabrir
  Permissions.tsx, Privacy.tsx       S · texto, flujos y consecuencias
  PermissionDemo.tsx                 C · switches de simulación
  Faq.tsx                            S · details/summary nativos
components/shared/CopyButton.tsx     C · Clipboard API, fallback y feedback
```

| Componente | Anatomía, estados e interacción |
| --- | --- |
| Cabecera | Marca y enlaces, selector nativo de idioma. Skip link salta a `#main` |
| Escritorio y ventanas | Título, cuerpo y rojo/amarillo/verde con nombres accesibles. Foco o clic trae al frente. Arrastre sobre título con puntero. Minimizada aparece en miniatura y selector. Cerrada pierde indicador y se reabre desde el dock. Archivos enfoca el H3 destino con `preventScroll` y después desplaza a la función |
| Barra y paneles | Inicio, apps, indicadores y bandeja. Hover de app abre miniatura y clic abre/restaura. `aria-expanded` y `aria-controls` enlazan botones con panel. Esc cierra. Anclar al control y adaptar posición al viewport |
| Selector y temas | Opción+Tab o botón Ventanas, flechas y Mayús+Tab; Enter o soltar Opción confirma, Esc cierra. Tema con radios nativos dentro de `radiogroup`, selección por flechas y punto indicado con anillo |
| Recorrido | Botón primario, leyenda anunciada, Pausar/Reanudar y Cerrar. En modo manual usa Siguiente. Tab fuera o interacción externa cancela |
| Funciones | Escenas visuales y encabezados navegables. IDs `feature-thumbnails`, `feature-switcher`, `feature-ai-usage`, `feature-slow-mac`, `feature-disk`, `feature-calendar`, `feature-themes` |
| Instalación | CTA DMG, Terminal con código seleccionable, minimizar/ancho/cerrar/reabrir y copiado. Verde `aria-disabled` cuando ya es ancho completo. El botón no cambia de modo en ese estado |
| Permisos / privacidad / FAQ | Siete `switch` con `aria-checked`, consecuencia anunciada; diagrama y detalle técnico; FAQ con `details/summary`, apertura por Enter/Espacio |
| Estados transversales | Hover y activo visibles; `focus-visible` en acciones; abierto refleja estado ARIA; deshabilitado conserva lectura y bloquea la acción. Copiar anuncia éxito o alternativa manual |

## 10. Contenido e i18n

Los mensajes completos están en [`i18n/es.json`](i18n/es.json) y [`i18n/en.json`](i18n/en.json), con las mismas 370 claves que `strings` del prototipo, que almacena pares **[EN, ES]**. Conservan claves compartidas y prefijos `hero.*`, `demo.*` y `lower.*`, así como los marcadores de interpolación, etiquetas accesibles, estados y mensajes dinámicos. Cargar un JSON por ruta en Next.js y conservar la elección al navegar. Para la primera visita, el prototipo elige ES si `navigator.language` empieza por `es`, EN en los demás casos. Guarda la elección en `localStorage` con la clave `cala-website-language` y actualiza `lang`.

| Regla del calendario | ES | EN |
| --- | --- | --- |
| Primer día y rótulos de la semana | Lunes. L, M, X, J, V, S, D | Domingo. S, M, T, W, T, F, S |
| Variante regional para reloj, fecha y mes | Si el idioma principal del navegador es `es`, conservar su variante. En otro caso, `es-PE` | Si el idioma principal del navegador es `en`, conservar su variante. En otro caso, `en-US` |

Formatear reloj, fechas y mes con `Intl.DateTimeFormat` según esa variante. Usar fecha y hora locales del navegador tanto en la barra como en el panel. Mantener el inicio de semana según el idioma de la interfaz, independientemente de la variante usada para formatear. [Orden de la semana](index.html#L2689) · [Selección de variante](index.html#L3554)

El tono sigue el README, directo y amable. Ejemplos reales: «Una barra de tareas para tu Mac.», «Mira cómo funciona», «¿Por qué va lento mi Mac?» y «Consulta cuánto cupo te queda en Claude y Codex.».

## 11. Accesibilidad

- [ ] Skip link operativo, un H1, encabezados en orden y regiones con nombres.
- [ ] Tab alcanza todo lo visible. Después de entrar en una función, Tab continúa allí. Restituir foco al cerrar cuando corresponda.
- [ ] Contrastes sobre el fondo renderizado en ambos modos y nueve temas. Verificar iconos, texto, foco, avisos, paneles y tooltips.
- [ ] Roles y estados reales en radios, switches, disclosure y paneles. Avisos en `aria-live` para copiar, recorrido y consecuencias de permisos.
- [ ] Opción+Tab, flechas, Enter, Espacio, Esc y navegación del recorrido probados. Acciones de puntero con equivalentes de teclado salvo arrastre.
- [ ] Reduced motion sin cursor, entrada ni zoom animados. Validar 360×740 y 390×844 con una ventana visible y panel contenido en pantalla.
- [ ] La demo funciona con teclado y tacto, sin activar permisos reales ni consultar cuentas o calendarios.

## 12. Implementación, assets y pendientes

- Usar [logo vectorial](../../branding/logo.svg), preparar favicon o imagen social a partir de [AppIcon.icns](../../branding/AppIcon.icns) cuando se confirme el formato. Reutilizar el [sprite aprobado](icons.svg). Preparar capturas 2× en ES/EN y claro/oscuro de escritorio, Opción+Tab, un ajuste de bandeja, Sistema y Calendario con Unirse. Usar datos de ejemplo. Confirmar URL pública y CTA móvil. La copia actual usa el enlace de GitHub para funcionar desde `file://`. Validar el primer arranque del DMG en macOS 14 y 15 o posterior.
- **Calendario:** la web tiene cita fija y un ejemplo local de Unirse. Cala usa EventKit con permiso, agrupa eventos por día y abre su enlace. Marca hoy con un círculo, permite volver a hoy y abre Calendario/Ajustes. Reproducir la presentación con datos simulados y comunicar el alcance de cada acción. [EventKit](../../Sources/Cala/CalendarEvents.swift#L186) · [Agenda](../../Sources/Cala/CalendarViews.swift#L43) · [Panel](../../Sources/Cala/Flyout.swift#L400)
- **Ventanas:** [`README.md`](../../README.md#L7) y [`README.es.md`](../../README.es.md#L7) hablan de «todas» o «cada» ventana. Conservar en la web el máximo de 20 en Opción+Tab según lo que devuelve Accesibilidad y hasta seis miniaturas por app. Una minimizada sin caché puede mostrar solo el icono y elegir una ventana de otro Espacio puede cambiar de Espacio. [Comportamiento](../../docs/features.md#window-switcher-optiontab) · [Miniaturas](../../Sources/Cala/Preview.swift#L33)
- **Privacidad y documentación de Cala:** [`README.md`](../../README.md#L9), [`README.es.md`](../../README.es.md#L9) y la bienvenida afirman en términos generales que los datos se quedan en el Mac. El indicador de cuota está activo por defecto y puede consultar `api.anthropic.com/api/oauth/usage` o `chatgpt.com/backend-api/wham/usage`, o usar `codex app-server` local. El envío automático de informes de cierre es opcional. [Bienvenida](../../Sources/Cala/Onboarding.swift#L127) · [Configuración](../../Sources/Cala/Config.swift#L52) · [Cuota](../../Sources/Cala/Usage.swift#L659) · [Informes automáticos](../../Sources/Cala/Feedback.swift#L186)
- **Vista previa frente al envío:** en un informe ordinario, al desmarcar «Incluir información técnica», la vista previa muestra el mensaje y el correo opcional. Sentry recibe además contexto estructurado si el envío está configurado, incluido el modelo del Mac, la versión de macOS, los estados de Accesibilidad, grabación de pantalla y calendario, y algunos ajustes de Cala. Esos datos siguen en el envío aunque se quite el adjunto detallado. El informe de cierre enviado a mano siempre adjunta `crash.ips` y `diagnostics.txt`. [Contexto](../../Sources/Cala/Feedback.swift#L55) · [Adjuntos y composición de la vista previa](../../Sources/Cala/Feedback.swift#L265) · [Vista previa](../../Sources/Cala/Feedback.swift#L333) · [Envío](../../Sources/Cala/Feedback.swift#L375)

### Consolidar en la implementación

| Hallazgo | Evidencia del HTML aprobado |
| --- | --- |
| Texto y secundarios casi duplicados. Extraer roles efectivos antes de mapear componentes | [Base](index.html#L20) y [segunda declaración](index.html#L269). Oscuro `#f1f5fc → #f2f7ff`, `#acbbd0 → #b6c5d9`. Claro `#445670 → #425570` |
| Anchos, secciones y altos históricos coexisten con sus reemplazos | Líneas 44–46 y 254–255 para contenedor. Líneas 314, 679, 699 y 951 para altura de barra. Conservar 66/99 px efectivos |
| Menta y navy literales en CTA, wallpaper, Terminal y logo | Líneas 326–335, 747–762, 1300 y 1499–1503. Referenciar los tokens de marca cuando coincidan. Conservar alfas del halo |
| Color de ayuda móvil, tinta del CTA y otros ajustes locales por contraste | Líneas 715, 748–750, 1033–1039 y 1323–1326. Evaluar roles separados para barra, panel y estado deshabilitado |
| Radios 8/9/10/12/13/14/15 y sombras parecidas entre ventanas, paneles y tarjetas | Ventanas en líneas 467–470, paneles 592–601, CTA 742–755, tarjetas 1187–1193 y Terminal 1298–1315. Consolidar solo después de comparar visualmente |

El formato JSON usa tipos de [Design Tokens Community Group 2025.10](https://www.designtokens.org/tr/2025.10/format/) para valores representables. Clamps, shorthands, listas CSS, fórmulas de color, degradados compuestos, nombres localizados y keyframes conservan la forma exacta en `$extensions.com.cala.css`. Las entradas sin valor DTCG son grupos de extensión. Para generar Tailwind/CSS, usar sus valores literales y condiciones, o importar `tokens.css` directamente y mapear los nombres efectivos. Las propiedades abreviadas con variables se conservan completas cuando CSSOM deja vacías sus propiedades individuales. El botón usa `--layout-button-gap: var(--s2)` (8 px) y el punto de tema usa `--layout-theme-dot-background` con su degradado de 135°. El prototipo sigue siendo la referencia para el comportamiento y la apariencia.
