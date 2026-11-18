// Bridge between the game (Lua in love.js) and the page: the browser window's size,
// and saving the save folder to IndexedDB (see sync below).
// Lua can't see the browser window, so it prints a request line:
//   SPPPD_WEB|<save dir>|hello     -> the page starts writing <save dir>/viewport.txt
// viewport.txt holds "<width> <height> <phone>" of the browser window in CSS pixels,
// phone being 1 on a touch screen without a mouse; src/web.lua resizes the game's
// window to it, so the game fills the screen and follows rotation on a phone, and a
// phone gets the touch controls and the bigger menus.
// The /play/ page (site/src/pages/play.astro) loads this first, then web/play.js.
(function () {
  var Module = window.Module = window.Module || {};
  var PREFIX = "SPPPD_WEB|";
  var print = Module.print || console.log.bind(console);

  var saveDir = null;

  function writeFile(dir, name, text) {
    var path = dir.replace(/\/+$/, "");
    try { Module.FS_unlink(path + "/" + name); } catch (e) {}
    Module.FS_createPath("/", path.replace(/^\/+/, ""), true, true);
    Module.FS_createDataFile(path, name, text, true, true);
  }

  function sendViewport() {
    var phone = navigator.maxTouchPoints > 0 && window.matchMedia("(pointer: coarse)").matches ? 1 : 0;
    if (saveDir) writeFile(saveDir, "viewport.txt", window.innerWidth + " " + window.innerHeight + " " + phone + "\n");
  }
  window.addEventListener("resize", sendViewport);
  window.addEventListener("orientationchange", function () { setTimeout(sendViewport, 300); });

  // Browsers may deliver a press before the pointer move that led to it (moves are batched per
  // frame), and SDL takes a press's position from the last move. Replaying the move first keeps
  // taps and clicks on the menu rows where they were aimed.
  ["mousedown", "mouseup"].forEach(function (type) {
    window.addEventListener(type, function (e) {
      if (!e.isTrusted || !e.target || e.target.id !== "canvas") return;
      e.target.dispatchEvent(new MouseEvent("mousemove", {
        bubbles: true, clientX: e.clientX, clientY: e.clientY, screenX: e.screenX, screenY: e.screenY,
      }));
    }, true);
  });

  // Keys the game uses that the browser would otherwise take: scrolling, Tab focus, quick find.
  window.addEventListener("keydown", function (e) {
    if ([" ", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Tab", "/", "'"].indexOf(e.key) >= 0) {
      e.preventDefault();
    }
  }, { passive: false });

  // Don't wait for Lua's hello: have the size in the save folder before the first frame.
  Module.preRun = (Module.preRun || []).concat([function () {
    saveDir = "/home/web_user/love/spppd";
    try { sendViewport(); } catch (e) { saveDir = null; }
  }]);

  // love.js copies the save folder into IndexedDB only as the page unloads, and
  // doesn't wait for it to finish. The game asks after it writes (src/web.lua), and
  // the page copies it whenever it's hidden, which a phone does before killing a tab.
  // bin/web-build exports FS.syncfs as Module.FS_syncfs.
  var syncing = false, again = false;
  function sync() {
    if (!Module.FS_syncfs) return;
    if (syncing) { again = true; return; }
    syncing = true;
    Module.FS_syncfs(false, function (err) {
      if (err) console.error("saving to IndexedDB failed", err);
      syncing = false;
      if (again) { again = false; sync(); }
    });
  }
  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "hidden") sync();
  });
  window.addEventListener("pagehide", sync);

  Module.print = function (line) {
    if (typeof line === "string" && line.indexOf(PREFIX) === 0) {
      var parts = line.split("|");
      if (parts[2] === "hello") {
        saveDir = parts[1];
        sendViewport();
      } else if (parts[2] === "sync") {
        sync();
      }
    } else {
      print(line);
    }
  };
})();
