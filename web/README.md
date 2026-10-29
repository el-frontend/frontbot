# Frontbot website

The Frontbot landing page, built with Next.js (App Router) and Tailwind CSS. The build is a static export, and AWS Amplify Hosting serves it.

```bash
npm install
npm run dev     # http://localhost:3000
npm run build   # static site in out/
```

Deployment settings are in `amplify.yml` at the repo root (`appRoot: web`, artifacts in `out/`).

The download button points at the latest GitHub Release, which `.github/workflows/release.yml` builds when a `v*` tag is pushed.
