import { render } from 'preact';
// Imported for its side effect, and before anything is rendered: it puts the
// saved interface size on the root element, so the first paint is already at
// that size instead of jumping to it.
import './state/appearance';
import { App } from './ui/App';
import { restoreSession } from './state/session';
import './app.css';

render(<App />, document.getElementById('app')!);
void restoreSession();
