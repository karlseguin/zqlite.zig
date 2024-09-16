const std = @import("std");
const t = std.testing;
const c = @cImport(@cInclude("sqlite3.h"));

pub const OpenFlags = struct {
    pub const Create = c.SQLITE_OPEN_CREATE;
    pub const ReadOnly = c.SQLITE_OPEN_READONLY;
    pub const ReadWrite = c.SQLITE_OPEN_READWRITE;
    pub const DeleteOnClose = c.SQLITE_OPEN_DELETEONCLOSE;
    pub const Exclusive = c.SQLITE_OPEN_EXCLUSIVE;
    pub const AutoProxy = c.SQLITE_OPEN_AUTOPROXY;
    pub const Uri = c.SQLITE_OPEN_URI;
    pub const Memory = c.SQLITE_OPEN_MEMORY;
    pub const MainDB = c.SQLITE_OPEN_MAIN_DB;
    pub const TempDB = c.SQLITE_OPEN_TEMP_DB;
    pub const TransientDB = c.SQLITE_OPEN_TRANSIENT_DB;
    pub const MainJournal = c.SQLITE_OPEN_MAIN_JOURNAL;
    pub const TempJournal = c.SQLITE_OPEN_TEMP_JOURNAL;
    pub const SubJournal = c.SQLITE_OPEN_SUBJOURNAL;
    pub const SuperJournal = c.SQLITE_OPEN_SUPER_JOURNAL;
    pub const NoMutex = c.SQLITE_OPEN_NOMUTEX;
    pub const FullMutex = c.SQLITE_OPEN_FULLMUTEX;
    pub const SharedCache = c.SQLITE_OPEN_SHAREDCACHE;
    pub const PrivateCache = c.SQLITE_OPEN_PRIVATECACHE;
    pub const OpenWAL = c.SQLITE_OPEN_WAL;
    pub const NoFollow = c.SQLITE_OPEN_NOFOLLOW;
    pub const EXResCode = c.SQLITE_OPEN_EXRESCODE;
};

pub fn open(path: [*:0]const u8, flags: c_int) !Conn {
    return Conn.init(path, flags);
}

pub fn blob(value: []const u8) Blob {
    return .{ .value = value };
}

// a marker type so we can tell if the provided []const u8 should be treated as
// a text or a blob
pub const Blob = struct {
    value: []const u8,
};

pub const Conn = struct {
    conn: *c.sqlite3,

    pub fn init(path: [*:0]const u8, flags: c_int) !Conn {
        // sqlite requires either READONLY or READWRITE flag
        var full_flags = flags;
        if (flags & c.SQLITE_OPEN_READONLY != c.SQLITE_OPEN_READONLY) {
            full_flags |= c.SQLITE_OPEN_READWRITE;
        }

        var conn: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path, &conn, full_flags, null);
        if (rc != c.SQLITE_OK) {
            return errorFromCode(rc);
        }
        return .{ .conn = conn.? };
    }

    pub fn close(self: Conn) void {
        _ = c.sqlite3_close_v2(self.conn);
    }

    // in case someone cares about getting this error
    pub fn tryClose(self: Conn) !void {
        const rc = c.sqlite3_close_v2(self.conn);
        if (rc != c.SQLITE_OK) {
            return errorFromCode(rc);
        }
    }

    pub fn busyTimeout(self: Conn, ms: c_int) !void {
        const rc = c.sqlite3_busy_timeout(self.conn, ms);
        if (rc != c.SQLITE_OK) {
            return errorFromCode(rc);
        }
    }

    pub fn exec(self: Conn, sql: []const u8, values: anytype) !void {
        const stmt = try self.prepare(sql, values);
        defer stmt.deinit();
        try stmt.stepToCompletion();
    }

    pub fn execNoArgs(self: Conn, sql: [*:0]const u8) !void {
        const rc = c.sqlite3_exec(self.conn, sql, null, null, null);
        if (rc != c.SQLITE_OK) {
            return errorFromCode(rc);
        }
    }

    pub fn prepare(self: Conn, sql: []const u8, values: anytype) !Stmt {
        var n_stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.conn, sql.ptr, @intCast(sql.len), &n_stmt, null);
        if (rc != c.SQLITE_OK) {
            return errorFromCode(rc);
        }

        const stmt = n_stmt.?;
        if (values.len > 0) {
            inline for (values, 0..) |value, i| {
                try bindValue(@TypeOf(value), stmt, value, i + 1);
            }
        }

        return .{
            .stmt = stmt,
            .conn = self.conn,
        };
    }

    pub fn changes(self: Conn) usize {
        return @intCast(c.sqlite3_changes(self.conn));
    }

    pub fn lastInsertedRowId(self: Conn) i64 {
        return @intCast(c.sqlite3_last_insert_rowid(self.conn));
    }

    pub fn row(self: Conn, sql: []const u8, values: anytype) !?Row {
        const stmt = try self.prepare(sql, values);
        if (try stmt.step() == false) {
            return null;
        }
        return .{ .stmt = stmt };
    }

    pub fn rows(self: Conn, sql: []const u8, values: anytype) !Rows {
        const stmt = try self.prepare(sql, values);
        return .{ .stmt = stmt, .err = null };
    }

    pub fn transaction(self: Conn) !void {
        return self.execNoArgs("begin");
    }

    pub fn exclusiveTransaction(self: Conn) !void {
        return self.execNoArgs("begin exclusive");
    }

    pub fn commit(self: Conn) !void {
        try self.execNoArgs("commit");
    }

    pub fn rollback(self: Conn) void {
        self.execNoArgs("rollback") catch {};
    }

    pub fn lastError(self: Conn) [*:0]const u8 {
        return @as([*:0]const u8, c.sqlite3_errmsg(self.conn));
    }
};

