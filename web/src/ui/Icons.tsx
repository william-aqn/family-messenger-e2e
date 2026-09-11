// Lucide icon sprite (MIT). Generated from the design handoff: one hidden <svg>
// with every <symbol> the UI uses, rendered once at the app root, and an <Icon>
// component that references a symbol with <use>. Stroke styling lives in app.css
// (.icon > g), so an icon inherits the current text colour.
export const iconNames = [
  'alert',
  'arrow-left',
  'bot',
  'check',
  'chevron-down',
  'cloud-off',
  'copy',
  'download',
  'file',
  'globe',
  'headphones',
  'image',
  'info',
  'lock',
  'log-out',
  'maximize',
  'message',
  'mic',
  'mic-off',
  'monitor',
  'monitor-off',
  'more',
  'paperclip',
  'pencil',
  'phone',
  'pin',
  'phone-off',
  'plus',
  'qr',
  'refresh',
  'search',
  'send',
  'settings',
  'switch-camera',
  'timer',
  'trash',
  'upload',
  'user',
  'users',
  'video',
  'video-off',
  'wifi-off',
  'x',
  'zap',
] as const;

export type IconName = (typeof iconNames)[number];

/** The sprite itself. Rendered once, at the top of the tree. */
export function IconSprite() {
  return (
    <svg class="icon-sprite" aria-hidden="true">
      <symbol id="i-alert" viewBox="0 0 24 24"><g><path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z"></path><path d="M12 9v4"></path><path d="M12 17h.01"></path></g></symbol>
      <symbol id="i-arrow-left" viewBox="0 0 24 24"><g><path d="m12 19-7-7 7-7"></path><path d="M19 12H5"></path></g></symbol>
      <symbol id="i-bot" viewBox="0 0 24 24"><g><path d="M12 8V4H8"></path><rect width="16" height="12" x="4" y="8" rx="2"></rect><path d="M2 14h2"></path><path d="M20 14h2"></path><path d="M15 13v2"></path><path d="M9 13v2"></path></g></symbol>
      <symbol id="i-check" viewBox="0 0 24 24"><g><path d="M20 6 9 17l-5-5"></path></g></symbol>
      <symbol id="i-chevron-down" viewBox="0 0 24 24"><g><path d="m6 9 6 6 6-6"></path></g></symbol>
      <symbol id="i-cloud-off" viewBox="0 0 24 24"><g><path d="m2 2 20 20"></path><path d="M5.782 5.782A7 7 0 0 0 9 19h8.5a4.5 4.5 0 0 0 1.307-.193"></path><path d="M21.532 16.5A4.5 4.5 0 0 0 17.5 10h-1.79A7.008 7.008 0 0 0 10 5.07"></path></g></symbol>
      <symbol id="i-copy" viewBox="0 0 24 24"><g><rect width="14" height="14" x="8" y="8" rx="2" ry="2"></rect><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"></path></g></symbol>
      <symbol id="i-download" viewBox="0 0 24 24"><g><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path><polyline points="7 10 12 15 17 10"></polyline><line x1="12" x2="12" y1="15" y2="3"></line></g></symbol>
      <symbol id="i-file" viewBox="0 0 24 24"><g><path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"></path><path d="M14 2v4a2 2 0 0 0 2 2h4"></path></g></symbol>
      <symbol id="i-globe" viewBox="0 0 24 24"><g><circle cx="12" cy="12" r="10"></circle><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"></path><path d="M2 12h20"></path></g></symbol>
      <symbol id="i-headphones" viewBox="0 0 24 24"><g><path d="M3 14h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2v-7a9 9 0 0 1 18 0v7a2 2 0 0 1-2 2h-3a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h3"></path></g></symbol>
      <symbol id="i-image" viewBox="0 0 24 24"><g><rect width="18" height="18" x="3" y="3" rx="2" ry="2"></rect><circle cx="9" cy="9" r="2"></circle><path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21"></path></g></symbol>
      <symbol id="i-info" viewBox="0 0 24 24"><g><circle cx="12" cy="12" r="10"></circle><path d="M12 16v-4"></path><path d="M12 8h.01"></path></g></symbol>
      <symbol id="i-lock" viewBox="0 0 24 24"><g><rect width="18" height="11" x="3" y="11" rx="2" ry="2"></rect><path d="M7 11V7a5 5 0 0 1 10 0v4"></path></g></symbol>
      <symbol id="i-log-out" viewBox="0 0 24 24"><g><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"></path><polyline points="16 17 21 12 16 7"></polyline><line x1="21" x2="9" y1="12" y2="12"></line></g></symbol>
      <symbol id="i-maximize" viewBox="0 0 24 24"><g><path d="M8 3H5a2 2 0 0 0-2 2v3"></path><path d="M21 8V5a2 2 0 0 0-2-2h-3"></path><path d="M3 16v3a2 2 0 0 0 2 2h3"></path><path d="M16 21h3a2 2 0 0 0 2-2v-3"></path></g></symbol>
      <symbol id="i-message" viewBox="0 0 24 24"><g><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"></path></g></symbol>
      <symbol id="i-mic" viewBox="0 0 24 24"><g><path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z"></path><path d="M19 10v2a7 7 0 0 1-14 0v-2"></path><line x1="12" x2="12" y1="19" y2="22"></line></g></symbol>
      <symbol id="i-mic-off" viewBox="0 0 24 24"><g><line x1="2" x2="22" y1="2" y2="22"></line><path d="M18.89 13.23A7.12 7.12 0 0 0 19 12v-2"></path><path d="M5 10v2a7 7 0 0 0 12 5"></path><path d="M15 9.34V5a3 3 0 0 0-5.68-1.33"></path><path d="M9 9v3a3 3 0 0 0 5.12 2.12"></path><line x1="12" x2="12" y1="19" y2="22"></line></g></symbol>
      <symbol id="i-monitor" viewBox="0 0 24 24"><g><rect width="20" height="14" x="2" y="3" rx="2"></rect><line x1="8" x2="16" y1="21" y2="21"></line><line x1="12" x2="12" y1="17" y2="21"></line></g></symbol>
      <symbol id="i-monitor-off" viewBox="0 0 24 24"><g><path d="M17 17H4a2 2 0 0 1-2-2V5c0-1.5 1-2 1-2"></path><path d="M22 15V5a2 2 0 0 0-2-2H9"></path><path d="M8 21h8"></path><path d="M12 17v4"></path><path d="m2 2 20 20"></path></g></symbol>
      <symbol id="i-more" viewBox="0 0 24 24"><g><circle cx="12" cy="12" r="1"></circle><circle cx="19" cy="12" r="1"></circle><circle cx="5" cy="12" r="1"></circle></g></symbol>
      <symbol id="i-paperclip" viewBox="0 0 24 24"><g><path d="m21.44 11.05-9.19 9.19a6 6 0 0 1-8.49-8.49l8.57-8.57A4 4 0 1 1 18 8.84l-8.59 8.57a2 2 0 0 1-2.83-2.83l8.49-8.48"></path></g></symbol>
      <symbol id="i-pencil" viewBox="0 0 24 24"><g><path d="M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z"></path><path d="m15 5 4 4"></path></g></symbol>
      <symbol id="i-phone" viewBox="0 0 24 24"><g><path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"></path></g></symbol>
      <symbol id="i-pin" viewBox="0 0 24 24"><g><path d="M12 17v5"></path><path d="M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z"></path></g></symbol>
      <symbol id="i-phone-off" viewBox="0 0 24 24"><g><path d="M10.68 13.31a16 16 0 0 0 3.41 2.6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7 2 2 0 0 1 1.72 2v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.42 19.42 0 0 1-3.33-2.67m-2.67-3.34a19.79 19.79 0 0 1-3.07-8.63A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91"></path><line x1="22" x2="2" y1="2" y2="22"></line></g></symbol>
      <symbol id="i-plus" viewBox="0 0 24 24"><g><path d="M5 12h14"></path><path d="M12 5v14"></path></g></symbol>
      <symbol id="i-qr" viewBox="0 0 24 24"><g><rect width="5" height="5" x="3" y="3" rx="1"></rect><rect width="5" height="5" x="16" y="3" rx="1"></rect><rect width="5" height="5" x="3" y="16" rx="1"></rect><path d="M21 16h-3a2 2 0 0 0-2 2v3"></path><path d="M21 21v.01"></path><path d="M12 7v3a2 2 0 0 1-2 2H7"></path><path d="M3 12h.01"></path><path d="M12 3h.01"></path><path d="M12 16v.01"></path><path d="M16 12h1"></path><path d="M21 12v.01"></path><path d="M12 21v-1"></path></g></symbol>
      <symbol id="i-refresh" viewBox="0 0 24 24"><g><path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"></path><path d="M21 3v5h-5"></path><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"></path><path d="M8 16H3v5"></path></g></symbol>
      <symbol id="i-search" viewBox="0 0 24 24"><g><circle cx="11" cy="11" r="8"></circle><path d="m21 21-4.3-4.3"></path></g></symbol>
      <symbol id="i-send" viewBox="0 0 24 24"><g><path d="m22 2-7 20-4-9-9-4Z"></path><path d="M22 2 11 13"></path></g></symbol>
      <symbol id="i-settings" viewBox="0 0 24 24"><g><path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"></path><circle cx="12" cy="12" r="3"></circle></g></symbol>
      <symbol id="i-switch-camera" viewBox="0 0 24 24"><g><path d="M11 19H4a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h5"></path><path d="M13 5h7a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2h-5"></path><circle cx="12" cy="12" r="3"></circle><path d="m18 22-3-3 3-3"></path><path d="m6 2 3 3-3 3"></path></g></symbol>
      <symbol id="i-timer" viewBox="0 0 24 24"><g><line x1="10" x2="14" y1="2" y2="2"></line><line x1="12" x2="15" y1="14" y2="11"></line><circle cx="12" cy="14" r="8"></circle></g></symbol>
      <symbol id="i-trash" viewBox="0 0 24 24"><g><path d="M3 6h18"></path><path d="M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6"></path><path d="M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2"></path><line x1="10" x2="10" y1="11" y2="17"></line><line x1="14" x2="14" y1="11" y2="17"></line></g></symbol>
      <symbol id="i-upload" viewBox="0 0 24 24"><g><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path><polyline points="17 8 12 3 7 8"></polyline><line x1="12" x2="12" y1="3" y2="15"></line></g></symbol>
      <symbol id="i-user" viewBox="0 0 24 24"><g><path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"></path><circle cx="12" cy="7" r="4"></circle></g></symbol>
      <symbol id="i-users" viewBox="0 0 24 24"><g><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"></path><circle cx="9" cy="7" r="4"></circle><path d="M22 21v-2a4 4 0 0 0-3-3.87"></path><path d="M16 3.13a4 4 0 0 1 0 7.75"></path></g></symbol>
      <symbol id="i-video" viewBox="0 0 24 24"><g><path d="m22 8-6 4 6 4V8Z"></path><rect width="14" height="12" x="2" y="6" rx="2" ry="2"></rect></g></symbol>
      <symbol id="i-video-off" viewBox="0 0 24 24"><g><path d="M10.66 6H14a2 2 0 0 1 2 2v2.5l5.248-3.062A.5.5 0 0 1 22 7.87v8.196"></path><path d="M16 16a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h2"></path><path d="m2 2 20 20"></path></g></symbol>
      <symbol id="i-wifi-off" viewBox="0 0 24 24"><g><path d="M12 20h.01"></path><path d="M8.5 16.429a5 5 0 0 1 7 0"></path><path d="M5 12.859a10 10 0 0 1 5.17-2.69"></path><path d="M19 12.859a10 10 0 0 0-2.007-1.523"></path><path d="M2 8.82a15 15 0 0 1 4.177-2.643"></path><path d="M22 8.82a15 15 0 0 0-11.288-3.764"></path><path d="m2 2 20 20"></path></g></symbol>
      <symbol id="i-x" viewBox="0 0 24 24"><g><path d="M18 6 6 18"></path><path d="m6 6 12 12"></path></g></symbol>
      <symbol id="i-zap" viewBox="0 0 24 24"><g><path d="M4 14a1 1 0 0 1-.78-1.63l9.9-10.2a.5.5 0 0 1 .86.46l-1.92 6.02A1 1 0 0 0 13 10h7a1 1 0 0 1 .78 1.63l-9.9 10.2a.5.5 0 0 1-.86-.46l1.92-6.02A1 1 0 0 0 11 14z"></path></g></symbol>
    </svg>
  );
}

/** One icon. `size` is the design's 12 / 16 / 20 / 24 grid. */
export function Icon({ name, size = 20, class: cls }: { name: IconName; size?: 12 | 16 | 20 | 24 | 32 | 48; class?: string }) {
  return (
    <svg class={cls ? `icon ${cls}` : 'icon'} width={size} height={size} aria-hidden="true">
      <use href={`#i-${name}`} />
    </svg>
  );
}
