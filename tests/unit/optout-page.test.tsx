import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { StrictMode } from 'react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { OptOutPage } from '@/components/optout/OptOutPage';

const copy = {
  eyebrow: 'Message preferences', title: 'Stop Recorrido outreach', body: 'Confirm below.',
  confirm: 'Stop messages', missing: 'Use the complete link.', waiting: 'Processing…',
  success: 'You will no longer receive Recorrido outreach messages.', unavailable: 'Could not complete.',
  fallback: 'Reply STOP in the original conversation.', back: 'Back to Recorrido', support: 'Email support',
};
const token = 'A'.repeat(32);

describe('OptOutPage', () => {
  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
    window.history.replaceState({}, '', '/');
  });

  it('does not submit on page load and requires a valid fragment token plus explicit click', async () => {
    const fetchSpy = vi.fn(async () => new Response(JSON.stringify({ status: 'success', message: copy.success }), { status: 200 }));
    vi.stubGlobal('fetch', fetchSpy);
    window.history.replaceState({}, '', `/en/opt-out#token=${token}`);
    render(<StrictMode><OptOutPage locale="en" copy={copy} /></StrictMode>);
    const button = await screen.findByRole('button', { name: copy.confirm });
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(window.location.hash).toBe('');
    fireEvent.click(button);
    await waitFor(() => expect(screen.getByText(copy.success)).toBeInTheDocument());
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    expect(fetchSpy).toHaveBeenCalledWith('/api/opt-out', expect.objectContaining({ method: 'POST', body: JSON.stringify({ token, locale: 'en' }) }));
    expect(button).toBeDisabled();
  });

  it('fails closed when the fragment token is missing', async () => {
    const fetchSpy = vi.fn();
    vi.stubGlobal('fetch', fetchSpy);
    window.history.replaceState({}, '', '/es/baja');
    render(<OptOutPage locale="es" copy={copy} />);
    expect(await screen.findByText(copy.missing)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: copy.confirm })).not.toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'recorrido@agentmail.to' })).toHaveAttribute('href', 'mailto:recorrido@agentmail.to');
    expect(fetchSpy).not.toHaveBeenCalled();
  });
});
