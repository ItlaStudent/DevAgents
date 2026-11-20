const std = @import("std");

/// Errores de validación de contratos (T-F1-09, ARCHITECTURE §3).
pub const ContractError = error{
    /// La pieza no aporta un campo requerido por el contrato.
    MissingRequiredField,
    /// El tipo del campo aportado no coincide con el del contrato.
    TypeMismatch,
    /// Dos o más piezas aportan el mismo campo del contrato.
    ConflictDetected,
    OutOfMemory,
};

/// Tipo declarado de un campo de la interfaz de un contrato.
pub const FieldType = enum {
    string,
    integer,
    boolean,
    /// Acepta cualquier tipo (campo libre).
    any,
};

/// Un campo de la interfaz que el productor debe entregar.
pub const Field = struct {
    name: []const u8,
    field_type: FieldType,
    required: bool,
};

/// Un campo realmente entregado por un worker (la "pieza" producida).
pub const ProducedField = struct {
    name: []const u8,
    field_type: FieldType,
};

/// Un contrato de integración: define la interfaz (campos) que una pieza debe cumplir
/// ANTES de ensamblarla con las demás. El ensamblador rechaza piezas no conformes.
pub const Contract = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    fields: []Field,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, fields: []const Field) !Contract {
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const fields_copy = try allocator.alloc(Field, fields.len);
        errdefer allocator.free(fields_copy);
        for (fields, 0..) |f, i| {
            fields_copy[i] = .{
                .name = try allocator.dupe(u8, f.name),
                .field_type = f.field_type,
                .required = f.required,
            };
        }
        return .{ .allocator = allocator, .name = name_copy, .fields = fields_copy };
    }

    pub fn deinit(self: *Contract) void {
        for (self.fields) |f| self.allocator.free(f.name);
        self.allocator.free(self.fields);
        self.allocator.free(self.name);
    }

    /// Valida que una pieza producida cumpla el contrato.
    /// - Todo campo `required` debe estar presente.
    /// - El tipo debe coincidir (salvo que el contrato lo declare `any`).
    pub fn validate(self: *const Contract, piece: []const ProducedField) ContractError!void {
        for (self.fields) |spec| {
            const provided = findField(piece, spec.name);
            if (provided == null) {
                if (spec.required) return error.MissingRequiredField;
                continue;
            }
            if (spec.field_type != .any and provided.?.field_type != spec.field_type) {
                return error.TypeMismatch;
            }
        }
    }
};

