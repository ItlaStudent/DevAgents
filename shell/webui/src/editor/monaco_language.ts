/** Monaco language IDs, independent of the smaller textarea fallback tokenizer. */
const languagesByExtension: Record<string, string> = {
  html: 'html', htm: 'html', css: 'css', js: 'javascript', jsx: 'javascript', mjs: 'javascript', cjs: 'javascript',
  ts: 'typescript', tsx: 'typescript', json: 'json', md: 'markdown', markdown: 'markdown', py: 'python', zig: 'zig',
  c: 'c', h: 'c', cpp: 'cpp', cc: 'cpp', cxx: 'cpp', hpp: 'cpp', hh: 'cpp', hxx: 'cpp',
  rs: 'rust', go: 'go', java: 'java', sh: 'shell', bash: 'shell', zsh: 'shell', ps1: 'powershell', psm1: 'powershell',
  yaml: 'yaml', yml: 'yaml', toml: 'toml', sql: 'sql', xml: 'xml', svg: 'xml',
};

export function monacoLanguageFor(path: string): string {
  const name = path.split(/[\\/]/).pop() ?? '';
  const dot = name.lastIndexOf('.');
  const extension = dot < 0 ? '' : name.slice(dot + 1).toLowerCase();
  return Object.prototype.hasOwnProperty.call(languagesByExtension, extension) ? languagesByExtension[extension] : 'plaintext';
}

/** Only grammars absent from the pinned offline Monaco build belong here. */
export function registerProjectLanguages(m: any): void {
  const registered = new Set(m.languages.getLanguages().map((language: any) => language.id));
  if (!registered.has('zig')) {
    m.languages.register({ id: 'zig', extensions: ['.zig'], aliases: ['Zig'] });
    m.languages.setMonarchTokensProvider('zig', {
      keywords: 'const var fn pub return if else while for switch struct enum union error try catch defer errdefer comptime inline export extern test and or orelse unreachable null true false usingnamespace anytype align break continue async await suspend resume nosuspend noinline opaque packed threadlocal allowzero volatile linksection callconv'.split(' '),
      types: 'bool void noreturn type anyerror anyopaque usize isize comptime_int comptime_float f16 f32 f64 f80 f128 c_char c_short c_ushort c_int c_uint c_long c_ulong c_longlong c_ulonglong c_longdouble'.split(' '),
      tokenizer: {
        root: [
          [/\/\/.*$/, 'comment'],
          [/\\\\.*$/, 'string'],
          [/"([^"\\]|\\.)*"/, 'string'],
          [/'([^'\\]|\\.)'/, 'string'],
          [/\b0[xX][\da-fA-F_]+\b|\b0[bB][01_]+\b|\b0[oO][0-7_]+\b|\b\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?[\d_]+)?\b/, 'number'],
          [/\b[ui]\d+\b/, 'type'],
          [/@[A-Za-z_][\w]*/, 'function'],
          [/\b[A-Za-z_][\w]*(?=\s*\()/, { cases: { '@keywords': 'keyword', '@default': 'function' } }],
          [/\b[A-Za-z_][\w]*\b/, { cases: { '@keywords': 'keyword', '@types': 'type', '@default': 'identifier' } }],
        ],
      },
    });
  }
  if (!registered.has('toml')) {
    m.languages.register({ id: 'toml', extensions: ['.toml'], aliases: ['TOML'] });
    m.languages.setMonarchTokensProvider('toml', {
      tokenizer: {
        root: [
          [/#.*$/, 'comment'],
          [/"""/, 'string', '@multilineBasic'],
          [/'''/, 'string', '@multilineLiteral'],
          [/"([^"\\]|\\.)*"|'[^']*'/, 'string'],
          [/\b(true|false)\b/, 'keyword'],
          [/[+-]?(?:\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?[\d_]+)?|inf|nan)\b/, 'number'],
          [/^\s*\[\[?[^\]]+\]\]?/, 'type'],
          [/[\w.-]+(?=\s*=)/, 'key'],
        ],
        multilineBasic: [[/"""/, 'string', '@pop'], [/\\./, 'string.escape'], [/./, 'string']],
        multilineLiteral: [[/'''/, 'string', '@pop'], [/./, 'string']],
      },
    });
  }
}
