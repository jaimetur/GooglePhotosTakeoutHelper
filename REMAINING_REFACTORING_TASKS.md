# Remaining Refactoring Tasks

*Updated: June 13, 2025*

## 🎯 **REMAINING WORK - Final Phase**

### **Priority 1: Complete UI Extraction** (High Impact)
**Current**: `interactive.dart` = 681 lines (down from 755)  
**Target**: <100 lines with zero console output

**Remaining Work**:
- Extract ~15 remaining UI methods (`askIfWriteExif`, `askIfLimitFileSize`, etc.)
- Move all remaining print statements to `InteractivePresenter`
- Complete domain logic extraction to `InteractiveConfigurationService`
- **Target**: Extract ~580 more lines to reach <100 line goal

**Methods Still to Extract**:
- `askIfWriteExif()` - EXIF writing prompts
- `askIfLimitFileSize()` - File size limitation prompts  
- `askFixExtensions()` - Extension fixing prompts
- `askIfUnzip()` - ZIP extraction prompts
- `freeSpaceNotice()` - Disk space warnings
- Various input validation helpers

### **Priority 2: Pipeline Steps Modernization** (Medium Impact)
**Current**: Steps use legacy MediaCollection interface  
**Target**: Update steps to work with MediaEntityCollection

**Work Required**:
- Update step interfaces to accept MediaEntityCollection
- Migrate step implementations gradually  
- Maintain backward compatibility during transition
- Test modern pipeline with MediaEntityCollection

### **Priority 3: Performance & Testing** (Low Impact)
**Optional Improvements**:
- Add performance monitoring to services
- Enhance error handling with Result types
- Improve test coverage for new service interfaces
- Add comprehensive integration tests

## 🏁 **COMPLETION CRITERIA**

### **Definition of Done**:
- ✅ `interactive.dart` under 100 lines
- ✅ Zero print statements in domain layer
- ✅ All UI logic in presentation layer
- ✅ Pipeline steps using MediaEntityCollection
- ✅ All tests passing
- ✅ Zero compilation errors

### **Success Metrics**:
- **Code Quality**: 95%+ reduction in UI/domain coupling
- **Testability**: All UI logic mockable and testable
- **Architecture**: Clean separation of concerns achieved
- **Performance**: No regression in functionality or speed

## 📈 **Progress Tracking**

**Phase 4 Progress**: ~20% Complete
- ✅ Architecture foundation established
- ✅ 74 lines extracted from interactive.dart
- 🔄 580 lines remaining to extract
- ⏸️ Pipeline modernization pending
