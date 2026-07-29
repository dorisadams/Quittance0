import tseslint from 'typescript-eslint';

export default tseslint.config(
  {
    ignores: ['dist/', 'node_modules/'],
  },
  {
    files: ['src/**/*.ts'],
    extends: [
      ...tseslint.configs.recommended,
    ],
    rules: {
      // `any` is common in catch blocks and DB row mapping; warn to track them
      '@typescript-eslint/no-explicit-any': 'warn',
      // Catch unused variables (ignore underscore-prefixed)
      '@typescript-eslint/no-unused-vars': [
        'warn',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_' },
      ],
      // Allow `require` for dynamic imports (e.g. tsx)
      '@typescript-eslint/no-require-imports': 'off',
    },
  },
);
