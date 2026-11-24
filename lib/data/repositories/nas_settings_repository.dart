import '../db/database.dart';
import '../services/nas_service.dart';
import '../services/secret_store.dart';

/// Settings → NAS: server, login and the chosen folders.
class NasSettings {
  final NasConfig config;

  /// Chosen folder per kind (absolute remote paths); missing = not chosen.
  final Map<NasFolder, String> folders;

  const NasSettings({this.config = const NasConfig(), this.folders = const {}});

  /// The folder of [kind], or null if the NAS isn't set up or none is chosen.
  String? folder(NasFolder kind) => config.isConfigured ? folders[kind] : null;

  NasSettings copyWith({NasConfig? config, Map<NasFolder, String>? folders}) =>
      NasSettings(config: config ?? this.config, folders: folders ?? this.folders);
}

/// Stores [NasSettings] in the settings table (so backups carry them) - the
/// password in the [SecretStore].
class NasSettingsRepository {
  NasSettingsRepository(this._db) : _secrets = SecretStore(_db);

  final AppDatabase _db;
  final SecretStore _secrets;

  /// SecretStore key of the NAS password.
  static const passwordKey = 'nas_password';

  static const _protocol = 'nas_protocol';
  static const _host = 'nas_host';
  static const _port = 'nas_port';
  static const _https = 'nas_https';
  static const _basePath = 'nas_base_path';
  static const _user = 'nas_user';
  static const _domain = 'nas_domain';
  static String _folderKey(NasFolder kind) => 'nas_folder_${kind.name}';

  Future<NasSettings> load() async {
    final protocol = await _db.getSetting(_protocol);
    final config = NasConfig(
      protocol: NasProtocol.values.firstWhere((p) => p.name == protocol, orElse: () => NasProtocol.webdav),
      host: await _db.getSetting(_host) ?? '',
      port: int.tryParse(await _db.getSetting(_port) ?? ''),
      https: await _db.getSetting(_https) == 'true',
      basePath: await _db.getSetting(_basePath) ?? '',
      user: await _db.getSetting(_user) ?? '',
      password: await _secrets.read(passwordKey) ?? '',
      domain: await _db.getSetting(_domain) ?? '',
    );
    final folders = <NasFolder, String>{};
    for (final kind in NasFolder.values) {
      final path = await _db.getSetting(_folderKey(kind));
      if (path != null && path.isNotEmpty) folders[kind] = path;
    }
    // Before the own background folder, Home's pictures came from the
    // pictures folder - it carries on as the background folder.
    final pictures = folders[NasFolder.pictures];
    if (!folders.containsKey(NasFolder.backgrounds) &&
        pictures != null &&
        await _db.getSetting(_folderKey(NasFolder.backgrounds)) == null) {
      folders[NasFolder.backgrounds] = pictures;
      await setFolder(NasFolder.backgrounds, pictures);
    }
    return NasSettings(config: config, folders: folders);
  }

  Future<void> saveConfig(NasConfig config) async {
    await _db.setSetting(_protocol, config.protocol.name);
    await _db.setSetting(_host, config.host.trim());
    await _db.setSetting(_port, config.port?.toString() ?? '');
    await _db.setSetting(_https, '${config.https}');
    await _db.setSetting(_basePath, config.basePath.trim());
    await _db.setSetting(_user, config.user);
    await _db.setSetting(_domain, config.domain.trim());
    await _secrets.write(passwordKey, config.password);
  }

  /// [path] null or empty clears the folder.
  Future<void> setFolder(NasFolder kind, String? path) => _db.setSetting(_folderKey(kind), path ?? '');
}
