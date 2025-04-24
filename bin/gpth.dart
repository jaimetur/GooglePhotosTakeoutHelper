import 'dart:developer';
import 'dart:io';

import 'package:args/args.dart';
import 'package:console_bars/console_bars.dart';
import 'package:coordinate_converter/src/models/dms_coordinates_model.dart';
import 'package:gpth/date_extractors/date_extractor.dart';
import 'package:gpth/exif_writer.dart';
import 'package:gpth/extras.dart';
import 'package:gpth/folder_classify.dart';
import 'package:gpth/grouping.dart';
import 'package:gpth/interactive.dart' as interactive;
import 'package:gpth/media.dart';
import 'package:gpth/moving.dart';
import 'package:gpth/utils.dart';
import 'package:path/path.dart' as p;

/// ############################### READ ME #############################
// Okay, time to explain the structure of things here
// We create a list of Media objects, and fill it with everything we find
// in "year folders". Then, we play *mutably* with this list - fill Media's
// with guess DateTime's, remove duplicates from this list.
//
// No shitheads, you did not overhear - we *mutate* the whole list and objects
// inside it. This is not Flutter-ish, but it's not Flutter - it's a small
// simple script, and this the best solution 😎💯

// Okay, more details on what will happen here:
// 1. We find *all* media in either year folders or album folders.
//    Every single file will be a separate [Media] object.
//    If given [Media] was found in album folder, it will have it noted
// 2. We [removeDuplicates] - if two files in same/null album have same hash,
//    one will be removed. Note that there are still duplicates from different
//    albums left. This is intentional
// 3. We guess their dates. Functions in [dateExtractors] are used in order
//    from most to least accurate
// 4. Now we [findAlbums]. This will analyze [Media] that have same hashes,
//    and leave just one with all [albums] filled.
//    final exampleMedia = [
//      Media('lonePhoto.jpg'),
//      Media('photo1.jpg, albums=null),
//      Media('photo1.jpg, albums={Vacation}),
//      Media('photo1.jpg, albums={Friends}),
//    ];
//    findAlbums(exampleMedia);
//    exampleMedia == [
//      Media('lonePhoto.jpg'),
//      Media('photo1.jpg, albums={Vacation, Friends}),
//    ];
//
//    Steps for all the major functionality have been added. You should always add to the output the step it originated from.
//    This is done to make it easier to debug and understand the flow of the program.
//    To find your way around search for "Step X" in the code.

/// ##############################################################
/// This is the help text that will be shown when user runs gpth --help

const String helpText = '''GooglePhotosTakeoutHelper v$version - The Dart successor

gpth is ment to help you with exporting your photos from Google Photos.

First, go to https://takeout.google.com/ , deselect all and select only Photos.
When ready, download all .zips, and extract them into *one* folder.
(Auto-extracting works only in interactive mode)

Then, run: gpth --input "folder/with/all/takeouts" --output "your/output/folder"
...and gpth will parse and organize all photos into one big chronological folder
''';
const int barWidth = 40;

/// ##############################################################
/// This is the main function that will be run when user runs gpth

