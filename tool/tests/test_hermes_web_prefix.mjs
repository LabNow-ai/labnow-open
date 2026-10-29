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
