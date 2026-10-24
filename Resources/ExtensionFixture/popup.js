(async () => {
  try {
    const result = await browser.runtime.sendMessage({kind: "popup"});
    document.getElementById("result").textContent = JSON.stringify(result);
    document.title = "Bam fixture ready";
  } catch (error) {
    document.getElementById("result").textContent = String(error);
    document.title = "Bam fixture failed";
  }
})();

document.getElementById("open-page").addEventListener("click", async () => {
  try {
    const tab = await browser.tabs.create({url: browser.runtime.getURL("page.html"), active: true});
    document.getElementById("opened").textContent = String(tab.id);
  } catch (error) { document.getElementById("opened").textContent = "ERROR: " + String(error); }
});
