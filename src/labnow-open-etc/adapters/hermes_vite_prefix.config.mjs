/** 运行时 Lab 前缀由 Hermes 原生 HTML 注入；懒加载资源沿用同一前缀。 */
import { mergeConfig } from 'vite';
import upstream from './vite.config.ts';

export function renderBuiltUrl(filename, { hostType }) {
  if (hostType === 'js') {
    return {
      runtime: `((globalThis.__HERMES_BASE_PATH__ || "") + ${JSON.stringify('/' + encodeURI(filename))})`,
    };
  }
  // HTML 和 CSS 保留 Hermes 原生响应中的前缀改写。
}

export default mergeConfig(upstream, { experimental: { renderBuiltUrl } });
