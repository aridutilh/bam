// Bam Reading Mode page. Original code. The article arrives from the app as
// HTML extracted by Readability; it is sanitized here before it is shown.
"use strict";
(function () {
  const SIZES = [14, 15, 16, 17, 18, 19, 20, 22, 24, 26, 28, 32];
  const root = document.documentElement;
  const $ = (id) => document.getElementById(id);
  let prefs = { size: 6, face: "serif", theme: "auto" };
  let pageURL = "";

  const post = (message) => {
    try { window.webkit.messageHandlers.bamReader.postMessage(message); } catch (e) {}
  };

  const EMBED = /^https:\/\/(www\.)?(youtube(-nocookie)?\.com\/embed\/|player\.vimeo\.com\/video\/|(www\.)?loom\.com\/embed\/|open\.spotify\.com\/embed\/|w\.soundcloud\.com\/player\/|player\.twitch\.tv\/|www\.dailymotion\.com\/embed\/)/;
  const DROP = "script,style,link,meta,base,object,embed,applet,form,input,button,select,textarea,noscript,template,dialog,frame,frameset,svg script";

  function sanitize(html) {
    const doc = new DOMParser().parseFromString("<!doctype html><body>" + html, "text/html");
    doc.querySelectorAll(DROP).forEach((n) => n.remove());
    doc.querySelectorAll("iframe").forEach((frame) => {
      const src = frame.getAttribute("src") || "";
      if (!EMBED.test(src)) { frame.remove(); return; }
      for (const name of Array.from(frame.getAttributeNames())) {
        if (!["src", "title", "allow", "allowfullscreen"].includes(name)) frame.removeAttribute(name);
      }
      frame.setAttribute("allow", "fullscreen; picture-in-picture; encrypted-media");
      frame.setAttribute("loading", "lazy");
      frame.setAttribute("referrerpolicy", "strict-origin-when-cross-origin");
    });
    doc.body.querySelectorAll("*").forEach((el) => {
      for (const name of Array.from(el.getAttributeNames())) {
        const value = el.getAttribute(name) || "";
        if (name.startsWith("on") || name === "style" || name === "class" || name === "contenteditable" || name === "tabindex"
            || ((name === "href" || name === "src" || name === "xlink:href" || name === "action" || name === "formaction")
                && /^\s*(javascript|vbscript|data:text\/html)/i.test(value))) {
          el.removeAttribute(name);
        }
      }
      if (el.localName === "img") { el.setAttribute("loading", "lazy"); el.setAttribute("decoding", "async"); }
      if (el.localName === "a") el.removeAttribute("target");
      if (el.localName === "video" || el.localName === "audio") { el.setAttribute("controls", ""); el.removeAttribute("autoplay"); }
    });
    // Drop images that were only tracking pixels or spacers.
    doc.body.querySelectorAll("img").forEach((img) => {
      const w = parseInt(img.getAttribute("width") || "0", 10), h = parseInt(img.getAttribute("height") || "0", 10);
      if ((w && w < 4) || (h && h < 4)) img.remove();
    });
    return doc.body;
  }

  function readingTime(words) {
    const minutes = Math.max(1, Math.round(words / 230));
    return minutes + " min read";
  }

  function normalize(text) { return (text || "").replace(/\s+/g, " ").trim(); }

  function scrollToAnchor(anchor) {
    if (!anchor) return;
    const probe = normalize(anchor).slice(0, 60);
    if (probe.length < 12) return;
    const blocks = document.querySelectorAll("#content p, #content li, #content h2, #content h3, #content h4, #content blockquote, #content pre");
    for (const block of blocks) {
      if (normalize(block.textContent).includes(probe)) {
        const top = block.getBoundingClientRect().top + window.scrollY - 64;
        window.scrollTo(0, Math.max(0, top));
        return;
      }
    }
  }

  function applyPrefs() {
    prefs.size = Math.max(0, Math.min(SIZES.length - 1, prefs.size | 0));
    root.style.setProperty("--size", SIZES[prefs.size] + "px");
    root.dataset.face = prefs.face === "sans" ? "sans" : "serif";
    root.dataset.theme = ["auto", "light", "sepia", "dark"].includes(prefs.theme) ? prefs.theme : "auto";
    document.querySelectorAll("[data-face]").forEach((b) => { if (b.localName === "button") b.setAttribute("aria-pressed", String(b.dataset.face === root.dataset.face)); });
    document.querySelectorAll("[data-theme]").forEach((b) => { if (b.localName === "button") b.setAttribute("aria-pressed", String(b.dataset.theme === root.dataset.theme)); });
    document.querySelector('[data-step="-1"]').disabled = prefs.size === 0;
    document.querySelector('[data-step="1"]').disabled = prefs.size === SIZES.length - 1;
    updateProgress();
  }

  function changePrefs(change, keepPlace) {
    // Keep the paragraph at the top of the window in place while the text reflows.
    let anchor = null, offset = 0;
    if (keepPlace) {
      const blocks = document.querySelectorAll("#content > *, #content p, #content li");
      for (const block of blocks) {
        const r = block.getBoundingClientRect();
        if (r.bottom > 40) { anchor = block; offset = r.top; break; }
      }
    }
    Object.assign(prefs, change);
    applyPrefs();
    if (anchor) window.scrollTo(0, anchor.getBoundingClientRect().top + window.scrollY - offset);
    post({ type: "prefs", prefs });
  }

  function updateProgress() {
    const max = document.documentElement.scrollHeight - window.innerHeight;
    $("progress").style.width = (max > 0 ? Math.min(1, window.scrollY / max) * 100 : 0) + "%";
  }

  // Controls fade while reading and come back with the pointer.
  let idleTimer = 0;
  function wake() {
    document.body.classList.remove("idle");
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => { if (window.scrollY > 40) document.body.classList.add("idle"); }, 1800);
  }

  function setPanel(open) {
    const panel = $("panel");
    if (open === !panel.hidden) return;
    panel.hidden = !open;
    $("controls").classList.toggle("open", open);
    $("appearance").setAttribute("aria-expanded", String(open));
    if (open) { panel.classList.remove("enter"); void panel.offsetWidth; panel.classList.add("enter"); }
  }

  $("appearance").addEventListener("click", (e) => { e.stopPropagation(); setPanel($("panel").hidden); });
  $("done").addEventListener("click", () => post({ type: "close" }));
  $("panel").addEventListener("click", (e) => {
    e.stopPropagation();
    const button = e.target.closest("button");
    if (!button) return;
    if (button.dataset.step) changePrefs({ size: prefs.size + Number(button.dataset.step) }, true);
    else if (button.dataset.face) changePrefs({ face: button.dataset.face }, true);
    else if (button.dataset.theme) changePrefs({ theme: button.dataset.theme }, false);
  });
  document.addEventListener("click", (e) => {
    if (!$("panel").hidden && !e.target.closest("#controls")) setPanel(false);
    // Footnotes and in-article links stay in the reader.
    const link = e.target.closest("#content a[href]");
    if (!link) return;
    const href = link.getAttribute("href") || "";
    let target;
    try { target = new URL(href, pageURL || undefined); } catch (err) { return; }
    const page = pageURL ? new URL(pageURL) : null;
    if (target.hash && page && target.origin === page.origin && target.pathname === page.pathname && target.search === page.search) {
      e.preventDefault();
      const id = decodeURIComponent(target.hash.slice(1));
      const dest = document.getElementById(id) || document.getElementsByName(id)[0];
      if (dest) dest.scrollIntoView({ block: "start", behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
    }
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && !e.metaKey && !e.altKey && !e.ctrlKey) {
      e.preventDefault();
      if (!$("panel").hidden) setPanel(false); else post({ type: "close" });
    }
  });
  window.addEventListener("scroll", () => { updateProgress(); wake(); }, { passive: true });
  window.addEventListener("mousemove", wake, { passive: true });
  window.addEventListener("resize", updateProgress, { passive: true });

  window.BamReader = {
    render(article, savedPrefs, anchor) {
      pageURL = article.url || "";
      if (savedPrefs) prefs = Object.assign(prefs, savedPrefs);
      applyPrefs();
      document.title = article.title || "Reading Mode";
      if (article.lang) root.lang = article.lang;
      if (article.dir) root.dir = article.dir;
      $("site").textContent = normalize(article.siteName) || article.host || "";
      $("title").textContent = normalize(article.title);
      const meta = [];
      const byline = normalize(article.byline);
      if (byline && byline.length < 120 && byline !== normalize(article.siteName)) meta.push(byline);
      if (article.published) meta.push(article.published);
      if (article.words) meta.push(readingTime(article.words));
      $("meta").textContent = meta.join("  ·  ");
      const content = $("content");
      content.replaceChildren(...Array.from(sanitize(article.content).childNodes).map((n) => document.importNode(n, true)));
      // An image of the title (a picture of the headline) is dropped too.
      const titleText = normalize(article.title).toLowerCase();
      content.querySelectorAll("img[alt]").forEach((img) => { if (titleText && normalize(img.getAttribute("alt")).toLowerCase() === titleText) img.remove(); });
      // A first heading that repeats the title is dropped.
      const first = content.querySelector("h1, h2");
      if (first && normalize(first.textContent) === normalize(article.title) && first.getBoundingClientRect().top - content.getBoundingClientRect().top < 40) first.remove();
      scrollToAnchor(anchor);
      requestAnimationFrame(() => { document.body.classList.add("ready"); updateProgress(); wake(); });
      return true;
    },
    step(delta) {
      if (delta === 0) changePrefs({ size: 6 }, true);
      else changePrefs({ size: prefs.size + delta }, true);
      return prefs.size;
    },
    prefs() { return prefs; }
  };
  post({ type: "loaded" });
})();
