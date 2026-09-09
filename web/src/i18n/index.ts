// Tiny i18n: dictionaries keyed by string ids, a reactive current language
// and t(). To add a language: create src/i18n/<code>.ts exporting a
// Partial<Dict> and register it in `languages` below.
import { signal } from '@preact/signals';
import { type Dict, en, type Key } from './en';
import { ru } from './ru';

export const languages: Record<string, { name: string; dict: Partial<Dict> }> = {
  en: { name: 'English', dict: en },
  ru: { name: 'Русский', dict: ru },
};

const STORAGE_KEY = 'family-messenger.lang';

function detect(): string {
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored && languages[stored]) return stored;
  } catch {
    /* storage unavailable */
  }
  const nav = (navigator.language || 'en').toLowerCase();
  for (const code of Object.keys(languages)) {
    if (nav === code || nav.startsWith(code + '-')) return code;
  }
  return 'en';
}

export const lang = signal<string>(detect());
document.documentElement.lang = lang.value;

export function setLang(code: string): void {
  if (!languages[code]) return;
  lang.value = code;
  document.documentElement.lang = code;
  try {
    localStorage.setItem(STORAGE_KEY, code);
  } catch {
    /* storage unavailable */
  }
}

/** Translates a key in the current language, falling back to English. */
export function t(key: Key, params?: Record<string, string | number>): string {
  const dict = languages[lang.value]?.dict;
  let s: string = (dict && dict[key]) ?? en[key] ?? key;
  if (params) {
    for (const [k, v] of Object.entries(params)) s = s.split(`{${k}}`).join(String(v));
  }
  return s;
}

/** Human-readable duration for retention timers. */
export function formatDuration(seconds: number): string {
  if (seconds === 3600) return t('duration_1h');
  if (seconds === 86400) return t('duration_1d');
  if (seconds === 7 * 86400) return t('duration_1w');
  if (seconds === 30 * 86400) return t('duration_30d');
  return t('duration_custom', { n: seconds });
}

/** Maps server error codes to localized messages where it helps the user. */
export function describeError(err: unknown): string {
  const code = (err as { code?: string })?.code;
  switch (code) {
    case 'network':
      return t('error_network');
    case 'invite_required':
      return t('invite_required');
    case 'registration_closed':
      return t('registration_closed');
    case 'invalid_credentials':
      return t('invalid_credentials');
    case 'username_taken':
      return t('username_taken');
    case 'account_disabled':
      return t('account_disabled');
    case 'attachments_disabled':
      return t('attachments_disabled');
  }
  return err instanceof Error ? err.message : String(err);
}
