const governed = @import("governed_process");
const c = governed.win;
extern fn sec5_child_main() c_int;

// Broker fixtures use the very same launcher as the suite parent.
export fn sec5_launch_fixture(request: [*c]const c.sec5_request, result: [*c]c.sec5_result) c_int {
    result.* = governed.launch(.{ .authority = .{ .sandbox = .{ .lease_sid = request.*.lease_sid } }, .fixture = request.* });
    return if (result.*.@"error" == 0) 1 else 0;
}

pub fn main() void {
    c.ExitProcess(@intCast(sec5_child_main()));
}
