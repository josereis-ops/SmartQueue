import { SignOutButton } from "@/components/sign-out-button";
import { getPerfilUtilizador } from "@/lib/auth/perfil";
import { createClient } from "@/lib/supabase/server";
import { redirect } from "next/navigation";

export default async function SemAcessoPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/");
  }

  const perfil = await getPerfilUtilizador(supabase);

  if (perfil.sucesso) {
    redirect("/operador");
  }

  const mensagem =
    perfil.mensagem ?? "Não tens acesso ao sistema.";
  const emailTentativa =
    perfil.email_tentativa ?? user.email ?? "desconhecido";

  return (
    <main className="flex min-h-screen items-center justify-center p-6">
      <div className="w-full max-w-lg rounded-xl border border-white/10 bg-surface p-8">
        <h2 className="text-xl font-semibold lowercase text-brand">
          acesso pendente
        </h2>
        <p className="mt-4 text-sm leading-relaxed text-gray-light">
          {mensagem}
        </p>
        <p className="mt-5 text-xs text-brand/70">
          utilizador detetado: {emailTentativa}
        </p>
        <div className="mt-8">
          <SignOutButton />
        </div>
      </div>
    </main>
  );
}
