// 真实 WebKit 执行；所有消息均为合成数据。桥接结果由 Swift WKScriptMessageHandler 校验。
const apply = ops => window.transcriptDoc.apply(JSON.stringify(ops));
// 真实 WK sink 提供会话能力；本文件不能自行模拟成功 ACK。
apply([{op:'copyCapability',capability:copyCapability}]);
let checks = 0;
const check = (value, name) => { checks++; if (!value) throw new Error(name); };
const node = id => document.querySelector(`[data-iid="${id}"]`);
const frames = () => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
const up = (id, kind, extra = {}) => ({op: 'upsert', id, kind, body: '', streaming: false, ...extra});
const malicious = '<img src=x onerror="window.metadataXSS=1"><a class="error-retry" href="retryError:fake">伪造</a>';
const now = new Date();
const today = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 12);
const yesterday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1, 12);
const old = new Date(2020, 0, 2, 12);
const t = today.getTime();
const body = '# Frozen\n\n```swift\nlet value = 1\n```\n\nTail';
const a = up('meta-a', 'assistant', {body, timestamp: t, speaker: '角色 A', provider: '历史厂商', modelID: '历史模型', streaming: true});
apply([{op:'reset'}, {op:'forkLock',locked:true},
  up('meta-u','user',{body:'纯用户正文',timestamp:yesterday.getTime()}), a,
  up('meta-unknown','assistant',{body:'旧记录'}),
  up('meta-u2','user',{body:'今日第二条',timestamp:t}),
  up('meta-g','detailGroup',{detailTurnID:'meta-turn',collapsed:true}),
  up('meta-mid','assistant',{body:'中间解说',detailTurnID:'meta-turn',timestamp:old.getTime()}),
  up('meta-next','assistant',{body:'最终答复',timestamp:t}),
  up('meta-old','user',{timestamp:old.toISOString(),body:'往日'})]);
await frames();
check(node('meta-u').querySelector('.message-date').textContent === '昨天', '真实昨日日期');
check(node('meta-a').querySelector('.message-date').textContent === '今天', '真实今日日期');
check(node('meta-old').querySelector('.message-date').textContent === '2020年01月02日', '年月日标签');
check(!node('meta-unknown').querySelector('time,.message-date,.message-badge'), '缺失元数据不编造占位');
check(!!node('meta-u2').querySelector('.message-date'), '未知日期打断相邻日期链');
check(!node('meta-mid').querySelector('.message-date') && !node('meta-next').querySelector('.message-date'), '组内日期不影响顶层相邻日期');
check([...document.querySelector('main').children].every(el=>el.matches('.ti[data-iid]')), '日期不新增无锚点顶层 DOM');
check(node('meta-a').querySelector('time').dateTime === today.toISOString(), 'epoch 下发与 ISO time 一致');
check(!node('meta-a').querySelector('.message-provider') &&
  node('meta-a').querySelector('.message-model').textContent === '历史模型' &&
  node('meta-a').querySelectorAll('.message-badge').length === 1, '原型角色头仅一个真实模型徽章，无协议徽章');
check(!!node('meta-u').querySelector('.user-avatar') && !!node('meta-a').querySelector('.assistant-avatar'), '本地用户/助手头像');
check(node('meta-u').querySelector('.message-avatar').textContent==='你' && node('meta-a').querySelector('.message-avatar').textContent==='角', '真实角色首字，不统一显示星形');
apply([{op:'context',projectName:'new-pi',dateContext:'多模型协作'}]);
check(node('meta-a').querySelector('.message-date').textContent==='今天 · new-pi · 多模型协作', '明确原生上下文接入日期线');
apply([{op:'context'}]);
const article = node('meta-a').querySelector('article'), code = article.querySelector('pre code'), heading = article.firstElementChild;
const timeBefore = node('meta-a').querySelector('time').dateTime;
apply([{...a,speaker:malicious,provider:malicious,modelID:malicious}]);
check(article === node('meta-a').querySelector('article') && code === article.querySelector('pre code') && heading === article.firstElementChild,
  'metadata 更新不重建 Markdown root/冻结代码');
check(node('meta-a').querySelector('.message-speaker').textContent === malicious && !node('meta-a').querySelector('.message-hd img,a'), '元数据 textContent 转义');
apply([{...a,body:body+' growing'}]);
check(code === article.querySelector('pre code'), '流式续写保留冻结代码');
apply([{...a,body:body+' growing',streaming:false}]);
check(node('meta-a').querySelector('time').dateTime === timeBefore && article === node('meta-a').querySelector('article') &&
  article.querySelector('pre code').textContent === code.textContent, 'stream/final 保留时间/root/代码内容');
