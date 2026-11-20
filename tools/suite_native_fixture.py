"""Run the Zig test protocol with the existing native HTTP fixture on loopback."""

import importlib.util
from contextlib import nullcontext, ExitStack
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid


def close_unrelated_inherited_pipes():
    # Zig 0.16 CreateProcessW inherits every inheritable handle, including
    # writers for sibling Run steps. Keeping one prevents that sibling's EOF.
    # CPython's close_fds applies to our child, not to this wrapper itself.
    if os.name != 'nt':
        return
    import ctypes
    from ctypes import wintypes
    import msvcrt

    class Entry(ctypes.Structure):
        _fields_ = [('handle', wintypes.HANDLE), ('handle_count', ctypes.c_size_t),
                    ('pointer_count', ctypes.c_size_t), ('access', wintypes.ULONG),
                    ('type', wintypes.ULONG), ('attributes', wintypes.ULONG),
                    ('reserved', wintypes.ULONG)]

    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    query = ctypes.WinDLL('ntdll').NtQueryInformationProcess
    query.argtypes = [wintypes.HANDLE, wintypes.ULONG, ctypes.c_void_p,
                      wintypes.ULONG, ctypes.POINTER(wintypes.ULONG)]
    query.restype = wintypes.LONG
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    kernel.GetStdHandle.argtypes = [wintypes.DWORD]
    kernel.GetStdHandle.restype = wintypes.HANDLE
    kernel.GetHandleInformation.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel.GetFileType.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    keep = {kernel.GetStdHandle(value & 0xffffffff) for value in (-10, -11, -12)}
    keep.update(msvcrt.get_osfhandle(fd) for fd in (0, 1, 2))
    progress = os.environ.get('ZIG_PROGRESS')
    if progress:
        keep.add(int(progress))
    size = 4096
    while True:
        buffer = ctypes.create_string_buffer(size)
        needed = wintypes.ULONG()
        # ProcessHandleInformation (51), available since Windows 8.
        status = query(kernel.GetCurrentProcess(), 51, buffer, size, ctypes.byref(needed))
        if status == 0:
            break
        if status & 0xffffffff not in (0xc0000004, 0xc0000023):
            raise OSError('ProcessHandleInformation failed: 0x%08x' % (status & 0xffffffff))
        size = max(size * 2, needed.value)
        if size > 16 * 1024 * 1024:
            raise OSError('ProcessHandleInformation exceeds fixture limit')
    count = ctypes.c_size_t.from_buffer(buffer).value
    header_size = 2 * ctypes.sizeof(ctypes.c_size_t)
    if header_size + count * ctypes.sizeof(Entry) > size:
        raise OSError('Invalid ProcessHandleInformation length')
    entries = (Entry * count).from_buffer(buffer, header_size)
    closed = 0
    for entry in entries:
        handle = entry.handle
        if handle in keep:
            continue
        flags = wintypes.DWORD()
        if not kernel.GetHandleInformation(handle, ctypes.byref(flags)):
            raise ctypes.WinError(ctypes.get_last_error())
        if flags.value & 1 and kernel.GetFileType(handle) == 3:  # inherited pipe
            if not kernel.CloseHandle(handle):
                raise ctypes.WinError(ctypes.get_last_error())
            closed += 1
    print(f'TEST_UNRELATED_INHERITED_PIPES_CLOSED={closed}', file=sys.stderr, flush=True)


