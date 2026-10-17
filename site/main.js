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

  /** Deterministic noise in [0, 1) for a given integer. */
  function hash(n) {
    const x = Math.sin(n * 127.1 + 311.7) * 43758.5453;
    return x - Math.floor(x);
  }

  /**
   * A person talking: phrases of a few words separated by breaths, words of
   * two or three syllables with short gaps, syllables at about five per second
   * with a sharp attack and a slower decay. Consonants light up the highs at
   * the start of a syllable, vowels carry the lows and mids.
   */
  function talkingSpectrum(t) {
    // Phrases: 1.8 to 3.4 s of speech, then 0.45 to 0.9 s of silence.
    let start = 0;
    let phrase = 0;
    for (;;) {
      const length = 1.8 + 1.6 * hash(phrase) + 0.45 + 0.45 * hash(phrase + 50);
      if (t < start + length) break;
      start += length;
      phrase++;
      if (phrase > 100000) break;
    }
    const local = t - start;
    const speech = 1.8 + 1.6 * hash(phrase);
    const gate = local < speech
      ? Math.min(1, local / 0.08) * Math.min(1, (speech - local) / 0.25)
      : 0;

    // Syllables at a slightly irregular rate, grouped into words.
    const rate = 4.6 + 0.8 * hash(phrase + 7);
    const position = local * rate;
    const index = Math.floor(position);
    const phase = position - index;
    const seed = phrase * 97 + index;
    const wordGap = hash(seed + 3) < 0.22 ? 0.25 : 1; // a short pause between words
    const stress = 0.65 + 0.35 * hash(seed);
    const attack = 0.18;
    const shape = phase < attack ? phase / attack : Math.exp(-(phase - attack) * 2.2);
    const gain = 1.7;
    const vowel = gain * gate * wordGap * stress * shape;
    const consonant = gain * gate * wordGap * (phase < 0.22 ? 1 - phase / 0.22 : 0) * (0.4 + 0.6 * hash(seed + 11));

    return {
      low: Math.min(1, vowel * (0.75 + 0.25 * Math.sin(t * 3.1))),
      mid: Math.min(1, vowel * 0.85 + consonant * 0.25),
      high: Math.min(1, consonant * 0.9 + vowel * 0.3),
      tilt: gate * (hash(seed + 23) * 2 - 1) * 0.8,
    };
  }

  /** Builds the wave path, the way WaveShape does: a sine under a warped envelope. */
  function tracePath(ctx, width, midY, amplitude, center, frequency, phase, closed, focus = 1.5) {
    const warp = Math.log(0.5) / Math.log(center);
    const steps = Math.max(40, Math.floor(width));
    ctx.beginPath();
    for (let step = 0; step <= steps; step++) {
      const u = step / steps;
      const v = Math.pow(u, warp);
      const envelope = Math.pow(4 * v * (1 - v), focus);
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

  /**
   * Same wave, drawn as a ribbon whose thickness follows the envelope: hairline
   * at both edges, widest where the wave is tallest. For the full-width hero.
   */
  function traceRibbon(ctx, width, midY, amplitude, center, frequency, phase, minWidth, maxWidth) {
    const warp = Math.log(0.5) / Math.log(center);
    const steps = Math.max(80, Math.floor(width / 2));
    const top = [];
    const bottom = [];
    for (let step = 0; step <= steps; step++) {
      const u = step / steps;
      const v = Math.pow(u, warp);
      const envelope = Math.pow(4 * v * (1 - v), 1.5);
      const y = midY - amplitude * envelope * Math.sin(2 * Math.PI * frequency * u + phase);
      const half = (minWidth + (maxWidth - minWidth) * envelope) / 2;
      const x = u * width;
      top.push([x, y - half]);
      bottom.push([x, y + half]);
    }
    ctx.beginPath();
    ctx.moveTo(top[0][0], top[0][1]);
    for (let i = 1; i < top.length; i++) ctx.lineTo(top[i][0], top[i][1]);
    for (let i = bottom.length - 1; i >= 0; i--) ctx.lineTo(bottom[i][0], bottom[i][1]);
    ctx.closePath();
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
        const spread = style.spread ?? 1;
        const center = Math.min(0.75, Math.max(0.25, 0.5 + (wave.center - 0.5) * spread + LEAN * spread * s.tilt));
        const frequency = wave.frequency * (style.freq ?? 1);
        const focus = style.focus ?? 1.5;
        const phase = wave.phase + time * wave.speed;
        const gradient = ctx.createLinearGradient(0, 0, width, 0);
        gradient.addColorStop(0, wave.colors[0]);
        gradient.addColorStop(0.5, wave.colors[1]);
        gradient.addColorStop(1, wave.colors[0]);

        if (style.ribbon) {
          const minWidth = style.ribbon[0] * this.dpr;
          const maxWidth = style.ribbon[1] * this.dpr;
          // Soft halo under the ribbon.
          ctx.save();
          ctx.filter = `blur(${style.glow * this.dpr}px)`;
          ctx.globalAlpha = 0.3;
          ctx.fillStyle = gradient;
          traceRibbon(ctx, width, midY, amplitude, center, wave.frequency, phase, minWidth, maxWidth * 1.8);
          ctx.fill();
          ctx.restore();
          ctx.globalAlpha = 0.92;
          ctx.fillStyle = gradient;
          traceRibbon(ctx, width, midY, amplitude, center, wave.frequency, phase, minWidth, maxWidth);
          ctx.fill();
          ctx.globalAlpha = 1;
          continue;
        }

        // Glow: the closed shape, blurred and translucent.
        ctx.save();
        ctx.filter = `blur(${style.glow * this.dpr}px)`;
        ctx.globalAlpha = 0.35;
        ctx.fillStyle = gradient;
        tracePath(ctx, width, midY, amplitude, center, frequency, phase, true, focus);
        ctx.fill();
        ctx.restore();

        // Stroke on top.
        ctx.strokeStyle = gradient;
        ctx.lineWidth = style.stroke * this.dpr;
        tracePath(ctx, width, midY, amplitude, center, frequency, phase, false, focus);
        ctx.stroke();
      }
      ctx.restore();
    }
  }

  const STYLES = {
    // Big icon: wide strokes, generous glow, waves across most of the square.
    // Full width, like the icon: a crisp 3 px gradient line over a soft translucent fill.
    // focus sharpens the envelope so the motion gathers in the middle third;
    // spread pulls the three peaks together; freq adds crossings there.
    hero: { scale: 0.46, stroke: 3, glow: 12, inset: 0.0, floor: 0.06, focus: 5, spread: 0.4, freq: 1.8 },
    download: { scale: 0.3, stroke: 4, glow: 10, inset: 0.0, floor: 0.45 },
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
  const download = renderers.get("download");
  if (download) download.source = iconBreath;
  const hero = renderers.get("hero");
  if (hero) hero.source = talkingSpectrum;
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

  // Two mails, dictated in turn in the same window.
  const SCENARIOS = [
    {
      to: "Claire Dubois",
      subject: "Réunion de jeudi",
      prefix: "Bonjour Claire,\n\n",
      heard: "euh donc je je voulais te dire que la réunion de de jeudi est décalée à mardi euh à la même heure et je t'envoie le lien dans la foulée",
      clean: "Je voulais te dire que la réunion de jeudi est décalée à mardi, à la même heure. Je t'envoie le lien dans la foulée.",
    },
    {
      to: "Marc Lefèvre",
      subject: "Re: Devis site web",
      prefix: "Bonjour Marc,\n\n",
      heard: "alors euh merci pour le devis euh on part sur la deuxième option et et je te confirme la date de démarrage d'ici vendredi",
      clean: "Merci pour le devis. On part sur la deuxième option, et je te confirme la date de démarrage d'ici vendredi.",
    },
  ];

  const dom = {
    to: document.querySelector("[data-mail-to]"),
    subject: document.querySelector("[data-mail-subject]"),
    text: document.querySelector("[data-field-text]"),
    pill: document.querySelector("[data-pill]"),
    key: document.querySelector("[data-key]"),
    steps: Array.from(document.querySelectorAll("[data-step]")),
  };

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  /** Lights the timeline up to `name`: earlier steps done, that one active. */
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
  }

  function setFieldText(text, withCaret = true) {
    dom.text.textContent = text;
    if (withCaret) {
      const caret = document.createElement("span");
      caret.className = "caret";
      dom.text.appendChild(caret);
    }
  }

  let run = 0;
  let demoVisible = false;

  async function playScenario(scenario, token) {
    const pillRenderer = renderers.get("pill");
    const alive = () => token === run;

    // Set the scene.
    dom.to.textContent = scenario.to;
    dom.subject.textContent = scenario.subject;
    setFieldText(scenario.prefix);
    setStep(null);
    setPill(null);
    setKey(false);
    await sleep(900);
    if (!alive()) return;

    // Hold the key: the pill appears with the waves.
    setKey(true);
    setStep("hold");
    setPill("recording");
    if (pillRenderer) pillRenderer.source = speakingSpectrum;
    await sleep(500);
    if (!alive()) return;

    // Speak: the recording lasts as long as the sentence takes to say.
    setStep("speak");
    const words = scenario.heard.split(" ");
    const perWord = reducedMotion ? 60 : 210;
    for (const word of words) {
      await sleep(perWord + (word.length > 6 ? 70 : 0));
      if (!alive()) return;
    }
    await sleep(250);
    if (!alive()) return;

    // Release: a short tail is kept, then the spinner while the text is made.
    setKey(false);
    setStep("release");
    if (pillRenderer) pillRenderer.source = idleSpectrum;
    await sleep(250);
    if (!alive()) return;
    setPill("processing");
    await sleep(1500);
    if (!alive()) return;

    // The clean sentence lands at the cursor.
    setPill(null);
    setStep("written");
    const clean = scenario.clean;
    const perChar = reducedMotion ? 4 : 14;
    for (let i = 1; i <= clean.length; i++) {
      setFieldText(scenario.prefix + clean.slice(0, i));
      await sleep(perChar);
      if (!alive()) return;
    }
    await sleep(3600);
  }

  async function loop() {
    let index = 0;
    for (;;) {
      const token = ++run;
      await playScenario(SCENARIOS[index], token);
      if (token !== run) continue;
      if (!demoVisible) { await sleep(500); continue; }
      index = (index + 1) % SCENARIOS.length;
    }
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
  for (const key of document.querySelectorAll("[data-key-feature], [data-key-hero]")) {
    if (reducedMotion) break;
    (async () => {
      for (;;) {
        await sleep(2200);
        key.classList.add("pressed");
        await sleep(1600);
        key.classList.remove("pressed");
      }
    })();
  }

  // The latency card counts up to the median and settles there, with the bar
  // filling underneath.
  for (const timer of document.querySelectorAll("[data-timer]")) {
    const timerBar = timer.parentElement.querySelector("[data-timer-bar]");
    if (!timerBar) continue;
    const median = 1.5;
    (async () => {
      for (;;) {
        const start = performance.now();
        timerBar.style.transition = "none";
        timerBar.style.width = "0";
        await sleep(20);
        timerBar.style.transition = `width ${median}s linear`;
        timerBar.style.width = "100%";
        let elapsed = 0;
        while (elapsed < median) {
          elapsed = Math.min(median, (performance.now() - start) / 1000);
          timer.textContent = elapsed.toFixed(1).replace(".", ",") + " s";
          await sleep(50);
        }
        timer.textContent = "1,5 s";
        await sleep(2600);
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

  // The cursor card types a phrase in one app after another.
  const typed = document.querySelector("[data-typed]");
  const typedApp = document.querySelector("[data-typed-app]");
  if (typed) {
    const phrases = [
      { app: "Mail", text: "Bonjour Marie, merci pour ton retour, je corrige ça ce matin." },
      { app: "Slack", text: "on se voit à 14 h salle Lumière ?" },
      { app: "Notes", text: "Idée : relancer le fournisseur avant la fin du mois." },
      { app: "Terminal", text: "lance les tests du module de paiement" },
      { app: "Claude", text: "Explique-moi ce que fait cette fonction." },
    ];
    (async () => {
      let p = 0;
      for (;;) {
        const phrase = phrases[p];
        if (typedApp) typedApp.textContent = phrase.app;
        for (let i = 1; i <= phrase.text.length; i++) {
          typed.textContent = phrase.text.slice(0, i);
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

  for (const el of document.querySelectorAll(".card, .pair, .faq-list details, .flow-node, .privacy-points li, .section-title, .section-lead")) {
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
