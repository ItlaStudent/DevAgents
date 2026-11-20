/**
 * Contrato de design tokens de DevAgents.
 *
 * Regla: ningun componente escribe un color literal. Todos consumen estas
 * referencias, que apuntan a CSS custom properties de :root. El ThemeManager
 * reescribe esas variables y el cambio de tema se propaga solo, sin tocar
 * ningun componente.
 *
 * `tokens.color.accent` devuelve la CADENA "var(--accent)", no un hex: sirve
 * igual dentro de un style inline que dentro de una hoja de estilos.
 */

export const cssVar = {
  bgApp: '--bg-app',
  bgTitlebar: '--bg-titlebar',
  bgActivityBar: '--bg-activitybar',
  bgSidebar: '--bg-sidebar',
  bgMain: '--bg-main',
  bgPanel: '--bg-panel',
  bgStatusBar: '--bg-statusbar',
  surface1: '--surface-1',
  surface2: '--surface-2',
  surface3: '--surface-3',
  border: '--border',
  borderStrong: '--border-strong',
  accent: '--accent',
  accentHover: '--accent-hover',
  accentSoft: '--accent-soft',
  accentContrast: '--accent-contrast',
  fg: '--fg',
  fgMuted: '--fg-muted',
  fgSubtle: '--fg-subtle',
  success: '--success',
  warning: '--warning',
  danger: '--danger',
  info: '--info',
  /** (e): el ámbar de la maqueta para lo activo (elegido, encendido, enlaces, chips). */
  highlight: '--highlight',
} as const;

const v = (name: string) => `var(${name})`;

export const tokens = {
  color: {
    // Superficies de la cabina, de fuera hacia dentro.
    bgApp: v(cssVar.bgApp),
    bgTitlebar: v(cssVar.bgTitlebar),
    bgActivityBar: v(cssVar.bgActivityBar),
    bgSidebar: v(cssVar.bgSidebar),
    bgMain: v(cssVar.bgMain),
    bgChatPanel: v(cssVar.bgPanel),
    bgPanel: v(cssVar.bgPanel),
    bgStatusBar: v(cssVar.bgStatusBar),
    // Elevacion dentro de una superficie: tarjetas, hover, estado activo.
    surface1: v(cssVar.surface1),
    surface2: v(cssVar.surface2),
    surface3: v(cssVar.surface3),
    border: v(cssVar.border),
    borderStrong: v(cssVar.borderStrong),
    accent: v(cssVar.accent),
    accentHover: v(cssVar.accentHover),
    accentSoft: v(cssVar.accentSoft),
    accentContrast: v(cssVar.accentContrast),
    textPrimary: v(cssVar.fg),
    textSecondary: v(cssVar.fgMuted),
    textMuted: v(cssVar.fgSubtle),
    success: v(cssVar.success),
    warning: v(cssVar.warning),
    danger: v(cssVar.danger),
    info: v(cssVar.info),
    highlight: v(cssVar.highlight),
  },
  typography: {
    fontFamily:
      '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Text", "Segoe UI", Roboto, Helvetica, Arial, sans-serif',
    fontCode: '"JetBrains Mono", "Cascadia Code", "Consolas", ui-monospace, monospace',
    fontSizeXs: '11px',
    fontSizeSm: '12px',
    fontSizeMd: '13px',
    fontSizeLg: '15px',
    fontSizeXl: '22px',
  },
  spacing: {
    xs: '4px',
    sm: '8px',
    md: '16px',
    lg: '24px',
    xl: '32px',
  },
  radii: {
    sm: '6px',
    md: '10px',
    lg: '14px',
    pill: '999px',
  },
  motion: {
    fast: '120ms cubic-bezier(0.2, 0, 0, 1)',
    normal: '200ms cubic-bezier(0.2, 0, 0, 1)',
  },
} as const;
