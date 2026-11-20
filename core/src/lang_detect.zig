//! Detección determinista y barata del idioma de un texto (español frente a
//! inglés). Sin red, sin modelos ni dependencias: cuenta palabras funcionales
//! frecuentes y señales fuertes del español (ñ, ¿, ¡) más acentos. Cuando no
//! hay evidencia suficiente devuelve `.unknown` y el llamador NO impone nada.
//!
//! Alcance deliberadamente corto: el motor de DevAgents necesita distinguir el
//! idioma de la ORDEN del idioma del ENTREGABLE de prosa, no etiquetar textos
//! arbitrarios. Por eso las listas sólo incluyen formas inequívocas (se han
//! excluido los tokens ambiguos entre ambos idiomas: "no", "a", "e", "o", "y",
//! "i"…): un falso positivo impondría un idioma equivocado.
const std = @import("std");

pub const Lang = enum { unknown, es, en };

/// Nombre legible del idioma para mensajes y prompts.
pub fn name(lang: Lang) []const u8 {
    return switch (lang) {
        .es => "español",
        .en => "inglés",
        .unknown => "desconocido",
    };
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c >= 0x80;
}

pub const WordIterator = struct {
    text: []const u8,
    i: usize = 0,

    pub fn next(self: *WordIterator) ?[]const u8 {
        while (self.i < self.text.len and !isWordByte(self.text[self.i])) self.i += 1;
        if (self.i >= self.text.len) return null;
        const start = self.i;
        while (self.i < self.text.len and isWordByte(self.text[self.i])) self.i += 1;
        return self.text[start..self.i];
    }
};

/// Itera las palabras (secuencias de letras ASCII o bytes UTF-8 >= 0x80).
pub fn words(text: []const u8) WordIterator {
    return .{ .text = text };
}

fn inSet(word: []const u8, set: []const []const u8) bool {
    for (set) |w| {
        if (std.ascii.eqlIgnoreCase(word, w)) return true;
    }
    return false;
}

/// Palabras funcionales inequívocas del español (sin las compartidas con el
/// inglés). Las acentuadas van literales en UTF-8.
const ES_WORDS = [_][]const u8{
    "de",      "la",    "el",     "los",      "las",    "un",    "una",     "unos",  "unas",
    "del",     "al",    "ante",   "con",      "contra", "desde", "durante", "entre", "hacia",
    "hasta",   "para",  "por",
    "según",
    "sin",     "sobre", "tras",   "que",      "pero",   "en",    "porque",  "como",  "cuando",
    "donde",   "si",    "aunque", "mientras", "pues",   "es",    "son",
    "está",
    "están",
    "sea",     "ser",   "hay",    "ha",       "han",    "tiene", "tienen",  "puede", "pueden",
    "debe",    "deben", "fue",    "era",      "se",     "su",    "sus",     "le",    "les",
    "nos",     "este",  "esta",   "estos",    "estas",  "ese",   "esa",     "esos",  "esas",
    "aquel",
    "él",
    "ella",    "ellos", "ellas",
    "más",
    "muy",
    "también",
    "ya",      "todo",  "toda",   "todos",    "todas",  "cada",  "solo",
    "cuál",
    "cuáles",
    "qué",
    "quién",
    "quienes",
    "dónde",
    "cómo",
};

/// Palabras funcionales inequívocas del inglés.
const EN_WORDS = [_][]const u8{
    "the",   "of",    "and",    "to",     "in",      "is",     "are",   "was",     "were",
    "for",   "with",  "that",   "this",   "these",   "those",  "on",    "as",      "at",
    "be",    "been",  "being",  "by",     "or",      "from",   "it",    "its",     "an",
    "not",   "can",   "could",  "should", "must",    "when",   "where", "which",   "while",
    "they",  "their", "them",   "have",   "has",     "had",    "will",  "would",   "you",
    "your",  "we",    "our",    "his",    "her",     "he",     "she",   "do",      "does",
    "did",   "but",   "if",     "so",     "than",    "then",   "there", "here",    "into",
    "over",  "after", "before", "also",   "more",    "most",   "only",  "such",    "some",
    "any",   "all",   "each",   "both",   "through", "during", "about", "because", "between",
    "under", "above", "again",  "just",   "very",    "out",    "off",   "up",      "down",
};

/// Señal fuerte del español: ñ/Ñ o los signos de apertura ¿/¡. Vale más que un
/// simple acierto de palabra porque es inequívoca.
fn hasStrongSpanishMark(text: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < text.len) : (i += 1) {
        const c0 = text[i];
        const c1 = text[i + 1];
        if (c0 == 0xC3 and (c1 == 0xB1 or c1 == 0x91)) return true; // ñ / Ñ
        if (c0 == 0xC2 and (c1 == 0xBF or c1 == 0xA1)) return true; // ¿ / ¡
    }
    return false;
}

/// Acento vocálico del español (á é í ó ú ü y mayúsculas). Suma 1; por sí solo
/// no basta para concluir, pero ayuda a superar el umbral.
fn hasWeakSpanishMark(text: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < text.len) : (i += 1) {
        const c0 = text[i];
        const c1 = text[i + 1];
        if (c0 != 0xC3) continue;
        switch (c1) {
            0xA1,
            0xA9,
            0xAD,
            0xB3,
            0xBA,
            0xBC, // á é í ó ú ü
            0x81,
            0x89,
            0x8D,
            0x93,
            0x9A,
            0x9C, // Á É Í Ó Ú Ü
            => return true,
            else => {},
        }
    }
    return false;
}

