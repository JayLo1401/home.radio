import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/nas_providers.dart';
import '../../core/popup_text_field.dart';
import '../../data/repositories/nas_settings_repository.dart';
import '../../data/services/nas_service.dart';
import '../../l10n/l10n.dart';
import 'nas_settings_screen.dart';

/// What OK on a film folder offers.
enum _MovieFolderAction { rename, change, up, down, remove }

/// Settings → NAS: the films part's folders - any number, each with its
/// name in Filme, in the order Filme shows them. OK on one opens what can
/// be done with it (rename, another folder, up, down, remove); the last
/// row adds a folder (the NAS folder browser, then its name).
class MovieFoldersSection extends ConsumerWidget {
  const MovieFoldersSection({super.key, required this.config, required this.enabled});

  /// The server as currently typed in (also before it was saved).
  final NasConfig Function() config;

  /// A server is entered.
  final bool enabled;

  Future<String?> _browse(BuildContext context, String title, String initialPath) =>
      Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => NasFolderBrowserScreen(
            config: config(),
            title: context.l10n.nasBrowseTitle(title),
            initialPath: initialPath,
          ),
        ),
      );

  /// Runs [change] - an error (the database) as a message, never a crash.
  Future<void> _save(BuildContext context, Future<void> Function() change) async {
    try {
      await change();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.nasMovieFolderSaveFailed('$e'))));
      }
    }
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final l = context.l10n;
    final path = await _browse(context, l.moviesTitle, '/');
    if (path == null || !context.mounted) return;
    final name = await showTextInputDialog(
      context,
      title: l.nasMovieFolderName,
      initialValue: MovieFolder.defaultName(path),
      hint: path,
    );
    if (name == null || !context.mounted) return;
    await _save(context, () => ref.read(nasSettingsProvider.notifier).addMovieFolder(path, name: name));
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, List<MovieFolder> folders, int index) async {
    final l = context.l10n;
    final folder = folders[index];
    final focusColor = Theme.of(context).colorScheme.primary.withValues(alpha: 0.35);
    Widget option(BuildContext context, _MovieFolderAction action, IconData icon, String title, {bool autofocus = false}) =>
        ListTile(
          autofocus: autofocus,
          leading: Icon(icon),
          title: Text(title),
          focusColor: focusColor,
          onTap: () => Navigator.of(context).pop(action),
        );
    final action = await showDialog<_MovieFolderAction>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(folder.label),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(folder.path, style: const TextStyle(color: Colors.white60)),
          ),
          option(context, _MovieFolderAction.rename, Icons.edit_outlined, l.nasMovieFolderRename, autofocus: true),
          option(context, _MovieFolderAction.change, Icons.folder_open_outlined, l.nasMovieFolderChange),
          if (index > 0) option(context, _MovieFolderAction.up, Icons.arrow_upward, l.nasMovieFolderUp),
          if (index < folders.length - 1) option(context, _MovieFolderAction.down, Icons.arrow_downward, l.nasMovieFolderDown),
          option(context, _MovieFolderAction.remove, Icons.delete_outline, l.nasMovieFolderRemove),
        ],
      ),
    );
    if (action == null || !context.mounted) return;
    final notifier = ref.read(nasSettingsProvider.notifier);
    switch (action) {
      case _MovieFolderAction.rename:
        final name = await showTextInputDialog(
          context,
          title: l.nasMovieFolderName,
          initialValue: folder.label,
          hint: MovieFolder.defaultName(folder.path),
        );
        if (name != null && context.mounted) await _save(context, () => notifier.renameMovieFolder(index, name));
      case _MovieFolderAction.change:
        final path = await _browse(context, folder.label, folder.path);
        if (path != null && context.mounted) await _save(context, () => notifier.setMovieFolderPath(index, path));
      case _MovieFolderAction.up:
        await _save(context, () => notifier.moveMovieFolder(index, index - 1));
      case _MovieFolderAction.down:
        await _save(context, () => notifier.moveMovieFolder(index, index + 1));
      case _MovieFolderAction.remove:
        await _save(context, () => notifier.removeMovieFolder(index));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    const help = TextStyle(color: Colors.white54, fontSize: 13);
    final focusColor = Theme.of(context).colorScheme.primary.withValues(alpha: 0.35);
    final folders = ref.watch(nasSettingsProvider).value?.movieFolders ?? const <MovieFolder>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l.nasMovieFoldersSection, style: Theme.of(context).textTheme.titleMedium),
        Text(enabled ? l.nasMovieFoldersHint : l.nasNeedServer, style: help),
        const SizedBox(height: 8),
        for (final (i, folder) in folders.indexed)
          ListTile(
            enabled: enabled,
            leading: const Icon(Icons.video_library_outlined),
            title: Text(folder.label),
            subtitle: Text(folder.path),
            trailing: const Icon(Icons.more_vert),
            focusColor: focusColor,
            onTap: () => _edit(context, ref, folders, i),
          ),
        ListTile(
          enabled: enabled,
          leading: const Icon(Icons.add),
          title: Text(l.nasMovieFolderAdd),
          subtitle: folders.isEmpty ? Text(l.nasMovieFoldersEmpty) : null,
          focusColor: focusColor,
          onTap: () => _add(context, ref),
        ),
      ],
    );
  }
}
