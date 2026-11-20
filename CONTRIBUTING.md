# Contribuir a DevAgents

[Español](#español) · [English](#english)

## Español

Gracias por querer mejorar DevAgents. Cualquier aportación cuenta: un aviso de fallo, una idea, una traducción, documentación o código.

### Antes de empezar

- **Fallos e ideas**: abre una incidencia describiendo qué hiciste, qué esperabas y qué pasó (con la versión de la barra de estado y, si puedes, una captura). Los fallos de seguridad **no** van en incidencias públicas: sigue [SECURITY.md](SECURITY.md).
- **Cambios grandes**: abre primero una incidencia para hablarlo; así nadie trabaja en algo que no encaja.

### Preparar el entorno

1. Windows 10/11 de 64 bits, **Zig 0.16.0**, Node.js y PowerShell 7 (`pwsh`). `DevAgents.bat` instala Zig dentro del repositorio si falta y, si falta Node, ofrece instalarlo con `winget`.
2. Instala los hooks del repositorio: `pwsh tools/install-hooks.ps1`.
3. Compila con `zig build` y corre la suite con `zig build test --summary all`.

### Reglas del código

- Los estándares están en [`docs/CODING-STANDARDS.md`](docs/CODING-STANDARDS.md). Lo esencial: todo error se maneja o se propaga, asignadores inyectados, cada función pública con prueba y sin fugas (`std.testing.allocator`).
- Una corrección de fallo llega con la prueba que lo reproduce y que falla sin el arreglo.
- Formato automático: `zig fmt` para Zig y `clang-format` para C/C++.
- Ninguna clave ni dato personal en el código, las pruebas o la documentación. El hook de commit ejecuta `tools/secrets_check.ps1` y bloquea el commit si encuentra una.
- No saltes los hooks (`--no-verify`) ni reescribas ramas compartidas (`push --force`).

### Enviar el cambio

1. Crea una rama desde `main`.
2. Commits pequeños y con un mensaje que diga qué cambia y por qué.
3. Abre la *pull request* explicando el cambio y cómo lo probaste (pruebas y, si toca la interfaz, una captura).

### Licencia de las contribuciones

DevAgents se publica bajo la [Licencia Apache 2.0](LICENSE). Toda contribución que envíes se acepta bajo esa misma licencia, como establece su sección 5, sin acuerdo de cesión aparte. Conservas los derechos de autor de lo que escribes. Si tu cambio incluye código de terceros, indícalo en la *pull request* con su licencia y su origen: solo se acepta código con licencia compatible con Apache-2.0, y su aviso se añade a [NOTICE](NOTICE).

### Firma del origen (DCO)

Cada commit debe llevar la firma del *Developer Certificate of Origin* 1.1: con ella declaras que tienes derecho a enviar ese código bajo la licencia del proyecto. No hay que firmar ningún documento aparte.

Para firmar, haz el commit con `-s`:

```bash
git commit -s -m "Explica qué cambia y por qué"
```

Git añade al final del mensaje una línea con el nombre y el correo de tu configuración (`user.name` y `user.email`):

```
Signed-off-by: Tu Nombre <tu-correo@example.com>
```

Usa tu nombre real o el nombre con el que te identificas públicamente; el correo puede ser el anónimo que da GitHub (`…@users.noreply.github.com`). Si olvidaste firmar, `git commit --amend -s` arregla el último commit y `git rebase --signoff main` los de tu rama. Una *pull request* con commits sin firmar no se fusiona.

Texto oficial del certificado (de <https://developercertificate.org>; se reproduce en inglés porque no se permite modificarlo):

```
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.


Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```

En resumen: (a) lo escribiste tú y puedes enviarlo con la licencia del proyecto; o (b) se basa en trabajo ajeno con una licencia libre adecuada que te permite enviarlo modificado con esa licencia; o (c) te lo dio alguien que certificó (a), (b) o (c) y no lo cambiaste; y (d) aceptas que la contribución y tu firma quedan registradas en público de forma permanente. El texto que vale es el inglés.

### Nombre y marca

El nombre «DevAgents», el de «Ad el auditor» y sus logotipos no se conceden con la licencia: ver [TRADEMARKS.md](TRADEMARKS.md). Un fork es bienvenido con otro nombre.

### Convivencia

Toda participación se rige por el [Código de conducta](CODE_OF_CONDUCT.md).

---

## English

Thanks for wanting to improve DevAgents. Every contribution counts: a bug report, an idea, a translation, documentation or code.

### Before you start

- **Bugs and ideas**: open an issue describing what you did, what you expected and what happened (include the version shown in the status bar and, if possible, a screenshot). Security issues do **not** go in public issues: follow [SECURITY.md](SECURITY.md).
- **Large changes**: open an issue first to discuss them, so nobody works on something that does not fit.

### Set up

1. Windows 10/11 64-bit, **Zig 0.16.0**, Node.js and PowerShell 7 (`pwsh`). `DevAgents.bat` installs Zig inside the repository if missing and, if Node is missing, offers to install it with `winget`.
2. Install the repository hooks: `pwsh tools/install-hooks.ps1`.
3. Build with `zig build` and run the suite with `zig build test --summary all`.

### Code rules

- Standards live in [`docs/CODING-STANDARDS.md`](docs/CODING-STANDARDS.md) (in Spanish). In short: every error is handled or propagated, allocators are injected, every public function has a test and tests are leak-free (`std.testing.allocator`).
- A bug fix comes with the test that reproduces it and fails without the fix.
- Automatic formatting: `zig fmt` for Zig and `clang-format` for C/C++.
- No keys or personal data in code, tests or docs. The commit hook runs `tools/secrets_check.ps1` and blocks the commit if it finds one.
- Do not skip hooks (`--no-verify`) or rewrite shared branches (`push --force`).

### Sending the change

1. Branch off `main`.
2. Small commits whose message says what changes and why.
3. Open the pull request explaining the change and how you tested it (tests and, for UI changes, a screenshot).

### License of contributions

DevAgents is released under the [Apache License 2.0](LICENSE). Every contribution you submit is accepted under that same license, as section 5 of the license states, with no separate assignment. You keep the copyright of what you write. If your change includes third-party code, say so in the pull request with its license and origin: only Apache-2.0-compatible code is accepted, and its notice is added to [NOTICE](NOTICE).

### Sign-off (DCO)

Every commit must carry a *Developer Certificate of Origin* 1.1 sign-off (full text in the Spanish section above, from <https://developercertificate.org>). Commit with `-s`:

```bash
git commit -s -m "Explain what changes and why"
```

Git appends `Signed-off-by: Your Name <your-email@example.com>` from your `user.name` and `user.email`; GitHub's `…@users.noreply.github.com` address is fine. Forgot? `git commit --amend -s` fixes the last commit and `git rebase --signoff main` fixes your branch. Pull requests with unsigned commits are not merged.

### Name and trademark

The names "DevAgents" and "Ad el auditor" and their logos are not granted by the license: see [TRADEMARKS.md](TRADEMARKS.md). Forks are welcome under a different name.

### Conduct

Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).
