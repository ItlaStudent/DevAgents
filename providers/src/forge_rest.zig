//! Common PR/MR contract. REST transport is injectable and never logs bodies.
//! API sources: docs.github.com/en/rest/pulls/pulls,
//! docs.gitlab.com/api/merge_requests/, docs.gitea.com/api/1.24/.
const std = @import("std");
const gitea = @import("gitea.zig");
const github = @import("github.zig");

pub const PullRequest = struct {
    number: i64,
    url: []u8,
    state: github.PullRequestState,
    pub fn deinit(self: *PullRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
    }
};

pub fn encodeComponent(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(allocator, c);
        } else {
            try out.appendSlice(allocator, &.{ '%', hex[c >> 4], hex[c & 15] });
        }
    }
    return out.toOwnedSlice(allocator);
}

pub const ForgeConnector = struct {
    transport: *gitea.GiteaConnector,
    kind: github.Forge,
    web_base: []const u8,
    slug: []const u8,

    fn endpoint(self: *ForgeConnector, suffix: []const u8) ![]u8 {
        // Authentication is confined to one origin, never a URL with userinfo.
        const uri = try std.Uri.parse(self.web_base);
        if ((!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) or uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.BadRemoteUrl;
        @import("http/client.zig").validateCredentialUrl(self.web_base) catch |err| switch (err) {
            error.InsecureCredentialTransport => return error.InsecureForgeUrl,
            else => return error.BadRemoteUrl,
        };
        const path = uri.path.percent_encoded;
        if (path.len != 0 and !std.mem.eql(u8, path, "/")) return error.BadRemoteUrl;
        var segments = std.mem.splitScalar(u8, self.slug, '/');
        var count: usize = 0;
        while (segments.next()) |segment| {
            if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.BadRemoteUrl;
            for (segment) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return error.BadRemoteUrl;
            count += 1;
        }
        if (count < 2 or (self.kind != .gitlab and count != 2)) return error.BadRemoteUrl;
        const a = self.transport.allocator;
        return switch (self.kind) {
            .gitea => std.fmt.allocPrint(a, "{s}/api/v1/repos/{s}{s}", .{ self.web_base, self.slug, suffix }),
            .github => if (std.mem.eql(u8, self.web_base, "https://github.com") or std.mem.eql(u8, self.web_base, "https://www.github.com"))
                std.fmt.allocPrint(a, "https://api.github.com/repos/{s}{s}", .{ self.slug, suffix })
            else
                std.fmt.allocPrint(a, "{s}/api/v3/repos/{s}{s}", .{ self.web_base, self.slug, suffix }),
            .gitlab => blk: {
                const project = try encodeComponent(a, self.slug);
                defer a.free(project);
                break :blk std.fmt.allocPrint(a, "{s}/api/v4/projects/{s}{s}", .{ self.web_base, project, suffix });
            },
        };
    }

    fn request(self: *ForgeConnector, method: []const u8, suffix: []const u8, body: ?[]const u8, expected: u16) !gitea.RestResponse {
        self.transport.last_error.clearRetainingCapacity();
        const url = try self.endpoint(suffix);
        defer self.transport.allocator.free(url);
        var response = self.transport.rest(method, url, body) catch |e| {
            self.transport.setLastError(@errorName(e), "forge transport unavailable");
            return error.ForgeUnavailable;
        };
        if (response.status != expected and !(self.kind == .gitea and std.mem.eql(u8, method, "POST") and std.mem.endsWith(u8, suffix, "/merge") and response.status == 204)) {
            defer response.deinit(self.transport.allocator);
            // Remote error bodies may echo credentials or attacker text.
            var buf: [96]u8 = undefined;
            const diagnostic = try std.fmt.bufPrint(&buf, "{s} {s}: HTTP {d}", .{ @tagName(self.kind), method, response.status });
            self.transport.setLastError(diagnostic, "forge request failed");
            return switch (response.status) {
                401, 403 => error.ForgeUnauthorized,
                404 => error.ForgeNotFound,
                422 => error.ForgeValidationFailed,
                else => error.ForgeFailed,
            };
        }
        return response;
    }

    fn parse(self: *ForgeConnector, response: *const gitea.RestResponse) !std.json.Parsed(std.json.Value) {
        return std.json.parseFromSlice(std.json.Value, self.transport.allocator, response.body, .{}) catch return error.ForgeParseFailed;
    }

    fn state(self: *ForgeConnector, value: std.json.Value) !github.PullRequestState {
        if (value != .object) return error.ForgeParseFailed;
        if (value.object.get("merged")) |merged| {
            if (merged == .bool and merged.bool) return .merged;
        }
        const sv = value.object.get("state") orelse return error.ForgeParseFailed;
        if (sv != .string) return error.ForgeParseFailed;
        if (self.kind == .gitlab and std.mem.eql(u8, sv.string, "merged")) return .merged;
        if (std.mem.eql(u8, sv.string, if (self.kind == .gitlab) "opened" else "open")) return .open;
        if (std.mem.eql(u8, sv.string, "closed")) return .failed;
        return error.ForgeParseFailed;
    }

    fn pull(self: *ForgeConnector, value: std.json.Value) !PullRequest {
        if (value != .object) return error.ForgeParseFailed;
        const n = value.object.get(if (self.kind == .gitlab) "iid" else "number") orelse return error.ForgeParseFailed;
        const u = value.object.get(if (self.kind == .gitlab) "web_url" else "html_url") orelse return error.ForgeParseFailed;
        if (n != .integer or n.integer <= 0 or u != .string) return error.ForgeParseFailed;
        if (!std.mem.startsWith(u8, u.string, self.web_base) or u.string.len <= self.web_base.len or u.string[self.web_base.len] != '/') return error.ForgeParseFailed;
        const parsed_uri = std.Uri.parse(u.string) catch return error.ForgeParseFailed;
        if (parsed_uri.user != null or parsed_uri.password != null or parsed_uri.query != null or parsed_uri.fragment != null) return error.ForgeParseFailed;
        return .{ .number = n.integer, .state = try self.state(value), .url = try self.transport.allocator.dupe(u8, u.string) };
    }

    pub fn repoDefaultBranch(self: *ForgeConnector) ![]u8 {
        var r = try self.request("GET", "", null, 200);
        defer r.deinit(self.transport.allocator);
        var p = try self.parse(&r);
        defer p.deinit();
        if (p.value != .object) return error.ForgeParseFailed;
        const b = p.value.object.get("default_branch") orelse return error.ForgeParseFailed;
        if (b != .string or b.string.len == 0) return error.ForgeParseFailed;
        return self.transport.allocator.dupe(u8, b.string);
    }

    pub fn listOpenPrForBranch(self: *ForgeConnector, branch: []const u8) !?PullRequest {
        const a = self.transport.allocator;
        const encoded = try encodeComponent(a, branch);
        defer a.free(encoded);
        const owner_end = std.mem.indexOfScalar(u8, self.slug, '/') orelse return error.BadRemoteUrl;
        const suffix = switch (self.kind) {
            .github => try std.fmt.allocPrint(a, "/pulls?state=open&head={s}%3A{s}&per_page=100", .{ self.slug[0..owner_end], encoded }),
            .gitlab => try std.fmt.allocPrint(a, "/merge_requests?state=opened&source_branch={s}&per_page=100", .{encoded}),
            .gitea => try a.dupe(u8, "/pulls?state=open&limit=100"),
        };
        defer a.free(suffix);
        var r = try self.request("GET", suffix, null, 200);
        defer r.deinit(a);
        var p = try self.parse(&r);
        defer p.deinit();
        if (p.value != .array) return error.ForgeParseFailed;
        for (p.value.array.items) |value| {
            if (value != .object) return error.ForgeParseFailed;
            const ref = if (self.kind == .gitlab) value.object.get("source_branch") else blk: {
                const head = value.object.get("head") orelse return error.ForgeParseFailed;
                if (head != .object) return error.ForgeParseFailed;
                break :blk head.object.get("ref");
            };
            if (ref == null or ref.? != .string) return error.ForgeParseFailed;
            if (!std.mem.eql(u8, ref.?.string, branch)) continue;
            if (try self.state(value) != .open) continue;
            return try self.pull(value);
        }
        return null;
    }

    pub fn createPullRequest(self: *ForgeConnector, title: []const u8, description: []const u8, branch: []const u8, base: []const u8) !PullRequest {
        const a = self.transport.allocator;
        const body = if (self.kind == .gitlab)
            try std.fmt.allocPrint(a, "{{\"title\":{f},\"description\":{f},\"source_branch\":{f},\"target_branch\":{f}}}", .{ std.json.fmt(title, .{}), std.json.fmt(description, .{}), std.json.fmt(branch, .{}), std.json.fmt(base, .{}) })
        else
            try std.fmt.allocPrint(a, "{{\"title\":{f},\"body\":{f},\"head\":{f},\"base\":{f}}}", .{ std.json.fmt(title, .{}), std.json.fmt(description, .{}), std.json.fmt(branch, .{}), std.json.fmt(base, .{}) });
        defer a.free(body);
        var r = try self.request("POST", if (self.kind == .gitlab) "/merge_requests" else "/pulls", body, 201);
        defer r.deinit(a);
        var p = try self.parse(&r);
        defer p.deinit();
        return self.pull(p.value);
    }

    pub fn pullRequestState(self: *ForgeConnector, number: i64) !github.PullRequestState {
        if (number <= 0) return error.InvalidPullRequest;
        const a = self.transport.allocator;
        const suffix = try std.fmt.allocPrint(a, "/{s}/{d}", .{ if (self.kind == .gitlab) "merge_requests" else "pulls", number });
        defer a.free(suffix);
        var r = try self.request("GET", suffix, null, 200);
        defer r.deinit(a);
        var p = try self.parse(&r);
        defer p.deinit();
        return self.state(p.value);
    }

    pub fn mergePullRequest(self: *ForgeConnector, number: i64) !void {
        if (number <= 0) return error.InvalidPullRequest;
        const a = self.transport.allocator;
        const suffix = try std.fmt.allocPrint(a, "/{s}/{d}/merge", .{ if (self.kind == .gitlab) "merge_requests" else "pulls", number });
        defer a.free(suffix);
        var r = try self.request(if (self.kind == .gitea) "POST" else "PUT", suffix, if (self.kind == .gitea) "{\"Do\":\"merge\"}" else if (self.kind == .github) "{\"merge_method\":\"merge\"}" else "{}", 200);
        defer r.deinit(a);
        if (self.kind == .github) {
            var p = try self.parse(&r);
            defer p.deinit();
            if (p.value != .object) return error.ForgeParseFailed;
            const m = p.value.object.get("merged") orelse return error.ForgeParseFailed;
            if (m != .bool or !m.bool) return error.ForgeMergeFailed;
        }
    }

    /// Called only by the explicit ship action, also when adopting an open PR.
    pub fn ensurePullRequestReferences(self: *ForgeConnector, number: i64, references: []const u8) !void {
        if (number <= 0) return error.InvalidPullRequest;
        if (references.len == 0) return;
        const a = self.transport.allocator;
        const suffix = try std.fmt.allocPrint(a, "/{s}/{d}", .{ if (self.kind == .gitlab) "merge_requests" else "pulls", number });
        defer a.free(suffix);
        var response = try self.request("GET", suffix, null, 200);
        defer response.deinit(a);
        var p = try self.parse(&response);
        defer p.deinit();
        if (p.value != .object) return error.ForgeParseFailed;
        const field = if (self.kind == .gitlab) "description" else "body";
        const body = p.value.object.get(field) orelse return error.ForgeParseFailed;
        if (body != .string and body != .null) return error.ForgeParseFailed;
        const existing = if (body == .string) body.string else "";
        var updated = std.ArrayList(u8).empty;
        defer updated.deinit(a);
        try updated.appendSlice(a, existing);
        var lines = std.mem.splitScalar(u8, references, '\n');
        var changed = false;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var existing_lines = std.mem.splitScalar(u8, existing, '\n');
            var present = false;
            while (existing_lines.next()) |existing_line| {
                if (std.mem.eql(u8, std.mem.trimEnd(u8, existing_line, "\r"), line)) {
                    present = true;
                    break;
                }
            }
            if (present) continue;
            try updated.appendSlice(a, "\n");
            try updated.appendSlice(a, line);
            changed = true;
        }
        if (!changed) return;
        const json = try std.fmt.allocPrint(a, "{{\"{s}\":{f}}}", .{ field, std.json.fmt(updated.items, .{}) });
        defer a.free(json);
        var written = try self.request(if (self.kind == .gitlab) "PUT" else "PATCH", suffix, json, 200);
        defer written.deinit(a);
    }
};

