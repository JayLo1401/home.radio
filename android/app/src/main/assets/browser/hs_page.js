// Home System browser - the page side (every frame, at document start).
//
// Comes after hs_scriptlets.js in the same function; BrowserView.kt puts
// `var HSN = '<bridge name>';` in front. Asks the app (the bridge, see
// BrowserView.Bridge) what this page gets: the scriptlets of the filter
// lists (run first, before any of the page's own scripts), the CSS hiding
// ads, and generic CSS for the page's classes/ids as they show up. Also
// tells the app when a text field gets focus (keyboard) and when audible
// media plays (keep the screen on, pause the radio), and gives the app
// `window[HSN + 'c']` for the remote's media keys and text input.
(function () {
  'use strict';
  var B = window[HSN];
  if (!B) return;
  var MARK = HSN + 'm';
  if (window[MARK]) return;
  try {
    Object.defineProperty(window, MARK, { value: true });
  } catch (e) {
    return;
  }
  var top = window === window.top;
  var frameId = Math.random().toString(36).slice(2);

  var cfg = { on: false };
  try {
    cfg = JSON.parse(B.config(location.href, top));
  } catch (e) {}

  // --- blocking ---------------------------------------------------------------

  var sheet = null;
  var extraSheet = null;
  function adopt(s) {
    try {
      var list = document.adoptedStyleSheets;
      if (list.indexOf(s) < 0) document.adoptedStyleSheets = list.concat([s]);
      return true;
    } catch (e) {
      return false;
    }
  }
  function styleFallback(css) {
    function add() {
      var parent = document.head || document.documentElement;
      if (!parent) return false;
      var st = document.createElement('style');
      st.textContent = css;
      parent.appendChild(st);
      return true;
    }
    if (!add()) document.addEventListener('DOMContentLoaded', add, { once: true });
  }
  function addCss(css) {
    if (!css) return;
    try {
      if (!extraSheet) {
        extraSheet = new CSSStyleSheet();
        adopt(extraSheet);
      }
      var rules = css.split('\n');
      for (var i = 0; i < rules.length; i++) {
        if (!rules[i]) continue;
        try {
          extraSheet.insertRule(rules[i], extraSheet.cssRules.length);
        } catch (e) {}
      }
    } catch (e) {
      styleFallback(css);
    }
  }

  if (cfg.on) {
    var js = cfg.js || [];
    for (var i = 0; i < js.length; i++) {
      try {
        hsRunScriptlet(js[i][0], js[i].slice(1));
      } catch (e) {}
    }
    if (cfg.css) {
      try {
        sheet = new CSSStyleSheet();
        sheet.replaceSync(cfg.css);
        if (!adopt(sheet)) styleFallback(cfg.css);
      } catch (e) {
        styleFallback(cfg.css);
      }
    }
    // A page that replaces document.adoptedStyleSheets drops ours - put
    // them back once it's loaded.
    document.addEventListener('DOMContentLoaded', function () {
      if (sheet) adopt(sheet);
      if (extraSheet) adopt(extraSheet);
    }, { once: true });

    if (cfg.generic) startSurveyor();
  }

  /** Generic class/id filters: only those for classes/ids the page really has. */
  function startSurveyor() {
    var seen = Object.create(null);
    var seenCount = 0;
    var pending = [];
    var timer = 0;
    function add(key) {
      if (seen[key] || seenCount > 30000) return;
      seen[key] = 1;
      seenCount++;
      pending.push(key);
    }
    function collect(el) {
      if (el.nodeType !== 1) return;
      var id = el.id;
      if (id && typeof id === 'string') add('#' + id);
      var cl = el.classList;
      if (cl) for (var i = 0; i < cl.length; i++) add('.' + cl[i]);
    }
    function collectTree(node) {
      if (node.nodeType !== 1) return;
      collect(node);
      if (node.firstElementChild) {
        var all = node.querySelectorAll('[id],[class]');
        for (var i = 0; i < all.length; i++) collect(all[i]);
      }
    }
    function flush() {
      timer = 0;
      if (!pending.length) return;
      var keys = pending;
      pending = [];
      var css = '';
      try {
        css = B.generic(location.href, keys.join(' '));
      } catch (e) {}
      addCss(css);
    }
    function schedule() {
      if (!timer && pending.length) timer = setTimeout(flush, 60);
    }
    var mo = new MutationObserver(function (records) {
      for (var i = 0; i < records.length; i++) {
        var r = records[i];
        if (r.type === 'attributes') collect(r.target);
        else for (var j = 0; j < r.addedNodes.length; j++) collectTree(r.addedNodes[j]);
      }
      schedule();
    });
    mo.observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['id', 'class'] });
    if (document.documentElement) {
      collectTree(document.documentElement);
      schedule();
    }
  }

  // --- text fields: the app shows the keyboard ---------------------------------

  var NOT_TEXT = {
    button: 1, checkbox: 1, color: 1, file: 1, hidden: 1, image: 1, radio: 1, range: 1, reset: 1, submit: 1,
  };
  function deepActive() {
    var a = document.activeElement;
    while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement;
    return a;
  }
  function kindOf(el) {
    if (!el) return '';
    if (el.isContentEditable) return 'multi';
    var tag = el.tagName;
    if (tag === 'TEXTAREA') return el.readOnly || el.disabled ? '' : 'multi';
    if (tag === 'INPUT') {
      if (el.readOnly || el.disabled) return '';
      var type = (el.getAttribute('type') || 'text').toLowerCase();
      if (NOT_TEXT[type]) return '';
      if (type === 'password') return 'password';
      if (type === 'number' || type === 'tel') return 'number';
      return 'input';
    }
    return '';
  }
  var lastKind = null;
  function reportFocus() {
    var el = deepActive();
    // The top frame doesn't know about a field inside a frame - that
    // frame reports it.
    if (el && el.tagName === 'IFRAME') return;
    var kind = kindOf(el);
    if (kind === lastKind) return;
    lastKind = kind;
    try {
      B.editing(frameId, kind);
    } catch (e) {}
  }
  document.addEventListener('focusin', reportFocus, true);
  document.addEventListener('focusout', function () {
    setTimeout(reportFocus, 0);
  }, true);

  // --- media: keep the screen on, pause the radio ----------------------------------

  var playing = [];
  function audible(m) {
    return !m.paused && !m.ended && !m.muted && m.volume > 0;
  }
  var lastPlaying = false;
  function reportMedia() {
    var now = false;
    for (var i = playing.length - 1; i >= 0; i--) {
      if (!playing[i].isConnected || playing[i].paused || playing[i].ended) playing.splice(i, 1);
      else if (audible(playing[i])) now = true;
    }
    if (now === lastPlaying) return;
    lastPlaying = now;
    try {
      B.media(frameId, now);
    } catch (e) {}
  }
  function onMedia(e) {
    var m = e.target;
    if (!(m instanceof HTMLMediaElement)) return;
    if (playing.indexOf(m) < 0 && !m.paused) playing.push(m);
    reportMedia();
  }
  ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied'].forEach(function (t) {
    document.addEventListener(t, onMedia, true);
  });

  // --- for the app: media keys and text input ----------------------------------------

  function mainVideo(doc) {
    var best = null;
    var bestArea = 0;
    var list;
    try {
      list = doc.querySelectorAll('video,audio');
    } catch (e) {
      return null;
    }
    for (var i = 0; i < list.length; i++) {
      var m = list[i];
      var r = m.getBoundingClientRect();
      var area = r.width * r.height + (m.paused ? 0 : 1e9) + (m.tagName === 'AUDIO' && !m.paused ? 1e9 : 0);
      if (best === null || area > bestArea) {
        best = m;
        bestArea = area;
      }
    }
    if (best) return best;
    var frames = doc.querySelectorAll('iframe');
    for (var j = 0; j < frames.length; j++) {
      try {
        var v = mainVideo(frames[j].contentDocument);
        if (v) return v;
      } catch (e) {}
    }
    return null;
  }

  function setNativeValue(el, value) {
    var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    var desc = Object.getOwnPropertyDescriptor(proto, 'value');
    if (desc && desc.set) desc.set.call(el, value);
    else el.value = value;
  }

  if (top) {
    try {
      Object.defineProperty(window, HSN + 'c', {
        value: {
          /** 'toggle', 'play', 'pause', 'seek' (+seconds); true if there was a video. */
          media: function (action, seconds) {
            var v = mainVideo(document);
            if (!v) return false;
            if (action === 'play' || (action === 'toggle' && v.paused)) {
              var p = v.play();
              if (p && p.catch) p.catch(function () {});
            } else if (action === 'pause' || action === 'toggle') {
              v.pause();
            } else if (action === 'seek' && isFinite(v.duration)) {
              v.currentTime = Math.max(0, Math.min(v.duration - 0.1, v.currentTime + seconds));
            }
            return true;
          },
          /** The focused field's text and kind (only fields we can reach). */
          field: function () {
            var el = deepActive();
            if (el && el.tagName === 'IFRAME') {
              try {
                var d = el.contentDocument;
                el = d && d.activeElement;
              } catch (e) {
                return JSON.stringify({ reach: false });
              }
            }
            var kind = kindOf(el);
            if (!kind) return JSON.stringify({ reach: true, kind: '' });
            return JSON.stringify({
              reach: true,
              kind: kind,
              value: el.isContentEditable ? el.innerText : el.value,
              label: el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.name || '',
            });
          },
          /** Puts [text] into the focused field as typing would; [submit]: Enter. */
          setText: function (text, submit) {
            var el = deepActive();
            if (el && el.tagName === 'IFRAME') {
              try {
                el = el.contentDocument.activeElement;
              } catch (e) {
                return false;
              }
            }
            if (!kindOf(el)) return false;
            if (el.isContentEditable) {
              el.focus();
              document.execCommand('selectAll', false, null);
              document.execCommand('insertText', false, text);
            } else {
              setNativeValue(el, text);
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
            }
            if (submit) {
              var opts = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
              var go = el.dispatchEvent(new KeyboardEvent('keydown', opts));
              el.dispatchEvent(new KeyboardEvent('keypress', opts));
              el.dispatchEvent(new KeyboardEvent('keyup', opts));
              if (go && el.form) {
                if (el.form.requestSubmit) el.form.requestSubmit();
                else el.form.submit();
              }
            }
            return true;
          },
          /** Leaves the text field (Back on the remote). */
          blur: function () {
            var el = deepActive();
            if (el && el.blur) el.blur();
          },
        },
      });
    } catch (e) {}
  }

  // The YouTube helper (hs_youtube.js) sees this.
  var hsPage = { cfg: cfg, top: top };
  if (cfg.on && cfg.yt) hsYoutube(hsPage);
})();
