"""Export a public source distribution and report blocking findings."""
import hashlib
import io
import posixpath
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tarfile
from urllib.parse import unquote, urlsplit

HERE = Path(__file__).resolve().parent
EVIDENCE_ROOT = 'evolving/evidencia/'
EVIDENCE_DOCS = ('README.md', 'README.en.md', 'README.es.md', 'docs/USER-GUIDE.md')
DENIED_DIRS = (
    '.git', 'node_modules', 'dist', 'zig-out', '.zig-cache', 'devagents-workspace',
)
DENIED_FILES = ('*.db', '*.db-*', '*.sqlite', '*.sqlite3', '*.status')
TARGET = r'<[^>\n]+>|(?:[^\s()]+|\([^()\n]*\))+'
INLINE = re.compile(
    rf'(?P<label>!?\[(?:[^\[\]\n]|\[[^\]\n]*\])*\])\(\s*(?P<target>{TARGET})'
    r'(?:[ \t]+(?:"[^"\n]*"|\x27[^\x27\n]*\x27|\([^()\n]*\)))?\s*\)'
)
FILE_LINE = re.compile(r'(?P<path>[^:#]+\.md):(?P<first>[0-9]+)(?:-(?P<last>[0-9]+))?')
REFERENCE = re.compile(rf'^ {{0,3}}\[[^\]\n]+\]:[ \t]*(?P<target>{TARGET})', re.M)
HTML_LINK = re.compile(
    r'<(?:a|img|source|video)\b[^>]*?\b(?:href|src|poster)\s*=\s*'
    r'(?P<quote>["\x27])(?P<target>.*?)(?P=quote)', re.I
)
CODE = re.compile(
    r'^ {0,3}(?P<fence>`{3,}|~{3,})[^\n]*\n[\s\S]*?(?:^ {0,3}(?P=fence)[`~]*[ \t]*$|\Z)'
    r'|<!--.*?-->|(?<!`)(?P<inline>`+)[^`\n]+(?P=inline)(?!`)', re.M | re.S
)
INTERNAL = re.compile(
    r'\b(?:Zenda|dueñ[oa]s?|orquestador(?:a|es|as)?|Beats|Fable|Opus|Sol\s+6(?:\.\d+)?|'
    r'Luna|Astra|Terra|DeepSeek|Sonnet)\b|\bC:[\\/]+Users[\\/]+|'
    r'\b(?:CK-[A-Z0-9-]+|E-\d+)\b|\b(?:evolving|maestro|archivo)[/\\]+(?=[\w.-]+)|'
    r'\b(?:AGENTS\.md|CLAUDE\.md)\b', re.I
)
MODEL = re.compile(r'^(?:Opus|Sonnet|DeepSeek|Luna|Terra|Astra|Fable)$', re.I)
PUBLIC_NAMES = re.compile(r'\bAd Astra\b', re.I)
# Categorías aceptadas por la decisión del orquestador (encargo B4): los
# identificadores de prueba CK-/E-/T- pueden quedarse en nombres de prueba y
# en referencias a los archivos de prueba que se exportan; el cableado de
# tests de build.zig (filtros y pasos) los necesita tal cual.
TEST_TAG = re.compile(
    r'^\s*(?:pub\s+)?test\s+"|^\s*(?:await\s+)?(?:it|test|describe|step|check)\s*\(\s*[\'"`]|^\s*def\s+test_')
TEST_TAG_TERM = re.compile(r'^(?:CK-[A-Z0-9-]+|E-\d+|T-\d+)$', re.I)
PRIVATE_DOTFILE = re.compile(r'evolving/|maestro/|archivo/|\.specify/|devagents-workspace/|tests/live/|tests/regression/', re.I)
# External identifiers required for compatibility with existing tooling.
COMPATIBILITY = (
    re.compile(r'\bbeats-webui\b', re.I),
    re.compile(r'(?<![\w.])\.beats\b', re.I),
    re.compile(r'\b(?:devagents:|beats:)\w', re.I),
    re.compile(r'\bnamespace\s+beats\b|\bbeats::', re.I),
    # Identificadores persistidos o de ejecución: beats-acp-*, beats_*,
    # BEATS_*, ramas beats/… y el nombre de carpeta antiguo devagents-beats.
    re.compile(r'\bbeats[-_][\w-]*', re.I),
    re.compile(r'\bBEATS_[A-Z0-9_]+\b'),
    re.compile(r'\bbeats[/\\][\w./\\-]*', re.I),
    re.compile(r'\bdevagents-beats\b', re.I),
)
MODEL_FILES = re.compile(
    r'^(?:providers/|core/src/(?:model_router|model_catalog|external_agents|'
    r'external_agent_catalog|cli_model_catalog|cli_accounts|pricing|'
    r'[\w]+_provider)\.zig$|'
    r'shell/webui/src/(?:panes/(?:settings_memory|catalog_sessions)|bridge/core_api)\.ts$)'
)

