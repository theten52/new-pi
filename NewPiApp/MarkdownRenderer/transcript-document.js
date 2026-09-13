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
  const actionButtons = new WeakMap();
  let approvalState = null;
  const approvalReceipts = new Map();
  let dateContext = "";
  let footersDirty = false;

  // 图形仅取本地常量，任何模型/工具文本都不进入 SVG/HTML。
  const iconPaths = {
    done: '<path d="m5 12 4 4L19 6"/>',
    pending: '<circle cx="12" cy="12" r="8"/>',
    running: '<path d="M3 12h4l3-7 4 14 3-7h4"/>',
    stopped: '<rect x="6" y="6" width="12" height="12" rx="2"/>',
    error: '<path d="m12 3 10 18H2zM12 9v5M12 17h.01"/>',
    copy: '<rect x="8" y="8" width="12" height="13" rx="2"/><path d="M15 8V3H3v13h5"/>',
    shield: '<path d="m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6z"/><path d="m8 12 3 3 5-6"/>',
    file: '<path d="M5 3h9l5 5v13H5zM14 3v6h5M9 13h6M9 17h6"/>',
    retry: '<path d="M3 11a9 9 0 1 1 3 8M3 4v7h7"/>',
    chevron: '<path d="m9 5 7 7-7 7"/>'
  };
  function icon(name) {
    const span = textElement("span", "transcript-icon icon-" + name, "");
    span.setAttribute("aria-hidden", "true");
    span.innerHTML = '<svg viewBox="0 0 24 24" focusable="false">' + (iconPaths[name] || iconPaths.running) + '</svg>';
    return span;
  }
  function toolStatus(tool) {
    // 真实失败优先；停止只表示原生报告的未结束调用，不改写执行结果。
    return tool.toolError ? "error" : tool.interrupted ? "stopped" : tool.toolRunning ? "running" : "done";
  }
  const statusLabels = { done: "已完成", running: "进行中", error: "失败", stopped: "已停止" };
  function finiteDuration(seconds) { return typeof seconds === "number" && Number.isFinite(seconds) && seconds >= 0; }
  function requestCopy(button, text, label, valid) {
    window.newPiCopy?.request(button, text, label, valid);
  }

  // 只消费 Core 的结构化字段；未知/非法数据不是 0，也不是执行证明。
  function progressReport(value) {
    if (!value || value.source !== "agentReport" || !Array.isArray(value.steps)) return null;
    const ids = new Set();
    for (const step of value.steps) {
      if (!step || typeof step.id !== "string" || !step.id.trim() || ids.has(step.id) ||
          typeof step.title !== "string" || !step.title.trim() ||
          !["pending", "inProgress", "completed"].includes(step.status)) return null;
      ids.add(step.id);
    }
    return value;
  }

  function testReport(value) {
    if (!value || value.source !== "JUnit" || typeof value.path !== "string" || !value.path.trim() ||
        ![value.passed, value.failed, value.skipped, value.total].every(n => Number.isSafeInteger(n) && n >= 0) ||
        value.total !== value.passed + value.failed + value.skipped) return null;
    return value;
  }

  function testReportSegments(tools) {
    // 已解析报告按当前 turn/speech 内路径取最后一次读取，不去重不同作用域。
    const latest = new Map();
    for (const tool of tools) {
      if (tool.testReport) latest.set(tool.testReport.path, tool.testReport);
    }
    if (!latest.size) return [];
    const reports = [...latest.values()];
    const totals = reports.reduce((sum, report) => ({
      passed: sum.passed + report.passed, failed: sum.failed + report.failed, skipped: sum.skipped + report.skipped
    }), { passed: 0, failed: 0, skipped: 0 });
    const countText = report => `通过 ${report.passed} · 失败 ${report.failed} · 跳过 ${report.skipped}`;
    return [
      { icon: totals.failed ? "error" : "file", className: "result-test-summary",
        text: "JUnit 报告汇总：" + (Object.values(totals).every(Number.isSafeInteger) ? countText(totals) : "计数超出显示范围") },
      ...reports.map(report => ({ icon: "file", className: "result-test-source",
        text: `${report.source} · ${report.path}：${countText(report)}` })),
      { icon: "file", className: "result-test-notice", text: "仅为已读取的测试报告，不保证报告新鲜度或对应当前代码。" }
    ];
  }

  function positionApproval() {
    const anchored = new Map();
    for (const state of [...approvalReceipts.values(), ...(approvalState ? [approvalState] : [])]) {
      const anchor = anchored.get(state.afterID) || items.get(state.afterID)?.el;
      const next = anchor ? anchor.nextSibling : main.firstChild;
      if (next !== state.el) main.insertBefore(state.el, next);
      anchored.set(state.afterID, state.el);
    }
  }

  function applyApprovalReceipt(op) {
    const state = approvalState;
    if (!state || state.id !== op.id || state.nonce !== op.nonce ||
        !["approved", "denied", "cancelled"].includes(op.outcome)) return;
    state.el.textContent = "";
    state.el.className = "ti ti-approval-receipt";
    state.el.setAttribute("aria-label", "审批结果");
    state.el.setAttribute("role", "status");
    state.el.append(icon(op.outcome === "approved" ? "done" : op.outcome === "denied" ? "shield" : "stopped"),
      textElement("span", "approval-result-text", op.message));
    state.el.dataset.outcome = op.outcome;
    approvalReceipts.set(state.id, state);
    approvalState = null;
    Warmer.warmed.delete(state.id);
  }

  function applyApproval(op) {
    if (approvalState && approvalState.id === op.id && approvalState.nonce === op.nonce) return;
    if (approvalState) {
      approvalState.el.remove();
      Warmer.warmed.delete(approvalState.id);
    }
    approvalState = null;
    if (!op.id) return;
    const el = textElement("section", "ti ti-approval", "");
    el.dataset.iid = op.id;
    el.setAttribute("aria-label", "待审批工具");
    const state = { id: op.id, nonce: op.nonce, el, afterID: op.afterID, claimed: false };
    approvalState = state;
    const title = textElement("h3", "approval-title", "需要你的确认 · " + op.toolName);
    title.prepend(icon("shield"));
    title.appendChild(textElement("span", "approval-risk", op.risk || "风险未标注"));
    el.appendChild(title);
    if (op.reason) el.appendChild(textElement("p", "approval-reason", op.reason));
    if (op.role) el.appendChild(textElement("p", "approval-role", "角色：" + op.role));
    el.appendChild(textElement("p", "approval-directory", "工作目录：" + op.directory));
    el.appendChild(textElement("pre", "approval-summary", op.summary || ""));
    el.appendChild(textElement("p", "approval-notice", "拟执行操作，尚未执行；文件可能在执行前变化。"));
    const actions = textElement("div", "approval-actions", "");
    function button(label, action, scope) {
      const btn = textElement("button", "approval-action approval-" + action, label);
      if (action === "approve" && scope === "once") btn.classList.add("approval-primary");
      btn.type = "button";
      // 能力只在闭包中，不放 DOM dataset；模型输出不能通过相同 class/href 冒充。
      btn.addEventListener("click", () => {
        if (approvalState !== state || state.claimed || !btn.isConnected || btn.disabled) return;
        const handler = window.webkit?.messageHandlers?.transcriptApproval;
        if (!handler) return;
        state.claimed = true;
        actions.querySelectorAll("button").forEach(b => { b.disabled = true; });
        handler.postMessage({ id: op.id, nonce: op.nonce, requestID: op.requestID, action, scope });
      });
      actions.appendChild(btn);
    }
    button("拒绝", "deny");
    for (const scope of op.scopes || []) {
      const label = scope === "once" ? "允许一次" : scope === "session" ? (op.isRoom ? "本聊天室内允许 " : "本对话内允许 ") + op.toolName : "一直允许 " + op.toolName;
      button(label, "approve", scope);
    }
    el.appendChild(actions);
    el.appendChild(textElement("p", "approval-scope", "记忆授权覆盖所选范围内该类工具的非高危调用；高危仅允许一次。"));
    main.appendChild(el);
    positionApproval();
  }

  // 每个用户轮次/角色发言只保留一个最终结果条；未完成/中间正文不冒充 final。
  function syncAnswerFooters() {
    const scopes = new Map();
    const wanted = new Map();
    for (const el of main.children) {
      const state = items.get(el.dataset.iid);
      if (!state) continue;
      // Session 在 user/summary 切轮；room 用原生显式 role+speechID，插话不改写既有发言身份。
      if (state.kind === "user" || state.kind === "summary") { scopes.delete("session"); continue; }
      const scope = state.resultScopeID || "session";
      const turn = scopes.get(scope) || { tools: [], final: null };
      scopes.set(scope, turn);
      if (state.kind === "tool") turn.tools.push(state);
      if (state.kind !== "assistant" || state.answerState !== "final" || state.streaming || state.detailTurnID) continue;
      if (turn.final) wanted.delete(turn.final);
      turn.final = state;
      const tools = [...new Set(turn.tools)];
      const completed = tools.filter(t => toolStatus(t) === "done");
      const failed = tools.filter(t => t.toolError).length;
      const running = tools.filter(t => toolStatus(t) === "running").length;
      const stopped = tools.filter(t => toolStatus(t) === "stopped").length;
      const changes = completed.flatMap(t => t.fileChanges || []);
      const paths = new Set(changes.map(c => c.path));
      const timed = tools.filter(t => finiteDuration(t.durationSeconds) && toolStatus(t) !== "running");
      const seconds = timed.reduce((sum, t) => sum + t.durationSeconds, 0);
      const segments = [{ icon: failed ? "error" : stopped ? "stopped" : running ? "running" : "done",
        text: tools.length ? `工具成功 ${completed.length} · 失败 ${failed} · 未完成 ${running + stopped}` + (stopped ? `（已停止 ${stopped}）` : "") : "本轮未调用工具" }];
      if (timed.length) segments.push({ icon: "running", text: `已记录工具耗时 ${seconds.toFixed(2)} 秒` + (timed.length < tools.length ? "（部分）" : "") });
      if (changes.length) segments.push({ icon: "file", text: `文件编辑记录 ${changes.length} 次 / ${paths.size} 个路径` });
      wanted.set(state, { segments, reportTools: turn.tools });
    }
    // 报告在全作用域扫描后归并；交错/迟到的读取也属于其显式发言，不能被 final 的 DOM 位置截断。
    for (const result of wanted.values()) {
      result.segments.push(...testReportSegments(result.reportTools));
      delete result.reportTools;
    }
    items.forEach(state => {
      const result = wanted.get(state);
      const key = result ? JSON.stringify(result) : null;
      if (state.footerKey === key) return;
      state.footerKey = key;
      if (state.footer) state.footer.remove();
      state.footer = null;
      if (!result) {
        const wrap = state.el.querySelector('.card.answer > .ti-actions');
        if (wrap) syncTopCopy(wrap, state);
        return;
      }
      const footer = textElement("footer", "answer-footer", "");
      state.footer = footer;
      const actions = textElement("div", "answer-actions", "");
      const copy = textElement("button", "answer-copy", "复制回答");
      copy.type = "button";
      copy.prepend(icon("copy"));
      copy.addEventListener("click", () => {
        const valid = () => items.get(state.el.dataset.iid) === state && state.footer === footer &&
            footer.isConnected && copy.parentElement === actions && actions.parentElement === footer;
        if (!valid()) return;
        requestCopy(copy, state.source || "", "复制回答", valid);
      });
      actions.append(copy);
      const strip = textElement("div", "result-strip", "");
      result.segments.forEach(segment => {
        const cell = textElement("span", "result-segment" + (segment.className ? " " + segment.className : ""), segment.text);
        cell.prepend(icon(segment.icon));
        strip.appendChild(cell);
      });
      footer.append(actions, strip);
      state.el.querySelector(".card.answer").appendChild(footer);
      syncTopCopy(state.el.querySelector('.card.answer > .ti-actions'), state);
      Warmer.warmed.delete(state.el.dataset.iid);
    });
  }

  // ===== 处理详情分组（BACKLOG-DETAIL-GROUP）=====
  // 组状态模块级、页面生命周期内有效：手动状态不持久化、不回传原生。
  // groupState: turnID -> 当前是否收起；manualOverride: turnID -> 用户已手动干预（一切自动逻辑失效）。
  const groupState = Object.create(null);
  const manualOverride = Object.create(null);

  // 全局 fork 锁（FORK-LOCK-GLOBAL）：会话正在流式时原生禁止 fork（forkFromMessage guard !isStreaming）。
  // 历史条目即使自身非流式，也应在全局流式期间禁用其 Fork 按钮，避免点击无反馈。
  let forkLocked = false;

  // 按 turnID 把组内条目的 detail-hidden class 对齐到 groupState，并同步 marker 行的 chevron 方向。
  function applyGroupState(turnID) {
    const collapsed = !!groupState[turnID];
    const nodes = Array.from(main.querySelectorAll('.detail-item')).filter(el => el.dataset.turnId === turnID);
    for (let i = 0; i < nodes.length; i += 1) {
      if (collapsed) {
        nodes[i].classList.add("detail-hidden");
      } else {
        nodes[i].classList.remove("detail-hidden");
      }
    }
    // 同步 marker（disclosure 行）的 chevron 展示态。
    const markers = Array.from(main.querySelectorAll('.detail-group')).filter(el => el.dataset.turnId === turnID);
    for (let j = 0; j < markers.length; j += 1) {
      const row = markers[j].querySelector(".detail-row");
      if (row) row.setAttribute("aria-expanded", String(!collapsed));
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
    // 最近一次程序滚动的时刻：scroll 事件据此区分「程序钉底/锚点校正」与
    // 「滚动条拖拽」（后者不发 wheel，必须靠 scroll 事件识别用户接管）。
    lastProgrammaticScrollAt: 0,

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
      this.lastProgrammaticScrollAt = Date.now();
      const target = el.getBoundingClientRect().top + window.scrollY + anchor.delta;
      if (Math.abs(window.scrollY - target) >= 1) {
        window.scrollTo(0, target);
      }
      return true;
    },

    pinBottom: function () {
      this.lastProgrammaticScrollAt = Date.now();
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
      // 流式钉底的维持不在 beginBatch：onScrollSettled 保证 pinnedBottom 在流式
      // 期间不降级（大块内容后布局导致的「未近底」不再误释放），本分支保持原
      // 语义——jumpTo 落点/锚点恢复位置不被迫拽回底部。
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
      // 流式期间钉底不因「内容长高导致的未近底」而释放（bd92de0 的意图），
      // 但也不在此补钉：settle→pinBottom 会形成「每次 flush 都多一轮强制布局 +
      // scroll 事件 → Poller/Warmer 重武装」的持续活跃链，页面在流式期间
      // 永不间断地跑渲染更新（STALL 回归根因）。下一批内容的 endBatch(pin)
      // 自会追平新高度（间隔即 flush 节奏，不可感知）。
      if (forkLocked && this.intent === "pinnedBottom") {
        return;
      }
      // PIN-FIX：钉底宽限期内同样不降级——发送→forkLock 空窗（数百毫秒~数秒）内
      // 布局噪声（分组收起/估算高校正）可让 settle 瞬间未近底，按旧逻辑会把
      // pinnedBottom 误贬为 idle，钉底永久丢失（与拖拽误判同一根因的另一条路径）。
      // 宽限过期后恢复「不近底即降级」，用户拖走仍能正常脱离钉底。
      if (this.intent === "pinnedBottom"
          && Date.now() - this.lastProgrammaticScrollAt < 1500) {
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
      // 平滑滚动持续数百毫秒：期间抑制用户接管误判（时间戳写到未来）
      this.lastProgrammaticScrollAt = Date.now() + 700;
      state.el.scrollIntoView({ block: "start", behavior: "smooth" });
      Poller.arm();
    },

    scrollToBottom: function (smooth) {
      this.intent = "pinnedBottom";
      if (smooth) {
        this.lastProgrammaticScrollAt = Date.now() + 600;
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
        // 到达边界的滚轮/同位置跳转可能不产生 scrollend，仍需恢复空闲预热。
        if (Scroll.intent === "userScrolling" || Scroll.intent === "jumpingToTarget") {
          Scroll.onScrollSettled();
          Warmer.schedule();
        }
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
      if (this.pending || forkLocked ||
          Scroll.intent === "userScrolling" || Scroll.intent === "jumpingToTarget") {
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
      // 用户主动滚动/跳转中让路，由滚动结束重新唤醒，不持续排空转计时器。
      // restoringAnchor 不让路：恢复 RAF 每帧都在校正锚点，预热的高度变化
      // 会被同一纪律覆盖——否则会白等 3s 恢复窗口，用户恰在这几秒内开始滚动。
      if (Scroll.intent === "userScrolling" || Scroll.intent === "jumpingToTarget") {
        return;
      }
      // 流式期间暂停预热（实验：BACKLOG-STALL 根因验证）。
      // Warmer 的 setTimeout(0) 链连续强制布局会占据 WebContent 的 JS 线程，
      // 让 applyOps 排队等待，表现就是「输出暂停、滚动一泵就续上」。
      // 流式结束后（forkLocked=false）恢复预热；代价是流式期间滚动条高度略虚。
      if (forkLocked) {
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
      // PIN-PROBE2：文档总高随流式的变化——区分「文档没长高」（布局/容器问题）
      // 与「长高了但 scrollY 没跟」（pinBottom/scrollTo 失效）。
      docHeight: Math.round(document.documentElement.scrollHeight),
      anchorID: anchor ? anchor.id : null,
      anchorDelta: anchor ? Math.round(anchor.delta) : 0,
      intent: Scroll.intent
    };
    const key = payload.nearBottom + "|" + payload.scrollTop + "|" + (payload.anchorID || "") + "|" + payload.anchorDelta + "|" + payload.intent + "|" + payload.docHeight;
    if (key === lastScrollReport) {
      return;
    }
    lastScrollReport = key;
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.scrollState) {
      window.webkit.messageHandlers.scrollState.postMessage(payload);
    }
  }

  window.addEventListener("scroll", function () {
    // 程序钉底的 scroll 不武装 Poller（STALL 回归根因另一半）：流式期间
    // 每次 flush 的 pin 都走这里，持续 arm 会让 rAF 轮询链整场 60fps 空转，
    // 页面失去 flush 间的安静。用户真滚动（intent 已是 userScrolling）照常武装。
    const streamingPinned = forkLocked && Scroll.intent === "pinnedBottom";
    if (!streamingPinned) {
      Poller.arm();
    }
    // 滚动条拖拽识别（不发 wheel/touch 事件）：距上次程序滚动超过窗口期的
    // 视口位移视为用户接管。
    // 流式钉底期间必须跳过该判定：scroll anchoring（视口上方内容定稿/预热时
    // 浏览器的 scrollY 微调）也走 scroll 事件，会被误判为拖拽而释放钉底——
    // 输出越快高度抖动越大，误判越频繁（钉不住的根因）。滚轮/触控/键盘的
    // onUserScrollInput 不受影响，仍是即时接管通道。
    // PIN-FIX：保护范围增加「钉底宽限期」——发送时的 scrollToBottom 到流式首批
    // forkLock 到达之间有数百毫秒空窗（Release/忙主线下更长），空窗内任何
    // scroll 事件（布局微调/锚定噪声）都会经此路径把 pinnedBottom 误贬为
    // userScrolling，钉底永久丢失且无任何机制重新武装（「发送后不跟随」根因）。
    // 宽限期取 1.5s（覆盖发送→流式起点），过后恢复拖拽识别；流式中仍由
    // streamingPinned 接管保护（与 bd92de0 一致）。
    const pinGrace = Scroll.intent === "pinnedBottom"
        && Date.now() - Scroll.lastProgrammaticScrollAt < 1500;
    if (!streamingPinned
        && !pinGrace
        && Date.now() - Scroll.lastProgrammaticScrollAt > 150
        && Scroll.intent !== "userScrolling") {
      Scroll.onUserScrollInput();
    }
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
      const capability = actionButtons.get(copyBtn);
      if (capability?.action !== "copy") return;
      const ti = copyBtn.closest(".ti");
      const state = ti ? items.get(ti.getAttribute("data-iid")) : null;
      if (!state || capability.state !== state || state.el !== ti || state.copyButton !== copyBtn ||
          !copyBtn.isConnected || copyBtn.disabled || state.footer?.isConnected) return;
      requestCopy(copyBtn, state.source || "", "复制消息", () =>
        items.get(ti.dataset.iid) === state && state.copyButton === copyBtn &&
        copyBtn.isConnected && !state.footer?.isConnected);
      return;
    }
    const forkBtn = event.target.closest(".ti-action-fork");
    if (forkBtn) {
      if (actionButtons.get(forkBtn)?.action !== "fork") return;
      if (forkBtn.disabled) {
        return;
      }
      const index = actionButtons.get(forkBtn).index;
      if (Number.isFinite(index) && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.fork) {
        window.webkit.messageHandlers.fork.postMessage({ index: index });
      }
      return;
    }

    const header = event.target.closest(".card-hd");
    if (header) {
      const card = header.closest(".card");
      if (card) {
        const plan = Scroll.beginBatch();
        card.classList.toggle("expanded");
        header.setAttribute("aria-expanded", String(card.classList.contains("expanded")));
        // 卡片会在 thinking delta / 工具结果到达时整体重建。把用户的展开选择
        // 存进条目的长命 state，而不是只留在即将被替换的 DOM class 上。
        const ti = card.closest(".ti");
        const id = ti ? ti.getAttribute("data-iid") : null;
        const state = id ? items.get(id) : null;
        if (state) {
          state.cardExpanded = card.classList.contains("expanded");
        }
        // 折叠/展开改变布局：走统一的批次纪律（非底部保持视口锚定）。
        Scroll.endBatch(plan);
        scheduleTurnOffsetsReport();
        // 展开态高度变了，已固化的占位高过时——重新预热该条目。
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
        const plan = Scroll.beginBatch();
        const current = !!groupState[turnID];
        groupState[turnID] = !current;
        manualOverride[turnID] = true; // 手动干预后一切自动逻辑失效（需求 4）。
        applyGroupState(turnID);
        // display 切换改变文档高度：走批次纪律保锚（需求 7）。
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

  // 时区固定于文档生命周期；当前日期只用于今日/昨日标签，不作为消息时间的兜底。
  const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const dayFormatter = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" });
  const timeFormatter = new Intl.DateTimeFormat("zh-CN", { timeZone, hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
  function dayKey(date) {
    const parts = dayFormatter.formatToParts(date);
    return ["year", "month", "day"].map(type => parts.find(p => p.type === type).value).join("-");
  }
  function messageDate(value) {
    if (typeof value !== "number" && typeof value !== "string") return null;
    if (value === "") return null;
    const date = new Date(value);
    return Number.isFinite(date.getTime()) ? date : null;
  }
  function textElement(tag, className, text) {
    const el = document.createElement(tag);
    el.className = className;
    el.textContent = text;
    return el;
  }

  // 仅更新署名行，不触碰 article/renderer/已冻结代码；空元数据不制造占位值。
  function syncMetadata(el, op, state) {
    const key = JSON.stringify([op.kind, op.speaker, op.timestamp, op.modelID]);
    let header = el.querySelector(op.kind === "user" ? ":scope > .message-hd" : ".answer-hd");
    if (header && state.metadataKey === key) return;
    if (!header) {
      header = textElement("div", "message-hd", "");
      el.prepend(header);
    }
    header.textContent = "";
    header.classList.add("message-hd");
    const avatar = textElement("span", "message-avatar " + (op.kind === "user" ? "user-avatar" : "assistant-avatar"), "");
    const roleName = typeof op.speaker === "string" ? op.speaker.trim() : "";
    avatar.textContent = op.kind === "user" ? "你" : roleName ? Array.from(roleName)[0] : "n";
    avatar.setAttribute("aria-hidden", "true");
    header.appendChild(avatar);
    const speaker = textElement("span", "message-speaker", op.speaker || (op.kind === "user" ? "你" : op.kind === "summary" ? "摘要" : "NewPi"));
    header.appendChild(speaker);
    // 原型：普通会话只有身份与时间；聊天室角色另有一个模型徽章。
    // provider 是内部协议标识，不是厂商展示名，不进入消息标签。
    if (op.kind === "assistant" && typeof op.modelID === "string" && op.modelID.length) {
      speaker.title = "回复模型：" + op.modelID;
      if (typeof op.speaker === "string" && op.speaker.length) {
        header.appendChild(textElement("span", "message-badge message-model", op.modelID));
      }
    }
    const date = messageDate(op.timestamp);
    if (date) {
      const time = textElement("time", "message-time", timeFormatter.format(date));
      time.dateTime = date.toISOString();
      time.title = date.toISOString() + " · " + timeZone;
      header.appendChild(time);
    }
    state.metadataKey = key;
  }

  // 同批最终顺序上计算：分隔线嵌在 .ti 内，不新增无 id 的顶层节点。
  // 日期未知的相邻消息切断已知日期链，不能暗示它属于前一天。
  function syncPlanRows(state, report) {
    const key = JSON.stringify(report || null);
    let section = state.el.querySelector(":scope > .agent-plan");
    if (section && state.planKey === key) return;
    if (!section) {
      section = textElement("section", "agent-plan", "");
      section.setAttribute("aria-label", "Agent计划（自报）");
      state.el.appendChild(section);
    }
    section.textContent = "";
    const steps = report?.steps || [];
    const completed = steps.filter(step => step.status === "completed").length;
    const count = steps.length ? `${completed}/${steps.length}` : report ? "未声明步骤（总数未知）" : "未提供计划";
    section.appendChild(textElement("div", "plan-summary", "Agent计划（自报） · " + count));
    if (steps.length) {
      const list = textElement("ol", "plan-steps", "");
      for (const step of steps) {
        const row = textElement("li", "plan-row", "");
        row.dataset.status = step.status;
        row.dataset.stepId = step.id;
        const status = step.status === "completed" ? "done" : step.status === "inProgress" ? "running" : "pending";
        row.append(icon(status), textElement("span", "plan-title", step.title),
          textElement("span", "plan-status", step.status === "completed" ? "已完成（自报）" : step.status === "inProgress" ? "进行中（自报）" : "待处理"));
        list.appendChild(row);
      }
      section.appendChild(list);
    }
    if (report) section.appendChild(textElement("p", "plan-notice", "仅为 Agent 最后声明的计划；不代表工具成功或测试通过，停止后不自动改写状态。"));
    state.planKey = key;
    Warmer.warmed.delete(state.el.dataset.iid);
  }

  function syncBatchDecorations() {
    const today = dayKey(new Date());
    const todayUTC = new Date(today + "T12:00:00Z");
    todayUTC.setUTCDate(todayUTC.getUTCDate() - 1);
    const yesterday = todayUTC.toISOString().slice(0, 10);
    let previousDay = null;
    const counts = new Map();
    const plans = new Map();
    const activeGroups = new Set();
    for (const el of main.children) {
      const state = items.get(el.dataset.iid);
      if (!state) continue;
      if (state.detailTurnID && state.streaming) activeGroups.add(state.detailTurnID);
      const topLevel = (state.kind === "user" || state.kind === "assistant") && !state.detailTurnID && !el.classList.contains("detail-hidden");
      const day = topLevel ? state.day : null;
      const show = day && day !== previousDay;
      if (topLevel) previousDay = day;
      let separator = el.querySelector(":scope > .message-date");
      if (show) {
        if (!separator) {
          separator = textElement("div", "message-date", "");
          el.prepend(separator);
        }
        const dateLabel = day === today ? "今天" : day === yesterday ? "昨天" : day.replace(/^(\d+)-(\d+)-(\d+)$/, "$1年$2月$3日");
        const label = dateLabel + (dateContext ? " · " + dateContext : "");
        if (separator.textContent !== label) {
          separator.textContent = label;
          Warmer.warmed.delete(el.dataset.iid);
        }
        separator.dataset.day = day;
      } else if (separator) {
        separator.remove();
        Warmer.warmed.delete(el.dataset.iid);
      }
      if (state.kind === "tool" && state.detailTurnID) {
        if (state.progressReport) plans.set(state.detailTurnID, state.progressReport);
        const count = counts.get(state.detailTurnID) || { done: 0, running: 0, error: 0, stopped: 0, total: 0 };
        count[toolStatus(state)]++;
        count.total++;
        counts.set(state.detailTurnID, count);
      }
    }
    items.forEach(state => {
      if (state.kind !== "detailGroup") return;
      const count = counts.get(state.detailTurnID);
      const active = !!count?.running || activeGroups.has(state.detailTurnID);
      const status = count ? count.error ? "error" : active ? "running" : count.stopped ? "stopped" : "done" : active ? "running" : "done";
      const label = count ?
        `${active ? "正在执行" : count.stopped ? "已停止" : count.error ? "处理未完成" : "处理过程"} · 已完成 ${count.done} / ${count.total} 个已知工具调用` +
        (count.error ? ` · 失败 ${count.error}` : "") +
        (count.stopped ? ` · 保留 ${count.done} 个已完成步骤` : "") : active ? "正在思考" : "处理详情";
      const title = state.el.querySelector(".detail-label");
      if (title.textContent !== label) {
        title.textContent = label;
        Warmer.warmed.delete(state.el.dataset.iid);
      }
      const statusIcon = state.el.querySelector(".detail-status");
      if (statusIcon.dataset.status !== status) {
        statusIcon.replaceChildren(icon(status));
        statusIcon.dataset.status = status;
      }
      syncPlanRows(state, plans.get(state.detailTurnID));
      state.el.querySelector(".detail-row").setAttribute("aria-expanded", String(!groupState[state.detailTurnID]));
    });
  }

  function syncRetryButton(state) {
    if (state.retryButton) state.retryButton.disabled = forkLocked || !!state.streaming || state.retryState !== "available";
  }

  function renderError(el, op, state) {
    el.className = "ti ti-error";
    el.textContent = "";
    const card = textElement("section", "error-card" + (op.retryState === "recovered" ? " recovered" : ""), "");
    const title = textElement("div", "error-title sysline", op.errorTitle ?? "本轮未完成");
    title.prepend(icon("error"));
    card.appendChild(title);
    const status = op.retryState === "retrying" ? "正在重试，请稍候。" : op.retryState === "recovered" ? "已恢复 · 历史错误记录" : "本次输出未完成。";
    card.appendChild(textElement("div", "error-status", status));
    card.appendChild(textElement("p", "error-guidance", "已有对话和输出仍会保留；重试不会发送或覆盖输入框中的新草稿。已执行的工具操作不会自动撤销。"));
    state.retryButton = null;
    if (op.retryState === "available" || op.retryState === "retrying") {
      const retry = textElement("button", "error-retry", op.retryState === "retrying" ? "重试中…" : "重试");
      retry.type = "button";
      retry.prepend(icon("retry"));
      state.retryButton = retry;
      // 只绑定我们创建的按钮，绝不委托 HTML class/href 为权限入口。
      retry.addEventListener("click", function () {
        if (items.get(op.id) !== state || state.kind !== "error" || state.retryButton !== retry ||
            state.retryState !== "available" || forkLocked || state.streaming || retry.disabled) return;
        const handler = window.webkit?.messageHandlers?.retryError;
        if (handler) handler.postMessage({ id: op.id });
      });
      card.appendChild(retry);
    }
    const details = textElement("div", "card error-details" + (state.cardExpanded ? " expanded" : ""), "");
    const header = textElement("button", "card-hd", "");
    header.type = "button";
    header.setAttribute("aria-expanded", String(!!state.cardExpanded));
    const disclosure = textElement("span", "card-chevron", "");
    disclosure.appendChild(icon("chevron"));
    header.appendChild(disclosure);
    header.appendChild(textElement("span", "card-title", "错误详情"));
    details.appendChild(header);
    details.appendChild(textElement("pre", "card-body error-raw", op.body));
    const copy = textElement("button", "error-copy", "复制错误详情");
    copy.type = "button";
    copy.prepend(icon("copy"));
    copy.addEventListener("click", function () {
      const valid = () => items.get(op.id) === state && state.kind === "error" && details.parentElement === card && card.parentElement === el && copy.isConnected;
      if (valid()) requestCopy(copy, state.source || "", "复制错误详情", valid);
    });
    details.appendChild(copy);
    card.appendChild(details);
    el.appendChild(card);
  }

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
    // 图片附件（BACKLOG-IMAGE-INPUT）：正文之后追加缩略图条（src 走 pi-att:// 受控通道）。
    if (op.attachments && op.attachments.length) {
      bubble.appendChild(makeAttachmentStrip(op.attachments));
    }
    el.appendChild(bubble);
    attachActions(bubble, op);
  }

  // 用户气泡内的图片附件条：懒加载；加载失败（文件缺失/目录被移）替换为占位文案。
  function makeAttachmentStrip(attachments) {
    const strip = document.createElement("div");
    strip.className = "bubble-attachments";
    for (const att of attachments) {
      const img = document.createElement("img");
      img.className = "bubble-attachment";
      img.src = att.src;
      img.alt = att.alt || "";
      img.loading = "lazy";
      img.decoding = "async";
      img.addEventListener("error", function () {
        const missing = document.createElement("div");
        missing.className = "bubble-attachment-missing";
        missing.textContent = "图片已丢失";
        if (img.parentNode) img.parentNode.replaceChild(missing, img);
      });
      // 点击放大（BACKLOG-IMAGE-INPUT 二期）：只传相对路径，原生经 SessionAttachments
      // 受控解析后弹预览窗；不回传图数据（避免大 base64 过 message 桥）。
      img.addEventListener("click", function () {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.attachmentTap) {
          window.webkit.messageHandlers.attachmentTap.postMessage({
            path: att.path || "",
            alt: att.alt || ""
          });
        }
      });
      // 可点击的视觉提示（悬停时轻微提亮 + 指针）。
      img.tabIndex = 0;
      img.role = "button";
      strip.appendChild(img);
    }
    return strip;
  }

  // 附件集合的比较键（路径 join）：进 upsert 的重渲染判定，不参与 DOM。
  function attachmentKey(op) {
    return op.attachments && op.attachments.length
      ? op.attachments.map(function (a) { return a.src; }).join("|")
      : "";
  }

  function renderSystemLike(el, op, cssClass) {
    el.className = "ti " + cssClass;
    el.textContent = "";
    const line = document.createElement("div");
    line.className = op.phaseDivider === true ? "phase-divider" : "sysline";
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
    chevron.appendChild(icon("chevron"));
    row.appendChild(textElement("span", "detail-status", ""));
    const label = document.createElement("span");
    label.className = "detail-label";
    label.textContent = "处理详情";
    row.appendChild(label);
    row.appendChild(chevron);
    el.appendChild(row);
    // 组内条目（可能存在，若先渲染了条目再渲染 marker）按当前组状态对齐。
    applyGroupState(op.detailTurnID);
  }

  // 思考 / 工具卡：状态图标、两行说明、耗时及右侧 disclosure；正文仍按原增量路径渲染。
  // ===== 消息级操作按钮（复制 / 分叉）：hover 显示在 user / assistant 条目右上角 =====
  // 复制走 copyText（复用代码块复制通道）；分叉走 fork（回传 messageIndex，原生触发 forkFromMessage）。
  function syncTopCopy(wrap, state) {
    // 以实际 footer 为准，而不是 answerState：同 scope 中被替换的 final 仍需可复制。
    // 真正摘除按钮（包括 AX 入口）并撤销能力；metadata-only upsert 不会重新插回。
    const hasFooter = state.footer?.isConnected && state.footer.parentElement === wrap.parentElement;
    let copy = wrap.querySelector(":scope > .ti-action-copy");
    if (state.copyButton && (state.copyButton !== copy || hasFooter)) {
      actionButtons.delete(state.copyButton);
      state.copyButton = null;
    }
    if (hasFooter) {
      if (copy) { actionButtons.delete(copy); copy.remove(); }
      return;
    }
    if (!copy) {
      copy = document.createElement("button");
      copy.type = "button";
      copy.className = "ti-action ti-action-copy";
      copy.title = "复制消息";
      copy.setAttribute("aria-label", "复制消息");
      copy.innerHTML =
        '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true">' +
        '<rect x="5.5" y="5.5" width="8" height="8" rx="1.5" stroke="currentColor" stroke-width="1.3"/>' +
        '<path d="M10.5 3.5h-6a1 1 0 0 0-1 1v6" stroke="currentColor" stroke-width="1.3" fill="none"/>' +
        "</svg>";
      wrap.prepend(copy);
      actionButtons.set(copy, { action: "copy", state: state });
    }
    state.copyButton = copy;
  }

  function attachActions(el, op) {
    // wrap 只建一次；复制按实际 footer、fork 按元数据分别双向同步。
    // agentEnd 才补 canFork/messageIndex，不能把 fork 创建锁在 wrap 的一次性分支内。
    let wrap = el.querySelector(":scope > .ti-actions");
    if (!wrap) {
      wrap = document.createElement("div");
      wrap.className = "ti-actions";
      el.appendChild(wrap);
    }
    syncTopCopy(wrap, items.get(op.id));

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
      actionButtons.delete(forkBtn);
      forkBtn.remove();
      forkBtn = null;
    }
    if (forkBtn) {
      forkBtn.disabled = !!op.streaming || forkLocked;
      forkBtn.dataset.forkIndex = String(op.messageIndex);
      actionButtons.set(forkBtn, { action: "fork", index: op.messageIndex });
    }
  }

  function renderCard(el, op, state) {
    const isThinking = op.kind === "thinking";
    el.className = "ti " + (isThinking ? "ti-thinking" : "ti-tool");
    el.textContent = "";

    const card = document.createElement("div");
    card.className = "card" + (op.toolError ? " is-error" : "") +
      (state.cardExpanded ? " expanded" : "");
    const status = toolStatus(op);
    if (!isThinking) card.dataset.status = status;

    const header = document.createElement("button");
    header.type = "button";
    header.className = "card-hd";
    header.setAttribute("aria-expanded", String(!!state.cardExpanded));

    const chevron = document.createElement("span");
    chevron.className = "card-chevron";
    chevron.appendChild(icon("chevron"));
    header.appendChild(icon(isThinking ? op.streaming ? "running" : "done" : status));

    const description = textElement("span", "card-description", "");

    const title = document.createElement("span");
    title.className = "card-title" + (isThinking ? " thinking" : "");
    if (isThinking) {
      title.textContent = op.streaming ? "思考中…" : "思考";
    } else {
      // 有限的已知工具名映射，不从任意命令/模型 prose 猜测意图或测试结果。
      const titles = { read: "读取文件", write: "写入文件", edit: "编辑文件", bash: "执行命令",
        read_file: "读取文件", write_file: "写入文件", apply_patch: "应用补丁", grep: "搜索内容", glob: "查找文件", subagent: "调用子代理",
        update_plan: "更新自报计划", read_test_report: "读取测试报告" };
      title.textContent = Object.prototype.hasOwnProperty.call(titles, op.toolName) ? titles[op.toolName] : op.toolName || "工具调用";
      title.title = op.toolName || "工具调用";
    }
    description.appendChild(title);

    if (!isThinking) {
      const badge = document.createElement("span");
      badge.className = "card-badge " + status;
      badge.textContent = statusLabels[status];
      description.appendChild(badge);
    } else if (op.streaming) {
      const badge = document.createElement("span");
      badge.className = "card-badge running";
      badge.textContent = "···";
      description.appendChild(badge);
    }

    const preview = document.createElement("span");
    preview.className = "card-preview";
    // 思考展示最新一行；工具只展示已记录调用参数，不把 stdout prose 冒充命令。
    preview.textContent = isThinking
      ? lastNonEmptyLine(op.body)
      : (op.command ? firstNonEmptyLine(op.command) : "未记录调用参数");
    description.appendChild(preview);
    header.appendChild(description);
    if (!isThinking) {
      const duration = textElement("span", "card-duration", finiteDuration(op.durationSeconds) ? op.durationSeconds.toFixed(2) + "s" : status === "running" ? "执行中" : status === "stopped" ? "已停止" : "—");
      duration.title = finiteDuration(op.durationSeconds) ? "已记录工具耗时" : "未记录耗时";
      header.appendChild(duration);
    }
    header.appendChild(chevron);

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
    // PIN-FREEZE 修复：流式期间强制渲染该条目（绕过 content-visibility 调度）。
    // 实测现象：气泡高度超过一个视口后，docHeight/scrollY 一起冻结在「恰好一屏」
    // 处，内容仍在流入但布局不再长高（CV 估算高被 lockIntrinsicHeight 逐批锁定后
    // 与真实内容脱钩）；流结束 renderFinal 后才恢复。流式条日本来就该在屏上，
    // 让 CV 调度它没有收益只有风险；定型后归还调度。
    el.style.contentVisibility = op.streaming ? "visible" : "";
    if (!state.renderer) {
      el.textContent = "";
      const card = document.createElement("div");
      card.className = "card answer";
      const hd = document.createElement("div");
      hd.className = "answer-hd";
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
    if (!state || state.kind !== op.kind || op.kind === "tool" ||
        state.answerState !== op.answerState || state.resultScopeID !== op.resultScopeID ||
        state.detailTurnID !== (op.detailTurnID || null) || state.streaming !== op.streaming) footersDirty = true;

    const structuralKinds = ["user", "system", "error", "thinking", "tool"];
    if (!el) {
      el = makeRow();
      el.setAttribute("data-iid", op.id);
      state = { el: el, kind: null, source: null, streaming: null, renderer: null };
      items.set(op.id, state);
      main.appendChild(el);
    }

    if (state.kind !== null && state.kind !== op.kind) {
      if (state.copyButton) actionButtons.delete(state.copyButton);
      state.copyButton = null;
      state.renderer = null;
      state.metadataKey = null;
      state.retryButton = null;
      state.footerKey = null;
      state.footer = null;
    }

    if (op.kind === "assistant" || op.kind === "summary") {
      renderAssistant(el, op, state);
    } else if (op.kind === "detailGroup") {
      // 处理详情 disclosure 行（BACKLOG-DETAIL-GROUP）。
      renderDetailGroup(el, op);
    } else if (structuralKinds.indexOf(op.kind) >= 0) {
      // 结构性条目内容整体替换（思考/工具流式期 body 会增长，重渲染成本可忽略——纯文本节点）。
      // attachKey：附件集合变化也须触发重渲染（防御；user 附件当前一次带全不变）。
      const attachKey = attachmentKey(op);
      if (state.source !== op.body || state.streaming !== op.streaming ||
          state.toolRunning !== op.toolRunning || state.toolError !== op.toolError ||
          state.interrupted !== op.interrupted || state.durationSeconds !== op.durationSeconds ||
          state.phaseDivider !== op.phaseDivider ||
          state.command !== op.command || state.toolName !== op.toolName ||
          state.errorTitle !== op.errorTitle || state.retryState !== op.retryState ||
          state.kind !== op.kind || state.attachKey !== attachKey) {
        if (op.kind === "user") {
          renderUser(el, op);
        } else if (op.kind === "system") {
          renderSystemLike(el, op, "ti-system");
        } else if (op.kind === "error") {
          renderError(el, op, state);
        } else {
          renderCard(el, op, state);
        }
        state.source = op.body;
        state.streaming = op.streaming;
        state.toolRunning = op.toolRunning;
        state.toolError = op.toolError;
        state.attachKey = attachKey;
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
    state.command = op.command;
    state.toolName = op.toolName;
    state.interrupted = op.interrupted;
    state.phaseDivider = op.phaseDivider;
    // detailGroup 不经过结构重建分支，但仍需真实运行态供无工具的思考组使用。
    if (op.kind === "detailGroup") state.streaming = op.streaming;
    state.errorTitle = op.errorTitle;
    state.retryState = op.retryState;
    state.fileChanges = op.fileChanges;
    state.durationSeconds = op.durationSeconds;
    state.answerState = op.answerState;
    state.resultScopeID = op.resultScopeID;
    state.progressReport = progressReport(op.progressReport);
    state.testReport = testReport(op.testReport);
    if (state.timestamp !== op.timestamp) {
      state.date = messageDate(op.timestamp);
      state.day = state.date ? dayKey(state.date) : null;
      state.timestamp = op.timestamp;
    }
    if (op.kind === "user" || op.kind === "assistant" || op.kind === "summary") syncMetadata(el, op, state);
    syncRetryButton(state);
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
    if (isGroupItem) {
      el.classList.add("detail-item");
      el.setAttribute("data-turn-id", op.detailTurnID);
      // 新条目 / 组归属变化时对齐组状态（折叠态立即隐藏，展开态保持可见）。
      el.classList.toggle("detail-hidden", !!groupState[op.detailTurnID]);
    } else {
      el.classList.remove("detail-item");
      el.classList.remove("detail-hidden");
      el.removeAttribute("data-turn-id");
    }
    state.detailTurnID = op.detailTurnID || null;
  }

  function applyOps(ops) {
    // UI 侧指标：本批 DOM 应用耗时（原生侧测不到，回传 uiTiming 供「API 监控」定位 JS/DOM 渲染）。
    const renderStart = performance.now();
    // 滚动纪律：批次开始时按意图决定本批的视口策略，结束后同步执行——
    // 保存锚点 → 变更 → 恢复在同一执行块内，不存在高度未回的中间态。
    // 显式滚动 op（jumpTo/scrollToBottom/restoreAnchor）优先于批次策略。
    const plan = Scroll.beginBatch();
    const scrollOps = [];
    const touchedEls = []; // 本批 ops 触达的条目（批次结束后固化其真实高度）
    for (const op of ops) {
      if (op.op === "reset") {
        footersDirty = true;
        approvalState = null;
        approvalReceipts.clear();
        dateContext = "";
        window.newPiCopy?.reset();
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
        const wasLocked = forkLocked;
        forkLocked = !!op.locked;
        if (wasLocked && !forkLocked) {
          Warmer.schedule();
        }
        const forkButtons = main.querySelectorAll(".ti-action-fork");
        for (let i = 0; i < forkButtons.length; i += 1) {
          const btn = forkButtons[i];
          const ti = btn.closest(".ti");
          const state = ti ? items.get(ti.getAttribute("data-iid")) : null;
          const selfStreaming = state ? !!state.streaming : false;
          btn.disabled = selfStreaming || forkLocked;
        }
        items.forEach(syncRetryButton);
        // 收尾对齐（CHATROOM-STREAM-PIN）：流式结束的同一批里发生 renderFinal
        // 重排、候选块追加、详情组收起；流式光标还会停留 ~1.4s 后移除（再次
        // 引起高度变化），hljs 高亮也有异步布局——全部落在最后一次钉底之后。
        // 若此前处于钉底跟随，在窗口期内逐帧无条件钉底（到点即停）；
        // 用户上滚（intent 变 userScrolling）立即退出，不打扰阅读。
        if (wasLocked && !forkLocked && Scroll.intent === "pinnedBottom") {
          const catchUpDeadline = Date.now() + 1600;
          const catchUp = function () {
            if (Scroll.intent !== "pinnedBottom") {
              return;
            }
            Scroll.pinBottom();
            if (Date.now() < catchUpDeadline) {
              window.requestAnimationFrame(catchUp);
            }
          };
          window.requestAnimationFrame(catchUp);
        }
      } else if (op.op === "copyCapability") {
        window.newPiCopy?.configure(op.capability);
      } else if (op.op === "copyResult") {
        window.newPiCopy?.acknowledge(op);
      } else if (op.op === "context") {
        dateContext = [op.projectName, op.dateContext].filter(value => typeof value === "string" && value.trim()).join(" · ");
      } else if (op.op === "approvalReceipt") {
        applyApprovalReceipt(op);
      } else if (op.op === "approval") {
        applyApproval(op);
      } else if (op.op === "upsert") {
        touchedEls.push(upsert(op));
      } else if (op.op === "remove") {
        footersDirty = true;
        // fork/删轮次时撤下失去正文锚点的内存回执，不能搬到另一轮冒充其审批结果。
        for (const [id, receipt] of approvalReceipts) {
          if (receipt.afterID === op.id) {
            receipt.el.remove();
            approvalReceipts.delete(id);
            Warmer.warmed.delete(id);
          }
        }
        const state = items.get(op.id);
        if (state) {
          state.el.remove();
          items.delete(op.id);
          Warmer.warmed.delete(op.id);
        }
      } else if (["jumpTo", "scrollToBottom", "restoreAnchor"].includes(op.op)) {
        scrollOps.push(op);
      } else if (op.op === "order") {
        footersDirty = true;
        // 结构重排（fork 重建等）：按给定 id 序列重挂节点（appendChild 移动已有节点）。
        for (const id of op.ids) {
          const state = items.get(id);
          if (state) {
            main.appendChild(state.el);
          }
        }
      }
    }
    // 日期/统计引发的布局必须先完成，再执行同批保锚或显式恢复。
    positionApproval();
    if (footersDirty) { syncAnswerFooters(); footersDirty = false; }
    syncBatchDecorations();
    for (const op of scrollOps) {
      if (op.op === "jumpTo") Scroll.jumpTo(op.id);
      else if (op.op === "scrollToBottom") Scroll.scrollToBottom(!!op.smooth);
      else Scroll.restoreAnchor({ id: op.id, delta: op.delta || 0 }, typeof op.offset === "number" ? op.offset : 0);
    }
    if (scrollOps.length === 0) {
      Scroll.endBatch(plan);
    }
    // PIN-PROBE2：批次结束后主动上报一次（内部有去重）——scrollY 不动时
    // scroll 事件不触发，docHeight 的变化也能反映出来。
    reportScrollState();
    // 批次结束后固化触达条目的真实高度（可见条目是真实高；离屏条目读到占位高，同值无害）。
    for (const el of touchedEls) {
      lockIntrinsicHeight(el);
    }
    // 新内容入场后安排空闲预热。
    if (touchedEls.length > 0) {
      Warmer.schedule();
    }
    const renderMs = performance.now() - renderStart;
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.uiTiming) {
      window.webkit.messageHandlers.uiTiming.postMessage({ durationMs: renderMs, opsCount: ops.length });
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