void main(final List<String> arguments) async {
  final ArgParser parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addOption(
      'fix',
      help: 'Folder with any photos to fix dates. \n'
          'This skips whole "GoogleTakeout" procedure. \n'
          'It is here because gpth has some cool heuristics to determine date \n'
          'of a photo, and this can be handy in many situations :)\n',
    )
    ..addFlag('interactive',
        help: 'Use interactive mode. Type this in case auto-detection fails, \n'
            'or you *really* want to combine advanced options with prompts\n')
    ..addOption('input',
        abbr: 'i', help: 'Input folder with *all* takeouts *extracted*.\n')
    ..addOption('output',
        abbr: 'o', help: 'Output folder where all photos will land\n')
    ..addOption(
      'albums',
      help: 'What to do about albums?',
      allowed: interactive.albumOptions.keys,
      allowedHelp: interactive.albumOptions,
      defaultsTo: 'shortcut',
    )
    ..addOption(
      'divide-to-dates',
      help: 'Divide output to folders by nothing/year/month/day\n',
      allowed: <String>['0', '1', '2', '3'],
      defaultsTo: '0',
    )
    ..addFlag('skip-extras', help: 'Skip extra images (like -edited etc)\n')
    ..addFlag(
      'guess-from-name',
      help: 'Try to guess file dates from their names\n',
      defaultsTo: true,
    )
    ..addFlag(
      'copy',
      help: 'Copy files instead of moving them.\n'
          'This is usually slower, and uses extra space, \n'
          "but doesn't break your input folder\n",
    )
    ..addFlag(
      'modify-json',
      help: 'Delete the "supplemental-metadata" suffix from \n'
          '.json files to ensure that script works correctly\n',
      defaultsTo: true,
    )
    ..addFlag('transform-pixel-mp',
        help: 'Transform Pixel .MP or .MV extensions to ".mp4"\n')
    ..addFlag('update-creation-time',
        help: 'Set creation time equal to the last \n'
            'modification date at the end of the program. \n'
            'Only Windows supported\n')
    ..addFlag('write-exif',
        help:
            'Experimental functionality to Write EXIF data to files\n'); //TODO Update when EXIF-write is stable
  final Map<String, dynamic> args = <String, dynamic>{};
  try {
    final ArgResults res = parser.parse(arguments);
    for (final String key in res.options) {
      args[key] = res[key];
    }
    interactive.indeed =
        args['interactive'] || (res.arguments.isEmpty && stdin.hasTerminal);
  } on FormatException catch (e) {
    // don't print big ass trace
    error('$e');
    quit(2);
  } catch (e) {
    // any other exceptions (args must not be null)
    error('$e');
    quit(100);
  }

  if (args['help']) {
    print(helpText);
    print(parser.usage);
    return;
  }

  /// ##############################################################
  /// Here the Script asks interactively to fill all arguments

  if (interactive.indeed) {
    // greet user
    await interactive.greet();
    print('');
    // @Deprecated('Interactive unzipping is suspended for now!')
    // final zips = await interactive.getZips(); //TODO: Add functionality to unzip files again
    late Directory inDir;
    try {
      inDir = await interactive.getInputDir();
    } catch (e) {
      print('Hmm, interactive selecting input dir crashed... \n'
          "it looks like you're running in headless/on Synology/NAS...\n"
          "If so, you have to use cli options - run 'gpth --help' to see them");
      exit(69);
    }
    print('');
    final Directory out = await interactive.getOutput();
    print('');
    args['divide-to-dates'] = await interactive.askDivideDates();
    print('');
    args['modify-json'] = await interactive.askModifyJson();
    print('');
    args['albums'] = await interactive.askAlbums();
    print('');
    args['transform-pixel-mp'] = await interactive.askTransformPixelMP();
    print('');
    if (Platform.isWindows) {
      //Only in windows is going to ask
      args['update-creation-time'] = await interactive.askChangeCreationTime();
      print('');
    }

    // @Deprecated('Interactive unzipping is suspended for now!')
    // // calculate approx space required for everything
    // final cumZipsSize = zips.map((e) => e.lengthSync()).reduce((a, b) => a + b);
    // final requiredSpace = (cumZipsSize * 2) + 256 * 1024 * 1024;
    // await interactive.freeSpaceNotice(requiredSpace, out); // and notify this
    // print('');
    //
    // final unzipDir = Directory(p.join(out.path, '.gpth-unzipped'));
    // args['input'] = unzipDir.path;
    args['input'] = inDir.path;
    args['output'] = out.path;
    //
    // await interactive.unzip(zips, unzipDir);
    // print('');
  }

  // elastic list of extractors - can add/remove with cli flags
  // those are in order of reliability -
  // if one fails, only then later ones will be used
  final List<DateTimeExtractor> dateExtractors = <DateTimeExtractor>[
    jsonDateTimeExtractor,
    exifDateTimeExtractor,
    if (args['guess-from-name']) guessExtractor,
    // this is potentially *dangerous* - see:
    // https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/175
    (final File f) => jsonDateTimeExtractor(f, tryhard: true),
  ];

  /// ##############################################################
  /// ######################## Occasional Fix mode #################
  /// This is a special mode that will go through all files in the given folder
  /// and try to set each file to correct lastModified value.
  /// This is useful for files that have been moved or copied and have lost their original lastModified value.
  /// This is not a part of the main functionality of the script, but it can be accessed by using the --fix flag.
  /// It is not recommended to use this mode unless you know what you are doing.

  if (args['fix'] != null) {
    // i was thing if not to move this to outside file, but let's leave for now
    print('========== FIX MODE ==========');
    print('I will go through all files in folder that you gave me');
    print('and try to set each file to correct lastModified value');
    final Directory dir = Directory(args['fix']);
    if (!await dir.exists()) {
      error("directory to fix doesn't exist :/");
      quit(11);
    }
    int set = 0;
    int notSet = 0;
    await for (final File file in dir.list(recursive: true).wherePhotoVideo()) {
      DateTime? date;
      for (final DateTimeExtractor extractor in dateExtractors) {
        date = await extractor(file);
        if (date != null) {
          await file.setLastModified(date);
          set++;
          break;
        }
      }
      if (date == null) notSet++;
    }
    print('FINISHED!');
    print('$set set✅');
    print('$notSet not set❌');
    return;
  }

  /// ################# Fix mode END ###############################
  /// ##############################################################
  /// ##### Parse all options and check if alright #################

  if (args['input'] == null) {
    error('No --input folder specified :/');
    quit(10);
  }
  if (args['output'] == null) {
    error('No --output folder specified :/');
    quit(10);
  }
  final Directory input = Directory(args['input']);
  final Directory output = Directory(args['output']);
  if (!await input.exists()) {
    error('Input folder does not exist :/');
    quit(11);
  }
  // all of this logic is to prevent user easily blowing output folder
  // by running command two times
  if (await output.exists() &&
      !await output
          .list()
          // allow input folder to be inside output
          .where((final FileSystemEntity e) => p.absolute(e.path) != p.absolute(args['input']))
          .isEmpty) {
    if (await interactive.askForCleanOutput()) {
      await for (final FileSystemEntity file in output
          .list()
          // delete everything except input folder if there
          .where((final FileSystemEntity e) => p.absolute(e.path) != p.absolute(args['input']))) {
        await file.delete(recursive: true);
      }
    }
  }
  await output.create(recursive: true);

  /// ##############################################################
  // ##### Really important global variables #######################

  // Big global media list that we'll work on
  final List<Media> media = <Media>[];

  // All "year folders" that we found
  final List<Directory> yearFolders = <Directory>[];

  // All album folders - that is, folders that were aside yearFolders and were
  // not matching "Photos from ...." name
  final List<Directory> albumFolders = <Directory>[];

  /// ##############################################################
  /// #### Here we start the actual work ###########################
  /// ##############################################################
  /// ################# STEP 1 #####################################
  /// ##### Fixing JSON files (if needed) ##########################
  if (args['modify-json']) {
    print(
        '[Step 1/8] Fixing JSON files. Removing suffix (this may take some time)...');
    await renameIncorrectJsonFiles(input);
  }

  /// ##############################################################
  /// ################# STEP 2 #####################################
  /// ##### Find literally *all* photos/videos and add to list #####

  print('[Step 2/8] Searching for everything in input folder...');

  // recursive=true makes it find everything nicely even if user id dumb 😋
  await for (final Directory d in input.list(recursive: true).whereType<Directory>()) {
    if (isYearFolder(d)) {
      yearFolders.add(d);
    } else if (await isAlbumFolder(d)) {
      albumFolders.add(d);
    }
  }
  for (final Directory f in yearFolders) {
    await for (final File file in f.list().wherePhotoVideo()) {
      media.add(Media(<String?, File>{null: file}));
    }
  }
  for (final Directory a in albumFolders) {
    await for (final File file in a.list().wherePhotoVideo()) {
      media.add(Media(<String?, File>{albumName(a): file}));
    }
  }

  if (media.isEmpty) {
    await interactive.nothingFoundMessage();
    // @Deprecated('Interactive unzipping is suspended for now!')
    // if (interactive.indeed) {
    //   print('([interactive] removing unzipped folder...)');
    //   await input.delete(recursive: true);
    // }
    quit(13);
  }

  /// ##############################################################
  /// ################# STEP 3 #####################################
  /// ##### Finding and removing duplicates ########################

  print('[Step 3/8] Finding duplicates...');

  final int countDuplicates = removeDuplicates(media, barWidth);

  /// ##############################################################

  /// ##### Potentially skip extras #####

  if (args['skip-extras']) {
    print('[Step 3/8] Finding "extra" photos (-edited etc)');
  }
  final int countExtras = args['skip-extras'] ? removeExtras(media) : 0;

  /// ##############################################################
  /// ################# STEP 4 #####################################
  /// ##### Extracting DateTime through Extractors #################

  // NOTE FOR MYSELF/whatever:
  // I placed extracting dates *after* removing duplicates.
  // Today i thought to myself - shouldn't this be reversed?
  // Finding correct date is our *biggest* priority, and duplicate that we just
  // removed might have been the chosen one
  //
  // But on the other hand, duplicates must be hash-perfect, so they contain
  // same exifs, and we can just compare length of their names - in 9999% cases,
  // one with shorter name will have json and others will not 🤷
  // ...and we would potentially waste a lot of time searching for all of their
  //    jsons
  // ...so i'm leaving this like that 😎
  //
  // Ps. BUT i've put album merging *after* guess date - notes below

  /// ##### Extracting/predicting dates using given extractors #####

  final FillingBar barExtract = FillingBar(
    total: media.length,
    desc: '[Step 4/8] Extracting dates from files',
    width: barWidth,
  );
  for (int i = 0; i < media.length; i++) {
    int q = 0;
    for (final DateTimeExtractor extractor in dateExtractors) {
      final DateTime? date = await extractor(media[i].firstFile);
      if (date != null) {
        media[i].dateTaken = date;
        media[i].dateTakenAccuracy = q;
        barExtract.increment();
        break;
      }
      // increase this every time - indicate the extraction gets more shitty
      q++;
    }
    if (media[i].dateTaken == null) {
      // only visible in debug mode. Normal user does not care about this. Just high level about the number at the end.
      log("\n[Step 4/8] Can't get date on ${media[i].firstFile.path}");
    }
  }
  print('');

  /// ##############################################################
  /// ################# STEP 5 #####################################
  /// ##### Json Coordinates and extracted DateTime to EXIF ########

  // In this part, we will write coordinates and dates to EXIF data of the files.
  // Currently supported file formats: JPG, PNG/Animated APNG, GIF/Animated GIF, BMP, TIFF, TGA, PVR, ICO.
  // This is done after the dates of files have been defined, because here we have to write the files to disk again and before
  // the files are moved to the output folder, to avoid shortcuts/symlinks problems.

  int ccounter = 0; //Counter for coordinates in EXIF data set
  if (args['write-exif']) {
    final FillingBar barJsonToExifExtractor = FillingBar(
      total: media.length,
      desc:
          '[Step 5/8] Getting EXIF data from JSON files and applying it to files',
      width: barWidth,
    );

    for (int i = 0; i < media.length; i++) {
      final File currentFile = media[i].firstFile;

      final DMSCoordinates? coords = await jsonCoordinatesExtractor(currentFile);
      if (coords != null) {
        //If coordinates were found in json, write them to exif
        if (await writeGpsToExif(coords, currentFile)) {
          ccounter++;
        }
      } else {
        log("\n[Step 5/8] Can't get coordinates on ${media[i].firstFile.path}");
      }
      if (media[i].dateTaken != null) {
        //If date was found before through one of the extractors, write it to exif
        await writeDateTimeToExif(media[i].dateTaken!, currentFile);
      }

      barJsonToExifExtractor.increment();
    }
    print('');
  } else {
    print(
        '[Step 5/8] Skipping writing EXIF data to files (experimental), because --write-exif flag was not set.'); //TODO Update when EXIF-write is stable
  }

  /// ##############################################################
  /// ################# STEP 6 #####################################
  /// ##### Find albums and rename .MP and .MV extensions ##########

  // I'm placing merging duplicate Media into albums after guessing date for
  // each one individually, because they are in different folder.
  // I wish that, thanks to this, we may find some jsons in albums that would
  // be broken in shithole of big-ass year folders

  print(
      '[Step 6/8] Finding albums (this may take some time, dont worry :) ...');
  findAlbums(media);

  /// ##############################################################

  // Change Pixel Motion Photos extension to .mp4 using a list of Medias.
  // This is done after the dates of files have been defined, and before
  // the files are moved to the output folder, to avoid shortcuts/symlinks problems
  if (args['transform-pixel-mp']) {
    print(
        '[Step 6/8] Changing .MP or .MV extensions to .mp4 (this may take some time) ...');
    await changeMPExtensions(media, '.mp4');
  } else {
    print('[Step 6/8] Skipped changing .MP or .MV extensions to .mp4');
  }
  print('');

  /// ##############################################################

  // https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/261
  // If a media is not in a year album (there is no null key) it establishes
  // one from an album as a null key to copy it to ALL_PHOTOS correctly.
  // This will move the album file to ALL_PHOTOS and create the shortcut to
  // the output album folder (if shortcut option is selected).
  // (The inverse will happen if the inverse-shortcut option is selected).
  // If album mode is set to *duplicate-copy* it will not proceed
  // to avoid moving the same file twice (which would throw an exception)
  if (args['albums'] != 'duplicate-copy') {
    for (final Media m in media) {
      final File? fileWithKey1 = m.files[null];
      if (fileWithKey1 == null) {
        m.files[null] = m.files.values.first;
      }
    }
  }

  /// ##############################################################
  /// ################# STEP 7 #####################################
  /// ##### Copy/move files to actual output folder ################

  final FillingBar barCopy = FillingBar(
    total: outputFileCount(media, args['albums']),
    desc:
        "[Step 7/8] ${args['copy'] ? 'Copying' : 'Moving'} photos to output folder",
    width: barWidth,
  );
  await moveFiles(
    media,
    output,
    copy: args['copy'],
    divideToDates: args['divide-to-dates'] is num
        ? args['divide-to-dates']
        : num.parse(args['divide-to-dates']),
    albumBehavior: args['albums'],
  ).listen((final _) => barCopy.increment()).asFuture();
  print('[Step 7/8] Done moving/copying files!');

  // @Deprecated('Interactive unzipping is suspended for now!')
  // // remove unzipped folder if was created
  // if (interactive.indeed) {
  //   print('Removing unzipped folder...');
  //   await input.delete(recursive: true);
  // }

  /// ##############################################################
  /// ################# STEP 8 #####################################
  /// ##### Update creation time (Windows only) ####################

  if (args['update-creation-time']) {
    print(
        '[Step 8/8] Updating creation time of files to match their modified time in output folder ...');
    await updateCreationTimeRecursively(output);
    print('');
    print('=' * barWidth);
  } else {
    print('[Step 8/8] Skipping: Updating creation time (Windows only)');
  }
  print('');

  /// ##############################################################
  /// ################# END ########################################

  print('=' * barWidth);
  print('DONE! FREEEEEDOOOOM!!!');
  if (countDuplicates > 0) print('Skipped $countDuplicates duplicates');
  if (ccounter > 0) print('Set $ccounter coordinates in EXIF data');
  if (args['skip-extras']) print('Skipped $countExtras extras');
  final int countPoop = media.where((final Media e) => e.dateTaken == null).length;
  if (countPoop > 0) {
    print("Couldn't find date for $countPoop photos/videos :/");
  }

  print(
    "Last thing - I've spent *a ton* of time on this script - \n"
    'if I saved your time and you want to say thanks, you can send me a tip:\n'
    'https://www.paypal.me/TheLastGimbus\n'
    'https://ko-fi.com/thelastgimbus\n'
    'Thank you ❤',
  );
  print('=' * barWidth);
  quit(0);
}
