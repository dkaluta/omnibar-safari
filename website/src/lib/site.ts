export const supportEmail = 'support@dkaluta.com';

export const repositoryURL = import.meta.env.PUBLIC_REPOSITORY_URL
  || (process.env.GITHUB_REPOSITORY ? `https://github.com/${process.env.GITHUB_REPOSITORY}` : 'https://github.com/dkaluta/omnibar-safari');

export const appStoreURL = import.meta.env.PUBLIC_APP_STORE_URL || undefined;

export function pageURL(path = ''): string {
  const base = import.meta.env.BASE_URL.replace(/\/$/, '');
  const segment = path.replace(/^\/+|\/+$/g, '');
  return `${base}/${segment}${segment ? '/' : ''}`;
}

export const engines = [
  'Google', 'DuckDuckGo', 'Bing', 'Yahoo', 'Ecosia', 'Kagi', 'Startpage', 'Qwant',
  'Yandex', 'Baidu', 'Sogou', '360 Search', 'Yahoo Japan', 'Naver', 'Seznam', 'Reddit', 'WolframAlpha',
];
