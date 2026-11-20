import { cssVar } from './tokens';

/**
 * Un tema es exactamente el mismo conjunto de tokens con otros valores. No
 * existe ninguna rama por tema en los componentes: aplicar un tema es
 * reescribir las CSS custom properties de :root.
 */
export interface ThemeTokens {
  id: string;
  name: string;
  /** 'dark' | 'light' — solo afecta a color-scheme (scrollbars y controles del SO). */
  base: 'dark' | 'light';
  colors: {
    bgApp: string;
    bgTitlebar: string;
    bgActivityBar: string;
    bgSidebar: string;
    bgMain: string;
    bgPanel: string;
    bgStatusBar: string;
    surface1: string;
    surface2: string;
    surface3: string;
    border: string;
    borderStrong: string;
    accent: string;
    accentHover: string;
    accentSoft: string;
    accentContrast: string;
    fg: string;
    fgMuted: string;
    fgSubtle: string;
    success: string;
    warning: string;
    danger: string;
    info: string;
    /** Ámbar de lo activo; si un tema no lo define, se usa su `warning`. */
    highlight?: string;
  };
}

export const themes: Record<string, ThemeTokens> = {
  /**
 * (e), 8-nov: la paleta EXACTA de la maqueta aprobada
   * (docs/referencias-visuales/maquetas-cabina-20261107.html, :root). Es
   * «DevAgents Black» más su ámbar (#e8a868) para lo activo, y el fondo de
   * sus ventanas emergentes (#121211). Tema por defecto desde ese día.
   */
  maqueta: {
    id: 'maqueta',
    name: 'DevAgents Ámbar (maqueta)',
    base: 'dark',
    colors: {
      bgApp: '#0a0a0a',
      bgTitlebar: '#080808',
      bgActivityBar: '#080808',
      bgSidebar: '#0d0d0c',
      bgMain: '#0a0a0a',
      bgPanel: '#121211',
      bgStatusBar: '#080808',
      surface1: '#131312',
      surface2: '#1a1918',
      surface3: '#232220',
      border: 'rgba(250,247,244,0.07)',
      borderStrong: 'rgba(250,247,244,0.13)',
      accent: '#d9d3c7',
      accentHover: '#ece7dd',
      accentSoft: 'rgba(217,211,199,0.10)',
      accentContrast: '#0a0a0a',
      fg: '#e4e0da',
      fgMuted: '#9a958e',
      fgSubtle: '#a39d94',
      success: '#79996a',
      warning: '#c89246',
      danger: '#c4553d',
      info: '#6389a6',
      highlight: '#e8a868',
    },
  },
  /**
 * Tema por defecto desde el 22-09: monocromo cálido de Ad el auditor, pensado
   * para horas de pantalla. Fondo tinta (#0A0A0A, el de la marca) y no negro
   * puro: el negro absoluto con texto claro produce halo y fatiga en sesiones
   * largas. Texto hueso ATENUADO (no #FAF7F4 pleno) por lo mismo. El acento es
   * hueso, no un color: botones y estados activos se distinguen por
   * luminosidad. Los cuatro pigmentos funcionales de la casa (desaturados,
 * medidos en la la sala de diseño) quedan solo para estados — hecho, aviso, error, info.
   * El único color fijo de la interfaz es el del logo.
   */
  black: {
    id: 'black',
    name: 'DevAgents Black',
    base: 'dark',
    colors: {
      bgApp: '#0a0a0a',
      bgTitlebar: '#080808',
      bgActivityBar: '#080808',
      bgSidebar: '#0d0d0c',
      bgMain: '#0a0a0a',
      bgPanel: '#080808',
      bgStatusBar: '#080808',
      surface1: '#131312',
      surface2: '#1a1918',
      surface3: '#232220',
      border: 'rgba(250,247,244,0.07)',
      borderStrong: 'rgba(250,247,244,0.13)',
      accent: '#d9d3c7',
      accentHover: '#ece7dd',
      accentSoft: 'rgba(217,211,199,0.10)',
      accentContrast: '#0a0a0a',
      fg: '#e4e0da',
      fgMuted: '#9a958e',
      fgSubtle: '#a39d94',
      success: '#79996a',
      warning: '#c89246',
      danger: '#c4553d',
      info: '#6389a6',
    },
  },
  dark: {
    id: 'dark',
    name: 'DevAgents Dark',
    base: 'dark',
    colors: {
      bgApp: '#0d0e10',
      bgTitlebar: '#0d0e10',
      bgActivityBar: '#0d0e10',
      bgSidebar: '#111214',
      bgMain: '#0d0e10',
      bgPanel: '#0a0b0c',
      bgStatusBar: '#0d0e10',
      surface1: '#16181b',
      surface2: '#1c1f23',
      surface3: '#24272c',
      border: 'rgba(255,255,255,0.07)',
      borderStrong: 'rgba(255,255,255,0.13)',
      accent: '#7c5cff',
      accentHover: '#9175ff',
      accentSoft: 'rgba(124,92,255,0.15)',
      accentContrast: '#ffffff',
      fg: '#e8eaef',
      fgMuted: '#8b909c',
      fgSubtle: '#9da4b2',
      success: '#3fb950',
      warning: '#d29922',
      danger: '#f85149',
      info: '#58a6ff',
    },
  },
  midnight: {
    id: 'midnight',
    name: 'DevAgents Midnight',
    base: 'dark',
    colors: {
      bgApp: '#08090b',
      bgTitlebar: '#08090b',
      bgActivityBar: '#08090b',
      bgSidebar: '#0c0d10',
      bgMain: '#08090b',
      bgPanel: '#050608',
      bgStatusBar: '#08090b',
      surface1: '#101216',
      surface2: '#15181d',
      surface3: '#1c2027',
      border: 'rgba(255,255,255,0.06)',
      borderStrong: 'rgba(255,255,255,0.12)',
      accent: '#6d8cff',
      accentHover: '#8aa3ff',
      accentSoft: 'rgba(109,140,255,0.15)',
      accentContrast: '#ffffff',
      fg: '#e6e9f0',
      fgMuted: '#868c99',
      fgSubtle: '#969eae',
      success: '#3fb950',
      warning: '#d29922',
      danger: '#f85149',
      info: '#58a6ff',
    },
  },
  cyberpunk: {
    id: 'cyberpunk',
    name: 'Cyberpunk Neon 2077',
    base: 'dark',
    colors: {
      bgApp: '#0b0118',
      bgTitlebar: '#0b0118',
      bgActivityBar: '#0b0118',
      bgSidebar: '#12042b',
      bgMain: '#0b0118',
      bgPanel: '#070010',
      bgStatusBar: '#0b0118',
      surface1: '#1a0640',
      surface2: '#230a52',
      surface3: '#2e0f68',
      border: 'rgba(255,0,85,0.22)',
      borderStrong: 'rgba(255,0,85,0.45)',
      accent: '#00f0ff',
      accentHover: '#5cf6ff',
      accentSoft: 'rgba(0,240,255,0.14)',
      accentContrast: '#0b0118',
      fg: '#ffe600',
      fgMuted: '#ff77a9',
      fgSubtle: '#dc9dce',
      success: '#00ffa3',
      warning: '#ffe600',
      danger: '#ff0055',
      info: '#00f0ff',
    },
  },
  nord: {
    id: 'nord',
    name: 'Nord Oscurecido',
    base: 'dark',
    colors: {
      bgApp: '#242933',
      bgTitlebar: '#242933',
      bgActivityBar: '#242933',
      bgSidebar: '#2e3440',
      bgMain: '#242933',
      bgPanel: '#1e222b',
      bgStatusBar: '#242933',
      surface1: '#2e3440',
      surface2: '#3b4252',
      surface3: '#434c5e',
      border: 'rgba(216,222,233,0.10)',
      borderStrong: 'rgba(216,222,233,0.20)',
      accent: '#88c0d0',
      accentHover: '#8fbcbb',
      accentSoft: 'rgba(136,192,208,0.16)',
      accentContrast: '#2e3440',
      fg: '#eceff4',
      fgMuted: '#a9b1c0',
      fgSubtle: '#c0c9d8',
      success: '#a3be8c',
      warning: '#ebcb8b',
      danger: '#bf616a',
      info: '#81a1c1',
    },
  },
  light: {
    id: 'light',
    name: 'Sleek Light',
    base: 'light',
    colors: {
      bgApp: '#ffffff',
      bgTitlebar: '#ffffff',
      bgActivityBar: '#ffffff',
      bgSidebar: '#f7f8fa',
      bgMain: '#ffffff',
      bgPanel: '#f7f8fa',
      bgStatusBar: '#ffffff',
      surface1: '#f2f4f7',
      surface2: '#e9ecf1',
      surface3: '#dee2e9',
      border: 'rgba(16,24,40,0.10)',
      borderStrong: 'rgba(16,24,40,0.18)',
      accent: '#6532e5',
      accentHover: '#7a4cf0',
      accentSoft: 'rgba(101,50,229,0.10)',
      accentContrast: '#ffffff',
      fg: '#101828',
      fgMuted: '#5b6472',
      fgSubtle: '#98a2b3',
      success: '#079455',
      warning: '#b54708',
      danger: '#d92d20',
      info: '#175cd3',
    },
  },
  synthwave: {
    id: 'synthwave',
    name: 'Synthwave 84',
    base: 'dark',
    colors: {
      bgApp: '#1d1528',
      bgTitlebar: '#1d1528',
      bgActivityBar: '#1d1528',
      bgSidebar: '#241b2f',
      bgMain: '#1d1528',
      bgPanel: '#150d1d',
      bgStatusBar: '#1d1528',
      surface1: '#2a1f38',
      surface2: '#342447',
      surface3: '#402c56',
      border: 'rgba(255,126,219,0.14)',
      borderStrong: 'rgba(255,126,219,0.30)',
      accent: '#f92aad',
      accentHover: '#ff5cc1',
      accentSoft: 'rgba(249,42,173,0.15)',
      accentContrast: '#ffffff',
      fg: '#fdfdfd',
      fgMuted: '#ff7edb',
      fgSubtle: '#c9a5d8',
      success: '#72f1b8',
      warning: '#fede5d',
      danger: '#fe4450',
      info: '#36f9f6',
    },
  },
  monokai: {
    id: 'monokai',
    name: 'Monokai Pro',
    base: 'dark',
    colors: {
      bgApp: '#221f22',
      bgTitlebar: '#221f22',
      bgActivityBar: '#221f22',
      bgSidebar: '#2d2a2e',
      bgMain: '#221f22',
      bgPanel: '#1a181a',
      bgStatusBar: '#221f22',
      surface1: '#2d2a2e',
      surface2: '#363336',
      surface3: '#403c40',
      border: 'rgba(252,252,250,0.09)',
      borderStrong: 'rgba(252,252,250,0.18)',
      accent: '#ffd866',
      accentHover: '#ffe28a',
      accentSoft: 'rgba(255,216,102,0.14)',
      accentContrast: '#221f22',
      fg: '#fcfcfa',
      fgMuted: '#c1c0c0',
      fgSubtle: '#b1adb1',
      success: '#a9dc76',
      warning: '#ffd866',
      danger: '#ff6188',
      info: '#78dce8',
    },
  },
};

