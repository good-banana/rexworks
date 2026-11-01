"use strict";
(function () {
  let sequence = 0;

  function message(error) {
    if (!error) return "Unknown error";
    if (typeof error === "string") return error;
    return String(error.message || error.str || error);
  }

  function removeLeftovers(id) {
    for (const node of document.querySelectorAll("#" + id + ", #d" + id)) node.remove();
  }

  window.renderDiagram = async function (source, theme) {
    const stage = document.getElementById("stage");
    stage.replaceChildren();
    document.documentElement.style.background = theme.background;
    document.body.style.background = theme.background;
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      theme: "base",
      themeVariables: theme.variables,
      fontFamily: theme.variables.fontFamily,
      deterministicIds: true,
    });
    const id = "mermaid-diagram-" + ++sequence;
    let svg;
    try {
      await mermaid.parse(source);
      ({ svg } = await mermaid.render(id, source));
    } catch (error) {
      removeLeftovers(id);
      return { error: message(error) };
    }
    removeLeftovers(id);
    stage.innerHTML = svg;
    const element = stage.querySelector("svg");
    if (!element) return { error: "Mermaid produced no diagram" };
    const box = element.viewBox && element.viewBox.baseVal;
    const bounds = element.getBoundingClientRect();
    const width = box && box.width > 0 ? box.width : bounds.width;
    const height = box && box.height > 0 ? box.height : bounds.height;
    return { width: width, height: height, pixelRatio: window.devicePixelRatio || 1 };
  };

  window.presentDiagram = function (width, height) {
    const element = document.querySelector("#stage svg");
    if (!element) return false;
    element.style.maxWidth = "none";
    element.setAttribute("width", String(width));
    element.setAttribute("height", String(height));
    return true;
  };
})();
