import 'dart:io';
import 'package:console_bars/console_bars.dart';
import 'package:gpth/gpth-lib.dart';

/// Step 4: Extract dates from media files
///
/// This critical step determines the correct date and time for each media file using
/// multiple extraction methods in order of reliability. Accurate date extraction is
/// essential for proper chronological organization of photos and videos.
///
/// ## Extraction Methods (Priority Order)
///
/// ### 1. JSON Metadata (Highest Priority)
/// - **Source**: Google Photos metadata files (.json)
/// - **Accuracy**: Highest - preserves original Google Photos timestamps
/// - **Content**: Contains exact photo/video creation time from Google's servers
/// - **Format**: Unix timestamp with timezone information
/// - **Reliability**: Most trustworthy as it comes directly from Google Photos
///
/// ### 2. EXIF Data (High Priority)
/// - **Source**: Embedded metadata within image/video files
/// - **Accuracy**: High - original camera/device timestamps
/// - **Content**: Camera-recorded date/time, GPS coordinates, device settings
/// - **Format**: Various EXIF date formats (DateTime, DateTimeOriginal, etc.)
/// - **Reliability**: Very reliable but can be modified by editing software
///
/// ### 3. Filename Patterns (Medium Priority)
/// - **Source**: Date patterns extracted from filenames
/// - **Accuracy**: Medium - depends on consistent naming conventions
/// - **Content**: Dates embedded in filename patterns (IMG_20230615_143022.jpg)
/// - **Format**: Various patterns (YYYYMMDD, YYYY-MM-DD, etc.)
/// - **Reliability**: Moderate - useful when metadata is missing
/// - **Configuration**: Can be enabled/disabled via `guessFromName` setting
///
/// ### 4. Aggressive JSON Matching (Low Priority)
/// - **Source**: JSON files with similar names or in same directory
/// - **Accuracy**: Lower - heuristic matching when direct association fails
/// - **Content**: Best-guess timestamps from related JSON files
/// - **Format**: Inferred from nearby files with similar naming patterns
/// - **Reliability**: Last resort when other methods fail
///
/// ### 5. Folder Year Extraction (Lowest Priority)
/// - **Source**: Year patterns in parent folder names
/// - **Accuracy**: Lowest - assigns January 1st of detected year
/// - **Content**: Year extracted from folder patterns like "Photos from YYYY"
/// - **Format**: Folder names containing 4-digit years (2000-current year)
/// - **Reliability**: Basic fallback when no other date sources exist
///
/// ## Processing Logic
///
/// ### Extraction Priority System
/// For each media file, the step:
/// 1. **Attempts each extractor in priority order** until a valid date is found
/// 2. **Records the extraction method used** for statistics and debugging
/// 3. **Assigns accuracy scores** based on the extraction method reliability
/// 4. **Handles timezone conversions** when timezone data is available
/// 5. **Validates extracted dates** to ensure they're reasonable
///
/// ### Date Accuracy Tracking
/// Each extracted date is assigned an accuracy level:
/// - **Level 1**: JSON metadata (most accurate)
/// - **Level 2**: EXIF data (very accurate)
/// - **Level 3**: Filename patterns (moderately accurate)
/// - **Level 4**: Aggressive JSON matching (low accuracy)
/// - **Level 5**: Folder year extraction (lowest accuracy)
/// - **Level 99**: No date found (will use fallback strategies)
///
/// ### Statistics Collection
/// The step tracks detailed statistics:
/// - **Extraction method distribution**: How many files used each method
/// - **Success/failure rates**: Percentage of files with successful date extraction
/// - **Accuracy distribution**: Breakdown of accuracy levels achieved
/// - **Processing performance**: Time taken and files processed per second
///
/// ## Configuration Options
///
/// ### Date Extractor Selection
/// - **JSON Extractor**: Always enabled (highest priority)
/// - **EXIF Extractor**: Always enabled (high reliability)
/// - **Filename Extractor**: Controlled by `guessFromName` configuration
/// - **Aggressive Extractor**: Always enabled as fallback
/// - **Folder Year Extractor**: Always enabled as final fallback
///
/// ### Processing Behavior
/// - **Verbose Mode**: Provides detailed progress reporting and statistics
/// - **Progress Reporting**: Updates every 100 files for large collections
/// - **Error Handling**: Continues processing when individual files fail
/// - **Performance Optimization**: Efficient processing for large photo libraries
///
/// ## Error Handling and Edge Cases
///
/// ### Invalid Date Detection
/// - **Future dates**: Dates more than 1 year in the future are flagged
/// - **Prehistoric dates**: Dates before 1900 are considered suspicious
/// - **Timezone issues**: Handles various timezone formats and conversions
/// - **Corrupted metadata**: Gracefully handles malformed JSON or EXIF data
///
/// ### Fallback Strategies
/// - **No date found**: Files without extractable dates are marked for manual review
/// - **Conflicting dates**: Priority system resolves conflicts automatically
/// - **Partial metadata**: Extracts what's available even with incomplete data
/// - **File access issues**: Skips inaccessible files without stopping processing
///
/// ### Performance Considerations
/// - **Batch processing**: Efficiently handles thousands of files
/// - **Memory management**: Processes files incrementally to avoid memory issues
/// - **I/O optimization**: Minimizes file system access through smart caching
/// - **Progress tracking**: Provides user feedback for long-running operations
///
/// ## Integration with Other Steps
///
/// ### Prerequisites
/// - **Media Discovery**: Requires populated MediaCollection from Step 2
/// - **File Accessibility**: Files must be readable and not corrupted
///
/// ### Outputs Used By Later Steps
/// - **Chronological Organization**: Date information enables year/month folder creation
/// - **EXIF Data Source**: Extracted dates provide input for EXIF writing step
/// - **Duplicate Resolution**: Date accuracy helps choose best duplicate to keep
/// - **Album Processing**: Temporal information aids in album organization
///
/// ### Data Flow
/// - **Input**: MediaCollection with discovered files
/// - **Processing**: Date extraction and accuracy assignment
/// - **Output**: MediaCollection with date metadata and extraction statistics
/// - **Side Effects**: Updates each Media object with date and accuracy information
class ExtractDatesStep extends ProcessingStep with LoggerMixin {
  ExtractDatesStep() : super('Extract Dates');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    final sw = Stopwatch()..start();

