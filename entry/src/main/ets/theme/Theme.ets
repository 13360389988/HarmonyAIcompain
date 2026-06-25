/**
 * Theme.ets
 * ----------
 * 统一设计主题：颜色、圆角、间距
 */

export class AppColors {
  // 主色系
  static readonly PRIMARY: string = "#5B7FFF";
  static readonly PRIMARY_DARK: string = "#3D5FE0";
  static readonly PRIMARY_LIGHT: string = "#E8EEFF";

  // 功能色
  static readonly SUCCESS: string = "#34C759";
  static readonly WARNING: string = "#FF9500";
  static readonly DANGER: string = "#FF3B30";
  static readonly INFO: string = "#5AC8FA";

  // 中性色
  static readonly BG_PAGE: string = "#F2F3F7";
  static readonly BG_CARD: string = "#FFFFFF";
  static readonly BG_INPUT: string = "#F5F6FA";
  static readonly BG_TAG: string = "#EEF1FF";

  static readonly TEXT_PRIMARY: string = "#1A1A2E";
  static readonly TEXT_SECONDARY: string = "#6B7280";
  static readonly TEXT_TERTIARY: string = "#9CA3AF";
  static readonly TEXT_PLACEHOLDER: string = "#C0C4CC";

  static readonly BORDER: string = "#EBEDF0";
  static readonly DIVIDER: string = "#F0F0F2";

  // 气泡
  static readonly BUBBLE_USER: string = "#5B7FFF";
  static readonly BUBBLE_AI: string = "#FFFFFF";
  static readonly BUBBLE_SYSTEM: string = "#FFF4E6";

  // 暗色头部
  static readonly HEADER_BG: string = "#1A1A2E";
  static readonly HEADER_BG_OUT: string = "#2D2D44";

  // 透明度
  static readonly SHADOW: string = "#0A000014";
  static readonly OVERLAY: string = "#00000066";
}

export class AppRadius {
  static readonly SM: number = 8;
  static readonly MD: number = 12;
  static readonly LG: number = 16;
  static readonly XL: number = 20;
  static readonly FULL: number = 999;
}

export class AppSpacing {
  static readonly XS: number = 4;
  static readonly SM: number = 8;
  static readonly MD: number = 12;
  static readonly LG: number = 16;
  static readonly XL: number = 20;
  static readonly XXL: number = 24;
}
