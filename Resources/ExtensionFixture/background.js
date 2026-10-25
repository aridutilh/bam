// Every tab status change the host reports, so a test can require `status: "complete"`.
const bamTabUpdates = [];
browser.tabs.onUpdated.addListener((id, info, tab) => {
  bamTabUpdates.push({id, info, status: tab.status || "", url: tab.url || ""});
  browser.storage.local.set({bamTabUpdates});
});

const menusReady = (async () => {
  await browser.contextMenus.removeAll();
  await new Promise((resolve, reject) => {
    browser.contextMenus.create({id: "bam-fixture-tab-command", title: "Bam fixture tab command", contexts: ["tab"]}, () => {
      const error = browser.runtime.lastError;
      if (error) reject(new Error(error.message)); else resolve();
    });
  });
})();
browser.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === "bam-fixture-tab-command") {
    browser.storage.local.set({lastMenu: {id: info.menuItemId, url: tab?.url || ""}});
  }
});

browser.runtime.onMessage.addListener((message) => {
  if (message?.kind === "ping") return Promise.resolve({pong: message.via});
  if (message?.kind === "updates") return browser.storage.local.get("bamTabUpdates").then(value => ({updates: value.bamTabUpdates || []}));
  if (!message || !["fixture", "popup"].includes(message.kind)) return;
  return (async () => {
    await menusReady;
    let value = await browser.storage.local.get(["token", "visits", "lastMenu"]);
    if (message.kind === "fixture") {
      value = {token: value.token || message.token, visits: (value.visits || 0) + 1};
      await browser.storage.local.set(value);
    }
    const tabs = await browser.tabs.query({});
    return {token: value.token, visits: value.visits, lastMenu: value.lastMenu, urls: tabs.map(tab => tab.url || ""),
      encoding: globalThis["bamCaf\u00e9"] || "absent", nativeMessagingExposed: typeof browser.runtime.sendNativeMessage !== "undefined",
      compat: await (globalThis.bamCompatProbe || "absent")};
  })();
});

// A real persistent port exercises a different engine path from sendMessage.
browser.runtime.onConnect.addListener((port) => {
  if (port.name !== "bam-fixture-port") return;
  port.onMessage.addListener((message) => {
    if (message?.kind !== "handshake") return;
    browser.storage.local.get("token").then(({token}) => {
      port.postMessage({kind: "handshake", token});
    });
  });
});