def main():
    started = time.monotonic()
    close_unrelated_inherited_pipes()
    native = sys.argv[1] == "--native"
    command = sys.argv[2:] if native else sys.argv[1:]
    original_cwd = Path.cwd()
    # T9 fase B: en Linux no hay LOCALAPPDATA; la carpeta temporal del sistema
    # (TMPDIR o /tmp) cumple el mismo papel.
    temp_parent = Path(os.environ["LOCALAPPDATA"]) / "Temp" if os.name == "nt" else Path(tempfile.gettempdir())
    with tempfile.TemporaryDirectory(prefix="beats-suite-run-", dir=temp_parent) as root, \
            tempfile.TemporaryDirectory(prefix="beats-suite-profile-", dir=temp_parent) as profile_root:
        Path(root).resolve().relative_to(temp_parent.resolve())
        env = os.environ.copy()
        env.update(DEVAGENTS_TEST_REAL_CLI_FORBIDDEN="1", DEVAGENTS_TEST_FIXTURE_DIR=root,
                   DEVAGENTS_TEST_PROFILE_DIR=profile_root)
        profile = Path(profile_root)
        env.update(HOME=str(profile), USERPROFILE=str(profile), XDG_CONFIG_HOME=str(profile / ".config"))
        for key in ("OPENCODE_CONFIG", "OPENCODE_CONFIG_DIR", "OPENCODE_CONFIG_CONTENT"):
            env.pop(key, None)
        for key in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "ENGRAM_BIN"):
            env.pop(key, None)
        env.update(TEMP=root, TMP=root, LOCALAPPDATA=root, PYTHONDONTWRITEBYTECODE="1")
        if os.name != "nt":
            # T9 fase B: las rutas XDG (claves en ~/.config/devagents, datos) y
            # TMPDIR caen dentro de la carpeta temporal, nunca en el HOME real.
            for name in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"):
                env[name] = str(Path(root) / ("xdg-" + name[4:-5].lower()))
            env.update(TMPDIR=root)
        # modo aislado documentado de la carpeta de datos. Desde que
        # host, CLI y MCP comparten core.paths.resolveDataDir, el valor por
        # defecto viene de la API de carpetas conocidas (SHGetFolderPathW), que
        # IGNORA la variable LOCALAPPDATA: sin este override la suite entera
        # abriría y escribiria la runtime.db REAL del usuario (incidente).
        # Aqui se fija la misma subcarpeta que antes resolvia LOCALAPPDATA, asi
        # que las rutas de las pruebas no cambian y ninguna toca la base real.
        data_dir = Path(root) / 'DevAgents'
        data_dir.mkdir(parents=True, exist_ok=True)
        env.update(BEATS_DATA_DIR=str(data_dir))
        git_config = Path(root) / 'empty.gitconfig'
        git_config.write_text('', encoding='utf-8')
        env.update(GIT_CONFIG_GLOBAL=str(git_config), GIT_CONFIG_NOSYSTEM="1")
        # The core needs only these tracked fixtures, never the repository or
        # the owner's data. Every test binary gets its own working directory.
        for rel in ("tests/fixtures/discovery", "tests/fixtures/linked"):
            source = original_cwd / rel
            if source.is_dir():
                shutil.copytree(source, Path(root) / rel)
        checklist = original_cwd / "CHECKLIST.md"
        if checklist.is_file():
            shutil.copyfile(checklist, Path(root) / "CHECKLIST.md")
        print(f"TEST_TEMP_START={root}", file=sys.stderr, flush=True)
        log_path = None
        if "--listen=-" in command:
            cache_arg = next(arg for arg in command if arg.startswith('--cache-dir='))
            log_dir = Path(cache_arg.split('=', 1)[1]).resolve() / 'suite-cleanup'
            log_dir.mkdir(parents=True, exist_ok=True)
            evidence_id = os.environ.get('BEATS_SUITE_EVIDENCE_ID', uuid.uuid4().hex)
            if not re.fullmatch('[0-9a-f]{32}', evidence_id):
                raise ValueError('Invalid suite evidence ID')
            log_path = log_dir / (evidence_id + '-' + Path(root).name + '.log')
            print(f'TEST_RUNNER_LOG={log_path}', file=sys.stderr, flush=True)
        try:
            code = run(command, env, root, native, log_path)
            print(f"TEST_CHILD_EXIT={code} ELAPSED_S={time.monotonic() - started:.3f} BIN={command[0]}", file=sys.stderr, flush=True)
            if "--listen=-" in command:
                # The test executable has finished the protocol. Signal EOF
                # now: Zig will wait for this wrapper's exit (and still reject
                # cleanup failures), without timing cleanup as a missing reply.
                print(f'TEST_CLEANUP_LOG={log_path}', file=sys.stderr, flush=True)
                # Zig's MultiReader waits for EOF on both pipes. Retaining
                # stderr still triggers its response timer, even with stdout
                # closed. Keep raw cleanup diagnostics in the build cache;
                # suite_evidence.ps1 collects them, including exceptions.
                sys.stderr = open(log_path, 'a', encoding='utf-8', buffering=1)
                sys.stdout = sys.stderr
                os.close(1)
                os.close(2)
            return code
        finally:
            cleanup_started = time.monotonic()
            remove_worktrees(Path(root))
            print(f"TEST_TEMP_CLEANUP={root} WORKTREE_CLEANUP_S={time.monotonic() - cleanup_started:.3f}", file=sys.stderr, flush=True)


