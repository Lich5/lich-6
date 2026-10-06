(() => {
  "use strict";

  const VERSION = "2.9.0";
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

  function discardPending(predicate) {
    for (const [request, record] of pending) if (predicate(record)) dropPending(request);
  }

  function findComponent(component, cid) {
    if (component.cid === cid) return component;
    for (const child of component.children || []) {
      const found = findComponent(child, cid);
      if (found) return found;
    }
  }

  function windowGeometry(content) {
    return JSON.stringify({
      width: content ? window.innerWidth : window.outerWidth,
      height: content ? window.innerHeight : window.outerHeight,
      position: [window.screenX, window.screenY]
    });
  }

  function stopWindowGeometry(page) {
    window.clearInterval(page.geometryTimer);
    if (page.reportGeometry) window.removeEventListener("resize", page.reportGeometry);
    page.reportGeometry = null;
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

  function trackPageGeometry(page, component) {
    if (requestedPage && page.address !== requestedPage) return;
    if (!bound(page, component.cid, "configure")) return;
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
      const payload = { width: Math.round(window.innerWidth), height: Math.round(window.innerHeight),
        position: [Math.round(window.screenX), Math.round(window.screenY)] };
      const signature = JSON.stringify(payload);
      if (signature === page.lastPageGeometry) return;
      page.lastPageGeometry = signature;
      emit(page, component, "configure", payload);
    };
    window.addEventListener("resize", page.reportGeometry);
    page.geometryTimer = window.setInterval(page.reportGeometry, 250);
    window.requestAnimationFrame(() => {
      if (!page.element?.isConnected) return;
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
      }
      // Preserve user geometry unless newly added unscrolled contents need
      // more room. Host refusals are deduplicated by the measurement above.
      page.reportGeometry?.(page.unscrolledTableMinimum ? { type: "resize" } : undefined);
    });
  }

  function node(tag, className, text) {
    const result = document.createElement(tag);
    if (className) result.className = className;
    if (text !== undefined) result.textContent = String(text);
    return result;
  }

  function common(element, component) {
    const props = component.props || {};
    element.dataset.cid = component.cid;
    element.dataset.componentType = component.type;
    element.hidden = props.hidden === true;
    if ("disabled" in element) element.disabled = props.disabled === true;
    if (props.tooltip) element.title = props.tooltip;
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

  function bound(page, cid, event) {
    return (page.bindings[cid] || []).includes(event);
  }

  function controlValue(control) {
    if (!control) return null;
    if (control.choiceValue) return control.choiceValue();
    if (control.type === "checkbox") return control.checked;
    if (control.type === "number" || control.type === "range") return control.valueAsNumber;
    return control.value;
  }

  function emit(page, component, event, payload = {}, previous = null) {
    if (!socket || socket.readyState !== WebSocket.OPEN || !bound(page, component.cid, event)) return;
    const message = {
      type: "event", page: page.address, cid: component.cid, event,
      generation: page.generation, payload, request: ++nextRequest
    };
    const scope = page.submissions[component.cid];
    if (scope && ["activate", "submit", "response", "row_activate", "region_activate", "surface_activate"].includes(event)) {
      message.submission = previous ? previous.message.submission : scope.map((cid) => controlValue(page.controls.get(cid)));
      // A submitted draft becomes the comparison baseline. Otherwise a server
      // clearing an initially empty field looks like an unrelated redraw and
      // the client restores the just-submitted text (sbounty's Create form).
      scope.forEach((cid, index) => {
        const control = page.controls.get(cid);
        if (control && control.type !== "password" && control.dataset?.sensitive !== "true") {
          page.bases?.set(cid, message.submission[index]);
        }
      });
    }
    // Scroll is a fresh measurement, not replayable user intent.
    if (event !== "scrolled") {
      while (pending.size >= 256) dropPending(pending.keys().next().value);
      const record = { message: JSON.parse(JSON.stringify(message)), scope: scope ? [...scope] : [],
        attempt: previous ? previous.attempt + 1 : 0, replay: false };
      record.timer = window.setTimeout(() => dropPending(message.request), 30000);
      pending.set(message.request, record);
    }
    socket.send(JSON.stringify(message));
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
      const shorten = count => parts.slice(0, Math.ceil(count / 2)).join("") + "…" +
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
    page(page, component) {
      const root = common(node("section", "webui-page"), component);
      if (!requestedPage || page.address === requestedPage) document.title = component.props.title;
      root.classList.toggle("webui-page-bare", component.props.bare === true);
      if (component.props.theme) root.dataset.theme = component.props.theme;
      if (component.props.density) root.dataset.density = component.props.density;
      if (component.props.viewport) root.dataset.viewport = "true";
      root.addEventListener("pointerdown", () => { page.pointerActive = true; });
      if (!component.props.bare) root.append(node("h1", null, component.props.title));
      return appendChildren(page, component, root);
    },
    group(page, component) {
      if (component.props.menu) {
        const submenu = component.props.menu === "submenu";
        const group = common(node("div", submenu ? "webui-submenu" : "webui-context-menu"), component);
        group.setAttribute("role", "menu");
        if (submenu) {
          const trigger = node("button", "submenu-trigger", component.props.label);
          trigger.setAttribute("aria-haspopup", "menu");
          const panel = node("div", "submenu-items");
          panel.style.display = "none";
          const open = () => {
            panel.style.display = "block";
            const anchor = trigger.getBoundingClientRect(), bounds = panel.getBoundingClientRect();
            panel.style.left = `${Math.max(0, anchor.right + bounds.width > window.innerWidth ? anchor.left - bounds.width : anchor.right)}px`;
            panel.style.top = `${Math.max(0, Math.min(anchor.top, window.innerHeight - bounds.height))}px`;
            trigger.setAttribute("aria-expanded", "true");
          };
          group.addEventListener("pointerenter", open);
          group.addEventListener("pointerleave", () => { panel.style.display = "none"; trigger.setAttribute("aria-expanded", "false"); });
          trigger.addEventListener("click", event => { event.stopPropagation(); open(); });
          trigger.addEventListener("keydown", event => { if (event.key === "ArrowRight") { event.preventDefault(); open(); panel.querySelector?.("button,input")?.focus(); } });
          group.append(trigger, appendChildren(page, component, panel));
          return group;
        } else {
          (page.contextMenus ||= new Map()).set(component.props.key, group);
          group.style.display = "none";
          group.addEventListener("click", event => {
            if (event.target.closest?.("button,input") && !event.target.closest?.(".submenu-trigger")) hideContextMenu(page);
          });
        }
        return appendChildren(page, component, group);
      }
      const group = common(node("fieldset", "webui-group"), component);
      if (["start", "center", "end"].includes(component.props.align)) group.style.justifySelf = component.props.align;
      if (component.props.constrain_width) group.style.maxWidth = "100%";
      if (component.props.min_width === undefined && component.props.width === undefined && !component.props.constrain_width &&
          component.children?.some(child => child.type === "grid" && child.props.homogeneous === false)) {
        // Keep a natural grid inside its frame, including when the frame lives
        // in a scrollable stack. Explicit constraints still win; grid scrollers
        // remain bounded by inline-size containment rather than long row text.
        group.style.minWidth = "min-content";
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
      return appendChildren(page, component, stack);
    },
    columns(page, component) {
      const columns = common(node("div", "webui-columns"), component);
      if (component.props.compact) columns.dataset.compact = "true";
      if (component.props.row_align) columns.style.alignItems = component.props.row_align;
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
      grid.style.gap = `${component.props.gap ?? 8}px`;
      if (component.props.row_gap !== undefined) grid.style.rowGap = `${component.props.row_gap}px`;
      if (component.props.column_gap !== undefined) grid.style.columnGap = `${component.props.column_gap}px`;
      (component.children || []).forEach((child) => {
        const cell = render(page, child);
        const placement = child.placement || {};
        cell.style.gridColumn = `${placement.column ? placement.column + " / " : ""}span ${placement.span ?? 1}`;
        cell.style.gridRow = `${placement.row ? placement.row + " / " : ""}span ${placement.row_span ?? 1}`;
        if (child.props.align) cell.style.justifySelf = child.props.align;
        if (["scroll", "table"].includes(child.type) && child.props.width === undefined) {
          // A scroller consumes its grid allocation; its longest row must not
          // enlarge max-content tracks spanned by the scrolling viewport.
          // Leave width auto so grid stretching subtracts the source margins.
          cell.style.contain = "inline-size";
          if (child.props.min_width === undefined) cell.style.minWidth = "0px";
        }
        if (component.props.homogeneous === false && !(component.props.expand_columns || []).length &&
            child.props.inline && ["text_input", "number_input", "select"].includes(child.type) &&
            child.props.min_width === undefined && !child.props.max_width_chars) {
          // Keep an inline label and control together without imposing the same
          // minimum on scrollable peers or explicitly capped entry fields.
          cell.style.minWidth = "max-content";
        }
        grid.append(cell);
      });
      if (component.props.row_sizing === "spread") spreadGridRows(page, component, grid);
      return grid;
    },
    // alias/vars use vertical adjustments. Retain offsets locally across tree
    // replacement and report actual layout measurements only when they change.
    scroll(page, component) {
      const element = common(node("div", "webui-scroll"), component);
      element.style.overflow = "auto";
      if (component.props.fill) { element.style.flex = "1"; element.style.minHeight = "0"; element.style.height = "0px"; }
      if (component.props.scrollbars === false) element.style.scrollbarWidth = "none";
      appendChildren(page, component, element);
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
        tabs.style.gridTemplateRows = "max-content minmax(min-content, 1fr)";
      }
      if (component.cid.includes("saved-account-tabs")) tabs.classList.add("account-tabs-left");
      else if (component.cid.includes("account")) tabs.classList.add("nested");
      const list = node("div", "tab-list");
      list.setAttribute("role", "tablist");
      const selected = component.props.selected ?? 0;
      component.props.names.forEach((name, index) => {
        const button = node("button", null, name);
        button.type = "button";
        button.setAttribute("role", "tab");
        button.setAttribute("aria-selected", String(index === selected));
        button.addEventListener("click", () => emit(page, component, "select", { index }));
        list.append(button);
      });
      tabs.append(list);
      (component.children || []).forEach((child, index) => {
        const panel = render(page, child);
        panel.classList.add("tab-panel");
        panel.setAttribute("role", "tabpanel");
        panel.hidden = index !== selected;
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
      overlay.style.display = "grid";
      appendChildren(page, component, overlay);
      for (const child of overlay.children) child.style.gridArea = "1 / 1";
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
      log.style.whiteSpace = "pre-wrap";
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
      const content = component.props.fragments ? component.props.fragments.join("") : component.props.content;
      const text = common(node("div", "webui-text", content), component);
      text.style.whiteSpace = component.props.wrap === false ? "pre" : "pre-wrap";
      nativeTextStyle(text, component.props);
      if (component.props.min_width_chars) {
        const minimum = `calc(${component.props.min_width_chars} * round(up, 1ch, 1px))`;
        text.style.minWidth = text.style.minWidth ? `max(${text.style.minWidth}, ${minimum})` : minimum;
      }
      if (component.props.max_width_chars) text.style.maxWidth = `${component.props.max_width_chars}ch`;
      if (component.props.ellipsize === "middle") middleEllipsis(page, text, content, component.props);
      return text;
    },
    markdown(_page, component) {
      // Setup labels use Markdown links in place of GTK's label anchors.
      // Build text nodes and HTTP(S) anchors; never interpret supplied HTML.
      const wrapper = common(node("div", "webui-markdown"), component);
      wrapper.style.whiteSpace = "pre-wrap";
      const content = component.props.content;
      const links = /\[([^\]]+)\]\((https?:\/\/(?:[^\s()]|\([^\s()]*\))+)\)/g;
      let offset = 0;
      for (const match of content.matchAll(links)) {
        wrapper.append(node("span", null, content.slice(offset, match.index)));
        const link = node("a", null, match[1]);
        link.href = match[2];
        link.target = "_blank";
        link.rel = "noopener noreferrer";
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
        wrapper.classList.add("webui-progress-colored");
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
    toggle(page, component) { return renderers.checkbox(page, component); },
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
      control.disabled = component.props.disabled === true;
      if (component.props.max_length) control.maxLength = component.props.max_length;
      control.addEventListener("input", () => emit(page, component, "change", { value: control.value }));
      return field(page, component, control);
    },
    text_input(page, component) {
      const control = input(page, component, component.props.search ? "search" : "text");
      markNaturalEntry(control, component.props);
      control.value = component.props.value;
      let lastValue = control.value;
      const changed = () => {
        if (control.value === lastValue) return;
        lastValue = control.value;
        emit(page, component, "change", { value: lastValue });
      };
      if (component.props.change_mode === "input") control.addEventListener("input", changed);
      control.addEventListener("change", changed);
      control.addEventListener("focus", () => {
        if (!page.restoringFocus) emit(page, component, "focus");
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
    number_input(page, component) {
      const control = input(page, component, "number");
      for (const name of ["min", "max", "step", "value"]) control[name] = component.props[name] ?? 1;
      let lastValue = control.valueAsNumber;
      const changed = () => {
        if (Number.isFinite(control.valueAsNumber) && control.checkValidity() && control.valueAsNumber !== lastValue) {
          lastValue = control.valueAsNumber;
          emit(page, component, "change", { value: lastValue });
        }
      };
      control.addEventListener("input", changed);
      control.addEventListener("change", changed);
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
        [-1, 1].forEach(direction => {
          const button = node("button", null, direction < 0 ? "−" : "+");
          button.type = "button";
          button.disabled = control.disabled;
          button.setAttribute("aria-label", direction < 0 ? "Decrease" : "Increase");
          button.addEventListener("click", () => {
            if (direction < 0) control.stepDown(); else control.stepUp();
            changed();
          });
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
        control.restoreChoice = value => {
          // An absent value is unselected; an explicit empty ID can name an option.
          selectedValue = value;
          selectedLabel = value == null ? "" : (component.props.options.find(option => option.value === value)?.label ?? value);
          control.value = selectedLabel;
          if (chooser) {
            if (value == null) chooser.selectedIndex = -1;
            else chooser.value = value;
          }
        };
        control.choiceValue = () => control.value === selectedLabel ? (selectedValue ?? "") : control.value;
        control.restoreChoice(component.props.value);
        control.maxLength = 8192;
        const suggestions = node("datalist");
        suggestions.id = `choices-${component.cid}`;
        control.setAttribute("list", suggestions.id);
        component.props.options.forEach(option => {
          const choice = node("option", null, option.label);
          choice.value = option.value;
          suggestions.append(choice);
        });
        let lastValue = selectedValue;
        const changed = () => {
          // A custom entry clears the native picker's selection. Otherwise
          // choosing the previous option again would not fire change.
          const value = control.value === selectedLabel ? selectedValue : control.value;
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
        const arrow = node("span", null, "⌄");
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
      image.src = component.props.src;
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
      if (component.props.wrap === false) table.dataset.wrap = "false";
      if (component.props.grid_lines) table.dataset.gridLines = component.props.grid_lines;
      table.setAttribute("role", "table"); // Headerless lists remain accessible data tables.
      // Column widths are viewer presentation state. Retain them across data
      // refreshes without changing row values or introducing script callbacks.
      const widths = (page.tableWidths ||= new Map());
      const columnWidths = widths.get(component.cid) || new Map();
      widths.set(component.cid, columnWidths);
      const cols = new Map();
      if (component.props.columns.some(column => column.resizable || column.width !== undefined)) {
        const colgroup = node("colgroup");
        component.props.columns.forEach(column => {
          const col = node("col");
          cols.set(column.key, col); colgroup.append(col);
          const width = columnWidths.get(column.key) ?? column.width;
          if (width !== undefined) col.style.width = `${width}px`;
        });
        table.append(colgroup);
      }
      const applyWidths = () => {
        if (!component.props.columns.every(column => columnWidths.has(column.key))) return;
        table.style.tableLayout = "fixed";
        table.style.width = `${component.props.columns.reduce((sum, column) => sum + columnWidths.get(column.key), 0)}px`;
        cols.forEach((col, key) => { col.style.width = `${columnWidths.get(key)}px`; });
      };
      applyWidths();
      const head = node("thead");
      const header = node("tr");
      const body = node("tbody");
      let sort = component.props.sort;
      const headings = new Map();
      const select = row => {
        if (component.props.selection === "none") return;
        for (const tr of body.children) tr.setAttribute("aria-selected", String(tr.dataset.rowKey === row.key));
        emit(page, component, "selection_change", { rows: [row.key] });
      };
      const drawRows = () => {
        body.replaceChildren();
        const rows = [...component.props.rows];
        if (sort) rows.sort((left, right) => {
          const a = left.sort_cells?.[sort.column] ?? left.cells[sort.column];
          const b = right.sort_cells?.[sort.column] ?? right.cells[sort.column];
          const compared = typeof a === "number" && typeof b === "number"
            ? a - b : String(a ?? "").localeCompare(String(b ?? ""), undefined, { numeric: component.props.sort_mode !== "lexical" });
          return sort.direction === "desc" ? -compared : compared;
        });
        for (const [key, th] of headings) th.setAttribute("aria-sort", sort?.column === key
          ? (sort.direction === "desc" ? "descending" : "ascending") : "none");
        rows.forEach(row => {
          const tr = node("tr");
          tr.dataset.rowKey = row.key;
          if (component.props.row_height) tr.style.height = `${component.props.row_height}px`;
          if (component.props.transfer_group) {
            tr.draggable = true;
            tr.addEventListener("dragstart", event => {
              event.dataTransfer.effectAllowed = "move";
              event.dataTransfer.setData("application/x-lich-row", JSON.stringify({
                page: page.address, group: component.props.transfer_group, source: component.cid, row: row.key
              }));
            });
          }
          tr.tabIndex = 0;
          tr.setAttribute("aria-selected", String((component.props.selected || []).includes(row.key)));
          tr.addEventListener("click", () => select(row));
          tr.addEventListener("dblclick", () => emit(page, component, "row_activate", { row: row.key }));
          tr.addEventListener("keydown", event => {
            if (event.key === "Enter") { event.preventDefault(); emit(page, component, "row_activate", { row: row.key }); }
            else if (event.key === " ") { event.preventDefault(); select(row); }
          });
          component.props.columns.forEach(column => {
            const cell = node("td", null, row.cells[column.key]);
            cell.style.textAlign = column.align || "start";
            // Reuse the same literal-cell presentation after edits and Escape.
            const paintCell = () => {
              cell.replaceChildren(); cell.textContent = row.cells[column.key] ?? "";
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
            if (column.editor && bound(page, component.cid, "cell_edit")) {
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
                const missingSelectValue = definition.type === "select" &&
                  !definition.options.some(option => option.value === row.cells[column.key]);
                if (missingSelectValue) {
                  const item = node("option", null, row.cells[column.key] ?? "");
                  item.value = row.cells[column.key] ?? "";
                  control.append(item);
                }
                if (definition.type !== "select") control.type = definition.type === "number" ? "number" : definition.type === "checkbox" ? "checkbox" : "text";
                for (const name of ["min", "max", "step"]) if (definition[name] !== undefined) control[name] = definition[name];
                if (definition.max_length) control.maxLength = definition.max_length;
                if (definition.type === "checkbox") control.checked = row.cells[column.key] === true;
                else control.value = row.cells[column.key] ?? "";
                let finished = false;
                const finish = save => {
                  if (finished) return;
                  finished = true;
                  const value = controlValue(control);
                  const commit = save && !(missingSelectValue && value === row.cells[column.key]);
                  // Selection or another server update may arrive while the
                  // cell editor owns an unfinished draft. Commit against the
                  // latest generation after releasing that render, once.
                  page.editingCell = false;
                  const deferred = page.deferredRender;
                  page.deferredRender = null;
                  if (commit && deferred) {
                    const pendingRow = findComponent(deferred.tree, component.cid)?.props.rows?.find(item => item.key === row.key);
                    if (pendingRow) pendingRow.cells[column.key] = value;
                  }
                  if (deferred) acceptRender(deferred);
                  if (commit) { row.cells[column.key] = value; emit(page, component, "cell_edit", { row: row.key, column: column.key, value }); }
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
              cell.addEventListener("click", event => { event.stopPropagation(); edit(); select(row); });
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
        if (component.props.sortable && column.sortable) {
          const button = node("button", null, column.label);
          button.type = "button";
          button.addEventListener("click", () => {
            sort = { column: column.key, direction: sort?.column === column.key && sort.direction === "asc" ? "desc" : "asc" };
            drawRows();
            emit(page, component, "sort_change", sort);
          });
          th.append(button);
        } else th.textContent = column.label;
        if (column.resizable) {
          const handle = node("span", "webui-column-resize");
          handle.setAttribute("aria-label", `Resize ${column.label}`);
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
            columnWidths.set(column.key, Math.max(24, Math.min(65536, drag.width + event.clientX - drag.x)));
            applyWidths();
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
      if (component.props.columns.some(column => column.label)) table.append(head);
      table.append(body);
      drawRows();
      wrapper.append(table);
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

  function compositeColor(value) {
    if (value && typeof value === "object" && "r" in value) return `rgba(${value.r}, ${value.g}, ${value.b}, ${value.a})`;
    const tone = typeof value === "string" ? value : value?.tone;
    return ({ neutral: "CanvasText", positive: "#27833e", caution: "#b57900", danger: "#b12a2a" })[tone] || "CanvasText";
  }

  // Reuses the bounded image/label/bar/region model reviewed in lich-5. Unlike
  // its drop-shadow tint, a mask actually colors the requested image pixels.
  function compositeLayer(page, component, layer) {
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

  function surfacePayload(event, surface, scale, button) {
    const bounds = surface.getBoundingClientRect();
    const modifiers = ["ctrl", "shift", "alt"].filter(key => event[`${key}Key`]);
    const payload = { x: Math.round((event.clientX - bounds.left) / scale),
      y: Math.round((event.clientY - bounds.top) / scale), button, modifiers };
    const region = event.target.closest?.(".composite-region");
    if (region) payload.region = region.dataset.region;
    return payload;
  }

  function render(page, component) {
    const renderer = renderers[component.type];
    if (!renderer) {
      const error = common(node("div", "renderer-error", `Renderer not implemented: ${component.type}`), component);
      error.dataset.error = "renderer_not_implemented";
      return error;
    }
    return renderer(page, component);
  }

  function applyFacilities(page) {
    const facilities = page.facilities || {};
    if (facilities.presentation?.opacity !== undefined) page.element.style.opacity = facilities.presentation.opacity;
    if (facilities.geometry) {
      if (facilities.geometry.width > 0) page.element.style.width = `${facilities.geometry.width}px`;
      if (facilities.geometry.height > 0) page.element.style.minHeight = `${facilities.geometry.height}px`;
    }
    if (facilities.focus) {
      const focusRoot = page.element.querySelector(`[data-cid="${CSS.escape(facilities.focus)}"]`);
      const focusTarget = focusRoot?.matches("input, select, button, textarea")
        ? focusRoot
        : focusRoot?.querySelector("input, select, button, textarea");
      focusTarget?.focus();
    }
    if (facilities.announce) {
      announcer.setAttribute("aria-live", facilities.announce.politeness);
      announcer.textContent = facilities.announce.text;
    }
    if (facilities.notify) notify(facilities.notify.text, facilities.notify.level);
  }

  function hideContextMenu(page) {
    page.contextMenus?.forEach(menu => { menu.style.display = "none"; });
    page.contextMenuPosition = null;
  }

  function showContextMenu(page, key, x, y) {
    hideContextMenu(page);
    page.contextMenuPosition = { key, x, y };
    const menu = page.contextMenus?.get(key);
    if (!menu) return;
    menu.style.display = "block";
    menu.style.left = `${Math.max(0, Math.min(x, window.innerWidth - menu.getBoundingClientRect().width))}px`;
    menu.style.top = `${Math.max(0, Math.min(y, window.innerHeight - menu.getBoundingClientRect().height))}px`;
  }

  document.addEventListener("pointerdown", event => {
    if (!event.target.closest?.(".webui-context-menu")) pages.forEach(hideContextMenu);
  });
  document.addEventListener("keydown", event => { if (event.key === "Escape") pages.forEach(hideContextMenu); });
  // A blur can commit an edited cell during a Save button's pointerdown.
  // Preserve that button through pointerup/click before applying the response.
  const releasePointers = () => window.setTimeout(() => pages.forEach(page => {
    page.pointerActive = false;
    if (!page.editingCell && !page.splitDragging && !page.columnDragging && page.deferredRender) {
      const deferred = page.deferredRender; page.deferredRender = null; acceptRender(deferred);
    }
  }), 0);
  document.addEventListener("pointerup", releasePointers);
  document.addEventListener("pointercancel", releasePointers);
  window.addEventListener("blur", releasePointers);

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

  function acceptRender(message) {
    const page = pages.get(message.page);
    if (!page) return;
    if (message.generation < page.generation) return;
    // Keep the active pointer target alive through periodic meter renders.
    // Only the latest tree is retained and applied when the gesture finishes.
    if (page.splitDragging || page.columnDragging || page.editingCell || page.pointerActive) {
      if (!page.deferredRender || message.generation > page.deferredRender.generation) page.deferredRender = message;
      return;
    }
    stopWindowGeometry(page);
    // Reuse the draft/base comparison from PR1650, restricted to stable cids.
    // A deliberate server value change wins; unrelated renders preserve typing.
    const edits = [];
    const active = document.activeElement;
    let focus = null;
    for (const [cid, control] of page.controls || []) {
      const base = page.bases?.get(cid);
      if (control === active) focus = { cid, start: control.selectionStart, end: control.selectionEnd };
      const sensitive = control.type === "password" || control.dataset.sensitive === "true";
      if (sensitive || (base !== undefined && controlValue(control) !== base)) {
        edits.push({ cid, base, value: controlValue(control), password: sensitive });
      }
    }
    page.generation = message.generation;
    page.bindings = message.bindings || {};
    page.submissions = message.submissions || {};
    page.facilities = message.facilities || {};
    page.resume = message.resume;
    page.tree = message.tree;
    page.controls = new Map();
    page.unscrolledTableMinimum = false;
    page.contextMenus = new Map();
    page.layoutObservers?.forEach(observer => observer.disconnect());
    page.layoutObservers = [];
    const next = render(page, message.tree);
    next.dataset.pageAddress = page.address;
    if (page.element) page.element.replaceWith(next); else pagesNode.append(next);
    page.element = next;
    if (page.contextMenuPosition) {
      const { key, x, y } = page.contextMenuPosition;
      showContextMenu(page, key, x, y);
    }
    trackPageGeometry(page, message.tree);
    page.bases = new Map([...page.controls].filter(([, control]) => control.dataset.sensitive !== "true")
      .map(([cid, control]) => [cid, controlValue(control)]));
    for (const edit of edits) {
      const control = page.controls.get(edit.cid);
      if (!control || (!edit.password && page.bases.get(edit.cid) !== edit.base)) continue;
      if (control.type === "checkbox") control.checked = edit.value;
      else if (control.restoreChoice) control.restoreChoice(edit.value);
      else control.value = edit.value;
    }
    const focused = focus && page.controls.get(focus.cid);
    if (focused && !focused.disabled) {
      page.restoringFocus = true;
      try {
        focused.focus();
        if (Number.isInteger(focus.start)) focused.setSelectionRange(focus.start, focus.end);
      } finally { page.restoringFocus = false; }
    }
    applyFacilities(page);
    for (const [request, record] of pending) {
      if (!record.replay || record.message.page !== page.address) continue;
      dropPending(request);
      const component = findComponent(page.tree, record.message.cid);
      const scope = page.submissions[record.message.cid] || [];
      if (!component || component.props.disabled || component.props.hidden ||
          JSON.stringify(scope) !== JSON.stringify(record.scope)) continue;
      emit(page, component, record.message.event, record.message.payload, record);
    }
  }

  function notify(text, level = "info") {
    const message = node("div", `notification ${level}`, text);
    notifications.append(message);
    window.setTimeout(() => message.remove(), 5000);
  }

  function receive(event) {
    const message = JSON.parse(event.data);
    if (message.type === "hello" || message.type === "pages") {
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
      if (pages.has(message.page)) stopWindowGeometry(pages.get(message.page));
      pages.get(message.page)?.element?.remove();
      pages.delete(message.page);
    } else if (message.type === "refusal") {
      if (message.reason === "stale_generation" && message.event === "scrolled") {
        pages.get(message.page)?.scrollMeasurements?.delete(message.cid);
      }
      const record = pending.get(message.request);
      const matches = record && ["page", "cid", "event"].every(key => record.message[key] === message[key]);
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

  function connect() {
    const scheme = window.location.protocol === "https:" ? "wss:" : "ws:";
    socket = new WebSocket(`${scheme}//${window.location.host}/ws`);
    socket.addEventListener("open", () => { reconnectDelay = 250; });
    socket.addEventListener("message", receive);
    socket.addEventListener("close", () => {
      discardPending(() => true);
      statusNode.textContent = "Disconnected; reconnecting";
      window.setTimeout(connect, reconnectDelay);
      reconnectDelay = Math.min(5000, reconnectDelay * 2);
    });
    socket.addEventListener("error", () => socket.close());
  }

  function detachPages() {
    if (!socket || socket.readyState !== WebSocket.OPEN) return;
    pages.forEach((page) => {
      page.splitDragging = false;
      page.editingCell = false;
      page.pointerActive = false;
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
