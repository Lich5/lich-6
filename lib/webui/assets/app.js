(() => {
  "use strict";

  const VERSION = "2.49.0";
  const pagesNode = document.getElementById("pages");
  const statusNode = document.getElementById("status");
  const notifications = document.getElementById("notifications");
  const announcer = document.getElementById("announcer");
  const pages = new Map();
  // Script app windows share the service, not its entire page catalog. Dialogs
  // advertise their eligible parent pages using server-owned opaque addresses.
  const requestedPage = new URLSearchParams(window.location.search).get("page");
  let socket;
  let reconnectDelay = 250;
  let nextRequest = 0;
  const pending = new Map();

  // Retain only bounded, short-lived intent snapshots for a single stale-tree
  // retry. Correlation numbers carry no server routing authority.
  function dropPending(request) {
    window.clearTimeout(pending.get(request)?.timer);
    pending.delete(request);
  }

  /** Drops matching retry records and their timers, including secret-bearing submissions. */
  function discardPending(predicate) {
    for (const [request, record] of pending) if (predicate(record)) dropPending(request);
  }

  /** Finds a stable identity in the accepted tree; absent controls cannot receive a retry. */
  function findComponent(component, cid) {
    if (component.cid === cid) return component;
    for (const child of component.children || []) {
      const found = findComponent(child, cid);
      if (found) return found;
    }
  }

  /**
   * Serializes host measurements using content or outer-frame dimensions explicitly.
   * @param {boolean} content Whether dimensions describe the client area.
   * @returns {string} JSON dimensions and desktop position.
   */
  function windowGeometry(content) {
    return JSON.stringify({
      width: content ? window.innerWidth : window.outerWidth,
      height: content ? window.innerHeight : window.outerHeight,
      position: [window.screenX, window.screenY]
    });
  }

  /** Removes the previous render's timer and resize listener before replacement or closure. */
  function stopWindowGeometry(page) {
    window.clearInterval(page.geometryTimer);
    if (page.reportGeometry) window.removeEventListener("resize", page.reportGeometry);
    page.reportGeometry = null;
  }

  /** Retires native state observation with its owning rendered page. */
  function stopWindowState(page) {
    if (page.reportWindowState) window.removeEventListener("lich-window-state", page.reportWindowState);
    page.reportWindowState = null;
  }

  /** Reports measured native minimize/restore transitions, independently of page visibility. */
  function trackWindowState(page, component) {
    stopWindowState(page);
    if (requestedPage && page.address !== requestedPage) return;
    if (!bound(page, component.cid, "window_state") || !window.lichNativeWindow) return;
    page.reportWindowState = () => {
      const minimized = window.lichNativeWindow.minimized;
      if (typeof minimized !== "boolean" || minimized === page.lastWindowMinimized) return;
      page.lastWindowMinimized = minimized;
      emit(page, component, "window_state", { minimized });
    };
    window.addEventListener("lich-window-state", page.reportWindowState);
    page.reportWindowState();
  }

  // Native windows may preserve either outer size (launcher) or content size
  // (fixed artwork). Meter renders must not reset the last observed geometry.
  function trackWindowGeometry(page, component, content) {
    stopWindowGeometry(page);
    if (!content) page.geometryRestored = true; // Launcher launch flags already describe its outer frame.
    if (content && !page.geometryRestored) {
      page.geometryRestored = true;
      try {
        const saved = JSON.parse(component.props.value);
        if ([saved.width, saved.height].every(n => Number.isInteger(n) && n > 0 && n <= 65536)) {
          window.resizeTo(saved.width + window.outerWidth - window.innerWidth,
            saved.height + window.outerHeight - window.innerHeight);
        }
      } catch (_) { /* Missing or invalid hints leave the browser's size intact. */ }
    }
    page.reportGeometry = () => {
      const current = windowGeometry(content);
      if (current === page.lastGeometry) return;
      page.lastGeometry = current;
      emit(page, component, "change", { value: current });
    };
    window.addEventListener("resize", page.reportGeometry);
    page.geometryTimer = window.setInterval(page.reportGeometry, 500);
  }

  // One geometry reporter per host window. Keep legacy hidden geometry fields
  // working while every page also reports typed measurements to core. Only the
  // requested root owns desktop geometry; an in-window dialog cannot resize it.
  function naturalPageSize(element, requestedWidth) {
    const previous = { width: element.style.width, height: element.style.height, minHeight: element.style.minHeight };
    try {
      // A viewport-sized allocation is not the contents' minimum. Collapse
      // only the root while measuring; child requests and overflow still count.
      element.style.width = "0px";
      element.style.height = "0px";
      element.style.minHeight = "0px";
      const width = element.scrollWidth;
      // Wrapped content's height depends on its allocated width. Measure it
      // at the requested width after deriving the independent width minimum.
      element.style.width = `${Math.max(width, requestedWidth)}px`;
      return { width, height: element.scrollHeight };
    } finally {
      Object.assign(element.style, previous);
    }
  }

  /** Reports typed root geometry and applies each explicit resize request only once. */
  function trackPageGeometry(page, component) {
    if (requestedPage && page.address !== requestedPage) return;
    const reportsGeometry = bound(page, component.cid, "configure");
    // Minima govern the host even when the script does not subscribe to geometry.
    if (!reportsGeometry && !Number.isFinite(component.props.min_width) && !Number.isFinite(component.props.min_height)) return;
    const legacyReport = page.reportGeometry;
    stopWindowGeometry(page);
    page.reportGeometry = (event) => {
      // Launch dimensions are not minima. An explicitly unscrolled table
      // also retains its contents' requisition, as a naked GTK TreeView does.
      if (event?.type === "resize") {
        const natural = page.unscrolledTableMinimum ? naturalPageSize(page.element,
          Math.max(window.innerWidth, component.props.min_width || 0)) : { width: 0, height: 0 };
        const width = Math.max(window.innerWidth, component.props.min_width || 0, natural.width);
        const height = Math.max(window.innerHeight, component.props.min_height || 0, natural.height);
        const attempt = `${window.innerWidth},${window.innerHeight}->${width},${height}`;
        if (width !== window.innerWidth || height !== window.innerHeight) {
          if (page.minimumResizeAttempt !== attempt) {
            page.minimumResizeAttempt = attempt;
            window.resizeTo(width + window.outerWidth - window.innerWidth,
              height + window.outerHeight - window.innerHeight);
          }
        } else page.minimumResizeAttempt = null;
      }
      legacyReport?.();
      if (!reportsGeometry) return;
      const payload = { width: Math.round(window.innerWidth), height: Math.round(window.innerHeight),
        position: [Math.round(window.screenX), Math.round(window.screenY)] };
      const nativeMonitors = window.lichNativeWindow?.monitors;
      const screen = window.screen;
      payload.monitors = nativeMonitors || (screen?.width > 0 && screen?.height > 0 ? {
        source: "browser", screens: [{ x: Math.round(screen.left ?? screen.availLeft ?? 0),
          y: Math.round(screen.top ?? screen.availTop ?? 0), width: Math.round(screen.width), height: Math.round(screen.height),
          primary: false, active: true }]
      } : { source: "unavailable", screens: [] });
      const signature = JSON.stringify(payload);
      if (signature === page.lastPageGeometry) return;
      page.lastPageGeometry = signature;
      emit(page, component, "configure", payload);
    };
    window.addEventListener("resize", page.reportGeometry);
    page.geometryTimer = window.setInterval(page.reportGeometry, 250);
    window.requestAnimationFrame(() => {
      if (!page.element?.isConnected) return;
      let requestedResize = false;
      if (!page.geometryRestored) {
        const size = component.props.size;
        const position = component.props.position;
        // GTK requested dimensions refer to the client area. Chrome's launch
        // flags use the outer frame, so add the measured decoration once.
        if (size?.[0] > 0 && size?.[1] > 0) {
          const natural = naturalPageSize(page.element, Math.max(size[0], component.props.min_width || 0));
          const height = Math.max(size[1], component.props.min_height || 0, natural.height);
          window.resizeTo(Math.max(size[0], component.props.min_width || 0, natural.width) + window.outerWidth - window.innerWidth,
            height + window.outerHeight - window.innerHeight);
          requestedResize = true;
        }
        if (position?.length === 2) window.moveTo?.(...position);
        page.geometryRestored = true;
      }
      // A script may explicitly request another resize. The id distinguishes
      // that action from an ordinary meter render and from replayed renders.
      const request = component.props.resize_request;
      if (request && request.id !== page.lastResizeRequest) {
        page.lastResizeRequest = request.id;
        const natural = naturalPageSize(page.element, Math.max(request.size[0], component.props.min_width || 0));
        const width = Math.max(request.size[0], component.props.min_width || 0, natural.width);
        const height = Math.max(request.size[1], component.props.min_height || 0, natural.height);
        window.resizeTo(width + window.outerWidth - window.innerWidth,
          height + window.outerHeight - window.innerHeight);
        requestedResize = true;
      }
      // Enforce partial or changed minima on first display and every render,
      // retaining the other axis and larger user geometry. An explicit request
      // already clamps both minima; do not compete with that asynchronous resize
      // using the old host measurements. Repeated host refusals are deduplicated.
      page.reportGeometry?.(requestedResize ? undefined : { type: "resize" });
    });
  }

  /** Creates a DOM node with literal textContent; supplied text is never parsed as HTML. */
  function node(tag, className, text) {
    const result = document.createElement(tag);
    if (className) result.className = className;
    if (text !== undefined) result.textContent = String(text);
    return result;
  }

  /** Applies validated common properties; it does not accept arbitrary CSS or HTML source. */
  function common(element, component) {
    const props = component.props || {};
    if (component.type === "button") nativeTextStyle(element, props);
    element.dataset.cid = component.cid;
    element.dataset.componentType = component.type;
    if (props.width_groups?.length) element.dataset.widthGroups = props.width_groups.join(" ");
    element.hidden = props.hidden === true;
    if (["stack", "button", "text"].includes(component.type)) element.style.opacity = props.opacity ?? "";
    if ("disabled" in element) element.disabled = props.disabled === true;
    if (props.disabled) element.inert = true;
    if (props.tooltip) element.title = props.tooltip;
    if (props.cursor_hint) {
      element.dataset.cursorHint = props.cursor_hint;
      element.style.setProperty("--webui-cursor-hint", props.cursor_hint);
    } else {
      delete element.dataset.cursorHint;
      element.style.removeProperty("--webui-cursor-hint");
    }
    if (props.a11y_label) element.setAttribute("aria-label", props.a11y_label);
    if (props.a11y_description) element.setAttribute("aria-description", props.a11y_description);
    if (props.a11y_role) element.setAttribute("role", props.a11y_role);
    ["align", "emphasis", "tone"].forEach((name) => {
      if (props[name]) element.classList.add(`${name}-${props[name]}`);
    });
    if (component.type === "button" && ["start", "center", "end"].includes(props.align)) {
      element.style.alignSelf = props.align === "center" ? "center" : `flex-${props.align}`;
      element.style.justifySelf = props.align;
    }
    if (Number.isFinite(props.margin)) element.style.margin = `${props.margin}px`;
    else if (props.margin) for (const side of ["top", "right", "bottom", "left"]) {
      element.style[`margin${side[0].toUpperCase()}${side.slice(1)}`] = `${props.margin[side] || 0}px`;
    }
    if (Number.isFinite(props.width) && props.width >= 0) element.style.width = `${props.width}px`;
    if (Number.isFinite(props.min_width)) element.style.minWidth = `${props.min_width}px`;
    if (component.type === "button" && props.width === undefined && Number.isFinite(props.min_width) &&
        ["start", "center", "end"].includes(props.align)) element.style.width = "max-content";
    if (Number.isFinite(props.height) && props.height >= 0) element.style.height = `${props.height}px`;
    if (Number.isFinite(props.min_height) && props.min_height >= 0) element.style.minHeight = `${props.min_height}px`;
    if (Number.isFinite(props.max_height) && props.max_height >= 0) element.style.maxHeight = `${props.max_height}px`;
    if (props.fill && ["stack", "columns", "table", "split", "group"].includes(component.type)) {
      element.style.flex = "1"; element.style.minHeight = `${props.min_height || 0}px`; element.style.height = "0px";
    }
    return element;
  }

  /** Equalizes page-local width requests, including overlapping horizontal groups. */
  function equalizeWidthGroups(page) {
    const root = page.element;
    const members = [...root.querySelectorAll("[data-width-groups]")];
    if (!members.length) return;
    const authored = new Map(members.map(element => [element, {
      width: element.style.width, minimum: element.style.minWidth
    }]));
    let scheduled = false;
    const measure = () => {
      scheduled = false;
      if (!root.isConnected || page.element !== root) return;
      // Measure all intrinsic requests in one layout pass, without touching live inputs.
      const fragment = document.createDocumentFragment();
      const probes = members.map(element => {
        const clone = element.cloneNode(true), base = authored.get(element);
        clone.hidden = false;
        clone.setAttribute("aria-hidden", "true");
        clone.style.position = "absolute";
        clone.style.visibility = "hidden";
        clone.style.width = "max-content";
        clone.style.maxWidth = "none";
        clone.style.minWidth = base.minimum;
        if (/^\d+(?:\.\d+)?px$/.test(base.width)) {
          clone.style.minWidth = base.minimum ? `max(${base.minimum}, ${base.width})` : base.width;
        }
        // A cloned checked radio must never join and deselect its live group.
        for (const node of [clone, ...clone.querySelectorAll("[id],input[name]")]) {
          node.removeAttribute("id");
          if (node.tagName === "INPUT") node.removeAttribute("name");
        }
        fragment.append(clone);
        return clone;
      });
      root.append(fragment);
      const widths = probes.map(probe => Math.min(65_536, Math.ceil(probe.getBoundingClientRect().width)));
      probes.forEach(probe => probe.remove());
      const parents = new Map();
      const find = key => {
        if (!parents.has(key)) parents.set(key, key);
        let root = key;
        while (parents.get(root) !== root) root = parents.get(root);
        while (key !== root) { const next = parents.get(key); parents.set(key, root); key = next; }
        return root;
      };
      const groups = members.map(element => element.dataset.widthGroups.split(" "));
      groups.forEach(keys => keys.slice(1).forEach(key => parents.set(find(key), find(keys[0]))));
      const maxima = new Map();
      groups.forEach((keys, index) => {
        const key = find(keys[0]);
        maxima.set(key, Math.max(maxima.get(key) || 0, widths[index]));
      });
      members.forEach((element, index) => {
        const width = maxima.get(find(groups[index][0]));
        const base = authored.get(element).minimum;
        element.style.minWidth = width > 0 ? (base ? `max(${base}, ${width}px)` : `${width}px`) : base;
      });
    };
    const schedule = () => {
      if (!scheduled) { scheduled = true; window.requestAnimationFrame(measure); }
    };
    schedule();
    if (window.ResizeObserver) {
      const observer = new window.ResizeObserver(schedule);
      observer.observe(root);
      (page.layoutObservers ||= []).push(observer);
    }
    document.fonts?.ready.then(schedule);
  }

  /** Checks the delivered event allowlist before sending a control interaction. */
  function bound(page, cid, event) {
    return (page.bindings[cid] || []).includes(event);
  }

  /**
   * Extracts the wire value rather than presentation text (notably editable-select labels).
   * @returns {*} Current scalar value, or null when the control is absent.
   */
  function controlValue(control) {
    if (!control) return null;
    if (control.choiceValue) return control.choiceValue();
    if (control.type === "checkbox") return control.checked;
    if (control.type === "number" || control.type === "range") return control.valueAsNumber;
    return control.value;
  }

  /** Retires unsent wheel movement when its attachment closes or disconnects. */
  function clearWheel(page) {
    if (page.wheelFrame != null) window.cancelAnimationFrame(page.wheelFrame);
    page.wheelFrame = null;
    page.wheelBatches = [];
  }

  /** Sends ordered, bounded chunks against the current tree, never an old DOM closure. */
  function flushWheel(page) {
    const batches = page.wheelBatches || [];
    clearWheel(page);
    for (const batch of batches) {
      const component = page.tree && findComponent(page.tree, batch.cid);
      const element = page.element && [page.element, ...page.element.querySelectorAll("[data-cid]")].find(node => node.dataset.cid === batch.cid);
      if (!component || !element || !bound(page, batch.cid, "scroll") || component.props.disabled ||
          element.closest("[hidden],[inert]")) continue;
      let { x, y } = batch;
      while (x || y) {
        const scale = Math.min(1, 65536 / Math.max(Math.abs(x), Math.abs(y)));
        const dx = Math.round(x * scale), dy = Math.round(y * scale);
        emit(page, component, "scroll", { delta_x: dx, delta_y: dy, state: batch.state });
        x -= dx; y -= dy;
      }
    }
  }

  /** Coalesces only compatible wheel movement; modifier/direction transitions retain order. */
  function queueWheel(page, component, x, y, state) {
    if (!Number.isFinite(x) || !Number.isFinite(y) || (!x && !y)) return;
    const direction = `${Math.sign(x)}:${Math.sign(y)}:${Math.abs(x) > Math.abs(y)}`;
    let batches = page.wheelBatches ||= [];
    let last = batches.at(-1);
    const compatible = last && last.cid === component.cid && last.state === state && last.direction === direction;
    // Bound unsent segments and sums without dropping accumulated movement.
    // Saturation flushes through the standing server bounds, never bypassing them.
    if (batches.length >= 256 || (compatible && Math.max(Math.abs(last.x + x), Math.abs(last.y + y)) > 16777216)) {
      flushWheel(page);
      batches = page.wheelBatches;
      last = null;
    }
    if (last && last.cid === component.cid && last.state === state && last.direction === direction) {
      last.x += x; last.y += y;
    } else batches.push({ cid: component.cid, x, y, state, direction });
    if (page.wheelFrame == null) page.wheelFrame = window.requestAnimationFrame(() => flushWheel(page));
  }

  /**
   * Counts UTF-8 bytes in serialized JSON without allocating a second byte buffer.
   * @param {string} text JSON text (unpaired surrogates have already been escaped).
   * @returns {number} Encoded byte count.
   */
  function utf8Bytes(text) {
    let size = 0;
    for (const character of text) {
      const code = character.codePointAt(0);
      size += code <= 0x7f ? 1 : code <= 0x7ff ? 2 : code <= 0xffff ? 3 : 4;
    }
    return size;
  }

  // Defaults match Contract::WIRE_LIMITS; the greeting supplies server limits.
  let wireLimits = { message_bytes: 2097152, event_payload_bytes: 524288, submission_bytes: 1048576 };

  // Kept in parity with Contract lifecycle events by contract_foundation_spec.
  const LIFECYCLE_EVENTS = new Set(["attach", "detach", "close", "dismiss", "focus", "blur", "pointer_press", "tab_pointer", "window_state"]);

  /**
   * Sends a bound event with the delivered generation and its server-declared input scope.
   * Keeps at most 256 intent snapshots totaling 8 MiB for 30 seconds and one correlated stale-tree retry.
   * Sensitive snapshots are released by clear_sensitive, expiry, closure, or disconnect.
   * Counts serialized message bytes once and updates a local subtotal during eviction.
   * @param {Object} page Viewer state containing bindings, controls, and submission scopes.
   * @param {Object} component Component whose bound event is being emitted.
   * @param {string} event Bound event name.
   * @param {Object} payload Event data checked against the payload byte budget.
   * @param {Object|null} previous Retained intent for its single replay, otherwise null.
   * @returns {void}
   */
  function emit(page, component, event, payload = {}, previous = null) {
    if (!socket || socket.readyState !== WebSocket.OPEN || !bound(page, component.cid, event)) return;
    if (!previous && !["scroll", "scrolled", "configure", "window_state"].includes(event)) flushWheel(page);
    if (event !== "configure" && !LIFECYCLE_EVENTS.has(event) && (component.props.disabled || page.element?.hidden)) return;
    const message = {
      type: "event", page: page.address, cid: component.cid, event,
      generation: page.generation, payload, request: ++nextRequest
    };
    const scope = page.submissions[component.cid];
    if (scope && ["activate", "submit", "response", "row_activate", "region_activate", "surface_activate"].includes(event)) {
      message.submission = previous ? previous.message.submission : scope.map(cid => controlValue(page.controls.get(cid)));
    }
    // Measure the actual serialized UTF-8 bytes, including Unicode and escaping,
    // before advancing draft baselines or retaining a retry snapshot.
    const serialized = JSON.stringify(message);
    const messageBytes = utf8Bytes(serialized);
    if (messageBytes > wireLimits.message_bytes ||
        utf8Bytes(JSON.stringify(payload)) > wireLimits.event_payload_bytes ||
        (message.submission && utf8Bytes(JSON.stringify(message.submission)) > wireLimits.submission_bytes)) {
      notify("This change is too large to send. Your edits are retained; reduce the input size and retry.", "error");
      return;
    }
    const liveText = component.type === "text_input" && event === "change" && !component.props.sensitive;
    // Only the newest live edit may be retried. Earlier callbacks may still
    // finish, but their render acknowledges an older request and cannot own
    // the current draft or caret. This also bounds typing to one retained edit.
    if (liveText) discardPending(record => record.liveText && record.message.page === page.address && record.message.cid === component.cid);
    // A sent toggle is no longer an unsent draft. A callback may reset it to
    // the previous server value before an intermediate render acknowledges it.
    // A replay must keep the replacement tree's baseline: its DOM may still
    // show the old server value, which must not become a fabricated local edit.
    if (!previous && event === "change" && ["checkbox", "toggle"].includes(component.type)) {
      page.bases?.set(component.cid, payload.value);
    }
    if (scope && ["activate", "submit", "response", "row_activate", "region_activate", "surface_activate"].includes(event)) {
      // A submitted draft becomes the comparison baseline. Otherwise a server
      // clearing an initially empty field looks like an unrelated redraw and
      // the client restores the just-submitted text (sbounty's Create form).
      // Retrying a retained snapshot is not a new edit of the current controls.
      scope.forEach((cid, index) => {
        if (!previous) discardPending(record => record.liveText && record.message.page === page.address && record.message.cid === cid);
        const control = page.controls.get(cid);
        if (!previous && control && control.type !== "password" && control.dataset?.sensitive !== "true") {
          page.bases?.set(cid, message.submission[index]);
        }
      });
    }
    // Scroll is a fresh measurement, not replayable user intent.
    if (event !== "scrolled") {
      let retained = [...pending.values()].reduce((sum, record) => sum + record.bytes, 0);
      while (pending.size >= 256 || retained + messageBytes > 8 * 1024 * 1024) {
        const oldest = pending.keys().next().value;
        retained -= pending.get(oldest).bytes;
        dropPending(oldest);
      }
      const record = { message: JSON.parse(JSON.stringify(message)), scope: scope ? [...scope] : [],
        attempt: previous ? previous.attempt + 1 : 0, replay: false, liveText, bytes: messageBytes };
      if (event === "widget_drop") record.dragSourceKey = previous?.dragSourceKey || findComponent(page.tree, payload.source)?.props.drag_source;
      record.timer = window.setTimeout(() => dropPending(message.request), 30000);
      pending.set(message.request, record);
    }
    socket.send(serialized);
  }

  function appendChildren(page, component, parent) {
    (component.children || []).forEach((child) => parent.append(render(page, child)));
    return parent;
  }

  // Pango's middle ellipsis is allocation-dependent. Measure literal text in
  // the rendered font, preserving the full value for accessibility and resize.
  function middleEllipsis(page, element, content, props) {
    const parts = window.Intl?.Segmenter
      ? Array.from(new window.Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(content), part => part.segment)
      : Array.from(content);
    element.style.overflow = "hidden";
    element.style.whiteSpace = "pre";
    element.style.minWidth = "0";
    element.setAttribute("aria-label", content);
    let preferredWidth = null;
    const fit = () => {
      if (!element.isConnected || element.clientWidth <= 0) return;
      element.textContent = content;
      if (preferredWidth === null && element.scrollWidth > element.clientWidth) {
        const cssCap = Number.parseFloat(window.getComputedStyle?.(element)?.maxWidth);
        // The original Pango markup declares points. CreatureBar draws those
        // labels at equivalent CSS pixels, but Gtk::Label's character request
        // is still measured in points. Preserve that natural request before
        // replacing the DOM text with a shorter middle-ellipsized string.
        const cap = Number.isFinite(cssCap) ? Math.round(cssCap * (props.font_unit === "px" ? 4 / 3 : 1)) : Infinity;
        preferredWidth = Math.min(element.scrollWidth, cap);
        element.style.width = `${preferredWidth}px`;
        const horizontalMargin = props.margin && typeof props.margin === "object"
          ? (props.margin.left || 0) + (props.margin.right || 0) : 0;
        element.style.maxWidth = horizontalMargin ? `calc(100% - ${horizontalMargin}px)` : "100%";
      }
      if (element.scrollWidth <= element.clientWidth) return;
      const shorten = count => parts.slice(0, Math.ceil(count / 2)).join("") + "\u2026" +
        (count > 1 ? parts.slice(-Math.floor(count / 2)).join("") : "");
      let low = 0, high = parts.length - 1;
      while (low < high) {
        const count = Math.ceil((low + high) / 2);
        element.textContent = shorten(count);
        if (element.scrollWidth <= element.clientWidth) low = count; else high = count - 1;
      }
      element.textContent = shorten(low);
    };
    observeAllocation(page, element, fit);
  }

  // Allocation observers belong to one render and never outlive its page.
  function observeAllocation(page, element, work) {
    window.requestAnimationFrame(work);
    if (window.ResizeObserver) {
      const observer = new window.ResizeObserver(work);
      observer.observe(element);
      (page.layoutObservers ||= []).push(observer);
    }
  }

  // Some source grids spread a spanning child's minimum-height deficit over
  // every covered row, including occupied rows. CSS auto tracks instead favor
  // empty rows. Measure natural children at the current column widths; never
  // substitute fixed heights captured from one window or font size.
  function spreadGridRows(page, component, grid) {
    observeAllocation(page, grid, () => {
      if (!grid.isConnected || !grid.getClientRects().length) return;
      // Property patches may arrive separately from a new child tree; retain
      // ordinary CSS allocation until explicit row placements are available.
      if ((component.children || []).some(child => !Number.isInteger(child.placement?.row))) return;
      grid.style.gridTemplateRows = "none";
      const items = (component.children || []).map((child, index) => {
        const cell = grid.children[index];
        if (!cell || child.props.hidden) return null;
        const alignment = cell.style.alignSelf, height = cell.style.height;
        cell.style.alignSelf = "start"; cell.style.height = "auto";
        const style = window.getComputedStyle(cell);
        const minimum = cell.getBoundingClientRect().height +
          (parseFloat(style.marginTop) || 0) + (parseFloat(style.marginBottom) || 0);
        cell.style.alignSelf = alignment; cell.style.height = height;
        return { row: child.placement.row - 1, span: child.placement.row_span || 1, minimum };
      }).filter(Boolean);
      if (!items.length) return;
      const gap = component.props.row_gap ?? component.props.gap ?? 8;
      const rows = Array(Math.max(...items.map(item => item.row + item.span))).fill(0);
      // Resolve smaller constraints first, then share each remaining deficit.
      // This retains sparse source rows rather than deleting their allocation.
      items.sort((a, b) => a.span - b.span).forEach(item => {
        const occupied = rows.slice(item.row, item.row + item.span).reduce((sum, height) => sum + height, 0);
        const extra = Math.max(0, item.minimum - occupied - gap * (item.span - 1)) / item.span;
        for (let row = item.row; row < item.row + item.span; row++) rows[row] += extra;
      });
      grid.style.gridTemplateRows = rows.map(height => `${height}px`).join(" ");
    });
  }

  /** Registers an input and composes its label without losing the control's natural sizing. */
  function field(page, component, control, inline = false) {
    control.dataset.sensitive = String(component.props.sensitive === true || component.type === "password_input");
    const wrapper = common(node("label", `field${inline || component.props.inline ? " inline" : ""}`), component);
    if (inline) wrapper.append(control);
    if (component.props.label) wrapper.append(node("span", "field-label", component.props.label));
    if (!inline) wrapper.append(control);
    if (component.props.max_width_chars) {
      // Preserve character-based natural sizing. GTK rounds the digit advance
      // to whole layout pixels; compact entries add 8px padding and 1px border
      // on each side. The field may grow within this cap as its grid expands.
      wrapper.style.width = "100%";
      wrapper.style.maxWidth = `calc(${component.props.max_width_chars} * round(up, 1ch, 1px) + 18px)`;
      // Give grid layout both a preferred width and a shrinkable allocation;
      // a cap alone leaves the entry's smaller default intrinsic size in force.
      control.style.width = wrapper.style.maxWidth;
      control.style.maxWidth = "100%";
    }
    if (component.props.control_width) {
      control.style.width = `${component.props.control_width}px`;
      // flex-basis follows the wrapper axis: only an inline row may use its
      // width as the basis. A vertical field would otherwise become square.
      control.style.flex = inline || component.props.inline ? `0 0 ${component.props.control_width}px` : "0 0 auto";
    }
    if (component.props.control_margin !== undefined) {
      // The combo entry shares this input; its spacing must not move the outer field.
      const margin = component.props.control_margin;
      if (Number.isFinite(margin)) control.style.margin = `${margin}px`;
      else for (const side of ["top", "right", "bottom", "left"]) {
        control.style[`margin${side[0].toUpperCase()}${side.slice(1)}`] = `${margin[side] || 0}px`;
      }
    }
    if (component.props.control_width_chars) {
      control.style.width = `calc(${component.props.control_width_chars} * round(up, 1ch, 1px) + 2 * var(--entry-padding, 8px) + 2px)`;
      control.style.flex = "0 0 auto";
    }
    if (component.props.min_width_chars) {
      // A GTK width-chars request is a minimum, independent of whether its
      // parent gives the field extra space. Keep any larger pixel request.
      const minimum = `calc(${component.props.min_width_chars} * round(up, 1ch, 1px) + 2 * var(--entry-padding, 8px) + 2px)`;
      wrapper.style.minWidth = wrapper.style.minWidth ? `max(${wrapper.style.minWidth}, ${minimum})` : minimum;
    }
    page.controls.set(component.cid, control);
    return wrapper;
  }

  /** Creates a typed input while keeping sensitive defaults out of the rendered value. */
  function input(page, component, type) {
    const control = node("input");
    control.type = type;
    control.disabled = component.props.disabled === true;
    if (component.props.placeholder) control.placeholder = component.props.placeholder;
    if (component.props.max_length) control.maxLength = component.props.max_length;
    page.controls.set(component.cid, control);
    return control;
  }

  function markNaturalEntry(control, props) {
    if (!props.search && ["width", "min_width", "control_width", "control_width_chars",
      "min_width_chars", "max_width_chars"].every(key => props[key] === undefined)) {
      // Both a bare Gtk::Entry and an editable Gtk::ComboBoxText contain
      // the same natural-width entry until the script requests another size.
      control.dataset.naturalEntry = "true";
    }
  }

  const renderers = {
    expander(page, component) {
      const details = common(node("details", "webui-expander"), component);
      details.open = component.props.open === true;
      let lastOpen = details.open;
      details.append(node("summary", null, component.props.label));
      // Collapsed content remains mounted so terminal submissions include its
      // inputs. Ignore the browser's initial toggle notification on rendering.
      appendChildren(page, component, details);
      details.addEventListener("toggle", () => {
        if (details.open === lastOpen) return;
        lastOpen = details.open;
        emit(page, component, "toggle", { open: details.open });
      });
      return details;
    },
    /** Builds the page root and retains its properties for native presentation updates. */
    page(page, component) {
      const root = common(node("section", "webui-page"), component);
      page.windowProps = component.props;
      if (!requestedPage || page.address === requestedPage) document.title = component.props.title;
      root.classList.toggle("webui-page-bare", component.props.bare === true);
      if (component.props.theme) root.dataset.theme = component.props.theme;
      if (component.props.density) root.dataset.density = component.props.density;
      if (component.props.viewport) root.dataset.viewport = "true";
      root.addEventListener("pointerdown", () => holdPointer(page));
      if (!component.props.bare) root.append(node("h1", null, component.props.title));
      return appendChildren(page, component, root);
    },
    /** Builds a frame or menu; submenu selection persists until toggled or dismissed. */
    group(page, component) {
      if (component.props.menu) {
        const popover = component.props.menu === "popover";
        const submenu = component.props.menu === "submenu" || popover;
        const group = common(node("div", submenu ? "webui-submenu" : "webui-context-menu"), component);
        group.setAttribute("role", "menu");
        if (submenu) {
          group.removeAttribute("role");
          const trigger = node("button", "submenu-trigger", component.props.label);
          trigger.setAttribute("role", "menuitem");
          trigger.disabled = component.props.disabled === true;
          trigger.setAttribute("aria-haspopup", "menu");
          trigger.setAttribute("aria-label", component.props.label || "");
          trigger.setAttribute("aria-expanded", "false");
          if (popover) {
            group.classList.add("webui-popover");
            trigger.setAttribute("aria-haspopup", "dialog");
            if (component.props.menu_icon && component.children?.length) {
              trigger.textContent = "";
              trigger.append(render(page, component.children[0]));
            }
          }
          const panel = node("div", "submenu-items");
          panel.setAttribute("role", popover ? "dialog" : "menu");
          if (popover) panel.setAttribute("aria-label", component.props.label || "Options");
          // A scrolling menu clips fixed descendants in WebKit. The top layer
          // lets the existing submenu escape that clip without reparenting it
          // (which would lose inherited theme and menu ancestry).
          if (typeof panel.showPopover === "function") panel.setAttribute("popover", "manual");
          panel.style.display = "none";
          /** Dismisses this branch, including any descendant top-layer panels. */
          const close = () => {
            hideSubmenus(group, page);
          };
          /** Opens this branch within the viewport while preserving its open ancestors. */
          const open = () => {
            if (popover) page.popovers?.forEach((entry, cid) => { if (cid !== component.cid) entry.close(); });
            // Click selection persists while the pointer crosses other rows.
            // Only selecting a sibling replaces this branch; ancestors stay open.
            for (const sibling of group.parentElement.children) {
              if (sibling !== group) hideSubmenus(sibling, page);
            }
            panel.style.display = "block";
            panel.showPopover?.();
            const anchor = trigger.getBoundingClientRect(), bounds = panel.getBoundingClientRect();
            let left = anchor.right + bounds.width > window.innerWidth ? anchor.left - bounds.width : anchor.right;
            let top = anchor.top;
            if (popover) {
              const position = component.props.menu_position || "bottom";
              left = ["top", "bottom"].includes(position) ? anchor.left : position === "left" ? anchor.left - bounds.width : anchor.right;
              top = position === "top" ? anchor.top - bounds.height : position === "bottom" ? anchor.bottom : anchor.top;
              (page.openPopovers ||= new Set()).add(component.cid);
            }
            panel.style.left = `${Math.max(0, Math.min(left, window.innerWidth - bounds.width))}px`;
            panel.style.top = `${Math.max(0, Math.min(top, window.innerHeight - bounds.height))}px`;
            trigger.setAttribute("aria-expanded", "true");
          };
          // Render restoration reuses positioning/popover logic without clicking
          // the trigger or delivering a synthetic script activation.
          group.openSubmenu = open;
          trigger.addEventListener("click", event => {
            event.stopPropagation();
            if (trigger.getAttribute("aria-expanded") === "true") close();
            else open();
          });
          trigger.addEventListener("keydown", event => {
            if (event.key !== "ArrowRight") return;
            event.preventDefault();
            open();
            focusMenuItem(panel);
          });
          const content = popover && component.props.menu_icon ? { ...component, children: component.children.slice(1) } : component;
          group.append(trigger, appendChildren(page, content, panel));
          if (popover) {
            (page.popovers ||= new Map()).set(component.cid, { group, trigger, open, close });
          } else menuNavigation(panel, () => { close(); trigger.focus(); });
          return group;
        } else {
          (page.contextMenus ||= new Map()).set(component.props.key, group);
          group.style.display = "none";
          group.menuComponent = component;
          group.addEventListener("click", event => {
            if (event.target.closest?.("button,input") && !event.target.closest?.(".submenu-trigger")) hideContextMenu(page);
          });
        }
        appendChildren(page, component, group);
        menuNavigation(group);
        return group;
      }
      const group = common(node("fieldset", "webui-group"), component);
      if (["start", "center", "end"].includes(component.props.align)) group.style.justifySelf = component.props.align;
      if (component.props.constrain_width) group.style.maxWidth = "100%";
      if (component.props.width === undefined && !component.props.constrain_width &&
          component.children?.some(child => child.type === "grid" && child.props.homogeneous === false)) {
        // Keep a natural grid inside its frame, including when the frame lives
        // in a scrollable stack. Explicit constraints still win; grid scrollers
        // remain bounded by inline-size containment rather than long row text.
        group.style.minWidth = "min-content";
        // A requested minimum is a floor, not a cap on the grid's requisition.
        // The intrinsic minimum can exceed this preferred width.
        if (component.props.min_width !== undefined) group.style.width = `${component.props.min_width}px`;
      }
      if (component.props.label) group.append(node("legend", null, component.props.label));
      // An explicitly blank label has a requisition; an absent label has none.
      if (component.props.label === "") group.dataset.emptyLabel = "true";
      // Filling frames participate in their parent's vertical allocation.
      if (component.props.fill || component.props.content_align) {
        group.style.display = "flex"; group.style.flexDirection = "column";
      }
      // Align the natural content inside an allocated frame. The legend and
      // frame allocation remain independent of the child alignment request.
      if (component.props.content_align) {
        group.style.justifyContent = component.props.content_align === "center" ? "center" :
          component.props.content_align === "end" ? "flex-end" : "flex-start";
      }
      if (component.props.padding !== undefined) group.style.padding = `${component.props.padding}px`;
      if (component.props.border_color) group.style.borderColor = compositeColor(component.props.border_color);
      if (component.props.border_width !== undefined) group.style.borderWidth = `${component.props.border_width}px`;
      // A borderless layout surface has no empty frame-label requisition.
      if (component.props.border_width === 0) group.dataset.borderless = "true";
      if (component.props.radius !== undefined) group.style.borderRadius = `${component.props.radius}px`;
      if (component.props.background) group.style.backgroundColor = compositeColor(component.props.background);
      if (component.props.surface_events) group.addEventListener("click", event => {
        if (event.target.closest?.("button,input,select,textarea")) return;
        emit(page, component, "surface_activate", surfacePayload(event, group, 1, "primary"));
      });
      if (component.props.context_menu) group.addEventListener("contextmenu", event => {
        event.preventDefault();
        showContextMenu(page, component.props.context_menu, event.clientX, event.clientY);
      });
      return appendChildren(page, component, group);
    },
    stack(page, component) {
      const stack = common(node("div", "webui-stack"), component);
      stack.style.gap = `${component.props.gap ?? 8}px`;
      if (component.props.orientation === "horizontal") {
        stack.style.flexDirection = "row";
        stack.style.flexWrap = "nowrap";
        if (component.props.align === "center") stack.style.justifyContent = "center";
      }
      appendChildren(page, component, stack);
      if (component.props.content_align && component.children?.length === 1) {
        stack.style.display = "grid";
        stack.style.gridTemplateRows = "minmax(min-content, 1fr)";
        stack.firstElementChild.style.alignSelf = component.props.content_align;
      }
      return stack;
    },
    columns(page, component) {
      const columns = common(node("div", "webui-columns"), component);
      if (component.props.compact) columns.dataset.compact = "true";
      // Center short content, but never place the beginning of overflowing text
      // above its scroll origin where the user cannot reach it.
      if (component.props.row_align) columns.style.alignItems = component.props.row_align === "center" ? "safe center" : component.props.row_align;
      const weights = component.props.weights || Array(component.props.count).fill(1);
      columns.style.gridTemplateColumns = weights.map((weight) => weight === 0 ? "max-content" : `${weight}fr`).join(" ");
      columns.style.gap = `${component.props.gap ?? 8}px`;
      (component.children || []).forEach((child) => {
        const childNode = render(page, child);
        childNode.style.gridColumn = String(Number(child.slot) + 1);
        columns.append(childNode);
      });
      return columns;
    },
    grid(page, component) {
      const grid = common(node("div", "webui-grid"), component);
      grid.style.gridTemplateColumns = `repeat(${component.props.cols}, ${component.props.homogeneous === false ? "auto" : "minmax(0, 1fr)"})`;
      if (component.props.homogeneous === false) {
        const expanding = component.props.expand_columns || [];
        if (expanding.length) {
          // Auto tracks share surplus space above their natural widths. Fixed
          // peers stay content-sized; equal fr tracks would erase that distinction.
          grid.style.gridTemplateColumns = Array.from({ length: component.props.cols },
            (_, index) => expanding.includes(index + 1) ? "auto" : "max-content").join(" ");
          grid.style.justifyContent = "stretch";
        } else {
          // Natural tracks must still let scroll containers fit their allocation.
          // Inline controls contribute their own minimum below; long list text
          // must not turn an entire column into a max-content track.
          grid.style.justifyContent = component.props.align === "end" ? "end" : "start";
        }
      }
      // Equal natural row tracks differ from spreading surplus height: each
      // occupied row receives the same fraction, including multi-row content.
      if (component.props.equal_rows) grid.style.gridAutoRows = "1fr";
      grid.style.gap = `${component.props.gap ?? 8}px`;
      if (component.props.row_gap !== undefined) grid.style.rowGap = `${component.props.row_gap}px`;
      if (component.props.column_gap !== undefined) grid.style.columnGap = `${component.props.column_gap}px`;
      (component.children || []).forEach((child) => {
        const cell = render(page, child);
        if (child.props.vertical_align) cell.style.alignSelf = child.props.vertical_align;
        const placement = child.placement || {};
        if (!component.props.flow) {
          cell.style.gridColumn = `${placement.column ? placement.column + " / " : ""}span ${placement.span ?? 1}`;
          cell.style.gridRow = `${placement.row ? placement.row + " / " : ""}span ${placement.row_span ?? 1}`;
        }
        if (child.props.align) cell.style.justifySelf = child.props.align;
        if (["scroll", "table"].includes(child.type) && child.props.width === undefined) {
          // A scroller consumes its grid allocation; its longest row must not
          // enlarge max-content tracks spanned by the scrolling viewport.
          // Leave width auto so grid stretching subtracts the source margins.
          cell.style.contain = "inline-size";
          if (child.props.min_width === undefined) cell.style.minWidth = "0px";
        }
        if (child.type === "scroll" && child.props.height === undefined && placement.row &&
            (!child.props.vertical_align || child.props.vertical_align === "stretch") &&
            (component.children || []).some(peer => peer !== child && peer.placement?.row === placement.row &&
              (peer.placement.row_span || 1) === (placement.row_span || 1) && Number.isFinite(peer.props.height))) {
          // An unsized scroller alongside an explicitly allocated peer consumes
          // that row's height. Its document must not become the row's minimum.
          cell.style.contain = "size";
          cell.style.minHeight = `${child.props.min_height || 0}px`;
          cell.style.alignSelf = child.props.vertical_align || "stretch";
        }
        if (component.props.homogeneous === false && !(component.props.expand_columns || []).length &&
            (child.props.inline || ["checkbox", "radio_option"].includes(child.type)) && ["text_input", "number_input", "select", "checkbox", "radio_option"].includes(child.type) &&
            child.props.min_width === undefined && !child.props.max_width_chars) {
          // Keep an inline label and control together without imposing the same
          // minimum on scrollable peers or explicitly capped entry fields.
          cell.style.minWidth = "max-content";
        }
        grid.append(cell);
      });
      if (component.props.flow) {
        const allocate = () => {
          if (!grid.isConnected || grid.clientWidth <= 0) return;
          const gap = component.props.column_gap ?? component.props.gap ?? 8;
          const cells = [...grid.children].filter(cell => !cell.hidden);
          const authoredWidths = cells.map(cell => cell.style.width);
          cells.forEach(cell => { cell.style.width = "max-content"; });
          const widths = cells.map(cell => Math.max(cell.scrollWidth, cell.getBoundingClientRect().width));
          cells.forEach((cell, index) => { cell.style.width = authoredWidths[index]; });
          const natural = Math.max(1, ...widths);
          const columns = Math.max(1, Math.min(component.props.cols, Math.floor((grid.clientWidth + gap) / (natural + gap))));
          const tracks = `repeat(${columns}, ${component.props.homogeneous === false ? "max-content" : "minmax(0, 1fr)"})`;
          if (grid.style.gridTemplateColumns !== tracks) grid.style.gridTemplateColumns = tracks;
        };
        window.requestAnimationFrame(allocate);
        if (window.ResizeObserver) {
          const observer = new window.ResizeObserver(allocate);
          observer.observe(grid);
          (page.layoutObservers ||= []).push(observer);
        }
        window.addEventListener("resize", allocate);
        (page.inputDisposers ||= []).push(() => window.removeEventListener("resize", allocate));
        document.fonts?.ready.then(allocate);
      }
      if (component.props.row_sizing === "spread" && !component.props.equal_rows) spreadGridRows(page, component, grid);
      return grid;
    },
    // alias/vars use vertical adjustments. Retain offsets locally across tree
    // replacement and report actual layout measurements only when they change.
    scroll(page, component) {
      const element = common(node("div", "webui-scroll"), component);
      element.style.overflow = "auto";
      if (component.props.fill) { element.style.flex = "1"; element.style.minHeight = `${Math.max(0, component.props.min_height || 0)}px`; element.style.height = "0px"; }
      if (component.props.scrollbars === false) element.style.scrollbarWidth = "none";
      appendChildren(page, component, element);
      const alignedChild = component.children?.length === 1 && component.children[0].props.vertical_align;
      if (alignedChild) {
        // Give the child a vertical allocation without turning align-self into
        // a flex cross-axis request. The min-content row grows when content
        // overflows, keeping its beginning reachable for center/end alignment.
        element.style.display = "grid";
        element.style.gridTemplateColumns = "minmax(0, 1fr)";
        element.style.gridTemplateRows = "minmax(min-content, 1fr)";
        const child = element.firstElementChild;
        child.style.alignSelf = alignedChild;
        if (component.children[0].props.height === undefined) child.style.height = "auto";
      }
      // A lone table owns the whole viewport, including its empty drop area.
      // Propagate allocation through transparent vertical wrappers; keep mixed
      // content and explicitly sized children under their existing layout rules.
      const path = [];
      let parent = component, parentNode = element;
      while (!alignedChild && parent.children?.length === 1) {
        const child = parent.children[0], childNode = parentNode.firstElementChild;
        if (!childNode || child.props.hidden || child.props.height !== undefined) break;
        path.push(childNode);
        if (child.type === "table") {
          element.style.display = "flex";
          element.style.flexDirection = "column";
          path.forEach(node => { node.style.flex = "1 0 auto"; node.style.height = "auto"; });
          // The outer viewport owns overflow; the table retains its natural row
          // height while its border/drop surface grows to the available minimum.
          childNode.style.contain = "none";
          childNode.style.overflow = "visible";
          break;
        }
        if (child.type !== "stack" || child.props.orientation === "horizontal") break;
        parent = child; parentNode = childNode;
      }
      const offsets = page.scrollOffsets ||= new Map();
      const horizontalOffsets = page.horizontalScrollOffsets ||= new Map();
      const requests = page.scrollRequests ||= new Map();
      const requested = component.props.scroll_position;
      const report = () => {
        if (!element.isConnected) return;
        const pixels = value => Math.round(value);
        const payload = {
          position: pixels(element.scrollTop), upper: pixels(element.scrollHeight),
          page_size: pixels(element.clientHeight)
        };
        offsets.set(component.cid, payload.position);
        horizontalOffsets.set(component.cid, pixels(element.scrollLeft));
        const signature = JSON.stringify(payload);
        const measurements = page.scrollMeasurements ||= new Map();
        if (measurements.get(component.cid) === signature) return;
        measurements.set(component.cid, signature);
        emit(page, component, "scrolled", payload);
      };
      element.addEventListener("scroll", report, { passive: true });
      window.requestAnimationFrame(() => {
        if (!element.isConnected) return;
        if (requested !== undefined && requests.get(component.cid) !== requested) {
          element.scrollTop = requested;
          requests.set(component.cid, requested);
        } else element.scrollTop = offsets.get(component.cid) || 0;
        element.scrollLeft = horizontalOffsets.get(component.cid) || 0;
        report();
      });
      return element;
    },
    tabs(page, component) {
      const tabs = common(node("div", "webui-tabs"), component);
      if (component.props.size_to_all) {
        tabs.dataset.sizeToAll = "true";
        // Theme flex styles must not put hidden sizing pages into normal flow.
        tabs.style.display = "grid";
        tabs.style.gridTemplateRows = component.props.show_tabs === false ? "0 minmax(min-content, 1fr)" : "max-content minmax(min-content, 1fr)";
      }
      if (component.cid.includes("saved-account-tabs")) tabs.classList.add("account-tabs-left");
      else if (component.cid.includes("account")) tabs.classList.add("nested");
      const list = node("div", "tab-list");
      list.setAttribute("role", "tablist");
      list.hidden = component.props.show_tabs === false;
      if (list.hidden) list.style.display = "none";
      const selected = component.props.selected ?? 0;
      component.props.names.forEach((name, index) => {
        const button = node("button", null, name);
        button.type = "button";
        button.setAttribute("role", "tab");
        button.setAttribute("aria-selected", String(index === selected));
        const header = component.props.headers?.[index];
        button.hidden = header?.hidden === true;
        button.disabled = component.props.disabled === true || header?.disabled === true;
        if (header?.foreground) button.style.color = compositeColor(header.foreground);
        if (header?.pointer_events) {
          const press = (event, clickCount) => {
            if (button.disabled || event.button > 2) return;
            event.stopPropagation();
            if (event.button !== 0) event.preventDefault();
            emit(page, component, "tab_pointer", { tab: header.key, x: Math.round(event.clientX), y: Math.round(event.clientY),
              button: event.button + 1, time: Math.floor(event.timeStamp),
              state: (event.shiftKey ? 1 : 0) | (event.ctrlKey ? 4 : 0) | (event.altKey ? 8 : 0), click_count: clickCount });
          };
          button.addEventListener("pointerdown", event => press(event, 1));
          button.addEventListener("dblclick", event => press(event, 2));
          button.addEventListener("contextmenu", event => event.preventDefault());
          button.addEventListener("auxclick", event => event.preventDefault());
        }
        button.addEventListener("click", () => emit(page, component, "select", { index, ...(header ? { tab: header.key } : {}) }));
        list.append(button);
      });
      const actions = (component.children || []).filter(child => child.placement?.tab_action);
      if (actions.length) {
        tabs.dataset.tabActions = "true";
        const header = node("div", "tab-header");
        header.hidden = component.props.show_tabs === false;
        if (header.hidden) header.style.display = "none";
        for (const side of ["start", "end"]) {
          const action = actions.find(child => child.placement.tab_action === side);
          if (!action) continue;
          const region = node("div", `tab-action tab-action-${side}`);
          region.append(render(page, action));
          header.append(region);
        }
        const end = header.querySelector(".tab-action-end");
        header.insertBefore(list, end);
        tabs.append(header);
      } else tabs.append(list);
      (component.children || []).filter(child => !child.placement?.tab_action).forEach((child, index) => {
        const panel = render(page, child);
        panel.classList.add("tab-panel");
        panel.setAttribute("role", list.hidden ? "group" : "tabpanel");
        if (list.hidden) panel.setAttribute("aria-label", component.props.names[index]);
        panel.hidden = index !== selected || component.props.headers?.[index]?.hidden === true;
        if (component.props.size_to_all) {
          panel.inert = index !== selected;
          // Grid tracks supply the allocation; the flex-parent zero-height
          // basis would otherwise prevent this page from stretching.
          if (child.props.fill) panel.style.height = "auto";
        }
        tabs.append(panel);
      });
      return tabs;
    },
    divider(_page, component) { return common(node("div", "webui-divider", component.props.label || ""), component); },
    overlay(page, component) {
      const overlay = common(node("div", "webui-overlay"), component);
      if (component.props.clip_children) overlay.style.overflow = "hidden";
      if (component.props.positioned) {
        overlay.style.position = "relative";
        appendChildren(page, component, overlay);
        Array.from(overlay.children).forEach((child, index) => {
          const layer = component.children[index];
          child.style.position = "absolute";
          child.style.left = `${layer.placement?.x || 0}px`;
          child.style.top = `${layer.placement?.y || 0}px`;
          if (layer.props.width === undefined) child.style.width = "max-content";
          if (layer.placement?.pass_through) child.dataset.overlayPassThrough = "true";
        });
        const measure = () => {
          if (!overlay.isConnected) return;
          let width = 0, height = 0;
          Array.from(overlay.children).forEach((child, index) => {
            if (child.hidden) return;
            const placement = component.children[index].placement || {};
            width = Math.max(width, (placement.x || 0) + child.offsetWidth);
            height = Math.max(height, (placement.y || 0) + child.offsetHeight);
          });
          overlay.style.minWidth = `${width}px`;
          overlay.style.minHeight = `${height}px`;
        };
        observeAllocation(page, overlay, measure);
        if (window.ResizeObserver) {
          const observer = new window.ResizeObserver(measure);
          Array.from(overlay.children).forEach(child => observer.observe(child));
          (page.layoutObservers ||= []).push(observer);
        }
        return overlay;
      }
      overlay.style.display = "grid";
      appendChildren(page, component, overlay);
      Array.from(overlay.children).forEach((child, index) => {
        const layer = component.children[index];
        child.style.gridArea = "1 / 1";
        if (layer.props.align) child.style.justifySelf = layer.props.align;
        if (layer.props.vertical_align) child.style.alignSelf = layer.props.vertical_align;
        if (layer.placement?.pass_through) child.dataset.overlayPassThrough = "true";
      });
      return overlay;
    },
    // A split starts at its first child's natural width. Subsequent positions
    // are viewer state, so a meter refresh cannot reset the user's divider.
    split(page, component) {
      const root = common(node("div", "webui-split"), component);
      const horizontal = component.props.orientation === "horizontal";
      root.dataset.orientation = component.props.orientation;
      if (component.props.fill) root.dataset.fill = "true";
      const first = node("div", "split-pane"), second = node("div", "split-pane");
      const handle = node("div", "split-handle");
      handle.tabIndex = 0;
      handle.setAttribute("role", "separator");
      handle.setAttribute("aria-orientation", horizontal ? "vertical" : "horizontal");
      handle.setAttribute("aria-valuemin", "0"); handle.setAttribute("aria-valuemax", "100");
      for (const child of component.children || []) (child.slot === "first" ? first : second).append(render(page, child));
      root.append(first, handle, second);
      let position = component.props.position;
      const pixelMode = component.props.position_pixels !== undefined && component.props.resize_side === "first";
      const pixelState = page.pixelSplits ||= new Map();
      let secondPixels = pixelState.get(component.cid);
      const measure = () => {
        const extent = horizontal ? root.clientWidth : root.clientHeight;
        return extent ? Math.round(100 * (horizontal ? first.clientWidth : first.clientHeight) / extent) : 0;
      };
      const layout = () => {
        if (pixelMode) {
          const extent = horizontal ? root.clientWidth : root.clientHeight;
          if (!root.isConnected || extent <= 0) return;
          // GTK gives a non-resizing second pane its width from the requested
          // initial window allocation. A split can first mount after the page
          // has grown or shrunk, so use that request rather than its current
          // allocation. An explicit drag still replaces this viewer state.
          if (secondPixels === undefined) {
            const pageExtent = horizontal ? page.element?.clientWidth : page.element?.clientHeight;
            const requested = page.tree?.props?.size?.[horizontal ? 0 : 1];
            const requestedExtent = Number.isFinite(requested) && pageExtent > 0
              ? requested - Math.max(0, pageExtent - extent) : 0;
            const initialExtent = requestedExtent > component.props.position_pixels + 1
              ? requestedExtent : extent;
            if (initialExtent > component.props.position_pixels + 1) {
              secondPixels = initialExtent - 1 - component.props.position_pixels;
            }
          }
          if (secondPixels !== undefined) pixelState.set(component.cid, secondPixels);
          const visibleSecondPixels = Math.min(secondPixels ?? 0, extent - 1);
          root.style[horizontal ? "gridTemplateColumns" : "gridTemplateRows"] = `minmax(0, 1fr) 1px ${visibleSecondPixels}px`;
          handle.setAttribute("aria-valuenow", String(Math.max(0, Math.round(100 * (extent - visibleSecondPixels - 1) / extent))));
          return;
        }
        const track = position === undefined ? "max-content" : `minmax(0, ${position}fr)`;
        const rest = position === undefined ? "minmax(0, 1fr)" : `minmax(0, ${100 - position}fr)`;
        root.style[horizontal ? "gridTemplateColumns" : "gridTemplateRows"] = `${track} 1px ${rest}`;
        handle.setAttribute("aria-valuenow", String(position ?? measure()));
      };
      if (pixelMode) observeAllocation(page, root, layout); else layout();
      window.requestAnimationFrame(() => {
        if (handle.isConnected && position === undefined) handle.setAttribute("aria-valuenow", String(measure()));
      });
      let dragging = false;
      const finish = commit => {
        if (!dragging) return;
        dragging = false;
        page.splitDragging = false;
        const deferred = page.deferredRender;
        page.deferredRender = null;
        if (deferred) acceptRender(deferred);
        if (commit && position !== undefined) emit(page, component, "move", { position });
      };
      handle.addEventListener("pointerdown", event => {
        if (event.button !== 0) return;
        dragging = true; page.splitDragging = true;
        handle.setPointerCapture(event.pointerId); event.preventDefault();
      });
      handle.addEventListener("pointermove", event => {
        if (!dragging) return;
        const rect = root.getBoundingClientRect();
        const extent = horizontal ? rect.width : rect.height;
        if (!extent) return;
        position = Math.max(0, Math.min(100, Math.round(100 *
          (horizontal ? event.clientX - rect.left : event.clientY - rect.top) / extent)));
        if (pixelMode) secondPixels = Math.max(0, extent * (1 - position / 100) - 1);
        layout();
      });
      handle.addEventListener("pointerup", () => finish(true));
      handle.addEventListener("pointercancel", () => finish(false));
      handle.addEventListener("lostpointercapture", () => finish(false));
      handle.addEventListener("keydown", event => {
        const decrement = horizontal ? "ArrowLeft" : "ArrowUp";
        const increment = horizontal ? "ArrowRight" : "ArrowDown";
        if (![decrement, increment, "Home", "End"].includes(event.key)) return;
        event.preventDefault();
        position = event.key === "Home" ? 0 : event.key === "End" ? 100 :
          Math.max(0, Math.min(100, (position ?? measure()) + (event.key === increment ? 1 : -1)));
        if (pixelMode) secondPixels = Math.max(0, (horizontal ? root.clientWidth : root.clientHeight) * (1 - position / 100) - 1);
        layout(); emit(page, component, "move", { position });
      });
      return root;
    },
    log(_page, component) {
      const log = common(node("div", "webui-log", component.props.lines.slice(-component.props.max_lines)
        .map(line => Array.isArray(line) ? line.join("") : line).join("\n")), component);
      log.setAttribute("role", "log");
      for (const side of ["left", "right"]) if (component.props[`padding_${side}`] !== undefined) log.style[`padding${side[0].toUpperCase()}${side.slice(1)}`] = `${component.props[`padding_${side}`]}px`;
      log.style.whiteSpace = component.props.wrap === "none" ? "pre" : "pre-wrap";
      log.style.overflowWrap = component.props.wrap === "word_char" ? "anywhere" : "normal";
      // The enclosing scroll component owns geometry and measurements. Follow
      // after its restoration frame, so the requested end is not overwritten.
      if (component.props.follow) window.requestAnimationFrame(() => window.requestAnimationFrame(() => {
        if (!log.isConnected) return;
        const scroll = log.closest(".webui-scroll");
        if (scroll) scroll.scrollTop = scroll.scrollHeight;
      }));
      return log;
    },
    text(page, component) {
      const fragments = component.props.fragments;
      const content = fragments ? fragments.map(part => typeof part === "string" ? part : part.content).join("") : component.props.content;
      const fill = element => {
        element.textContent = "";
        if (!fragments || fragments.every(part => typeof part === "string")) { element.textContent = content; return element; }
        fragments.forEach(part => {
          if (typeof part === "string") { element.append(document.createTextNode(part)); return; }
          const span = node("span", "webui-text-fragment", part.content);
          nativeTextStyle(span, part);
          if (part.emphasis) span.style.fontWeight = part.emphasis === "strong" ? "bold" : "normal";
          if (part.font_weight !== undefined) span.style.fontWeight = String(part.font_weight);
          if (part.letter_spacing !== undefined) span.style.letterSpacing = `${part.letter_spacing}px`;
          if (part.emphasis === "subtle") span.style.opacity = "0.72";
          if (part.underline) span.style.textDecorationLine = "underline";
          if (part.scale !== undefined) span.style.fontSize = part.font_size !== undefined
            ? `${part.font_size * part.scale}${part.font_unit || "pt"}` : `${part.scale}em`;
          element.append(span);
        });
        return element;
      };
      const text = common(fill(node("div", "webui-text")), component);
      text.style.whiteSpace = component.props.wrap === false ? "pre" : "pre-wrap";
      nativeTextStyle(text, component.props);
      if (component.props.line_limit > 0) {
        text.style.display = "-webkit-box";
        text.style.webkitBoxOrient = "vertical";
        text.style.webkitLineClamp = String(component.props.line_limit);
        text.style.overflow = "hidden";
      }
      const props = component.props;
      if (props.padding_x !== undefined) text.style.paddingInline = `${props.padding_x}px`;
      if (props.padding_y !== undefined) text.style.paddingBlock = `${props.padding_y}px`;
      if (props.content_vertical_align) {
        text.style.display = "grid";
        text.style.alignContent = props.content_vertical_align;
      }
      // An inner writing-mode box contributes swapped natural dimensions for
      // quarter-turns; rotating the outer element alone would overlap neighbors.
      // GTK angles are counterclockwise. Preserve ordinary literal text at zero.
      const rotation = Number(props.rotation || 0);
      if (rotation) {
        const label = fill(node("span", "webui-rotated-text"));
        text.textContent = "";
        text.style.display = "grid";
        text.style.justifyItems = props.align || "center";
        text.style.alignContent = props.content_vertical_align || "center";
        if (rotation === 90 || rotation === 270) {
          label.style.writingMode = "vertical-rl";
          label.style.textOrientation = "sideways";
        }
        if (rotation === 90 || rotation === 180) label.style.transform = "rotate(180deg)";
        text.append(label);
      }
      if (props.line_justify) {
        // Placement belongs to the outer label. Only lines within its natural
        // text block are justified; one line must not move to the opposite edge.
        // Nest inside a rotated label so its writing mode still determines size.
        const target = rotation ? text.firstElementChild : text;
        const lines = fill(node("span", "webui-justified-lines"));
        lines.style.display = "inline-block";
        lines.style.maxWidth = "100%";
        lines.style.verticalAlign = "top";
        lines.style.textAlign = props.line_justify;
        if (props.content_vertical_align) lines.style.justifySelf = props.align || "start";
        target.textContent = "";
        target.append(lines);
      }
      if (component.props.min_width_chars) {
        const minimum = `calc(${component.props.min_width_chars} * round(up, 1ch, 1px))`;
        text.style.minWidth = text.style.minWidth ? `max(${text.style.minWidth}, ${minimum})` : minimum;
      }
      if (component.props.max_width_chars) text.style.maxWidth = `${component.props.max_width_chars}ch`;
      if (component.props.ellipsize === "middle") middleEllipsis(page, text, content, component.props);
      if (component.props.ellipsize === "end") {
        text.style.overflow = "hidden";
        text.style.whiteSpace = "pre";
        text.style.textOverflow = "ellipsis";
        text.style.minWidth = "0";
        text.setAttribute("aria-label", content);
      }
      return text;
    },
    /**
     * Render text and HTTP(S) links without sending host cookies to other ports.
     * @param {object} _page Owning page (unused by this stateless control).
     * @param {object} component Validated Markdown component and content.
     * @returns {HTMLElement} Text with permitted links; refused links remain labels.
     */
    markdown(_page, component) {
      // Setup labels use Markdown links in place of GTK's label anchors.
      // Build text nodes and HTTP(S) anchors; never interpret supplied HTML.
      const wrapper = common(node("div", "webui-markdown"), component);
      wrapper.style.whiteSpace = "pre-wrap";
      const content = component.props.content;
      const links = /\[([^\]]+)\]\((https?:\/\/(?:[^\s()]|\([^\s()]*\))+)(?: "((?:\\["\\]|[^"\\])*)")?\)/g;
      let offset = 0;
      for (const match of content.matchAll(links)) {
        wrapper.append(node("span", null, content.slice(offset, match.index)));
        let destination = null;
        try {
          const candidate = new URL(match[2]);
          const current = new URL(`${window.location.protocol}//${window.location.host}`);
          // Cookies have no port boundary. Normalize numeric IP aliases too.
          if (candidate.hostname !== current.hostname || candidate.origin === current.origin) destination = candidate.href;
        } catch (_) { /* Malformed destinations remain ordinary text. */ }
        const link = node(destination ? "a" : "span", null, match[1]);
        if (match[3] !== undefined) link.title = match[3].replace(/\\(["\\])/g, "$1");
        if (destination && component.props.disabled) {
          link.setAttribute("aria-disabled", "true");
          link.tabIndex = -1;
        } else if (destination) {
          link.href = destination;
          link.target = "_blank";
          link.rel = "noopener noreferrer";
        }
        wrapper.append(link);
        offset = match.index + match[0].length;
      }
      wrapper.append(node("span", null, content.slice(offset)));
      return wrapper;
    },
    progress(_page, component) {
      const wrapper = common(node("label", "webui-progress"), component);
      if (component.props.label) wrapper.append(node("span", null, component.props.label));
      const progress = node("progress");
      if (component.props.fill_color) {
        progress.style.setProperty("--progress-fill", compositeColor(component.props.fill_color));
      }
      progress.max = 1;
      if (!component.props.indeterminate) progress.value = component.props.value;
      wrapper.append(progress);
      return wrapper;
    },
    button(page, component) {
      const button = common(node("button", component.props.variant || "default"), component);
      if (component.cid.includes("button:play-entry-") && component.props.label.includes("  |  ")) {
        button.classList.add("entry-launch");
        component.props.label.split("  |  ").forEach((part) => {
          button.append(node("span", "entry-launch-part", part));
        });
      } else if (component.cid.includes("button:favorite-entry-")) {
        button.textContent = component.props.label === "filled_star" ? "\u2605" : "\u2606";
        button.dataset.favoriteState = component.props.label;
      } else {
        button.textContent = component.props.label;
      }
      button.type = "button";
      if (component.children?.length) {
        button.replaceChildren();
        appendChildren(page, component, button);
      }
      if (component.props.indicator) {
        button.dataset.indicator = component.props.indicator;
        button.setAttribute("role", component.props.indicator === "check" ? "menuitemcheckbox" : "menuitemradio");
        button.setAttribute("aria-checked", String(component.props.checked));
      }
      button.addEventListener("click", () => {
        if (!component.props.confirm || window.confirm(component.props.confirm)) emit(page, component, "activate");
      });
      return button;
    },
    checkbox(page, component) {
      const control = input(page, component, "checkbox");
      control.checked = component.props.checked;
      control.addEventListener("change", () => emit(page, component, "change", { value: control.checked }));
      return field(page, component, control, true);
    },
    toggle(page, component) {
      if (component.props.appearance === "menu") return menuChoice(page, component, false);
      if (component.props.appearance === "switch") {
        const control = input(page, component, "checkbox");
        control.checked = component.props.checked;
        control.setAttribute("role", "switch");
        control.setAttribute("aria-label", component.props.label || component.props.accessible_label || "Switch");
        control.classList.add("webui-switch-control");
        control.addEventListener("change", () => emit(page, component, "change", { value: control.checked }));
        const wrapper = field(page, component, control, true);
        wrapper.classList.add("webui-switch");
        const track = node("span", "webui-switch-track");
        track.setAttribute("aria-hidden", "true");
        control.after(track);
        return wrapper;
      }
      if (component.props.appearance !== "button") return renderers.checkbox(page, component);
      const button = common(node("button", "webui-toggle", component.props.label || ""), component);
      button.type = "button";
      button.disabled = component.props.disabled === true;
      let checked = component.props.checked;
      button.setAttribute("aria-pressed", String(checked));
      button.choiceValue = () => checked;
      button.restoreChoice = value => {
        checked = value;
        button.setAttribute("aria-pressed", String(checked));
      };
      page.controls.set(component.cid, button);
      button.addEventListener("click", () => {
        checked = !checked;
        button.setAttribute("aria-pressed", String(checked));
        emit(page, component, "change", { value: checked });
      });
      return button;
    },
    radio_option(page, component) {
      if (component.props.appearance === "menu") return menuChoice(page, component, true);
      const control = input(page, component, "radio");
      let checked = component.props.checked;
      control.choiceValue = () => control.checked;
      control.restoreChoice = value => { checked = value; control.checked = value; };
      control.name = radioGroupName(page, component.props.group);
      control.menuGroup = component.props.group;
      control.checked = checked;
      // Native click precedes change. Publish the transition synchronously and
      // suppress its later duplicate; already-selected clicks still activate.
      const change = () => {
        if (!control.isConnected || control.disabled || control.closest("[hidden],[inert]")) return;
        if (control.checked && !checked) {
          checked = true;
          clearRadioPeers(page, control);
          emit(page, component, "change", { value: true });
        }
      };
      control.addEventListener("change", change);
      control.addEventListener("click", () => {
        if (!control.isConnected || control.disabled || control.closest("[hidden],[inert]")) return;
        change();
        // A synchronous bridge/redraw may replace this DOM control during change.
        // Resolve the same live identity rather than losing or reviving activation.
        const current = page.controls.get(component.cid);
        const latest = page.tree && findComponent(page.tree, component.cid);
        if (latest && current?.isConnected && !current.disabled && !current.closest("[hidden],[inert]")) emit(page, latest, "activate");
      });
      return field(page, component, control, true);
    },
    radio(page, component) {
      const wrapper = common(node("fieldset", "field"), component);
      wrapper.append(node("legend", null, component.props.label));
      const options = node("div", "radio-options");
      if (component.props.orientation === "vertical") options.style.flexDirection = "column";
      options.style.gap = `${component.props.gap ?? 12}px`;
      let selectedControl;
      component.props.options.forEach((option) => {
        const label = node("label", "field inline");
        const control = node("input");
        control.type = "radio";
        control.disabled = component.props.disabled === true;
        control.name = `${page.address}:${component.props.group}`;
        control.value = option.value;
        control.checked = option.value === component.props.selected;
        control.addEventListener("change", () => {
          if (control.checked) {
            page.controls.set(component.cid, control);
            emit(page, component, "change", { value: control.value });
          }
        });
        if (control.checked) selectedControl = control;
        label.append(control, node("span", null, option.label));
        options.append(label);
      });
      if (selectedControl) page.controls.set(component.cid, selectedControl);
      wrapper.append(options);
      return wrapper;
    },
    textarea(page, component) {
      const control = node("textarea");
      control.value = component.props.value || "";
      control.rows = component.props.rows || 5;
      control.readOnly = component.props.read_only === true;
      for (const side of ["left", "right"]) if (component.props[`padding_${side}`] !== undefined) control.style[`padding${side[0].toUpperCase()}${side.slice(1)}`] = `${component.props[`padding_${side}`]}px`;
      control.wrap = component.props.wrap === "none" ? "off" : "soft";
      control.style.overflowWrap = component.props.wrap === "word_char" ? "anywhere" : "normal";
      if (component.props.cursor_visible === false) control.style.caretColor = "transparent";
      if (component.props.follow) window.requestAnimationFrame(() => { control.scrollTop = control.scrollHeight; });
      control.disabled = component.props.disabled === true;
      if (component.props.max_length) control.maxLength = component.props.max_length;
      control.addEventListener("input", () => { if (!control.readOnly) emit(page, component, "change", { value: control.value }); });
      control.addEventListener("blur", () => {
        if (!control.readOnly && !page.restoringFocus) emit(page, component, "blur", { value: control.value });
      });
      return field(page, component, control);
    },
    text_input(page, component) {
      const control = input(page, component, component.props.search ? "search" : "text");
      nativeTextStyle(control, component.props);
      if (component.props.has_frame === false) {
        control.style.border = "none";
        control.style.boxShadow = "none";
      }
      markNaturalEntry(control, component.props);
      control.value = component.props.value;
      control.readOnly = component.props.read_only === true;
      let lastValue = control.value;
      const changed = () => {
        if (control.readOnly) return;
        if (control.value === lastValue) return;
        lastValue = control.value;
        emit(page, component, "change", { value: lastValue });
      };
      if (component.props.change_mode === "input") control.addEventListener("input", changed);
      control.addEventListener("change", changed);
      control.addEventListener("focus", () => {
        if (!page.restoringFocus) emit(page, component, "focus");
      });
      control.addEventListener("blur", () => {
        if (!control.readOnly && !page.restoringFocus) emit(page, component, "blur", { value: control.value });
      });
      control.addEventListener("keydown", (event) => {
        if (event.key === "Enter") emit(page, component, "submit");
      });
      const wrapper = field(page, component, control);
      if (component.props.hidden && component.cid.endsWith("text_input:window-geometry")) trackWindowGeometry(page, component, false);
      if (component.props.hidden && component.cid.endsWith("text_input:window-content-geometry")) trackWindowGeometry(page, component, true);
      return wrapper;
    },
    password_input(page, component) {
      const control = input(page, component, "password");
      const wrapper = field(page, component, control);
      control.addEventListener("keydown", (event) => {
        if (event.key === "Enter") emit(page, component, "submit");
      });
      if (component.props.revealable) {
        const reveal = node("button", null, "Show");
        reveal.type = "button";
        reveal.addEventListener("click", () => {
          control.type = control.type === "password" ? "text" : "password";
          reveal.textContent = control.type === "password" ? "Show" : "Hide";
        });
        wrapper.append(reveal);
      }
      return wrapper;
    },
    /** Renders a numeric range through the existing numeric event and form path. */
    slider(page, component) {
      return renderers.number_input(page, component);
    },
    /** Renders numeric inputs and sliders with validated changes and numeric submissions. */
    number_input(page, component) {
      const control = input(page, component, component.type === "slider" ? "range" : "number");
      for (const name of ["min", "max", "step", "value"]) control[name] = component.props[name] ?? 1;
      if (component.props.snap_to_step === false) control.step = "any";
      let preciseValue = component.props.value, formattedText = null;
      const numericValue = () => component.props.digits !== undefined && control.value === formattedText ? preciseValue : control.valueAsNumber;
      const formatValue = () => {
        if (component.props.digits !== undefined && Number.isFinite(numericValue())) {
          preciseValue = numericValue();
          formattedText = preciseValue.toFixed(component.props.digits);
          control.value = formattedText;
        }
      };
      formatValue();
      if (component.props.digits !== undefined) {
        // Display precision must not silently change the numeric submission value.
        control.choiceValue = numericValue;
        control.restoreChoice = value => { formattedText = null; control.value = value; formatValue(); };
      }
      let lastValue = numericValue();
      const changed = () => {
        const value = numericValue();
        const valid = component.props.snap_to_step === false ? value >= component.props.min && value <= component.props.max : control.checkValidity();
        if (Number.isFinite(value) && valid && value !== lastValue) {
          lastValue = value;
          emit(page, component, "change", { value: lastValue });
        }
      };
      control.addEventListener("input", changed);
      control.addEventListener("change", changed);
      control.addEventListener("blur", () => { formatValue(); changed(); });
      const wrapper = field(page, component, control);
      if (component.props.stepper_buttons) {
        const row = node("span", "webui-number-stepper");
        row.style.width = `${component.props.control_width || 118}px`;
        // A standalone spin widget owns its original minimum request. Leaving
        // that request only on the label wrapper creates empty space beside a
        // smaller control. An inline labelled field keeps its separate sizing.
        if (!component.props.label && !component.props.inline && component.props.min_width !== undefined) {
          row.style.minWidth = `${component.props.min_width}px`;
        }
        control.style.width = "100%";
        control.replaceWith(row);
        row.append(control);
        let timer, repeatStep = component.props.step, repeats = 0, suppressClick = false;
        const pageStep = component.props.page_step ?? component.props.step * 10;
        const stop = () => {
          window.clearTimeout(timer);
          timer = null;
          repeatStep = component.props.step;
          repeats = 0;
        };
        const step = (direction, amount = component.props.step) => {
          if (control.disabled) return;
          if (component.props.snap_to_step === false) {
            const current = Number.isFinite(numericValue()) ? numericValue() : component.props.min;
            const next = Math.min(component.props.max, Math.max(component.props.min, current + direction * amount));
            formattedText = null;
            control.value = Number(next.toPrecision(15));
          } else if (direction < 0) control.stepDown(); else control.stepUp();
          formatValue();
          changed();
        };
        const accelerate = () => {
          if (++repeats > 5) {
            repeats = 0;
            if (repeatStep < pageStep) {
              repeatStep = Math.min(pageStep, repeatStep + (component.props.acceleration || 0));
            }
          }
        };
        (page.inputDisposers ||= []).push(() => { stop(); window.removeEventListener("blur", stop); });
        window.addEventListener("blur", stop);
        control.addEventListener("blur", stop);
        if (component.props.snap_to_step === false) {
          control.addEventListener("keydown", event => {
            if (!["ArrowUp", "ArrowDown", "PageUp", "PageDown"].includes(event.key)) return;
            event.preventDefault();
            const direction = event.key.endsWith("Up") ? 1 : -1;
            step(direction, event.key.startsWith("Page") ? pageStep : repeatStep);
            accelerate();
          });
          control.addEventListener("keyup", stop);
        }
        [-1, 1].forEach(direction => {
          const button = node("button", null, direction < 0 ? "\u2212" : "+");
          button.type = "button";
          button.disabled = control.disabled;
          button.setAttribute("aria-label", direction < 0 ? "Decrease" : "Increase");
          button.addEventListener("click", () => {
            if (suppressClick) { suppressClick = false; return; }
            step(direction);
          });
          if (component.props.acceleration !== undefined) {
            button.addEventListener("pointerdown", event => {
              if (event.button !== 0 || control.disabled) return;
              stop();
              suppressClick = true;
              button.setPointerCapture?.(event.pointerId);
              step(direction);
              const repeat = () => {
                if (!control.isConnected || control.disabled) { stop(); return; }
                step(direction, repeatStep);
                accelerate();
                timer = window.setTimeout(repeat, 50);
              };
              timer = window.setTimeout(repeat, 500);
            });
            const released = () => { stop(); window.setTimeout(() => { suppressClick = false; }, 0); };
            button.addEventListener("pointerup", released);
            button.addEventListener("pointercancel", released);
            button.addEventListener("lostpointercapture", stop);
          }
          row.append(button);
        });
      }
      return wrapper;
    },
    select(page, component) {
      // Editable legacy combos offer suggestions without restricting the text
      // value. The server enables this explicitly; ordinary selects stay closed.
      if (component.props.editable) {
        const control = input(page, component, "text");
        markNaturalEntry(control, component.props);
        // Keep the option ID separate from its visible label. Free text still
        // travels literally; form submissions and draft restoration use IDs
        // for selected options, just like an ordinary select.
        let selectedValue, selectedLabel, chooser;
        const textPrefix = component.props.free_text_prefix || "";
        const textValue = text => textPrefix + text;
        control.restoreChoice = value => {
          // An absent value is unselected; an explicit empty ID can name an option.
          selectedValue = value;
          selectedLabel = value == null ? "" : (component.props.options.find(option => option.value === value)?.label ??
            (textPrefix && value.startsWith(textPrefix) ? value.slice(textPrefix.length) : value));
          control.value = selectedLabel;
          if (chooser) {
            if (value == null) chooser.selectedIndex = -1;
            else chooser.value = value;
          }
        };
        control.choiceValue = () => control.value === selectedLabel ? (selectedValue ?? "") : textValue(control.value);
        control.restoreChoice(component.props.value);
        control.maxLength = 8192 - textPrefix.length;
        const suggestions = node("datalist");
        suggestions.id = `choices-${component.cid}`;
        control.setAttribute("list", suggestions.id);
        component.props.options.forEach(option => {
          const choice = node("option", null, option.label);
          choice.value = textPrefix ? option.label : option.value;
          suggestions.append(choice);
        });
        let lastValue = selectedValue;
        const changed = () => {
          // A custom entry clears the native picker's selection. Otherwise
          // choosing the previous option again would not fire change.
          const value = control.value === selectedLabel ? selectedValue : textValue(control.value);
          if (value === lastValue) return;
          control.restoreChoice(value);
          lastValue = value;
          emit(page, component, "change", { value: lastValue });
        };
        control.addEventListener("input", changed);
        control.addEventListener("change", changed);
        const wrapper = field(page, component, control);
        // Keep an always-visible native option picker beside the editable
        // text. Unlike datalist filtering, this picker offers every choice
        // even when the current entry contains a custom value.
        const row = node("span", "webui-editable-select");
        if (component.props.min_height) row.style.minHeight = `${component.props.min_height}px`;
        if (component.props.control_width) row.style.width = `${component.props.control_width}px`;
        // The character request belongs to the editable entry. Its adjacent
        // picker retains the existing 34px body plus its one-pixel border.
        if (component.props.control_width_chars) {
          row.style.width = `calc(${component.props.control_width_chars} * round(up, 1ch, 1px) + 2 * var(--entry-padding, 8px) + 2px + 35px)`;
        }
        const picker = node("span", "webui-choice-picker");
        const arrow = node("span", null, "\u2304");
        arrow.setAttribute("aria-hidden", "true");
        chooser = node("select");
        chooser.disabled = control.disabled;
        chooser.setAttribute("aria-label", `Choose ${component.props.label || "option"}`);
        component.props.options.forEach(option => {
          const item = node("option", null, option.label); item.value = option.value; chooser.append(item);
        });
        control.restoreChoice(component.props.value);
        chooser.addEventListener("change", () => { control.restoreChoice(chooser.value); changed(); });
        control.style.width = "100%"; control.style.flex = "1";
        control.replaceWith(row);
        picker.append(arrow, chooser); row.append(control, picker);
        wrapper.append(suggestions);
        return wrapper;
      }
      const control = node("select");
      if (component.props.min_height) control.style.minHeight = `${component.props.min_height}px`;
      control.disabled = component.props.disabled === true;
      component.props.options.forEach((option) => {
        const choice = node("option", null, option.label);
        choice.value = option.value;
        choice.selected = option.value === component.props.value;
        control.append(choice);
      });
      if (!Object.prototype.hasOwnProperty.call(component.props, "value")) control.selectedIndex = -1;
      control.addEventListener("change", () => emit(page, component, "change", { value: control.value }));
      return field(page, component, control);
    },
    image(_page, component) {
      const image = common(node("img", "webui-image"), component);
      if (component.props.src) image.src = component.props.src;
      else image.style.visibility = "hidden";
      image.alt = component.props.alt || "";
      const scale = component.props.scale || 1;
      if (scale !== 1) {
        const resize = () => {
          image.style.width = `${(component.props.width ?? image.naturalWidth) * scale}px`;
          image.style.height = `${(component.props.height ?? image.naturalHeight) * scale}px`;
        };
        image.addEventListener("load", resize);
        if (image.complete) resize();
      }
      return image;
    },
    // The existing composite vocabulary serves native maps and creature panels.
    // The outer box reserves scaled space; events use absolute image pixels.
    composite(page, component) {
      const props = component.props;
      const scale = props.scale || 1;
      const wrapper = common(node("div", "webui-composite"), component);
      wrapper.style.width = `${props.width * scale}px`;
      wrapper.style.height = `${props.height * scale}px`;
      const surface = node("div", "composite-surface");
      Object.assign(surface.style, { position: "relative", width: `${props.width}px`, height: `${props.height}px`,
        transformOrigin: "top left", transform: `scale(${scale})` });
      if (props.clip_layers) surface.style.overflow = "hidden";
      const regions = new Map();
      props.layers.forEach(layer => {
        const element = compositeLayer(page, component, layer);
        if (!element) return;
        element.classList.add("composite-layer");
        Object.assign(element.style, { position: "absolute", left: `${layer.x ?? Math.min(layer.x1, layer.x2)}px`,
          top: `${layer.y ?? Math.min(layer.y1, layer.y2)}px` });
        if (layer.kind === "region") regions.set(layer.key, element);
        surface.append(element);
      });
      let dragged = false;
      if (props.surface_events) {
        let drag;
        surface.addEventListener("pointerdown", event => {
          const scroller = surface.closest(".webui-scroll");
          if (event.button !== 0 || event.target.closest("button") || !scroller) return;
          dragged = false;
          drag = { id: event.pointerId, x: event.clientX, y: event.clientY,
            left: scroller.scrollLeft, top: scroller.scrollTop, scroller };
          surface.setPointerCapture?.(event.pointerId);
        });
        surface.addEventListener("pointermove", event => {
          if (!drag || event.pointerId !== drag.id) return;
          const dx = event.clientX - drag.x, dy = event.clientY - drag.y;
          if (!dragged && Math.abs(dx) <= 4 && Math.abs(dy) <= 4) return;
          dragged = true;
          drag.scroller.scrollLeft = drag.left - dx;
          drag.scroller.scrollTop = drag.top - dy;
        });
        const endDrag = event => {
          if (!drag || drag.id !== event.pointerId) return;
          if (surface.hasPointerCapture?.(drag.id)) surface.releasePointerCapture(drag.id);
          drag = null;
          if (event.type === "pointercancel") dragged = false;
        };
        surface.addEventListener("pointerup", endDrag);
        surface.addEventListener("pointercancel", endDrag);
        surface.addEventListener("click", event => {
          if (dragged) { dragged = false; return; }
          emit(page, component, "surface_activate", surfacePayload(event, surface, scale, "primary"));
        });
      }
      if (props.surface_events || props.popup) surface.addEventListener("contextmenu", event => {
        event.preventDefault();
        if (props.context_menu) showContextMenu(page, props.context_menu, event.clientX, event.clientY);
        if (props.popup) {
          const size = props.popup.size || [500, 600];
          window.open(`/?page=${encodeURIComponent(props.popup.page)}`, "_blank", `noopener,width=${size[0]},height=${size[1]}`);
        } else emit(page, component, "surface_activate", surfacePayload(event, surface, scale, "secondary"));
      });
      if (bound(page, component.cid, "zoom")) surface.addEventListener("wheel", event => {
        if (!event.ctrlKey) return;
        event.preventDefault();
        emit(page, component, "zoom", { direction: event.deltaY < 0 ? "in" : "out" });
      }, { passive: false });
      wrapper.append(surface);
      if (props.scroll_origin) {
        const signature = JSON.stringify(props.scroll_origin);
        const origins = page.compositeOrigins ||= new Map();
        if (origins.get(component.cid) !== signature) {
          origins.set(component.cid, signature);
          window.requestAnimationFrame(() => window.requestAnimationFrame(() => {
            const scroller = wrapper.closest?.(".webui-scroll");
            if (scroller) [scroller.scrollLeft, scroller.scrollTop] = props.scroll_origin;
          }));
        }
      }
      if (props.scroll_to) {
        const target = props.layers.find(layer => layer.kind === "region" && layer.key === props.scroll_to);
        const signature = JSON.stringify([props.scroll_to, target?.x1, target?.y1, scale, props.layers.find(layer => layer.kind === "image")?.src]);
        const centers = page.compositeCenters ||= new Map();
        if (centers.get(component.cid) !== signature) {
          centers.set(component.cid, signature);
          // Restore the containing scroll view first, then apply a changed
          // marker target. Ordinary redraws must not undo the user's panning.
          window.requestAnimationFrame(() => window.requestAnimationFrame(() => {
            if (wrapper.isConnected) regions.get(props.scroll_to)?.scrollIntoView?.({ block: "center", inline: "center" });
          }));
        }
      } else page.compositeCenters?.delete(component.cid);
      return wrapper;
    },
    table(page, component) {
      const wrapper = common(node("div", "webui-table-wrap"), component);
      // Filled lists scroll inside their allocation. Their rows must not turn
      // a requested viewport minimum into a content-sized notebook minimum.
      if (component.props.scrollable === false) {
        page.unscrolledTableMinimum = true;
        wrapper.style.overflow = "visible";
        if (component.props.fill) {
          wrapper.style.flex = "1 0 auto";
          wrapper.style.height = "auto";
          wrapper.style.minHeight = "min-content";
        }
      } else if (component.props.fill) wrapper.style.contain = "size";
      if (component.props.border_width !== undefined) wrapper.style.borderWidth = `${component.props.border_width}px`;
      if (component.props.transfer_group && bound(page, component.cid, "row_drop")) {
        wrapper.addEventListener("dragover", event => { event.preventDefault(); event.dataTransfer.dropEffect = "move"; });
        wrapper.addEventListener("drop", event => {
          event.preventDefault();
          try {
            const transfer = JSON.parse(event.dataTransfer.getData("application/x-lich-row"));
            if (transfer.group === component.props.transfer_group && transfer.page === page.address) {
              emit(page, component, "row_drop", { source: transfer.source, row: transfer.row });
            }
          } catch (_) { /* A non-Lich drag has no table operation. */ }
        });
      }
      const table = node("table", "webui-table");
      if (component.props.selection_background) {
        table.style.setProperty("--selection-background", compositeColor(component.props.selection_background));
      }
      if (component.props.wrap === false) table.dataset.wrap = "false";
      if (component.props.grid_lines) table.dataset.gridLines = component.props.grid_lines;
      table.setAttribute("role", "table"); // Headerless lists remain accessible data tables.
      // Column widths are viewer presentation state. Retain them across data
      // refreshes without changing row values or introducing script callbacks.
      const widths = (page.tableWidths ||= new Map());
      const columnWidths = widths.get(component.cid) || new Map();
      widths.set(component.cid, columnWidths);
      const automaticWidths = new Map();
      const boundedWidth = (column, width) => width === undefined ? undefined : Math.max(column.min_width || 0, width);
      const resizable = component.props.columns.some(column => column.resizable);
      const expanding = component.props.columns.some(column => column.expand);
      const allocated = resizable || expanding;
      const cols = new Map();
      if (allocated || component.props.columns.some(column => column.width !== undefined || column.min_width !== undefined)) {
        const colgroup = node("colgroup");
        component.props.columns.forEach(column => {
          const col = node("col");
          cols.set(column.key, col); colgroup.append(col);
          const authored = columnWidths.get(column.key) ?? column.width;
          const width = boundedWidth(column, authored ?? column.min_width);
          if (width > 0 || (!resizable && width === 0)) col.style.width = `${width}px`;
        });
        table.append(colgroup);
      }
      const applyWidths = () => {
        if (!allocated) return;
        const resolved = new Map(component.props.columns.map(column => [column.key,
          boundedWidth(column, columnWidths.get(column.key) ?? (column.width > 0 ? column.width : automaticWidths.get(column.key)))]));
        if ([...resolved.values()].some(width => width === undefined)) return;
        table.style.tableLayout = "fixed";
        table.style.width = `${[...resolved.values()].reduce((sum, width) => sum + width, 0)}px`;
        cols.forEach((col, key) => { col.style.width = `${resolved.get(key)}px`; });
      };
      applyWidths();
      const head = node("thead");
      const header = node("tr");
      const body = node("tbody");
      let sort = component.props.sort;
      const headings = new Map();
      let selected = new Set(component.props.selected || []);
      const expanded = new Set(component.props.expanded || component.props.rows.filter(row => row.expanded).map(row => row.key));
      const children = new Map();
      component.props.rows.forEach(row => {
        const parent = row.parent || null;
        if (!children.has(parent)) children.set(parent, []);
        children.get(parent).push(row);
      });
      const hierarchical = component.props.rows.some(row => row.parent);
      if (hierarchical) table.setAttribute("role", "treegrid");
      if (component.props.selection === "multi") table.setAttribute("aria-multiselectable", "true");
      let visibleRows = [];
      // Search state belongs to this page/viewer, never to the shared model.
      const searches = page.tableSearches ||= new Map();
      const searchStatus = node("span", "webui-table-search");
      searchStatus.setAttribute("role", "status");
      searchStatus.setAttribute("aria-live", "polite");
      const retainedSearch = searches.get(component.cid);
      if (retainedSearch?.text && Date.now() - retainedSearch.time <= 1500) searchStatus.textContent = `Search: ${retainedSearch.text}`;
      if (component.props.search_column) wrapper.append(searchStatus);
      const search = event => {
        if (!component.props.search_column || component.props.disabled || event.ctrlKey || event.metaKey || event.altKey || event.isComposing) return false;
        const previous = searches.get(component.cid) || { text: '', time: 0 };
        let text = Date.now() - previous.time > 1500 ? '' : previous.text;
        if (event.key === 'Escape') text = '';
        else if (event.key === 'Backspace') text = text.slice(0, -1);
        else if (event.key.length === 1 && (event.key !== ' ' || text)) text += event.key;
        else return false;
        event.preventDefault();
        text = text.slice(0, 256);
        searches.set(component.cid, { text, time: Date.now() });
        searchStatus.textContent = text ? `Search: ${text}` : '';
        if (text) {
          const target = visibleRows.find(({ row }) => String(row.cells[component.props.search_column] ?? '').toLocaleLowerCase().startsWith(text.toLocaleLowerCase()));
          if (target) { select(target.row); setCursor(target.row, component.props.search_column); focusRow(target.row.key); }
        }
        return true;
      };
      let anchor = (page.tableAnchors ||= new Map()).get(component.cid);
      const setCursor = (row, column) => {
        const payload = { row: row.key };
        if (column) payload.column = column;
        if (JSON.stringify(component.props.cursor) === JSON.stringify(payload)) return;
        component.props.cursor = payload;
        (page.tableCursors ||= new Map()).set(component.cid, JSON.stringify(payload));
        emit(page, component, "cursor_change", payload);
      };
      const select = (row, event = {}) => {
        if (component.props.selection === "none") return;
        const previous = new Set(selected);
        if (component.props.selection === "multi" && event.shiftKey && visibleRows.some(item => item.row.key === anchor)) {
          const a = visibleRows.findIndex(item => item.row.key === anchor);
          const b = visibleRows.findIndex(item => item.row.key === row.key);
          const range = visibleRows.slice(Math.min(a, b), Math.max(a, b) + 1).map(item => item.row.key);
          selected = new Set(event.ctrlKey || event.metaKey ? [...selected, ...range] : range);
        } else if (component.props.selection === "multi" && (event.ctrlKey || event.metaKey)) {
          if (selected.has(row.key)) selected.delete(row.key); else selected.add(row.key);
          anchor = row.key;
        } else {
          selected = new Set([row.key]); anchor = row.key;
        }
        page.tableAnchors.set(component.cid, anchor);
        // Repeated clicks/search hits must not schedule redundant structural
        // renders that invalidate the following double-click activation.
        if (selected.size === previous.size && [...selected].every(key => previous.has(key))) return;
        component.props.selected = [...selected];
        for (const tr of body.children) tr.setAttribute("aria-selected", String(selected.has(tr.dataset.rowKey)));
        emit(page, component, "selection_change", { rows: [...selected] });
      };
      const focusRow = key => [...body.children].find(tr => tr.dataset.rowKey === key)?.focus();
      const toggle = row => {
        if (expanded.has(row.key)) expanded.delete(row.key); else expanded.add(row.key);
        component.props.expanded = [...expanded];
        drawRows(); focusRow(row.key);
        emit(page, component, "row_toggle", { row: row.key, expanded: expanded.has(row.key) });
      };
      const drawRows = () => {
        body.replaceChildren();
        const compare = (left, right) => {
          const a = left.sort_cells?.[sort.column] ?? left.cells[sort.column];
          const b = right.sort_cells?.[sort.column] ?? right.cells[sort.column];
          const compared = typeof a === "number" && typeof b === "number"
            ? a - b : String(a ?? "").localeCompare(String(b ?? ""), undefined, { numeric: component.props.sort_mode !== "lexical" });
          return sort.direction === "desc" ? -compared : compared;
        };
        // Sorting is sibling-local; a flat global sort would detach children from parents.
        // Model-owned order comes from Ruby and determines GTK paths as well as display order.
        visibleRows = [];
        const visit = (parent, depth) => {
          const peers = [...(children.get(parent) || [])];
          if (sort && component.props.sort_mode !== "model") peers.sort(compare);
          peers.forEach(row => {
            visibleRows.push({ row, depth });
            if (expanded.has(row.key)) visit(row.key, depth + 1);
          });
        };
        visit(null, 0);
        for (const [key, th] of headings) th.setAttribute("aria-sort", sort?.column === key
          ? (sort.direction === "desc" ? "descending" : "ascending") : "none");
        visibleRows.forEach(({ row, depth }, index) => {
          const tr = node("tr");
          tr.dataset.rowKey = row.key;
          if (component.props.row_height) tr.style.height = `${component.props.row_height}px`;
          if (component.props.transfer_group) {
            tr.draggable = true;
            // The table's legacy pointer callback stops bubbling. Keep its row alive
            // across that callback's render until the drag or click is released.
            tr.addEventListener("pointerdown", () => holdPointer(page));
            tr.addEventListener("dragstart", event => {
              page.rowDragging = true;
              holdPointer(page);
              event.dataTransfer.effectAllowed = "move";
              event.dataTransfer.setData("application/x-lich-row", JSON.stringify({
                page: page.address, group: component.props.transfer_group, source: component.cid, row: row.key
              }));
            });
          }
          tr.tabIndex = 0;
          tr.setAttribute("aria-selected", String(selected.has(row.key)));
          if (hierarchical) {
            tr.setAttribute("aria-level", String(depth + 1));
            if (children.has(row.key)) tr.setAttribute("aria-expanded", String(expanded.has(row.key)));
          }
          const activate = event => {
            const payload = { row: row.key };
            const column = event.target.closest("td")?.dataset.columnKey;
            if (column) payload.column = column;
            emit(page, component, "row_activate", payload);
          };
          tr.addEventListener("click", event => {
            select(row, event); setCursor(row, event.target.closest("td")?.dataset.columnKey); tr.focus();
            // Ignore the second click of a double click in single-activation mode.
            if (component.props.activation === "single" && event.detail < 2) activate(event);
          });
          tr.addEventListener("dblclick", event => {
            if (component.props.activation !== "single") activate(event);
          });
          tr.addEventListener("keydown", event => {
            if (event.target !== tr) return;
            if (search(event)) return;
            if (event.key === "Enter") { event.preventDefault(); emit(page, component, "row_activate", { row: row.key, ...(component.props.cursor?.row === row.key && component.props.cursor.column ? { column: component.props.cursor.column } : {}) }); }
            else if (event.key === " ") { event.preventDefault(); select(row, event); setCursor(row); }
            else if (["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) {
              event.preventDefault();
              const targetIndex = event.key === "Home" ? 0 : event.key === "End" ? visibleRows.length - 1 : Math.max(0, Math.min(visibleRows.length - 1, index + (event.key === "ArrowDown" ? 1 : -1)));
              const target = visibleRows[targetIndex].row;
              focusRow(target.key); setCursor(target);
              if (!event.ctrlKey && !event.metaKey) select(target, event);
            } else if (event.key === "ArrowRight" && children.has(row.key)) {
              event.preventDefault();
              if (!expanded.has(row.key)) toggle(row);
              else { const child = children.get(row.key)[0]; focusRow(child.key); setCursor(child); }
            } else if (event.key === "ArrowLeft") {
              event.preventDefault();
              if (expanded.has(row.key)) toggle(row);
              else if (row.parent) { focusRow(row.parent); setCursor(component.props.rows.find(candidate => candidate.key === row.parent)); }
            }
          });
          component.props.columns.forEach((column, columnIndex) => {
            const cell = node("td", null, row.cells[column.key]);
            const cellDisabled = component.props.disabled === true || column.editor?.disabled === true || row.cell_disabled?.includes(column.key) === true;
            if (cellDisabled) cell.setAttribute("aria-disabled", "true");
            cell.dataset.columnKey = column.key;
            cell.style.textAlign = column.align || "start";
            if (column.min_width) cell.style.minWidth = `${column.min_width}px`;
            const foreground = row.cell_foregrounds?.find(entry => entry.column === column.key)?.color;
            if (foreground) cell.style.color = compositeColor(foreground);
            if (column.background && !row.background_disabled?.includes(column.key)) {
              cell.style.backgroundColor = compositeColor(column.background);
              cell.dataset.backgroundFill = "true";
            }
            // Reuse the same literal-cell presentation after edits and Escape.
            const paintCell = () => {
              cell.replaceChildren(); cell.textContent = row.cells[column.key] ?? "";
              if (resizable) cell.title = cell.textContent;
              if (column.editor?.type === "checkbox") {
                const control = node("input"); control.type = "checkbox";
                control.checked = row.cells[column.key] === true;
                control.disabled = cellDisabled || !bound(page, component.cid, "cell_edit");
                control.setAttribute("aria-label", column.label || "Toggle row");
                control.addEventListener("click", event => event.stopPropagation());
                control.addEventListener("change", () => {
                  select(row); setCursor(row, column.key);
                  emit(page, component, "cell_edit", { row: row.key, column: column.key, value: control.checked });
                });
                cell.replaceChildren(control);
              }
              if (hierarchical && columnIndex === 0) {
                cell.style.paddingLeft = `${4 + depth * 18}px`;
                const disclosure = node(children.has(row.key) ? "button" : "span", "webui-tree-disclosure", children.has(row.key) ? (expanded.has(row.key) ? "\u25be" : "\u25b8") : "");
                if (children.has(row.key)) {
                  disclosure.type = "button";
                  disclosure.disabled = component.props.disabled === true;
                  disclosure.setAttribute("aria-label", `${expanded.has(row.key) ? "Collapse" : "Expand"} ${row.cells[column.key] ?? "row"}`);
                  disclosure.addEventListener("click", event => { event.stopPropagation(); toggle(row); });
                }
                cell.prepend(disclosure);
              }
              if (column.color_preview) {
              const swatch = node("span", "webui-cell-swatch");
              swatch.setAttribute("aria-hidden", "true");
              Object.assign(swatch.style, { display: "inline-block", verticalAlign: "middle", marginRight: "10px",
                width: `${column.color_preview.width}px`, height: `${column.color_preview.height}px`,
                backgroundColor: /^#[0-9a-f]{6}$/i.test(String(row.cells[column.key])) ? row.cells[column.key] : "#FFFFFF" });
              // Keep the original literal text beside the bounded color preview.
              cell.replaceChildren(swatch, node("span", null, row.cells[column.key]));
            }
            };
            paintCell();
            if (column.editor && !cellDisabled && column.editor.type !== "checkbox" && bound(page, component.cid, "cell_edit")) {
              cell.tabIndex = 0;
              cell.setAttribute("aria-label", `${column.label}: ${row.cells[column.key] ?? ""}`);
              const edit = () => {
                if (cell.dataset.editing) return;
                cell.dataset.editing = "true";
                page.editingCell = true;
                const definition = column.editor;
                const control = node(definition.type === "select" ? "select" : "input");
                if (definition.type === "select") definition.options.forEach(option => {
                  const item = node("option", null, option.label); item.value = option.value; control.append(item);
                });
                // A saved value can outlive the current choices. GTK keeps its
                // displayed cell until the user picks another value; a native
                // select would otherwise fall back to its first option.
                const initialValue = definition.type === "select" && definition.option_labels
                  ? definition.options.find(option => option.label === row.cells[column.key])?.value ?? row.cells[column.key]
                  : row.cells[column.key];
                const missingSelectValue = definition.type === "select" &&
                  !definition.options.some(option => option.value === initialValue);
                if (missingSelectValue) {
                  const item = node("option", null, row.cells[column.key] ?? "");
                  item.value = row.cells[column.key] ?? "";
                  control.append(item);
                }
                if (definition.type !== "select") control.type = definition.type === "number" ? "number" : definition.type === "checkbox" ? "checkbox" : "text";
                for (const name of ["min", "max", "step"]) if (definition[name] !== undefined) control[name] = definition[name];
                if (definition.max_length) control.maxLength = definition.max_length;
                if (definition.type === "checkbox") control.checked = row.cells[column.key] === true;
                else control.value = initialValue ?? "";
                let finished = false;
                const finish = save => {
                  if (finished) return;
                  finished = true;
                  const value = controlValue(control);
                  const commit = save && !(missingSelectValue && value === initialValue);
                  const displayValue = definition.option_labels ? definition.options.find(option => option.value === value)?.label ?? row.cells[column.key] : value;
                  // Selection or another server update may arrive while the
                  // cell editor owns an unfinished draft. Commit against the
                  // latest generation after releasing that render, once.
                  page.editingCell = false;
                  const deferred = page.deferredRender;
                  page.deferredRender = null;
                  if (commit && deferred) {
                    const pendingRow = findComponent(deferred.tree, component.cid)?.props.rows?.find(item => item.key === row.key);
                    if (pendingRow) pendingRow.cells[column.key] = displayValue;
                  }
                  if (deferred) acceptRender(deferred);
                  if (commit) { row.cells[column.key] = displayValue; emit(page, component, "cell_edit", { row: row.key, column: column.key, value }); }
                  delete cell.dataset.editing;
                  paintCell();
                  cell.setAttribute("aria-label", `${column.label}: ${row.cells[column.key] ?? ""}`);
                };
                control.addEventListener("change", () => finish(true));
                control.addEventListener("blur", () => finish(true));
                control.addEventListener("keydown", event => {
                  event.stopPropagation();
                  if (event.key === "Enter" || event.key === "Escape") { event.preventDefault(); finish(event.key === "Enter"); }
                });
                cell.replaceChildren(control); control.focus();
                if (definition.type === "text") control.select?.();
              };
              cell.addEventListener("click", event => {
                event.stopPropagation();
                // Modifier clicks select a range/set; they must not consume the gesture as editing.
                if (event.ctrlKey || event.metaKey || event.shiftKey) tr.focus(); else edit();
                select(row, event); setCursor(row, column.key);
              });
              cell.addEventListener("dblclick", event => { event.stopPropagation(); edit(); });
              cell.addEventListener("keydown", event => { if (event.key === "Enter" || event.key === "F2") { event.stopPropagation(); event.preventDefault(); edit(); } });
            }
            tr.append(cell);
          });
          body.append(tr);
        });
      };
      component.props.columns.forEach(column => {
        const th = node("th");
        headings.set(column.key, th);
        if (column.min_width) th.style.minWidth = `${column.min_width}px`;
        if (column.tooltip !== undefined) th.title = column.tooltip;
        if (column.activatable) {
          const button = node("button", null, column.label);
          button.type = "button";
          button.disabled = component.props.disabled === true;
          button.addEventListener("click", () => emit(page, component, "column_activate", { column: column.key }));
          th.append(button);
        } else if (component.props.sortable && column.sortable) {
          const button = node("button", null, column.label);
          button.type = "button";
          button.addEventListener("click", () => {
            sort = { column: column.key, direction: sort?.column === column.key && sort.direction === "asc" ? "desc" : "asc" };
            drawRows();
            emit(page, component, "sort_change", sort);
          });
          th.append(button);
        } else if (allocated) th.append(node("span", "webui-column-label", column.label));
        else th.textContent = column.label;
        if (column.resizable) {
          const handle = node("span", "webui-column-resize");
          handle.setAttribute("aria-label", `Resize ${column.label}`);
          handle.setAttribute("role", "separator");
          handle.setAttribute("aria-orientation", "vertical");
          handle.setAttribute("aria-valuemin", String(Math.max(24, column.min_width || 0)));
          handle.setAttribute("aria-valuemax", "65536");
          const updateWidth = () => handle.setAttribute("aria-valuenow", String(Math.round(
            boundedWidth(column, columnWidths.get(column.key) || th.getBoundingClientRect().width || 24))));
          updateWidth();
          window.requestAnimationFrame(() => { if (handle.isConnected) updateWidth(); });
          handle.tabIndex = 0;
          handle.addEventListener("keydown", event => {
            if (!["ArrowLeft", "ArrowRight"].includes(event.key)) return;
            event.preventDefault(); event.stopPropagation();
            headings.forEach((heading, key) => columnWidths.set(key, heading.getBoundingClientRect().width));
            columnWidths.set(column.key, Math.max(24, column.min_width || 0, Math.min(65536,
              columnWidths.get(column.key) + (event.key === "ArrowRight" ? 10 : -10))));
            applyWidths();
            updateWidth();
          });
          let drag = null;
          handle.addEventListener("pointerdown", event => {
            if (event.button !== 0) return;
            event.preventDefault(); event.stopPropagation();
            headings.forEach((heading, key) => columnWidths.set(key, heading.getBoundingClientRect().width));
            drag = { x: event.clientX, width: columnWidths.get(column.key) };
            page.columnDragging = true;
            handle.setPointerCapture?.(event.pointerId);
          });
          handle.addEventListener("pointermove", event => {
            if (!drag) return;
            columnWidths.set(column.key, Math.max(24, column.min_width || 0, Math.min(65536, drag.width + event.clientX - drag.x)));
            applyWidths();
            updateWidth();
          });
          const finish = () => {
            drag = null; page.columnDragging = false;
            if (page.deferredRender) { const pending = page.deferredRender; page.deferredRender = null; acceptRender(pending); }
          };
          handle.addEventListener("pointerup", finish);
          handle.addEventListener("pointercancel", finish);
          handle.addEventListener("lostpointercapture", finish);
          th.append(handle);
        }
        header.append(th);
      });
      head.append(header);
      // Empty captions represent the original headerless spell lists.
      const hasHeaders = component.props.headers !== false && (component.props.headers === true || component.props.columns.some(column => column.label));
      if (hasHeaders) table.append(head);
      table.append(body);
      drawRows();
      wrapper.append(table);
      if (allocated) {
        table.dataset.boundedColumns = "true";
        /**
         * Allocate automatic columns from the visible viewport and header labels,
         * never from the longest cell. Zero is an automatic width. Positive
         * authored widths and viewer-resized widths remain authoritative, even
         * when they require horizontal scrolling. Hidden tabs wait for allocation.
         */
        const allocateColumns = () => {
          if (!wrapper.isConnected || wrapper.clientWidth <= 0) return;
          const available = wrapper.clientWidth;
          const automatic = [];
          let occupied = 0;
          component.props.columns.forEach(column => {
            const fixed = columnWidths.get(column.key) ?? (column.width > 0 ? column.width : undefined);
            if (fixed !== undefined) { occupied += Math.max(column.min_width || 0, fixed); return; }
            const heading = headings.get(column.key);
            const style = heading && window.getComputedStyle(heading);
            const minimum = Math.max(24, column.min_width || 0, heading ? Math.ceil(heading.firstElementChild.getBoundingClientRect().width +
              parseFloat(style.paddingLeft || 0) + parseFloat(style.paddingRight || 0) +
              parseFloat(style.borderLeftWidth || 0) + parseFloat(style.borderRightWidth || 0)) : 24);
            automatic.push([column.key, minimum]);
            occupied += minimum;
          });
          const recipients = expanding ? automatic.filter(([key]) => component.props.columns.find(column => column.key === key).expand) : automatic;
          const extra = recipients.length ? Math.max(0, available - occupied) / recipients.length : 0;
          const recipientKeys = new Set(recipients.map(([key]) => key));
          automatic.forEach(([key, minimum]) => automaticWidths.set(key, minimum + (recipientKeys.has(key) ? extra : 0)));
          applyWidths();
        };
        window.requestAnimationFrame(allocateColumns);
        if (window.ResizeObserver) {
          const observer = new ResizeObserver(allocateColumns);
          observer.observe(wrapper);
          (page.layoutObservers ||= []).push(observer);
        }
      }
      const cursor = component.props.cursor || {};
      const signature = JSON.stringify(cursor);
      const cursors = page.tableCursors ||= new Map();
      if (cursors.get(component.cid) !== signature && cursor.row) {
        (page.tableFocusRequests ||= []).push({ cid: component.cid, ...cursor });
      }
      cursors.set(component.cid, signature);
      return wrapper;
    },
    dialog(page, component) {
      const dialog = common(node("dialog", "webui-dialog"), component);
      dialog.setAttribute("aria-label", component.props.title);
      if (component.props.title && component.props.show_title !== false) dialog.append(node("h2", null, component.props.title));
      if (component.props.body) dialog.append(node("p", null, component.props.body));
      appendChildren(page, component, dialog);
      const actions = node("div", "dialog-actions");
      component.props.buttons.forEach((definition) => {
        const button = node("button", definition.variant || "default", definition.label);
        button.addEventListener("click", () => emit(page, component, "response", { button: definition.id }));
        actions.append(button);
      });
      dialog.append(actions);
      if (component.props.cancel_button) dialog.addEventListener("cancel", event => {
        event.preventDefault();
        emit(page, component, "response", { button: component.props.cancel_button });
      });
      queueMicrotask(() => { if (dialog.isConnected && !dialog.open) dialog.showModal(); });
      return dialog;
    }
  };

  // Adapted from Nisugi's individual DOM style assignments. Native consumers
  // supply validated properties; no markup or CSS source is interpreted.
  function nativeTextStyle(element, props) {
    if (props.font_size !== undefined) element.style.fontSize = `${props.font_size}${props.font_unit || "pt"}`;
    if (props.font_family) element.style.fontFamily = props.font_family;
    if (props.font_style) element.style.fontStyle = props.font_style;
    if (props.foreground) element.style.color = compositeColor(props.foreground);
    if (props.background) element.style.backgroundColor = compositeColor(props.background);
  }

  /** Converts validated RGBA channels or semantic tones to a renderer-owned CSS color. */
  function compositeColor(value) {
    if (value && typeof value === "object" && "r" in value) return `rgba(${value.r}, ${value.g}, ${value.b}, ${value.a})`;
    const tone = typeof value === "string" ? value : value?.tone;
    return ({ neutral: "CanvasText", positive: "#27833e", caution: "#b57900", danger: "#b12a2a" })[tone] || "CanvasText";
  }

  // Reuses the bounded image/label/bar/region model reviewed in lich-5. Unlike
  // its drop-shadow tint, a mask actually colors the requested image pixels.
  function compositeLayer(page, component, layer) {
    if (layer.kind === "rectangle") {
      const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      const rect = document.createElementNS("http://www.w3.org/2000/svg", "rect");
      svg.setAttribute("width", String(layer.w)); svg.setAttribute("height", String(layer.h));
      Object.assign(svg.style, { overflow: "visible", pointerEvents: "none" });
      rect.setAttribute("width", String(layer.w)); rect.setAttribute("height", String(layer.h));
      rect.setAttribute("fill", layer.mode === "fill" ? compositeColor(layer.color) : "none");
      if (layer.mode === "stroke") {
        rect.setAttribute("stroke", compositeColor(layer.color));
        rect.setAttribute("stroke-width", String(layer.line_width || 2));
      }
      svg.append(rect);
      return svg;
    }
    if (layer.kind === "marker") {
      const marker = node("div", "composite-marker");
      Object.assign(marker.style, { width: `${layer.w}px`, height: `${layer.h}px`, pointerEvents: "none" });
      const color = compositeColor(layer.color), line = layer.line_width || 2;
      if (layer.shape === "ring") {
        Object.assign(marker.style, { border: `${line}px solid ${color}`, borderRadius: "50%" });
      } else {
        const length = Math.hypot(layer.w, layer.h), angle = Math.atan2(layer.h, layer.w) * 180 / Math.PI;
        [angle, -angle].forEach(rotation => {
          const stroke = node("div");
          Object.assign(stroke.style, { position: "absolute", left: "50%", top: "50%", width: `${length}px`,
            height: `${line}px`, backgroundColor: color, transform: `translate(-50%, -50%) rotate(${rotation}deg)` });
          marker.append(stroke);
        });
      }
      return marker;
    }
    if (layer.kind === "image") {
      const image = node(layer.tint ? "div" : "img", "composite-image");
      if (layer.tint) {
        // Keep intrinsic image dimensions when a consumer omits w/h.
        const sizing = node("img");
        sizing.src = layer.src;
        sizing.alt = "";
        Object.assign(sizing.style, { opacity: "0", display: "block", width: layer.w === undefined ? "auto" : "100%",
          height: layer.h === undefined ? "auto" : "100%" });
        image.append(sizing);
        image.style.backgroundColor = compositeColor(layer.tint);
        // Multiply the source raster so tint preserves its shading; the mask
        // restores alpha instead of turning the silhouette into a solid color.
        image.style.backgroundImage = `url(${JSON.stringify(layer.src)})`;
        image.style.backgroundSize = "100% 100%";
        image.style.backgroundBlendMode = "multiply";
        image.style.maskImage = `url(${JSON.stringify(layer.mask || layer.src)})`;
        image.style.maskSize = "100% 100%";
      } else {
        image.src = layer.src;
        image.alt = "";
        if (layer.mask) { image.style.maskImage = `url(${JSON.stringify(layer.mask)})`; image.style.maskSize = "100% 100%"; }
      }
      if (layer.w !== undefined) image.style.width = `${layer.w}px`;
      if (layer.h !== undefined) image.style.height = `${layer.h}px`;
      image.style.opacity = String(layer.opacity ?? 1);
      image.style.pointerEvents = "none";
      return image;
    }
    if (layer.kind === "label") {
      const label = node("div", "composite-label", layer.text);
      label.style.color = compositeColor(layer.tone);
      label.style.textAlign = layer.align || "start";
      if (layer.emphasis === "strong") label.style.fontWeight = "bold";
      if (layer.emphasis === "subtle") label.style.opacity = "0.65";
      nativeTextStyle(label, layer);
      if (layer.w !== undefined) label.style.width = `${layer.w}px`;
      if (layer.h !== undefined) {
        label.style.height = `${layer.h}px`;
        label.style.display = "flex";
        label.style.alignItems = "center";
        label.style.justifyContent = { start: "flex-start", center: "center", end: "flex-end" }[layer.align || "start"];
      }
      return label;
    }
    if (layer.kind === "bar") {
      const track = node("div", "composite-bar");
      Object.assign(track.style, { width: `${layer.w}px`, height: `${layer.h}px` });
      const fill = node("div", "composite-bar-fill");
      const vertical = layer.orientation === "vertical";
      Object.assign(fill.style, { position: "absolute", bottom: "0px", left: "0px",
        width: vertical ? "100%" : `${layer.value * 100}%`, height: vertical ? `${layer.value * 100}%` : "100%",
        backgroundColor: compositeColor(layer.tone) });
      track.append(fill);
      return track;
    }
    if (layer.kind === "region") {
      const region = node(layer.activates ? "button" : "div", "composite-region");
      Object.assign(region.style, { width: `${Math.abs(layer.x2 - layer.x1)}px`, height: `${Math.abs(layer.y2 - layer.y1)}px` });
      region.dataset.region = layer.key;
      region.title = layer.label || layer.key;
      if (layer.activates) {
        region.type = "button";
        region.setAttribute("aria-label", layer.label || layer.key);
        region.addEventListener("click", event => {
          if (!event.ctrlKey && !event.shiftKey && !event.altKey && bound(page, component.cid, "region_activate")) {
            event.stopPropagation();
            emit(page, component, "region_activate", { region: layer.key });
          }
        });
      } else region.style.pointerEvents = layer.label ? "auto" : "none";
      return region;
    }
  }

  /** Converts pointer coordinates back to original image pixels and includes an optional region ID. */
  function surfacePayload(event, surface, scale, button) {
    const bounds = surface.getBoundingClientRect();
    const modifiers = ["ctrl", "shift", "alt"].filter(key => event[`${key}Key`]);
    const payload = { x: Math.round((event.clientX - bounds.left) / scale),
      y: Math.round((event.clientY - bounds.top) / scale), button, modifiers };
    const region = event.target.closest?.(".composite-region");
    if (region) payload.region = region.dataset.region;
    return payload;
  }

  /** Names one independent radio-option group within its owning page. */
  function radioGroupName(page, group) {
    return `${page.address}:option:${group}`;
  }

  /** Keeps native and menu radio peers exclusive without touching other groups. */
  function clearRadioPeers(page, selected) {
    const name = radioGroupName(page, selected.menuGroup);
    for (const peer of page.controls.values()) {
      if (peer !== selected && (peer.menuGroup === selected.menuGroup || peer.name === name)) peer.restoreChoice(false);
    }
  }

  /** Menu choices share boolean/radio values and submit the form on activation. */
  function menuChoice(page, component, radio) {
    const button = common(node("button", "webui-menu-choice", component.props.label), component);
    button.type = "button";
    button.setAttribute("role", radio ? "menuitemradio" : "menuitemcheckbox");
    button.setAttribute("aria-label", component.props.label || "");
    button.dataset.indicator = radio ? "radio" : "check";
    button.menuGroup = radio ? component.props.group : null;
    let checked = component.props.checked === true;
    button.choiceValue = () => checked;
    button.restoreChoice = value => {
      checked = value;
      button.setAttribute("aria-checked", String(value));
      button.dataset.checked = String(value);
    };
    button.restoreChoice(checked);
    page.controls.set(component.cid, button);
    button.addEventListener("click", () => {
      const changed = !radio || !checked;
      if (radio) clearRadioPeers(page, button);
      button.restoreChoice(radio || !checked);
      if (changed) emit(page, component, "change", { value: checked });
      emit(page, component, "activate");
    });
    return button;
  }

  const widgetCoordinate = value => Math.max(-65536, Math.min(65536, Math.round(value)));

  /** Measures only the destination's declared children, in contract order. */
  function widgetAllocations(element, component) {
    const origin = element.getBoundingClientRect();
    const children = new Map([...element.querySelectorAll("[data-cid]")].map(child => [child.dataset.cid, child]));
    return (component.children || []).map(child => {
      const rect = children.get(child.cid)?.getBoundingClientRect();
      return { cid: child.cid, y: widgetCoordinate((rect?.top ?? origin.top) - origin.top),
        height: Math.max(0, Math.min(65536, Math.round(rect?.height || 0))) };
    });
  }

  /** Dispatches by contract type, leaving an explicit diagnostic node for unsupported types. */
  function render(page, component) {
    const inherited = page.renderDisabled;
    page.renderDisabled = inherited || component.props.disabled === true;
    if (page.renderDisabled) component = { ...component, props: { ...component.props, disabled: true } };
    try {
      return renderComponent(page, component);
    } finally {
      page.renderDisabled = inherited;
    }
  }

  /** Renders one effective component while recursive children inherit its sensitivity. */
  function renderComponent(page, component) {
    const renderer = renderers[component.type];
    if (!renderer) {
      const error = common(node("div", "renderer-error", `Renderer not implemented: ${component.type}`), component);
      error.dataset.error = "renderer_not_implemented";
      return error;
    }
    const element = renderer(page, component);
    const modifiers = event => (event.shiftKey ? 1 : 0) | (event.ctrlKey ? 4 : 0) | (event.altKey ? 8 : 0);
    // Keep widget transfers in this viewer and generation. Browser text/files
    // never authorize a drop, and nested targets consume only their own surface.
    if (component.props.drag_source && !component.props.disabled) {
      element.draggable = true;
      element.dataset.widgetDragSource = "true";
      element.addEventListener("pointerdown", () => holdPointer(page));
      element.addEventListener("dragstart", event => {
        if (event.target.closest("[data-widget-drag-source]") !== element || !element.isConnected) return;
        event.stopPropagation();
        page.widgetDrag = { source: component.cid, generation: page.generation };
        page.rowDragging = true; // Reuse render deferral through native dragend/drop.
        holdPointer(page);
        event.dataTransfer.effectAllowed = "move";
        event.dataTransfer.setData("application/x-lich-widget", component.cid);
      });
      element.addEventListener("dragend", () => { page.widgetDrag = null; });
    }
    if (component.props.drag_destination && bound(page, component.cid, "widget_drop")) {
      element.dataset.widgetDragDestination = "true";
      const accepts = event => page.widgetDrag?.generation === page.generation && !component.props.disabled &&
        element.isConnected && !element.closest("[hidden],[inert]") && event.target.closest("[data-widget-drag-destination]") === element;
      element.addEventListener("dragover", event => {
        if (!accepts(event)) return;
        event.preventDefault(); event.stopPropagation();
        event.dataTransfer.dropEffect = "move";
      });
      element.addEventListener("drop", event => {
        if (!accepts(event)) return;
        event.preventDefault(); event.stopPropagation();
        const source = page.widgetDrag.source;
        page.widgetDrag = null;
        const origin = element.getBoundingClientRect();
        emit(page, component, "widget_drop", { source, x: widgetCoordinate(event.clientX - origin.left),
          y: widgetCoordinate(event.clientY - origin.top), allocations: widgetAllocations(element, component) });
      });
    }

    if (bound(page, component.cid, "pointer_enter") || bound(page, component.cid, "pointer_leave")) {
      page.hoveredComponents ||= new Set();
      const rememberPointer = event => { page.hoverPointer = { x: event.clientX, y: event.clientY }; };
      element.addEventListener("pointermove", rememberPointer);
      element.addEventListener("pointerenter", event => {
        rememberPointer(event);
        // Suppressed enters must not poison hover tracking when re-enabled.
        if (component.props.disabled || page.element?.hidden) return;
        if (page.hoveredComponents.has(component.cid)) return;
        page.hoveredComponents.add(component.cid);
        emit(page, component, "pointer_enter");
      });
      const leave = event => {
        if (!element.isConnected || page.restoringFocus) return;
        if (event) rememberPointer(event);
        const point = page.hoverPointer;
        if (point && element.contains(document.elementFromPoint(point.x, point.y))) return;
        if (page.hoveredComponents.delete(component.cid)) emit(page, component, "pointer_leave");
      };
      (page.hoverElements ||= new Map()).set(component.cid, { element, leave });
      element.addEventListener("pointerleave", leave);
    }
    if (component.type === "page") {
      if (bound(page, component.cid, "key_press") || bound(page, component.cid, "key_release")) element.tabIndex = 0;
      for (const [native, name] of [["keydown", "key_press"], ["keyup", "key_release"]]) {
        if (!bound(page, component.cid, name)) continue;
        element.addEventListener(native, event => {
          if (event.isComposing) return;
          const keyval = event.key === "Escape" ? 0xff1b : [...event.key].length === 1 ? event.key.codePointAt(0) : null;
          if (keyval !== null) emit(page, component, name, { keyval, state: modifiers(event) });
        });
      }
    }
    if (bound(page, component.cid, "scroll")) {
      element.dataset.scrollSurface = "true";
      element.addEventListener("wheel", event => {
        if (!element.isConnected || event.target.closest("[data-scroll-surface]") !== element || component.props.disabled || element.closest("[hidden],[inert]")) return;
        event.preventDefault(); event.stopPropagation();
        const scale = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? window.innerHeight : 1;
        const pixels = value => Math.max(-65536, Math.min(65536, Math.round(value * scale)));
        queueWheel(page, component, pixels(event.deltaX), pixels(event.deltaY), modifiers(event));
      }, { passive: false });
    }
    if (component.props.pointer_events) {
      const press = (event, clickCount) => {
        if ((component.type === "button" && component.props.disabled) || event.target.closest("[data-pointer-surface]") !== element || event.button > 2) return;
        event.stopPropagation();
        emit(page, component, "pointer_press", { x: Math.round(event.clientX), y: Math.round(event.clientY),
          button: event.button + 1, time: Math.floor(event.timeStamp),
          state: (event.shiftKey ? 1 : 0) | (event.ctrlKey ? 4 : 0) | (event.altKey ? 8 : 0), click_count: clickCount });
      };
      let pressed = null;
      element.addEventListener("pointerdown", event => {
        if (event.target.closest("[data-pointer-surface]") === element && event.button <= 2 &&
            !component.props.disabled && !element.closest("[hidden],[inert]")) {
          pressed = { id: event.pointerId, button: event.button };
          page.pointerRelease = pressed;
          if (bound(page, component.cid, "pointer_release")) holdPointer(page);
        }
        press(event, 1);
      });
      const cancelRelease = () => { pressed = null; };
      element.addEventListener("pointercancel", cancelRelease);
      element.addEventListener("dragstart", cancelRelease);
      element.addEventListener("pointerup", event => {
        const previous = pressed; pressed = null;
        if (!previous || page.pointerRelease !== previous || previous.id !== event.pointerId || previous.button !== event.button || component.props.disabled ||
            element.closest("[hidden],[inert]") || event.target.closest("[data-pointer-surface]") !== element) return;
        if (!bound(page, component.cid, "pointer_release")) return;
        event.stopPropagation();
        try {
          emit(page, component, "pointer_release", { x: Math.round(event.clientX), y: Math.round(event.clientY),
            button: event.button + 1, time: Math.floor(event.timeStamp), state: modifiers(event), click_count: 1 });
        } finally {
          // This handler stops bubbling, so document pointerup cannot release it.
          releasePointers(event);
        }
      });
      element.addEventListener("dblclick", event => press(event, 2));
      element.dataset.pointerSurface = "true";
      element.addEventListener("contextmenu", event => event.preventDefault());
    }
    return element;
  }

  /** Applies accepted viewer-local wheel deltas once, after scroll restoration. */
  function applyScrollRequests(page) {
    page.wheelRequests ||= new Map();
    const live = new Set();
    const visit = component => {
      if (component.props.scroll_request) {
        live.add(component.cid);
        const current = component.props.scroll_request;
        const previous = page.wheelRequests.get(component.cid) || { x: 0, y: 0 };
        const dx = current.x - previous.x, dy = current.y - previous.y;
        page.wheelRequests.set(component.cid, current);
        const element = page.element.querySelector(`[data-cid="${CSS.escape(component.cid)}"]`);
        let target = element;
        while (target && target !== page.element) {
          const style = window.getComputedStyle(target);
          if ((dx && /auto|scroll/.test(style.overflowX) && target.scrollWidth > target.clientWidth) ||
              (dy && /auto|scroll/.test(style.overflowY) && target.scrollHeight > target.clientHeight)) break;
          target = target.parentElement;
        }
        if (target === page.element) target = document.scrollingElement;
        if (target && !element?.closest("[hidden],[inert]")) {
          target.scrollLeft += dx; target.scrollTop += dy;
          if (target.dataset.cid && target.classList.contains("webui-scroll")) {
            (page.scrollOffsets ||= new Map()).set(target.dataset.cid, target.scrollTop);
            (page.horizontalScrollOffsets ||= new Map()).set(target.dataset.cid, target.scrollLeft);
          }
        }
      }
      component.children?.forEach(visit);
    };
    visit(page.tree);
    for (const cid of page.wheelRequests.keys()) if (!live.has(cid)) page.wheelRequests.delete(cid);
  }

  /**
   * Applies page facilities, delegating OS presentation only for the owning root.
   * Native alpha replaces CSS opacity; in-window modals retain their parent's window.
   * @param {Object} page Rendered page state with properties and facility overrides.
   */
  function applyFacilities(page) {
    const facilities = page.facilities || {};
    const presentation = { ...page.windowProps?.presentation, ...facilities.presentation };
    const ownsWindow = !requestedPage || page.address === requestedPage;
    const nativeOpacity = ownsWindow && (window.lichNativeWindow || page.windowPresentation?.opacity);
    page.element.style.opacity = nativeOpacity ? "" : (presentation.opacity ?? "");
    page.element.hidden = presentation.hidden === true;
    // Only the requested root owns the native window. In-window modals retain
    // their parent's title, level and geometry. Browsers have no native bridge.
    if (!requestedPage || page.address === requestedPage) {
      window.lichNativeWindow?.present({ ...presentation, title: page.windowProps.title,
        min_width: page.windowProps.min_width, min_height: page.windowProps.min_height });
    }
    if (facilities.geometry) {
      if (facilities.geometry.width > 0) page.element.style.width = `${facilities.geometry.width}px`;
      if (facilities.geometry.height > 0) page.element.style.minHeight = `${facilities.geometry.height}px`;
    }
    if (facilities.focus && (facilities.focus_revision === undefined || page.focusRevision !== facilities.focus_revision)) {
      const focusRoot = page.element.querySelector(`[data-cid="${CSS.escape(facilities.focus)}"]`);
      const focusTarget = focusRoot?.matches("input, select, button, textarea")
        ? focusRoot
        : focusRoot?.querySelector("input, select, button, textarea");
      if (focusTarget) {
        focusTarget.focus();
        if (document.activeElement === focusTarget) page.focusRevision = facilities.focus_revision;
      }
    }
    if (facilities.announce) {
      announcer.setAttribute("aria-live", facilities.announce.politeness);
      announcer.textContent = facilities.announce.text;
    }
    if (facilities.notify) notify(facilities.notify.text, facilities.notify.level);
  }

  /**
   * Dismisses descendant popovers and clears expanded state when a menu branch closes.
   * @param {Element} menu Ancestor of the branch being dismissed.
   * @param {Object} page Viewer state whose closed panels must not reopen on render.
   */
  function hideSubmenus(menu, page) {
    page.popovers?.forEach((entry, cid) => {
      if (entry.group === menu || menu.contains(entry.group)) page.openPopovers?.delete(cid);
    });
    menu.querySelectorAll?.(".submenu-items").forEach(panel => {
      panel.hidePopover?.();
      panel.style.display = "none";
    });
    menu.querySelectorAll?.(".submenu-trigger").forEach(trigger => trigger.setAttribute("aria-expanded", "false"));
  }

  /** Returns enabled entries in this branch only, excluding hidden nested panels. */
  function menuItems(menu) {
    return [...menu.querySelectorAll("button,input")].filter(item => {
      if (item.disabled || item.closest(".submenu-items,.webui-context-menu") !== menu) return false;
      for (let ancestor = item; ancestor; ancestor = ancestor.parentElement) {
        if (ancestor.hidden || ancestor.inert || ancestor.style.display === "none") return false;
        if (ancestor === menu) break;
      }
      return true;
    });
  }

  /** Moves the branch's single tab stop and focus without activating an entry. */
  function focusMenuItem(menu, index = 0) {
    const items = menuItems(menu);
    if (!items.length) return;
    const selected = items[(index + items.length) % items.length];
    items.forEach(item => { item.tabIndex = item === selected ? 0 : -1; });
    selected.focus();
  }

  /**
   * Installs branch-local roving focus. Native buttons retain Enter/Space clicks;
   * Escape remains owned by the existing page-level dismissal handler.
   * @param {Element} menu Context menu or submenu panel, never its trigger.
   * @param {Function} closeBranch Optional ArrowLeft action returning to the parent.
   */
  function menuNavigation(menu, closeBranch) {
    const entries = [...menu.querySelectorAll("button,input")].filter(item => item.closest(".submenu-items,.webui-context-menu") === menu);
    entries.forEach(item => {
      item.tabIndex = -1;
      if (!item.hasAttribute("role")) item.setAttribute("role", "menuitem");
    });
    menu.addEventListener("keydown", event => {
      if (event.target.closest(".submenu-items,.webui-context-menu") !== menu) return;
      if (event.key === "ArrowLeft" && closeBranch) {
        event.preventDefault();
        event.stopPropagation();
        closeBranch();
        return;
      }
      if (!["ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)) return;
      const items = menuItems(menu);
      if (!items.length) return;
      event.preventDefault();
      event.stopPropagation();
      const current = items.indexOf(document.activeElement);
      const index = event.key === "Home" ? 0 : event.key === "End" ? items.length - 1 :
        current < 0 ? (event.key === "ArrowUp" ? items.length - 1 : 0) : current + (event.key === "ArrowUp" ? -1 : 1);
      focusMenuItem(menu, index);
    });
    menu.addEventListener("focusin", event => {
      if (event.target.closest(".submenu-items,.webui-context-menu") !== menu) return;
      entries.forEach(item => { item.tabIndex = item === event.target ? 0 : -1; });
    });
  }

  /**
   * Captures only the currently visible menu's navigation state for one replacement.
   * Trigger CIDs belong to their submenu containers; ordinary entries use their
   * own CIDs. No draft values or script-owned open state are copied here.
   */
  function captureMenuNavigation(page) {
    for (const [key, menu] of page.contextMenus || []) {
      if (menu.style.display === "none") continue;
      return {
        key, cid: menu.dataset.cid,
        branches: [...menu.querySelectorAll('.submenu-trigger[aria-expanded="true"]')]
          .map(trigger => trigger.parentElement.dataset.cid),
        focus: menu.contains(document.activeElement) ? document.activeElement.closest("[data-cid]")?.dataset.cid : null
      };
    }
    return null;
  }

  /**
   * Restores surviving ancestors before their focused entry. Explicit closure,
   * replacement or disabled/removed branches override the previous navigation.
   * A removed entry falls back to the first enabled item in the deepest surviving
   * branch. Opening uses the normal popover layout without emitting events.
   */
  function restoreMenuNavigation(page, state) {
    if (!state) return;
    const menu = page.contextMenus.get(state.key);
    if (!menu || menu.dataset.cid !== state.cid || menu.style.display === "none") return;
    let branch = menu;
    for (const cid of state.branches) {
      const group = menu.querySelector(`[data-cid="${CSS.escape(cid)}"]`);
      const trigger = group?.querySelector(".submenu-trigger");
      if (!group?.openSubmenu || !menuItems(branch).includes(trigger)) break;
      group.openSubmenu();
      branch = trigger.nextElementSibling;
    }
    if (!state.focus) return;
    const component = menu.querySelector(`[data-cid="${CSS.escape(state.focus)}"]`);
    const target = page.controls.get(state.focus) ||
      (component?.matches("button,input") ? component : component?.querySelector("button,input"));
    const targetBranch = target?.closest(".submenu-items,.webui-context-menu");
    const index = targetBranch && menu.contains(target) ? menuItems(targetBranch).indexOf(target) : -1;
    if (index >= 0) focusMenuItem(targetBranch, index);
    else focusMenuItem(branch);
  }

  /**
   * Captures the origin before page replacement can move focus to document.body.
   * The element supports unchanged DOM; its page-local CID survives later renders.
   */
  function contextMenuFocus(page, element = document.activeElement) {
    const component = page.element?.contains?.(element) ? element.closest("[data-cid]") : null;
    return { element, cid: component?.dataset.cid };
  }

  /** Closes every menu branch and restores the origin in the current page tree. */
  function hideContextMenu(page, notify = true) {
    let dismissed = false;
    page.contextMenus?.forEach(menu => {
      const wasOpen = menu.style.display !== "none";
      dismissed ||= wasOpen;
      hideSubmenus(menu, page);
      menu.style.display = "none";
      if (wasOpen && notify && menu.menuComponent) emit(page, menu.menuComponent, "dismiss");
    });
    page.contextMenuPosition = null;
    if (dismissed && notify) {
      const origin = page.contextMenuReturnFocus;
      const target = origin?.element?.isConnected ? origin.element : origin?.cid &&
        (page.controls.get(origin.cid) || page.element?.querySelector(`[data-cid="${CSS.escape(origin.cid)}"]`));
      if (target && !target.disabled && !target.closest("[hidden],[inert]")) target.focus();
      page.contextMenuReturnFocus = null;
    }
  }

  /** Opens a bounded popup, retaining the origin for focus restoration on dismissal. */
  function showContextMenu(page, key, x, y, returnFocus = contextMenuFocus(page)) {
    if (!page.contextMenuPosition) page.contextMenuReturnFocus = returnFocus;
    hideContextMenu(page, false);
    page.contextMenuPosition = { key, x, y };
    const menu = page.contextMenus?.get(key);
    if (!menu) return;
    menu.style.display = "block";
    menu.style.left = `${Math.max(0, Math.min(x, window.innerWidth - menu.getBoundingClientRect().width))}px`;
    menu.style.top = `${Math.max(0, Math.min(y, window.innerHeight - menu.getBoundingClientRect().height))}px`;
    focusMenuItem(menu);
  }

  document.addEventListener("pointerdown", event => {
    if (!event.target.closest?.(".webui-context-menu")) pages.forEach(hideContextMenu);
    pages.forEach(page => page.popovers?.forEach(entry => {
      if (!entry.group.contains(event.target)) entry.close();
    }));
  });
  document.addEventListener("keydown", event => {
    if (event.key !== "Escape") return;
    pages.forEach(page => {
      page.popovers?.forEach(entry => {
        if (entry.trigger.getAttribute("aria-expanded") === "true") {
          entry.close(); entry.trigger.focus(); event.preventDefault();
        }
      });
      page.contextMenus?.forEach(menu => {
        if (menu.style.display === "none") return;
        // There is one selected branch. Its last expanded trigger is deepest.
        const expanded = [...menu.querySelectorAll('.submenu-trigger[aria-expanded="true"]')].at(-1);
        if (expanded) {
          hideSubmenus(expanded.parentElement, page);
          expanded.focus();
        } else hideContextMenu(page);
        event.preventDefault();
      });
    });
  });
  // A blur can commit an edited cell during a Save button's pointerdown.
  // Preserve that button through pointerup/click before applying the response.
  function holdPointer(page) {
    page.pointerActive = true;
    page.pointerEpoch = (page.pointerEpoch || 0) + 1;
  }
  const releasePointers = event => {
    const endingDrag = ["drop", "dragend", "blur"].includes(event.type);
    const releases = [...pages.values()].map(page => {
      page.pointerRelease = null;
      if (endingDrag) { page.rowDragging = false; page.widgetDrag = null; }
      return [page, page.pointerEpoch || 0];
    });
    window.setTimeout(() => releases.forEach(([page, epoch]) => {
      // Chrome cancels its pointer stream when native HTML dragging takes over.
      // Also ignore a previous gesture's delayed release after a new press.
      if (page.rowDragging || (page.pointerEpoch || 0) !== epoch) return;
      page.pointerActive = false;
      if (!page.editingCell && !page.splitDragging && !page.columnDragging && page.deferredRender) {
        const deferred = page.deferredRender; page.deferredRender = null; acceptRender(deferred);
      }
    }), 0);
  };
  document.addEventListener("pointerup", releasePointers);
  document.addEventListener("pointercancel", releasePointers);
  // Native HTML drags can end without pointerup/cancel. Release the render
  // after drop handlers finish, or after a cancelled drag, without another click.
  document.addEventListener("drop", releasePointers);
  document.addEventListener("dragend", releasePointers);
  window.addEventListener("blur", releasePointers);

  /** Canonicalizes modifier ordering to match registered page accelerator tokens. */
  function acceleratorKey(event) {
    const parts = [];
    if (event.ctrlKey) parts.push("ctrl");
    if (event.altKey) parts.push("alt");
    if (event.shiftKey) parts.push("shift");
    if (event.metaKey) parts.push("meta");
    parts.push(event.key.toLowerCase());
    return parts.join("+");
  }

  document.addEventListener("keydown", (event) => {
    if (event.isComposing || event.repeat) return;
    const key = acceleratorKey(event);
    for (const page of pages.values()) {
      const activeCid = event.target.closest?.("[data-cid]")?.dataset.cid;
      if (activeCid && bound(page, activeCid, "submit")) continue;
      const accelerator = (page.facilities?.accelerators || []).find((item) => item.keys.toLowerCase() === key);
      if (!accelerator) continue;
      const target = page.element?.querySelector(`[data-cid="${CSS.escape(accelerator.target)}"]`);
      // An explicitly registered shortcut may own a keyboard-only action.
      // Ordinary controls inside inactive tabs still cannot receive shortcuts.
      if (!target || target.disabled || (!target.hidden && target.getClientRects().length === 0)) continue;
      event.preventDefault();
      target.click();
      break;
    }
  });

  /**
   * Accepts a current render while preserving local drafts, focus and active gestures.
   * Native-presentation metadata travels with the accepted tree and its facilities.
   * @param {Object} message Server render envelope for an attached page.
   */
  function acceptRender(message) {
    const page = pages.get(message.page);
    if (!page) return;
    if (message.generation < page.generation) return;
    // Keep the active pointer target alive through periodic meter renders.
    // Only the latest tree is retained and applied when the gesture finishes.
    if (page.splitDragging || page.columnDragging || page.editingCell || page.pointerActive || page.rowDragging) {
      if (!page.deferredRender || message.generation > page.deferredRender.generation) page.deferredRender = message;
      return;
    }
    stopWindowGeometry(page);
    // Reuse the draft/base comparison from PR1650, restricted to stable cids.
    // A deliberate server value change wins; unrelated renders preserve typing.
    const edits = [];
    const active = document.activeElement;
    const activeRow = active?.closest?.("tr[data-row-key]");
    const tableFocus = activeRow && page.element?.contains(activeRow) ? {
      cid: activeRow.closest("[data-cid]")?.dataset.cid, row: activeRow.dataset.rowKey,
      column: active.closest("td")?.dataset.columnKey
    } : null;
    const menuState = captureMenuNavigation(page);
    // Preserve an open menu's original target, not its currently focused item.
    // A newly server-opened menu needs the origin before replaceWith detaches it.
    const menuReturnFocus = page.contextMenuPosition ? page.contextMenuReturnFocus : contextMenuFocus(page, active);
    let focus = null;
    for (const [cid, control] of page.controls || []) {
      const base = page.bases?.get(cid);
      if (control === active) focus = { cid, start: control.selectionStart, end: control.selectionEnd };
      const sensitive = control.type === "password" || control.dataset.sensitive === "true";
      const outstanding = [...pending.values()].find(record => record.liveText && record.message.page === page.address && record.message.cid === cid);
      const acknowledged = outstanding && message.input_requests !== undefined &&
        (message.input_requests[cid] || 0) >= outstanding.message.request;
      const live = outstanding && message.input_requests !== undefined && !acknowledged;
      if (live || sensitive || (base !== undefined && controlValue(control) !== base)) {
        edits.push({ cid, base, value: controlValue(control), password: sensitive, live, acknowledged });
      }
    }
    // Plain action buttons are not input values. Retain their exact component
    // identity independently so a redraw cannot swallow the following Enter.
    if (!focus && active?.matches?.('button[data-component-type="button"]') && page.element?.contains(active)) {
      focus = { cid: active.dataset.cid, action: true };
    }
    page.generation = message.generation;
    page.bindings = message.bindings || {};
    page.submissions = message.submissions || {};
    page.facilities = message.facilities || {};
    page.windowPresentation = message.window_presentation || {};
    page.resume = message.resume;
    page.tree = message.tree;
    if (page.hoveredComponents) {
      for (const cid of page.hoveredComponents) if (!findComponent(page.tree, cid)) page.hoveredComponents.delete(cid);
    }
    page.hoverElements = new Map();
    page.controls = new Map();
    page.unscrolledTableMinimum = false;
    page.contextMenus = new Map();
    page.popovers = new Map();
    page.tableFocusRequests = [];
    page.layoutObservers?.forEach(observer => observer.disconnect());
    page.layoutObservers = [];
    page.inputDisposers?.forEach(dispose => dispose());
    page.inputDisposers = [];
    const next = render(page, message.tree);
    next.dataset.pageAddress = page.address;
    // Chrome blurs the old textarea during replacement, before focus is restored.
    // That redraw is not a user focus-out; suppress only this mechanical blur.
    const previousRestoringFocus = page.restoringFocus;
    page.restoringFocus = true;
    try {
      if (page.element) page.element.replaceWith(next); else pagesNode.append(next);
    } finally { page.restoringFocus = previousRestoringFocus; }
    page.element = next;
    const hoverElements = page.hoverElements;
    window.requestAnimationFrame(() => {
      if (page.hoverElements !== hoverElements) return;
      hoverElements?.forEach(({ element, leave }, cid) => {
        if (page.hoveredComponents?.has(cid)) leave();
      });
    });
    page.openPopovers?.forEach(cid => {
      const entry = page.popovers.get(cid);
      if (entry && !entry.trigger.disabled && !entry.group.closest("[hidden],[inert]")) entry.open();
      else page.openPopovers.delete(cid);
    });
    equalizeWidthGroups(page);
    const requestedMenu = [...page.contextMenus.entries()].find(([, menu]) => menu.menuComponent?.props.open === true);
    if (requestedMenu) {
      const [key, menu] = requestedMenu;
      const [x, y] = menu.menuComponent.props.popup_position || [0, 0];
      showContextMenu(page, key, x, y, menuReturnFocus);
    } else if (page.contextMenuPosition) {
      const { key, x, y } = page.contextMenuPosition;
      const menu = page.contextMenus.get(key);
      if (menu && menu.menuComponent?.props.open === undefined) showContextMenu(page, key, x, y, menuReturnFocus);
      else page.contextMenuPosition = null;
    }
    trackPageGeometry(page, message.tree);
    trackWindowState(page, message.tree);
    page.bases = new Map([...page.controls].filter(([, control]) => control.dataset.sensitive !== "true")
      .map(([cid, control]) => [cid, controlValue(control)]));
    for (const edit of edits) {
      const control = page.controls.get(edit.cid);
      if (!control || edit.acknowledged || (!edit.live && !edit.password && page.bases.get(edit.cid) !== edit.base)) continue;
      if (edit.live && (control.disabled || control.closest("[hidden],[inert]"))) continue;
      if (control.type === "checkbox") control.checked = edit.value;
      else if (control.restoreChoice) control.restoreChoice(edit.value);
      else control.value = edit.value;
    }
    discardPending(record => record.liveText && record.message.page === page.address &&
      (!page.controls.has(record.message.cid) || (message.input_requests?.[record.message.cid] || 0) >= record.message.request));
    restoreMenuNavigation(page, menuState);
    // Resolve table focus by identities after replacement, never by a stale row index.
    if (!requestedMenu && !menuState?.focus) {
      const target = page.tableFocusRequests.at(-1) || tableFocus;
      if (target) {
        const wrapper = [...page.element.querySelectorAll(".webui-table-wrap")].find(element => element.dataset.cid === target.cid);
        const row = [...(wrapper?.querySelectorAll("tr[data-row-key]") || [])].find(element => element.dataset.rowKey === target.row);
        const cell = target.column && [...(row?.children || [])].find(element => element.dataset.columnKey === target.column);
        if (row && !wrapper.inert) {
          const focusable = cell?.querySelector("input,select") || row;
          if (!focusable.disabled) { focusable.focus(); if (page.tableFocusRequests.length) row.scrollIntoView?.({ block: "nearest" }); }
        }
      }
    }
    // Menu restoration also covers triggers and plain action buttons, which do
    // not appear in the form-control map. Never refocus a now-closed menu input.
    const focused = !menuState?.focus && focus && (focus.action
      ? [...page.element.querySelectorAll('button[data-component-type="button"]')].find(button => button.dataset.cid === focus.cid)
      : page.controls.get(focus.cid));
    if (focused && !focused.disabled && !focused.closest("[hidden],[inert]") &&
        (!requestedMenu || focused.closest(".webui-context-menu"))) {
      page.restoringFocus = true;
      try {
        focused.focus({ preventScroll: true });
        if (Number.isInteger(focus.start)) focused.setSelectionRange(focus.start, focus.end);
      } finally { page.restoringFocus = false; }
    }
    applyFacilities(page);
    const scrollRoot = page.element;
    window.requestAnimationFrame(() => {
      if (page.element === scrollRoot) applyScrollRequests(page);
    });
    for (const [request, record] of pending) {
      if (!record.replay || record.message.page !== page.address) continue;
      dropPending(request);
      const component = findComponent(page.tree, record.message.cid);
      const scope = page.submissions[record.message.cid] || [];
      if (!component || component.props.disabled || component.props.hidden ||
          JSON.stringify(scope) !== JSON.stringify(record.scope)) continue;
      let payload = record.message.payload;
      if (record.message.event === "widget_drop") {
        const source = findComponent(page.tree, payload.source);
        const ids = (component.children || []).map(child => child.cid);
        if (!component.props.drag_destination || !source?.props.drag_source || source.props.drag_source !== record.dragSourceKey ||
            source.props.disabled || source.props.hidden || JSON.stringify(ids) !== JSON.stringify(payload.allocations.map(child => child.cid))) continue;
        const element = [...page.element.querySelectorAll("[data-cid]")].find(child => child.dataset.cid === component.cid);
        if (!element || element.closest("[hidden],[inert]")) continue;
        // Retry the insertion intent, not old pixel measurements. A changed
        // child set/order retires the drop instead of moving a different item.
        let index = payload.allocations.findIndex(child => payload.y < child.y + child.height / 2);
        if (index < 0) index = ids.length;
        const allocations = widgetAllocations(element, component);
        const y = index < allocations.length ? Math.ceil(allocations[index].y + allocations[index].height / 2) - 1 :
          allocations.length ? allocations.at(-1).y + allocations.at(-1).height : 0;
        payload = { ...payload, y: widgetCoordinate(y), allocations };
      }
      emit(page, component, record.message.event, payload, record);
    }
  }

  /** Displays a literal, temporary status notice without interpreting message markup. */
  function notify(text, level = "info") {
    const message = node("div", `notification ${level}`, text);
    notifications.append(message);
    window.setTimeout(() => message.remove(), 5000);
  }

  /**
   * Routes server envelopes, keeping page selection and modal routing within this window.
   * A stale-event retry requires matching request/page/control/event correlation; other
   * refusals do not replay user actions. The server still validates all routing authority.
   */
  function receive(event) {
    const message = JSON.parse(event.data);
    if (message.type === "hello" || message.type === "pages") {
      if (message.type === "hello" && message.limits) wireLimits = message.limits;
      statusNode.textContent = "Connected";
      message.pages.forEach((descriptor) => {
        if (requestedPage && descriptor.address !== requestedPage &&
            !descriptor.modal_for?.includes(requestedPage)) return;
        if (descriptor.title && (!requestedPage || descriptor.address === requestedPage)) document.title = descriptor.title;
        const page = pages.get(descriptor.address) || { address: descriptor.address };
        pages.set(descriptor.address, page);
        // Opening or closing a modal announces the page list again. Resuming a
        // live attachment is refused by the core and must not reset its drafts.
        if (message.type === "pages" && page.attaching) return;
        page.attaching = true;
        socket.send(JSON.stringify({ type: "attach", page: descriptor.address, version: VERSION, resume: page.resume }));
      });
    } else if (message.type === "render") acceptRender(message);
    else if (message.type === "clear_sensitive") {
      discardPending(record => record.scope.some(cid => message.cids.includes(cid)));
      pages.forEach((page) => message.cids.forEach((cid) => {
        const control = page.controls?.get(cid); if (control) control.value = "";
        page.bases?.delete(cid);
      }));
    }
    else if (message.type === "page_closed") {
      discardPending(record => record.message.page === message.page);
      pages.get(message.page)?.layoutObservers?.forEach(observer => observer.disconnect());
      pages.get(message.page)?.inputDisposers?.forEach(dispose => dispose());
      if (pages.has(message.page)) {
        clearWheel(pages.get(message.page));
        stopWindowGeometry(pages.get(message.page));
        stopWindowState(pages.get(message.page));
      }
      pages.get(message.page)?.element?.remove();
      pages.delete(message.page);
    } else if (message.type === "refusal") {
      if (message.reason === "stale_generation" && message.event === "scrolled") {
        pages.get(message.page)?.scrollMeasurements?.delete(message.cid);
      }
      const record = pending.get(message.request);
      const matches = record && ["page", "cid", "event"].every(key => record.message[key] === message[key]);
      // A superseded/acknowledged edit no longer has retry authority or a
      // user-visible failure. Only a still-correlated intent may report staleness.
      if (message.reason === "stale_generation" && !matches) return;
      if (message.reason === "stale_generation" && matches && record.attempt === 0) {
        record.replay = true;
      } else {
        if (matches) dropPending(message.request);
        if (!(message.reason === "stale_generation" && message.event === "scrolled")) {
          notify(message.message || "Request refused", "error");
        }
      }
    }
  }

  /** Reconnects the authenticated same-origin socket with bounded backoff and clears old retries. */
  function connect() {
    const scheme = window.location.protocol === "https:" ? "wss:" : "ws:";
    socket = new WebSocket(`${scheme}//${window.location.host}/ws`);
    socket.addEventListener("open", () => { reconnectDelay = 250; });
    socket.addEventListener("message", receive);
    socket.addEventListener("close", () => {
      discardPending(() => true);
      pages.forEach(clearWheel);
      statusNode.textContent = "Disconnected; reconnecting";
      window.setTimeout(connect, reconnectDelay);
      reconnectDelay = Math.min(5000, reconnectDelay * 2);
    });
    socket.addEventListener("error", () => socket.close());
  }

  /** Sends intentional detach with final geometry; transport loss alone remains resumable. */
  function detachPages() {
    if (!socket || socket.readyState !== WebSocket.OPEN) return;
    pages.forEach((page) => {
      flushWheel(page);
      page.splitDragging = false;
      page.editingCell = false;
      page.pointerActive = false;
      page.rowDragging = false;
      if (page.deferredRender) { const deferred = page.deferredRender; page.deferredRender = null; acceptRender(deferred); }
      if (!Number.isInteger(page.generation)) return;
      page.reportGeometry?.();
      socket.send(JSON.stringify({
        type: "detach", page: page.address, generation: page.generation,
        ...(!requestedPage || page.address === requestedPage ? { geometry: JSON.parse(windowGeometry(true)) } : {})
      }));
    });
  }

  // A dedicated launcher window owns its Ruby startup session. Tell the
  // server that this is an intentional page close before Chrome tears down
  // the WebSocket; transport-only disconnects retain their resume semantics.
  window.addEventListener("pagehide", detachPages);

  window.LichWebUI = Object.freeze({ VERSION, renderers, render });
  connect();
})();