def git(root, *args):
    return subprocess.run(['git', '-C', str(root), *args], check=True, stdout=subprocess.PIPE).stdout

def config(name):
    return [line.strip() for line in (HERE / name).read_text(encoding='utf-8-sig').splitlines()
            if line.strip() and not line.lstrip().startswith('#')]

def safe_name(name):
    parts = name.rstrip('/').split('/')
    if any(part in ('', '.', '..') or part.endswith((' ', '.')) or
           re.search(r'[<>:"\\|?*\x00-\x1f]', part) or
           re.fullmatch(r'(?:CON|PRN|AUX|NUL|(?:COM|LPT)[1-9¹²³])(?:\..*)?', part, re.I)
           for part in parts):
        raise ValueError(f'Ruta no apta para el árbol público: {name}')
    return PurePosixPath(*parts)

def archive(root, tree, paths):
    data = git(root, 'archive', '--format=tar', tree, '--', *paths)
    return tarfile.open(fileobj=io.BytesIO(data), mode='r:')

def write_public(root, tree, output):
    rules = config('publico-incluir.txt')
    included = [line for line in rules if not line.startswith('!')]
    excluded = [line[1:] for line in rules if line.startswith('!')]
    for rule in included + excluded:
        safe_name(rule)
    exclusions = [f':(exclude,literal){path.rstrip("/")}' for path in excluded]
    exclusions += [f':(exclude,glob,icase)**/{directory}/**' for directory in DENIED_DIRS]
    exclusions += [f':(exclude,glob,icase)**/{name}' for name in DENIED_FILES]
    paths = [f':(literal){path.rstrip("/")}' for path in included]
    # Git archive rejects absent pathspecs. An older revision can omit some entries.
    tree_paths = set(git(root, 'ls-tree', '-r', '-t', '--name-only', '-z', tree)
                     .decode('utf-8').rstrip('\0').split('\0'))
    paths = [path for path in paths if path.removeprefix(':(literal)') in tree_paths]
    if not paths:
        raise ValueError('La lista blanca no coincide con ningún archivo del árbol.')
    seen = set()
    with archive(root, tree, [*paths, *exclusions]) as source:
        for member in source:
            path = safe_name(member.name)
            if member.isdir():
                continue
            if not member.isfile() or path.as_posix().casefold() in seen:
                raise ValueError(f'Entrada no regular o duplicada: {path}')
            seen.add(path.as_posix().casefold())
            destination = output / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(source.extractfile(member).read())
            if member.mode & 0o111:
                destination.chmod(0o755)

def blank_code(text, *, inline=True):
    def blank(match):
        if match.group('inline') and not inline:
            return match[0]
        return re.sub(r'[^\n]', ' ', match[0])
    return CODE.sub(blank, text)

def evidence_refs(output):
    for doc in EVIDENCE_DOCS:
        file = output / doc
        if file.is_file():
            text = file.read_text(encoding='utf-8-sig')
            pattern = re.compile(r'(?<![\w/])(?:\.\./)*evolving/evidencia/([^\s)>\]`#]+)')
            yield file, text, set(pattern.findall(blank_code(text, inline=False)))