fn bindValue(comptime T: type, stmt: *c.sqlite3_stmt, value: anytype, bind_index: c_int) !void {
    var rc: c_int = 0;

    switch (@typeInfo(T)) {
        .Null => rc = c.sqlite3_bind_null(stmt, bind_index),
        .Int, .ComptimeInt => rc = c.sqlite3_bind_int64(stmt, bind_index, @intCast(value)),
        .Float, .ComptimeFloat => rc = c.sqlite3_bind_double(stmt, bind_index, value),
        .Bool => {
            if (value) {
                rc = c.sqlite3_bind_int64(stmt, bind_index, @intCast(1));
            } else {
                rc = c.sqlite3_bind_int64(stmt, bind_index, @intCast(0));
            }
        },
        .Pointer => |ptr| {
            switch (ptr.size) {
                .One => switch (@typeInfo(ptr.child)) {
                    .Array => |arr| {
                        if (arr.child == u8) {
                            rc = c.sqlite3_bind_text(stmt, bind_index, value.ptr, @intCast(value.len), c.SQLITE_STATIC);
                        } else {
                            bindError(T);
                        }
                    },
                    else => bindError(T),
                },
                .Slice => switch (ptr.child) {
                    u8 => rc = c.sqlite3_bind_text(stmt, bind_index, value.ptr, @intCast(value.len), c.SQLITE_STATIC),
                    else => bindError(T),
                },
                else => bindError(T),
            }
        },
        .Array => return bindValue(@TypeOf(&value), stmt, &value, bind_index),
        .Optional => |opt| {
            if (value) |v| {
                return bindValue(opt.child, stmt, v, bind_index);
            } else {
                rc = c.sqlite3_bind_null(stmt, bind_index);
            }
        },
        .Struct => {
            if (T == Blob) {
                const inner = value.value;
                rc = c.sqlite3_bind_blob(stmt, bind_index, @ptrCast(inner), @intCast(inner.len), c.SQLITE_STATIC);
            } else {
                bindError(T);
            }
        },
        else => bindError(T),
    }

    if (rc != c.SQLITE_OK) {
        return errorFromCode(rc);
    }
}

fn bindError(comptime T: type) void {
    @compileError("cannot bind value of type " ++ @typeName(T));
}

