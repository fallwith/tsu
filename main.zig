// tsu - report current tide height and up/down trend

const std = @import("std");

const BYTES_PER_EVENT = 16;
const SECONDS_PER_DAY = 86400;

const DAYS_IN_MONTHS = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
const DAYS_IN_MONTHS_LEAP = [_]u32{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

fn print(comptime fmt: []const u8, args: anytype) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(fmt, args);
    try stdout.flush();
}

const TideEvent = struct {
    timestamp: i64,
    height: f64,
};

const TidePrediction = struct {
    t: []const u8,
    v: []const u8,
};

const TideResponse = struct {
    predictions: ?[]TidePrediction = null,
};

fn getStationId(allocator: std.mem.Allocator) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, "NOAA_GOV_STATION_ID");
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

fn isValidTideData(events: []const TideEvent) bool {
    const now = std.time.timestamp();
    var has_past = false;
    var has_future = false;

    for (events) |event| {
        if (event.timestamp == 0) return false;
        if (event.timestamp <= now) has_past = true;
        if (event.timestamp > now) has_future = true;
    }

    return has_past and has_future;
}

fn writeCache(allocator: std.mem.Allocator, events: []const TideEvent, station_id: []const u8, date: []const u8) !void {
    const cache_path = try getCachePath(allocator, station_id, date);
    defer allocator.free(cache_path);

    const file = try std.fs.cwd().createFile(cache_path, .{});
    defer file.close();

    const count: u32 = @intCast(events.len);
    const count_bytes = std.mem.nativeToLittle(u32, count);
    try file.writeAll(std.mem.asBytes(&count_bytes));

    for (events) |event| {
        const timestamp_bytes = std.mem.nativeToLittle(i64, event.timestamp);
        const height_bytes = std.mem.nativeToLittle(u64, @bitCast(event.height));
        try file.writeAll(std.mem.asBytes(&timestamp_bytes));
        try file.writeAll(std.mem.asBytes(&height_bytes));
    }
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

    var req = try client.request(.GET, uri, .{
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buffer: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    if (response.head.status != .ok) {
        return error.HttpRequestFailed;
    }

    var transfer_buffer: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buffer);

    var body = std.ArrayList(u8){};
    errdefer body.deinit(allocator);

    try reader.appendRemainingUnlimited(allocator, &body);

    return try body.toOwnedSlice(allocator);
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

fn fetchTideData(allocator: std.mem.Allocator, station_id: []const u8, date: []const u8) ![]TideEvent {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const yesterday = try addDaysToDate(arena_allocator, date, -1);
    const tomorrow = try addDaysToDate(arena_allocator, date, 1);
    const begin = try std.mem.replaceOwned(u8, arena_allocator, yesterday, "-", "");
    const end = try std.mem.replaceOwned(u8, arena_allocator, tomorrow, "-", "");

    const url = try std.fmt.allocPrint(arena_allocator,
        "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?station={s}&product=predictions&datum=MLLW&interval=6&begin_date={s}&end_date={s}&time_zone=gmt&units=english&format=json",
        .{ station_id, begin, end },
    );

    var client = std.http.Client{ .allocator = arena_allocator };
    defer client.deinit();

    const body = try httpGetWithClient(&client, arena_allocator, url);
    const parsed = try std.json.parseFromSlice(TideResponse, arena_allocator, body, .{ .ignore_unknown_fields = true });

    var all_events = std.ArrayList(TideEvent){};

    if (parsed.value.predictions) |predictions| {
        for (predictions) |pred| {
            const height = std.fmt.parseFloat(f64, pred.v) catch 0.0;
            const timestamp = parseTimeToTimestamp(pred.t) catch continue;
            try all_events.append(arena_allocator, TideEvent{ .timestamp = timestamp, .height = height });
        }
    }

    const items = all_events.items;
    std.mem.sort(TideEvent, items, {}, struct {
        fn lessThan(_: void, a: TideEvent, b: TideEvent) bool {
            return a.timestamp < b.timestamp;
        }
    }.lessThan);

    const result = try allocator.alloc(TideEvent, items.len);
    @memcpy(result, items);
    return result;
}

fn readCache(allocator: std.mem.Allocator, station_id: []const u8, date: []const u8) ![]TideEvent {
    const cache_path = try getCachePath(allocator, station_id, date);
    defer allocator.free(cache_path);

    const file = std.fs.cwd().openFile(cache_path, .{}) catch {
        return error.CacheNotFound;
    };
    defer file.close();

    var count_bytes: [4]u8 = undefined;
    if ((try file.readAll(&count_bytes)) != 4) return error.InvalidCache;
    const count = std.mem.readInt(u32, &count_bytes, .little);

    if (count == 0 or count > 10000) return error.InvalidCache;

    const events = try allocator.alloc(TideEvent, count);
    errdefer allocator.free(events);

    for (0..count) |i| {
        var event_bytes: [BYTES_PER_EVENT]u8 = undefined;
        if ((try file.readAll(&event_bytes)) != BYTES_PER_EVENT) return error.InvalidCache;
        events[i].timestamp = std.mem.readInt(i64, event_bytes[0..8], .little);
        events[i].height = @bitCast(std.mem.readInt(u64, event_bytes[8..16], .little));
    }

    return events;
}

fn interpolateCurrentTideHeight(events: []const TideEvent) f64 {
    const now = std.time.timestamp();

    var before_idx: ?usize = null;

    for (events, 0..) |event, i| {
        if (event.timestamp <= now) {
            before_idx = i;
        } else {
            break;
        }
    }

    if (before_idx) |bi| {
        if (bi + 1 < events.len) {
            const before = events[bi];
            const after = events[bi + 1];
            const total_duration = @as(f64, @floatFromInt(after.timestamp - before.timestamp));
            const elapsed_duration = @as(f64, @floatFromInt(now - before.timestamp));

            if (total_duration > 0.0) {
                const ratio = elapsed_duration / total_duration;
                return before.height + (after.height - before.height) * ratio;
            }
            return before.height;
        }
        return events[bi].height;
    } else if (events.len > 0) {
        return events[0].height;
    }

    return 0.0;
}

fn determineCurrentStatus(allocator: std.mem.Allocator, events: []const TideEvent) ![]u8 {
    const now = std.time.timestamp();
    const current_height = interpolateCurrentTideHeight(events);

    for (events) |event| {
        if (event.timestamp > now) {
            const direction: []const u8 = if (event.height > current_height) "↑" else "↓";
            return std.fmt.allocPrint(allocator, "{d:.3}{s}", .{ current_height, direction });
        }
    }

    return std.fmt.allocPrint(allocator, "?.???", .{});
}

fn fetchDayData(allocator: std.mem.Allocator, station_id: []const u8, date: []const u8) ![]u8 {
    if (readCache(allocator, station_id, date)) |cached_events| {
        defer allocator.free(cached_events);
        if (isValidTideData(cached_events)) {
            return determineCurrentStatus(allocator, cached_events);
        }
        try clearCache(allocator);
    } else |_| {
        try clearCache(allocator);
    }

    const events = try fetchTideData(allocator, station_id, date);
    defer allocator.free(events);

    if (isValidTideData(events)) {
        writeCache(allocator, events, station_id, date) catch {};
        return determineCurrentStatus(allocator, events);
    } else {
        try clearCache(allocator);
        return try allocator.dupe(u8, "?.???");
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
        clearCache(allocator) catch {};
        try print("?.???", .{});
        return;
    };
    defer allocator.free(output);

    try print("{s}", .{output});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "epochDaysToDate: unix epoch" {
    const d = epochDaysToDate(0);
    try testing.expectEqual(@as(u32, 1970), d.year);
    try testing.expectEqual(@as(u32, 1), d.month);
    try testing.expectEqual(@as(u32, 1), d.day);
}

test "epochDaysToDate: known date 2026-02-25" {
    const days = dateToEpochDays(2026, 2, 25);
    const d = epochDaysToDate(days);
    try testing.expectEqual(@as(u32, 2026), d.year);
    try testing.expectEqual(@as(u32, 2), d.month);
    try testing.expectEqual(@as(u32, 25), d.day);
}

test "epochDaysToDate: leap day 2024-02-29" {
    const days = dateToEpochDays(2024, 2, 29);
    const d = epochDaysToDate(days);
    try testing.expectEqual(@as(u32, 2024), d.year);
    try testing.expectEqual(@as(u32, 2), d.month);
    try testing.expectEqual(@as(u32, 29), d.day);
}

test "dateToEpochDays: unix epoch" {
    try testing.expectEqual(@as(u64, 0), dateToEpochDays(1970, 1, 1));
}

test "dateToEpochDays: one day after epoch" {
    try testing.expectEqual(@as(u64, 1), dateToEpochDays(1970, 1, 2));
}

test "dateToEpochDays: known value 2000-01-01" {
    try testing.expectEqual(@as(u64, 10957), dateToEpochDays(2000, 1, 1));
}

test "dateToEpochDays and epochDaysToDate round-trip" {
    const years = [_]struct { y: u32, m: u32, d: u32 }{
        .{ .y = 1970, .m = 1, .d = 1 },
        .{ .y = 1999, .m = 12, .d = 31 },
        .{ .y = 2000, .m = 2, .d = 29 },
        .{ .y = 2024, .m = 7, .d = 4 },
        .{ .y = 2026, .m = 2, .d = 25 },
        .{ .y = 2100, .m = 3, .d = 1 },
    };
    for (years) |case| {
        const days = dateToEpochDays(case.y, case.m, case.d);
        const result = epochDaysToDate(days);
        try testing.expectEqual(case.y, result.year);
        try testing.expectEqual(case.m, result.month);
        try testing.expectEqual(case.d, result.day);
    }
}

test "isLeapYear" {
    try testing.expect(isLeapYear(2000));
    try testing.expect(isLeapYear(2024));
    try testing.expect(!isLeapYear(1900));
    try testing.expect(!isLeapYear(2023));
    try testing.expect(isLeapYear(2400));
    try testing.expect(!isLeapYear(2100));
}

test "parseTimeToTimestamp: known value" {
    const ts = try parseTimeToTimestamp("2026-02-25 12:30");
    const expected = dateToEpochDays(2026, 2, 25) * SECONDS_PER_DAY + 12 * 3600 + 30 * 60;
    try testing.expectEqual(@as(i64, @intCast(expected)), ts);
}

test "parseTimeToTimestamp: midnight" {
    const ts = try parseTimeToTimestamp("2026-01-01 00:00");
    const expected = dateToEpochDays(2026, 1, 1) * SECONDS_PER_DAY;
    try testing.expectEqual(@as(i64, @intCast(expected)), ts);
}

test "parseTimeToTimestamp: invalid format" {
    try testing.expectError(error.InvalidFormat, parseTimeToTimestamp("garbage"));
    try testing.expectError(error.InvalidFormat, parseTimeToTimestamp("2026-02-25"));
}

test "addDaysToDate: forward" {
    const allocator = testing.allocator;
    const result = try addDaysToDate(allocator, "2026-02-25", 1);
    defer allocator.free(result);
    try testing.expectEqualStrings("2026-02-26", result);
}

test "addDaysToDate: backward" {
    const allocator = testing.allocator;
    const result = try addDaysToDate(allocator, "2026-02-25", -1);
    defer allocator.free(result);
    try testing.expectEqualStrings("2026-02-24", result);
}

test "addDaysToDate: cross month boundary" {
    const allocator = testing.allocator;
    const result = try addDaysToDate(allocator, "2026-01-31", 1);
    defer allocator.free(result);
    try testing.expectEqualStrings("2026-02-01", result);
}

test "addDaysToDate: cross year boundary" {
    const allocator = testing.allocator;
    const result = try addDaysToDate(allocator, "2025-12-31", 1);
    defer allocator.free(result);
    try testing.expectEqualStrings("2026-01-01", result);
}

test "addDaysToDate: leap year crossing" {
    const allocator = testing.allocator;
    const result = try addDaysToDate(allocator, "2024-02-28", 1);
    defer allocator.free(result);
    try testing.expectEqualStrings("2024-02-29", result);
}

test "addDaysToDate: underflow returns error" {
    const allocator = testing.allocator;
    try testing.expectError(error.DateOutOfRange, addDaysToDate(allocator, "1970-01-01", -1));
}

test "interpolateCurrentTideHeight: exact bracket midpoint" {
    const now = std.time.timestamp();
    const events = [_]TideEvent{
        .{ .timestamp = now - 300, .height = 1.0 },
        .{ .timestamp = now + 300, .height = 3.0 },
    };
    const height = interpolateCurrentTideHeight(&events);
    try testing.expectApproxEqAbs(2.0, height, 0.05);
}

test "interpolateCurrentTideHeight: at before event" {
    const now = std.time.timestamp();
    const events = [_]TideEvent{
        .{ .timestamp = now, .height = 4.0 },
        .{ .timestamp = now + 600, .height = 5.0 },
    };
    const height = interpolateCurrentTideHeight(&events);
    try testing.expectApproxEqAbs(4.0, height, 0.01);
}

test "interpolateCurrentTideHeight: no future events returns last" {
    const now = std.time.timestamp();
    const events = [_]TideEvent{
        .{ .timestamp = now - 600, .height = 2.5 },
        .{ .timestamp = now - 300, .height = 3.0 },
    };
    const height = interpolateCurrentTideHeight(&events);
    try testing.expectApproxEqAbs(3.0, height, 0.01);
}

test "interpolateCurrentTideHeight: no past events returns first" {
    const now = std.time.timestamp();
    const events = [_]TideEvent{
        .{ .timestamp = now + 300, .height = 1.5 },
        .{ .timestamp = now + 600, .height = 2.0 },
    };
    const height = interpolateCurrentTideHeight(&events);
    try testing.expectApproxEqAbs(1.5, height, 0.01);
}

test "interpolateCurrentTideHeight: empty events returns zero" {
    const events = [_]TideEvent{};
    const height = interpolateCurrentTideHeight(&events);
    try testing.expectApproxEqAbs(0.0, height, 0.01);
}

test "isValidTideData: valid window" {
    const now = std.time.timestamp();
    const events = [_]TideEvent{
        .{ .timestamp = now - 300, .height = 1.0 },
        .{ .timestamp = now + 300, .height = 2.0 },
    };
    try testing.expect(isValidTideData(&events));
}

test "isValidTideData: all past" {
    const now = std.time.timestamp();
    const events = [_]TideEvent{
        .{ .timestamp = now - 600, .height = 1.0 },
        .{ .timestamp = now - 300, .height = 2.0 },
    };
    try testing.expect(!isValidTideData(&events));
}

test "isValidTideData: all future" {
    const now = std.time.timestamp();
    const events = [_]TideEvent{
        .{ .timestamp = now + 300, .height = 1.0 },
        .{ .timestamp = now + 600, .height = 2.0 },
    };
    try testing.expect(!isValidTideData(&events));
}

test "isValidTideData: zero timestamp" {
    const now = std.time.timestamp();
    const events = [_]TideEvent{
        .{ .timestamp = 0, .height = 1.0 },
        .{ .timestamp = now + 300, .height = 2.0 },
    };
    try testing.expect(!isValidTideData(&events));
}

test "isValidTideData: empty" {
    const events = [_]TideEvent{};
    try testing.expect(!isValidTideData(&events));
}

test "determineCurrentStatus: rising tide" {
    const allocator = testing.allocator;
    const now = std.time.timestamp();
    const events = [_]TideEvent{
        .{ .timestamp = now - 300, .height = 1.0 },
        .{ .timestamp = now + 300, .height = 3.0 },
    };
    const result = try determineCurrentStatus(allocator, &events);
    defer allocator.free(result);
    try testing.expect(std.mem.endsWith(u8, result, "↑"));
}

test "determineCurrentStatus: falling tide" {
    const allocator = testing.allocator;
    const now = std.time.timestamp();
    const events = [_]TideEvent{
        .{ .timestamp = now - 300, .height = 3.0 },
        .{ .timestamp = now + 300, .height = 1.0 },
    };
    const result = try determineCurrentStatus(allocator, &events);
    defer allocator.free(result);
    try testing.expect(std.mem.endsWith(u8, result, "↓"));
}

test "cache round-trip" {
    const allocator = testing.allocator;
    const now = std.time.timestamp();

    const events = [_]TideEvent{
        .{ .timestamp = now - 600, .height = 1.138 },
        .{ .timestamp = now - 300, .height = 2.867 },
        .{ .timestamp = now + 300, .height = 4.530 },
        .{ .timestamp = now + 600, .height = 3.090 },
    };

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/.cache/tsu", .{home});
    defer allocator.free(cache_dir);
    std.fs.cwd().makePath(cache_dir) catch {};

    try writeCache(allocator, &events, "test_stn", "1138-01-01");

    const loaded = try readCache(allocator, "test_stn", "1138-01-01");
    defer allocator.free(loaded);

    try testing.expectEqual(@as(usize, 4), loaded.len);
    for (events, 0..) |expected, i| {
        try testing.expectEqual(expected.timestamp, loaded[i].timestamp);
        try testing.expectApproxEqAbs(expected.height, loaded[i].height, 0.001);
    }

    const cache_path = try getCachePath(allocator, "test_stn", "1138-01-01");
    defer allocator.free(cache_path);
    std.fs.cwd().deleteFile(cache_path) catch {};
}

test "readCache: truncated file returns error" {
    const allocator = testing.allocator;

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/.cache/tsu", .{home});
    defer allocator.free(cache_dir);
    std.fs.cwd().makePath(cache_dir) catch {};

    const cache_path = try getCachePath(allocator, "test_stn", "8675-03-09");
    defer allocator.free(cache_path);

    const file = try std.fs.cwd().createFile(cache_path, .{});
    const count: u32 = 100;
    const count_bytes = std.mem.nativeToLittle(u32, count);
    try file.writeAll(std.mem.asBytes(&count_bytes));
    file.close();

    try testing.expectError(error.InvalidCache, readCache(allocator, "test_stn", "8675-03-09"));

    std.fs.cwd().deleteFile(cache_path) catch {};
}
