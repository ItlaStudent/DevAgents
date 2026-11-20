"""Genera los activos de marca de la cabina desde el logo real de Ad Astra.

Fuente: shell/brand/logo-ico-<variante>.png (copias de la carpeta de
marca del estudio). La marca NO se dibuja a
mano: una imitación en SVG ya se confundió con el logo una vez (ver
la bitácora interna, sesión del 22-09). Todo lo que sale de aquí es un recorte o un
reescalado del archivo de marca.

Salidas:
  shell/webui/public/brand/mark.png    núcleo sobre su teja, para el favicon
  shell/webui/public/brand/glyph.png   silueta del núcleo SIN teja: una máscara
                                        (blanco + alfa) que la cabina pinta con
                                        el color del tema; es la marca de la
                                        barra de título y la de actividad
  shell/webui/public/brand/emblem.png  logo completo SIN el marco redondeado,
                                        con borde radial fundido: para la
                                        pantalla de inicio, sobre el fondo
  shell/host/devagents.ico             16..256; los tamaños <= 32 usan el
                                        núcleo, porque el logo completo a
                                        16 px es un cuadro oscuro ilegible

Por qué la variante 1 (metal claro) y no la 2 (metal oscuro con la Tierra):
sobre el tema negro por defecto el triángulo oscuro de la 2 desaparece a
tamaño de barra de título. Para volver a la 2: --variante 2.

Uso:  python tools/brand/generate_brand_assets.py [--variante 1|2]
"""

import argparse
import pathlib
from collections import deque

from PIL import Image, ImageDraw, ImageFilter

RAIZ = pathlib.Path(__file__).resolve().parents[2]

# Caja cuadrada del núcleo sobre el lienzo de 1254 px: del anillo del ápice
# (y≈262) a los planetas de la base (y≈840), centrada en x=627.
NUCLEO = (277, 201, 977, 901)
LADO_FUENTE = 1254
# Fondo del interior del logo, medido en el propio PNG (8,8,6).
FONDO = (8, 8, 6, 255)


def teja_redondeada(img: Image.Image, radio_frac: float = 0.22) -> Image.Image:
    """Pone el recorte cuadrado sobre una teja de esquinas redondeadas."""
    lado = img.size[0]
    mascara = Image.new("L", (lado, lado), 0)
    ImageDraw.Draw(mascara).rounded_rectangle(
        (0, 0, lado - 1, lado - 1), radius=int(lado * radio_frac), fill=255
    )
    base = Image.new("RGBA", (lado, lado), FONDO)
    base.alpha_composite(img)
    base.putalpha(mascara)
    return base


def sin_marco(fuente: Image.Image, lado: int) -> Image.Image:
    """El logo sin su teja: una máscara radial que funde el borde.

    Dentro de la cabina el marco redondeado del icono se leía como un botón
    pegado encima del fondo. Con la máscara solo queda el emblema —eje,
    ramas y estrellas— y se desvanece hacia el fondo de la página.
    Opaco hasta el 70 % del radio y transparente al 97 %: el marco empieza
    en el 93 % del radio a media altura, así que desaparece entero.
    """
    img = fuente.resize((lado, lado), Image.LANCZOS)
    mascara = Image.new("L", (lado, lado), 0)
    c = (lado - 1) / 2
    r_in, r_out = 0.70 * c, 0.97 * c
    px = mascara.load()
    for y in range(lado):
        for x in range(lado):
            d = ((x - c) ** 2 + (y - c) ** 2) ** 0.5
            t = 1.0 if d <= r_in else 0.0 if d >= r_out else 1 - (d - r_in) / (r_out - r_in)
            px[x, y] = int(255 * t * t * (3 - 2 * t))
    # Además se recorta el FONDO del logo por luminancia: su negro interior
    # (8,8,6) es más oscuro que el halo de la pantalla de inicio y dibujaba un
    # disco negro alrededor del emblema. Lo que tiene brillo o color (metal,
    # ramas, planetas, estrellas) se queda; el negro se vuelve transparente.
    rgb = img.convert("RGB").load()
    llave = Image.new("L", (lado, lado), 0)
    pk = llave.load()
    for y in range(lado):
        for x in range(lado):
            v = max(rgb[x, y])
            t = 0.0 if v <= 16 else 1.0 if v >= 64 else (v - 16) / 48
            pk[x, y] = int(255 * t)
    alfa = Image.composite(img.getchannel("A"), Image.new("L", (lado, lado), 0), mascara)
    alfa = Image.composite(alfa, Image.new("L", (lado, lado), 0), llave)
    img.putalpha(alfa)
    return img


# Silueta del núcleo (coordenadas del lienzo de 1254 px).
GLIFO_CAJA = (277, 216, 967, 906)
# Interior del triángulo: ahí vive la galaxia, que es puntillismo y no
# sobrevive a una apertura morfológica, así que se conserva entera.
GLIFO_INTERIOR = [(622, 480), (425, 775), (835, 765)]
# Casco del triángulo con sus tres anillos: lo que cae fuera (estrellas
# sueltas) no es parte de la marca.
GLIFO_CASCO = [(622, 236), (262, 836), (982, 836)]


def _componentes(px, lado: int, dentro) -> list:
    """Componentes 4-conexas de los píxeles donde `dentro(valor)` es cierto."""
    visto = bytearray(lado * lado)
    salida = []
    for y0 in range(lado):
        for x0 in range(lado):
            if visto[y0 * lado + x0] or not dentro(px[x0, y0]):
                continue
            cola = deque([(x0, y0)])
            visto[y0 * lado + x0] = 1
            comp = []
            while cola:
                x, y = cola.popleft()
                comp.append((x, y))
                for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                    if 0 <= nx < lado and 0 <= ny < lado and not visto[ny * lado + nx] and dentro(px[nx, ny]):
                        visto[ny * lado + nx] = 1
                        cola.append((nx, ny))
            salida.append(comp)
    return salida


