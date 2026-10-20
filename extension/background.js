const KEY = '__TOKEN__';
const ENDPOINT = 'http://127.0.0.1:18765/status';
const tabs = new Map();
let inFlight = false;

function aggregate() {
  const now = Date.now();
  for (const [id, info] of tabs) if (now - info.at > 9000) tabs.delete(id);
  const states = [...tabs.values()].map(v => v.state);
  if (states.includes('attention')) return {state:'attention', detail:'ChatGPT：等待确认 / 授权'};
  if (states.includes('running')) return {state:'running', detail:'ChatGPT：正在生成回答'};
  return {state:'idle', detail:'ChatGPT：空闲 / 回答完成'};
}
async function sync() {
  if (inFlight) return;
  inFlight = true;
  try {
    await fetch(ENDPOINT, {
      method: 'POST', headers: {'Content-Type':'application/json', 'X-Status-Key':KEY},
      body: JSON.stringify(aggregate()), signal: AbortSignal.timeout(1500)
    });
  } catch (_) { /* native app not yet open */ }
  finally { inFlight = false; }
}
chrome.runtime.onMessage.addListener((message, sender) => {
  if (message?.kind !== 'heartbeat' || !sender.tab?.id) return;
  if (!['idle', 'running', 'attention'].includes(message.state)) return;
  tabs.set(sender.tab.id, {state:message.state, at:Date.now()});
  sync();
});
chrome.tabs?.onRemoved?.addListener(id => { tabs.delete(id); sync(); });
