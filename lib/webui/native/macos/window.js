// Injected only into the helper's main frame. Preserve the renderer's existing
// browser geometry API, backed by actual host measurements and operations.
(() => {
  'use strict';
  if (window.top && window.top !== window) return;
  /** Sends a window-operation payload to the host, which validates frame origin and values. */
  const send = message => window.webkit.messageHandlers.lichWindow.postMessage(message);
  let geometry = {};
  window.lichNativeWindow = {
    /** Replaces measured outer bounds and notifies the renderer's geometry observer. */
    update(next) { geometry = next; window.dispatchEvent(new Event('resize')); },
    /** Requests native title, level, alpha and minimum sizing for the root page. */
    present(props) { send({ action: 'present', ...props }); }
  };
  for (const key of ['outerWidth', 'outerHeight', 'screenX', 'screenY']) {
    Object.defineProperty(window, key, { configurable: true, get: () => geometry[key] ?? 0 });
  }
  /** Requests outer dimensions; the host preserves the window's top edge. */
  window.resizeTo = (width, height) => send({ action: 'resize', width, height });
  /** Requests a browser-coordinate top-left position in desktop points. */
  window.moveTo = (x, y) => send({ action: 'move', x, y });
  /** Closes this helper's window, allowing Ruby's owned-process monitor to observe exit. */
  window.close = () => send({ action: 'close' });
})();
