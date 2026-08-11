import nextVitals from 'eslint-config-next/core-web-vitals';
import nextTypescript from 'eslint-config-next/typescript';

const config = [
  {
    ignores: ['.next/**', 'next-env.d.ts', 'node_modules/**', 'test-results/**', 'playwright-report/**'],
  },
  ...nextVitals,
  ...nextTypescript,
  {
    rules: {
      '@next/next/no-img-element': 'off',
    },
  },
];

export default config;
