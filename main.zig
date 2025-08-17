// tsu - report current tide height and up/down trend

const std = @import("std");

const CACHE_BUFFER_SIZE = 96;
const EVENTS_PER_WINDOW = 6;
const BYTES_PER_EVENT = 16;
const SECONDS_PER_DAY = 86400;
const HTTP_TIMEOUT_MS = 10000;
const MAX_RESPONSE_SIZE = 1024 * 1024;
const SMALL_JSON_BUFFER_SIZE = 8192;

const DAYS_IN_MONTHS = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
const DAYS_IN_MONTHS_LEAP = [_]u32{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

const stdout = std.io.getStdOut().writer();
fn print(comptime fmt: []const u8, args: anytype) !void {
    try stdout.print(fmt, args);
}

const TideEvent = struct {
    timestamp: i64,
    height: f64,
};

const TideWindow = [EVENTS_PER_WINDOW]TideEvent;

const TidePrediction = struct {
    t: []const u8,
    v: []const u8,
    type: []const u8,
};

const TideResponse = struct {
    predictions: ?[]TidePrediction = null,
};

fn getStationId(allocator: std.mem.Allocator) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, "NOAA_GOV_STATION_ID") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            try std.io.getStdErr().writer().print("Error: NOAA_GOV_STATION_ID environment variable is required\n", .{});
            return err;
        },
        else => return err,
    };
}

const DateParts = struct {
    year: u32,
    month: u32,
    day: u32,
};

fn getCurrentDate(allocator: std.mem.Allocator) ![]u8 {
    const now = std.time.timestamp();
    const days = @as(u64, @intCast(now)) / SECONDS_PER_DAY;
    const date_parts = epochDaysToDate(days);
    
    return std.fmt.allocPrint(allocator, "{:04}-{:02}-{:02}", .{ date_parts.year, date_parts.month, date_parts.day });
}

fn epochDaysToDate(days: u64) DateParts {
    var year: u32 = 1970;
    var remaining_days = days;
    
    while (true) {
        const days_in_year = if (isLeapYear(year)) @as(u64, 366) else @as(u64, 365);
        if (remaining_days < days_in_year) break;
        remaining_days -= days_in_year;
        year += 1;
    }
    
    const days_in_months = if (isLeapYear(year)) &DAYS_IN_MONTHS_LEAP else &DAYS_IN_MONTHS;
    
    var month: u32 = 1;
    for (days_in_months) |days_in_month| {
        if (remaining_days < days_in_month) break;
        remaining_days -= days_in_month;
        month += 1;
    }
    
    const day = @as(u32, @intCast(remaining_days + 1));
    return DateParts{ .year = year, .month = month, .day = day };
}

fn getHomeDir(allocator: std.mem.Allocator) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, "HOME") catch {
        return error.NoHomeDir;
    };
}

fn getCachePath(allocator: std.mem.Allocator, station_id: []const u8, date: []const u8) ![]u8 {
    const home = try getHomeDir(allocator);
    defer allocator.free(home);
    
    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/.cache/tsu", .{home});
    defer allocator.free(cache_dir);
    
    return std.fmt.allocPrint(allocator, "{s}/{s}_{s}.bin", .{ cache_dir, station_id, date });
}