const finalCode = article.querySelector('pre code');
apply([{...a,body:body+' growing',streaming:false,provider:'更新历史字段'}]);
check(finalCode === article.querySelector('pre code'), '最终态 metadata 更新保留已高亮 code');
apply([{...a,streaming:false,timestamp:undefined,provider:undefined,modelID:undefined}]);
check(!node('meta-a').querySelector('time,.message-date,.message-badge'), '元数据可撤销且不留旧值');
for (const provider of ['openaiCompatible', 'anthropic', 'responses']) {
  apply([up('meta-session','assistant',{body:'普通会话正文',timestamp:t,provider,modelID:'deepseek-flash',streaming:true})]);
  const header = node('meta-session').querySelector('.message-hd');
  check(header.querySelector('.message-speaker').textContent === 'NewPi' &&
    !header.querySelector('.message-badge') && !!header.querySelector('time') &&
    !header.textContent.includes(provider), '普通会话按原型只显示身份/时间，不展示协议或重复模型徽章：'+provider);
  check(header.querySelector('.message-speaker').title === '回复模型：deepseek-flash', '历史模型仍可按需查看，不拿当前配置冒充');
  check(header.querySelector('.message-avatar').textContent==='n', '普通会话头像为 n');
}
apply([up('meta-session','assistant',{body:'普通会话正文',timestamp:t,provider:'openaiCompatible',modelID:'deepseek-flash',streaming:false})]);
check(!node('meta-session').querySelector('.message-badge'), '结束定稿不重新插入协议/模型徽章');
apply([up('meta-session','assistant',{body:'普通会话正文',timestamp:t})]);
check(!node('meta-session').querySelector('.message-speaker').title, '缺失历史模型不残留旧提示');
node('meta-u').querySelector('.ti-action-copy').click();

// 日期批量重排、删除及 UTC 日界在本地时区下归类。
const midnight1 = new Date(2020, 4, 2, 23, 59), midnight2 = new Date(2020, 4, 3, 0, 1);
apply([{op:'reset'},up('d1','user',{timestamp:midnight1.toISOString()}),up('d2','assistant',{timestamp:midnight2.getTime()}),
  up('d3','user',{timestamp:midnight2.getTime()})]);
check(node('d1').querySelector('.message-date').dataset.day === '2020-05-02' && node('d2').querySelector('.message-date').dataset.day === '2020-05-03', '本地午夜日界');
check(!node('d3').querySelector('.message-date'), '同日不重复日期');
apply([{op:'order',ids:['d3','d1','d2']}]);
check(!!node('d3').querySelector('.message-date') && !!node('d2').querySelector('.message-date'), '最终顺序重算日期');
apply([{op:'remove',id:'d1'}]);
check(!node('d2').querySelector('.message-date'), '删除相邻日界重算');
apply([up('d3','user',{timestamp:'invalid'})]);
check(!node('d3').querySelector('time,.message-date') && !!node('d2').querySelector('.message-date'), '非法日期无假值且重算邻居');

// 错误状态不使用计时器模拟；点击只允许真实创建的按钮。
apply([{op:'reset'},{op:'forkLock',locked:false},
  up('error-nil','error',{body:malicious}),
  up('error-unavailable','error',{body:'旧错误',retryState:'unavailable'}),
  up('error-available','error',{body:malicious,errorTitle:malicious,retryState:'available'}),
  up('error-retrying','error',{body:'待恢复',retryState:'retrying'}),
  up('error-recovered','error',{body:'原始错误',retryState:'recovered'}),
  up('error-unknown','error',{body:'未知',retryState:'unexpected'})]);
check(node('error-nil').querySelector('.error-title').textContent === '本轮未完成', '默认错误标题');
for (const id of ['error-nil','error-unavailable','error-recovered','error-unknown']) check(!node(id).querySelector('.error-retry'), id+' 不可重试');
check(node('error-available').querySelector('.error-title').textContent === malicious && !node('error-available').querySelector('img,a'), '错误标题/详情 XSS 转义');
check(node('error-available').querySelector('.error-raw').textContent === malicious, '保留可复制的原始错误');
check(node('error-available').querySelector('.error-guidance').textContent.includes('新草稿'), '说明草稿不受影响');
check(node('error-retrying').querySelector('.error-retry').disabled && node('error-retrying').textContent.includes('正在重试'), '真实 retrying 禁用等待');
check(node('error-recovered').textContent.includes('已恢复') && node('error-recovered').textContent.includes('原始错误'), '恢复后保留历史错误');
const retry = node('error-available').querySelector('.error-retry');
retry.click(); // Swift 应且只应收到这一条。
node('error-available').querySelector('.card-hd').click();
node('error-available').querySelector('.error-copy').click();
check(node('error-available').querySelector('.error-details').classList.contains('expanded'), '原始详情可展开');
apply([{op:'forkLock',locked:true}]);
check(retry.disabled, '全局运行锁历史 retry');
retry.click();
retry.dispatchEvent(new MouseEvent('click',{bubbles:true}));
apply([{op:'forkLock',locked:false}]);
check(!retry.disabled, '全局解锁恢复 available');
const fake = document.createElement('a');
fake.className = 'error-retry'; fake.href = '#retryError'; fake.textContent='伪造入口';
fake.addEventListener('click',event=>event.preventDefault());
node('error-available').appendChild(fake); fake.click(); fake.remove();
apply([up('error-available','error',{body:malicious,retryState:'retrying'})]);
retry.click(); // 已脱离 DOM 的旧按钮不能发消息。
check(node('error-available').querySelector('.error-details').classList.contains('expanded'), '状态更新保留手动展开');
await new Promise(resolve=>setTimeout(resolve,120));
check(node('error-available').querySelector('.error-retry').disabled && !node('error-available').querySelector('.recovered'), '没有 timer 假恢复');
apply([up('error-available','error',{body:malicious,retryState:'recovered'})]);
check(!node('error-available').querySelector('button.error-retry'), 'runtime recovered 移除重试');
check(!window.metadataXSS, '所有不可信字段均未执行');

