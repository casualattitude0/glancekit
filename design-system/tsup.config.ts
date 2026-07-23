import { defineConfig } from "tsup";

// Bundles src/index.ts to ESM + emits a .d.ts tree the design-sync converter
// reads for each component's Props interface. React stays external so the
// design agent's runtime (which provides React) resolves it, not us.
export default defineConfig({
  entry: ["src/index.ts"],
  format: ["esm"],
  dts: true,
  clean: true,
  external: ["react", "react-dom", "react/jsx-runtime"],
  // No CSS is imported from JS — styles ship as plain files (styles.css /
  // tokens.css) that the converter picks up via cfg.cssEntry, so the JS
  // bundle stays CSS-import-free and esbuild-bundlable downstream.
  splitting: false,
  sourcemap: false,
  target: "es2020",
});
