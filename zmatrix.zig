const std = @import("std");
const print = std.debug.print;
const builtin = @import("builtin");

const windows = builtin.os.tag == .windows;
const linux = !windows;

var prng: std.Random.DefaultPrng = undefined;
var rand: std.Random = undefined;

var stdout: std.fs.File.Writer = undefined;
var g_tty_win: std.os.windows.HANDLE = undefined;

var matrix: [][]Matrix = undefined;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

const Matrix = struct {
    val: i32,
    is_head: bool,
};

const AnsiEscapeCodes = struct {
    const esc = "\x1B";
    const csi = esc ++ "[";

    const cursor_show = csi ++ "?25h"; //h=high
    const cursor_hide = csi ++ "?25l"; //l=low
    const cursor_home = csi ++ "1;1H"; //1,1

    const color_fg = "38;5;";
    const color_bg = "48;5;";
    const color_fg_def = csi ++ color_fg ++ "15m"; // white
    const color_bg_def = csi ++ color_bg ++ "0m"; // black
    const color_def = color_bg_def ++ color_fg_def;

    const screen_clear = csi ++ "2J";
    const screen_buf_on = csi ++ "?1049h"; //h=high
    const screen_buf_off = csi ++ "?1049l"; //l=low

    const nl = "\n";

    const term_on = screen_buf_on ++ cursor_hide ++ cursor_home ++ screen_clear ++ color_def;
    const term_off = screen_buf_off ++ nl;
};

fn getTerminalSize() !struct { width: usize, height: usize } {
    if (windows) {
        var info: std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = .{
            .dwSize = .{ .X = 0, .Y = 0 },
            .dwCursorPosition = .{ .X = 0, .Y = 0 },
            .wAttributes = 0,
            .srWindow = .{ .Left = 0, .Top = 0, .Right = 0, .Bottom = 0 },
            .dwMaximumWindowSize = .{ .X = 0, .Y = 0 },
        };

        if (0 == std.os.windows.kernel32.GetConsoleScreenBufferInfo(g_tty_win, &info)) switch (std.os.windows.kernel32.GetLastError()) {
            else => |e| return std.os.windows.unexpectedError(e),
        };

        return .{
            .height = @intCast(info.srWindow.Bottom - info.srWindow.Top + 1),
            .width = @intCast(info.srWindow.Right - info.srWindow.Left + 1),
        };
    } else {
        const TIOCGWINSZ = std.c.T.IOCGWINSZ;
        const winsz = std.c.winsize{ .col = 0, .row = 0, .xpixel = 0, .ypixel = 0 };

        if (winsz.row == 0 or winsz.col == 0) {
            var lldb_tty_nix = try std.fs.cwd().openFile("/dev/tty", .{});
            defer lldb_tty_nix.close();

            var lldb_winsz = std.c.winsize{ .col = 0, .row = 0, .xpixel = 0, .ypixel = 0 };
            const lldb_rv = std.os.linux.ioctl(lldb_tty_nix.handle, TIOCGWINSZ, @intFromPtr(&lldb_winsz));
            const lldb_err = std.posix.errno(lldb_rv);

            if (lldb_rv >= 0) {
                return .{ .height = lldb_winsz.row, .width = lldb_winsz.col };
            } else {
                return std.posix.unexpectedErrno(lldb_err);
            }
        } else {
            return .{ .height = winsz.row, .width = winsz.col };
        }
    }
}

pub fn main() !void {
    prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    rand = prng.random();
    // const alloc = gpa.allocator();

    print("{any}\n", .{try getTerminalSize()});

    // while (true) {
    //      print("{s}", .{AnsiEscapeCodes.term_on});
    //      defer print("{s}", .{AnsiEscapeCodes.term_off});
    //      print("a", .{});
    //  }
}
