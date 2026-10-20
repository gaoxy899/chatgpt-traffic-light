(() => {
  if (window.__gptTrafficLightAttached) return;
  window.__gptTrafficLightAttached = true;

  const visible = el => !!(el && el.getClientRects().length);
  function getStatus() {
    const stop = [
      'button[data-testid="stop-button"]',
      'button[aria-label="Stop streaming"]',
      'button[aria-label="停止生成"]',
      'button[aria-label="Stop generating"]'
    ];
    if (stop.some(sel => [...document.querySelectorAll(sel)].some(visible))) {
      return 'running';
    }
    // 只有可见的确认/授权弹窗，才亮红灯；避免把普通对话按钮识别成错误。
    const dialogs = [...document.querySelectorAll('[role="alertdialog"], [role="dialog"]')].filter(visible);
    if (dialogs.some(dialog => [...dialog.querySelectorAll('button')].some(b =>
      visible(b) && /^(allow|approve|confirm|authorize|允许|批准|确认|授权)$/i.test((b.innerText || '').trim())
    ))) return 'attention';
    return 'idle';
  }
  function report() {
    try { chrome.runtime.sendMessage({ kind: 'heartbeat', state: getStatus() }, () => void chrome.runtime.lastError); }
    catch (_) { /* extension reloaded */ }
  }
  report();
  setInterval(report, 2000);
  window.addEventListener('pageshow', report);
  document.addEventListener('visibilitychange', report);
})();
