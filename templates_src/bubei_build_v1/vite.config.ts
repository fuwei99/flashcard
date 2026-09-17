import path from "path";
import { fileURLToPath } from "url";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/* 模板构建：产出壳能内联的三件套
     dist/script.js   自包含 IIFE（挂载到 #app，无 import/export）
     dist/style.css   已降级的 CSS（老 WebView 也能认）
   壳 template_engine 会把 style.css / script.js 直接塞进 <style>/<script>，
   所以 script 必须是普通脚本（不能是 type="module"），CSS 不能有
   oklch / color-mix / @property 这些 Chrome 111+ 才认的东西。 */
export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: { "@": path.resolve(__dirname, "src") },
  },
  // 把图片内联成 base64（loadHtmlString 是 about:blank，相对路径必裂）
  build: {
    assetsInlineLimit: 100 * 1024 * 1024,
    cssCodeSplit: false,
    // 老 Android WebView 兜底目标
    target: "chrome80",
    cssTarget: "chrome80",
    minify: "esbuild",
    lib: {
      entry: path.resolve(__dirname, "src/entry.tsx"),
      name: "FlashcardTemplate",
      formats: ["iife"],
      fileName: () => "script.js",
    },
    rollupOptions: {
      output: {
        // 单文件：不拆分 chunk、不 hash
        inlineDynamicImports: true,
        assetFileNames: (info) => {
          const n = info.names?.[0] || info.name || "";
          if (n.endsWith(".css")) return "style.css";
          return "assets/[name][extname]";
        },
      },
    },
    emptyOutDir: true,
  },
  // CSS 降级：lightningcss 把 oklch/color-mix/@property 编译成老浏览器认的形式
  css: {
    transformer: "lightningcss",
    lightningcss: {
      targets: { chrome: 80 << 16 },
    },
  },
});
