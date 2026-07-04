import { redirect } from "next/navigation";

/** Legado MS-07 — redirecciona para /operador */
export default function AppPage() {
  redirect("/operador");
}
