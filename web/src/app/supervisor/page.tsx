import { SupervisorDashboard } from "@/components/supervisor/supervisor-dashboard";
import { getPerfilUtilizador } from "@/lib/auth/perfil";
import { createClient } from "@/lib/supabase/server";
import { redirect } from "next/navigation";

export default async function SupervisorPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/");
  }

  const perfil = await getPerfilUtilizador(supabase);

  if (!perfil.sucesso || !perfil.utilizador) {
    redirect("/sem-acesso");
  }

  if (!perfil.utilizador.is_supervisao) {
    redirect("/operador");
  }

  return <SupervisorDashboard perfil={perfil.utilizador} />;
}
