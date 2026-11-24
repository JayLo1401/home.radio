// The browser's ad/tracker blocker, part 1: reads filter lists in the
// Adblock Plus / uBlock Origin syntax (EasyList, EasyPrivacy, uBlock's own
// lists, hosts files) and compiles what we support into a compact text file
// that the Android side (AdblockEngine.kt) loads and matches against.
//
// Supported (see [AdblockCompiler] for the details):
// - network rules: `||host^` (into a hash set), hosts-file lines, bare
//   hostnames, URL patterns with `*`, `^`, `|`, `||` (indexed by a token as
//   uBlock does), `@@` exceptions, `$important`, `$third-party`/`$1p`,
//   `$domain=`/`$from=` (incl. `~` and `name.*`), resource types,
//   `$badfilter`, `$redirect=` to neutral resources (empty JS/text/HTML,
//   1x1 GIF, silent media), page exceptions `$document`, `$elemhide`,
//   `$generichide`, `$specifichide`.
// - cosmetic rules: `##sel` (generic, keyed by class/id when possible),
//   `domain##sel`, `~domain`, `#@#` exceptions; procedural ones are skipped.
// - scriptlets: `domain##+js(name, args)` for the scriptlets
//   assets/browser/hs_scriptlets.js implements, `#@#+js(...)` exceptions.
//   `trusted-*` ones only from trusted lists (uBlock's own).
// Not supported: regex rules `/.../`, `$csp`, `$removeparam`, `$popup`,
// `$header`, `$method`, `$denyallow`, `$redirect=` to shims, HTML filters
// `##^`, procedural cosmetics (`:has-text`, `:upward`, `:remove`, ...).
import 'dart:convert';

/// The resource types of network rules - one bit each; Kotlin's
/// AdblockEngine uses the same bits.
abstract final class AdType {
  static const script = 1;
  static const image = 2;
  static const stylesheet = 4;
  static const xhr = 8;
  static const subdocument = 16;
  static const media = 32;
  static const font = 64;
  static const other = 128;
  static const all = 255;
}

/// What a network rule does.
enum NetKind {
  block('b'),
  allow('a'),
  important('i');

  const NetKind(this.code);
  final String code;

  static NetKind parse(String code) => values.firstWhere((k) => k.code == code);
}

/// One network rule that is not a plain host: a URL pattern with options.
class NetRule {
  NetRule({
    required this.kind,
    required this.pattern,
    required this.token,
    this.types = AdType.all,
    this.party = 0,
    this.domains = const [],
  });

  final NetKind kind;

  /// Lower case; `||` (host anchor) or `|` (start) in front, `|` (end) at
  /// the end, `*` any characters, `^` a separator or the end.
  final String pattern;

  /// A word of [pattern] every matching URL contains as a whole word ('' =
  /// none, checked for every URL).
  final String token;

  /// [AdType] bits the rule applies to.
  final int types;

  /// 0 any, 1 first-party only, 3 third-party only.
  final int party;

  /// The pages it applies to (`$domain=`): hosts or `name.*`, `~` = not.
  final List<String> domains;

  String serialize() => [kind.code, token, pattern, '$types', '$party', domains.join(',')].join('\t');

  static NetRule parse(String line) {
    final f = line.split('\t');
    return NetRule(
      kind: NetKind.parse(f[0]),
      token: f[1],
      pattern: f[2],
      types: int.parse(f[3]),
      party: int.parse(f[4]),
      domains: f.length > 5 && f[5].isNotEmpty ? f[5].split(',') : const [],
    );
  }
}

/// How much of a list we use - shown in the browser's settings.
class AdblockStats {
  int networkHosts = 0;
  int networkPatterns = 0;
  int cosmetic = 0;
  int scriptlets = 0;
  int unsupported = 0;

  int get used => networkHosts + networkPatterns + cosmetic + scriptlets;

  Map<String, int> toJson() => {
        'hosts': networkHosts,
        'patterns': networkPatterns,
        'cosmetic': cosmetic,
        'scriptlets': scriptlets,
        'unsupported': unsupported,
      };
}

/// Page-level exceptions (`@@||host^$document` etc.): letters in
/// [AdblockData.pageFlags].
abstract final class PageFlag {
  /// Nothing filtered on the page.
  static const document = 'd';

  /// No cosmetic filtering (and no scriptlets).
  static const elemhide = 'e';

  /// No generic cosmetic filtering.
  static const generichide = 'g';

  /// No site-specific cosmetic filtering.
  static const specifichide = 's';
}

/// Everything compiled - what AdblockEngine.kt loads. Also read back in
/// Dart ([parse]) for the tests and the reference matcher.
class AdblockData {
  final blockHosts = <String>{};
  final allowHosts = <String>{};
  final netRules = <NetRule>[];
  final pageFlags = <String, String>{};

  /// Generic selectors by their first class/id ('.ad', '#banner') - only
  /// injected once the page has such an element.
  final genericKeyed = <String, List<String>>{};

