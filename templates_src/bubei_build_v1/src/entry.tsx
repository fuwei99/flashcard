/* 模板入口：把 FlashcardApp 挂到 #app，全屏。
   与参考项目的 main.tsx 区别：不套手机外壳，直接铺满 WebView。 */
import "./index.css";
import { createRoot } from "react-dom/client";
import FlashcardApp from "./flashcard/FlashcardApp";

function mount() {
  const el =
    document.getElementById("app") || document.getElementById("root");
  if (!el) return;
  createRoot(el).render(<FlashcardApp />);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", mount);
} else {
  mount();
}
