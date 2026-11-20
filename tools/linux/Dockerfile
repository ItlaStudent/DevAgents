# T9 fase B (L1): imagen de trabajo de DevAgents en Linux (motor, CLI y MCP).
# Ubuntu 24.04 + Zig 0.16.0 x86_64-linux con su SHA-256 comprobado.
# El repo se monta de solo lectura en /src; la cache y el prefijo van en
# volumenes del contenedor (devagents-t9-cache, devagents-t9-prefix).
# Construir: docker build -t devagents-t9:ubuntu24.04 tools/linux
FROM ubuntu:24.04

ARG ZIG_VERSION=0.16.0
ARG ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00

# git y python3 los usa la suite (fixtures HTTP, repos temporales); curl y xz
# solo descargan Zig. nodejs: lo lanzan de verdad pruebas del motor (QA-V1
# console.assert, guardia SEC-FS por Node, dobles de las pruebas de la cabina).
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils git python3 nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
 && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
 && mkdir -p /opt/zig \
 && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
 && rm /tmp/zig.tar.xz \
 && ln -s /opt/zig/zig /usr/local/bin/zig

# Usuario sin privilegios: las pruebas de permisos (0600/0700, propietario)
# no valen como root.
RUN useradd -m -u 1001 dev \
 && mkdir -p /cache /prefix \
 && chown dev:dev /cache /prefix
USER dev
ENV HOME=/home/dev
WORKDIR /home/dev
