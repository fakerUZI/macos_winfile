"use strict";

// Keep all feature sections visible when JavaScript is unavailable.
const tabList = document.querySelector(".feature-tabs");
const tabs = [...tabList.querySelectorAll('[role="tab"]')];
const panels = tabs.map(tab => document.getElementById(tab.getAttribute("aria-controls")));
function selectTab(index, focus = false) {
  tabs.forEach((tab, i) => {
    tab.setAttribute("aria-selected", String(i === index));
    tab.tabIndex = i === index ? 0 : -1;
    panels[i].hidden = i !== index;
  });
  if (focus) tabs[index].focus();
}
tabs.forEach((tab, index) => {
  tab.addEventListener("click", () => selectTab(index));
  tab.addEventListener("keydown", event => {
    let target;
    if (event.key === "ArrowRight") target = (index + 1) % tabs.length;
    if (event.key === "ArrowLeft") target = (index + tabs.length - 1) % tabs.length;
    if (event.key === "Home") target = 0;
    if (event.key === "End") target = tabs.length - 1;
    if (target === undefined) return;
    event.preventDefault();
    selectTab(target, true);
  });
});
selectTab(0);
tabList.hidden = false;

const dialog = document.querySelector(".image-dialog");
const dialogImage = document.getElementById("dialog-image");
const imageCaption = document.getElementById("image-caption");
let screenshotTrigger;
document.querySelectorAll("[data-image]").forEach(button => {
  button.addEventListener("click", () => {
    if (typeof dialog.showModal !== "function") {
      window.location.href = button.dataset.image;
      return;
    }
    screenshotTrigger = button;
    dialogImage.src = button.dataset.image;
    dialogImage.alt = button.querySelector("img").alt;
    imageCaption.textContent = button.dataset.caption;
    dialog.showModal();
    document.body.classList.add("modal-open");
  });
});
document.querySelector(".close-dialog").addEventListener("click", () => dialog.close());
dialog.addEventListener("click", event => {
  const bounds = dialog.getBoundingClientRect();
  if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) dialog.close();
});
dialog.addEventListener("close", () => {
  document.body.classList.remove("modal-open");
  screenshotTrigger?.focus();
});

const copyButton = document.getElementById("copy-command");
copyButton.hidden = false;
copyButton.addEventListener("click", async () => {
  const command = document.getElementById("install-command");
  const status = document.getElementById("copy-status");
  try {
    await navigator.clipboard.writeText(command.textContent.trim());
    status.textContent = "已复制，可粘贴到终端运行。";
    copyButton.textContent = "已复制 ✓";
  } catch {
    const range = document.createRange();
    range.selectNodeContents(command);
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    status.textContent = "命令已选中，请按 ⌘C 复制。";
  }
});
