import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/data/services/adblock_lists.dart';
import 'package:home_system/features/browser/browser_settings.dart';

void main() {
  test('address field: addresses, hosts, local devices, searches', () {
    const e = SearchEngine.duckDuckGo;
    expect(browserUrlFor('https://orf.at/news', e), 'https://orf.at/news');
    expect(browserUrlFor('orf.at', e), 'https://orf.at');
    expect(browserUrlFor('www.derstandard.at/sport', e), 'https://www.derstandard.at/sport');
    expect(browserUrlFor('192.168.100.5:8123', e), 'http://192.168.100.5:8123');
    expect(browserUrlFor('homeassistant.local:8123/lovelace', e), 'http://homeassistant.local:8123/lovelace');
    expect(browserUrlFor('localhost:1401', e), 'http://localhost:1401');
    expect(browserUrlFor('wetter wien', e), 'https://duckduckgo.com/?q=wetter+wien');
    expect(browserUrlFor('flutter', SearchEngine.google), 'https://www.google.com/search?q=flutter');
    expect(browserUrlFor('  ', e), e.homeUrl);
  });

  test('settings survive storing', () {
    final s = const BrowserSettings().copyWith(
      blocker: false,
      allowlist: {'example.com'},
      lists: {'easylist'},
      searchEngine: SearchEngine.startpage,
      textZoom: 125,
      bookmarks: const [Bookmark(title: 'ORF', url: 'https://orf.at')],
    );
    final back = BrowserSettings.fromJson(s.toJson());
    expect(back.blocker, isFalse);
    expect(back.allowlist, {'example.com'});
    expect(back.enabledLists, {'easylist'});
    expect(back.searchEngine, SearchEngine.startpage);
    expect(back.textZoom, 125);
    expect(back.bookmarks.single.url, 'https://orf.at');
    expect(BrowserSettings.fromJson(null).blocker, isTrue);
  });

  test('default filter lists: EasyList Germany on German devices', () {
    expect(defaultFilterLists('de'), contains('easylist-germany'));
    expect(defaultFilterLists('en'), isNot(contains('easylist-germany')));
    expect(defaultFilterLists('en'), containsAll(['ublock-filters', 'ublock-quick-fixes', 'easylist', 'easyprivacy']));
  });

  test('hosts', () {
    expect(browserHostOf('https://WWW.Example.com:8080/x'), 'www.example.com');
    expect(browserHostOf('about:blank'), '');
  });
}
