const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
const allocator = arena.allocator();

pub fn main() void {
    var db: ?*c.sqlite3 = null;
    defer _ = c.sqlite3_close(db);
    const result = c.sqlite3_open_v2(
        "/home/jamie/preimp/preimp.db",
        //":memory:",
        &db,
        c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
        null,
    );
    check_sqlite_error(db, result);
    _ = query(db,
        \\ create table if not exists foo(a int, b text);
        \\ create table if not exists bar(a int);
        \\ select * from foo;
    );
    std.log.info("{s}", .{query(db,
        \\ select * from foo;
    )});
    std.log.info("finished", .{});
}

const SqliteValue = union(enum) {
    Integer: i64,
    Float: f64,
    Text: []const u8, // valid utf-8
    Blob: []const u8,
    Null,

    pub fn format(self: SqliteValue, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .Integer => |i| try std.fmt.format(writer, "{}", .{i}),
            .Float => |f| try std.fmt.format(writer, "{e}", .{f}),
            .Text => |t| try std.fmt.format(writer, "\"{}\"", .{std.zig.fmtEscapes(t)}),
            .Blob => |b| try std.fmt.format(writer, "0x{}", .{std.fmt.fmtSliceHexLower(b)}),
            .Null => _ = try writer.write("null"),
        }
    }
};

fn query(db: ?*c.sqlite3, sql: [:0]const u8) []const []const SqliteValue {
    var rows = std.ArrayList([]const SqliteValue).init(allocator);
    var remaining_sql: [*c]const u8 = sql;
    while (true) {
        const remaining_sql_len = sql.len - (@ptrToInt(remaining_sql) - @ptrToInt(@ptrCast([*c]const u8, sql)));
        if (remaining_sql_len == 0) break;
        var statement: ?*c.sqlite3_stmt = undefined;
        defer _ = c.sqlite3_finalize(statement);
        {
            const result = c.sqlite3_prepare_v2(
                db,
                remaining_sql,
                @intCast(c_int, remaining_sql_len),
                &statement,
                &remaining_sql,
            );
            check_sqlite_error(db, result);
        }
        while (true) {
            const result = c.sqlite3_step(statement);
            switch (result) {
                c.SQLITE_DONE => break,
                c.SQLITE_ROW => {
                    const num_columns = c.sqlite3_column_count(statement);
                    var column: c_int = 0;
                    var row = std.ArrayList(SqliteValue).init(allocator);
                    while (column < num_columns) : (column += 1) {
                        const value = switch (c.sqlite3_column_type(statement, column)) {
                            c.SQLITE_INTEGER => SqliteValue{ .Integer = c.sqlite3_column_int64(statement, column) },
                            c.SQLITE_FLOAT => SqliteValue{ .Float = c.sqlite3_column_double(statement, column) },
                            c.SQLITE_TEXT => value: {
                                const ptr = c.sqlite3_column_text(statement, column);
                                const len = @intCast(usize, c.sqlite3_column_bytes(statement, column));
                                const slice = allocator.dupe(u8, ptr[0..len]) catch std.debug.panic("OOM", .{});
                                break :value SqliteValue{ .Text = slice };
                            },
                            c.SQLITE_BLOB => value: {
                                const ptr = @ptrCast([*c]const u8, c.sqlite3_column_blob(statement, column));
                                const len = @intCast(usize, c.sqlite3_column_bytes(statement, column));
                                const slice = allocator.dupe(u8, ptr[0..len]) catch std.debug.panic("OOM", .{});
                                break :value SqliteValue{ .Blob = slice };
                            },
                            c.SQLITE_NULL => SqliteValue{ .Null = {} },
                            else => unreachable,
                        };
                        row.append(value) catch std.debug.panic("OOM", .{});
                    }
                    rows.append(row.toOwnedSlice()) catch std.debug.panic("OOM", .{});
                },
                else => check_sqlite_error(db, result),
            }
        }
    }
    return rows.toOwnedSlice();
}

fn check_sqlite_error(db: ?*c.sqlite3, result: c_int) void {
    if (result != c.SQLITE_OK) {
        std.debug.panic("{s}", .{c.sqlite3_errmsg(db)});
    }
}
