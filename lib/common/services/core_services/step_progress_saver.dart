// File: step_progress_service.dart
//
// Progress I/O for all steps (single "steps" block).
// Contains StepProgressSaver and StepProgressLoader.
//
// JSON at <outputDirectory>/progress.json:
// {
//   "Completed steps": [1, 2, 3],
//   "steps": {
//     "1": { "duration": { "iso8601": "PT1M23S", "seconds": 83 }, "result": { ... }, "message": "..." },
//     "2": { "duration": { ... }, "result": { ... }, "message": "..." }
//   },
//   "dataset_root": "forward-slash normalized input dir",
//   "output_root": "forward-slash normalized output dir",
//   "media_entity_collection_object": <List|Map|null>,
//   "updated_at": "2025-09-24T11:00:00Z"
// }
//
// Design:
// - Save ONLY on step success.
// - Store only forward-slash normalized absolute paths in FileEntity (no duplicates).
// - On load, rebase to current OS + roots using dataset_root/output_root.
// - If the context does not provide deserializers, rebuild domain objects here.

import 'dart:convert';
import 'dart:io';

import 'package:gpth/gpth_lib_exports.dart';

class StepProgressSaver with LoggerMixin {
  const StepProgressSaver._();

  static Future<void> saveProgress({
    required final ProcessingContext context,
    required final int stepId,
    required final Duration duration,
    required final StepResult stepResult,
  }) async {
    final Directory outputDir = context.outputDirectory;
    if (!await outputDir.exists()) await outputDir.create(recursive: true);

    final File progressFile = File('${outputDir.path}${Platform.pathSeparator}progress.json');

    Map<String, dynamic> existing = {};
    if (await progressFile.exists()) {
      try {
        final String raw = await progressFile.readAsString();
        existing = jsonDecode(raw) as Map<String, dynamic>;
      } catch (e) {
        logWarning('[Progress] Corrupted progress.json detected, will overwrite: $e', forcePrint: true);
        existing = {};
      }
    }

    final Map<dynamic, dynamic> stepsDyn =
        (existing['steps'] is Map) ? Map<dynamic, dynamic>.from(existing['steps'] as Map) : <dynamic, dynamic>{};

    final String key = stepId.toString();
    stepsDyn[key] = {
      'duration': {
        'iso8601': _formatDurationIso8601(duration),
        'seconds': duration.inSeconds,
      },
      'result': stepResult.data,
      'message': stepResult.message ?? '',
    };

    final Set<int> completedSet = _extractAllCompletedIds(existing, stepsDyn)..add(stepId);
    final List<int> completed = completedSet.toList()..sort();

    final dynamic mediaSnapshot = _serializeMediaCollection(context);

    final String datasetRoot = _toForwardSlashes(context.inputDirectory.path);
    final String outputRoot = _toForwardSlashes(context.outputDirectory.path);

    final Map<String, dynamic> doc = <String, dynamic>{
      'Completed steps': completed,
      'steps': stepsDyn.map((final k, final v) => MapEntry('$k', v)), // stringify keys
      'dataset_root': datasetRoot,
      'output_root': outputRoot,
      'media_entity_collection_object': mediaSnapshot,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };

    final File tmp = File('${progressFile.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(doc));
    await tmp.rename(progressFile.path);
    logDebug('[Progress] Saved progress for step $stepId at ${progressFile.path}');
  }

  static dynamic _serializeMediaCollection(final ProcessingContext context) {
    try {
      final dynamic mc = (context as dynamic).mediaCollection;
      if (mc == null) return null;

      Iterable<dynamic>? it;
      try { it = mc.items ?? mc.entities ?? mc.all ?? mc.list ?? mc.values; } catch (_) {}
      try { it ??= mc.asList?.call(); } catch (_) {}
      if (it == null && mc is Iterable) it = mc;

      if (it != null) return it.map(_serializeMediaEntityCompact).toList(growable: false);

      try {
        final dynamic colJson = mc.toJson?.call();
        if (colJson != null) return colJson;
      } catch (_) {}

      return _serializeMediaEntityCompact(mc);
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _serializeMediaEntityCompact(final dynamic me) {
    final dynamic primary = me.primaryFile;

    final List<dynamic> secondaries = <dynamic>[];
    try { secondaries.addAll(me.secondaryFiles as List); } catch (_) {}
    final List<dynamic> duplicates = <dynamic>[];
    try { duplicates.addAll(me.duplicatesFiles as List); } catch (_) {}

    final Map<String, dynamic> albumsOut = <String, dynamic>{};
    try {
      final dynamic albumsMap = me.albumsMap;
      if (albumsMap is Map) {
        albumsMap.forEach((final k, final v) { albumsOut['$k'] = _serializeAlbumEntity(v); });
      }
    } catch (_) {}

    String? dateTakenIso;
    try { final DateTime? dt = me.dateTaken as DateTime?; dateTakenIso = dt?.toIso8601String(); } catch (_) {}
    int? dateAccuracyValue;
    String? dateAccuracyLabel;
    try { final dynamic acc = me.dateAccuracy; dateAccuracyValue = acc?.value as int?; dateAccuracyLabel = acc?.description as String?; } catch (_) {}
    String? extractionMethod;
    try { final dynamic method = me.dateTimeExtractionMethod; extractionMethod = method?.name ?? method?.toString().split('.').last; } catch (_) {}
    bool partnerShared = false;
    try { partnerShared = me.partnerShared as bool? ?? false; } catch (_) {}

    return <String, dynamic>{
      'primaryFile': _serializeFileEntityCompact(primary),
      'secondaryFiles': secondaries.map(_serializeFileEntityCompact).toList(growable: false),
      'duplicatesFiles': duplicates.map(_serializeFileEntityCompact).toList(growable: false),
      'dateTaken': dateTakenIso,
      'dateAccuracy': dateAccuracyValue,
      'dateAccuracyLabel': dateAccuracyLabel,
      'dateTimeExtractionMethod': extractionMethod,
      'partnerShared': partnerShared,
      'albumsMap': albumsOut,
    };
  }

  static Map<String, dynamic> _serializeFileEntityCompact(final dynamic fe) {
    String sourcePath = '';
    String? targetPath;
    bool isShortcut = false, isMoved = false, isDeleted = false, isDuplicateCopy = false, isCanonical = false;
    int ranking = 0;
    int? dateAccuracyValue;
    String? dateAccuracyLabel;

    try { sourcePath = fe.sourcePath as String? ?? ''; } catch (_) {}
    try { targetPath = fe.targetPath as String?; } catch (_) {}
    try { isShortcut = fe.isShortcut as bool? ?? false; } catch (_) {}
    try { isMoved = fe.isMoved as bool? ?? false; } catch (_) {}
    try { isDeleted = fe.isDeleted as bool? ?? false; } catch (_) {}
    try { isDuplicateCopy = fe.isDuplicateCopy as bool? ?? false; } catch (_) {}
    try { ranking = fe.ranking as int? ?? 0; } catch (_) {}
    try { isCanonical = fe.isCanonical as bool? ?? false; } catch (_) {}
    try { final dynamic acc = fe.dateAccuracy; dateAccuracyValue = acc?.value as int?; dateAccuracyLabel = acc?.description as String?; } catch (_) {}

    final String srcFs = _toForwardSlashes(sourcePath);
    final String? tgtFs = targetPath == null ? null : _toForwardSlashes(targetPath);

    return <String, dynamic>{
      'sourcePath': srcFs,
      'targetPath': tgtFs,
      'isCanonical': isCanonical,
      'isShortcut': isShortcut,
      'isMoved': isMoved,
      'isDeleted': isDeleted,
      'isDuplicateCopy': isDuplicateCopy,
      'dateAccuracy': dateAccuracyValue,
      'dateAccuracyLabel': dateAccuracyLabel,
      'ranking': ranking,
    };
  }

  static Map<String, dynamic> _serializeAlbumEntity(final dynamic album) {
    String name = '';
    List<String> dirs = const [];
    try { name = album.name as String? ?? ''; } catch (_) {}
    try { final dynamic sd = album.sourceDirectories; if (sd is Iterable) dirs = sd.map((final e) => '$e').toList(growable: false); } catch (_) {}
    return <String, dynamic>{ 'name': name, 'sourceDirectories': dirs };
  }

  static Set<int> _extractAllCompletedIds(final Map<String, dynamic> existing, final Map<dynamic, dynamic> stepsDyn) {
    final Set<int> out = <int>{};

    final dynamic comp = existing['Completed steps'];
    if (comp is List) {
      for (final dynamic v in comp) {
        final String s = '$v'.trim();
        final int? n = int.tryParse(s);
        if (n != null) out.add(n);
      }
    }

    for (final dynamic k in stepsDyn.keys) {
      final String s = '$k'.trim();
      final int? n = int.tryParse(s);
      if (n != null) out.add(n);
    }

    return out;
  }

  static String _formatDurationIso8601(final Duration d) {
    final int hours = d.inHours;
    final int minutes = d.inMinutes.remainder(60);
    final int seconds = d.inSeconds.remainder(60);
    final StringBuffer sb = StringBuffer('PT');
    if (hours > 0) sb.write('${hours}H');
    if (minutes > 0) sb.write('${minutes}M');
    if (seconds > 0 || (hours == 0 && minutes == 0)) sb.write('${seconds}S');
    return sb.toString();
  }

  static String _toForwardSlashes(final String path) => path.replaceAll('\\', '/');
}

class StepProgressLoader with LoggerMixin {
  const StepProgressLoader._();

  static Future<Map<String, dynamic>?> readProgressJson(final ProcessingContext context) async {
    try {
      final Directory out = context.outputDirectory;
      final String full = '${out.path}${Platform.pathSeparator}progress.json';
      final File f = File(full);
      if (!await f.exists()) {
        logWarning('[Progress] No progress.json found at $full');
        return null;
      }
      final String raw = await f.readAsString();
      final Map<String, dynamic> decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded;
    } catch (e) {
      logWarning('[Progress] Failed to read progress.json: $e', forcePrint: true);
      return null;
    }
  }

  static bool isStepCompleted(final Map<String, dynamic> json, final int stepId, {final ProcessingContext? context}) {
    if (context != null && !context.inputDirectory.existsSync()) {
      logWarning('[Resume] Dataset not found at inputDirectory: ${context.inputDirectory.path}. Resume disabled for step $stepId.', forcePrint: true);
      return false;
    }

    bool inSteps = false, inCompleted = false;

    try {
      final dynamic stepsDyn = json['steps'];
      if (stepsDyn is Map) {
        if (stepsDyn.containsKey(stepId.toString())) inSteps = true;
        if (!inSteps) {
          for (final dynamic k in stepsDyn.keys) {
            final int? n = int.tryParse('$k'.trim());
            if (n != null && n == stepId) { inSteps = true; break; }
          }
        }
      }
    } catch (_) {}

    try {
      final dynamic comp = json['Completed steps'];
      if (comp is List) {
        for (final dynamic v in comp) {
          final String s = '$v'.trim();
          if (s == stepId.toString()) { inCompleted = true; break; }
          final int? n = int.tryParse(s);
          if (n != null && n == stepId) { inCompleted = true; break; }
        }
      }
    } catch (_) {}

    return inSteps || inCompleted;
  }

  static Duration readDurationForStep(final Map<String, dynamic> json, final int stepId) {
    try {
      final dynamic stepsDyn = json['steps'];
      if (stepsDyn is Map) {
        final dynamic rec = stepsDyn[stepId.toString()];
        if (rec is Map) {
          final dynamic dur = rec['duration'];
          if (dur is Map) {
            final dynamic sec = dur['seconds'];
            if (sec is int) return Duration(seconds: sec);
            if (sec is num) return Duration(seconds: sec.toInt());
          }
        }
      }
    } catch (_) {}
    return Duration.zero;
  }

  static Map<String, dynamic> readResultDataForStep(final Map<String, dynamic> json, final int stepId) {
    try {
      final dynamic stepsDyn = json['steps'];
      if (stepsDyn is Map) {
        final dynamic rec = stepsDyn[stepId.toString()];
        if (rec is Map) {
          final dynamic result = rec['result'];
          if (result is Map<String, dynamic>) return result;
          if (result is Map) return Map<String, dynamic>.from(result);
        }
      }
    } catch (_) {}
    return <String, dynamic>{};
  }

  static String readMessageForStep(final Map<String, dynamic> json, final int stepId) {
    try {
      final dynamic stepsDyn = json['steps'];
      if (stepsDyn is Map) {
        final dynamic rec = stepsDyn[stepId.toString()];
        if (rec is Map) {
          final dynamic msg = rec['message'];
          if (msg is String) return msg;
        }
      }
    } catch (_) {}
    return '';
  }

  /// Apply saved media snapshot into context.mediaCollection.
  /// - Rebase paths across OS using dataset_root/output_root.
  /// - Rebuild domain objects if no deserializers are provided by the context.
  static void applyMediaSnapshot(final ProcessingContext context, final dynamic snapshot, {final Map<String, dynamic>? progressJson}) {
    try {
      if (snapshot == null) return;

      // Rebase snapshot to current roots and separators
      final String oldInFs = _stringOrEmpty(progressJson?['dataset_root']);
      final String oldOutFs = _stringOrEmpty(progressJson?['output_root']);
      final String newInPlat = context.inputDirectory.path;
      final String newOutPlat = context.outputDirectory.path;
      final dynamic rebased = _rebaseSnapshot(snapshot, oldInFs, oldOutFs, newInPlat, newOutPlat);

      // 1) Let the context handle it if it provides deserializers
      try {
        final dynamic maybe = (context as dynamic).deserializeMediaCollection?.call(rebased);
        if (maybe != null) return;
      } catch (_) {}
      try {
        final dynamic maybe2 = (context as dynamic).loadMediaCollectionFromJson?.call(rebased);
        if (maybe2 != null) return;
      } catch (_) {}

      // 2) Build domain objects here (MediaEntity/FileEntity/AlbumEntity) if needed
      if (rebased is List) {
        final List<dynamic> restored = rebased.map((final e) {
          if (e is Map<String, dynamic>) return _buildMediaEntityFromMap(e);
          if (e is Map) return _buildMediaEntityFromMap(Map<String, dynamic>.from(e));
          return e;
        }).toList(growable: false);

        // Try to inject into an existing collection or assign directly
        try {
          final dynamic coll = (context as dynamic).mediaCollection;
          try { coll.clear(); coll.addAll(restored); return; } catch (_) {}
        } catch (_) {}
        try { (context as dynamic).mediaCollection = restored; return; } catch (_) {}
      }

      if (rebased is Map<String, dynamic> || rebased is Map) {
        // Some implementations might store the collection as a map; pass it through
        final Map<String, dynamic> snap = rebased is Map<String, dynamic> ? rebased : Map<String, dynamic>.from(rebased as Map);
        try { (context as dynamic).mediaCollection = snap; return; } catch (_) {}
      }
    } catch (e) {
      logWarning('[Resume] Failed to apply media snapshot: $e', forcePrint: true);
    }
  }

  // ───────────────────────────── Domain rebuild helpers ─────────────────────────────

  static MediaEntity _buildMediaEntityFromMap(final Map<String, dynamic> m) {
    final Map<String, dynamic>? pf =
        m['primaryFile'] is Map ? Map<String, dynamic>.from(m['primaryFile'] as Map) : null;

    final List<FileEntity> secondaries = <FileEntity>[];
    final List<FileEntity> duplicates = <FileEntity>[];

    try {
      final List<dynamic> s = m['secondaryFiles'] is List ? List<dynamic>.from(m['secondaryFiles'] as List) : const <dynamic>[];
      for (final e in s) {
        if (e is Map<String, dynamic> || e is Map) {
          secondaries.add(_buildFileEntityFromMap(e is Map<String, dynamic> ? e : Map<String, dynamic>.from(e as Map)));
        }
      }
    } catch (_) {}

    try {
      final List<dynamic> d = m['duplicatesFiles'] is List ? List<dynamic>.from(m['duplicatesFiles'] as List) : const <dynamic>[];
      for (final e in d) {
        if (e is Map<String, dynamic> || e is Map) {
          duplicates.add(_buildFileEntityFromMap(e is Map<String, dynamic> ? e : Map<String, dynamic>.from(e as Map)));
        }
      }
    } catch (_) {}

    // Albums map
    final Map<String, AlbumEntity> albums = <String, AlbumEntity>{};
    try {
      final dynamic am = m['albumsMap'];
      if (am is Map) {
        am.forEach((final k, final v) {
          if (v is Map<String, dynamic> || v is Map) {
            final Map<String, dynamic> a = v is Map<String, dynamic> ? v : Map<String, dynamic>.from(v as Map);
            albums['$k'] = _buildAlbumEntityFromMap(a);
          }
        });
      }
    } catch (_) {}

    // Dates
    DateTime? dateTaken;
    try {
      final String? iso = m['dateTaken'] as String?;
      if (iso != null && iso.isNotEmpty) dateTaken = DateTime.tryParse(iso);
    } catch (_) {}

    // DateAccuracy / ExtractionMethod are optional; if you need to map them, add your own adapters.
    DateAccuracy? dateAccuracy;
    try {
      // If your DateAccuracy exposes a factory from value, plug it here.
      // final int? accVal = m['dateAccuracy'] is int ? m['dateAccuracy'] as int : null;
      // dateAccuracy = accVal != null ? DateAccuracy.fromValue(accVal) : null;
    } catch (_) {}

    DateTimeExtractionMethod? extractionMethod;
    try {
      // If your enum can be parsed by name, plug it here.
      // final String? name = m['dateTimeExtractionMethod'] as String?;
      // extractionMethod = name != null ? DateTimeExtractionMethod.values.firstWhereOrNull((e)=> e.name == name) : null;
    } catch (_) {}

    bool partner = false;
    try { partner = m['partnerShared'] as bool? ?? false; } catch (_) {}

    final FileEntity primary = _buildFileEntityFromMap(pf ?? const <String, dynamic>{});

    return MediaEntity(
      primaryFile: primary,
      secondaryFiles: secondaries,
      duplicatesFiles: duplicates,
      dateTaken: dateTaken,
      dateAccuracy: dateAccuracy,
      dateTimeExtractionMethod: extractionMethod,
      partnershared: partner,
      albumsMap: albums,
    );
  }

  static FileEntity _buildFileEntityFromMap(final Map<String, dynamic> f) {
    String src = f['sourcePath'] is String ? f['sourcePath'] as String : '';
    String? tgt = f['targetPath'] is String ? f['targetPath'] as String : null;

    // Convert stored forward-slash paths to platform separators
    src = _toPlatformSeparators(src);
    if (tgt != null && tgt.isNotEmpty) tgt = _toPlatformSeparators(tgt);

    final bool isShortcut = f['isShortcut'] is bool ? f['isShortcut'] as bool : false;
    final bool isMoved = f['isMoved'] is bool ? f['isMoved'] as bool : false;
    final bool isDeleted = f['isDeleted'] is bool ? f['isDeleted'] as bool : false;
    final bool isDuplicateCopy = f['isDuplicateCopy'] is bool ? f['isDuplicateCopy'] as bool : false;
    final int ranking = f['ranking'] is int ? f['ranking'] as int : (f['ranking'] is num ? (f['ranking'] as num).toInt() : 0);

    // If you need to restore DateAccuracy at file-level, add adapter here.
    final DateAccuracy? fileAcc = null;

    final fe = FileEntity(
      sourcePath: src,
      targetPath: tgt,
      isShortcut: isShortcut,
      isMoved: isMoved,
      isDeleted: isDeleted,
      isDuplicateCopy: isDuplicateCopy,
      dateAccuracy: fileAcc,
      ranking: ranking,
    );

    // isCanonical is recalculated in FileEntity constructor; no need to set manually
    return fe;
  }

  static AlbumEntity _buildAlbumEntityFromMap(final Map<String, dynamic> a) {
    final String name = a['name'] is String ? a['name'] as String : '';
    final List<String> dirs = (a['sourceDirectories'] is List)
        ? List<String>.from((a['sourceDirectories'] as List).map((final e) => '$e'))
        : const <String>[];
    return AlbumEntity(name: name, sourceDirectories: dirs.toSet());
  }

  // ───────────────────────────── Rebase helpers ─────────────────────────────

  static String _stringOrEmpty(final dynamic v) => (v is String) ? v : '';

  static String _toForwardSlashes(final String p) => p.replaceAll('\\', '/');

  static String _toPlatformSeparators(final String fsPath) =>
      Platform.pathSeparator == '\\' ? fsPath.replaceAll('/', '\\') : fsPath.replaceAll('\\', '/');

  static String _normalizeNoTrailingSlash(final String fs) {
    if (fs.isEmpty) return '';
    final String s = _toForwardSlashes(fs);
    return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
  }

  static String? _stripPrefixCaseAware(final String fullFs, final String prefixFs) {
    if (fullFs.isEmpty || prefixFs.isEmpty) return null;
    final String full = _normalizeNoTrailingSlash(fullFs);
    final String pref = _normalizeNoTrailingSlash(prefixFs);
    final bool winLike = pref.contains(':'); // heuristic for Windows drive prefixes
    final bool starts = winLike ? full.toLowerCase().startsWith(pref.toLowerCase()) : full.startsWith(pref);
    if (!starts) return null;
    final String rel = full.substring(pref.length);
    if (rel.isEmpty) return '';
    return rel.startsWith('/') ? rel.substring(1) : rel;
  }

  static String _joinPlatform(final String base, final String relFs) {
    final String rel = _toPlatformSeparators(relFs);
    final String sep = Platform.pathSeparator;
    if (base.endsWith(sep)) return '$base$rel';
    return '$base$sep$rel';
  }

  static dynamic _rebaseSnapshot(
    final dynamic snapshot,
    final String oldInFs,
    final String oldOutFs,
    final String newInPlat,
    final String newOutPlat,
  ) {
    if (snapshot is List) {
      return snapshot.map((final e) {
        if (e is Map<String, dynamic>) return _rebaseEntity(Map<String, dynamic>.from(e), oldInFs, oldOutFs, newInPlat, newOutPlat);
        if (e is Map) return _rebaseEntity(Map<String, dynamic>.from(e), oldInFs, oldOutFs, newInPlat, newOutPlat);
        return e;
      }).toList(growable: false);
    }
    if (snapshot is Map<String, dynamic>) {
      final Map<String, dynamic> clone = Map<String, dynamic>.from(snapshot);
      clone.updateAll((final k, final v) {
        if (v is List && v.isNotEmpty && v.first is Map) {
          return v.map((final e) => _rebaseEntity(Map<String, dynamic>.from(e as Map), oldInFs, oldOutFs, newInPlat, newOutPlat)).toList();
        }
        return v;
      });
      return clone;
    }
    return snapshot;
  }

  static Map<String, dynamic> _rebaseEntity(
    final Map<String, dynamic> me,
    final String oldInFs,
    final String oldOutFs,
    final String newInPlat,
    final String newOutPlat,
  ) {
    final Map<String, dynamic> out = Map<String, dynamic>.from(me);

    Map<String, dynamic>? rebaseFile(final Map<String, dynamic>? fe) {
      if (fe == null) return null;
      final Map<String, dynamic> f = Map<String, dynamic>.from(fe);

      final String? srcNorm = f['sourcePath'] is String ? f['sourcePath'] as String : null;
      final String? tgtNorm = f['targetPath'] is String ? f['targetPath'] as String : null;

      if (srcNorm != null && srcNorm.isNotEmpty) {
        final String? rel = _stripPrefixCaseAware(srcNorm, oldInFs);
        final String newSourcePlat = (rel == null) ? _toPlatformSeparators(srcNorm) : _joinPlatform(newInPlat, rel);
        f['sourcePath'] = _toForwardSlashes(newSourcePlat);
      }

      if (tgtNorm != null && tgtNorm.isNotEmpty) {
        final String? rel = _stripPrefixCaseAware(tgtNorm, oldOutFs);
        final String newTargetPlat = (rel == null) ? _toPlatformSeparators(tgtNorm) : _joinPlatform(newOutPlat, rel);
        f['targetPath'] = _toForwardSlashes(newTargetPlat);
      }

      return f;
    }

    if (out['primaryFile'] is Map) out['primaryFile'] = rebaseFile(Map<String, dynamic>.from(out['primaryFile'] as Map));
    List<dynamic> reb(final List<dynamic> list) => list.map((final e) => e is Map ? rebaseFile(Map<String, dynamic>.from(e)) : e).toList(growable: false);

    if (out['secondaryFiles'] is List) out['secondaryFiles'] = reb(List<dynamic>.from(out['secondaryFiles'] as List));
    if (out['duplicatesFiles'] is List) out['duplicatesFiles'] = reb(List<dynamic>.from(out['duplicatesFiles'] as List));

    return out;
  }
}
