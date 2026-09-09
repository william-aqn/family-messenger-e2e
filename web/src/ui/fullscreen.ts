import type { RefObject } from 'preact';
import { useEffect, useState } from 'preact/hooks';

export function isFullscreen(el: Element | null): boolean {
  return el !== null && document.fullscreenElement === el;
}

export function exitFullscreen(): void {
  if (document.fullscreenElement) void document.exitFullscreen().catch(() => {});
}

export function toggleFullscreen(el: HTMLElement | null): void {
  if (!el) return;
  if (isFullscreen(el)) exitFullscreen();
  else void el.requestFullscreen().catch(() => {});
}

/** Whether the referenced element is full screen; leaves full screen when the component unmounts. */
export function useFullscreen(ref: RefObject<HTMLElement>): boolean {
  const [on, setOn] = useState(false);
  useEffect(() => {
    let active: Element | null = null;
    const onChange = () => {
      const now = isFullscreen(ref.current);
      active = now ? ref.current : null;
      setOn(now);
    };
    document.addEventListener('fullscreenchange', onChange);
    return () => {
      document.removeEventListener('fullscreenchange', onChange);
      if (active && document.fullscreenElement === active) exitFullscreen();
    };
  }, []);
  return on;
}