const Fixture = struct {
    status: u16 = 200,
    response: []const u8 = "[]",
    method: []const u8 = "GET",
    url_contains: []const u8 = "",
    body_contains: ?[]const u8 = null,
    calls: usize = 0,
    fn rest(a: std.mem.Allocator, method: []const u8, url: []const u8, auth: ?[]const u8, body: ?[]const u8, ctx: ?*anyopaque) !gitea.RestResponse {
        const f: *Fixture = @ptrCast(@alignCast(ctx.?));
        f.calls += 1;
        try std.testing.expectEqualStrings(f.method, method);
        try std.testing.expect(std.mem.indexOf(u8, url, f.url_contains) != null);
        try std.testing.expectEqualStrings("Bearer synthetic", auth.?);
        if (f.body_contains) |needle| try std.testing.expect(std.mem.indexOf(u8, body.?, needle) != null);
        return .{ .status = f.status, .body = try a.dupe(u8, f.response) };
    }
};

const ReferenceFixture = struct {
    calls: usize = 0,
    kind: github.Forge,
    existing: []const u8 = "original",
    status: u16 = 200,
    fn rest(a: std.mem.Allocator, method: []const u8, url: []const u8, auth: ?[]const u8, body: ?[]const u8, ctx: ?*anyopaque) !gitea.RestResponse {
        _ = url;
        _ = auth;
        const f: *ReferenceFixture = @ptrCast(@alignCast(ctx.?));
        f.calls += 1;
        if (std.mem.eql(u8, method, "GET")) return .{ .status = f.status, .body = try std.fmt.allocPrint(a, "{{\"{s}\":{f}}}", .{ if (f.kind == .gitlab) "description" else "body", std.json.fmt(f.existing, .{}) }) };
        try std.testing.expectEqualStrings(if (f.kind == .gitlab) "PUT" else "PATCH", method);
        try std.testing.expect(std.mem.indexOf(u8, body.?, "Closes #7") != null);
        try std.testing.expect(std.mem.indexOf(u8, body.?, "original") != null);
        return .{ .status = f.status, .body = try a.dupe(u8, "{}") };
    }
};