/// Mayúscula inicial ASCII o latina en UTF-8 (À-Þ: Ñ, Á, É…), para no tomar
/// «Ñandú» por una palabra española corriente (el segundo auditor, r3).
fn startsUpper(w: []const u8) bool {
    if (std.ascii.isUpper(w[0])) return true;
    return w.len >= 2 and w[0] == 0xC3 and w[1] >= 0x80 and w[1] <= 0x9E and w[1] != 0x97;
}

/// Señales del español fuera de nombres propios: ¿/¡ cuentan siempre; ñ y los
/// acentos solo en palabras que no son un nombre propio (mayúscula inicial
/// fuera de la primera palabra). «Summarize El Niño» no es una orden española
/// (el segundo auditor, r2); «Información sobre claves» sí conserva su acento.
fn spanishMarks(text: []const u8) struct { strong: bool, weak: bool } {
    var strong = false;
    var weak = false;
    var i: usize = 0;
    while (i + 1 < text.len) : (i += 1) {
        if (text[i] == 0xC2 and (text[i + 1] == 0xBF or text[i + 1] == 0xA1)) strong = true; // ¿ / ¡
    }
    var it = words(text);
    var first = true;
    while (it.next()) |w| {
        const proper = !first and startsUpper(w);
        first = false;
        if (proper) continue;
        if (hasStrongSpanishMark(w)) strong = true else if (hasWeakSpanishMark(w)) weak = true;
    }
    return .{ .strong = strong, .weak = weak };
}

/// Detecta el idioma. `.unknown` cuando no hay evidencia concluyente: textos
/// muy cortos, una sola señal ambigua o una mezcla equilibrada.
pub fn detect(text: []const u8) Lang {
    var es: i32 = 0;
    var en: i32 = 0;
    const marks = spanishMarks(text);
    const strong = marks.strong;
    const weak = !strong and marks.weak;
    if (strong) es += 2 else if (weak) es += 1;

    var it = words(text);
    while (it.next()) |w| {
        if (inSet(w, &ES_WORDS)) es += 1;
        if (inSet(w, &EN_WORDS)) en += 1;
    }

    // Concluyente solo con tres señales y el doble que el otro idioma: un título
    // o una lista española con dos palabras inglesas («The API and OAuth:
    // claves de seguridad») no basta para declarar inglés (el segundo auditor,).
    if (es >= 3 and es >= 2 * en) return .es;
    if (en >= 3 and en >= 2 * es) return .en;
    // Un acento español casi nunca aparece en inglés: con él bastan dos señales.
    if (weak and es >= 2 and es >= 2 * en) return .es;
    // Con señal fuerte (ñ/¿/¡) una única palabra funcional ya decanta.
    if (strong and es >= 1 and es > en) return .es;
    return .unknown;
}

// ── Tests ────────────────────────────────────────────────────────────────

test "LANG-DETECT español concluyente (orden del selftest #851)" {
    try std.testing.expectEqual(Lang.es, detect("Documenta brevemente en un texto los riesgos de guardar claves de API en texto plano"));
    try std.testing.expectEqual(Lang.es, detect("Resume el informe y explica los riesgos para el usuario"));
    try std.testing.expectEqual(Lang.es, detect("¿Cuáles son los riesgos? La clave está expuesta en el repositorio"));
}

test "LANG-DETECT inglés concluyente" {
    try std.testing.expectEqual(Lang.en, detect("Document the risks of storing API keys in plain text"));
    try std.testing.expectEqual(Lang.en, detect("This is an explanation of the risks of exposing the key in the repository"));
    try std.testing.expectEqual(Lang.en, detect("Write a summary of the findings and the plan for the team"));
}

test "LANG-DETECT mezcla breve con términos técnicos ingleses no concluye inglés" {
    try std.testing.expectEqual(Lang.unknown, detect("The API and OAuth: claves de seguridad"));
    try std.testing.expect(detect("Guía de la API: the client and the server") != .en);
}

test "LANG-DETECT desconocido en textos cortos o sin función gramatical" {
    try std.testing.expectEqual(Lang.unknown, detect(""));
    try std.testing.expectEqual(Lang.unknown, detect("hola"));
    try std.testing.expectEqual(Lang.unknown, detect("Hello world"));
    try std.testing.expectEqual(Lang.unknown, detect("print(42)"));
    try std.testing.expectEqual(Lang.unknown, detect("UNO"));
    try std.testing.expectEqual(Lang.unknown, detect("API keys"));
    try std.testing.expectEqual(Lang.unknown, detect("{\"document\":true}"));
}

test "LANG-DETECT mezcla equilibrada no concluye" {
    try std.testing.expectEqual(Lang.unknown, detect("The API risks la seguridad clave"));
}

test "LANG-DETECT una ñ en un nombre propio no decanta español" {
    try std.testing.expect(detect("Summarize El Niño") != .es);
    try std.testing.expect(detect("Write about the city of Logroño and its history") != .es);
    try std.testing.expect(detect("Summarize Ñandú") != .es);
}

test "LANG-DETECT señales fuertes y acentos del español" {
    try std.testing.expectEqual(Lang.es, detect("¿Qué es esto?"));
    try std.testing.expectEqual(Lang.es, detect("Información sobre claves"));
}

test "LANG-DETECT el inglés no lo decanta una palabra aislada" {
    try std.testing.expectEqual(Lang.unknown, detect("the"));
    try std.testing.expectEqual(Lang.unknown, detect("please"));
}
