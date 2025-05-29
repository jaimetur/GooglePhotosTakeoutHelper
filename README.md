# Google Photos Takeout Helper 📸

[![AUR](https://img.shields.io/aur/version/gpth-bin?logo=arch-linux)](https://aur.archlinux.org/packages/gpth-bin)
[![Downloads](https://img.shields.io/github/downloads/TheLastGimbus/GooglePhotosTakeoutHelper/total?label=downloads)](https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/releases/)
[![Issues](https://img.shields.io/github/issues-closed/TheLastGimbus/GooglePhotosTakeoutHelper?label=resolved%20issues)](https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues)

Transform your chaotic Google Photos Takeout into organized photo libraries with proper dates, albums, and metadata.

## What This Tool Does

When you export photos from Google Photos using [Google Takeout](https://takeout.google.com/), you get a mess of folders with weird `.json` files and broken timestamps. This tool:

- ✅ **Organizes photos chronologically** with correct dates
- ✅ **Restores album structure** with multiple handling options
- ✅ **Fixes timestamps** from JSON metadata and EXIF data
- ✅ **Writes GPS coordinates and timestamps** back to media files
- ✅ **Removes duplicates** automatically
- ✅ **Handles special formats** (HEIC, Motion Photos, etc.)

## Quick Start

### 1. Get Your Photos from Google Takeout

1. Go to [Google Takeout](https://takeout.google.com/)
2. Deselect all, then select only **Google Photos**
3. Download all ZIP files

### 2. Extract and Merge

Unzip all files and merge them so you have one unified "Takeout" folder.

**⚠️ Keep the original ZIPs as backup!**

### 3. Install Prerequisites

**ExifTool** (required for metadata handling):

- **Windows**: Download from [exiftool.org](https://exiftool.org/) and rename `exiftool(-k).exe` to `exiftool.exe`
  ```bash
  # Or with Chocolatey:
  choco install exiftool
  ```
- **Mac**: 
  ```bash
  brew install exiftool
  ```
- **Linux**: 
  ```bash
  sudo apt install libimage-exiftool-perl
  ```

### 4. Download and Run GPTH

1. Download the latest executable from [releases](https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/releases)
2. **Interactive Mode** (recommended for beginners):
   - Windows: Double-click `gpth.exe`
   - Mac/Linux: Run `./gpth-macos` or `./gpth-linux` in terminal
3. Follow the prompts to select input/output folders and options

## Album Handling Options

GPTH offers several ways to handle your Google Photos albums:

### 🔗 Shortcut (Recommended)
Creates shortcuts/symlinks from album folders to files in `ALL_PHOTOS`. Saves space while maintaining organization.

### 📁 Duplicate Copy
Creates actual file copies in both `ALL_PHOTOS` and album folders. Uses more space but works across all systems.

### 🔄 Reverse Shortcut
Files stay in album folders, shortcuts created in `ALL_PHOTOS`. Good for album-centric organization.

### 📄 JSON
Single `ALL_PHOTOS` folder plus `albums-info.json` with metadata. Most space-efficient, programmatically accessible.

### ❌ Nothing
Ignores albums entirely, creates only `ALL_PHOTOS`. Simplest option.

## Command Line Usage

For automation, headless systems, or advanced users:

```bash
gpth --input "/path/to/takeout" --output "/path/to/organized" --albums "shortcut"
```

### Core Arguments

| Argument | Description |
|----------|-------------|
| `--input`, `-i` | Input folder containing extracted Takeout |
| `--output`, `-o` | Output folder for organized photos |
| `--albums` | Album handling: `shortcut`, `duplicate-copy`, `reverse-shortcut`, `json`, `nothing` |
| `--help`, `-h` | Show help and exit |

### Organization Options

| Argument | Description |
|----------|-------------|
| `--divide-to-dates` | Folder structure: `0`=one folder, `1`=by year, `2`=year/month, `3`=year/month/day |
| `--copy` | Copy files instead of moving (safer but uses more space) |
| `--skip-extras` | Skip extra images like "-edited" versions |

### Metadata & Processing

| Argument | Description |
|----------|-------------|
| `--write-exif` | Write GPS coordinates and dates to EXIF metadata |
| `--modify-json` | Fix JSON files with "supplemental-metadata" suffix |
| `--transform-pixel-mp` | Convert Pixel Motion Photos (.MP/.MV) to .mp4 |
| `--guess-from-name` | Extract dates from filenames (enabled by default) |
| `--update-creation-time` | Sync creation time with modified time (Windows only) |
| `--limit-filesize` | Skip files larger than 64MB (for low-RAM systems) |

### Other Options

| Argument | Description |
|----------|-------------|
| `--interactive` | Force interactive mode |
| `--verbose`, `-v` | Show detailed logging output |
| `--fix` | Special mode: fix dates in any folder (not just Takeout) |

### Example Commands

**Basic usage:**
```bash
gpth --input "~/Takeout" --output "~/Photos" --albums "shortcut"
```

**Copy files with year folders:**
```bash
gpth --input "~/Takeout" --output "~/Photos" --copy --divide-to-dates 1
```

**Full metadata processing:**
```bash
gpth --input "~/Takeout" --output "~/Photos" --write-exif --transform-pixel-mp --albums "duplicate-copy"
```

**Fix dates in existing folder:**
```bash
gpth --fix "~/existing-photos"
```

## Features & Capabilities

### 📅 Date Extraction
GPTH uses multiple methods to determine correct photo dates:
1. **JSON metadata** (most accurate)
2. **EXIF data** from photo files
3. **Filename patterns** (Screenshot_20190919-053857.jpg, etc.)
4. **Aggressive matching** for difficult cases

### 🔍 Duplicate Detection
Removes identical files using content hashing, keeping the best copy (shortest filename, most metadata).

### 🌍 GPS Coordinates & Timestamps
Extracts location data and timestamps from JSON files and writes them to media file EXIF data for compatibility with photo viewers and other applications.

### 🎯 Smart File Handling
- **Motion Photos**: Pixel .MP/.MV files can be converted to .mp4
- **HEIC/RAW support**: Handles modern camera formats
- **Unicode filenames**: Properly handles international characters
- **Large files**: Optional size limits for resource-constrained systems

### 📁 Flexible Organization
- Multiple date-based folder structures
- Preserve or reorganize album structure
- Copy or move files (safety vs. efficiency)

## Installation

### Pre-built Binaries
Download from [releases page](https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/releases)

### Package Managers
- **Arch Linux**: `yay -S gpth-bin`

### Building from Source
```bash
git clone https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper.git
cd GooglePhotosTakeoutHelper
dart pub get
dart compile exe bin/gpth.dart -o gpth
```

## Troubleshooting

### Common Issues

**"No photos found"**: Make sure you have a unified Takeout folder structure with "Photos from YYYY" folders.

**Permission errors**: Run with administrator/sudo privileges if moving files across drives.

**Memory issues**: Use `--limit-filesize` for systems with limited RAM.

**Encoding errors**: Some JSON files may have encoding issues; the tool handles most cases automatically.

### Platform-Specific Notes

**Windows**: Creation time updates require administrator privileges.

**macOS**: You may need to allow the executable in Security & Privacy settings.

**Linux**: Ensure ExifTool is installed for full functionality.

## After Migration

### Recommended Apps
- **[Immich](https://immich.app/)**: Self-hosted Google Photos alternative
- **[PhotoPrism](https://photoprism.org/)**: AI-powered photo management
- **[Syncthing](https://syncthing.net/)**: Sync photos across devices while preserving dates

### Android Users
Standard file managers reset photo dates when moving files. Use **Simple Gallery** to preserve timestamps.

## Support This Project

If GPTH saved you time and frustration, consider supporting development:

[![PayPal](https://img.shields.io/badge/Donate-PayPal-blue.svg?logo=paypal&style=for-the-badge)](https://www.paypal.me/TheLastGimbus)
[![Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/A0A6HO71P)
[![Liberapay](https://liberapay.com/assets/widgets/donate.svg)](https://liberapay.com/TheLastGimbus/donate)

## Related Projects

- **[Google Keep Exporter](https://github.com/vHanda/google-keep-exporter)**: Export Google Keep notes to Markdown
- **[PhotoMigrator](https://github.com/jaimetur/PhotoMigrator)**: Uses GPTH 4.x.x which has been designed to Interact and Manage different Photos Cloud services, and allow users to do an Automatic Migration from one Photo Cloud service to other or from one account to a new account of the same Photo Cloud service.

---

**Note**: This tool moves files by default to avoid using extra disk space. Always keep backups of your original Takeout files!
