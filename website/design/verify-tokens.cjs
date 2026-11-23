// Usage is documented in ../README.md. This script does not install dependencies.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {pathToFileURL} = require('node:url');
const {chromium} = require(process.env.CALA_PLAYWRIGHT_MODULE || 'playwright');

const dir = __dirname;
const html = fs.readFileSync(path.join(dir, 'index.html'), 'utf8');
const css = fs.readFileSync(path.join(dir, 'tokens.css'), 'utf8');
const tokens = JSON.parse(fs.readFileSync(path.join(dir, 'tokens.json'), 'utf8'));
const extension = 'com.cala.css';

function flatten(group, parts = []) {
  return Object.entries(group).flatMap(([key, value]) => {
    if (key.startsWith('$')) return [];
    const names = [...parts, key];
    return value.$value !== undefined || value.$extensions?.[extension]?.value !== undefined
      ? [[names, value]]
      : flatten(value, names);
  });
}

function nonemptyCss(value) {
  if (typeof value !== 'string') return false;
  const text = value.replace(/\/\*[\s\S]*?\*\//g, '').trim();
  return text !== '' && text !== '""' && text !== "''";
}

function nonemptyTokenValue(value) {
  if (typeof value === 'string') return value.trim() !== '';
  if (value !== null && typeof value === 'object') {
    const parts = Object.values(value);
    return parts.length > 0 && parts.every(nonemptyTokenValue);
  }
  return typeof value === 'number' && Number.isFinite(value) || typeof value === 'boolean';
}

function assertNonemptyExports() {
  const emptyDeclaration = /--[\w-]+\s*:\s*(?:\/\*[\s\S]*?\*\/\s*)*(?=[;}]|$)/;
  assert.doesNotMatch(css, emptyDeclaration, 'tokens.css contiene una declaración vacía');
  for (const [parts, token] of flatten(tokens)) {
    const label = parts.join('.');
    const record = token.$extensions?.[extension];
    if (record) assert.ok(nonemptyCss(record.value), label + ' · valor CSS vacío en tokens.json');
    if (Object.hasOwn(token, '$value')) {
      assert.ok(nonemptyTokenValue(token.$value), label + ' · $value vacío en tokens.json');
    }
  }
}

