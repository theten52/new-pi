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
// - 布局锚定（2026-08 三轮迭代，详见 docs/dev-notes/2026-08-30-transcript-scroll-jump.md）：
//   ① ResizeObserver 补偿——WebKit 实测 content-visibility 占位高↔真实高切换
//     不触发 RO（Playwright WebKit 探针 0 事件），方案无效；
//   ② 锚点文档位置 − scrollY 差分看门狗——macOS 异步滚动下 scrollY 读数与视觉
//     位置有帧延迟，差分把滚动本身误判为平移，补偿形成反馈振荡（小范围频繁跳动）。
//   最终方案：Poller（滚动中直接轮询视口上方条目的高度变化，与 scrollY 解耦，
//   无反馈环）+ Warmer（空闲时把全部条目真实高度固化进 contain-intrinsic-size，
//   从源头消除占位高差）。
(function () {
  "use strict";

  const main = document.getElementById("transcript");
  // itemID -> { el, kind, source, streaming, renderer, toolName, toolRunning, toolError, tint }
  const items = new Map();

  // ===== 处理详情分组（BACKLOG-DETAIL-GROUP）=====
  // 组状态模块级、页面生命周期内有效：手动状态不持久化、不回传原生。
  // groupState: turnID -> 当前是否收起；manualOverride: turnID -> 用户已手动干预（一切自动逻辑失效）。
  const groupState = {};
  const manualOverride = {};

  // 全局 fork 锁（FORK-LOCK-GLOBAL）：会话正在流式时原生禁止 fork（forkFromMessage guard !isStreaming）。
  // 历史条目即使自身非流式，也应在全局流式期间禁用其 Fork 按钮，避免点击无反馈。
  let forkLocked = false;

  // 按 turnID 把组内条目的 detail-hidden class 对齐到 groupState，并同步 marker 行的 chevron 方向。
  function applyGroupState(turnID) {
    const collapsed = !!groupState[turnID];
    const nodes = main.querySelectorAll('.detail-item[data-turn-id="' + turnID + '"]');
    for (let i = 0; i < nodes.length; i += 1) {
      if (collapsed) {
        nodes[i].classList.add("detail-hidden");
      } else {
        nodes[i].classList.remove("detail-hidden");
      }
    }
    // 同步 marker（disclosure 行）的 chevron 展示态。
    const markers = main.querySelectorAll('.detail-group[data-turn-id="' + turnID + '"]');
    for (let j = 0; j < markers.length; j += 1) {
      if (collapsed) {
        markers[j].classList.remove("expanded");
      } else {
        markers[j].classList.add("expanded");
      }
    }
  }

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
      if (this.intent === "restoringAnchor") {
        // 恢复模式由截止期限管理（RAF 校正还要继续），不因滚动停驻提前退出；
        // 只有用户滚动输入（onUserScrollInput）能提前接管。
        return;
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
      this.startRestoreLoop();
    },

    // 恢复窗口期内的逐帧校正：content-visibility 未渲染区域用估算高，
    // 冷恢复落点后附近条目渲染出真实高度会引发几何漂移——RAF 循环在窗口内
    // 持续把视口拉回锚点（<1px 差值跳过，稳定后近乎零开销）。
    // 用户滚动输入会先把 intent 改为 userScrolling，循环下一帧即退出，不跟用户抢。
    restoreRAF: null,
    startRestoreLoop: function () {
      if (this.restoreRAF !== null) {
        return;
      }
      const step = () => {
        this.restoreRAF = null;
        if (this.intent !== "restoringAnchor" || !this.restoreTarget) {
          return;
        }
        if (Date.now() > this.restoreDeadline) {
          this.intent = "idle";
          this.restoreTarget = null;
          return;
        }
        this.scrollToAnchor(this.restoreTarget);
        this.restoreRAF = requestAnimationFrame(step);
      };
      this.restoreRAF = requestAnimationFrame(step);
    }
  };

  // ===== 布局锚定：Poller（滚动中轮询补偿）+ Warmer（空闲高度固化） =====

  // 把条目当前真实高度固化为其离屏占位高（仅可见/已渲染条目的 offsetHeight 是真实高；
  // 离屏条目读到的是当前占位高，写入同值无害）。
  function lockIntrinsicHeight(el) {
    const h = el.offsetHeight;
    if (h > 0) {
      const v = "auto " + h + "px";
      if (el.style.containIntrinsicSize !== v) {
        el.style.containIntrinsicSize = v;
      }
    }
  }

  // Poller：滚动活跃期逐帧轮询「视口上方 3 屏内」条目的高度。
  // 占位高→真实高（或反向）会让视口内容平移，变化量 = 补偿量（scrollBy 抵消）。
  // 关键：补偿量直接量自高度变化这个根源，与 scrollY 完全解耦——
  // 高度没变就不产生任何滚动写入，不存在反馈环。
  // 低于视口的条目高度变化不影响可见内容，不轮询。
  const Poller = {
    raf: null,
    activeUntil: 0,
    heights: new Map(), // 轮询窗口内条目 id -> 最近一次高度

    arm: function () {
      // 滚动停后再守 500ms（惯性收尾与停后落地的 CV 解析）。
      this.activeUntil = performance.now() + 500;
      if (this.raf === null) {
        const self = this;
        this.raf = requestAnimationFrame(function () { self.step(); });
      }
    },

    step: function () {
      this.raf = null;
      if (performance.now() > this.activeUntil) {
        this.heights.clear();
        return;
      }
      // pinnedBottom / jumpingToTarget / restoringAnchor 由各自意图逻辑持滚动权，不补偿。
      if (Scroll.intent === "userScrolling" || Scroll.intent === "idle") {
        this.pollAboveViewport();
      }
      const self = this;
      this.raf = requestAnimationFrame(function () { self.step(); });
    },

    pollAboveViewport: function () {
      const y = window.scrollY;
      const lo = y - 3 * window.innerHeight;
      const kids = main.children;
      // 视口顶部锚点下标（第一个底边越过视口顶的条目）。
      let anchorIdx = -1;
      for (let i = 0; i < kids.length; i += 1) {
        const el = kids[i];
        const top = el.getBoundingClientRect().top + y;
        if (top + el.offsetHeight > y) { anchorIdx = i; break; }
        if (top > y) { break; }
      }
      if (anchorIdx <= 0) {
        return;
      }
      let delta = 0;
      const seen = new Set();
      for (let i = anchorIdx - 1; i >= 0; i--) {
        const el = kids[i];
        const top = el.getBoundingClientRect().top + y;
        if (top + el.offsetHeight < lo) { break; }
        const id = el.getAttribute("data-iid");
        const h = el.offsetHeight;
        const old = id === null ? undefined : this.heights.get(id);
        if (id) {
          this.heights.set(id, h);
          seen.add(id);
        }
        if (old !== undefined && old !== h) {
          delta += h - old;
        }
      }
      // 离开轮询窗口的条目清除基线（重进窗口重新取样，防 Map 膨胀）。
      for (const id of this.heights.keys()) {
        if (!seen.has(id)) {
          this.heights.delete(id);
        }
      }
      if (Math.abs(delta) >= 1) {
        window.scrollBy(0, delta);
      }
    }
  };

  // Warmer：空闲时把尚未固化的条目按「距视口由近及远」逐个强制渲染一次，
  // 真实高度写进 contain-intrinsic-size——之后滚出/滚入视口时占位高=真实高，
  // 布局平移从源头消失（渲染过的条目永不再跳）。每个 chunk 用批次锚定纪律
  // 保护视口（高度变化与锚点恢复在同一同步块内，不可见）。
  const Warmer = {
    warmed: new Set(),  // 已固化真实高度的条目 id
    pending: false,

    schedule: function () {
      if (this.pending) {
        return;
      }
      this.pending = true;
      // 直接用 setTimeout(0) 连续推进：预热完成度决定滚动体感的下限，
      // rIC 在 WebKit 可能迟迟不触发；chunk 之间的 0ms 让出已足够渲染线程呼吸。
      const self = this;
      setTimeout(function () {
        self.pending = false;
        self.runChunk();
      }, 0);
    },

    runChunk: function () {
      // 用户主动滚动/跳转中让路（避免滚动中塞布局工作），稍后再试。
      // restoringAnchor 不让路：恢复 RAF 每帧都在校正锚点，预热的高度变化
      // 会被同一纪律覆盖——否则会白等 3s 恢复窗口，用户恰在这几秒内开始滚动。
      if (Scroll.intent === "userScrolling" || Scroll.intent === "jumpingToTarget") {
        this.schedule();
        return;
      }
      const kids = main.children;
      if (kids.length === 0) {
        return;
      }
      const y = window.scrollY;
      // 距视口最近的未预热条目（流式中的条目不预热——高度还在变，流结束后自然入选）。
      let startIdx = -1;
      let startDist = Infinity;
      for (let i = 0; i < kids.length; i += 1) {
        const el = kids[i];
        const id = el.getAttribute("data-iid");
        if (id === null || this.warmed.has(id)) {
          continue;
        }
        const st = items.get(id);
        if (st && st.streaming) {
          continue;
        }
        const top = el.getBoundingClientRect().top + y;
        const dist = Math.abs(top - y);
        if (dist < startDist) {
          startDist = dist;
          startIdx = i;
        }
      }
      if (startIdx < 0) {
        return; // 全部预热完
      }
      // 从最近点向上下扩展取一个 chunk；批次锚定纪律保护视口（同一同步块内恢复）。
      const plan = Scroll.beginBatch();
      const chunk = [kids[startIdx]];
      let up = startIdx - 1;
      let down = startIdx + 1;
      const chunkSize = 10;
      while (chunk.length < chunkSize && (up >= 0 || down < kids.length)) {
        if (down < kids.length) { chunk.push(kids[down]); down += 1; }
        if (chunk.length < chunkSize && up >= 0) { chunk.push(kids[up]); up -= 1; }
      }
      const chunkItems = [];
      for (const el of chunk) {
        const id = el.getAttribute("data-iid");
        if (id === null || this.warmed.has(id)) {
          continue;
        }
        const st = items.get(id);
        if (st && st.streaming) {
          continue;
        }
        el.style.contentVisibility = "visible"; // 强制渲染
        chunkItems.push({ el: el, id: id });
      }
      for (const c of chunkItems) {
        lockIntrinsicHeight(c.el); // 首次读取触发布局（整 chunk 一次 flush）
      }
      for (const c of chunkItems) {
        c.el.style.contentVisibility = ""; // 归还 CV 调度；离屏后占位高=固化的真实高
        this.warmed.add(c.id);
      }
      Scroll.endBatch(plan);
      this.schedule();
    },

    reset: function () {
      this.warmed.clear();
    }
  };

  // 用户输入信号：wheel / 触控板 / 滚动相关按键 → 用户接管 + Poller 进入活跃期。
  window.addEventListener("wheel", function () { Scroll.onUserScrollInput(); Poller.arm(); }, { passive: true, capture: true });
  window.addEventListener("touchmove", function () { Scroll.onUserScrollInput(); Poller.arm(); }, { passive: true, capture: true });
  window.addEventListener("keydown", function (event) {
    const keys = ["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End", " "];
    if (keys.indexOf(event.key) >= 0) {
      Scroll.onUserScrollInput();
      Poller.arm();
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
    Poller.arm();
    // scroll 事件在当帧布局后、绘制前分发：这里直接轮询一次，高度平移可同帧抵消，
    // 避免 rAF（下一帧布局前才跑）晚一拍留下单帧闪动。
    if (Scroll.intent === "userScrolling" || Scroll.intent === "idle") {
      Poller.pollAboveViewport();
    }
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
      // 滚动停下来了，让 Warmer 继续追上进度的固化。
      Warmer.schedule();
    }, 200);
  }, { passive: true });
  window.addEventListener("scrollend", function () {
    if (scrollSettleTimer !== null) {
      window.clearTimeout(scrollSettleTimer);
      scrollSettleTimer = null;
    }
    Scroll.onScrollSettled();
    reportScrollState();
    Warmer.schedule();
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
    // 消息级操作按钮（复制 / 分叉）
    const copyBtn = event.target.closest(".ti-action-copy");
    if (copyBtn) {
      const ti = copyBtn.closest(".ti");
      const state = ti ? items.get(ti.getAttribute("data-iid")) : null;
      const text = state ? (state.source || "") : "";
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.copyText) {
        window.webkit.messageHandlers.copyText.postMessage(text);
      }
      // 复制成功反馈（与代码块复制通道一致）：短暂高亮 + 图标切勾。
      copyBtn.classList.add("copied");
      window.setTimeout(function () {
        copyBtn.classList.remove("copied");
      }, 1000);
      return;
    }
    const forkBtn = event.target.closest(".ti-action-fork");
    if (forkBtn) {
      if (forkBtn.disabled) {
        return;
      }
      const index = Number(forkBtn.getAttribute("data-fork-index"));
      if (Number.isFinite(index) && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.fork) {
        window.webkit.messageHandlers.fork.postMessage({ index: index });
      }
      return;
    }

    const header = event.target.closest(".card-hd");
    if (header) {
      const card = header.closest(".card");
      if (card) {
        card.classList.toggle("expanded");
        // 折叠/展开改变布局：走统一的批次纪律（非底部保持视口锚定）。
        const plan = Scroll.beginBatch();
        Scroll.endBatch(plan);
        scheduleTurnOffsetsReport();
        // 展开态高度变了，已固化的占位高过时——重新预热该条目。
        const ti = card.closest(".ti");
        const id = ti ? ti.getAttribute("data-iid") : null;
        if (id) {
          Warmer.warmed.delete(id);
          Warmer.schedule();
        }
      }
      return;
    }

    // 处理详情组 disclosure 行（BACKLOG-DETAIL-GROUP）：手动切换折叠态。
    const detailRow = event.target.closest(".detail-row");
    if (detailRow) {
      const group = detailRow.closest(".detail-group");
      const turnID = group ? group.getAttribute("data-turn-id") : null;
      if (turnID) {
        const current = !!groupState[turnID];
        groupState[turnID] = !current;
        manualOverride[turnID] = true; // 手动干预后一切自动逻辑失效（需求 4）。
        applyGroupState(turnID);
        // display 切换改变文档高度：走批次纪律保锚（需求 7）。
        const plan = Scroll.beginBatch();
        Scroll.endBatch(plan);
        scheduleTurnOffsetsReport();
      }
      return;
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
    attachActions(bubble, op);
  }

  function renderSystemLike(el, op, cssClass) {
    el.className = "ti " + cssClass;
    el.textContent = "";
    const line = document.createElement("div");
    line.className = "sysline";
    line.textContent = op.body;
    el.appendChild(line);
  }

  // 处理详情组 disclosure 行（BACKLOG-DETAIL-GROUP）：chevron + 「处理详情」文本，整行可点击。
  function renderDetailGroup(el, op) {
    el.className = "ti ti-detail detail-group";
    el.textContent = "";
    el.setAttribute("data-turn-id", op.detailTurnID || "");
    // 手动覆盖优先：无手动干预时才采纳 op.collapsed（自动逻辑目标态）。
    if (!manualOverride[op.detailTurnID]) {
      groupState[op.detailTurnID] = !!op.collapsed;
    }
    // collapsed 态在 el（.detail-group）上用 expanded class 表达（与 applyGroupState 一致），
    // CSS 用它驱动 chevron 方向与组内条目的展示。
    if (groupState[op.detailTurnID]) {
      el.classList.remove("expanded");
    } else {
      el.classList.add("expanded");
    }
    const row = document.createElement("button");
    row.type = "button";
    row.className = "detail-row";
    const chevron = document.createElement("span");
    chevron.className = "detail-chevron";
    row.appendChild(chevron);
    const label = document.createElement("span");
    label.className = "detail-label";
    label.textContent = "处理详情";
    row.appendChild(label);
    el.appendChild(row);
    // 组内条目（可能存在，若先渲染了条目再渲染 marker）按当前组状态对齐。
    applyGroupState(op.detailTurnID);
  }

  // 思考 / 工具卡：header（chevron + 标题胶囊 + 折叠预览）+ 折叠体。
  // ===== 消息级操作按钮（复制 / 分叉）：hover 显示在 user / assistant 条目右上角 =====
  // 复制走 copyText（复用代码块复制通道）；分叉走 fork（回传 messageIndex，原生触发 forkFromMessage）。
  function attachActions(el, op) {
    // 幂等：wrap（含复制按钮）只建一次；fork 按钮独立按 op 元数据双向同步（建/删/禁用）。
    // 注意 fork 创建不能锁在 wrap 的一次性创建块里：直播期首个 upsert 必然无 canFork
    //（messageIndex 在 agentEnd 才补），若那时就把 wrap 定型，后续补 index 的 upsert
    // 再也加不进 fork 按钮（FORK-BUTTON-META-DIFF 的真正根因，恢复会话首 op 带
    // canFork 才侥幸正常，直播路径必现缺失）。
    let wrap = el.querySelector(":scope > .ti-actions");
    if (!wrap) {
      wrap = document.createElement("div");
      wrap.className = "ti-actions";

      const copy = document.createElement("button");
      copy.type = "button";
      copy.className = "ti-action ti-action-copy";
      copy.title = "复制消息";
      copy.setAttribute("aria-label", "复制消息");
      copy.innerHTML =
        '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true">' +
        '<rect x="5.5" y="5.5" width="8" height="8" rx="1.5" stroke="currentColor" stroke-width="1.3"/>' +
        '<path d="M10.5 3.5h-6a1 1 0 0 0-1 1v6" stroke="currentColor" stroke-width="1.3" fill="none"/>' +
        "</svg>";
      wrap.appendChild(copy);
      el.appendChild(wrap);
    }

    // fork 按钮双向同步：有元数据→建/更新；无→摘除（compaction 置空 messageIndex 后
    // 不留死索引）。禁用态 = 本条目流式中或全局流式锁。
    const canFork = op.canFork === true && typeof op.messageIndex === "number";
    let forkBtn = wrap.querySelector(".ti-action-fork");
    if (canFork && !forkBtn) {
      forkBtn = document.createElement("button");
      forkBtn.type = "button";
      forkBtn.className = "ti-action ti-action-fork";
      forkBtn.title = "从这里分叉";
      forkBtn.setAttribute("aria-label", "从这里分叉");
      forkBtn.innerHTML =
        '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true">' +
        '<circle cx="4" cy="4" r="2" stroke="currentColor" stroke-width="1.3"/>' +
        '<circle cx="12" cy="4" r="2" stroke="currentColor" stroke-width="1.3"/>' +
        '<circle cx="12" cy="12" r="2" stroke="currentColor" stroke-width="1.3"/>' +
        '<path d="M4 6v2a2 2 0 0 0 2 2h6" stroke="currentColor" stroke-width="1.3" fill="none"/>' +
        "</svg>";
      wrap.appendChild(forkBtn);
    } else if (!canFork && forkBtn) {
      forkBtn.remove();
      forkBtn = null;
    }
    if (forkBtn) {
      forkBtn.disabled = !!op.streaming || forkLocked;
      forkBtn.dataset.forkIndex = String(op.messageIndex);
    }
  }

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
    // 思考展示最新一行（流式追加在尾部）；工具展示结果首行摘要，
    // 结果为空（Running 中）时回退展示命令本身——折叠态也能看到正在跑什么。
    preview.textContent = isThinking
      ? lastNonEmptyLine(op.body)
      : (firstNonEmptyLine(op.body) || (op.command ? firstNonEmptyLine(op.command) : ""));
    header.appendChild(preview);

    card.appendChild(header);

    // 工具卡展开区：命令（高亮色）与结果用分隔线分开（BACKLOG：工具卡展开展示命令+结果）。
    if (!isThinking && op.command) {
      const cmdEl = document.createElement("pre");
      cmdEl.className = "card-cmd";
      cmdEl.textContent = op.command;
      card.appendChild(cmdEl);
      if (op.body) {
        const sep = document.createElement("div");
        sep.className = "card-sep";
        card.appendChild(sep);
      }
    }

    // 结果为空且已有命令块（Running 中的工具）时不挂空 body，避免展开区出现多余分隔线；
    // 结果到达后结构性重渲染会自然补上。
    if (op.body || isThinking) {
      const bodyEl = document.createElement("pre");
      bodyEl.className = "card-body";
      bodyEl.textContent = op.body;
      card.appendChild(bodyEl);
    }

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
      attachActions(card, op);
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
    // fork 元数据（canFork/messageIndex）不依赖 body/streaming 变化：agentEnd 补 index 的
    // upsert 到达时 body/streaming 均已 final，若把 attachActions 关在上方门控里，
    // 该 upsert 会被静默忽略、Fork 按钮永远缺失（FORK-BUTTON-META-DIFF 的 JS 侧半边）。
    // attachActions 幂等（复用已有按钮），每次 upsert 都同步，成本可忽略。
    const cardEl = el.querySelector(".card.answer");
    if (cardEl) {
      attachActions(cardEl, op);
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
    } else if (op.kind === "detailGroup") {
      // 处理详情 disclosure 行（BACKLOG-DETAIL-GROUP）。
      renderDetailGroup(el, op);
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
      // fork 元数据与渲染门控解耦：user 气泡的按钮也要在「只有 canFork 变化」的
      // upsert 里同步（compaction 撤回时移除按钮），不能只依赖 renderUser 重渲染。
      if (op.kind === "user") {
        const bubble = el.querySelector(":scope > .bubble");
        if (bubble) {
          attachActions(bubble, op);
        }
      }
    }

    // 组内条目归属管理（BACKLOG-DETAIL-GROUP）：thinking/tool/中间 assistant 带 detailTurnID。
    // detailTurnID 有 → 标记为 detail-item（遵守组折叠状态）；无 → 移除（最终答复移出组）。
    applyDetailGroupClass(el, op, state);

    state.kind = op.kind;
    return el;
  }

  // 按 op.detailTurnID 维护条目的 detail-item / data-turn-id / detail-hidden class。
  // 只在归属发生变化时切换，避免无谓 class 抖动。
  // 注意：detailGroup（marker）由 renderDetailGroup 管理其 data-turn-id / expanded，
  // 这里必须跳过，否则 else 分支会把 marker 的 data-turn-id 移除导致点击展开失效。
  function applyDetailGroupClass(el, op, state) {
    if (op.kind === "detailGroup") {
      // marker 的归属管理交给 renderDetailGroup；这里只记录，不清除 data-turn-id。
      state.detailTurnID = op.detailTurnID || null;
      return;
    }
    const isGroupItem = !!op.detailTurnID;
    const prevTurnID = state.detailTurnID || null;
    if (isGroupItem) {
      el.classList.add("detail-item");
      el.setAttribute("data-turn-id", op.detailTurnID);
      // 新条目 / 组归属变化时对齐组状态（折叠态立即隐藏，展开态保持可见）。
      if (prevTurnID !== op.detailTurnID) {
        applyGroupState(op.detailTurnID);
      }
    } else {
      el.classList.remove("detail-item");
      el.classList.remove("detail-hidden");
      el.removeAttribute("data-turn-id");
    }
    state.detailTurnID = op.detailTurnID || null;
  }

  function applyOps(ops) {
    // 滚动纪律：批次开始时按意图决定本批的视口策略，结束后同步执行——
    // 保存锚点 → 变更 → 恢复在同一执行块内，不存在高度未回的中间态。
    // 显式滚动 op（jumpTo/scrollToBottom/restoreAnchor）优先于批次策略。
    const plan = Scroll.beginBatch();
    let explicitScroll = false;
    const touchedEls = []; // 本批 ops 触达的条目（批次结束后固化其真实高度）
    for (const op of ops) {
      if (op.op === "reset") {
        main.textContent = "";
        items.clear();
        Warmer.reset();
        // 分组状态一并清空（页面生命周期内有效，但 reset 表示全新文档，应重置）。
        for (const k in groupState) { delete groupState[k]; }
        for (const k in manualOverride) { delete manualOverride[k]; }
        forkLocked = false;
      } else if (op.op === "forkLock") {
        // 全局 fork 锁切换（FORK-LOCK-GLOBAL）：更新所有已有 fork 按钮的禁用态。
        // 锁住（进入流式）或解锁（流式结束）都只影响 fork 按钮，历史条目自身 streaming 位不变。
        forkLocked = !!op.locked;
        const forkButtons = main.querySelectorAll(".ti-action-fork");
        for (let i = 0; i < forkButtons.length; i += 1) {
          const btn = forkButtons[i];
          const ti = btn.closest(".ti");
          const state = ti ? items.get(ti.getAttribute("data-iid")) : null;
          const selfStreaming = state ? !!state.streaming : false;
          btn.disabled = selfStreaming || forkLocked;
        }
      } else if (op.op === "upsert") {
        touchedEls.push(upsert(op));
      } else if (op.op === "remove") {
        const state = items.get(op.id);
        if (state) {
          state.el.remove();
          items.delete(op.id);
          Warmer.warmed.delete(op.id);
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
    // 批次结束后固化触达条目的真实高度（可见条目是真实高；离屏条目读到占位高，同值无害）。
    for (const el of touchedEls) {
      lockIntrinsicHeight(el);
    }
    // 新内容入场后安排空闲预热。
    if (touchedEls.length > 0) {
      Warmer.schedule();
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
