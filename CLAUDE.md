# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

S.C.O.R.E is a video behavior-annotation platform: admins upload videos to a shared library, group them into projects with a configurable list of behaviors, add members, and auto-generate annotator assignments. Annotators mark time segments per behavior on their assigned videos and submit (which locks the annotation).

Monorepo with two independent apps and no root-level tooling:

- `backend/` — FastAPI + SQLAlchemy + Postgres, managed with `uv` (Python 3.13)
- `frontend/` — Next.js 15 App Router + React 19 + Zustand + Tailwind v4

There is no automated test suite in either app.

## Commands

### Backend (run from `backend/`)

```bash
uv sync                      # install deps (incl. dev group: pyrefly)
uv run fastapi dev           # dev server on :8000 with reload (needs .env, see below)
uv run pyrefly check         # type check (models/ and preprocess.py are excluded in pyrefly.toml)
docker compose up --build    # api + postgres + caddy (reads .env; mounts $GOOGLE_CREDENTIALS_FILE)
```

Backend requires a `backend/.env` with every non-defaulted field in `app/core/config.py` (`DATABASE_URL`, `AUTH_*`, `GCS_BUCKET_NAME`, `GOOGLE_APPLICATION_CREDENTIALS`, `ADMIN_EMAIL`/`ADMIN_PASSWORD`, `FRONTEND_URL`, `BACKEND_URL`, `YOLO_MODEL_PATH`, ...). Set `IS_PRODUCTION=false` locally: in production mode auth cookies use the `__Host-` prefix and `secure=True`, which browsers reject over plain HTTP.

### Frontend (run from `frontend/`)

```bash
npm install
npm run dev       # next dev --turbopack on :3000
npm run build
npm run lint      # eslint (next/core-web-vitals + next/typescript)
```

`next.config.ts` rewrites `/api/v1/*`, `/auth/*`, and `/health` to `BACKEND_PROXY_URL` (default `http://localhost:8000`), so in dev `NEXT_PUBLIC_API_URL` can be left empty and the browser talks same-origin (cookies just work). If `NEXT_PUBLIC_API_URL` is set, the client calls the backend directly and CORS / `ALLOWED_ORIGINS` matters.

## Backend architecture

Request flow: `app/api/v1/<resource>.py` (router) -> `app/api/dependencies.py` (builds a service) -> `app/services/<resource>.py` -> SQLAlchemy models in `app/database/models.py`.

- **ServiceContext**: `get_service_context` resolves the cookie JWT to a `ServiceContext(user_id, is_admin)` and every service takes `db` + `ctx`. Authorization is enforced twice on admin routes: `Depends(require_role("admin"))` at the route and `self._require_admin()` inside the service. Member-scoped checks (e.g. "you are assigned to this video") live only in the service.
- **Errors**: services raise the custom exceptions in `app/core/exceptions.py` (`NotFoundError`, `ForbiddenError`, `ConflictError`, `BadRequestError`, `ProcessingError`, `GCSError`, ...); `main.py` maps each to an HTTP status. Only `services/auth.py` raises `HTTPException` directly. Add new error types to both files.
- **Schemas** (`app/database/schemas.py`): all request/response models inherit `BaseRequest` / `BaseResponse`, which apply a `to_camel` alias generator with `populate_by_name=True`. The wire format is camelCase (`startTime`, `projectVideoId`); Python code uses snake_case. `VideoService.list_all` returns hand-built camelCase dicts rather than ORM objects.
- **Database**: tables are created with `Base.metadata.create_all` at startup in `db.py`; there are no migrations. Schema changes to existing tables require dropping/recreating the DB (or a manual ALTER). `init_db` also seeds an admin user from `ADMIN_EMAIL` / `ADMIN_PASSWORD` if absent.
- **Auth** (`services/auth.py`, `api/v1/auth.py`): JWT (HS256) stored in an httpOnly cookie; both email/password (bcrypt) and Google OAuth (state + nonce cookies, id_token verified via `google-auth`) are supported and can link to the same user by email. `POST /auth/refresh` re-issues the cookie. Routers: `/auth/*` and `/health` are mounted at root; everything else is under `/api/v1`.
- **Video storage**: videos live in a GCS bucket (`services/gcs.py`, singleton client from a service-account file). The current upload path is direct-to-GCS: `POST /videos/upload-url` returns a signed PUT URL, the browser uploads, then `POST /videos` registers the row. Playback uses a signed GET URL from `GET /videos/{id}/url`. The multipart `POST /videos/upload` route still exists but is the legacy path.
- **Preprocessing / YOLO**: `services/preprocess.py` (chamber detection and cropping with ultralytics/opencv/ffmpeg) is intentionally disabled: its imports and the `PreprocessService` dependency are commented out and its deps are not in `pyproject.toml`. `backend/models/` holds the YOLO training data and scripts (`train.py`, `utils.py`), which likewise need `ultralytics` installed separately.