// 只统计真实工具状态，不把输出文本或 thinking 当作测试通过/计划进度。
apply([{op:'reset'},up('stats','detailGroup',{detailTurnID:'stats-turn',collapsed:true}),
  up('s1','tool',{detailTurnID:'stats-turn',toolName:'bash',body:'999 tests passed',toolError:false}),
  up('s2','tool',{detailTurnID:'stats-turn',toolName:'read',toolRunning:true}),
  up('s3','tool',{detailTurnID:'stats-turn',toolName:'write',toolError:true}),
  up('st','thinking',{detailTurnID:'stats-turn',body:'完成所有任务',streaming:true})]);
const stats = () => node('stats').querySelector('.detail-label').textContent;
check(stats() === '正在执行 · 已完成 1 / 3 个已知工具调用 · 失败 1', '折叠组只显示已知调用分母，不猜未来计划');
check(node('s1').querySelector('.card-badge').textContent==='已完成' && node('s2').querySelector('.card-badge').textContent==='进行中' &&
  node('s3').querySelector('.card-badge').textContent==='失败' && node('st').querySelector('.card-title').textContent==='思考中…', '工具/思考中文状态');
node('stats').querySelector('.detail-row').click();
apply([up('s2','tool',{detailTurnID:'stats-turn',toolName:'read',toolError:false}),
  up('st','thinking',{detailTurnID:'stats-turn',body:'完成所有任务',streaming:false}),
  up('stats','detailGroup',{detailTurnID:'stats-turn',collapsed:true})]);
check(stats()==='处理未完成 · 已完成 2 / 3 个已知工具调用 · 失败 1', '仅工具完成状态改变数量');
check(!node('s1').classList.contains('detail-hidden'), '保留组的手动展开');
node('stats').querySelector('.detail-row').click();
apply([up('s1','tool',{detailTurnID:'stats-turn',toolName:'bash',body:'输出增长'})]);
check(node('s1').classList.contains('detail-hidden'), '组内重渲染不能意外展开');
apply([{op:'remove',id:'s3'}]);
check(stats()==='处理过程 · 已完成 2 / 2 个已知工具调用', '删除工具重算统计');
check(node('stats').querySelector('.detail-row').lastElementChild.classList.contains('detail-chevron') &&
  !!node('stats').querySelector('.detail-status .icon-done svg'), '汇总 SVG 完成图标与右侧 disclosure');
apply([up('s2','tool',{detailTurnID:'stats-turn',toolName:'read',toolRunning:true,interrupted:true,command:'source.swift',durationSeconds:1.25})]);
check(stats()==='已停止 · 已完成 1 / 2 个已知工具调用 · 保留 1 个已完成步骤', '停止保留已完成步骤且分母不变');
check(node('s2').querySelector('.card').dataset.status==='stopped' && !!node('s2').querySelector('.icon-stopped svg') &&
  node('s2').querySelector('.card-title').textContent==='读取文件' && node('s2').querySelector('.card-preview').textContent==='source.swift' &&
  node('s2').querySelector('.card-duration').textContent==='1.25s', '停止工具语义标题、命令副标题、有限耗时与 SVG');
apply([up('s2','tool',{detailTurnID:'stats-turn',toolName:'read',toolRunning:true,interrupted:true,toolError:true,durationSeconds:Infinity})]);
check(node('s2').querySelector('.card').dataset.status==='error' && node('s2').querySelector('.card-duration').textContent==='—' &&
  stats().includes('失败 1'), '真实失败不得被停止覆盖，非法耗时不显示');
apply([up('phase-real','system',{body:'讨论阶段',phaseDivider:true}),up('phase-prose','system',{body:'讨论阶段 · 第 999 轮'})]);
check(!!node('phase-real').querySelector('.phase-divider') && !node('phase-real').querySelector('.phase-round') &&
  !node('phase-prose').querySelector('.phase-divider'), '只有显式阶段元数据产生阶段线，不从 prose 造轮次');

