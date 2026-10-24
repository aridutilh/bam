(async () => {
  document.documentElement.dataset.bamExtensionStarted = "injected";
  if (!document.body.dataset.bamFixtureToken) return;
  try {
    const result = await browser.runtime.sendMessage({kind: "fixture", token: document.body.dataset.bamFixtureToken});
    document.documentElement.dataset.bamExtensionResult = JSON.stringify(result);
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
