"use client";

import { createClient } from "@/lib/supabase/client";

export function LoginButton() {
  async function handleLogin() {
    const supabase = createClient();
    const redirectTo = `${window.location.origin}/auth/callback`;

    await supabase.auth.signInWithOAuth({
      provider: "google",
      options: { redirectTo },
    });
  }

  return (
    <button
      type="button"
      onClick={handleLogin}
      className="flex w-full items-center justify-center gap-3 rounded-lg bg-brand px-6 py-3 text-sm font-semibold text-white shadow-brand transition hover:bg-brand-hover"
    >
      Entrar com Google
    </button>
  );
}
