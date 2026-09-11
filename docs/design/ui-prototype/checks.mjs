// 在已打开原型的同一个 Ego TaskSpace 执行；输入脚本前设置 globalThis.NEWPI_UI_SPACE = <id>。
// 只操作演示页面，不触发复制、不连接模型。断言失败保留页面供检查。
const space = Number(globalThis.NEWPI_UI_SPACE);
if (!Number.isInteger(space) || space < 1) throw new Error('请通过 NEWPI_UI_SPACE 指定现有原型 TaskSpace');
const task = await taskSpace(space);
const page = task.page('p1');
const results = [];
async function check(name, condition) {
  if (!condition) throw new Error(name);
  results.push(name);
}
await page.reload();
console.log(await page.snapshot());
await page.evaluate(() => {
  window.prototypeErrors = [];
  window.addEventListener('error', event => window.prototypeErrors.push(event.message));
  window.addEventListener('unhandledrejection', event => window.prototypeErrors.push(String(event.reason)));
  window.addEventListener('securitypolicyviolation', event => window.prototypeErrors.push('CSP: ' + event.violatedDirective));
});
await check('初始空草稿不可发送', await page.evaluate(() => document.querySelector('#primary-action').disabled));
await page.fill('#message-input', '同一份草稿，比较 A 与 B。');
await page.click('#process-details > summary');
const content = await page.evaluate(() => {
  window.prototypeMessages = document.querySelector('#messages');
  window.prototypeFirstMessage = document.querySelector('.message');
  return document.querySelector('#messages').innerHTML;
});
await page.click('button[data-variant="chat"]');
await check('A/B 不重建消息、不清空草稿或详情展开', await page.evaluate(expected =>
  document.body.dataset.variant === 'chat' && document.querySelector('#messages').innerHTML === expected &&
  document.querySelector('.message') === window.prototypeFirstMessage &&
  document.querySelector('#message-input').value === '同一份草稿，比较 A 与 B。' &&
  document.querySelector('#process-details').open, content));
await page.click('button[data-variant="document"]');
await page.selectOption('#theme-select', 'dark');
await check('深色切换不改变正文', await page.evaluate(expected =>
  document.body.dataset.theme === 'dark' && document.querySelector('#messages').innerHTML === expected, content));
await page.click('#metrics-button');
await check('用量弹窗正常打开', await page.evaluate(() => document.querySelector('#detail-dialog').open && document.querySelector('#dialog-title').textContent === '本轮用量'));
await page.press('#close-dialog', 'Escape');
await check('Esc 关闭并恢复焦点', await page.evaluate(() => !document.querySelector('#detail-dialog').open && document.activeElement === document.querySelector('#metrics-button')));
await page.click('#changes-button');
await check('差异明确标注为示意', await page.evaluate(() => document.querySelector('#detail-dialog').open && document.querySelector('#dialog-content').textContent.includes('并不是可应用的补丁') === false && document.querySelector('#dialog-content').textContent.includes('不是可应用的补丁')));
await page.click('#close-dialog');

await page.selectOption('#scene-select', 'running');
await page.fill('#message-input', '运行期间保留下一条草稿');
await page.press('#message-input', 'Enter');
await check('运行中 Enter 不会停止任务', await page.evaluate(() => document.querySelector('#primary-action').dataset.action === 'stop'));
await page.click('#primary-action');
await check('明确停止后保留草稿、不伪造全部完成', await page.evaluate(() =>
  document.querySelector('#message-input').value === '运行期间保留下一条草稿' &&
  document.querySelector('#run-status').textContent.includes('已停止') &&
  document.querySelector('#process-details').textContent.includes('几何验证未完成')));
await page.selectOption('#scene-select', 'complete');
await check('场景切换保留独立草稿', await page.evaluate(() => document.querySelector('#message-input').value === '同一份草稿，比较 A 与 B。'));

await page.selectOption('#scene-select', 'approval');
await page.fill('#message-input', '等待审批时写下的草稿');
await check('审批期间不发送，草稿可编辑', await page.evaluate(() => document.querySelector('#primary-action').disabled && !document.querySelector('#message-input').disabled));
await page.click('[data-action="allow"]');
await check('一次审批后可继续，草稿保留', await page.evaluate(() =>
  document.querySelector('.approval-result').textContent.includes('允许一次') &&
  !document.querySelector('#primary-action').disabled && document.querySelector('#message-input').value === '等待审批时写下的草稿'));
await page.click('#reset-scene');
await page.click('[data-action="deny"]');
await check('拒绝路径明确且无文件操作', await page.evaluate(() => document.querySelector('.approval-result').textContent.includes('未写入任何文件')));

await page.selectOption('#scene-select', 'error');
await page.fill('#message-input', '错误后仍保留的草稿');
await page.click('[data-action="retry"]');
await page.waitForFunction(() => document.querySelector('#run-status').textContent === '连接演示已恢复', undefined, { timeout: 6000 });
await page.selectOption('#scene-select', 'complete');
await page.selectOption('#scene-select', 'error');
await check('重试恢复状态与草稿在切回后仍正确', await page.evaluate(() =>
  !document.querySelector('.error-card') && document.querySelector('#message-input').value === '错误后仍保留的草稿'));
