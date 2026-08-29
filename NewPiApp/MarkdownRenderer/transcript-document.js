// 单文档 transcript（BACKLOG-SINGLE-DOC，Phase 1+2）：整条会话渲染进一个文档，
// 浏览器持布局权与滚动权；原生侧只发意图（upsert/remove/jumpTo/scrollToBottom/restoreAnchor），
// 永不消费内容高度。
//
// 每条 transcript item 一个 .ti 元素，以 item id 为锚做增量 upsert；
// assistant/summary 的正文用 createMarkdownRenderer 的 per-root 实例做块级增量。
//
// Phase 2（滚动收敛入文档）：
// - Scroll 模块是文档内滚动的唯一 writer（意图状态机）；
// - 内容变更时的视口稳定在同一同步块内完成（保存锚点→变更→恢复），
//   不存在「高度还没回来」的中间态（对比：遗留路径跨原生↔Web 异步边界尽力而为）；
// - 锚点（视口顶部条目 id + 条目内偏移）随滚动状态上报原生持久化，切换/冷启动恢复。
(function () {
  "use strict";

  const main = document.getElementById("transcript");
  // itemID -> { el, kind, source, streaming, renderer, toolName, toolRunning, toolError, tint }
  const items = new Map();

  // ===== Scroll：文档内滚动的唯一 writer（osaurus ScrollAnchorManager 算法同构，
  // 但同步执行：保存→变更→恢复在同一执行块，不可能被其他 writer 插队） =====
  const nearBottomThreshold = 100;

  const Scroll = {
    // idle | pinnedBottom | userScrolling | jumpingToTarget | restoringAnchor
    intent: "idle",
    // restoringAnchor 模式下的目标锚点与截止期限（有界校正，防无限跟随）。
    restoreTarget: null,
    restoreDeadline: 0,

    isNearBottom: function () {
      return (document.documentElement.scrollHeight - window.scrollY - window.innerHeight) < nearBottomThreshold;
    },

    // 视口顶部第一个可见条目的锚点：{id, delta}（delta = scrollY 距该条目顶部的偏移）。
    topAnchor: function () {
      const y = window.scrollY;
      const kids = main.children;
      for (let i = 0; i < kids.length; i += 1) {
        const el = kids[i];
        const top = el.getBoundingClientRect().top + y;
        if (top + el.offsetHeight > y) {
          return { id: el.getAttribute("data-iid"), delta: y - top };
        }
      }
      return null;
    },

    // 按锚点重算 scrollY；差值 <1px 跳过（断反馈环，同 osaurus 规则）。
    scrollToAnchor: function (anchor) {
      if (!anchor || !anchor.id) {
        return false;
      }
      const el = main.querySelector('[data-iid="' + anchor.id + '"]');
      if (!el) {
        return false;
      }
      const target = el.getBoundingClientRect().top + window.scrollY + anchor.delta;
      if (Math.abs(window.scrollY - target) >= 1) {
        window.scrollTo(0, target);
      }
      return true;
    },

    pinBottom: function () {
      window.scrollTo(0, document.documentElement.scrollHeight);
    },

    // 内容批次变更的统一入口纪律：返回是否需要在本批结束后钉底。
    // - pinnedBottom：内容增长继续钉底（流式跟随）。
    // - userScrolling / idle（非底部）：保持视口不动（锚点保住）。
    // - jumpingToTarget：不动（跳转进行中，内容变化不抢）。
    // - restoringAnchor：恢复窗口期内每批结束重校锚点（几何未长全也不丢位置）。
    beginBatch: function () {
      if (this.intent === "pinnedBottom") {
        return { pin: true };
      }
      if (this.intent === "jumpingToTarget") {
        return {};
      }
      if (this.intent === "restoringAnchor") {
        return { anchor: this.restoreTarget };
      }
      if (this.intent === "userScrolling" || !this.isNearBottom()) {
        return { anchor: this.topAnchor() };
      }
      // idle 且在底部附近：跟随钉底。
      return { pin: true };
    },

    endBatch: function (plan) {
      if (plan.pin) {
        this.pinBottom();
      } else if (plan.anchor) {
        this.scrollToAnchor(plan.anchor);
      }
      // restoringAnchor 到期退出（有界）。
      if (this.intent === "restoringAnchor" && Date.now() > this.restoreDeadline) {
        this.intent = "idle";
        this.restoreTarget = null;
      }
    },

    // 用户主动滚动（滚轮/触控板/滚动按键）：接管滚动，取消一切程序跟随。
    onUserScrollInput: function () {
      this.intent = "userScrolling";
      this.restoreTarget = null;
    },

    // 滚动停止（scrollend 或 debounce 兜底）：落底则回钉底态，否则归 idle。
    onScrollSettled: function () {
      if (this.intent === "jumpingToTarget" || this.intent === "restoringAnchor") {
        // 跳转/恢复结束：按落点决定后续。
      }
      this.intent = this.isNearBottom() ? "pinnedBottom" : "idle";
    },

    jumpTo: function (id) {
      const state = items.get(id);
      if (!state) {
        return;
      }
      this.intent = "jumpingToTarget";
      state.el.scrollIntoView({ block: "start", behavior: "smooth" });
    },

    scrollToBottom: function (smooth) {
      this.intent = "pinnedBottom";
      if (smooth) {
        window.scrollTo({ top: document.documentElement.scrollHeight, behavior: "smooth" });
      } else {
        this.pinBottom();
      }
    },

    restoreAnchor: function (anchor, fallbackOffset) {
      this.restoreTarget = anchor;
      this.restoreDeadline = Date.now() + 3000;
      this.intent = "restoringAnchor";
      if (!this.scrollToAnchor(anchor)) {
        // 锚点条目不存在（条目被删/旧会话）：退到绝对 offset，再没有就落底。
        if (typeof fallbackOffset === "number" && fallbackOffset > 0) {
          window.scrollTo(0, fallbackOffset);
        } else {
          this.scrollToBottom(false);
        }
      }
    }
  };

  // 用户输入信号：wheel / 滚动相关按键 → 用户接管。
  window.addEventListener("wheel", function () { Scroll.onUserScrollInput(); }, { passive: true, capture: true });
  window.addEventListener("touchmove", function () { Scroll.onUserScrollInput(); }, { passive: true, capture: true });
  window.addEventListener("keydown", function (event) {
    const keys = ["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End", " "];
    if (keys.indexOf(event.key) >= 0) {
      Scroll.onUserScrollInput();
    }
  });

  // ===== 状态上报（JS → 原生）：nearBottom / scrollTop / 锚点 / 意图；节流 120ms =====
  let lastScrollReport = null;
  let scrollReportTimer = null;
  let scrollSettleTimer = null;

  function reportScrollState() {
    const anchor = Scroll.topAnchor();
    const payload = {
      nearBottom: Scroll.isNearBottom(),
      scrollTop: Math.round(window.scrollY),
      anchorID: anchor ? anchor.id : null,
      anchorDelta: anchor ? Math.round(anchor.delta) : 0,
      intent: Scroll.intent
    };
    const key = payload.nearBottom + "|" + payload.scrollTop + "|" + (payload.anchorID || "") + "|" + payload.anchorDelta + "|" + payload.intent;
    if (key === lastScrollReport) {
      return;
    }
    lastScrollReport = key;
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.scrollState) {
      window.webkit.messageHandlers.scrollState.postMessage(payload);
    }
  }

  window.addEventListener("scroll", function () {
    if (scrollReportTimer === null) {
      scrollReportTimer = window.setTimeout(function () {
        scrollReportTimer = null;
        reportScrollState();
      }, 120);
    }
    // scrollend 实测可用（Safari 18）；200ms 无事件作兜底，双保险。
    if (scrollSettleTimer !== null) {
      window.clearTimeout(scrollSettleTimer);
    }
    scrollSettleTimer = window.setTimeout(function () {
      scrollSettleTimer = null;
      Scroll.onScrollSettled();
      reportScrollState();
    }, 200);
  }, { passive: true });
  window.addEventListener("scrollend", function () {
    if (scrollSettleTimer !== null) {
      window.clearTimeout(scrollSettleTimer);
      scrollSettleTimer = null;
    }
    Scroll.onScrollSettled();
    reportScrollState();
  });

  // ===== turn offsets 上报（rail minimap 数据源）：user 条目的文档内相对位置 =====
  let turnOffsetsTimer = null;
  function reportTurnOffsets() {
    const total = document.documentElement.scrollHeight;
    if (total <= 0) {
      return;
    }
    const offsets = [];
    items.forEach(function (state, id) {
      if (state.kind === "user") {
        const top = state.el.getBoundingClientRect().top + window.scrollY;
        offsets.push({ id: id, frac: Math.min(1, Math.max(0, top / total)) });
      }
    });
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.turnOffsets) {
      window.webkit.messageHandlers.turnOffsets.postMessage({ offsets: offsets });
    }
  }
  function scheduleTurnOffsetsReport() {
    if (turnOffsetsTimer !== null) {
      return;
    }
    turnOffsetsTimer = window.setTimeout(function () {
      turnOffsetsTimer = null;
      reportTurnOffsets();
    }, 250);
  }

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
      // 折叠/展开改变布局：走统一的批次纪律（非底部保持视口锚定）。
      const plan = Scroll.beginBatch();
      Scroll.endBatch(plan);
      scheduleTurnOffsetsReport();
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
  }

  function applyOps(ops) {
    // 滚动纪律：批次开始时按意图决定本批的视口策略，结束后同步执行——
    // 保存锚点 → 变更 → 恢复在同一执行块内，不存在高度未回的中间态。
    // 显式滚动 op（jumpTo/scrollToBottom/restoreAnchor）优先于批次策略。
    const plan = Scroll.beginBatch();
    let explicitScroll = false;
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
        explicitScroll = true;
        Scroll.jumpTo(op.id);
      } else if (op.op === "scrollToBottom") {
        explicitScroll = true;
        Scroll.scrollToBottom(!!op.smooth);
      } else if (op.op === "restoreAnchor") {
        explicitScroll = true;
        Scroll.restoreAnchor(
          { id: op.id, delta: op.delta || 0 },
          typeof op.offset === "number" ? op.offset : 0
        );
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
    if (!explicitScroll) {
      Scroll.endBatch(plan);
    }
    reportScrollState();
    scheduleTurnOffsetsReport();
  }

  window.transcriptDoc = {
    apply: function (opsJSON) {
      applyOps(JSON.parse(opsJSON));
    }
  };
}());
