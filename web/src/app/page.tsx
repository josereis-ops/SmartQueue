import { LoginButton } from "@/components/login-button";
import { getPerfilUtilizador } from "@/lib/auth/perfil";
import { createClient } from "@/lib/supabase/server";
import { redirect } from "next/navigation";

interface HomeProps {
  searchParams: { error?: string };
}

export default async function Home({ searchParams }: HomeProps) {
  const params = searchParams;
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (user) {
    const perfil = await getPerfilUtilizador(supabase);
    if (perfil.sucesso && perfil.utilizador) {
      redirect(
        perfil.utilizador.is_supervisao ? "/supervisor" : "/operador"
      );
    }
    redirect("/sem-acesso");
  }

  return (
    <main className="flex min-h-screen items-center justify-center p-6">
      <div className="w-full max-w-md rounded-xl border border-white/10 bg-surface p-8 shadow-xl">
        <div className="mb-8 border-t-4 border-brand pt-2">
          <p className="text-xs font-semibold uppercase tracking-widest text-muted">
            Smart Queue v2
          </p>
          <h1 className="mt-2 text-2xl font-bold text-white">Bem-vindo</h1>
          <p className="mt-2 text-sm leading-relaxed text-muted">
            Utiliza o email da empresa que a gestão te atribuiu. Só entram
            utilizadores pré-registados.
          </p>
        </div>

        {params.error === "auth" && (
          <p className="mb-4 rounded-lg bg-red-500/10 px-4 py-3 text-sm text-red-300">
            Falha na autenticação. Tenta novamente.
          </p>
        )}

        <LoginButton />

        <p className="mt-6 text-center text-xs text-muted/70">
          Acesso gerido pela equipa de supervisão
        </p>
      </div>
    </main>
  );
}
