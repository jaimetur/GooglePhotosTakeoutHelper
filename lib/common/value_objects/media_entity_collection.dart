import 'package:gpth/gpth-lib.dart';

/// Modern domain model representing a collection of media entities (slim version).
/// This class is now a pure container; the heavy logic for steps 3–6
/// lives inside each step's `execute`.
class MediaEntityCollection with LoggerMixin {
  MediaEntityCollection([final List<MediaEntity>? initial])
      : _media = initial?.toList(growable: true) ?? <MediaEntity>[];

  final List<MediaEntity> _media;

  /// Read-only snapshot
  List<MediaEntity> get media => List.unmodifiable(_media);

  /// Number of media items in the collection
  int get length => _media.length;

  /// Whether the collection is empty
  bool get isEmpty => _media.isEmpty;

  bool get isNotEmpty => _media.isNotEmpty;

  /// Iterable view
  Iterable<MediaEntity> get entities => _media;

  /// Indexer (read)
  MediaEntity operator [](final int index) => _media[index];

  /// Indexer (write/replace one)
  void operator []=(final int index, final MediaEntity entity) {
    _media[index] = entity;
  }

  /// Append one
  void add(final MediaEntity entity) => _media.add(entity);

  /// Append many
  void addAll(final Iterable<MediaEntity> entities) => _media.addAll(entities);

  /// Remove one (by identity/equality)
  bool remove(final MediaEntity entity) => _media.remove(entity);

  /// Clear all
  void clear() => _media.clear();

  /// Replace at index
  void replaceAt(final int index, final MediaEntity entity) {
    _media[index] = entity;
  }

  /// Replace entire content in one shot
  void replaceAll(final List<MediaEntity> newList) {
    _media
      ..clear()
      ..addAll(newList);
  }

  /// Return a modifiable copy of the internal list
  List<MediaEntity> asList() => List<MediaEntity>.from(_media);

  // Backward compat helpers (used by some steps)
  void addOrReplaceAt(final int index, final MediaEntity entity) {
    if (index >= 0 && index < _media.length) {
      _media[index] = entity;
    } else if (index == _media.length) {
      _media.add(entity);
    } else {
      throw RangeError.index(index, _media, 'index', null, _media.length);
    }
  }
}
