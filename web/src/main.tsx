import { render } from 'preact';
import { App } from './ui/App';
import { restoreSession } from './state/session';
import './app.css';

render(<App />, document.getElementById('app')!);
void restoreSession();
