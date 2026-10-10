module.exports = {
  // The fork is its own package; it also lives vendored inside other repos, whose
  // ESLint configs must not merge into this one.
  root: true,
  extends: [
    'plugin:@typescript-eslint/recommended',
    // 'prettier',
  ],
  parser: '@typescript-eslint/parser',
  plugins: ['@typescript-eslint'],
  rules: {
    '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
    '@typescript-eslint/explicit-function-return-type': 'off',
    '@typescript-eslint/explicit-module-boundary-types': 'off',
    '@typescript-eslint/no-explicit-any': 'warn',
    '@typescript-eslint/no-non-null-assertion': 'warn',
  },
  ignorePatterns: [
    'node_modules/',
    'lib/',
    'plugin/build/',
    'nitrogen/generated/',
    '*.js',
  ],
};