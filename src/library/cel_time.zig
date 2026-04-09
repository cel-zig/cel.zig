const std = @import("std");

pub const Error = error{
    InvalidDuration,
    InvalidTimestamp,
    UnsupportedTimeZone,
    Overflow,
};

pub const nanos_per_second: i64 = 1_000_000_000;
pub const nanos_per_millisecond: i64 = 1_000_000;
pub const nanos_per_minute: i64 = 60 * nanos_per_second;
pub const nanos_per_hour: i64 = 60 * nanos_per_minute;
pub const seconds_per_day: i64 = 24 * 60 * 60;
pub const max_duration_seconds: i64 = 315_576_000_000;

pub const timestamp_min_seconds: i64 = daysFromCivil(1, 1, 1) * seconds_per_day;
pub const timestamp_max_seconds: i64 = daysFromCivil(9999, 12, 31) * seconds_per_day + (seconds_per_day - 1);

pub const Duration = struct {
    seconds: i64,
    nanos: i32,

    pub fn fromComponents(seconds: i64, nanos: i64) Error!Duration {
        const normalized = try normalizeDurationComponents(seconds, nanos);
        return .{
            .seconds = normalized.seconds,
            .nanos = normalized.nanos,
        };
    }
};

pub const Timestamp = struct {
    seconds: i64,
    nanos: u32,

    pub fn fromComponents(seconds: i64, nanos: i64) Error!Timestamp {
        const normalized = try normalizeTimestampComponents(seconds, nanos);
        return .{
            .seconds = normalized.seconds,
            .nanos = @intCast(normalized.nanos),
        };
    }
};

pub const DateTimeFields = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

pub fn parseDuration(text: []const u8) Error!Duration {
    if (text.len == 0) return Error.InvalidDuration;
    if (std.mem.eql(u8, text, "0")) return .{ .seconds = 0, .nanos = 0 };

    var index: usize = 0;
    var negative = false;
    if (text[index] == '+' or text[index] == '-') {
        negative = text[index] == '-';
        index += 1;
    }
    if (index >= text.len) return Error.InvalidDuration;

    var total_nanos: i128 = 0;
    var saw_component = false;
    while (index < text.len) {
        const number_start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
        const saw_digits = index > number_start;

        var fraction_start: ?usize = null;
        if (index < text.len and text[index] == '.') {
            fraction_start = index + 1;
            index += 1;
            while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
            if (fraction_start.? == index) return Error.InvalidDuration;
        }
        if (!saw_digits and fraction_start == null) return Error.InvalidDuration;

        const unit = parseDurationUnit(text[index..]) orelse return Error.InvalidDuration;
        index += unit.text.len;
        saw_component = true;

        const whole_end = if (fraction_start) |frac_start| frac_start - 1 else index - unit.text.len;
        const whole_value = if (saw_digits)
            std.fmt.parseInt(i128, text[number_start..whole_end], 10) catch return Error.InvalidDuration
        else
            0;
        var component = whole_value * @as(i128, unit.nanos);

        if (fraction_start) |frac_start| {
            const frac_text = text[frac_start .. index - unit.text.len];
            var denom: i128 = 1;
            var frac_value: i128 = 0;
            for (frac_text) |ch| {
                denom *= 10;
                frac_value = (frac_value * 10) + (ch - '0');
            }
            component += @divTrunc(@as(i128, unit.nanos) * frac_value, denom);
        }

        total_nanos += component;
    }

    if (!saw_component) return Error.InvalidDuration;
    if (negative) total_nanos = -total_nanos;

    const seconds = std.math.cast(i64, @divTrunc(total_nanos, nanos_per_second)) orelse return Error.InvalidDuration;
    const nanos = std.math.cast(i64, @rem(total_nanos, nanos_per_second)) orelse return Error.InvalidDuration;
    return Duration.fromComponents(seconds, nanos) catch Error.InvalidDuration;
}

pub fn formatDuration(allocator: std.mem.Allocator, duration: Duration) ![]u8 {
    if (duration.seconds == 0 and duration.nanos == 0) return allocator.dupe(u8, "0s");

    const negative = duration.seconds < 0 or duration.nanos < 0;
    const abs_seconds: u64 = if (negative)
        @intCast(-(@as(i128, duration.seconds)))
    else
        @intCast(duration.seconds);
    const abs_nanos: u32 = if (negative)
        @intCast(-@as(i64, duration.nanos))
    else
        @intCast(duration.nanos);

    if (abs_nanos == 0) {
        return std.fmt.allocPrint(allocator, "{s}{d}s", .{
            if (negative) "-" else "",
            abs_seconds,
        });
    }

    var frac_buffer: [9]u8 = undefined;
    var frac: u32 = abs_nanos;
    var i: usize = frac_buffer.len;
    while (i > 0) {
        i -= 1;
        frac_buffer[i] = @intCast('0' + @as(u8, @intCast(frac % 10)));
        frac /= 10;
    }
    var frac_end = frac_buffer.len;
    while (frac_end > 0 and frac_buffer[frac_end - 1] == '0') : (frac_end -= 1) {}

    return std.fmt.allocPrint(allocator, "{s}{d}.{s}s", .{
        if (negative) "-" else "",
        abs_seconds,
        frac_buffer[0..frac_end],
    });
}

