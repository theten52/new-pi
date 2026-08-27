// Local Markdown renderer glue for AIChatMac.
// SECURITY-REVIEW: Model output is untrusted. markdown-it is configured with
// raw HTML disabled, image syntax disabled, and link clicks intercepted so
// rendered content cannot execute arbitrary HTML or navigate the WebView.
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

  const heightChangeThreshold = 20;
  let lastPostedHeight = 0;
  let pendingHeightFrame = null;
  let resizeObserver = null;
  let activeStreamingRender = false;

  function postHeight(height) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.height) {
      window.webkit.messageHandlers.height.postMessage(height);
    }
  }

  function measureRootHeight(root) {
    return Math.ceil(Math.max(1, root.getBoundingClientRect().height));
  }

  function postHeightIfChanged(force) {
    const root = document.getElementById("markdown-root");
    if (!root) {
      return;
    }

    let height = measureRootHeight(root);
    // 终态光标是绝对定位的，不计入 root 布局高度；淡出期间把它的视觉范围
    // 一并上报，否则会被 Swift 侧按内容高度裁掉。光标移除后恢复精确内容高度。
    const caret = document.getElementById(caretID);
    if (caret && caret.style.position === "absolute") {
      height = Math.max(height, Math.ceil(caret.offsetTop + caret.offsetHeight));
    }

    const streaming = activeStreamingRender;
    if (!force && !streaming && Math.abs(height - lastPostedHeight) < heightChangeThreshold) {
      return;
    }

    lastPostedHeight = height;
    root.style.minHeight = height + "px";
    postHeight(height);
  }

  function scheduleHeightPost(force) {
    if (pendingHeightFrame !== null) {
      return;
    }

    pendingHeightFrame = window.requestAnimationFrame(function () {
      pendingHeightFrame = null;
      postHeightIfChanged(force);
    });
  }

  function observeRootHeight(root) {
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

  function bindLinks(root) {
    root.querySelectorAll("a").forEach(function (link) {
      link.setAttribute("rel", "nofollow noopener noreferrer");
      link.addEventListener("click", function (event) {
        event.preventDefault();
      });
    });
  }

  // ===== 块级增量渲染 =====
  // renderedBlocks 与 root 的块节点一一对应（流式末尾的光标节点除外）。
  // 块只追加 / 只在尾部变化，因此索引对齐是稳定的。
  let renderedBlocks = [];

  const fencePattern = /^ {0,3}(`{3,}|~{3,})/;
  const caretID = "newpi-streaming-caret";

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

    // 先剥掉已闭合的行内代码段，避免把代码内容里的标记（如 2 ** 3）当成加粗
    const withoutCodeSpans = source.replace(/`[^`\n]*`/g, "");

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

  // 流式结束后光标进入静止终态：停止闪烁，稍作停留后淡出移除。
  // hasStreamed 区分“刚流式完的消息”与“会话恢复时直接完成态挂载的消息”——
  // 后者不应再闪一次终态光标。
  // caretTop：终态光标用绝对定位落在流式光标原处，不参与布局，
  // 否则淡出移除时消息高度会在完成后二次收缩（延迟跳动）。
  let hasStreamed = false;
  let caretRemovalTimer = null;
  const caretFinalHoldMilliseconds = 1400;

  function makeCaret(isFinal) {
    const caret = document.createElement("span");
    caret.id = caretID;
    caret.className = isFinal ? "streaming-caret is-final" : "streaming-caret";
    caret.setAttribute("aria-hidden", "true");
    caret.textContent = "✦";
    return caret;
  }

  function ensureStreamingCaret(root) {
    if (caretRemovalTimer !== null) {
      window.clearTimeout(caretRemovalTimer);
      caretRemovalTimer = null;
    }
    let caret = document.getElementById(caretID);
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

  function finishStreamingCaret(root, caretTop) {
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
      caret.style.left = "0";
    }
    root.appendChild(caret);
    caretRemovalTimer = window.setTimeout(function () {
      caretRemovalTimer = null;
      removeStreamingCaret();
      scheduleHeightPost(true);
    }, caretFinalHoldMilliseconds);
  }

  function removeStreamingCaret() {
    const caret = document.getElementById(caretID);
    if (caret && caret.parentNode) {
      caret.parentNode.removeChild(caret);
    }
  }

  function renderStreaming(root, markdownSource) {
    activeStreamingRender = true;
    hasStreamed = true;
    removeStreamingCaret();

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

    ensureStreamingCaret(root);
    scheduleHeightPost(true);
    activeStreamingRender = false;
  }

  window.renderMarkdown = function (markdownSource, options) {
    const root = document.getElementById("markdown-root");
    if (!root) {
      return;
    }

    options = options || {};
    const streaming = options.streaming === true;

    if (streaming) {
      renderStreaming(root, markdownSource);
      return;
    }

    // 非流式（最终）渲染：全量重渲染 + hljs 高亮，归一化所有块
    //（例如流式结束时刚好闭合的代码围栏）
    const preservedHeight = measureRootHeight(root);
    if (preservedHeight > 1) {
      root.style.minHeight = preservedHeight + "px";
    }

    // 先记下流式光标的位置，终态光标绝对定位回原处（见 finishStreamingCaret）
    const existingCaret = document.getElementById(caretID);
    const caretTop = existingCaret ? existingCaret.offsetTop : null;

    removeStreamingCaret();
    renderedBlocks = [];
    root.innerHTML = markdown.render(markdownSource);
    enhanceCodeBlocks(root);
    bindLinks(root);
    // 静止终态：仅在经历过流式的消息上停留一颗静态 ✦，随即淡出
    finishStreamingCaret(root, caretTop);

    root.style.minHeight = "";
    lastPostedHeight = 0;
    observeRootHeight(root);
    scheduleHeightPost(true);
  };
}());
