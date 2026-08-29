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
  const fencePattern = /^ {0,3}(`{3,}|~{3,})/;
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

  // 按顶层块切分：空行是块边界；围栏代码块内部不切分，
  // 闭合行（以相同 fence 标记开头）归属于该代码块。
  function splitBlocks(source) {
    const lines = source.split("\n");
    const blocks = [];
    let current = [];
    let fenceMarker = null;

    lines.forEach(function (line) {
      if (fenceMarker === null && line.trim() === "") {
        if (current.length > 0) {
          blocks.push(current.join("\n"));
          current = [];
        }
        return;
      }

      current.push(line);

      const fenceMatch = fencePattern.exec(line);
      if (fenceMatch) {
        const marker = fenceMatch[1].charAt(0) === "`" ? "```" : "~~~";
        if (fenceMarker === null) {
          fenceMarker = marker;
        } else if (marker === fenceMarker) {
          fenceMarker = null;
          blocks.push(current.join("\n"));
          current = [];
        }
      }
    });

    const result = { blocks: blocks, tailFenceMarker: null };
    if (current.length > 0) {
      blocks.push(current.join("\n"));
      // 扫描结束时仍处于围栏内：尾块是一个未闭合的代码块
      result.tailFenceMarker = fenceMarker;
    }
    return result;
  }

  // 仅作用于渲染副本：修复尾部块未闭合的 Markdown 结构，绝不改动原始 source。
  // 优先级：代码围栏 > 行内代码 > 加粗 / 删除线。
  function repairTailSource(source, tailFenceMarker) {
    if (tailFenceMarker !== null) {
      // 未闭合的代码围栏：补一个闭合行，让代码块正常渲染而不是吞掉后续原始文本
      return source + "\n" + tailFenceMarker;
    }

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

  function renderBlockNode(blockSource, highlighted) {
    const node = document.createElement("div");
    node.className = "markdown-block";
    if (highlighted) {
      node.innerHTML = markdown.render(blockSource);
    } else {
      // 流式尾块：跳过 hljs 高亮（沿用 streamingRenderDepth 开关）；
      // try/finally 保证 render 抛异常时计数器不泄漏（否则后续渲染永远不再高亮）
      streamingRenderDepth += 1;
      try {
        node.innerHTML = markdown.render(blockSource);
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
    const enableCaret = options.caret !== false;

    let renderedBlocks = [];
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
      const frozenLimit = blockCount - 1;

      // 与上一帧的公共前缀（冻结块逐字节对齐）
      let common = 0;
      const maxCommon = Math.min(renderedBlocks.length, blockCount);
      while (common < maxCommon && renderedBlocks[common].source === blocks[common]) {
        common += 1;
      }

      // 冻结前缀分叉（源变短 / 内容被编辑）：退回全量重渲染
      if (common < frozenLimit && common < renderedBlocks.length) {
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
        const blockSource = blocks[i];
        // 冻结块已完结：带 hljs 高亮渲染；尾块流式渲染（无高亮 + 修复未闭合结构）
        const renderSource = isTail ? repairTailSource(blockSource, split.tailFenceMarker) : blockSource;
        const node = renderBlockNode(renderSource, !isTail);
        if (i < renderedBlocks.length) {
          root.replaceChild(node, renderedBlocks[i].node);
          renderedBlocks[i] = { source: blockSource, node: node };
        } else {
          root.appendChild(node);
          renderedBlocks.push({ source: blockSource, node: node });
        }
      }

      ensureStreamingCaret();
      scheduleHeightPost(true);
    }

    // 非流式（最终）渲染：全量重渲染 + hljs 高亮，归一化所有块
    //（例如流式结束时刚好闭合的代码围栏）
    function renderFinal(markdownSource) {
      const preservedHeight = measureRootHeight();
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
