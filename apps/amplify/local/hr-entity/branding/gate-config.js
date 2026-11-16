// Copyright 2025 The ThunderID Authors
// SPDX-License-Identifier: Apache-2.0

window.__THUNDERID_RUNTIME_CONFIG__ = {
  brand: {
    product_name: 'Amplify',
    favicon: {
      light: 'assets/images/favicon.ico',
      dark: 'assets/images/favicon-inverted.ico',
    },
  },
  client: {
    base: '/gate',
  },
  documentation: {
    baseUrl: 'https://thunderid.dev/docs/next',
    releasesUrl: 'https://thunderid.dev/data/releases.json',
    links: {},
  },
  // Defaults to the origin this app is served from. Add a `server` block with `public_url`
  // (or `hostname`, `port`, `http_only`) to target a different backend.
};
