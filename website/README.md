# Omnibar website

A static Astro website with landing, support, and privacy pages. It has no client-side JavaScript, external fonts, analytics, or runtime service dependencies.

```sh
cd website
npm ci
npm run dev
npm run build
```

The local development and preview URL is `http://localhost:4321/omnibar-safari/`.

GitHub Pages deployment is configured in `../.github/workflows/deploy-pages.yml`. Set the repository’s Pages source to **GitHub Actions**. A push to `main` that changes the website or workflow builds the site and deploys the Pages artifact.

The production site is `https://dkaluta.com/omnibar-safari/`. The workflow reads the Pages origin and base path from `actions/configure-pages`, so the existing `dkaluta.com` user-site domain is retained. Do not add a project `CNAME` file. Links to the source use the workflow’s `GITHUB_REPOSITORY`, with the public `dkaluta/omnibar-safari` repository as the local fallback. You can also set:

- `ASTRO_SITE`: site origin, such as `https://your-name.github.io`.
- `ASTRO_BASE`: site path, such as `/omnibar-safari`, or `/` for a custom domain.
- `PUBLIC_REPOSITORY_URL`: optional override for the source repository link.
- `PUBLIC_APP_STORE_URL`: the public Mac App Store listing URL. The download button appears only when this is set. In GitHub Actions, set the repository variable `APP_STORE_URL`.

To check project-path handling locally:

```sh
ASTRO_SITE=https://example.github.io ASTRO_BASE=/omnibar-safari npm run build
```

Public App Store metadata URLs after deployment:

- Marketing: the site root.
- Support: `<site-root>/support/`.
- Privacy policy: `<site-root>/privacy/`.

Keep the product copy consistent with the repository’s `README.markdown` and update the privacy policy date when data handling changes. The website is covered by the repository’s BSD 2-Clause license.