pub const Stmt = struct {
    conn: *c.sqlite3,
    stmt: *c.sqlite3_stmt,

    pub fn deinit(self: Stmt) void {
        _ = c.sqlite3_finalize(self.stmt);
    }

    pub fn deinitErr(self: Stmt) !void {
        const rc = c.sqlite3_finalize(self.stmt);
        if (rc != c.SQLITE_OK) {
            return errorFromCode(rc);
        }
    }

    pub fn step(self: Stmt) !bool {
        const s = self.stmt;
        const rc = c.sqlite3_step(s);
        if (rc == c.SQLITE_DONE) {
            return false;
        }
        if (rc != c.SQLITE_ROW) {
            return errorFromCode(rc);
        }
        return true;
    }

    pub fn stepToCompletion(self: Stmt) !void {
        const stmt = self.stmt;
        while (true) {
            switch (c.sqlite3_step(stmt)) {
                c.SQLITE_DONE => return,
                c.SQLITE_ROW => continue,
                else => |rc| return errorFromCode(rc),
            }
        }
    }

    pub fn boolean(self: Stmt, index: usize) bool {
        return self.int(index) == 1;
    }
    pub fn nullableBoolean(self: Stmt, index: usize) ?bool {
        const n = self.nullableInt(index) orelse return null;
        return n == 1;
    }

    pub fn int(self: Stmt, index: usize) i64 {
        return @intCast(c.sqlite3_column_int64(self.stmt, @intCast(index)));
    }
    pub fn nullableInt(self: Stmt, index: usize) ?i64 {
        if (c.sqlite3_column_type(self.stmt, @intCast(index)) == c.SQLITE_NULL) {
            return null;
        }
        return self.int(index);
    }

    pub fn float(self: Stmt, index: usize) f64 {
        return @floatCast(c.sqlite3_column_double(self.stmt, @intCast(index)));
    }
    pub fn nullableFloat(self: Stmt, index: usize) ?f64 {
        if (c.sqlite3_column_type(self.stmt, @intCast(index)) == c.SQLITE_NULL) {
            return null;
        }
        return self.float(index);
    }

    pub fn text(self: Stmt, index: usize) []const u8 {
        const stmt = self.stmt;
        const c_index: c_int = @intCast(index);
        const data = c.sqlite3_column_text(stmt, c_index);
        const len = c.sqlite3_column_bytes(stmt, c_index);
        if (len == 0) {
            return "";
        }
        return @as([*c]const u8, @ptrCast(data))[0..@intCast(len)];
    }
    pub fn nullableText(self: Stmt, index: usize) ?[]const u8 {
        if (c.sqlite3_column_type(self.stmt, @intCast(index)) == c.SQLITE_NULL) {
            return null;
        }
        return self.text(index);
    }

    pub fn textZ(self: Stmt, index: usize) [*:0]const u8 {
        const stmt = self.stmt;
        const c_index: c_int = @intCast(index);
        return c.sqlite3_column_text(stmt, c_index);
    }
    pub fn nullableTextZ(self: Stmt, index: usize) ?[*:0]const u8 {
        if (c.sqlite3_column_type(self.stmt, @intCast(index)) == c.SQLITE_NULL) {
            return null;
        }
        return self.textZ(index);
    }
    pub fn textLen(self: Stmt, index: usize) usize {
        const stmt = self.stmt;
        const c_index: c_int = @intCast(index);
        return @intCast(c.sqlite3_column_bytes(stmt, c_index));
    }

    pub fn blob(self: Stmt, index: usize) []const u8 {
        const stmt = self.stmt;
        const c_index: c_int = @intCast(index);

        const data = c.sqlite3_column_blob(stmt, c_index);
        if (data == null) {
            return "";
        }

        const len = c.sqlite3_column_bytes(stmt, c_index);
        return @as([*c]const u8, @ptrCast(data))[0..@intCast(len)];
    }
    pub fn nullableBlob(self: Stmt, index: usize) ?[]const u8 {
        if (c.sqlite3_column_type(self.stmt, @intCast(index)) == c.SQLITE_NULL) {
            return null;
        }
        return self.blob(index);
    }

    pub fn columnCount(self: Stmt) i32 {
        return c.sqlite3_data_count(self.stmt);
    }

    pub fn columnName(self: Stmt, index: usize) [*:0]const u8 {
        return c.sqlite3_column_name(self.stmt, @intCast(index));
    }

    pub fn columnType(self: Stmt, index: usize) ColumnType {
        return switch (c.sqlite3_column_type(self.stmt, @intCast(index))) {
            1 => .int,
            2 => .float,
            3 => .text,
            4 => .blob,
            5 => .null,
            else => .unknown,
        };
    }
};

pub const ColumnType = enum { int, float, text, blob, null, unknown };

pub const Row = struct {
    stmt: Stmt,

    pub fn deinit(self: Row) void {
        self.stmt.deinit();
    }

    pub fn deinitErr(self: Row) !void {
        return self.stmt.deinitErr();
    }

    pub fn boolean(self: Row, index: usize) bool {
        return self.stmt.boolean(index);
    }
    pub fn nullableBoolean(self: Row, index: usize) ?bool {
        return self.stmt.nullableBoolean(index);
    }

    pub fn int(self: Row, index: usize) i64 {
        return self.stmt.int(index);
    }
    pub fn nullableInt(self: Row, index: usize) ?i64 {
        return self.stmt.nullableInt(index);
    }

    pub fn float(self: Row, index: usize) f64 {
        return self.stmt.float(index);
    }
    pub fn nullableFloat(self: Row, index: usize) ?f64 {
        return self.stmt.nullableFloat(index);
    }

    pub fn text(self: Row, index: usize) []const u8 {
        return self.stmt.text(index);
    }
    pub fn nullableText(self: Row, index: usize) ?[]const u8 {
        return self.stmt.nullableText(index);
    }

    pub fn textZ(self: Row, index: usize) [*:0]const u8 {
        return self.stmt.textZ(index);
    }
    pub fn nullableTextZ(self: Row, index: usize) ?[*:0]const u8 {
        return self.stmt.nullableTextZ(index);
    }
    pub fn textLen(self: Row, index: usize) usize {
        return self.stmt.textLen(index);
    }

    pub fn blob(self: Row, index: usize) []const u8 {
        return self.stmt.blob(index);
    }
    pub fn nullableBlob(self: Row, index: usize) ?[]const u8 {
        return self.stmt.nullableBlob(index);
    }
};

pub const Rows = struct {
    stmt: Stmt,
    err: ?Error,

    pub fn deinit(self: Rows) void {
        self.stmt.deinit();
    }

    pub fn deinitErr(self: Rows) !void {
        return self.stmt.deinitErr();
    }

    pub fn next(self: *Rows) ?Row {
        if (self.err != null) {
            return null;
        }

        const stmt = self.stmt;
        const has_data = stmt.step() catch |err| {
            self.err = err;
            return null;
        };

        if (!has_data) {
            return null;
        }

        return .{ .stmt = stmt };
    }
};

