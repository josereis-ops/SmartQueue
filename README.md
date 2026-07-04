# Smart Queue v2

POC multi-área para gestão de filas operacionais. Stack: **Next.js (Vercel)** + **Supabase** (PostgreSQL, Auth, Realtime, RPCs).

Sistema legado Google Apps Script em [`legacy/`](legacy/) — referência only, não alterar.

## Estrutura

```
SmartQueue/
├── legacy/              # Exports GAS (referência)
├── web/                 # Frontend Next.js → Vercel
├── supabase/
│   └── migrations/      # Schema + RLS + RPCs
└── scripts/             # Seeds e utilitários
```

## Pré-requisitos

- Node.js 20+
- Git, GitHub CLI (`gh`), Supabase CLI, Vercel CLI
- Conta Supabase (EU) — projecto `SmartQueue`

## Setup local

```powershell
# 1. Variáveis de ambiente
cp .env.example web/.env.local   # preencher NEXT_PUBLIC_SUPABASE_*

# 2. Supabase — projecto já ligado
supabase link --project-ref gwjfwdbwydwtkxffhysb

# 3. Frontend Next.js (MS-07+)
cd web
npm install
npm run dev
```

### Google OAuth (Supabase Dashboard)

1. **Authentication → Providers → Google** — activar e configurar Client ID/Secret
2. **Authentication → URL Configuration** — redirect URLs:
   - `http://localhost:3000/auth/callback`
   - `https://<teu-projeto-vercel>.vercel.app/auth/callback`
3. **Authentication → Hooks → before-user-created** — Postgres function:
   - `public.hook_before_user_created` (migration MS-07)

## Deploy

| Serviço   | Destino                          |
|-----------|------------------------------------|
| Frontend  | Vercel (ligado ao repo GitHub)     |
| Backend   | Supabase RPCs + RLS (sem servidor) |
| Base dados| Supabase EU (`eu-central-1`)       |

## Comandos úteis

```powershell
supabase db push          # aplicar migrations
supabase db diff          # gerar migration a partir de alterações
gh repo view --web        # abrir repo no browser
```
