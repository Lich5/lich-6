// Injected only into the helper's main frame. Preserve the renderer's existing
// browser geometry API, backed by actual host measurements and operations.
(() => {
  'use strict';
  if (window.top && window.top !== window) return;
  const send = message => window.webkit.messageHandlers.lichWindow.postMessage(message);
  let geometry = {};
  window.lichNativeWindow = {
    update(next) { geometry = next; window.dispatchEvent(new Event('resize')); },
    present(props) { send({ action: 'present', ...props }); }
  };
  for (const key of ['outerWidth', 'outerHeight', 'screenX', 'screenY']) {
    Object.defineProperty(window, key, { configurable: true, get: () => geometry[key] ?? 0 });
  }
  window.resizeTo = (width, height) => send({ action: 'resize', width, height });
  window.moveTo = (x, y) => send({ action: 'move', x, y });
  window.close = () => send({ action: 'close' });
})();
