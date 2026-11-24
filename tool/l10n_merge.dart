// Merges the per-area text files l10n/<area>_de.arb and l10n/<area>_en.arb
// into lib/l10n/app_de.arb / app_en.arb and runs `flutter gen-l10n`.
//
//   dart run tool/l10n_merge.dart
//
// Each area owns its keys (prefixed with the area, e.g. "scannerTitle"); a
// key in two areas, or one that's missing in English, is an error.
import 'dart:convert';
import 'dart:io';

void main() {
  final dir = Directory('l10n');
  final merged = {'de': <String, dynamic>{'@@locale': 'de'}, 'en': <String, dynamic>{'@@locale': 'en'}};
  final owner = <String, String>{};
  final errors = <String>[];
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.arb')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final name = file.uri.pathSegments.last;
    final match = RegExp(r'^(.+)_(de|en)\.arb$').firstMatch(name);
    if (match == null) {
      errors.add('$name: expected <area>_de.arb or <area>_en.arb');
      continue;
    }
    final area = match.group(1)!;
    final lang = match.group(2)!;
    final Map<String, dynamic> content;
    try {
      content = (jsonDecode(file.readAsStringSync()) as Map).cast<String, dynamic>();
    } on FormatException catch (e) {
      errors.add('$name: $e');
      continue;
    }
    for (final entry in content.entries) {
      if (entry.key.startsWith('@@')) continue;
      final key = entry.key.startsWith('@') ? entry.key.substring(1) : entry.key;
      final other = owner[key];
      if (other != null && other != area) {
        errors.add('$name: "$key" is already used by area "$other"');
        continue;
      }
      owner[key] = area;
      merged[lang]![entry.key] = entry.value;
    }
  }
  for (final key in merged['de']!.keys.where((k) => !k.startsWith('@'))) {
    if (!merged['en']!.containsKey(key)) errors.add('"$key" (${owner[key]}) has no English text');
  }
  for (final key in merged['en']!.keys.where((k) => !k.startsWith('@'))) {
    if (!merged['de']!.containsKey(key)) errors.add('"$key" (${owner[key]}) has no German text');
  }
  if (errors.isNotEmpty) {
    stderr.writeln(errors.join('\n'));
    exit(1);
  }
  const encoder = JsonEncoder.withIndent('  ');
  Directory('lib/l10n').createSync(recursive: true);
  for (final lang in merged.keys) {
    File('lib/l10n/app_$lang.arb').writeAsStringSync('${encoder.convert(merged[lang])}\n');
  }
  final result = Process.runSync('flutter', ['gen-l10n'], runInShell: true);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) exit(result.exitCode);
  stdout.writeln('${owner.length} texts from ${files.length} files');
}
