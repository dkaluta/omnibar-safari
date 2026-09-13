import { defineConfig } from 'astro/config';

const [owner, repository] = (process.env.GITHUB_REPOSITORY ?? '').split('/');
const repositoryBase = owner && repository && repository.toLowerCase() !== `${owner.toLowerCase()}.github.io`
  ? `/${repository}`
  : '/';

export default defineConfig({
  output: 'static',
  site: process.env.ASTRO_SITE || 'https://dkaluta.com',
  base: process.env.ASTRO_BASE ?? (process.env.GITHUB_ACTIONS && owner ? repositoryBase : '/omnibar-safari'),
  trailingSlash: 'always',
  build: { format: 'directory' },
});
