//! SEC5 P1 only: no production import or authority migration.
//! The fixture owns the executable pin, environment, ACL and pipe capabilities.
const std = @import("std");
pub const win = @cImport({
    @cInclude("sec5_launch.h");
});
const c = win;

pub const Authority = union(enum) {
    sandbox: struct { lease_sid: c.PSID },
};
pub const LaunchRequest = struct {
    authority: Authority,
    fixture: c.sec5_request,
};

fn fail(result: *c.sec5_result, stage: c.enum_sec5_stage, code: c.DWORD) void {
    result.stage = stage;
    result.@"error" = if (code == 0) @as(c.DWORD, c.ERROR_GEN_FAILURE) else code;
    // A failed suspended launch is terminated, never just abandoned by closing.
    if (result.pi.hProcess != null) {
        if (c.TerminateProcess(result.pi.hProcess, 125) == 0 and c.WaitForSingleObject(result.pi.hProcess, 0) != c.WAIT_OBJECT_0)
            result.cleanup_error = c.GetLastError();
        if (result.job != null and c.TerminateJobObject(result.job, 125) == 0 and result.cleanup_error == 0)
            result.cleanup_error = c.GetLastError();
        if (c.WaitForSingleObject(result.pi.hProcess, 10_000) != c.WAIT_OBJECT_0 and result.cleanup_error == 0)
            result.cleanup_error = c.ERROR_TIMEOUT;
    }
    // Returned handles remain owned by the fixture, including failure handles.
}

fn tokenDword(token: c.HANDLE, class: c.TOKEN_INFORMATION_CLASS, out: *c.DWORD) bool {
    var size: c.DWORD = 0;
    return c.GetTokenInformation(token, class, out, @sizeOf(c.DWORD), &size) != 0;
}

fn sameExecutable(pin: c.HANDLE, path: [*c]const c.WCHAR) bool {
    if (pin == null or pin == c.INVALID_HANDLE_VALUE or path == null) return false;
    // The name Windows will reopen must resolve to the retained fixture object.
    const reopened = c.CreateFileW(path, c.GENERIC_READ, c.FILE_SHARE_READ, null, c.OPEN_EXISTING, c.FILE_FLAG_OPEN_REPARSE_POINT, null);
    if (reopened == c.INVALID_HANDLE_VALUE) return false;
    defer _ = c.CloseHandle(reopened);
    var a: c.FILE_ID_INFO = std.mem.zeroes(c.FILE_ID_INFO);
    var b: c.FILE_ID_INFO = std.mem.zeroes(c.FILE_ID_INFO);
    var attributes: c.BY_HANDLE_FILE_INFORMATION = undefined;
    if (c.GetFileInformationByHandle(reopened, &attributes) == 0 or (attributes.dwFileAttributes & c.FILE_ATTRIBUTE_REPARSE_POINT) != 0) return false;
    if (c.GetFileInformationByHandleEx(pin, c.FileIdInfo, &a, @sizeOf(c.FILE_ID_INFO)) == 0 or
        c.GetFileInformationByHandleEx(reopened, c.FileIdInfo, &b, @sizeOf(c.FILE_ID_INFO)) == 0) return false;
    return a.VolumeSerialNumber == b.VolumeSerialNumber and std.mem.eql(u8, &a.FileId.Identifier, &b.FileId.Identifier);
}

