---
name: lavish-artifacts
description: Agent-only contract for Lavish HTML artifacts. Load before authoring, substantially editing, or presenting a Lavish HTML artifact for captain review, so the iframe document owns vertical scroll correctly.
user-invocable: false
metadata:
  internal: true
---

# lavish-artifacts

Load this skill before authoring, substantially editing, or presenting a Lavish HTML artifact for captain review.
This skill is the single owner of the agent-authored Lavish artifact HTML scroll contract.

## Scroll ownership

Lavish shell locks the outer page.
The iframe document, or an inner root inside that document, must own vertical scroll for long artifact content.

Use the proven `#scroll-root` pattern unless the page has a concrete reason not to use an inner root.
This pattern was captain-verified on 2026-07-29 after restoring vertical scroll for long Lavish review HTML.

```css
html, body {
  margin: 0;
  padding: 0;
  height: 100%;
  width: 100%;
  overflow: hidden;
}
#scroll-root {
  height: 100%;
  width: 100%;
  overflow-x: hidden;
  overflow-y: scroll;
  -webkit-overflow-scrolling: touch;
  touch-action: pan-y;
  overscroll-behavior-x: none;
  overscroll-behavior-y: auto;
}
```

Wrap all body content in the scroll root.

```html
<body>
  <div id="scroll-root">
    ...
  </div>
</body>
```

## Fallback without an inner root

When an artifact cannot use an inner root, make `html, body` the scroll surface.
Use `overflow-x: hidden; overflow-y: auto; touch-action: pan-y; overscroll-behavior-x: none;` on `html, body`.
Set `body { min-height: 100%; }`.
Never pair viewport height with `overflow: hidden` on the same element that must scroll content.

## Wide content

Wide tables and other horizontally large regions must use horizontal overflow on a child wrapper only, such as `.table-scroll { overflow-x: auto; }`.
Do not make `html`, `body`, or `#scroll-root` the only horizontal overflow owner.
The artifact page root remains responsible for vertical scroll, while the child wrapper owns local horizontal pan.

## Lavish session handling

After a scroll fix or substantial content rewrite, open a new `lavish-axi` session.
Do not mutate or reuse a frozen review URL as if it represented the updated artifact.

Prefer `lavish-axi ... --no-open` or `LAVISH_AXI_NO_OPEN=1` when captain preferences forbid auto-opening a browser.
Do not invent Tailscale hosts in this skill because those stay captain-private.

## Do not

- Do not put `height: 100%` plus `overflow: hidden` on the element that must scroll content.
- Do not rely on bare Tailwind `min-h-screen` alone as the scroll strategy.
- Do not claim shell package patches in this skill unless they are documented by another tracked owner.