fn findField(piece: []const ProducedField, name: []const u8) ?ProducedField {
    for (piece) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

fn findSpec(contract: *const Contract, name: []const u8) ?Field {
    for (contract.fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

/// Información de un conflicto detectado durante el ensamblado de múltiples piezas.
pub const ConflictInfo = struct {
    field_name: []const u8,
    /// Índices de las piezas que aportan el mismo campo (al menos 2).
    piece_indices: []usize,

    pub fn deinit(self: *const ConflictInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.field_name);
        allocator.free(self.piece_indices);
    }
};

/// Ensamblador: solo integra piezas que cumplen su contrato.
/// Devuelve error en la primera pieza no conforme (fail-fast), de modo que
/// ningún resultado parcial inválido entra en la integración.
pub const Assembler = struct {
    pub fn assemble(contract: *const Contract, piece: []const ProducedField) ContractError!void {
        try contract.validate(piece);
    }

    /// Ensambla múltiples piezas validando cada una contra el contrato Y
    /// detectando conflictos: si dos piezas aportan el mismo campo, se reporta
    /// como `ConflictDetected` (no silencioso). Devuelve la lista de conflictos
    /// si los hay, o array vacío si el ensamblado es limpio.
    pub fn assembleMulti(allocator: std.mem.Allocator, contract: *const Contract, pieces: []const []const ProducedField) ContractError![]ConflictInfo {
        var conflicts = std.ArrayList(ConflictInfo).empty;
        errdefer {
            for (conflicts.items) |*c| c.deinit(allocator);
            conflicts.deinit(allocator);
        }

        // Validar que cada pieza individual tiene tipos correctos (sin exigir completitud).
        for (pieces) |piece| {
            for (piece) |pf| {
                const spec = findSpec(contract, pf.name);
                if (spec != null and spec.?.field_type != .any and pf.field_type != spec.?.field_type) {
                    return error.TypeMismatch;
                }
            }
        }

        // Validar completitud: la UNION de todas las piezas debe cubrir los campos required.
        for (contract.fields) |field| {
            if (field.required) {
                var covered = false;
                for (pieces) |piece| {
                    if (findField(piece, field.name) != null) {
                        covered = true;
                        break;
                    }
                }
                if (!covered) return error.MissingRequiredField;
            }
        }

        // Detectar conflictos: mismo campo aportado por ≥2 piezas.
        for (contract.fields) |field| {
            var contributors = std.ArrayList(usize).empty;
            defer contributors.deinit(allocator);

            for (pieces, 0..) |piece, idx| {
                if (findField(piece, field.name) != null) {
                    try contributors.append(allocator, idx);
                }
            }

            if (contributors.items.len >= 2) {
                try conflicts.append(allocator, .{
                    .field_name = try allocator.dupe(u8, field.name),
                    .piece_indices = try contributors.toOwnedSlice(allocator),
                });
            }
        }

        if (conflicts.items.len > 0) {
            const result = try conflicts.toOwnedSlice(allocator);
            return result;
        }

        return try allocator.alloc(ConflictInfo, 0);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "contract accepts conforming piece" {
    var contract = try Contract.init(std.testing.allocator, "code-module", &.{
        .{ .name = "result", .field_type = .string, .required = true },
        .{ .name = "exit_code", .field_type = .integer, .required = true },
    });
    defer contract.deinit();

    try contract.validate(&.{
        .{ .name = "result", .field_type = .string },
        .{ .name = "exit_code", .field_type = .integer },
    });
}

test "contract rejects missing required field" {
    var contract = try Contract.init(std.testing.allocator, "code-module", &.{
        .{ .name = "result", .field_type = .string, .required = true },
        .{ .name = "exit_code", .field_type = .integer, .required = true },
    });
    defer contract.deinit();

    try std.testing.expectError(error.MissingRequiredField, contract.validate(&.{
        .{ .name = "result", .field_type = .string },
    }));
}

test "contract rejects type mismatch" {
    var contract = try Contract.init(std.testing.allocator, "code-module", &.{
        .{ .name = "exit_code", .field_type = .integer, .required = true },
    });
    defer contract.deinit();

    try std.testing.expectError(error.TypeMismatch, contract.validate(&.{
        .{ .name = "exit_code", .field_type = .string },
    }));
}

test "contract allows optional field absent and any type" {
    var contract = try Contract.init(std.testing.allocator, "flexible", &.{
        .{ .name = "result", .field_type = .string, .required = true },
        .{ .name = "warnings", .field_type = .string, .required = false },
        .{ .name = "meta", .field_type = .any, .required = true },
    });
    defer contract.deinit();

    try contract.validate(&.{
        .{ .name = "result", .field_type = .string },
        .{ .name = "meta", .field_type = .boolean },
    });
}

test "assembler rejects non-conforming piece" {
    var contract = try Contract.init(std.testing.allocator, "code-module", &.{
        .{ .name = "result", .field_type = .string, .required = true },
    });
    defer contract.deinit();

    try std.testing.expectError(error.MissingRequiredField, Assembler.assemble(&contract, &.{
        .{ .name = "other", .field_type = .string },
    }));
    // Pieza válida sí se integra.
    try Assembler.assemble(&contract, &.{.{ .name = "result", .field_type = .string }});
}

test "assembleMulti detects conflict: two pieces contribute same field" {
    const allocator = std.testing.allocator;
    var contract = try Contract.init(allocator, "module", &.{
        .{ .name = "source", .field_type = .string, .required = true },
        .{ .name = "tests", .field_type = .string, .required = true },
    });
    defer contract.deinit();

    const piece_a: [2]ProducedField = .{
        .{ .name = "source", .field_type = .string },
        .{ .name = "tests", .field_type = .string },
    };
    const piece_b: [1]ProducedField = .{
        .{ .name = "source", .field_type = .string },
    };
    const pieces = [_][]const ProducedField{ &piece_a, &piece_b };

    const conflicts = try Assembler.assembleMulti(allocator, &contract, &pieces);
    defer {
        for (conflicts) |*c| c.deinit(allocator);
        allocator.free(conflicts);
    }

    try std.testing.expectEqual(@as(usize, 1), conflicts.len);
    try std.testing.expectEqualStrings("source", conflicts[0].field_name);
    try std.testing.expectEqual(@as(usize, 2), conflicts[0].piece_indices.len);
}

test "assembleMulti passes with clean assembly (no conflicts)" {
    const allocator = std.testing.allocator;
    var contract = try Contract.init(allocator, "module", &.{
        .{ .name = "source", .field_type = .string, .required = true },
        .{ .name = "tests", .field_type = .string, .required = true },
    });
    defer contract.deinit();

    const piece_a: [1]ProducedField = .{
        .{ .name = "source", .field_type = .string },
    };
    const piece_b: [1]ProducedField = .{
        .{ .name = "tests", .field_type = .string },
    };
    const pieces = [_][]const ProducedField{ &piece_a, &piece_b };

    const conflicts = try Assembler.assembleMulti(allocator, &contract, &pieces);
    defer {
        for (conflicts) |*c| c.deinit(allocator);
        allocator.free(conflicts);
    }

    try std.testing.expectEqual(@as(usize, 0), conflicts.len);
}
