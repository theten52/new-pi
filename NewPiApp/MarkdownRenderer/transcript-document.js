// 单文档 transcript（BACKLOG-SINGLE-DOC，Phase 1）：整条会话渲染进一个文档，
// 浏览器持布局权与滚动权；原生侧只发意图（upsert/remove/jumpTo/scrollToBottom），
// 永不消费内容高度。
//
// 每条 transcript item 一个 .ti 元素，以 item id 为锚做增量 upsert；
// assistant/summary 的正文用 createMarkdownRenderer 的 per-root 实例做块级增量。
(function () {
  "use strict";

  const main = document.getElementById("transcript");
  // itemID -> { el, kind, source, streaming, renderer, toolName, toolRunning, toolError, tint }
  const items = new Map();

  // ===== 自动钉底：仅当用户原本在底部附近才跟随（与原生语义一致） =====
  const nearBottomThreshold = 100;
  let lastReportedNearBottom = null;

  function isNearBottom() {
    return (document.documentElement.scrollHeight - window.scrollY - window.innerHeight) < nearBottomThreshold;
  }

  function reportScrollState() {
    const near = isNearBottom();
    if (near === lastReportedNearBottom) {
      return;
    }
    lastReportedNearBottom = near;
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.scrollState) {
      window.webkit.messageHandlers.scrollState.postMessage({ nearBottom: near });
    }
  }

  let scrollStateTimer = null;
  window.addEventListener("scroll", function () {
    if (scrollStateTimer !== null) {
      return;
    }
    scrollStateTimer = window.setTimeout(function () {
      scrollStateTimer = null;
      reportScrollState();
    }, 120);
  }, { passive: true });

  // ===== 折叠卡片（思考 / 工具）：事件委托，JS 切 class（不用 <details>——
  // Safari 18.0 的 <details> + content-visibility 有展开失效回归，WebKit #277573） =====
  main.addEventListener("click", function (event) {
    const header = event.target.closest(".card-hd");
    if (!header) {
      return;
    }
    const card = header.closest(".card");
    if (card) {
      card.classList.toggle("expanded");
    }
  });

  function lastNonEmptyLine(text) {
    const lines = text.split("\n");
    for (let i = lines.length - 1; i >= 0; i -= 1) {
      const trimmed = lines[i].trim();
      if (trimmed) {
        return trimmed;
      }
    }
    return "";
  }

  function firstNonEmptyLine(text) {
    const lines = text.split("\n");
    for (let i = 0; i < lines.length; i += 1) {
      const trimmed = lines[i].trim();
      if (trimmed) {
        return trimmed;
      }
    }
    return "";
  }

  // ===== 各类条目的 DOM 构建 =====

  function makeRow() {
    const el = document.createElement("div");
    el.className = "ti";
    return el;
  }

  function applyTint(el, tint) {
    if (tint === null || tint === undefined) {
      el.style.removeProperty("--tint");
    } else {
      el.style.setProperty("--tint", String(tint));
    }
  }

  function renderUser(el, op) {
    el.className = "ti ti-user";
    applyTint(el, op.tint);
    el.textContent = "";
    const bubble = document.createElement("div");
    bubble.className = "bubble";
    bubble.textContent = op.body;
    el.appendChild(bubble);
  }

  function renderSystemLike(el, op, cssClass) {
    el.className = "ti " + cssClass;
    el.textContent = "";
    const line = document.createElement("div");
    line.className = "sysline";
    line.textContent = op.body;
    el.appendChild(line);
  }

  // 思考 / 工具卡：header（chevron + 标题胶囊 + 折叠预览）+ 折叠体。
  function renderCard(el, op, state) {
    const isThinking = op.kind === "thinking";
    el.className = "ti " + (isThinking ? "ti-thinking" : "ti-tool");
    el.textContent = "";

    const card = document.createElement("div");
    card.className = "card" + (op.toolError ? " is-error" : "");

    const header = document.createElement("button");
    header.type = "button";
    header.className = "card-hd";

    const chevron = document.createElement("span");
    chevron.className = "card-chevron";
    header.appendChild(chevron);

    const title = document.createElement("span");
    title.className = "card-title" + (isThinking ? " thinking" : "");
    if (isThinking) {
      title.textContent = op.streaming ? "Thinking…" : "Thinking";
    } else {
      title.textContent = op.toolName || "tool";
    }
    header.appendChild(title);

    if (!isThinking) {
      const badge = document.createElement("span");
      badge.className = "card-badge" + (op.toolError ? " error" : op.toolRunning ? " running" : "");
      badge.textContent = op.toolRunning ? "Running" : op.toolError ? "Failed" : "Done";
      header.appendChild(badge);
    } else if (op.streaming) {
      const badge = document.createElement("span");
      badge.className = "card-badge running";
      badge.textContent = "···";
      header.appendChild(badge);
    }

    const preview = document.createElement("span");
    preview.className = "card-preview";
    // 思考展示最新一行（流式追加在尾部）；工具输出展示首行摘要
    preview.textContent = isThinking ? lastNonEmptyLine(op.body) : firstNonEmptyLine(op.body);
    header.appendChild(preview);

    card.appendChild(header);

    const bodyEl = document.createElement("pre");
    bodyEl.className = "card-body";
    bodyEl.textContent = op.body;
    card.appendChild(bodyEl);

    el.appendChild(card);
  }

  // assistant/summary：卡片头 + markdown article（per-root 渲染器实例）
  function renderAssistant(el, op, state) {
    el.className = "ti ti-answer";
    applyTint(el, op.tint);
    if (!state.renderer) {
      el.textContent = "";
      const card = document.createElement("div");
      card.className = "card answer";
      const hd = document.createElement("div");
      hd.className = "answer-hd";
      hd.textContent = op.kind === "summary" ? "Summary" : "NewPi";
      const article = document.createElement("article");
      article.className = "markdown-body article";
      card.appendChild(hd);
      card.appendChild(article);
      el.appendChild(card);
      // 单文档内不报高度、不回传产物（浏览器自持布局；replay 缓存是遗留路径的资产）
      state.renderer = window.createMarkdownRenderer(article, {
        reportHeight: false,
        postSnapshot: false,
        caret: true
      });
      state.source = null;
      state.streaming = null;
    }
    if (state.source !== op.body || state.streaming !== op.streaming) {
      if (op.streaming) {
        state.renderer.renderStreaming(op.body);
      } else {
        state.renderer.renderFinal(op.body);
      }
      state.source = op.body;
      state.streaming = op.streaming;
    }
  }

  // ===== ops 应用 =====

  function upsert(op) {
    const wasNearBottom = isNearBottom();
    let state = items.get(op.id);
    let el = state ? state.el : null;

    const structuralKinds = ["user", "system", "error", "thinking", "tool"];
    if (!el) {
      el = makeRow();
      el.setAttribute("data-iid", op.id);
      state = { el: el, kind: null, source: null, streaming: null, renderer: null };
      items.set(op.id, state);
      main.appendChild(el);
    }

    if (op.kind === "assistant" || op.kind === "summary") {
      renderAssistant(el, op, state);
    } else if (structuralKinds.indexOf(op.kind) >= 0) {
      // 结构性条目内容整体替换（思考/工具流式期 body 会增长，重渲染成本可忽略——纯文本节点）
      if (state.source !== op.body || state.streaming !== op.streaming ||
          state.toolRunning !== op.toolRunning || state.toolError !== op.toolError ||
          state.kind !== op.kind) {
        if (op.kind === "user") {
          renderUser(el, op);
        } else if (op.kind === "system") {
          renderSystemLike(el, op, "ti-system");
        } else if (op.kind === "error") {
          renderSystemLike(el, op, "ti-error");
        } else {
          renderCard(el, op, state);
        }
        state.source = op.body;
        state.streaming = op.streaming;
        state.toolRunning = op.toolRunning;
        state.toolError = op.toolError;
      }
    }
    state.kind = op.kind;

    // 内容增长后若原本钉底，继续钉底
    if (wasNearBottom) {
      window.scrollTo(0, document.documentElement.scrollHeight);
    }
  }

  function applyOps(ops) {
    for (const op of ops) {
      if (op.op === "reset") {
        main.textContent = "";
        items.clear();
      } else if (op.op === "upsert") {
        upsert(op);
      } else if (op.op === "remove") {
        const state = items.get(op.id);
        if (state) {
          state.el.remove();
          items.delete(op.id);
        }
      } else if (op.op === "jumpTo") {
        const state = items.get(op.id);
        if (state) {
          state.el.scrollIntoView({ block: "start", behavior: "smooth" });
        }
      } else if (op.op === "scrollToBottom") {
        window.scrollTo({ top: document.documentElement.scrollHeight, behavior: "smooth" });
      } else if (op.op === "order") {
        // 结构重排（fork 重建等）：按给定 id 序列重挂节点（appendChild 移动已有节点）。
        for (const id of op.ids) {
          const state = items.get(id);
          if (state) {
            main.appendChild(state.el);
          }
        }
      }
    }
    reportScrollState();
  }

  window.transcriptDoc = {
    apply: function (opsJSON) {
      applyOps(JSON.parse(opsJSON));
    }
  };
}());
