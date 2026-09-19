(() => {
  "use strict";

  const VERSION = "2.7.0";
  const pagesNode = document.getElementById("pages");
  const statusNode = document.getElementById("status");
  const notifications = document.getElementById("notifications");
  const announcer = document.getElementById("announcer");
  const pages = new Map();
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

  function windowGeometry() {
    return JSON.stringify({
      width: window.outerWidth,
      height: window.outerHeight,
      position: [window.screenX, window.screenY]
    });
  }

  function trackWindowGeometry(page, component) {
    if (page.geometryTimer) window.clearInterval(page.geometryTimer);
    let previous = windowGeometry();
    page.geometryTimer = window.setInterval(() => {
      const current = windowGeometry();
      if (current === previous) return;

      previous = current;
      emit(page, component, "change", { value: current });
    }, 500);
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
    if (Number.isFinite(props.margin)) element.style.margin = `${props.margin}px`;
    else if (props.margin) for (const side of ["top", "right", "bottom", "left"]) {
      element.style[`margin${side[0].toUpperCase()}${side.slice(1)}`] = `${props.margin[side] || 0}px`;
    }
    if (Number.isFinite(props.width) && props.width >= 0) element.style.width = `${props.width}px`;
    if (Number.isFinite(props.height) && props.height >= 0) element.style.height = `${props.height}px`;
    if (Number.isFinite(props.max_height) && props.max_height >= 0) element.style.maxHeight = `${props.max_height}px`;
    return element;
  }

  function bound(page, cid, event) {
    return (page.bindings[cid] || []).includes(event);
  }

  function controlValue(control) {
    if (!control) return null;
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

  function field(page, component, control, inline = false) {
    control.dataset.sensitive = String(component.props.sensitive === true || component.type === "password_input");
    const wrapper = common(node("label", `field${inline ? " inline" : ""}`), component);
    if (component.props.label) wrapper.append(node("span", "field-label", component.props.label));
    wrapper.append(control);
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

  const renderers = {
    page(page, component) {
      const root = common(node("section", "webui-page"), component);
      document.title = component.props.title;
      if (!component.props.bare) root.append(node("h1", null, component.props.title));
      return appendChildren(page, component, root);
    },
    group(page, component) {
      const group = common(node("fieldset", "webui-group"), component);
      group.append(node("legend", null, component.props.label));
      return appendChildren(page, component, group);
    },
    stack(page, component) {
      const stack = common(node("div", "webui-stack"), component);
      stack.style.gap = `${component.props.gap ?? 8}px`;
      return appendChildren(page, component, stack);
    },
    columns(page, component) {
      const columns = common(node("div", "webui-columns"), component);
      const weights = component.props.weights || Array(component.props.count).fill(1);
      columns.style.gridTemplateColumns = weights.map((weight) => `${weight}fr`).join(" ");
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
      grid.style.gridTemplateColumns = `repeat(${component.props.cols}, minmax(0, 1fr))`;
      grid.style.gap = `${component.props.gap ?? 8}px`;
      if (component.props.row_gap !== undefined) grid.style.rowGap = `${component.props.row_gap}px`;
      if (component.props.column_gap !== undefined) grid.style.columnGap = `${component.props.column_gap}px`;
      (component.children || []).forEach((child) => {
        const cell = render(page, child);
        const placement = child.placement || {};
        cell.style.gridColumn = `${placement.column ? placement.column + " / " : ""}span ${placement.span ?? 1}`;
        cell.style.gridRow = `${placement.row ? placement.row + " / " : ""}span ${placement.row_span ?? 1}`;
        grid.append(cell);
      });
      return grid;
    },
    // alias/vars use vertical adjustments. Retain offsets locally across tree
    // replacement and report actual layout measurements only when they change.
    scroll(page, component) {
      const element = common(node("div", "webui-scroll"), component);
      element.style.overflow = "auto";
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
    log(_page, component) {
      const log = common(node("div", "webui-log", component.props.lines.slice(-component.props.max_lines).join("\n")), component);
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
    text(_page, component) {
      const text = common(node("div", "webui-text", component.props.content), component);
      text.style.whiteSpace = component.props.wrap === false ? "pre" : "pre-wrap";
      nativeTextStyle(text, component.props);
      return text;
    },
    progress(_page, component) {
      const wrapper = common(node("label", "webui-progress"), component);
      if (component.props.label) wrapper.append(node("span", null, component.props.label));
      const progress = node("progress");
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
      control.value = component.props.value;
      control.addEventListener("change", () => emit(page, component, "change", { value: control.value }));
      control.addEventListener("focus", () => {
        if (!page.restoringFocus) emit(page, component, "focus");
      });
      control.addEventListener("keydown", (event) => {
        if (event.key === "Enter") emit(page, component, "submit");
      });
      const wrapper = field(page, component, control);
      if (component.cid.includes("text_input:window-geometry")) trackWindowGeometry(page, component);
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
      return field(page, component, control);
    },
    select(page, component) {
      const control = node("select");
      control.disabled = component.props.disabled === true;
      component.props.options.forEach((option) => {
        const choice = node("option", null, option.label);
        choice.value = option.value;
        choice.selected = option.value === component.props.value;
        control.append(choice);
      });
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
        if (props.popup) {
          const size = props.popup.size || [500, 600];
          window.open(`/?page=${encodeURIComponent(props.popup.page)}`, "_blank", `noopener,width=${size[0]},height=${size[1]}`);
        } else emit(page, component, "surface_activate", surfacePayload(event, surface, scale, "secondary"));
      });
      wrapper.append(surface);
      if (props.scroll_to) {
        const target = props.layers.find(layer => layer.kind === "region" && layer.key === props.scroll_to);
        const signature = JSON.stringify([props.scroll_to, target?.x1, target?.y1, scale]);
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
      const table = node("table", "webui-table");
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
          const a = left.cells[sort.column], b = right.cells[sort.column];
          const compared = typeof a === "number" && typeof b === "number"
            ? a - b : String(a ?? "").localeCompare(String(b ?? ""), undefined, { numeric: true });
          return sort.direction === "desc" ? -compared : compared;
        });
        for (const [key, th] of headings) th.setAttribute("aria-sort", sort?.column === key
          ? (sort.direction === "desc" ? "descending" : "ascending") : "none");
        rows.forEach(row => {
          const tr = node("tr");
          tr.dataset.rowKey = row.key;
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
        header.append(th);
      });
      head.append(header);
      table.append(head, body);
      drawRows();
      wrapper.append(table);
      return wrapper;
    },
    dialog(page, component) {
      const dialog = common(node("dialog", "webui-dialog"), component);
      dialog.append(node("h2", null, component.props.title));
      if (component.props.body) dialog.append(node("p", null, component.props.body));
      appendChildren(page, component, dialog);
      const actions = node("div", "dialog-actions");
      component.props.buttons.forEach((definition) => {
        const button = node("button", definition.variant || "default", definition.label);
        button.addEventListener("click", () => emit(page, component, "response", { button: definition.id }));
        actions.append(button);
      });
      dialog.append(actions);
      queueMicrotask(() => { if (dialog.isConnected && !dialog.open) dialog.showModal(); });
      return dialog;
    }
  };

  // Adapted from Nisugi's individual DOM style assignments. Native consumers
  // supply validated properties; no markup or CSS source is interpreted.
  function nativeTextStyle(element, props) {
    if (props.font_size !== undefined) element.style.fontSize = `${props.font_size}pt`;
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
      } else region.style.pointerEvents = "none";
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
      if (!target || target.disabled || target.hidden || target.getClientRects().length === 0) continue;
      event.preventDefault();
      target.click();
      break;
    }
  });

  function acceptRender(message) {
    const page = pages.get(message.page);
    if (!page) return;
    if (message.generation < page.generation) return;
    if (page.geometryTimer) window.clearInterval(page.geometryTimer);
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
    const next = render(page, message.tree);
    next.dataset.pageAddress = page.address;
    if (page.element) page.element.replaceWith(next); else pagesNode.append(next);
    page.element = next;
    page.bases = new Map([...page.controls].filter(([, control]) => control.dataset.sensitive !== "true")
      .map(([cid, control]) => [cid, controlValue(control)]));
    for (const edit of edits) {
      const control = page.controls.get(edit.cid);
      if (!control || (!edit.password && page.bases.get(edit.cid) !== edit.base)) continue;
      if (control.type === "checkbox") control.checked = edit.value;
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
        if (descriptor.title) document.title = descriptor.title;
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
      window.clearInterval(pages.get(message.page)?.geometryTimer);
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
      if (!Number.isInteger(page.generation)) return;
      socket.send(JSON.stringify({
        type: "detach", page: page.address, generation: page.generation
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
