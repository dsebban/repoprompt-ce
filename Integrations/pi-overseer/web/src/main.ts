import { mount } from "svelte";
import App from "./App.svelte";
import "./app.css";

// Track the visual viewport so the app shrinks above the iOS keyboard instead of being
// scrolled under it, and flag when the keyboard is up (the tab bar hides, like native apps).
const vv = window.visualViewport;
if (vv) {
  const root = document.documentElement;
  let frame = 0;
  const sync = () => {
    frame = 0;
    root.style.setProperty("--vv-height", `${vv.height}px`);
    root.style.setProperty("--vv-top", `${vv.offsetTop}px`);
    root.classList.toggle("keyboard-open", window.innerHeight - vv.height > 120);
  };
  const schedule = () => {
    if (!frame) frame = requestAnimationFrame(sync);
  };
  vv.addEventListener("resize", schedule);
  vv.addEventListener("scroll", schedule);
  sync();
}

mount(App, { target: document.getElementById("app")! });
