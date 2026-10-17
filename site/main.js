/* Dictate landing page.
 *
 * Three things move on this page, all driven from here:
 *  1. The waves: the same three sine waves as the app icon and the recording
 *     pill (magenta lows, blue mids, cyan highs), with the same envelope maths
 *     as the app's WaveShape, fed by a synthetic voice spectrum.
 *  2. The dictation demo: a scripted loop that presses the key, listens, works,
 *     then types the cleaned sentence into the mock window.
 *  3. Small loops in the feature cards.
 */

(() => {
  "use strict";

  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ---------------------------------------------------------------------------
  // Waves
  // ---------------------------------------------------------------------------

  // Mirrors LevelWaves in RecordingIndicator.swift: colours, frequencies, travel
  // speeds, phases and resting centres. Drawn in this order so magenta is on top.
  const WAVES = [
    { colors: ["#14d1cc", "#8cf5eb"], frequency: 2.0, speed: 6.6, phase: 2.6, center: 0.6, band: "high" },
    { colors: ["#1a6bf2", "#80b3ff"], frequency: 1.5, speed: -4.3, phase: 1.3, center: 0.5, band: "mid" },
    { colors: ["#ed17c7", "#ff80e0"], frequency: 1.0, speed: 5.5, phase: 0, center: 0.4, band: "low" },
  ];
  const LEAN = 0.15;

  /** A voice that is not there: a quiet, slowly breathing spectrum. */
  function idleSpectrum(t) {
    return {
      low: 0.18 + 0.08 * Math.sin(t * 0.9),
      mid: 0.22 + 0.08 * Math.sin(t * 1.3 + 1),
      high: 0.16 + 0.06 * Math.sin(t * 1.7 + 2),
      tilt: 0.3 * Math.sin(t * 0.4),
    };
  }

  /** Someone talking: syllables as bursts, with the bands moving independently. */
  function speakingSpectrum(t) {
    const syllable = Math.max(0, Math.sin(t * 9) * 0.6 + Math.sin(t * 13.7) * 0.4);
    const breath = 0.6 + 0.4 * Math.sin(t * 0.8);
    return {
      low: Math.min(1, 0.25 + syllable * 0.9 * breath + 0.1 * Math.sin(t * 5.1)),
      mid: Math.min(1, 0.3 + syllable * 0.8 + 0.15 * Math.sin(t * 7.3 + 1)),
      high: Math.min(1, 0.15 + syllable * 0.6 + 0.2 * Math.sin(t * 11 + 2)),
      tilt: 0.8 * Math.sin(t * 1.1),
    };
  }

  /** Builds the wave path, the way WaveShape does: a sine under a warped envelope. */
  function tracePath(ctx, width, midY, amplitude, center, frequency, phase, closed) {
    const warp = Math.log(0.5) / Math.log(center);
    const steps = Math.max(40, Math.floor(width));
    ctx.beginPath();
    for (let step = 0; step <= steps; step++) {
      const u = step / steps;
      const v = Math.pow(u, warp);
      const envelope = Math.pow(4 * v * (1 - v), 1.5);
      const y = midY - amplitude * envelope * Math.sin(2 * Math.PI * frequency * u + phase);
      const x = u * width;
      if (step === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    if (closed) {
      ctx.lineTo(width, midY);
      ctx.lineTo(0, midY);
      ctx.closePath();
    }
  }

  class WaveRenderer {
    /**
     * @param {HTMLCanvasElement} canvas
     * @param {{scale: number, stroke: number, glow: number, inset: number}} style
     */
    constructor(canvas, style) {
      this.canvas = canvas;
      this.ctx = canvas.getContext("2d");
      this.style = style;
      this.spectrum = idleSpectrum(0);
      this.target = this.spectrum;
      this.source = idleSpectrum;
      this.visible = true;
      this.dpr = Math.min(2, window.devicePixelRatio || 1);
      this.resize();
    }

    resize() {
      const rect = this.canvas.getBoundingClientRect();
      const w = Math.max(1, Math.round(rect.width * this.dpr));
      const h = Math.max(1, Math.round(rect.height * this.dpr));
      if (this.canvas.width !== w || this.canvas.height !== h) {
        this.canvas.width = w;
        this.canvas.height = h;
      }
    }

    draw(time) {
      this.resize();
      const { ctx, canvas, style } = this;
      const w = canvas.width;
      const h = canvas.height;
      ctx.clearRect(0, 0, w, h);

      // Spring towards the target spectrum, like the interactiveSpring in the app.
      const target = this.source(time);
      const s = this.spectrum;
      const k = 0.25;
      s.low += (target.low - s.low) * k;
      s.mid += (target.mid - s.mid) * k;
      s.high += (target.high - s.high) * k;
      s.tilt += (target.tilt - s.tilt) * k;

      const inset = style.inset * w;
      const width = w - inset * 2;
      const midY = h / 2;
      const maxAmp = h * style.scale;

      ctx.save();
      ctx.translate(inset, 0);
      ctx.lineCap = "round";
      ctx.lineJoin = "round";

      for (const wave of WAVES) {
        const level = Math.min(1, s[wave.band]);
        const amplitude = maxAmp * (style.floor + (1 - style.floor) * level);
        const center = Math.min(0.75, Math.max(0.25, wave.center + LEAN * s.tilt));
        const phase = wave.phase + time * wave.speed;
        const gradient = ctx.createLinearGradient(0, 0, width, 0);
        gradient.addColorStop(0, wave.colors[0]);
        gradient.addColorStop(0.5, wave.colors[1]);
        gradient.addColorStop(1, wave.colors[0]);

        // Glow: the closed shape, blurred and translucent.
        ctx.save();
        ctx.filter = `blur(${style.glow * this.dpr}px)`;
        ctx.globalAlpha = 0.35;
        ctx.fillStyle = gradient;
        tracePath(ctx, width, midY, amplitude, center, wave.frequency, phase, true);
        ctx.fill();
        ctx.restore();

        // Stroke on top.
        ctx.strokeStyle = gradient;
        ctx.lineWidth = style.stroke * this.dpr;
        tracePath(ctx, width, midY, amplitude, center, wave.frequency, phase, false);
        ctx.stroke();
      }
      ctx.restore();
    }
  }

  const STYLES = {
    // Big icon: wide strokes, generous glow, waves across most of the square.
    hero: { scale: 0.3, stroke: 7, glow: 16, inset: 0.0, floor: 0.45 },
    download: { scale: 0.3, stroke: 4, glow: 10, inset: 0.0, floor: 0.45 },
    nav: { scale: 0.3, stroke: 1.6, glow: 1.5, inset: 0.0, floor: 0.45 },
    // The pill: 72×26 points like the real one, thin stroke.
    pill: { scale: 0.42, stroke: 1.2, glow: 3, inset: 0.0, floor: 0.08 },
    feature: { scale: 0.42, stroke: 1.2, glow: 3, inset: 0.0, floor: 0.08 },
  };

  const renderers = new Map();
  for (const canvas of document.querySelectorAll("canvas[data-wave]")) {
    const kind = canvas.dataset.wave;
    const renderer = new WaveRenderer(canvas, STYLES[kind] || STYLES.pill);
    renderers.set(kind, renderer);
  }

  // The icon-sized waves "listen" on their own, in slow motion, so the icon feels
  // alive without shouting; the pill waves follow the demo.
  const iconBreath = (t) => {
    const s = speakingSpectrum(t * 0.35);
    return { low: s.low * 0.8, mid: s.mid * 0.8, high: s.high * 0.8, tilt: s.tilt };
  };
  for (const kind of ["hero", "download", "nav"]) {
    const r = renderers.get(kind);
    if (r) r.source = iconBreath;
  }
  const featurePill = renderers.get("feature");
  if (featurePill) featurePill.source = (t) => speakingSpectrum(t * 0.7);

  // Only draw what is on screen.
  const visibleCanvases = new Set();
  const io = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) visibleCanvases.add(entry.target);
      else visibleCanvases.delete(entry.target);
    }
  }, { rootMargin: "80px" });
  for (const r of renderers.values()) io.observe(r.canvas);

  let lastFrame = 0;
  function frame(now) {
    const time = now / 1000;
    const slow = reducedMotion ? 0.25 : 1;
    for (const r of renderers.values()) {
      if (!visibleCanvases.has(r.canvas)) continue;
      if (r.canvas.offsetParent === null && !r.canvas.closest(".pill.static")) continue;
      r.draw(time * slow);
    }
    lastFrame = now;
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);

  // ---------------------------------------------------------------------------
  // Dictation demo
  // ---------------------------------------------------------------------------

  const SCENARIOS = {
    mail: {
      title: "Mail",
      label: "Message",
      theme: "",
      prefix: "Bonjour Claire,\n\n",
      heard: "euh donc je je voulais te dire que la réunion de de jeudi est décalée à mardi euh à la même heure et je t'envoie le lien dans la foulée",
      fillers: ["euh", "je je", "de de"],
      clean: "Je voulais te dire que la réunion de jeudi est décalée à mardi, à la même heure. Je t'envoie le lien dans la foulée.",
    },
    chat: {
      title: "#projet-nova · Slack",
      label: "Message",
      theme: "dark",
      prefix: "",
      heard: "ouais euh c'est bon pour moi on déploie en fin de journée euh et je ping marc pour le post-mortem",
      fillers: ["euh", "ouais"],
      clean: "C'est bon pour moi, on déploie en fin de journée. Je ping Marc pour le post-mortem.",
    },
    code: {
      title: "Transcriber.swift — Dictate",
      label: "Commentaire",
      theme: "dark code",
      prefix: "// ",
      heard: "alors euh on garde les deux cents dernières millisecondes après le relâchement de la touche parce que sinon on coupe la dernière syllabe",
      fillers: ["alors euh", "euh"],
      clean: "Keep the last 200 ms after the key is released, otherwise the last syllable is clipped.",
    },
    terminal: {
      title: "zsh — ~/Code/dictate",
      label: "Commande",
      theme: "terminal",
      prefix: "",
      heard: "git commit moins m euh fixe deux points garde les deux cents millisecondes après le relâchement",
      fillers: ["euh"],
      clean: "git commit -m \"fix: keep 200 ms after the key is released\"",
    },
  };
  const ORDER = Object.keys(SCENARIOS);

  const dom = {
    window: document.querySelector("[data-window]"),
    title: document.querySelector("[data-window-title]"),
    label: document.querySelector("[data-field-label]"),
    text: document.querySelector("[data-field-text]"),
    pill: document.querySelector("[data-pill]"),
    key: document.querySelector("[data-key]"),
    keyState: document.querySelector("[data-key-state]"),
    heard: document.querySelector("[data-heard]"),
    steps: Array.from(document.querySelectorAll("[data-step]")),
    tabs: Array.from(document.querySelectorAll("[data-scenario]")),
  };

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  function setStep(name) {
    let reached = false;
    for (const li of dom.steps) {
      const step = li.dataset.step;
      li.classList.remove("active", "done");
      if (name === null) continue;
      if (step === name) { li.classList.add("active"); reached = true; }
      else if (!reached) li.classList.add("done");
    }
  }

  function setPill(mode) {
    dom.pill.classList.toggle("visible", mode !== null);
    dom.pill.classList.toggle("recording", mode === "recording");
    dom.pill.classList.toggle("processing", mode === "processing");
  }

  function setKey(pressed) {
    dom.key.classList.toggle("pressed", pressed);
    dom.keyState.textContent = pressed ? "Maintenue" : "Relâchée";
    dom.keyState.classList.toggle("on", pressed);
  }

  function setFieldText(text, withCaret = true) {
    dom.text.textContent = text;
    if (withCaret) {
      const caret = document.createElement("span");
      caret.className = "caret";
      dom.text.appendChild(caret);
    }
  }

  /** Shows the raw transcript word by word, then strikes the hesitations. */
  function heardMarkup(scenario, upTo) {
    const words = scenario.heard.split(" ");
    return words.slice(0, upTo).join(" ");
  }

  function heardStruck(scenario) {
    let html = scenario.heard
      .replace(/&/g, "&amp;").replace(/</g, "&lt;");
    for (const filler of [...scenario.fillers].sort((a, b) => b.length - a.length)) {
      const re = new RegExp(`(^|\\s)(${filler.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")})(?=\\s|$)`, "g");
      html = html.replace(re, "$1<s>$2</s>");
    }
    return html;
  }

  let current = "mail";
  let run = 0;
  let demoVisible = false;

  async function playScenario(name, token) {
    const scenario = SCENARIOS[name];
    const pillRenderer = renderers.get("pill");
    const alive = () => token === run;

    // Set the scene.
    dom.window.className = "window " + scenario.theme;
    dom.title.textContent = scenario.title;
    dom.label.textContent = scenario.label;
    setFieldText(scenario.prefix);
    dom.heard.innerHTML = "";
    setStep(null);
    setPill(null);
    setKey(false);
    await sleep(900);
    if (!alive()) return;

    // Hold the key: the pill appears with the waves, the raw words come in.
    setKey(true);
    setStep("recording");
    setPill("recording");
    if (pillRenderer) pillRenderer.source = speakingSpectrum;
    const words = scenario.heard.split(" ");
    const perWord = reducedMotion ? 60 : 210;
    for (let i = 1; i <= words.length; i++) {
      dom.heard.textContent = heardMarkup(scenario, i);
      await sleep(perWord + (words[i - 1].length > 6 ? 70 : 0));
      if (!alive()) return;
    }
    await sleep(250);
    if (!alive()) return;

    // Release: a short tail is kept, then the spinner.
    setKey(false);
    if (pillRenderer) pillRenderer.source = idleSpectrum;
    await sleep(250);
    if (!alive()) return;
    setPill("processing");
    setStep("transcribing");
    await sleep(700);
    if (!alive()) return;
    setStep("enhancing");
    dom.heard.innerHTML = heardStruck(scenario);
    await sleep(1100);
    if (!alive()) return;

    // The clean sentence lands at the cursor.
    setPill(null);
    setStep("pasted");
    const clean = scenario.clean;
    const perChar = reducedMotion ? 4 : 14;
    for (let i = 1; i <= clean.length; i++) {
      setFieldText(scenario.prefix + clean.slice(0, i));
      await sleep(perChar);
      if (!alive()) return;
    }
    await sleep(3200);
  }

  async function loop() {
    for (;;) {
      const token = ++run;
      await playScenario(current, token);
      if (token !== run) continue; // a tab click restarted the loop
      if (!demoVisible) { await sleep(500); continue; }
      current = ORDER[(ORDER.indexOf(current) + 1) % ORDER.length];
      selectTab(current);
    }
  }

  function selectTab(name) {
    for (const tab of dom.tabs) tab.setAttribute("aria-selected", String(tab.dataset.scenario === name));
  }

  for (const tab of dom.tabs) {
    tab.addEventListener("click", () => {
      current = tab.dataset.scenario;
      selectTab(current);
      run++; // interrupts the running scenario; loop() picks the new one up
    });
  }

  const demoSection = document.getElementById("demo");
  new IntersectionObserver((entries) => {
    demoVisible = entries.some((e) => e.isIntersecting);
  }, { threshold: 0.2 }).observe(demoSection);

  loop();

  // ---------------------------------------------------------------------------
  // Feature cards
  // ---------------------------------------------------------------------------

  // The big key presses itself every few seconds.
  const featureKey = document.querySelector("[data-key-feature]");
  if (featureKey && !reducedMotion) {
    (async () => {
      for (;;) {
        await sleep(2200);
        featureKey.classList.add("pressed");
        await sleep(1600);
        featureKey.classList.remove("pressed");
      }
    })();
  }

  // The context chips light up one after another.
  const chips = Array.from(document.querySelectorAll(".context-demo .chip"));
  if (chips.length) {
    let i = 0;
    chips[0].classList.add("lit");
    setInterval(() => {
      chips[i].classList.remove("lit");
      i = (i + 1) % chips.length;
      chips[i].classList.add("lit");
    }, 1400);
  }

  // The cursor card types a few phrases.
  const typed = document.querySelector("[data-typed]");
  if (typed) {
    const phrases = [
      "merci pour ton retour, je corrige ça ce matin.",
      "on se voit à 14 h, salle Lumière.",
      "le dossier est dans le drive partagé.",
    ];
    (async () => {
      let p = 0;
      for (;;) {
        const phrase = phrases[p];
        for (let i = 1; i <= phrase.length; i++) {
          typed.textContent = phrase.slice(0, i);
          await sleep(reducedMotion ? 5 : 28);
        }
        await sleep(2400);
        typed.textContent = "";
        await sleep(700);
        p = (p + 1) % phrases.length;
      }
    })();
  }

  // ---------------------------------------------------------------------------
  // Reveal on scroll, latest version
  // ---------------------------------------------------------------------------

  for (const el of document.querySelectorAll(".card, .flow-node, .privacy-points li, .section-title, .section-lead")) {
    el.classList.add("reveal");
  }
  const revealer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) { entry.target.classList.add("in"); revealer.unobserve(entry.target); }
    }
  }, { threshold: 0.15 });
  for (const el of document.querySelectorAll(".reveal")) revealer.observe(el);

  // The GitHub API is public for this; failing silently keeps the generic label.
  fetch("https://api.github.com/repos/moifort/dictate/releases/latest", { headers: { Accept: "application/vnd.github+json" } })
    .then((r) => (r.ok ? r.json() : null))
    .then((release) => {
      if (!release || !release.tag_name) return;
      const version = release.tag_name.replace(/^v/, "");
      for (const el of document.querySelectorAll("[data-version]")) el.textContent = `Version ${version}`;
      const dmg = (release.assets || []).find((a) => a.name.endsWith(".dmg"));
      if (dmg) {
        for (const a of document.querySelectorAll("[data-download]")) a.href = dmg.browser_download_url;
      }
    })
    .catch(() => {});
})();
