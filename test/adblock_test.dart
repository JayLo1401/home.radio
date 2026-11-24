import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/services/adblock_compiler.dart';
import 'package:home_system/data/services/adblock_matcher.dart';

AdblockMatcher _compile(String list, {bool trusted = false}) {
  final data = AdblockCompiler.compile([FilterListSource(list, trusted: trusted)]);
  // Always through the file format, as the device gets it.
  return AdblockMatcher(AdblockData.parse(data.serialize()));
}

AdblockStats _stats(String list) => AdblockCompiler.compile([FilterListSource(list)]).stats;

void main() {
  group('hosts', () {
    test('parent domains, hosts files, bare hostnames', () {
      final m = _compile('''
! comment
||ads.example.com^
0.0.0.0 tracker.example.net
127.0.0.1 localhost
plain.example.org
''');
      expect(m.shouldBlock('https://ads.example.com/x.js', 'news.at', AdType.script), isTrue);
      expect(m.shouldBlock('https://a.b.ads.example.com/x.js', 'news.at', AdType.script), isTrue);
      expect(m.shouldBlock('https://example.com/x.js', 'news.at', AdType.script), isFalse);
      expect(m.shouldBlock('https://notads.example.com/', 'news.at', AdType.image), isFalse);
      expect(m.shouldBlock('http://tracker.example.net/p', 'news.at', AdType.image), isTrue);
      expect(m.shouldBlock('https://plain.example.org/', 'news.at', AdType.xhr), isTrue);
      expect(m.data.blockHosts.contains('localhost'), isFalse);
    });

    test('a page on a blocked host still loads its own files', () {
      final m = _compile('||ads.example.com^');
      expect(m.shouldBlock('https://ads.example.com/app.js', 'ads.example.com', AdType.script), isFalse);
    });

    test('exceptions and important', () {
      final m = _compile('''
||cdn.example.com^
@@||cdn.example.com/player/
||track.example.com^\$important
@@||track.example.com^
''');
      expect(m.shouldBlock('https://cdn.example.com/ad.js', 'site.at', AdType.script), isTrue);
      expect(m.shouldBlock('https://cdn.example.com/player/p.js', 'site.at', AdType.script), isFalse);
      expect(m.shouldBlock('https://track.example.com/t', 'site.at', AdType.image), isTrue);
    });
  });

  group('patterns', () {
    test('wildcards, separators, anchors', () {
      expect(patternMatches('/ads/*.gif', 'https://x.at/ads/banner.gif', 8, 12), isTrue);
      expect(patternMatches('/ads/*.gif', 'https://x.at/ads/banner.png', 8, 12), isFalse);
      expect(patternMatches('||x.at^', 'https://x.at/', 8, 12), isTrue);
      expect(patternMatches('||x.at^', 'https://x.at', 8, 12), isTrue);
      expect(patternMatches('||x.at^', 'https://x.atom.com/', 8, 18), isFalse);
      expect(patternMatches('||ads.x.at^', 'https://www.ads.x.at/', 8, 20), isTrue);
      expect(patternMatches('||s.x.at^', 'https://ads.x.at/', 8, 16), isFalse);
      expect(patternMatches('|https://x.at/a.js|', 'https://x.at/a.js', 8, 12), isTrue);
      expect(patternMatches('|https://x.at/a.js|', 'https://x.at/a.js?v=1', 8, 12), isFalse);
      expect(patternMatches('&ad_type=', 'https://x.at/q?a=1&ad_type=2', 8, 12), isTrue);
      expect(patternMatches('-banner-ad.', 'https://x.at/img/top-banner-ad.png', 8, 12), isTrue);
    });

    test('tokens are whole words', () {
      expect(AdblockCompiler.bestToken('/adsbygoogle.js'), 'adsbygoogle');
      expect(AdblockCompiler.bestToken('||doubleclick.net/pagead/'), 'doubleclick');
      // "banner*": the word may go on - not a token.
      expect(AdblockCompiler.bestToken('/banner*'), '');
      expect(urlTokens('https://a.b/c-d?e=1').toList(), ['https', 'a', 'b', 'c', 'd', 'e', '1']);
    });

    test('options: party, types, domains', () {
      final m = _compile(r'''
||cdn.ads.net^$third-party
/pixel.gif$image
/track.js$script,domain=news.at|~sport.news.at
||widgets.example^$~script
||google.*/ads/$1p
''');
      expect(m.shouldBlock('https://cdn.ads.net/a', 'news.at', AdType.script), isTrue);
      expect(m.shouldBlock('https://cdn.ads.net/a', 'www.ads.net', AdType.script), isFalse);
      expect(m.shouldBlock('https://x.at/pixel.gif', 'news.at', AdType.image), isTrue);
      expect(m.shouldBlock('https://x.at/pixel.gif', 'news.at', AdType.script), isFalse);
      expect(m.shouldBlock('https://x.at/track.js', 'www.news.at', AdType.script), isTrue);
      expect(m.shouldBlock('https://x.at/track.js', 'sport.news.at', AdType.script), isFalse);
      expect(m.shouldBlock('https://x.at/track.js', 'other.at', AdType.script), isFalse);
      expect(m.shouldBlock('https://widgets.example/w.png', 'a.at', AdType.image), isTrue);
      expect(m.shouldBlock('https://widgets.example/w.js', 'a.at', AdType.script), isFalse);
    });

    test('unsupported rules are skipped, badfilter removes', () {
      const list = r'''
/^https?:\/\/ads\./
||popup.example^$popup
||x.example^$csp=script-src 'none'
||ima.example^$redirect=google-ima.js
||noop.example^$script,redirect=noopjs
||bad.example^
||bad.example^$badfilter
''';
      final m = _compile(list);
      expect(_stats(list).unsupported, 4);
      expect(m.shouldBlock('https://popup.example/', 'a.at', AdType.script), isFalse);
      expect(m.shouldBlock('https://noop.example/a.js', 'a.at', AdType.script), isTrue);
      expect(m.shouldBlock('https://bad.example/a.js', 'a.at', AdType.script), isFalse);
    });

    test('page exceptions', () {
      final m = _compile(r'''
||ads.net^
@@||trusted.at^$document
@@||nohide.at^$generichide
##.ad
nohide.at##.special
''');
      expect(m.shouldBlock('https://ads.net/a.js', 'www.trusted.at', AdType.script), isFalse);
      expect(m.shouldBlock('https://ads.net/a.js', 'other.at', AdType.script), isTrue);
      expect(m.cosmetic('nohide.at').generic, isFalse);
      expect(m.cosmetic('nohide.at').selectors, ['.special']);
      expect(m.cosmetic('trusted.at').selectors, isEmpty);
    });
  });

  group('cosmetic', () {
    test('generic keyed by class/id, high generic, specific, exceptions', () {
      const list = r'''
##.ad-banner
###top-ad
##.sidebar > .promo
##a[href^="https://ads."]
##div:has-text(Werbung)
example.com##.paywall-ad
example.com#@#.ad-banner
~fine.at##.sponsor
google.*##.g-ad
''';
      final m = _compile(list);
      expect(m.data.genericKeyed.keys, containsAll(['.ad-banner', '#top-ad', '.sidebar', '.sponsor']));
      expect(m.data.genericHigh, ['a[href^="https://ads."]']);
      expect(_stats(list).unsupported, 1);
      expect(m.cosmetic('www.example.com').selectors, containsAll(['.paywall-ad', 'a[href^="https://ads."]']));
      expect(m.genericFor('www.example.com', ['.ad-banner', '#top-ad']), ['#top-ad']);
      expect(m.genericFor('news.at', ['.ad-banner']), ['.ad-banner']);
      expect(m.genericFor('fine.at', ['.sponsor']), isEmpty);
      expect(m.cosmetic('www.google.co.uk').selectors, contains('.g-ad'));
      expect(m.cosmetic('www.google.de').selectors, contains('.g-ad'));
      expect(m.cosmetic('google.example.com').selectors, isNot(contains('.g-ad')));
    });

    test('generic exceptions drop the selector everywhere', () {
      final m = _compile('##.ad\n#@#.ad\n');
      expect(m.genericFor('a.at', ['.ad']), isEmpty);
    });
  });

  group('scriptlets', () {
    test('arguments', () {
      expect(AdblockCompiler.parseScriptletArgs('set, a.b, undefined'), ['set', 'a.b', 'undefined']);
      expect(AdblockCompiler.parseScriptletArgs(r'rpnt, script, a\, b, c'), ['rpnt', 'script', 'a, b', 'c']);
      expect(AdblockCompiler.parseScriptletArgs(r'''trusted-rpfr, '"adSlots"', '"no_ads"', player?'''),
          ['trusted-rpfr', '"adSlots"', '"no_ads"', 'player?']);
      expect(AdblockCompiler.parseScriptletArgs("x, 'a, b', c"), ['x', 'a, b', 'c']);
      expect(AdblockCompiler.parseScriptletArgs('nowoif'), ['nowoif']);
      expect(AdblockCompiler.parseScriptletArgs('json-prune-fetch-response, a, , propsToMatch, /x/'),
          ['json-prune-fetch-response', 'a', '', 'propsToMatch', '/x/']);
    });

    test('per site, aliases, exceptions, trusted', () {
      final m = _compile(r'''
youtube.com##+js(set, ytInitialPlayerResponse.adPlacements, undefined)
www.youtube.com##+js(trusted-rpfr, '"adSlots"', '"no_ads"', player?)
example.*##+js(aopr, adsbygoogle)
example.*##+js(nostif, ads)
example.org#@#+js(nostif, ads)
quiet.example.net#@#+js()
##+js(unknown-scriptlet)
''');
      final yt = m.scriptletsFor('www.youtube.com').map((s) => jsonDecode(s) as List).toList();
      expect(yt.first, ['set-constant', 'ytInitialPlayerResponse.adPlacements', 'undefined']);
      // trusted-* not from an untrusted list.
      expect(yt.length, 1);
      expect(m.scriptletsFor('example.com').length, 2);
      expect(m.scriptletsFor('example.org').map((s) => jsonDecode(s)[0]), ['abort-on-property-read']);
      expect(m.scriptletsFor('quiet.example.net'), isEmpty);
      final trusted = _compile(r'''www.youtube.com##+js(trusted-rpfr, '"adSlots"', '"no_ads"', player?)''', trusted: true);
      expect(jsonDecode(trusted.scriptletsFor('www.youtube.com').single),
          ['trusted-replace-fetch-response', '"adSlots"', '"no_ads"', 'player?']);
    });
  });

  group('preprocessor', () {
    test('!#if / !#else', () {
      final m = _compile('''
!#if env_firefox
||firefox-only.example^
!#else
||not-firefox.example^
!#endif
!#if env_chromium && !env_safari
||chromium.example^
!#endif
!#if (ext_ublock || adguard)
||ublock.example^
!#endif
''');
      expect(m.data.blockHosts, {'not-firefox.example', 'chromium.example', 'ublock.example'});
    });
  });

  test('registrable domains and entities', () {
    expect(registrableDomain('www.orf.at'), 'orf.at');
    expect(registrableDomain('www.help.gv.at'), 'help.gv.at');
    expect(registrableDomain('news.bbc.co.uk'), 'bbc.co.uk');
    expect(registrableDomain('192.168.1.1'), '192.168.1.1');
    expect(entityKeys('www.google.co.uk'), containsAll(['google.*', 'www.google.*']));
    expect(adblockHostOf('https://user@Example.COM:8080/x'), 'example.com');
  });
}
