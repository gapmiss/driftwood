// Light/dark toggle, shared by both pages.
//
// The <head> of each page applies the saved mode *before* the stylesheet
// loads, so a reader who picked light does not get a frame of dark. This file
// only draws the button and handles the click, which is why it can load at the
// end of the body.
(function () {
  var SUN = '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4.5"/><path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.2 5.2l1.4 1.4M17.4 17.4l1.4 1.4M18.8 5.2l-1.4 1.4M6.6 17.4l-1.4 1.4"/></svg>';
  var MOON = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5z"/></svg>';

  var toggle = document.getElementById("mode-toggle");
  if (!toggle) return;

  // What the button *does*, not what mode you are in — so the icon shows the
  // mode you would switch to.
  function currentMode() {
    if (document.documentElement.dataset.theme) {
      return document.documentElement.dataset.theme;
    }
    return window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
  }

  function draw() {
    var dark = currentMode() === "dark";
    toggle.innerHTML = dark ? SUN : MOON;
    toggle.setAttribute("aria-label", dark ? "Switch to light mode" : "Switch to dark mode");
  }

  toggle.addEventListener("click", function () {
    var next = currentMode() === "dark" ? "light" : "dark";
    document.documentElement.dataset.theme = next;
    try { localStorage.setItem("driftwood-mode", next); } catch (e) {}
    draw();
  });

  // Follow the OS until the reader overrides it. Once data-theme is set the
  // override wins, and this listener stops mattering.
  window.matchMedia("(prefers-color-scheme: light)").addEventListener("change", draw);

  draw();
})();
