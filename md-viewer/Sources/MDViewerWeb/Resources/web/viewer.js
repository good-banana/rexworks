(function () {
  "use strict";

  const ALERT_TITLES = {
    note: "Note",
    tip: "Tip",
    important: "Important",
    warning: "Warning",
    caution: "Caution",
  };
  const ALERT_MARKER = /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*(?:\n|$)/i;
  const REMOVED_ELEMENTS = "script, meta, base, link, object, embed, audio";
  const IMAGE_TIMEOUT_MS = 3000;

  function escapeHtml(text) {
    return text
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function highlight(code, language) {
    try {
      if (language && hljs.getLanguage(language)) {
        return hljs.highlight(code, { language: language, ignoreIllegals: true }).value;
      }
      return hljs.highlightAuto(code).value;
    } catch (error) {
      return "";
    }
  }

  function githubAlerts(md) {
    md.core.ruler.after("block", "github_alerts", function (state) {
      const tokens = state.tokens;
      for (let i = 0; i < tokens.length; i++) {
        const open = tokens[i];
        if (open.type !== "blockquote_open") continue;
        const paragraph = tokens[i + 1];
        const inline = tokens[i + 2];
        if (!paragraph || paragraph.type !== "paragraph_open" || !inline || inline.type !== "inline") continue;
        const match = ALERT_MARKER.exec(inline.content);
        if (!match) continue;
        const kind = match[1].toLowerCase();
        const close = tokens.slice(i + 1).find(function (t) {
          return t.type === "blockquote_close" && t.level === open.level;
        });
        open.tag = "div";
        open.meta = { alertKind: kind };
        close.tag = "div";
        inline.content = inline.content.slice(match[0].length);
        if (inline.content.trim() === "") tokens.splice(i + 1, 3);
      }
    });
    const defaultOpen =
      md.renderer.rules.blockquote_open ||
      function (tokens, idx, options, env, self) {
        return self.renderToken(tokens, idx, options);
      };
    md.renderer.rules.blockquote_open = function (tokens, idx, options, env, self) {
      const kind = tokens[idx].meta && tokens[idx].meta.alertKind;
      if (!kind) return defaultOpen(tokens, idx, options, env, self);
      return (
        '<div class="markdown-alert markdown-alert-' + kind + '">\n' +
        '<p class="markdown-alert-title">' + ALERT_TITLES[kind] + "</p>\n"
      );
    };
  }

  function slugify(text) {
    return text
      .trim()
      .toLowerCase()
      .replace(/[^\p{L}\p{M}\p{N}\p{Pc}\- ]/gu, "")
      .replace(/ /g, "-");
  }

  function headingIds(md) {
    md.core.ruler.push("heading_ids", function (state) {
      const seen = new Map();
      const tokens = state.tokens;
      for (let i = 0; i < tokens.length; i++) {
        if (tokens[i].type !== "heading_open") continue;
        const text = (tokens[i + 1].children || [])
          .filter(function (t) {
            return t.type === "text" || t.type === "code_inline";
          })
          .map(function (t) {
            return t.content;
          })
          .join("");
        const base = slugify(text);
        const count = seen.get(base) || 0;
        seen.set(base, count + 1);
        tokens[i].attrSet("id", count === 0 ? base : base + "-" + count);
      }
    });
  }

  function mermaidFences(md) {
    const defaultFence = md.renderer.rules.fence;
    md.renderer.rules.fence = function (tokens, idx, options, env, self) {
      const token = tokens[idx];
      if (token.info.trim().split(/\s+/)[0] === "mermaid") {
        return '<pre class="mermaid">' + escapeHtml(token.content) + "</pre>\n";
      }
      return defaultFence(tokens, idx, options, env, self);
    };
  }

  const md = window
    .markdownit({ html: true, linkify: true, typographer: false, highlight: highlight })
    .use(window.markdownitFootnote)
    .use(window.markdownitTaskLists)
    .use(githubAlerts)
    .use(headingIds)
    .use(mermaidFences);

  function videoEmbedSource(iframe) {
    const src = iframe.getAttribute("src") || "";
    let url;
    try {
      url = new URL(src, document.baseURI);
    } catch (error) {
      return null;
    }
    const host = url.hostname.replace(/^www\./, "");
    if (host === "youtube.com" || host === "youtube-nocookie.com" || host === "youtu.be") {
      const id = url.pathname.split("/").filter(Boolean).pop();
      return { href: "https://www.youtube.com/watch?v=" + id, poster: "https://img.youtube.com/vi/" + id + "/hqdefault.jpg" };
    }
    if (host === "player.vimeo.com" || host === "vimeo.com") {
      const id = url.pathname.split("/").filter(Boolean).pop();
      return { href: "https://vimeo.com/" + id, poster: null };
    }
    return null;
  }

  function videoSource(video) {
    const src = video.getAttribute("src");
    if (src) return src;
    const source = video.querySelector("source[src]");
    return source ? source.getAttribute("src") : null;
  }

  function makePlaceholder(href, poster, index) {
    const placeholder = document.createElement("div");
    placeholder.className = "video-placeholder";
    placeholder.dataset.href = href;
    placeholder.dataset.index = String(index);
    const image = document.createElement("img");
    image.className = "video-poster";
    image.alt = "";
    if (poster) image.setAttribute("src", poster);
    else image.hidden = true;
    const play = document.createElement("span");
    play.className = "video-play";
    placeholder.append(image, play);
    return placeholder;
  }

  function sanitize(root) {
    root.querySelectorAll(REMOVED_ELEMENTS).forEach(function (element) {
      element.remove();
    });
    root.querySelectorAll("*").forEach(function (element) {
      element.getAttributeNames().forEach(function (name) {
        const lower = name.toLowerCase();
        if (lower.startsWith("on") || lower === "loading") element.removeAttribute(name);
      });
    });
  }

  function replaceVideos(root) {
    let index = 0;
    root.querySelectorAll("video, iframe").forEach(function (element) {
      let replacement = null;
      if (element.tagName === "VIDEO") {
        const href = videoSource(element);
        if (href) replacement = makePlaceholder(href, element.getAttribute("poster"), index);
      } else {
        const embed = videoEmbedSource(element);
        if (embed) replacement = makePlaceholder(embed.href, embed.poster, index);
      }
      if (replacement) {
        element.replaceWith(replacement);
        index += 1;
      } else {
        element.remove();
      }
    });
  }

  function setBase(baseURL) {
    let base = document.head.querySelector("base");
    if (!base) {
      base = document.createElement("base");
      document.head.prepend(base);
    }
    base.setAttribute("href", baseURL);
  }

  function applyTheme(theme) {
    const active = function (enabled) {
      return enabled ? "all" : "not all";
    };
    document.getElementById("markdown-light").media = active(!theme.dark);
    document.getElementById("markdown-dark").media = active(theme.dark);
    document.getElementById("hljs-light").media = active(!theme.dark);
    document.getElementById("hljs-dark").media = active(theme.dark);
    document.documentElement.style.colorScheme = theme.dark ? "dark" : "light";
    document.body.style.backgroundColor = theme.background;
    document.body.style.color = theme.foreground;
  }

  function imageSettled(image) {
    if (image.complete) return Promise.resolve();
    return new Promise(function (resolve) {
      image.addEventListener("load", resolve, { once: true });
      image.addEventListener("error", resolve, { once: true });
    });
  }

  function waitForImages(root) {
    const images = Array.from(root.querySelectorAll("img"));
    const timeout = new Promise(function (resolve) {
      setTimeout(resolve, IMAGE_TIMEOUT_MS);
    });
    return Promise.race([Promise.all(images.map(imageSettled)), timeout]);
  }

  async function renderDiagrams(dark) {
    const nodes = document.querySelectorAll("article pre.mermaid");
    if (nodes.length === 0) return;
    mermaid.initialize({ startOnLoad: false, theme: dark ? "dark" : "default", securityLevel: "strict" });
    try {
      await mermaid.run({ nodes: nodes, suppressErrors: true });
    } catch (error) {
      return;
    }
  }

  function pageRect(rect) {
    return {
      x: rect.left + window.scrollX,
      y: rect.top + window.scrollY,
      width: rect.width,
      height: rect.height,
    };
  }

  window.render = async function (markdown, baseURL, theme) {
    setBase(baseURL);
    applyTheme(theme);
    const template = document.createElement("template");
    template.innerHTML = md.render(markdown);
    sanitize(template.content);
    replaceVideos(template.content);
    const article = document.querySelector("article");
    article.replaceChildren(template.content);
    await renderDiagrams(theme.dark);
    await waitForImages(article);
    await document.fonts.ready;
    const bodyStyle = getComputedStyle(document.body);
    const bottom = article.getBoundingClientRect().bottom + window.scrollY;
    return { height: Math.ceil(bottom + parseFloat(bodyStyle.paddingBottom) + parseFloat(bodyStyle.marginBottom)) };
  };

  window.setPoster = async function (index, dataURL) {
    const image = document.querySelector('.video-placeholder[data-index="' + index + '"] img.video-poster');
    if (!image) return false;
    image.src = dataURL;
    image.hidden = false;
    await imageSettled(image);
    return true;
  };

  window.missingPosters = function () {
    return Array.from(document.querySelectorAll("article .video-placeholder"))
      .filter(function (placeholder) {
        return placeholder.querySelector("img.video-poster").hidden;
      })
      .map(function (placeholder) {
        const entry = pageRect(placeholder.getBoundingClientRect());
        entry.index = Number(placeholder.dataset.index);
        entry.href = placeholder.dataset.href;
        return entry;
      });
  };

  function linkElements() {
    return Array.from(document.querySelectorAll("article a[href], article .video-placeholder")).filter(
      function (element) {
        const rect = element.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      }
    );
  }

  window.links = function () {
    return linkElements().map(function (element) {
      const isVideo = element.classList.contains("video-placeholder");
      const entry = pageRect(element.getBoundingClientRect());
      entry.href = isVideo ? element.dataset.href : element.getAttribute("href");
      entry.kind = isVideo ? "video" : "link";
      return entry;
    });
  };

  window.focusLink = function (index) {
    document.querySelectorAll(".md-focus").forEach(function (element) {
      element.classList.remove("md-focus");
    });
    const target = index === null ? null : linkElements()[index];
    if (target) target.classList.add("md-focus");
    return Boolean(target);
  };

  window.anchorOffset = function (id) {
    const target = document.getElementById(id) || document.getElementsByName(id)[0];
    if (!target) return null;
    return target.getBoundingClientRect().top + window.scrollY;
  };

  window.search = function (query) {
    if (!query) return [];
    const needle = query.toLowerCase();
    const result = [];
    const walker = document.createTreeWalker(document.querySelector("article"), NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const haystack = node.data.toLowerCase();
      for (let at = haystack.indexOf(needle); at !== -1; at = haystack.indexOf(needle, at + needle.length)) {
        const range = document.createRange();
        range.setStart(node, at);
        range.setEnd(node, at + needle.length);
        const rect = range.getBoundingClientRect();
        if (rect.width > 0 && rect.height > 0) result.push(pageRect(rect));
      }
    }
    return result;
  };
})();