const STORAGE_KEY = 'devagents.theme';
export const DEFAULT_THEME_ID = 'maqueta';
/**
 * Migración única al cambiar el tema por defecto a 'black' (22-09, decisión
 * del propietario). Un tema guardado no distingue «lo elegí» de «me lo dejaron»:
 * applyTheme() guarda SIEMPRE el tema aplicado (así que el antiguo defecto
 * 'dark' quedaba guardado sin que nadie lo eligiera), y la prueba E2E en vivo
 * `tests/live/cdp_ui_action_test.cjs` dejaba 'nord' en el perfil real. Por eso
 * cualquier tema guardado antes de esta versión pasa UNA vez a 'black'. Lo que
 * se elija después se conserva, porque la bandera ya está puesta.
 */
// 8-nov: la paleta de la maqueta pasa a ser la de todos UNA vez (el propietario la
// pidió aplicada); lo que se elija después se conserva.
const MIGRATION_KEY = 'devagents.theme.default-maqueta';

export class ThemeManager {
  private currentThemeId = DEFAULT_THEME_ID;
  private listeners: Array<(id: string) => void> = [];

  constructor() {
    try {
      let saved = localStorage.getItem(STORAGE_KEY);
      if (!localStorage.getItem(MIGRATION_KEY)) {
        saved = DEFAULT_THEME_ID;
        localStorage.setItem(MIGRATION_KEY, '1');
      }
      if (saved && themes[saved]) this.currentThemeId = saved;
    } catch {
      // Sin localStorage (modo file:// o almacenamiento bloqueado): tema por defecto.
    }
  }