test "SEC-RED forge reutiliza la politica HTTPS y loopback" {
    const a = std.testing.allocator;
    var transport = gitea.GiteaConnector.init(a);
    defer transport.deinit();
    var forge = ForgeConnector{ .transport = &transport, .kind = .gitea, .web_base = "", .slug = "team/repo" };
    for ([_][]const u8{ "http://localhost", "http://LOCALHOST", "http://127.42.0.1:8000", "http://[::1]:8000", "https://forge.example" }) |url| {
        forge.web_base = url;
        const endpoint_url = try forge.endpoint("");
        a.free(endpoint_url);
    }
    for ([_][]const u8{ "http://localhost.", "http://localhost.evil.com", "http://127.0.0.1.nip.io", "http://[::ffff:127.0.0.1]" }) |url| {
        forge.web_base = url;
        try std.testing.expectError(error.InsecureForgeUrl, forge.endpoint(""));
    }
}

test "providers E5.26 references on adopted PR additive idempotent and errors all forges" {
    const a = std.testing.allocator;
    inline for (.{ github.Forge.github, github.Forge.gitlab, github.Forge.gitea }) |kind| {
        var fixture = ReferenceFixture{ .kind = kind };
        var t = gitea.GiteaConnector.init(a);
        defer t.deinit();
        t.http_fn = ReferenceFixture.rest;
        t.http_ctx = &fixture;
        var f = ForgeConnector{ .transport = &t, .kind = kind, .web_base = "https://forge.example", .slug = "team/repo" };
        try f.ensurePullRequestReferences(8, "Closes #7");
        try std.testing.expectEqual(@as(usize, 2), fixture.calls);
        fixture.calls = 0;
        fixture.existing = "original\nCloses #7";
        try f.ensurePullRequestReferences(8, "Closes #7");
        try std.testing.expectEqual(@as(usize, 1), fixture.calls);
        try f.ensurePullRequestReferences(8, "");
        try std.testing.expectEqual(@as(usize, 1), fixture.calls);
        fixture.status = 401;
        try std.testing.expectError(error.ForgeUnauthorized, f.ensurePullRequestReferences(8, "new reference"));
        try std.testing.expectError(error.InvalidPullRequest, f.ensurePullRequestReferences(0, "Closes #7"));
    }
}

