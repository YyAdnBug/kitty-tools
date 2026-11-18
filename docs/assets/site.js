// Kitty Tools 官网的公共脚本：下载按钮、版本信息、按访客系统换按钮、更新日志。
// 数据都在浏览器里现读 GitHub（不用密钥，每个 IP 每小时 60 次，读到的存 10 分钟），所以发版后官网不用改。
// Mac 取版本号最大的 macos-v*（DMG），Windows 取最大的 windows-v*（Windows 的 release 故意不标 latest，
// 不能用 releases/latest）。读不到时什么都不改：按钮本来就链着 GitHub 的发布页。
(function () {
  "use strict";
  var REPO = "YyAdnBug/kitty-tools";
  // 英文页（docs/en/）：<html lang="en">。页面里的字都写在 HTML 里，这里只有脚本自己填的几句
  var EN = document.documentElement.lang.indexOf("en") === 0;
  var API = "https://api.github.com/repos/" + REPO;
  var TTL = 10 * 60 * 1000;

  function cached(key, load) {
    try {
      var hit = JSON.parse(localStorage.getItem(key) || "null");
      if (hit && Date.now() - hit.at < TTL) return Promise.resolve(hit.data);
    } catch (e) {}
    return load().then(function (data) {
      try {
        localStorage.setItem(key, JSON.stringify({ at: Date.now(), data: data }));
      } catch (e) {}
      return data;
    });
  }

  function getJSON(url, raw) {
    var headers = { Accept: raw ? "application/vnd.github.raw+json" : "application/vnd.github+json" };
    return fetch(url, { headers: headers }).then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    });
  }

  // "0.7.1" → [0, 7, 1]，按段比大小
  function parts(v) {
    return v.split(".").map(function (n) {
      return parseInt(n, 10) || 0;
    });
  }
  function newer(a, b) {
    var x = parts(a), y = parts(b);
    for (var i = 0; i < Math.max(x.length, y.length); i++) {
      if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0);
    }
    return false;
  }

  function releases() {
    return cached("kt-releases", function () {
      return getJSON(API + "/releases?per_page=40").then(function (list) {
        // 只留要用的字段，存得小一点
        return list
          .filter(function (r) {
            return !r.draft && !r.prerelease;
          })
          .map(function (r) {
            return {
              tag: r.tag_name,
              url: r.html_url,
              date: r.published_at,
              assets: r.assets.map(function (a) {
                return { name: a.name, url: a.browser_download_url, size: a.size };
              }),
            };
          });
      });
    });
  }

  function latest(list, prefix) {
    var best = null;
    list.forEach(function (r) {
      if (r.tag.indexOf(prefix) !== 0) return;
      r.version = r.tag.slice(prefix.length);
      if (!best || newer(r.version, best.version)) best = r;
    });
    return best;
  }

  function find(release, pattern) {
    if (!release) return null;
    for (var i = 0; i < release.assets.length; i++) {
      if (pattern.test(release.assets[i].name)) return release.assets[i];
    }
    return null;
  }

  // 和访达、发布说明一样按 1000 进位
  function mb(bytes) {
    return (bytes / 1e6).toFixed(1) + " MB";
  }
  function day(iso) {
    var d = new Date(iso);
    return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0");
  }

  // 访客的系统：Mac、Windows、手机（含 iPad）、其他（Linux 等）
  var ua = navigator.userAgent;
  var mobile = /iPhone|iPad|iPod|Android/i.test(ua) || (navigator.maxTouchPoints > 1 && /Macintosh/.test(ua));
  var os = mobile ? "phone" : /Windows/i.test(ua) ? "windows" : /Macintosh|Mac OS X/i.test(ua) ? "mac" : "other";
  document.documentElement.dataset.os = os;

  // Windows 的 ARM 电脑：Edge / Chrome 能告诉我们，别的浏览器认不出就给 x64
  var armWindows =
    os === "windows" && navigator.userAgentData && navigator.userAgentData.getHighEntropyValues
      ? navigator.userAgentData
          .getHighEntropyValues(["architecture"])
          .then(function (v) {
            return v.architecture === "arm";
          })
          .catch(function () {
            return false;
          })
      : Promise.resolve(false);

  // 主按钮按访客系统换：data-auto 的按钮在 Windows 上变成「下载 Windows 版」
  if (os === "windows") {
    document.querySelectorAll("[data-auto]").forEach(function (a) {
      a.dataset.dl = "win";
      a.href = "https://github.com/YyAdnBug/kitty-tools/releases?q=windows&expanded=true";
      var label = a.querySelector("[data-label]");
      if (label) label.textContent = EN ? "Download for Windows" : "下载 Windows 版";
    });
    document.querySelectorAll("[data-auto-meta]").forEach(function (el) {
      el.hidden = true;
    });
    document.querySelectorAll("[data-auto-meta-win]").forEach(function (el) {
      el.hidden = false;
    });
  }

  function fill(name, text) {
    document.querySelectorAll('[data-fill="' + name + '"]').forEach(function (el) {
      el.textContent = text;
    });
  }

  // 点了 Mac 的下载：在按钮下面提醒第一次打开会被拦、该去哪放行
  document.addEventListener("click", function (e) {
    var a = e.target.closest && e.target.closest("[data-dl]");
    if (!a || !a.dataset.ready) return;
    var note = document.getElementById(a.getAttribute("aria-describedby") || "");
    if (note) note.hidden = false;
  });

  // 「拷贝」按钮：拷贝 data-copy 指向的那段文字
  document.addEventListener("click", function (e) {
    var button = e.target.closest && e.target.closest("[data-copy]");
    if (!button) return;
    var text = document.getElementById(button.dataset.copy).textContent;
    var done = function () {
      button.textContent = EN ? "Copied" : "已拷贝";
      setTimeout(function () {
        button.textContent = EN ? "Copy" : "拷贝";
      }, 1600);
    };
    if (navigator.clipboard) navigator.clipboard.writeText(text).then(done, function () {});
  });

  var needsReleases = document.querySelector("[data-dl], [data-fill]");
  if (needsReleases) {
    Promise.all([releases(), armWindows])
      .then(function (got) {
        var list = got[0], arm = got[1];
        var mac = latest(list, "macos-v"), win = latest(list, "windows-v");
        var dmg = find(mac, /_arm64\.dmg$/), intel = find(mac, /_x86_64\.dmg$/);
        var x64 = find(win, /-windows-x64-setup\.exe$/), arm64 = find(win, /-windows-arm64-setup\.exe$/);
        var x64zip = find(win, /-windows-x64\.zip$/), arm64zip = find(win, /-windows-arm64\.zip$/);
        var links = {
          mac: dmg,
          "mac-intel": intel,
          win: arm ? arm64 || x64 : x64 || arm64,
          "win-x64": x64,
          "win-arm64": arm64,
          "win-x64-zip": x64zip,
          "win-arm64-zip": arm64zip,
        };
        document.querySelectorAll("[data-dl]").forEach(function (a) {
          var asset = links[a.dataset.dl];
          if (!asset) return;
          a.href = asset.url;
          a.dataset.ready = "1";
        });
        if (mac) {
          document.querySelectorAll('[data-needs="mac"]').forEach(function (el) {
            el.hidden = false;
          });
          fill("mac-version", mac.version);
          fill("mac-date", day(mac.date));
          if (dmg) fill("mac-size", mb(dmg.size));
          fill("mac-file", dmg ? dmg.name : "");
          document.querySelectorAll('[data-href="mac-release"]').forEach(function (a) {
            a.href = mac.url;
          });
        }
        if (win) {
          document.querySelectorAll('[data-needs="win"]').forEach(function (el) {
            el.hidden = false;
          });
          fill("win-version", win.version);
          fill("win-date", day(win.date));
          if (x64) fill("win-size", mb(x64.size));
          if (arm) fill("win-arch", "ARM64");
          document.querySelectorAll('[data-href="win-release"]').forEach(function (a) {
            a.href = win.url;
          });
        }
        document.documentElement.dataset.releases = "ok";
      })
      .catch(function () {
        document.documentElement.dataset.releases = "failed";
      });
  }

  // ---------- 更新日志 ----------

  var log = document.getElementById("changelog");
  if (log) changelog(log);

  function changelog(root) {
    // 读最新那个发版 tag 上的 changelog.json（2026-11-07：0.7.3 从发布分支打的 tag，macos 分支上的日志还没搬回来，
    // 首页显示 0.7.3、这里还停在 0.7.2）。tag 上的就是发出去的那一版，分支上可能还没搬回来、也可能有还没发的版本；
    // 发布列表读不到时退回分支
    var SOURCES = {
      mac: { path: "macos/KittyTools/Resources/changelog.json", prefix: "macos-v", branch: "macos" },
      windows: { path: "windows/KittyTools/Resources/changelog.json", prefix: "windows-v", branch: "windows" },
    };
    function ref(platform) {
      var source = SOURCES[platform];
      return releases().then(
        function (list) {
          var release = latest(list, source.prefix);
          return release ? release.tag : source.branch;
        },
        function () {
          return source.branch;
        }
      );
    }
    var TYPES = [
      ["feat", EN ? "New" : "新功能"],
      ["ui", EN ? "UI" : "界面"],
      ["perf", EN ? "Performance" : "性能"],
      ["fix", EN ? "Fixes" : "修复"],
    ];
    // 英文页：Mac 的日志每版有 summaryEn、每条有 textEn（缺了退回中文）；功能名（scope）的英文在 App 的
    // Localizable.xcstrings 里，不在 changelog.json，这里抄一份（新加功能名时补一行，没有的照原样显示）。
    // Windows 的日志还没有英文，照旧显示中文
    var SCOPES = {
      截图: "Screenshot", 翻译: "Translate", 启动器: "Launcher", 剪贴板: "Clipboard", 便签: "Notes",
      全局: "Global", 启动台: "Launchpad", 设置: "Settings", 录屏: "Record Screen", 刘海岛: "Notch",
      通用: "General", 访达右键: "Finder Menu", 同步: "Sync", 状态屏: "Status Screen", 程序坞预览: "Dock Preview",
      提醒: "Reminders", 快捷键: "Shortcuts", 录音: "Record Audio", 主界面: "Home", 更新: "Update",
      外观: "Appearance", 隐私: "Privacy", 插件: "Plugins", 长截图: "Scrolling Capture", 界面: "UI",
      截图与录制: "Screenshot & Recording",
    };
    function english(zh, en) {
      return EN && en ? en : zh;
    }
    var tabs = root.querySelectorAll("[role=tab]");
    var loaded = {};

    function el(tag, cls, text) {
      var node = document.createElement(tag);
      if (cls) node.className = cls;
      if (text != null) node.textContent = text;
      return node;
    }

    // 两个平台的格式不一样：Mac 是数组、条目有 scope；Windows 是 { entries: [{ items }] }
    function normalize(data) {
      var list = Array.isArray(data) ? data : data.entries || [];
      return list.map(function (v) {
        return {
          version: v.version,
          date: v.date,
          summary: v.summary,
          summaryEn: v.summaryEn,
          changes: v.changes || v.items || [],
        };
      });
    }

    function render(platform, versions) {
      var panel = document.getElementById("log-" + platform);
      panel.textContent = "";
      if (EN && platform === "windows") panel.appendChild(el("p", "small muted", "The Windows release notes are in Chinese for now."));
      versions.forEach(function (v, index) {
        var box = el("details", "release");
        box.id = platform + "-v" + v.version;
        if (index === 0 || location.hash === "#" + box.id) box.open = true;
        var head = el("summary");
        var title = el("span", "release-title");
        title.appendChild(el("b", null, v.version));
        if (index === 0) title.appendChild(el("span", "badge", EN ? "Latest" : "最新"));
        head.appendChild(title);
        head.appendChild(el("time", "release-date", v.date));
        box.appendChild(head);
        var body = el("div", "release-body");
        var summary = english(v.summary, v.summaryEn);
        if (summary) body.appendChild(el("p", "release-summary", summary));
        TYPES.forEach(function (t) {
          var items = v.changes.filter(function (c) {
            return c.type === t[0];
          });
          if (!items.length) return;
          var group = el("section", "change-group");
          group.appendChild(el("h3", "type-" + t[0], t[1] + " " + items.length));
          var ul = el("ul");
          items.forEach(function (c) {
            var li = el("li");
            if (c.scope) li.appendChild(el("span", "scope", english(c.scope, SCOPES[c.scope])));
            li.appendChild(document.createTextNode(english(c.text, c.textEn)));
            ul.appendChild(li);
          });
          group.appendChild(ul);
          body.appendChild(group);
        });
        box.appendChild(body);
        panel.appendChild(box);
      });
      if (location.hash.indexOf("#" + platform + "-v") === 0) {
        var target = document.getElementById(location.hash.slice(1));
        if (target) target.scrollIntoView();
      }
    }

    function show(platform) {
      tabs.forEach(function (tab) {
        var on = tab.dataset.platform === platform;
        tab.setAttribute("aria-selected", on ? "true" : "false");
        tab.tabIndex = on ? 0 : -1;
        document.getElementById("log-" + tab.dataset.platform).hidden = !on;
      });
      if (loaded[platform]) return;
      loaded[platform] = true;
      ref(platform)
        .then(function (at) {
          // 按 tag 记缓存：发了新版就换一个键，不会拿着旧版的日志等 10 分钟
          // kt-log2：2026-11 起缓存里多了 summaryEn，换个键，免得英文页拿到旧格式的缓存
          return cached("kt-log2-" + platform + "@" + at, function () {
            var url = API + "/contents/" + SOURCES[platform].path + "?ref=" + encodeURIComponent(at);
            return getJSON(url, true).then(normalize);
          });
        })
        .then(function (versions) {
          render(platform, versions);
        })
        .catch(function () {
          loaded[platform] = false;
          document.getElementById("log-" + platform).querySelector(".log-status").textContent = EN
            ? "Couldn’t load the release notes (a network problem, or GitHub is limiting requests). Try refreshing later, or see the GitHub releases page."
            : "暂时读不到更新日志（可能是网络问题，或者 GitHub 限制了访问次数）。可以稍后刷新，或者去 GitHub 的发布页看。";
        });
    }

    tabs.forEach(function (tab, i) {
      tab.addEventListener("click", function () {
        show(tab.dataset.platform);
        history.replaceState(null, "", "#" + tab.dataset.platform);
      });
      tab.addEventListener("keydown", function (e) {
        if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
        var next = tabs[(i + (e.key === "ArrowRight" ? 1 : tabs.length - 1)) % tabs.length];
        next.focus();
        next.click();
      });
    });

    var start = /^#windows/.test(location.hash) ? "windows" : /^#mac/.test(location.hash) ? "mac" : os === "windows" ? "windows" : "mac";
    show(start);
  }
})();
