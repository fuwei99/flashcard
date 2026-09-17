import FlashcardApp from "./flashcard/FlashcardApp";

export default function App() {
  return (
    <div className="flex min-h-screen items-center justify-center bg-[#060607] font-sans">
      {/* 手机容器：锁定截图原始比例 1080×2400 = 9:20 */}
      <div className="flex h-[100dvh] w-full max-w-[430px] flex-col overflow-hidden bg-[#121214] sm:aspect-[9/20] sm:h-auto sm:max-h-[96dvh] sm:w-[430px] sm:rounded-[30px] sm:shadow-[0_0_0_1px_rgba(255,255,255,0.07),0_30px_90px_rgba(0,0,0,0.7)]">
        <FlashcardApp />
      </div>
    </div>
  );
}
