// Music Library website: small progressive enhancements. The page works without any of it.

const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

// Nav border once the page scrolls.
const nav = document.querySelector(".nav");
const onScroll = () => nav.classList.toggle("scrolled", window.scrollY > 8);
window.addEventListener("scroll", onScroll, { passive: true });
onScroll();

// Fade sections in as they scroll into view.
const revealed = document.querySelectorAll(".reveal");
if ("IntersectionObserver" in window && !reduceMotion) {
  const io = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        entry.target.classList.add("in");
        io.unobserve(entry.target);
      }
    }
  }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
  revealed.forEach((el) => io.observe(el));
} else {
  revealed.forEach((el) => el.classList.add("in"));
}

// The search bar types a few real queries.
const typed = document.getElementById("typed");
const queries = [
  "genre:jazz year:1955-1965 is:hires",
  'credit:"rudy van gelder"',
  "added:30d -is:live",
  "missing:cover",
  'label:"blue note" decade:60s',
  "time:>10m is:lossless",
  "own:vinyl genre:jazz",
  "own:cd ripped:no bought:2024",
];
function highlight(text) {
  const escape = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  return text.split(/(\s+)/).map((word) => {
    const m = word.match(/^(-?)([a-z]+:)(.*)$/);
    if (!m) return escape(word);
    return (m[1] ? `<span class="tok-neg">-</span>` : "") + `<span class="tok-key">${m[2]}</span>${escape(m[3])}`;
  }).join("");
}
if (typed && !reduceMotion) {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  (async () => {
    for (let i = 0; ; i = (i + 1) % queries.length) {
      const q = queries[i];
      for (let n = 1; n <= q.length; n++) {
        typed.innerHTML = highlight(q.slice(0, n));
        await sleep(45 + Math.random() * 45);
      }
      await sleep(2200);
      for (let n = q.length; n >= 0; n--) {
        typed.innerHTML = highlight(q.slice(0, n));
        await sleep(18);
      }
      await sleep(350);
    }
  })();
} else if (typed) {
  typed.innerHTML = highlight(typed.textContent);
}

// Swap a screenshot with a quick fade.
function swapShot(button, src, alt) {
  const img = button.querySelector("img");
  if (img.getAttribute("src") === src) return;
  const next = new Image();
  next.src = src;
  button.classList.add("fade-swap", "swapping");
  const show = () => {
    img.src = src;
    img.alt = alt;
    requestAnimationFrame(() => button.classList.remove("swapping"));
  };
  (next.decode ? next.decode() : Promise.resolve()).then(show, show);
}

// Insights: Digital Collection / Listening tabs.
const tabs = document.querySelectorAll('.tabs [role="tab"]');
tabs.forEach((tab) => {
  tab.addEventListener("click", () => {
    tabs.forEach((t) => t.setAttribute("aria-selected", String(t === tab)));
    swapShot(document.getElementById("insights-shot"), tab.dataset.src, tab.dataset.alt);
  });
});

// Themes: preview the two themes we have screenshots of.
const themeButtons = document.querySelectorAll("[data-theme-shot]");
themeButtons.forEach((button) => {
  button.addEventListener("click", () => {
    themeButtons.forEach((b) => b.setAttribute("aria-pressed", String(b === button)));
    swapShot(document.getElementById("theme-shot"), button.dataset.themeShot, button.dataset.themeAlt);
  });
});

// Click a screenshot (or a picture in the docs) to see it full size.
const lightbox = document.getElementById("lightbox");
if (lightbox && typeof lightbox.showModal === "function") {
  const big = lightbox.querySelector("img");
  const zoom = (img) => {
    big.src = img.currentSrc || img.src;
    big.alt = img.alt;
    lightbox.showModal();
  };
  document.querySelectorAll("[data-zoom]").forEach((shot) => {
    shot.addEventListener("click", () => zoom(shot.querySelector("img")));
  });
  document.querySelectorAll(".prose img").forEach((img) => img.addEventListener("click", () => zoom(img)));
  lightbox.addEventListener("click", (event) => {
    if (event.target === lightbox || event.target === big) lightbox.close();
  });
} else {
  document.querySelectorAll("[data-zoom], .prose img").forEach((shot) => (shot.style.cursor = "default"));
}

// Docs: on a phone, the page list starts folded so the page comes first.
const docsNav = document.querySelector(".docs-nav details");
if (docsNav && window.matchMedia("(max-width: 820px)").matches) docsNav.open = false;

// Copy the build commands.
document.querySelectorAll(".copy").forEach((button) => {
  button.addEventListener("click", async () => {
    const text = button.parentElement.querySelector("code").textContent;
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = "Copied";
    } catch {
      button.textContent = "Select and copy";
    }
    setTimeout(() => (button.textContent = "Copy"), 1800);
  });
});

// Show the latest release's version (unauthenticated GitHub API; fine if it fails or is rate limited).
fetch("https://api.github.com/repos/davidlago/music-library/releases/latest", { headers: { Accept: "application/vnd.github+json" } })
  .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
  .then((release) => {
    const version = String(release.tag_name || "").replace(/^v/, "");
    if (!/^\d+\.\d+\.\d+$/.test(version)) return;
    const meta = document.getElementById("release-meta");
    if (meta) meta.textContent = `Version ${version} · macOS 14 or later · Apple Silicon and Intel · Signed and notarized by Apple`;
    document.querySelectorAll(".ver").forEach((el) => (el.textContent = version));
  })
  .catch(() => {});