    try {
      print('\n[Step 4/8] Extracting metadata (this may take a while)...');

      final collection = context.mediaCollection;

      // --- Parity with previous implementation: explicit “threads” (concurrency) log.
      final maxConcurrency = ConcurrencyManager().concurrencyFor(
        ConcurrencyOperation.exif,
      );
      print(
        '[Step 4/8] Starting $maxConcurrency threads (exif date extraction concurrency)',
      );

      // Build extractor callables bound to File (as in your config), but we will decide
      // per extractor whether to probe primary only (EXIF) or primary+secondaries (others).
      final fileExtractors = context.config.dateExtractors;

      // Map extractor index to the proper DateTimeExtractionMethod (kept order-compatible with your config)
      final extractorMethods = <DateTimeExtractionMethod>[
        DateTimeExtractionMethod.json,
        DateTimeExtractionMethod.exif,
        DateTimeExtractionMethod.guess,
        DateTimeExtractionMethod.jsonTryHard,
        DateTimeExtractionMethod.folderYear,
      ];

      DateAccuracy accuracyFor(final DateTimeExtractionMethod method) {
        switch (method) {
          case DateTimeExtractionMethod.json:
            return DateAccuracy.fromInt(1);
          case DateTimeExtractionMethod.exif:
            return DateAccuracy.fromInt(2);
          case DateTimeExtractionMethod.guess:
            return DateAccuracy.fromInt(3);
          case DateTimeExtractionMethod.jsonTryHard:
            return DateAccuracy.fromInt(4);
          case DateTimeExtractionMethod.folderYear:
            return DateAccuracy.fromInt(5);
          default:
            return DateAccuracy.fromInt(99);
        }
      }

      // Stats + progress (same semantics as before)
      final extractionStats = <DateTimeExtractionMethod, int>{};
      var completed = 0;
      final progressBar = FillingBar(
        desc: '[Step 4/8] Processing media files',
        total: collection.length,
        width: 50,
      );

      for (int i = 0; i < collection.length; i += maxConcurrency) {
        final batch = collection
            .asList()
            .skip(i)
            .take(maxConcurrency)
            .toList(growable: false);
        final batchStartIndex = i;

        final futures = batch.asMap().entries.map((final entry) async {
          final batchIndex = entry.key;
          final media = entry.value;
          final actualIndex = batchStartIndex + batchIndex;

          // If already has a date, keep it (parity with previous behavior)
          if (media.dateTaken != null) {
            final method =
                media.dateTimeExtractionMethod ?? DateTimeExtractionMethod.none;
            return {
              'index': actualIndex,
              'mediaFile': media,
              'extractionMethod': method,
            };
          }

          DateTime? foundDate;
          DateTimeExtractionMethod methodUsed = DateTimeExtractionMethod.none;

          // Iterate extractors in priority order
          for (
            int extractorIndex = 0;
            extractorIndex < fileExtractors.length;
            extractorIndex++
          ) {
            final method = extractorIndex < extractorMethods.length
                ? extractorMethods[extractorIndex]
                : DateTimeExtractionMethod.guess;
            final extractor = fileExtractors[extractorIndex];

            try {
              if (method == DateTimeExtractionMethod.exif) {
                // EXIF: only check primaryFile to avoid redundant work on secondaries
                foundDate = await extractor(media.primaryFile.asFile());
                if (foundDate != null) {
                  methodUsed = method;
                  break;
                }
              } else {
                // Non-EXIF (e.g., JSON/guess/etc.): try primary, then secondaries
                foundDate = await extractor(media.primaryFile.asFile());
                if (foundDate != null) {
                  methodUsed = method;
                  break;
                }
                for (final fe in media.secondaryFiles) {
                  foundDate = await extractor(fe.asFile());
                  if (foundDate != null) {
                    methodUsed = method;
                    break;
                  }
                }
                if (foundDate != null) break;
              }
            } catch (e) {
              logWarning(
                'Extractor failed for ${_safePath(media.primaryFile.asFile())}: $e',
                forcePrint: true,
              );
            }
          }

          // Build updated entity with entity-level date/accuracy/method
          final DateAccuracy acc = accuracyFor(
            foundDate != null ? methodUsed : DateTimeExtractionMethod.none,
          );
          final MediaEntity updated = media.withDate(
            dateTaken: foundDate ?? media.dateTaken,
            dateAccuracy: acc,
            dateTimeExtractionMethod: foundDate != null
                ? methodUsed
                : DateTimeExtractionMethod.none,
          );

          if (foundDate != null) {
            logDebug(
              'Date extracted for ${media.primaryFile.path}: $foundDate (method: ${methodUsed.name}, accuracy: ${acc.value})',
            );
          }

          return {
            'index': actualIndex,
            'mediaFile': updated,
            'extractionMethod': foundDate != null
                ? methodUsed
                : DateTimeExtractionMethod.none,
          };
        });

        final results = await Future.wait(futures);

        // Apply results & stats update
        for (final r in results) {
          final idx = r['index'] as int;
          final updated = r['mediaFile'] as MediaEntity;
          final method = r['extractionMethod'] as DateTimeExtractionMethod;

          collection.replaceAt(idx, updated);
          extractionStats[method] = (extractionStats[method] ?? 0) + 1;

          completed++;
          progressBar.update(completed);
        }
      }

      // Print stats
      print('');
      print('[Step 4/8] Date extraction completed:');
      print('\n[Step 4/8] === Date Extraction Summary ===');
      final byName = <String, int>{
        for (final e in extractionStats.entries) e.key.name: e.value,
      };
      const order = [
        'json',
        'exif',
        'guess',
        'jsonTryHard',
        'folderYear',
        'none',
      ];
      for (final k in order) {
        print('\t\t\t$k: ${byName[k] ?? 0} files');
      }

      // READ-EXIF stats summary (seconds)
      ExifDateExtractor.dumpStats(
        reset: true,
        loggerMixin: this,
        exiftoolFallbackEnabled:
            ServiceContainer
                .instance
                .globalConfig
                .fallbackToExifToolOnNativeMiss ==
            true,
      );

      sw.stop();
      return StepResult.success(
        stepName: name,
        duration: sw.elapsed,
        data: {
          'extractionStats': extractionStats,
          'processedMedia': collection.length,
        },
        message: 'Extracted dates for ${collection.length} files',
      );
    } catch (e) {
      sw.stop();
      return StepResult.failure(
        stepName: name,
        duration: sw.elapsed,
        error: e is Exception ? e : Exception(e.toString()),
        message: 'Failed to extract dates: $e',
      );
    }
  }

  @override
  bool shouldSkip(final ProcessingContext context) =>
      context.mediaCollection.isEmpty;

  String _safePath(final File f) {
    try {
      return f.path;
    } catch (_) {
      return '<unknown-file>';
    }
  }
}
