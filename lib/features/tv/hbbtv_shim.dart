import 'dart:convert';

import '../../data/services/hbbtv_ait.dart';

/// The channel and settings the HbbTV objects in the page report.
class HbbtvShimConfig {
  const HbbtvShimConfig({
    required this.channelName,
    required this.channelNumber,
    this.triplet,
    this.apps = const [],
    this.autoRed = false,
    this.language = 'deu',
    this.country = 'DEU',
  });

  final String channelName;
  final int channelNumber;
  final DvbTriplet? triplet;

  /// The AIT's apps - `dvb://current.ait/<org>.<app>` links lead to them.
  final List<HbbtvApp> apps;

  /// Press red in the page once it's ready: the channel's autostart app
  /// waits for it to open its portal (on a TV it runs from the start and
  /// the viewer presses red).
  final bool autoRed;

  /// ISO 639-2 (deu, eng) and ISO 3166 alpha-3 (AUT, DEU, CHE).
  final String language;
  final String country;

  Map<String, Object?> toJson() => {
        'channel': {
          'name': channelName,
          'number': channelNumber,
          'onid': triplet?.onid ?? 0,
          'tsid': triplet?.tsid ?? 0,
          'sid': triplet?.sid ?? 0,
        },
        'apps': [for (final a in apps) a.toJson()],
        'autoRed': autoRed,
        'lang': language,
        'country': country,
      };
}

/// The script put in front of every page of an HbbTV app: what an HbbTV
/// TV set offers its apps, as far as they need it to start - KeyEvent.VK_*
/// constants, the OIPF objects (application manager with the app's keyset
/// and show/hide, configuration, capabilities, DRM agent, a video/broadcast
/// object - the live picture runs under the transparent page), A/V control
/// objects played with an HTML5 video; the page scaled from HbbTV's
/// 1280×720 to the screen. `window.__hbb.key(name)` presses a key of the
/// remote in the page; what the page wants of the TV goes to the app over
/// the "HbbtvHost" JavaScript channel.
String hbbtvShim(HbbtvShimConfig config) => 'window.__hbbCfg=${jsonEncode(config.toJson())};\n$_shim';

