// Local Markdown renderer glue for AIChatMac.
// SECURITY-REVIEW: Model output is untrusted. markdown-it is configured with
// raw HTML disabled, image syntax disabled, and link clicks intercepted so
// rendered content cannot execute arbitrary HTML or navigate the WebView.
//
// 结构（BACKLOG-SINGLE-DOC）：所有 per-root 状态收进 createMarkdownRenderer(root, options)
// 工厂——单文档 transcript 里每条 assistant 消息一个实例；遗留 per-message WebView
// 路径仍走 window.renderMarkdown / window.replayRendered（委托给一个绑定 #markdown-root
// 的单例实例，行为与重构前完全一致）。
(function () {
  "use strict";

  const escapeHtml = window.markdownit().utils.escapeHtml;
  let streamingRenderDepth = 0;

  const markdown = window.markdownit({
    html: false,
    linkify: true,
    typographer: true,
    breaks: true,
    highlight: function (source, language) {
      // language-xxx class 供代码块头部显示语言标签
      const languageClass = language ? ' class="language-' + escapeHtml(language) + '"' : "";
      if (streamingRenderDepth > 0) {
        return '<pre class="hljs"><code' + languageClass + ">" + escapeHtml(source) + "</code></pre>";
      }

      if (language && window.hljs && window.hljs.getLanguage(language)) {
        try {
          const highlighted = window.hljs.highlight(source, {
            language: language,
            ignoreIllegals: true
          }).value;
          return '<pre class="hljs"><code' + languageClass + ">" + highlighted + "</code></pre>";
        } catch (_) {
          return '<pre class="hljs"><code' + languageClass + ">" + escapeHtml(source) + "</code></pre>";
        }
      }

      return '<pre class="hljs"><code' + languageClass + ">" + escapeHtml(source) + "</code></pre>";
    }
  });

  markdown.disable("image");

  const heightChangeThreshold = 4;
  const caretFinalHoldMilliseconds = 1400;
  // 光标用 class 查找（作用域限定在各实例 root 内），不再用文档级唯一 id——
  // 单文档内多个 renderer 实例共存时 id 会撞车。
  const caretClass = "streaming-caret";

  // ===== 共享纯函数（无实例状态） =====

  // 复制按钮点击：file:// 源下 navigator.clipboard 不可靠，走原生 NSPasteboard。
  // enhanceCodeBlocks（新建外框）与 rebindInteractivity（产物重放）共用。
  function attachCopyHandler(button, pre) {
    const code = pre.querySelector("code");
    button.addEventListener("click", function () {
      const text = code ? code.textContent : pre.textContent;
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.copyText) {
        window.webkit.messageHandlers.copyText.postMessage(text || "");
      }
      button.textContent = "✓";
      button.classList.add("copied");
      window.setTimeout(function () {
        button.textContent = "Copy";
        button.classList.remove("copied");
      }, 1000);
    });
  }

  function bindLinks(root) {
    root.querySelectorAll("a").forEach(function (link) {
      link.setAttribute("rel", "nofollow noopener noreferrer");
      link.addEventListener("click", function (event) {
        event.preventDefault();
      });
    });
  }

  // 重放模式：产物 HTML 已内联在 root 中。innerHTML 重放不保留事件监听，
  // 需重绑复制按钮与链接拦截。
  function rebindInteractivity(root) {
    root.querySelectorAll(".code-block-container").forEach(function (container) {
      const pre = container.querySelector("pre");
      const button = container.querySelector(".code-block-copy");
      if (pre && button) {
        attachCopyHandler(button, pre);
      }
    });
    bindLinks(root);
  }

  // ===== 块级增量渲染 =====
  // renderedBlocks 与 root 的块节点一一对应（流式末尾的光标节点除外）。
  // 块只追加 / 只在尾部变化，因此索引对齐是稳定的。

  // 使用全文解析的顶层语义边界：空行可能仍在列表、引用或缩进代码内，不能独立解析。
  // tokens 已经过 inline/reference/typographer 处理，渲染时直接复用；source 仅用于缓存对齐。
  function splitBlocks(source) {
    // 与 markdown-it 的 normalize 对齐，使 token.map 的行号能映射回渲染副本。
    source = source.replace(/\r\n?/g, "\n").replace(/\u0000/g, "\uFFFD");
    const lines = source.split("\n");
    function parse(renderSource) {
      const env = {};
      const tokens = markdown.parse(renderSource, env);
      const blocks = [];
      let start = 0;
      let depth = 0;
      tokens.forEach(function (token, index) {
        depth += token.nesting;
        if (depth === 0) {
          const map = tokens[start].map;
          blocks.push({
            // map 不含行分隔符；仅追加 EOF 换行也会改变代码 token 的 content，必须参与缓存键。
            source: lines.slice(map[0], map[1]).join("\n") + (map[1] < lines.length ? "\n" : ""),
            tokens: tokens.slice(start, index + 1)
          });
          start = index + 1;
        }
      });
      return { blocks: blocks, env: env, referencesKey: JSON.stringify(env.references || {}) };
    }

    const result = parse(source);
    const tail = result.blocks[result.blocks.length - 1];
    if (!tail) {
      return result;
    }
    const leaves = tail.tokens.filter(function (token) { return token.block && token.nesting === 0; });
    const lastLeaf = leaves[leaves.length - 1];
    // markdown-it 原生支持 EOF 未闭合围栏，且保留真实 fence 长度/缩进；代码末尾不补行内标记。
    // 只修复文档末尾的 inline 块，后面仍有引用定义时不能把修复符号追加到定义里。
    // 表格单元格等合成 inline 没有 map；无法精确定位时不猜测尾部修复位置。
    if (lastLeaf && lastLeaf.type === "inline" && lastLeaf.map) {
      const end = lines.slice(0, lastLeaf.map[1]).join("\n").length;
      // 只检查最后一个 inline 叶子，避免容器里先前代码块的 ** 被当作正文未闭合标记。
      const inlineSource = lines.slice(lastLeaf.map[0], lastLeaf.map[1]).join("\n");
      const repaired = repairTailSource(inlineSource);
      if (repaired !== inlineSource && /^\s*$/.test(source.slice(end))) {
        return parse(source.slice(0, end) + repaired.slice(inlineSource.length) + source.slice(end));
      }
    }
    return result;
  }

  // 仅作用于渲染副本：行内代码 > 加粗 / 删除线；围栏由全文 parser 处理。
  function repairTailSource(source) {
    // 先剥掉已闭合的行内代码段，避免把代码内容里的标记（如 2 ** 3）当成加粗。
    // 同时识别双/多反引号代码段（``code``）：只认单反引号会把代码里的反引号
    // 误判成加粗/删除线标记而给尾块补上多余闭合符。
    const withoutCodeSpans = source.replace(/`+[^`\n]*`+/g, "");

    const backtickCount = (withoutCodeSpans.match(/`/g) || []).length;
    if (backtickCount % 2 === 1) {
      // 行内代码未闭合：其余标记可能在代码段内，保守起见到此为止
      return source + "`";
    }

    let repaired = source;
    if (needsClosingMarker(withoutCodeSpans, "**")) {
      repaired += "**";
    }
    if (needsClosingMarker(withoutCodeSpans, "__")) {
      repaired += "__";
    }
    if (needsClosingMarker(withoutCodeSpans, "~~")) {
      repaired += "~~";
    }
    return repaired;
  }

  // 只优化顶层单围栏；列表/引用/混合块仍交给完整渲染，内容与缩进由 markdown-it 解析。
  function singleFence(tokens) {
    return tokens.length === 1 && tokens[0].type === "fence" ? tokens[0] : null;
  }

  function appendFenceText(previous, source, fence) {
    const cached = previous && previous.fence;
    if (!cached || !fence || !source.startsWith(previous.source) ||
        cached.info !== fence.info || cached.markup !== fence.markup) {
      return false;
    }
    const text = cached.text;
    let offset = text.length;
    if (!fence.content.startsWith(text.data)) {
      // markdown-it 会为未结束的末行补换行；下一批续写同一行时，只替换这一个补位。
      offset -= 1;
      if (offset < 0 || !text.data.endsWith("\n") ||
          !fence.content.startsWith(text.data.slice(0, offset))) {
        return false;
      }
    }
    if (text.data !== fence.content) {
      text.replaceData(offset, text.length - offset, fence.content.slice(offset));
    }
    previous.source = source;
    return true;
  }

  function cacheFence(node, fence) {
    if (!fence) {
      return null;
    }
    const code = node.querySelector("pre code");
    if (!code) {
      return null;
    }
    if (!code.firstChild) {
      code.appendChild(document.createTextNode(""));
    }
    if (code.childNodes.length !== 1 || code.firstChild.nodeType !== Node.TEXT_NODE) {
      return null;
    }
    return { info: fence.info, markup: fence.markup, text: code.firstChild };
  }

  // 标记出现奇数次，且最后一次出现后面紧跟非空白（可能是未闭合的起始标记）才修复；
  // 像 "2 ** 3" 这种两侧空白的不可能是加粗起始，保守不动。
  function needsClosingMarker(source, marker) {
    const parts = source.split(marker);
    if ((parts.length - 1) % 2 === 0) {
      return false;
    }
    const afterLast = parts[parts.length - 1];
    return afterLast.length > 0 && !/^\s/.test(afterLast);
  }

  // 代码块外框：语言标签 + 复制按钮（hover 显示，点击走原生 copyText 写剪贴板）
  function enhanceCodeBlocks(scope) {
    scope.querySelectorAll("pre").forEach(function (pre) {
      if (pre.parentElement && pre.parentElement.classList.contains("code-block-container")) {
        return;
      }

      const code = pre.querySelector("code");
      let language = "";
      if (code) {
        const languageMatch = /language-([\w+-]+)/.exec(code.className || "");
        if (languageMatch) {
          language = languageMatch[1];
        }
      }

      const container = document.createElement("div");
      container.className = "code-block-container";

      const header = document.createElement("div");
      header.className = "code-block-header";

      const label = document.createElement("span");
      label.className = "code-block-language";
      label.textContent = language || "code";

      const button = document.createElement("button");
      button.type = "button";
      button.className = "code-block-copy";
      button.textContent = "Copy";
      attachCopyHandler(button, pre);

      header.appendChild(label);
      header.appendChild(button);
      pre.parentNode.insertBefore(container, pre);
      container.appendChild(header);
      container.appendChild(pre);
    });
  }

  function renderBlockNode(tokens, highlighted, env) {
    const node = document.createElement("div");
    node.className = "markdown-block";
    if (highlighted) {
      node.innerHTML = markdown.renderer.render(tokens, markdown.options, env);
    } else {
      // 流式尾块：跳过 hljs 高亮（沿用 streamingRenderDepth 开关）；
      // try/finally 保证 render 抛异常时计数器不泄漏（否则后续渲染永远不再高亮）
      streamingRenderDepth += 1;
      try {
        node.innerHTML = markdown.renderer.render(tokens, markdown.options, env);
      } finally {
        streamingRenderDepth -= 1;
      }
    }
    enhanceCodeBlocks(node);
    bindLinks(node);
    return node;
  }

  // ===== 工厂：每个 root（遗留：整条消息页；单文档：一条 assistant 消息的 article）一个实例 =====
  //
  // options:
  //   reportHeight —— ResizeObserver 高度上报（遗留 per-message 页需要；单文档不需要：
  //                   浏览器自己布局，原生侧永不消费内容高度）
  //   postSnapshot —— 最终渲染产物回传（遗留路径的 render-once/replay 缓存；单文档暂不需要）
  //   caret        —— 流式/终态 ✦ 光标
  function createMarkdownRenderer(root, options) {
    options = options || {};
    const reportHeight = options.reportHeight !== false;
    const postSnapshot = options.postSnapshot !== false;
    // 需求：移除助手消息末尾的 ✦ 小星星（流式/终态光标）。此处恒为 false，
    // 使任何调用方都不再生成该光标；相关渲染/高度上报逻辑保留不动，便于后续恢复。
    const enableCaret = false;

    let renderedBlocks = [];
    let referencesKey = "";
    let hasStreamed = false;
    let caretRemovalTimer = null;
    let lastPostedHeight = 0;
    let pendingHeightFrame = null;
    let resizeObserver = null;

    function postHeight(height) {
      if (!reportHeight) {
        return;
      }
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.height) {
        // 高度是宽度的函数：宽度随高度一起上报，Swift 侧按宽度判定缓存条目有效。
        // 窗口 resize 使宽度变化时整体失效缓存，因此必须带上 width，否则 height(for:)
        // 永远 currentWidth <= 0、缓存整条失效（曾导致冷重建首帧防闪烁/rail 定位全变死代码）。
        window.webkit.messageHandlers.height.postMessage({
          height: height,
          width: Math.ceil(document.documentElement.clientWidth)
        });
      }
    }

    function measureRootHeight() {
      return Math.ceil(Math.max(1, root.getBoundingClientRect().height));
    }

    function findCaret() {
      return root.querySelector(":scope > ." + caretClass);
    }

    function postHeightIfChanged(force) {
      let height = measureRootHeight();
      // 终态光标是绝对定位的，不计入 root 布局高度；淡出期间把它的视觉范围
      // 一并上报，否则会被 Swift 侧按内容高度裁掉。光标移除后恢复精确内容高度。
      const caret = findCaret();
      if (caret && caret.style.position === "absolute") {
        height = Math.max(height, Math.ceil(caret.offsetTop + caret.offsetHeight));
      }

      // 高度与上次完全相同（含 force 上报）则去重，避免 Swift 侧重复更新缓存。
      if (height === lastPostedHeight) {
        return;
      }
      if (!force && Math.abs(height - lastPostedHeight) < heightChangeThreshold) {
        return;
      }

      lastPostedHeight = height;
      // 不把测量值钉回 root.style.minHeight：那会把自身钉的高度算进下次测量，
      // 窗口拉宽后高度永远降不下来（自锁）；root 高度由内容自然决定，光标淡出
      // 后的高度收缩由上方 absolute 光标的范围上报兜住。
      postHeight(height);
    }

    function scheduleHeightPost(force) {
      if (!reportHeight) {
        return;
      }
      if (pendingHeightFrame !== null) {
        return;
      }

      pendingHeightFrame = window.requestAnimationFrame(function () {
        pendingHeightFrame = null;
        postHeightIfChanged(force);
      });
    }

    function observeRootHeight() {
      if (!reportHeight) {
        return;
      }
      if (resizeObserver) {
        resizeObserver.disconnect();
        resizeObserver = null;
      }

      if (window.ResizeObserver) {
        resizeObserver = new ResizeObserver(function () {
          scheduleHeightPost(false);
        });
        resizeObserver.observe(root);
      }
    }

    // 最终渲染产物回传：克隆后剥掉流式/终态光标，只存内容本体。
    // Swift 侧按（内容哈希 + 宽度桶 + 引擎指纹）持久化，之后该消息永远重放、不再解析。
    function postRenderedSnapshot() {
      if (!postSnapshot) {
        return;
      }
      if (!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.renderedSnapshot)) {
        return;
      }
      const clone = root.cloneNode(true);
      const caret = clone.querySelector("." + caretClass);
      if (caret && caret.parentNode) {
        caret.parentNode.removeChild(caret);
      }
      window.webkit.messageHandlers.renderedSnapshot.postMessage({
        html: clone.innerHTML,
        width: Math.ceil(document.documentElement.clientWidth)
      });
    }

    // ===== 流式/终态光标 =====
    // 流式结束后光标进入静止终态：停止闪烁，稍作停留后淡出移除。
    // hasStreamed 区分“刚流式完的消息”与“会话恢复时直接完成态挂载的消息”——
    // 后者不应再闪一次终态光标。
    // caretTop：终态光标用绝对定位落在流式光标原处，不参与布局，
    // 否则淡出移除时消息高度会在完成后二次收缩（延迟跳动）。

    function makeCaret(isFinal) {
      const caret = document.createElement("span");
      caret.className = isFinal ? caretClass + " is-final" : caretClass;
      caret.setAttribute("aria-hidden", "true");
      caret.textContent = "✦";
      return caret;
    }

    function ensureStreamingCaret() {
      if (!enableCaret) {
        return;
      }
      if (caretRemovalTimer !== null) {
        window.clearTimeout(caretRemovalTimer);
        caretRemovalTimer = null;
      }
      let caret = findCaret();
      if (!caret) {
        caret = makeCaret(false);
      } else {
        caret.classList.remove("is-final");
        caret.style.position = "";
        caret.style.top = "";
        caret.style.left = "";
      }
      // 始终保持在最后一个块之后
      root.appendChild(caret);
    }

    function finishStreamingCaret(caretTop, caretLeft) {
      if (!enableCaret) {
        return;
      }
      if (caretRemovalTimer !== null) {
        window.clearTimeout(caretRemovalTimer);
        caretRemovalTimer = null;
      }
      removeStreamingCaret();
      if (!hasStreamed) {
        return;
      }
      const caret = makeCaret(true);
      if (caretTop !== null) {
        caret.style.position = "absolute";
        caret.style.top = caretTop + "px";
        // 水平位置同样取流式光标原处，避免完成瞬间光标横向跳到行首。
        caret.style.left = (caretLeft || 0) + "px";
      }
      root.appendChild(caret);
      caretRemovalTimer = window.setTimeout(function () {
        caretRemovalTimer = null;
        removeStreamingCaret();
        scheduleHeightPost(true);
      }, caretFinalHoldMilliseconds);
    }

    function removeStreamingCaret() {
      const caret = findCaret();
      if (caret && caret.parentNode) {
        caret.parentNode.removeChild(caret);
      }
    }

    // ===== 渲染入口（实例方法） =====

    function renderStreaming(markdownSource) {
      hasStreamed = true;
      removeStreamingCaret();

      // 防御：重放页（renderedBlocks 为空但 root 已有产物内容）若意外收到流式更新，
      // 先清空再全量增量，否则块会 append 到重放内容之后造成重复。
      if (renderedBlocks.length === 0 && root.firstChild) {
        while (root.firstChild) {
          root.removeChild(root.firstChild);
        }
      }

      const split = splitBlocks(markdownSource);
      const blocks = split.blocks;
      const blockCount = blocks.length;
      const previousFrozenLimit = Math.max(0, renderedBlocks.length - 1);
        // 定义本身没有可见 token，但增删/改定义可能改变已冻结段落的链接；按全文环境失效。
        const referencesChanged = referencesKey !== split.referencesKey;
        referencesKey = split.referencesKey;

      // 与上一帧的公共前缀（冻结块逐字节对齐）
      let common = 0;
      const maxCommon = Math.min(renderedBlocks.length, blockCount);
        while (!referencesChanged && common < maxCommon &&
          renderedBlocks[common].source === blocks[common].source &&
          renderedBlocks[common].highlighted === (common < blockCount - 1)) {
        common += 1;
      }

      // 上一批尾块本来就允许变化；补完尾块并新增块不算冻结前缀分叉。
      // 高亮状态也参与比较，让未改正文的旧尾块在冻结时补上高亮。
      if (referencesChanged || (common < previousFrozenLimit && common < blockCount)) {
        while (root.firstChild) {
          root.removeChild(root.firstChild);
        }
        renderedBlocks = [];
        common = 0;
      }

      // 源变短：裁掉多余的尾部节点
      while (renderedBlocks.length > blockCount) {
        const removed = renderedBlocks.pop();
        if (removed.node.parentNode === root) {
          root.removeChild(removed.node);
        }
      }

      for (let i = common; i < blockCount; i += 1) {
        const isTail = i === blockCount - 1;
        const block = blocks[i];
        const blockSource = block.source;
        // 冻结块带高亮，尾块不高亮；tokens 已共享全文上下文并完成必要的尾部修复。
        const fence = isTail ? singleFence(block.tokens) : null;
        // 保留 pre/code/按钮和 Text 节点身份，避免每个 delta 重建整个增长中的代码表面。
        if (isTail && appendFenceText(renderedBlocks[i], blockSource, fence)) {
          continue;
        }
        const node = renderBlockNode(block.tokens, !isTail, split.env);
        const rendered = { source: blockSource, node: node, highlighted: !isTail, fence: cacheFence(node, fence) };
        if (i < renderedBlocks.length) {
          root.replaceChild(node, renderedBlocks[i].node);
          renderedBlocks[i] = rendered;
        } else {
          root.appendChild(node);
          renderedBlocks.push(rendered);
        }
      }

      ensureStreamingCaret();
      scheduleHeightPost(true);
    }

    // 非流式（最终）渲染：全量重渲染 + hljs 高亮，归一化所有块
    //（例如流式结束时刚好闭合的代码围栏）
    function renderFinal(markdownSource) {
      // 单文档模式不消费旧高度。逐条插入历史时读取布局会迫使浏览器反复布局前序 DOM。
      // 仅高度上报模式保留测量，避免冷加载出现每条消息一次无用的同步布局读取。
      const preservedHeight = reportHeight ? measureRootHeight() : 0;
      if (reportHeight && preservedHeight > 1) {
        root.style.minHeight = preservedHeight + "px";
      }

      // 先记下流式光标的位置，终态光标绝对定位回原处（见 finishStreamingCaret）——
      // offsetTop 只管纵向、offsetLeft 管横向，避免完成瞬间光标横向跳到行首。
      const existingCaret = findCaret();
      const caretTop = existingCaret ? existingCaret.offsetTop : null;
      const caretLeft = existingCaret ? existingCaret.offsetLeft : null;

      removeStreamingCaret();
      renderedBlocks = [];
      root.innerHTML = markdown.render(markdownSource);
      enhanceCodeBlocks(root);
      bindLinks(root);
      // 静止终态：仅在经历过流式的消息上停留一颗静态 ✦，随即淡出
      finishStreamingCaret(caretTop, caretLeft);

      // 产物重放：把最终渲染结果回传 Swift 持久化（克隆内剥光标），后续展示直接重放。
      postRenderedSnapshot();

      root.style.minHeight = "";
      lastPostedHeight = 0;
      observeRootHeight();
      scheduleHeightPost(true);
    }

    function replayRendered() {
      rebindInteractivity(root);
      lastPostedHeight = 0;
      observeRootHeight();
      scheduleHeightPost(true);
    }

    return {
      renderStreaming: renderStreaming,
      renderFinal: renderFinal,
      replayRendered: replayRendered
    };
  }

  window.createMarkdownRenderer = createMarkdownRenderer;

  // ===== 遗留 per-message 页 API（行为与重构前完全一致） =====
  let legacyRenderer = null;

  function legacyInstance() {
    const root = document.getElementById("markdown-root");
    if (!root) {
      return null;
    }
    if (!legacyRenderer) {
      legacyRenderer = createMarkdownRenderer(root, {});
    }
    return legacyRenderer;
  }

  window.renderMarkdown = function (markdownSource, options) {
    const instance = legacyInstance();
    if (!instance) {
      return;
    }

    options = options || {};
    if (options.streaming === true) {
      instance.renderStreaming(markdownSource);
      return;
    }
    instance.renderFinal(markdownSource);
  };

  window.replayRendered = function () {
    const instance = legacyInstance();
    if (!instance) {
      return;
    }
    instance.replayRendered();
  };
}());