pub const Error = error{
    Abort,
    Auth,
    Busy,
    CantOpen,
    Constraint,
    Corrupt,
    Empty,
    Error,
    Format,
    Full,
    Internal,
    Interrupt,
    IoErr,
    Locked,
    Mismatch,
    Misuse,
    NoLFS,
    NoMem,
    NotADB,
    Notfound,
    Notice,
    Perm,
    Protocol,
    Range,
    ReadOnly,
    Schema,
    TooBig,
    Warning,
    ErrorMissingCollseq,
    ErrorRetry,
    ErrorSnapshot,
    IoerrRead,
    IoerrShortRead,
    IoerrWrite,
    IoerrFsync,
    IoerrDir_fsync,
    IoerrTruncate,
    IoerrFstat,
    IoerrUnlock,
    IoerrRdlock,
    IoerrDelete,
    IoerrBlocked,
    IoerrNomem,
    IoerrAccess,
    IoerrCheckreservedlock,
    IoerrLock,
    IoerrClose,
    IoerrDirClose,
    IoerrShmopen,
    IoerrShmsize,
    IoerrShmlock,
    ioerrshmmap,
    IoerrSeek,
    IoerrDeleteNoent,
    IoerrMmap,
    IoerrGetTempPath,
    IoerrConvPath,
    IoerrVnode,
    IoerrAuth,
    IoerrBeginAtomic,
    IoerrCommitAtomic,
    IoerrRollbackAtomic,
    IoerrData,
    IoerrCorruptFS,
    LockedSharedCache,
    LockedVTab,
    BusyRecovery,
    BusySnapshot,
    BusyTimeout,
    CantOpenNoTempDir,
    CantOpenIsDir,
    CantOpenFullPath,
    CantOpenConvPath,
    CantOpenDirtyWal,
    CantOpenSymlink,
    CorruptVTab,
    CorruptSequence,
    CorruptIndex,
    ReadonlyRecovery,
    ReadonlyCantlock,
    ReadonlyRollback,
    ReadonlyDbMoved,
    ReadonlyCantInit,
    ReadonlyDirectory,
    AbortRollback,
    ConstraintCheck,
    ConstraintCommithook,
    ConstraintForeignKey,
    ConstraintFunction,
    ConstraintNotNull,
    ConstraintPrimaryKey,
    ConstraintTrigger,
    ConstraintUnique,
    ConstraintVTab,
    ConstraintRowId,
    ConstraintPinned,
    ConstraintDatatype,
    NoticeRecoverWal,
    NoticeRecoverRollback,
    WarningAutoIndex,
    AuthUser,
    OkLoadPermanently,
};

