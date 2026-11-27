/** 在固定 Hermes 镜像中加载实际 Vite 配置，核对懒加载URL与原生改写的分工。 */
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { pathToFileURL } from 'node:url';

const root = process.env.HERMES_SOURCE_ROOT || '/opt/hermes';
const { loadConfigFromFile } = await import(pathToFileURL(root + '/node_modules/vite/dist/node/index.js'));
const loaded = await loadConfigFromFile({ command: 'build', mode: 'production' }, root + '/web/labnow.vite.config.mjs', root + '/web');
const render = loaded.config.experimental.renderBuiltUrl;
let cases = 0;
for (const prefix of ['', '/studio/user/fixture/lab/hermes']) {
  for (const filename of ['assets/chat.css', 'assets/icon name.svg', 'assets/中文.js']) {
    const result = render(filename, { hostType: 'js', type: 'asset' });
    assert.equal(vm.runInNewContext(result.runtime, { globalThis: { __HERMES_BASE_PATH__: prefix } }), prefix + '/' + encodeURI(filename));
    cases++;
  }
}
for (const hostType of ['html', 'css']) {
  assert.equal(render('assets/app.css', { hostType, type: 'asset' }), undefined);
  cases++;
}
console.log(JSON.stringify({ cases, passed: cases, native_vite_config_loaded: true }));

// 未知上游版本必须停止，而不是静默跳过修复或改变不相关模块。
const { sidecarReconnectPlugin } = await import(pathToFileURL(root + '/web/labnow.sidecar-reconnect.mjs'));
const { mkdtempSync, mkdirSync, writeFileSync, rmSync } = await import('node:fs');
const { tmpdir } = await import('node:os');
const path = await import('node:path');
const temp = mkdtempSync(path.join(tmpdir(), 'hermes-reconnect-contract-'));
try {
  const dir = path.join(temp, 'web/src/components');
  mkdirSync(dir, { recursive: true });
  const unknown = path.join(dir, 'ChatSidebar.tsx');
  writeFileSync(unknown, 'unknown-upstream-version');
  assert.throws(() => sidecarReconnectPlugin().load(unknown), /源码版本不匹配/);
  assert.equal(sidecarReconnectPlugin().load(path.join(dir, 'Other.tsx')), undefined);
  assert(loaded.config.plugins.some(p => p?.name === 'labnow-hermes-sidecar-reconnect'));
  console.log(JSON.stringify({ reconnect_contract_cases: 3, passed: 3 }));
} finally {
  rmSync(temp, { recursive: true, force: true });
}