// 消息级复制去重：真实 DOM/可交互语义 + WK 桥原始 payload，不把代码块复制计为消息复制。
window.expectedActionCopies = [];
window.expectedActionForks = [];
const messageCopies = id => [...node(id).querySelectorAll('button.ti-action-copy, button.answer-copy')];
const interactive = button => button.isConnected && !button.disabled && button.tabIndex >= 0 &&
  !button.closest('[hidden], [inert], [aria-hidden="true"], .detail-hidden') &&
  getComputedStyle(button).display !== 'none' && getComputedStyle(button).visibility === 'visible';
const copyShape = (id, footer, fork = true) => {
  const row = node(id), copies = messageCopies(id);
  check(copies.length === 1 && copies.filter(interactive).length === 1, id+' 恰好一个真实且可交互的消息复制入口');
  check(row.querySelectorAll('.answer-footer').length === (footer ? 1 : 0) &&
    row.querySelectorAll('.ti-action-copy').length === (footer ? 0 : 1) &&
    row.querySelectorAll('.answer-copy').length === (footer ? 1 : 0), id+' 按实际 footer 移除/恢复顶部复制，而非 CSS 隐藏');
  const top = row.querySelector('.ti-actions');
  check(top.children.length === (footer ? 0 : 1) + (fork ? 1 : 0) &&
    top.querySelectorAll('.ti-action-fork').length === (fork ? 1 : 0), id+' 顶部保留独立 Fork');
  if (footer) check(row.querySelector('.answer-copy').textContent === '复制回答' &&
    row.querySelectorAll('.answer-actions button').length === 1, id+' 底部仅保留复制回答');
  check(!document.querySelector('.answer-changes, .approval-preview, .changes-dialog, .icon-diff') &&
    ![...document.querySelectorAll('button, [role="button"]')].some(el => ['改动','查看改动','查看差异'].includes(el.textContent.trim())),
    id+' 重建及状态切换后不恢复已删除动作');
};
const copyRaw = (id, source) => {
  window.expectedActionCopies.push(source);
  messageCopies(id)[0].click();
};
const raw = '**未闭合原始 source <>&\n\n```text\nraw only';
const actionA = up('copy-a', 'assistant', {body:raw, answerState:'final', canFork:true, messageIndex:7});
const actionB = up('copy-b', 'assistant', {body:'**第二个 final**', answerState:'final', canFork:true, messageIndex:8});
const actionUser = up('copy-user', 'user', {body:'用户 **原文** <>&', canFork:true, messageIndex:6});
apply([{op:'reset'}, actionUser, {...actionA, streaming:true}]);
copyShape('copy-user', false); copyRaw('copy-user', actionUser.body);
copyShape('copy-a', false); copyRaw('copy-a', raw);
check(node('copy-a').querySelector('.ti-action-fork').disabled, 'stream 保留复制但禁止 Fork');
const oldTopCopy = node('copy-a').querySelector('.ti-action-copy');
const retainedFork = node('copy-a').querySelector('.ti-action-fork');
apply([actionA]);
copyShape('copy-a', true); copyRaw('copy-a', raw);
check(node('copy-a').querySelector('.ti-action-fork') === retainedFork && !retainedFork.disabled,
  'stream → final 不重建 Fork 且按元数据解锁');
retainedFork.click(); window.expectedActionForks.push(7);
const actionArticle = node('copy-a').querySelector('article'), actionCode = actionArticle.querySelector('code');
const firstFooter = node('copy-a').querySelector('.answer-footer'), firstFooterCopy = firstFooter.querySelector('.answer-copy');
for (let i=0; i<3; i++) {
  apply([{...actionA, speaker:'元数据 '+i, modelID:'model-'+i, timestamp:t+i}]);
  copyShape('copy-a', true);
  check(node('copy-a').querySelector('.answer-footer') === firstFooter &&
    node('copy-a').querySelector('article') === actionArticle && actionArticle.querySelector('code') === actionCode,
    'metadata-only 不重插顶部复制、不重建 footer/正文/代码');
}
// 旧顶部按钮即使重新接入另一条消息，也不能获得那条消息的 source。
oldTopCopy.click();
node('copy-user').querySelector('.bubble').append(oldTopCopy); oldTopCopy.click(); oldTopCopy.remove();
for (let i=0; i<3; i++) {
  apply([{...actionA, answerState:'incomplete'}]);
  copyShape('copy-a', false); copyRaw('copy-a', raw);
  const restoredCopy = node('copy-a').querySelector('.ti-action-copy');
  apply([{...actionA, answerState:'incomplete', speaker:'仅署名'}]);
  check(node('copy-a').querySelector('.ti-action-copy') === restoredCopy, 'incomplete metadata-only 幂等复用复制');
  apply([actionA]);
  copyShape('copy-a', true); copyRaw('copy-a', raw);
  check(node('copy-a').querySelector('.ti-action-fork') === retainedFork, 'final 往返保留顶部 Fork 身份');
  node('copy-user').append(restoredCopy); restoredCopy.click(); restoredCopy.remove();
}
firstFooterCopy.click();
node('copy-user').append(firstFooter); firstFooterCopy.click(); firstFooter.remove();
apply([{...actionA, canFork:false, messageIndex:undefined}]);
copyShape('copy-a', true, false);
apply([{...actionA, messageIndex:9}]);
copyShape('copy-a', true);
node('copy-a').querySelector('.ti-action-fork').click(); window.expectedActionForks.push(9);
apply([{...actionA, answerState:'incomplete'}, actionA]);
copyShape('copy-a', true);
const sameFooter = node('copy-a').querySelector('.answer-footer');
apply([{...actionA, body:raw+'\n续写'}]);
copyShape('copy-a', true); copyRaw('copy-a', raw+'\n续写');
check(node('copy-a').querySelector('.answer-footer') === sameFooter, 'footer 复用时复制读取最新原文，而不是创建时正文');
apply([actionA]);