pub fn parseTimestamp(text: []const u8) Error!Timestamp {
    if (text.len < 20) return Error.InvalidTimestamp;

    const year = try parseFixedInt(text, 0, 4, Error.InvalidTimestamp);
    if (text[4] != '-') return Error.InvalidTimestamp;
    const month = try parseFixedInt(text, 5, 2, Error.InvalidTimestamp);
    if (text[7] != '-') return Error.InvalidTimestamp;
    const day = try parseFixedInt(text, 8, 2, Error.InvalidTimestamp);
    if (text[10] != 'T' and text[10] != 't') return Error.InvalidTimestamp;
    const hour = try parseFixedInt(text, 11, 2, Error.InvalidTimestamp);
    if (text[13] != ':') return Error.InvalidTimestamp;
    const minute = try parseFixedInt(text, 14, 2, Error.InvalidTimestamp);
    if (text[16] != ':') return Error.InvalidTimestamp;
    const second = try parseFixedInt(text, 17, 2, Error.InvalidTimestamp);

    if (year < 1 or year > 9999) return Error.InvalidTimestamp;
    if (month < 1 or month > 12) return Error.InvalidTimestamp;
    if (day < 1 or day > daysInMonth(year, @intCast(month))) return Error.InvalidTimestamp;
    if (hour > 23 or minute > 59 or second > 59) return Error.InvalidTimestamp;

    var index: usize = 19;
    var nanos: i64 = 0;
    if (index < text.len and text[index] == '.') {
        index += 1;
        const frac_start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
        if (frac_start == index) return Error.InvalidTimestamp;
        nanos = try parseFractionalNanos(text[frac_start..index]);
    }

    const offset_seconds = try parseTimeZoneOffset(text[index..]);
    const day_count = daysFromCivil(year, @intCast(month), @intCast(day));
    const day_seconds = (@as(i64, hour) * 3600) + (@as(i64, minute) * 60) + @as(i64, second);
    const utc_seconds = std.math.sub(i64, std.math.add(i64, day_count * seconds_per_day, day_seconds) catch return Error.Overflow, offset_seconds) catch return Error.Overflow;
    return Timestamp.fromComponents(utc_seconds, nanos) catch Error.InvalidTimestamp;
}

pub fn formatTimestamp(allocator: std.mem.Allocator, ts: Timestamp) ![]u8 {
    const fields = timestampFields(ts, null) catch unreachable;
    if (ts.nanos == 0) {
        return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            @as(u32, @intCast(fields.year)),
            fields.month,
            fields.day,
            fields.hour,
            fields.minute,
            fields.second,
        });
    }

    var frac_buffer: [9]u8 = undefined;
    var frac: u32 = ts.nanos;
    var i: usize = frac_buffer.len;
    while (i > 0) {
        i -= 1;
        frac_buffer[i] = @intCast('0' + @as(u8, @intCast(frac % 10)));
        frac /= 10;
    }
    var frac_end = frac_buffer.len;
    while (frac_end > 0 and frac_buffer[frac_end - 1] == '0') : (frac_end -= 1) {}

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{s}Z", .{
        @as(u32, @intCast(fields.year)),
        fields.month,
        fields.day,
        fields.hour,
        fields.minute,
        fields.second,
        frac_buffer[0..frac_end],
    });
}

pub fn parseTimeZone(text: ?[]const u8) Error!i32 {
    if (text == null) return 0;
    return parseTimeZoneOffset(text.?);
}

pub fn timestampFields(ts: Timestamp, timezone: ?[]const u8) Error!DateTimeFields {
    const offset = try resolveTimeZoneOffsetAt(timezone, ts.seconds);
    const shifted = std.math.add(i64, ts.seconds, offset) catch return Error.Overflow;
    const day = floorDiv(shifted, seconds_per_day);
    const seconds_in_day = shifted - (day * seconds_per_day);
    const civil = civilFromDays(day);
    return .{
        .year = civil.year,
        .month = civil.month,
        .day = civil.day,
        .hour = @intCast(@divTrunc(seconds_in_day, 3600)),
        .minute = @intCast(@divTrunc(@rem(seconds_in_day, 3600), 60)),
        .second = @intCast(@rem(seconds_in_day, 60)),
    };
}

pub fn timestampDayOfWeek(ts: Timestamp, timezone: ?[]const u8) Error!i64 {
    const offset = try resolveTimeZoneOffsetAt(timezone, ts.seconds);
    const shifted = std.math.add(i64, ts.seconds, offset) catch return Error.Overflow;
    const day = floorDiv(shifted, seconds_per_day);
    return positiveMod(day + 4, 7);
}

pub fn timestampDayOfYear(ts: Timestamp, timezone: ?[]const u8) Error!i64 {
    const fields = try timestampFields(ts, timezone);
    return dayOfYear(fields.year, fields.month, fields.day);
}

pub fn durationHours(duration: Duration) i64 {
    return @divTrunc(duration.seconds, 60 * 60);
}

