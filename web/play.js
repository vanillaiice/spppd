// Starts the love.js build of SPPPD on /play/. love.js's own page sets this up in
// inline script, which the site's Content-Security-Policy doesn't allow, so it lives
// here. bridge.js runs before this; this loads game.js (the packed game), then
// love.js (LÖVE), and starts LÖVE once it's in.
(function () {
  var canvas = document.getElementById("canvas");
  var status = document.getElementById("status");
  var cover = document.getElementById("cover");

  function say(text) {
    if (status) status.textContent = text;
  }

  canvas.addEventListener("webglcontextlost", function (e) {
    e.preventDefault();
    say("The graphics were lost. Reload the page to play again.");
    cover.hidden = false;
  }, false);

  window.addEventListener("load", function () { window.focus(); });
  canvas.addEventListener("pointerdown", function () { window.focus(); });
  // A right click is the editor's delete, not the browser's menu.
  canvas.addEventListener("contextmenu", function (e) { e.preventDefault(); });

  var M = window.Module = window.Module || {};
  M.arguments = ["./game.love"];
  // The heap grows as needed (up to 2 GB); a race on the desktop never took it past
  // this. Asking for much more up front can fail on a phone.
  M.INITIAL_MEMORY = 67108864;
  M.canvas = canvas;
  M.printErr = console.error.bind(console);
  M.totalDependencies = 0;
  M.remainingDependencies = 0;
  M.setStatus = function (text) {
    if (text) {
      say(text.replace(/\(\d+(\.\d+)?\/\d+(\.\d+)?\)/, "").trim() || "Loading");
    } else if (M.remainingDependencies === 0) {
      cover.hidden = true;
      canvas.style.visibility = "visible";
    }
  };
  M.monitorRunDependencies = function (left) {
    M.remainingDependencies = left;
    M.totalDependencies = Math.max(M.totalDependencies, left);
    M.setStatus(left ? "Loading" : "");
  };
  M.setStatus("Downloading");

  window.addEventListener("error", function () {
    say("Something went wrong. Reload the page, or download the game.");
    cover.hidden = false;
    M.setStatus = function (text) { if (text) M.printErr("[after error] " + text); };
  });

  function load(src, then) {
    var script = document.createElement("script");
    script.src = src;
    script.async = false;
    if (then) script.addEventListener("load", then);
    document.body.appendChild(script);
  }
  load("/play/game.js");
  load("/play/love.js", function () { window.Love(M); });
})();
