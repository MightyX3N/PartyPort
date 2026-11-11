// PartyPort website: detect the visitor's platform and fill download links
// from the latest GitHub release. With no release yet, everything points to
// the releases page and says so.
(function () {
  "use strict";

  var REPO = "MightyX3N/PartyPort";
  var RELEASES_URL = "https://github.com/" + REPO + "/releases";
  // The list endpoint returns [] (not a 404) while there are no releases.
  var API_URL = "https://api.github.com/repos/" + REPO + "/releases?per_page=10";

  var PLATFORM_NAMES = { windows: "Windows", linux: "Linux", android: "Android" };

  // Which release file goes with which button, matched on the file name.
  var ASSET_PATTERNS = {
    exe: /\.exe$/i,
    winzip: /win.*\.zip$/i,
    appimage: /\.appimage$/i,
    deb: /\.deb$/i,
    apk: /\.apk$/i
  };

  function detectPlatform() {
    var ua = navigator.userAgent || "";
    if (/android/i.test(ua)) return "android";
    if (/windows/i.test(ua)) return "windows";
    if (/linux|x11/i.test(ua) && !/cros/i.test(ua)) return "linux";
    return null;
  }

  function markDetected(platform) {
    if (!platform) return;
    var card = document.querySelector('.dl-card[data-platform="' + platform + '"]');
    if (!card) return;
    card.classList.add("is-detected");
    var badge = card.querySelector(".badge");
    if (badge) badge.hidden = false;
  }

  function setHeroButton(platform, href) {
    var label = document.getElementById("hero-download-label");
    var link = document.getElementById("hero-download");
    if (!label || !link) return;
    label.textContent = platform ? "Download for " + PLATFORM_NAMES[platform] : "Download";
    if (href) link.href = href;
  }

  function findAsset(assets, key) {
    var pattern = ASSET_PATTERNS[key];
    for (var i = 0; i < assets.length; i++) {
      if (pattern.test(assets[i].name)) return assets[i];
    }
    return null;
  }

  function formatSize(bytes) {
    if (!bytes) return "";
    return (bytes / (1024 * 1024)).toFixed(1) + " MB";
  }

  function applyRelease(release, platform) {
    var assets = release.assets || [];
    var info = document.getElementById("release-info");
    var meta = document.getElementById("hero-meta");
    var date = release.published_at ? new Date(release.published_at).toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" }) : "";

    if (info) {
      info.textContent = "";
      info.appendChild(document.createTextNode("Version " + release.tag_name + (date ? " · released " + date + " · " : " · ")));
      var notes = document.createElement("a");
      notes.href = release.html_url || RELEASES_URL;
      notes.textContent = "release notes";
      info.appendChild(notes);
    }
    if (meta) meta.textContent = "Free · Windows, Linux and Android · " + release.tag_name;

    var links = document.querySelectorAll("[data-asset]");
    for (var i = 0; i < links.length; i++) {
      var asset = findAsset(assets, links[i].getAttribute("data-asset"));
      if (asset) {
        links[i].href = asset.browser_download_url;
        if (links[i].classList.contains("dl-main") && asset.size) {
          links[i].title = asset.name + " · " + formatSize(asset.size);
        }
      }
    }

    var heroKey = { windows: "exe", linux: "appimage", android: "apk" }[platform];
    var heroAsset = heroKey ? findAsset(assets, heroKey) : null;
    setHeroButton(platform, heroAsset ? heroAsset.browser_download_url : "#download");
  }

  function showNoRelease() {
    var info = document.getElementById("release-info");
    if (info) {
      info.textContent = "";
      info.appendChild(document.createTextNode("PartyPort is still being built, so there's nothing to download yet. "));
      var link = document.createElement("a");
      link.href = "https://github.com/" + REPO;
      link.textContent = "Follow it on GitHub";
      info.appendChild(link);
      info.appendChild(document.createTextNode(" to hear when the first version is out."));
    }
    var mains = document.querySelectorAll(".dl-main[data-asset]");
    for (var i = 0; i < mains.length; i++) mains[i].textContent = "Coming soon";
    // Hide links to files that don't exist yet, but keep their space so the
    // buttons in every card stay lined up.
    var alts = document.querySelectorAll(".dl-alt[data-asset], [data-needs-release]");
    for (var j = 0; j < alts.length; j++) {
      alts[j].classList.add("is-unavailable");
      alts[j].setAttribute("aria-hidden", "true");
      alts[j].setAttribute("tabindex", "-1");
    }
  }

  var platform = detectPlatform();
  markDetected(platform);
  setHeroButton(platform, "#download");

  if (!window.fetch) { showNoRelease(); return; }

  fetch(API_URL, { headers: { Accept: "application/vnd.github+json" } })
    .then(function (res) {
      if (!res.ok) throw new Error("GitHub API " + res.status);
      return res.json();
    })
    .then(function (releases) {
      // Prefer the newest full release; fall back to the newest pre-release.
      var list = (releases || []).filter(function (r) { return !r.draft; });
      var stable = list.filter(function (r) { return !r.prerelease; });
      var release = stable[0] || list[0] || null;
      if (release && release.tag_name) applyRelease(release, platform);
      else showNoRelease();
    })
    .catch(function () {
      var info = document.getElementById("release-info");
      if (info) {
        info.textContent = "";
        info.appendChild(document.createTextNode("Couldn't check for the latest version. "));
        var link = document.createElement("a");
        link.href = RELEASES_URL;
        link.textContent = "See all releases on GitHub";
        info.appendChild(link);
        info.appendChild(document.createTextNode("."));
      }
    });
})();
