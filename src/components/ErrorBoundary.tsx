import { Component, type ErrorInfo, type ReactNode } from 'react';
import { Btn, Pre } from './ui';

/** Contains a crash to the current view so the shell and navigation keep working. */
export class ErrorBoundary extends Component<{ children: ReactNode; resetKey: string }, { error: Error | null }> {
  state = { error: null as Error | null };

  static getDerivedStateFromError(error: Error) {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('view crashed:', error, info.componentStack);
  }

  componentDidUpdate(prev: { resetKey: string }) {
    if (prev.resetKey !== this.props.resetKey && this.state.error) this.setState({ error: null });
  }

  render() {
    if (!this.state.error) return this.props.children;
    return (
      <div className="mx-auto mt-[8vh] flex max-w-[640px] flex-col gap-3 rounded-xl border border-bad/30 bg-card p-5">
        <div className="text-[15px] font-semibold text-bad">This view hit an error</div>
        <div className="text-[12.5px] leading-normal text-muted">Nothing was changed on the server. You can retry, or use the navigation to open another page.</div>
        <Pre>{this.state.error.message}</Pre>
        <div className="flex gap-2">
          <Btn variant="primary" size="md" onClick={() => this.setState({ error: null })}>Try again</Btn>
          <Btn size="md" onClick={() => location.reload()}>Reload console</Btn>
        </div>
      </div>
    );
  }
}
