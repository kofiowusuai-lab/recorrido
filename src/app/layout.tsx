import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = { metadataBase: new URL(process.env.NEXT_PUBLIC_SITE_URL ?? 'https://recorrido.example'), title: 'Recorrido', icons: { icon: '/brand/favicon.png' } };
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) { return <html><body>{children}</body></html>; }