fn errorFromCode(result: c_int) Error {
    return switch (result) {
        c.SQLITE_ABORT => error.Abort,
        c.SQLITE_AUTH => error.Auth,
        c.SQLITE_BUSY => error.Busy,
        c.SQLITE_CANTOPEN => error.CantOpen,
        c.SQLITE_CONSTRAINT => error.Constraint,
        c.SQLITE_CORRUPT => error.Corrupt,
        c.SQLITE_EMPTY => error.Empty,
        c.SQLITE_ERROR => error.Error,
        c.SQLITE_FORMAT => error.Format,
        c.SQLITE_FULL => error.Full,
        c.SQLITE_INTERNAL => error.Internal,
        c.SQLITE_INTERRUPT => error.Interrupt,
        c.SQLITE_IOERR => error.IoErr,
        c.SQLITE_LOCKED => error.Locked,
        c.SQLITE_MISMATCH => error.Mismatch,
        c.SQLITE_MISUSE => error.Misuse,
        c.SQLITE_NOLFS => error.NoLFS,
        c.SQLITE_NOMEM => error.NoMem,
        c.SQLITE_NOTADB => error.NotADB,
        c.SQLITE_NOTFOUND => error.Notfound,
        c.SQLITE_NOTICE => error.Notice,
        c.SQLITE_PERM => error.Perm,
        c.SQLITE_PROTOCOL => error.Protocol,
        c.SQLITE_RANGE => error.Range,
        c.SQLITE_READONLY => error.ReadOnly,
        c.SQLITE_SCHEMA => error.Schema,
        c.SQLITE_TOOBIG => error.TooBig,
        c.SQLITE_WARNING => error.Warning,

        // extended codes:
        c.SQLITE_ERROR_MISSING_COLLSEQ => error.ErrorMissingCollseq,
        c.SQLITE_ERROR_RETRY => error.ErrorRetry,
        c.SQLITE_ERROR_SNAPSHOT => error.ErrorSnapshot,
        c.SQLITE_IOERR_READ => error.IoerrRead,
        c.SQLITE_IOERR_SHORT_READ => error.IoerrShortRead,
        c.SQLITE_IOERR_WRITE => error.IoerrWrite,
        c.SQLITE_IOERR_FSYNC => error.IoerrFsync,
        c.SQLITE_IOERR_DIR_FSYNC => error.IoerrDir_fsync,
        c.SQLITE_IOERR_TRUNCATE => error.IoerrTruncate,
        c.SQLITE_IOERR_FSTAT => error.IoerrFstat,
        c.SQLITE_IOERR_UNLOCK => error.IoerrUnlock,
        c.SQLITE_IOERR_RDLOCK => error.IoerrRdlock,
        c.SQLITE_IOERR_DELETE => error.IoerrDelete,
        c.SQLITE_IOERR_BLOCKED => error.IoerrBlocked,
        c.SQLITE_IOERR_NOMEM => error.IoerrNomem,
        c.SQLITE_IOERR_ACCESS => error.IoerrAccess,
        c.SQLITE_IOERR_CHECKRESERVEDLOCK => error.IoerrCheckreservedlock,
        c.SQLITE_IOERR_LOCK => error.IoerrLock,
        c.SQLITE_IOERR_CLOSE => error.IoerrClose,
        c.SQLITE_IOERR_DIR_CLOSE => error.IoerrDirClose,
        c.SQLITE_IOERR_SHMOPEN => error.IoerrShmopen,
        c.SQLITE_IOERR_SHMSIZE => error.IoerrShmsize,
        c.SQLITE_IOERR_SHMLOCK => error.IoerrShmlock,
        c.SQLITE_IOERR_SHMMAP => error.ioerrshmmap,
        c.SQLITE_IOERR_SEEK => error.IoerrSeek,
        c.SQLITE_IOERR_DELETE_NOENT => error.IoerrDeleteNoent,
        c.SQLITE_IOERR_MMAP => error.IoerrMmap,
        c.SQLITE_IOERR_GETTEMPPATH => error.IoerrGetTempPath,
        c.SQLITE_IOERR_CONVPATH => error.IoerrConvPath,
        c.SQLITE_IOERR_VNODE => error.IoerrVnode,
        c.SQLITE_IOERR_AUTH => error.IoerrAuth,
        c.SQLITE_IOERR_BEGIN_ATOMIC => error.IoerrBeginAtomic,
        c.SQLITE_IOERR_COMMIT_ATOMIC => error.IoerrCommitAtomic,
        c.SQLITE_IOERR_ROLLBACK_ATOMIC => error.IoerrRollbackAtomic,
        c.SQLITE_IOERR_DATA => error.IoerrData,
        c.SQLITE_IOERR_CORRUPTFS => error.IoerrCorruptFS,
        c.SQLITE_LOCKED_SHAREDCACHE => error.LockedSharedCache,
        c.SQLITE_LOCKED_VTAB => error.LockedVTab,
        c.SQLITE_BUSY_RECOVERY => error.BusyRecovery,
        c.SQLITE_BUSY_SNAPSHOT => error.BusySnapshot,
        c.SQLITE_BUSY_TIMEOUT => error.BusyTimeout,
        c.SQLITE_CANTOPEN_NOTEMPDIR => error.CantOpenNoTempDir,
        c.SQLITE_CANTOPEN_ISDIR => error.CantOpenIsDir,
        c.SQLITE_CANTOPEN_FULLPATH => error.CantOpenFullPath,
        c.SQLITE_CANTOPEN_CONVPATH => error.CantOpenConvPath,
        c.SQLITE_CANTOPEN_DIRTYWAL => error.CantOpenDirtyWal,
        c.SQLITE_CANTOPEN_SYMLINK => error.CantOpenSymlink,
        c.SQLITE_CORRUPT_VTAB => error.CorruptVTab,
        c.SQLITE_CORRUPT_SEQUENCE => error.CorruptSequence,
        c.SQLITE_CORRUPT_INDEX => error.CorruptIndex,
        c.SQLITE_READONLY_RECOVERY => error.ReadonlyRecovery,
        c.SQLITE_READONLY_CANTLOCK => error.ReadonlyCantlock,
        c.SQLITE_READONLY_ROLLBACK => error.ReadonlyRollback,
        c.SQLITE_READONLY_DBMOVED => error.ReadonlyDbMoved,
        c.SQLITE_READONLY_CANTINIT => error.ReadonlyCantInit,
        c.SQLITE_READONLY_DIRECTORY => error.ReadonlyDirectory,
        c.SQLITE_ABORT_ROLLBACK => error.AbortRollback,
        c.SQLITE_CONSTRAINT_CHECK => error.ConstraintCheck,
        c.SQLITE_CONSTRAINT_COMMITHOOK => error.ConstraintCommithook,
        c.SQLITE_CONSTRAINT_FOREIGNKEY => error.ConstraintForeignKey,
        c.SQLITE_CONSTRAINT_FUNCTION => error.ConstraintFunction,
        c.SQLITE_CONSTRAINT_NOTNULL => error.ConstraintNotNull,
        c.SQLITE_CONSTRAINT_PRIMARYKEY => error.ConstraintPrimaryKey,
        c.SQLITE_CONSTRAINT_TRIGGER => error.ConstraintTrigger,
        c.SQLITE_CONSTRAINT_UNIQUE => error.ConstraintUnique,
        c.SQLITE_CONSTRAINT_VTAB => error.ConstraintVTab,
        c.SQLITE_CONSTRAINT_ROWID => error.ConstraintRowId,
        c.SQLITE_CONSTRAINT_PINNED => error.ConstraintPinned,
        c.SQLITE_CONSTRAINT_DATATYPE => error.ConstraintDatatype,
        c.SQLITE_NOTICE_RECOVER_WAL => error.NoticeRecoverWal,
        c.SQLITE_NOTICE_RECOVER_ROLLBACK => error.NoticeRecoverRollback,
        c.SQLITE_WARNING_AUTOINDEX => error.WarningAutoIndex,
        c.SQLITE_AUTH_USER => error.AuthUser,
        c.SQLITE_OK_LOAD_PERMANENTLY => error.OkLoadPermanently,

        else => std.debug.panic("{s} {d}", .{ c.sqlite3_errstr(result), result }),
    };
}

