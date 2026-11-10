/* Dictate landing page: its 25 languages.
 * The page is written in French. The head script picks the language
 * (<html lang>); every language but French has its texts in i18n/<code>.js.
 * Elements carrying data-i18n get their HTML from there before the first
 * paint (the head script hides the page until then), data-i18n-aria
 * translates an aria-label, and the App Store badge takes Apple's artwork for
 * that language. main.js starts once the texts are in: its demo reads them. */
(() => {
  "use strict";
  const root = document.documentElement;
  // The same cache-busting query as this script's own.
  const version = new URL(document.currentScript.src).search;

  const start = () => {
    root.classList.remove("i18n-pending");
    const main = document.createElement("script");
    main.src = `main.js${version}`;
    document.body.append(main);
  };

  const apply = (dictionary) => {
    for (const el of document.querySelectorAll("[data-i18n]")) {
      const html = dictionary.text[el.dataset.i18n];
      if (html !== undefined) el.innerHTML = html;
    }
    for (const el of document.querySelectorAll("[data-i18n-aria]")) {
      const label = dictionary.text[el.dataset.i18nAria];
      if (label !== undefined) el.setAttribute("aria-label", label);
    }
    document.querySelector('meta[name="description"]')?.setAttribute("content", dictionary.text["meta.description"]);
    for (const img of document.querySelectorAll("[data-store-badge]")) img.src = dictionary.badge;
  };

  const load = (lang, otherwise) => {
    const script = document.createElement("script");
    script.src = `i18n/${lang}.js${version}`;
    script.onload = () => {
      root.lang = lang;
      apply(window.DICTATE_I18N);
      start();
    };
    script.onerror = otherwise;
    document.head.append(script);
  };

  if (root.lang === "fr") {
    start();
    return;
  }
  // A dictionary that does not load gives English, then the French page as written.
  load(root.lang, () =>
    load("en", () => {
      root.lang = "fr";
      start();
    }),
  );
})();
