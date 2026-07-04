import type { Config } from "tailwindcss";

const config: Config = {
  content: [
    "./src/pages/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/components/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/app/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
    extend: {
      colors: {
        brand: {
          DEFAULT: "#2175D9",
          hover: "#1a5eb1",
        },
        navy: "#0F1941",
        card: "#0b122e",
        input: "#162454",
        surface: "#0b122e",
        muted: "#9CA3AF",
        "gray-light": "#E5E7EB",
        success: "#10B981",
        warning: "#F59E0B",
        danger: "#EF4444",
      },
      fontFamily: {
        sans: ["var(--font-inter)", "system-ui", "sans-serif"],
      },
      boxShadow: {
        brand: "0 4px 24px rgba(33, 117, 217, 0.25)",
        card: "0 12px 40px rgba(0, 0, 0, 0.45)",
      },
    },
  },
  plugins: [],
};
export default config;