  /// Generic selectors without a class/id to key them by - always injected.
  final genericHigh = <String>[];

  /// Site-specific selectors by host (or `name.*`).
  final specificCss = <String, List<String>>{};

  /// Selectors not to hide on a host (`host#@#sel`, `~host##sel`).
  final cssExceptions = <String, Set<String>>{};

  /// Scriptlets by host (or `name.*`, or '*' for all pages): each a JSON
  /// array `["name", "arg", ...]`.
  final scriptlets = <String, List<String>>{};

  /// Scriptlets not to run on a host - the JSON array, or '' for all.
  final scriptletExceptions = <String, Set<String>>{};

  final stats = AdblockStats();

  static const header = 'HSAB 2';

  String serialize() {
    final out = StringBuffer('$header\n');
    void section(String name, Iterable<String> lines) {
      final list = lines.toList();
      out.writeln('@$name ${list.length}');
      for (final l in list) {
        out.writeln(l);
      }
    }

    section('hosts', blockHosts);
    section('allowhosts', allowHosts);
    section('net', netRules.map((r) => r.serialize()));
    section('pageflags', pageFlags.entries.map((e) => '${e.key}\t${e.value}'));
    section('generic', [
      for (final e in genericKeyed.entries)
        for (final s in e.value) '${e.key}\t$s',
      for (final s in genericHigh) '\t$s',
    ]);
    // Site-specific selectors and scriptlets are mostly shared by many
    // sites: each text once in a table, the sites name them by index.
    final cssTable = _Table();
    final specific = [for (final e in specificCss.entries) '${e.key}\t${e.value.map(cssTable.indexOf).join(',')}'];
    section('csstable', cssTable.items);
    section('specific', specific);
    section('cssexcept', [
      for (final e in cssExceptions.entries)
        for (final s in e.value) '${e.key}\t$s',
    ]);
    final jsTable = _Table();
    final js = [for (final e in scriptlets.entries) '${e.key}\t${e.value.map(jsTable.indexOf).join(',')}'];
    section('jstable', jsTable.items);
    section('js', js);
    section('jsexcept', [
      for (final e in scriptletExceptions.entries)
        for (final s in e.value) '${e.key}\t$s',
    ]);
    return out.toString();
  }

  static AdblockData parse(String text) {
    final data = AdblockData();
    final lines = const LineSplitter().convert(text);
    if (lines.isEmpty || lines.first != header) throw const FormatException('not a compiled filter file');
    var i = 1;
    var cssTable = const <String>[];
    var jsTable = const <String>[];
    while (i < lines.length) {
      final head = lines[i++];
      if (head.isEmpty) continue;
      final space = head.indexOf(' ');
      final name = head.substring(1, space);
      final count = int.parse(head.substring(space + 1));
      if (name == 'csstable' || name == 'jstable') {
        final table = lines.sublist(i, i + count);
        i += count;
        if (name == 'csstable') {
          cssTable = table;
        } else {
          jsTable = table;
        }
        continue;
      }
      for (var n = 0; n < count; n++) {
        final line = lines[i++];
        final tab = line.indexOf('\t');
        final key = tab < 0 ? line : line.substring(0, tab);
        final value = tab < 0 ? '' : line.substring(tab + 1);
        switch (name) {
          case 'hosts':
            data.blockHosts.add(line);
          case 'allowhosts':
            data.allowHosts.add(line);
          case 'net':
            data.netRules.add(NetRule.parse(line));
          case 'pageflags':
            data.pageFlags[key] = value;
          case 'generic':
            key.isEmpty ? data.genericHigh.add(value) : (data.genericKeyed[key] ??= []).add(value);
          case 'specific':
            data.specificCss[key] = [for (final n in value.split(',')) cssTable[int.parse(n)]];
          case 'cssexcept':
            (data.cssExceptions[key] ??= {}).add(value);
          case 'js':
            data.scriptlets[key] = [for (final n in value.split(',')) jsTable[int.parse(n)]];
          case 'jsexcept':
            (data.scriptletExceptions[key] ??= {}).add(value);
        }
      }
    }
    return data;
  }
}

/// Texts numbered in the order they come.
class _Table {
  final items = <String>[];
  final _index = <String, int>{};

  int indexOf(String text) => _index.putIfAbsent(text, () {
        items.add(text);
        return items.length - 1;
      });
}

/// One filter list's text, and whether its `trusted-*` scriptlets may run
/// (only uBlock Origin's own lists).
class FilterListSource {
  const FilterListSource(this.text, {this.trusted = false});

  final String text;
  final bool trusted;
}

