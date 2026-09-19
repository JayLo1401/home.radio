// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $FavoritesTable extends Favorites
    with TableInfo<$FavoritesTable, Favorite> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FavoritesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _programNumberMeta = const VerificationMeta(
    'programNumber',
  );
  @override
  late final GeneratedColumn<int> programNumber = GeneratedColumn<int>(
    'program_number',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sourceTypeMeta = const VerificationMeta(
    'sourceType',
  );
  @override
  late final GeneratedColumn<String> sourceType = GeneratedColumn<String>(
    'source_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _logoUrlMeta = const VerificationMeta(
    'logoUrl',
  );
  @override
  late final GeneratedColumn<String> logoUrl = GeneratedColumn<String>(
    'logo_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _logoLocalPathMeta = const VerificationMeta(
    'logoLocalPath',
  );
  @override
  late final GeneratedColumn<String> logoLocalPath = GeneratedColumn<String>(
    'logo_local_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sourceRefMeta = const VerificationMeta(
    'sourceRef',
  );
  @override
  late final GeneratedColumn<String> sourceRef = GeneratedColumn<String>(
    'source_ref',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  @override
  List<GeneratedColumn> get $columns => [
    programNumber,
    sourceType,
    displayName,
    logoUrl,
    logoLocalPath,
    sourceRef,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'favorites';
  @override
  VerificationContext validateIntegrity(
    Insertable<Favorite> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('program_number')) {
      context.handle(
        _programNumberMeta,
        programNumber.isAcceptableOrUnknown(
          data['program_number']!,
          _programNumberMeta,
        ),
      );
    }
    if (data.containsKey('source_type')) {
      context.handle(
        _sourceTypeMeta,
        sourceType.isAcceptableOrUnknown(data['source_type']!, _sourceTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceTypeMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_displayNameMeta);
    }
    if (data.containsKey('logo_url')) {
      context.handle(
        _logoUrlMeta,
        logoUrl.isAcceptableOrUnknown(data['logo_url']!, _logoUrlMeta),
      );
    }
    if (data.containsKey('logo_local_path')) {
      context.handle(
        _logoLocalPathMeta,
        logoLocalPath.isAcceptableOrUnknown(
          data['logo_local_path']!,
          _logoLocalPathMeta,
        ),
      );
    }
    if (data.containsKey('source_ref')) {
      context.handle(
        _sourceRefMeta,
        sourceRef.isAcceptableOrUnknown(data['source_ref']!, _sourceRefMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceRefMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {programNumber};
  @override
  Favorite map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Favorite(
      programNumber: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}program_number'],
      )!,
      sourceType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_type'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      logoUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}logo_url'],
      ),
      logoLocalPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}logo_local_path'],
      ),
      sourceRef: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_ref'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $FavoritesTable createAlias(String alias) {
    return $FavoritesTable(attachedDatabase, alias);
  }
}