pub fn durationMinutes(duration: Duration) i64 {
    return @divTrunc(duration.seconds, 60);
}

pub fn durationSeconds(duration: Duration) i64 {
    return duration.seconds;
}

pub fn durationMillisecondsPortion(duration: Duration) i64 {
    return @divTrunc(duration.nanos, nanos_per_millisecond);
}

pub fn addDurations(lhs: Duration, rhs: Duration) Error!Duration {
    return Duration.fromComponents(
        std.math.add(i64, lhs.seconds, rhs.seconds) catch return Error.Overflow,
        @as(i64, lhs.nanos) + @as(i64, rhs.nanos),
    ) catch |err| switch (err) {
        Error.InvalidDuration => Error.Overflow,
        else => err,
    };
}

pub fn subDurations(lhs: Duration, rhs: Duration) Error!Duration {
    return addDurations(lhs, try negateDuration(rhs));
}

pub fn addDurationToTimestamp(ts: Timestamp, duration: Duration) Error!Timestamp {
    return Timestamp.fromComponents(
        std.math.add(i64, ts.seconds, duration.seconds) catch return Error.Overflow,
        @as(i64, ts.nanos) + @as(i64, duration.nanos),
    ) catch |err| switch (err) {
        Error.InvalidTimestamp => Error.Overflow,
        else => err,
    };
}

pub fn subDurationFromTimestamp(ts: Timestamp, duration: Duration) Error!Timestamp {
    return addDurationToTimestamp(ts, try negateDuration(duration));
}

pub fn diffTimestamps(lhs: Timestamp, rhs: Timestamp) Error!Duration {
    const seconds = std.math.sub(i64, lhs.seconds, rhs.seconds) catch return Error.Overflow;
    const nanos = @as(i64, lhs.nanos) - @as(i64, rhs.nanos);
    const total_nanos = std.math.add(i128, @as(i128, seconds) * nanos_per_second, nanos) catch return Error.Overflow;
    _ = std.math.cast(i64, total_nanos) orelse return Error.Overflow;
    return Duration.fromComponents(seconds, nanos) catch |err| switch (err) {
        Error.InvalidDuration => Error.Overflow,
        else => err,
    };
}

const DurationUnit = struct {
    text: []const u8,
    nanos: i64,
};

fn parseDurationUnit(text: []const u8) ?DurationUnit {
    const units = [_]DurationUnit{
        .{ .text = "ms", .nanos = nanos_per_millisecond },
        .{ .text = "us", .nanos = 1_000 },
        .{ .text = "ns", .nanos = 1 },
        .{ .text = "h", .nanos = nanos_per_hour },
        .{ .text = "m", .nanos = nanos_per_minute },
        .{ .text = "s", .nanos = nanos_per_second },
    };
    for (units) |unit| {
        if (std.mem.startsWith(u8, text, unit.text)) return unit;
    }
    return null;
}

fn parseFractionalNanos(text: []const u8) Error!i64 {
    if (text.len == 0) return 0;
    var nanos: i64 = 0;
    var consumed: usize = 0;
    while (consumed < text.len and consumed < 9) : (consumed += 1) {
        nanos = (nanos * 10) + (text[consumed] - '0');
    }
    while (consumed < 9) : (consumed += 1) {
        nanos *= 10;
    }
    return nanos;
}

fn parseFixedInt(text: []const u8, start: usize, len: usize, invalid: Error) Error!i32 {
    if (start + len > text.len) return invalid;
    for (text[start .. start + len]) |ch| {
        if (!std.ascii.isDigit(ch)) return invalid;
    }
    return std.fmt.parseInt(i32, text[start .. start + len], 10) catch invalid;
}

fn resolveTimeZoneOffsetAt(text: ?[]const u8, unix_seconds: i64) Error!i32 {
    if (text == null) return 0;
    return parseTimeZoneOffset(text.?) catch |err| switch (err) {
        Error.UnsupportedTimeZone => try loadNamedTimeZoneOffset(text.?, unix_seconds),
        else => return err,
    };
}

fn parseTimeZoneOffset(text: []const u8) Error!i32 {
    if (text.len == 1 and (text[0] == 'Z' or text[0] == 'z')) return 0;
    if (std.mem.eql(u8, text, "UTC") or std.mem.eql(u8, text, "GMT")) return 0;

    var sign: i32 = 1;
    var start: usize = 0;
    if (text.len != 5 and text.len != 6) return Error.UnsupportedTimeZone;
    if (text[0] == '+' or text[0] == '-') {
        sign = if (text[0] == '-') -1 else 1;
        start = 1;
    }
    if (text.len - start != 5 or text[start + 2] != ':') return Error.UnsupportedTimeZone;

    const hours = parseFixedInt(text, start, 2, Error.UnsupportedTimeZone) catch return Error.UnsupportedTimeZone;
    const minutes = parseFixedInt(text, start + 3, 2, Error.UnsupportedTimeZone) catch return Error.UnsupportedTimeZone;
    if (hours > 23 or minutes > 59) return Error.UnsupportedTimeZone;
    const total: i32 = (hours * 3600) + (minutes * 60);
    return sign * total;
}