/// The scriptlets assets/browser/hs_scriptlets.js implements, by their
/// canonical name, and the names (aliases) lists use for them.
const scriptletAliases = <String, String>{
  'set': 'set-constant',
  'set-constant': 'set-constant',
  'trusted-set': 'trusted-set-constant',
  'trusted-set-constant': 'trusted-set-constant',
  'aopr': 'abort-on-property-read',
  'abort-on-property-read': 'abort-on-property-read',
  'aopw': 'abort-on-property-write',
  'abort-on-property-write': 'abort-on-property-write',
  'acs': 'abort-current-script',
  'acis': 'abort-current-script',
  'abort-current-script': 'abort-current-script',
  'abort-current-inline-script': 'abort-current-script',
  'aost': 'abort-on-stack-trace',
  'abort-on-stack-trace': 'abort-on-stack-trace',
  'nowoif': 'no-window-open-if',
  'no-window-open-if': 'no-window-open-if',
  'window.open-defuser': 'no-window-open-if',
  'rmnt': 'remove-node-text',
  'remove-node-text': 'remove-node-text',
  'rpnt': 'replace-node-text',
  'replace-node-text': 'replace-node-text',
  'trusted-rpnt': 'trusted-replace-node-text',
  'trusted-replace-node-text': 'trusted-replace-node-text',
  'nostif': 'no-setTimeout-if',
  'no-setTimeout-if': 'no-setTimeout-if',
  'setTimeout-defuser': 'no-setTimeout-if',
  'nosiif': 'no-setInterval-if',
  'no-setInterval-if': 'no-setInterval-if',
  'setInterval-defuser': 'no-setInterval-if',
  'aeld': 'addEventListener-defuser',
  'addEventListener-defuser': 'addEventListener-defuser',
  'prevent-addEventListener': 'addEventListener-defuser',
  'no-fetch-if': 'no-fetch-if',
  'prevent-fetch': 'no-fetch-if',
  'trusted-prevent-fetch': 'no-fetch-if',
  'no-xhr-if': 'no-xhr-if',
  'prevent-xhr': 'no-xhr-if',
  'trusted-prevent-xhr': 'no-xhr-if',
  'nano-sib': 'nano-setInterval-booster',
  'nano-setInterval-booster': 'nano-setInterval-booster',
  'nano-stb': 'nano-setTimeout-booster',
  'nano-setTimeout-booster': 'nano-setTimeout-booster',
  'noeval-if': 'noeval-if',
  'prevent-eval-if': 'noeval-if',
  'noeval': 'noeval',
  'silent-noeval': 'noeval',
  'json-prune': 'json-prune',
  'json-prune-fetch-response': 'json-prune-fetch-response',
  'json-prune-xhr-response': 'json-prune-xhr-response',
  'ra': 'remove-attr',
  'remove-attr': 'remove-attr',
  'rc': 'remove-class',
  'remove-class': 'remove-class',
  'trusted-rpfr': 'trusted-replace-fetch-response',
  'trusted-replace-fetch-response': 'trusted-replace-fetch-response',
  'trusted-replace-xhr-response': 'trusted-replace-xhr-response',
  'trusted-prevent-dom-bypass': 'trusted-prevent-dom-bypass',
  'trusted-edit-inbound-object': 'trusted-edit-inbound-object',
  'json-edit': 'json-edit',
  'trusted-json-edit': 'trusted-json-edit',
  'json-edit-fetch-response': 'json-edit-fetch-response',
  'trusted-json-edit-fetch-response': 'trusted-json-edit-fetch-response',
  'json-edit-xhr-response': 'json-edit-xhr-response',
  'trusted-json-edit-xhr-response': 'trusted-json-edit-xhr-response',
  'set-local-storage-item': 'set-local-storage-item',
  'set-session-storage-item': 'set-session-storage-item',
  'trusted-set-local-storage-item': 'trusted-set-local-storage-item',
  'remove-cookie': 'remove-cookie',
  'cookie-remover': 'remove-cookie',
  'nowebrtc': 'nowebrtc',
  'norafif': 'no-requestAnimationFrame-if',
  'no-requestAnimationFrame-if': 'no-requestAnimationFrame-if',
  'trusted-replace-argument': 'trusted-replace-argument',
  'trusted-replace-outbound-text': 'trusted-replace-outbound-text',
  'set-attr': 'set-attr',
  'trusted-set-attr': 'trusted-set-attr',
  'trusted-click-element': 'trusted-click-element',
  'href-sanitizer': 'href-sanitizer',
  'refresh-defuser': 'refresh-defuser',
  'prevent-innerHTML': 'prevent-innerHTML',
};

/// The canonical scriptlet name for [name] (with or without `.js`), or null
/// when we don't have it.
String? canonicalScriptlet(String name) {
  var n = name.trim();
  if (n.endsWith('.js')) n = n.substring(0, n.length - 3);
  return scriptletAliases[n];
}