  public registerTheme(theme: ThemeTokens): void {
    themes[theme.id] = theme;
  }

  public applyTheme(themeId: string): void {
    const theme = themes[themeId] || themes[DEFAULT_THEME_ID];
    this.currentThemeId = theme.id;
    const root = document.documentElement;

    const c = theme.colors;
    root.style.setProperty(cssVar.bgApp, c.bgApp);
    root.style.setProperty(cssVar.bgTitlebar, c.bgTitlebar);
    root.style.setProperty(cssVar.bgActivityBar, c.bgActivityBar);
    root.style.setProperty(cssVar.bgSidebar, c.bgSidebar);
    root.style.setProperty(cssVar.bgMain, c.bgMain);
    root.style.setProperty(cssVar.bgPanel, c.bgPanel);
    root.style.setProperty(cssVar.bgStatusBar, c.bgStatusBar);
    root.style.setProperty(cssVar.surface1, c.surface1);
    root.style.setProperty(cssVar.surface2, c.surface2);
    root.style.setProperty(cssVar.surface3, c.surface3);
    root.style.setProperty(cssVar.border, c.border);
    root.style.setProperty(cssVar.borderStrong, c.borderStrong);
    root.style.setProperty(cssVar.accent, c.accent);
    root.style.setProperty(cssVar.accentHover, c.accentHover);
    root.style.setProperty(cssVar.accentSoft, c.accentSoft);
    root.style.setProperty(cssVar.accentContrast, c.accentContrast);
    root.style.setProperty(cssVar.fg, c.fg);
    root.style.setProperty(cssVar.fgMuted, c.fgMuted);
    root.style.setProperty(cssVar.fgSubtle, c.fgSubtle);
    root.style.setProperty(cssVar.success, c.success);
    root.style.setProperty(cssVar.warning, c.warning);
    root.style.setProperty(cssVar.danger, c.danger);
    root.style.setProperty(cssVar.info, c.info);
    root.style.setProperty(cssVar.highlight, c.highlight ?? c.warning);
    root.style.setProperty('color-scheme', theme.base);
    root.setAttribute('data-theme', theme.id);

    try {
      localStorage.setItem(STORAGE_KEY, theme.id);
    } catch {
      // Persistencia best-effort: no impide aplicar el tema.
    }

    this.listeners.forEach((fn) => fn(theme.id));
  }

  public onChange(fn: (id: string) => void): void {
    this.listeners.push(fn);
  }

  /** Con sus colores, para pintar las muestras de Apariencia (maqueta, pág. 5). */
  public getAvailableThemes(): { id: string; name: string; colors: ThemeTokens['colors'] }[] {
    return Object.values(themes).map((t) => ({ id: t.id, name: t.name, colors: t.colors }));
  }

  public getCurrentThemeId(): string {
    return this.currentThemeId;
  }
}