function authoredValue(ref) {
  // CSSOM can lose a pending shorthand when one of its longhands is also authored.
  if (!ref.authored || !html.includes(ref.authored)) return undefined;
  const [, selector, property, value] = /^([^{}]+)\{\s*([\w-]+):\s*([^;]+);/.exec(ref.authored) || [];
  return selector?.trim() === ref.selector && property === ref.property ? value.trim() : undefined;
}

function cssValue(type, value) {
  switch (type) {
    case 'color': {
      assert.equal(value.colorSpace, 'srgb');
      return `rgba(${value.components.map(channel => channel * 255).join(', ')}, ${value.alpha ?? 1})`;
    }
    case 'number':
    case 'fontWeight':
      return String(value);
    case 'dimension':
    case 'duration':
      return value.value + value.unit;
    case 'fontFamily':
      return value.map(name => (/\s/.test(name) ? JSON.stringify(name) : name)).join(', ');
    case 'cubicBezier':
      return `cubic-bezier(${value.join(', ')})`;
    case 'shadow': {
      const layers = Array.isArray(value) ? value : [value];
      return layers.map(layer => [
        layer.inset ? 'inset' : '',
        ...['offsetX', 'offsetY', 'blur', 'spread'].map(key => cssValue('dimension', layer[key])),
        cssValue('color', layer.color),
      ].filter(Boolean).join(' ')).join(', ');
    }
    default:
      throw new Error('Tipo DTCG sin comparador: ' + type);
  }
}

async function main() {
  assertNonemptyExports();
  const browser = await chromium.launch({
    executablePath: process.env.CALA_CHROMIUM_EXECUTABLE || undefined,
    args: JSON.parse(process.env.CALA_CHROMIUM_ARGS || '[]'),
  });
  const errors = [];
  try {
    const page = await browser.newPage({viewport: {width: 1440, height: 900}, reducedMotion: 'reduce'});
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => {
      if (message.type() === 'error') errors.push(message.text());
    });
    await page.goto(pathToFileURL(path.join(dir, 'index.html')).href);
    const inventory = await page.evaluate(cssText => {
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(cssText);
      const read = (list, includeShorthands = false) => {
        const rules = [], keyframes = [], properties = [], mediaQueries = new Set();
        function visit(items, media = []) {
          for (const rule of items) {
            if (rule instanceof CSSMediaRule) {
              mediaQueries.add(rule.conditionText);
              visit(rule.cssRules, [...media, rule.conditionText]);
            } else if (rule instanceof CSSKeyframesRule) {
              keyframes.push(rule.cssText);
            } else if (rule instanceof CSSPropertyRule) {
              properties.push(rule.cssText);
            } else if (rule.selectorText && rule.style) {
              const names = new Set(rule.style);
              if (includeShorthands) {
                for (const name of ['background', 'border', 'border-top', 'outline', 'gap', 'font', 'animation']) {
                  names.add(name);
                }
              }
              const declarations = Object.fromEntries([...names].map(name => [
                name, rule.style.getPropertyValue(name).trim(),
              ]).filter(([name, value]) => value || name.startsWith('--')));
              rules.push({selector: rule.selectorText, media, declarations});
            }
          }
        }
        visit(list);
        return {rules, keyframes, properties, mediaQueries: [...mediaQueries]};
      };
      return {
        source: read(document.styleSheets[0].cssRules, true),
        extracted: read(sheet.cssRules),
        themeNames: Object.fromEntries([...document.querySelectorAll('.theme-picker input')].map(
          input => ['theme-' + input.value, strings['theme-' + input.value]],
        )),
      };
    }, css);

    const discrepancies = [];
    for (const rule of inventory.extracted.rules) {
      for (const [name, value] of Object.entries(rule.declarations)) {
        assert.ok(nonemptyCss(value), name + ' · declaración CSS vacía');
      }
    }
    const unaccounted = new Set(inventory.extracted.rules.flatMap(rule =>
      Object.entries(rule.declarations).map(([prop, value]) => JSON.stringify([rule.selector, rule.media, prop, value])),
    ));
    const typedPairs = [];
    let declared = 0, aliases = 0;
    for (const [parts, token] of flatten(tokens)) {
      const ref = token.$extensions?.[extension];
      const label = parts.join('.');
      if (!ref) {
        const alias = typeof token.$value === 'string' && token.$value.match(/^\{(.+)\}$/);
        const target = alias && alias[1].split('.').reduce((group, key) => group?.[key], tokens);
        if (!target || target.$type !== token.$type) discrepancies.push(label + ' · alias');
        aliases++;
        continue;
      }
      if (token.$value !== undefined) {
        const alias = typeof token.$value === 'string' && token.$value.match(/^\{(.+)\}$/);
        if (alias) {
          const path = alias[1].split('.');
          const target = path.reduce((group, key) => group?.[key], tokens);
          if (target?.$type !== token.$type || ref.value !== 'var(--' + path.at(-1) + ')') {
            discrepancies.push(label + ' · alias CSS');
          }
        } else typedPairs.push({label, type: token.$type, value: cssValue(token.$type, token.$value), css: ref.value});
      }
      const prop = ref.export || (ref.dictionary ? '--theme-' + parts.at(-1) : ref.property || '--' + parts.at(-1));
      const selector = ref.export || ref.condition ? ':root' : ref.selector || '[data-theme="' + parts[1] + '"]';
      const media = ref.media || [];
      const exportedMedia = ref.exportMedia ?? media;
      if (!unaccounted.has(JSON.stringify([selector, exportedMedia, prop, ref.value]))) {
        // Several semantic entries may point to the same declaration.
        const found = inventory.extracted.rules.some(rule => rule.selector === selector &&
          JSON.stringify(rule.media) === JSON.stringify(exportedMedia) && rule.declarations[prop] === ref.value);
        if (!found) discrepancies.push(label + ' · tokens.css');
      }
      unaccounted.delete(JSON.stringify([selector, exportedMedia, prop, ref.value]));

      if (ref.rule !== undefined) {
        const original = inventory.source.rules[ref.rule];
        const value = original?.declarations[ref.property] || authoredValue(ref);
        if (original?.selector !== ref.selector || JSON.stringify(original.media) !== JSON.stringify(media) ||
            !nonemptyCss(value) || value !== ref.value) discrepancies.push(label + ' · CSS del HTML');
      } else if (ref.dictionary) {
        const localized = inventory.themeNames[ref.dictionary]?.[ref.locale === 'en' ? 0 : 1];
        if (JSON.stringify(localized) !== ref.value) discrepancies.push(label + ' · diccionario');
      } else if (ref.condition) {
        if (!inventory.source.mediaQueries.some(query => query.includes(ref.condition))) discrepancies.push(label + ' · media query');
      } else if (ref.script) {
        const source = ref.native ? fs.readFileSync(path.join(dir, '..', '..', ref.native), 'utf8') : html;
        if (!source.includes(ref.script) || !ref.script.includes(String(parseFloat(ref.value))) &&
            !ref.value.startsWith('cubic-bezier')) discrepancies.push(label + ' · código');
      }
      declared++;
    }
    for (const declaration of unaccounted) discrepancies.push('CSS sin ficha JSON · ' + declaration);
    const recordedFrames = Object.values(tokens.motion.keyframes).map(group => group.$extensions[extension].keyframes);
    const recordedProperties = Object.values(tokens.motion.interpolation).map(group => group.$extensions[extension].propertyRule);
    for (const [label, recorded] of [['keyframes', recordedFrames], ['properties', recordedProperties]]) {
      const canonical = JSON.stringify(inventory.source[label]);
      if (canonical !== JSON.stringify(inventory.extracted[label]) || canonical !== JSON.stringify(recorded)) {
        discrepancies.push(label);
      }
    }
    const typedMismatches = await page.evaluate(pairs => {
      const properties = {color: 'color', shadow: 'box-shadow', fontFamily: 'font-family', cubicBezier: 'transition-timing-function'};
      const probe = document.createElement('div');
      probe.hidden = true;
      document.body.append(probe);
      const {style} = probe;
      function normalize(pair, value) {
        const property = properties[pair.type];
        if (!property) {
          return pair.type === 'duration' ? parseFloat(value) * (value.endsWith('ms') ? 1 : 1000) :
            pair.type === 'number' || pair.type === 'fontWeight' ? Number(value) : value;
        }
        style.removeProperty(property);
        style.setProperty(property, value);
        const declared = style.getPropertyValue(property);
        if (!declared) return undefined;
        return pair.type === 'shadow' ? getComputedStyle(probe).boxShadow : declared;
      }
      const mismatches = pairs.filter(pair => {
        const fromJson = normalize(pair, pair.value);
        const fromCss = normalize(pair, pair.css);
        return fromJson === undefined || fromCss === undefined || fromJson !== fromCss;
      }).map(pair => pair.label + ' · valor DTCG');
      probe.remove();
      return mismatches;
    }, typedPairs);
    assert.deepEqual([...discrepancies, ...typedMismatches], []);

    let computed = 0;
    for (const colorScheme of ['dark', 'light']) {
      await page.emulateMedia({colorScheme});
      for (const [width, height] of [[1440, 900], [1280, 700], [390, 844]]) {
        await page.setViewportSize({width, height});
        for (const locale of ['es', 'en']) {
          await page.locator('#language').selectOption(locale);
          const scenarios = await page.evaluate(cssText => {
            const desktop = document.querySelector('.desktop');
            const bar = document.querySelector('.taskbar');
            const read = (element, props) => props.map(prop => getComputedStyle(element).getPropertyValue(prop).trim());
            const snapshot = () => ({
              root: read(document.documentElement, [
                '--navy', '--navy-deep', '--mint', '--bg', '--surface', '--card', '--line', '--control-line',
                '--text', '--muted', '--accent', '--accent-ink', '--r-control', '--r-card', '--r-window',
                '--wrap', '--gutter', '--section', '--desktop-shadow', '--font', '--mono',
              ]),
              dock: read(desktop, ['--bar-height', '--bar-start', '--bar-end', '--theme-accent', '--bar-text']),
              bar: read(bar, ['height', 'background-image', 'backdrop-filter', 'color']),
              hero: read(document.querySelector('h1'), ['font-size', 'font-weight', 'line-height', 'letter-spacing']),
              heading: read(document.querySelector('h2'), ['font-size', 'line-height']),
              panel: read(document.querySelector('#demo-popover'), ['--card', '--text', '--muted', '--accent', '--line']),
            });
            const style = document.createElement('style');
            style.textContent = cssText;
            return [...document.querySelectorAll('.theme-picker input')].map(input => {
              desktop.dataset.theme = input.value;
              const before = snapshot();
              document.head.append(style);
              const after = snapshot();
              style.remove();
              return {theme: input.value, before, after};
            });
          }, css);
          for (const {theme, before, after} of scenarios) {
            assert.deepEqual(after, before, `${theme} / ${locale} / ${colorScheme} / ${width}×${height}`);
            assert.equal(before.bar[0], width < 768 ? '99px' : '66px');
            computed++;
          }
        }
      }
    }
    assert.deepEqual(errors, []);
    console.log(JSON.stringify({declared, typed: typedPairs.length, aliases, computed, keyframes: inventory.source.keyframes.length, discrepancies: 0, empty: 0, consoleErrors: 0}));
  } finally {
    await browser.close();
  }
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
