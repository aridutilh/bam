(async () => {
  try {
    const result = await browser.runtime.sendMessage({kind: "popup"});
    document.getElementById("result").textContent = JSON.stringify(result);
    document.title = "Bam extension page ready";
  } catch (error) { document.title = "Bam extension page failed"; }
})();
