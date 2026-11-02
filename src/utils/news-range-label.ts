import { t } from '@/services/i18n';

/**
 * [china-fork] 新闻面板"时间窗过滤后为空"的文案。
 *
 * 上游这三处（panel-layout 两处、data-loader 一处）直接拼英文字面量
 * `No items in the last hour`，中文界面里会漏出英文。这里统一走 i18n，
 * 语言包缺键时用英文原文兜底，行为与上游一致。
 */

const RANGE_FALLBACK: Record<string, string> = {
  '1h': 'the last hour',
  '6h': 'the last 6 hours',
  '24h': 'the last 24 hours',
  '48h': 'the last 48 hours',
  '7d': 'the last 7 days',
  all: 'all time',
};

export function timeRangeLabel(range: string): string {
  const fallback = RANGE_FALLBACK[range] ?? RANGE_FALLBACK['7d'];
  return t(`components.newsPanel.timeRanges.${range}`, { defaultValue: fallback });
}

export function noItemsInRangeText(range: string): string {
  const label = timeRangeLabel(range);
  return t('components.newsPanel.noItemsInRange', {
    range: label,
    defaultValue: `No items in ${label}`,
  });
}