/// Neutral resources `$redirect=` may point to - blocking gives the same
/// (an empty answer, a transparent GIF for images). Redirects to shims
/// (google-ima.js, ...) we don't have, so those rules are skipped.
const _neutralRedirects = {
  'noopjs', 'noop.js', 'nooptext', 'noop.txt', 'noop.html', 'noopframe', 'noop.json', 'noop.css', 'noopcss',
  '1x1.gif', '1x1-transparent.gif', '2x2.png', '2x2-transparent.png', '3x2.png', '3x2-transparent.png',
  '32x32.png', '32x32-transparent.png', 'noopmp3-0.1s', 'noop-0.1s.mp3', 'noop-0.5s.mp3', 'noopmp4-1s',
  'noop-1s.mp4', 'empty', 'none', 'noop-vast2.xml', 'noop-vast3.xml', 'noop-vast4.xml', 'noop-vmap1.xml',
  'noopvast-2.0', 'noopvast-3.0', 'noopvast-4.0', 'noopvmap-1.0',
};

/// uBlock's procedural / action pseudo classes - plain CSS can't do them.
const _proceduralMarkers = [
  ':has-text(', ':-abp-', ':upward(', ':xpath(', ':matches-css', ':min-text-length(', ':watch-attr(',
  ':remove(', ':style(', ':others(', ':matches-path(', ':matches-attr(', ':matches-prop(', ':matches-media(',
  ':if(', ':if-not(', ':nth-ancestor(', ':spath(', ':contains(', ':remove-attr(', ':remove-class(', ':-ext-',
];

/// Words too common to index a URL pattern by (every URL has them).
const _badTokens = {
  'http', 'https', 'www', 'com', 'net', 'org', 'js', 'html', 'php', 'jpg', 'png', 'gif', 'css', 'de', 'at',
};

final _hostRe = RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9_-]*[a-z0-9])?)+$');
final _simpleKeyRe = RegExp(r'^([.#])([A-Za-z_][\w-]*)$');
final _leadingKeyRe = RegExp(r'^([.#])([A-Za-z_][\w-]*)(?=$|[\s>+~:.\[#])');

/// Compiles filter lists into [AdblockData].
class AdblockCompiler {
  AdblockCompiler({Map<String, bool>? env}) : _env = env ?? defaultEnv;

  /// `!#if` conditions as uBlock Origin on Chromium sees them.
  static const defaultEnv = {
    'env_chromium': true,
    'ext_ublock': true,
    'cap_html_filtering': false,
    'cap_user_stylesheet': true,
    'env_firefox': false,
    'env_safari': false,
    'env_edge': false,
    'env_mobile': false,
    'env_mv3': false,
    'ext_ubol': false,
    'ext_devbuild': false,
    'adguard': false,
    'cap_ipaddress': false,
    'false': false,
  };

  final Map<String, bool> _env;
  final data = AdblockData();

  final _badfilters = <String>{};
  final _genericExceptions = <String>{};
  final _genericScriptletExceptions = <String>{};
  final _seenNet = <String>{};

  /// Compiles [sources] (in that order) into one [AdblockData].
  static AdblockData compile(List<FilterListSource> sources) {
    final c = AdblockCompiler();
    for (final s in sources) {
      c.addList(s.text, trusted: s.trusted);
    }
    return c.finish();
  }

