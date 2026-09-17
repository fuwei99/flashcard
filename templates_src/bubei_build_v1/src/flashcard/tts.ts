import { speak as bridgeSpeak } from "../bridge";

/* 发音统一走 bridge：有壳用壳的 TTS（豆包/系统，可缓存），
   无壳（浏览器直开）退到 speechSynthesis。 */
export function speak(text: string, rate = 0.95) {
  bridgeSpeak(text, rate);
}
