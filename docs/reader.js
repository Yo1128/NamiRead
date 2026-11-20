const pages = Array.from(document.querySelectorAll(".passages article"));
const controls = document.querySelector(".turns");
const previous = document.querySelector("#prev");
const next = document.querySelector("#next");
const counter = controls.querySelector("output");
let current = 0;

function turn(offset) {
  const target = current + offset;
  if (target < 0 || target >= pages.length) return;
  pages[current].hidden = true;
  current = target;
  pages[current].hidden = false;
  counter.textContent = `${current + 1} / ${pages.length}`;
  previous.disabled = current === 0;
  next.disabled = current === pages.length - 1;
  if (next.disabled) previous.focus();
  if (previous.disabled) next.focus();
}

previous.addEventListener("click", () => turn(-1));
next.addEventListener("click", () => turn(1));
controls.hidden = false;