test "providers E5.26 forge REST contract create adopt merge and HTTP errors for all forges" {
    const a = std.testing.allocator;
    inline for (.{ github.Forge.github, github.Forge.gitlab, github.Forge.gitea }) |kind| {
        var fixture = Fixture{};
        var t = gitea.GiteaConnector.init(a);
        defer t.deinit();
        t.http_fn = Fixture.rest;
        t.http_ctx = &fixture;
        t.auth_header = try a.dupe(u8, "Bearer synthetic");
        var f = ForgeConnector{ .transport = &t, .kind = kind, .web_base = "https://forge.example", .slug = "team/repo" };
        fixture.url_contains = switch (kind) {
            .github => "/api/v3/repos/team/repo",
            .gitlab => "/api/v4/projects/team%2Frepo",
            .gitea => "/api/v1/repos/team/repo",
        };
        fixture.response = "{\"default_branch\":\"trunk\"}";
        const base = try f.repoDefaultBranch();
        defer a.free(base);
        try std.testing.expectEqualStrings("trunk", base);
        fixture.status = 201;
        fixture.method = "POST";
        fixture.body_contains = if (kind == .gitlab) "\"source_branch\":\"feature/a\"" else "\"head\":\"feature/a\"";
        fixture.response = if (kind == .gitlab) "{\"iid\":8,\"web_url\":\"https://forge.example/team/repo/-/merge_requests/8\",\"state\":\"opened\"}" else "{\"number\":8,\"html_url\":\"https://forge.example/team/repo/pulls/8\",\"state\":\"open\"}";
        var pr = try f.createPullRequest("title", "body", "feature/a", "trunk");
        defer pr.deinit(a);
        try std.testing.expectEqual(@as(i64, 8), pr.number);
        fixture.method = "GET";
        fixture.status = 200;
        fixture.body_contains = null;
        fixture.response = if (kind == .gitlab) "[{\"iid\":8,\"web_url\":\"https://forge.example/team/repo/-/merge_requests/8\",\"state\":\"opened\",\"source_branch\":\"feature/a\"}]" else "[{\"number\":8,\"html_url\":\"https://forge.example/team/repo/pulls/8\",\"state\":\"open\",\"head\":{\"ref\":\"feature/a\"}}]";
        var adopted = (try f.listOpenPrForBranch("feature/a")).?;
        defer adopted.deinit(a);
        try std.testing.expectEqual(@as(i64, 8), adopted.number);
        try std.testing.expect((try f.listOpenPrForBranch("other")) == null);
        fixture.method = if (kind == .gitea) "POST" else "PUT";
        fixture.response = "{\"merged\":true}";
        try f.mergePullRequest(8);
        fixture.method = "GET";
        fixture.response = if (kind == .gitlab) "{\"state\":\"merged\"}" else "{\"state\":\"closed\",\"merged\":true}";
        try std.testing.expectEqual(github.PullRequestState.merged, try f.pullRequestState(8));
        inline for (.{ @as(u16, 401), @as(u16, 404), @as(u16, 422) }, .{ error.ForgeUnauthorized, error.ForgeNotFound, error.ForgeValidationFailed }) |status, failure| {
            fixture.status = status;
            fixture.response = "{\"token\":\"fx-s7\",\"password\":\"synthetic\"}";
            try std.testing.expectError(failure, f.listOpenPrForBranch("feature/a"));
            try std.testing.expectError(failure, f.repoDefaultBranch());
            try std.testing.expectError(failure, f.pullRequestState(8));
            fixture.method = "POST";
            try std.testing.expectError(failure, f.createPullRequest("t", "b", "feature/a", "trunk"));
            fixture.method = if (kind == .gitea) "POST" else "PUT";
            try std.testing.expectError(failure, f.mergePullRequest(8));
            fixture.method = "GET";
            try std.testing.expect(std.mem.indexOf(u8, t.last_error.items, "synthetic") == null);
            try std.testing.expect(std.mem.indexOf(u8, t.last_error.items, "fx-s7") == null);
        }
    }
}

