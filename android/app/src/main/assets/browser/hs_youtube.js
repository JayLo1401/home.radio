// Home System browser - YouTube helper (our own, small; easy to change).
//
// The real work against YouTube's ads is done by the filter lists'
// scriptlets (hs_scriptlets.js, uBlock Origin's YouTube rules). This adds:
// - a fallback when no list scriptlets came (lists not downloaded yet):
//   the ad fields of the player data are removed,
// - an ad skipper for ads that still get through (ads put into the video
//   stream by the server): muted, jumped to their end, "Skip" pressed,
// - hiding YouTube's ad slots.
// Called from hs_page.js on youtube.com / youtube-nocookie.com with the
// blocker on.
function hsYoutube(page) {
  'use strict';
  var AD_FIELDS = 'playerResponse.adPlacements playerResponse.playerAds playerResponse.adSlots adPlacements playerAds adSlots';

  if (!page.cfg.js || !page.cfg.js.length) {
    hsRunScriptlet('set-constant', ['ytInitialPlayerResponse.adPlacements', 'undefined']);
    hsRunScriptlet('set-constant', ['ytInitialPlayerResponse.playerAds', 'undefined']);
    hsRunScriptlet('set-constant', ['ytInitialPlayerResponse.adSlots', 'undefined']);
    hsRunScriptlet('json-prune', [AD_FIELDS]);
    hsRunScriptlet('json-prune-fetch-response', [AD_FIELDS, '', 'propsToMatch', '/\\/youtubei\\/v1\\/(player|next)/']);
    hsRunScriptlet('json-prune-xhr-response', [AD_FIELDS, '', 'propsToMatch', '/\\/youtubei\\/v1\\/(player|next)/']);
  }

  try {
    var css = new CSSStyleSheet();
    css.replaceSync([
      'ytd-ad-slot-renderer', 'ytd-in-feed-ad-layout-renderer', 'ytd-promoted-sparkles-web-renderer',
      'ytd-banner-promo-renderer', 'ytd-statement-banner-renderer', '#player-ads', '#masthead-ad',
      '.ytp-ad-overlay-container', '.ytp-ad-image-overlay', 'ytm-promoted-sparkles-web-renderer',
      'ytm-companion-ad-renderer', 'ytm-ad-slot-renderer', 'ytm-promoted-video-renderer',
      'ad-slot-renderer', 'ytd-player-legacy-desktop-watch-ads-renderer',
    ].join(',') + '{display:none!important}');
    document.adoptedStyleSheets = document.adoptedStyleSheets.concat([css]);
  } catch (e) {}

  var SKIP = '.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, ' +
    '.ytp-ad-skip-button-slot button, .ytp-ad-skip-button-container button, ytm-skip-ad-button button';
  var savedMuted = null;
  function tick() {
    var player = document.querySelector('.html5-video-player');
    if (!player) return;
    var v = player.querySelector('video');
    var ad = player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting');
    if (ad && v) {
      if (savedMuted === null) savedMuted = v.muted;
      v.muted = true;
      if (isFinite(v.duration) && v.duration > 0 && v.currentTime < v.duration - 0.3) {
        try {
          v.currentTime = v.duration - 0.1;
        } catch (e) {}
      }
      var skip = player.querySelector(SKIP) || document.querySelector(SKIP);
      if (skip) skip.click();
    } else if (savedMuted !== null) {
      if (v) v.muted = savedMuted;
      savedMuted = null;
    }
  }
  setInterval(tick, 300);
}