def copy_evidence(root, tree, output):
    approvals = {}
    for line in config('publico-evidencia.txt'):
        path, digest, selection = line.split('|')
        safe_name(path)
        approvals[path] = (digest, selection)
    docs = list(evidence_refs(output))
    requested = set().union(*(paths for _, _, paths in docs))
    copied = set()
    for path in sorted(requested):
        if path not in approvals:
            print(f'EVIDENCE WITHHELD {path} (sin revisión)')
            continue
        try:
            with archive(root, tree, [f':(literal){EVIDENCE_ROOT}{path}']) as source:
                member = source.getmember(EVIDENCE_ROOT + path)
                if not member.isfile():
                    raise ValueError(f'La evidencia no es un archivo regular: {path}')
                data = source.extractfile(member).read()
        except subprocess.CalledProcessError:
            print(f'EVIDENCE WITHHELD {path} (ausente en el árbol)')
            continue
        expected, selection = approvals[path]
        if selection != 'image':
            text = data.decode('utf-8-sig').replace('\r\n', '\n')
            data = text.encode('utf-8')
        if hashlib.sha256(data).hexdigest() != expected:
            print(f'EVIDENCE WITHHELD {path} (cambió desde la revisión)')
            continue
        if selection != 'image':
            lines = text.split('\n')
            excerpt = []
            for span in selection.split(','):
                first, _, last = span.partition('-')
                excerpt.extend(lines[int(first)-1:int(last or first)])
            if path == 'FASE0-20261110/T2-matriz/matriz-1.log':
                excerpt = [re.sub(r'(agent:[^|]+)\|\S+', r'\1', line) for line in excerpt]
            excerpt = [line.rstrip() for line in excerpt]
            if any(INTERNAL.search(line) for line in excerpt):
                print(f'EVIDENCE WITHHELD {path} (un extracto conserva referencias internas)')
                continue
            data = ('Extracto revisado / Reviewed excerpt\n\n' + '\n'.join(excerpt) + '\n').encode()
        destination = output / 'docs/evidencia' / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        copied.add(path)
        print(f'EVIDENCE COPIED {path} ({"imagen revisada" if selection == "image" else "extracto revisado"})')
    for file, text, paths in docs:
        for path in paths & copied:
            prefix = 'docs/evidencia/' if file.parent == output else 'evidencia/'
            text = re.sub(r'(?<![\w/])(?:\.\./)*' + re.escape(EVIDENCE_ROOT + path) +
                          r'(?=$|[\s)>\]`#])', lambda _: prefix + path, text)
        file.write_text(text, encoding='utf-8')
    return requested == copied

def sanitize_private_dotfiles(output):
    # .gitignore/.gitattributes viajan en el paquete público pero solo sirven
    # al repositorio interno: las líneas que nombran carpetas privadas se
    # quitan de la copia exportada (el archivo privado no se toca).
    for name in ('.gitignore', '.gitattributes'):
        file = output / name
        if not file.is_file():
            continue
        lines = file.read_text(encoding='utf-8-sig').splitlines()
        kept = [line for line in lines if not PRIVATE_DOTFILE.search(line)]
        if len(kept) != len(lines):
            file.write_text('\n'.join(kept) + '\n', encoding='utf-8')
            print(f'DOTFILE SANITIZED {name}: {len(lines) - len(kept)} línea(s) privadas fuera')

def remove_private_doc_links(output):
    private = ('archivo/', 'evolving/', 'maestro/', '.specify/', 'docs/historia/')
    for file in sorted(output.rglob('*.md')):
        rel = file.relative_to(output).as_posix()
        text = file.read_text(encoding='utf-8-sig')
        content = blank_code(text, inline=False)
        buffer = []
        end = 0
        for match in INLINE.finditer(content):
            raw = match['target'].strip('<>')
            replacement = None
            if source_line := FILE_LINE.fullmatch(raw):
                anchor = 'L' + source_line['first']
                if source_line['last']:
                    anchor += '-L' + source_line['last']
                replacement = match['label'] + '(' + source_line['path'] + '#' + anchor + ')'
            elif not raw.startswith(('/', '#')) and not re.match(r'^[A-Za-z][A-Za-z0-9+.-]*:', raw):
                target = posixpath.normpath(posixpath.join(posixpath.dirname(rel), unquote(urlsplit(raw).path)))
                if target.startswith(private):
                    label = match['label'].lstrip('!')[1:-1]
                    replacement = label if not INTERNAL.search(label) else 'referencia histórica'
                elif rel == 'docs/MCP-INTEGRACION.md' and target == 'docs/CLI-CONFIANZA.md':
                    replacement = 'las comprobaciones de confianza descritas en esta sección'
            if replacement is not None:
                print(f'DOC LINK REWRITTEN {rel}:{text.count(chr(10), 0, match.start()) + 1}: {raw}')
                buffer.extend((text[end:match.start()], replacement))
                end = match.end()
        if end:
            file.write_text(''.join(buffer) + text[end:], encoding='utf8')