### Domain model

```
Video (global library, admin-only)
  └─ ProjectVideo (link to a Project; unique per project+video)
       └─ Assignment (ProjectVideo x User; unique; status Not Started / In Progress / Completed)
            └─ Annotation (1:1 with Assignment; JSON `segments`; `submitted` locks it)
Project ── ProjectMember (User) ; `behaviors` is a JSON list of {name, hotkey, description?, threshold?}
```

`ProjectAssignmentService.create_project_assignments` is the "balanced pairing" algorithm: a min-heap over member workload hands each project video to the `annotators_per_video` least-loaded members. It refuses to run if any assignments already exist for the project (delete them first) or if `annotators_per_video` exceeds the member count. Cascades: deleting a project removes its members, video links, assignments, and annotations; a video cannot be deleted while linked to any project.

A segment is `{behavior, startTime, endTime | null, notes?}`; `endTime: null` means in progress. `AnnotationService` only allows the assigned user to read/write, and `update` is rejected once `submitted` is true.

## Frontend architecture

- **Routing**: `app/(protected)/layout.tsx` wraps `dashboard`, `projects/[project_id]`, and `annotate/[assignment_id]` in `AuthProvider`, which fetches `/auth/me`, redirects to `/login` on failure, and starts the session refresh timer. `/` and `/login` both render `components/Login.tsx`. Pages are thin; the real UI is in `components/`.
- **API client** (`lib/api.ts`): single `api.get/post/put/patch/del` wrapper. Always sends `credentials: "include"`; on a 401 it attempts one `/auth/refresh` and retries, then clears the user store and hard-redirects to `/login`. Pass `skipAuthRedirect: true` for login/signup calls. `SessionManager` proactively refreshes every 10 min while the user has been active in the last 15 min, and on tab re-focus.
- **State**: one Zustand store per domain in `store/` (`useUserStore`, `useProjectStore`, `useVideoStore`, `useAssignmentStore`, `useAnnotationStore`). Stores own the API calls; components read from stores. `useUserStore.searchUsers` and the video equivalent filter client-side over a cached full list because the backend list endpoints take no search params. `useAnnotationStore` holds the annotation workspace state (playhead, segments, start/end behavior, overlap merging of same-behavior segments).
- **Annotation workspace**: `AnnotationWorkspace` = `VideoHandler` / `VideoPlayer` + `BehaviorToggles` (hotkeys from the project's behaviors) + `ControlPanel` (save / submit / export / status) + `Timeline`. `VideoHandler` loads `/assignments/{id}/context` for the video id and behavior list, then fetches the signed playback URL. `ControlPanel` creates the annotation on first save (POST) and updates afterwards (PUT), and blocks submit while any segment is still open.
- **Styling**: Tailwind v4 with the theme defined in `app/globals.css` via `@theme` tokens mapped to CSS variables (`--color-primary`, `--color-muted-foreground`, etc.) with light/dark values. Use those semantic classes (`bg-background`, `text-muted-foreground`, `border-border`) rather than raw palette colors. Fonts are monospace throughout (Geist Mono / JetBrains Mono).
- **Types** in `types/` mirror backend response schemas and use camelCase. The one exception is `GET /assignments/{id}/context`, which returns a raw dict with `video_id` because it has no response model.

## Conventions

- Commit messages follow Conventional Commits with optional scope (`feat(backend): ...`, `fix(auth): ...`, `refactor(SessionManager): ...`); work lands via PRs from feature branches (`feature/...`, `fix/...`, `ci/...`) into `main`.
- `backend/.gitignore` excludes `*.pt` weights, `runs/`, `tmp/`, `out/`; don't commit model weights or uploaded media.