fn loadNamedTimeZoneOffset(name: []const u8, unix_seconds: i64) Error!i32 {
    if (!isSafeTimeZoneName(name)) return Error.UnsupportedTimeZone;

    const roots = [_][]const u8{
        "/usr/share/zoneinfo",
        "/var/db/timezone/zoneinfo",
    };

    var path_buffer: [512]u8 = undefined;
    for (roots) |root| {
        const path_z = std.fmt.bufPrintZ(path_buffer[0..path_buffer.len -| 1], "{s}/{s}", .{ root, name }) catch return Error.UnsupportedTimeZone;
        const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) continue;
        defer _ = std.c.close(fd);

        var buffer: [256 * 1024]u8 = undefined;
        var len: usize = 0;
        while (len < buffer.len) {
            const rc = std.c.read(fd, @ptrCast(buffer[len..].ptr), buffer.len - len);
            if (rc <= 0) break;
            len += @intCast(rc);
        }
        return parseTzifOffset(buffer[0..len], unix_seconds);
    }
    return Error.UnsupportedTimeZone;
}

fn parseTzifOffset(data: []const u8, unix_seconds: i64) Error!i32 {
    const section = try selectTzifSection(data);
    return readTzifOffset(data, section, unix_seconds);
}

const TzifCounts = struct {
    ttisgmtcnt: u32,
    ttisstdcnt: u32,
    leapcnt: u32,
    timecnt: u32,
    typecnt: u32,
    charcnt: u32,
};

const TzifSection = struct {
    offset: usize,
    counts: TzifCounts,
    is64: bool,
};

fn selectTzifSection(data: []const u8) Error!TzifSection {
    const first = try parseTzifHeader(data, 0);
    if (first.version >= '2') {
        const second_header_offset = try skipTzifData(data, first.next, first.counts, false);
        const second = try parseTzifHeader(data, second_header_offset);
        return .{
            .offset = second.next,
            .counts = second.counts,
            .is64 = true,
        };
    }
    return .{
        .offset = first.next,
        .counts = first.counts,
        .is64 = false,
    };
}

fn parseTzifHeader(data: []const u8, offset: usize) Error!struct {
    version: u8,
    counts: TzifCounts,
    next: usize,
} {
    if (offset + 44 > data.len) return Error.UnsupportedTimeZone;
    if (!std.mem.eql(u8, data[offset .. offset + 4], "TZif")) return Error.UnsupportedTimeZone;
    return .{
        .version = data[offset + 4],
        .counts = .{
            .ttisgmtcnt = try readU32BE(data, offset + 20),
            .ttisstdcnt = try readU32BE(data, offset + 24),
            .leapcnt = try readU32BE(data, offset + 28),
            .timecnt = try readU32BE(data, offset + 32),
            .typecnt = try readU32BE(data, offset + 36),
            .charcnt = try readU32BE(data, offset + 40),
        },
        .next = offset + 44,
    };
}

fn skipTzifData(data: []const u8, offset: usize, counts: TzifCounts, is64: bool) Error!usize {
    const time_size: usize = if (is64) 8 else 4;
    const leap_size: usize = if (is64) 12 else 8;

    var cursor = offset;
    cursor += counts.timecnt * time_size;
    cursor += counts.timecnt;
    cursor += counts.typecnt * 6;
    cursor += counts.charcnt;
    cursor += counts.leapcnt * leap_size;
    cursor += counts.ttisstdcnt;
    cursor += counts.ttisgmtcnt;
    if (cursor > data.len) return Error.UnsupportedTimeZone;
    return cursor;
}

fn readTzifOffset(data: []const u8, section: TzifSection, unix_seconds: i64) Error!i32 {
    const time_size: usize = if (section.is64) 8 else 4;
    const transitions_offset = section.offset;
    const indexes_offset = transitions_offset + section.counts.timecnt * time_size;
    const infos_offset = indexes_offset + section.counts.timecnt;
    if (infos_offset + section.counts.typecnt * 6 > data.len) return Error.UnsupportedTimeZone;
    if (section.counts.typecnt == 0) return Error.UnsupportedTimeZone;

    var type_index: usize = chooseInitialTzifType(data, infos_offset, section.counts.typecnt);
    var i: usize = 0;
    while (i < section.counts.timecnt) : (i += 1) {
        const transition = if (section.is64)
            try readI64BE(data, transitions_offset + i * 8)
        else
            @as(i64, try readI32BE(data, transitions_offset + i * 4));
        if (unix_seconds < transition) break;
        const idx_offset = indexes_offset + i;
        if (idx_offset >= data.len) return Error.UnsupportedTimeZone;
        type_index = data[idx_offset];
    }

    if (type_index >= section.counts.typecnt) return Error.UnsupportedTimeZone;
    const info_offset = infos_offset + type_index * 6;
    return try readI32BE(data, info_offset);
}

fn chooseInitialTzifType(data: []const u8, infos_offset: usize, type_count: u32) usize {
    var i: usize = 0;
    while (i < type_count) : (i += 1) {
        const isdst_offset = infos_offset + i * 6 + 4;
        if (isdst_offset < data.len and data[isdst_offset] == 0) return i;
    }
    return 0;
}

