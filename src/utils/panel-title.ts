import { t } from '@/services/i18n';

/**
 * [china-fork] 面板标题统一走 `panels.<camelCase(panelId)>`。
 *
 * 上游的做法是让每个 Panel 子类自己传 title：一部分传 `t('panels.xxx')`，
 * 另一部分直接写英文字面量，于是中文界面里会混着 "Threat Timeline" 这类标题。
 * 这里做一次兜底，让标题在所有渲染路径（真实面板、延迟挂载的骨架）上一致。
 *
 * 语言包缺键时 `t()` 返回 key 本身，此时原样返回调用方给的值 —— 与上游行为一致。
 */
export function localizePanelTitle(panelId: string, fallback: string): string {
  const key = panelId.replace(/-([a-z])/g, (_match, group: string) => group.toUpperCase());
  const lookup = `panels.${key}`;
  const localized = t(lookup);
  return localized === lookup ? fallback : localized;
}