def glifo(fuente: Image.Image, lado: int) -> Image.Image:
    """El núcleo del logo como silueta de un solo color, sin teja ni fondo.

    La marca pequeña era el núcleo sobre su teja oscura: en cualquier tema
    que no fuera negro se veía como una foto pegada (22-09, el propietario la
    detectó al pasar a un tema claro y a uno rosa). La cabina la pinta ahora
    con `mask-image` y el color del texto, así que sigue al tema.

    Es el MISMO archivo de marca, recortado: el metal y la galaxia dan el
    alfa; las ramas finas y las estrellas caen con una apertura morfológica
    (son más delgadas que la banda del triángulo y que los anillos).
    """
    ox, oy = GLIFO_CAJA[0], GLIFO_CAJA[1]
    rec = fuente.convert("RGB").crop(GLIFO_CAJA)
    n = rec.size[0]
    lum = rec.convert("L")
    llave = lum.point(lambda v: 0 if v <= 22 else 255 if v >= 48 else (v - 22) * 255 // 26)
    grueso = (
        lum.point(lambda v: 255 if v > 30 else 0)
        .filter(ImageFilter.MinFilter(11))
        .filter(ImageFilter.MaxFilter(11))
        .filter(ImageFilter.MaxFilter(7))
    )

    def poligono(puntos):
        m = Image.new("L", (n, n), 0)
        ImageDraw.Draw(m).polygon([(x - ox, y - oy) for x, y in puntos], fill=255)
        return m

    interior, casco = poligono(GLIFO_INTERIOR), poligono(GLIFO_CASCO)
    conservar = Image.composite(Image.new("L", (n, n), 255), grueso, interior)
    alfa = Image.composite(llave, Image.new("L", (n, n), 0), conservar)
    a, pi, pc = alfa.load(), interior.load(), casco.load()

    # Fuera del casco: una estrella con halo es lo bastante gruesa para
    # sobrevivir a la apertura. Se borra por su centro, con un margen.
    comps = sorted(_componentes(a, n, lambda v: v > 60), key=len, reverse=True)
    for comp in comps[1:]:
        cx = sum(x for x, _ in comp) // len(comp)
        cy = sum(y for _, y in comp) // len(comp)
        if pc[cx, cy]:
            continue
        for x, y in comp:
            for dx in range(-3, 4):
                for dy in range(-3, 4):
                    if 0 <= x + dx < n and 0 <= y + dy < n and not pi[x + dx, y + dy]:
                        a[x + dx, y + dy] = 0

    # Huecos pequeños del fondo (la ranura entre anillo y planeta): se
    # rellenan, o a 17 px los anillos se leen como ruido.
    for comp in _componentes(a, n, lambda v: v <= 60):
        toca_borde = any(x in (0, n - 1) or y in (0, n - 1) for x, y in comp)
        if not toca_borde and len(comp) < 4000 and not pi[comp[0][0], comp[0][1]]:
            for x, y in comp:
                a[x, y] = 255

    salida = Image.new("RGBA", (n, n), (255, 255, 255, 0))
    salida.putalpha(alfa)
    return salida.resize((lado, lado), Image.LANCZOS)


def nucleo(fuente: Image.Image, lado: int) -> Image.Image:
    recorte = fuente.crop(NUCLEO).resize((lado, lado), Image.LANCZOS)
    return teja_redondeada(recorte)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--variante", choices=("1", "2"), default="1")
    args = ap.parse_args()

    ruta = RAIZ / "shell" / "brand" / f"logo-ico-{args.variante}.png"
    fuente = Image.open(ruta).convert("RGBA")
    if fuente.size != (LADO_FUENTE, LADO_FUENTE):
        raise SystemExit(
            f"{ruta.name} mide {fuente.size}; la caja del núcleo está medida "
            f"sobre {LADO_FUENTE}x{LADO_FUENTE}. Vuelve a medirla antes de generar."
        )

    salida_web = RAIZ / "shell" / "webui" / "public" / "brand"
    salida_web.mkdir(parents=True, exist_ok=True)

    # 96 px cubre la marca de 26 px a 3,5x de escala de pantalla.
    nucleo(fuente, 96).save(salida_web / "mark.png", optimize=True)
    # 128 px: la marca se pinta a 17-19 px, hasta 6x de escala de pantalla.
    glifo(fuente, 128).save(salida_web / "glyph.png", optimize=True)
    sin_marco(fuente, 320).save(salida_web / "emblem.png", optimize=True)

    # El .ico se compone a mano tamaño por tamaño: Pillow, con `sizes=`,
    # reescala UNA sola imagen, y aquí los pequeños son otra composición.
    tamanos = (16, 20, 24, 32, 48, 64, 128, 256)
    capas = [nucleo(fuente, t) if t <= 32 else fuente.resize((t, t), Image.LANCZOS) for t in tamanos]
    ico = RAIZ / "shell" / "host" / "devagents.ico"
    capas[-1].save(ico, format="ICO", sizes=[c.size for c in capas], append_images=capas[:-1])

    for p in (salida_web / "mark.png", salida_web / "glyph.png", salida_web / "emblem.png", ico):
        print(f"{p.relative_to(RAIZ)}  {p.stat().st_size} bytes")


if __name__ == "__main__":
    main()
