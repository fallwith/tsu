# TSU - Tide Status Utility

## Project Overview
A high-performance tide status utility written in Zig that displays current tide height and trend (rising/falling) for shell prompts. Fetches 6-minute interval predictions from NOAA.gov, caches for speed, and uses linear interpolation for real-time estimates.

**Key Requirements:**
- Blazing fast execution (primary concern - especially cache hits)
- Silent error handling (outputs "?.???" on any error, never stderr)
- No newlines in output (designed for shell prompts)
- Small binary size (secondary concern)
- Cross-platform (Linux/macOS)

## Architecture

### Data Flow
1. **NOAA API call**: Single request fetches 3 days of 6-minute predictions (yesterday, today, tomorrow)
2. **Binary cache**: Single file per station/date, cleared completely on cache miss
3. **Linear interpolation**: Estimates current height between bracketing 6-minute predictions

### Cache Strategy
- **Location**: `$HOME/.cache/tsu/{station_id}_{date}.bin`
- **Format**: 4-byte event count (u32 LE) + N events (16 bytes each: 8-byte timestamp + 8-byte height)
- **Typical size**: ~11.5 KB (720 events across 3 days)
- **Invalidation**: Complete cache directory deletion on any cache miss
- **Resilience**: Validates byte counts on read; truncated files are detected and treated as cache misses

### NOAA API Integration
- **Endpoint**: `api.tidesandcurrents.noaa.gov/api/prod/datagetter`
- **Data requested**: 6-minute interval predictions across a 3-day range, GMT, English units, JSON format
- **Single request**: One HTTP call per cache refresh (3-day date range)

## Build & Development

### Build Commands
```bash
# Optimized production build
zig build -Doptimize=ReleaseFast -Dstrip=true

# Development build
zig build

# Run tests
zig build test

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
- **@bitCast**: For safe f64 <-> u64 conversions in binary serialization
- **Little-endian encoding**: Explicit endianness for cross-platform cache files

### Testing
Tests live at the bottom of `main.zig` and run via `zig build test`. Coverage includes:
- Date/time utilities (`epochDaysToDate`, `dateToEpochDays`, `parseTimeToTimestamp`, `addDaysToDate`)
- Interpolation logic (`interpolateCurrentTideHeight`)
- Cache serialization/deserialization round-trip
- Cache truncation detection
- Validation (`isValidTideData`)
- Status formatting and trend direction (`determineCurrentStatus`)

## Core Functions

### Critical Path (Cache Hit)
1. `readCache()` - Reads binary cache, validates byte counts
2. `interpolateCurrentTideHeight()` - Linear interpolation between bracketing 6-minute predictions
3. `determineCurrentStatus()` - Formats output with trend arrow

### Cache Miss Path
1. `clearCache()` - Removes entire cache directory
2. `fetchTideData()` - Single API call for 3-day range of 6-minute predictions
3. `writeCache()` - Serializes events with count header to binary

### Utility Functions
- `getCurrentDate()` - Current date in YYYY-MM-DD format
- `epochDaysToDate()` - Converts epoch days to date parts
- `dateToEpochDays()` - Converts date to epoch days
- `parseTimeToTimestamp()` - Parses NOAA timestamp to Unix timestamp
- `addDaysToDate()` - Date arithmetic with string dates

## Error Handling Strategy
- **Silent failures**: All errors result in "?.???" output
- **No stderr**: Prevents shell prompt corruption
- **Cache resilience**: Cache corruption/truncation/read errors trigger fresh fetch
- **Network errors**: Propagated and caught at top level, output "?.???"

## Future Improvements
1. **Performance metrics**: Add optional timing/profiling for optimization
2. **Memory optimization**: Reduce allocations in hot cache-hit path

## Development Notes
- **Target platforms**: Linux and macOS
- **Zig version**: 0.15.x
- **Dependencies**: Standard library only (no external deps)
- **Binary location**: `zig-out/bin/tsu` after build
- **Optimization focus**: Execution time > binary size > memory usage
