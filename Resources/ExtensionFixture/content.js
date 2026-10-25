(async () => {
  document.documentElement.dataset.bamExtensionStarted = "injected";
  // Measurement only: whether this isolated content-script world has idle callbacks.
  document.documentElement.dataset.bamContentIdle = typeof requestIdleCallback + "," + typeof cancelIdleCallback;
  if (!document.body.dataset.bamFixtureToken) return;
  try {
    const result = await browser.runtime.sendMessage({kind: "fixture", token: document.body.dataset.bamFixtureToken});
    document.documentElement.dataset.bamExtensionResult = JSON.stringify(result);
    // Callback forms, with and without the extension ID, as vendor content scripts use them.
    chrome.runtime.sendMessage(chrome.runtime.id, {kind: "ping", via: "callback-id"}, (reply) => {
      document.documentElement.dataset.bamExtensionCallbackID = reply?.pong || "missing";
    });
    chrome.runtime.sendMessage({kind: "ping", via: "callback"}, (reply) => {
      document.documentElement.dataset.bamExtensionCallback = reply?.pong || "missing";
    });
    const port = browser.runtime.connect({name: "bam-fixture-port"});
    let received = false;
    port.onMessage.addListener((message) => {
      if (message?.kind !== "handshake") return;
      received = true;
      document.documentElement.dataset.bamExtensionPort = message.token || "missing";
      port.disconnect();
    });
    port.onDisconnect.addListener(() => {
      if (!received) document.documentElement.dataset.bamExtensionPortError = String(browser.runtime.lastError?.message || "Disconnected before receipt");
    });
    port.postMessage({kind: "handshake"});
  } catch (error) {
    document.documentElement.dataset.bamExtensionError = String(error);
  }
})();
