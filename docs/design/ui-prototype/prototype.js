/* 纯前端设计样机。所有状态仅在内存中，不连接生产 API、不读取本地用户数据。 */
(() => {
  'use strict';
  const $ = selector => document.querySelector(selector);
  const icons = {
    folder: '<path d="M3 6h6l2 2h10v11H3z"/><path d="M3 6V4h6l2 2h9v2"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    message: '<path d="M4 4h16v12H9l-5 4z"/><path d="M8 8h8M8 12h5"/>',
    activity: '<path d="M3 12h4l3-7 4 14 3-7h4"/>',
    people: '<circle cx="9" cy="8" r="3"/><path d="M3 20v-3a6 6 0 0 1 12 0v3M16 5a3 3 0 0 1 0 6M18 14c2 1 3 2 3 5"/>',
    shield: '<path d="m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6z"/><path d="m8 12 3 3 5-6"/>',
    info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7h.01"/>',
    sidebar: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16M5 8h2M5 11h2"/>',
    diff: '<rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 8h8M8 15h8M12 12v6"/>',
    arrowDown: '<path d="M12 4v16m-6-6 6 6 6-6"/>',
    arrowUp: '<path d="M12 20V4m-6 6 6-6 6 6"/>',
    arrowRight: '<path d="M4 12h16m-6-6 6 6-6 6"/>',
    chart: '<path d="M4 20h16M7 16v-5M12 16V4M17 16V8"/>',
    image: '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8" cy="8" r="1.5"/><path d="m3 17 6-6 4 4 3-3 5 5"/>',
    close: '<path d="m6 6 12 12M6 18 18 6"/>',
    sparkle: '<path d="m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5z"/>',
    check: '<path d="m5 12 4 4L19 6"/>',
    chevron: '<path d="m9 5 7 7-7 7"/>',
    file: '<path d="M5 3h9l5 5v13H5zM14 3v6h5M9 13h6M9 17h6"/>',
    terminal: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="m7 8 4 4-4 4M13 16h4"/>',
    copy: '<rect x="8" y="8" width="12" height="13" rx="2"/><path d="M15 8V3H3v13h5"/>',
    stop: '<rect x="6" y="6" width="12" height="12" rx="2"/>',
    warning: '<path d="m12 3 10 18H2zM12 9v5M12 17h.01"/>',
    retry: '<path d="M3 11a9 9 0 1 1 3 8M3 4v7h7"/>'
  };
  const icon = name => `<svg viewBox="0 0 24 24" aria-hidden="true">${icons[name] || icons.message}</svg>`;
  document.querySelectorAll('[data-icon]').forEach(el => { el.innerHTML = icon(el.dataset.icon); });

  if (!window.markdownit || !window.hljs) {
    $('#messages').textContent = '本地渲染资源未加载。请保留原型在仓库中的相对路径，并从仓库根目录启动本地预览。';
    return;
  }
  const markdown = window.markdownit({
    html: false, breaks: true, typographer: true,
    highlight(source, language) {
      if (language && window.hljs.getLanguage(language)) {
        return window.hljs.highlight(source, { language, ignoreIllegals: true }).value;
      }
      return markdown.utils.escapeHtml(source);
    }
  });
  markdown.disable('image');
  const escape = markdown.utils.escapeHtml;

  // 两种设计共享同一份 fixture，只有 body[data-variant] 控制视觉。
  const answer = [
    '## 已对齐流式与最终的 Markdown 结构',
    '',
    '问题不在滚动条，而在**同一段内容被解析成了不同结构**。空行曾把一个完整列表拆成多个片段，结束时重新合并，才出现了那一下跳动。',
    '',
    '### 这次调整了什么',
    '',
    '1. **按语义分块。** 以 markdown-it 的顶层 token 为边界，列表、引用和代码保持完整。',
    '',
    '2. **保留稳定内容。** 已冻结的 DOM 节点继续复用，只更新发生变化的部分。',
    '',
    '3. **处理跨块引用。** 新增或删除引用定义时，相关的旧内容会重新解析。',
    '',
    '```javascript',
    '// 使用全文上下文，不再把空行当成独立文档',
    'const tokens = markdown.parse(source, environment);',
    'const blocks = groupTopLevelTokens(tokens);',
    '',
    'for (const block of changedBlocks(blocks)) {',
    '  updateBlock(block);',
    '}',
    '```',
    '',
    '### 验证结果',
    '',
    '| 检查项 | 演示数据 |',
    '| --- | --- |',
    '| 松散列表收尾位移 | 26px → 0px |',
    '| 语义与字符级用例 | 19 项通过 |',
    '| 200 行代码输出 | 保留代码节点 |',
    '',
    '> 没有增加固定高度、滚动补偿或动画。这里展示的是设计样例，不代表一次新执行的测试。',
    '',
    '**下一步：** 用真实的长回答确认阅读体验，尤其留意展开过程详情后，正文的位置是否稳定。'
  ].join('\n');
  const scenes = {
    complete: { title: '让 Markdown 收尾更稳定', mode: '会话', path: '~/personal/projects/new-pi', phase: 'done', status: '本轮已完成', detail: '2 个文件 · 19 项检查' },
    running: { title: '检查长会话渲染', mode: '会话', path: '~/personal/projects/new-pi', phase: 'running', status: '正在检查渲染边界', detail: '执行中 · 演示状态' },
    approval: { title: '让 Markdown 收尾更稳定', mode: '会话', path: '~/personal/projects/new-pi', phase: 'approval', status: '等待你的确认', detail: '1 项操作需要审批' },
    room: { title: '界面设计评审', mode: '聊天室', path: '~/personal/projects/design-lab · 独立工作目录', phase: 'done', status: '等待下一位角色发言', detail: '讨论阶段 · 手动推进' },
    error: { title: '梳理项目结构', mode: '会话', path: '~/personal/projects/new-pi', phase: 'error', status: '连接失败', detail: '草稿与历史已保留' },
    empty: { title: '新会话', mode: '会话', path: '~/personal/projects/new-pi', phase: 'done', status: '准备就绪', detail: '已选择项目与模型' }
  };
  const memory = new Map();
  let scene = 'complete';
  let toastTimer;
  let dialogOpener;
  let themePreference = 'light';
  const media = window.matchMedia('(prefers-color-scheme: dark)');
  function current(id = scene) {
    if (!memory.has(id)) memory.set(id, { ...scenes[id], draft: '', attachment: false, model: 'Claude Sonnet', extras: [], decision: null, nextSpeaker: false, recovered: false, timer: null });
    return memory.get(id);
  }
  function toast(text) {
    clearTimeout(toastTimer);
    $('#toast').textContent = text;
    $('#toast').hidden = false;
    toastTimer = setTimeout(() => { $('#toast').hidden = true; }, 3500);
  }
  function userMessage(text, time = '11:42') {
    return `<section class="message user-message"><div class="message-label"><span class="avatar user">你</span><strong>你</strong><time>${time}</time></div><div class="user-content">${escape(text)}</div></section>`;
  }
  function assistantMessage(text, name = 'NewPi', role = '', actions = false) {
    return `<section class="message assistant-message"><div class="message-label"><span class="avatar">${escape(name.charAt(0) === 'N' ? 'n' : name.charAt(0))}</span><strong>${escape(name)}</strong>${role ? `<span class="role-badge">${escape(role)}</span>` : ''}<time>演示</time></div><div class="prose">${markdown.render(text)}</div>${actions ? '<div class="message-actions"><button type="button" class="quiet-button" data-action="copy-answer">' + icon('copy') + '复制回答</button><button type="button" class="quiet-button" data-action="changes">' + icon('diff') + '查看改动</button></div>' : ''}</section>`;
  }
  function process(open = false, phase = 'done') {
    const running = phase === 'running', stopped = phase === 'stopped';
    return `<details class="process" id="process-details"${open ? ' open' : ''}><summary><span class="check-icon">${icon(running ? 'activity' : stopped ? 'stop' : 'check')}</span><span>${running ? '正在执行 · 已完成 2 / 3 步' : stopped ? '已停止 · 保留 2 个已完成步骤' : '处理过程 · 3 个步骤'}</span><span class="chevron">${icon('chevron')}</span></summary><div class="process-list">
      <div class="process-step">${icon('check')}<div>读取渲染与布局逻辑<code>markdown-renderer.js · transcript-document.css</code></div><small>0.2s</small></div>
      <div class="process-step">${icon('check')}<div>对齐顶层语义块<code>保留完整列表、引用与围栏</code></div><small>1.4s</small></div>
      <div class="process-step">${icon(running ? 'activity' : stopped ? 'stop' : 'check')}<div>${running ? '验证收尾与上翻保锚' : stopped ? '几何验证未完成' : '完成语义与几何验证'}<code>check-transcript-dom.sh · 演示，不执行</code></div><small>${running ? '执行中' : stopped ? '已停止' : '8.1s'}</small></div>
    </div></details>`;
  }
  function approval(state) {
    if (state.decision) return `<div class="approval-result">${icon(state.decision === 'allow' ? 'check' : 'shield')} ${state.decision === 'allow' ? '已模拟「允许一次」。授权仅针对本次演示操作。' : '已模拟拒绝操作，未写入任何文件。'}<br><span class="dialog-note">这不是生产权限设置，也没有执行显示的命令。</span></div>`;
    return `<section class="approval-card" aria-label="待审批操作"><div class="callout-title">${icon('shield')}需要你的确认 <span class="role-badge">普通风险</span></div><p class="callout-description">NewPi 想修改 <strong>1 个项目文件</strong>。本次演示未启用项目内自动允许。</p><code class="command-preview">edit · NewPiApp/MarkdownRenderer/markdown-renderer.js</code><p class="callout-description">影响：替换语义分块函数。可先查看差异；允许一次不会扩大为永久授权。</p><div class="callout-actions"><button type="button" class="quiet-button" data-action="changes">查看演示差异</button><button type="button" class="secondary-button" data-action="deny">拒绝</button><button type="button" class="accent-button" data-action="allow">允许一次</button></div></section>`;
  }
  function fixture(state) {
    const task = '修复 Markdown 输出结束时的小幅跳动。保持现有滚动架构，并补上列表、引用和代码块的回归验证。';
    if (scene === 'empty' && state.extras.length) return '<div class="day-divider">今天 · 新会话</div>';
    if (scene === 'empty') return `<section class="empty-state"><div class="empty-symbol">n·</div><p class="eyebrow">NEW SESSION / new-pi</p><h2>今天，我们从哪里开始？</h2><p>项目已就绪。描述一个问题、一处改动，<br>或者先一起理解这份代码。</p><div class="suggestions"><button type="button" class="suggestion" data-prompt="请先梳理这个项目的结构和主要入口。">${icon('folder')}理解项目结构<span>↗</span></button><button type="button" class="suggestion" data-prompt="检查最近的代码改动，先列出风险，不修改文件。">${icon('diff')}检查最近的改动<span>↗</span></button><button type="button" class="suggestion" data-prompt="帮我定位一个问题：">${icon('message')}一起定位问题<span>↗</span></button></div></section>`;
    if (scene === 'room') return `<div class="day-divider">今天 · 多模型协作</div>${userMessage('请讨论一个更安静、更适合长时间阅读的 NewPi 界面。先明确层级，不急着增加装饰。')}<div class="phase-divider">讨论阶段 · 第 1 轮</div>${assistantMessage('### 先把注意力留给答案\n\n建议区分三层信息：**用户目标 → 最终结果 → 执行细节**。正文采用中性阅读面，过程默认折叠；只有等待确认时，界面才需要明显提醒。\n\n项目身份和当前阶段留在顶部，不与模型用量混排。', '架构师', 'Claude Sonnet')}${assistantMessage('可以保持现有单文档 WebView。先统一 SwiftUI 外壳与文档的间距、颜色和字体变量，避免为了换外观重做滚动与会话保活。\n\n**建议先做一个主聊天界面切片，再验证窄窗口和深色模式。**', '程序员', 'GPT-5')}${state.nextSpeaker ? assistantMessage('### 评审结论\n\n方向可行。建议验收三件事：停止操作是否容易找到、审批范围是否清楚，以及用户上翻阅读时位置是否稳定。\n\n这是演示发言，没有请求模型。', '评审员', '本地模型') : ''}<div class="room-next"><span>${state.nextSpeaker ? '本轮演示讨论结束' : '下一位 · 评审员'}</span><button type="button" class="secondary-button" data-action="next-speaker"${state.nextSpeaker ? ' disabled' : ''}>让评审员发言 ${icon('arrowRight')}</button></div>`;
    if (scene === 'error') {
      const question = `<div class="day-divider">今天</div>${userMessage('帮我梳理一下项目结构，重点看会话与渲染模块。')}`;
      if (state.recovered) return question + assistantMessage('### 连接已模拟恢复\n\n项目可以分为 **NewPiCore 引擎**、**原生 App 外壳**和**单文档渲染器**。\n\n重试没有清除你的输入。这里是本地样例，没有访问模型或读取项目。');
      return question + `<section class="error-card"><div class="callout-title">${icon('warning')}${state.phase === 'running' ? '正在模拟重试' : '未能连接到模型'}</div><p class="callout-description">服务暂时不可用。你的输入和已有对话都还在，可以重试，或选择另一个模型。</p><code class="command-preview">演示错误 · connection_timeout · 未发送真实请求</code><div class="callout-actions"><button type="button" class="secondary-button" data-action="retry"${state.phase === 'running' ? ' disabled' : ''}>${icon('retry')}${state.phase === 'running' ? '重试中…' : '模拟重试'}</button></div></section>`;
    }
    const prefix = `<div class="day-divider">今天 · new-pi</div>${userMessage(task)}${process(scene === 'running', scene === 'running' ? state.phase : 'done')}`;
    if (scene === 'approval') return prefix + assistantMessage('已定位到空行分块与最终全文解析的差异。接下来准备调整渲染器，修改前请确认下面的操作。') + approval(state);
    if (scene === 'running') return prefix + assistantMessage('### 正在验证边界\n\n已准备松散列表、嵌套引用和围栏样例。接下来比较流式末帧与最终态的高度，以及上翻阅读时的锚点位置。\n\n你可以在下方继续编辑草稿，或停止本轮演示。') + (state.phase === 'running' && !state.timer ? '<button type="button" class="secondary-button" data-action="finish-run">模拟完成本轮</button>' : '');
    return prefix + assistantMessage(answer, 'NewPi', '', true) + `<div class="result-strip"><span>${icon('file')}<b>2</b> 个文件</span><span>${icon('check')}<b>19</b> 项演示检查</span><span>${icon('shield')}未修改滚动机制</span></div>`;
  }
  function enhanceContent() {
    $('#messages').querySelectorAll('pre').forEach(pre => {
      const container = document.createElement('div');
      container.className = 'code-block';
      const header = document.createElement('div');
      header.className = 'code-header';
      const code = pre.querySelector('code');
      const language = document.createElement('span');
      language.textContent = code?.className.replace('language-', '') || 'text';
      const copy = document.createElement('button');
      copy.type = 'button'; copy.textContent = '复制'; copy.dataset.action = 'copy-code';
      copy.setAttribute('aria-label', '复制代码');
      header.append(language, copy);
      pre.replaceWith(container); container.append(header, pre);
    });
    $('#messages').querySelectorAll('table').forEach(table => {
      const wrapper = document.createElement('div'); wrapper.className = 'table-scroll';
      table.replaceWith(wrapper); wrapper.append(table);
    });
  }
  function renderMessages(scroll = 'preserve') {
    const transcript = $('#transcript');
    const oldTop = transcript.scrollTop;
    const expanded = $('#process-details')?.open;
    const state = current();
    $('#messages').innerHTML = fixture(state) + state.extras.map(item => item.kind === 'user' ? userMessage(item.text, '刚刚') : assistantMessage(item.text)).join('');
    if (scroll === 'preserve' && expanded !== undefined && $('#process-details')) $('#process-details').open = expanded;
    enhanceContent();
    transcript.scrollTop = scroll === 'bottom' ? transcript.scrollHeight : scroll === 'top' ? 0 : oldTop;
    updateJump();
  }
  function updateControls() {
    const state = current();
    $('#run-status').textContent = state.status;
    $('#run-detail').textContent = state.detail;
    $('#status-indicator').dataset.status = state.phase;
    const running = state.phase === 'running';
    const pending = state.phase === 'approval';
    $('#primary-action').dataset.action = running ? 'stop' : 'send';
    $('#primary-action').innerHTML = icon(running ? 'stop' : 'arrowUp');
    $('#primary-action').setAttribute('aria-label', running ? '停止演示生成' : '发送演示消息');
    $('#primary-action').title = running ? '停止演示生成，保留草稿' : pending ? '先处理上方审批，草稿会保留' : '发送演示消息';
    $('#primary-action').disabled = !running && (pending || (!state.draft.trim() && !state.attachment));
    $('#model-select').disabled = running || pending;
    $('#input-hint').textContent = running || pending ? '可继续编辑草稿' : '↵ 发送 · ⇧↵ 换行';
    $('#message-input').placeholder = running ? '先写下一条消息，当前任务结束后发送…' : pending ? '等待确认期间，也可以继续编辑草稿…' : '继续提问，或告诉 NewPi 下一步做什么…';
    $('#attachment-strip').hidden = !state.attachment;
    $('#changes-button').hidden = scene === 'empty' || scene === 'room' || scene === 'error';
    const runningScene = memory.get('running');
    $('.nav-row[data-scene="running"] small').textContent = !runningScene || runningScene.phase === 'running' ? '今天 · 演示执行中' : runningScene.phase === 'stopped' ? '今天 · 已停止' : '今天 · 已完成';
  }
  function switchScene(id) {
    if (!scenes[id]) return;
    scene = id;
    const state = current();
    $('#scene-select').value = scene;
    $('#conversation-title').textContent = state.title;
    $('#mode-label').textContent = state.mode;
    $('#working-directory').textContent = state.path;
    $('#room-bar').hidden = scene !== 'room';
    $('#message-input').value = state.draft;
    $('#model-select').value = state.model;
    document.querySelectorAll('.nav-row').forEach(button => {
      const selected = button.dataset.scene === scene || (scene === 'approval' && button.dataset.scene === 'complete');
      if (selected) button.setAttribute('aria-current', 'page'); else button.removeAttribute('aria-current');
    });
    renderMessages('top'); updateControls();
  }
  function applyVariant(variant) {
    document.body.dataset.variant = variant;
    document.querySelectorAll('button[data-variant]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.variant === variant)));
    $('#variant-title').textContent = variant === 'document' ? '让答案回到中心。' : '保留对话感，减少干扰。';
    $('#variant-description').textContent = variant === 'document' ? '文档式阅读面 · 收敛的过程信息 · 一个完整的输入区' : '轻量消息气泡 · 中性的角色区分 · 相同的任务与交互';
    $('#variant-tag').textContent = variant === 'document' ? 'A / DOCUMENT' : 'B / CONVERSATION';
    requestAnimationFrame(updateJump);
  }
  function updateTheme() {
    document.body.dataset.theme = themePreference === 'system' ? (media.matches ? 'dark' : 'light') : themePreference;
  }
  function updateJump() {
    const el = $('#transcript');
    $('#jump-latest').hidden = !$('#messages .message') || el.scrollHeight - el.scrollTop - el.clientHeight < 70;
  }
  function showDialog(title, content) {
    dialogOpener = document.activeElement;
    $('#dialog-title').textContent = title;
    $('#dialog-content').innerHTML = content;
    $('#detail-dialog').showModal();
    $('#close-dialog').focus();
  }
  function showChanges() {
    showDialog('改动预览', '<p class="dialog-note">以下为用于评估排版的示意差异，并非读取你的工作区，也不是可应用的补丁。</p><div class="diff-file"><h3>NewPiApp/MarkdownRenderer/markdown-renderer.js</h3><pre class="diff-code"><span class="diff-removed">− splitAtBlankLines(source)</span><span class="diff-added">+ parseSemanticBlocks(source, environment)</span><span class="diff-added">+ preserveFrozenNodes(blocks)</span></pre></div><div class="diff-file"><h3>scripts/validation/TranscriptStreamingDOMChecks.swift</h3><pre class="diff-code"><span class="diff-added">+ looseListsAndNestedBlocks</span><span class="diff-added">+ referenceDefinitionChanges</span><span class="diff-added">+ finalizationGeometryChecks</span></pre></div><p class="dialog-note">生产版应展示真实文件路径、逐行差异和明确的恢复边界。</p>');
  }
  function stopRun() {
    const state = current();
    clearTimeout(state.timer); state.timer = null; state.phase = 'stopped';
    state.status = '本轮已停止'; state.detail = '草稿已保留';
    state.extras.push({ kind: 'assistant', text: '本轮演示已停止。**输入框中的草稿仍然保留**，你可以修改后继续发送。' });
    renderMessages('bottom'); updateControls();
  }
  function completeDemo(id) {
    const state = current(id); state.timer = null; state.phase = 'done';
    state.status = '演示回复已完成'; state.detail = '未调用模型';
    state.extras.push({ kind: 'assistant', text: '收到。这是一条**本地模拟回复**，用于体验发送、停止和连续阅读。\n\n切换 A/B 方案不会清空草稿或改变消息。模型选择与附件也仅用于界面演示。' });
    if (scene === id) { renderMessages('bottom'); updateControls(); }
  }
  function sendMessage() {
    const state = current();
    if (state.phase === 'running') { stopRun(); return; }
    if (state.phase === 'approval' || (!state.draft.trim() && !state.attachment)) return;
    state.extras.push({ kind: 'user', text: (state.draft.trim() || '请看这张参考图。') + (state.attachment ? '\n[演示附件：界面参考.png]' : '') });
    state.draft = ''; state.attachment = false; $('#message-input').value = '';
    state.phase = 'running'; state.status = '正在演示生成'; state.detail = '本地模拟 · 可随时停止';
    const id = scene;
    state.timer = setTimeout(() => completeDemo(id), 2200);
    renderMessages('bottom'); updateControls();
  }
  async function copyText(text) {
    try {
      await navigator.clipboard.writeText(text);
      toast('已复制到剪贴板');
    } catch (_) { toast('浏览器不允许复制，请选中文字后手动复制。'); }
  }

  document.addEventListener('click', event => {
    const button = event.target.closest('button');
    if (!button || button.disabled) return;
    if (button.dataset.variant) applyVariant(button.dataset.variant);
    if (button.dataset.scene) switchScene(button.dataset.scene);
    if (button.dataset.prompt) {
      current().draft = button.dataset.prompt; $('#message-input').value = current().draft;
      updateControls(); $('#message-input').focus();
    }
    const action = button.dataset.action;
    if (action === 'changes') showChanges();
    if (action === 'copy-answer') copyText(answer);
    if (action === 'copy-code') copyText(button.closest('.code-block').querySelector('code').textContent);
    if (action === 'allow' || action === 'deny') {
      current().decision = action; current().phase = 'done';
      current().status = action === 'allow' ? '已允许本次演示操作' : '已拒绝演示操作'; current().detail = '未执行任何文件操作';
      renderMessages('preserve'); updateControls(); $('#message-input').focus();
    }
    if (action === 'finish-run') completeDemo(scene);
    if (action === 'retry') {
      const state = current(), id = scene;
      state.phase = 'running'; state.status = '正在模拟重试'; state.detail = '不会发送网络请求';
      state.timer = setTimeout(() => {
        state.timer = null; state.recovered = true; state.phase = 'done';
        state.status = '连接演示已恢复'; state.detail = '未调用真实服务';
        if (scene === id) { renderMessages('bottom'); updateControls(); }
      }, 1200);
      renderMessages('preserve'); updateControls(); $('#message-input').focus();
    }
    if (action === 'next-speaker') {
      current().nextSpeaker = true; current().status = '本轮讨论已完成'; current().detail = '3 位角色 · 演示发言';
      renderMessages('bottom'); updateControls(); $('#message-input').focus();
    }
  });
  $('#messages').addEventListener('click', event => {
    if (event.target.closest('a')) { event.preventDefault(); toast('原型不打开正文中的外部链接。'); }
  });
  $('#scene-select').addEventListener('change', event => switchScene(event.target.value));
  $('#reset-scene').addEventListener('click', () => {
    clearTimeout(current().timer);
    memory.delete(scene); switchScene(scene);
    toast('当前场景已重置；其他场景的草稿不受影响。');
  });
  $('#theme-select').addEventListener('change', event => { themePreference = event.target.value; updateTheme(); });
  media.addEventListener('change', updateTheme);
  $('#width-toggle').addEventListener('click', () => {
    const narrow = document.body.dataset.width !== 'narrow';
    document.body.dataset.width = narrow ? 'narrow' : 'wide';
    $('#width-toggle').setAttribute('aria-pressed', String(narrow));
    $('#width-toggle').textContent = narrow ? '恢复宽窗口' : '窄窗口';
    requestAnimationFrame(updateJump);
  });
  $('#sidebar-toggle').addEventListener('click', () => {
    const collapsed = $('.app-window').classList.toggle('sidebar-collapsed');
    $('#sidebar-toggle').setAttribute('aria-expanded', String(!collapsed));
    $('#sidebar-toggle').setAttribute('aria-label', collapsed ? '展开侧边栏' : '收起侧边栏');
    requestAnimationFrame(updateJump);
  });
  $('#message-input').addEventListener('input', event => { current().draft = event.target.value; updateControls(); });
  $('#message-input').addEventListener('keydown', event => {
    if (event.key !== 'Enter' || event.isComposing || event.keyCode === 229 || event.shiftKey) return;
    event.preventDefault();
    // 编辑下一条草稿时 Return 不能意外变为 Stop；停止只由明确的按钮触发。
    if (current().phase !== 'running') sendMessage();
  });
  $('#composer-form').addEventListener('submit', event => { event.preventDefault(); sendMessage(); });
  $('#model-select').addEventListener('change', event => { current().model = event.target.value; toast('仅切换演示模型，不修改 Provider 配置。'); });
  $('#attach-button').addEventListener('click', () => { current().attachment = true; updateControls(); });
  $('#remove-attachment').addEventListener('click', () => { current().attachment = false; updateControls(); $('#attach-button').focus(); });
  $('#transcript').addEventListener('scroll', updateJump, { passive: true });
  new ResizeObserver(updateJump).observe($('#transcript'));
  $('#jump-latest').addEventListener('click', () => { $('#transcript').scrollTop = $('#transcript').scrollHeight; $('#transcript').focus(); });
  $('#changes-button').addEventListener('click', showChanges);
  $('#metrics-button').addEventListener('click', () => showDialog('本轮用量', '<p class="dialog-note">固定演示数据。默认只展示任务状态，详细指标按需查看。</p><div class="metric-grid"><div><span>输入 tokens</span><strong>12.4k</strong></div><div><span>输出 tokens</span><strong>2.1k</strong></div><div><span>缓存命中率</span><strong>86%</strong></div><div><span>上下文占用</span><strong>9%</strong></div></div><p class="dialog-note">设计原则：上下文接近上限或需要用户处理时，才提升提示级别。不能只用颜色表达风险。</p>'));
  $('#design-info').addEventListener('click', () => showDialog('关于这次设计', '<p><strong>A · 文档工作台</strong><br>把最终答案作为阅读中心，弱化气泡和过程容器。推荐用于较长的代码与技术说明。</p><p><strong>B · 轻量聊天</strong><br>保留左右对话关系，使用中性卡片而不是按轮次铺满彩色。适合偏好明确消息边界的用户。</p><p>两者共享演示内容、指标、草稿和操作。上方可切换场景、深浅色及窄窗口。</p><p class="dialog-note">这是 HTML 视觉原型，不是 macOS App。窗口装饰为示意，不模拟系统玻璃材质；生产方案仍保留 SwiftUI/AppKit 外壳和单文档 WKWebView。</p>'));
  $('#close-dialog').addEventListener('click', () => $('#detail-dialog').close());
  $('#detail-dialog').addEventListener('close', () => { if (dialogOpener?.isConnected) dialogOpener.focus(); });
  $('#detail-dialog').addEventListener('click', event => { if (event.target === $('#detail-dialog')) { const rect = event.target.getBoundingClientRect(); if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) event.target.close(); } });
  document.addEventListener('keydown', event => {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'n' && !$('#detail-dialog').open) {
      event.preventDefault(); switchScene('empty'); $('#message-input').focus();
    }
  });
  switchScene('complete');
  window.addEventListener('pagehide', () => { memory.forEach(state => clearTimeout(state.timer)); clearTimeout(toastTimer); });
})();