# Clean Architecture Refactoring Plan

## Overview
This document outlines the refactoring plan to align the codebase with clean architecture principles, following the excellent patterns already established in the `domain/` folder.

## Current State Analysis

### ✅ **Well-Architected (Domain Folder)**
- Clear separation of concerns
- Proper dependency direction
- Single responsibility principle
- Testable design

### 🚨 **Critical Issues**

#### 1. `utils.dart` - God Object (883 lines)
**Problems:**
- Mixed responsibilities: file operations, platform detection, UI helpers, constants
- Global mutable state
- Platform-specific code mixed with business logic
- Hard to test and maintain

**Refactoring Actions:**
```
utils.dart (883 lines) → Split into:
├── domain/services/file_system_service.dart
├── domain/services/platform_detection_service.dart  
├── domain/models/performance_config_model.dart
├── infrastructure/disk_space_checker.dart
├── infrastructure/shortcut_creator.dart
└── shared/constants.dart
```

#### 2. Global State Variables
**Problems:**
```dart
bool isVerbose = false;
bool enforceMaxFileSize = false;
bool exifToolInstalled = false;
```

**Solution:**
- Move to `ProcessingConfig` model
- Use dependency injection
- Remove global mutation

### 🔥 **High Priority Issues**

#### 3. `media.dart` - Anemic Domain Model
**Problems:**
- Business logic mixed with data structure
- Mutable state without proper encapsulation
- Missing domain behavior

**Refactoring Actions:**
```
media.dart → 
├── domain/models/media_model.dart (immutable)
├── domain/services/media_hash_service.dart
└── domain/value_objects/date_time_extraction_method.dart
```

#### 4. `interactive.dart` - UI in Core Library
**Problems:**
- UI logic in library code
- Global state (`indeed` variable)
- Sleep/timing logic mixed with business logic

**Refactoring Actions:**
```
interactive.dart →
├── presentation/interactive_presenter.dart
├── presentation/user_input_validator.dart
└── infrastructure/console_ui_adapter.dart
```

### 📋 **Medium Priority Issues**

#### 5. `grouping.dart` - Mixed Abstractions
**Problems:**
- Extension methods mixed with complex business logic
- Async patterns not consistently applied

**Refactoring Actions:**
```
grouping.dart →
├── domain/services/duplicate_detection_service.dart
├── domain/services/media_grouping_service.dart
└── shared/extensions/media_extensions.dart
```

#### 6. `moving.dart` - Legacy Compatibility
**Problems:**
- Hides clean architecture behind old API
- Potential confusion about which APIs to use

**Refactoring Actions:**
- Add deprecation warnings
- Create migration guide
- Update all callers to use domain services directly

### 📝 **Low Priority Issues**

#### 7. `exiftoolInterface.dart` - Infrastructure Concerns
**Solution:** Move to `infrastructure/` folder

#### 8. `folder_classify.dart` & `extras.dart`
**Solution:** Minor alignment with domain patterns

## Implementation Strategy

### Phase 1: Critical Issues (Week 1-2)
1. **Extract Configuration Management**
   - Create `GlobalConfigService` to replace global variables
   - Update all references

2. **Split utils.dart**
   - Start with file system operations
   - Move platform-specific code to infrastructure
   - Extract constants and shared utilities

### Phase 2: High Priority (Week 3-4)
1. **Refactor Media Model**
   - Create immutable domain model
   - Extract hash calculation service
   - Add proper value objects

2. **Extract Interactive Logic**
   - Create presentation layer structure
   - Move UI logic out of core library

### Phase 3: Medium Priority (Week 5-6)
1. **Clean Up Grouping Logic**
   - Extract services
   - Improve async patterns

2. **Deprecate Legacy APIs**
   - Add warnings
   - Update documentation

### Phase 4: Final Polish (Week 7-8)
1. **Infrastructure Organization**
   - Move external integrations
   - Clean up remaining issues

2. **Documentation & Testing**
   - Update documentation
   - Ensure test coverage

## Success Metrics

### Code Quality
- [ ] No files > 300 lines
- [ ] No global mutable state
- [ ] Clear dependency direction
- [ ] Single responsibility per class

### Architecture 
- [ ] All business logic in domain/
- [ ] Infrastructure separated
- [ ] Presentation layer extracted
- [ ] Dependency injection used

### Testing
- [ ] Domain services unit testable
- [ ] No testing global state
- [ ] Mock-friendly interfaces

## Migration Guidelines

### For Contributors
1. **New Features**: Use domain services directly
2. **Bug Fixes**: Prefer domain layer fixes
3. **Utilities**: Check domain/ first before adding to utils.dart

### For API Users
1. **Deprecated APIs**: Will work but show warnings
2. **New APIs**: Cleaner, more testable
3. **Migration Path**: Provided for each deprecated function

## Benefits After Refactoring

### Developer Experience
- Easier to find relevant code
- Better IntelliSense/code completion
- Clearer testing boundaries
- Faster builds (better tree shaking)

### Maintainability  
- Single responsibility principle
- Clear dependency direction
- Easier to modify without breaking changes
- Better error isolation

### Testing
- Pure functions easier to test
- Mockable dependencies
- No global state complications
- Better coverage metrics

### Performance
- Better tree shaking
- Lazy loading of services
- Parallel processing opportunities
- Reduced coupling