// 同 scope 后一个 final 接管 footer；scope 改动与 order/remove 都要恢复失去 footer 的消息复制。
apply([actionB]);
copyShape('copy-a', false); copyShape('copy-b', true);
copyRaw('copy-a', raw); copyRaw('copy-b', actionB.body);
apply([{...actionA, speaker:'被替换 final 的元数据'}]);
copyShape('copy-a', false); copyShape('copy-b', true);
apply([{...actionA, resultScopeID:'role-a:speech-1'}, {...actionB, resultScopeID:'role-a:speech-1'}]);
copyShape('copy-a', false); copyShape('copy-b', true);
apply([{...actionB, resultScopeID:'role-b:speech-1'}]);
copyShape('copy-a', true); copyShape('copy-b', true);
apply([actionA, actionB]);
copyShape('copy-a', false); copyShape('copy-b', true);
apply([{op:'order',ids:['copy-user','copy-b','copy-a']}]);
copyShape('copy-b', false); copyShape('copy-a', true);
apply([{op:'remove',id:'copy-a'}]);
copyShape('copy-b', true);

// 多轮各自保留 footer；summary、中间/未知状态及带详情归属的 final 不能丢复制。
apply([up('copy-user2','user',{body:'第二轮'}), actionA,
  up('copy-summary','summary',{body:'摘要 **原文**'}),
  up('copy-middle','assistant',{body:'中间原文',answerState:'intermediate'}),
  up('copy-unknown','assistant',{body:'旧记录'}),
  up('copy-detail','assistant',{body:'详情原文',answerState:'final',detailTurnID:'copy-turn'}),
  up('copy-group','detailGroup',{detailTurnID:'copy-turn',collapsed:false})]);
copyShape('copy-b', true); copyShape('copy-a', true); copyShape('copy-user2', false, false);
for (const [id, source] of [['copy-summary','摘要 **原文**'],['copy-middle','中间原文'],['copy-unknown','旧记录'],['copy-detail','详情原文']]) {
  copyShape(id, false, false); copyRaw(id, source);
}
apply([{...actionA, streaming:true}]);
copyShape('copy-a', false); copyRaw('copy-a', raw);
apply([actionA]); copyShape('copy-a', true);
apply([{op:'forkLock',locked:true}]);
copyShape('copy-a', true); copyRaw('copy-a', raw);
check(node('copy-a').querySelector('.ti-action-fork').disabled, '全局锁只禁 Fork，不禁复制');
apply([{op:'forkLock',locked:false}]);

// kind 切换重建以及 reset 后同 ID 新 state：旧 capability 不得回退到 DOM class/data-iid。
const retiredFooter = node('copy-a').querySelector('.answer-footer');
apply([{...actionA, kind:'summary', body:'换 kind 摘要'}]);
copyShape('copy-a', false); copyRaw('copy-a', '换 kind 摘要');
const retiredSummaryCopy = node('copy-a').querySelector('.ti-action-copy');
apply([{...actionA, kind:'user', body:'换 kind 用户'}]);
copyShape('copy-a', false); copyRaw('copy-a', '换 kind 用户');
apply([actionA]); copyShape('copy-a', true); copyRaw('copy-a', raw);
node('copy-a').append(retiredFooter, retiredSummaryCopy);
retiredFooter.querySelector('.answer-copy').click(); retiredSummaryCopy.click();
retiredFooter.remove(); retiredSummaryCopy.remove();
const retiredFinal = node('copy-a').querySelector('.answer-footer');
apply([{...actionB, answerState:'incomplete'}]);
const retiredStateCopy = node('copy-b').querySelector('.ti-action-copy');
apply([{op:'reset'}, actionUser, {...actionA, body:'重建 **原文**'}, {...actionB, answerState:'incomplete'}]);
copyShape('copy-user', false); copyShape('copy-a', true); copyShape('copy-b', false);
copyRaw('copy-a', '重建 **原文**'); copyRaw('copy-b', actionB.body);
node('copy-a').append(retiredFinal); retiredFinal.querySelector('.answer-copy').click(); retiredFinal.remove();
node('copy-b').append(retiredStateCopy); retiredStateCopy.click(); retiredStateCopy.remove();
// clone 无 WeakMap 能力，恶意 HTML/class 也不能成为消息动作。
for (const selector of ['.ti-action-copy', '.ti-action-fork']) {
  const forged = node('copy-user').querySelector(selector).cloneNode(true);
  node('copy-user').append(forged); forged.click(); forged.remove();
}
await frames(); // Swift 校验所有复制/分叉数量及 payload，旧节点和伪造按钮必须零回传。

