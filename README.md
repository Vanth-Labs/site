# site: vanthlabs.org

The site of Vanth Labs, the company behind Hannah. Plain HTML/CSS/JS, **no build step, no
dependencies**. Live at **https://vanthlabs.org/**.

## Pages

| Path | What it is |
|---|---|
| `/` (`index.html`) | Hannah: the product landing, with the copyable install command, capabilities, requirements, FAQ |
| `/about/` | Vanth Labs: what we believe, who we are, work with us, contact |
| `/brand/` | Brand and press kit: logos, colors, type, naming, official paragraph, screenshots |
| `404.html` | Custom not-found page (GitHub Pages picks it up by name) |

## Files

| File | What it is |
|---|---|
| `styles.css` | One stylesheet for every page: dark theme, violet accent, Orbitron + Inter, the HUD vocabulary (eyebrows, corner-bracket frames, progress hairline) and the scroll motion |
| `main.js` | Landing only: OS switcher, copy button, clips that play only on screen, reveals, the progress hairline, the sticky job (step picks the capture) |
| `install.sh`, `install-mac.sh`, `install.ps1` | The installers, served from the root (their URLs are in every README: do not move them) |
| `assets/vanth-*.svg`, `assets/vanth-*.png` | The logo: `vanth-logo.svg` is the source lockup (mark + letters); `vanth-icon.png` the mark recolored to the site violet; lockups and marks in three colors; PNGs for avatars; `og-vanth.png` for link previews |
| `assets/*.webp` | Screenshots; each has its JPG next to it as the fallback in a `<picture>` |
| `assets/media/` | The captures on the landing: every clip as `.webm` (VP9) + `.mp4` (H.264) + `.webp` poster, muted, 30 fps. All of them (`hero`, `say-*`, `hands-*`, `avatar-swap`, and the stills `overlay-live`, `hud-permission`, `gesture-wide`) are cut from two screen recordings; nothing is generated |
| `favicon.svg` | The mark on a violet tile |
| `robots.txt`, `sitemap.xml`, `llms.txt` | Crawlers: everything allowed (AI crawlers named explicitly), the three pages, a plain-text summary |
| `CNAME`, `.nojekyll` | Custom domain; serve files as-is |

## Logo

`assets/vanth-logo.svg` is the source (a raster mark plus the letter outlines). Every other
`vanth-*` file derives from it: the mark is the same PNG with its RGB replaced by the site violet
(`#b48cff`), alpha untouched; the lockups place that mark at 438x410 and the letters in white,
black or the site text color. Headings use Orbitron because that is the family of the letters.

## SEO

Every page has its own title, description, canonical, OpenGraph and Twitter cards, and JSON-LD:
`Organization`, `WebSite`, `SoftwareApplication` and `FAQPage` on the landing; `Organization`
(with founders and contact points), `Person`, `AboutPage` and `BreadcrumbList` on About;
`WebPage` and `BreadcrumbList` on Brand. Lighthouse 12 on the live site (2026-09-03), desktop and
mobile, all three pages: 100 performance, 100 accessibility, 100 best practices, 100 SEO.

## Media

Clips are encoded from the source recordings with ffmpeg, no audio:

```bash
ffmpeg -ss START -to END -i take.mp4 -an -vf "CROP,fps=30,format=yuv420p" -c:v libvpx-vp9 -crf 34 -b:v 0 -row-mt 1 out.webm
ffmpeg -ss START -to END -i take.mp4 -an -vf "CROP,fps=30,format=yuv420p" -c:v libx264 -crf 25 -movflags +faststart out.mp4
ffmpeg -ss START -i take.mp4 -frames:v 1 -vf "CROP" -c:v libwebp -quality 80 out.webp   # poster
```

Every `<video>` on the page is `muted playsinline preload="none"` with a poster, and `main.js` plays it only while it is on screen (with `prefers-reduced-motion` nothing autoplays; the clips get controls instead).

## Preview locally

```bash
cd hannah-site && python3 -m http.server 8080
```

## Deploy

GitHub Pages serves the root of `main` automatically, push and it's live.
(Enabled once via Settings → Pages → Deploy from branch → `main` / `/root`.)

## How install.sh works

Queries the GitHub API for the latest release of [`Vanth-Labs/hannah`](https://github.com/Vanth-Labs/hannah),
downloads the first `*.AppImage` asset into `~/.local/bin/Hannah.AppImage` and makes it
executable. It refuses gracefully when no release exists yet.

**It only works once a real release is published**: tagging `v*` in `Vanth-Labs/hannah`
triggers its CI workflow, which builds and uploads the artifacts.

## If anything moves

- Pages URL changes → update the command in `index.html` (hero), `og:url`, and `SITE` in `install.sh`.
- Release asset name changes → nothing to change here (the script picks any `*.AppImage`).
- New OS builds ship → enable the disabled tabs in `index.html` and extend `install.sh`.
