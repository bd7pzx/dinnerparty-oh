/**
 * 设计令牌 —— 取自逆向出的海报配色与皮肤 token 体系。
 * 主视觉：绯（paper/ink）系，深墨文字，浅粉底。
 */

export interface Palette {
  bg: string;
  surface: string;
  surfaceAlt: string;
  tint: string;
  line: string;
  ink: string;
  inkSoft: string;
  inkFaint: string;
  primary: string;
  primaryDeep: string;
  onPrimary: string;
  success: string;
  warn: string;
  danger: string;
}

const LIGHT: Palette = {
  bg: '#FFF6F8',
  surface: '#FFFFFF',
  surfaceAlt: '#FDF1F5',
  tint: '#F9E4EB',
  line: '#F0C9D6',
  ink: '#4A2438',
  inkSoft: 'rgba(74,36,56,0.72)',
  inkFaint: 'rgba(74,36,56,0.45)',
  primary: '#B5466E',
  primaryDeep: '#8E3054',
  onPrimary: '#FFFFFF',
  success: '#3F8F6B',
  warn: '#C9873A',
  danger: '#C0433F'
};

const DARK: Palette = {
  bg: '#1A1014',
  surface: '#241519',
  surfaceAlt: '#2C1A20',
  tint: '#3A2129',
  line: '#4A2B35',
  ink: '#F6E8ED',
  inkSoft: 'rgba(246,232,237,0.72)',
  inkFaint: 'rgba(246,232,237,0.42)',
  primary: '#E0709A',
  primaryDeep: '#F09BB8',
  onPrimary: '#2A0F18',
  success: '#66B98F',
  warn: '#D9A055',
  danger: '#DE6A66'
};

export class Theme {
  static dark: boolean = false;

  static palette(): Palette {
    return Theme.dark ? DARK : LIGHT;
  }

  /** 圆角 */
  static readonly R_SM: number = 10;
  static readonly R_MD: number = 14;
  static readonly R_LG: number = 20;
  static readonly R_XL: number = 26;
  static readonly R_FULL: number = 999;

  /** 间距 */
  static readonly S_XS: number = 4;
  static readonly S_SM: number = 8;
  static readonly S_MD: number = 12;
  static readonly S_LG: number = 16;
  static readonly S_XL: number = 24;
  static readonly S_XXL: number = 32;

  /** 字号 */
  static readonly F_CAP: number = 11;
  static readonly F_SM: number = 12;
  static readonly F_BASE: number = 14;
  static readonly F_MD: number = 16;
  static readonly F_LG: number = 19;
  static readonly F_XL: number = 24;
  static readonly F_XXL: number = 30;

  /** 阴影 */
  /** 悬浮栏/浮层的半透明底色（配合 backgroundBlurStyle 做毛玻璃） */
  static glass(): string {
    return Theme.dark ? 'rgba(26,16,20,0.90)' : 'rgba(255,255,255,0.82)';
  }

  static glassBorder(): string {
    return Theme.dark ? 'rgba(246,232,237,0.12)' : 'rgba(240,201,214,0.9)';
  }

  static cardShadow(): ShadowOptions {
    return Theme.dark
      ? { radius: 12, color: 'rgba(0,0,0,0.45)', offsetX: 0, offsetY: 4 }
      : { radius: 16, color: 'rgba(180,90,120,0.14)', offsetX: 0, offsetY: 6 };
  }

  static floatShadow(): ShadowOptions {
    return Theme.dark
      ? { radius: 20, color: 'rgba(0,0,0,0.55)', offsetX: 0, offsetY: 8 }
      : { radius: 26, color: 'rgba(160,70,105,0.22)', offsetX: 0, offsetY: 10 };
  }
}

/** 评分档位的图标与文案（对应逆向 strongNo / belowAverage / aboveAverage / strongYes） */
export interface RatingLevelMeta {
  score: number;
  icon: string;
  label: string;
  color: string;
}

export const RATING_LEVELS: RatingLevelMeta[] = [
  { score: 4, icon: '♥', label: '强烈推荐', color: '#C0433F' },
  { score: 3, icon: '♡', label: '还不错', color: '#D2739A' },
  { score: 2, icon: '·', label: '一般', color: '#8B7A82' },
  { score: 1, icon: '×', label: '不推荐', color: '#6B5A62' }
];

export function ratingMeta(score: number): RatingLevelMeta {
  for (const m of RATING_LEVELS) {
    if (m.score === score) return m;
  }
  return { score: 0, icon: '·', label: '未评分', color: '#8B7A82' };
}