/// No exception/fallback to an ordinary token. Mutation switches are private
/// fixture inputs; this module is not linked into the core or host.
pub fn launch(request: LaunchRequest) c.sec5_result {
    const r = request.fixture;
    var result = std.mem.zeroes(c.sec5_result);
    if (!sameExecutable(r.executable_pin, r.executable) or r.environment == null or r.cwd == null or r.command_line == null or
        request.authority.sandbox.lease_sid == null or c.IsValidSid(request.authority.sandbox.lease_sid) == 0 or (r.backend != c.SEC5_APPCONTAINER and r.backend != c.SEC5_RESTRICTED_DIAGNOSTIC) or r.observe_suspended == null or (r.backend == c.SEC5_RESTRICTED_DIAGNOSTIC and r.default_dacl == null) or
        r.handle_count > 32 or (r.handle_count != 0 and r.handles == null))
    {
        fail(&result, c.SEC5_INPUT, c.ERROR_INVALID_PARAMETER);
        return result;
    }
    var token: c.HANDLE = null;
    defer if (token != null) {
        _ = c.CloseHandle(token);
    };
    if (r.backend == c.SEC5_RESTRICTED_DIAGNOSTIC) {
        var source: c.HANDLE = null;
        if (c.OpenProcessToken(c.GetCurrentProcess(), c.TOKEN_QUERY | c.TOKEN_DUPLICATE | c.TOKEN_ASSIGN_PRIMARY | c.TOKEN_ADJUST_DEFAULT, &source) == 0) {
            fail(&result, c.SEC5_TOKEN, c.GetLastError());
            return result;
        }
        defer _ = c.CloseHandle(source);
        // SIDs restrictivos (medido el 10-oct, orq-matriz-aislamiento-20261010.txt):
        // con solo el SID de lease ningún binario que cargue user32 arranca
        // (0xC0000142). Se añaden Everyone, Users, Authenticated Users, RESTRICTED y
        // el SID de logon: no conceden escritura sobre archivos del usuario (solo su
        // SID) y la integridad baja bloquea todo objeto medio. Residuo declarado:
        // objetos de integridad baja escribibles por esos grupos genéricos.
        var sids: [6]c.SID_AND_ATTRIBUTES = undefined;
        var sid_count: c.DWORD = 0;
        if (r.mutation != c.SEC5_NO_SID) {
            sids[sid_count] = .{ .Sid = request.authority.sandbox.lease_sid, .Attributes = 0 };
            sid_count += 1;
        }
        var generic: [4]c.PSID = .{ null, null, null, null };
        defer for (generic) |g| {
            if (g != null) _ = c.LocalFree(g);
        };
        const generic_text = .{ "S-1-1-0", "S-1-5-32-545", "S-1-5-11", "S-1-5-12" };
        inline for (generic_text, 0..) |text, i| {
            if (c.ConvertStringSidToSidW(std.unicode.utf8ToUtf16LeStringLiteral(text), &generic[i]) == 0) {
                fail(&result, c.SEC5_TOKEN, c.GetLastError());
                return result;
            }
            sids[sid_count] = .{ .Sid = generic[i], .Attributes = 0 };
            sid_count += 1;
        }
        var groups_size: c.DWORD = 0;
        _ = c.GetTokenInformation(source, c.TokenGroups, null, 0, &groups_size);
        const groups_buf = std.heap.page_allocator.alignedAlloc(u8, .of(usize), groups_size) catch {
            fail(&result, c.SEC5_TOKEN, c.ERROR_NOT_ENOUGH_MEMORY);
            return result;
        };
        defer std.heap.page_allocator.free(groups_buf);
        if (groups_size == 0 or c.GetTokenInformation(source, c.TokenGroups, groups_buf.ptr, groups_size, &groups_size) == 0) {
            fail(&result, c.SEC5_TOKEN, c.GetLastError());
            return result;
        }
        const token_groups: *const c.TOKEN_GROUPS = @ptrCast(groups_buf.ptr);
        const group_list: [*]const c.SID_AND_ATTRIBUTES = @ptrCast(&token_groups.Groups);
        var logon_found = false;
        for (0..token_groups.GroupCount) |i| {
            if ((group_list[i].Attributes & c.SE_GROUP_LOGON_ID) == c.SE_GROUP_LOGON_ID) {
                sids[sid_count] = .{ .Sid = group_list[i].Sid, .Attributes = 0 };
                sid_count += 1;
                logon_found = true;
                break;
            }
        }
        if (!logon_found) {
            fail(&result, c.SEC5_TOKEN, c.ERROR_NO_SUCH_LOGON_SESSION);
            return result;
        }
        const flags: c.DWORD = @as(c.DWORD, c.DISABLE_MAX_PRIVILEGE) | (if (r.mutation == c.SEC5_NO_WRITE_RESTRICTED) @as(c.DWORD, 0) else @as(c.DWORD, c.WRITE_RESTRICTED));
        if (c.CreateRestrictedToken(source, flags, 0, null, 0, null, sid_count, &sids, &token) == 0) {
            fail(&result, c.SEC5_TOKEN, c.GetLastError());
            return result;
        }
        var low: c.PSID = null;
        if (c.ConvertStringSidToSidW(std.unicode.utf8ToUtf16LeStringLiteral("S-1-16-4096"), &low) == 0) {
            fail(&result, c.SEC5_INTEGRITY, c.GetLastError());
            return result;
        }
        defer _ = c.LocalFree(low);
        var label = c.TOKEN_MANDATORY_LABEL{ .Label = .{ .Sid = low, .Attributes = c.SE_GROUP_INTEGRITY } };
        if (r.mutation != c.SEC5_NO_IL and c.SetTokenInformation(token, c.TokenIntegrityLevel, &label, @sizeOf(c.TOKEN_MANDATORY_LABEL) + c.GetLengthSid(low)) == 0) {
            fail(&result, c.SEC5_INTEGRITY, c.GetLastError());
            return result;
        }
        // TokenMandatoryPolicy solo se puede FIJAR con SeTcbPrivilege (1314 medido
        // el 10-oct con usuario estándar). Se exige que el token ya la tenga: la
        // política por defecto es NO_WRITE_UP | NEW_PROCESS_MIN.
        var policy: c.DWORD = 0;
        const required_policy: c.DWORD = c.TOKEN_MANDATORY_POLICY_NO_WRITE_UP | c.TOKEN_MANDATORY_POLICY_NEW_PROCESS_MIN;
        if (!tokenDword(token, c.TokenMandatoryPolicy, &policy) or (policy & required_policy) != required_policy) {
            fail(&result, c.SEC5_POLICY, c.ERROR_INVALID_SECURITY_DESCR);
            return result;
        }
        var dacl = c.TOKEN_DEFAULT_DACL{ .DefaultDacl = r.default_dacl };
        if (c.SetTokenInformation(token, c.TokenDefaultDacl, &dacl, @sizeOf(c.TOKEN_DEFAULT_DACL)) == 0) {
            fail(&result, c.SEC5_POLICY, c.GetLastError());
            return result;
        }
        var ui: c.DWORD = 0;
        var virtualization: c.DWORD = 0;
        if (!tokenDword(token, c.TokenUIAccess, &ui) or !tokenDword(token, c.TokenVirtualizationEnabled, &virtualization) or ui != 0 or virtualization != 0) {
            fail(&result, c.SEC5_POLICY, c.ERROR_ACCESS_DENIED);
            return result;
        }
    }
    result.job = if (r.recovery_job != null) r.recovery_job else c.CreateJobObjectW(null, null);
    if (result.job == null) {
        fail(&result, c.SEC5_JOB, c.GetLastError());
        return result;
    }
    var limits = std.mem.zeroes(c.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    limits.BasicLimitInformation.LimitFlags = c.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | c.JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
    if (r.mutation == c.SEC5_NO_JOB_KILL) limits.BasicLimitInformation.LimitFlags &= ~@as(c.DWORD, c.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE);
    if (r.mutation == c.SEC5_BREAKAWAY_OK) limits.BasicLimitInformation.LimitFlags |= c.JOB_OBJECT_LIMIT_BREAKAWAY_OK;
    if (c.SetInformationJobObject(result.job, c.JobObjectExtendedLimitInformation, &limits, @sizeOf(c.JOBOBJECT_EXTENDED_LIMIT_INFORMATION)) == 0) {
        fail(&result, c.SEC5_JOB, c.GetLastError());
        return result;
    }
    var si = std.mem.zeroes(c.STARTUPINFOEXW);
    si.StartupInfo.cb = @sizeOf(c.STARTUPINFOW);
    si.StartupInfo.dwFlags = if (r.handle_count != 0) c.STARTF_USESTDHANDLES else 0;
    si.StartupInfo.hStdInput = r.stdin_handle;
    si.StartupInfo.hStdOutput = r.stdout_handle;
    si.StartupInfo.hStdError = r.stderr_handle;
    var attribute_size: c.SIZE_T = 0;
    var attributes: ?[]align(@alignOf(usize)) u8 = null;
    var initialized = false;
    defer {
        if (initialized) c.DeleteProcThreadAttributeList(si.lpAttributeList);
        if (attributes) |memory| std.heap.page_allocator.free(memory);
    }
    const appcontainer = r.backend == c.SEC5_APPCONTAINER and r.mutation != c.SEC5_NO_APPCONTAINER;
    const handle_list = r.handle_count != 0 and r.mutation != c.SEC5_NO_HANDLE_LIST;
    const attribute_count: c.DWORD = @intFromBool(appcontainer) + @as(c.DWORD, @intFromBool(handle_list));
    var capabilities = std.mem.zeroes(c.SECURITY_CAPABILITIES);
    capabilities.AppContainerSid = r.lease_sid;
    var runtime_capability = std.mem.zeroes(c.SID_AND_ATTRIBUTES);
    if (r.runtime_capability != null and r.mutation != c.SEC5_NO_RUNTIME_CAPABILITY) {
        if (r.backend != c.SEC5_APPCONTAINER or c.IsValidSid(r.runtime_capability) == 0) {
            fail(&result, c.SEC5_ATTRIBUTES, c.ERROR_INVALID_SID);
            return result;
        }
        runtime_capability.Sid = r.runtime_capability;
        runtime_capability.Attributes = c.SE_GROUP_ENABLED;
        capabilities.Capabilities = &runtime_capability;
        capabilities.CapabilityCount = 1;
    }
    if (attribute_count != 0) {
        _ = c.InitializeProcThreadAttributeList(null, attribute_count, 0, &attribute_size);
        if (attribute_size == 0) {
            fail(&result, c.SEC5_ATTRIBUTES, c.GetLastError());
            return result;
        }
        attributes = std.heap.page_allocator.alignedAlloc(u8, .of(usize), attribute_size) catch {
            fail(&result, c.SEC5_ATTRIBUTES, c.ERROR_NOT_ENOUGH_MEMORY);
            return result;
        };
        si.lpAttributeList = @ptrCast(attributes.?.ptr);
        if (c.InitializeProcThreadAttributeList(si.lpAttributeList, attribute_count, 0, &attribute_size) == 0) {
            fail(&result, c.SEC5_ATTRIBUTES, c.GetLastError());
            return result;
        }
        initialized = true;
        if (appcontainer and c.UpdateProcThreadAttribute(si.lpAttributeList, 0, c.PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, &capabilities, @sizeOf(c.SECURITY_CAPABILITIES), null, null) == 0) {
            fail(&result, c.SEC5_ATTRIBUTES, c.GetLastError());
            return result;
        }
        if (handle_list) {
            for (0..r.handle_count) |i| {
                var handle_flags: c.DWORD = 0;
                if (c.GetHandleInformation(r.handles[i], &handle_flags) == 0 or (handle_flags & c.HANDLE_FLAG_INHERIT) == 0) {
                    fail(&result, c.SEC5_ATTRIBUTES, c.ERROR_INVALID_HANDLE);
                    return result;
                }
            }
            if (c.UpdateProcThreadAttribute(si.lpAttributeList, 0, c.PROC_THREAD_ATTRIBUTE_HANDLE_LIST, @ptrCast(r.handles), @as(c.SIZE_T, r.handle_count) * @sizeOf(c.HANDLE), null, null) == 0) {
                fail(&result, c.SEC5_ATTRIBUTES, c.GetLastError());
                return result;
            }
        }
    }
    // AppContainer keeps SECURITY_CAPABILITIES even without inherited handles.
    if (initialized) si.StartupInfo.cb = @sizeOf(c.STARTUPINFOEXW);
    const base_flags: c.DWORD = c.CREATE_SUSPENDED | c.CREATE_UNICODE_ENVIRONMENT | c.CREATE_NO_WINDOW;
    const creation_flags: c.DWORD = base_flags | (if (initialized) @as(c.DWORD, c.EXTENDED_STARTUPINFO_PRESENT) else @as(c.DWORD, 0));
    // A common runtime SID must never grant access to another order's process.
    // R2 uses its package-only descriptor for process/thread objects as well.
    var process_descriptor = std.mem.zeroes(c.SECURITY_DESCRIPTOR);
    var process_security = std.mem.zeroes(c.SECURITY_ATTRIBUTES);
    const private_process_objects = appcontainer and r.runtime_capability != null;
    if (private_process_objects) {
        if (r.default_dacl == null or c.InitializeSecurityDescriptor(&process_descriptor, c.SECURITY_DESCRIPTOR_REVISION) == 0 or
            c.SetSecurityDescriptorDacl(&process_descriptor, c.TRUE, r.default_dacl, c.FALSE) == 0)
        {
            fail(&result, c.SEC5_POLICY, c.ERROR_INVALID_SECURITY_DESCR);
            return result;
        }
        process_security.nLength = @sizeOf(c.SECURITY_ATTRIBUTES);
        process_security.lpSecurityDescriptor = &process_descriptor;
    }
    const created = if (r.backend == c.SEC5_APPCONTAINER)
        c.CreateProcessW(r.executable, r.command_line, if (private_process_objects) &process_security else null, if (private_process_objects) &process_security else null, @intFromBool(r.handle_count != 0), creation_flags, @constCast(r.environment), r.cwd, &si.StartupInfo, &result.pi)
    else
        c.CreateProcessAsUserW(token, r.executable, r.command_line, null, null, @intFromBool(r.handle_count != 0), creation_flags, @constCast(r.environment), r.cwd, &si.StartupInfo, &result.pi);
    if (created == 0) {
        fail(&result, c.SEC5_CREATE, c.GetLastError());
        return result;
    }
    // Fixture containment is outside the SEC5 Job under test, and precedes
    // even the deliberately broken resume-first ordering.
    if (r.harness_job != null and c.AssignProcessToJobObject(r.harness_job, result.pi.hProcess) == 0) {
        fail(&result, c.SEC5_ASSIGN, c.GetLastError());
        return result;
    }
    var exit_time: c.FILETIME = undefined;
    var kernel_time: c.FILETIME = undefined;
    var user_time: c.FILETIME = undefined;
    if (c.GetProcessTimes(result.pi.hProcess, &result.creation_time, &exit_time, &kernel_time, &user_time) == 0) {
        fail(&result, c.SEC5_OBSERVE, c.GetLastError());
        return result;
    }
    // Inject failures only after retaining the suspended process identity.
    // These cancellation seams stand for token/ACL/Job/final preparation;
    // no durable production journal is implemented in round 1.
    if (r.fail_before_resume != 0 and r.fail_stage != 0 and r.fail_stage != c.SEC5_SEEDED and r.mutation != c.SEC5_RESUME_FIRST) {
        fail(&result, r.fail_stage, c.ERROR_CANCELLED);
        return result;
    }
    if (r.mutation == c.SEC5_RESUME_FIRST) {
        if (c.ResumeThread(result.pi.hThread) != 1) {
            fail(&result, c.SEC5_RESUME, c.GetLastError());
            return result;
        }
        result.resumed = c.TRUE;
        // Deterministic seeded defect: the first-act witness must precede the
        // deliberately failed assignment. No scheduling-race-based mutation.
        if (r.early_event == null or c.WaitForSingleObject(r.early_event, 10_000) != c.WAIT_OBJECT_0) {
            fail(&result, c.SEC5_OBSERVE, c.ERROR_TIMEOUT);
            return result;
        }
        fail(&result, c.SEC5_ASSIGN, c.ERROR_ACCESS_DENIED);
        return result;
    }
    if (c.AssignProcessToJobObject(result.job, result.pi.hProcess) == 0) {
        fail(&result, c.SEC5_ASSIGN, c.GetLastError());
        return result;
    }
    var in_job: c.BOOL = c.FALSE;
    var actual_limits = std.mem.zeroes(c.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    if (c.IsProcessInJob(result.pi.hProcess, result.job, &in_job) == 0 or in_job == 0 or
        c.QueryInformationJobObject(result.job, c.JobObjectExtendedLimitInformation, &actual_limits, @sizeOf(c.JOBOBJECT_EXTENDED_LIMIT_INFORMATION), null) == 0 or
        actual_limits.BasicLimitInformation.LimitFlags != limits.BasicLimitInformation.LimitFlags)
    {
        fail(&result, c.SEC5_ASSIGN, c.ERROR_INVALID_DATA);
        return result;
    }
    if (r.observe_suspended) |observer| {
        if (observer(result.pi.hProcess, result.job, r.observer_context) == 0) {
            fail(&result, c.SEC5_OBSERVE, c.ERROR_INVALID_DATA);
            return result;
        }
    }
    if (r.lifecycle) |callback| {
        if (callback(c.SEC5_OBSERVE, result.pi.hProcess, result.job, r.observer_context) == 0) {
            fail(&result, c.SEC5_OBSERVE, c.ERROR_WRITE_FAULT);
            return result;
        }
    }
    if (r.fail_before_resume != 0) {
        fail(&result, c.SEC5_SEEDED, c.ERROR_CANCELLED);
        return result;
    }
    if (c.ResumeThread(result.pi.hThread) != 1) {
        fail(&result, c.SEC5_RESUME, c.GetLastError());
        return result;
    }
    result.resumed = c.TRUE;
    if (r.lifecycle) |callback| {
        if (callback(c.SEC5_RESUME, result.pi.hProcess, result.job, r.observer_context) == 0) {
            fail(&result, c.SEC5_RESUME, c.ERROR_WRITE_FAULT);
            return result;
        }
    }
    result.stage = c.SEC5_READY;
    return result;
}