fn readU32BE(data: []const u8, offset: usize) Error!u32 {
    if (offset + 4 > data.len) return Error.UnsupportedTimeZone;
    return std.mem.readInt(u32, data[offset .. offset + 4][0..4], .big);
}

fn readI32BE(data: []const u8, offset: usize) Error!i32 {
    if (offset + 4 > data.len) return Error.UnsupportedTimeZone;
    return std.mem.readInt(i32, data[offset .. offset + 4][0..4], .big);
}

fn readI64BE(data: []const u8, offset: usize) Error!i64 {
    if (offset + 8 > data.len) return Error.UnsupportedTimeZone;
    return std.mem.readInt(i64, data[offset .. offset + 8][0..8], .big);
}

fn isSafeTimeZoneName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '/') return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch)) continue;
        switch (ch) {
            '/', '_', '-', '+', '.' => continue,
            else => return false,
        }
    }
    return true;
}

fn negateDuration(duration: Duration) Error!Duration {
    return Duration.fromComponents(
        std.math.negate(duration.seconds) catch return Error.Overflow,
        -@as(i64, duration.nanos),
    );
}

fn normalizeDurationComponents(seconds: i64, nanos: i64) Error!struct {
    seconds: i64,
    nanos: i32,
} {
    var sec = seconds;
    var ns = nanos;
    if (ns <= -nanos_per_second or ns >= nanos_per_second) {
        const extra = floorDiv(ns, nanos_per_second);
        sec = std.math.add(i64, sec, extra) catch return Error.Overflow;
        ns -= extra * nanos_per_second;
    }
    if (sec > 0 and ns < 0) {
        sec = std.math.sub(i64, sec, 1) catch return Error.Overflow;
        ns += nanos_per_second;
    } else if (sec < 0 and ns > 0) {
        sec = std.math.add(i64, sec, 1) catch return Error.Overflow;
        ns -= nanos_per_second;
    }
    if (!isValidDuration(sec, ns)) return Error.InvalidDuration;
    return .{
        .seconds = sec,
        .nanos = @intCast(ns),
    };
}

fn normalizeTimestampComponents(seconds: i64, nanos: i64) Error!struct {
    seconds: i64,
    nanos: i64,
} {
    var sec = seconds;
    var ns = nanos;
    if (ns <= -nanos_per_second or ns >= nanos_per_second) {
        const extra = floorDiv(ns, nanos_per_second);
        sec = std.math.add(i64, sec, extra) catch return Error.Overflow;
        ns -= extra * nanos_per_second;
    }
    if (ns < 0) {
        sec = std.math.sub(i64, sec, 1) catch return Error.Overflow;
        ns += nanos_per_second;
    }
    if (sec < timestamp_min_seconds or sec > timestamp_max_seconds) return Error.InvalidTimestamp;
    return .{
        .seconds = sec,
        .nanos = ns,
    };
}

fn isValidDuration(seconds: i64, nanos: i64) bool {
    if (nanos <= -nanos_per_second or nanos >= nanos_per_second) return false;
    if (seconds > 0 and nanos < 0) return false;
    if (seconds < 0 and nanos > 0) return false;

    const abs_seconds: u64 = if (seconds < 0)
        @intCast(-(@as(i128, seconds)))
    else
        @intCast(seconds);
    if (abs_seconds > max_duration_seconds) return false;
    if (abs_seconds == max_duration_seconds and nanos != 0) return false;
    return true;
}

const CivilDate = struct {
    year: i32,
    month: u8,
    day: u8,
};

fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1 => 31,
        2 => if (isLeapYear(year)) 29 else 28,
        3 => 31,
        4 => 30,
        5 => 31,
        6 => 30,
        7 => 31,
        8 => 31,
        9 => 30,
        10 => 31,
        11 => 30,
        12 => 31,
        else => 0,
    };
}

fn isLeapYear(year: i32) bool {
    if (@mod(year, 4) != 0) return false;
    if (@mod(year, 100) != 0) return true;
    return @mod(year, 400) == 0;
}

fn dayOfYear(year: i32, month: u8, day: u8) i64 {
    var total: i64 = 0;
    var current: u8 = 1;
    while (current < month) : (current += 1) {
        total += daysInMonth(year, current);
    }
    return total + day - 1;
}

fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    var y = year;
    const m: i32 = month;
    y -= if (m <= 2) 1 else 0;
    const era = if (y >= 0) @divTrunc(y, 400) else @divTrunc(y - 399, 400);
    const yoe = y - era * 400;
    const month_adjust: i32 = if (m > 2) -3 else 9;
    const mp = m + month_adjust;
    const doy = @divTrunc(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return @as(i64, era) * 146097 + doe - 719468;
}