  void addList(String text, {bool trusted = false}) {
    // !#if nesting: each level is active or not.
    final stack = <bool>[];
    var active = true;
    for (var raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('!#')) {
        if (line.startsWith('!#if ')) {
          stack.add(active);
          active = active && evaluateCondition(line.substring(5));
        } else if (line.startsWith('!#else')) {
          final outer = stack.isEmpty || stack.last;
          // The branch is active when the outer one is and the if wasn't.
          active = outer && !active;
        } else if (line.startsWith('!#endif')) {
          active = stack.isEmpty ? true : stack.removeLast();
        }
        continue;
      }
      if (!active) continue;
      if (line.startsWith('!') || line.startsWith('[')) continue;
      addRule(line, trusted: trusted);
    }
  }

  /// A `!#if` condition: names, `!`, `&&`, `||`, parentheses.
  bool evaluateCondition(String expr) {
    final tokens = RegExp(r'\(|\)|!|&&|\|\||[A-Za-z_][\w-]*').allMatches(expr).map((m) => m[0]!).toList();
    var pos = 0;
    late bool Function() orExpr;
    bool primary() {
      if (pos >= tokens.length) return false;
      final t = tokens[pos++];
      if (t == '!') return !primary();
      if (t == '(') {
        final v = orExpr();
        if (pos < tokens.length && tokens[pos] == ')') pos++;
        return v;
      }
      return _env[t] ?? false;
    }

    bool andExpr() {
      var v = primary();
      while (pos < tokens.length && tokens[pos] == '&&') {
        pos++;
        final r = primary();
        v = v && r;
      }
      return v;
    }

    orExpr = () {
      var v = andExpr();
      while (pos < tokens.length && tokens[pos] == '||') {
        pos++;
        final r = andExpr();
        v = v || r;
      }
      return v;
    };
    return orExpr();
  }

  /// One line of a list (no comment, already trimmed).
  void addRule(String line, {bool trusted = false}) {
    // Hosts file: "0.0.0.0 host" / "127.0.0.1 host".
    if (line.startsWith('0.0.0.0 ') || line.startsWith('127.0.0.1 ') || line.startsWith('::1 ')) {
      _addHostsLine(line);
      return;
    }
    if (line.startsWith('#') && !line.startsWith('##') && !line.startsWith('#@#') && !line.startsWith('#?#')) {
      return; // a hosts file's comment
    }
    final cosmetic = _cosmeticSeparator(line);
    if (cosmetic != null) {
      _addCosmetic(line, cosmetic.$1, cosmetic.$2, trusted);
      return;
    }
    _addNetwork(line);
  }

  void _addHostsLine(String line) {
    final parts = line.split(RegExp(r'\s+'));
    for (final p in parts.skip(1)) {
      if (p.startsWith('#')) break;
      final h = p.toLowerCase();
      if (h == 'localhost' || h == 'localhost.localdomain' || h == 'local' || h == '0.0.0.0' || h == 'broadcasthost') {
        continue;
      }
      if (_hostRe.hasMatch(h)) {
        if (data.blockHosts.add(h)) data.stats.networkHosts++;
      }
    }
  }

  /// Where a cosmetic rule's separator is: (index, separator).
  (int, String)? _cosmeticSeparator(String line) {
    var i = line.indexOf('#');
    while (i >= 0 && i < line.length - 1) {
      final rest = line.substring(i);
      for (final sep in const ['#@#+js(', '##+js(', '#@?#', r'#@$#', '#@%#', '#@#', '#?#', '#\$?#', '#\$#', '#%#', '##']) {
        if (rest.startsWith(sep)) {
          // A network rule may hold '#' in its URL ("...#ad"), a cosmetic
          // one's domain part can't hold '/' or '$'.
          final domains = line.substring(0, i);
          if (domains.contains('/') || domains.contains(r'$') || domains.contains('|')) return null;
          return (i, sep.endsWith('+js(') ? sep.substring(0, sep.length - 4) : sep);
        }
      }
      i = line.indexOf('#', i + 1);
    }
    return null;
  }

  void _addCosmetic(String line, int index, String sep, bool trusted) {
    final domainsText = line.substring(0, index);
    final body = line.substring(index + sep.length);
    final exception = sep.contains('@');
    if (sep != '##' && sep != '#@#') {
      data.stats.unsupported++;
      return;
    }
    final include = <String>[];
    final exclude = <String>[];
    var droppedDomain = false;
    if (domainsText.isNotEmpty) {
      for (var d in domainsText.split(',')) {
        d = d.trim().toLowerCase();
        if (d.isEmpty) continue;
        final negated = d.startsWith('~');
        if (negated) d = d.substring(1);
        // uBlock's "descendant frames" (">>") and regexes: not supported.
        if (d.contains('>>') || d.startsWith('/') || d.contains('/')) {
          droppedDomain = true;
          continue;
        }
        if (d == '*') continue;
        (negated ? exclude : include).add(d);
      }
      if (droppedDomain && include.isEmpty && exclude.isEmpty) {
        data.stats.unsupported++;
        return;
      }
      if (droppedDomain && include.isEmpty) {
        data.stats.unsupported++;
        return;
      }
    }

    if (body.startsWith('+js(')) {
      _addScriptlet(body, include, exclude, exception, trusted);
      return;
    }
    if (body.startsWith('^') || body.startsWith('+')) {
      data.stats.unsupported++;
      return;
    }
    final selector = body.trim();
    if (selector.isEmpty || _proceduralMarkers.any(selector.contains) || selector.contains('{')) {
      data.stats.unsupported++;
      return;
    }
    if (exception) {
      if (include.isEmpty) {
        _genericExceptions.add(selector);
      } else {
        for (final d in include) {
          (data.cssExceptions[d] ??= {}).add(selector);
        }
      }
      return;
    }
    data.stats.cosmetic++;
    for (final d in exclude) {
      (data.cssExceptions[d] ??= {}).add(selector);
    }
    if (include.isEmpty) {
      _addGeneric(selector);
    } else {
      for (final d in include) {
        final list = data.specificCss[d] ??= [];
        if (!list.contains(selector)) list.add(selector);
      }
    }
  }

  void _addGeneric(String selector) {
    final simple = _simpleKeyRe.firstMatch(selector);
    final leading = simple ?? (_hasTopLevelComma(selector) || selector.contains(r'\') ? null : _leadingKeyRe.firstMatch(selector));
    if (leading != null) {
      final key = '${leading[1]}${leading[2]}';
      final list = data.genericKeyed[key] ??= [];
      if (!list.contains(selector)) list.add(selector);
    } else if (!data.genericHigh.contains(selector)) {
      data.genericHigh.add(selector);
    }
  }

  static bool _hasTopLevelComma(String s) {
    var depth = 0;
    String? quote;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (quote != null) {
        if (c == quote) quote = null;
      } else if (c == '"' || c == "'") {
        quote = c;
      } else if (c == '(' || c == '[') {
        depth++;
      } else if (c == ')' || c == ']') {
        depth--;
      } else if (c == ',' && depth == 0) {
        return true;
      }
    }
    return false;
  }

  void _addScriptlet(String body, List<String> include, List<String> exclude, bool exception, bool trusted) {
    if (!body.endsWith(')')) {
      data.stats.unsupported++;
      return;
    }
    final args = parseScriptletArgs(body.substring(4, body.length - 1));
    if (exception && (args.isEmpty || args.first.isEmpty)) {
      // "#@#+js()": no scriptlets at all on these sites.
      for (final d in include) {
        (data.scriptletExceptions[d] ??= {}).add('');
      }
      return;
    }
    if (args.isEmpty) return;
    final name = canonicalScriptlet(args.first);
    if (name == null || (name.startsWith('trusted-') && !trusted)) {
      if (!exception) data.stats.unsupported++;
      return;
    }
    final json = jsonEncode([name, ...args.skip(1)]);
    if (exception) {
      if (include.isEmpty) {
        _genericScriptletExceptions.add(json);
      } else {
        for (final d in include) {
          (data.scriptletExceptions[d] ??= {}).add(json);
        }
      }
      return;
    }
    data.stats.scriptlets++;
    for (final d in exclude) {
      (data.scriptletExceptions[d] ??= {}).add(json);
    }
    for (final d in include.isEmpty ? const ['*'] : include) {
      final list = data.scriptlets[d] ??= [];
      if (!list.contains(json)) list.add(json);
    }
  }

  /// uBlock's scriptlet arguments: separated by commas, `\,` is a comma in
  /// an argument, an argument in quotes ('…', "…", `…`) may hold commas.
  static List<String> parseScriptletArgs(String text) {
    final args = <String>[];
    var i = 0;
    while (i <= text.length) {
      while (i < text.length && text[i] == ' ') {
        i++;
      }
      if (i >= text.length) {
        if (args.isNotEmpty && text.trimRight().endsWith(',')) args.add('');
        break;
      }
      final q = text[i];
      if (q == '"' || q == "'" || q == '`') {
        // Quoted: up to the matching unescaped quote that is followed by a
        // comma (or the end).
        var j = i + 1;
        final buf = StringBuffer();
        var closed = false;
        while (j < text.length) {
          final c = text[j];
          if (c == r'\' && j + 1 < text.length && text[j + 1] == q) {
            buf.write(q);
            j += 2;
            continue;
          }
          if (c == q) {
            var k = j + 1;
            while (k < text.length && text[k] == ' ') {
              k++;
            }
            if (k >= text.length || text[k] == ',') {
              closed = true;
              j = k;
              break;
            }
          }
          buf.write(c);
          j++;
        }
        if (closed) {
          args.add(buf.toString());
          i = j + 1;
          continue;
        }
      }
      final buf = StringBuffer();
      var j = i;
      while (j < text.length) {
        final c = text[j];
        if (c == r'\' && j + 1 < text.length && text[j + 1] == ',') {
          buf.write(',');
          j += 2;
          continue;
        }
        if (c == ',') break;
        buf.write(c);
        j++;
      }
      args.add(buf.toString().trim());
      i = j + 1;
      if (j >= text.length) break;
    }
    return args;
  }

  void _addNetwork(String line) {
    var rule = line;
    var exception = false;
    if (rule.startsWith('@@')) {
      exception = true;
      rule = rule.substring(2);
    }
    // Options after the last '$' (a '$' inside the pattern is rare; uBlock
    // takes the last one as well).
    var pattern = rule;
    var options = <String>[];
    final dollar = rule.lastIndexOf(r'$');
    if (dollar >= 0 && !(rule.startsWith('/') && rule.endsWith('/'))) {
      final opts = rule.substring(dollar + 1);
      // "$" followed by something that doesn't look like options: part of
      // the pattern.
      if (opts.isNotEmpty && RegExp(r'^~?[\w-]+(=|,|$)').hasMatch(opts)) {
        pattern = rule.substring(0, dollar);
        options = _splitOptions(opts);
      }
    }
    if (options.contains('badfilter')) {
      _badfilters.add(_withoutOption(line, 'badfilter'));
      return;
    }
    pattern = pattern.toLowerCase();
    if (pattern.length > 1 && pattern.startsWith('/') && pattern.endsWith('/')) {
      data.stats.unsupported++; // regex
      return;
    }

    var types = 0;
    var negTypes = 0;
    var party = 0;
    var important = false;
    final domains = <String>[];
    String? pageFlags;
    var unsupported = false;
    for (final raw in options) {
      final o = raw.trim();
      final eq = o.indexOf('=');
      final name = (eq < 0 ? o : o.substring(0, eq)).toLowerCase();
      final value = eq < 0 ? '' : o.substring(eq + 1);
      final negated = name.startsWith('~');
      final bare = negated ? name.substring(1) : name;
      final typeBit = _typeBit(bare);
      if (typeBit != null) {
        if (negated) {
          negTypes |= typeBit;
        } else {
          types |= typeBit;
        }
        continue;
      }
      switch (bare) {
        case 'third-party' || '3p' || 'strict3p' || 'strict-third-party':
          party = negated ? 1 : 3;
        case 'first-party' || '1p' || 'strict1p' || 'strict-first-party':
          party = negated ? 3 : 1;
        case 'important':
          important = true;
        case 'all' || 'match-case':
          break;
        case 'domain' || 'from':
          for (var d in value.split('|')) {
            d = d.trim().toLowerCase();
            if (d.isEmpty) continue;
            if (d.startsWith('/') || d.contains('>>')) {
              unsupported = true;
              break;
            }
            domains.add(d);
          }
        case 'document' || 'doc':
          if (exception) {
            pageFlags = '${pageFlags ?? ''}${PageFlag.document}';
          } else {
            unsupported = true; // uBlock's strict blocking of whole pages
          }
        case 'elemhide' || 'ehide':
          if (exception) {
            pageFlags = '${pageFlags ?? ''}${PageFlag.elemhide}';
          } else {
            unsupported = true;
          }
        case 'generichide' || 'ghide':
          if (exception) {
            pageFlags = '${pageFlags ?? ''}${PageFlag.generichide}';
          } else {
            unsupported = true;
          }
        case 'specifichide' || 'shide':
          if (exception) {
            pageFlags = '${pageFlags ?? ''}${PageFlag.specifichide}';
          } else {
            unsupported = true;
          }
        case 'redirect' || 'rewrite':
          var res = value.toLowerCase();
          final colon = res.lastIndexOf(':');
          if (colon > 0 && int.tryParse(res.substring(colon + 1)) != null) res = res.substring(0, colon);
          if (res.startsWith('abp-resource:')) res = res.substring(13);
          if (exception || !_neutralRedirects.contains(res) && res != 'blank-js' && res != 'blank-text') {
            unsupported = true;
          }
        case 'redirect-rule':
          // Only changes what an already blocked request gets - ours are
          // neutral anyway.
          unsupported = true;
        case 'empty' || 'mp4':
          break;
        default:
          unsupported = true;
      }
      if (unsupported) break;
    }
    if (unsupported) {
      data.stats.unsupported++;
      return;
    }

    if (pageFlags != null) {
      // Page exceptions only for whole hosts ("@@||host^$document").
      final host = _plainHost(pattern);
      if (host == null || domains.isNotEmpty) {
        data.stats.unsupported++;
        return;
      }
      final flags = data.pageFlags[host] ?? '';
      data.pageFlags[host] = {...flags.split(''), ...pageFlags.split('')}.join();
      return;
    }

    final typeMask = types != 0 ? types : (negTypes != 0 ? AdType.all & ~negTypes : AdType.all);
    if (typeMask == 0) {
      data.stats.unsupported++;
      return;
    }

    final kind = exception ? NetKind.allow : (important ? NetKind.important : NetKind.block);
    final plain = typeMask == AdType.all && party == 0 && domains.isEmpty && kind != NetKind.important;
    // A bare hostname line is a host rule, as in uBlock.
    final host = _plainHost(pattern) ?? (plain && options.isEmpty && _hostRe.hasMatch(pattern) ? pattern : null);
    if (plain && host != null) {
      if (exception) {
        data.allowHosts.add(host);
      } else if (data.blockHosts.add(host)) {
        data.stats.networkHosts++;
      }
      return;
    }

    final normalized = _normalizePattern(pattern);
    if (normalized == null || (normalized.isEmpty && domains.isEmpty)) {
      data.stats.unsupported++;
      return;
    }
    final key = '${kind.code}|$normalized|$typeMask|$party|${domains.join(',')}';
    if (!_seenNet.add(key)) return;
    data.netRules.add(NetRule(
      kind: kind,
      pattern: normalized,
      token: bestToken(normalized),
      types: typeMask,
      party: party,
      domains: domains,
    ));
    data.stats.networkPatterns++;
  }

  static List<String> _splitOptions(String opts) {
    // Commas inside a value ("domain=a|b" has none, but regex values may
    // have "\,").
    final out = <String>[];
    final buf = StringBuffer();
    for (var i = 0; i < opts.length; i++) {
      final c = opts[i];
      if (c == r'\' && i + 1 < opts.length && opts[i + 1] == ',') {
        buf.write(',');
        i++;
      } else if (c == ',') {
        out.add(buf.toString());
        buf.clear();
      } else {
        buf.write(c);
      }
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }

  static String _withoutOption(String line, String option) {
    final dollar = line.lastIndexOf(r'$');
    if (dollar < 0) return line;
    final opts = _splitOptions(line.substring(dollar + 1)).where((o) => o.trim().toLowerCase() != option).toList();
    return opts.isEmpty ? line.substring(0, dollar) : '${line.substring(0, dollar)}\$${opts.join(',')}';
  }

  static int? _typeBit(String name) => switch (name) {
        'script' => AdType.script,
        'image' || 'img' => AdType.image,
        'stylesheet' || 'css' => AdType.stylesheet,
        'xmlhttprequest' || 'xhr' => AdType.xhr,
        'subdocument' || 'frame' => AdType.subdocument,
        'media' => AdType.media,
        'font' => AdType.font,
        'object' || 'object-subrequest' || 'ping' || 'beacon' || 'websocket' || 'other' || 'webrtc' => AdType.other,
        _ => null,
      };

  /// `||host^` (or `||host^|`, `||host`) for a pure hostname - else null.
  static String? _plainHost(String pattern) {
    if (!pattern.startsWith('||')) return null;
    var h = pattern.substring(2);
    if (h.endsWith('^|')) {
      h = h.substring(0, h.length - 2);
    } else if (h.endsWith('^')) {
      h = h.substring(0, h.length - 1);
    } else {
      return null;
    }
    return _hostRe.hasMatch(h) ? h : null;
  }

  /// The pattern without useless wildcards; null if it can't be used.
  static String? _normalizePattern(String p) {
    var s = p;
    // "||" / "|" anchors stay; '*' at either end is implied.
    var prefix = '';
    if (s.startsWith('||')) {
      prefix = '||';
      s = s.substring(2);
    } else if (s.startsWith('|')) {
      prefix = '|';
      s = s.substring(1);
    }
    var suffix = '';
    if (s.endsWith('|') && !s.endsWith(r'\|')) {
      suffix = '|';
      s = s.substring(0, s.length - 1);
    }
    if (prefix.isEmpty) {
      while (s.startsWith('*')) {
        s = s.substring(1);
      }
    }
    if (suffix.isEmpty) {
      while (s.endsWith('*')) {
        s = s.substring(0, s.length - 1);
      }
    }
    s = s.replaceAll(RegExp(r'\*{2,}'), '*');
    if (s.isEmpty) return prefix.isEmpty && suffix.isEmpty ? '' : null;
    if (s.contains(' ')) return null;
    return '$prefix$s$suffix';
  }

  /// The longest word of [pattern] that any matching URL must contain as a
  /// whole word (a run of a-z, 0-9, %) - '' if there is none.
  static String bestToken(String pattern) {
    var best = '';
    final re = RegExp(r'[a-z0-9%]+');
    var body = pattern;
    var start = 0;
    if (body.startsWith('||')) {
      start = 2;
    } else if (body.startsWith('|')) {
      start = 1;
    }
    var end = body.length;
    if (body.endsWith('|')) end--;
    body = body.substring(0, end);
    for (final m in re.allMatches(body, start)) {
      final t = m[0]!;
      // Bounded on both sides by a non-word character of the pattern (not
      // '*', which might add word characters); the pattern's ends count as
      // bounds only where anchored.
      final before = m.start == start ? (start > 0 ? 'anchor' : null) : body[m.start - 1];
      final after = m.end == body.length ? (end < pattern.length ? 'anchor' : null) : body[m.end];
      if (before == null || before == '*') continue;
      if (after == null || after == '*') continue;
      if (_badTokens.contains(t) || t.length < 2) continue;
      // A host-anchored start: the URL has a '.' or '/' before the word.
      if (t.length > best.length) best = t;
    }
    return best;
  }

  AdblockData finish() {
    if (_badfilters.isNotEmpty) {
      // Recompile-free removal: drop net rules / hosts that a $badfilter
      // names exactly.
      for (final bad in _badfilters) {
        final c = AdblockCompiler(env: _env);
        c.addRule(bad);
        final d = c.data;
        data.blockHosts.removeAll(d.blockHosts);
        data.allowHosts.removeAll(d.allowHosts);
        for (final r in d.netRules) {
          data.netRules.removeWhere((x) =>
              x.kind == r.kind &&
              x.pattern == r.pattern &&
              x.types == r.types &&
              x.party == r.party &&
              x.domains.join(',') == r.domains.join(','));
        }
      }
    }
    if (_genericExceptions.isNotEmpty) {
      data.genericHigh.removeWhere(_genericExceptions.contains);
      for (final list in data.genericKeyed.values) {
        list.removeWhere(_genericExceptions.contains);
      }
      data.genericKeyed.removeWhere((_, v) => v.isEmpty);
    }
    if (_genericScriptletExceptions.isNotEmpty) {
      for (final list in data.scriptlets.values) {
        list.removeWhere(_genericScriptletExceptions.contains);
      }
      data.scriptlets.removeWhere((_, v) => v.isEmpty);
    }
    return data;
  }
}
