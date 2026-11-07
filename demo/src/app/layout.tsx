import type { Metadata } from "next";
import type { ReactNode } from "react";
import { GardenProvider } from "./providers";
import "./globals.css";

export const metadata: Metadata = {
  title: "Greenhouse",
  description: "Water what's thirsty, and nothing else.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        <GardenProvider>{children}</GardenProvider>
      </body>
    </html>
  );
}
