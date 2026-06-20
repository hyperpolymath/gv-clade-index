// SPDX-License-Identifier: MPL-2.0
import js from '@eslint/js';
import globals from 'globals';

export default [
  { ignores: ['node_modules/**', '.wrangler/**', 'data/**', 'coverage/**'] },
  js.configs.recommended,
  {
    files: ['**/*.js'],
    languageOptions: {
      ecmaVersion: 'latest',
      sourceType: 'module',
      globals: {
        ...globals.node,
        ...globals.browser,
        ...globals.serviceworker,
      },
    },
    rules: {
      'no-unused-vars': ['warn', { argsIgnorePattern: '^_' }],
    },
  },
];