fn civilFromDays(days: i64) CivilDate {
    const z = days + 719468;
    const era = if (z >= 0) @divTrunc(z, 146097) else @divTrunc(z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    var year: i32 = @intCast(yoe + era * 400);
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const day: u8 = @intCast(doy - @divTrunc(153 * mp + 2, 5) + 1);
    const month_adjust: i64 = if (mp < 10) 3 else -9;
    const month: u8 = @intCast(mp + month_adjust);
    year += if (month <= 2) 1 else 0;
    return .{
        .year = year,
        .month = month,
        .day = day,
    };
}

fn floorDiv(num: i64, den: i64) i64 {
    var quot = @divTrunc(num, den);
    const rem = @rem(num, den);
    if (rem != 0 and ((rem > 0) != (den > 0))) {
        quot -= 1;
    }
    return quot;
}

fn positiveMod(value: i64, modulus: i64) i64 {
    const rem = @mod(value, modulus);
    return if (rem < 0) rem + modulus else rem;
}

test "duration parsing and formatting work with full range semantics" {
    const duration = try parseDuration("-1.5h");
    try std.testing.expectEqual(@as(i64, -5400), duration.seconds);
    try std.testing.expectEqual(@as(i32, 0), duration.nanos);

    const text = try formatDuration(std.testing.allocator, try parseDuration("1m1ms"));
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("60.001s", text);

    try std.testing.expectError(Error.InvalidDuration, parseDuration("320000000000s"));
}

test "timestamp parsing and accessors work in utc and fixed offsets" {
    const ts = try parseTimestamp("2023-12-25T00:00:00.500-08:00");
    const utc = try timestampFields(ts, null);
    try std.testing.expectEqual(@as(i32, 2023), utc.year);
    try std.testing.expectEqual(@as(u8, 25), utc.day);
    try std.testing.expectEqual(@as(u8, 8), utc.hour);
    try std.testing.expectEqual(@as(i64, 1), try timestampDayOfWeek(ts, null));

    const local = try timestampFields(ts, "-08:00");
    try std.testing.expectEqual(@as(u8, 25), local.day);
    try std.testing.expectEqual(@as(u8, 0), local.hour);

    const rendered = try formatTimestamp(std.testing.allocator, ts);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("2023-12-25T08:00:00.5Z", rendered);
}

test "timestamp named timezone offsets are read from zoneinfo" {
    const ts = try parseTimestamp("2009-02-13T23:31:30Z");
    const sydney = try timestampFields(ts, "Australia/Sydney");
    try std.testing.expectEqual(@as(u8, 14), sydney.day);
    try std.testing.expectEqual(@as(u8, 10), sydney.hour);

    const kathmandu = try timestampFields(ts, "Asia/Kathmandu");
    try std.testing.expectEqual(@as(u8, 5), kathmandu.hour);
    try std.testing.expectEqual(@as(u8, 16), kathmandu.minute);
}

test "duration parsing table-driven" {
    const cases = [_]struct { text: []const u8, seconds: i64, nanos: i32 }{
        .{ .text = "0", .seconds = 0, .nanos = 0 },
        .{ .text = "1s", .seconds = 1, .nanos = 0 },
        .{ .text = "1.5s", .seconds = 1, .nanos = 500_000_000 },
        .{ .text = "1m", .seconds = 60, .nanos = 0 },
        .{ .text = "1h", .seconds = 3600, .nanos = 0 },
        .{ .text = "1h30m", .seconds = 5400, .nanos = 0 },
        .{ .text = "-1s", .seconds = -1, .nanos = 0 },
        .{ .text = "-1.5s", .seconds = -1, .nanos = -500_000_000 },
        .{ .text = "-2h", .seconds = -7200, .nanos = 0 },
        .{ .text = "+3s", .seconds = 3, .nanos = 0 },
        .{ .text = "500ms", .seconds = 0, .nanos = 500_000_000 },
        .{ .text = "1000ms", .seconds = 1, .nanos = 0 },
        .{ .text = "1us", .seconds = 0, .nanos = 1_000 },
        .{ .text = "1ns", .seconds = 0, .nanos = 1 },
        .{ .text = "1h1m1s", .seconds = 3661, .nanos = 0 },
        .{ .text = "0.001s", .seconds = 0, .nanos = 1_000_000 },
    };
    for (cases) |case| {
        const d = try parseDuration(case.text);
        try std.testing.expectEqual(case.seconds, d.seconds);
        try std.testing.expectEqual(case.nanos, d.nanos);
    }
}

test "duration parsing rejects invalid inputs" {
    const invalid = [_][]const u8{
        "",
        "abc",
        "s",
        "1",
        "1x",
        "1.s",
        "--1s",
        "320000000000s", // exceeds max
    };
    for (invalid) |text| {
        try std.testing.expectError(Error.InvalidDuration, parseDuration(text));
    }
}

test "duration formatting roundtrip" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "0", .expected = "0s" },
        .{ .input = "1s", .expected = "1s" },
        .{ .input = "1m1ms", .expected = "60.001s" },
        .{ .input = "1h", .expected = "3600s" },
        .{ .input = "-2s", .expected = "-2s" },
        .{ .input = "500ms", .expected = "0.5s" },
    };
    for (cases) |case| {
        const d = try parseDuration(case.input);
        const text = try formatDuration(std.testing.allocator, d);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(case.expected, text);
    }
}