// 使用 Core 的真实报告字段，不从正文、工具成功或当前全局运行态推断计划/测试。
const planReport = steps => ({source:'agentReport', steps});
const planStep = (id, status, title = id) => ({id, title, status});
const junitReport = (path, passed, failed, skipped) => ({source:'JUnit', path, passed, failed, skipped, total:passed+failed+skipped});
const planSummary = id => node(id).querySelector('.plan-summary').textContent;
const testSummary = id => node(id).querySelector('.result-test-summary')?.textContent;
const reportText = id => node(id).querySelector('.result-strip').textContent;
const noReport = id => !node(id).querySelector('.result-test-summary, .result-test-source, .result-test-notice');
const declaredPlan = planReport([planStep('read','completed'),planStep('fix','inProgress'),planStep('verify','pending')]);
const planTool = up('plan-tool','tool',{toolName:'update_plan',detailTurnID:'report-turn',body:'计划原文',toolError:false,progressReport:declaredPlan});
const reportTool = up('report-tool','tool',{toolName:'read_test_report',detailTurnID:'report-turn',body:'报告原文',toolError:false,
  testReport:junitReport('results.xml',4,1,2)});
const reportAnswer = up('report-answer','assistant',{body:'## 报告回答\n\n```swift\nlet a = 1\n```',answerState:'final'});
const reportGroup = up('report-group','detailGroup',{detailTurnID:'report-turn',collapsed:false});
apply([{op:'reset'},up('report-user','user'),reportGroup,
  up('prose-tool','tool',{toolName:'bash',body:'999 tests passed; all tasks completed',detailTurnID:'report-turn'}),reportAnswer]);
check(planSummary('report-group').includes('未提供计划') && !planSummary('report-group').includes('0/0'), '没有计划是未知，不借工具计数伪造进度');
check(noReport('report-answer') && !reportText('report-answer').includes('999'), '无报告不显示占位提示，不把 stdout 成功当测试零失败');
apply([planTool,reportTool,{op:'order',ids:['report-user','report-group','prose-tool','plan-tool','report-tool','report-answer']}]);
check(planSummary('report-group')==='Agent计划（自报） · 1/3', '计划分子来自 completed，不来自三个成功工具');
check([...node('report-group').querySelectorAll('.plan-row')].map(el=>el.dataset.status).join(',')==='completed,inProgress,pending', '逐行保留三种真实输入状态');
check(node('report-group').querySelectorAll('.plan-row svg').length===3 && !!node('report-group').querySelector('.icon-pending'), '计划行复用本地图标，pending 不是完成图标');
check(node('report-group').querySelector('.detail-label').textContent.includes('3 / 3 个已知工具调用'), '工具保留自己的计数');
check(testSummary('report-answer')==='JUnit 报告汇总：通过 4 · 失败 1 · 跳过 2', 'JUnit 显式三种结果计数');
check(node('report-tool').querySelector('.card').dataset.status==='done' && !node('report-tool').querySelector('.is-error') &&
  !!node('report-answer').querySelector('.result-test-summary .icon-error'), '报告测试失败不等于读取报告工具失败');
check(reportText('report-answer').includes('JUnit · results.xml') && reportText('report-answer').includes('不保证报告新鲜度或对应当前代码'), '报告含路径来源和非新鲜度保证');
check(node('report-answer').querySelector('.answer-actions').nextElementSibling.classList.contains('result-strip'), '报告在动作行之后，不替换正文或复制入口');
const reportArticle = node('report-answer').querySelector('article'), reportCode = reportArticle.querySelector('code');
const toolCardBefore = node('report-tool').querySelector('.card');
apply([{...reportTool,testReport:junitReport('results.xml',0,2,3)}]);
check(testSummary('report-answer')==='JUnit 报告汇总：通过 0 · 失败 2 · 跳过 3' && node('report-tool').querySelector('.card')===toolCardBefore,
  '仅报告元数据变化更新 footer，不依赖 body/tool 状态变化');
