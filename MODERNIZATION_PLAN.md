# Legacy Code Removal and Modernization Plan

## Overview
This document outlines the complete removal of legacy compatibility layers to simplify the codebase and eliminate technical debt.

## Current Legacy Components

### 1. Legacy Media Class (`lib/media.dart`)
- **Purpose**: Backward compatibility wrapper around MediaEntity
- **Usage**: Tests, some service interfaces
- **Dependencies**: LegacyMediaAdapter, MediaEntity
- **Action**: DELETE

### 2. Legacy Grouping Functions (`lib/grouping.dart`)
- **Purpose**: Legacy grouping functions with Media class
- **Usage**: Tests (removeDuplicates, findAlbums functions)
- **Dependencies**: Media class, legacy imports
- **Action**: DELETE

### 3. Legacy MediaCollection (`lib/domain/models/media_collection_model.dart`)
- **Purpose**: Wrapper around MediaEntityCollection for backward compatibility
- **Usage**: Some pipeline steps, services
- **Dependencies**: MediaCollectionAdapter, Media class
- **Action**: DELETE

### 4. Legacy Adapters
- **Files**: 
  - `lib/adapters/legacy_media_adapter.dart`
  - `lib/domain/adapters/media_collection_adapter.dart`
- **Purpose**: Bridge between legacy and modern types
- **Action**: DELETE

### 5. Legacy Moving Services (`lib/moving.dart`)
- **Purpose**: Backward compatible interface to modern moving service
- **Usage**: Potentially some calling code
- **Dependencies**: Media class, legacy types
- **Action**: CONVERT or DELETE

## Implementation Steps

### Phase 1: Test Infrastructure (PRIORITY: HIGH)
1. Update all test files to use MediaEntity instead of Media
2. Replace legacy function calls with modern service methods
3. Update test helpers and fixtures

**Files to update:**
- `test/media_grouping_test.dart`
- `test/moving_test.dart` 
- `test/moving_logic_test.dart`
- `test/functional_test.dart`
- `test/gpth_integration_test.dart`

### Phase 2: Core Model Removal (PRIORITY: HIGH)
1. Delete legacy Media class and related files
2. Update all service interfaces to use MediaEntity only
3. Remove adapter layers

**Files to delete:**
- `lib/media.dart`
- `lib/adapters/legacy_media_adapter.dart`
- `lib/grouping.dart`
- `lib/domain/models/media_collection_model.dart`
- `lib/domain/adapters/media_collection_adapter.dart`

### Phase 3: Service Modernization (PRIORITY: MEDIUM)
1. Update all services to use modern types exclusively
2. Remove legacy singleton patterns
3. Implement proper dependency injection

**Files to update:**
- `lib/domain/services/global_config_service.dart`
- All moving service files
- Service interfaces that still reference legacy types

### Phase 4: Cleanup (PRIORITY: LOW)  
1. Remove unused imports
2. Update documentation
3. Verify no legacy references remain

## Benefits After Completion

1. **Simplified Codebase**: Remove ~2000+ lines of legacy compatibility code
2. **Better Performance**: No adapter overhead, direct MediaEntity usage
3. **Type Safety**: No more mixed legacy/modern type usage
4. **Maintainability**: Single, consistent API surface
5. **Testing**: Cleaner test code using modern types directly

## Risks and Mitigation

- **Risk**: Breaking existing tests during transition
- **Mitigation**: Update tests incrementally, run after each phase

- **Risk**: Missing legacy usage patterns
- **Mitigation**: Comprehensive grep search for legacy patterns before deletion

## Success Criteria

- [ ] All tests pass with MediaEntity-only code
- [ ] No imports of deleted legacy files exist
- [ ] No references to Media class exist in codebase
- [ ] All services use MediaEntity/MediaEntityCollection exclusively
- [ ] Codebase compiles cleanly with no warnings
- [ ] Functional tests demonstrate same behavior as before

## Implementation Status

- [x] Main pipeline modernized to use MediaEntityCollection
- [x] All pipeline steps use modern services
- [ ] Test infrastructure updated
- [ ] Legacy Media class removed
- [ ] Legacy adapters removed
- [ ] Service dependencies cleaned
- [ ] Global config modernized
- [ ] Documentation updated