class Favorite extends DataClass implements Insertable<Favorite> {
  final int programNumber;
  final String sourceType;
  final String displayName;
  final String? logoUrl;
  final String? logoLocalPath;
  final String sourceRef;
  final DateTime createdAt;
  const Favorite({
    required this.programNumber,
    required this.sourceType,
    required this.displayName,
    this.logoUrl,
    this.logoLocalPath,
    required this.sourceRef,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['program_number'] = Variable<int>(programNumber);
    map['source_type'] = Variable<String>(sourceType);
    map['display_name'] = Variable<String>(displayName);
    if (!nullToAbsent || logoUrl != null) {
      map['logo_url'] = Variable<String>(logoUrl);
    }
    if (!nullToAbsent || logoLocalPath != null) {
      map['logo_local_path'] = Variable<String>(logoLocalPath);
    }
    map['source_ref'] = Variable<String>(sourceRef);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  FavoritesCompanion toCompanion(bool nullToAbsent) {
    return FavoritesCompanion(
      programNumber: Value(programNumber),
      sourceType: Value(sourceType),
      displayName: Value(displayName),
      logoUrl: logoUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(logoUrl),
      logoLocalPath: logoLocalPath == null && nullToAbsent
          ? const Value.absent()
          : Value(logoLocalPath),
      sourceRef: Value(sourceRef),
      createdAt: Value(createdAt),
    );
  }

  factory Favorite.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Favorite(
      programNumber: serializer.fromJson<int>(json['programNumber']),
      sourceType: serializer.fromJson<String>(json['sourceType']),
      displayName: serializer.fromJson<String>(json['displayName']),
      logoUrl: serializer.fromJson<String?>(json['logoUrl']),
      logoLocalPath: serializer.fromJson<String?>(json['logoLocalPath']),
      sourceRef: serializer.fromJson<String>(json['sourceRef']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'programNumber': serializer.toJson<int>(programNumber),
      'sourceType': serializer.toJson<String>(sourceType),
      'displayName': serializer.toJson<String>(displayName),
      'logoUrl': serializer.toJson<String?>(logoUrl),
      'logoLocalPath': serializer.toJson<String?>(logoLocalPath),
      'sourceRef': serializer.toJson<String>(sourceRef),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  Favorite copyWith({
    int? programNumber,
    String? sourceType,
    String? displayName,
    Value<String?> logoUrl = const Value.absent(),
    Value<String?> logoLocalPath = const Value.absent(),
    String? sourceRef,
    DateTime? createdAt,
  }) => Favorite(
    programNumber: programNumber ?? this.programNumber,
    sourceType: sourceType ?? this.sourceType,
    displayName: displayName ?? this.displayName,
    logoUrl: logoUrl.present ? logoUrl.value : this.logoUrl,
    logoLocalPath: logoLocalPath.present
        ? logoLocalPath.value
        : this.logoLocalPath,
    sourceRef: sourceRef ?? this.sourceRef,
    createdAt: createdAt ?? this.createdAt,
  );
  Favorite copyWithCompanion(FavoritesCompanion data) {
    return Favorite(
      programNumber: data.programNumber.present
          ? data.programNumber.value
          : this.programNumber,
      sourceType: data.sourceType.present
          ? data.sourceType.value
          : this.sourceType,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      logoUrl: data.logoUrl.present ? data.logoUrl.value : this.logoUrl,
      logoLocalPath: data.logoLocalPath.present
          ? data.logoLocalPath.value
          : this.logoLocalPath,
      sourceRef: data.sourceRef.present ? data.sourceRef.value : this.sourceRef,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Favorite(')
          ..write('programNumber: $programNumber, ')
          ..write('sourceType: $sourceType, ')
          ..write('displayName: $displayName, ')
          ..write('logoUrl: $logoUrl, ')
          ..write('logoLocalPath: $logoLocalPath, ')
          ..write('sourceRef: $sourceRef, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    programNumber,
    sourceType,
    displayName,
    logoUrl,
    logoLocalPath,
    sourceRef,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Favorite &&
          other.programNumber == this.programNumber &&
          other.sourceType == this.sourceType &&
          other.displayName == this.displayName &&
          other.logoUrl == this.logoUrl &&
          other.logoLocalPath == this.logoLocalPath &&
          other.sourceRef == this.sourceRef &&
          other.createdAt == this.createdAt);
}

class FavoritesCompanion extends UpdateCompanion<Favorite> {
  final Value<int> programNumber;
  final Value<String> sourceType;
  final Value<String> displayName;
  final Value<String?> logoUrl;
  final Value<String?> logoLocalPath;
  final Value<String> sourceRef;
  final Value<DateTime> createdAt;
  const FavoritesCompanion({
    this.programNumber = const Value.absent(),
    this.sourceType = const Value.absent(),
    this.displayName = const Value.absent(),
    this.logoUrl = const Value.absent(),
    this.logoLocalPath = const Value.absent(),
    this.sourceRef = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  FavoritesCompanion.insert({
    this.programNumber = const Value.absent(),
    required String sourceType,
    required String displayName,
    this.logoUrl = const Value.absent(),
    this.logoLocalPath = const Value.absent(),
    required String sourceRef,
    this.createdAt = const Value.absent(),
  }) : sourceType = Value(sourceType),
       displayName = Value(displayName),
       sourceRef = Value(sourceRef);
  static Insertable<Favorite> custom({
    Expression<int>? programNumber,
    Expression<String>? sourceType,
    Expression<String>? displayName,
    Expression<String>? logoUrl,
    Expression<String>? logoLocalPath,
    Expression<String>? sourceRef,
    Expression<DateTime>? createdAt,
  }) {
    return RawValuesInsertable({
      if (programNumber != null) 'program_number': programNumber,
      if (sourceType != null) 'source_type': sourceType,
      if (displayName != null) 'display_name': displayName,
      if (logoUrl != null) 'logo_url': logoUrl,
      if (logoLocalPath != null) 'logo_local_path': logoLocalPath,
      if (sourceRef != null) 'source_ref': sourceRef,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  FavoritesCompanion copyWith({
    Value<int>? programNumber,
    Value<String>? sourceType,
    Value<String>? displayName,
    Value<String?>? logoUrl,
    Value<String?>? logoLocalPath,
    Value<String>? sourceRef,
    Value<DateTime>? createdAt,
  }) {
    return FavoritesCompanion(
      programNumber: programNumber ?? this.programNumber,
      sourceType: sourceType ?? this.sourceType,
      displayName: displayName ?? this.displayName,
      logoUrl: logoUrl ?? this.logoUrl,
      logoLocalPath: logoLocalPath ?? this.logoLocalPath,
      sourceRef: sourceRef ?? this.sourceRef,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (programNumber.present) {
      map['program_number'] = Variable<int>(programNumber.value);
    }
    if (sourceType.present) {
      map['source_type'] = Variable<String>(sourceType.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (logoUrl.present) {
      map['logo_url'] = Variable<String>(logoUrl.value);
    }
    if (logoLocalPath.present) {
      map['logo_local_path'] = Variable<String>(logoLocalPath.value);
    }
    if (sourceRef.present) {
      map['source_ref'] = Variable<String>(sourceRef.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FavoritesCompanion(')
          ..write('programNumber: $programNumber, ')
          ..write('sourceType: $sourceType, ')
          ..write('displayName: $displayName, ')
          ..write('logoUrl: $logoUrl, ')
          ..write('logoLocalPath: $logoLocalPath, ')
          ..write('sourceRef: $sourceRef, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $SettingsTable extends Settings with TableInfo<$SettingsTable, Setting> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<Setting> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  Setting map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Setting(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $SettingsTable createAlias(String alias) {
    return $SettingsTable(attachedDatabase, alias);
  }
}

class Setting extends DataClass implements Insertable<Setting> {
  final String key;
  final String value;
  const Setting({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  SettingsCompanion toCompanion(bool nullToAbsent) {
    return SettingsCompanion(key: Value(key), value: Value(value));
  }

  factory Setting.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Setting(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  Setting copyWith({String? key, String? value}) =>
      Setting(key: key ?? this.key, value: value ?? this.value);
  Setting copyWithCompanion(SettingsCompanion data) {
    return Setting(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Setting(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Setting && other.key == this.key && other.value == this.value);
}

class SettingsCompanion extends UpdateCompanion<Setting> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const SettingsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SettingsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<Setting> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SettingsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return SettingsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SettingsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DabStationsTable extends DabStations
    with TableInfo<$DabStationsTable, DabStation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DabStationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _freqKhzMeta = const VerificationMeta(
    'freqKhz',
  );
  @override
  late final GeneratedColumn<int> freqKhz = GeneratedColumn<int>(
    'freq_khz',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serviceIdMeta = const VerificationMeta(
    'serviceId',
  );
  @override
  late final GeneratedColumn<int> serviceId = GeneratedColumn<int>(
    'service_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _channelLabelMeta = const VerificationMeta(
    'channelLabel',
  );
  @override
  late final GeneratedColumn<String> channelLabel = GeneratedColumn<String>(
    'channel_label',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stationLabelMeta = const VerificationMeta(
    'stationLabel',
  );
  @override
  late final GeneratedColumn<String> stationLabel = GeneratedColumn<String>(
    'station_label',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _ensembleLabelMeta = const VerificationMeta(
    'ensembleLabel',
  );
  @override
  late final GeneratedColumn<String> ensembleLabel = GeneratedColumn<String>(
    'ensemble_label',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastSeenAtMeta = const VerificationMeta(
    'lastSeenAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastSeenAt = GeneratedColumn<DateTime>(
    'last_seen_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  static const VerificationMeta _customLabelMeta = const VerificationMeta(
    'customLabel',
  );
  @override
  late final GeneratedColumn<String> customLabel = GeneratedColumn<String>(
    'custom_label',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _logoLocalPathMeta = const VerificationMeta(
    'logoLocalPath',
  );
  @override
  late final GeneratedColumn<String> logoLocalPath = GeneratedColumn<String>(
    'logo_local_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _logoUrlMeta = const VerificationMeta(
    'logoUrl',
  );
  @override
  late final GeneratedColumn<String> logoUrl = GeneratedColumn<String>(
    'logo_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    freqKhz,
    serviceId,
    channelLabel,
    stationLabel,
    ensembleLabel,
    lastSeenAt,
    customLabel,
    logoLocalPath,
    logoUrl,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'dab_stations';
  @override
  VerificationContext validateIntegrity(
    Insertable<DabStation> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('freq_khz')) {
      context.handle(
        _freqKhzMeta,
        freqKhz.isAcceptableOrUnknown(data['freq_khz']!, _freqKhzMeta),
      );
    } else if (isInserting) {
      context.missing(_freqKhzMeta);
    }
    if (data.containsKey('service_id')) {
      context.handle(
        _serviceIdMeta,
        serviceId.isAcceptableOrUnknown(data['service_id']!, _serviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_serviceIdMeta);
    }
    if (data.containsKey('channel_label')) {
      context.handle(
        _channelLabelMeta,
        channelLabel.isAcceptableOrUnknown(
          data['channel_label']!,
          _channelLabelMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_channelLabelMeta);
    }
    if (data.containsKey('station_label')) {
      context.handle(
        _stationLabelMeta,
        stationLabel.isAcceptableOrUnknown(
          data['station_label']!,
          _stationLabelMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_stationLabelMeta);
    }
    if (data.containsKey('ensemble_label')) {
      context.handle(
        _ensembleLabelMeta,
        ensembleLabel.isAcceptableOrUnknown(
          data['ensemble_label']!,
          _ensembleLabelMeta,
        ),
      );
    }
    if (data.containsKey('last_seen_at')) {
      context.handle(
        _lastSeenAtMeta,
        lastSeenAt.isAcceptableOrUnknown(
          data['last_seen_at']!,
          _lastSeenAtMeta,
        ),
      );
    }
    if (data.containsKey('custom_label')) {
      context.handle(
        _customLabelMeta,
        customLabel.isAcceptableOrUnknown(
          data['custom_label']!,
          _customLabelMeta,
        ),
      );
    }
    if (data.containsKey('logo_local_path')) {
      context.handle(
        _logoLocalPathMeta,
        logoLocalPath.isAcceptableOrUnknown(
          data['logo_local_path']!,
          _logoLocalPathMeta,
        ),
      );
    }
    if (data.containsKey('logo_url')) {
      context.handle(
        _logoUrlMeta,
        logoUrl.isAcceptableOrUnknown(data['logo_url']!, _logoUrlMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {freqKhz, serviceId};
  @override
  DabStation map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DabStation(
      freqKhz: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}freq_khz'],
      )!,
      serviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}service_id'],
      )!,
      channelLabel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}channel_label'],
      )!,
      stationLabel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}station_label'],
      )!,
      ensembleLabel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ensemble_label'],
      ),
      lastSeenAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_seen_at'],
      )!,
      customLabel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}custom_label'],
      ),
      logoLocalPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}logo_local_path'],
      ),
      logoUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}logo_url'],
      ),
    );
  }

  @override
  $DabStationsTable createAlias(String alias) {
    return $DabStationsTable(attachedDatabase, alias);
  }
}

class DabStation extends DataClass implements Insertable<DabStation> {
  final int freqKhz;
  final int serviceId;
  final String channelLabel;
  final String stationLabel;
  final String? ensembleLabel;
  final DateTime lastSeenAt;
  final String? customLabel;
  final String? logoLocalPath;
  final String? logoUrl;
  const DabStation({
    required this.freqKhz,
    required this.serviceId,
    required this.channelLabel,
    required this.stationLabel,
    this.ensembleLabel,
    required this.lastSeenAt,
    this.customLabel,
    this.logoLocalPath,
    this.logoUrl,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['freq_khz'] = Variable<int>(freqKhz);
    map['service_id'] = Variable<int>(serviceId);
    map['channel_label'] = Variable<String>(channelLabel);
    map['station_label'] = Variable<String>(stationLabel);
    if (!nullToAbsent || ensembleLabel != null) {
      map['ensemble_label'] = Variable<String>(ensembleLabel);
    }
    map['last_seen_at'] = Variable<DateTime>(lastSeenAt);
    if (!nullToAbsent || customLabel != null) {
      map['custom_label'] = Variable<String>(customLabel);
    }
    if (!nullToAbsent || logoLocalPath != null) {
      map['logo_local_path'] = Variable<String>(logoLocalPath);
    }
    if (!nullToAbsent || logoUrl != null) {
      map['logo_url'] = Variable<String>(logoUrl);
    }
    return map;
  }

  DabStationsCompanion toCompanion(bool nullToAbsent) {
    return DabStationsCompanion(
      freqKhz: Value(freqKhz),
      serviceId: Value(serviceId),
      channelLabel: Value(channelLabel),
      stationLabel: Value(stationLabel),
      ensembleLabel: ensembleLabel == null && nullToAbsent
          ? const Value.absent()
          : Value(ensembleLabel),
      lastSeenAt: Value(lastSeenAt),
      customLabel: customLabel == null && nullToAbsent
          ? const Value.absent()
          : Value(customLabel),
      logoLocalPath: logoLocalPath == null && nullToAbsent
          ? const Value.absent()
          : Value(logoLocalPath),
      logoUrl: logoUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(logoUrl),
    );
  }

  factory DabStation.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DabStation(
      freqKhz: serializer.fromJson<int>(json['freqKhz']),
      serviceId: serializer.fromJson<int>(json['serviceId']),
      channelLabel: serializer.fromJson<String>(json['channelLabel']),
      stationLabel: serializer.fromJson<String>(json['stationLabel']),
      ensembleLabel: serializer.fromJson<String?>(json['ensembleLabel']),
      lastSeenAt: serializer.fromJson<DateTime>(json['lastSeenAt']),
      customLabel: serializer.fromJson<String?>(json['customLabel']),
      logoLocalPath: serializer.fromJson<String?>(json['logoLocalPath']),
      logoUrl: serializer.fromJson<String?>(json['logoUrl']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'freqKhz': serializer.toJson<int>(freqKhz),
      'serviceId': serializer.toJson<int>(serviceId),
      'channelLabel': serializer.toJson<String>(channelLabel),
      'stationLabel': serializer.toJson<String>(stationLabel),
      'ensembleLabel': serializer.toJson<String?>(ensembleLabel),
      'lastSeenAt': serializer.toJson<DateTime>(lastSeenAt),
      'customLabel': serializer.toJson<String?>(customLabel),
      'logoLocalPath': serializer.toJson<String?>(logoLocalPath),
      'logoUrl': serializer.toJson<String?>(logoUrl),
    };
  }

  DabStation copyWith({
    int? freqKhz,
    int? serviceId,
    String? channelLabel,
    String? stationLabel,
    Value<String?> ensembleLabel = const Value.absent(),
    DateTime? lastSeenAt,
    Value<String?> customLabel = const Value.absent(),
    Value<String?> logoLocalPath = const Value.absent(),
    Value<String?> logoUrl = const Value.absent(),
  }) => DabStation(
    freqKhz: freqKhz ?? this.freqKhz,
    serviceId: serviceId ?? this.serviceId,
    channelLabel: channelLabel ?? this.channelLabel,
    stationLabel: stationLabel ?? this.stationLabel,
    ensembleLabel: ensembleLabel.present
        ? ensembleLabel.value
        : this.ensembleLabel,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    customLabel: customLabel.present ? customLabel.value : this.customLabel,
    logoLocalPath: logoLocalPath.present
        ? logoLocalPath.value
        : this.logoLocalPath,
    logoUrl: logoUrl.present ? logoUrl.value : this.logoUrl,
  );
  DabStation copyWithCompanion(DabStationsCompanion data) {
    return DabStation(
      freqKhz: data.freqKhz.present ? data.freqKhz.value : this.freqKhz,
      serviceId: data.serviceId.present ? data.serviceId.value : this.serviceId,
      channelLabel: data.channelLabel.present
          ? data.channelLabel.value
          : this.channelLabel,
      stationLabel: data.stationLabel.present
          ? data.stationLabel.value
          : this.stationLabel,
      ensembleLabel: data.ensembleLabel.present
          ? data.ensembleLabel.value
          : this.ensembleLabel,
      lastSeenAt: data.lastSeenAt.present
          ? data.lastSeenAt.value
          : this.lastSeenAt,
      customLabel: data.customLabel.present
          ? data.customLabel.value
          : this.customLabel,
      logoLocalPath: data.logoLocalPath.present
          ? data.logoLocalPath.value
          : this.logoLocalPath,
      logoUrl: data.logoUrl.present ? data.logoUrl.value : this.logoUrl,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DabStation(')
          ..write('freqKhz: $freqKhz, ')
          ..write('serviceId: $serviceId, ')
          ..write('channelLabel: $channelLabel, ')
          ..write('stationLabel: $stationLabel, ')
          ..write('ensembleLabel: $ensembleLabel, ')
          ..write('lastSeenAt: $lastSeenAt, ')
          ..write('customLabel: $customLabel, ')
          ..write('logoLocalPath: $logoLocalPath, ')
          ..write('logoUrl: $logoUrl')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    freqKhz,
    serviceId,
    channelLabel,
    stationLabel,
    ensembleLabel,
    lastSeenAt,
    customLabel,
    logoLocalPath,
    logoUrl,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DabStation &&
          other.freqKhz == this.freqKhz &&
          other.serviceId == this.serviceId &&
          other.channelLabel == this.channelLabel &&
          other.stationLabel == this.stationLabel &&
          other.ensembleLabel == this.ensembleLabel &&
          other.lastSeenAt == this.lastSeenAt &&
          other.customLabel == this.customLabel &&
          other.logoLocalPath == this.logoLocalPath &&
          other.logoUrl == this.logoUrl);
}

class DabStationsCompanion extends UpdateCompanion<DabStation> {
  final Value<int> freqKhz;
  final Value<int> serviceId;
  final Value<String> channelLabel;
  final Value<String> stationLabel;
  final Value<String?> ensembleLabel;
  final Value<DateTime> lastSeenAt;
  final Value<String?> customLabel;
  final Value<String?> logoLocalPath;
  final Value<String?> logoUrl;
  final Value<int> rowid;
  const DabStationsCompanion({
    this.freqKhz = const Value.absent(),
    this.serviceId = const Value.absent(),
    this.channelLabel = const Value.absent(),
    this.stationLabel = const Value.absent(),
    this.ensembleLabel = const Value.absent(),
    this.lastSeenAt = const Value.absent(),
    this.customLabel = const Value.absent(),
    this.logoLocalPath = const Value.absent(),
    this.logoUrl = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DabStationsCompanion.insert({
    required int freqKhz,
    required int serviceId,
    required String channelLabel,
    required String stationLabel,
    this.ensembleLabel = const Value.absent(),
    this.lastSeenAt = const Value.absent(),
    this.customLabel = const Value.absent(),
    this.logoLocalPath = const Value.absent(),
    this.logoUrl = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : freqKhz = Value(freqKhz),
       serviceId = Value(serviceId),
       channelLabel = Value(channelLabel),
       stationLabel = Value(stationLabel);
  static Insertable<DabStation> custom({
    Expression<int>? freqKhz,
    Expression<int>? serviceId,
    Expression<String>? channelLabel,
    Expression<String>? stationLabel,
    Expression<String>? ensembleLabel,
    Expression<DateTime>? lastSeenAt,
    Expression<String>? customLabel,
    Expression<String>? logoLocalPath,
    Expression<String>? logoUrl,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (freqKhz != null) 'freq_khz': freqKhz,
      if (serviceId != null) 'service_id': serviceId,
      if (channelLabel != null) 'channel_label': channelLabel,
      if (stationLabel != null) 'station_label': stationLabel,
      if (ensembleLabel != null) 'ensemble_label': ensembleLabel,
      if (lastSeenAt != null) 'last_seen_at': lastSeenAt,
      if (customLabel != null) 'custom_label': customLabel,
      if (logoLocalPath != null) 'logo_local_path': logoLocalPath,
      if (logoUrl != null) 'logo_url': logoUrl,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DabStationsCompanion copyWith({
    Value<int>? freqKhz,
    Value<int>? serviceId,
    Value<String>? channelLabel,
    Value<String>? stationLabel,
    Value<String?>? ensembleLabel,
    Value<DateTime>? lastSeenAt,
    Value<String?>? customLabel,
    Value<String?>? logoLocalPath,
    Value<String?>? logoUrl,
    Value<int>? rowid,
  }) {
    return DabStationsCompanion(
      freqKhz: freqKhz ?? this.freqKhz,
      serviceId: serviceId ?? this.serviceId,
      channelLabel: channelLabel ?? this.channelLabel,
      stationLabel: stationLabel ?? this.stationLabel,
      ensembleLabel: ensembleLabel ?? this.ensembleLabel,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      customLabel: customLabel ?? this.customLabel,
      logoLocalPath: logoLocalPath ?? this.logoLocalPath,
      logoUrl: logoUrl ?? this.logoUrl,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (freqKhz.present) {
      map['freq_khz'] = Variable<int>(freqKhz.value);
    }
    if (serviceId.present) {
      map['service_id'] = Variable<int>(serviceId.value);
    }
    if (channelLabel.present) {
      map['channel_label'] = Variable<String>(channelLabel.value);
    }
    if (stationLabel.present) {
      map['station_label'] = Variable<String>(stationLabel.value);
    }
    if (ensembleLabel.present) {
      map['ensemble_label'] = Variable<String>(ensembleLabel.value);
    }
    if (lastSeenAt.present) {
      map['last_seen_at'] = Variable<DateTime>(lastSeenAt.value);
    }
    if (customLabel.present) {
      map['custom_label'] = Variable<String>(customLabel.value);
    }
    if (logoLocalPath.present) {
      map['logo_local_path'] = Variable<String>(logoLocalPath.value);
    }
    if (logoUrl.present) {
      map['logo_url'] = Variable<String>(logoUrl.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DabStationsCompanion(')
          ..write('freqKhz: $freqKhz, ')
          ..write('serviceId: $serviceId, ')
          ..write('channelLabel: $channelLabel, ')
          ..write('stationLabel: $stationLabel, ')
          ..write('ensembleLabel: $ensembleLabel, ')
          ..write('lastSeenAt: $lastSeenAt, ')
          ..write('customLabel: $customLabel, ')
          ..write('logoLocalPath: $logoLocalPath, ')
          ..write('logoUrl: $logoUrl, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $FavoritesTable favorites = $FavoritesTable(this);
  late final $SettingsTable settings = $SettingsTable(this);
  late final $DabStationsTable dabStations = $DabStationsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    favorites,
    settings,
    dabStations,
  ];
}

typedef $$FavoritesTableCreateCompanionBuilder =
    FavoritesCompanion Function({
      Value<int> programNumber,
      required String sourceType,
      required String displayName,
      Value<String?> logoUrl,
      Value<String?> logoLocalPath,
      required String sourceRef,
      Value<DateTime> createdAt,
    });
typedef $$FavoritesTableUpdateCompanionBuilder =
    FavoritesCompanion Function({
      Value<int> programNumber,
      Value<String> sourceType,
      Value<String> displayName,
      Value<String?> logoUrl,
      Value<String?> logoLocalPath,
      Value<String> sourceRef,
      Value<DateTime> createdAt,
    });

class $$FavoritesTableFilterComposer
    extends Composer<_$AppDatabase, $FavoritesTable> {
  $$FavoritesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get programNumber => $composableBuilder(
    column: $table.programNumber,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceType => $composableBuilder(
    column: $table.sourceType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get logoUrl => $composableBuilder(
    column: $table.logoUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get logoLocalPath => $composableBuilder(
    column: $table.logoLocalPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceRef => $composableBuilder(
    column: $table.sourceRef,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$FavoritesTableOrderingComposer
    extends Composer<_$AppDatabase, $FavoritesTable> {
  $$FavoritesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get programNumber => $composableBuilder(
    column: $table.programNumber,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceType => $composableBuilder(
    column: $table.sourceType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get logoUrl => $composableBuilder(
    column: $table.logoUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get logoLocalPath => $composableBuilder(
    column: $table.logoLocalPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceRef => $composableBuilder(
    column: $table.sourceRef,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$FavoritesTableAnnotationComposer
    extends Composer<_$AppDatabase, $FavoritesTable> {
  $$FavoritesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get programNumber => $composableBuilder(
    column: $table.programNumber,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sourceType => $composableBuilder(
    column: $table.sourceType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get logoUrl =>
      $composableBuilder(column: $table.logoUrl, builder: (column) => column);

  GeneratedColumn<String> get logoLocalPath => $composableBuilder(
    column: $table.logoLocalPath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sourceRef =>
      $composableBuilder(column: $table.sourceRef, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$FavoritesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $FavoritesTable,
          Favorite,
          $$FavoritesTableFilterComposer,
          $$FavoritesTableOrderingComposer,
          $$FavoritesTableAnnotationComposer,
          $$FavoritesTableCreateCompanionBuilder,
          $$FavoritesTableUpdateCompanionBuilder,
          (Favorite, BaseReferences<_$AppDatabase, $FavoritesTable, Favorite>),
          Favorite,
          PrefetchHooks Function()
        > {
  $$FavoritesTableTableManager(_$AppDatabase db, $FavoritesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FavoritesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FavoritesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FavoritesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> programNumber = const Value.absent(),
                Value<String> sourceType = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<String?> logoUrl = const Value.absent(),
                Value<String?> logoLocalPath = const Value.absent(),
                Value<String> sourceRef = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
              }) => FavoritesCompanion(
                programNumber: programNumber,
                sourceType: sourceType,
                displayName: displayName,
                logoUrl: logoUrl,
                logoLocalPath: logoLocalPath,
                sourceRef: sourceRef,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> programNumber = const Value.absent(),
                required String sourceType,
                required String displayName,
                Value<String?> logoUrl = const Value.absent(),
                Value<String?> logoLocalPath = const Value.absent(),
                required String sourceRef,
                Value<DateTime> createdAt = const Value.absent(),
              }) => FavoritesCompanion.insert(
                programNumber: programNumber,
                sourceType: sourceType,
                displayName: displayName,
                logoUrl: logoUrl,
                logoLocalPath: logoLocalPath,
                sourceRef: sourceRef,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$FavoritesTable, Favorite>(table),
                  BaseReferences<_$AppDatabase, $FavoritesTable, Favorite>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$FavoritesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $FavoritesTable,
      Favorite,
      $$FavoritesTableFilterComposer,
      $$FavoritesTableOrderingComposer,
      $$FavoritesTableAnnotationComposer,
      $$FavoritesTableCreateCompanionBuilder,
      $$FavoritesTableUpdateCompanionBuilder,
      (Favorite, BaseReferences<_$AppDatabase, $FavoritesTable, Favorite>),
      Favorite,
      PrefetchHooks Function()
    >;
typedef $$SettingsTableCreateCompanionBuilder =
    SettingsCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$SettingsTableUpdateCompanionBuilder =
    SettingsCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$SettingsTableFilterComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SettingsTableOrderingComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SettingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$SettingsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SettingsTable,
          Setting,
          $$SettingsTableFilterComposer,
          $$SettingsTableOrderingComposer,
          $$SettingsTableAnnotationComposer,
          $$SettingsTableCreateCompanionBuilder,
          $$SettingsTableUpdateCompanionBuilder,
          (Setting, BaseReferences<_$AppDatabase, $SettingsTable, Setting>),
          Setting,
          PrefetchHooks Function()
        > {
  $$SettingsTableTableManager(_$AppDatabase db, $SettingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SettingsCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => SettingsCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SettingsTable, Setting>(table),
                  BaseReferences<_$AppDatabase, $SettingsTable, Setting>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SettingsTable,
      Setting,
      $$SettingsTableFilterComposer,
      $$SettingsTableOrderingComposer,
      $$SettingsTableAnnotationComposer,
      $$SettingsTableCreateCompanionBuilder,
      $$SettingsTableUpdateCompanionBuilder,
      (Setting, BaseReferences<_$AppDatabase, $SettingsTable, Setting>),
      Setting,
      PrefetchHooks Function()
    >;
typedef $$DabStationsTableCreateCompanionBuilder =
    DabStationsCompanion Function({
      required int freqKhz,
      required int serviceId,
      required String channelLabel,
      required String stationLabel,
      Value<String?> ensembleLabel,
      Value<DateTime> lastSeenAt,
      Value<String?> customLabel,
      Value<String?> logoLocalPath,
      Value<String?> logoUrl,
      Value<int> rowid,
    });
typedef $$DabStationsTableUpdateCompanionBuilder =
    DabStationsCompanion Function({
      Value<int> freqKhz,
      Value<int> serviceId,
      Value<String> channelLabel,
      Value<String> stationLabel,
      Value<String?> ensembleLabel,
      Value<DateTime> lastSeenAt,
      Value<String?> customLabel,
      Value<String?> logoLocalPath,
      Value<String?> logoUrl,
      Value<int> rowid,
    });

class $$DabStationsTableFilterComposer
    extends Composer<_$AppDatabase, $DabStationsTable> {
  $$DabStationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get freqKhz => $composableBuilder(
    column: $table.freqKhz,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get serviceId => $composableBuilder(
    column: $table.serviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get channelLabel => $composableBuilder(
    column: $table.channelLabel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stationLabel => $composableBuilder(
    column: $table.stationLabel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ensembleLabel => $composableBuilder(
    column: $table.ensembleLabel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastSeenAt => $composableBuilder(
    column: $table.lastSeenAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get customLabel => $composableBuilder(
    column: $table.customLabel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get logoLocalPath => $composableBuilder(
    column: $table.logoLocalPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get logoUrl => $composableBuilder(
    column: $table.logoUrl,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DabStationsTableOrderingComposer
    extends Composer<_$AppDatabase, $DabStationsTable> {
  $$DabStationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get freqKhz => $composableBuilder(
    column: $table.freqKhz,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get serviceId => $composableBuilder(
    column: $table.serviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get channelLabel => $composableBuilder(
    column: $table.channelLabel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stationLabel => $composableBuilder(
    column: $table.stationLabel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ensembleLabel => $composableBuilder(
    column: $table.ensembleLabel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastSeenAt => $composableBuilder(
    column: $table.lastSeenAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get customLabel => $composableBuilder(
    column: $table.customLabel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get logoLocalPath => $composableBuilder(
    column: $table.logoLocalPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get logoUrl => $composableBuilder(
    column: $table.logoUrl,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DabStationsTableAnnotationComposer
    extends Composer<_$AppDatabase, $DabStationsTable> {
  $$DabStationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get freqKhz =>
      $composableBuilder(column: $table.freqKhz, builder: (column) => column);

  GeneratedColumn<int> get serviceId =>
      $composableBuilder(column: $table.serviceId, builder: (column) => column);

  GeneratedColumn<String> get channelLabel => $composableBuilder(
    column: $table.channelLabel,
    builder: (column) => column,
  );

  GeneratedColumn<String> get stationLabel => $composableBuilder(
    column: $table.stationLabel,
    builder: (column) => column,
  );

  GeneratedColumn<String> get ensembleLabel => $composableBuilder(
    column: $table.ensembleLabel,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get lastSeenAt => $composableBuilder(
    column: $table.lastSeenAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get customLabel => $composableBuilder(
    column: $table.customLabel,
    builder: (column) => column,
  );

  GeneratedColumn<String> get logoLocalPath => $composableBuilder(
    column: $table.logoLocalPath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get logoUrl =>
      $composableBuilder(column: $table.logoUrl, builder: (column) => column);
}

class $$DabStationsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DabStationsTable,
          DabStation,
          $$DabStationsTableFilterComposer,
          $$DabStationsTableOrderingComposer,
          $$DabStationsTableAnnotationComposer,
          $$DabStationsTableCreateCompanionBuilder,
          $$DabStationsTableUpdateCompanionBuilder,
          (
            DabStation,
            BaseReferences<_$AppDatabase, $DabStationsTable, DabStation>,
          ),
          DabStation,
          PrefetchHooks Function()
        > {
  $$DabStationsTableTableManager(_$AppDatabase db, $DabStationsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DabStationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DabStationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DabStationsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> freqKhz = const Value.absent(),
                Value<int> serviceId = const Value.absent(),
                Value<String> channelLabel = const Value.absent(),
                Value<String> stationLabel = const Value.absent(),
                Value<String?> ensembleLabel = const Value.absent(),
                Value<DateTime> lastSeenAt = const Value.absent(),
                Value<String?> customLabel = const Value.absent(),
                Value<String?> logoLocalPath = const Value.absent(),
                Value<String?> logoUrl = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DabStationsCompanion(
                freqKhz: freqKhz,
                serviceId: serviceId,
                channelLabel: channelLabel,
                stationLabel: stationLabel,
                ensembleLabel: ensembleLabel,
                lastSeenAt: lastSeenAt,
                customLabel: customLabel,
                logoLocalPath: logoLocalPath,
                logoUrl: logoUrl,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int freqKhz,
                required int serviceId,
                required String channelLabel,
                required String stationLabel,
                Value<String?> ensembleLabel = const Value.absent(),
                Value<DateTime> lastSeenAt = const Value.absent(),
                Value<String?> customLabel = const Value.absent(),
                Value<String?> logoLocalPath = const Value.absent(),
                Value<String?> logoUrl = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DabStationsCompanion.insert(
                freqKhz: freqKhz,
                serviceId: serviceId,
                channelLabel: channelLabel,
                stationLabel: stationLabel,
                ensembleLabel: ensembleLabel,
                lastSeenAt: lastSeenAt,
                customLabel: customLabel,
                logoLocalPath: logoLocalPath,
                logoUrl: logoUrl,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$DabStationsTable, DabStation>(table),
                  BaseReferences<_$AppDatabase, $DabStationsTable, DabStation>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DabStationsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DabStationsTable,
      DabStation,
      $$DabStationsTableFilterComposer,
      $$DabStationsTableOrderingComposer,
      $$DabStationsTableAnnotationComposer,
      $$DabStationsTableCreateCompanionBuilder,
      $$DabStationsTableUpdateCompanionBuilder,
      (
        DabStation,
        BaseReferences<_$AppDatabase, $DabStationsTable, DabStation>,
      ),
      DabStation,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$FavoritesTableTableManager get favorites =>
      $$FavoritesTableTableManager(_db, _db.favorites);
  $$SettingsTableTableManager get settings =>
      $$SettingsTableTableManager(_db, _db.settings);
  $$DabStationsTableTableManager get dabStations =>
      $$DabStationsTableTableManager(_db, _db.dabStations);
}
