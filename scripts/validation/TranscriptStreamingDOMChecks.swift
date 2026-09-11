import AppKit
import WebKit

/// 加载真实 JS/CSS 的 WKWebView 检查，不发送模型请求、不触碰用户会话。
@MainActor
final class TranscriptStreamingDOMChecks: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
        styleMask: [.borderless], backing: .buffered, defer: false)
    let root: URL

    init(root: URL) {
        self.root = root
        super.init()
        webView.navigationDelegate = self
        window.contentView = webView
    }

    func run() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("NewPiApp/MarkdownRenderer")
        try FileManager.default.copyItem(at: source, to: root.appendingPathComponent("renderer"))
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <link rel="stylesheet" href="renderer/github-markdown-light.css">
        <link rel="stylesheet" href="renderer/highlight-github.min.css">
        <link rel="stylesheet" href="renderer/markdown-renderer.css">
        <link rel="stylesheet" href="renderer/transcript-document.css">
        </head><body><main id="transcript"></main>
        <script src="renderer/markdown-it.min.js"></script><script src="renderer/highlight.min.js"></script>
        <script src="renderer/markdown-renderer.js"></script><script src="renderer/transcript-document.js"></script>
        </body></html>
        """
        let file = root.appendingPathComponent("index.html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        NSApp.setActivationPolicy(.accessory)
        window.orderBack(nil)
        webView.loadFileURL(file, allowingReadAccessTo: root)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let script = #"""
        const apply = ops => window.transcriptDoc.apply(JSON.stringify(ops));
        const check = (condition, name) => { if (!condition) throw new Error(name); };
        const node = id => document.querySelector(`[data-iid="${id}"]`);
        // 产品已关闭正文 ✦ 光标；检查真实渲染函数调用，不依赖光标是否存在。
        const renders = {streaming:0, final:0};
        const originalCreate = window.createMarkdownRenderer;
        window.createMarkdownRenderer = (...args) => {
          const renderer = originalCreate(...args);
          const stream = renderer.renderStreaming.bind(renderer), final = renderer.renderFinal.bind(renderer);
          renderer.renderStreaming = body => { renders.streaming++; return stream(body); };
          renderer.renderFinal = body => { renders.final++; return final(body); };
          return renderer;
        };
        apply([
          {op:'reset'}, {op:'forkLock',locked:true},
          {op:'upsert',id:'group',kind:'detailGroup',detailTurnID:'speech',collapsed:false,body:''},
          {op:'upsert',id:'thinking',kind:'thinking',detailTurnID:'speech',body:'Reasoning',streaming:true},
          {op:'upsert',id:'answer',kind:'assistant',speaker:'Role A',body:'A paragraph',streaming:true},
          {op:'upsert',id:'user',kind:'user',body:'User steering',streaming:false}
        ]);
        await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
        const answer = node('answer');
        check(renders.streaming === 1 && renders.final === 0, 'non-last assistant must stream');
        check(!node('thinking').classList.contains('detail-hidden'), 'steering must not collapse active group');
        node('thinking').querySelector('.card-hd').click();
        apply([
          {op:'upsert',id:'thinking',kind:'thinking',detailTurnID:'speech',body:'Reasoning finished',streaming:false},
          {op:'upsert',id:'answer',kind:'assistant',speaker:'Role A',body:'A paragraph grows\n\n```swift\nlet x = 1',streaming:true}
        ]);
        check(node('answer') === answer, 'assistant DOM must retain identity');
        check(renders.streaming === 2 && renders.final === 0, 'subsequent update must remain streaming');
        check(node('thinking').querySelector('.card').classList.contains('expanded'), 'manual expansion must persist');
        apply([{op:'upsert',id:'answer',kind:'assistant',speaker:'Role A',body:'A paragraph grows\n\n```swift\nlet x = 1\n```',streaming:false}]);
        check(renders.final === 1, 'message end must freeze before run ends');
        check(!answer.querySelector('.streaming-caret'), 'must not reintroduce disabled caret');
        check(answer.style.height === '', 'message end must retain natural height');
        check(!!answer.querySelector('pre code'), 'final markdown must retain code block');
        check(node('user').textContent.includes('User steering'), 'user steering must not disappear');
        apply([{op:'forkLock',locked:false}]);
        // 单文档最终渲染不能读取不用的旧高度；遗留高度上报模式仍保持测量。
        for (const reportHeight of [false, true]) {
          const article=document.createElement('article');
          document.body.appendChild(article);
          let reads=0;
          const rect=article.getBoundingClientRect.bind(article);
          article.getBoundingClientRect=() => { reads++; return rect(); };
          const renderer=originalCreate(article,{reportHeight,postSnapshot:false});
          renderer.renderFinal('Height mode check');
          check(reportHeight ? reads>0 : reads===0, 'height reporting mode must control old-height reads');
          article.remove();
        }
        // 消息外层身份不够：正常尾块完成不能删除内部已冻结前缀。
        const article = document.createElement('article');
        document.body.appendChild(article);
        const incremental = originalCreate(article, {reportHeight:false,postSnapshot:false});
        incremental.renderStreaming('# Frozen\n\npartial');
        const frozen = article.firstElementChild;
        incremental.renderStreaming('# Frozen\n\npartial completed\n\nnext');
        check(article.firstElementChild === frozen, 'normal tail completion must preserve frozen prefix');
        incremental.renderStreaming('# Frozen\n\n```swift\nlet value = 1\n```');
        const heading = article.firstElementChild;
        incremental.renderStreaming('# Frozen\n\n```swift\nlet value = 1\n```\n\nnext');
        check(article.firstElementChild === heading, 'code promotion must preserve preceding blocks');
        check(!!article.querySelector('code .hljs-keyword'), 'unchanged tail must acquire highlighting when frozen');
        incremental.renderStreaming('# Edited\n\nshort');
        check(article.textContent.includes('Edited') && !article.textContent.includes('value = 1'),
          'edited frozen prefix and shortened source must replace stale output');
        incremental.renderStreaming('');
        check(article.childElementCount === 0, 'empty source must remove old blocks');
        const changes = new MutationObserver(() => {});
        changes.observe(article, {childList:true});
        let growing = 'block 0';
        incremental.renderStreaming(growing);
        for (let i=1;i<100;i++) {
          growing += ' completed\n\nblock '+i;
          incremental.renderStreaming(growing);
        }
        const inserted = changes.takeRecords().reduce((sum,record)=>sum+record.addedNodes.length,0);
        changes.disconnect();
        check(article.childElementCount === 100 && inserted <= 200,
          '100 growing blocks must use linear block replacement, not 5050 insertions');
        incremental.renderFinal(growing);
        check(article.textContent.includes('block 99'), 'final render must preserve complete output');
        article.remove();

        // 单个大围栏是实际 200 行问题的输入形态：容器、代码和 Text 节点均应保留。
        const codeRoot = document.createElement('article');
        document.body.appendChild(codeRoot);
        const codeRenderer = originalCreate(codeRoot, {reportHeight:false,postSnapshot:false});
        let codeSource = '```swift\n';
        codeRenderer.renderStreaming(codeSource);
        const codeContainer = codeRoot.firstElementChild;
        const code = codeRoot.querySelector('pre code');
        const textNode = code.firstChild;
        const codeMutations = new MutationObserver(()=>{});
        codeMutations.observe(codeRoot, {childList:true,subtree:true});
        for (let i=1;i<=200;i++) {
          codeSource += `let value${i} = "<>& 测试 ${i}"\n`;
          codeRenderer.renderStreaming(codeSource);
          check(codeRoot.firstElementChild === codeContainer && codeRoot.querySelector('pre code') === code &&
            code.firstChild === textNode, 'streaming fence must retain container/code/Text identities');
        }
        const codeReplacements = codeMutations.takeRecords().filter(r=>r.type==='childList').length;
        codeMutations.disconnect();
        check(codeReplacements === 0, '200 code lines must not recreate any code subtree');
        check(code.textContent.includes('value200') && code.textContent.includes('<>&'),
          'append path must preserve final line and escape text without HTML injection');
        codeRenderer.renderStreaming(codeSource+'```');
        check(codeRoot.querySelector('pre code') === code, 'closing fence alone must preserve the code node');
        codeRenderer.renderFinal(codeSource+'```');
        check(!!codeRoot.querySelector('code .hljs-keyword'), 'final code must acquire syntax highlighting');
        // 字符粒度、补位换行、换行规范化、围栏长度/缩进以及回退后的语义与原路径一致。
        const reference = document.createElement('article');
        const referenceRenderer = originalCreate(reference, {reportHeight:false,postSnapshot:false});
        for (const source of [
          '```swift\nlet x = "<>&"\n```',
          '~~~text\nfirst\n\nsecond\n~~~',
          '````text\nliteral ```\nend\n````',
          '  ```text\n  indented\n less\n  ```',
          '```text\r\nA\u0000B\r\nC\tD\r\n```',
          'paragraph\n\n```text\npartial\n```\n\nnext',
          '> ```text\n> quoted\n> ```'
        ]) {
          codeRenderer.renderStreaming('');
          for (let end=1;end<=source.length;end++) codeRenderer.renderStreaming(source.slice(0,end));
          referenceRenderer.renderStreaming(source);
          check(codeRoot.innerHTML === reference.innerHTML, 'chunked fence must match single streaming render');
          codeRenderer.renderFinal(source);
          referenceRenderer.renderFinal(source);
          check(codeRoot.innerHTML === reference.innerHTML, 'final fence must match markdown normalization');
        }
        codeRenderer.renderStreaming('```text\nold text');
        codeRenderer.renderStreaming('```text\nedited');
        referenceRenderer.renderFinal('```text\nedited');
        check(codeRoot.querySelector('code').textContent === reference.querySelector('code').textContent,
          'non-append edits must match original-source fence content, without synthetic closing newline');
        codeRenderer.renderStreaming('```text\nedited\n```\n\nnext');
        check(codeRoot.textContent.includes('next'), 'new blocks after a fence must still render');
        codeRoot.remove();

        // 同源末帧与最终全文解析必须一致；仅忽略流式包装与最终才添加的高亮 span。
        const semanticHTML = root => {
          const clone=root.cloneNode(true);
          clone.querySelectorAll('.markdown-block').forEach(el=>el.replaceWith(...el.childNodes));
          clone.querySelectorAll('pre code').forEach(el=>{ el.textContent=el.textContent; });
          return clone.innerHTML.trim();
        };
        const markdownCases = [
          ['loose ordered list', '1. First\n\n2. Second\n\n3. Third'],
          ['loose unordered list', '- First\n\n- Second\n\n- Third'],
          ['nested list', '- Parent\n\n  First paragraph\n\n  - Child one\n\n  - Child two\n\n- Next parent'],
          ['blockquote paragraphs', '> First paragraph\n>\n> Second paragraph\n\n> Third paragraph'],
          ['adjacent blocks', '# Heading\nParagraph\n\n---\n\n## Subheading\nNext paragraph'],
          ['table', '| Name | Value |\n| --- | --- |\n| A | B |\n\nAfter table'],
          ['forward reference', 'Read [the docs][guide].\n\nOther paragraph.\n\n[guide]: https://example.com "Guide"'],
          ['earlier reference', '[guide]: https://example.com\n\nRead [the docs][guide].'],
          ['reference in list', '- [First][guide]\n\n- [Second][guide]\n\n[guide]: https://example.com'],
          ['typography and links', '"Hello" -- (c) ... https://example.com\n\nA **bold** and ~~deleted~~ word.'],
          ['long fence', '````text\none\n```\n\ntwo\n````\n\nAfter fence'],
          ['unfinished fence', '```text\nliteral ** and `'],
          ['unfinished fence newline', '```text\nliteral ** and `\n'],
          ['unfinished long fence', '````text\none\n```\n\ntwo'],
          ['nested fence', '> ```text\n> literal ** and `\n> ```'],
          ['list code then prose', '- Parent\n\n  ```text\n  **literal\n  ```\n\n  After code'],
          ['indented code', '    literal ** and `\n\n    next line'],
          ['fence then prose', '```swift\nlet value = 1\n```\n\nAfter fence'],
          ['normalized newlines', '1. First\r\n\r\n2. Second\r\n\r\n3. A\u0000B']
        ];
        const semanticRoot=document.createElement('article');
        semanticRoot.className='markdown-body';
        semanticRoot.style.width='800px';
        document.body.appendChild(semanticRoot);
        const semanticRenderer=originalCreate(semanticRoot,{reportHeight:false,postSnapshot:false});
        const semanticFailures=[];
        for(const [name,source] of markdownCases){
          semanticRenderer.renderStreaming('');
          // 模拟逐行到达，而不是只检查一次性流式渲染。
          let end=0;
          for(const line of source.split('\n')){
            end=Math.min(source.length,end+line.length+1);
            semanticRenderer.renderStreaming(source.slice(0,end));
          }
          semanticRenderer.renderStreaming('');
          for(let end=1;end<=source.length;end++){
            const prefix=source.slice(0,end);
            semanticRenderer.renderStreaming(prefix);
            referenceRenderer.renderStreaming('');
            referenceRenderer.renderStreaming(prefix);
            if(semanticHTML(semanticRoot)!==semanticHTML(reference)){
              semanticFailures.push(name+': incremental cache mismatch at character '+end);
              break;
            }
          }
          // 前缀检查失败也继续收集最终态差异，方便辨别缓存问题与分块语义问题。
          semanticRenderer.renderStreaming(source);
          const html=semanticHTML(semanticRoot), height=semanticRoot.getBoundingClientRect().height;
          semanticRenderer.renderFinal(source);
          const finalHeight=semanticRoot.getBoundingClientRect().height;
          if(html!==semanticHTML(semanticRoot)) semanticFailures.push(name+': DOM mismatch');
          if(Math.abs(height-finalHeight)>=1) semanticFailures.push(name+': height '+height+' -> '+finalHeight);
        }
        check(semanticFailures.length===0,'Markdown finalization: '+semanticFailures.join('; '));
        // 定义变化会影响已冻结的旧段落，不能只按旧段落的 source 判断缓存命中。
        const referencePrefix='Read [the docs][guide].\n\nStable paragraph\n\nTail';
        for(const definition of [
          '\n\n[guide]: https://example.com/one "One"',
          '\n\n[guide]: https://example.com/two "Two"',
          ''
        ]){
          const source=referencePrefix+definition;
          semanticRenderer.renderStreaming(source);
          const html=semanticHTML(semanticRoot);
          referenceRenderer.renderFinal(source);
          check(html===semanticHTML(reference),'reference add/change/remove must invalidate frozen output');
        }
        semanticRenderer.renderStreaming('**unfinished');
        check(semanticRoot.querySelector('strong')?.textContent==='unfinished','tail repair must remain available');
        semanticRenderer.renderFinal('**unfinished');
        check(!semanticRoot.querySelector('strong') && semanticRoot.textContent.includes('**unfinished'),
          'final render must use original source, never the repaired copy');
        semanticRoot.remove();

        // 暂停时不再排预热轮询；无 upsert 的解锁也必须重新唤醒。
        let warmerSchedules = 0;
        const originalTimeout = window.setTimeout;
        window.setTimeout = function(callback, delay, ...args) {
          if (typeof callback === 'function' && callback.toString().includes('self.runChunk()')) {
            warmerSchedules++;
          }
          return originalTimeout.call(window, callback, delay, ...args);
        };
        try {
          apply([{op:'forkLock',locked:true},
            {op:'upsert',id:'warm-test',kind:'assistant',body:'Warm test',streaming:false}]);
          await new Promise(r=>originalTimeout(r,100));
          const pausedCount = warmerSchedules;
          await new Promise(r=>originalTimeout(r,100));
          check(warmerSchedules === pausedCount, 'paused warmer must stop scheduling');
          apply([{op:'forkLock',locked:false}]);
          await new Promise(r=>originalTimeout(r,100));
          check(warmerSchedules > pausedCount, 'unlock without content must resume warming');
          const beforeScroll = warmerSchedules;
          window.dispatchEvent(new WheelEvent('wheel', {deltaY:-1}));
          apply([{op:'upsert',id:'warm-scroll',kind:'assistant',body:'Scroll pause',streaming:false}]);
          await new Promise(r=>originalTimeout(r,50));
          check(warmerSchedules === beforeScroll, 'user scrolling must pause warming without polling');
          await new Promise(r=>originalTimeout(r,750));
          check(warmerSchedules > beforeScroll, 'input without scrollend must eventually resume warming');
        } finally {
          window.setTimeout = originalTimeout;
        }
        // 正文/思考/工具共用自然高度与文档尾距，不允许完成态释放人工占位。
        const frames = () => new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
        const history = Array.from({length:25},(_,i)=>({
          op:'upsert',id:`gap-history-${i}`,kind:'user',body:`History ${i}\n`+'history line\n'.repeat(5)
        }));
        apply([{op:'reset'}, ...history, {op:'forkLock',locked:true},
          {op:'upsert',id:'gap-group',kind:'detailGroup',detailTurnID:'gap-turn',collapsed:false,body:''},
          {op:'upsert',id:'gap-thinking',kind:'thinking',detailTurnID:'gap-turn',body:'Thinking',streaming:true},
          {op:'scrollToBottom',smooth:false}]);
        await frames();
        // 新建历史的 CV 估算先收敛；后面的类型切换不再额外补滚动意图。
        for(let attempt=0;attempt<30;attempt++){
          if(Math.abs(window.innerHeight-node('gap-thinking').getBoundingClientRect().bottom-32)<2) break;
          apply([{op:'scrollToBottom',smooth:false}]);
          await frames();
        }
        const geometry = [];
        const checkTail = (id, stage) => {
          const el=node(id), child=el.firstElementChild;
          const rect=el.getBoundingClientRect();
          check(el.style.height === '', stage+': no stepped inline height');
          check(Math.abs(rect.height-child.getBoundingClientRect().height)<1,
            stage+': row must fit its visible content');
          const gap=window.innerHeight-rect.bottom;
          check(Math.abs(gap-32)<2, stage+': bottom gap must be 32px, got '+gap);
          geometry.push({stage,gap,height:rect.height});
        };
        checkTail('gap-thinking','thinking');
        apply([
          {op:'upsert',id:'gap-thinking',kind:'thinking',detailTurnID:'gap-turn',body:'Thinking',streaming:false},
          {op:'upsert',id:'gap-answer',kind:'assistant',detailTurnID:'gap-turn',body:'line 1',streaming:true}
        ]);
        await frames();
        checkTail('gap-answer','short answer');
        let gapBody='line 1', previousHeight=node('gap-answer').getBoundingClientRect().height;
        for(let i=2;i<=40;i++){
          gapBody+='\n'+'line '+i;
          apply([{op:'upsert',id:'gap-answer',kind:'assistant',detailTurnID:'gap-turn',body:gapBody,streaming:true}]);
          await frames();
          checkTail('gap-answer','growing answer '+i);
          const height=node('gap-answer').getBoundingClientRect().height;
          check(height>previousHeight && height-previousHeight<40, 'one line must grow naturally, not in 160px steps');
          previousHeight=height;
        }
        apply([{op:'upsert',id:'gap-answer',kind:'assistant',detailTurnID:'gap-turn',body:gapBody,streaming:false}]);
        await frames();
        checkTail('gap-answer','answer boundary');
        check(Math.abs(node('gap-answer').getBoundingClientRect().height-previousHeight)<1,
          'same source at message end must not shrink');
        apply([{op:'upsert',id:'gap-tool',kind:'tool',detailTurnID:'gap-turn',toolName:'bash',
          command:'echo test',toolRunning:true,body:'',streaming:false}]);
        await frames();
        checkTail('gap-tool','running tool');
        node('gap-tool').querySelector('.card-hd').click();
        await frames();
        checkTail('gap-tool','expanded tool');
        apply([
          {op:'upsert',id:'gap-tool',kind:'tool',detailTurnID:'gap-turn',toolName:'bash',
            command:'echo test',toolRunning:false,body:'test',streaming:false},
          {op:'upsert',id:'gap-next',kind:'assistant',detailTurnID:'gap-turn',body:'Next answer',streaming:true}
        ]);
        await frames();
        checkTail('gap-next','next answer');
        check(node('gap-tool').querySelector('.card').classList.contains('expanded'),
          'completed tool must retain manual expansion');
        // 尾部隐藏节点仍存在，折叠后的最后可见 disclosure 也只能留同一个底距。
        apply([{op:'upsert',id:'gap-group',kind:'detailGroup',detailTurnID:'gap-turn',collapsed:true,body:''}]);
        await frames();
        checkTail('gap-group','collapsed detail');
        apply([
          {op:'upsert',id:'gap-next',kind:'assistant',body:'Next answer',streaming:false},
          {op:'forkLock',locked:false}
        ]);
        await frames();
        checkTail('gap-next','final answer');
        // 离底阅读时，工具插入和正文增长仍应保住既有顶部锚点。
        apply([{op:'jumpTo',id:'gap-history-5'}]);
        await new Promise(r=>setTimeout(r,1000));
        window.dispatchEvent(new WheelEvent('wheel',{deltaY:-1}));
        await frames();
        const anchorBefore=node('gap-history-5').getBoundingClientRect().top;
        apply([{op:'forkLock',locked:true},
          {op:'upsert',id:'gap-last-tool',kind:'tool',toolName:'read',body:'result',toolRunning:false},
          {op:'upsert',id:'gap-last-answer',kind:'assistant',body:'More text\n'.repeat(50),streaming:true}]);
        await frames();
        check(Math.abs(node('gap-history-5').getBoundingClientRect().top-anchorBefore)<1,
          'reading history must not be pulled to new output');
        apply([{op:'scrollToBottom',smooth:false}]);
        await frames();
        checkTail('gap-last-answer','jump back to latest');
        apply([{op:'reset'},{op:'upsert',id:'short-answer',kind:'assistant',body:'Short answer',streaming:true}]);
        await frames();
        check(window.scrollY===0 && Math.abs(node('short-answer').getBoundingClientRect().top-16)<1,
          'short conversation must stay top aligned');
        check(node('short-answer').style.height==='', 'short conversation must also use natural height');
        // 收尾不应改变末行屏幕位置；history 已有占位收敛后再比较，不掩盖变更本身。
        const reflowGeometry=[];
        for(const [name,body] of markdownCases.slice(0,4)){
          apply([{op:'reset'},...history,{op:'forkLock',locked:true},
            {op:'upsert',id:'semantic-tail',kind:'assistant',body,streaming:true},
            {op:'scrollToBottom',smooth:false}]);
          await frames();
          for(let attempt=0;attempt<30;attempt++){
            if(Math.abs(innerHeight-node('semantic-tail').getBoundingClientRect().bottom-32)<2) break;
            apply([{op:'scrollToBottom',smooth:false}]);
            await frames();
          }
          checkTail('semantic-tail',name+' streaming');
          const before=node('semantic-tail').getBoundingClientRect(), scrollBefore=scrollY;
          apply([{op:'upsert',id:'semantic-tail',kind:'assistant',body,streaming:false}]);
          await frames();
          const after=node('semantic-tail').getBoundingClientRect();
          checkTail('semantic-tail',name+' final');
          check(Math.abs(after.height-before.height)<1 && Math.abs(after.bottom-before.bottom)<1 &&
            Math.abs(scrollY-scrollBefore)<1,name+': finalization must not move the last line or scroll position');
          reflowGeometry.push({name,heightDelta:after.height-before.height,scrollDelta:scrollY-scrollBefore});
          apply([{op:'jumpTo',id:'gap-history-5'}]);
          await new Promise(r=>setTimeout(r,250));
          window.dispatchEvent(new WheelEvent('wheel',{deltaY:-1}));
          await frames();
          const top=node('gap-history-5').getBoundingClientRect().top;
          apply([{op:'upsert',id:'semantic-tail',kind:'assistant',body:body+'\n\nMore text',streaming:true}]);
          apply([{op:'upsert',id:'semantic-tail',kind:'assistant',body:body+'\n\nMore text',streaming:false}]);
          await frames();
          check(Math.abs(node('gap-history-5').getBoundingClientRect().top-top)<1,
            name+': finalization while reading history must preserve anchor');
        }
        if (benchmark) {
          const results = [];
          const frames = () => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
          for (const [name, count, tools] of [['short',20,false], ['long',500,false], ['tools',200,true]]) {
            const ops = [{op:'reset'}, {op:'forkLock',locked:true}];
            for (let i=0; i<count; i++) {
              if (tools) {
                ops.push({op:'upsert',id:`g${i}`,kind:'detailGroup',detailTurnID:`s${i}`,collapsed:true,body:''});
                ops.push({op:'upsert',id:`t${i}`,kind:'thinking',detailTurnID:`s${i}`,body:'Reasoning. '.repeat(100),streaming:false});
                ops.push({op:'upsert',id:`c${i}`,kind:'tool',detailTurnID:`s${i}`,toolName:'read',command:'file.swift',body:'Tool output\n'.repeat(100),streaming:false});
              }
              ops.push({op:'upsert',id:`a${i}`,kind:'assistant',body:`History ${i} text. `.repeat(80),streaming:false});
            }
            ops.push({op:'upsert',id:'live',kind:'assistant',body:'Streaming',streaming:true});
            const coldStart = performance.now();
            apply(ops);
            const coldApplyMs = performance.now()-coldStart;
            await frames();
            const times=[];
            let body='Streaming';
            for(let i=0;i<30;i++) {
              body+=' delta';
              const start=performance.now();
              apply([{op:'upsert',id:'live',kind:'assistant',body,streaming:true}]);
              times.push(performance.now()-start);
              await frames();
            }
            times.sort((a,b)=>a-b);
            results.push({name, rows:document.querySelectorAll('.ti').length, updates:30,
              coldApplyMs, applyP50ms:times[14], applyP95ms:times[27]});
          }
          // JS synchronous apply timings include serialization and forced layout, not GPU/frame presentation.
          return JSON.stringify({benchmark:'WKWebView synchronous apply; not end-to-end latency', results},null,2);
        }
        return `PASS: WKWebView non-last streaming, stable DOM, thinking expansion, finalization, steering, frozen prefix (${inserted} insertions for 100 blocks), 200-line code (${codeReplacements} subtree replacements), highlighting, warmer pause/resume, natural-height alternation (${geometry.length} checks), 32px tail gap and history anchor; ${markdownCases.length} semantic cases, reference invalidation, tail repair; final reflow ${JSON.stringify(reflowGeometry)}`;
        """#
        Task { @MainActor in
            do {
                let result = try await webView.callAsyncJavaScript(script,
                    arguments: ["benchmark": ProcessInfo.processInfo.environment["NEWPI_TRANSCRIPT_PERFORMANCE"] == "1"],
                    in: nil, contentWorld: .page)
                print(result ?? "missing result")
                exit(0)
            } catch { print("FAIL: \(error)"); exit(1) }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("FAIL: \(error)"); exit(1)
    }
}

@main
struct Runner {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let runner = TranscriptStreamingDOMChecks(root: root)
        try runner.run()
        let timeout: Double = ProcessInfo.processInfo.environment["NEWPI_TRANSCRIPT_PERFORMANCE"] == "1" ? 120 : 20
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { print("FAIL: WebView test timeout"); exit(1) }
        withExtendedLifetime(runner) { NSApp.run() }
    }
}
