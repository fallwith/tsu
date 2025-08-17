# TSU - Tide Status Utility

## Project Overview
A high-performance tide status utility written in Zig that displays current tide height and trend (rising/falling) for shell prompts. Fetches data from NOAA.gov, caches for speed, and uses linear interpolation for real-time estimates.

**Key Requirements:**
- Blazing fast execution (primary concern - especially cache hits)
- Silent error handling (outputs "?.???" on any error, never stderr)
- No newlines in output (designed for shell prompts)
- Small binary size (secondary concern)
- Cross-platform (Linux/macOS)

## Architecture

### Data Flow
1. **NOAA API calls**: Fetches 3 days of tide data (yesterday, today, tomorrow)
2. **6-event window**: Always maintains exactly 6 tide events spanning 3 days
3. **Binary cache**: Single file per station/date, cleared completely on cache miss
4. **Linear interpolation**: Estimates current height between bracketing events

### Cache Strategy
- **Location**: `$HOME/.cache/tsu/{station_id}_{date}.bin`
- **Format**: 96 bytes total (6 events × 16 bytes each: 8-byte timestamp + 8-byte height)
- **Invalidation**: Complete cache directory deletion on any cache miss
- **Performance**: Cache hit is just a 96-byte file read + interpolation

### NOAA API Integration
- **Endpoint**: `api.tidesandcurrents.noaa.gov/api/prod/datagetter`
- **Data requested**: High/low predictions in GMT, English units, JSON format
- **Rate limiting**: Reuses HTTP client across 3 API calls per cache refresh
- **Error tolerance**: Individual date fetch failures don't abort the entire operation

## Build & Development

### Build Commands
```bash
# Optimized production build
zig build -Doptimize=ReleaseFast -Dstrip=true

# Development build
zig build

# Test run (requires NOAA_GOV_STATION_ID env var)
zig build run
```

### Environment Setup
```bash
export NOAA_GOV_STATION_ID="8454000"  # Example: Providence, RI
```

## Code Conventions & Zig Best Practices

### Style Guidelines
- **Function naming**: snake_case throughout
- **Constants**: SCREAMING_SNAKE_CASE
- **Error handling**: Explicit error handling, no panics
- **Memory management**: Arena allocators for temporary operations, explicit defer cleanup
- **Performance**: Prefer stack allocation, minimize heap usage in hot paths

### Zig-Specific Patterns Used
- **Arena allocators**: For temporary operations (HTTP requests, JSON parsing)
- **Error unions**: All fallible operations return error unions
- **Comptime**: Used for buffer sizes and compile-time constants
- **@bitCast**: For safe f64 ↔ u64 conversions in binary serialization
- **Little-endian encoding**: Explicit endianness for cross-platform cache files

### Testing Philosophy (TODO)
**Current state**: No tests exist yet
**Desired state**: TDD with 100% coverage
**Test targets**:
- Date/time utilities (`epochDaysToDate`, `parseTimeToTimestamp`, `addDaysToDate`)
- Interpolation logic (`interpolateCurrentTideHeight`) 
- Cache serialization/deserialization (`writeCache`, `readCache`)
- Error handling scenarios (malformed JSON, network failures, cache corruption)

## Core Functions

### Critical Path (Cache Hit)
1. `readCache()` - main.zig:301 - Reads 96-byte binary cache
2. `interpolateCurrentTideHeight()` - main.zig:326 - Linear interpolation between events
3. `determineCurrentStatus()` - main.zig:362 - Formats output with trend arrow

### Cache Miss Path
1. `clearCache()` - main.zig:115 - Removes entire cache directory
2. `fetchTideWindow()` - main.zig:227 - Fetches 3 days from NOAA API
3. `writeCache()` - main.zig:126 - Serializes 6 events to binary

### Utility Functions
- `getCurrentDate()` - main.zig:54 - Current date in YYYY-MM-DD format
- `epochDaysToDate()` - main.zig:62 - Converts epoch days to date parts
- `dateToEpochDays()` - main.zig:210 - Converts date to epoch days
- `parseTimeToTimestamp()` - main.zig:186 - Parses NOAA timestamp to Unix timestamp

## Error Handling Strategy
- **Silent failures**: All errors result in "?.???" output
- **No stderr**: Prevents shell prompt corruption
- **Cache resilience**: Cache corruption/read errors trigger fresh fetch
- **Network tolerance**: Individual API call failures don't abort operation

## Future Improvements (TODOs)
1. **Enhanced error handling**: Delete corrupted cache files before fresh fetch attempts
2. **Test coverage**: Implement comprehensive test suite using Zig testing framework
3. **Performance metrics**: Add optional timing/profiling for optimization
4. **Robust date handling**: Handle edge cases in date arithmetic
5. **Memory optimization**: Reduce allocations in hot cache-hit path

## Development Notes
- **Target platforms**: Linux and macOS 
- **Zig version**: Latest stable release
- **Dependencies**: Standard library only (no external deps)
- **Binary location**: `zig-out/bin/tsu` after build
- **Optimization focus**: Execution time > binary size > memory usage