const _shim = r"""
(function () {
  if (window.__hbb) return;
  var cfg = window.__hbbCfg || {};
  var H = window.__hbb = { hidden: false, liveStopped: false };
  function post(t, d) {
    try { window.HbbtvHost.postMessage(JSON.stringify({ t: t, d: d === undefined ? null : d })); } catch (e) {}
  }
  function noop() {}

  // ---- Keys -------------------------------------------------------------
  var K = {
    VK_LEFT: 37, VK_UP: 38, VK_RIGHT: 39, VK_DOWN: 40, VK_ENTER: 13, VK_BACK: 461,
    VK_RED: 403, VK_GREEN: 404, VK_YELLOW: 405, VK_BLUE: 406,
    VK_PLAY: 415, VK_PAUSE: 19, VK_PLAY_PAUSE: 402, VK_STOP: 413, VK_FAST_FWD: 417, VK_REWIND: 412,
    VK_TRACK_NEXT: 425, VK_TRACK_PREV: 424, VK_INFO: 457, VK_TELETEXT: 459, VK_SUBTITLE: 460,
    VK_PAGE_UP: 33, VK_PAGE_DOWN: 34
  };
  for (var n = 0; n <= 9; n++) K['VK_' + n] = 48 + n;
  var KE = window.KeyEvent || {};
  for (var k in K) { try { if (KE[k] === undefined) KE[k] = K[k]; } catch (e) {} }
  try { window.KeyEvent = KE; } catch (e) {}
  var NAMES = {
    left: 37, up: 38, right: 39, down: 40, enter: 13, back: 461, red: 403, green: 404, yellow: 405, blue: 406,
    play: 415, pause: 19, stop: 413, ffwd: 417, rew: 412, next: 425, prev: 424, info: 457, text: 459
  };
  var KEYNAMES = { 37: 'ArrowLeft', 38: 'ArrowUp', 39: 'ArrowRight', 40: 'ArrowDown', 13: 'Enter' };
  function keyEvent(type, code) {
    var e;
    try { e = new KeyboardEvent(type, { bubbles: true, cancelable: true, key: KEYNAMES[code] || (code >= 48 && code <= 57 ? String(code - 48) : 'Unidentified') }); }
    catch (x) { e = document.createEvent('Event'); e.initEvent(type, true, true); }
    try {
      Object.defineProperty(e, 'keyCode', { get: function () { return code; } });
      Object.defineProperty(e, 'which', { get: function () { return code; } });
      Object.defineProperty(e, 'charCode', { get: function () { return 0; } });
    } catch (x) {}
    return e;
  }
  H.key = function (name) {
    var code = NAMES[name];
    if (/^[0-9]$/.test(name)) code = 48 + Number(name);
    if (name === 'playpause') code = playing() ? 19 : 415;
    if (!code) return 'ignored';
    var target = document.activeElement || document.body || document.documentElement;
    var handled = false;
    try { handled = !target.dispatchEvent(keyEvent('keydown', code)); } catch (e) {}
    try { target.dispatchEvent(keyEvent('keyup', code)); } catch (e) {}
    return handled ? 'handled' : 'ignored';
  };

  // Whether the page listens to keys yet (for the first red).
  var keyListeners = 0;
  try {
    var addEL = EventTarget.prototype.addEventListener;
    EventTarget.prototype.addEventListener = function (type, fn, opt) {
      if (type === 'keydown' || type === 'keypress' || type === 'keyup') keyListeners++;
      return addEL.call(this, type, fn, opt);
    };
  } catch (e) {}
  function listensToKeys() {
    return keyListeners > 0 || !!(document.onkeydown || window.onkeydown || (document.body && document.body.onkeydown) ||
      document.onkeypress || window.onkeypress);
  }

  // ---- The application and its manager --------------------------------
  var keyset = {
    RED: 1, GREEN: 2, YELLOW: 4, BLUE: 8, NAVIGATION: 16, VCR: 32, SCROLL: 64, INFO: 128, NUMERIC: 256, ALPHA: 512, OTHER: 1024,
    value: 0x1F, maximumValue: 0x7FF, otherKeys: [], maximumOtherKeys: [], supportsPointer: false,
    setValue: function (v) { keyset.value = v; return v; },
    getKey: function () { return null; }, getKeyIcon: function () { return ''; }
  };
  function channel() {
    var c = cfg.channel || {};
    return {
      channelType: 0, idType: 12, ccid: 'ccid:' + c.onid + '.' + c.tsid + '.' + c.sid, dsd: '',
      onid: c.onid, tsid: c.tsid, sid: c.sid, nid: c.onid, name: c.name, longName: c.name, description: '',
      majorChannel: c.number || 0, minorChannel: 0, favIDs: [], locked: false, manualBlock: false, authorised: true,
      genre: [], hidden: false, ipBroadcastID: null, logoURL: ''
    };
  }
  function setHidden(h) {
    H.hidden = h;
    try { document.documentElement.style.visibility = h ? 'hidden' : ''; } catch (e) {}
    post(h ? 'hide' : 'show');
  }
  function resolveApp(uri) {
    uri = String(uri || '');
    var m = /^dvb:\/\/current\.ait\/([0-9a-f]+)\.([0-9a-f]+)(.*)$/i.exec(uri);
    if (m) {
      var org = parseInt(m[1], 16), id = parseInt(m[2], 16), url = null;
      (cfg.apps || []).forEach(function (a) { if (a.org === org && a.app === id && a.url) url = a.url; });
      if (!url) return null;
      var rest = m[3] || '';
      if (rest.charAt(0) === '?') url += (url.indexOf('?') < 0 ? '?' : '&') + rest.substring(1);
      else if (rest.charAt(0) === '#') url += rest;
      return url;
    }
    if (/^dvb:/i.test(uri)) return null;
    try { return new URL(uri, location.href).href; } catch (e) { return null; }
  }
  var app = {
    visible: true, active: true, permissions: [], isPrimaryReceiver: true,
    privateData: { keyset: keyset, get currentChannel() { return channel(); }, getFreeMem: function () { return 64 * 1024 * 1024; } },
    show: function () { app.visible = true; setHidden(false); return true; },
    hide: function () { app.visible = false; setHidden(true); return true; },
    activate: noop, deactivate: noop, addEventListener: noop, removeEventListener: noop,
    createApplication: function (uri) {
      var url = resolveApp(uri);
      if (!url) return null;
      post('launch', url);
      return app;
    },
    destroyApplication: function () { post('destroy'); },
    startWidget: noop, stopWidget: noop
  };
  var appManager = {
    getOwnerApplication: function () { return app; },
    getChildApplications: function () { return []; },
    getApplicationVisualizationMode: function () { return 1; },
    onLowMemory: null, onApplicationLoadError: null, widgets: []
  };

  // ---- Configuration, capabilities, DRM ---------------------------------
  var configuration = {
    configuration: {
      preferredAudioLanguage: cfg.lang || 'deu', preferredSubtitleLanguage: cfg.lang || 'deu',
      preferredUILanguage: cfg.lang || 'deu', countryId: cfg.country || 'DEU', subtitlesEnabled: false,
      audioDescriptionEnabled: false, timeShiftSynchronized: false, dtt_network_ids: [], deviceId: 'homesystem',
      requestAccessToDistinctiveIdentifier: function (cb) { if (typeof cb === 'function') setTimeout(function () { cb(false); }, 0); },
      getText: function () { return ''; }, setText: noop
    },
    localSystem: {
      deviceID: 'homesystem', systemReady: true, vendorName: 'JayCloud', modelName: 'HomeSystem', familyName: 'HomeSystem',
      softwareVersion: '1.0', hardwareVersion: '1.0', serialNumber: '0', releaseVersion: 1, majorVersion: 1, minorVersion: 0,
      oipfProfile: 'OITF_HD_UIPROF+DVB_S+TRICKMODE', pvrEnabled: false, ciplusEnabled: false, powerState: 1,
      volume: 100, mute: false, outputs: [], networkInterfaces: [], tvStandardsSupported: 0, startupInformation: null
    }
  };
  var capsXml = '<profilelist><ui_profile name="OITF_HD_UIPROF+DVB_S+TRICKMODE"><ext><parentalcontrol schemes="dvb-si">true</parentalcontrol>' +
    '<clientMetadata type="dvb-si">true</clientMetadata></ext></ui_profile><video_profile name="MP4_AVC_SD_25_HEAAC" type="video/mp4"/>' +
    '<video_profile name="MP4_AVC_HD_25_HEAAC" type="video/mp4"/><video_profile name="DASH_AVC_SD_25_HEAAC" type="application/dash+xml"/>' +
    '<video_profile name="DASH_AVC_HD_25_HEAAC" type="application/dash+xml"/></profilelist>';
  var capabilities = {
    get xmlCapabilities() { try { return new DOMParser().parseFromString(capsXml, 'text/xml'); } catch (e) { return null; } },
    extraSDVideoDecodes: 0, extraHDVideoDecodes: 0,
    hasCapability: function (c) { return /TRICKMODE|DVB_S|HD_UIPROF/.test(String(c)); }
  };
  var drmMsg = 0;
  var drmAgent = {
    onDRMMessageResult: null, onDRMRightsError: null, onDRMSystemStatusChange: null, onDRMSystemMessage: null,
    sendDRMMessage: function () {
      var id = String(++drmMsg), self = this;
      setTimeout(function () { if (typeof self.onDRMMessageResult === 'function') self.onDRMMessageResult(id, '', 4); }, 0);
      return id;
    },
    DRMSystemStatus: function () { return 3; },
    getDRMSystemID: function () { return null; }
  };
  var parental = { parentalRatingSchemes: [], isPINEntryLocked: false, getBlockUnrated: function () { return false; }, setParentalControlStatus: noop };

  // ---- The live picture (video/broadcast) -------------------------------
  function fire(el, name, props, handler, args) {
    try {
      var ev = document.createEvent('Event');
      ev.initEvent(name, false, false);
      for (var p in props) ev[p] = props[p];
      el.dispatchEvent(ev);
    } catch (e) {}
    try { if (typeof el[handler] === 'function') el[handler].apply(el, args || []); } catch (e) {}
  }
  function bc(el) { if (!el.__hbbBc) el.__hbbBc = { state: 0, fullScreen: false }; return el.__hbbBc; }
  function setLive(want) {
    if (H.liveStopped === !want) return;
    H.liveStopped = !want;
    post('broadcast', want);
  }
  function bcState(el, state, error) {
    bc(el).state = state;
    fire(el, 'PlayStateChange', { state: state, error: error }, 'onPlayStateChange', [state, error]);
  }

  // ---- A/V control objects (video/mp4, DASH ...) as HTML5 video ---------
  var AV = /^(video\/(mp4|mpeg|mpeg4|mp2t|x-ms-asf)|audio\/(mp4|mpeg|mp3)|application\/(dash\+xml|vnd\.apple\.mpegurl|x-mpegurl))/i;
  function typeOf(el) { return String(el.getAttribute('type') || '').toLowerCase(); }
  function isBc(el) { return typeOf(el) === 'video/broadcast'; }
  function isAv(el) { return AV.test(typeOf(el)); }
  function av(el) { if (!el.__hbbAv) el.__hbbAv = { state: 0, speed: 0, video: null, error: undefined, src: '' }; return el.__hbbAv; }
  function avState(el, state) {
    var s = av(el);
    if (s.state === state) return;
    s.state = state;
    fire(el, 'PlayStateChange', { state: state }, 'onPlayStateChange', []);
  }
  function avVideo(el) {
    var s = av(el);
    if (s.video && s.video.isConnected) return s.video;
    var v = document.createElement('video');
    v.setAttribute('playsinline', '');
    v.__hbbOwn = true;
    v.addEventListener('playing', function () { avState(el, 1); post('media', true); });
    v.addEventListener('waiting', function () { if (s.state === 1) avState(el, 4); });
    v.addEventListener('pause', function () { if (s.speed === 0 && s.state !== 0) avState(el, 2); });
    v.addEventListener('ended', function () { avState(el, 5); post('media', false); });
    v.addEventListener('error', function () {
      s.error = v.error && v.error.code === 2 ? 1 : 0;
      avState(el, 6);
    });
    if (el.parentNode) el.parentNode.insertBefore(v, el.nextSibling);
    s.video = v;
    return v;
  }
  function placeVideo(el, v) {
    try {
      var cs = getComputedStyle(el);
      v.style.position = cs.position === 'static' ? 'relative' : cs.position;
      v.style.left = cs.left; v.style.top = cs.top; v.style.width = cs.width; v.style.height = cs.height;
      v.style.zIndex = cs.zIndex; v.style.background = '#000'; v.style.objectFit = 'contain';
      v.style.display = cs.display === 'none' ? 'none' : 'block';
    } catch (e) {}
  }
  function playing() {
    var vids = document.getElementsByTagName('video');
    for (var i = 0; i < vids.length; i++) if (!vids[i].paused && !vids[i].ended) return true;
    return false;
  }

  // ---- The OIPF methods on <object> elements ----------------------------
  var P = window.HTMLObjectElement && HTMLObjectElement.prototype;
  function def(name, fn) { try { Object.defineProperty(P, name, { value: fn, configurable: true, writable: true }); } catch (e) {} }
  function prop(name, get, set) {
    try { Object.defineProperty(P, name, { get: get, set: set || function (v) { this['__hbb_' + name] = v; }, configurable: true }); } catch (e) {}
  }
  if (P) {
    def('getOwnerApplication', function () { return app; });
    def('getChildApplications', function () { return []; });
    def('getChannelConfig', function () {
      var list = [channel()];
      list.item = function (i) { return list[i] || null; };
      list.getChannel = function (ccid) { return ccid === channel().ccid ? channel() : null; };
      list.getChannelByTriplet = function (onid, tsid, sid) { var c = channel(); return c.onid === onid && c.sid === sid ? c : null; };
      list.getChannelBySourceID = function () { return null; };
      return { channelList: list, currentChannel: channel(), favouriteLists: [], currentFavouriteList: null };
    });
    def('bindToCurrentChannel', function () {
      if (!isBc(this)) return null;
      setLive(true);
      bcState(this, 2);
      return channel();
    });
    def('setChannel', function (ch) {
      if (!isBc(this)) return;
      if (ch === null || ch === undefined) { setLive(false); bcState(this, 0); return; }
      var c = channel();
      if (ch.sid === c.sid && ch.onid === c.onid) {
        setLive(true);
        bcState(this, 2);
        fire(this, 'ChannelChangeSucceeded', { channel: c }, 'onChannelChangeSucceeded', [c]);
      } else {
        fire(this, 'ChannelChangeError', { channel: ch, errorState: 0 }, 'onChannelChangeError', [ch, 0]);
      }
    });
    def('prevChannel', function () { fire(this, 'ChannelChangeError', { channel: null, errorState: 0 }, 'onChannelChangeError', [null, 0]); });
    def('nextChannel', function () { fire(this, 'ChannelChangeError', { channel: null, errorState: 0 }, 'onChannelChangeError', [null, 0]); });
    def('release', function () { if (isBc(this)) { setLive(false); bcState(this, 0); } else if (isAv(this)) this.stop(); });
    def('setFullScreen', function (f) { bc(this).fullScreen = !!f; fire(this, 'FullScreenChange', {}, 'onFullScreenChange', []); });
    def('getComponents', function () { return []; });
    def('getCurrentActiveComponents', function () { return []; });
    def('selectComponent', noop);
    def('unselectComponent', noop);
    def('setVolume', function () { return true; });
    def('getVolume', function () { return 100; });
    def('addStreamEventListener', noop);
    def('removeStreamEventListener', noop);
    def('play', function (speed) {
      if (!isAv(this)) return false;
      var s = av(this), v = avVideo(this);
      speed = speed === undefined ? 1 : Number(speed);
      s.speed = speed;
      placeVideo(this, v);
      if (speed === 0) { try { v.pause(); } catch (e) {} avState(this, 2); return true; }
      var src = this.data;
      if (src && s.src !== src) { s.src = src; v.src = src; avState(this, 3); }
      try { v.playbackRate = speed > 0 ? speed : 1; } catch (e) {}
      try {
        var p = v.play();
        var el = this;
        if (p && p.catch) p.catch(function () { s.error = 0; avState(el, 6); });
      } catch (e) {}
      return true;
    });
    def('stop', function () {
      if (isBc(this)) { setLive(false); bcState(this, 3); return; }
      if (!isAv(this)) return;
      var s = av(this);
      if (s.video) {
        try { s.video.pause(); s.video.removeAttribute('src'); s.video.load(); } catch (e) {}
        s.video.style.display = 'none';
      }
      s.src = ''; s.speed = 0;
      avState(this, 0);
      post('media', false);
      return true;
    });
    def('seek', function (ms) { var s = av(this); if (!s.video) return false; try { s.video.currentTime = ms / 1000; } catch (e) { return false; } return true; });
    prop('playState', function () { return isAv(this) ? av(this).state : bc(this).state; });
    prop('playPosition', function () { var s = av(this); return s.video ? Math.floor(s.video.currentTime * 1000) : 0; });
    prop('playTime', function () { var s = av(this); return s.video && isFinite(s.video.duration) ? Math.floor(s.video.duration * 1000) : 0; });
    prop('speed', function () { return av(this).speed; });
    prop('error', function () { return av(this).error; });
    prop('fullScreen', function () { return bc(this).fullScreen; });
    prop('currentChannel', function () { return isBc(this) && bc(this).state !== 0 ? channel() : null; });
    prop('programmes', function () { return []; });
    prop('configuration', function () { return configuration.configuration; });
    prop('localSystem', function () { return configuration.localSystem; });
    prop('xmlCapabilities', function () { return capabilities.xmlCapabilities; });
    prop('extraSDVideoDecodes', function () { return 0; });
    prop('extraHDVideoDecodes', function () { return 0; });
    def('hasCapability', capabilities.hasCapability);
    def('sendDRMMessage', drmAgent.sendDRMMessage);
    def('DRMSystemStatus', drmAgent.DRMSystemStatus);
    prop('parentalRatingSchemes', function () { return []; });
    prop('isPINEntryLocked', function () { return false; });
    // A/V objects: "data" is the media for play() - not loaded by the
    // browser itself (it would play it on its own).
    try {
      var nativeData = Object.getOwnPropertyDescriptor(P, 'data');
      Object.defineProperty(P, 'data', {
        configurable: true,
        get: function () { return isAv(this) ? (this.__hbbData || '') : nativeData.get.call(this); },
        set: function (v) {
          if (isAv(this)) { try { this.__hbbData = new URL(String(v), location.href).href; } catch (e) { this.__hbbData = String(v); } }
          else nativeData.set.call(this, v);
        }
      });
    } catch (e) {}
  }

  window.oipfObjectFactory = {
    isObjectSupported: function (t) {
      return /^(video\/broadcast|application\/oipf(ApplicationManager|Configuration|Capabilities|DrmAgent|ParentalControlManager))$/i.test(t) || AV.test(t);
    },
    createVideoBroadcastObject: function () { var o = document.createElement('object'); o.setAttribute('type', 'video/broadcast'); return o; },
    createVideoMpegObject: function () { var o = document.createElement('object'); o.setAttribute('type', 'video/mp4'); return o; },
    createApplicationManagerObject: function () { return appManager; },
    createConfigurationObject: function () { return configuration; },
    createCapabilitiesObject: function () { return capabilities; },
    createDrmAgentObject: function () { return drmAgent; },
    createParentalControlManagerObject: function () { return parental; }
  };

  // HTML5 video of the app (HbbTV 2): the live sound has to stop.
  document.addEventListener('playing', function (e) {
    var t = e.target;
    if (t && t.tagName === 'VIDEO' && !t.__hbbOwn && !t.muted) post('media', true);
  }, true);

  // The OIPF objects draw nothing themselves (the live picture is under the
  // page) - and the browser mustn't show "plugin not supported" in them.
  try {
    var css = document.createElement('style');
    css.textContent = 'object[type="video/broadcast" i],object[type^="application/oipf" i],object[type^="application/hbbtv" i],' +
      'object[type^="video/mp4" i],object[type^="video/mpeg" i],object[type^="audio/" i],object[type^="application/dash+xml" i],' +
      'object[type*="mpegurl" i]{visibility:hidden !important}';
    (document.head || document.documentElement).appendChild(css);
  } catch (e) {}

  // ---- 1280×720 onto the screen -----------------------------------------
  function fit() {
    try {
      var w = window.innerWidth, h = window.innerHeight;
      if (!w || !h) return;
      var root = document.documentElement;
      root.style.zoom = String(Math.min(w / 1280, h / 720));
      root.style.overflow = 'hidden';
    } catch (e) {}
  }
  window.addEventListener('resize', fit);
  document.addEventListener('DOMContentLoaded', fit);
  fit();

  window.addEventListener('error', function (e) { post('log', 'JS: ' + (e && e.message)); });

  // ---- The first red (the autostart app opens its portal) ---------------
  if (cfg.autoRed) {
    window.addEventListener('load', function () {
      var waited = 0;
      var t = setInterval(function () {
        waited += 250;
        if (listensToKeys() || waited >= 8000) {
          clearInterval(t);
          setTimeout(function () { H.key('red'); post('autoRed'); }, 900);
        }
      }, 250);
    });
  }
})();
""";