test "timestamp parsing various RFC3339 formats" {
    const cases = [_]struct { text: []const u8, year: i32, month: u8, day: u8, hour: u8, minute: u8, second: u8 }{
        .{ .text = "2023-01-15T10:30:00Z", .year = 2023, .month = 1, .day = 15, .hour = 10, .minute = 30, .second = 0 },
        .{ .text = "2000-06-15T00:00:00Z", .year = 2000, .month = 6, .day = 15, .hour = 0, .minute = 0, .second = 0 },
        .{ .text = "1999-12-31T23:59:59Z", .year = 1999, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59 },
        .{ .text = "2024-02-29T12:00:00Z", .year = 2024, .month = 2, .day = 29, .hour = 12, .minute = 0, .second = 0 }, // leap year
        .{ .text = "2023-07-04T18:00:00+05:30", .year = 2023, .month = 7, .day = 4, .hour = 12, .minute = 30, .second = 0 }, // offset applied
        .{ .text = "2023-01-01T05:00:00-05:00", .year = 2023, .month = 1, .day = 1, .hour = 10, .minute = 0, .second = 0 }, // negative offset
    };
    for (cases) |case| {
        const ts = try parseTimestamp(case.text);
        const fields = try timestampFields(ts, null);
        try std.testing.expectEqual(case.year, fields.year);
        try std.testing.expectEqual(case.month, fields.month);
        try std.testing.expectEqual(case.day, fields.day);
        try std.testing.expectEqual(case.hour, fields.hour);
        try std.testing.expectEqual(case.minute, fields.minute);
        try std.testing.expectEqual(case.second, fields.second);
    }
}

test "timestamp parsing with fractional seconds" {
    const ts = try parseTimestamp("2023-06-15T12:30:45.123456789Z");
    try std.testing.expectEqual(@as(u32, 123_456_789), ts.nanos);
    const fields = try timestampFields(ts, null);
    try std.testing.expectEqual(@as(u8, 45), fields.second);

    const ts2 = try parseTimestamp("2023-06-15T12:30:45.5Z");
    try std.testing.expectEqual(@as(u32, 500_000_000), ts2.nanos);

    const ts3 = try parseTimestamp("2023-06-15T12:30:45.000001Z");
    try std.testing.expectEqual(@as(u32, 1_000), ts3.nanos);
}

test "timestamp parsing rejects invalid inputs" {
    const invalid = [_][]const u8{
        "",
        "not-a-timestamp",
        "2023-13-01T00:00:00Z", // month 13
        "2023-00-01T00:00:00Z", // month 0
        "2023-01-32T00:00:00Z", // day 32
        "2023-02-29T00:00:00Z", // not a leap year
        "2023-01-01T24:00:00Z", // hour 24
        "2023-01-01T00:60:00Z", // minute 60
        "2023-01-01T00:00:60Z", // second 60
        "2023-01-01T00:00:00",  // missing timezone
    };
    for (invalid) |text| {
        try std.testing.expectError(Error.InvalidTimestamp, parseTimestamp(text));
    }
}

test "timestamp field accessors day of week and day of year" {
    // 2023-01-15 is a Sunday (day 0)
    const ts1 = try parseTimestamp("2023-01-15T00:00:00Z");
    try std.testing.expectEqual(@as(i64, 0), try timestampDayOfWeek(ts1, null));
    try std.testing.expectEqual(@as(i64, 14), try timestampDayOfYear(ts1, null)); // Jan 15 = day 14 (0-indexed)

    // 2023-01-16 is a Monday (day 1)
    const ts2 = try parseTimestamp("2023-01-16T00:00:00Z");
    try std.testing.expectEqual(@as(i64, 1), try timestampDayOfWeek(ts2, null));

    // 2023-12-31 is day 364 of the year (0-indexed)
    const ts3 = try parseTimestamp("2023-12-31T00:00:00Z");
    try std.testing.expectEqual(@as(i64, 364), try timestampDayOfYear(ts3, null));

    // 2024-12-31 is day 365 (leap year, 0-indexed)
    const ts4 = try parseTimestamp("2024-12-31T00:00:00Z");
    try std.testing.expectEqual(@as(i64, 365), try timestampDayOfYear(ts4, null));
}

test "timestamp arithmetic with durations" {
    const ts = try parseTimestamp("2023-06-15T12:00:00Z");
    const one_hour = try parseDuration("1h");
    const thirty_min = try parseDuration("30m");

    // timestamp + duration
    const ts_plus = try addDurationToTimestamp(ts, one_hour);
    const fields_plus = try timestampFields(ts_plus, null);
    try std.testing.expectEqual(@as(u8, 13), fields_plus.hour);

    // timestamp - duration
    const ts_minus = try subDurationFromTimestamp(ts, thirty_min);
    const fields_minus = try timestampFields(ts_minus, null);
    try std.testing.expectEqual(@as(u8, 11), fields_minus.hour);
    try std.testing.expectEqual(@as(u8, 30), fields_minus.minute);

    // timestamp - timestamp = duration
    const diff = try diffTimestamps(ts_plus, ts);
    try std.testing.expectEqual(@as(i64, 3600), diff.seconds);
    try std.testing.expectEqual(@as(i32, 0), diff.nanos);
}