test "providers E5.26 guard rejects credential URL traversal malformed responses and false merge" {
    const a = std.testing.allocator;
    var fixture = Fixture{};
    var t = gitea.GiteaConnector.init(a);
    defer t.deinit();
    t.http_fn = Fixture.rest;
    t.http_ctx = &fixture;
    t.auth_header = try a.dupe(u8, "Bearer synthetic");
    var f = ForgeConnector{ .transport = &t, .kind = .github, .web_base = "https://user:secret@forge.example", .slug = "team/repo" };
    try std.testing.expectError(error.BadRemoteUrl, f.repoDefaultBranch());
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    f.web_base = "https://forge.example";
    f.web_base = "http://forge.example";
    try std.testing.expectError(error.InsecureForgeUrl, f.repoDefaultBranch());
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    f.web_base = "https://forge.example";
    f.slug = "team/../repo";
    try std.testing.expectError(error.BadRemoteUrl, f.repoDefaultBranch());
    f.slug = "team/repo";
    fixture.response = "[]";
    try std.testing.expectError(error.ForgeParseFailed, f.repoDefaultBranch());
    try std.testing.expectError(error.ForgeParseFailed, f.pullRequestState(8));
    fixture.method = "PUT";
    fixture.response = "{\"merged\":false}";
    try std.testing.expectError(error.ForgeMergeFailed, f.mergePullRequest(8));
    try std.testing.expectError(error.InvalidPullRequest, f.mergePullRequest(0));
    try std.testing.expectError(error.InvalidPullRequest, f.pullRequestState(-1));
    fixture.method = "GET";
    fixture.status = 401;
    try std.testing.expectError(error.ForgeUnauthorized, f.repoDefaultBranch());
    try std.testing.expect(t.last_error.items.len > 0);
    fixture.status = 200;
    fixture.response = "[]";
    try std.testing.expectError(error.ForgeParseFailed, f.repoDefaultBranch());
    try std.testing.expectEqual(@as(usize, 0), t.last_error.items.len);
    fixture.method = "POST";
    fixture.status = 201;
    fixture.response = "{\"number\":8,\"html_url\":\"https://forge.example.evil/team/repo/pulls/8\",\"state\":\"open\"}";
    try std.testing.expectError(error.ForgeParseFailed, f.createPullRequest("t", "b", "branch", "main"));
    const encoded = try encodeComponent(a, "feature/a ?");
    defer a.free(encoded);
    try std.testing.expectEqualStrings("feature%2Fa%20%3F", encoded);
}