await page.click('#reset-scene');
await check('场景可重置再次演示', await page.evaluate(() => !!document.querySelector('[data-action="retry"]')));

await page.selectOption('#scene-select', 'room');
await check('聊天室明确独立工作目录', await page.evaluate(() =>
  !document.querySelector('#room-bar').hidden && document.querySelector('#working-directory').textContent.includes('design-lab') &&
  document.querySelector('#mode-label').textContent === '聊天室'));
await page.click('[data-action="next-speaker"]');
await check('手动推进只追加一次评审发言', await page.evaluate(() => document.querySelectorAll('.assistant-message').length === 3 && document.querySelector('[data-action="next-speaker"]').disabled));

await page.selectOption('#scene-select', 'empty');
await page.click('[data-prompt="请先梳理这个项目的结构和主要入口。"]');
await check('空态建议填入草稿而非自动发送', await page.evaluate(() => document.querySelector('#message-input').value.includes('梳理') && !!document.querySelector('.empty-state')));
await page.click('#attach-button');
await check('附件演示可添加', await page.evaluate(() => !document.querySelector('#attachment-strip').hidden));
await page.click('#remove-attachment');
await check('附件演示可移除', await page.evaluate(() => document.querySelector('#attachment-strip').hidden));
await page.fill('#message-input', '<img src=x onerror="window.prototypeInjected=true">');
await page.evaluate(() => document.querySelector('#message-input').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', isComposing: true, bubbles: true, cancelable: true })));
await check('IME 确认不触发发送', await page.evaluate(() => !!document.querySelector('.empty-state') && document.querySelectorAll('.user-message').length === 0));
await page.press('#message-input', 'Shift+Enter');
await check('Shift+Enter 换行不发送', await page.evaluate(() => document.querySelector('#message-input').value.includes('\n') && !!document.querySelector('.empty-state')));
await page.press('#message-input', 'Enter');
await page.waitForFunction(() => document.querySelector('#run-status').textContent === '演示回复已完成', undefined, { timeout: 7000 });
await check('发送后退出欢迎空态，用户内容安全转义', await page.evaluate(() =>
  !document.querySelector('.empty-state') && !document.querySelector('#messages img') && !window.prototypeInjected &&
  document.querySelector('.user-content').textContent.includes('<img')));

// 验证后台演示完成不会覆写正在浏览的另一个场景。
await page.fill('#message-input', '后台运行隔离检查');
await page.press('#message-input', 'Enter');
await page.selectOption('#scene-select', 'room');
await page.waitForFunction(() => document.querySelector('#scene-select').value === 'room', undefined, { timeout: 3000 });
await page.evaluate(() => new Promise(resolve => {
  // 等待演示计时器的完成边界；这不是轮询进程或网络请求。
  setTimeout(resolve, 2400);
}));
await check('后台完成不污染当前聊天室', await page.evaluate(() => document.querySelector('#mode-label').textContent === '聊天室' && document.querySelector('#run-status').textContent === '本轮讨论已完成'));
await page.selectOption('#scene-select', 'empty');
await check('切回后保留后台完成结果', await page.evaluate(() => document.querySelector('#run-status').textContent === '演示回复已完成' && document.querySelectorAll('.user-message').length === 2));

const layouts = await page.evaluate(() => {
  const problems = [], cases = [];
  const select = (id, value) => { const el = document.querySelector(id); el.value = value; el.dispatchEvent(new Event('change', { bubbles: true })); };
  for (const variant of ['document', 'chat']) {
    document.querySelector(`button[data-variant="${variant}"]`).click();
    for (const width of ['wide', 'narrow']) {
      if (document.body.dataset.width !== width) document.querySelector('#width-toggle').click();
      for (const scene of ['complete', 'running', 'approval', 'room', 'error', 'empty']) {
        select('#scene-select', scene);
        for (const id of ['.workspace', '.workspace-header', '.composer', '.composer-tools', '.reading-column']) {
          const el = document.querySelector(id);
          if (el.scrollWidth > el.clientWidth + 2) problems.push({ variant, width, scene, id, client: el.clientWidth, scroll: el.scrollWidth });
        }
        cases.push({ variant, width, scene });
      }
    }
  }
  return { problems, count: cases.length };
});
await check(`${layouts.count} 种场景/宽度/方案组合无横向溢出：${JSON.stringify(layouts.problems)}`, layouts.problems.length === 0);
await check('未发生运行时或 CSP 错误', await page.evaluate(() => window.prototypeErrors.length === 0));

// 留下可供用户直接比较的干净完成态，不关闭由主任务保留的结果页面。
await page.selectOption('#scene-select', 'complete');
await page.click('#reset-scene');
await page.selectOption('#theme-select', 'light');
await page.click('button[data-variant="document"]');
if (await page.evaluate(() => document.body.dataset.width === 'narrow')) await page.click('#width-toggle');
console.log(JSON.stringify({ passed: results.length, checks: results, layoutCases: layouts.count }, null, 2));
console.log(await page.snapshot());