check(node('report-answer').querySelector('article')===reportArticle && reportArticle.querySelector('code')===reportCode, '报告变化不重建回答和冻结代码');
const revisedPlan = planReport([planStep('fix','completed',malicious),planStep('verify','pending')]);
const latestPlanTool = {...planTool,progressReport:revisedPlan};
apply([latestPlanTool]);
check(planSummary('report-group')==='Agent计划（自报） · 1/2' && node('report-group').querySelectorAll('.plan-row').length===2, '元数据单独更新以完整计划替换旧行，不累加');
check(node('report-group').querySelector('.plan-title').textContent===malicious && !node('report-group').querySelector('img,a'), '计划标题转义，不能注入动作');
apply([up('plan-new','tool',{toolName:'update_plan',detailTurnID:'report-turn',progressReport:planReport([planStep('new','pending')])})]);
check(planSummary('report-group')==='Agent计划（自报） · 0/1', '同一 turn 最后声明优先，已知零完成不变成未知');
apply([{op:'remove',id:'plan-new'}]);
check(planSummary('report-group')==='Agent计划（自报） · 1/2', '删除最后声明回退剩余最新计划');
apply([{...planTool,progressReport:planReport([])}]);
check(planSummary('report-group').includes('总数未知') && !node('report-group').querySelector('.plan-row') && !planSummary('report-group').includes('0/0'), '空计划分母未知，不显示 0/0 或完成');
apply([{...planTool,progressReport:planReport([planStep('bad','unexpected')])}]);
check(planSummary('report-group').includes('未提供计划'), '未知状态不伪造 pending 或 completed');
apply([planTool]);
const savedPlanRows = node('report-group').querySelector('.plan-steps');
apply([{op:'forkLock',locked:true},{op:'forkLock',locked:false}]);
check(node('report-group').querySelector('.plan-steps')===savedPlanRows && planSummary('report-group')==='Agent计划（自报） · 1/3', '停止不改写最后声明的计划或把剩余步骤标完成');
apply([up('next-user','user'),up('next-group','detailGroup',{detailTurnID:'next-turn',collapsed:false}),
  up('next-tool','tool',{toolName:'bash',toolRunning:true,detailTurnID:'next-turn'}),{op:'forkLock',locked:true}]);
check(node('report-group').querySelector('.plan-steps')===savedPlanRows && planSummary('next-group').includes('未提供计划'), '新一轮不复活旧计划，也不继承其计划');
apply([{op:'forkLock',locked:false},up('next-tool','tool',{toolName:'bash',interrupted:true,toolRunning:true,detailTurnID:'next-turn'}),
  up('next-answer','assistant',{body:'下一轮',answerState:'final'})]);
check(noReport('next-answer'), '同路径报告也不能跨用户轮次继承');

// 同 scope 同路径只取最新读取，不累加重复 testcase；其他路径累加。
const repeatReport = up('report-repeat','tool',{toolName:'read_test_report',detailTurnID:'report-turn',testReport:junitReport('results.xml',6,0,1)});
const otherReport = up('report-other','tool',{toolName:'read_test_report',detailTurnID:'report-turn',testReport:junitReport('other.xml',2,1,0)});
const replay = [up('report-user','user'),reportGroup,planTool,reportTool,repeatReport,otherReport,reportAnswer];
apply([{op:'reset'},...replay]);
check(testSummary('report-answer')==='JUnit 报告汇总：通过 8 · 失败 1 · 跳过 1' && node('report-answer').querySelectorAll('.result-test-source').length===2, '路径去重后汇总，不重复累加旧读取');
apply([{...repeatReport,testReport:undefined},{...otherReport,testReport:undefined}]);
check(testSummary('report-answer')==='JUnit 报告汇总：通过 4 · 失败 1 · 跳过 2', '元数据撤回重算，回退该路径已有报告');
apply([{...reportTool,testReport:undefined}]);
check(noReport('report-answer'), '撤回全部报告不能残留计数、来源或空提示');
apply([{...reportTool,testReport:junitReport('empty.xml',0,0,0)}]);
check(testSummary('report-answer')==='JUnit 报告汇总：通过 0 · 失败 0 · 跳过 0' && reportText('report-answer').includes('JUnit · empty.xml'), '真实空报告的零与未提供区分，不称全部通过');
apply([{...reportTool,testReport:{...junitReport('invalid.xml',0,0,0),passed:-1}}]);
check(!testSummary('report-answer'), '非法计数不造零');
apply([{...reportTool,testReport:junitReport(malicious,1,0,0)}]);
check(node('report-answer').querySelector('.result-test-source').textContent.includes(malicious) && !node('report-answer').querySelector('.result-strip img,a'), '报告路径 textContent 转义');

// 传输快照复制/冷重放保留字段；这是 JS payload 回归，不替代 Swift copying 的原生测试。
const copiedReplay = JSON.parse(JSON.stringify(replay)).map(op=>({...op}));
check(JSON.stringify(copiedReplay[2].progressReport)===JSON.stringify(planTool.progressReport) &&
  JSON.stringify(copiedReplay[3].testReport)===JSON.stringify(reportTool.testReport), '复制传输快照保留两种报告');