test "duration field accessors" {
    const d = try parseDuration("2h30m15s");
    try std.testing.expectEqual(@as(i64, 2), durationHours(d));
    try std.testing.expectEqual(@as(i64, 150), durationMinutes(d)); // 2*60 + 30
    try std.testing.expectEqual(@as(i64, 9015), durationSeconds(d)); // 2*3600 + 30*60 + 15

    const d2 = try parseDuration("1.5s");
    try std.testing.expectEqual(@as(i64, 1), durationSeconds(d2));
    try std.testing.expectEqual(@as(i64, 500), durationMillisecondsPortion(d2));

    const d3 = try parseDuration("-1.5s");
    try std.testing.expectEqual(@as(i64, -1), durationSeconds(d3));
    try std.testing.expectEqual(@as(i64, -500), durationMillisecondsPortion(d3));
}

test "duration arithmetic" {
    const d1 = try parseDuration("1h");
    const d2 = try parseDuration("30m");

    const sum = try addDurations(d1, d2);
    try std.testing.expectEqual(@as(i64, 5400), sum.seconds);

    const diff = try subDurations(d1, d2);
    try std.testing.expectEqual(@as(i64, 1800), diff.seconds);
}

test "timestamp formatting roundtrip" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "2023-01-15T10:30:00Z", .expected = "2023-01-15T10:30:00Z" },
        .{ .input = "2023-06-15T12:30:45.5Z", .expected = "2023-06-15T12:30:45.5Z" },
        .{ .input = "2000-01-01T00:00:00Z", .expected = "2000-01-01T00:00:00Z" },
    };
    for (cases) |case| {
        const ts = try parseTimestamp(case.input);
        const text = try formatTimestamp(std.testing.allocator, ts);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(case.expected, text);
    }
}

test "timestamp comparison via field ordering" {
    const ts1 = try parseTimestamp("2023-01-01T00:00:00Z");
    const ts2 = try parseTimestamp("2023-06-15T12:00:00Z");
    const ts3 = try parseTimestamp("2023-01-01T00:00:00Z"); // same as ts1

    // ts1 < ts2
    try std.testing.expect(ts1.seconds < ts2.seconds);
    // ts1 == ts3
    try std.testing.expectEqual(ts1.seconds, ts3.seconds);
    try std.testing.expectEqual(ts1.nanos, ts3.nanos);
    // ts2 > ts1
    try std.testing.expect(ts2.seconds > ts1.seconds);
}

test "timestamp and duration CEL eval integration" {
    const compile_mod = @import("../compiler/compile.zig");
    const eval_impl = @import("../eval/eval.zig");
    const env_mod = @import("../env/env.zig");
    const Activation = @import("../eval/activation.zig").Activation;

    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    // Test timestamp field accessors via CEL expressions returning int
    const int_cases = [_]struct { expr: []const u8, expected: i64 }{
        .{ .expr = "timestamp('2023-01-15T10:30:00Z').getFullYear()", .expected = 2023 },
        .{ .expr = "timestamp('2023-01-15T10:30:00Z').getMonth()", .expected = 0 }, // 0-indexed
        .{ .expr = "timestamp('2023-01-15T10:30:00Z').getDayOfMonth()", .expected = 14 }, // 0-indexed
        .{ .expr = "timestamp('2023-01-15T10:30:00Z').getHours()", .expected = 10 },
        .{ .expr = "timestamp('2023-01-15T10:30:00Z').getMinutes()", .expected = 30 },
        .{ .expr = "timestamp('2023-01-15T10:30:00Z').getSeconds()", .expected = 0 },
        .{ .expr = "timestamp('2023-01-16T00:00:00Z').getDayOfWeek()", .expected = 1 }, // Monday
        .{ .expr = "timestamp('2023-01-01T00:00:00Z').getDayOfYear()", .expected = 0 }, // Jan 1 = 0
        .{ .expr = "duration('1h').getHours()", .expected = 1 },
        .{ .expr = "duration('90m').getMinutes()", .expected = 90 },
        .{ .expr = "duration('42s').getSeconds()", .expected = 42 },
        .{ .expr = "duration('1.5s').getMilliseconds()", .expected = 500 },
    };
    for (int_cases) |case| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, result.int);
    }

    // Test timestamp comparisons via CEL expressions returning bool
    const bool_cases = [_]struct { expr: []const u8, expected: bool }{
        .{ .expr = "timestamp('2023-06-15T12:00:00Z') > timestamp('2023-01-01T00:00:00Z')", .expected = true },
        .{ .expr = "timestamp('2023-01-01T00:00:00Z') < timestamp('2023-06-15T12:00:00Z')", .expected = true },
        .{ .expr = "timestamp('2023-01-01T00:00:00Z') == timestamp('2023-01-01T00:00:00Z')", .expected = true },
        .{ .expr = "timestamp('2023-01-01T00:00:00Z') != timestamp('2023-06-15T12:00:00Z')", .expected = true },
        .{ .expr = "duration('1h') > duration('30m')", .expected = true },
        .{ .expr = "duration('1h') == duration('60m')", .expected = true },
    };
    for (bool_cases) |case| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, result.bool);
    }
}