pub fn isUnique(err: Error) bool {
    return err == error.ConstraintUnique;
}

pub const Pool = struct {
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    conns: []Conn,
    available: usize,
    allocator: std.mem.Allocator,

    pub const Config = struct {
        size: usize = 5,
        flags: c_int = OpenFlags.Create | OpenFlags.EXResCode,
        path: [*:0]const u8,
        on_connection: ?*const fn (conn: Conn) anyerror!void = null,
        on_first_connection: ?*const fn (conn: Conn) anyerror!void = null,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !Pool {
        const size = config.size;
        const conns = try allocator.alloc(Conn, size);

        const path = config.path;
        const flags = config.flags;
        const on_connection = config.on_connection;

        var init_count: usize = 0;
        errdefer {
            for (0..init_count) |i| {
                conns[i].close();
            }
        }

        for (0..size) |i| {
            const conn = try Conn.init(path, flags);
            init_count += 1;
            if (i == 0) {
                if (config.on_first_connection) |f| {
                    try f(conn);
                }
            }
            if (on_connection) |f| {
                try f(conn);
            }
            conns[i] = conn;
        }

        return .{
            .conns = conns,
            .available = size,
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
            .cond = std.Thread.Condition{},
        };
    }

    pub fn deinit(self: *Pool) void {
        const allocator = self.allocator;
        for (self.conns) |conn| {
            conn.close();
        }
        allocator.free(self.conns);
    }

    pub fn acquire(self: *Pool) Conn {
        self.mutex.lock();
        while (true) {
            const conns = self.conns;
            const available = self.available;
            if (available == 0) {
                self.cond.wait(&self.mutex);
                continue;
            }
            const index = available - 1;
            const conn = conns[index];
            self.available = index;
            self.mutex.unlock();
            return conn;
        }
    }

    pub fn release(self: *Pool, conn: Conn) void {
        self.mutex.lock();

        var conns = self.conns;
        const available = self.available;
        conns[available] = conn;
        self.available = available + 1;
        self.mutex.unlock();
        self.cond.signal();
    }
};

test "init: path does not exist" {
    try t.expectError(error.CantOpen, Conn.init("does_not_exist", 0));
}

test "exec and scan" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    conn.exec(
        \\
        \\  insert into test (cint, creal, ctext, cblob)
        \\  values (?1, ?2, ?3, ?4)
    , .{ -3, 2.2, "three", "four" }) catch unreachable;

    try t.expectEqual(@as(usize, 1), conn.changes());

    const lastId = conn.lastInsertedRowId();
    const row = queryLast(conn).?;
    defer row.row.deinit();
    try t.expectEqual(lastId, row.id);
    try t.expectEqual(@as(i64, -3), row.int);
    try t.expectEqual(@as(f64, 2.2), row.real);
    try t.expectEqualStrings("three", row.text);
    try t.expectEqualStrings("four", row.blob);
    try t.expectEqual(@as(?i64, null), row.intn);
    try t.expectEqual(@as(?f64, null), row.realn);
    try t.expectEqual(@as(?[]const u8, null), row.textn);
    try t.expectEqual(@as(?[]const u8, null), row.blobn);

    try conn.exec("delete from test where id = ?", .{lastId});
    try t.expectEqual(@as(usize, 1), conn.changes());
    try t.expectEqual(@as(?TestRow, null), queryLast(conn));

    try conn.exec("delete from test where id = ?", .{lastId});
    try t.expectEqual(@as(usize, 0), conn.changes());
    try t.expectEqual(@as(?TestRow, null), queryLast(conn));
}

test "bind null" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    conn.exec(
        \\
        \\ insert into test (cintn, crealn, ctextn, cblobn)
        \\ values (?1, ?2, ?3, ?4)
    , .{ null, null, null, null }) catch unreachable;
    try t.expectEqual(@as(usize, 1), conn.changes());

    const row = queryLast(conn).?;
    defer row.row.deinit();
    try t.expectEqual(@as(?i64, null), row.intn);
    try t.expectEqual(@as(?f64, null), row.realn);
    try t.expectEqual(@as(?[]const u8, null), row.textn);
    try t.expectEqual(@as(?[]const u8, null), row.blobn);
}

test "bind null optionals" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    const empty = TestRow{};

    conn.exec(
        \\
        \\ insert into test (cintn, crealn, ctextn, cblobn)
        \\ values (?1, ?2, ?3, ?4)
    , .{ empty.intn, empty.realn, empty.textn, empty.blobn }) catch unreachable;
    try t.expectEqual(@as(usize, 1), conn.changes());

    const row = queryLast(conn).?;
    defer row.row.deinit();
    try t.expectEqual(@as(?i64, null), row.intn);
    try t.expectEqual(@as(?f64, null), row.realn);
    try t.expectEqual(@as(?[]const u8, null), row.textn);
    try t.expectEqual(@as(?[]const u8, null), row.blobn);
}

