import { defineConfig } from 'vitepress'

export default defineConfig({
  lang: 'en-US',
  title: 'Meridian',
  description: 'Ship web apps without a hassle',
  cleanUrls: true,

  base: '/',
  appearance: 'force-dark',

  // Internal audit notes live under docs/ for convenience; they must never ship.
  srcExclude: ['audits/**', '*-audit.md'],

  head: [
    ['link', { rel: 'icon', href: '/favicon.ico', sizes: 'any' }],
    ['link', { rel: 'icon', type: 'image/png', href: '/favicon-32x32.png', sizes: '32x32' }],
    ['link', { rel: 'icon', type: 'image/png', href: '/favicon-16x16.png', sizes: '16x16' }],
    ['link', { rel: 'apple-touch-icon', href: '/apple-touch-icon.png', sizes: '180x180' }],
    [
      'script',
      {
        defer: '',
        src: 'https://cloud.umami.is/script.js',
        'data-website-id': '29c7a8a4-a30b-45f2-a36e-a07fdb27ea7d'
      }
    ]
  ],

  themeConfig: {
    logo: '/meridian-64.webp',
    siteTitle: 'Meridian',

    nav: [
      { text: 'Home', link: '/' },
      { text: 'Guide', link: '/guide/', activeMatch: '/guide/' },
      { text: 'Recipes', link: '/recipes/', activeMatch: '/recipes/' },
      { text: 'Reference', link: '/reference/', activeMatch: '/reference/' },
      // VP renders nav item text with v-html, so the span is a stable hook for the
      // gold pill in custom.css — the docs counterpart to the landing's CTA.
      {
        text: '<span class="nav-cta">GitHub →</span>',
        link: 'https://github.com/treagod/meridian',
        target: '_blank',
        rel: 'noreferrer',
        noIcon: true
      }
    ],

    outline: {
      level: [2, 3],
      label: 'On This Page'
    },

    docFooter: {
      prev: 'Previous',
      next: 'Next'
    },

    footer: {
      message: 'MIT License',
      copyright: '© 2026 Meridian'
    },

    sidebar: {
      '/guide/': [
        {
          text: 'Guide',
          items: [
            { text: 'Overview', link: '/guide/' },
            { text: 'Quickstart', link: '/guide/quickstart' },
            { text: 'Concepts', link: '/guide/concepts' },
            { text: 'Multi-App Hosting', link: '/guide/multi-app' },
            { text: 'Pre-Flight Checklist', link: '/guide/preflight' },
            { text: 'Troubleshooting', link: '/guide/troubleshooting' }
          ]
        }
      ],
      '/recipes/': [
        {
          text: 'Recipes',
          items: [
            { text: 'Overview', link: '/recipes/' },
            { text: 'Marten + Postgres + Dragonfly + Assets', link: '/recipes/marten-postgres-dragonfly-assets' },
            { text: 'Marten + SQLite + Assets', link: '/recipes/marten-sqlite-assets' },
            { text: 'Rails + Postgres', link: '/recipes/rails-postgres' },
            { text: 'Go Static Binary', link: '/recipes/go-static-binary' },
            { text: 'Simple Kemal App', link: '/recipes/kemal-simple' },
            { text: 'Third-Party Distroless Image', link: '/recipes/vikunja-distroless' },
            { text: 'Static Site', link: '/recipes/static-site' },
            { text: 'Multi-App On One Host', link: '/recipes/multi-app-one-host' }
          ]
        }
      ],
      '/reference/': [
        {
          text: 'Reference',
          items: [
            { text: 'Overview', link: '/reference/' },
            { text: 'deploy.yml', link: '/reference/deploy-yml' },
            { text: 'CLI', link: '/reference/cli' }
          ]
        }
      ]
    },

    search: { provider: 'local' }
  }
})