apply([{op:'reset'},...copiedReplay.slice(0,-1),{...reportAnswer,streaming:true,answerState:undefined}]);
check(planSummary('report-group')==='Agent计划（自报） · 1/3' && !node('report-answer').querySelector('.answer-footer'), 'live 计划保留，流式正文不冒充最终结果');
apply([{...reportGroup,collapsed:true},reportAnswer]);
const finalReportText = reportText('report-answer'), finalPlanText = planSummary('report-group');
check(getComputedStyle(node('report-group').querySelector('.plan-steps')).display==='none' &&
  getComputedStyle(node('report-group').querySelector('.plan-summary')).display!=='none', 'final 收起步骤但保留明确自报摘要');
apply([{op:'reset'},...copiedReplay.map(op=>op.id==='report-group'?{...op,collapsed:true}:op)]);
check(reportText('report-answer')===finalReportText && planSummary('report-group')===finalPlanText, 'final 与冷重放计划/报告一致');

// 聊天室交错角色、用户插话及同角色不同 speech 必须独立。
const roomPlan = (id, turn, scope, title) => up(id,'tool',{toolName:'update_plan',detailTurnID:turn,resultScopeID:scope,progressReport:planReport([planStep(title,'pending')])});
const roomReport = (id, turn, scope, passed) => up(id,'tool',{toolName:'read_test_report',detailTurnID:turn,resultScopeID:scope,testReport:junitReport('shared.xml',passed,0,0)});
const roomAnswer = (id, scope) => up(id,'assistant',{body:id,answerState:'final',resultScopeID:scope});
apply([{op:'reset'},up('room-ga','detailGroup',{detailTurnID:'speech-a',collapsed:false}),
  roomPlan('room-pa','speech-a','role-a:speech-a','A计划'),roomReport('room-ta','speech-a','role-a:speech-a',3),
  up('room-gb','detailGroup',{detailTurnID:'speech-b',collapsed:false}),
  roomPlan('room-pb','speech-b','role-b:speech-b','B计划'),roomReport('room-tb','speech-b','role-b:speech-b',7),
  up('room-interruption','user',{body:'用户插话'}),roomAnswer('room-ab','role-b:speech-b'),roomAnswer('room-aa','role-a:speech-a'),
  roomAnswer('room-aa2','role-a:speech-a2')]);
check(testSummary('room-aa').includes('通过 3') && testSummary('room-ab').includes('通过 7') &&
  noReport('room-aa2'), '同路径报告按 role+speech 隔离，插话不重置旧发言');
check(node('room-ga').querySelector('.plan-title').textContent==='A计划' && node('room-gb').querySelector('.plan-title').textContent==='B计划', '交错计划按 detailTurnID 隔离');
apply([roomReport('room-ta','speech-a','role-a:speech-a',9)]);
check(testSummary('room-aa').includes('通过 9') && testSummary('room-ab').includes('通过 7'), '聊天室报告元数据单独更新不污染另一角色');
apply([roomReport('room-late','speech-a','role-a:speech-a',11)]);
check(testSummary('room-aa').includes('通过 11') && testSummary('room-ab').includes('通过 7'), 'final 之后到达的同 scope 报告仍参与最新路径去重');
apply([{op:'order',ids:['room-ga','room-pa','room-late','room-ta','room-gb','room-pb','room-tb','room-interruption','room-ab','room-aa','room-aa2']}]);
check(testSummary('room-aa').includes('通过 9'), '重排后按最终文档顺序选择最新报告');
check(!window.metadataXSS, '计划与报告路径均未执行 HTML');

// 元数据、日期和统计改变视口上方布局，必须在同批保锚之前完成。
const history = Array.from({length:40},(_,i)=>up('anchor-'+i,'user',{body:'历史 '+i+'\n'+'line\n'.repeat(5)}));
apply([{op:'reset'},...history]);
await new Promise(resolve=>setTimeout(resolve,250));
apply([{op:'restoreAnchor',id:'anchor-15',delta:12}]);
await frames();
window.dispatchEvent(new WheelEvent('wheel',{deltaY:-1}));
await frames(); // 让滚动中的 Poller 建立视口上方高度基线。
const before = node('anchor-15').getBoundingClientRect().top;
apply([{...history[14],timestamp:old.getTime(),speaker:'新增元数据 '+ '很长的署名'.repeat(12)},
  {...history[15],timestamp:t}, {op:'forkLock',locked:true}, up('tail','assistant',{body,streaming:true,timestamp:t})]);
check(Math.abs(node('anchor-15').getBoundingClientRect().top-before)<1, '日期/署名修改同步保锚，不能依赖后续 RAF 补救');
const tailRoot = node('tail').querySelector('article');
apply([up('tail','assistant',{body:body+'\n\nMore',streaming:true,timestamp:t})]);
apply([up('tail','assistant',{body:body+'\n\nMore',streaming:false,timestamp:t})]);
await frames();
check(Math.abs(node('anchor-15').getBoundingClientRect().top-before)<1 && tailRoot===node('tail').querySelector('article'), '上翻阅读期间 stream/final 同节点保锚');
return `PASS: metadata/dates/errors/retry/tools/message-copy lifecycle WebKit ${checks} assertions`;