test "boolean" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    {
        conn.exec("insert into test (cint, cintn) values (?, ?)", .{ true, true }) catch unreachable;
        const row = (try conn.row("select cint, cintn from test where id = ?", .{conn.lastInsertedRowId()})).?;
        defer row.deinit();

        try t.expectEqual(true, row.boolean(0));
        try t.expectEqual(true, row.nullableBoolean(1).?);
    }

    {
        conn.execNoArgs("update test set cint = false, cintn = false") catch unreachable;
        const row = (try conn.row("select cint, cintn from test where id = ?", .{conn.lastInsertedRowId()})).?;
        defer row.deinit();

        try t.expectEqual(false, row.boolean(0));
        try t.expectEqual(false, row.nullableBoolean(1).?);
    }

    {
        conn.execNoArgs("update test set cintn = null") catch unreachable;
        const row = (try conn.row("select cintn from test where id = ?", .{conn.lastInsertedRowId()})).?;
        defer row.deinit();

        try t.expectEqual(@as(?bool, null), row.nullableBoolean(0));
    }
}

test "blob/text" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    {
        const d1 = [_]u8{ 5, 1, 2, 3 };
        const d2 = [_]u8{ 9, 10, 11, 12, 13 };
        conn.exec("insert into test (cblob, cblobn, ctext, ctextn) values (?1, ?2, ?1, ?2)", .{ &d1, d2 }) catch unreachable;
        const row = (try conn.row("select cblob, cblobn, ctext, ctextn from test where id = ?", .{conn.lastInsertedRowId()})).?;
        defer row.deinit();

        try t.expectEqualStrings(&d1, row.blob(0));
        try t.expectEqualStrings(&d2, row.nullableBlob(1).?);

        try t.expectEqualStrings(&d1, row.text(2));
        try t.expectEqualStrings(&d2, row.nullableText(3).?);

        try t.expectEqualStrings(&d1, std.mem.span(row.textZ(2)));
        try t.expectEqualStrings(&d2, std.mem.span(row.nullableTextZ(3).?));
        try t.expectEqual(@as(usize, 4), row.textLen(2));
        try t.expectEqual(@as(usize, 5), row.textLen(3));
    }
}

test "explicit blob type" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    {
        const d1 = [_]u8{ 0, 1, 2, 3 };
        conn.exec("insert into test (cblob) values (?1)", .{blob(&d1)}) catch unreachable;
        const row = (try conn.row("select 1 from test where cblob = ?1", .{blob(&d1)})).?;
        defer row.deinit();

        try t.expectEqual(true, row.boolean(0));
    }

    {
        conn.exec("insert into test (cblob) values (?1)", .{blob("hello")}) catch unreachable;
        const row = (try conn.row("select 1 from test where cblob = ?1", .{blob("hello")})).?;
        defer row.deinit();

        try t.expectEqual(true, row.boolean(0));
    }
}

test "empty string/blob" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    conn.exec(
        \\ insert into test (ctext, ctextn, cblob, cblobn) values
        \\ (?1, ?1, ?1, ?1)
    , .{""}) catch unreachable;

    const row = queryLast(conn).?;
    defer row.row.deinit();
    try t.expectEqualStrings("", row.text);
    try t.expectEqualStrings("", row.textn.?);
    try t.expectEqualStrings("", row.blob);
    try t.expectEqualStrings("", row.blobn.?);
}

test "transaction commit" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    var id1: i64 = 0;
    var id2: i64 = 0;
    {
        try conn.transaction();
        errdefer conn.rollback();

        conn.exec("insert into test (ctext) values (?)", .{"hello"}) catch unreachable;
        id1 = conn.lastInsertedRowId();

        conn.exec("insert into test (ctext) values (?)", .{"world"}) catch unreachable;
        id2 = conn.lastInsertedRowId();

        try conn.commit();
    }

    const row1 = queryId(conn, id1).?;
    defer row1.row.deinit();
    const row2 = queryId(conn, id2).?;
    defer row2.row.deinit();

    try t.expectEqualStrings("hello", row1.text);
    try t.expectEqualStrings("world", row2.text);
}

test "transaction rollback" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    var id1: i64 = 0;
    var id2: i64 = 0;
    {
        try conn.transaction();
        defer conn.rollback();

        conn.exec("insert into test (ctext) values (?)", .{"hello"}) catch unreachable;
        id1 = conn.lastInsertedRowId();

        conn.exec("insert into test (ctext) values (?)", .{"world"}) catch unreachable;
        id2 = conn.lastInsertedRowId();
    }

    // make sure the insert actually happened before we rolledback
    try t.expectEqual(true, id2 > id1);
    try t.expectEqual(@as(?TestRow, null), queryId(conn, id1));
    try t.expectEqual(@as(?TestRow, null), queryId(conn, id2));
}