def remove_worktrees(root):
    # Only repositories created inside this invocation belong to the fixture.
    # Remove registered worktrees before the temporary repository itself.
    for directory, children, _ in os.walk(root, followlinks=False):
        if ".git" not in children:
            continue
        children.remove(".git")
        repo = Path(directory).resolve()
        repo.relative_to(root.resolve())
        if not (repo / '.git/worktrees').is_dir():
            continue
        listing = subprocess.run(["git", "-C", str(repo), "worktree", "list", "--porcelain"],
                                 capture_output=True, text=True, check=True)
        for line in listing.stdout.splitlines():
            if not line.startswith("worktree "):
                continue
            worktree = Path(line[len("worktree "):]).resolve()
            worktree.relative_to(root.resolve())
            if worktree != repo:
                subprocess.run(["git", "-C", str(repo), "worktree", "remove", "--force", str(worktree)],
                               stdout=sys.stderr, stderr=sys.stderr, check=True)
                print(f"TEST_WORKTREE_REMOVED={worktree}", file=sys.stderr, flush=True)
        subprocess.run(["git", "-C", str(repo), "worktree", "prune"],
                       stdout=sys.stderr, stderr=sys.stderr, check=True)


def run_child(command, env, root, log_path):
    # Zig can consume test_results before the remaining stderr chunks. A file
    # preserves the full diagnostic (names and causes), even on failed tests.
    with open(log_path, 'wb', buffering=0) if log_path else nullcontext(None) as stderr:
        with subprocess.Popen(command, env=env, cwd=root, stderr=stderr) as child:
            try:
                return child.wait()
            finally:
                if child.poll() is None:
                    child.terminate()
                    child.wait()


def run(command, env, root, native, log_path):
    if not native:
        return run_child(command, env, root, log_path)
    fixture = Path(__file__).resolve().parents[1] / "tests/fixtures/native-http-server.py"
    spec = importlib.util.spec_from_file_location("native_fixture", fixture)
    module = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    spec.loader.exec_module(module)
    # stdout belongs exclusively to Zig's binary test-runner protocol.
    sys.stdout = sys.stderr
    orders_path = Path(__file__).resolve().with_name("ordenes_fixture.py")
    orders_spec = importlib.util.spec_from_file_location("ordenes_fixture", orders_path)
    orders = importlib.util.module_from_spec(orders_spec)
    orders_spec.loader.exec_module(orders)
    with ExitStack() as stack:
        server = stack.enter_context(module.ThreadingHTTPServer(("127.0.0.1", 0), module.FixtureHandler))
        server.daemon_threads = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        stack.callback(thread.join)
        stack.callback(server.shutdown)
        url = f"http://127.0.0.1:{server.server_port}"
        env["DEVAGENTS_NATIVE_TEST_URL"] = url
        print(f"NATIVE_FIXTURE_START={url}", flush=True)
        orders_server = stack.enter_context(orders.http.server.ThreadingHTTPServer(("127.0.0.1", 0), orders.Handler))
        orders_server.daemon_threads = True
        orders_thread = threading.Thread(target=orders_server.serve_forever, daemon=True)
        orders_thread.start()
        stack.callback(orders_thread.join)
        stack.callback(orders_server.shutdown)
        orders_url = f"http://127.0.0.1:{orders_server.server_port}"
        env["DEVAGENTS_ORDENES_TEST_URL"] = orders_url
        print(f"ORDENES_FIXTURE_START={orders_url}", flush=True)
        try:
            return run_child(command, env, root, log_path)
        finally:
            stack.close()
            print(f"ORDENES_FIXTURE_STOP={orders_url}", flush=True)
            print(f"NATIVE_FIXTURE_STOP={url}", flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
