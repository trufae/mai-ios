import Foundation

/// JavaScript helpers injected in front of every browser tool call. Everything
/// hangs off `window.__pm` and is idempotent, so re-sending it per call is
/// cheap and works on pages that loaded before the tool first ran.
enum BrowserPageScript {
  static let helpers = #"""
    window.__pm = window.__pm || (function () {
      const pm = {};
      const DEFAULT_LIMIT = 6000;
      pm.interactiveQuery = 'a[href], button, input:not([type=hidden]), textarea, select, summary, ' +
        '[role=button], [role=link], [role=textbox], [role=checkbox], [role=radio], [role=tab], ' +
        '[role=menuitem], [role=option], [contenteditable=""], [contenteditable="true"], [onclick]';

      pm.truncate = function (value, max) {
        const text = String(value == null ? '' : value);
        max = max > 0 ? max : DEFAULT_LIMIT;
        if (text.length <= max) return text;
        return text.slice(0, max) + '\n…[truncated, ' + (text.length - max) + ' more characters]';
      };
      pm.clean = function (value) { return String(value || '').replace(/\s+/g, ' ').trim(); };
      pm.visible = function (el) {
        if (!el || !(el instanceof Element)) return false;
        const style = getComputedStyle(el);
        if (style.display === 'none' || style.visibility === 'hidden' || parseFloat(style.opacity) === 0) return false;
        const rect = el.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      };
      pm.inViewport = function (rect) {
        return rect.bottom > 0 && rect.right > 0 && rect.top < innerHeight && rect.left < innerWidth;
      };
      pm.label = function (el) {
        const own = pm.clean(el.innerText || el.textContent);
        if (own) return own.slice(0, 80);
        return pm.clean(el.getAttribute('aria-label') || el.getAttribute('placeholder') ||
          el.getAttribute('title') || el.getAttribute('alt') || el.value || el.getAttribute('name') || '').slice(0, 80);
      };
      pm.describe = function (el) {
        const label = pm.label(el);
        return el.tagName.toLowerCase() + (label ? ' "' + label + '"' : '');
      };
      pm.isEditable = function (el) {
        if (!el || !(el instanceof Element)) return false;
        if (el.isContentEditable) return true;
        const tag = el.tagName;
        if (tag === 'TEXTAREA' || tag === 'SELECT') return true;
        if (tag !== 'INPUT') return false;
        return !['button', 'submit', 'checkbox', 'radio', 'file', 'hidden', 'image', 'reset'].includes(el.type);
      };

      pm.text = function (selector, max) {
        const root = selector ? document.querySelector(selector) : document.body;
        if (!root) return 'Error: no element matches ' + selector;
        const text = (root.innerText || root.textContent || '')
          .replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
        return pm.truncate(text || '(no visible text)', max);
      };
      pm.visibleText = function (max) {
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        const parts = [];
        let node;
        while ((node = walker.nextNode())) {
          const value = pm.clean(node.nodeValue);
          if (!value) continue;
          const el = node.parentElement;
          if (!el || ['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE'].includes(el.tagName)) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          const rect = range.getBoundingClientRect();
          if (!rect.width || !rect.height || !pm.inViewport(rect)) continue;
          parts.push(value);
        }
        return pm.truncate(parts.join('\n') || '(nothing visible in the viewport)', max);
      };
      pm.links = function (selector, max) {
        const root = selector ? document.querySelector(selector) : document;
        if (!root) return 'Error: no element matches ' + selector;
        const seen = new Set();
        const out = [];
        for (const a of root.querySelectorAll('a[href]')) {
          if (!pm.visible(a)) continue;
          const href = a.href;
          if (!href || href.startsWith('javascript:') || seen.has(href)) continue;
          seen.add(href);
          out.push((pm.label(a) || '(no text)') + ' → ' + href);
          if (out.length >= 150) break;
        }
        return pm.truncate(out.join('\n') || '(no visible links)', max);
      };
      pm.elements = function (selector, max) {
        const root = selector ? document.querySelector(selector) : document;
        if (!root) return 'Error: no element matches ' + selector;
        for (const old of document.querySelectorAll('[data-pm-ref]')) old.removeAttribute('data-pm-ref');
        const out = [];
        let ref = 0;
        for (const el of root.querySelectorAll(pm.interactiveQuery)) {
          if (!pm.visible(el)) continue;
          ref += 1;
          el.setAttribute('data-pm-ref', String(ref));
          const tag = el.tagName.toLowerCase();
          let kind = tag;
          if (tag === 'a') kind = 'link';
          else if (tag === 'input') kind = 'input:' + (el.type || 'text');
          else if (el.getAttribute('role')) kind = el.getAttribute('role');
          let line = '[' + ref + '] ' + kind;
          const label = pm.label(el);
          if (label) line += ' "' + label + '"';
          if (tag === 'input' || tag === 'textarea') {
            if (el.name) line += ' name=' + el.name;
            if (el.value && el.type !== 'password') line += ' value="' + pm.clean(el.value).slice(0, 40) + '"';
          }
          if (tag === 'select') {
            line += ' options=' + Array.from(el.options).slice(0, 12).map(o => pm.clean(o.textContent)).join('|');
          }
          if (tag === 'a' && el.href) line += ' → ' + el.href;
          if (!pm.inViewport(el.getBoundingClientRect())) line += ' (offscreen)';
          out.push(line);
          if (ref >= 200) break;
        }
        return pm.truncate(out.join('\n') || '(no interactive elements)', max);
      };
      pm.html = function (selector, max) {
        const root = selector ? document.querySelector(selector) : document.documentElement;
        if (!root) return 'Error: no element matches ' + selector;
        const clone = root.cloneNode(true);
        for (const el of clone.querySelectorAll('script, style, svg, noscript, template, link[rel=stylesheet]')) el.remove();
        return pm.truncate(clone.outerHTML.replace(/\n\s*\n/g, '\n'), max);
      };

      pm.findByText = function (text) {
        const needle = pm.clean(text).toLowerCase();
        if (!needle) return null;
        const score = function (el) {
          const label = pm.label(el).toLowerCase();
          if (!label) return 0;
          if (label === needle) return 3;
          if (label.startsWith(needle)) return 2;
          if (label.includes(needle)) return 1;
          return 0;
        };
        let best = null;
        let bestScore = 0;
        for (const el of document.querySelectorAll(pm.interactiveQuery)) {
          if (!pm.visible(el)) continue;
          const s = score(el);
          if (s > bestScore) { best = el; bestScore = s; }
          if (s === 3) return el;
        }
        if (best) return best;
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        let node;
        let fallback = null;
        while ((node = walker.nextNode())) {
          const value = pm.clean(node.nodeValue).toLowerCase();
          if (!value) continue;
          const el = node.parentElement;
          if (!el || !pm.visible(el)) continue;
          if (value === needle) return el;
          if (!fallback && value.includes(needle)) fallback = el;
        }
        return fallback;
      };
      pm.resolve = function (target) {
        target = String(target == null ? '' : target).trim();
        if (!target) return { error: 'target is required' };
        let match;
        if ((match = target.match(/^#?(\d+)$/)) && !(target.startsWith('#') && document.getElementById(match[1]))) {
          const el = document.querySelector('[data-pm-ref="' + match[1] + '"]');
          return el ? { element: el } : { error: 'ref ' + match[1] + ' is not on the page any more; run browser_read with what=elements again' };
        }
        if ((match = target.match(/^(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)$/))) {
          const el = document.elementFromPoint(parseFloat(match[1]), parseFloat(match[2]));
          return el ? { element: el } : { error: 'nothing at ' + target + ' (viewport is ' + innerWidth + 'x' + innerHeight + ')' };
        }
        if (target.toLowerCase().startsWith('text=')) {
          const el = pm.findByText(target.slice(5));
          return el ? { element: el } : { error: 'no visible element with text "' + target.slice(5) + '"' };
        }
        let el = null;
        try { el = document.querySelector(target); } catch (e) { el = null; }
        if (!el && target.startsWith('#')) el = document.getElementById(target.slice(1));
        if (el) return { element: el };
        el = pm.findByText(target);
        return el ? { element: el } : { error: 'no element matches "' + target + '" as a selector or visible text' };
      };

      pm.click = function (target) {
        const found = pm.resolve(target);
        if (found.error) return 'Error: ' + found.error;
        const el = found.element;
        el.scrollIntoView({ block: 'center', inline: 'center' });
        const rect = el.getBoundingClientRect();
        const opts = { bubbles: true, cancelable: true, composed: true, button: 0,
          clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2 };
        for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup']) {
          try {
            el.dispatchEvent(type.startsWith('pointer')
              ? new PointerEvent(type, Object.assign({ pointerId: 1, pointerType: 'touch', isPrimary: true }, opts))
              : new MouseEvent(type, opts));
          } catch (e) {}
        }
        try { if (typeof el.focus === 'function') el.focus({ preventScroll: true }); } catch (e) {}
        if (typeof el.click === 'function') el.click();
        else el.dispatchEvent(new MouseEvent('click', opts));
        return 'Clicked ' + pm.describe(el) + '.';
      };
      pm.type = function (target, text, submit) {
        let el = null;
        if (target) {
          const found = pm.resolve(target);
          if (found.error) return 'Error: ' + found.error;
          el = found.element;
        } else {
          el = document.activeElement;
        }
        if (!el || el === document.body) return 'Error: no target field; pass a selector, a ref, or text=<label>.';
        if (!pm.isEditable(el)) {
          const inner = el.querySelector('input:not([type=hidden]), textarea, select, [contenteditable=""], [contenteditable="true"]');
          if (inner) el = inner;
        }
        if (!pm.isEditable(el)) return 'Error: ' + pm.describe(el) + ' is not an editable field.';
        el.scrollIntoView({ block: 'center' });
        try { el.focus({ preventScroll: true }); } catch (e) {}
        text = String(text == null ? '' : text);
        if (el.tagName === 'SELECT') {
          const wanted = text.toLowerCase();
          const option = Array.from(el.options).find(o => o.value.toLowerCase() === wanted || pm.clean(o.textContent).toLowerCase() === wanted)
            || Array.from(el.options).find(o => pm.clean(o.textContent).toLowerCase().includes(wanted));
          if (!option) return 'Error: no option matches "' + text + '" in ' + pm.describe(el) + '.';
          el.value = option.value;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return 'Selected "' + pm.clean(option.textContent) + '" in ' + pm.describe(el) + '.';
        }
        if (el.isContentEditable) {
          el.textContent = text;
          el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
        } else {
          const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          const descriptor = Object.getOwnPropertyDescriptor(proto, 'value');
          if (descriptor && descriptor.set) descriptor.set.call(el, text); else el.value = text;
          el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        }
        let message = 'Typed into ' + pm.describe(el) + '.';
        if (submit) {
          const key = { bubbles: true, cancelable: true, key: 'Enter', code: 'Enter', keyCode: 13, which: 13 };
          const handled = !el.dispatchEvent(new KeyboardEvent('keydown', key));
          el.dispatchEvent(new KeyboardEvent('keypress', key));
          el.dispatchEvent(new KeyboardEvent('keyup', key));
          if (!handled && el.form) {
            if (typeof el.form.requestSubmit === 'function') el.form.requestSubmit(); else el.form.submit();
            message += ' Submitted the form.';
          } else {
            message += ' Pressed Enter.';
          }
        }
        return message;
      };
      pm.scroll = function (direction, amount, target) {
        if (target) {
          const found = pm.resolve(target);
          if (found.error) return 'Error: ' + found.error;
          found.element.scrollIntoView({ block: 'center', inline: 'center' });
          return 'Scrolled to ' + pm.describe(found.element) + '.';
        }
        const px = amount > 0 ? amount : Math.round(innerHeight * 0.8);
        const dy = direction === 'up' ? -px : px;
        const before = scrollY;
        window.scrollBy({ top: dy, left: 0, behavior: 'instant' });
        if (Math.abs(scrollY - before) < 1) {
          // The page itself did not move: try the tallest scrollable container.
          const boxes = Array.from(document.querySelectorAll('div, main, section, article, ul, ol'))
            .filter(function (el) {
              const style = getComputedStyle(el);
              return /(auto|scroll)/.test(style.overflowY) && el.scrollHeight > el.clientHeight + 10 && pm.visible(el);
            })
            .sort(function (a, b) { return b.clientHeight - a.clientHeight; });
          if (boxes[0]) boxes[0].scrollBy({ top: dy, behavior: 'instant' });
        }
        const maxY = Math.max(0, Math.round(document.documentElement.scrollHeight - innerHeight));
        return 'Scrolled ' + (direction === 'up' ? 'up' : 'down') + ' ' + px + 'px (page y=' + Math.round(scrollY) + ' of ' + maxY + ').';
      };

      pm.serialize = function (value, max) {
        const seen = new WeakSet();
        const convert = function (x, depth) {
          if (x === undefined) return null;
          if (x === null || typeof x !== 'object') return typeof x === 'function' ? '[function]' : x;
          if (x instanceof Node) return x.nodeType === 1 ? x.outerHTML.slice(0, 2000) : String(x.nodeValue);
          if (x instanceof Error) return 'Error: ' + x.message;
          if (seen.has(x)) return '[circular]';
          seen.add(x);
          if (depth > 4) return '[...]';
          if (x instanceof NodeList || x instanceof HTMLCollection || Array.isArray(x) || x instanceof Set) {
            return Array.from(x).slice(0, 200).map(function (item) { return convert(item, depth + 1); });
          }
          if (x instanceof Map) {
            return Object.fromEntries(Array.from(x.entries()).slice(0, 200).map(function (entry) { return [String(entry[0]), convert(entry[1], depth + 1)]; }));
          }
          const out = {};
          let count = 0;
          for (const key in x) {
            try { out[key] = convert(x[key], depth + 1); } catch (e) { out[key] = '[unreadable]'; }
            if (++count > 200) break;
          }
          return out;
        };
        let plain;
        try { plain = convert(value, 0); } catch (e) { return 'Error: ' + e; }
        const text = typeof plain === 'string' ? plain : JSON.stringify(plain, null, 1);
        return pm.truncate(text == null ? 'null' : text, max);
      };
      pm.eval = async function (script, max) {
        const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
        let fn;
        try {
          fn = new AsyncFunction('return (' + String(script).trim().replace(/;+\s*$/, '') + '\n);');
        } catch (e) {
          try { fn = new AsyncFunction(script); } catch (e2) { return 'Error: ' + e2.message; }
        }
        try {
          return pm.serialize(await fn.call(window), max);
        } catch (e) {
          return 'Error: ' + (e && e.message ? e.message : String(e));
        }
      };
      return pm;
    })();
    """#
}
