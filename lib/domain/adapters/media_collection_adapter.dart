import '../../media.dart';
import '../entities/media_entity.dart';
import '../models/media_entity_collection.dart';

/// Adapter that bridges MediaCollection to use MediaEntityCollection internally
///
/// This provides backward compatibility while transitioning the collection
/// to use immutable MediaEntity objects internally for better performance.
class MediaCollectionAdapter {
  MediaCollectionAdapter() : _entityCollection = MediaEntityCollection();

  final MediaEntityCollection _entityCollection;

  /// Get all media as legacy Media objects
  List<Media> get media =>
      _entityCollection.media.map(Media.fromEntity).toList();

  /// Get the number of media items
  int get length => _entityCollection.length;

  /// Check if collection is empty
  bool get isEmpty => _entityCollection.isEmpty;
  bool get isNotEmpty => _entityCollection.isNotEmpty;

  /// Add a Media object (converts to MediaEntity internally)
  void add(final Media media) {
    _entityCollection.add(media.entity);
  }

  /// Add multiple Media objects
  void addAll(final Iterable<Media> mediaList) {
    final entities = mediaList.map((final media) => media.entity);
    _entityCollection.addAll(entities);
  }

  /// Remove a Media object
  bool remove(final Media media) => _entityCollection.remove(media.entity);

  /// Clear all media
  void clear() {
    _entityCollection.clear();
  }

  /// Access media by index (returns legacy Media)
  Media operator [](final int index) =>
      Media.fromEntity(_entityCollection[index]);

  /// Set media at index (converts to MediaEntity)
  void operator []=(final int index, final Media media) {
    _entityCollection[index] = media.entity;
  }

  /// Get direct access to the entity collection for modern operations
  MediaEntityCollection get entityCollection => _entityCollection;

  /// Update an entity directly (for performance-critical operations)
  void updateEntity(final int index, final MediaEntity entity) {
    _entityCollection[index] = entity;
  }

  /// Bulk update entities
  void updateEntities(final List<MediaEntity> entities) {
    _entityCollection.clear();
    _entityCollection.addAll(entities);
  }
}