test "rows" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    conn.exec(
        \\
        \\ insert into test (cint, ctext)
        \\ values (?1, ?2), (?3, ?4)
    , .{ 1, "two", 3, "four" }) catch unreachable;
    try t.expectEqual(@as(usize, 2), conn.changes());

    var rows = conn.rows("select cint, ctext from test order by cint", .{}) catch unreachable;
    defer rows.deinit();

    const r1 = rows.next().?;
    try t.expectEqual(@as(i64, 1), r1.int(0));
    try t.expectEqualStrings("two", r1.text(1));

    const r2 = rows.next().?;
    try t.expectEqual(@as(i64, 3), r2.int(0));
    try t.expectEqualStrings("four", r2.text(1));

    try t.expectEqual(@as(?Row, null), rows.next());
    try t.expectEqual(@as(?Error, null), rows.err);
}

test "row query error" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;
    try t.expectError(error.Error, conn.row("select invalid from test", .{}));
    try t.expectEqualStrings("no such column: invalid", std.mem.span(conn.lastError()));
}

test "rows query error" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;
    try t.expectError(error.Error, conn.rows("select invalid from test", .{}));
    try t.expectEqualStrings("no such column: invalid", std.mem.span(conn.lastError()));
}

test "lastError without error" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;
    try t.expectEqualStrings("not an error", std.mem.span(conn.lastError()));
}

test "isUnique" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    conn.execNoArgs("insert into test (uniq) values (1)") catch unreachable;

    var is_unique = false;
    conn.execNoArgs("insert into test (uniq) values (1)") catch |err| {
        is_unique = isUnique(err);
    };
    try t.expectEqual(true, is_unique);
}

test "statement meta" {
    const conn = testDB();
    defer conn.tryClose() catch unreachable;

    const row = conn.row("select 1 as id, 'leto' as name, null as other", .{}) catch unreachable orelse unreachable;
    defer row.deinit();

    try t.expectEqual(@as(i32, 3), row.stmt.columnCount());
    try t.expectEqualStrings("id", std.mem.span(row.stmt.columnName(0)));
    try t.expectEqualStrings("name", std.mem.span(row.stmt.columnName(1)));
    try t.expectEqualStrings("other", std.mem.span(row.stmt.columnName(2)));

    try t.expectEqual(ColumnType.int, row.stmt.columnType(0));
    try t.expectEqual(ColumnType.text, row.stmt.columnType(1));
    try t.expectEqual(ColumnType.null, row.stmt.columnType(2));
}

fn testPool(p: *Pool) void {
    for (0..1000) |_| {
        const conn = p.acquire();
        conn.execNoArgs("update pool_test set cnt = cnt + 1") catch |err| {
            std.debug.print("update err: {any}\n", .{err});
            unreachable;
        };
        p.release(conn);
    }
}

fn testPoolFirstConnection(conn: Conn) !void {
    try conn.execNoArgs("pragma journal_mode=wal");

    // This is not safe and can result in corruption. This is only set
    // because the tests might be run on really slow hardware and we
    // want to avoid having a busy timeout.
    try conn.execNoArgs("pragma synchronous=off");

    try conn.execNoArgs("drop table if exists pool_test");
    try conn.execNoArgs("create table pool_test (cnt int not null)");
    try conn.execNoArgs("insert into pool_test (cnt) values (0)");
}

fn testPoolEachConnection(conn: Conn) !void {
    return conn.busyTimeout(5000);
}

fn testDB() Conn {
    var conn = open(":memory:", OpenFlags.Create | OpenFlags.EXResCode) catch unreachable;
    conn.execNoArgs(
        \\
        \\ create table test (
        \\  id integer primary key not null,
        \\  cint integer not null default(0),
        \\  cintn integer null,
        \\  creal real not null default(0.0),
        \\  crealn real null,
        \\  ctext text not null default(''),
        \\  ctextn text null,
        \\  cblob blob not null default(''),
        \\  cblobn blob null,
        \\  uniq int unique null
        \\ )
    ) catch unreachable;
    return conn;
}

const TestRow = struct {
    row: Row = undefined,
    id: i64 = 0,
    int: i64 = 0,
    intn: ?i64 = null,
    real: f64 = 0.0,
    realn: ?f64 = null,
    text: []const u8 = "",
    textn: ?[]const u8 = null,
    blob: []const u8 = "",
    blobn: ?[]const u8 = null,
};

fn queryLast(conn: Conn) ?TestRow {
    return queryId(conn, conn.lastInsertedRowId());
}

fn queryId(conn: Conn, id: i64) ?TestRow {
    const row = conn.row(
        \\
        \\ select id, cint, cintn, creal, crealn,
        \\   ctext, ctextn, cblob, cblobn
        \\ from test where id = ?
    , .{id}) catch unreachable orelse return null;

    return .{
        .row = row,
        .id = row.int(0),
        .int = row.int(1),
        .intn = row.nullableInt(2),
        .real = row.float(3),
        .realn = row.nullableFloat(4),
        .text = row.text(5),
        .textn = row.nullableText(6),
        .blob = row.blob(7),
        .blobn = row.nullableBlob(8),
    };
}