fn ensureCacheDir(allocator: std.mem.Allocator) !void {
    const home = getHomeDir(allocator) catch return;
    defer allocator.free(home);
    
    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/.cache/tsu", .{home});
    defer allocator.free(cache_dir);
    
    std.fs.cwd().makePath(cache_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn clearCache(allocator: std.mem.Allocator) !void {
    const home = getHomeDir(allocator) catch return;
    defer allocator.free(home);
    
    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/.cache/tsu", .{home});
    defer allocator.free(cache_dir);
    
    std.fs.cwd().deleteTree(cache_dir) catch {};
    try ensureCacheDir(allocator);
}

fn writeCache(allocator: std.mem.Allocator, window: *const TideWindow, station_id: []const u8, date: []const u8) !void {
    const cache_path = try getCachePath(allocator, station_id, date);
    defer allocator.free(cache_path);
    
    const file = try std.fs.cwd().createFile(cache_path, .{});
    defer file.close();
    
    for (window) |event| {
        const timestamp_bytes = std.mem.nativeToLittle(i64, event.timestamp);
        const height_bytes = std.mem.nativeToLittle(u64, @bitCast(event.height));
        try file.writeAll(std.mem.asBytes(&timestamp_bytes));
        try file.writeAll(std.mem.asBytes(&height_bytes));
    }
}

fn addDaysToTimestamp(timestamp: i64, days: i32) i64 {
    return timestamp + (@as(i64, days) * SECONDS_PER_DAY);
}

fn addDaysToDate(allocator: std.mem.Allocator, date_str: []const u8, days: i32) ![]u8 {
    var parts = std.mem.splitScalar(u8, date_str, '-');
    const year = try std.fmt.parseInt(u32, parts.next().?, 10);
    const month = try std.fmt.parseInt(u32, parts.next().?, 10);
    const day_num = try std.fmt.parseInt(u32, parts.next().?, 10);
    
    const original_days = dateToEpochDays(year, month, day_num);
    const new_days = @as(i64, @intCast(original_days)) + days;
    
    if (new_days < 0) {
        return error.DateOutOfRange;
    }
    
    const result_date = epochDaysToDate(@intCast(new_days));
    return std.fmt.allocPrint(allocator, "{:04}-{:02}-{:02}", .{ result_date.year, result_date.month, result_date.day });
}

fn httpGetWithClient(client: *std.http.Client, allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const uri = try std.Uri.parse(url);
    const server_header_buffer = try allocator.alloc(u8, 8192);
    defer allocator.free(server_header_buffer);
    
    var request = try client.open(.GET, uri, .{
        .server_header_buffer = server_header_buffer,
    });
    defer request.deinit();
    
    try request.send();
    try request.finish();
    try request.wait();
    
    const body = try request.reader().readAllAlloc(allocator, MAX_RESPONSE_SIZE);
    return body;
}

fn httpGet(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    return httpGetWithClient(&client, allocator, url);
}

fn parseTimeToTimestamp(time_str: []const u8) !i64 {
    var parts = std.mem.splitScalar(u8, time_str, ' ');
    const date_part = parts.next() orelse return error.InvalidFormat;
    const time_part = parts.next() orelse return error.InvalidFormat;
    
    var date_parts = std.mem.splitScalar(u8, date_part, '-');
    const year = try std.fmt.parseInt(u32, date_parts.next().?, 10);
    const month = try std.fmt.parseInt(u32, date_parts.next().?, 10);
    const day = try std.fmt.parseInt(u32, date_parts.next().?, 10);
    
    var time_parts = std.mem.splitScalar(u8, time_part, ':');
    const hour = try std.fmt.parseInt(u32, time_parts.next().?, 10);
    const minute = try std.fmt.parseInt(u32, time_parts.next().?, 10);
    
    const days_since_epoch = dateToEpochDays(year, month, day);
    const seconds = days_since_epoch * SECONDS_PER_DAY + hour * 3600 + minute * 60;
    
    return @intCast(seconds);
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn dateToEpochDays(year: u32, month: u32, day: u32) u64 {
    var days: u64 = 0;
    
    for (1970..year) |y| {
        days += if (isLeapYear(@intCast(y))) 366 else 365;
    }
    
    const days_in_months = if (isLeapYear(year)) &DAYS_IN_MONTHS_LEAP else &DAYS_IN_MONTHS;
    
    for (1..month) |m| {
        days += days_in_months[m - 1];
    }
    
    days += day - 1;
    return days;
}

fn fetchTideWindow(allocator: std.mem.Allocator, station_id: []const u8, date: []const u8) !TideWindow {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    
    const yesterday = try addDaysToDate(arena_allocator, date, -1);
    const tomorrow = try addDaysToDate(arena_allocator, date, 1);
    
    var all_events = std.ArrayList(TideEvent).init(arena_allocator);
    
    // Reuse HTTP client for multiple requests
    var client = std.http.Client{ .allocator = arena_allocator };
    defer client.deinit();
    
    // Fetch 3 days of data
    const dates = [_][]const u8{ yesterday, date, tomorrow };
    for (dates) |fetch_date| {
        const formatted_date = try std.mem.replaceOwned(u8, arena_allocator, fetch_date, "-", "");
        
        const url = try std.fmt.allocPrint(arena_allocator, 
            "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?station={s}&product=predictions&datum=MLLW&interval=hilo&begin_date={s}&end_date={s}&time_zone=gmt&units=english&format=json",
            .{ station_id, formatted_date, formatted_date }
        );
        
        const body = httpGetWithClient(&client, arena_allocator, url) catch continue;
        
        const parsed = std.json.parseFromSlice(TideResponse, arena_allocator, body, .{}) catch continue;
        
        if (parsed.value.predictions) |predictions| {
            for (predictions) |pred| {
                const height = std.fmt.parseFloat(f64, pred.v) catch 0.0;
                const timestamp = parseTimeToTimestamp(pred.t) catch continue;
                try all_events.append(TideEvent{ .timestamp = timestamp, .height = height });
            }
        }
    }
    
    // Sort and select 6 events around current time
    const items = all_events.items;
    std.mem.sort(TideEvent, items, {}, struct {
        fn lessThan(_: void, a: TideEvent, b: TideEvent) bool {
            return a.timestamp < b.timestamp;
        }
    }.lessThan);
    
    const now = std.time.timestamp();
    
    // Find the events that bracket the current time
    var current_idx: usize = 0;
    for (items, 0..) |event, i| {
        if (event.timestamp <= now) {
            current_idx = i;
        } else {
            break;
        }
    }
    
    var window: TideWindow = undefined;
    if (items.len >= EVENTS_PER_WINDOW) {
        const start_idx = if (current_idx >= 3) current_idx - 3 else 0;
        const end_idx = if (start_idx + EVENTS_PER_WINDOW <= items.len) start_idx else items.len - EVENTS_PER_WINDOW;
        
        for (0..EVENTS_PER_WINDOW) |i| {
            window[i] = items[end_idx + i];
        }
    } else {
        for (0..EVENTS_PER_WINDOW) |i| {
            window[i] = if (i < items.len) items[i] else TideEvent{ .timestamp = 0, .height = 0.0 };
        }
    }
    
    return window;
}

fn readCache(allocator: std.mem.Allocator, station_id: []const u8, date: []const u8) !TideWindow {
    const cache_path = try getCachePath(allocator, station_id, date);
    defer allocator.free(cache_path);
    
    const file = std.fs.cwd().openFile(cache_path, .{}) catch {
        return error.CacheNotFound;
    };
    defer file.close();
    
    var buffer: [CACHE_BUFFER_SIZE]u8 = undefined;
    _ = try file.readAll(&buffer);
    
    var window: TideWindow = undefined;
    for (0..EVENTS_PER_WINDOW) |i| {
        const offset = i * BYTES_PER_EVENT;
        const timestamp_bytes = buffer[offset..offset+8];
        const height_bytes = buffer[offset+8..offset+16];
        
        window[i].timestamp = std.mem.readInt(i64, timestamp_bytes[0..8], .little);
        window[i].height = @bitCast(std.mem.readInt(u64, height_bytes[0..8], .little));
    }
    
    return window;
}

fn interpolateCurrentTideHeight(window: *const TideWindow) f64 {
    const now = std.time.timestamp();
    
    var before_event: ?*const TideEvent = null;
    var after_event: ?*const TideEvent = null;
    
    for (window) |*event| {
        if (event.timestamp <= now) {
            before_event = event;
        } else if (after_event == null) {
            after_event = event;
            break;
        }
    }
    
    if (before_event != null and after_event != null) {
        const before = before_event.?;
        const after = after_event.?;
        const total_duration = @as(f64, @floatFromInt(after.timestamp - before.timestamp));
        const elapsed_duration = @as(f64, @floatFromInt(now - before.timestamp));
        
        if (total_duration > 0.0) {
            const ratio = elapsed_duration / total_duration;
            const height_diff = after.height - before.height;
            return before.height + (height_diff * ratio);
        }
        return before.height;
    } else if (before_event != null) {
        return before_event.?.height;
    } else if (after_event != null) {
        return after_event.?.height;
    }
    
    return 0.0;
}

fn determineCurrentStatus(allocator: std.mem.Allocator, window: *const TideWindow) ![]u8 {
    const now = std.time.timestamp();
    const current_height = interpolateCurrentTideHeight(window);
    
    for (window) |*event| {
        if (event.timestamp > now) {
            const direction: []const u8 = if (event.height > current_height) "↑" else "↓";
            return std.fmt.allocPrint(allocator, "{d:.3}{s}", .{ current_height, direction });
        }
    }
    
    return std.fmt.allocPrint(allocator, "?.???", .{});
}

fn fetchDayData(allocator: std.mem.Allocator, station_id: []const u8, date: []const u8) ![]u8 {
    // Try cache first
    if (readCache(allocator, station_id, date)) |cached_window| {
        return determineCurrentStatus(allocator, &cached_window);
    } else |_| {
        // Cache miss - clear cache and fetch fresh data
        try clearCache(allocator);
        const window = try fetchTideWindow(allocator, station_id, date);
        try writeCache(allocator, &window, station_id, date);
        return determineCurrentStatus(allocator, &window);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    try ensureCacheDir(allocator);
    
    const station_id = getStationId(allocator) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            try print("Error: NOAA_GOV_STATION_ID environment variable is required\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer allocator.free(station_id);
    
    const date = try getCurrentDate(allocator);
    defer allocator.free(date);
    
    const output = fetchDayData(allocator, station_id, date) catch {
        try print("?.???", .{});
        return;
    };
    defer allocator.free(output);
    
    try print("{s}", .{output});
}
