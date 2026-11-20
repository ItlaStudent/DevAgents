const std = @import("std");
const core = @import("core");

extern "kernel32" fn GetTickCount64() u64;
extern "kernel32" fn Sleep(dwMilliseconds: u32) void;

fn nowMs() u64 {
    return GetTickCount64();
}

const NUM_WORKERS = 12;
const NUM_TASKS = 200;
const MIN_THROUGHPUT = 50; // tasks/sec minimum
const TASK_WORK_US = 100; // simulated work per task

var completed_count: usize = 0;
var completed_mutex: core.sync.Mutex = core.sync.Mutex.init();

fn benchHandler(allocator: std.mem.Allocator, task: *core.scheduler.Task, worker: *core.scheduler.Worker) void {
    _ = allocator;
    _ = worker;
    var i: usize = 0;
    while (i < TASK_WORK_US * 50) : (i += 1) {
        std.atomic.spinLoopHint();
    }

    completed_mutex.lock();
    completed_count += 1;
    completed_mutex.unlock();

    task.result = task.allocator.dupe(u8, "ok") catch "ok";
    task.state = .completed;
}

pub fn main() !void {
    std.debug.print("=== BENCH SCHEDULER (T-F9-04) ===\n", .{});
    std.debug.print("Workers: {d}, Tasks: {d}\n", .{ NUM_WORKERS, NUM_TASKS });
    std.debug.print("Budget: throughput >= {d} tasks/s\n\n", .{MIN_THROUGHPUT});

    // Create thread pool
    var pool = try core.scheduler.ThreadPool.init(std.heap.page_allocator, NUM_WORKERS, benchHandler);
    defer pool.deinit();

    // Create and submit tasks
    for (0..NUM_TASKS) |i| {
        const id = try std.fmt.allocPrint(std.heap.page_allocator, "task-{d}", .{i});
        const desc = try std.fmt.allocPrint(std.heap.page_allocator, "bench {d}", .{i});
        const task = try core.scheduler.Task.create(std.heap.page_allocator, id, desc, 1, 0);
        try pool.submit(task);
    }

    std.debug.print("All tasks submitted. Starting...\n", .{});

    completed_count = 0;
    const start_ms = nowMs();
    try pool.start();

    // Poll until all tasks complete
    var waited: usize = 0;
    while (completed_count < NUM_TASKS) {
        Sleep(1);
        waited += 1;
        if (waited > 30000) {
            std.debug.print("TIMEOUT: {d}/{d} completed after 30s\n", .{ completed_count, NUM_TASKS });
            pool.stop();
            std.process.exit(1);
        }
    }

    pool.stop();
    const elapsed_ms = nowMs() - start_ms;

    const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
    const throughput = if (elapsed_s > 0)
        @as(f64, @floatFromInt(NUM_TASKS)) / elapsed_s
    else
        @as(f64, @floatFromInt(NUM_TASKS));

    // Worker distribution visible via completed_count (all completed)
    std.debug.print("\n=== RESULTS ===\n", .{});
    std.debug.print("Elapsed: {d} ms ({d:.3} s)\n", .{ elapsed_ms, elapsed_s });
    std.debug.print("Throughput: {d:.2} tasks/s\n", .{throughput});
    std.debug.print("Completed: {d}/{d}\n", .{ completed_count, NUM_TASKS });
    std.debug.print("Workers: {d}\n", .{NUM_WORKERS});

    if (throughput < MIN_THROUGHPUT) {
        std.debug.print("FAIL: throughput {d:.2} < budget {d}\n", .{ throughput, MIN_THROUGHPUT });
        std.process.exit(1);
    }

    std.debug.print("PASS: throughput {d:.2} >= {d} tasks/s\n", .{ throughput, MIN_THROUGHPUT });
    std.debug.print("=== BENCH PASSED ===\n", .{});
}
