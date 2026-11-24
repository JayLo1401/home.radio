// Home System browser - scriptlets.
//
// Our own implementations (written for Home System, not taken from uBlock
// Origin) of the scriptlets uBlock Origin's filter lists call with
// `domain##+js(name, args...)`, under the same names and with the same
// meaning of the arguments, so the lists' rules work here. The compiler
// (lib/data/services/adblock_compiler.dart) maps the short names (set, aopr,
// acs, ...) to the names below; a name we don't have is skipped there.
//
// This file is the start of the document-start script (BrowserView.kt puts
// hs_scriptlets.js, hs_page.js and hs_youtube.js together in one function);
// it defines `hsRunScriptlet(name, args)`.
var hsRunScriptlet = (function () {
  'use strict';
  var W = window;
  var nativeParse = JSON.parse;
  var nativeStringify = JSON.stringify;
  var nativeFetch = W.fetch;
  var nativeReflectApply = Reflect.apply;
  var rand = Math.random().toString(36).slice(2);

  // --- helpers -------------------------------------------------------------

  /** '/re/flags' -> RegExp, anything else a literal; '' matches everything. */
  function toRegex(pattern, flags) {
    if (pattern === undefined || pattern === null || pattern === '') return /^/;
    var m = /^\/(.+)\/([gimsuy]*)$/.exec(pattern);
    if (m) {
      try {
        return new RegExp(m[1], flags !== undefined ? mergeFlags(m[2], flags) : m[2]);
      } catch (e) {}
    }
    return new RegExp(String(pattern).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), flags || '');
  }
  function mergeFlags(a, b) {
    var out = a;
    for (var i = 0; i < b.length; i++) if (out.indexOf(b[i]) < 0) out += b[i];
    return out;
  }
  /** A needle with an optional leading '!' (not). */
  function needleTester(needle) {
    var not = false;
    var n = needle || '';
    if (n.charAt(0) === '!') {
      not = true;
      n = n.slice(1);
    }
    var re = toRegex(n);
    return function (text) {
      return re.test(text) !== not;
    };
  }
  /** Extra arguments after the fixed ones: 'key', value, 'key', value ... */
  function extras(args, from) {
    var out = {};
    for (var i = from; i + 1 < args.length; i += 2) out[args[i]] = args[i + 1];
    return out;
  }
  function abortError() {
    return new ReferenceError(rand);
  }
  function fnText(fn) {
    try {
      return typeof fn === 'function' ? Function.prototype.toString.call(fn) : String(fn);
    } catch (e) {
      return '';
    }
  }
  function delayTester(spec) {
    if (spec === undefined || spec === '' || spec === '*') return function () { return true; };
    var not = spec.charAt(0) === '!';
    var s = not ? spec.slice(1) : spec;
    var test;
    if (s.charAt(0) === '>') {
      var gt = parseInt(s.slice(1), 10);
      test = function (d) { return d > gt; };
    } else if (s.charAt(0) === '<') {
      var lt = parseInt(s.slice(1), 10);
      test = function (d) { return d < lt; };
    } else {
      var eq = parseInt(s, 10);
      test = function (d) { return d === eq; };
    }
    return function (d) {
      return test(Number(d) || 0) !== not;
    };
  }

  /**
   * Follows 'a.b.c' from window and calls leaf(owner, prop) on the object
   * holding 'c' - now, and again whenever one of the objects on the way is
   * set later (the page builds them after us).
   */
  function trapChain(chain, leaf) {
    function walk(owner, path) {
      if (owner === null || (typeof owner !== 'object' && typeof owner !== 'function')) return;
      var dot = path.indexOf('.');
      if (dot < 0) {
        leaf(owner, path);
        return;
      }
      var head = path.slice(0, dot);
      var tail = path.slice(dot + 1);
      var current;
      try {
        current = owner[head];
      } catch (e) {}
      if (current !== undefined && current !== null && (typeof current === 'object' || typeof current === 'function')) {
        walk(current, tail);
      }
      var desc = Object.getOwnPropertyDescriptor(owner, head);
      if (desc && desc.configurable === false) return;
      if (desc && desc.get && desc.get.__hsTrap) return;
      var stored = current;
      var getter = function () { return stored; };
      getter.__hsTrap = true;
      try {
        Object.defineProperty(owner, head, {
          configurable: true,
          enumerable: desc ? desc.enumerable : true,
          get: desc && desc.get ? desc.get : getter,
          set: function (v) {
            if (desc && desc.set) desc.set.call(this, v);
            stored = v;
            walk(v, tail);
          },
        });
      } catch (e) {}
    }
    walk(W, chain);
  }

  function chainValue(chain, root) {
    var o = root || W;
    var parts = chain.split('.');
    for (var i = 0; i < parts.length; i++) {
      if (o === null || o === undefined) return undefined;
      o = o[parts[i]];
    }
    return o;
  }
  function chainOwner(chain) {
    var parts = chain.split('.');
    var prop = parts.pop();
    var owner = parts.length ? chainValue(parts.join('.')) : W;
    return owner === null || owner === undefined ? null : { owner: owner, prop: prop };
  }

  /** Replaces the function at `chain` with a Proxy around it (its toString stays native). */
  function wrapFunction(chain, apply) {
    var r = chainOwner(chain);
    if (!r || typeof r.owner[r.prop] !== 'function') return false;
    var original = r.owner[r.prop];
    try {
      r.owner[r.prop] = new Proxy(original, { apply: apply });
    } catch (e) {
      return false;
    }
    return true;
  }

  function onReady(fn) {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', fn, { once: true });
    else fn();
  }

  /** Runs fn on the page's elements per `behavior`: 'asap', 'stay', 'complete' (default DOMContentLoaded). */
  function runOnElements(fn, behavior) {
    var b = behavior || '';
    var asap = b.indexOf('asap') >= 0;
    var stay = b.indexOf('stay') >= 0;
    var complete = b.indexOf('complete') >= 0;
    var timer = 0;
    function run() {
      timer = 0;
      try { fn(); } catch (e) {}
    }
    function start() {
      run();
      if (stay) {
        new MutationObserver(function () {
          if (!timer) timer = setTimeout(run, 20);
        }).observe(document, { childList: true, subtree: true, attributes: true });
      }
    }
    if (asap) {
      if (document.documentElement) start();
      else onReady(start);
    } else if (complete) {
      if (document.readyState === 'complete') start();
      else W.addEventListener('load', start, { once: true });
    } else {
      onReady(start);
    }
  }

  var policy = null;
  function trusted(kind, text) {
    if (!W.trustedTypes || !W.trustedTypes.createPolicy) return text;
    if (policy === null) {
      try {
        policy = W.trustedTypes.createPolicy('hs-' + rand, {
          createHTML: function (s) { return s; },
          createScript: function (s) { return s; },
          createScriptURL: function (s) { return s; },
        });
      } catch (e) {
        policy = false;
      }
    }
    if (!policy) return text;
    return kind === 'script' ? policy.createScript(text) : policy.createHTML(text);
  }

  // --- values -----------------------------------------------------------------

  var noop = function () {};
  function constantValue(raw, isTrusted) {
    switch (raw) {
      case 'undefined': return { v: undefined };
      case 'null': return { v: null };
      case 'true': return { v: true };
      case 'false': return { v: false };
      case '': case 'emptyStr': return { v: '' };
      case 'noopFunc': return { v: function () {} };
      case 'trueFunc': return { v: function () { return true; } };
      case 'falseFunc': return { v: function () { return false; } };
      case 'throwFunc': return { v: function () { throw abortError(); } };
      case 'emptyArr': case '[]': return { v: [] };
      case 'emptyObj': case '{}': return { v: {} };
      case 'noopCallbackFunc': return { v: function () { return function () {}; } };
      case 'yes': case 'no': case 'on': case 'off': case 'accept': case 'accepted': case 'reject': case 'rejected':
        return { v: raw };
      case 'NaN': return { v: NaN };
      case 'Infinity': return { v: Infinity };
      case '-Infinity': return { v: -Infinity };
    }
    if (/^-?\d+(\.\d+)?$/.test(raw)) {
      var n = Number(raw);
      if (isTrusted || Math.abs(n) <= 32767) return { v: n };
    }
    if (isTrusted) {
      if (raw.indexOf('json:') === 0) {
        try { return { v: nativeParse(raw.slice(5)) }; } catch (e) {}
      }
      try { return { v: nativeParse(raw) }; } catch (e) {}
      return { v: raw };
    }
    return null;
  }

  // --- the scriptlets -----------------------------------------------------------

  function setConstant(isTrusted, chain, raw) {
    if (!chain) return;
    var c = constantValue(raw === undefined ? '' : raw, isTrusted);
    if (!c) return;
    var value = c.v;
    var opts = Array.prototype.slice.call(arguments, 3);
    if (opts.indexOf('asFunction') >= 0) {
      var fv = value;
      value = function () { return fv; };
    } else if (opts.indexOf('asCallback') >= 0) {
      var cv = value;
      value = function () { return function () { return cv; }; };
    } else if (opts.indexOf('asResolved') >= 0) {
      value = Promise.resolve(value);
    } else if (opts.indexOf('asRejected') >= 0) {
      value = Promise.reject(value);
    }
    trapChain(chain, function (owner, prop) {
      var desc = Object.getOwnPropertyDescriptor(owner, prop);
      if (desc && desc.configurable === false) {
        try { owner[prop] = value; } catch (e) {}
        return;
      }
      try {
        Object.defineProperty(owner, prop, {
          configurable: true,
          enumerable: desc ? desc.enumerable : true,
          get: function () { return value; },
          set: function () {},
        });
      } catch (e) {}
    });
  }

  function abortOnRead(chain) {
    if (!chain) return;
    trapChain(chain, function (owner, prop) {
      try {
        Object.defineProperty(owner, prop, {
          configurable: true,
          get: function () { throw abortError(); },
          set: function () {},
        });
      } catch (e) {}
    });
  }

  function abortOnWrite(chain) {
    if (!chain) return;
    trapChain(chain, function (owner, prop) {
      var desc = Object.getOwnPropertyDescriptor(owner, prop);
      var value = desc && 'value' in desc ? desc.value : undefined;
      try {
        Object.defineProperty(owner, prop, {
          configurable: true,
          get: function () { return value; },
          set: function () { throw abortError(); },
        });
      } catch (e) {}
    });
  }

  function abortCurrentScript(chain, needle, context) {
    if (!chain) return;
    var test = needleTester(needle);
    var reContext = context ? toRegex(context) : null;
    var self = document.currentScript;
    function check() {
      var s = document.currentScript;
      if (!(s instanceof HTMLScriptElement) || s === self) return;
      if (reContext && !reContext.test(s.src)) return;
      var text = s.src ? '' : s.textContent;
      if (needle && !test(text)) return;
      throw abortError();
    }
    trapChain(chain, function (owner, prop) {
      var desc = Object.getOwnPropertyDescriptor(owner, prop);
      if (desc && desc.configurable === false) return;
      var value = owner[prop];
      try {
        Object.defineProperty(owner, prop, {
          configurable: true,
          get: function () {
            check();
            return desc && desc.get ? desc.get.call(this) : value;
          },
          set: function (v) {
            check();
            if (desc && desc.set) desc.set.call(this, v);
            else value = v;
          },
        });
      } catch (e) {}
    });
  }

  function abortOnStackTrace(chain, needle) {
    if (!chain) return;
    var n = (needle || '').replace('inlineScript', location.href.split('#')[0]).replace('injectedScript', '');
    var test = needleTester(n);
    function check() {
      var stack = '';
      try { stack = new Error().stack || ''; } catch (e) {}
      if (test(stack)) throw abortError();
    }
    trapChain(chain, function (owner, prop) {
      var desc = Object.getOwnPropertyDescriptor(owner, prop);
      if (desc && desc.configurable === false) return;
      var value = owner[prop];
      try {
        Object.defineProperty(owner, prop, {
          configurable: true,
          get: function () { check(); return value; },
          set: function (v) { check(); value = v; },
        });
      } catch (e) {}
    });
  }

  function noWindowOpenIf(needle) {
    var test = needleTester(needle);
    wrapFunction('open', function (target, thisArg, args) {
      var url = args.length ? String(args[0]) : '';
      if (!needle || test(url)) {
        // A harmless stand-in window.
        return new Proxy({ closed: false, close: noop, focus: noop, blur: noop, postMessage: noop }, {
          get: function (o, k) { return k in o ? o[k] : noop; },
          set: function () { return true; },
        });
      }
      return nativeReflectApply(target, thisArg, args);
    });
  }

  function nodeTextScriptlet(nodeName, apply, extra) {
    var reName = toRegex(nodeName && nodeName.charAt(0) === '/' ? nodeName : '/^' + (nodeName || 'script').toLowerCase().replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '$/');
    var condition = extra.condition ? toRegex(extra.condition) : null;
    var excludes = extra.excludes ? toRegex(extra.excludes) : null;
    var quitAfter = parseInt(extra.quitAfter || '0', 10) || 0;
    var done = 0;
    var observer;
    function handle(node) {
      if (!reName.test(node.nodeName.toLowerCase())) return;
      var text = node.textContent;
      if (!text) return;
      if (condition && !condition.test(text)) return;
      if (excludes && excludes.test(text)) return;
      var next = apply(text);
      if (next === null || next === text) return;
      try {
        if (node.nodeName === 'SCRIPT') node.textContent = trusted('script', next);
        else node.textContent = next;
      } catch (e) {
        try { node.textContent = next; } catch (e2) {}
      }
      done++;
      if (quitAfter && done >= quitAfter && observer) observer.disconnect();
    }
    observer = new MutationObserver(function (records) {
      for (var i = 0; i < records.length; i++) {
        var added = records[i].addedNodes;
        for (var j = 0; j < added.length; j++) handle(added[j]);
      }
    });
    observer.observe(document, { childList: true, subtree: true });
    if (document.documentElement) {
      var all = document.querySelectorAll(nodeName && /^[a-z]+$/i.test(nodeName) ? nodeName : 'script');
      for (var k = 0; k < all.length; k++) handle(all[k]);
    }
  }

  function removeNodeText(nodeName, needle) {
    var test = needleTester(needle);
    nodeTextScriptlet(nodeName, function (text) { return test(text) ? '' : null; }, extras(arguments, 2));
  }

  function replaceNodeText(nodeName, pattern, replacement) {
    if (!pattern) return;
    var extra = extras(arguments, 3);
    var count = parseInt(extra.sedCount || '0', 10) || 0;
    var re = toRegex(pattern, count ? undefined : 'g');
    var rep = replacement === undefined ? '' : replacement;
    nodeTextScriptlet(nodeName, function (text) {
      if (!re.test(text)) return null;
      re.lastIndex = 0;
      if (!count) return text.replace(re, rep);
      var out = text;
      for (var i = 0; i < count; i++) {
        var next = out.replace(re, rep);
        if (next === out) break;
        out = next;
      }
      return out;
    }, extra);
  }

  function noTimerIf(name, needle, delay) {
    var test = needleTester(needle);
    var delayOk = delayTester(delay);
    wrapFunction(name, function (target, thisArg, args) {
      var text = fnText(args[0]);
      if ((needle === undefined || needle === '' || test(text)) && delayOk(args[1])) {
        args = [noop].concat(Array.prototype.slice.call(args, 1));
      }
      return nativeReflectApply(target, thisArg, args);
    });
  }

  function timerBooster(name, needle, delay, boost) {
    var test = needleTester(needle === '*' ? '' : needle);
    var d = delay === undefined || delay === '' || delay === '*' ? 1000 : parseInt(delay, 10);
    var anyDelay = delay === '*';
    var b = parseFloat(boost);
    if (!(b > 0)) b = 0.05;
    b = Math.min(50, Math.max(0.001, b));
    wrapFunction(name, function (target, thisArg, args) {
      if ((anyDelay || Number(args[1]) === d) && test(fnText(args[0]))) {
        args = Array.prototype.slice.call(args);
        args[1] = (Number(args[1]) || 0) * b;
      }
      return nativeReflectApply(target, thisArg, args);
    });
  }

  function noRafIf(needle) {
    var test = needleTester(needle);
    wrapFunction('requestAnimationFrame', function (target, thisArg, args) {
      if (!needle || test(fnText(args[0]))) args = [noop];
      return nativeReflectApply(target, thisArg, args);
    });
  }

  function aeldDefuser(type, needle) {
    var testType = needleTester(type);
    var testFn = needleTester(needle);
    var proto = W.EventTarget && W.EventTarget.prototype;
    if (!proto) return;
    var original = proto.addEventListener;
    proto.addEventListener = new Proxy(original, {
      apply: function (target, thisArg, args) {
        var t = String(args[0]);
        var h = fnText(args[1] && typeof args[1] === 'object' && args[1].handleEvent ? args[1].handleEvent : args[1]);
        if ((!type || testType(t)) && (!needle || testFn(h))) return undefined;
        return nativeReflectApply(target, thisArg, args);
      },
    });
  }

  function noEvalIf(needle) {
    var test = needleTester(needle);
    wrapFunction('eval', function (target, thisArg, args) {
      if (!needle || test(String(args[0]))) return undefined;
      return nativeReflectApply(target, thisArg, args);
    });
  }

  // --- requests: fetch and XMLHttpRequest -------------------------------------------

  /** 'url:x method:POST' (or just a URL pattern) -> tester of request details. */
  function propsTester(props) {
    if (props === undefined || props === null || props === '') return null;
    var tests = [];
    var parts = String(props).split(/\s+/);
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i];
      if (!p) continue;
      var colon = p.indexOf(':');
      var key = 'url';
      var value = p;
      if (colon > 0 && /^[A-Za-z]+$/.test(p.slice(0, colon)) && !/^https?$/.test(p.slice(0, colon))) {
        key = p.slice(0, colon);
        value = p.slice(colon + 1);
      }
      tests.push({ key: key, test: needleTester(value) });
    }
    return function (details) {
      for (var i = 0; i < tests.length; i++) {
        var v = details[tests[i].key];
        if (v === undefined || !tests[i].test(String(v))) return false;
      }
      return true;
    };
  }

  function fetchDetails(args) {
    var input = args[0];
    var init = args[1] || {};
    var d = {};
    try {
      if (input instanceof Request) {
        d.url = input.url;
        d.method = input.method;
        d.mode = input.mode;
        d.credentials = input.credentials;
      } else {
        d.url = String(input);
      }
      for (var k in init) if (typeof init[k] !== 'object') d[k] = String(init[k]);
      if (typeof init.body === 'string') d.body = init.body;
      if (!d.method) d.method = 'GET';
    } catch (e) {}
    return d;
  }

  var fetchHooks = null; // { prevent: [], transform: [] }
  function installFetch() {
    if (fetchHooks) return fetchHooks;
    fetchHooks = { prevent: [], transform: [] };
    var hooks = fetchHooks;
    if (typeof nativeFetch !== 'function') return hooks;
    W.fetch = new Proxy(nativeFetch, {
      apply: function (target, thisArg, args) {
        var details = fetchDetails(args);
        for (var i = 0; i < hooks.prevent.length; i++) {
          var p = hooks.prevent[i];
          if (p.test(details)) {
            var res = new Response(p.body, { status: 200, statusText: 'OK', headers: { 'Content-Type': p.type } });
            try { Object.defineProperty(res, 'url', { value: details.url }); } catch (e) {}
            return Promise.resolve(res);
          }
        }
        var transforms = [];
        for (var j = 0; j < hooks.transform.length; j++) {
          if (hooks.transform[j].test(details)) transforms.push(hooks.transform[j].fn);
        }
        var promise = nativeReflectApply(target, thisArg, args);
        if (!transforms.length) return promise;
        return promise.then(function (response) {
          return response.clone().text().then(function (text) {
            var out = text;
            for (var k = 0; k < transforms.length; k++) out = transforms[k](out);
            if (out === text) return response;
            var copy = new Response(out, {
              status: response.status,
              statusText: response.statusText,
              headers: response.headers,
            });
            try {
              Object.defineProperties(copy, {
                url: { value: response.url },
                type: { value: response.type },
                redirected: { value: response.redirected },
              });
            } catch (e) {}
            return copy;
          }).catch(function () { return response; });
        });
      },
    });
    return hooks;
  }

  var xhrHooks = null;
  function installXhr() {
    if (xhrHooks) return xhrHooks;
    xhrHooks = { prevent: [], transform: [] };
    var hooks = xhrHooks;
    var XHR = W.XMLHttpRequest;
    if (!XHR) return hooks;
    var proto = XHR.prototype;
    var details = new WeakMap();
    var cache = new WeakMap();
    var open = proto.open;
    var send = proto.send;
    proto.open = new Proxy(open, {
      apply: function (target, thisArg, args) {
        details.set(thisArg, { method: String(args[0] || 'GET').toUpperCase(), url: String(args[1]) });
        cache.delete(thisArg);
        return nativeReflectApply(target, thisArg, args);
      },
    });
    proto.send = new Proxy(send, {
      apply: function (target, thisArg, args) {
        var d = details.get(thisArg);
        if (d) {
          if (typeof args[0] === 'string') d.body = args[0];
          for (var i = 0; i < hooks.prevent.length; i++) {
            if (!hooks.prevent[i].test(d)) continue;
            var body = hooks.prevent[i].body;
            var xhr = thisArg;
            try {
              Object.defineProperties(xhr, {
                readyState: { value: 4, configurable: true },
                status: { value: 200, configurable: true },
                statusText: { value: 'OK', configurable: true },
                responseURL: { value: d.url, configurable: true },
                responseText: { value: body, configurable: true },
                response: { value: xhr.responseType === 'json' ? safeParse(body) : body, configurable: true },
              });
            } catch (e) {}
            setTimeout(function () {
              xhr.dispatchEvent(new Event('readystatechange'));
              xhr.dispatchEvent(new ProgressEvent('load'));
              xhr.dispatchEvent(new ProgressEvent('loadend'));
            }, 1);
            return undefined;
          }
        }
        return nativeReflectApply(target, thisArg, args);
      },
    });
    function transformed(xhr, raw) {
      var d = details.get(xhr);
      if (!d || xhr.readyState !== 4) return null;
      if (cache.has(xhr)) return cache.get(xhr);
      var fns = [];
      for (var i = 0; i < hooks.transform.length; i++) if (hooks.transform[i].test(d)) fns.push(hooks.transform[i].fn);
      var out = null;
      if (fns.length && typeof raw === 'string') {
        out = raw;
        for (var j = 0; j < fns.length; j++) out = fns[j](out);
      }
      cache.set(xhr, out);
      return out;
    }
    var rt = Object.getOwnPropertyDescriptor(proto, 'responseText');
    var r = Object.getOwnPropertyDescriptor(proto, 'response');
    if (rt && rt.get) {
      Object.defineProperty(proto, 'responseText', {
        configurable: true,
        enumerable: rt.enumerable,
        get: function () {
          var raw = rt.get.call(this);
          var t = transformed(this, raw);
          return t === null ? raw : t;
        },
      });
    }
    if (r && r.get) {
      Object.defineProperty(proto, 'response', {
        configurable: true,
        enumerable: r.enumerable,
        get: function () {
          var raw = r.get.call(this);
          var type = this.responseType;
          if (type === '' || type === 'text') {
            var t = transformed(this, raw);
            return t === null ? raw : t;
          }
          if (type === 'json' && raw && typeof raw === 'object') {
            var t2 = transformed(this, nativeStringify(raw));
            return t2 === null ? raw : safeParse(t2);
          }
          return raw;
        },
      });
    }
    return hooks;
  }

  function safeParse(text) {
    try { return nativeParse(text); } catch (e) { return null; }
  }

  function preventBody(raw) {
    switch (raw) {
      case undefined: case '': return { body: '', type: 'text/plain' };
      case 'emptyObj': return { body: '{}', type: 'application/json' };
      case 'emptyArr': return { body: '[]', type: 'application/json' };
      case 'emptyStr': return { body: '', type: 'text/plain' };
      case 'true': return { body: 'true', type: 'application/json' };
      case 'false': return { body: 'false', type: 'application/json' };
      default: return { body: '', type: 'text/plain' };
    }
  }

  function noFetchIf(props, responseBody) {
    var test = propsTester(props);
    if (!test) return;
    var b = preventBody(responseBody);
    installFetch().prevent.push({ test: test, body: b.body, type: b.type });
  }

  function noXhrIf(props, directive) {
    var test = propsTester(props);
    if (!test) return;
    var b = preventBody(directive);
    installXhr().prevent.push({ test: test, body: b.body });
  }

  // --- JSON: pruning (uBlock's json-prune paths) -------------------------------------

  function pathSegments(path) {
    return path.split('.').filter(function (s) { return s !== ''; });
  }
  function hasPath(obj, segs, i) {
    if (i >= segs.length) return true;
    if (obj === null || typeof obj !== 'object') return false;
    var seg = segs[i];
    if (seg === '*' || seg === '[]' || seg === '[-]' || seg === '{-}') {
      for (var k in obj) if (hasPath(obj[k], segs, i + 1)) return true;
      return false;
    }
    if (!Object.prototype.hasOwnProperty.call(obj, seg)) return false;
    return hasPath(obj[seg], segs, i + 1);
  }
  function prunePath(obj, segs, i) {
    if (obj === null || typeof obj !== 'object') return false;
    var seg = segs[i];
    var last = i === segs.length - 1;
    var found = false;
    var k;
    if (seg === '[-]' && Array.isArray(obj)) {
      for (var a = obj.length - 1; a >= 0; a--) {
        if (hasPath(obj[a], segs, i + 1)) {
          obj.splice(a, 1);
          found = true;
        }
      }
      return found;
    }
    if (seg === '{-}') {
      for (k in obj) {
        if (hasPath(obj[k], segs, i + 1)) {
          delete obj[k];
          found = true;
        }
      }
      return found;
    }
    if (seg === '*' || seg === '[]') {
      for (k in obj) {
        if (last) {
          delete obj[k];
          found = true;
        } else if (prunePath(obj[k], segs, i + 1)) {
          found = true;
        }
      }
      return found;
    }
    if (!Object.prototype.hasOwnProperty.call(obj, seg)) return false;
    if (last) {
      delete obj[seg];
      return true;
    }
    return prunePath(obj[seg], segs, i + 1);
  }
  function makePruner(prunePaths, needlePaths) {
    var prunes = (prunePaths || '').split(/\s+/).filter(Boolean).map(pathSegments);
    var needles = (needlePaths || '').split(/\s+/).filter(Boolean).map(pathSegments);
    if (!prunes.length) return null;
    return function (obj) {
      if (obj === null || typeof obj !== 'object') return false;
      for (var n = 0; n < needles.length; n++) if (!hasPath(obj, needles[n], 0)) return false;
      var changed = false;
      for (var p = 0; p < prunes.length; p++) if (prunePath(obj, prunes[p], 0)) changed = true;
      return changed;
    };
  }

  function jsonPrune(prunePaths, needlePaths) {
    var prune = makePruner(prunePaths, needlePaths);
    if (!prune) return;
    var extra = extras(arguments, 2);
    var stackTest = extra.stackToMatch ? needleTester(extra.stackToMatch) : null;
    JSON.parse = new Proxy(JSON.parse, {
      apply: function (target, thisArg, args) {
        var result = nativeReflectApply(target, thisArg, args);
        if (stackTest) {
          var stack = '';
          try { stack = new Error().stack || ''; } catch (e) {}
          if (!stackTest(stack)) return result;
        }
        try { prune(result); } catch (e) {}
        return result;
      },
    });
    var json = Response.prototype.json;
    Response.prototype.json = new Proxy(json, {
      apply: function (target, thisArg, args) {
        return nativeReflectApply(target, thisArg, args).then(function (obj) {
          try { prune(obj); } catch (e) {}
          return obj;
        });
      },
    });
  }

  function textPruner(prune) {
    return function (text) {
      var obj = safeParse(text);
      if (obj === null) return text;
      return prune(obj) ? nativeStringify(obj) : text;
    };
  }

  function jsonPruneResponse(kind, prunePaths, needlePaths) {
    var prune = makePruner(prunePaths, needlePaths);
    if (!prune) return;
    var extra = extras(arguments, 3);
    var test = propsTester(extra.propsToMatch) || function () { return true; };
    var hooks = kind === 'fetch' ? installFetch() : installXhr();
    hooks.transform.push({ test: test, fn: textPruner(prune) });
  }

  function replaceResponse(kind, pattern, replacement, props) {
    if (!pattern) return;
    var re = toRegex(pattern, 'g');
    if (pattern.charAt(0) === '/' && !re.global) re = new RegExp(re.source, mergeFlags(re.flags, 'g'));
    var rep = replacement === undefined ? '' : replacement;
    var test = propsTester(props) || function () { return true; };
    var hooks = kind === 'fetch' ? installFetch() : installXhr();
    hooks.transform.push({
      test: test,
      fn: function (text) {
        re.lastIndex = 0;
        return text.replace(re, rep);
      },
    });
  }

  // --- JSON: editing with uBlock's JSONPath dialect -----------------------------------
  //
  // Paths like `..client[?.clientName=="WEB"]+={"clientScreen":"CHANNEL"}`:
  // `.key`, `..key` (anywhere below), `.*`, `[n]`, `["key"]`, `[?pred]`
  // (keeps the node if pred holds: `.path` exists, `!` not, `==`, `!=`,
  // `*=` contains, `^=` starts, `$=` ends, `=/re/`), then nothing (delete),
  // `=value` (JSON, or `repl({"regex":..,"replacement":..})`) or `+=object`.

  function parseJsonPath(q) {
    var i = 0;
    var steps = [];
    function readName() {
      var start = i;
      while (i < q.length && '.[=+'.indexOf(q[i]) < 0) i++;
      return q.slice(start, i);
    }
    function readBracket() {
      var depth = 0;
      var start = i;
      var quote = null;
      for (; i < q.length; i++) {
        var c = q[i];
        if (quote) {
          if (c === '\\') { i++; continue; }
          if (c === quote) quote = null;
          continue;
        }
        if (c === '"' || c === "'") quote = c;
        else if (c === '[') depth++;
        else if (c === ']') {
          depth--;
          if (depth === 0) { i++; return q.slice(start + 1, i - 1); }
        }
      }
      return null;
    }
    while (i < q.length) {
      var c = q[i];
      if (c === '.' && q[i + 1] === '.') {
        i += 2;
        if (q[i] === '[') steps.push({ t: 'desc', name: '*' });
        else steps.push({ t: 'desc', name: readName() || '*' });
      } else if (c === '.') {
        i++;
        if (q[i] === '[') continue;
        var n = readName();
        steps.push(n === '*' || n === '' ? { t: 'all' } : { t: 'key', name: n });
      } else if (c === '[') {
        var inner = readBracket();
        if (inner === null) return null;
        if (inner.charAt(0) === '?') steps.push({ t: 'filter', pred: parsePredicate(inner.slice(1)) });
        else if (inner === '*' || inner === '' || inner === '-') steps.push({ t: 'all' });
        else if (/^-?\d+$/.test(inner)) steps.push({ t: 'index', n: parseInt(inner, 10) });
        else if (/^(["']).*\1$/.test(inner)) steps.push({ t: 'key', name: inner.slice(1, -1) });
        else steps.push({ t: 'key', name: inner });
      } else if (c === '+' && q[i + 1] === '=') {
        return { steps: steps, op: '+=', value: parseEditValue(q.slice(i + 2)) };
      } else if (c === '=') {
        return { steps: steps, op: '=', value: parseEditValue(q.slice(i + 1)) };
      } else {
        // A path may start with a name ("a.b").
        var name = readName();
        if (!name) return null;
        steps.push({ t: 'key', name: name });
      }
    }
    return { steps: steps, op: null };
  }

  function parseEditValue(text) {
    var m = /^repl\((.*)\)$/.exec(text);
    if (m) {
      var r = safeParse(m[1]);
      if (r && typeof r.regex === 'string') {
        var re = toRegex(r.regex.charAt(0) === '/' ? r.regex : '/' + r.regex + '/');
        return { repl: re, replacement: r.replacement || '' };
      }
      return { invalid: true };
    }
    try { return { v: nativeParse(text) }; } catch (e) { return { invalid: true }; }
  }

  function parsePredicate(text) {
    var not = false;
    var s = text;
    if (s.charAt(0) === '!') { not = true; s = s.slice(1); }
    var m = /^(.*?)(==|!=|\*=|\^=|\$=|=\/)(.*)$/.exec(s);
    var path = m ? m[1] : s;
    var op = m ? m[2] : null;
    var raw = m ? m[3] : null;
    var value;
    if (op === '=/') {
      value = toRegex('/' + raw);
      op = 're';
    } else if (op) {
      try { value = nativeParse(raw); } catch (e) { value = raw; }
    }
    var parsed = parseJsonPath(path);
    var steps = parsed ? parsed.steps : [];
    return function (node) {
      var refs = evalSteps([{ parent: null, key: null, value: node }], steps);
      var ok = false;
      for (var i = 0; i < refs.length && !ok; i++) {
        var v = refs[i].value;
        if (v === undefined) continue;
        if (!op) ok = true;
        else if (op === '==') ok = v === value;
        else if (op === '!=') ok = v !== value;
        else if (typeof v !== 'string') ok = false;
        else if (op === '*=') ok = v.indexOf(value) >= 0;
        else if (op === '^=') ok = v.indexOf(value) === 0;
        else if (op === '$=') ok = v.slice(-String(value).length) === String(value);
        else if (op === 're') ok = value.test(v);
      }
      return ok !== not;
    };
  }

  function evalSteps(refs, steps) {
    var cur = refs;
    for (var s = 0; s < steps.length; s++) {
      var step = steps[s];
      var next = [];
      for (var r = 0; r < cur.length; r++) {
        var v = cur[r].value;
        if (step.t === 'filter') {
          if (step.pred(v)) next.push(cur[r]);
          continue;
        }
        if (v === null || typeof v !== 'object') continue;
        if (step.t === 'key') {
          if (Object.prototype.hasOwnProperty.call(v, step.name)) next.push({ parent: v, key: step.name, value: v[step.name] });
        } else if (step.t === 'all') {
          for (var k in v) next.push({ parent: v, key: Array.isArray(v) ? Number(k) : k, value: v[k] });
        } else if (step.t === 'index') {
          if (Array.isArray(v)) {
            var idx = step.n < 0 ? v.length + step.n : step.n;
            if (idx >= 0 && idx < v.length) next.push({ parent: v, key: idx, value: v[idx] });
          }
        } else if (step.t === 'desc') {
          collectDescendants(v, step.name, next, 0);
        }
      }
      cur = next;
    }
    return cur;
  }

  function collectDescendants(obj, name, out, depth) {
    if (depth > 64 || obj === null || typeof obj !== 'object') return;
    for (var k in obj) {
      var child = obj[k];
      if (name === '*' || k === name) out.push({ parent: obj, key: Array.isArray(obj) ? Number(k) : k, value: child });
      collectDescendants(child, name, out, depth + 1);
    }
  }

  /** Applies the edit [q] (parsed) to [root]; returns the (maybe new) root, or undefined if nothing changed. */
  function applyJsonEdit(edit, root, allowAssign) {
    if (!edit) return undefined;
    var refs = evalSteps([{ parent: null, key: null, value: root }], edit.steps);
    if (!refs.length) return undefined;
    var changed = false;
    if (edit.op === null) {
      // Delete - array elements from the back, so indices stay right.
      refs.sort(function (a, b) { return typeof a.key === 'number' && typeof b.key === 'number' ? b.key - a.key : 0; });
      for (var i = 0; i < refs.length; i++) {
        var ref = refs[i];
        if (!ref.parent) continue;
        if (Array.isArray(ref.parent) && typeof ref.key === 'number') ref.parent.splice(ref.key, 1);
        else delete ref.parent[ref.key];
        changed = true;
      }
      return changed ? root : undefined;
    }
    if (!allowAssign || edit.value.invalid) return undefined;
    for (var j = 0; j < refs.length; j++) {
      var rf = refs[j];
      if (edit.op === '+=') {
        if (rf.value && typeof rf.value === 'object' && edit.value.v && typeof edit.value.v === 'object') {
          Object.assign(rf.value, nativeParse(nativeStringify(edit.value.v)));
          changed = true;
        }
        continue;
      }
      var nv;
      if (edit.value.repl) {
        if (typeof rf.value !== 'string') continue;
        nv = rf.value.replace(edit.value.repl, edit.value.replacement);
      } else {
        nv = edit.value.v && typeof edit.value.v === 'object' ? nativeParse(nativeStringify(edit.value.v)) : edit.value.v;
      }
      if (!rf.parent) {
        root = nv;
      } else {
        rf.parent[rf.key] = nv;
      }
      changed = true;
    }
    return changed ? root : undefined;
  }

  function jsonEdit(allowAssign, q) {
    var edit = q ? parseJsonPath(q) : null;
    if (!edit) return;
    JSON.parse = new Proxy(JSON.parse, {
      apply: function (target, thisArg, args) {
        var result = nativeReflectApply(target, thisArg, args);
        try {
          var out = applyJsonEdit(edit, result, allowAssign);
          if (out !== undefined) return out;
        } catch (e) {}
        return result;
      },
    });
  }

  function jsonEditResponse(kind, allowAssign, q) {
    var edit = q ? parseJsonPath(q) : null;
    if (!edit) return;
    var extra = extras(arguments, 3);
    var test = propsTester(extra.propsToMatch) || function () { return true; };
    var hooks = kind === 'fetch' ? installFetch() : installXhr();
    hooks.transform.push({
      test: test,
      fn: function (text) {
        var obj = safeParse(text);
        if (obj === null) return text;
        var out = applyJsonEdit(edit, obj, allowAssign);
        return out === undefined ? text : nativeStringify(out);
      },
    });
  }

  function editInboundObject(chain, argPos, q) {
    var edit = q ? parseJsonPath(q) : null;
    if (!edit) return;
    var pos = parseInt(argPos || '0', 10) || 0;
    wrapFunction(chain, function (target, thisArg, args) {
      var a = args[pos];
      if (a && typeof a === 'object') {
        try {
          var copy = nativeParse(nativeStringify(a));
          var out = applyJsonEdit(edit, copy, true);
          if (out !== undefined) {
            args = Array.prototype.slice.call(args);
            args[pos] = out;
          }
        } catch (e) {}
      }
      return nativeReflectApply(target, thisArg, args);
    });
  }

  function replaceArgument(chain, argPos, argRaw) {
    if (!chain || argRaw === undefined) return;
    var pos = parseInt(argPos || '0', 10) || 0;
    var extra = extras(arguments, 3);
    var condition = extra.condition ? toRegex(extra.condition) : null;
    var repl = null;
    var value;
    var m = /^repl:\/(.+)\/(.*)\/$/.exec(argRaw);
    if (m) {
      repl = { re: toRegex('/' + m[1] + '/'), to: m[2] };
    } else {
      var c = constantValue(argRaw, true);
      value = c ? c.v : argRaw;
    }
    wrapFunction(chain, function (target, thisArg, args) {
      var a = args;
      var current = pos === -1 ? thisArg : a[pos];
      if (!condition || condition.test(String(current))) {
        var next = repl ? String(current).replace(repl.re, repl.to) : value;
        if (pos === -1) thisArg = next;
        else {
          a = Array.prototype.slice.call(args);
          a[pos] = next;
        }
      }
      return nativeReflectApply(target, thisArg, a);
    });
  }

  function replaceOutboundText(chain, pattern, replacement) {
    if (!chain || !pattern) return;
    var extra = extras(arguments, 3);
    var condition = extra.condition ? toRegex(extra.condition) : null;
    var re = toRegex(pattern);
    var rep = replacement || '';
    wrapFunction(chain, function (target, thisArg, args) {
      var out = nativeReflectApply(target, thisArg, args);
      if (typeof out !== 'string') return out;
      if (condition && !condition.test(out)) return out;
      return out.replace(re, rep);
    });
  }

  function preventDomBypass(methodChain, targetProp) {
    if (!methodChain || !targetProp) return;
    function patch(node) {
      if (!node || node.nodeType !== 1) return;
      var frames = node.tagName === 'IFRAME' ? [node] : node.querySelectorAll ? node.querySelectorAll('iframe') : [];
      for (var i = 0; i < frames.length; i++) {
        var w;
        try { w = frames[i].contentWindow; } catch (e) { continue; }
        if (!w) continue;
        try {
          var src = chainOwner(targetProp);
          var parts = targetProp.split('.');
          var prop = parts.pop();
          var owner = parts.length ? chainValue(parts.join('.'), w) : w;
          if (src && owner) owner[prop] = src.owner[src.prop];
        } catch (e) {}
      }
    }
    wrapFunction(methodChain, function (target, thisArg, args) {
      var out = nativeReflectApply(target, thisArg, args);
      try { patch(args[0]); } catch (e) {}
      return out;
    });
  }

  // --- DOM ---------------------------------------------------------------------------

  function removeAttr(attrs, selector, behavior) {
    var names = (attrs || '').split(/\s*\|\s*/).filter(Boolean);
    if (!names.length) return;
    var sel = selector || names.map(function (n) { return '[' + n + ']'; }).join(',');
    runOnElements(function () {
      var els = document.querySelectorAll(sel);
      for (var i = 0; i < els.length; i++) for (var j = 0; j < names.length; j++) els[i].removeAttribute(names[j]);
    }, behavior);
  }

  function removeClass(classes, selector, behavior) {
    var names = (classes || '').split(/\s*\|\s*/).filter(Boolean);
    if (!names.length) return;
    var sel = selector || names.map(function (n) { return '.' + n; }).join(',');
    runOnElements(function () {
      var els = document.querySelectorAll(sel);
      for (var i = 0; i < els.length; i++) els[i].classList.remove.apply(els[i].classList, names);
    }, behavior);
  }

  function setAttr(isTrusted, selector, attr, value) {
    if (!selector || !attr) return;
    var v = value === undefined ? '' : value;
    if (!isTrusted && !/^(|true|false|-?\d+|\[[\w-]+\])$/.test(v)) return;
    runOnElements(function () {
      var els = document.querySelectorAll(selector);
      for (var i = 0; i < els.length; i++) {
        var val = /^\[([\w-]+)\]$/.test(v) ? els[i].getAttribute(v.slice(1, -1)) : v;
        if (val !== null) els[i].setAttribute(attr, val);
      }
    }, 'stay');
  }

  function hrefSanitizer(selector, source) {
    if (!selector) return;
    var src = source || 'text';
    runOnElements(function () {
      var els = document.querySelectorAll(selector);
      for (var i = 0; i < els.length; i++) {
        var a = els[i];
        var url = null;
        if (src === 'text') url = (a.textContent || '').trim();
        else if (src.charAt(0) === '?') {
          try { url = new URL(a.href).searchParams.get(src.slice(1)); } catch (e) {}
        } else if (src.charAt(0) === '[') url = a.getAttribute(src.slice(1, -1));
        if (url && /^https?:\/\//.test(url)) a.setAttribute('href', url);
      }
    }, 'stay');
  }

  function refreshDefuser() {
    onReady(function () {
      var metas = document.querySelectorAll('meta[http-equiv="refresh" i]');
      for (var i = 0; i < metas.length; i++) metas[i].remove();
    });
  }

  function preventInnerHTML(selector, needle) {
    var test = needleTester(needle);
    var proto = W.Element && W.Element.prototype;
    var desc = proto && Object.getOwnPropertyDescriptor(proto, 'innerHTML');
    if (!desc || !desc.set) return;
    Object.defineProperty(proto, 'innerHTML', {
      configurable: true,
      enumerable: desc.enumerable,
      get: desc.get,
      set: function (v) {
        if ((!selector || this.matches(selector)) && (!needle || test(String(v)))) return;
        desc.set.call(this, v);
      },
    });
  }

  function setStorageItem(isTrusted, which, key, value) {
    if (!key) return;
    var store;
    try { store = W[which]; } catch (e) { return; }
    if (!store) return;
    try {
      if (value === '$remove$') {
        store.removeItem(key);
        return;
      }
      var allowed = /^(undefined|false|true|null|emptyArr|emptyObj|yes|no|on|off|accept|accepted|reject|rejected|-?\d+|)$/;
      if (!isTrusted && !allowed.test(value)) return;
      var v = value === 'emptyArr' ? '[]' : value === 'emptyObj' ? '{}' : value;
      store.setItem(key, v);
    } catch (e) {}
  }

  function removeCookie(needle) {
    var test = needleTester(needle);
    function run() {
      var cookies = document.cookie.split(';');
      for (var i = 0; i < cookies.length; i++) {
        var name = cookies[i].split('=')[0].trim();
        if (!name || (needle && !test(name))) continue;
        var parts = location.hostname.split('.');
        for (var j = 0; j < parts.length - 1; j++) {
          var domain = parts.slice(j).join('.');
          document.cookie = name + '=; max-age=0; path=/; domain=' + domain;
          document.cookie = name + '=; max-age=0; path=/; domain=.' + domain;
        }
        document.cookie = name + '=; max-age=0; path=/';
      }
    }
    run();
    W.addEventListener('beforeunload', run);
    onReady(run);
  }

  function noWebrtc() {
    var Pc = W.RTCPeerConnection || W.webkitRTCPeerConnection;
    if (!Pc) return;
    var Fake = function () {
      return { close: noop, createDataChannel: noop, createOffer: function () { return Promise.reject(abortError()); }, setRemoteDescription: noop, addEventListener: noop };
    };
    try { W.RTCPeerConnection = Fake; } catch (e) {}
    try { W.webkitRTCPeerConnection = Fake; } catch (e) {}
  }

  function clickElement(selectors) {
    if (!selectors) return;
    var list = selectors.split(/\s*,\s*/).filter(Boolean);
    var i = 0;
    var tries = 0;
    var timer = setInterval(function () {
      if (i >= list.length || ++tries > 50) {
        clearInterval(timer);
        return;
      }
      var el = document.querySelector(list[i]);
      if (el) {
        try { el.click(); } catch (e) {}
        i++;
      }
    }, 200);
  }

  // --- the table --------------------------------------------------------------------

  var lib = {
    'set-constant': function () { setConstant.apply(null, [false].concat([].slice.call(arguments))); },
    'trusted-set-constant': function () { setConstant.apply(null, [true].concat([].slice.call(arguments))); },
    'abort-on-property-read': abortOnRead,
    'abort-on-property-write': abortOnWrite,
    'abort-current-script': abortCurrentScript,
    'abort-on-stack-trace': abortOnStackTrace,
    'no-window-open-if': noWindowOpenIf,
    'remove-node-text': removeNodeText,
    'replace-node-text': replaceNodeText,
    'trusted-replace-node-text': replaceNodeText,
    'no-setTimeout-if': function (n, d) { noTimerIf('setTimeout', n, d); },
    'no-setInterval-if': function (n, d) { noTimerIf('setInterval', n, d); },
    'no-requestAnimationFrame-if': noRafIf,
    'nano-setTimeout-booster': function (n, d, b) { timerBooster('setTimeout', n, d, b); },
    'nano-setInterval-booster': function (n, d, b) { timerBooster('setInterval', n, d, b); },
    'addEventListener-defuser': aeldDefuser,
    'noeval-if': noEvalIf,
    'noeval': function () { noEvalIf(''); },
    'no-fetch-if': noFetchIf,
    'no-xhr-if': noXhrIf,
    'json-prune': jsonPrune,
    'json-prune-fetch-response': function () { jsonPruneResponse.apply(null, ['fetch'].concat([].slice.call(arguments))); },
    'json-prune-xhr-response': function () { jsonPruneResponse.apply(null, ['xhr'].concat([].slice.call(arguments))); },
    'trusted-replace-fetch-response': function (p, r, props) { replaceResponse('fetch', p, r, props); },
    'trusted-replace-xhr-response': function (p, r, props) { replaceResponse('xhr', p, r, props); },
    'json-edit': function (q) { jsonEdit(false, q); },
    'trusted-json-edit': function (q) { jsonEdit(true, q); },
    'json-edit-fetch-response': function () { jsonEditResponse.apply(null, ['fetch', false].concat([].slice.call(arguments))); },
    'trusted-json-edit-fetch-response': function () { jsonEditResponse.apply(null, ['fetch', true].concat([].slice.call(arguments))); },
    'json-edit-xhr-response': function () { jsonEditResponse.apply(null, ['xhr', false].concat([].slice.call(arguments))); },
    'trusted-json-edit-xhr-response': function () { jsonEditResponse.apply(null, ['xhr', true].concat([].slice.call(arguments))); },
    'trusted-edit-inbound-object': editInboundObject,
    'trusted-replace-argument': replaceArgument,
    'trusted-replace-outbound-text': replaceOutboundText,
    'trusted-prevent-dom-bypass': preventDomBypass,
    'remove-attr': removeAttr,
    'remove-class': removeClass,
    'set-attr': function (s, a, v) { setAttr(false, s, a, v); },
    'trusted-set-attr': function (s, a, v) { setAttr(true, s, a, v); },
    'href-sanitizer': hrefSanitizer,
    'refresh-defuser': refreshDefuser,
    'prevent-innerHTML': preventInnerHTML,
    'set-local-storage-item': function (k, v) { setStorageItem(false, 'localStorage', k, v); },
    'trusted-set-local-storage-item': function (k, v) { setStorageItem(true, 'localStorage', k, v); },
    'set-session-storage-item': function (k, v) { setStorageItem(false, 'sessionStorage', k, v); },
    'remove-cookie': removeCookie,
    'nowebrtc': noWebrtc,
    'trusted-click-element': clickElement,
  };

  return function (name, args) {
    var f = lib[name];
    if (!f) return false;
    try {
      f.apply(null, args);
    } catch (e) {}
    return true;
  };
})();