def headings(text):
    body = blank_code(text, inline=False)
    slugs = set()
    for title in re.findall(r'^ {0,3}#{1,6}\s+(.+?)\s*#*\s*$', body, re.M):
        slug = re.sub(r'[^\w -]', '', title.lower()).replace(' ', '-')
        unique = slug
        count = 0
        while unique in slugs:
            count += 1
            unique = f'{slug}-{count}'
        slugs.add(unique)
    slugs.update(re.findall(r'\b(?:id|name)=["\x27]([^"\x27]+)', text))
    return slugs

def broken_links(output):
    for file in sorted(output.rglob('*.md')):
        text = blank_code(file.read_text(encoding='utf-8-sig'))
        for pattern in (INLINE, REFERENCE, HTML_LINK):
            for match in pattern.finditer(text):
                raw = match['target'].strip('<>')
                location = f'{file.relative_to(output).as_posix()}:{text.count(chr(10), 0, match.start()) + 1}'
                if FILE_LINE.fullmatch(raw):
                    yield f'{location}: {raw}'
                    continue
                if re.match(r'^(?:[A-Za-z][A-Za-z0-9+.-]*:|//)', raw):
                    continue
                target = urlsplit(raw)
                path = unquote(target.path)
                if path.startswith('/'):
                    destination = (output / path.lstrip('/')).resolve()
                else:
                    destination = (file.parent / path).resolve() if path else file
                if not destination.is_relative_to(output) or not destination.exists() or (
                    target.fragment and destination.is_file() and destination.suffix.lower() == '.md'
                    and unquote(target.fragment) not in headings(destination.read_text(encoding='utf-8-sig'))
                    and not re.fullmatch(r'L\d+(?:-L\d+)?', target.fragment)
                ):
                    yield f'{location}: {raw}'

def token_around(line, match):
    s, e = match.span()
    i = s
    while i > 0 and (line[i - 1].isalnum() or line[i - 1] in '._/\\-'):
        i -= 1
    j = e
    while j < len(line) and (line[j].isalnum() or line[j] in '._/\\-'):
        j += 1
    return line[i:j]

def in_line_comment(line, match):
    prefix = re.sub(r'"[^"\n]*"|\x27[^\x27\n]*\x27', '', line[:match.start()])
    stripped = prefix.lstrip()
    return ('//' in prefix or '/*' in prefix or stripped.startswith('#')
            or stripped.startswith('<!--'))

CODE_FILE = re.compile(r'\.(?:zig|cpp|hpp|cc|c|h|cjs|mjs|js|ts|tsx|py|ps1|'
                       r'bat|cmd|iss|yml|yaml|json|html|css|xml|toml|cfg|ini|sh)$', re.I)

def is_compatible(file, line, match):
    start, end = match.span()
    term = match[0]
    # El código vendorizado es de terceros: un «beats» ahí es coincidencia,
    # no una referencia interna.
    if file.startswith('shell/webui/vendor/'):
        return True
    # Nombres de modelo donde el producto los soporta: identificadores de
    # proveedor en código y configuración (los textos se limpiaron antes).
    if MODEL.fullmatch(term) and CODE_FILE.search(file):
        return True
    if MODEL.fullmatch(term) and MODEL_FILES.search(file):
        return True
    if term.casefold() == 'astra' and any(m.start() <= start < end <= m.end()
                                         for m in PUBLIC_NAMES.finditer(line)):
        return True
    if term.casefold() == 'beats' and any(m.start() <= start < end <= m.end()
                                         for pattern in COMPATIBILITY for m in pattern.finditer(line)):
        return True
    # «Sol 6.x» es la edición del agente usada en catálogo y fixtures; en
    # código es identificador, no una referencia a la gobernanza interna.
    if re.fullmatch(r'(?i)sol\s+6(?:\.\d+)?', term) and CODE_FILE.search(file):
        return True
    # AGENTS.md/CLAUDE.md son nombres genéricos de convención; la UI los
    # menciona para explicar las reglas del proyecto.
    if term in ('AGENTS.md', 'CLAUDE.md') and CODE_FILE.search(file):
        return True
    # Fixture anonimizado: C:\Users\x\… es un placeholder, no una ruta real.
    if re.fullmatch(r'(?i)c:[\\/]+users[\\/]+', term) and line[end:end + 1] == 'x':
        return True
    if TEST_TAG_TERM.fullmatch(term) and not in_line_comment(line, match):
        # Nombre de prueba (test "CK-…", it('E-…'), def test_…), referencia a
        # un archivo de prueba exportado, o identificador de andamiaje de
        # tests en código (los comentarios ya se limpiaron en la fuente).
        if TEST_TAG.search(line):
            return True
        if CODE_FILE.search(file):
            return True
        token = token_around(line, match)
        if '/' in token or '\\' in token or re.search(
                r'\.(?:zig|cjs|mjs|js|ts|tsx|cpp|cc|c|h|hpp|py|ps1|bat|cmd|json|txt|md|yml|yaml|iss|html|css)$',
                token, re.I):
            return True
        # build.zig teje los tests (filtros y nombres de paso) con estos IDs.
        if file == 'build.zig':
            return True
    # Slugs de modelo tal como los devuelve el catálogo del proveedor
    # (p. ej. gpt-6-luna): token completo en minúsculas con guiones, no el
    # nombre interno suelto.
    token = token_around(line, match)
    if MODEL.fullmatch(term) and '-' in token and token == token.lower():
        return True
    return False

