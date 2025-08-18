// ignore_for_file: non_constant_identifier_names

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:exif_reader/exif_reader.dart';
import 'package:mime/mime.dart';

import '../../../../infrastructure/exiftool_service.dart';
import '../../../../shared/constants.dart';
import '../../../../shared/constants/exif_constants.dart';
import '../../core/global_config_service.dart';
import '../../core/logging_service.dart';

/// Service for extracting dates from EXIF data
class ExifDateExtractor with LoggerMixin {
  /// Creates a new instance of ExifDateExtractor
  ExifDateExtractor(this.exiftool);

  /// The ExifTool service instance (can be null if ExifTool is not available)
  final ExifToolService? exiftool;

  // ────────────────────────────────────────────────────────────────────────────
  // Tiny instrumentation (per-process static counters)
  // Call ExifDateExtractor.dumpStats() to print & optionally reset.
  // ────────────────────────────────────────────────────────────────────────────
  static int _total = 0;
  static int _videoDirect = 0;
  static int _mimeNativeSupported = 0;

  static int _nativeHeadReads = 0;
  static int _nativeFullReads = 0;

  static int _nativeHit = 0;        // native returned a DateTime
  static int _nativeMiss = 0;       // native returned null

  static int _fallbackTried = 0;    // native miss + fallback enabled
  static int _fallbackHit = 0;      // fallback returned a DateTime

  static int _unsupportedDirect = 0;       // unsupported/unknown MIME → ExifTool path taken
  static int _exiftoolDirectHit = 0;       // ExifTool on direct path returned a DateTime
  static int _exiftoolFail = 0;            // ExifTool returned null (any path)

/// Print counters; pass reset:true to zero them after printing.
