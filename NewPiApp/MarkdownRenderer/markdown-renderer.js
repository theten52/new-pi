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
      if (streamingRenderDepth > 0) {
        return '<pre class="hljs"><code>' + escapeHtml(source) + "</code></pre>";
      }

      if (language && window.hljs && window.hljs.getLanguage(language)) {
        try {
          const highlighted = window.hljs.highlight(source, {
            language: language,
            ignoreIllegals: true
          }).value;
          return '<pre class="hljs"><code>' + highlighted + "</code></pre>";
        } catch (_) {
          return '<pre class="hljs"><code>' + escapeHtml(source) + "</code></pre>";
        }
      }

      return '<pre class="hljs"><code>' + escapeHtml(source) + "</code></pre>";
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

    const height = measureRootHeight(root);
    const streaming = activeStreamingRender;
    if (!force && !streaming && Math.abs(height - lastPostedHeight) < heightChangeThreshold) {
      return;
    }

    lastPostedHeight = height;
    if (!streaming) {
      root.style.minHeight = height + "px";
    }
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

  window.renderMarkdown = function (markdownSource, options) {
    const root = document.getElementById("markdown-root");
    if (!root) {
      return;
    }

    options = options || {};
    const streaming = options.streaming === true;
    if (!streaming) {
      const preservedHeight = measureRootHeight(root);
      if (preservedHeight > 1) {
        root.style.minHeight = preservedHeight + "px";
      }
    }

    if (streaming) {
      streamingRenderDepth += 1;
      activeStreamingRender = true;
    }

    root.innerHTML = markdown.render(markdownSource);
    bindLinks(root);

    if (streaming) {
      streamingRenderDepth -= 1;
      scheduleHeightPost(true);
      activeStreamingRender = false;
      return;
    }

    root.style.minHeight = "";
    lastPostedHeight = 0;
    observeRootHeight(root);
    scheduleHeightPost(true);
  };
}());