def scan_internal(output, files):
    clean = True
    for file in files:
        rel = file.relative_to(output).as_posix()
        if file.name in ('exportar_arbol_publico.py', 'publico-evidencia.txt') and file.parent == output / 'tools/publicar':
            continue  # Definitions of the checks and the reviewed input paths.
        data = file.read_bytes()
        try:
            if data.startswith((b'\xff\xfe', b'\xfe\xff')):
                contents = data.decode('utf-16')
            elif b'\0' not in data:
                contents = data.decode('utf-8-sig')
            else:
                continue
        except UnicodeDecodeError:
            contents = data.decode('cp1252', errors='replace')
        for number, line in enumerate(contents.splitlines(), 1):
            blocked, compatible = set(), set()
            for match in INTERNAL.finditer(line):
                group = compatible if is_compatible(rel, line, match) else blocked
                group.add(match[0])
            for label, findings in (('INTERNAL', blocked), ('COMPAT', compatible)):
                if findings:
                    print(f'{label} {rel}:{number}: {", ".join(sorted(findings))}')
            clean = clean and not blocked
    return clean

def main(root, commit, output):
    root = Path(root).resolve()
    output = Path(output).resolve()
    if output.is_relative_to(root) or output.exists():
        raise ValueError('La salida debe ser una carpeta nueva fuera del repositorio.')
    probe = output.parent
    while not probe.is_dir():
        probe = probe.parent
    parent_git = subprocess.run(['git', '-C', str(probe), 'rev-parse', '--is-inside-work-tree'],
                                capture_output=True)
    if parent_git.returncode == 0:
        raise ValueError('La salida está dentro de otro repositorio Git.')
    revision = git(root, 'rev-parse', '--verify', '--end-of-options', commit + '^{object}').decode().strip()
    tree = git(root, 'rev-parse', '--verify', revision + '^{tree}').decode().strip()
    output.mkdir(parents=True)
    print(f'Revisión: {revision}\nÁrbol: {tree}\nSalida: {output}')
    write_public(root, tree, output)
    (output / 'DEVAGENTS-REVISION').write_text(revision[:12] + '\n', encoding='ascii')
    evidence_ok = copy_evidence(root, tree, output)
    sanitize_private_dotfiles(output)
    remove_private_doc_links(output)
    links = list(broken_links(output))
    for link in links:
        print(f'BROKEN LINK {link}')
    print(f'Enlaces relativos rotos: {len(links)}')
    sys.stdout.flush()
    result = subprocess.run([
        'pwsh', '-NoProfile', '-File', str(output / 'tools/secrets_check.ps1'),
        '-Root', str(output), '-NoGitHistory',
    ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    secrets = result.stdout.decode('utf-8', errors='replace')
    # The scanner prints the matching value on a separate line. Never relay it.
    print('\n'.join(line for line in secrets.splitlines() if not line.lstrip().startswith('matched:')))
    secrets_ok = result.returncode == 0 and bool(re.search(r'(?m)^Leaks found:\s+0\s*$', secrets))
    files = sorted(file for file in output.rglob('*') if file.is_file())
    internal_ok = scan_internal(output, files)
    print(f'Archivos: {len(files)}; tamaño: {sum(file.stat().st_size for file in files)} bytes')
    ok = evidence_ok and not links and secrets_ok and internal_ok
    print(f'Exportación {"validada" if ok else "bloqueada"}')
    return 0 if ok else 1

if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    try:
        sys.exit(main(*sys.argv[1:]))
    except (OSError, subprocess.CalledProcessError, ValueError, tarfile.TarError) as error:
        print(f'Error de exportación: {error}', file=sys.stderr)
        sys.exit(1)
